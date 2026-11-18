import CoreGraphics
import CoreText
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Exact unchanged text does not justify erasing and approximating original lettering.
/// Shared by live Reader regions and historical serialized native layout items.
enum NativeSourceTextPreservation {
    static func matches(source: String?, translated: String?) -> Bool {
        guard let source, let translated else { return false }
        let original = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return !original.isEmpty && original == translated.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalized(_ items: [[String: Any]]) -> [[String: Any]] {
        items.map { item in
            guard matches(source: item["sourceOriginalText"] as? String, translated: item["text"] as? String) else {
                return item
            }
            var preserved = item
            preserved["keptLettering"] = true
            preserved["sourceTextOnly"] = true
            return preserved
        }
    }
}

/// The ordinary reader, synchronous renderer and CLI PDF exporter share this route.
/// The old panel renderer remains an explicit rollback, never a silent success fallback.
enum NativeMainEnsembleRenderer {
    static var enabled: Bool {
        guard #available(iOS 18.0, macOS 15.0, *) else { return false }
        return ProcessInfo.processInfo.environment["AIDOKU_LEGACY_PANEL_RENDERER"] != "1"
    }

    private enum Metadata { case diagnostics, layout, pixelsOnly }

    struct Page {
        let result: NativeAOTTranslationPageComposer.Result
        let layoutData: Data
        let diagnostics: Data
        let count: Int
    }

