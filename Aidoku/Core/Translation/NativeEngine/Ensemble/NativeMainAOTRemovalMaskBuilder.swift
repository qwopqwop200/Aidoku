import CoreGraphics
import CryptoKit
import Foundation

/// Adapter to the actual frozen SourceBase/Role/Chromatic producer graph.
enum NativeMainAOTRemovalMaskBuilder {
    static let defaults: [String: Double] = ["sourceContrast": 32, "radiusScale": 1, "roleSupport": 1,
        "connectedFringe":1,"connectedFringeReach":3]
    enum Failure: Error {
        case sourceBudget, allocation, staleOrInvalidProbability, nativeSegmentationUnavailable
        case invalidSourceGeometry(item: Int)
        case workBudget(item: Int)
        case staleProducerIdentity
    }
    /// Actual full DB grid, NOT ROI upper bounds or sparse detector seed cells.
    /// Parent validates cached file provenance; same strong source object is required.
    struct SourceProbability {
        let original: CGImage
        let width: Int
        let height: Int
        let values: [Float]
        // nil remains explicitly legacy/unproven; never borrow current defaults.
        let capability: NativeMainEnsembleDBCapability.Record?
        init(original: CGImage, width: Int, height: Int, values: [Float],
             capability: NativeMainEnsembleDBCapability.Record? = nil) {
            self.original=original;self.width=width;self.height=height;self.values=values
            self.capability=capability
        }
    }
    struct MaskSummary {
        let foregroundCount: Int
        let sha256: String?
    }
    struct Result {
        let summary: MaskSummary
        let mask: CGImage
        /// Final 0/255 bytes, from the exact same immutable raster as mask.
        let canonicalMaskBytes: [UInt8]
        let audit: [String: Any]
        let ownership: NativeEnsembleRemovalDenseSupport.Ownership
    }
    private typealias Factory = NativeMainRemovalSourceFactory
    private typealias Caller = Factory.NativeCurrentMaskCaller

