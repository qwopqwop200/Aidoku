import CoreGraphics
import Foundation
import CryptoKit
import ImageIO

extension NativeAOTTranslationPageComposer {
    struct TranslatedFillPrimitive {
        /// Transparent, fill-only native glyph raster. No old display stroke.
        var image: CGImage
        /// Integral source/output pixel rectangle, origin at image top left.
        var frame: CGRect
        let fontOutputPixels: CGFloat
        var displayStrokeEndpoint:UInt8? = nil
        var displayStrokeRatio:CGFloat? = nil
        var recheckFinalEndpoint = false
        var minimumFillStrokeContrast = 3.0
        var minimumCoverageGain = 0.05
        var sourceStyle: NativeSourceStylePaint.Style? = nil
        var sourceAppearance: [String:Any]? = nil
        /// Resolved only by the authenticated source producer, never by paint.
        var sourceContourOnly: Bool = false
        var ownerID: String? = nil
        var placementDomain: ((CGRect) -> Bool)? = nil {
            didSet { domainContainsSubrects = false }
        }
        // Only the native mask/contour, capacity and protected-rectangle
        // predicates certify every positive subrectangle of an accepted box.
        private(set) var domainContainsSubrects = false
        mutating func certifyNativeDomainSubrects() {
            domainContainsSubrects = placementDomain != nil
        }
        var hasFinalEffects = false
        var sourceClusterAlignment: NativeSourceClusterAlignment? = nil
        var balloonPlacement: NativeBalloonPlacement? = nil
        /// Only a failed soft body target is relaxed; the assigned alpha mask
        /// and source/body ownership remain mandatory and unchanged.
        var balloonTargetRelaxed = false
        var textPlacementGuide: NativeTextPlacementGuide? = nil
        var textExpansionPolicy: NativeTextExpansionPolicy? = nil

        func validateSourceContourOnly() throws {
            if sourceContourOnly {
                guard !hasFinalEffects else { throw NativeMandatoryDisplayStroke.Failure.invalidInput }
                try NativeSourceStylePaint.validateSourceContourOnly(sourceStyle)
            }
        }
    }

    /// Internal, render-local typed handoff from a REAL completed final paint.
    /// Never decoded from JSON and never reconstructs carriers from rectangles.
    final class CompletedPaintObserver: @unchecked Sendable {
        let observe: (CGImage, [TranslatedFillPrimitive], [[String:Any]]) -> Void
        init(_ observe: @escaping (CGImage, [TranslatedFillPrimitive], [[String:Any]]) -> Void) {
            self.observe = observe
        }
    }
    @TaskLocal static var completedPaintObserver: CompletedPaintObserver?

    /// Concrete minimal adapter for render(source:removalMask:textLayer:).
    /// Invoke inside textLayer with its reconstructed CGImage, before creating
    /// or sealing TextLayer. Upstream owns source colour and text completeness.
    static func mandatoryStrokeLayer(restored: CGImage,
                                     fills: [TranslatedFillPrimitive],
                                     expectedItems: Int,
                                     textComplete: Bool) throws -> TextLayer {
        guard textComplete, expectedItems == fills.count, expectedItems >= 0 else {
            throw Failure.incompleteTranslation
        }
        let start = Date()
        let admitted = try NativeFinalTextPaintAdmission.place(fills,
            page: CGRect(x: 0, y: 0, width: restored.width, height: restored.height))
        return try paintAdmitted(restored:restored,admitted:admitted,expectedItems:expectedItems,textComplete:textComplete,start:start)
    }

