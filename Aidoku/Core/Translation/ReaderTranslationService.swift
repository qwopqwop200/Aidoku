import UIKit
import CoreGraphics
import Foundation

struct ReaderTranslationRegion: Equatable, Sendable {
    let id: String
    let rect: CGRect // Normalized image coordinates, top-left origin.
    let source: String
    // Source reread receipts; original accepted-source table remains immutable.
    var sourceColumnRecognition: NativeCausalPacketColumnRecognition.Correction? = nil
    var sourceRFParagraphRecognition: NativeCausalRFParagraphRecognition.Correction? = nil
    var translation: String?
    /// A classified effect retains its source pixels even though its translated
    /// text is stored for diagnostics and cache reuse.
    var keepsClassifiedSFXSource = false
    /// Changed symbol-only output may need typesetting; identical output keeps source pixels.
    var rendersUnchangedSymbols = false
    var polygon: [CGPoint] = [] // Normalized; retain the detector/merger geometry.
    var confidence: Double = 1
    var sourceImageAspectRatio: Double? = nil
    var translationOrder: Int? = nil
    var translationOrderVersion: String? = nil
    var sourceOrientation: BrowserOCRSourceOrientation = .unknown
    var sourceSingleVerticalColumn: Bool?
    var translationReuseIdentity: NativeTranslationReuseIdentity?
    /// Explicit optional-recovery failure; nil also permits legitimate preserved lettering.
    var translationRecoveryFailure: String? = nil
    var auxiliaryInkRects: [CGRect] = [] // Normalized suppressed-ruby ink; not layout bounds.
    var auxiliaryInkPolygons: [[CGPoint]] = []
    var detectorSeedEvidence: [NativeOCRDetectorSeedEvidence]? = nil
    var acceptedSource: NativeOCRSourceMetadata = .init()
    /// Original premerge BODY geometry in GLOBAL SOURCE PIXELS. Cached geometry
    /// is saved directly from real members; never reconstructed from final rect.
    var cachedSourceMemberPolygons: [[CGPoint]] = []
    var sourceMemberPolygons: [[CGPoint]] {
        acceptedSource.bodySourcePolygons ?? cachedSourceMemberPolygons
    }
    var sourceOCRAlternatives: [ReaderTranslationSourceOCRAlternative] = [] // Legacy stored data; never read or sent for translation.
    var sourceRoleEvidence: NativeTranslationRoleEvidence? = nil // Source-bound geometry, never a role answer.
    /// Compact model/OCR evidence only; no source masks or images survive here.
    var postLLMContentEvidence: NativePostLLMContentReclassifier.Evidence? = nil
    /// Clean paper of the balloon that holds only this caption (native, measured with the OCR).
    var balloonInterior: ReaderTranslationBalloonInterior?
    /// Normalized OCR boxes of the blocks joined into this balloon unit (see
    /// `ReaderTranslationBalloonMerger.joinBalloonUnits`); `rect` is their union. The overlay erases and
    /// plates the members inside their balloon, never the whole union rectangle. Empty for other regions.
    var unitMemberRects: [CGRect] = []
    /// Cut-off fine print of a background document, found with the OCR (see
    /// `ReaderTranslationNonContentText.markingOccludedDocumentText`): its lettering stays as printed.
    var isOccludedFinePrint = false
    /// A whole utterance recovered by the OCR below its confidence gate (an isolated near-threshold read or a
    /// split lettering stack, see `NativeOCRIsolatedLineRecovery`). The overlay translates it only where its
    /// source erases cleanly: when it would need a plate over artwork, the source lettering stays as printed.
    var isRecoveredLine = false

    /// If translation adds no information, preserve the original lettering.
    /// This avoids opaque boxes over numbers, punctuation, unchanged names,
    /// and artwork that OCR mistook for a letter. Changed output still paints.
    var preservesOriginalText: Bool {
        if translationRecoveryFailure != nil { return true }
        if keepsClassifiedSFXSource && translation != nil { return true }
        return NativeSourceTextPreservation.matches(source: source, translated: translation)
    }

    func effectiveTranslation(_ segment: RemoteTranslatedSegment) -> RemoteTranslatedSegment {
        NativePostLLMContentReclassifier.resolved(segment, evidence: postLLMContentEvidence)
    }

    @discardableResult
    mutating func applyTranslation(_ segment: RemoteTranslatedSegment) -> Bool {
        let segment = effectiveTranslation(segment)
        // A false OCR detection is not lettering: keep its original pixels and
        // ignore any schema-required text returned with the error role.
        if segment.textRole == .error {
            let changed = translation != source || rendersUnchangedSymbols || keepsClassifiedSFXSource
            translation = source
            keepsClassifiedSFXSource = false
            rendersUnchangedSymbols = false
            return changed
        }
        let classifiedSFX = segment.isSFX == true || segment.textRole == .sfx
        let keepSFX = classifiedSFX
        let effectiveText = segment.textRole == .background ? source : segment.text
        let original = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceScalars = original.unicodeScalars
        let renderSymbols = !keepSFX && segment.textRole != .background &&
            effectiveText.trimmingCharacters(in: .whitespacesAndNewlines) != original &&
            !sourceScalars.isEmpty && sourceScalars.allSatisfy {
                CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0) ||
                    CharacterSet.whitespacesAndNewlines.contains($0)
            }
        let changed = translation != effectiveText || rendersUnchangedSymbols != renderSymbols ||
            keepsClassifiedSFXSource != keepSFX
        // Object lettering is translated by the provider for diagnostics, but
        // its original pixels must not receive a speech-style overlay.
        translation = effectiveText
        keepsClassifiedSFXSource = keepSFX
        rendersUnchangedSymbols = renderSymbols
        return changed
    }

    /// The reply only re-spells its source (see `restatesSource`), so repainting
    /// would replace styled lettering with plain type without adding information.
    var restatesOriginalText: Bool {
        guard let translation else { return false }
        let original = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return !original.isEmpty && Self.restatesSource(original, translation.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Regions whose original lettering stays visible (no overlay item, no cleanup).
    /// Restated regions, non-content notices (watermarks, handles, URLs) and occluded document fine
    /// print (see `ReaderTranslationNonContentText`) are kept only when their lettering does not overlap
    /// a painted region's: the neighbour's erasure or plate would otherwise cut the kept lettering.
    /// Slanted quads are tested as drawn, not by their axis-aligned bounds (a tilted phone number whose
    /// bounds only reach the empty corners of the tilted name above it and a caption box beside it).
    static func keepsOriginalLettering(_ regions: [Self]) -> [Bool] {
        let exact = regions.map(\.preservesOriginalText)
        let notices = ReaderTranslationNonContentText.notices(in: regions)
        let restated = regions.enumerated().map { index, region in
            !exact[index] && (region.restatesOriginalText
                || (region.translation != nil && (notices[index] || region.isOccludedFinePrint)))
        }
        guard restated.contains(true) else { return exact }
        var kept = zip(exact, restated).map { $0 || $1 }
        var painted = regions.indices.filter { regions[$0].translation != nil && !kept[$0] }
        var cursor = 0
        // A restated caption that meets a painted neighbour must itself paint. Propagate that
        // decision through its neighbours too, so a chain cannot leave protected lettering
        // underneath a newly painted caption. Visit each painted region only once.
        while cursor < painted.count {
            let neighbour = painted[cursor]
            cursor += 1
            for index in regions.indices where kept[index] && !exact[index] {
                if regions[index].letteringIntersects(regions[neighbour]) {
                    kept[index] = false
                    painted.append(index)
                }
            }
        }
        return kept
    }

    /// Whether the lettering of two regions meets: a separating-axis test on the convex hulls of their
    /// detected quadrilaterals (a box without one), which never reports less overlap than the drawn quads have.
    func letteringIntersects(_ other: Self) -> Bool {
        guard rect.intersects(other.rect) else { return false }
        let shapes = [self, other].map { region -> [CGPoint] in
            let box = region.rect
            let corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                           CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
            guard region.polygon.count >= 3, region.polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return corners }
            let hull = Self.convexHull(region.polygon)
            return hull.count >= 3 ? hull : corners
        }
        for shape in shapes {
            for (index, point) in shape.enumerated() {
                let next = shape[(index + 1) % shape.count]
                let axis = CGPoint(x: point.y - next.y, y: next.x - point.x)
                let spans = shapes.map { points -> (CGFloat, CGFloat) in
                    let values = points.map { $0.x * axis.x + $0.y * axis.y }
                    return (values.min() ?? 0, values.max() ?? 0)
                }
                if spans[0].1 < spans[1].0 || spans[1].1 < spans[0].0 { return false }
            }
        }
        return true
    }

    private static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard sorted.count >= 3 else { return sorted }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower: [CGPoint] = [], upper: [CGPoint] = []
        for point in sorted {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 0 { lower.removeLast() }
            lower.append(point)
        }
        for point in sorted.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 0 { upper.removeLast() }
            upper.append(point)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// Letters and digits equal up to case, width, spacing and punctuation, or Latin
    /// lettering (logos, credits, UI labels, product names) with a few OCR-corrected
    /// characters. OCR may attach one stray glyph of another script to the lettering.
    static func restatesSource(_ source: String, _ translation: String) -> Bool {
        let target = skeleton(translation)
        guard !target.isEmpty, target.count <= 64, !source.isEmpty else { return false }
        let original = skeleton(source)
        if original == target { return true }
        guard target.allSatisfy(isLatinOrDigit) else { return false }
        let latin = original.filter(isLatinOrDigit)
        let stray = original.count - latin.count
        guard !latin.isEmpty, stray <= 1, stray * 10 <= original.count else { return false }
        let allowance = min(3, max(1, max(latin.count, target.count) / 5))
        guard abs(latin.count - target.count) <= allowance else { return false }
        return editDistance(latin, target) <= allowance
    }

    private static func skeleton(_ text: String) -> [Unicode.Scalar] {
        text.precomposedStringWithCompatibilityMapping.folding(options: [.caseInsensitive], locale: nil)
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
    }

    private static func isLatinOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
    }

    private static func editDistance(_ lhs: [Unicode.Scalar], _ rhs: [Unicode.Scalar]) -> Int {
        var previous = Array(0...rhs.count)
        for (i, left) in lhs.enumerated() {
            var current = [i + 1]
            for (j, right) in rhs.enumerated() {
                current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (left == right ? 0 : 1)))
            }
            previous = current
        }
        return previous[rhs.count]
    }

    static func overlayItems(_ regions: [Self], imageSize: CGSize) -> [BrowserOverlayItem] {
        let kept = keepsOriginalLettering(regions)
        return regions.enumerated().compactMap { index, region in
            kept[index] ? nil : region.overlayItem(index: index, imageSize: imageSize)
        }
    }

    /// The layout input: painted captions plus the kept source lettering, which
    /// the planner reserves and the overlay protects (never typeset or erased).
    static func layoutItems(_ regions: [Self], imageSize: CGSize) -> [BrowserOverlayItem] {
        let kept = keepsOriginalLettering(regions)
        return regions.enumerated().compactMap { index, region in
            kept[index] ? nil : region.overlayItem(index: index, imageSize: imageSize)
        } + regions.enumerated().compactMap { index, region in
            kept[index] && region.translation != nil
                ? region.overlayItem(index: index, imageSize: imageSize, keepsSourceLettering: true) : nil
        }
    }

    func overlayItem(index: Int, imageSize: CGSize, keepsSourceLettering: Bool = false) -> BrowserOverlayItem {
        BrowserOverlayItem(
            stableRegionID: UInt64(index),
            rect: CGRect(x: rect.minX * imageSize.width, y: rect.minY * imageSize.height,
                         width: rect.width * imageSize.width, height: rect.height * imageSize.height),
            sourceText: source, translatedText: translation, confidence: confidence,
            sourceOrientation: sourceOrientation, sourceSingleVerticalColumn: sourceSingleVerticalColumn,
            translationReuseIdentity: translationReuseIdentity,
            sourcePolygon: polygon.map { CGPoint(x: $0.x * imageSize.width, y: $0.y * imageSize.height) },
            auxiliaryInkRects: auxiliaryInkRects.map { CGRect(x: $0.minX * imageSize.width, y: $0.minY * imageSize.height,
                width: $0.width * imageSize.width, height: $0.height * imageSize.height) },
            auxiliaryInkPolygons: auxiliaryInkPolygons.map { $0.map { CGPoint(x: $0.x * imageSize.width, y: $0.y * imageSize.height) } },
            balloonInterior: balloonInterior,
            unitMemberRects: unitMemberRects.map {
                CGRect(x: $0.minX * imageSize.width, y: $0.minY * imageSize.height,
                       width: $0.width * imageSize.width, height: $0.height * imageSize.height)
            },
            keepsSourceLettering: keepsSourceLettering,
            recoveredLine: isRecoveredLine
        )
    }
}

