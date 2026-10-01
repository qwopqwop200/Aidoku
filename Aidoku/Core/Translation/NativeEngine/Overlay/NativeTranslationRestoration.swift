import CoreGraphics
import Foundation

/// Source-pixel replacement is independent of text rasterization. Every returned patch is
/// transparent outside verified source ink, so neither page art nor neighboring lettering is flattened.
enum NativeTranslationRestoration {
    struct Patch {
        struct RasterGeometry {
            let frame: CGRect
            let imageSize: CGSize
            let origin: CGPoint
            let scale: CGSize
        }
        private let initialImage: CGImage
        var image: CGImage { candidate?.image() ?? initialImage }
        /// Top-left viewport coordinates, in the same space as the typed layout.
        let rect: CGRect
        let itemID: String?
        /// One byte per patch image pixel, row-major from the top. Zero is surviving ink/art.
        private let initialSafe: [UInt8]?
        var layoutSafe: [UInt8]? { candidate?.safe ?? initialSafe }
        private let initialLuminance: [UInt8]?
        var surfaceLuminance: [UInt8]? { candidate?.luminance ?? initialLuminance }
        let candidate: NativeRestorationCandidate?
        let surfaceQuality: [String: Any]?
        let finalForcedErasure: Bool
        let slantedProof: NativeSlantedRestoration.ProofRaster?
        let slantedScale: CGFloat?
        let rasterGeometry: RasterGeometry?
        let cleanupClip: CGRect?
        let independentArtworkCover: Bool

        init(image: CGImage, rect: CGRect, itemID: String? = nil, layoutSafe: [UInt8]? = nil,
             surfaceLuminance: [UInt8]? = nil, surfaceQuality: [String: Any]? = nil, finalForcedErasure: Bool = false,
             slantedProof: NativeSlantedRestoration.ProofRaster? = nil, slantedScale: CGFloat? = nil, candidate: NativeRestorationCandidate? = nil,
             rasterGeometry: RasterGeometry? = nil, cleanupClip: CGRect? = nil, independentArtworkCover: Bool = false) {
            initialImage = image
            self.candidate = candidate
            self.rect = rect
            self.itemID = itemID
            initialSafe = layoutSafe
            initialLuminance = surfaceLuminance
            self.surfaceQuality = surfaceQuality
            self.finalForcedErasure = finalForcedErasure
            self.slantedProof = slantedProof; self.slantedScale = slantedScale
            self.rasterGeometry = rasterGeometry
            self.cleanupClip = cleanupClip
            self.independentArtworkCover = independentArtworkCover
        }
    }

    struct Appearance {
        let foreground: CGColor?
        let background: CGColor?
        let restored: Bool
        let erasureComplete: Bool
        let restorationMethod: String?
        let sourceGlyphsVerified: Bool
        let finalForcedErasure: Bool
        let provisional: Bool
        let letteringStyle: String?
        let fontName: String?
        let sourceStrokeWeight: Double
        let sourceSample: [String: Any]?
        let stroke: CGColor?
        let strokeWidth: CGFloat

        init(foreground: CGColor?, background: CGColor?, restored: Bool, stroke: CGColor? = nil, strokeWidth: CGFloat = 0,
             erasureComplete: Bool = false, letteringStyle: String? = nil, fontName: String? = nil, sourceStrokeWeight: Double = 0,
             sourceSample: [String: Any]? = nil, restorationMethod: String? = nil, sourceGlyphsVerified: Bool = false, finalForcedErasure: Bool = false, provisional: Bool = false) {
            self.foreground = foreground
            self.background = background
            self.restored = restored
            self.erasureComplete = erasureComplete
            self.restorationMethod = restorationMethod
            self.sourceGlyphsVerified = sourceGlyphsVerified
            self.finalForcedErasure = finalForcedErasure
            self.provisional = provisional
            self.letteringStyle = letteringStyle
            self.fontName = fontName
            self.sourceStrokeWeight = sourceStrokeWeight
            self.sourceSample = sourceSample
            self.stroke = stroke
            self.strokeWidth = strokeWidth
        }
    }