    /// Position/background-bound actual effect layers, not an opaque raster or
    /// geometry-only certificate. Construction is confined to this real verifier.
    struct FixedFontVerifiedAdmission {
        fileprivate let restored:CGImage
        fileprivate let admitted:(fills:[TranslatedFillPrimitive],audit:[[String:Any]])
        fileprivate let layers:[NativeMandatoryDisplayStroke.Prepared]
        fileprivate let sourceStyleMemo:NativeSourceStylePaint.PlaneMemo
        fileprivate let retainedPixels:Int
        fileprivate let rowGapSupport:[NativeFinalTextPaintAdmission.Footprint]?
    }
    static func verifyFixedFontAdmission(restored:CGImage,
        admitted:(fills:[TranslatedFillPrimitive],audit:[[String:Any]]),
        requireOwnerIdentity:Bool=true,reusing prior:FixedFontVerifiedAdmission?=nil)throws -> FixedFontVerifiedAdmission {
        let fills=admitted.fills
        guard fills.count==admitted.audit.count else {throw Failure.incompleteTranslation}
        let owners=fills.compactMap(\.ownerID)
        if requireOwnerIdentity {
            guard owners.count==fills.count,Set(owners).count==fills.count else {throw Failure.invalidTextLayer}
        }
        let layers=try fills.enumerated().map {index,fill -> NativeMandatoryDisplayStroke.Prepared in
            try fill.validateSourceContourOnly()
            // Prepared effects are position/background-bound. Reuse only the
            // exact immutable peer snapshot from this request; all final alpha,
            // domain and peer verification still runs on the new complete tuple.
            if let prior,prior.restored === restored,prior.admitted.fills.count==fills.count,
               prior.layers.count==fills.count {
                let old=prior.admitted.fills[index]
                if NativeBodySourceAnchorRecovery.carrierPreserved(old,fill,shift:.zero),
                   old.sourceStyle?.pendingRoundedContour?.identity == fill.sourceStyle?.pendingRoundedContour?.identity {
                    let sameRaster=try NativeMandatoryDisplayStroke.rgba(old.image)==NativeMandatoryDisplayStroke.rgba(fill.image)
                    if sameRaster {return prior.layers[index]}
                }
            }
            return try NativeMandatoryDisplayStroke.prepare(fill:fill.image,restored:restored,
                fontOutputPixels:fill.fontOutputPixels,outwardEm:fill.displayStrokeRatio ?? 0.20,
                fillFrame:fill.frame,forcedEndpoint:fill.displayStrokeEndpoint,
                recheckFinalEndpoint:fill.recheckFinalEndpoint,minimumFillStrokeContrast:fill.minimumFillStrokeContrast,
                minimumCoverageGain:fill.minimumCoverageGain,sourceAppearance:fill.sourceAppearance,
                sourceContourOnly:fill.sourceContourOnly)
        }
        let cache=NativeFixedFontRecovery.metrics?.activeCache
        var newlyCharged:[CGImage]=[]
        var verificationSucceeded=false
        defer {
            if !verificationSucceeded,let cache {
                // Existing incumbent/shared image charges belong to their prior owner.
                for image in newlyCharged {cache.releaseDiscarded(image:image)}
            }
        }
        if let cache {
            for (index,layer) in layers.enumerated() {
                let owner=fills[index].ownerID ?? "unknown"
                if try cache.retain(owner:owner,image:layer.fill) {newlyCharged.append(layer.fill)}
                if try cache.retain(owner:owner,image:layer.halo) {newlyCharged.append(layer.halo)}
            }
        }
        let sourceStyleMemo = NativeSourceStylePaint.PlaneMemo()
        var rowGapSupport: [NativeFinalTextPaintAdmission.Footprint]?
        let pixels=try NativeFinalTextPaintAdmission.verify(fills,layers:layers,
            page:CGRect(x:0,y:0,width:restored.width,height:restored.height),admissionAudit:admitted.audit,
            sourceStyleMemo:sourceStyleMemo) { supports in
                // Some fixed-font candidates outlive verification. Keep only bounded run storage.
                guard !supports.isEmpty, supports.count <= 256, NativeStyledRowGap.enabled else { return }
                var bytes = supports.capacity * MemoryLayout<NativeFinalTextPaintAdmission.Footprint>.stride
                for support in supports {
                    bytes += support.runs.source.capacity * MemoryLayout<NativeFinalTextPaintAdmission.Run>.stride
                    guard bytes <= 512 * 1024 else { return }
                }
                rowGapSupport = supports
            }
        verificationSucceeded=true
        return .init(restored:restored,admitted:admitted,layers:layers,sourceStyleMemo:sourceStyleMemo,retainedPixels:pixels,rowGapSupport:rowGapSupport)
    }
    /// Reuse the exact verified image/style/position/background witnesses. Paint
    /// once after selection; no second solve can alter body targets or peer pins.
    static func mandatoryStrokeLayer(verified:FixedFontVerifiedAdmission,
        expectedItems:Int,textComplete:Bool)throws -> TextLayer {
        guard textComplete,expectedItems==verified.admitted.fills.count else {throw Failure.incompleteTranslation}
        return try paintAdmitted(restored:verified.restored,admitted:verified.admitted,
            expectedItems:expectedItems,textComplete:textComplete,start:Date(),verified:verified)
    }