enum ReaderTranslationGeometry {
    // UIView derives bounds from frame/center arithmetic. Fractional webtoon
    // heights can differ by a few ULPs without any actual viewport change.
    static func sameViewport(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        abs(lhs.width - rhs.width) < 0.000_001 && abs(lhs.height - rhs.height) < 0.000_001
    }

    static func displayRect(_ rect: CGRect, imageSize: CGSize, bounds: CGRect, aspectFit: Bool) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        var canvas = bounds
        if aspectFit {
            let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
            canvas = CGRect(
                x: bounds.midX - imageSize.width * scale / 2,
                y: bounds.midY - imageSize.height * scale / 2,
                width: imageSize.width * scale,
                height: imageSize.height * scale
            )
        }
        return CGRect(
            x: canvas.minX + rect.minX * canvas.width,
            y: canvas.minY + rect.minY * canvas.height,
            width: rect.width * canvas.width,
            height: rect.height * canvas.height
        )
    }
}

@available(iOS 18.0, *)
actor ReaderOCRService {
    static let shared = ReaderOCRService()
    private let gate = TranslationProviderRequestLimiter(maximumConcurrentRequests: 1)
    private var pipeline: NativeCoreMLOCRPipeline?
    private let layoutDetector: NativeRFDETRLayoutDetector
    private let rawCanonicalLayoutDetector: NativeRFDETRLayoutDetector?

    init() {
        let auxiliary = NativeRFDETRLayoutResource.auxiliaryOCR
        let canonical = NativeRFDETRLayoutResource.rawCanonicalOCR
        layoutDetector = Self.makeLayoutDetector(auxiliary)
        // Both roles resolve through the same bundle, installed-model store and decoder.
        // When their complete requests match, the first result already belongs to this OCR call.
        rawCanonicalLayoutDetector = NativeRFRawCachePolicy.enabled && auxiliary == canonical
            ? nil : Self.makeLayoutDetector(canonical)
    }

    private static func makeLayoutDetector(_ producer: NativeRFDETRLayoutResource.OCRProducer) -> NativeRFDETRLayoutDetector {
        NativeRFDETRLayoutDetector(maximumMaskQueries: producer.maximumMaskQueries, retainAllQueryMasks: producer.retainAllQueryMasks,
            expectedWeightsSHA256: producer.weightsSHA256, expectedSourceRevision: producer.revision, resolveModelURL: {
                try await Task.detached(priority: .utility) {
                    try NativeCoreMLModelStore.shared.modelURL(for: producer.modelURL())
                }.value
            })
    }
    // Separate DET-only cold-cache lifecycle: never constructs/prepares REC.
    private var probabilityOnlyDetector:NativeCoreMLDetector?
    private var probabilityOnlyConfiguration:ReaderOCRConfiguration?

    /// Existing OCR gate serializes fresh OCR and cold/cached probability ensure.
    /// The caller retains this local lease/snapshot through rendering.
    func ensureSourceProbability(original:CGImage,configuration:ReaderOCRConfiguration,
        allowOneCurrentDetector:Bool = true) async throws -> NativeMainEnsemblePreparedDB {
        try await gate.withPermit {
            try await NativeOCRDirectionGeometry.$mainMangaPolicy.withValue(configuration.modelTier == .manga) {
                try await self.ensureSourceProbabilitySerial(original:original,configuration:configuration,
                    allowOneCurrentDetector:allowOneCurrentDetector)
            }
        }
    }

    private func ensureSourceProbabilitySerial(original:CGImage,configuration:ReaderOCRConfiguration,
        allowOneCurrentDetector:Bool) async throws -> NativeMainEnsemblePreparedDB {
        try Task.checkCancellation()
        let source = try NativeMainEnsemblePreparedDB.SourceBinding(original: original)
        let store = NativeMainEnsembleEvidenceStore.shared
        let lease = try store.lease(source: source)
        var retained=false
        defer {if !retained {lease.release()}}
        let usingPipeline:NativeCoreMLOCRPipeline?
        let detector:NativeCoreMLDetector?
        if let pipeline, Self.sameDetector(loadedConfiguration, configuration) {
            usingPipeline=pipeline;detector=nil
        } else {
            usingPipeline=nil
            if probabilityOnlyDetector == nil || !Self.sameDetector(probabilityOnlyConfiguration, configuration) {
                await probabilityOnlyDetector?.purgeResources()
                let profile=NativeCoreMLOCRModelProfile.profile(for:configuration.modelTier)
                probabilityOnlyDetector=NativeCoreMLDetector(modelResourceName:profile.detectorResourceName,
                    maximumSide:configuration.detectorMaximumSide)
                probabilityOnlyConfiguration=configuration
            }
            detector=probabilityOnlyDetector
        }
        let postprocess=configuration.detectorPostprocessConfiguration
        let request: NativeCoreMLDetector.ProbabilityRequest
        if let usingPipeline {
            request=try await usingPipeline.prepareSourceProbabilityRequest(image:original,configuration:postprocess)
        } else {
            guard let detector,let frame=await NativeOCRCGImageAdapter.makeRGBAFrameOffMain(from:original) else {
                throw NativeMainEnsemblePreparedDB.Failure.requiredDBUnavailable
            }
            request=try await detector.prepareProbabilityRequest(frame:frame,configuration:postprocess)
        }
        let metadata = request.expectation
        guard metadata.producer.resizedWidth<=original.width,metadata.producer.resizedHeight<=original.height else {
            throw NativeMainEnsembleDBCapability.Failure.upsampled
        }
        let expected=NativeMainEnsembleDBCapability.Key(source:.init(canonicalIdentity:source.identity,
            detectorInputIdentity:metadata.detectorInputIdentity,width:original.width,height:original.height),producer:metadata.producer)
        if let resident = try store.currentPreparedProbability(source: source, expected: expected, lease: lease,
                                                               consumerConfigurationSHA256: metadata.consumerConfigurationSHA256) {
            retained = true
            ReaderTranslationDiagnostics.record("render_db_current_hit", count: 0)
            return resident
        }
        var captured:NativeMainAOTRemovalMaskBuilder.SourceProbability?
        let resolution=try await NativeMainEnsembleDBCapability.resolve(expected:expected,
            resident:nil,replay:nil,allowOneCurrentDetector:allowOneCurrentDetector) {
            let capture=NativeMainEnsembleDBCapture()
            let observer = NativeMainEnsembleOCRProbability.observer(source: source, register: { try capture.store($0) })
            try await request.observe({ sample in
                let report = observer(sample)
                capture.record(report)
                return report
            }, { try Task.checkCancellation() })
            let actual=try capture.take()
            guard let record=actual.capability else {throw NativeMainEnsemblePreparedDB.Failure.observerUnavailable}
            // Authored only AFTER this actual DET callback. No historical rebranding.
            let fresh=NativeMainEnsembleDBCapability.Record(source:record.source,producer:record.producer,
                grid:record.grid,mapSHA256:record.mapSHA256,origin:.freshCurrentDetector,
                consumerConfigurationSHA256:record.consumerConfigurationSHA256)
            captured = .init(original:original,width:actual.width,height:actual.height,values:actual.values,capability:fresh)
            return fresh
        }
        guard let probability=captured else {
            throw NativeMainEnsemblePreparedDB.Failure.requiredDBUnavailable
        }
        try Task.checkCancellation()
        try store.register(probability: probability, source: source)
        let result=try NativeMainEnsemblePreparedDB(probability:probability,source:source,expected:expected,
            detectorCalls:resolution.detectorCalls,lease:lease,
            currentConsumerConfigurationSHA256:metadata.consumerConfigurationSHA256)
        retained=true
        ReaderTranslationDiagnostics.record("render_db_one_det_fallback",count:resolution.detectorCalls)
        return result
    }

    private var loadedConfiguration: ReaderOCRConfiguration?
    private var pipelineEpoch: UInt64 = 0
    private var warmUpTask: Task<Void, Never>?
    private var warmUpID: UUID?
    private(set) var lastPhaseMilliseconds: [String: Double] = [:]

    func recognize(image: CGImage, tier: IPhoneOCRModelTier) async throws -> [ReaderTranslationRegion] {
        try await recognize(image: image, configuration: ReaderOCRConfiguration(modelTier: tier))
    }

    func recognize(image: CGImage, configuration: ReaderOCRConfiguration) async throws -> [ReaderTranslationRegion] {
        let queuedAt = ProcessInfo.processInfo.systemUptime
        return try await gate.withPermit {
            TranslationPerformanceFileLog.record(.ocrQueue, fields: [
                .elapsedMilliseconds: TranslationPerformanceDiagnostics.elapsedMilliseconds(since: queuedAt)
            ])
            guard configuration.modelTier == .manga else {
                return try await self.recognizeSerial(image: image, configuration: configuration)
            }
            let sourceReuse = NativeRFOCRSourceReuse(original: image)
            defer { sourceReuse.close() }
            return try await NativeRFOCRSourceReuse.$active.withValue(sourceReuse) {
                try await self.recognizeSerial(image: image, configuration: configuration)
            }
        }
    }

    /// Saved OCR already owns its regions. Refresh only RF evidence after regrouping;
    /// never recognize text again or reapply final-owner admission.
    func refreshingPostLLMEvidence(regions: [ReaderTranslationRegion], image: CGImage) async throws -> [ReaderTranslationRegion] {
        try Task.checkCancellation()
        let cleared = regions.map { region in
            var region = region
            region.postLLMContentEvidence = nil
            return region
        }
        // This refresh owns post-response classification evidence only.
        // Provider-direct comparison keeps sourceRoleEvidence, OCR owners and
        // the actual LLM request untouched, and avoids a dedicated RF refresh.
        // Fresh final4/postmerge admission still extracts its required signals.
        guard NativePostLLMContentReclassifier.activePolicy != .providerOnly else { return cleared }
        return try await gate.withPermit {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.environment["AIDOKU_DISABLE_RF_LAYOUT"] != "1",
                  ReaderTranslationSession.processAvailableMemory() >= TranslationImageWorkBudget.minimumHeadroom else {
                return cleared
            }
            do {
                let layout = try await self.layoutDetector.detect(image: image)
                try Task.checkCancellation()
                let refreshed = NativeFinalOutputContentFilter.attachingEvidence(cleared, layout: layout)
                try Task.checkCancellation()
                return refreshed
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                ReaderTranslationDiagnostics.record("post_llm_rf_layout_fallback")
                return cleared
            }
        }
    }

    private static func sameDetector(_ lhs: ReaderOCRConfiguration?, _ rhs: ReaderOCRConfiguration) -> Bool {
        lhs?.modelTier == rhs.modelTier && lhs?.detectorMaximumSide == rhs.detectorMaximumSide
    }

    private static func sameModels(_ lhs: ReaderOCRConfiguration?, _ rhs: ReaderOCRConfiguration) -> Bool {
        sameDetector(lhs, rhs) && lhs?.recognizerMaximumWidth == rhs.recognizerMaximumWidth
    }

    /// Callers hold `gate`: replacement awaits the old pipeline's purge.
    private func currentPipeline(for configuration: ReaderOCRConfiguration) async -> NativeCoreMLOCRPipeline {
        if let pipeline, Self.sameModels(loadedConfiguration, configuration) { return pipeline }
        await pipeline?.purgeResources()
        // A saved-page probability miss may already have loaded this exact detector.
        // Transfer ownership so the full pipeline keeps its resident Core ML handle.
        var existingDetector: NativeCoreMLDetector?
        if Self.sameDetector(probabilityOnlyConfiguration, configuration) {
            existingDetector = probabilityOnlyDetector
            probabilityOnlyDetector = nil
            probabilityOnlyConfiguration = nil
        }
        let created = NativeCoreMLOCRPipeline(
            modelTier: configuration.modelTier, detectorMaximumSide: configuration.detectorMaximumSide,
            recognizerMaximumWidth: configuration.recognizerMaximumWidth, existingDetector: existingDetector
        )
        pipeline = created
        loadedConfiguration = configuration
        pipelineEpoch &+= 1
        return created
    }

    /// Loads the OCR models for `configuration` in the background so the first
    /// page does not pay detector + recognizer model load. Idempotent (one
    /// in-flight warm-up; resident models return immediately), low priority,
    /// and it never holds `gate` while loading: real OCR coalesces with, and
    /// escalates, the shared model loads. Skipped under memory pressure; it
    /// loads only the models the first OCR frame would load anyway.
    func warmUp(configuration: ReaderOCRConfiguration) {
        guard warmUpTask == nil,
              ReaderTranslationSession.processAvailableMemory() >= TranslationImageWorkBudget.minimumHeadroom
        else { return }
        let id = UUID()
        warmUpID = id
        warmUpTask = Task(priority: .utility) {
            await self.performWarmUp(configuration: configuration)
            self.finishWarmUp(id)
        }
    }

    private func finishWarmUp(_ id: UUID) {
        guard warmUpID == id else { return }
        warmUpTask = nil
        warmUpID = nil
    }

    func cancelWarmUp() {
        warmUpTask?.cancel()
        warmUpTask = nil
        warmUpID = nil
    }

    private func performWarmUp(configuration: ReaderOCRConfiguration) async {
        let target: NativeCoreMLOCRPipeline
        if let pipeline, Self.sameModels(loadedConfiguration, configuration) {
            target = pipeline
        } else {
            guard let created = try? await gate.withPermit({
                await self.currentPipeline(for: configuration)
            }) else { return }
            target = created
        }
        let epoch = pipelineEpoch
        guard !Task.isCancelled else { return }
        do {
            try await target.warmUp()
            ReaderTranslationDiagnostics.record("ocr_warmup_end")
        } catch {
            ReaderTranslationDiagnostics.record("ocr_warmup_cancelled")
        }
        // A purge or configuration change during warm-up orphaned `target`;
        // release anything it admitted instead of waiting for deallocation.
        if epoch != pipelineEpoch || pipeline !== target {
            await target.purgeResources()
        }
    }

    private func recognizeSerial(image: CGImage, configuration: ReaderOCRConfiguration) async throws -> [ReaderTranslationRegion] {
        try Task.checkCancellation()
        let pipeline = await currentPipeline(for: configuration)
        // Pass the complete source once. The detector owns aspect-preserving
        // resize and maps detections back to original-image coordinates.
        ReaderTranslationDiagnostics.record("ocr_begin")
        // RF text scopes are available for the FIRST OCR recognition pass.
        // Both models remain serialized under the existing image admission slot.
        let auxiliaryLayout: NativeRFDETRLayoutResult?
        if ProcessInfo.processInfo.environment["AIDOKU_DISABLE_RF_LAYOUT"] != "1",
           ReaderTranslationSession.processAvailableMemory() >= TranslationImageWorkBudget.minimumHeadroom {
            do {
                auxiliaryLayout = try await layoutDetector.detect(image: image)
                ReaderTranslationDiagnostics.record("rf_layout_end", count: auxiliaryLayout?.primitives.count ?? 0)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                auxiliaryLayout = nil
                ReaderTranslationDiagnostics.record("rf_layout_fallback")
            }
        } else {
            auxiliaryLayout = nil
            ReaderTranslationDiagnostics.record("rf_layout_skipped")
        }
        try Task.checkCancellation()
        // This is the upright ORIGINAL CG object entering OCR, not DeviceRGB frame bytes.
        let boundProbability: NativeMainEnsembleOCRProbability.Observer? =
            (NativeMainEnsembleRenderer.enabled || NativeOCRRFGapRecovery.runtimeEnabled)
                ? NativeMainEnsembleOCRProbability.fullPageObserver(original: image) : nil
        let probabilityContext = ReaderTranslationDiagnostics.context
        let probabilityObserver: NativeMainEnsembleOCRProbability.Observer? = boundProbability.map { bound in
            { @Sendable sample in
                let report = bound(sample)
                ReaderTranslationDiagnostics.record("ocr_probability_" + report.status.rawValue,
                    count: report.registered ? sample.values.count : 0, context: probabilityContext)
                return report
            }
        }
        let rawCanonicalLayout: NativeRFDETRLayoutResult?
        if configuration.modelTier == .manga, auxiliaryLayout != nil, let rawCanonicalLayoutDetector {
            rawCanonicalLayout = try await rawCanonicalLayoutDetector.detect(image: image)
        } else { rawCanonicalLayout = nil }
        try Task.checkCancellation()
        let result = try await pipeline.recognize(
            image: image, requestID: UUID().uuidString,
            confidenceThreshold: configuration.confidenceThreshold,
            detectorConfiguration: configuration.detectorPostprocessConfiguration,
            probabilityObserver: probabilityObserver,
            rfLayout: rawCanonicalLayout ?? auxiliaryLayout
        )
        try Task.checkCancellation()
        ReaderTranslationDiagnostics.record("ocr_end", count: result.lines.count)
        // Also release when the raw canonical path was not entered.
        NativeRFOCRSourceReuse.active?.releasePixels()
        TranslationPerformanceFileLog.record(.ocrFrame, fields: [.elapsedMilliseconds: result.frameConversionMilliseconds])
        TranslationPerformanceFileLog.record(.ocrDetection, fields: [.elapsedMilliseconds: result.detectionMilliseconds])
        TranslationPerformanceFileLog.record(.ocrRecognition, fields: [.elapsedMilliseconds: result.recognitionMilliseconds])
        let postprocessStartedAt = ProcessInfo.processInfo.systemUptime
        if let auxiliaryLayout { NativeMainEnsembleEvidenceStore.shared.register(rf: auxiliaryLayout) }
        let representatives = NativeOCRLegacyComplementFilter.representatives(result.lines, width: result.width, height: result.height)
        var lines = NativeOCRAcceptedSource.bindingPrimary(representatives, width: result.width, height: result.height)
        let simpleParagraphRoute = NativeParagraphFragmentGrouping.simpleGroupingEnabled
        // Only incumbent grouping substitutes its stable layout view. SIMPLE
        // reads the literal accepted native extents and keeps their source table.
        if !simpleParagraphRoute { lines = lines.map { line -> NativeCoreMLOCRLine in
            guard let membership=line.acceptedSource.membership,membership.body.count == 1,
                  let index=membership.body.first,
                  let layout=membership.table.packets[index].layoutPolygon,
                  layout.count == 4,layout.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return line }
            return NativeCoreMLOCRLine(polygon:layout,text:line.text,score:line.score,
                orientation:line.orientation,orientationIsEstimated:line.orientationIsEstimated,
                sourceTileBounds:line.sourceTileBounds,erasurePolygons:line.erasurePolygons,
                detectorSeedEvidence:line.detectorSeedEvidence,acceptedSource:line.acceptedSource)
        } }
        let rfGapMilliseconds: Double = 0
        let lineCount = lines.count + result.recoveryCandidates.count + result.isolatedLines.count + result.splitLines.count
        let separator = !simpleParagraphRoute && lineCount >= 2 ? NativeOCRRegionSeparator(image: image) : nil
        // Text in two different enclosed light components (neighbouring balloons or caption
        // boxes), or in a balloon and on the artwork beside it, belongs to separate utterances.
        // A lone isolated line still needs it too: it qualifies only on open paper.
        let enclosure = !simpleParagraphRoute && (lineCount >= 2 || !result.isolatedLines.isEmpty)
            ? ReaderTranslationEnclosedBackground.ComponentMap(image: image) : nil
        let sourceBounds = (lines + result.recoveryCandidates + result.isolatedLines + result.splitLines)
            .compactMap { NativeOCRScopeGeometry.bounds(for: $0.polygon) }
        let layoutOwnership = simpleParagraphRoute ? nil : auxiliaryLayout.map {
            NativeRFDETRLayoutApplication.independentBalloonOwnership(sourceBounds: sourceBounds, result: $0)
        }
        var phases: [String: Double] = ["native": result.totalMilliseconds, "ocrPasses": 1,
                                        "rowSplit": result.stackedRowSplitMilliseconds,
                                        "unit": result.unitMilliseconds, "unitLines": Double(result.unitLineCount)]
        if NativeOCRRFGapRecovery.runtimeEnabled {
            phases["rfGap"] = rfGapMilliseconds
            phases["rfGapAccepted"] = Double(lines.count - representatives.count)
        }
        if let auxiliaryLayout {
            phases["rfLayoutModel"] = auxiliaryLayout.modelMilliseconds
            phases["rfLayoutPreprocess"] = auxiliaryLayout.preprocessingMilliseconds
            phases["rfLayoutDecode"] = auxiliaryLayout.decodeMilliseconds
            phases["rfLayoutOwnerPixelTests"] = Double(layoutOwnership?.verifiedPixelTests ?? 0)
        }
        if let raw = result.rawCanonicalReceipt {
            phases["rawCanonicalGenerated"] = Double(raw.generated)
            phases["rawCanonicalBBoxAdmitted"] = Double(raw.bboxAdmitted)
            phases["rawCanonicalPreRECAdmitted"] = Double(raw.preRecognitionAdmitted)
            phases["rawCanonicalRecognized"] = Double(raw.recognized)
            phases["rawCanonicalRetained"] = Double(raw.retained)
            phases["rawCanonicalDETThreshold"] = raw.detectorThreshold
            phases["rawCanonicalRECThreshold"] = raw.recognitionThreshold
        }
        var joined: [ReaderTranslationRegion]
        var layoutMergeDecisions: [String: Int] = [:]
        if simpleParagraphRoute {
            // This is a replacement, not a late correction after all legacy
            // families. No candidate recovery, pixel separator or lexical pass
            // runs here; the common final filter/role/cache path follows below.
            let started = ProcessInfo.processInfo.systemUptime
            let grouped = try NativeParagraphFragmentGrouping.simpleNativeResult(lines, width: result.width, height: result.height,
                scopes: (auxiliaryLayout?.primitives ?? []).compactMap {
                    $0.semanticClass == .text ? .init(owner: $0.queryID, box: $0.normalizedBounds, confidence: Double($0.confidence)) : nil
                }, balloons: (auxiliaryLayout?.primitives ?? []).compactMap {
                    $0.semanticClass == .balloon ? .init(owner: $0.queryID, box: $0.normalizedBounds, confidence: Double($0.confidence)) : nil
                })
            joined = grouped.regions
            phases["simpleParagraph"] = (ProcessInfo.processInfo.systemUptime-started)*1000
            phases["simpleParagraphInputAtoms"] = Double(grouped.inputAtoms)
            phases["simpleParagraphOutputOwners"] = Double(grouped.outputOwners)
            phases["simpleParagraph."+grouped.outcome.rawValue] = 1
            phases["simpleParagraphBypassedLegacy"] = 1
            phases["simpleParagraphRecoveryCandidatesNotAdmitted"] = Double(result.recoveryCandidates.count+result.isolatedLines.count+result.splitLines.count+result.gapLines.count)
            lastPhaseMilliseconds = phases
            ReaderTranslationDiagnostics.record("simple_paragraph_"+grouped.outcome.rawValue, count: joined.count)
        } else {
        let wordStart = ProcessInfo.processInfo.systemUptime
        let wordCandidates = NativeOCRTextLineMerger.latinWordCandidates(lines)
        let recognizedWords: Set<String>
        if wordCandidates.isEmpty {
            recognizedWords = []
        } else {
            recognizedWords = await ReaderOCRWordBoundaryResolver.recognizedWords(in: wordCandidates)
        }
        try Task.checkCancellation()
        phases["wordBoundary"] = (ProcessInfo.processInfo.systemUptime - wordStart) * 1000
        let mergeStart = ProcessInfo.processInfo.systemUptime
        // Cache even inconclusive colour samples: each candidate rectangle is sampled once.
        var inkSamples: [NSValue: [Double]] = [:]
        func ink(_ rect: CGRect) -> [Double] {
            let key = NSValue(cgRect: rect)
            if let cached = inkSamples[key] { return cached }
            let sample = ReaderTranslationBalloonMerger.outlinedInk(in: image, rect: rect)
            let value = sample.map { [$0.0, $0.1, $0.2] } ?? []
            inkSamples[key] = value
            return value
        }
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let relaxSharedOwnerOutlinedGap = ProcessInfo.processInfo.environment["AIDOKU_RF_OWNER_RELAX_OUTLINED_GAP"] == "1"
        func separated(_ a: CGRect, _ b: CGRect, _ orientation: BrowserOCRSourceOrientation) -> Bool {
            var sharesResolvedBalloon = false
            if let layoutOwnership, let auxiliaryLayout {
                let decision = layoutOwnership.mergeDecision(first: a, second: b,
                    imageIdentity: auxiliaryLayout.imageIdentity)
                layoutMergeDecisions["outcome." + decision.outcome, default: 0] += 1
                layoutMergeDecisions["first." + decision.first.kind, default: 0] += 1
                layoutMergeDecisions["second." + decision.second.kind, default: 0] += 1
                // A shared model owner is NOT permission to join: all original
                // native direction, gutter, source-style and speaker gates follow.
                if decision.veto { return true }
                sharesResolvedBalloon = decision.outcome == "sameOwner"
            }
            if orientation == .vertical {
                let first = ink(a), second = ink(b)
                if first.count == 3, second.count == 3 {
                    if zip(first, second).contains(where: { abs($0 - $1) >= 70 }) { return true }
                    // Outlined captions on artwork have observable gutters,
                    // even when recognition drops every quotation mark.
                    let gap = max(a.minX, b.minX) - min(a.maxX, b.maxX)
                    if gap >= min(a.width, b.width) * 0.3 {
                        // Shared ownership only removes this gap-only veto. Native
                        // gutter, speaker, geometry, style, separator and enclosure
                        // checks still decide whether an actual join is admissible.
                        guard relaxSharedOwnerOutlinedGap && sharesResolvedBalloon else { return true }
                        layoutMergeDecisions["sharedOwnerOutlinedGapRelaxed", default: 0] += 1
                    }
                }
            }
            if separator?.separates(a, b, orientation: orientation) == true { return true }
            return enclosure?.separates(a, b) ?? false
        }
        // Recovery regroups the same lines, and pairwise merging compares each line more than
        // once. Keep both conclusive and inconclusive samples for this page only, avoiding
        // repeated image crops/rasterization without extending image lifetime beyond OCR.
        // Each cache retains at most 256 scalar samples, including merged candidate boxes.
        var textInkSamples: [NSValue: (Double, Double, Double)?] = [:]
        var darkSamples: [NSValue: Double?] = [:]
        func textInk(_ rect: CGRect) -> (Double, Double, Double)? {
            let key = NSValue(cgRect: rect)
            if let cached = textInkSamples[key] { return cached }
            let value = ReaderTranslationBalloonMerger.textInk(in: image, rect: rect)
            if textInkSamples.count < 256 { textInkSamples[key] = .some(value) }
            return value
        }
        func darkFraction(_ rect: CGRect) -> Double? {
            let key = NSValue(cgRect: rect)
            if let cached = darkSamples[key] { return cached }
            let value = ReaderTranslationBalloonMerger.darkFraction(in: image, rect: rect)
            if darkSamples.count < 256 { darkSamples[key] = .some(value) }
            return value
        }
        func group(_ lines: [NativeCoreMLOCRLine]) -> [ReaderTranslationRegion] {
            let columns = lines.enumerated().compactMap { index, line -> NativeIndependentColumnCohorts.Column? in
                guard (3...16).contains(line.polygon.count), line.polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
                      line.orientation == .vertical, line.text.count >= 3, line.text.unicodeScalars.lazy.filter({ CharacterSet.letters.contains($0) }).count >= 2 else { return nil }
                let xs=line.polygon.map(\.x), ys=line.polygon.map(\.y)
                guard let minX=xs.min(), let maxX=xs.max(), let minY=ys.min(), let maxY=ys.max() else { return nil }
                return .init(id:index,box:CGRect(x:minX,y:minY,width:maxX-minX,height:maxY-minY))
            }
            let boundaries = NativeIndependentColumnCohorts.boundaries(columns:columns) { a,b,font in
                NativeOutlinedLobeProof.inspect(image:image,first:a,second:b,glyph:font) != nil
            }
            let merged = NativeOCRTextLineMerger.merge(
                lines, imageWidth: image.width, imageHeight: image.height, recognizedLatinWords: recognizedWords,
                separationCheck: { a,b,orientation in
                    if orientation == .vertical, NativeIndependentColumnCohorts.separates(a,b,boundaries:boundaries) { return true }
                    return separated(a,b,orientation)
                },
                inkContrast: {
                    guard let a = textInk($0), let b = textInk($1) else { return false }
                    return max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2)) >= 100
                },
                polarityContrast: {
                    guard let a = darkFraction($0), let b = darkFraction($1) else { return false }
                    return max(a, b) >= 0.3 && min(a, b) <= 0.15
                }
            )
            let regions: [ReaderTranslationRegion] = merged.enumerated().compactMap { index, line in
                let rect = line.boundingRect.intersection(imageBounds)
                let source = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !rect.isNull, !rect.isEmpty, !source.isEmpty else { return nil }
                var region = ReaderTranslationRegion(
                    id: "region-\(index)",
                    rect: CGRect(
                        x: rect.minX / imageBounds.width, y: rect.minY / imageBounds.height,
                        width: rect.width / imageBounds.width, height: rect.height / imageBounds.height
                    ),
                    source: source,
                    polygon: line.poly.map { CGPoint(x: $0.x / imageBounds.width, y: $0.y / imageBounds.height) },
                    confidence: line.score, sourceImageAspectRatio: Double(image.width) / Double(image.height),
                    sourceOrientation: line.sourceOrientation,
                    sourceSingleVerticalColumn: line.singleVerticalColumn,
                    auxiliaryInkRects: line.auxiliaryInkRects.map { $0.intersection(imageBounds) }.filter { !$0.isNull && !$0.isEmpty }.map {
                        CGRect(x: $0.minX / imageBounds.width, y: $0.minY / imageBounds.height,
                               width: $0.width / imageBounds.width, height: $0.height / imageBounds.height)
                    },
                    auxiliaryInkPolygons: line.auxiliaryInkPolygons.map {
                        $0.map { CGPoint(x: $0.x / imageBounds.width, y: $0.y / imageBounds.height) }
                    },
                    detectorSeedEvidence: line.detectorSeedEvidence
                )
                region.acceptedSource = line.acceptedSource
                return region
            }
            return ReaderTranslationBalloonMerger.apply(
                regions, image: image,
                sourceLines: lines.map { .init(polygon: $0.polygon, text: $0.text, orientation: $0.orientation) }, enclosure: enclosure)
        }
        joined = group(lines)
        phases["mergeAndSeparator"] = (ProcessInfo.processInfo.systemUptime - mergeStart) * 1000
        lastPhaseMilliseconds = phases
        try Task.checkCancellation()
        let balloonStart = ProcessInfo.processInfo.systemUptime
        // Adjacent-line recovery completes a caption only: the base grouping is kept unless a recovered
        // line extends exactly one caption without crowding its neighbours.
        let separates: (CGRect, CGRect, BrowserOCRSourceOrientation) -> Bool = { a, b, orientation in
            separator?.separates(a, b, orientation: orientation) == true || enclosure?.separates(a, b) == true
        }
        let recovered = NativeOCRAdjacentLineRecovery.admitted(result.recoveryCandidates, anchors: lines, separates: separates)
        // A gap line may also join the captions of its two flanks: it completes their reading order.
        // So may a recovered line with an accepted sibling on each side.
        let gaps = NativeOCRGapLineRecovery.admitted(result.gapLines, separates: separates)
        let bridges = gaps + NativeOCRGapLineRecovery.admitted(NativeOCRGapLineRecovery.bridges(recovered, lines: lines),
                                                               separates: separates)
        // Isolated lines (a whole utterance read just under the gate) qualify only on open paper: over artwork the
        // erase would need a plate over the art. One beside an accepted line of its caption completes that caption
        // like a recovered line; the others become captions of their own after the balloon join (below).
        let isolated = result.isolatedLines.filter { line in
            guard let bounds = NativeOCRScopeGeometry.bounds(for: line.polygon) else { return false }
            return enclosure?.onOpenPaper(bounds) == true
        }
        let beside = isolated.filter { line in
            guard let bounds = NativeOCRScopeGeometry.bounds(for: line.polygon) else { return false }
            return lines.contains { anchor in
                guard NativeOCRAdjacentLineRecovery.isAdjacent(line.polygon, to: anchor.polygon),
                      let anchorBounds = NativeOCRScopeGeometry.bounds(for: anchor.polygon),
                      let direction = NativeOCRAdjacentLineRecovery.axis(anchor.polygon)?.direction else { return false }
                return !separates(anchorBounds, bounds, abs(direction.y) > abs(direction.x) ? .vertical : .horizontal)
            }
        }
        if !recovered.isEmpty || !gaps.isEmpty || !beside.isEmpty {
            joined = NativeOCRAdjacentLineRecovery.extending(joined, with: group(lines + recovered + beside + gaps.map(\.line)),
                                                             baseLines: lines, recovered: recovered + beside + gaps.map(\.line),
                                                             bridges: bridges, imageBounds: imageBounds, inkContrast: {
                let foreground = $0, background = $1
                // Sample the sign outside the recovered foreground column.
                // Otherwise its few dark glyph pixels can masquerade as the
                // sign's own ink and veto a valid gap completion.
                let overlap = foreground.intersection(background)
                let sample: CGRect
                if !overlap.isNull, !overlap.isEmpty {
                    let strips = [
                        CGRect(x: background.minX, y: background.minY, width: overlap.minX - background.minX, height: background.height),
                        CGRect(x: overlap.maxX, y: background.minY, width: background.maxX - overlap.maxX, height: background.height),
                        CGRect(x: background.minX, y: background.minY, width: background.width, height: overlap.minY - background.minY),
                        CGRect(x: background.minX, y: overlap.maxY, width: background.width, height: background.maxY - overlap.maxY)
                    ]
                    guard let strip = strips.max(by: { $0.width * $0.height < $1.width * $1.height }),
                          strip.width * strip.height >= background.width * background.height * 0.4 else { return false }
                    sample = strip
                } else { sample = background }
                guard let a = textInk(foreground) else { return false }
                if let b = textInk(sample) {
                    return max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2)) >= 100
                }
                // A faded sign may have no high-contrast ink bin at all.
                // Certify that its remaining pixels contain none of the dark
                // strokes which occupy a meaningful part of the recovered line.
                return max(a.0, a.1, a.2) < 80 && (darkFraction(foreground) ?? 0) >= 0.08
                    && (darkFraction(sample) ?? 1) < 0.01
            })
        }
        // One enclosed balloon is translated as one unit (fragments, tails, ruby, split blocks). The join runs once,
        // after recovery: both recovery groupings above then compare the same line merge, and a recovered or gap
        // line completes its column before the balloon's blocks are joined (diverse2-2918).
        if let enclosure {
            joined = ReaderTranslationBalloonMerger.joinBalloonUnits(
                joined, image: image, enclosure: enclosure,
                sourceLines: lines.map { .init(polygon: $0.polygon, text: $0.text, orientation: $0.orientation) }, separates: separated)
        }
        // The remaining isolated lines become captions of their own, after the balloon join: they never join, split
        // or overlap a caption above, so no unit grows across a balloon's open side.
        let alone = isolated.filter { line in
            guard let bounds = NativeOCRScopeGeometry.bounds(for: line.polygon) else { return false }
            let center = CGPoint(x: bounds.midX / imageBounds.width, y: bounds.midY / imageBounds.height)
            return !joined.contains { $0.rect.contains(center) }
        }
        // Rows of a split lettering stack form their own captions the same way.
        if !alone.isEmpty || !result.splitLines.isEmpty {
            joined += NativeOCRIsolatedLineRecovery.captions(group(alone + result.splitLines), beside: joined)
        }
        lastPhaseMilliseconds["balloonMerge"] = (ProcessInfo.processInfo.systemUptime - balloonStart) * 1000
        try Task.checkCancellation()
        // The balloon around each caption, from the same component map: the overlay sizes a caption
        // alone in its balloon against that paper instead of its OCR column (no pixel work in WebKit).
        let interiorStart = ProcessInfo.processInfo.systemUptime
        joined = ReaderTranslationEnclosedBackground.attachingBalloonInteriors(joined, image: image, map: enclosure)
        let paragraphOwnerHints = joined
        let separateCaptionOwners = enclosure?.separateCaptionOwnerIndices(of: joined.map {
            CGRect(x: $0.rect.minX * imageBounds.width, y: $0.rect.minY * imageBounds.height,
                   width: $0.rect.width * imageBounds.width, height: $0.rect.height * imageBounds.height)
        }) ?? []
        let captionSlotIDs = Set(separateCaptionOwners.map { joined[$0].id })
        let countBeforeChromaticJoin = joined.count
        joined = ReaderTranslationChromaticBalloon.applying(joined, image: image, preservingSourceSlots: captionSlotIDs)
        // A colored contour can complete a column whose fragments occupied different
        // light-paper patches. Give that completed column one bounded opportunity to
        // join its paragraph, using the same separation and enclosure guards.
        if joined.count < countBeforeChromaticJoin, let enclosure {
            let prior = Dictionary(joined.map { ($0.id, $0.rect) }, uniquingKeysWith: { first, _ in first })
            let completed = ReaderTranslationBalloonMerger.joinBalloonUnits(
                joined, image: image, enclosure: enclosure,
                sourceLines: lines.map { .init(polygon: $0.polygon, text: $0.text, orientation: $0.orientation) }, separates: separated)
            if completed.count < joined.count {
                joined = completed
                let changed = joined.indices.filter { prior[joined[$0].id] != joined[$0].rect }
                let refreshed = ReaderTranslationEnclosedBackground.attachingBalloonInteriors(
                    changed.map { joined[$0] }, image: image, map: enclosure)
                let contours = ReaderTranslationChromaticBalloon.interiors(refreshed, image: image, preservingSourceSlots: captionSlotIDs)
                for (offset, index) in changed.enumerated() {
                    joined[index] = refreshed[offset]
                    if captionSlotIDs.contains(joined[index].id) {
                        joined[index].balloonInterior = nil
                    } else if let contour = contours[offset] { joined[index].balloonInterior = contour }
                }
            }
        }
        if ProcessInfo.processInfo.environment["AIDOKU_DISABLE_OVERLAP_GROUPING"] != "1" {
            joined = try NativeOverlappingSourceUnitGrouping.apply(joined, image: image, separates: separated)
        }
        lastPhaseMilliseconds["balloonInterior"] = (ProcessInfo.processInfo.systemUptime - interiorStart) * 1000
        // Cut-off fine print of a background document stays as printed art (kept lettering).
        joined = await ReaderTranslationNonContentText.markingOccludedDocumentText(joined)
        let lexicalContinuation = NativeJapaneseLexicalContinuationGrouping.applying(
            joined, width: imageBounds.width, height: imageBounds.height)
        joined = lexicalContinuation.regions
        joined = NativeParagraphFragmentGrouping.applying(
            joined, lines: lines, ownerHints: paragraphOwnerHints, image: image, separates: separated)
        // Transfer only independently measured round cores in its verified balloon;
        // semantic text and geometry remain unchanged, physical DB evidence survives.
        let sourceDotRails = NativeSourceDotRailOwnership.applying(
            joined, width: image.width, height: image.height, reader: { scope, width, height in
                try? NativeSourcePixelReader.draw(image: image, x: Double(scope.minX), y: Double(scope.minY),
                    sourceWidth: Double(scope.width), sourceHeight: Double(scope.height), width: width, height: height)
            })
        joined = sourceDotRails.regions
        if let auxiliaryLayout, ProcessInfo.processInfo.environment["AIDOKU_DISABLE_RF_BALLOON_CONTOURS"] != "1" {
            var modelContours = 0
            for index in joined.indices where joined[index].balloonInterior == nil {
                let region = joined[index]
                let normalized = region.unitMemberRects.isEmpty ? [region.rect] : region.unitMemberRects
                let sourceRects = normalized.map {
                    CGRect(x: $0.minX * imageBounds.width, y: $0.minY * imageBounds.height,
                           width: $0.width * imageBounds.width, height: $0.height * imageBounds.height)
                }
                guard let contour = NativeRFDETRLayoutApplication.balloonContour(sourceBounds: sourceRects,
                    result: auxiliaryLayout) else { continue }
                joined[index].balloonInterior = .init(rect: contour.rect, center: contour.center, spans: contour.spans,
                    contourVerified: false, modelEstimated: true)
                modelContours += 1
            }
            lastPhaseMilliseconds["rfBalloonModelContours"] = Double(modelContours)
        }
        // causal96-live-ordered-source-begin
        // Final original-source grouping, before ReaderTranslationService plans
        // provider requests or looks up translations. No saved revisions needed.
        if let auxiliaryLayout,
           ReaderTranslationOrderedSourceRoute.anyEnabled {
            let ordered = ReaderTranslationOrderedSourceRoute.apply(joined,
                imageSize: imageBounds.size,
                supports: auxiliaryLayout.primitives.compactMap { primitive in
                    guard primitive.semanticClass == .text || primitive.semanticClass == .soundEffect else { return nil }
                    return .init(queryID: primitive.queryID, isText: primitive.semanticClass == .text,
                        confidence: Double(primitive.confidence), normalizedBounds: primitive.normalizedBounds)
                }, enabled: ReaderTranslationOrderedSourceRoute.enabled,
                separates: { separated($0, $1, .vertical) },
                originalInk: { ReaderTranslationOrderedSourceRoute.originalNeutralGlyphInk($0, image: image) })
            joined = ordered.regions
            lastPhaseMilliseconds["orderedSourceJoinedGroups"] = Double(ordered.joinedGroups)
            lastPhaseMilliseconds["orderedSourceJoinedOwners"] = Double(ordered.joinedOwners)
            let intervals = ReaderTranslationOrderedSourceRoute.applySourceIntervals(joined,
                imageSize: imageBounds.size,
                supports: auxiliaryLayout.primitives.compactMap { primitive in
                    guard primitive.semanticClass == .text || primitive.semanticClass == .soundEffect else { return nil }
                    return .init(queryID: primitive.queryID, isText: primitive.semanticClass == .text,
                        confidence: Double(primitive.confidence), normalizedBounds: primitive.normalizedBounds)
                }, enabled: ReaderTranslationOrderedSourceRoute.sourceIntervalsEnabled,
                separates: { separated($0, $1, .vertical) },
                originalInk: { ReaderTranslationOrderedSourceRoute.originalNeutralGlyphInk($0, image: image) })
            joined = intervals.regions
            lastPhaseMilliseconds["sourceIntervalJoinedGroups"] = Double(intervals.joinedGroups)
            lastPhaseMilliseconds["sourceIntervalJoinedOwners"] = Double(intervals.joinedOwners)
        }
        // causal96-live-ordered-source-end
        if let auxiliaryLayout {
            let before = joined.count
            joined = NativeParagraphFragmentGrouping.reconcilingObservations(joined, scopes: auxiliaryLayout.primitives.compactMap {
                $0.semanticClass == .text ? .init(owner: $0.queryID, box: $0.normalizedBounds, confidence: Double($0.confidence)) : nil
            }, balloons: auxiliaryLayout.primitives.compactMap {
                $0.semanticClass == .balloon ? .init(owner: $0.queryID, box: $0.normalizedBounds, confidence: Double($0.confidence)) : nil
            })
            lastPhaseMilliseconds["reconciledSourceObservations"] = Double(before - joined.count)
        }
        } // Full incumbent grouping rollback; SIMPLE never enters these families.
        let finalOwners = NativeFinalOutputDuplicateResolver.applying(joined)
        joined = finalOwners.regions
        lastPhaseMilliseconds["finalOutputDuplicatesSuppressed"] = Double(finalOwners.suppressed)
        if let filteringLayout = rawCanonicalLayout ?? auxiliaryLayout {
            let before = joined.count
            joined = NativeFinalOutputContentFilter.applying(joined, layout: filteringLayout, auxiliaryLayout: auxiliaryLayout)
            lastPhaseMilliseconds["finalOutputContentSuppressed"] = Double(before - joined.count)
        }
        let complementOwners = NativeFinalOutputDuplicateResolver.applyingComplementOwners(joined)
        joined = complementOwners.regions
        lastPhaseMilliseconds["finalOutputComplementDuplicatesSuppressed"] = Double(complementOwners.suppressed)
        for (key, count) in layoutMergeDecisions {
            lastPhaseMilliseconds["rfMergeDecision." + key] = Double(count)
        }
        TranslationPerformanceFileLog.record(.ocrPostprocess, fields: [
            .segments: Double(joined.count),
            .elapsedMilliseconds: TranslationPerformanceDiagnostics.elapsedMilliseconds(since: postprocessStartedAt)
        ])
        try Task.checkCancellation()
        if NativeMainEnsembleRenderer.enabled {
            do {
                let evidenceSource = try NativeMainEnsemblePreparedDB.SourceBinding(ocrEvidenceOriginal: image)
                let binding = NativeMainEnsembleOCREvidence.liveBinding(source: evidenceSource)
                func auditEvidence(_ key: String) {
                    lastPhaseMilliseconds["mainOCREvidence." + key, default: 0] += 1
                }
                var stages: [NativeMainEnsembleOCREvidence.StageRows] = []
                func appendEvidence(_ stage: NativeMainEnsembleOCREvidence.StageRows) -> Bool {
                    do {
                        _ = try NativeMainEnsembleOCREvidence.Packet(binding: binding, stages: stages + [stage])
                        stages.append(stage)
                        return true
                    } catch {
                        auditEvidence(stage.stage.rawValue + ".packetBudgetFailure")
                        return false
                    }
                }
                do {
                    for stage in try result.ensembleStageSnapshot?.project(binding: binding, audit: auditEvidence) ?? [] {
                        _ = appendEvidence(stage)
                    }
                } catch { auditEvidence("snapshot.projectionFailure") }
                if result.ensembleStageSnapshot == nil { lastPhaseMilliseconds["mainOCRSnapshotUnavailable"] = 1 }
                do {
                    let native = try NativeOCREnsembleStageSnapshot.projectNativeLines(lines, binding: binding,
                        audit: { auditEvidence("nativeLines." + $0) })
                    if !appendEvidence(native) {
                        auditEvidence("nativeLines.missingGeometry")
                        _ = appendEvidence(try NativeOCREnsembleStageSnapshot.projectNativeLines(lines,
                            binding: binding, includeSeeds: false))
                    }
                } catch { auditEvidence("nativeLines.projectionFailure") }
                var seedBudget = NativeOCREnsembleStageSnapshot.SeedBudget()
                let rows: [[String: Any]] = joined.map { region in
                    var row: [String: Any] = ["id": region.id, "source": region.source,
                        "confidence": region.confidence,
                        "sourceOrientation": region.sourceOrientation.rawValue,
                        "rect": ["x": region.rect.minX, "y": region.rect.minY,
                                 "width": region.rect.width, "height": region.rect.height],
                        "polygon": region.polygon.map { [Double($0.x), Double($0.y)] },
                        "sourceMemberPolygons": region.sourceMemberPolygons.map { $0.map { [Double($0.x),Double($0.y)] } },
                        "unitMemberRects": region.unitMemberRects.map {
                            ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height]
                        }]
                    if let translated = region.translation { row["translation"] = translated }
                    if let vertical = region.sourceSingleVerticalColumn { row["sourceSingleVerticalColumn"] = vertical }
                    if let seeds = NativeOCREnsembleStageSnapshot.optionalSeedRows(region.detectorSeedEvidence,
                        budget: &seedBudget, audit: { auditEvidence("finalRegions." + $0) }) {
                        row["detectorSeedEvidence"] = seeds
                    }
                    row["sourceOCRAlternatives"] = region.sourceOCRAlternatives.map { alternative in
                        ["originalText": alternative.originalText, "exactReading": alternative.exactReading,
                         "paddedReading": alternative.paddedReading, "primaryConfidence": alternative.primaryConfidence,
                         "exactConfidence": alternative.exactConfidence, "paddedConfidence": alternative.paddedConfidence,
                         "rect": ["x": alternative.rect.minX, "y": alternative.rect.minY,
                                  "width": alternative.rect.width, "height": alternative.rect.height]] as [String: Any]
                    }
                    return row
                }
                do {
                    let projected = try NativeMainEnsembleOCREvidence.project(rows: rows, stage: .finalRegions,
                        space: .normalizedTopLeft, binding: binding)
                    if !appendEvidence(projected) {
                        auditEvidence("finalRegions.missingGeometry")
                        let baseRows = rows.map { row in
                            row.filter { !["detectorSeedEvidence", "sourceOCRAlternatives"].contains($0.key) }
                        }
                        _ = appendEvidence(try NativeMainEnsembleOCREvidence.project(rows: baseRows, stage: .finalRegions,
                            space: .normalizedTopLeft, binding: binding))
                    }
                } catch { auditEvidence("finalRegions.projectionFailure") }
                let packet = try NativeMainEnsembleOCREvidence.Packet(binding: binding, stages: stages)
                try NativeMainEnsembleEvidenceStore.shared.register(ocr: packet, original: image, source: evidenceSource)
                lastPhaseMilliseconds["mainOCREvidenceRows"] = Double(rows.count)
                lastPhaseMilliseconds["mainOCREvidenceStages"] = Double(stages.count)
            } catch is CancellationError { throw CancellationError() }
            catch {
                // OCR itself succeeded. Preserve its results while explicitly
                // recording that optional ensemble evidence could not be bound.
                lastPhaseMilliseconds["mainOCREvidenceRegistrationFailure"] = 1
            }
        }
        if let auxiliaryLayout {
            for index in joined.indices {
                joined[index].sourceRoleEvidence = NativeTranslationRoleEvidenceBuilder.make(
                    region: joined[index], imageIdentity: auxiliaryLayout.imageIdentity,
                    layout: auxiliaryLayout, ownership: layoutOwnership)
            }
        }
        return joined
    }


    func purge() async {
        cancelWarmUp()
        try? await gate.withPermit { await self.purgeSerial() }
    }

    private func purgeSerial() async {
        if NativeAOTTensorCachePolicy.enabled {
            await NativeAOTExactTensorCache.discardWhenIdle()
        }
        await pipeline?.purgeResources()
        await probabilityOnlyDetector?.purgeResources()
        probabilityOnlyDetector=nil;probabilityOnlyConfiguration=nil
        await layoutDetector.purgeResources()
        await rawCanonicalLayoutDetector?.purgeResources()
        pipeline = nil
        loadedConfiguration = nil
        pipelineEpoch &+= 1
    }
}