    static func build(original: CGImage, items: [[String: Any]], rfRegions: [Ensemble100RFRegion]) throws -> CGImage {
        try buildWithAudit(original: original, items: items, rfRegions: rfRegions).mask
    }
    static func build(original: CGImage, items: [[String: Any]], rfRegions: [Ensemble100RFRegion],
                      parameters: [String: Double], probability: SourceProbability? = nil) throws -> CGImage {
        try buildWithAudit(original: original, items: items, rfRegions: rfRegions,
            parameters: parameters, probability: probability).mask
    }
    static func buildWithAudit(original: CGImage, items: [[String: Any]], rfRegions: [Ensemble100RFRegion],
                               parameters: [String: Double] = [:], probability: SourceProbability? = nil,
                               unownedMasks: [NativeCausalUnownedInkLiveRecovery.AffiliatedMask] = [],
                               sourceDisplayItems: [[String: Any]]? = nil,
                               selectedSegmentation: NativeSelectedSourceSegmentationMasks? = nil, collectAudit: Bool = true) throws -> Result {
        // Original erasure owners remain immutable across source revisions.
        // Fresh sparse glyph evidence binds to the separately validated NEW
        // source/target owner, not to a stale hash on an old removal descriptor.
        let affiliatedOwners = sourceDisplayItems ?? items
        var recoveredColumns = [[String: Any]]()
        if sourceDisplayItems != nil {
            for candidate in unownedMasks {
                let r = candidate.sourceBounds
                let bounds = [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)]
                let matches = affiliatedOwners.filter { item in
                    guard item["originalSourceSHA256"] as? String == candidate.sourceSHA256,
                          item["keptLettering"] as? Bool != true, item["sourceTextOnly"] as? Bool != true,
                          let text = item["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          let b = item["sourceBounds"] as? [Double], b.count == 4 else { return false }
                    return zip(b, bounds).allSatisfy { abs($0 - $1) < 1e-7 }
                }
                guard matches.count == 1, let owner = matches.first,
                      let polygons = owner["auxiliaryInkPolygons"] as? [[[Double]]] else { continue }
                for polygon in polygons.prefix(256) {
                    guard polygon.count == 4, polygon.allSatisfy({ $0.count == 2 && $0.allSatisfy({ $0.isFinite && (0...1).contains($0) }) }) else { continue }
                    let b = NativeCausalUnownedInkLiveRecovery.polygonBounds(polygon.map { CGPoint(x: $0[0], y: $0[1]) })
                    guard b.width > 0, b.height > 0 else { continue }
                    // Actual freshly accepted ORIGINAL column quads only.
                    // Do not turn the merged paragraph envelope into an ROI fill.
                    var column = owner
                    column["sourceBounds"] = [Double(b.minX), Double(b.minY), Double(b.width), Double(b.height)]
                    column["sourcePolygon"] = polygon
                    column["originalSourceSHA256"] = NSNull()
                    recoveredColumns.append(column)
                }
            }
        }
        // Preserve every original primary source polygon carried by the Reader
        // transaction. These are factory ownership domains, never filled masks.
        let items = (items + recoveredColumns).flatMap { item -> [[String: Any]] in
            guard let hash = item["originalSourceSHA256"] as? String,
                  unownedMasks.contains(where: { $0.sourceSHA256 == hash }),
                  item["sourceTextOnly"] as? Bool != true,
                  let auxiliary = item["auxiliaryInkPolygons"] as? [[[Double]]] else { return [item] }
            var expanded = [item]
            for polygon in auxiliary.prefix(256) {
                guard (3...16).contains(polygon.count),
                      polygon.allSatisfy({ $0.count == 2 && $0.allSatisfy({ $0.isFinite && (0...1).contains($0) }) }) else { continue }
                let bounds = NativeCausalUnownedInkLiveRecovery.polygonBounds(
                    polygon.map { CGPoint(x: $0[0], y: $0[1]) })
                guard bounds.width > 0, bounds.height > 0 else { continue }
                let b = [Double(bounds.minX), Double(bounds.minY), Double(bounds.width), Double(bounds.height)]
                if let main = item["sourceBounds"] as? [Double], main.count == 4,
                   zip(main, b).allSatisfy({ abs($0 - $1) < 1e-7 }) { continue }
                var member = item
                member["sourceBounds"] = b; member["sourcePolygon"] = polygon
                member["originalSourceSHA256"] = NSNull() // not a second translated owner
                expanded.append(member)
            }
            return expanded
        }
        func p(_ key: String, _ range: ClosedRange<Double>) -> Double {
            let value = parameters[key] ?? defaults[key]!
            return value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : defaults[key]!
        }
        let contrast = p("sourceContrast", 16...64), radiusScale = p("radiusScale", 0.5...1.5)
        let roles = p("roleSupport", 0...1) > 0, w = original.width, h = original.height
        guard w > 0, h > 0, w <= 16_777_216 / h, items.count <= 256, rfRegions.count <= 4096,
              rfRegions.reduce(0, { $0 + $1.exterior.count + $1.holes.reduce(0, { $0 + $1.count }) }) <= 65_536
        else { throw Failure.sourceBudget }
        try Task.checkCancellation()
        let simpleProtection = NativeSourceBackedRFProtection.simpleHardConstraintsEnabled
        let fringeEnabled = !simpleProtection && p("connectedFringe", 0...1) == 1
        var rgbConsumers: NativeSelectedSourceSegmentationMasks.RGBConsumers = []
        if !simpleProtection { rgbConsumers.insert(.legacyFactory) }
        if NativeSourceBackedRFProtection.runtimeEnabled { rgbConsumers.insert(.sourceWitness) }
        if fringeEnabled { rgbConsumers.insert(.connectedFringe) }
        if !simpleProtection, NativeOwnedGlyphRFBoundaryProtection.runtimeEnabled, probability != nil {
            rgbConsumers.insert(.glyphBoundary)
        }
        var decoded: NativeRFDETRSourceImage?
        var source: Caller.Source?
        var sourceIdentity = try NativeSelectedSourceSegmentationMasks.resolveSourceIdentity(original: original,
            selectedMasks: selectedSegmentation, rgbConsumers: rgbConsumers) {
                let observed = try NativeRFDETRSourceImage.decode(original)
                let identity = observed.identity
                decoded = observed
                source = Caller.Source(width: w, height: h, rgb: Array(observed.rgb), revision: identity)
                return identity
            }
        var records: [[String: Any]] = [], work = 0
        let owners: [Caller.Owner] = try items.enumerated().map { index, item in
            guard var box = bounds(item, w, h) else { throw Failure.invalidSourceGeometry(item: index) }
            // Missing/null/invalid translation is not permission to erase the source.
            let translatedText = (item["text"] as? String) ?? ""
            let held = item["keptLettering"] as? Bool == true || item["sourceTextOnly"] as? Bool == true ||
                translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let raw = item["sourcePolygon"] ?? item["polygon"], pairs = raw as? [[Double]] ?? []
            let empty = raw == nil || raw is NSNull || (raw as? [Any])?.isEmpty == true
            var polygon: [CGPoint]
            if !empty && pairs.count >= 3 && pairs.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) {
                let observed = pairs.map { CGPoint(x: $0[0] * Double(w), y: $0[1] * Double(h)) }
                polygon = NativeIndependentPanelGutter.clip(observed,
                    to: CGRect(x: 0, y: 0, width: w - 1, height: h - 1))
            } else if empty || held {
                polygon = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                    CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
            } else { throw Failure.invalidSourceGeometry(item: index) }
            guard polygon.count >= 3, NativeIndependentPanelGutter.area(polygon) > 0,
                  Caller.convex(polygon) else { throw Failure.invalidSourceGeometry(item: index) }
            let font: Double, authority: String
            if let measured = item["sourceFontPixels"] as? Double, measured.isFinite, measured > 0 {
                font = measured; authority = "explicit-original-pixel-source-measurement"
            } else if let measured = item["sourceFontSize"] as? Double, measured.isFinite, measured > 0,
                      let frame = item["sourceFrame"] as? [Double], frame.count == 4, frame.allSatisfy(\.isFinite), frame[2] > 0 {
                font = measured * Double(w) / frame[2]; authority = "sourceFontSize*originalWidth/sourceFrameWidth"
            } else {
                font = max(1, min(box.width, box.height)); authority = "source-extent-fallback-not-measured-font"
            }
            guard font.isFinite, font > 0, font < Double(max(w, h)) * 4 else { throw Failure.invalidSourceGeometry(item: index) }
            var adjacentSupport: [String: Any]?
            // RF supplies only a search domain. Independent DB support and
            // exclusive OCR ownership are required before the original-pixel
            // glyph-mask factory can inspect an adjacent missed column.
            if !held, item["sourceVertical"] as? Bool == true,
               item["sourceSingleColumn"] as? Bool == true, box.width <= font * 1.6,
               let db = probability, db.original === original, db.width > 0, db.height > 0,
               db.values.count == db.width * db.height {
                let candidates = rfRegions.filter { region in
                    guard region.classID == 0, region.confidence >= 0.85 else { return false }
                    let r = CGRect(x: region.bounds.minX * Double(w), y: region.bounds.minY * Double(h),
                        width: region.bounds.width * Double(w), height: region.bounds.height * Double(h))
                    let overlap = r.intersection(box)
                    let union = r.union(box)
                    return !overlap.isNull && overlap.width * overlap.height >= box.width * box.height * 0.9 &&
                        r.width >= box.width * 1.2 && r.width <= box.width * 1.85 &&
                        r.height >= box.height * 0.85 && r.height <= box.height * 1.2 &&
                        union.width - box.width <= font * 1.3 && union.height - box.height <= font * 0.5 &&
                        !items.enumerated().contains { peer, raw in
                            peer != index && bounds(raw, w, h).map { $0.intersects(union) } == true
                        }
                }
                if candidates.count == 1, let region = candidates.first {
                    let r = CGRect(x: region.bounds.minX * Double(w), y: region.bounds.minY * Double(h),
                        width: region.bounds.width * Double(w), height: region.bounds.height * Double(h)).union(box)
                    let x0 = max(0, Int(floor(r.minX / Double(w) * Double(db.width))))
                    let x1 = min(db.width, Int(ceil(r.maxX / Double(w) * Double(db.width))))
                    let y0 = max(0, Int(floor(r.minY / Double(h) * Double(db.height))))
                    let y1 = min(db.height, Int(ceil(r.maxY / Double(h) * Double(db.height))))
                    var strong = 0, rows = Set<Int>()
                    for y in y0..<y1 { for x in x0..<x1 {
                        let point = CGPoint(x: (Double(x) + 0.5) * Double(w) / Double(db.width),
                            y: (Double(y) + 0.5) * Double(h) / Double(db.height))
                        if !box.contains(point), db.values[y * db.width + x] >= 0.65 { strong += 1; rows.insert(y) }
                    } }
                    if strong >= 12, rows.count >= max(4, Int(Double(y1 - y0) * 0.3)) {
                        box = r
                        polygon = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                            CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
                        adjacentSupport = ["rfQuery": region.queryID, "strongDBPixelsOutsideOCR": strong,
                            "supportedRows": rows.count, "authority": "RF search domain + independent DB; original-pixel glyph mask, not rectangle erasure"]
                    }
                }
            }
            let canvas = CGRect(x: 0, y: 0, width: w, height: h)
            let baseMargin = max(18, ceil(font * 0.18) + 3)
            let baseROI = box.insetBy(dx: -baseMargin, dy: -baseMargin).intersection(canvas).integral
            let baseCount = Int(baseROI.width) * Int(baseROI.height)
            let completionMargin = ceil(font * 0.55) + 3
            let roi = box.insetBy(dx: -completionMargin, dy: -completionMargin).intersection(canvas).integral
            let count = Int(roi.width) * Int(roi.height)
            // Completion may need more than four megapixels for a large source glyph.
            // Its ROI is already clipped to the bounded source page; retain the
            // cumulative work guard without a separate per-item completion cap.
            guard held || (baseCount > 0 && baseCount <= Factory.NativeSourceRoleMask.maximumROIPixels &&
                count > 0 &&
                work <= 24_000_000 - count) else { throw Failure.workBudget(item: index) }
            if !held { work += count }
            records.append(["index": index, "translated": !held, "fontPixels": font, "fontAuthority": authority,
                "geometry": empty ? "bbox-ownership-not-erasure" : "source-polygon",
                "baseROIPixels": baseCount, "completionROIPixels": count])
            if let adjacentSupport { records[records.count - 1]["adjacentMissedColumn"] = adjacentSupport }
            return Caller.Owner(id: String(index), polygon: polygon, fontPixels: font, translated: !held,
                balloon: item["balloonInterior"] != nil && !(item["balloonInterior"] is NSNull))
        }
        let protectionRegions = releasingSelfOwnedSFX(
            simpleProtection ? NativeSourceBackedRFProtection.finalRegions(rfRegions) : rfRegions, owners: owners, w: w, h: h)
        let sourceProtectionRequest = NativeSourceBackedRFProtection.request(original: original, regions: protectionRegions)
        let weakProtectionLabels = sourceProtectionRequest != nil
        let blocked = try protection(owners: owners, rf: protectionRegions, w: w, h: h, classifyWeak: weakProtectionLabels)
        var mask: [UInt8], factoryAudit: [String: Any]
        if simpleProtection {
            // The authoritative source NN mask is selected below. The legacy
            // base/role/chroma/DB factory would be overwritten, and its RGB
            //background is unused when all completion/exemptions are disabled.
            if let probability {
                guard probability.original === original, probability.width > 0, probability.height > 0,
                      probability.width <= w, probability.height <= h,
                      probability.values.count == probability.width * probability.height,
                      probability.values.allSatisfy({ $0.isFinite && (0...1).contains($0) })
                else { throw Failure.staleOrInvalidProbability }
            }
            mask = [UInt8](repeating: 0, count: w * h)
            factoryAudit = ["legacySourceFactoryExecuted": false,
                "status": "simple-selected-mask-authority-no-legacy-completion",
                "DBDependentStagesExecuted": false,
                "probabilityStatus": probability == nil ? "absent-unused" : "validated-source-binding-unused"]
        } else if let probability {
            guard let source else { throw Failure.sourceBudget }
            guard probability.original === original, probability.width > 0, probability.height > 0,
                  probability.width <= w, probability.height <= h,
                  probability.values.count == probability.width * probability.height,
                  probability.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw Failure.staleOrInvalidProbability }
            // This bounds only the caller's UInt8 ownership rasters. It is not a
            // peak-memory guarantee; parent records actual whole-page RSS.
            let streamingOwners = parameters["streamingOwners"] == 1
            let residentOwnerCount = streamingOwners ? min(1, owners.count) : owners.count
            guard residentOwnerCount <= 192_000_000 / (w * h) else { throw Failure.workBudget(item: -1) }
            let revision = probability.values.withUnsafeBytes { SHA256.hash(data: Data($0)).map { String(format: "%02x", $0) }.joined() }
            let evidence = Caller.Evidence(sourceRevision: source.revision, revision: source.revision,
                boundary: [UInt8](repeating: 0, count: w * h), owners: owners, pending: [])
            let boundProbability = Caller.Probability(width: probability.width, height: probability.height,
                values: probability.values, sourceRevision: source.revision, revision: revision)
            let result: Caller.Result
            if streamingOwners {
                result = try Caller.prepareStreamingOwners(source: source, probability: boundProbability,
                    evidence: evidence, contrast: contrast, radiusScale: radiusScale, roleSupport: roles,
                    protectForeignTargets: parameters["neutralForeignOwnerProtection"] == 1,
                    foreignTargetHaloScale: parameters["neutralForeignHaloScale"] ?? 0,
                    foreignHaloExcludesSelf: parameters["neutralForeignHaloExcludesSelf"] == 1)
            } else {
                result = try Caller.prepare(source: source, probability: boundProbability, evidence: evidence,
                    contrast: contrast, radiusScale: radiusScale, roleSupport: roles,
                    protectForeignTargets: parameters["neutralForeignOwnerProtection"] == 1,
                    foreignTargetHaloScale: parameters["neutralForeignHaloScale"] ?? 0,
                    foreignHaloExcludesSelf: parameters["neutralForeignHaloExcludesSelf"] == 1)
            }
            mask = result.mask; factoryAudit = result.audit
            factoryAudit["probabilityStatus"] = "actual-source-bound-full-DB-grid"
        } else {
            guard let source else { throw Failure.sourceBudget }
            // Execute only stages genuinely independent of DB. Unknown cells are
            // not zero probabilities and upper bounds are not positive ink seeds.
            let base = try Factory.NativeSourceBaseMask.extract(source: source, owners: owners,
                contrast: contrast, radiusScale: radiusScale, roleSupport: roles)
            let chroma = try Factory.NativeChromaticMaskCompletion.complete(rgb: source.rgb, width: w, height: h,
                base: base.mask, protection: blocked, owners: owners.filter(\.translated).map {
                    .init(id: $0.id, polygon: $0.polygon, fontPixels: $0.fontPixels)
                })
            mask = chroma.mask
            factoryAudit = ["base": base.audit, "chroma": chroma.audit,
                "probabilityStatus": "missing-explicitly-source-only-stages", "DBDependentStagesExecuted": false]
        }
        factoryAudit["acceptedFinalSegmentation"] = [
            "policySHA256": NativeSourceSegmentationExecution.erasurePolicySHA256,
            "executed": false,
            "status": "unavailable-current-source-mask-producer",
            "scope": "existing-source-base-role-chroma-mask-preserved"]
        try Task.checkCancellation()
        // Only exact source-hash/geometry owners with real targets may consume
        // provisional original-pixel glyph evidence. Final protection below wins.
        let unownedAdded: Int
        if simpleProtection { unownedAdded = 0 }
        else {
            unownedAdded = try NativeCausalUnownedInkLiveRecovery.applyAffiliatedMasks(
                unownedMasks, original: original, items: affiliatedOwners, mask: &mask)
        }
        factoryAudit["causalUnownedContext"] = ["candidateCount": unownedMasks.count,
            "addedBeforeFinalProtection": unownedAdded,
            "recoveredOriginalColumns": recoveredColumns.count, "bboxFill": false]
        let translatedOwners = owners.filter(\.translated)
        // Select the authoritative seed before proposing any fringe. Never
        // union the provisional factory mask back into selected segmentation.
        var authoritativeSelectedMasks: NativeSelectedSourceSegmentationMasks?
        let fringe = try selectAndCompleteFringe(mask: &mask, recordSeedDigest: collectAudit && fringeEnabled, supplied: {
            guard let selectedSegmentation else { return nil }
            let selected = try selectedSegmentation.resolve(original: original,
                translatedPolygons: translatedOwners.map(\.polygon),
                admitOwnerMajorityComponents: NativeSourceBackedRFProtection.ownerMajorityComponentsEnabled)
            factoryAudit["acceptedFinalSegmentation"] = selected.audit
            if selected.mask != nil { authoritativeSelectedMasks = selectedSegmentation }
            return selected.mask
        }, generated: {
            guard !translatedOwners.isEmpty else { return nil }
            if #available(iOS 18.0, macOS 15.0, *) {
                rgbConsumers.insert(.generatedErasure)
                let generatedSource: NativeRFDETRSourceImage
                if let decoded { generatedSource = decoded }
                else {
                    // An incomplete supplied roster still needs REAL RGB for
                    // fresh erasure inference. Never supply empty/fake arrays.
                    let observed = try NativeRFDETRSourceImage.decode(original)
                    let identity = observed.identity
                    guard identity == sourceIdentity.identity else { throw Failure.staleProducerIdentity }
                    decoded = observed; generatedSource = observed
                    sourceIdentity = .init(identity: identity, authority: "independently-decoded-and-rehashed-canonical-rgb",
                        producerIdentityReused: false)
                }
                let generated = try NativeSelectedSourceSegmentationPageProducer.shared.build(original: original,
                    decodedSource: generatedSource, owners: translatedOwners.map { .init(polygon: $0.polygon, fontPixels: $0.fontPixels) },
                    sourceWitnessRequest: sourceProtectionRequest)
                let selected = try generated.masks.resolve(original: original,
                    translatedPolygons: translatedOwners.map(\.polygon),
                    admitOwnerMajorityComponents: NativeSourceBackedRFProtection.ownerMajorityComponentsEnabled)
                guard let selectedMask = selected.mask else {
                    throw NativeSelectedSourceSegmentationPageProducer.Failure.incompleteNativeMasks
                }
                factoryAudit["acceptedFinalSegmentation"] = selected.audit
                factoryAudit["nativeSourceSegmentationProducer"] = generated.audit
                authoritativeSelectedMasks = generated.masks
                return selectedMask
            } else { throw Failure.nativeSegmentationUnavailable }
        }, propose: { seed in
            guard fringeEnabled else { return .init(additions: [], audit: []) }
            guard let source else { throw Failure.sourceBudget }
            let observations = factoryAudit["base"] as? [[String: Any]] ?? []
            let candidates = owners.enumerated().compactMap { index, owner -> NativeOriginalMaskFringeCompletion.Owner? in
                guard owner.translated, records[index]["fontAuthority"] as? String != "source-extent-fallback-not-measured-font",
                      let bg = observations.first(where: { $0["owner"] as? String == owner.id })?["backgroundRGB"] as? [Double]
                else { return nil }
                return .init(id: owner.id, polygon: owner.polygon, font: owner.fontPixels, background: bg)
            }
            let completion = try NativeOriginalMaskFringeCompletion.apply(rgb: source.rgb, width: w, height: h,
                base: seed, protection: blocked, owners: candidates, regions: rfRegions,
                reach: Int(p("connectedFringeReach", 1...3)),
                includeChromatic: NativeOriginalMaskFringeCompletion.chromaticRuntimeEnabled, verifyOpacity: { roi in
                    NativeOriginalMaskFringeCompletion.isOpaque(original: original, roi: roi)
                })
            factoryAudit["connectedFringe"] = ["owners": completion.audit,
                "inputOwners": owners.count, "candidateOwners": candidates.count,
                "preservedOwners": owners.filter { !$0.translated }.count,
                "immutableBase": true, "restoredPixelsRead": false]
            return completion
        })
        var glyphExemptions = Set<Int>()
        var glyphHardProtection: [UInt8]?
        factoryAudit["ownedGlyphRFBoundaryProtection"] = ["enabled": !simpleProtection && NativeOwnedGlyphRFBoundaryProtection.runtimeEnabled,
            "status": simpleProtection ? "disabled-by-simple-hard-policy" : "disabled-or-missing-probability",
            "exemptedBalloonBoundaryPixels": 0]
        if !simpleProtection, NativeOwnedGlyphRFBoundaryProtection.runtimeEnabled, probability != nil {
            guard let source else { throw Failure.sourceBudget }
            let hard = try protection(owners: owners, rf: rfRegions.filter { $0.classID != 2 }, w: w, h: h)
            let balloon = try protection(owners: [], rf: rfRegions.filter { $0.classID == 2 }, w: w, h: h)
            let arbitration = try NativeOwnedGlyphRFBoundaryAdapter.evaluate(source: source, owners: owners,
                factoryMask: mask, factoryAudit: factoryAudit, records: records, rfRegions: rfRegions,
                original: original, probability: probability, hardProtection: hard, balloonBoundary: balloon)
            glyphExemptions = arbitration.pageExemptions
            glyphHardProtection = hard
            factoryAudit["ownedGlyphRFBoundaryProtection"] = arbitration.audit
        }
        let sourceProtection: NativeSourceBackedRFProtection.Result
        if weakProtectionLabels {
            guard let source else { throw Failure.sourceBudget }
            let observations = factoryAudit["base"] as? [[String: Any]] ?? []
            let witnesses = owners.compactMap { owner -> NativeSourceBackedRFProtection.Owner? in
                guard owner.translated,
                      let background = observations.first(where: { $0["owner"] as? String == owner.id })?["backgroundRGB"] as? [Double]
                else { return nil }
                return .init(polygon: owner.polygon, background: background)
            }
            sourceProtection = NativeSourceBackedRFProtection.evaluate(original: original, sourceIdentity: source.revision,
                rgb: source.rgb, selected: mask, labels: blocked, masks: authoritativeSelectedMasks,
                owners: witnesses, regions: rfRegions, sourceContrast: contrast)
        } else {
            sourceProtection = .init(exemptions: .init(), audit: ["enabled": NativeSourceBackedRFProtection.runtimeEnabled,
                "status": "disabled-or-no-weak-protection", "exemptedPixels": 0])
        }
        factoryAudit["sourceBackedRFProtection"] = sourceProtection.audit
        factoryAudit["sourceIdentityBinding"] = ["authority": sourceIdentity.authority,
            "producerIdentityReused": sourceIdentity.producerIdentityReused,
            "independentlyRehashed": !sourceIdentity.producerIdentityReused,
            "RGBDecodeExecuted": decoded != nil, "RGBConsumerFlags": Int(rgbConsumers.rawValue),
            "compositionRGBAChecksBypassed": false]
        factoryAudit["finalRFProtectionPolicy"] = ["mode": NativeSourceBackedRFProtection.estimatedFrameBoundaryDisabled
            ? "preserved-balloon-sfx-owner-majority-no-model-frame" : NativeSourceBackedRFProtection.ownerMajorityComponentsEnabled
            ? "preserved-owner-contours-owner-majority-components" : simpleProtection ? "preserved-owner-contours-no-sfx-box" : "incumbent",
            "RFSFXBoxVeto": !simpleProtection, "explicitPreservedOwnersHard": true, "contouredSFXHard": true,
            "frameAndBalloonContoursRetained": !NativeSourceBackedRFProtection.estimatedFrameBoundaryDisabled,
            "frameContoursRetained": !NativeSourceBackedRFProtection.estimatedFrameBoundaryDisabled,
            "balloonContoursRetained": true, "sourceWitnessRequired": weakProtectionLabels,
            "ownerMajorityComponents": NativeSourceBackedRFProtection.ownerMajorityComponentsEnabled,
            "lateFringeCompletion": fringeEnabled,
            "upstreamOwnerSelectionAuthority": true]
        var counts = protectAndCount(mask: &mask, blocked: blocked,
            hard: weakProtectionLabels ? nil : glyphHardProtection, exemptions: glyphExemptions,
            weakLabels: weakProtectionLabels, sourceExemptions: sourceProtection.exemptions)
        if counts.foreground == 0, counts.excluded > 0, let authoritativeSelectedMasks {
            let recovered = try recoverSelectedInkOutsideSFX(original: original, sourceIdentity: sourceIdentity.identity,
                entries: authoritativeSelectedMasks.entries, regions: protectionRegions, mask: &mask) { remaining in
                try protection(owners: owners, rf: remaining, w: w, h: h)
            }
            counts.foreground += recovered
            counts.excluded -= recovered
            factoryAudit["selectedPixelsOutsideObservedSFX"] = recovered
        }
        // Equal binary occupancy before and after protection has the same canonical SHA.
        let unchangedSeed = fringe.additions.isEmpty && counts.excluded == 0 ? fringe.seedSHA256 : nil
        let finalMaskDigest = collectAudit ? (unchangedSeed ?? canonicalMaskSHA256(mask)) : nil
        factoryAudit["finalRemovalMaskSHA256"] = finalMaskDigest
        if fringeEnabled, let finalMaskDigest {
            var audit = factoryAudit["connectedFringe"] as? [String: Any] ?? [:]
            let retained = fringe.additions.filter { mask[$0] != 0 }.count
            audit.merge(fringe.audit) { _, current in current }
            audit["added"] = fringe.additions.count // Proposed additions before final protection.
            audit["retainedAdditions"] = retained
            audit["vetoedAdditions"] = fringe.additions.count - retained
            audit["finalMaskSHA256"] = finalMaskDigest
            factoryAudit["connectedFringe"] = audit
        }
        guard let provider = CGDataProvider(data: Data(mask) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw Failure.allocation }
        let denseOwners = owners.enumerated().map { index, owner in
            NativeEnsembleRemovalDenseSupport.Owner(
                polygon: owner.polygon.map { CGPoint(x: $0.x / CGFloat(w), y: $0.y / CGFloat(h)) },
                fontPixels: records[index]["fontAuthority"] as? String == "source-extent-fallback-not-measured-font"
                    ? nil : owner.fontPixels, preserved: !owner.translated)
        }
        return Result(summary: MaskSummary(foregroundCount: counts.foreground, sha256: finalMaskDigest),
            mask: image, canonicalMaskBytes: mask,
            audit: collectAudit ? ["factory": simpleProtection ? "selected-source-mask-with-hard-boundaries" :
                "full-manifest-source-base-role-chroma-native-port",
            "parameters": ["sourceContrast": contrast, "radiusScale": radiusScale, "roleSupport": roles ? 1 : 0,
                "connectedFringe":p("connectedFringe",0...1),"connectedFringeReach":p("connectedFringeReach",1...3)],
            "owners": records, "factoryEvidence": factoryAudit, "protectedProposedPixels": counts.excluded,
            "maskPixels": counts.foreground, "sourcePixels": w * h, "roiBudgetPixels": work,
            "sourceIdentity": sourceIdentity.identity, "requiresFreshAOTIfMaskChanges": true, "restoredPixelsRead": false] : [:],
            ownership: .init(original: original, owners: denseOwners))
    }

    struct FringeReceipt {
        let seedSHA256: String?
        let additions: Set<Int>
        let audit: [String: Any]
    }

    /// Model-free ordering seam shared by supplied, generated and legacy seeds.
    /// The proposer runs exactly once against an immutable authoritative seed.
    static func selectAndCompleteFringe(mask: inout [UInt8], recordSeedDigest: Bool = true,
                                       supplied: () throws -> [UInt8]?,
                                       generated: () throws -> [UInt8]?,
                                       propose: ([UInt8]) throws -> NativeOriginalMaskFringeCompletion.Result) throws -> FringeReceipt {
        let origin: String
        if let selected = try supplied() {
            mask = selected; origin = "supplied-selected"
        } else if let selected = try generated() {
            mask = selected; origin = "generated-selected"
        } else {
            origin = "legacy-no-selected"
        }
        let seedSHA256 = recordSeedDigest ? binaryMaskSHA256(mask) : nil
        let completion = try propose(mask)
        let additions = Set(completion.additions.filter { mask[$0] == 0 })
        for index in additions { mask[index] = 1 }
        var audit: [String: Any] = ["seedOrigin": origin, "proposalAdditions": additions.count,
            "completionStage": "after-selected-segmentation-before-final-protection"]
        audit["seedMaskSHA256"] = seedSHA256
        return FringeReceipt(seedSHA256: seedSHA256, additions: additions, audit: audit)
    }

    /// A box-only SFX veto can cover a whole translated line even when its own RF mask excludes
    /// that line. Recheck only an otherwise empty result against the very same query and source.
    /// The caller has already resolved every selected entry against its translated owner polygon.
    static func recoverSelectedInkOutsideSFX(original: CGImage, sourceIdentity: String,
        entries: [NativeSelectedSourceSegmentationMasks.Entry], regions: [Ensemble100RFRegion],
        mask: inout [UInt8], hardProtection: ([Ensemble100RFRegion]) throws -> [UInt8]) throws -> Int {
        let width = original.width, height = original.height
        let page = CGRect(x: 0, y: 0, width: width, height: height)
        var observed: [(bounds: CGRect, pixels: Ensemble100RFSourcePixelMask)] = []
        var remaining: [Ensemble100RFRegion] = []
        for region in regions {
            guard region.classID == 1, NativeSourceBackedRFProtection.isWeak(region),
                  let pixels = region.sourcePixelMask, pixels.queryID == region.queryID,
                  pixels.sourceIdentity == sourceIdentity, pixels.sourceWidth == width, pixels.sourceHeight == height,
                  !region.bounds.isEmpty, CGRect(x: 0, y: 0, width: 1, height: 1).contains(region.bounds) else {
                remaining.append(region)
                continue
            }
            let b = region.bounds
            let bounds = CGRect(x: b.minX * page.width, y: b.minY * page.height,
                                width: b.width * page.width, height: b.height * page.height)
            observed.append((bounds.integral, pixels))
        }
        guard !observed.isEmpty, !entries.isEmpty else { return 0 }
        let hard = try hardProtection(remaining)
        var candidate = mask, recovered = 0
        for entry in entries {
            try Task.checkCancellation()
            let overlapping = observed.filter { $0.bounds.intersects(entry.crop) }
            let cropWidth = Int(entry.crop.width)
            let polygon = entry.ownerPolygon.map { CGPoint(x: $0.x - entry.crop.minX, y: $0.y - entry.crop.minY) }
            guard !overlapping.isEmpty, let owned = NativeSourceBackedRFProtection.admitOwnerMajorityComponents(
                mask: entry.mask, width: cropWidth, height: Int(entry.crop.height), localPolygon: polygon)
            else { return 0 }
            var represented = false
            for local in owned.mask.indices where owned.mask[local] != 0 {
                let x = Int(entry.crop.minX) + local % cropWidth, y = Int(entry.crop.minY) + local / cropWidth
                let i = y * width + x
                guard hard[i] == 0 else { continue }
                let center = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                var observedNegative = false
                for region in overlapping where region.bounds.contains(center) {
                    guard region.pixels.contains(sourceX: x, sourceY: y, sourceIdentity: sourceIdentity) == false
                    else { observedNegative = false; break }
                    observedNegative = true
                }
                if observedNegative {
                    represented = true
                    if candidate[i] == 0 { candidate[i] = 255; recovered += 1 }
                }
            }
            // Keep the original readiness failure if any translated owner still lacks a safe seed.
            guard represented else { return 0 }
        }
        mask = candidate
        return recovered
    }

    /// Preserve existing RF exemptions, but hard/foreign-owner protection always wins.
    static func applyFinalProtection(mask: inout [UInt8], blocked: [UInt8], hard: [UInt8]?,
                                     exemptions: Set<Int>, weakLabels: Bool = false,
                                     sourceExemptions: NativeSourceBackedRFProtection.Exemptions = .init()) -> Int {
        protectAndCount(mask: &mask, blocked: blocked, hard: hard, exemptions: exemptions,
            weakLabels: weakLabels, sourceExemptions: sourceExemptions).excluded
    }

    private static func protectAndCount(mask: inout [UInt8], blocked: [UInt8], hard: [UInt8]?,
                                        exemptions: Set<Int>, weakLabels: Bool,
                                        sourceExemptions: NativeSourceBackedRFProtection.Exemptions)
                                        -> (excluded: Int, foreground: Int) {
        var excluded = 0, foreground = 0
        for i in mask.indices where mask[i] != 0 {
            if (hard?[i] ?? 0) != 0 || (weakLabels && blocked[i] == 255) ||
                (blocked[i] != 0 && !exemptions.contains(i) && !sourceExemptions.contains(i)) {
                excluded += 1
                mask[i] = 0
            } else {
                foreground += 1
                mask[i] = 255
            }
        }
        return (excluded, foreground)
    }

    static func canonicalMaskSHA256(_ mask: [UInt8]) -> String {
        var hash = SHA256()
        mask.withUnsafeBytes { hash.update(bufferPointer: $0) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func binaryMaskSHA256(_ mask: [UInt8]) -> String {
        var hash = SHA256()
        var scratch = [UInt8](repeating: 0, count: min(64 * 1024, mask.count))
        scratch.withUnsafeMutableBytes { output in
            var start = 0
            while start < mask.count {
                let length = min(output.count, mask.count - start)
                for offset in 0..<length { output[offset] = mask[start + offset] == 0 ? 0 : 255 }
                hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: output[..<length]))
                start += length
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// An RF SFX query whose box IS the single translated owner's own line is
    /// that owner's ink, not a foreign keepout: the retained translation already
    /// overrode the SFX role. Vetoing it would erase nothing and fail readiness
    /// (translatedOwnersWithoutRemovalMask). A query touching any preserved owner,
    /// or matching zero/several translated owners, keeps its hard protection.
    private static func releasingSelfOwnedSFX(_ regions: [Ensemble100RFRegion], owners: [Caller.Owner],
                                      w: Int, h: Int) -> [Ensemble100RFRegion] {
        let boxes = owners.map { owner -> (box: CGRect, translated: Bool) in
            let xs = owner.polygon.map(\.x), ys = owner.polygon.map(\.y)
            guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return (.null, owner.translated) }
            return (CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0), owner.translated)
        }
        return regions.filter { region in
            guard region.classID == 1 else { return true }
            let b = CGRect(x: region.bounds.minX * CGFloat(w), y: region.bounds.minY * CGFloat(h),
                           width: region.bounds.width * CGFloat(w), height: region.bounds.height * CGFloat(h))
            guard [b.minX, b.minY, b.width, b.height].allSatisfy(\.isFinite), b.width > 0, b.height > 0 else { return true }
            func iou(_ o: CGRect) -> CGFloat {
                let i = b.intersection(o)
                guard !i.isNull, o.width > 0, o.height > 0 else { return 0 }
                let inter = i.width * i.height
                return inter / (b.width * b.height + o.width * o.height - inter)
            }
            guard !boxes.contains(where: { !$0.translated && !$0.box.isNull && b.intersects($0.box) }) else { return true }
            return boxes.filter { $0.translated && iou($0.box) >= 0.7 }.count != 1
        }
    }

    private static func bounds(_ item: [String: Any], _ w: Int, _ h: Int) -> CGRect? {
        let r: CGRect
        if let a = item["sourceBounds"] as? [Double], a.count == 4 { r = CGRect(x: a[0], y: a[1], width: a[2], height: a[3]) }
        else if let a = item["rect"] as? [String: Any], let x = a["x"] as? Double, let y = a["y"] as? Double,
                let width = a["width"] as? Double, let height = a["height"] as? Double {
            r = CGRect(x: x, y: y, width: width, height: height)
        } else { return nil }
        guard [r.origin.x, r.origin.y, r.size.width, r.size.height, r.maxX, r.maxY].allSatisfy(\.isFinite),
              r.size.width > 0, r.size.height > 0 else { return nil }
        // Rotated OCR polygons can straddle the page edge. Use the visible
        // bounds for the work ROI; the separately clipped polygon owns the ink.
        let visible: CGRect
        if r.minX >= 0, r.minY >= 0, r.maxX <= 1.000001, r.maxY <= 1.000001 {
            visible = r
        } else {
            visible = r.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !visible.isEmpty else { return nil }
        }
        return CGRect(x: visible.minX * CGFloat(w), y: visible.minY * CGFloat(h),
                      width: visible.width * CGFloat(w), height: visible.height * CGFloat(h))
    }

    /// Explicit preserved owners/SFX and actual RF edges veto final support.
    /// RF body masks are never erasure. Missing RF leaves source/OCR fallback.
    private static func protection(owners: [Caller.Owner], rf: [Ensemble100RFRegion], w: Int, h: Int,
                                   classifyWeak: Bool = false) throws -> [UInt8] {
        var mask = [UInt8](repeating: 0, count: w * h)
        try mask.withUnsafeMutableBytes { bytes in
            guard let c = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { throw Failure.allocation }
            c.setShouldAntialias(false); c.setFillColor(gray: 1, alpha: 1)
            c.setStrokeColor(gray: 1, alpha: 1); c.setLineWidth(4); c.setLineJoin(.round)
            // Paths use top-left source coordinates; unlike CGImage drawing,
            // path rasterization needs the explicit Y transform on this bitmap.
            c.translateBy(x: 0, y: CGFloat(h)); c.scaleBy(x: 1, y: -1)
            func path(_ ring: [CGPoint]) { c.addLines(between: ring); c.closePath() }
            // Private label bitmap only: weak1 first, hard255 last. Its >0
            //union must equal the historical protection raster exactly. Never
            //expose this label encoding as a public mask image or change AA.
            for weakPass in classifyWeak ? [true, false] : [false] {
                let gray: CGFloat = classifyWeak && weakPass ? 1 / 255 : 1
                c.setFillColor(gray: gray, alpha: 1); c.setStrokeColor(gray: gray, alpha: 1)
                if !weakPass {
                    for owner in owners where !owner.translated { c.beginPath(); path(owner.polygon); c.fillPath() }
                }
                for r in rf where r.confidence.isFinite && r.confidence >= 0.6 && (1...3).contains(r.classID) &&
                    (!classifyWeak || NativeSourceBackedRFProtection.isWeak(r) == weakPass) {
                let rings = ([r.exterior] + r.holes).filter { $0.count >= 3 && $0.allSatisfy {
                    $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y)
                } }
                c.beginPath()
                if r.classID == 1 && rings.isEmpty {
                    let b = r.bounds
                    if [b.minX, b.minY, b.width, b.height].allSatisfy(\.isFinite), b.width > 0, b.height > 0 {
                        c.fill(CGRect(x: b.minX * CGFloat(w), y: b.minY * CGFloat(h), width: b.width * CGFloat(w), height: b.height * CGFloat(h)))
                    }
                } else if !rings.isEmpty {
                    for ring in rings { path(ring.map { CGPoint(x: $0.x * CGFloat(w), y: $0.y * CGFloat(h)) }) }
                    if r.classID == 1 { c.drawPath(using: .eoFill) } else { c.strokePath() }
                }
            }
            }
        }
        return mask
    }
}