    /// Apply only after all shape-selection counterfactuals have finished.
    /// Source bands, fill and final BW contrast are re-prepared at the new
    /// position, with the same native glyphs and point sizes.
    static func refineFinalReadability(layer:TextLayer,fills:[TranslatedFillPrimitive],restored:CGImage,
        admittedOverride:(fills:[TranslatedFillPrimitive],audit:[[String:Any]])?=nil,forceRepaint:Bool=false)throws->TextLayer {
        let page=CGRect(x:0,y:0,width:restored.width,height:restored.height)
        // A forced terminal repaint already carries a complete admitted tuple.
        // Re-proposing its incumbent could discard a certified retained anchor.
        // The actual prepared effects and receipts are still verified below.
        let priorCohort: (fills:[TranslatedFillPrimitive],audit:[[String:Any]])?
        if let admittedOverride, admittedOverride.audit.contains(where: { $0[NativeSourceCohortCenterBalance.auditKey] != nil }) {
            priorCohort = admittedOverride
        } else if let rows = layer.audit["finalPaintAdmission"] as? [[String:Any]],
                  rows.contains(where: { $0[NativeSourceCohortCenterBalance.auditKey] != nil }) {
            priorCohort = (fills,rows)
        } else { priorCohort = nil }
        let before: (fills:[TranslatedFillPrimitive],audit:[[String:Any]])
        if forceRepaint, let admittedOverride { before = admittedOverride }
        else if let priorCohort {
            let support = try priorCohort.fills.map { try NativeFinalTextPaintAdmission.retainedFootprint($0) }
            let anchors = try NativeFinalTextPaintAdmission.verifiedRetainedClusterAnchors(priorCohort.fills,
                footprints:support,audit:priorCohort.audit,page:page)
            let owners = priorCohort.fills.compactMap(\.ownerID)
            guard owners.count == support.count, Set(owners).count == owners.count else { throw NativeFinalTextPaintAdmission.Failure.invalidGeometry }
            let fixed = Dictionary(uniqueKeysWithValues:owners.indices.map { (owners[$0],support[$0].bounds.origin) })
            var admitted = try NativeFinalTextPaintAdmission.place(priorCohort.fills,page:page,
                fixedOrigins:fixed,retainedClusterAnchors:anchors)
            admitted.audit = try NativeBalloonPlacement.RetainedState.preservingKnownSnapshots(
                priorAudit:priorCohort.audit,admittedAudit:admitted.audit,unknownPolicy:.preservePriorUncertainty)
            before = try NativeSourceCohortCenterBalance.preservingReceipts(prior:priorCohort,admitted:admitted,page:page)
        } else { before = try NativeFinalTextPaintAdmission.place(fills,page:page) }
        // A retained tuple has already completed geometry refinement. A reload
        // validates its same origins instead of introducing a fresh polish pass.
        var after = admittedOverride ?? (priorCohort == nil ? NativeFinalTextPaintAdmission.refineFinalPlacement(before,page:page):before)
        if let priorCohort {
            after = try NativeSourceCohortCenterBalance.preservingReceipts(prior:priorCohort,admitted:after,page:page)
        }
        guard forceRepaint || after.fills.indices.contains(where:{i in
            after.fills[i].frame != (priorCohort != nil && fills.indices.contains(i) ? fills[i].frame : before.fills[i].frame) ||
            after.fills[i].balloonTargetRelaxed != before.fills[i].balloonTargetRelaxed ||
            after.fills[i].balloonPlacement?.finalReadabilityGaps != before.fills[i].balloonPlacement?.finalReadabilityGaps
        })else{return layer}
        let painted=try paintAdmitted(restored:restored,admitted:after,expectedItems:layer.expectedItems,
            textComplete:layer.complete,start:Date())
        var audit=layer.audit;audit.merge(painted.audit){_,new in new}
        if painted.audit["finalGlyphWitnesses"] == nil { audit.removeValue(forKey:"finalGlyphWitnesses") }
        if after.audit.contains(where:{$0["adaptiveGutterRefined"]as?Bool == true}) {audit["adaptiveGutterFinalOnly"]=true}
        if after.audit.contains(where:{$0["contourClearanceRefined"]as?Bool == true}) {audit["contourClearanceFinalOnly"]=true}
        if after.audit.contains(where:{$0["inkContourClearanceRefined"]as?Bool == true}) {audit["inkContourClearanceFinalOnly"]=true}
        if var rows=audit["rawNativeItems"]as?[[String:Any]],
           let decisions=painted.audit["endpointDecisions"]as?[[String:Any]] {
            for i in rows.indices where i<decisions.count {
                rows[i]["finalStrokeDecision"]=decisions[i]
                rows[i]["finalDisplayFill"]=decisions[i]["displayFillRGB"]
                rows[i]["finalDisplayStroke"] = decisions[i]["finalDisplayStroke"] ??
                    decisions[i]["finalEndpoint"].map {[$0,$0,$0]}
            }
            audit["rawNativeItems"]=rows
        }
        return .init(image:painted.image,expectedItems:layer.expectedItems,paintedItems:layer.paintedItems,
            complete:layer.complete,audit:audit)
    }