    /// Shared source-local adapter for the renderer and authenticated host probes.
    /// No owner selection, display consolidation, or source policy occurs here.
    @available(iOS 16.0, macOS 13.0, *)
    static func sourceLocalMapper(layout: NativeTranslationLayout, source: CGImage) throws
        -> (map: ([String: Any]) -> [String: Any], sx: CGFloat, sy: CGFloat) {
        let frame = layout.sourceRect
        guard [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
              frame.width > 0, frame.height > 0 else { throw NativeTranslationRenderer.RenderError.invalidGeometry }
        // Keep all source evidence normalized. Only viewport-valued typography is
        // transformed into a source-local viewport; this also handles reader letterboxing.
        let sx = CGFloat(source.width) / frame.width
        let sy = CGFloat(source.height) / frame.height
        guard sx.isFinite, sy.isFinite, sx > 0, sy > 0 else { throw NativeTranslationRenderer.RenderError.invalidGeometry }
        func local(_ value: [String: Any]) -> [String: Any] {
            var item = value
            for key in ["x", "width", "paddingLeft", "paddingRight", "fontSize", "lineHeight", "sourceFontSize"] {
                if let n = value[key] as? NSNumber { item[key] = n.doubleValue * Double(sx) }
            }
            for key in ["y", "height", "paddingTop", "paddingBottom", "inspectionHeight"] {
                if let n = value[key] as? NSNumber { item[key] = n.doubleValue * Double(sy) }
            }
            if let x = value["x"] as? NSNumber { item["x"] = (x.doubleValue - Double(frame.minX)) * Double(sx) }
            if let y = value["y"] as? NSNumber { item["y"] = (y.doubleValue - Double(frame.minY)) * Double(sy) }
            for key in ["uprightAlternative", "columnLayout"] {
                if let nested = value[key] as? [String: Any] { item[key] = local(nested) }
            }
            item["sourceFrame"] = [0.0, 0.0, Double(source.width), Double(source.height)]
            item["enableVerticalDisplayTitles"] = true
            return item
        }
        return (local, sx, sy)
    }

    @available(iOS 16.0, macOS 13.0, *)
    static func page(layout: NativeTranslationLayout, source: CGImage,
                     completeEvidence: NativeMainEnsembleRenderEvidence? = nil,
                     preparedDB:NativeMainEnsemblePreparedDB? = nil) throws -> Page {
        try page(layout: layout, source: source, completeEvidence: completeEvidence, preparedDB: preparedDB, metadata: .diagnostics)
    }

    @available(iOS 16.0, macOS 13.0, *)
    private static func page(layout: NativeTranslationLayout, source: CGImage,
                     completeEvidence: NativeMainEnsembleRenderEvidence? = nil,
                     preparedDB: NativeMainEnsemblePreparedDB?, metadata: Metadata) throws -> Page {
        try Task.checkCancellation()
        let localized = try sourceLocalMapper(layout: layout, source: source)
        let local = localized.map, sx = localized.sx, sy = localized.sy
        var raw = NativeSourceTextPreservation.normalized(layout.items.map { local($0.payload) })
        defer {withExtendedLifetime(preparedDB) {}}
        let completeSelection = try completeEvidence?.selection(for: source)
        let evidence: (regions: [Ensemble100RFRegion], probability: NativeMainAOTRemovalMaskBuilder.SourceProbability?)
        let packet: NativeMainEnsembleOCREvidence.Packet?
        let lookupSource: NativeMainEnsemblePreparedDB.SourceBinding?
        let revisionContentIdentity: String
        if let completeSelection {
            lookupSource = nil
            revisionContentIdentity = completeSelection.ocr.binding.contentIdentity
            evidence = (completeSelection.regions, completeSelection.probability)
            packet = completeSelection.ocr
        } else {
            guard let preparedDB else {throw NativeMainEnsemblePreparedDB.Failure.requiredDBUnavailable}
            try preparedDB.validate(original:source)
            let binding = preparedDB.sourceBinding
            lookupSource = binding
            revisionContentIdentity = binding.identity
            let existing = try NativeMainEnsembleEvidenceStore.shared.evidence(source: binding)
            evidence = (existing.regions, preparedDB.probability)
            packet = NativeMainEnsembleEvidenceStore.shared.ocr(source: binding)
        }
        var saved = try packet?.savedEvidence(currentOriginalItems: raw, removalMaskAvailable: false) ?? [:]
        var revisionAudit: [[String: Any]] = []
        let sourceRevisionData: Data?
        if let lookupSource { sourceRevisionData = NativeMainEnsembleEvidenceStore.shared.sourceRevision(source: lookupSource) }
        else { sourceRevisionData = completeSelection?.revisionData }
        if let data = sourceRevisionData,
           let revision = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let resolved = try NativeMainSourceRevision.validate(revision, displayItems: raw,
                imageSize: CGSize(width: source.width, height: source.height),
                canonicalSourceIdentity: NativeMainEnsembleOCREvidence.Binding.candidateIdentity(for: revisionContentIdentity),
                localize: { original in
                    let data = try JSONSerialization.data(withJSONObject: original)
                    let typed = try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: data)
                    return local(typed.payload)
                })
            saved["sourceRevisionRemovalItems"] = resolved.removalItems
            saved["sourceRevisionOwnCapacityOwnerIDs"] = resolved.ownCapacityOwnerIDs
            revisionAudit = resolved.transactions
        }
        // Frozen layout replays otherwise retain historical source-axis errors.
        // OCR is already bound to this exact image by the evidence store. Only
        // one exact, unclipped source rectangle may repair an active owner.
        let direction = recoverSourceDirections(raw, evidence: saved,
            imageSize: CGSize(width: source.width, height: source.height))
        let parameters = try NativeMainEnsembleConfiguration.parameters()
        let short = recoverShortSources(direction.items, evidence: saved,
            imageSize: CGSize(width: source.width, height: source.height),
            recoverFont: parameters["pipeline"]?["recoverShortSourceFont"] == 1,
            recoverDirection: parameters["pipeline"]?["recoverShortSourceDirection"] == 1)
        raw = short.items
        if let request = NativeSourceBackedRFProtection.request(original: source, regions: evidence.regions) {
            saved[NativeSourceBackedRFProtection.sourceEvidenceKey] = request
        }
        let sourceStyles = try NativeLiveSourceAppearance.shared.annotate(source: source, items: raw, sourceEvidence: saved)
        saved.removeValue(forKey: NativeSourceBackedRFProtection.sourceEvidenceKey)
        // Actual fresh-pipeline A/B found an admission loss with newly available
        // contours. Keep this handoff opt-in until its shape/domain failure is fixed.
        let sourceRFHandoffEnabled = completeSelection == nil && ProcessInfo.processInfo.environment["AIDOKU_SOURCE_RF_LAYOUT_HANDOFF"] == "1"
        let freshRFSelected = sourceRFHandoffEnabled && sourceStyles.sourceRF != nil
        let regions = try sourceStyles.resolvedRegions(original: source, fallback: evidence.regions,
            useFreshSourceRF: sourceRFHandoffEnabled)
        raw = NativeTextSpacing.defaults(sourceStyles.items)
        let renderViewport = CGSize(width: source.width, height: source.height)
        let simplePlacement: NativeSimpleRFBalloonPlacement?
        if let completeEvidence {
            simplePlacement = try completeEvidence.makeSimplePlacement(items: raw, viewport: renderViewport)
        } else {
            simplePlacement = try NativeMainEnsembleEvidenceStore.shared.makeSimplePlacement(
                original: source, items: raw, viewport: renderViewport)
        }
        raw = try NativeOperationalRenderExpansion.annotate(items:raw,
            viewport: renderViewport, source: source, regions: regions, simplePlacement: simplePlacement)
        if let masks = sourceStyles.sourceSegmentationMasks { saved["sourceSegmentationMasks"] = masks }
        if let rf = sourceStyles.sourceRF { saved["retainedSourceRF"] = rf }
        saved["originalItems"] = saved["sourceRevisionRemovalItems"] ?? raw
        if let packet {
            // Both region and OCR stores were looked up against this exact
            // canonical source. This is a content-domain token, not a file SHA.
            saved["rfSourceSHA256"] = packet.binding.candidateIdentity
        }
        let render = {
            try NativeMainEnsemblePipeline.render(original: source, rawItems: raw,
                viewport: CGSize(width: source.width, height: source.height), rfRegions: regions,
                savedEvidence: saved, sourceProbability: evidence.probability,
                unownedMasks: try completeSelection?.unownedMasks
                    ?? NativeMainEnsembleEvidenceStore.shared.unownedMasks(original: source),
                simplePlacement: simplePlacement, parameters: parameters, collectAudit: metadata == .diagnostics)
        }
        let result: NativeAOTTranslationPageComposer.Result
        if NativeEnsembleLayoutContour.supportedEstimatedContourEnabled {
            let identity = packet?.binding.candidateIdentity ?? sourceStyles.sourceRF?.sourceIdentity ?? ""
            result = try NativeSupportedEstimatedContour.withSource(sourceSHA256: identity,
                regions: regions, operation: render)
        } else {
            result = try render()
        }
        guard metadata == .diagnostics else {
            let layoutData = metadata == .layout ? try JSONEncoder().encode(layout) : Data()
            return Page(result: result, layoutData: layoutData, diagnostics: Data(), count: result.paintedItemCount)
        }
        var audit = result.audit
        audit["completeEvidenceHandoff"] = completeSelection?.audit ?? [
            "path": "legacy-global-source-bound-store", "allRequiredSlotsAvailable": false]
        audit["dbCapability"] = completeSelection == nil ? ["path":"strict-current-local-capability",
            "required":true,"actualDetectorCalls":preparedDB?.detectorCalls ?? 0,
            "mapSHA256":preparedDB?.probability.capability?.mapSHA256 ?? "",
            "actualProducerConsumerSHA256":preparedDB?.probability.capability?.consumerConfigurationSHA256 ?? "",
            "currentConsumerSHA256":preparedDB?.currentConsumerConfigurationSHA256 ?? "",
            "rawGridReusedAcrossConsumerChange":preparedDB?.probability.capability?.consumerConfigurationSHA256 != preparedDB?.currentConsumerConfigurationSHA256] : ["path":"explicit-complete-evidence",
            "required":true,"currentModelProofAdded":false]
        audit["mainApplied"] = true
        audit["entrypoint"] = "NativeTranslationRenderer/NativeMainEnsemblePipeline"
        audit["inputLayoutItems"] = layout.items.count
        audit["sourceDirectionRecovery"] = direction.audit
        audit["shortSourceRecovery"] = short.audit
        audit["sourceOwnerRecovery"] = [["status": "removed;upstream-owners-preserved"]]
        audit["sourceRevisionTransactions"] = revisionAudit
        audit["textSpacingPolicy"] = ["version": NativeTextSpacing.version, "defaultTracking": 0,
            "maximumTrackingReductionEm": Double(NativeTextSpacing.maximumTrackingReduction),
            "defaultLineHeightEm": 1.2, "lineHeightStepEm": 0.1, "lineHeightAuthority": "font-metrics-and-effects", "outlineClearance": true, "sameStyleDefaults": true,
            "baselinePolicy": "native-runs; visible-ink block alignment", "innerPaddingEm": 0.12,
            "innerPaddingPixelRange": [1,8]] as [String: Any]
        audit["rfRegionCount"] = regions.count
        audit["sourceRFHandoff"] = ["enabled": sourceRFHandoffEnabled,
            "freshSourceRFAvailable": sourceStyles.sourceRF != nil,
            "freshSourceRFSelected": freshRFSelected, "identityVerified": freshRFSelected,
            "previousEvidenceRegionCount": evidence.regions.count, "selectedRegionCount": regions.count,
            "authority": freshRFSelected ? "same-call executable source appearance RF" : "source-bound existing evidence",
            "additionalDetectorCalls": 0] as [String: Any]
        audit["ocrEvidenceHandoff"] = ["registered": packet != nil,
            "identityDomain": saved["sourceIdentityDomain"] ?? NSNull(),
            "stageAvailability": saved["ocrStageAvailability"] ?? NSNull(),
            "projectedBytes": saved["ocrRetainedBytes"] ?? NSNull(),
            "clippedRecordCount": saved["ocrClippedRecordCount"] ?? NSNull(),
            "encodedSourceSHA256": saved["verifiedEncodedSourceSHA256"] ?? NSNull(),
            "authority": "source-bound projected OCR; clipped source observations retained; not glyph ground truth"] as [String: Any]
        audit["sourceLocalScale"] = [Double(sx), Double(sy)]
        audit["independentValidationComplete"] = false
        let data = try JSONSerialization.data(withJSONObject: audit, options: [.sortedKeys])
        return Page(result: result, layoutData: try JSONEncoder().encode(layout), diagnostics: data,
            count: result.paintedItemCount)
    }