    struct Result {
        var patches: [Patch] = []
        var appearances: [String: Appearance] = [:]
        var limitations: [String] = []
        var sourceLetterWeights: [Double] = []
        var unitResidueRiskIDs: Set<String> = []
        var paperProposalRemaining = 2_097_152
        var deferredForced: NativeDeferredForcedRestoration?
        var cleanupGeometry: NativeSourceSurfaceGeometry.Geometry?
        var collectDiagnostics = false
        var restorationAttempts: [[String: Any]] = []

        mutating func recordAttempt(_ item: NativeTranslationLayoutItem, phase: String, details: [String: Any]) {
            guard collectDiagnostics else { return }
            var record = details
            record["id"] = item.id
            record["phase"] = phase
            restorationAttempts.append(record)
        }
    }

    typealias SlantedAdmission = (NativeTranslationLayoutItem, Appearance, NativeSlantedRestoration.ProofRaster, CGFloat) -> Bool

    typealias SlantedPageAdmission = (NativeTranslationLayoutItem, Appearance, NativeSpatialSourceCrop.Prepared, NativeRestorationPixels) -> Bool

    static func prepare(image: CGImage?, layout: NativeTranslationLayout, settings: IPhoneOverlaySettings,
                        acceptSlanted: SlantedAdmission? = nil, acceptPageSlanted: SlantedPageAdmission? = nil,
                        cleanupGeometry: NativeSourceSurfaceGeometry.Geometry? = nil,
                        collectDiagnostics: Bool = false) throws -> Result {
        var result = Result()
        result.collectDiagnostics = collectDiagnostics
        result.cleanupGeometry = cleanupGeometry
        let cleanupFrame = cleanupGeometry?.frame ?? layout.sourceRect
        guard settings.preserveSourceTextColor || settings.preserveSourceBackgroundColor || settings.usesSourceInpainting else { return result }
        guard let image else {
            result.limitations.append("source-image-unavailable")
            return result
        }
        if settings.usesSourceInpainting && settings.renderedBackgroundOpacity == 1 {
            result.deferredForced = NativeDeferredForcedRestoration(image: image, layout: layout, cleanupGeometry: cleanupGeometry)
        }
        let pixelReader = NativeSourcePixelReader(image: image)
        defer { pixelReader.release() }
        let colorBudget = NativeSourceColorSamplingStage.Budget()
        colorBudget.remainingSamples = layout.items.filter { !$0.keptLettering && $0.sourceColorEligible }.count
        let sampleEnabled = settings.preserveSourceTextColor || settings.preserveSourceBackgroundColor
        let sourceColors = NativeSourceColorSamplingStage(image: image, enabled: sampleEnabled,
            phase: "ocr", budget: colorBudget, pixelReader: pixelReader)
        let translatedColors = NativeSourceColorSamplingStage(image: image, enabled: sampleEnabled,
            phase: "translation", budget: colorBudget, pixelReader: pixelReader)
        func polygon(_ item: NativeTranslationLayoutItem) -> [[Double]] {
            if item.sourcePolygon.count >= 3 { return item.sourcePolygon.map { $0.map(Double.init) } }
            guard let bounds = normalizedRect(item.sourceBounds) else { return [] }
            return [[Double(bounds.minX), Double(bounds.minY)], [Double(bounds.maxX), Double(bounds.minY)],
                    [Double(bounds.maxX), Double(bounds.maxY)], [Double(bounds.minX), Double(bounds.maxY)]]
        }
        let cropper = NativeSpatialSourceCrop(image: image, reader: pixelReader, eligibleCount: layout.items.filter {
            !$0.keptLettering && $0.sourcePanelRestorationEligible && $0.sourceColorEligible
        }.count)
        let protectedItems = layout.items.filter(\.keptLettering)
        let measuredLetterStyles = sampleLetterStyles(image: image, layout: layout, enabled: settings.preserveSourceColors, reader: pixelReader)
        var styleSamples: [String: [String: Any]] = [:], styleSampleAttempts = Set<String>()
        func fetchStyleSample(_ item: NativeTranslationLayoutItem) -> [String: Any]? {
            if styleSampleAttempts.contains(item.id) { return styleSamples[item.id] }
            styleSampleAttempts.insert(item.id)
            let sampler = item.sourceTextOnly ? sourceColors : translatedColors
            let value = sampler.sample(bounds: item.sourceBounds.map(Double.init), geometry: [
                "polygon": polygon(item), "excluded": layout.items.filter { $0.id != item.id }.map(polygon)
            ])
            styleSamples[item.id] = value
            return value
        }
        let letterStyles = resolvedLetterStyles(layout: layout, styles: measuredLetterStyles, sample: fetchStyleSample)
        let uprightSlantedBudget = NativeSlantedPreparation.Budget()
        for item in layout.items where !item.keptLettering && item.sourceColorEligible {
            try Task.checkCancellation()
            guard let bounds = normalizedRect(item.sourceBounds) else { continue }
            let source = pixels(bounds, image: image)
            let exclusions = layout.items.filter { $0.id != item.id }.flatMap { other in
                ([other.sourceBounds] + other.auxiliaryInkRects).compactMap(cropper.pixelRect)
            }
            let protected = protectedItems.flatMap { other in
                ([other.sourceBounds] + other.auxiliaryInkRects).compactMap(cropper.pixelRect)
            }
            var sample = fetchStyleSample(item)
            var palette = sample.flatMap(NativeRestorationPixels.palette)
            let letterStyle = letterStyles[item.id]
            var restored = false
            var sampledForeground = sample.flatMap { NativeRestorationPixels.rgb($0["foreground"]) ??
                NativeRestorationPixels.rgb($0["displayForeground"]) }
            var sampledStroke = sample.flatMap { NativeRestorationPixels.rgb($0["stroke"]) }
            var erasureComplete = false
            var restorationMethod: String?
            var sourceGlyphsVerified = false
            var provisional = false
            if settings.usesSourceInpainting && settings.renderedBackgroundOpacity == 1 && item.sourcePanelRestorationEligible {
                var prepared: NativeSpatialSourceCrop.Prepared?
                var repaired: NativeRestorationPixels?
                var slantedProof: NativeSlantedRestoration.ProofRaster?
                var slantedScale: CGFloat?
                var slantedRasterAvailable = false
                var detached = false
                if item.rotation != 0, let acceptSlanted {
                    let failures = NativeSlantedGeometry.Failures()
                    if var proposal = cropper.prepareSlanted(item: item, palette: palette, excluded: exclusions,
                        frame: cleanupFrame, uprightBudget: &uprightSlantedBudget.remaining, failures: failures) {
                        proposal.result.proof.method = proposal.result.pixels.method
                        proposal.result.proof.preparation = NativeSlantedPreparation(cropper: cropper, item: item,
                            palette: palette, excluded: exclusions, frame: cleanupFrame, budget: uprightSlantedBudget, clip: cleanupGeometry?.clip)
                        slantedRasterAvailable = true
                        let initialAppearance = Appearance(
                            foreground: settings.preserveSourceTextColor ? sampledForeground?.cgColor : nil,
                            background: settings.preserveSourceBackgroundColor ? palette?.verifiedBackground?.cgColor : nil,
                            restored: false, stroke: settings.preserveSourceTextColor ? sampledStroke?.cgColor : nil,
                            letteringStyle: letterStyle.map { $0.serif ? "serif" : "gothic" },
                            fontName: letterStyle?.serif == true ? "AidokuSerifKR-Bold" : nil,
                            sourceStrokeWeight: letterStyle?.weight ?? 0, sourceSample: sample)
                        if acceptSlanted(item, initialAppearance, proposal.result.proof, proposal.scale) {
                            prepared = proposal.prepared; repaired = proposal.result.pixels
                            repaired?.erasureComplete = true; repaired?.glyphsVerified = true
                            slantedProof = proposal.result.proof; slantedScale = proposal.scale
                        }
                    }
                    if collectDiagnostics {
                        result.recordAttempt(item, phase: "slanted-preparation", details: [
                            "reasons": failures.reasons, "rasterAvailable": slantedRasterAvailable,
                            "admitted": prepared != nil, "backgroundConfidence": palette?.backgroundConfidence ?? 0
                        ])
                    }
                    // The caller's initial glyph proof runs before this fallback spends
                    // a second crop allowance, preserving the page's shared budget order.
                    let unproven = !failures.reasons.isEmpty && failures.reasons.allSatisfy { ["panel", "preserved-core", "budget"].contains($0) }
                    let gated = unproven && (palette?.backgroundConfidence ?? 0) < 0.75
                    if prepared == nil && !slantedRasterAvailable && !gated {
                        detached = true
                        prepared = cropper.prepare(item: item, palette: palette, excluded: exclusions, detached: true, sample: sample, frame: cleanupFrame)
                    }
                } else {
                    prepared = cropper.prepare(item: item, palette: palette, excluded: exclusions, sample: sample, frame: cleanupFrame)
                }
                func localPolygon(_ vertices: [[Double]], in descriptor: NativeSpatialSourceCrop.Prepared) -> [CGPoint] {
                    vertices.compactMap { point in
                        guard point.count == 2 else { return nil }
                        return CGPoint(x: (point[0] * Double(image.width) - Double(descriptor.crop.minX)) * Double(descriptor.sx),
                                       y: (point[1] * Double(image.height) - Double(descriptor.crop.minY)) * Double(descriptor.sy))
                    }
                }
                if repaired == nil, let descriptor = prepared {
                    if collectDiagnostics {
                        func rect(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height].map(Double.init) }
                        result.recordAttempt(item, phase: "source-crop", details: [
                            "detached": detached, "crop": rect(descriptor.crop), "box": rect(descriptor.box),
                            "width": descriptor.pixels.width, "height": descriptor.pixels.height,
                            "auxiliary": descriptor.auxiliary.map(rect), "excluded": descriptor.excluded.map(rect)
                        ])
                    }
                    var options = NativeObservedRestoreOptions()
                    options.chromaticBalloon = item.balloonInterior?.contourVerified == true
                    options.sampleScale = Double(min(descriptor.sx, descriptor.sy))
                    options.leadingRule = descriptor.leadingRule
                    options.rowEndMarks = descriptor.marks
                    if detached {
                        options.auxiliary = descriptor.auxiliary; options.excluded = descriptor.excluded
                        options.inferredRubyExclusions = descriptor.excluded; options.vertical = item.sourceVertical
                        repaired = NativeRestorationPixels.exactObservedRestore(descriptor.pixels, box: descriptor.box, palette: palette, options: options)
                        if let candidate = repaired, candidate.preservedCore == 0, candidate.preservedPixels == 0,
                           let gated = NativeSlantedProof.pageErasureInQuad(original: descriptor.pixels, result: candidate,
                            sx: Double(descriptor.sx), sy: Double(descriptor.sy), ox: Double(descriptor.crop.minX), oy: Double(descriptor.crop.minY),
                            quad: [(Double(item.rect.minX) - Double(item.sourceFrame[0])) * Double(image.width) / Double(item.sourceFrame[2]),
                                   (Double(item.rect.minY) - Double(item.sourceFrame[1])) * Double(image.height) / Double(item.sourceFrame[3]),
                                   Double(item.rect.width) * Double(image.width) / Double(item.sourceFrame[2]),
                                   Double(item.rect.height) * Double(image.height) / Double(item.sourceFrame[3])],
                            angle: Double(item.rotation), auxiliary: item.auxiliaryInkRects.compactMap(cropper.pixelRect).map(NativeSlantedGeometry.array), palette: palette) {
                            let appearance = Appearance(foreground: sampledForeground?.cgColor, background: palette?.verifiedBackground?.cgColor,
                                restored: false, stroke: sampledStroke?.cgColor, sourceSample: sample)
                            let admitted = acceptPageSlanted?(item, appearance, descriptor, gated.result) == true
                            repaired = admitted ? gated.result : nil
                            if collectDiagnostics {
                                result.recordAttempt(item, phase: "slanted-page-admission", details: [
                                    "admitted": admitted, "quadProof": true
                                ])
                            }
                            if repaired != nil { repaired?.erasureComplete = true; repaired?.glyphsVerified = true }
                        } else {
                            if collectDiagnostics {
                                result.recordAttempt(item, phase: "slanted-page-admission", details: [
                                    "admitted": false, "quadProof": false,
                                    "observedRepair": repaired != nil,
                                    "preservedCore": repaired?.preservedCore ?? 0,
                                    "preservedPixels": repaired?.preservedPixels ?? 0
                                ])
                            }
                            repaired = nil
                        }
                    } else {
                        let balloonProof = NativeClosedBalloonExclusion.prove(prepared: descriptor, item: item,
                            palette: palette, imageSize: CGSize(width: image.width, height: image.height))
                        let ownedExclusions = balloonProof?.excluded ?? descriptor.excluded
                        if collectDiagnostics, ownedExclusions != descriptor.excluded {
                            result.recordAttempt(item, phase: "closed-balloon-owned-rectangle", details: [
                                "originalExclusions": descriptor.excluded.count, "resolvedExclusions": ownedExclusions.count
                            ])
                        }
                        if !ownedExclusions.isEmpty && abs(item.rotation) <= 0.01 {
                            options.excludedDonorPolicy = .observedSource
                        }
                        repaired = NativeRestorationPixels.restore(descriptor.pixels, box: descriptor.box,
                            auxiliary: descriptor.auxiliary, excluded: ownedExclusions, palette: palette,
                            vertical: item.sourceVertical, polygon: localPolygon(polygon(item), in: descriptor),
                            slanted: abs(item.rotation) > 0.01, sourceOptions: options,
                            inferredRubyExclusions: descriptor.excluded)
                        if let balloonProof, var candidate = repaired {
                            let added = balloonProof.certifyLayout(of: &candidate)
                            repaired = candidate
                            if collectDiagnostics, added > 0 {
                                result.recordAttempt(item, phase: "closed-balloon-readable-paper", details: ["pixels": added])
                            }
                        }
                    }
                }
                if var proposal = repaired, let descriptor = prepared {
                    let unitSafe = clipUnitInterior(item: item, prepared: descriptor,
                        imageSize: CGSize(width: image.width, height: image.height), repaired: &proposal,
                        frame: cleanupFrame, detached: detached, slantedProof: slantedProof)
                    if !unitSafe { result.unitResidueRiskIDs.insert(item.id) }
                    repaired = unitSafe ? proposal : nil
                }
                if var repaired, let descriptor = prepared {
                    if repaired.method == "chromatic-balloon-glyphs", let foreground = repaired.observedFill {
                        var cached = sample ?? [:]
                        cached["foreground"] = foreground.channels; cached["displayForeground"] = foreground.channels
                        cached["stroke"] = NSNull(); cached["outline"] = NSNull()
                        if let outline = repaired.discoveredOutline {
                            cached["foreground"] = [255.0, 255.0, 255.0]; cached["displayForeground"] = [255.0, 255.0, 255.0]
                            cached["stroke"] = outline.channels
                            var confidence = cached["confidence"] as? [String: Any] ?? [:]
                            confidence["foreground"] = 0.9; confidence["stroke"] = 0.9; cached["confidence"] = confidence
                            cached["sourceInk"] = ["foreground": [255.0, 255.0, 255.0], "stroke": outline.channels,
                                "confidence": ["foreground": 0.9, "stroke": 0.9],
                                "widthEvidence": ["method": "closed source fill and observed chromatic ring"]]
                        }
                        sample = cached
                    }
                    if let foreground = repaired.observedFill {
                        sampledForeground = foreground; sampledStroke = repaired.observedStroke
                        if palette != nil { palette?.foreground = foreground; palette?.stroke = repaired.observedStroke }
                        else if let background = repaired.observedBacking {
                            palette = .init(foreground: foreground, background: background, stroke: repaired.observedStroke)
                        }
                    }
                    for rect in protected { repaired.clear(rect: descriptor.local(rect)) }
                    for i in 0..<repaired.count where descriptor.synthetic[i] != 0 {
                        repaired.rgba[i * 4 + 3] = 0; repaired.layoutSafe?[i] = 0
                    }
                    if let patch = repaired.image(), repaired.paintedCount > 0 {
                        let frame = cleanupGeometry?.frame ?? normalizedRect(item.sourceFrame) ?? layout.sourceRect
                        let rect = CGRect(x: frame.minX + descriptor.crop.minX / CGFloat(image.width) * frame.width,
                                          y: frame.minY + descriptor.crop.minY / CGFloat(image.height) * frame.height,
                                          width: descriptor.crop.width / CGFloat(image.width) * frame.width,
                                          height: descriptor.crop.height / CGFloat(image.height) * frame.height)
                        let linear = (0...255).map { value -> Double in
                            let v = Double(value) / 255
                            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
                        }
                        func luminance(_ values: [Double]) -> UInt8 {
                            let value = 255 * (0.2126 * values[0] + 0.7152 * values[1] + 0.0722 * values[2])
                            return UInt8(min(255, max(0, floor(value + 0.5))))
                        }
                        let paperL = repaired.paperColor.map { luminance($0.channels.map { channel in
                            let v = channel / 255
                            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
                        }) }
                        let surfaceLuminance = (0..<repaired.count).map { i -> UInt8 in
                            if repaired.readableRules?[i] != 0, let paperL { return paperL }
                            let data = repaired.rgba[i * 4 + 3] != 0 ? repaired.rgba : descriptor.pixels.rgba
                            return luminance((0..<3).map { linear[Int(data[i * 4 + $0])] })
                        }
                        let canvasComplete = NativeRestorationCanvasPolicy.isComplete(paintedCount: repaired.paintedCount,
                            preservedPixels: repaired.preservedPixels, preservedCore: repaired.preservedCore)
                        let candidate = slantedProof != nil ? nil : NativeRestorationCandidate(
                            prepared: descriptor, repaired: repaired, luminance: surfaceLuminance,
                            imageSize: CGSize(width: image.width, height: image.height), frame: frame, item: item,
                            canvasErasureComplete: canvasComplete)
                        result.patches.append(Patch(image: patch, rect: rect, itemID: item.id, layoutSafe: repaired.layoutSafe,
                                                    surfaceLuminance: surfaceLuminance,
                                                    surfaceQuality: slantedProof != nil ? nil : repaired.surfaceQuality,
                                                    slantedProof: slantedProof, slantedScale: slantedScale, candidate: candidate,
                                                    rasterGeometry: .init(frame: frame, imageSize: CGSize(width: image.width, height: image.height),
                                                        origin: descriptor.crop.origin, scale: CGSize(width: descriptor.sx, height: descriptor.sy)),
                                                    cleanupClip: cleanupGeometry?.clip))
                        restored = true
                        restorationMethod = repaired.method; sourceGlyphsVerified = repaired.glyphsVerified; provisional = repaired.localProposal
                        erasureComplete = slantedProof != nil ? repaired.erasureComplete : canvasComplete
                    }
                }
                if !restored { result.limitations.append("unresolved-source-restoration:\(item.id)") }
            }
            result.appearances[item.id] = Appearance(
                foreground: settings.preserveSourceTextColor ? sampledForeground?.cgColor : nil,
                background: settings.preserveSourceBackgroundColor ? sample.flatMap { value in
                    NativeRestorationPixels.rgb((value["surface"] as? [String: Any])?["color"])?.cgColor ??
                        NativeRestorationPixels.rgb(value["background"])?.cgColor
                } : nil,
                restored: restored,
                stroke: settings.preserveSourceTextColor ? sampledStroke?.cgColor : nil,
                strokeWidth: sampledStroke == nil ? 0 : min(2, max(0.5, min(source.width, source.height) * 0.04)),
                erasureComplete: erasureComplete,
                letteringStyle: letterStyle.map { $0.serif ? "serif" : "gothic" },
                fontName: letterStyle?.serif == true ? "AidokuSerifKR-Bold" : nil,
                sourceStrokeWeight: letterStyle?.weight ?? 0,
                sourceSample: sample, restorationMethod: restorationMethod, sourceGlyphsVerified: sourceGlyphsVerified,
                provisional: provisional
            )
        }
        applyLetterStyles(letterStyles, result: &result)
        return result
    }

    private static func normalizedRect(_ values: [CGFloat]) -> CGRect? {
        guard values.count == 4, values.allSatisfy(\.isFinite), values[2] > 0, values[3] > 0 else { return nil }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    private static func pixels(_ bounds: CGRect, image: CGImage) -> CGRect {
        CGRect(x: bounds.minX * CGFloat(image.width), y: bounds.minY * CGFloat(image.height),
               width: bounds.width * CGFloat(image.width), height: bounds.height * CGFloat(image.height))
    }
}