    private enum GlyphWitnessFailure: String, Error {
        case invalidOwner, invalidGeometry, pixelBudget, byteBudget, allocation, encoding, nonExactPNGRoundTrip, processing
    }
    private struct GlyphWitnessStats {
        static let maxImagePixels = 8_000_000
        static let maxPixels = 16_777_216
        static let maxPNGBytes = 16_777_216
        static let maxBase64Bytes = 24 * 1_024 * 1_024
        static let maxWorkingBytes = 192 * 1_024 * 1_024
        var pixels = 0, rgbaBytes = 0, pngBytes = 0, base64Bytes = 0, encodedOwners = 0, unsupportedOwners = 0
        var audit: [String: Any] {
            ["processedPixels": pixels, "canonicalRGBABytes": rgbaBytes, "encodedPNGBytes": pngBytes,
             "encodedBase64UTF8Bytes": base64Bytes, "encodedOwnerCount": encodedOwners,
             "unsupportedOwnerCount": unsupportedOwners, "perImagePixelBudget": Self.maxImagePixels,
             "aggregatePixelBudget": Self.maxPixels, "aggregatePNGByteBudget": Self.maxPNGBytes,
             "aggregateBase64ByteBudget": Self.maxBase64Bytes, "captureWorkingBufferByteBudget": Self.maxWorkingBytes]
        }
    }
    /// Bound the encoder's output while ImageIO writes, not only after it has
    /// allocated an arbitrarily large compressed stream. No source/background.
    private final class GlyphWitnessPNGBuffer {
        var data = Data()
        let limit: Int
        var exceeded = false
        init(limit: Int) { self.limit = limit }
    }
    private static func witnessPNG(_ image: CGImage, limit: Int, stats: inout GlyphWitnessStats) throws -> Data {
        let output = GlyphWitnessPNGBuffer(limit: limit)
        let retained = Unmanaged.passRetained(output)
        var callbacks = CGDataConsumerCallbacks(putBytes: { info, bytes, count in
            guard let info else { return 0 }
            let buffer = Unmanaged<GlyphWitnessPNGBuffer>.fromOpaque(info).takeUnretainedValue()
            guard count >= 0, count <= buffer.limit - buffer.data.count else { buffer.exceeded = true; return 0 }
            buffer.data.append(bytes.assumingMemoryBound(to: UInt8.self), count: count)
            return count
        }, releaseConsumer: { info in
            if let info { Unmanaged<GlyphWitnessPNGBuffer>.fromOpaque(info).release() }
        })
        guard let consumer = CGDataConsumer(info: retained.toOpaque(), cbks: &callbacks) else {
            retained.release(); throw GlyphWitnessFailure.allocation
        }
        guard let destination = CGImageDestinationCreateWithDataConsumer(consumer, "public.png" as CFString, 1, nil) else {
            throw GlyphWitnessFailure.encoding
        }
        CGImageDestinationAddImage(destination, image, nil)
        let completed = CGImageDestinationFinalize(destination)
        stats.pngBytes += output.data.count
        guard !output.exceeded else { throw GlyphWitnessFailure.byteBudget }
        guard completed, !output.data.isEmpty else { throw GlyphWitnessFailure.encoding }
        return output.data
    }
    private static func finalGlyphWitnesses(fills: [TranslatedFillPrimitive], layers: [NativeMandatoryDisplayStroke.Prepared],
        canvas: CGSize, stats: inout GlyphWitnessStats) throws -> [[String: Any]] {
        try Task.checkCancellation()
        guard fills.count == layers.count, fills.count <= 256 else { throw GlyphWitnessFailure.invalidGeometry }
        var owners: [[String: Any]] = [], identities = Set<String>()
        for (i, layer) in layers.enumerated() {
            try Task.checkCancellation()
            let fill = fills[i], image = layer.fill // THE exact plane subsequently passed to paint().
            guard let owner = fill.ownerID, !owner.isEmpty, owner.utf8.count <= 512,
                  identities.insert(owner).inserted else { throw GlyphWitnessFailure.invalidOwner }
            guard image.width > 0, image.height > 0, fill.fontOutputPixels.isFinite, fill.fontOutputPixels > 0,
                  [layer.frame.minX, layer.frame.minY, layer.frame.width, layer.frame.height].allSatisfy(\.isFinite)
            else { throw GlyphWitnessFailure.invalidGeometry }
            var row: [String: Any] = ["ownerID": owner, "width": image.width, "height": image.height,
                "frameOutputPixels": [layer.frame.minX, layer.frame.minY, layer.frame.width, layer.frame.height].map(Double.init),
                "fontOutputPixels": Double(fill.fontOutputPixels), "canvasWidth": Int(canvas.width), "canvasHeight": Int(canvas.height),
                "sourceContourOnly": layer.sourceContourOnly,
                "hasFinalEffects": fill.hasFinalEffects, "glyphOnly": !fill.hasFinalEffects,
                "producer": "actual-final-NativeMandatoryDisplayStroke.Prepared.fill"]
            if fill.hasFinalEffects {
                // A prepainted raster may already contain a stroke/shadow. Do
                // not mislabel it or emit it as independently observed glyph AA.
                row["status"] = "unsupported-prepainted-effects"
                stats.unsupportedOwners += 1; owners.append(row); continue
            }
            guard image.width <= GlyphWitnessStats.maxImagePixels / image.height else { throw GlyphWitnessFailure.pixelBudget }
            let pixels = image.width * image.height, byteCount = pixels * 4
            guard pixels <= GlyphWitnessStats.maxPixels - stats.pixels else { throw GlyphWitnessFailure.pixelBudget }
            // Conservative owned-buffer reservation: canonical/hash/decode
            // buffers plus PNG/base64 temporaries and prior retained strings.
            // ImageIO/CG internal allocations are not a measured process RSS.
            let remainingMemory = GlyphWitnessStats.maxWorkingBytes - stats.base64Bytes - byteCount * 4
            let pngLimit = min(GlyphWitnessStats.maxPNGBytes - stats.pngBytes, remainingMemory / 5)
            guard pngLimit > 0 else { throw GlyphWitnessFailure.byteBudget }
            stats.pixels += pixels; stats.rgbaBytes += byteCount
            let rgba = try NativeMandatoryDisplayStroke.rgba(image)
            guard rgba.count == byteCount else { throw GlyphWitnessFailure.invalidGeometry }
            let rgbaHash = SHA256.hash(data: Data(rgba)).map { String(format: "%02x", $0) }.joined()
            try Task.checkCancellation()
            let png = try witnessPNG(image, limit: pngLimit, stats: &stats)
            try Task.checkCancellation()
            // A PNG is proof only if decoding reproduces the SAME canonical
            // actual prepared premultiplied bytes, including every AA sample.
            guard let source = CGImageSourceCreateWithData(png as CFData, nil),
                  let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  decoded.width == image.width, decoded.height == image.height,
                  try NativeMandatoryDisplayStroke.rgba(decoded) == rgba else { throw GlyphWitnessFailure.nonExactPNGRoundTrip }
            let base64Bytes = ((png.count + 2) / 3) * 4
            guard base64Bytes <= GlyphWitnessStats.maxBase64Bytes - stats.base64Bytes,
                  stats.base64Bytes + byteCount * 4 + png.count * 5 <= GlyphWitnessStats.maxWorkingBytes
            else { throw GlyphWitnessFailure.byteBudget }
            row["premultipliedRGBASHA256"] = rgbaHash
            row["pngSHA256"] = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
            row["pngBase64"] = png.base64EncodedString()
            row["status"] = "captured-actual-prepared-glyph-plane"
            stats.base64Bytes += base64Bytes; stats.encodedOwners += 1
            owners.append(row)
        }
        try Task.checkCancellation()
        return owners
    }