    static func recoverSourceDirections(_ items: [[String: Any]], evidence: [String: Any],
                                        imageSize: CGSize) -> (items: [[String: Any]], audit: [[String: Any]]) {
        guard let ocr = evidence["originalOCR"] as? [String: Any],
              let rows = ocr["regions"] as? [[String: Any]],
              imageSize.width > 0, imageSize.height > 0 else { return (items, []) }
        var audit: [[String: Any]] = []
        let result = items.map { original -> [String: Any] in
            guard original["sourceVertical"] as? Bool == false,
                  original["keptLettering"] as? Bool != true,
                  original["sourceTextOnly"] as? Bool != true,
                  !(original["text"] as? String ?? "").isEmpty,
                  let bounds = original["sourceBounds"] as? [Double], bounds.count == 4,
                  bounds.allSatisfy(\.isFinite), bounds[2] > 0, bounds[3] > 0 else { return original }
            let matches = rows.filter { row in
                guard let b = row["sourceBounds"] as? [Double], b.count == 4,
                      b.allSatisfy(\.isFinite) else { return false }
                // Tolerance is floating-point transport only, much less than a pixel.
                return zip(b, bounds).allSatisfy { abs($0 - $1) <= 1e-8 }
            }
            guard matches.count == 1, let row = matches.first,
                  row["sourceOrientation"] as? String == "vertical",
                  let observation = row["sourceGeometryObservation"] as? [String: Any],
                  observation["rectClipped"] as? Bool == false,
                  observation["polygonClipped"] as? Bool == false,
                  let text = row["source"] as? String else { return original }
            let pixels = CGRect(x: bounds[0] * imageSize.width, y: bounds[1] * imageSize.height,
                width: bounds[2] * imageSize.width, height: bounds[3] * imageSize.height)
            guard BrowserOverlayTextFlow.usesVerticalSourceLayout(rect: pixels, text: text,
                sourceOrientation: .vertical) else { return original }
            var value = original
            value["sourceVertical"] = true
            audit.append(["id": original["id"] ?? NSNull(), "beforeVertical": false, "afterVertical": true,
                "authority": "unique source-bound unclipped OCR rectangle; explicit vertical and script/pixel geometry",
                "sourceFontSizeReestimated": false])
            return value
        }
        return (result, audit)
    }

