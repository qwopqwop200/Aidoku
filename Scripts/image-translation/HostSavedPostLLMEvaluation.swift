import Foundation
import CoreGraphics

/// Replays saved provider replies through the real display/cache/progress path.
/// No provider requests, source image access, GT or page-specific decisions.
@available(macOS 15.0, *)
enum HostSavedPostLLMEvaluation {
    private struct Rect: Decodable {
        let x: Double; let y: Double; let width: Double; let height: Double
        var cg: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }
    private struct Region: Decodable {
        let id: String; let source: String; let rect: Rect
        let polygon: [[Double]]; let confidence: Double
        let orientation: String?
        let postLLMDetectorFeatures: [Double]?
        let postLLMDetectorSignals: [[Double]]?
        let sourceMemberPolygons: [[[Double]]]?
        let unitMemberRects: [Rect]
        let balloon_interior: Balloon?
        var native: ReaderTranslationRegion {
            var value = ReaderTranslationRegion(id: id, rect: rect.cg, source: source)
            value.polygon = polygon.map { CGPoint(x: $0[0], y: $0[1]) }
            value.confidence = confidence
            value.cachedSourceMemberPolygons = (sourceMemberPolygons ?? []).filter {
                $0.count >= 3 && $0.allSatisfy { $0.count == 2 && $0.allSatisfy(\.isFinite) }
            }.map { $0.map { CGPoint(x:$0[0],y:$0[1]) } }
            value.sourceOrientation = .init(tolerantRawValue: orientation)
            value.unitMemberRects = unitMemberRects.map(\.cg)
            value.balloonInterior = balloon_interior?.native
            return value
        }
    }
    private struct Balloon: Decodable {
        let rect: Rect; let center: [Double]; let spans: [Double]
        let verified: Bool; let model_estimated: Bool
        var native: ReaderTranslationBalloonInterior {
            .init(rect: rect.cg, center: CGPoint(x: center[0], y: center[1]), spans: spans,
                members: nil, contourVerified: verified, modelEstimated: model_estimated)
        }
    }
    private struct Page: Decodable {
        let page: String
        let regions: [Region]
        let finalFilter: [NativeFinalOutputContentFilter.AuditRow]
    }
    private struct Reply: Decodable {
        let status: String
        let translations: [RemoteTranslatedSegment]
    }
    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw HostError.message(message) }
    }
    private static func kept(_ segment: RemoteTranslatedSegment) -> Bool {
        segment.isSFX != true && [.dialogue, .narration, .storyText].contains(segment.textRole)
    }

    static func controls() throws -> Int {
        typealias C = NativePostLLMContentReclassifier
        var features = Array(repeating: 0.0, count: NativeFinalOutputContentFilter.featureNames.count)
        func set(_ name: String, _ value: Double) {
            features[NativeFinalOutputContentFilter.featureNames.firstIndex(of: name)!] = value
        }
        var checks = 0
        func check(_ condition: Bool) throws {
            try require(condition, "Post-LLM reconciliation control failed at \(checks)"); checks += 1
        }
        set("bodyMean.rawTextSupport", 0.8); set("bodyMax.rawTextSupport", 0.8)
        set("ocrBodyMean", 0.9); set("ocrBodyMax", 0.9); set("bodyMean.balloonInteriorCoverage", 1)
        let evidence = C.Evidence(features: features)!
        let sfx = RemoteTranslatedSegment(id: "arbitrary", text: "translated", isSFX: true, textRole: .sfx)
        let recovered = C.resolved(sfx, evidence: evidence)
        try check(recovered.textRole == .storyText && recovered.isSFX == false && recovered.text == sfx.text && recovered.id == sfx.id)
        try check(C.resolved(sfx, evidence: nil) == sfx)
        try check(C.Evidence(features: nil) == nil && C.Evidence(features: []) == nil)
        for invalid in [Double.nan, Double.infinity, -0.1, 1.1] {
            var bad = features; bad[0] = invalid; try check(C.Evidence(features: bad) == nil)
        }
        let error = RemoteTranslatedSegment(id: "error", text: "translated", isSFX: false, textRole: .error)
        try check(C.resolved(error, evidence: evidence) == error)
        let blank = RemoteTranslatedSegment(id: "blank", text: " \n", isSFX: true, textRole: .sfx)
        try check(C.resolved(blank, evidence: evidence) == blank)
        let unknown = RemoteTranslatedSegment(id: "unknown", text: "translated")
        try check(C.resolved(unknown, evidence: evidence) == unknown)
        let background = RemoteTranslatedSegment(id: "background", text: "translated", isSFX: false, textRole: .background)
        try check(C.resolved(background, evidence: evidence).textRole == .storyText)
        var conflict = features
        conflict[NativeFinalOutputContentFilter.featureNames.firstIndex(of: "out.maskSFXOnlyCoverage")!] = 0.2
        try check(C.resolved(sfx, evidence: C.Evidence(features: conflict)) == sfx)
        let renamed = RemoteTranslatedSegment(id: "different-page-and-owner", text: sfx.text, isSFX: true, textRole: .sfx)
        try check(C.resolved(renamed, evidence: evidence).textRole == recovered.textRole)
        let oldData = try JSONSerialization.data(withJSONObject: ["version": "old", "features": features])
        let old = try JSONDecoder().decode(C.Evidence.self, from: oldData)
        try check(C.resolved(sfx, evidence: old) == sfx)
        set("bodyMean.rawTextSupport", 0.2); set("bodyMax.rawTextSupport", 0.2)
        set("ocrBodyMean", 0.6); set("ocrBodyMax", 0.7); set("out.jointSFXClassShare", 0.8)
        let low = C.Evidence(features: features)!
        let speech = RemoteTranslatedSegment(id: "speech", text: "translated", isSFX: false, textRole: .dialogue)
        try check(C.resolved(speech, evidence: low).textRole == .background)
        let story = RemoteTranslatedSegment(id: "story", text: "translated", isSFX: false, textRole: .storyText)
        let narration = RemoteTranslatedSegment(id: "narration", text: "translated", isSFX: false, textRole: .narration)
        set("out.rawTextSupport", 0); set("out.rawTextShare", 0)
        try check(C.resolved(story, evidence: C.Evidence(features: features)).textRole == .background)
        set("out.rawTextSupport", 0.15); set("out.rawTextShare", 0.6)
        try check(C.resolved(narration, evidence: C.Evidence(features: features)).textRole == .background)
        set("out.rawTextSupport", 0.5); set("out.rawTextShare", 0.9)
        try check(C.resolved(narration, evidence: C.Evidence(features: features)) == narration)
        // Every provider class has exactly one independent calibration. Weak
        // text + SFX evidence for dialogue must not leak into narrative roles.
        try check(C.rolePolicies.count == RemoteTranslationTextRole.allCases.count
            && Set(C.rolePolicies.map(\.role)) == Set(RemoteTranslationTextRole.allCases))
        set("bodyMax.rawTextSupport", 0.05); set("out.jointSFXClassShare", 0.8)
        set("ocrBodyMean", 0.85); set("ocrBodyMax", 0.95)
        let queryConflict = C.Evidence(features: features)!
        try check(C.resolved(speech, evidence: queryConflict).textRole == .background)
        try check(C.resolved(narration, evidence: queryConflict) == narration)
        try check(C.resolved(story, evidence: queryConflict) == story)
        set("out.jointSFXClassShare", 0.4)
        try check(C.resolved(speech, evidence: C.Evidence(features: features)) == speech)
        set("bodyMax.rawTextSupport", 0.3); set("out.jointSFXClassShare", 0.8)
        try check(C.resolved(speech, evidence: C.Evidence(features: features)) == speech)
        // Even high recognizer confidence is insufficient when the RF query
        // and exclusive SFX mask agree, but mask coverage alone is not enough.
        set("bodyMax.rawTextSupport", 0.18); set("out.jointSFXClassShare", 0.65)
        set("out.maskSFXOnlyCoverage", 0.6); set("ocrBodyMean", 0.95)
        let maskConflict = C.Evidence(features: features)!
        try check(C.resolved(speech, evidence: maskConflict).textRole == .background)
        try check(C.resolved(narration, evidence: maskConflict) == narration)
        try check(C.resolved(story, evidence: maskConflict) == story)
        set("out.jointSFXClassShare", 0.4)
        try check(C.resolved(speech, evidence: C.Evidence(features: features)) == speech)
        set("out.jointSFXClassShare", 0.65); set("bodyMax.rawTextSupport", 0.3)
        try check(C.resolved(speech, evidence: C.Evidence(features: features)) == speech)
        // Expanded signal families remain source-role specific. An absent
        // detector measurement cannot satisfy a detector-conditioned rule.
        features = Array(repeating: 0, count: NativeFinalOutputContentFilter.featureNames.count)
        set("bodyMax.rawTextSupport", 0.5); set("ocrBodyMean", 0.95); set("ocrBodyMax", 0.95)
        set("out.rawTextSupport", 0.8); set("out.rawTextShare", 0.9)
        set("out.balloonInteriorCoverage", 0.8); set("bodyMean.rawTextShare", 0.5)
        set("bodyMax.jointSFXClassShare", 0.6)
        let balloonConflict = C.Evidence(features: features)!
        try check(C.resolved(speech, evidence: balloonConflict).textRole == .background)
        try check(C.resolved(narration, evidence: balloonConflict) == narration)
        try check(C.resolved(story, evidence: balloonConflict) == story)
        set("out.balloonInteriorCoverage", 0); set("bodyMean.rawTextShare", 0.9)
        set("out.maskSFXShare", 0.3); set("out.frameInteriorCoverage", 0.4)
        try check(C.resolved(speech, evidence: C.Evidence(features: features)).textRole == .background)
        set("out.frameInteriorCoverage", 0)
        try check(C.resolved(speech, evidence: C.Evidence(features: features)) == speech)
        set("out.maskSFXShare", 0); set("bodyMean.rawTextShare", 0.4)
        let detector = [1.0, 0.8, 0.9, 0.7, 0.95]
        let detectorAggregate = C.detectorFeatures(bodySignals: [detector, detector])!
        try check(detectorAggregate.count == 15 && detectorAggregate == detector + detector + detector)
        try check(C.detectorFeatures(bodySignals: [detector, nil]) == nil)
        try check(C.Evidence(features: features, detectorFeatures: []) == nil)
        try check(C.Evidence(features: features, detectorFeatures: Array(repeating: Double.nan, count: 15)) == nil)
        try check(C.resolved(speech, evidence: C.Evidence(features: features)) == speech)
        let detectorEvidence = C.Evidence(features: features, detectorFeatures: detectorAggregate)!
        try check(C.resolved(speech, evidence: detectorEvidence).textRole == .background)
        try check(C.resolved(narration, evidence: detectorEvidence) == narration)
        try check(C.resolved(story, evidence: detectorEvidence) == story)
        var source55 = Array(repeating: Double.nan, count: 55)
        source55.replaceSubrange(8..<13, with: detector)
        try check(C.detectorSignals(from: source55) == detector)
        source55[9] = Double.nan
        try check(C.detectorSignals(from: source55) == nil)
        let measuredLine = NativeCoreMLOCRLine(polygon: [], text: "control", score: 0.8,
            orientation: .vertical, acceptedSource: .init(detectorSignals: detector))
        let boundLine = NativeOCRAcceptedSource.bindingPrimary([measuredLine], width: 100, height: 100)[0]
        try check(boundLine.acceptedSource.membership?.table.packets[0].detectorSignals == detector)
        var region = ReaderTranslationRegion(id: "speech", rect: CGRect(x: 0.1, y: 0.2, width: 0.1, height: 0.3), source: "source")
        region.postLLMContentEvidence = low
        region.applyTranslation(speech)
        try check(region.translation == region.source && !region.keepsClassifiedSFXSource)
        var stored = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ReaderTranslationStoredRegion(region))) as! [String: Any]
        stored.removeValue(forKey: "postLLMContentEvidence")
        let legacy = try JSONDecoder().decode(ReaderTranslationStoredRegion.self, from: JSONSerialization.data(withJSONObject: stored)).region
        try check(legacy.postLLMContentEvidence == nil && legacy.effectiveTranslation(speech) == speech)
        // Saved-owner refresh must recompute signals without a second admission.
        region.confidence = 0.5
        region.polygon = [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.2, y: 0.5), CGPoint(x: 0.1, y: 0.5)]
        let packet = NativeOCRAcceptedSource.Packet(polygon: region.polygon.map { CGPoint(x: $0.x * 100, y: $0.y * 100) },
            text: region.source, score: 0.5, orientation: .vertical, orientationIsEstimated: false,
            sourceTileBounds: nil, erasurePolygons: [], detectorSeedEvidence: nil, detectorSignals: detector)
        let table = NativeOCRAcceptedSource.PacketTable(packets: [packet], width: 100, height: 100)
        region.acceptedSource = .init(.init(table: table, body: [0], readings: [], unknownDedup: [], hasUntrackedInputs: false))
        let queries = (0..<300).map { index in NativeRFDETRClassEvidence(queryID: index,
            logits: [0, 0, 0, 0, 1], probabilities: [0, 0, 0, 0, 1],
            normalizedBounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            sourceBounds: CGRect(x: 0, y: 0, width: 100, height: 100), mask: nil) }
        let layout = NativeRFDETRLayoutResult(imageIdentity: "synthetic-control", sourceWidth: 100, sourceHeight: 100,
            primitives: [], maskQueriesOmittedByBudget: 0, preprocessingMilliseconds: 0, modelMilliseconds: 0,
            decodeMilliseconds: 0, computeUnits: "synthetic-control", fromCache: false, classEvidence: queries)
        let refreshed = NativeFinalOutputContentFilter.attachingEvidence([region], layout: layout)
        try check(refreshed.count == 1 && refreshed[0].postLLMContentEvidence?.detectorFeatures == detectorAggregate)
        let admitted = NativeFinalOutputContentFilter.applying([region], layout: layout)
        try check(admitted.isEmpty)
        try check(!NativeFinalOutputContentFilter.keep(refreshed[0].postLLMContentEvidence!.features,
            policy: NativeFinalOutputContentFilter.defaultPolicy, detectorFeatures: detectorAggregate))
        try check(NativePostMergeSignalFilter.keep(features: refreshed[0].postLLMContentEvidence!.features, detectorFeatures: detectorAggregate))
        try check(refreshed[0].rect == region.rect && refreshed[0].polygon == region.polygon)
        var untracked = region
        untracked.acceptedSource = .init()
        let unavailable = NativeFinalOutputContentFilter.attachingEvidence([untracked], layout: layout)
        try check(unavailable.count == 1 && unavailable[0].postLLMContentEvidence == nil)
        // Exercise actual shared admission, not just attach-only refresh.
        let untrackedAdmitted = NativeFinalOutputContentFilter.applying([untracked], layout: layout)
        try check(untrackedAdmitted.count == 1 && untrackedAdmitted[0].postLLMContentEvidence == nil)
        var incomplete = region
        incomplete.acceptedSource = .init(.init(table: table, body: [0], readings: [], unknownDedup: [], hasUntrackedInputs: true))
        let incompleteAdmitted = NativeFinalOutputContentFilter.applying([incomplete], layout: layout)
        try check(incompleteAdmitted.count == 1 && incompleteAdmitted[0].postLLMContentEvidence == nil)
        let noDetectorPacket = NativeOCRAcceptedSource.Packet(polygon: packet.polygon,
            text: packet.text, score: packet.score, orientation: packet.orientation,
            orientationIsEstimated: packet.orientationIsEstimated, sourceTileBounds: packet.sourceTileBounds,
            erasurePolygons: packet.erasurePolygons, detectorSeedEvidence: packet.detectorSeedEvidence, detectorSignals: nil)
        let noDetectorTable = NativeOCRAcceptedSource.PacketTable(packets: [noDetectorPacket], width: 100, height: 100)
        var noDetector = region
        noDetector.acceptedSource = .init(.init(table: noDetectorTable, body: [0], readings: [], unknownDedup: [], hasUntrackedInputs: false))
        let noDetectorRefreshed = NativeFinalOutputContentFilter.attachingEvidence([noDetector], layout: layout)
        try check(noDetectorRefreshed.count == 1 && noDetectorRefreshed[0].postLLMContentEvidence?.features.count == 92)
        try check(noDetectorRefreshed[0].postLLMContentEvidence?.detectorFeatures == nil)
        let noDetectorAdmitted = NativeFinalOutputContentFilter.applying([noDetector], layout: layout)
        try check(noDetectorAdmitted.isEmpty)
        // Missing DET does not itself reject: genuine source corroboration
        // still protects the member through the unchanged final4 MIN guard.
        var corroborated = noDetectorRefreshed[0].postLLMContentEvidence!.features
        for name in ["ocrBodyMin", "ocrBodyMean", "ocrBodyMax"] {
            corroborated[NativeFinalOutputContentFilter.featureNames.firstIndex(of: name)!] = 0.95
        }
        corroborated[NativeFinalOutputContentFilter.featureNames.firstIndex(of: "out.rawSFXSupport")!] = 0.1
        for prefix in ["bodyMin", "bodyMean", "bodyMax"] {
            for (name, value) in [("rawTextSupport", 0.2), ("jointTextSupport", 0.1), ("jointTextMaskCoverage", 0.5)] {
                corroborated[NativeFinalOutputContentFilter.featureNames.firstIndex(of: prefix + "." + name)!] = value
            }
        }
        try check(NativeFinalOutputContentFilter.keep(corroborated, policy: NativeFinalOutputContentFilter.defaultPolicy, detectorFeatures: nil))
        var contradictoryDetector = [Double](repeating: 0, count: 15)
        contradictoryDetector[0] = 1
        try check(!NativeFinalOutputContentFilter.keep(corroborated, policy: NativeFinalOutputContentFilter.defaultPolicy, detectorFeatures: contradictoryDetector))
        for score in [Double(0.6).nextDown, 0.6, Double(0.6).nextUp] {
            let tiedPacket = NativeOCRAcceptedSource.Packet(polygon: packet.polygon,
                text: packet.text, score: score, orientation: packet.orientation,
                orientationIsEstimated: packet.orientationIsEstimated, sourceTileBounds: packet.sourceTileBounds,
                erasurePolygons: packet.erasurePolygons, detectorSeedEvidence: packet.detectorSeedEvidence, detectorSignals: detector)
            let tiedTable = NativeOCRAcceptedSource.PacketTable(packets: [tiedPacket], width: 100, height: 100)
            var tied = region
            tied.confidence = score
            tied.acceptedSource = .init(.init(table: tiedTable, body: [0], readings: [], unknownDedup: [], hasUntrackedInputs: false))
            let tiedRefreshed = NativeFinalOutputContentFilter.attachingEvidence([tied], layout: layout)
            try check(tiedRefreshed.count == 1)
            let measured = tiedRefreshed[0].postLLMContentEvidence!
            let tiedAdmitted = NativeFinalOutputContentFilter.applying([tied], layout: layout)
            try check(tiedAdmitted.count == (score > 0.6 ? 1 : 0))
            try check(measured.features[2].bitPattern == score.bitPattern)
            try check(NativePostMergeSignalFilter.keep(features: measured.features, detectorFeatures: measured.detectorFeatures))
            try check(NativeFinalOutputContentFilter.keep(measured.features,
                policy: NativeFinalOutputContentFilter.defaultPolicy, detectorFeatures: measured.detectorFeatures) == (score > 0.6))
            if let accepted = tiedAdmitted.first {
                try check(accepted.polygon == tied.polygon && accepted.source == tied.source)
                try check(accepted.postLLMContentEvidence == measured)
            }
        }
        return checks
    }

    @MainActor static func run(_ args: [String]) async -> Int32 {
        do {
            guard args.count == 4 else { throw HostError.message("Expected native shard directory, saved reply directory and output directory") }
            let started = Date(), checks = try controls()
            let native = URL(fileURLWithPath: args[1]), replies = URL(fileURLWithPath: args[2]), out = URL(fileURLWithPath: args[3])
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let decoder = JSONDecoder(), encoder = JSONEncoder()
            let settings = ReaderTranslationSettings(includePageImage: true, sourceLanguage: "ja", targetLanguage: "ko",
                filterSFXWithLLM: true, filterBackgroundWithLLM: true)
            let configuration = RemoteTranslationConfiguration(provider: .custom, apiProtocol: .responses,
                baseURL: "https://saved-response.invalid/v1", model: "saved-response-evaluation", credentialAccount: "unused")
            var output: [[String: Any]] = [], pages = 0, owners = 0, evidenceCount = 0, prefilterCount = 0, changes = 0, detectorOwners = 0
            for shard in 0..<8 {
                let pagesInShard = try decoder.decode([Page].self, from: Data(contentsOf: native.appendingPathComponent("result-\(shard).json")))
                for page in pagesInShard {
                    let response = try decoder.decode(Reply.self, from: Data(contentsOf: replies.appendingPathComponent(page.page + ".json")))
                    try require(response.status == "complete", "Incomplete provider response")
                    let raw = Dictionary(uniqueKeysWithValues: response.translations.map { ($0.id, $0) })
                    var signals: [String: NativePostLLMContentReclassifier.Evidence] = [:]
                    for audit in page.finalFilter {
                        try require(NativeFinalOutputContentFilter.keep(audit.features, policy: NativeFinalOutputContentFilter.defaultPolicy) == audit.keep,
                            "Pre-LLM admission changed")
                        prefilterCount += 1
                        if audit.keep {
                            let owner = page.regions.first(where: { $0.id == audit.id })!
                            let detector = owner.postLLMDetectorSignals.flatMap {
                                NativePostLLMContentReclassifier.detectorFeatures(bodySignals: $0.map { Optional($0) })
                            }
                            if let expected = owner.postLLMDetectorFeatures {
                                try require(detector?.count == expected.count && zip(detector ?? [], expected).allSatisfy {
                                    abs($0 - $1) < 0.00001
                                }, "Native detector aggregation differs from saved measured sources")
                                detectorOwners += 1
                            }
                            guard let evidence = NativePostLLMContentReclassifier.Evidence(features: audit.features,
                                detectorFeatures: detector) else {
                                throw HostError.message("Missing current RF evidence")
                            }
                            signals[audit.id] = evidence
                        }
                    }
                    var regions = page.regions.map(\.native)
                    try require(Set(raw.keys) == Set(regions.map(\.id)) && Set(signals.keys) == Set(raw.keys), "Owner mismatch")
                    for index in regions.indices { regions[index].postLLMContentEvidence = signals[regions[index].id] }
                    // OCR-only disk reuse must preserve every model signal.
                    let archive = try ReaderTranslationRegionArchive(regions)
                    let restored = try ReaderTranslationRegionArchive.regions(base: archive.base, variant: archive.variant)
                    try require(zip(restored, regions).allSatisfy { $0.postLLMContentEvidence == $1.postLLMContentEvidence }, "Signal archive mismatch")
                    var applied = restored
                    var decisions: [[String: Any]] = []
                    for index in applied.indices {
                        let segment = raw[applied[index].id]!, before = applied[index]
                        let effective = before.effectiveTranslation(segment)
                        applied[index].applyTranslation(segment)
                        try require(before.id == applied[index].id && before.rect == applied[index].rect
                            && before.polygon == applied[index].polygon && before.confidence == applied[index].confidence
                            && before.source == applied[index].source, "Reclassification changed source geometry")
                        if effective.textRole == .background || effective.textRole == .error {
                            try require(applied[index].translation == before.source, "Rejected content rendered a translation")
                        } else { try require(applied[index].translation == segment.text, "Provider translation changed") }
                        if kept(effective) != kept(segment) { changes += 1 }
                        decisions.append(["id": segment.id, "rawRole": segment.textRole!.rawValue,
                            "effectiveRole": effective.textRole!.rawValue, "keep": kept(effective), "baselineKeep": kept(segment)])
                    }
                    // Streaming and completed batches use the same raw replies,
                    // including reverse batch order and late streamed updates.
                    let plans = ReaderTranslationService.plans(regions: restored, settings: settings).map { plan in
                        var request = plan.request
                        // Presence-only token exercises the production diagnosis
                        // gate without opening or copying any original image.
                        request.imageJPEG = Data([0xFF, 0xD8, 0xFF, 0xD9])
                        return NativeTranslationBatchPlan(request: request, inputIndicesBySegmentID: plan.inputIndicesBySegmentID)
                    }
                    let progress = try ReaderTranslationProgress(regions: restored, plans: plans, configuration: configuration)
                    for index in plans.indices.reversed() {
                        let plan = plans[index]
                        let segments = plan.request.segments.map { raw[$0.id]! }
                        if let partial = await progress.partial(index: index, segments: segments) {
                            for segment in segments {
                                let input = plan.inputIndicesBySegmentID[segment.id]!
                                try require(partial[input].translation == applied[input].translation
                                    && partial[input].keepsClassifiedSFXSource == applied[input].keepsClassifiedSFXSource
                                    && partial[input].rendersUnchangedSymbols == applied[input].rendersUnchangedSymbols,
                                    "Partial display differs from direct raw-reply application")
                            }
                        }
                        let result = RemoteTranslationBatchResult(translations: segments, source: .network, providerRequestID: nil)
                        let misses = ReaderTranslationService.unresolvedPrimaryTranslationIDs(
                            plan: plan, result: result, regions: restored, targetLanguage: settings.targetLanguage)
                        let identities = try NativeTranslationReuseIdentity.identitiesBySegmentID(configuration: configuration, request: plan.request)
                        for segment in segments {
                            let input = plan.inputIndicesBySegmentID[segment.id]!
                            applied[input].translationRecoveryFailure = misses.contains(segment.id) ? "primary_untranslated" : nil
                            applied[input].translationReuseIdentity = misses.contains(segment.id) ? nil : identities[segment.id]
                        }
                        _ = await progress.complete(index: index, result: result, unresolvedRecoveryIDs: misses)
                        let late = await progress.partial(index: index, segments: segments)
                        try require(late == nil, "Late partial replaced a completed result")
                    }
                    let completed = await progress.snapshot()
                    try require(zip(applied, completed).allSatisfy {
                        $0.translation == $1.translation && $0.keepsClassifiedSFXSource == $1.keepsClassifiedSFXSource
                            && $0.rendersUnchangedSymbols == $1.rendersUnchangedSymbols
                            && $0.translationRecoveryFailure == $1.translationRecoveryFailure
                            && $0.translationReuseIdentity == $1.translationReuseIdentity
                    }, "Progress differs from direct application")
                    let translatedArchive = try ReaderTranslationRegionArchive(completed)
                    let cached = try ReaderTranslationRegionArchive.regions(base: translatedArchive.base, variant: translatedArchive.variant)
                    try require(zip(completed, cached).allSatisfy {
                        $0.translation == $1.translation && $0.postLLMContentEvidence == $1.postLLMContentEvidence
                            && $0.keepsClassifiedSFXSource == $1.keepsClassifiedSFXSource
                            && $0.translationRecoveryFailure == $1.translationRecoveryFailure
                            && $0.translationReuseIdentity == $1.translationReuseIdentity
                    }, "Completed translation archive mismatch")
                    output.append(["page": page.page, "regions": decisions])
                    pages += 1; owners += regions.count; evidenceCount += signals.count
                }
            }
            let report: [String: Any] = ["pages": pages, "owners": owners, "signalOwners": evidenceCount, "detectorOwnersVerified": detectorOwners,
                "prefilterRowsVerified": prefilterCount, "changedDecisions": changes, "controlsPassed": checks,
                "cacheRoundTripsPassed": true, "partialCompleteParity": true, "geometryUnchanged": true,
                "productionCompletionDiagnosisVerified": true, "imagePresenceTokenOnlyForDiagnostics": true,
                "providerRequestsSent": 0, "sourceImagesRead": 0, "GTReadByNative": false,
                "preLLMAdmissionPolicyVersion": NativeFinalOutputContentFilter.admissionPolicyVersion,
                "combinedAdmissionFocusedControls": "actual-shared-combined-applying-v2",
                "seconds": Date().timeIntervalSince(started), "policyVersion": NativePostLLMContentReclassifier.policyVersion]
            try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]).write(to: out.appendingPathComponent("NATIVE-DECISIONS.json"), options: .atomic)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("NATIVE-VERIFICATION.json"), options: .atomic)
            try encoder.encode(NativePostLLMContentReclassifier.rolePolicies).write(to: out.appendingPathComponent("NATIVE-ROLE-POLICIES.json"), options: .atomic)
            print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
            return 0
        } catch { fputs("Saved post-LLM evaluation failed: \(error)\n", stderr); return 1 }
    }
}