    private static func paintAdmitted(restored:CGImage,
        admitted:(fills:[TranslatedFillPrimitive],audit:[[String:Any]]),
        expectedItems:Int,textComplete:Bool,start:Date,
        verified:FixedFontVerifiedAdmission?=nil)throws->TextLayer {
        let captureGlyphWitnesses = ProcessInfo.processInfo.environment["AIDOKU_CAPTURE_FINAL_GLYPH_WITNESSES"] == "1"
        let fills = admitted.fills
        let verification=try verified ?? verifyFixedFontAdmission(restored:restored,admitted:admitted,requireOwnerIdentity:false)
        let layers=verification.layers
        let retainedPixels=verification.retainedPixels
        /* Preparation and all native guards moved without relaxation to the
           typed factory above; this comment marks the end of the refactor. */
        guard let context = CGContext(data: nil, width: restored.width, height: restored.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.allocation }
        var sourceStyleAudit: [[String: Any]] = []
        for (index, layer) in layers.enumerated() {
            if let style = fills[index].sourceStyle {
                sourceStyleAudit.append(try NativeSourceStylePaint.paint(style, fill:layer.fill,frame:layer.frame,
                    fontPixels:fills[index].fontOutputPixels,mandatoryOutward:layer.outwardPixels,
                    pageHeight:restored.height,context:context,memo:verification.sourceStyleMemo))
            } else {sourceStyleAudit.append(["sourceStylePainted":false])}
        }
        NativeMandatoryDisplayStroke.paint(layers, in: context)
        guard let image = context.makeImage() else { throw Failure.allocation }
        try NativeFinalTextPaintAdmission.verifyRaster(image, expectedPixels: retainedPixels)
        let decisions = layers.enumerated().map { index, layer -> [String: Any] in
            var decision = layer.endpointDecision
            if layer.sourceContourOnly, let style = fills[index].sourceStyle {
                decision["finalDisplayStroke"] = style.bands[0].rgb
                decision["sourceLayerWidthsPixels"] = style.bands.map(\.width)
                decision["sourceToDisplayScale"] = Double(fills[index].fontOutputPixels) / style.sourceFontPixels
            }
            return decision
        }
        var audit: [String: Any] = [
                "policy": layers.contains(where: { $0.sourceContourOnly })
                    ? "source-contour-only-or-mandatory-BW" : "mandatory-pureBW-outward-max2px-runtime-em",
                "defaultOutwardEm": 0.20,
                "outwardRadiiOutputPixels": layers.map(\.outwardPixels),
                "paintOrder": "all-strokes-then-all-fills",
                "restoredImageExplicit": true,
                "fontRefitForHalo": false,
                "preSealRasterFallback": true,
                "pageEdgeContacts": layers.filter(\.touchesPageEdge).count,
                "endpointDecisions": decisions,
                "sourceStylePaint": sourceStyleAudit,
                "finalPaintAdmission": admitted.audit,
                "finalPaintCollisionAuthority": "actual nonzero retained glyph/stroke/band/shadow alpha; zero peer intersections",
                "finalPaintBoundsChecked": true,
                "finalRetainedAlphaPixels": retainedPixels,
                "finalCompositeAlphaVerified": true,
                "strokePrepareAndPaintSeconds": Date().timeIntervalSince(start),
                "semanticCompletenessAuthority": "caller; not established by nonzero alpha"
            ]
        if NativeStyledRowGap.enabled {
            do {audit["completedStyledRowPairMetric"] = try NativeStyledRowGap.measure(fills:fills,layers:layers,audit:admitted.audit,
                sourceStyleMemo:verification.sourceStyleMemo,verifiedSupport:verification.rowGapSupport)}
            catch is CancellationError {throw CancellationError()}
            catch {audit["completedStyledRowPairMetric"]=["version":1,"complete":false,"reason":"measurement-unavailable"]}
        }
        audit["sourceStylePlaneReuse"] = ["hits": verification.sourceStyleMemo.hits,
                                         "retainedBytes": verification.sourceStyleMemo.retainedBytes]
        if captureGlyphWitnesses {
            var stats = GlyphWitnessStats()
            var wrapper: [String: Any] = ["version": 1, "canvasWidth": restored.width, "canvasHeight": restored.height,
                "metricScope": "actual Prepared.fill only; no synthetic halo/source bands/shadows/restored background; not OCR or semantic completeness",
                "canonicalization": "NativeMandatoryDisplayStroke.rgba: DeviceRGB8 premultiplied-last; exact PNG decode roundtrip required",
                "sourceRGBExported": false]
            do {
                let owners = try finalGlyphWitnesses(fills: fills, layers: layers,
                    canvas: CGSize(width: restored.width, height: restored.height), stats: &stats)
                wrapper["owners"] = owners
                wrapper["status"] = stats.unsupportedOwners == 0 ? "captured" : "captured-with-unsupported"
                wrapper["captureComplete"] = true
                wrapper["glyphProofComplete"] = stats.unsupportedOwners == 0
            } catch {
                if error is CancellationError { throw error }
                // Logging cannot trigger a new font/layout fallback. Failure is
                // typed and atomic: no partial owner array is published as proof.
                wrapper["owners"] = [[String: Any]]()
                wrapper["status"] = "failed"
                wrapper["failureCode"] = (error as? GlyphWitnessFailure ?? .processing).rawValue
                wrapper["captureComplete"] = false; wrapper["glyphProofComplete"] = false
            }
            wrapper.merge(stats.audit) { _, measured in measured }
            audit["finalGlyphWitnesses"] = wrapper
        }
        let result = TextLayer(image:image,expectedItems:expectedItems,paintedItems:layers.count,
            complete:textComplete,audit:audit)
        completedPaintObserver?.observe(image,admitted.fills,admitted.audit)
        return result
    }
}