actor ReaderTranslationService {
    static let shared = ReaderTranslationService(warmsOCROnReaderOpen: true)
    private let client: RemoteTranslating
    private let warmsOCROnReaderOpen: Bool
    private var service: TranslationService?
    private let limiter = TranslationProviderRequestLimiter(maximumConcurrentRequests: 16)

    private var activeReaders: Set<UUID> = []
    private var metadataGeneration: UInt64 = 0
    private var metadataTasks: [UUID: Task<[ReaderTranslationRegion], Error>] = [:]
    private var metadataWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    // Pause before reader OCR/debounce starts, and retain the pause between pages.
    // Multiple reader owners cannot accidentally resume each other's metadata work.
    // Readers mark themselves active while visible or background translation is on,
    // so this is also the reader-open hook that warms the OCR models.
    func setReaderActive(_ active: Bool, owner: UUID) {
        if active {
            guard activeReaders.insert(owner).inserted else { return }
            metadataGeneration &+= 1
            for task in metadataTasks.values { task.cancel() }
            if warmsOCROnReaderOpen {
                if #available(iOS 18.0, *), ReaderTranslationSettings().usesPipelineV2 {
                    // V2 owns its own resident models; never warm the legacy OCR set too.
                    if ReaderTranslationSettings().shouldProcessReaderPages {
                        Task(priority: .utility) { await ReaderTranslationV2Service.shared.prewarm() }
                    }
                } else {
                    Self.requestOCRWarmUp()
                }
                let configuration = ReaderTranslationSettings().configuration
                Task(priority: .utility) { [client] in await client.prepare(configuration: configuration) }
            }
        } else {
            activeReaders.remove(owner)
            guard activeReaders.isEmpty else { return }
            if warmsOCROnReaderOpen, #available(iOS 18.0, *) {
                Task(priority: .utility) { await ReaderOCRService.shared.cancelWarmUp() }
            }
            let waiters = metadataWaiters
            metadataWaiters.removeAll()
            for waiter in waiters.values { waiter.resume() }
        }
    }

    /// Off the main thread and low priority; the OCR service ignores the
    /// request when models are resident, a warm-up is running, or memory is low.
    private static func requestOCRWarmUp() {
        guard #available(iOS 18.0, *) else { return }
        let settings = ReaderTranslationSettings()
        guard settings.shouldProcessReaderPages else { return }
        let configuration = settings.ocrConfiguration
        Task(priority: .utility) { await ReaderOCRService.shared.warmUp(configuration: configuration) }
    }

    private func waitForMetadataAdmission() async throws {
        while !activeReaders.isEmpty {
            try Task.checkCancellation()
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { metadataWaiters[id] = continuation }
                }
            } onCancel: {
                Task { await self.cancelMetadataWaiter(id) }
            }
        }
        try Task.checkCancellation()
    }

    private func cancelMetadataWaiter(_ id: UUID) {
        metadataWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    func translateMetadata(
        regions: [ReaderTranslationRegion], settings: ReaderTranslationSettings,
        priority: MetadataTranslationPriority = .mangaTitle
    ) async throws -> [ReaderTranslationRegion] {
        while true {
            try await waitForMetadataAdmission()
            guard activeReaders.isEmpty else { continue }
            let generation = metadataGeneration
            let id = UUID()
            let task = Task { try await self.translateMetadataText(regions: regions, settings: settings, priority: priority) }
            metadataTasks[id] = task
            do {
                let result = try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: { task.cancel() }
                metadataTasks.removeValue(forKey: id)
                try Task.checkCancellation()
                return result
            } catch {
                metadataTasks.removeValue(forKey: id)
                try Task.checkCancellation()
                // Only reader preemption retries. A disappearing/cancelled caller
                // exits immediately, and ordinary provider failures are preserved.
                guard task.isCancelled, generation != metadataGeneration else { throw error }
            }
        }
    }

    /// Metadata has no page image or visual roles. Keep its admission and
    /// cancellation policy above, but never enter the mandatory page route.
    private func translateMetadataText(
        regions: [ReaderTranslationRegion], settings: ReaderTranslationSettings,
        priority: MetadataTranslationPriority
    ) async throws -> [ReaderTranslationRegion] {
        try Task.checkCancellation()
        let sourceOwners = regions
        let regions = ReaderTranslationLanguageFilter.apply(regions, settings: settings)
        let eligibleIDs = Set(regions.map(\.id))
        guard !regions.isEmpty else {
            return ReaderTranslationLanguageFilter.preservingExcludedSource(
                original: sourceOwners, translated: [], eligibleIDs: eligibleIDs)
        }
        let plans = NativeTranslationBatchPlanner.makeBatches(
            candidates: regions.enumerated().map {
                NativeTranslationBatchCandidate(inputIndex: $0.offset,
                    segment: .init(id: $0.element.id, text: $0.element.source))
            },
            sourceLanguage: settings.sourceLanguage, targetLanguage: settings.targetLanguage)
        let service = try translationService()
        let concurrency = max(1, min(BoundedTranslationBatchExecutor.allowedMaximumConcurrentRequests,
            settings.maximumConcurrentRequests))
        await limiter.setMaximumConcurrentRequests(concurrency)
        let progress = try ReaderTranslationProgress(regions: regions, plans: plans, configuration: settings.configuration)
        let results = try await BoundedTranslationBatchExecutor.translate(
            plans.map(\.request), configuration: settings.configuration, service: service,
            maximumConcurrentRequests: concurrency, priority: .metadata(priority))
        for (index, result) in results.enumerated() {
            _ = await progress.complete(index: index, result: result)
        }
        try Task.checkCancellation()
        return ReaderTranslationLanguageFilter.preservingExcludedSource(
            original: sourceOwners, translated: await progress.snapshot(), eligibleIDs: eligibleIDs)
    }

    init(client: RemoteTranslating = RemoteTranslationClient(), warmsOCROnReaderOpen: Bool = false) {
        self.client = client
        self.warmsOCROnReaderOpen = warmsOCROnReaderOpen
    }

    private func translationService() throws -> TranslationService {
        if let service { return service }
        // Request-level batch reuse stays in memory; the reader's durable cache stores completed pages separately.
        let cache = try TranslationCache(configuration: .init(diskEnabled: false, maxSizeMiB: 10))
        let service = TranslationService(
            client: client, cache: cache,
            providerRequestLimiter: limiter
        )
        self.service = service
        return service
    }

    private static func mandatoryPageSettings(_ settings: ReaderTranslationSettings) -> ReaderTranslationSettings {
        var result = settings
        result.includePageImage = true
        result.filterSFXWithLLM = true
        result.filterBackgroundWithLLM = true
        return result
    }

    static func plans(regions: [ReaderTranslationRegion], settings: ReaderTranslationSettings) -> [NativeTranslationBatchPlan] {
        let settings = mandatoryPageSettings(settings)
        var candidates = regions.enumerated().map {
            let rect = $0.element.rect
            let bounds = [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)]
            return NativeTranslationBatchCandidate(inputIndex: $0.offset,
                segment: .init(id: $0.element.id, text: $0.element.source,
                    bounds: (settings.shouldAttachPageImage || settings.filterSFXWithLLM || settings.filterBackgroundWithLLM) && bounds.allSatisfy { $0.isFinite && (0...1).contains($0) } ? bounds : nil))
        }
        let ranks = regions.compactMap(\.translationOrder)
        if settings.rightToLeftPanelOrder, ranks.count == regions.count, Set(ranks).count == ranks.count {
            candidates.sort { ranks[$0.inputIndex] < ranks[$1.inputIndex] }
        }
        let plans = NativeTranslationBatchPlanner.makeBatches(candidates: candidates,
            sourceLanguage: settings.sourceLanguage, targetLanguage: settings.targetLanguage)
        return plans.map { plan in
            var request = plan.request
            request.filtersSFX = true
            request.filtersBackground = true
            request.translatesPageLettering = true
            return NativeTranslationBatchPlan(request: request, inputIndicesBySegmentID: plan.inputIndicesBySegmentID)
        }
    }

    static func requests(regions: [ReaderTranslationRegion], settings: ReaderTranslationSettings) throws -> [RemoteTranslationRequest] {
        let settings = mandatoryPageSettings(settings)
        let regions = ReaderTranslationLanguageFilter.apply(regions, settings: settings)
        let requests = plans(regions: regions, settings: settings).map(\.request)
        for request in requests { try request.validate() }
        return requests
    }

    /// Diagnose the same effective classification in Reader, CLI and saved
    /// response evaluation. Raw provider results remain the application input.
    static func unresolvedPrimaryTranslationIDs(
        plan: NativeTranslationBatchPlan, result: RemoteTranslationBatchResult,
        regions: [ReaderTranslationRegion], targetLanguage: String
    ) -> Set<String> {
        let effective = RemoteTranslationBatchResult(translations: result.translations.map { segment in
            guard let input = plan.inputIndicesBySegmentID[segment.id], regions.indices.contains(input) else { return segment }
            return regions[input].effectiveTranslation(segment)
        }, source: result.source, providerRequestID: result.providerRequestID)
        let copies = ReaderTranslationLanguageFilter.untranslatedAdmittedDialogueIDs(request: plan.request, result: effective)
        return copies.union(effective.translations.compactMap { segment in
            guard let input = plan.inputIndicesBySegmentID[segment.id], regions.indices.contains(input),
                segment.isSFX != true, segment.textRole != .sfx, segment.textRole != .background, segment.textRole != .error,
                ReaderTranslationLanguageFilter.requiresBalloonTranslation(
                    regions[input], translation: segment.text, target: targetLanguage) else { return nil }
            return segment.id
        })
    }

    typealias Progress = @Sendable ([ReaderTranslationRegion]) async throws -> Void

    /// `onPartialProgress` (optional) receives snapshots that include
    /// provisional streamed segments of unfinished batches. It never runs
    /// after this call returns, and completed batches always win over it.
    func translate(
        regions: [ReaderTranslationRegion], settings: ReaderTranslationSettings, image: UIImage? = nil,
        preparedImageJPEG: Data? = nil, preparedPage: RemoteTranslationPageImage? = nil, onProgress: Progress? = nil,
        priority: TranslationRequestPriority = .foreground,
        onPartialProgress: Progress? = nil
    ) async throws -> [ReaderTranslationRegion] {
        try Task.checkCancellation()
        let settings = Self.mandatoryPageSettings(settings)
        let sourceOwners = regions
        let regions = ReaderTranslationLanguageFilter.apply(regions, settings: settings)
        let eligibleIDs = Set(regions.map(\.id))
        let preservingOwners: @Sendable ([ReaderTranslationRegion]) -> [ReaderTranslationRegion] = { translated in
            ReaderTranslationLanguageFilter.preservingExcludedSource(
                original: sourceOwners, translated: translated, eligibleIDs: eligibleIDs)
        }
        guard !regions.isEmpty else {
            let kept = preservingOwners([])
            try await onProgress?(kept)
            return kept
        }
        let service = try translationService()
        let concurrency = max(1, min(3, settings.maximumConcurrentRequests))
        await limiter.setMaximumConcurrentRequests(concurrency)
        // Each of the two offscreen pages submits one batch at a time, leaving
        // the third provider slot available for visible demand. Promotion may
        // then expand that page's batches; metadata keeps its existing policy.
        let speculativeBatchLimit: Int
        switch priority {
        case .prefetch, .promotable:
            speculativeBatchLimit = min(2, max(1, (concurrency - 1) / 2))
        default:
            speculativeBatchLimit = 2
        }
        try Task.checkCancellation()
        guard preparedPage == nil || (preparedImageJPEG == nil && image == nil) else {
            throw RemoteTranslationError.invalidRequest("Provide one page image representation.")
        }
        let pageImage = try preparedPage
            ?? preparedImageJPEG.map { RemoteTranslationPageImage(jpeg: $0, sourceIdentity: nil) }
            ?? image.map(ReaderTranslationImagePreparation.preparedPage)
        guard let pageImage else {
            throw RemoteTranslationError.invalidRequest("Page translation requires a page image.")
        }
        let imageDataURL = "data:image/jpeg;base64," + pageImage.jpeg.base64EncodedString()
        let plans = Self.plans(regions: regions, settings: settings).map { plan in
            var request = plan.request
            pageImage.apply(to: &request)
            request.preparedImageDataURL = imageDataURL
            return NativeTranslationBatchPlan(request: request, inputIndicesBySegmentID: plan.inputIndicesBySegmentID)
        }
        let progress = try ReaderTranslationProgress(regions: regions, plans: plans, configuration: settings.configuration)
        // Clear translations whose language/model/prompt identity no longer matches before publishing any batch.
        try await onProgress?(preservingOwners(await progress.snapshot()))
        // Streamed segments arrive synchronously on the network queue. One
        // ordered consumer applies them, so a partial never overtakes a later
        // partial and never replaces a completed batch.
        var partialConsumer: Task<Void, Never>?
        var partialHandler: BoundedTranslationBatchExecutor.BatchPartialHandler?
        var partialContinuation: AsyncStream<(Int, [RemoteTranslatedSegment])>.Continuation?
        if let onPartialProgress {
            let (stream, continuation) = AsyncStream<(Int, [RemoteTranslatedSegment])>.makeStream()
            partialContinuation = continuation
            partialHandler = { index, segments in continuation.yield((index, segments)) }
            partialConsumer = Task {
                for await (index, segments) in stream {
                    guard !Task.isCancelled else { break }
                    guard let snapshot = await progress.partial(index: index, segments: segments) else { continue }
                    guard !Task.isCancelled else { break }
                    try? await onPartialProgress(preservingOwners(snapshot))
                }
            }
        }
        defer {
            partialContinuation?.finish()
            partialConsumer?.cancel()
        }
        do {
            _ = try await BoundedTranslationBatchExecutor.translate(
                plans.map(\.request), configuration: settings.configuration, service: service,
                // The scheduler reserves foreground capacity until a lookahead is promoted.
                maximumConcurrentRequests: concurrency,
                maximumSpeculativeRequests: speculativeBatchLimit,
                priority: priority,
                onBatchCompleted: { index, result in
                    try Task.checkCancellation()
                    // One provider call per page-lettering batch. Diagnose any
                    // untranslated primary result locally; never issue a second
                    // classification or literal-recovery request here.
                    let plan = plans[index]
                    let missed = Self.unresolvedPrimaryTranslationIDs(
                        plan: plan, result: result, regions: regions, targetLanguage: settings.targetLanguage)
                    ReaderTranslationDiagnostics.record("primary_untranslated", count: missed.count)
                    let snapshot = await progress.complete(index: index, result: result,
                        unresolvedRecoveryIDs: missed)
                    try await onProgress?(preservingOwners(snapshot))
                },
                onBatchPartial: partialHandler
            )
        } catch {
            // Cancellation alone does not join an in-progress UI callback.
            // Drain its lifetime before failure escapes to a replacement page.
            partialContinuation?.finish()
            partialConsumer?.cancel()
            await partialConsumer?.value
            throw error
        }
        partialContinuation?.finish()
        partialConsumer?.cancel()
        await partialConsumer?.value
        try Task.checkCancellation()
        return preservingOwners(await progress.snapshot())
    }

    func clearCache() async throws {
        try await service?.purgeCache()
    }

    /// V2 S5: one page request through the live provider client, sharing the
    /// reader's provider concurrency limit and mandatory page settings.
    @available(iOS 18.0, *)
    func translateV2(
        _ blocks: [V2Block], pageSize: CGSize, settings: ReaderTranslationSettings, imageJPEG: Data?,
        priority: TranslationRequestPriority = .foreground
    ) async throws -> [V2Block] {
        try Task.checkCancellation()
        let settings = Self.mandatoryPageSettings(settings)
        let configuration = settings.configuration
        _ = try configuration.validatedEndpoint()
        let concurrency = max(1, min(3, settings.maximumConcurrentRequests))
        await limiter.setMaximumConcurrentRequests(concurrency)
        let client = client
        return try await limiter.withPermit(priority: priority) {
            try await V2Translation.translate(
                blocks, pageSize: pageSize, client: client, configuration: configuration,
                sourceLanguage: settings.sourceLanguage, targetLanguage: settings.targetLanguage,
                imageJPEG: settings.includePageImage ? imageJPEG : nil)
        }
    }
}