    /// Candidate only: pipeline.recoverShortSourceFont/Direction are opt-in.
    /// A native glyph fitted to its OWN source rectangle is a forecast, not an
    /// observed original font or permission to join overlapping translations.
    /// Keep every owner/string/geometry intact, including possible duplicates.
    static func recoverShortSources(_ items: [[String: Any]], evidence: [String: Any], imageSize: CGSize,
                                    recoverFont: Bool = false, recoverDirection: Bool = false)
        -> (items: [[String: Any]], audit: [[String: Any]]) {
        guard recoverFont || recoverDirection else { return (items, []) }
        guard let ocr = evidence["originalOCR"] as? [String: Any],
              let rows = ocr["regions"] as? [[String: Any]], rows.count <= 4096, items.count <= 4096,
              imageSize.width.isFinite, imageSize.height.isFinite, imageSize.width > 0, imageSize.height > 0 else {
            return (items, [])
        }
        func rectangle(_ value: Any?) -> CGRect? {
            guard let b = value as? [Double], b.count == 4, b.allSatisfy(\.isFinite),
                  b[0] >= 0, b[1] >= 0, b[2] > 0, b[3] > 0, b[0] + b[2] <= 1, b[1] + b[3] <= 1 else { return nil }
            return CGRect(x: b[0], y: b[1], width: b[2], height: b[3])
        }
        func unclipped(_ row: [String: Any]) -> Bool {
            guard let observation = row["sourceGeometryObservation"] as? [String: Any] else { return false }
            return observation["rectClipped"] as? Bool == false && observation["polygonClipped"] as? Bool == false &&
                (row["clippedUnitMemberIndices"] as? [Int] ?? []).isEmpty
        }
        let boxes = rows.map { rectangle($0["sourceBounds"]) }
        var audit: [[String: Any]] = []
        let font = CTFontCreateWithName("HiraginoSans-W3" as CFString, 100, nil)
        let result = items.map { original -> [String: Any] in
            guard original["keptLettering"] as? Bool != true, original["sourceTextOnly"] as? Bool != true,
                  !(original["text"] as? String ?? "").isEmpty,
                  let box = rectangle(original["sourceBounds"]) else { return original }
            let matches = boxes.indices.filter { index in
                guard let candidate = boxes[index] else { return false }
                return zip([box.minX, box.minY, box.width, box.height],
                    [candidate.minX, candidate.minY, candidate.width, candidate.height]).allSatisfy { abs($0 - $1) <= 1e-8 }
            }
            guard matches.count == 1, let index = matches.first, unclipped(rows[index]),
                  let source = rows[index]["source"] as? String, !source.isEmpty, source.count <= 3 else { return original }
            var record: [String: Any] = ["id": original["id"] ?? NSNull(), "sourceOCRIndex": index,
                "sourceUTF16": source.utf16.count, "fontApplied": false, "directionApplied": false,
                "translationUTF16Unchanged": true, "ownersAndGeometryUnchanged": true,
                "fontRecoveryEnabled": recoverFont, "directionRecoveryEnabled": recoverDirection]
            var relations: [[String: Any]] = []
            for peer in boxes.indices where peer != index {
                guard let other = boxes[peer], let text = rows[peer]["source"] as? String, !text.isEmpty else { continue }
                let overlap = box.intersection(other)
                let fraction = overlap.isNull ? 0 : overlap.width * overlap.height / (box.width * box.height)
                guard fraction >= 0.6 else { continue }
                let relation: String
                if text == source || text.hasPrefix(source) {
                    relation = "overlappingDuplicatePrefixCandidate"
                } else if text.contains(source) || source.contains(text) {
                    relation = "overlappingSubstringAmbiguous"
                } else {
                    relation = "overlappingDistinctRead"
                }
                relations.append(["sourceOCRIndex": peer, "relation": relation, "shortOwnerCoverage": fraction,
                    "peerUTF16": text.utf16.count])
            }
            record["sourceRelations"] = relations
            // Even exact prefix+overlap is not proof of duplicate physical ink.
            // Never concatenate, suppress or retranslate any of these owners.
            let ambiguous = relations.contains { $0["relation"] as? String != "overlappingDistinctRead" }
            let row = rows[index]
            let confidence = row["confidence"] as? Double ?? 0
            let pixels = CGRect(x: box.minX * imageSize.width, y: box.minY * imageSize.height,
                width: box.width * imageSize.width, height: box.height * imageSize.height)
            let independentAxis = row["sourceOrientation"] as? String == "vertical" &&
                row["sourceSingleVerticalColumn"] as? Bool == true && pixels.height >= pixels.width * 1.8 &&
                BrowserOverlayTextFlow.usesVerticalSourceLayout(rect: pixels, text: source, sourceOrientation: .vertical)
            var value = original
            if recoverDirection, !ambiguous, confidence.isFinite, confidence >= 0.8, independentAxis,
               original["sourceVertical"] as? Bool == false {
                value["sourceVertical"] = true
                record["directionApplied"] = true
            }
            record["independentVerticalEvidence"] = independentAxis
            record["directionUnresolved"] = value["sourceVertical"] as? Bool != true && !independentAxis
            let prior = original["sourceFontSize"] as? Double
            if prior == nil || !(prior!.isFinite && prior! > 0) {
                record["fontStatus"] = "insufficient-own-single-glyph-evidence"
                let scalars = Array(source.unicodeScalars)
                let supportedGlyph = scalars.count == 1 && scalars.allSatisfy {
                    (0x3041...0x3096).contains($0.value) || (0x30A1...0x30FA).contains($0.value) ||
                        (0x3400...0x9FFF).contains($0.value)
                }
                if ambiguous {
                    record["fontStatus"] = "overlapping-lexical-ambiguity-retained"
                } else if supportedGlyph, confidence.isFinite, confidence >= 0.8 {
                    var character = UniChar(scalars[0].value), glyph = CGGlyph()
                    if CTFontGetGlyphsForCharacters(font, &character, &glyph, 1), glyph != 0 {
                        var native = CGRect.zero
                        CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, &native, 1)
                        if native.width > 0, native.height > 0 {
                            let forecast = Double(100 * min(pixels.width / native.width, pixels.height / native.height))
                            guard forecast.isFinite, forecast > 0 else { audit.append(record); return value }
                            record["fontStatus"] = "own-source-native-glyph-forecast"
                            record["forecastSourceFontPixels"] = forecast
                            record["fontAuthority"] = "own exact OCR glyph/rectangle fitted to HiraginoSans-W3; estimate, not source font truth"
                            if recoverFont {
                                value["sourceFontSize"] = forecast
                                record["fontApplied"] = true
                            }
                        }
                    }
                }
            } else { record["fontStatus"] = "existing-source-font-retained" }
            audit.append(record)
            return value
        }
        return (result, audit)
    }

    /// Draw a CGImage into the renderer's top-left logical coordinates.
    static func draw(_ image: CGImage, frame: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: frame.minX, y: frame.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: frame.size))
        context.restoreGState()
    }

    @available(iOS 16.0, macOS 13.0, *)
    static func render(layout: NativeTranslationLayout, source: CGImage, scale: CGFloat,
                       renderBounds: CGRect?, outputPixelSize: CGSize?, composeSource: Bool,
                       collectDiagnostics: Bool, includeLayoutData: Bool, capturePDF: Bool, pdfDeviceScale: CGFloat,
                       preparedDB:NativeMainEnsemblePreparedDB? = nil) throws -> NativeTranslationRenderer.Result {
        let bounds = renderBounds ?? CGRect(origin: .zero, size: layout.viewport)
        guard NativeTranslationRenderer.valid(bounds), scale.isFinite, scale > 0 else {
            throw NativeTranslationRenderer.RenderError.invalidGeometry
        }
        let pixels = outputPixelSize ?? CGSize(width: ceil(bounds.width * scale), height: ceil(bounds.height * scale))
        try NativeTranslationRenderer.validate(viewport: pixels, scale: 1)
        // Host probes and PDF captures retain the complete provenance envelope.
        #if canImport(UIKit)
        let metadata: Metadata = collectDiagnostics || capturePDF ? .diagnostics : (includeLayoutData ? .layout : .pixelsOnly)
        #else
        let metadata: Metadata = .diagnostics
        #endif
        let page = try page(layout: layout, source: source, preparedDB: preparedDB, metadata: metadata)
        try Task.checkCancellation()
        let composed = page.result.image
        let bitmap: CGImage
        if composed !== source, bounds == layout.sourceRect,
           pixels == CGSize(width: composed.width, height: composed.height),
           composed.bitsPerComponent == 8, composed.bitsPerPixel == 32,
           composed.alphaInfo == .premultipliedLast, composed.colorSpace?.name == CGColorSpace.sRGB {
            // The compositor already painted this full page into the destination format.
            bitmap = composed
        } else {
            guard let context = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw NativeTranslationRenderer.RenderError.bitmapTooLarge
            }
            context.translateBy(x: 0, y: pixels.height)
            context.scaleBy(x: pixels.width / bounds.width, y: -pixels.height / bounds.height)
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            draw(composed, frame: layout.sourceRect, context: context)
            guard let rendered = context.makeImage() else { throw NativeTranslationRenderer.RenderError.invalidGeometry }
            bitmap = rendered
        }
        let pdf: Data? = capturePDF ? try pdf(page: page, layout: layout, bounds: bounds,
            pixels: pixels, deviceScale: pdfDeviceScale) : nil
        let image = UIImage(cgImage: bitmap, scale: scale, orientation: .up)
        return .init(image: image, overlayImage: image,
            layoutData: page.layoutData, renderedItemCount: page.count, limitations: [], renderBounds: bounds,
            diagnosticData: metadata == .diagnostics ? page.diagnostics : nil, exportPDFData: pdf, sourceRestorationRects: [],
            paintBounds: [layout.sourceRect], sourcePatches: [], includesSourcePage: true)
    }

    @available(iOS 16.0, macOS 13.0, *)
    static func pdf(page: Page, layout: NativeTranslationLayout, bounds: CGRect,
                    pixels: CGSize, deviceScale: CGFloat) throws -> Data {
        try NativeTranslationPDFCapture.captureDocument(bounds: bounds, pixels: pixels,
            deviceScale: deviceScale, alignsToLogicalBounds: true) { context in
            draw(page.result.image, frame: layout.sourceRect, context: context)
        }.data
    }

    @available(iOS 16.0, macOS 13.0, *)
    static func renderPDF(layout: NativeTranslationLayout, source: CGImage, scale: CGFloat,
                          renderBounds: CGRect?, outputPixelSize: CGSize?, pdfDeviceScale: CGFloat,
                          preparedDB:NativeMainEnsemblePreparedDB? = nil) throws -> NativeTranslationRenderer.PDFResult {
        let started = ProcessInfo.processInfo.systemUptime
        let bounds = renderBounds ?? CGRect(origin: .zero, size: layout.viewport)
        guard NativeTranslationRenderer.valid(bounds), scale.isFinite, scale > 0 else {
            throw NativeTranslationRenderer.RenderError.invalidGeometry
        }
        let pixels = outputPixelSize ?? CGSize(width: ceil(bounds.width * scale), height: ceil(bounds.height * scale))
        try NativeTranslationRenderer.validate(viewport: pixels, scale: 1)
        let page = try page(layout: layout, source: source,preparedDB:preparedDB)
        try Task.checkCancellation()
        let data = try pdf(page: page, layout: layout, bounds: bounds, pixels: pixels, deviceScale: pdfDeviceScale)
        return .init(layoutData: page.layoutData, renderedItemCount: page.count, limitations: [],
            renderBounds: bounds, diagnosticData: page.diagnostics, exportPDFData: data,
            sourceRestorationRects: [], paintBounds: [layout.sourceRect], sourcePatches: [],
            stagesMilliseconds: ["native.mainEnsemble": (ProcessInfo.processInfo.systemUptime - started) * 1000],
            ensembleRestored: page.result.restored, ensembleRemovalMask: page.result.removalMask,
            includesSourcePage: true)
    }
}