/// Applies the original progressive identity policy without sharing mutable batches between page requests.
actor ReaderTranslationProgress {
    private var regions: [ReaderTranslationRegion]
    private let inputIndices: [[String: Int]]
    private let expected: [Int: NativeTranslationReuseIdentity]

    init(regions: [ReaderTranslationRegion], plans: [NativeTranslationBatchPlan], configuration: RemoteTranslationConfiguration) throws {
        self.regions = regions
        self.inputIndices = plans.map(\.inputIndicesBySegmentID)
        var expected: [Int: NativeTranslationReuseIdentity] = [:]
        for plan in plans {
            for (id, identity) in try NativeTranslationReuseIdentity.identitiesBySegmentID(configuration: configuration, request: plan.request) {
                if let index = plan.inputIndicesBySegmentID[id] {
                    expected[index] = identity
                }
            }
        }
        self.expected = expected
        // Validate existing display-only reuse once. Subsequent batches only
        // replace their own regions, retaining OCR geometry without rebuilding
        // two full overlay arrays on every progressive publication.
        for index in regions.indices {
            guard regions[index].translationRecoveryFailure == nil,
                  let old = regions[index].translationReuseIdentity,
                  let identity = expected[index], regions[index].translation != nil,
                  old == identity || old.canRemainVisibleWhileRefreshing(expected: identity) else {
                self.regions[index].translation = nil
                self.regions[index].translationReuseIdentity = nil
                self.regions[index].keepsClassifiedSFXSource = false
                continue
            }
        }
    }

    private var completedBatches = Set<Int>()

    /// Applies provisional streamed segments of an unfinished batch. Returns
    /// nil when nothing changed or the batch has already completed.
    func partial(index: Int, segments: [RemoteTranslatedSegment]) -> [ReaderTranslationRegion]? {
        guard inputIndices.indices.contains(index), !completedBatches.contains(index) else { return nil }
        var changed = false
        for segment in segments {
            if let inputIndex = inputIndices[index][segment.id], let identity = expected[inputIndex] {
                let reusableIdentity = regions[inputIndex].translationRecoveryFailure == nil ? identity : nil
                let translationChanged = regions[inputIndex].applyTranslation(segment)
                if translationChanged || regions[inputIndex].translationReuseIdentity != reusableIdentity {
                    regions[inputIndex].translationReuseIdentity = reusableIdentity
                    changed = true
                }
            }
        }
        return changed ? regions : nil
    }

    func complete(index: Int, result: RemoteTranslationBatchResult,
                  unresolvedRecoveryIDs: Set<String> = []) -> [ReaderTranslationRegion] {
        completedBatches.insert(index)
        for segment in result.translations {
            if let inputIndex = inputIndices[index][segment.id], let identity = expected[inputIndex] {
                regions[inputIndex].applyTranslation(segment)
                // Retained primary data remains visible but is not reusable as
                // a successfully recovered translation on a later request.
                regions[inputIndex].translationReuseIdentity = unresolvedRecoveryIDs.contains(segment.id) ? nil : identity
                regions[inputIndex].translationRecoveryFailure = unresolvedRecoveryIDs.contains(segment.id)
                    ? "primary_untranslated" : nil
            }
        }
        return regions
    }

    func snapshot() -> [ReaderTranslationRegion] {
        regions
    }
}
