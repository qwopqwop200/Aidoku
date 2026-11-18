import CoreGraphics
import Foundation
import ImageIO

/// HOST-ONLY approximation boundary. No translation client/HTTP transport is
/// created. Root supplies the budget-fenced ACTUAL production render operation.
@available(macOS 15.0, *)
enum HostMatchedReaderRender {
    enum Failure: Error { case request, binding, changedReader, noRenderableTarget, unsupported }
    struct Reference: Codable, Sendable { let path: String; let SHA256: String }
    struct DBReplay: Decodable, Sendable {
        let metadata: Reference
        let values: Reference
        let captureReceipt: Reference
    }
    struct DBMetadata: Decodable {
        let schema: String
        let sourceEncodedSHA256: String
        let width: Int
        let height: Int
        let mapSHA256: String
        let expected: NativeMainEnsembleDBCapability.Key
        let actualDetectorCalls: Int
        let historicalProducerRebranded: Bool
    }
    struct Request: Decodable {
        let schema: String
        let pageID: String
        let readerRequest: Reference
        let readerIndex: Reference
        let matchedManifest: Reference
        let outputDirectory: String
        let targetLanguage: String
        let freshDetectorBudget: Int?
        let freshAOTBudget: Int?
        let AOTRawReplayIndex: Reference?
        let DBProbabilityReplay: DBReplay?
    }
    /// The caller MUST enforce AOT before prediction, not merely count after.
    /// Return an actual runtime budget/cache receipt, never a fake HTTP result.
    typealias Render = @MainActor ([ReaderTranslationRegion], CGImage, URL, ReaderOCRConfiguration, Int) async throws -> [String: Any]
    private static func checked(_ r: Reference) throws -> Data {
        let bytes = try Data(contentsOf: URL(fileURLWithPath: r.path))
        guard HostModuleBank.digest(bytes) == r.SHA256 else { throw Failure.binding }
        return bytes
    }
    private static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.binding }
        return value
    }
    private static func write(_ value: [String: Any], _ destination: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
            .write(to: destination, options: .atomic)
    }
    private static func bits(_ x: Double) -> String { String(format: "%016llx", x.bitPattern) }
    /// Decode only witnessed actual current grid bytes. The existing Reader
    /// ensure then independently recomputes the complete current tensor/model
    /// expectation and must admit this as a zero-forward resident hit.
    static func probabilityReplay(_ replay: DBReplay, original: CGImage,
                                  sourceEncodedSHA256: String, currentModelSHA256: String) throws
        -> NativeMainAOTRemovalMaskBuilder.SourceProbability {
        let meta = try JSONDecoder().decode(DBMetadata.self, from: checked(replay.metadata))
        let receipt = try object(checked(replay.captureReceipt))
        let key = meta.expected, p = key.producer, s = key.source
        let source = try NativeRFDETRSourceImage.decode(original)
        guard meta.schema == "actual-current-db-map-cache-v1", meta.actualDetectorCalls == 1,
              !meta.historicalProducerRebranded,
              receipt["status"] as? String == "actual-current-source-style-renderer-completed-approximate-targets-only",
              receipt["actualDetectorCalls"] as? Int == 1,
              receipt["sourceEncodedSHA256"] as? String == sourceEncodedSHA256,
              meta.sourceEncodedSHA256 == sourceEncodedSHA256,
              s.canonicalIdentity == source.identity, s.width == original.width, s.height == original.height,
              p.modelPackageSHA256 == currentModelSHA256,
              meta.width == p.resizedWidth, meta.height == p.resizedHeight,
              meta.width > 0, meta.height > 0, meta.width <= 2000, meta.height <= 2000 else { throw Failure.binding }
        let bytes = try checked(replay.values)
        guard bytes.count == meta.width * meta.height * 4,
              replay.values.SHA256 == meta.mapSHA256 else { throw Failure.binding }
        let values: [Float] = bytes.withUnsafeBytes { raw in
            (0..<(bytes.count / 4)).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
        }
        let grid = NativeMainEnsembleDBCapability.Grid(sourceWidth: s.width, sourceHeight: s.height,
            resizedWidth: p.resizedWidth, resizedHeight: p.resizedHeight,
            regionX: 0, regionY: 0, regionWidth: p.resizedWidth, regionHeight: p.resizedHeight,
            width: meta.width, height: meta.height, values: values)
        let record = NativeMainEnsembleDBCapability.Record(source: s, producer: p, grid: grid,
            mapSHA256: meta.mapSHA256, origin: .authenticatedReplay)
        try NativeMainEnsembleDBCapability.validate(record, expected: key)
        return .init(original: original, width: meta.width, height: meta.height, values: values, capability: record)
    }
    private static func assertReader(_ regions: [ReaderTranslationRegion], rows: [[String: Any]]) throws {
        guard regions.count == rows.count else { throw Failure.changedReader }
        for (r, row) in zip(regions, rows) {
            guard r.id == row["id"] as? String, r.source == row["source"] as? String,
                  bits(r.confidence) == row["confidenceF64"] as? String,
                  r.polygon.map({ [bits(Double($0.x)), bits(Double($0.y))] }) == row["polygonF64"] as? [[String]],
                  [r.rect.minX, r.rect.minY, r.rect.width, r.rect.height].map({ bits(Double($0)) }) == row["rectF64"] as? [String],
                  r.acceptedSource.membership?.body.sorted() == row["body"] as? [Int],
                  r.acceptedSource.membership?.readings.sorted() == row["readings"] as? [Int],
                  r.acceptedSource.membership?.unknownDedup.sorted() == row["unknownDedup"] as? [Int] else { throw Failure.changedReader }
        }
    }

    @MainActor
    static func run(root: URL, arguments: [String], render: Render) async -> Int32 {
        var output: URL?
        var audit: [String: Any] = ["schema": "matched-reader-actual-renderqa-result-v1", "LLMCalls": 0,
            "HTTPClientConstructed": false, "exactHTTPResponseSynthesized": false,
            "approximateRenderQAOnly": true, "semanticTranslationAccuracyProof": false,
            "wholeOriginalVisualOpened": false, "TESTPages": 0]
        do {
            guard arguments.count == 2 else { throw Failure.request }
            let requestBytes = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
            let request = try JSONDecoder().decode(Request.self, from: requestBytes)
            let detBudget = request.freshDetectorBudget ?? 0, aotBudget = request.freshAOTBudget ?? 0
            let fresh = detBudget != 0 || aotBudget != 0
            let mixedPreservationCanary = request.pageID == "0229"
            let changedGroupingCanary = request.pageID == "0158"
            // A caller can approve one exact local capture request, not a
            // page range or a bypass for a zero-budget replay. Fail closed
            // unless the current binary itself observed the same Reader rows.
            let sealedGroupingCapture = !mixedPreservationCanary && !changedGroupingCanary && request.pageID != "0636"
                && detBudget == 1 && aotBudget == 1
                && request.DBProbabilityReplay == nil && request.AOTRawReplayIndex == nil
                && ProcessInfo.processInfo.environment["AIDOKU_CANARY_CAPTURE_AOT"] == "1"
                && ProcessInfo.processInfo.environment["AIDOKU_APPROVED_MATCHED_CAPTURE_SHA256"] == HostModuleBank.digest(requestBytes)
            // One held-out smoke source with a known saved keep/drop pair.
            // This cannot select a rule or authorize another DEV page.
            let sealedDEVCanary = sealedGroupingCapture && request.pageID == "0725"
            guard request.schema == "matched-reader-actual-renderqa-request-v1",
                  request.targetLanguage == "ko",
                  (0...1).contains(detBudget), (0...1).contains(aotBudget),
                  !fresh || request.pageID == "0636" || mixedPreservationCanary ||
                    (changedGroupingCanary && detBudget == 1 && aotBudget == 1) || sealedGroupingCapture,
                  ProcessInfo.processInfo.environment["AIDOKU_HOST_RF_RAW_MODE"] == "replay-only",
                  HostBuildMode.savedReaderReplay,
                  NativePostLLMContentReclassifier.activePolicy == .normalizedCorroboration else { throw Failure.request }
            let readerBytes = try checked(request.readerRequest)
            let reader = try JSONDecoder().decode(HostObservedReaderStage.Request.self, from: readerBytes)
            guard reader.recognitionBank == "old-authenticated-module", reader.changedRecognition == nil,
                  ["all-post-bbox", "observed-scheduled"].contains(reader.preRecognition),
                  reader.RFArchive == ProcessInfo.processInfo.environment["AIDOKU_HOST_RF_RAW_ARCHIVE"],
                  let spec = reader.pages.first(where: { $0.pageID == request.pageID }),
                  ["train", "dev"].contains(spec.split),
                  (!fresh && request.pageID != "0636" && !mixedPreservationCanary && !changedGroupingCanary) ||
                    spec.split == (sealedDEVCanary ? "dev" : "train") else { throw Failure.unsupported }
            let index = try object(checked(request.readerIndex))
            guard index["complete"] as? Bool == true, index["failures"] as? Int == 0,
                  let indexRows = index["pages"] as? [[String: Any]],
                  let indexRow = indexRows.first(where: { $0["pageID"] as? String == spec.pageID }),
                  let stagePath = indexRow["path"] as? String, let stageSHA = indexRow["SHA256"] as? String else { throw Failure.binding }
            let stage = try object(checked(.init(path: stagePath, SHA256: stageSHA)))
            guard stage["requestSHA256"] as? String == request.readerRequest.SHA256,
                  stage["observationComplete"] as? Bool == true,
                  stage["sourceEncodedSHA256"] as? String == spec.sourceEncodedSHA256,
                  let stageRegions = stage["outputRegions"] as? [[String: Any]] else { throw Failure.binding }
            let manifest = try object(checked(request.matchedManifest))
            guard manifest["GTUsedAtRuntime"] as? Bool == false, manifest["TESTPages"] as? Int == 0,
                  manifest["readerIndexSHA256"] as? String == request.readerIndex.SHA256,
                  let matches = manifest["pages"] as? [[String: Any]],
                  let match = matches.first(where: { $0["pageID"] as? String == spec.pageID || $0["page_id"] as? String == spec.pageID }),
                  match["readerTraceSHA256"] as? String == stageSHA,
                  match["sourceEncodedSHA256"] as? String == spec.sourceEncodedSHA256,
                  let inputPath = match["inputPath"] as? String, let inputSHA = match["inputSHA256"] as? String else { throw Failure.binding }
            let matched = try JSONDecoder().decode(HostMatchedLLMFilterReplay.Input.self,
                from: checked(.init(path: inputPath, SHA256: inputSHA)))
            guard matched.encodedImageSHA256 == spec.sourceEncodedSHA256 else { throw Failure.binding }
            let plan = HostMatchedRenderPlan.build(matched)
            guard plan.entries.contains(where: { !$0.preserveWithoutTarget && $0.approximateTarget != nil }) else { throw Failure.noRenderableTarget }
            if sealedGroupingCapture {
                let binary = try HostRenderProvenance.fileSHA256(URL(fileURLWithPath: CommandLine.arguments[0]))
                guard reader.selectionBasis == "code_smoke_only", reader.pages.count <= 2,
                      reader.pages.allSatisfy({ $0.split == (sealedDEVCanary ? "dev" : "train") }),
                      (index["identity"] as? [String: Any])?["consumerBinarySHA256"] as? String == binary,
                      stage["consumerBinarySHA256"] as? String == binary,
                      stage["newPPOCRPredictions"] as? Int == 0, stage["newRECPredictions"] as? Int == 0,
                      stage["newRFPredictions"] as? Int == 0, stage["providerInvoked"] as? Bool == false,
                      NativeParagraphFragmentGrouping.policyVersion.hasSuffix("-vertical-endfree-v1"),
                      let historical = match["historicalInputReference"] as? [String: String],
                      let path = historical["path"], let sha = historical["SHA256"] else { throw Failure.binding }
                let saved = try JSONDecoder().decode(HostMatchedLLMFilterReplay.Input.self,
                    from: checked(.init(path: path, SHA256: sha)))
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                guard saved.encodedImageSHA256 == spec.sourceEncodedSHA256,
                      try encoder.encode(saved.candidates) == encoder.encode(matched.candidates) else { throw Failure.binding }
                if sealedDEVCanary {
                    guard reader.pages.count == 1, indexRows.count == 1,
                          spec.sourceEncodedSHA256 == "c2ef6fe1106d666b007f408bca4870f4a5090c4d9f8e68a72ec8c032183dd743",
                          sha == "7b9164c6e7cb6cd12f9b8bd638182697dc7d2bd82facb9fe7f6c1c5d64c42d40",
                          stageRegions.count == 2, plan.entries.count == 2,
                          plan.entries.allSatisfy({ $0.matchStatus == "matched_existing_LLM_filter_simulation" &&
                              $0.approximateTarget != nil }),
                          plan.entries.filter({ $0.cachedKeep && $0.contentClass == "story_text" }).map(\.id) ==
                              ["simple-native-line-0"],
                          plan.entries.filter({ !$0.cachedKeep && $0.contentClass == "background" }).map(\.id) ==
                              ["native-line-2"] else { throw Failure.binding }
                    audit["exactHeldOutSourceSmoke"] = true
                }
                audit["exactRequestApprovedForLocalGroupingCapture"] = true
            }
            if mixedPreservationCanary {
                // This host-only allowance exists solely for one authenticated
                // mixed known/unknown source. Never widen the inference budget
                // based on the caller's page name or on an approximate match.
                guard spec.sourceEncodedSHA256 == "3dc0680bdf1be6b0e4e4e8e3be1ce7c4a3dbf7503ce2713085a64eb67c6defbd",
                      plan.entries.count == 3,
                      plan.entries.filter({ $0.cachedKeep && !$0.preserveWithoutTarget && $0.contentClass == "story_text" })
                        .map(\.id).sorted() == ["native-line-0", "native-line-1"],
                      plan.entries.filter(\.preserveWithoutTarget).map(\.id) == ["native-line-2"] else { throw Failure.binding }
            }
            if changedGroupingCanary {
                let currentBinary = try HostRenderProvenance.fileSHA256(URL(fileURLWithPath: CommandLine.arguments[0]))
                let focus = stageRegions.filter { $0["id"] as? String == "simple-native-line-1" }
                let targets = plan.entries.filter { $0.approximateTarget != nil }
                guard let historical = manifest["historicalInputReference"] as? [String: String],
                      let historicalPath = historical["path"],
                      historical["SHA256"] == "7b2ad04bf9aa7f724c7e7f89c20e72a7bae007419ea1da0d4797b7634216a600"
                else { throw Failure.binding }
                let historicalInput = try JSONDecoder().decode(HostMatchedLLMFilterReplay.Input.self,
                    from: checked(.init(path: historicalPath, SHA256: historical["SHA256"]!)))
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                guard historicalInput.encodedImageSHA256 == spec.sourceEncodedSHA256,
                      try encoder.encode(historicalInput.candidates) == encoder.encode(matched.candidates)
                else { throw Failure.binding }
                let groupingPolicy = NativeParagraphFragmentGrouping.policyVersion
                // Later grouping may reuse the archived 0158 artifacts only
                // as a zero-budget replay. The actual Reader roster below and
                // the independently reconstructed DET/AOT keys must still bind.
                let acceptedArchiveOrder = groupingPolicy.hasSuffix("-conflict-060-030-vertical-endfree-v1")
                    || groupingPolicy.hasSuffix("-conflict-060-030-vertical-endfree-v1-column-order-v3")
                let exactArchiveReplay = !fresh && request.DBProbabilityReplay != nil && request.AOTRawReplayIndex != nil
                    && acceptedArchiveOrder
                // A fresh model call is allowed only after the same binary
                // observed the changed packet roster and authenticated a saved
                // one-to-one approximate target. Same bytes do not certify a translation.
                guard spec.sourceEncodedSHA256 == "fefbab17b7242cd352ba1dca9939f07f18b7d4900a0137632c1e1c62c0b4b384",
                      reader.selectionBasis == "code_smoke_only", reader.pages.count == 1, indexRows.count == 1,
                      (index["identity"] as? [String: Any])?["consumerBinarySHA256"] as? String == currentBinary,
                      stage["consumerBinarySHA256"] as? String == currentBinary,
                      stage["newPPOCRPredictions"] as? Int == 0, stage["newRECPredictions"] as? Int == 0,
                      stage["newRFPredictions"] as? Int == 0, stage["providerInvoked"] as? Bool == false,
                      groupingPolicy.hasSuffix("-conflict-060-030") || exactArchiveReplay,
                      stageRegions.count == 18, plan.entries.count == 18, targets.count == 17,
                      focus.count == 1, focus[0]["body"] as? [Int] == [0, 1, 3],
                      let entry = targets.first(where: { $0.id == "simple-native-line-1" }),
                      entry.cachedKeep, entry.contentClass == "dialogue",
                      entry.matchStatus == "matched_existing_LLM_filter_simulation",
                      let target = entry.approximateTarget,
                      HostModuleBank.digest(Data(target.utf8)) == "25c8fe3d1bc86e08ec490a8a1437b75b28a214e81e15b623c22834d30771e7e0",
                      !fresh || (request.DBProbabilityReplay == nil && request.AOTRawReplayIndex == nil &&
                        ProcessInfo.processInfo.environment["AIDOKU_CANARY_CAPTURE_AOT"] == "1")
                else { throw Failure.binding }
            }
            if let reference = request.AOTRawReplayIndex {
                _ = try checked(reference)
                try NativeMainAOTBackend.shared.configureRawPredictionReplay(.init(
                    indexFile: URL(fileURLWithPath: reference.path), expectedIndexSHA256: reference.SHA256))
            }
            let directory = URL(fileURLWithPath: request.outputDirectory)
            guard !FileManager.default.fileExists(atPath: directory.path) else { throw Failure.request }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); output = directory
            let sourceURL = URL(fileURLWithPath: spec.source)
            try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("input.png"), withDestinationURL: sourceURL)
            let dump = HostDumpContext(directory: directory, quiet: true, sourceURL: sourceURL)
            audit["requestSHA256"] = HostModuleBank.digest(requestBytes); audit["pageID"] = spec.pageID
            audit["sourceEncodedSHA256"] = spec.sourceEncodedSHA256; audit["freshDetectorBudget"] = detBudget; audit["freshAOTBudget"] = aotBudget
            audit["readerTraceSHA256"] = stageSHA; audit["matchedInputSHA256"] = inputSHA
            audit["selectionReason"] = mixedPreservationCanary
                ? "TRAIN0229 has two one-to-one approximate targets and one held original owner"
                : changedGroupingCanary
                    ? "TRAIN0158 changed grouping joins observed packets 0,1,3; saved one-to-one targets are approximate"
                    : "Exact-source matched targets from the saved Reader ledger"
            audit["consumerBinarySHA256"] = try HostRenderProvenance.fileSHA256(URL(fileURLWithPath: CommandLine.arguments[0]))
            audit["postLLMPolicy"] = NativePostLLMContentReclassifier.activePolicy.version
            audit["sourceInferencePolicy"] = NativeSourceInferencePolicy.cacheProjection
            try JSONEncoder().encode(plan).write(to: directory.appendingPathComponent("matched-render-plan.json"), options: .atomic)
            try await HostDump.$context.withValue(dump) {
                let page = try HostObservedOCRReplay.loadObservedBank(directory: URL(fileURLWithPath: spec.directory), sourceURL: sourceURL,
                    expected: spec.contract, expectedManifestSHA256: spec.moduleManifestSHA256)
                guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure.binding }
                let context = HostObservedReaderInput.Context(page: page, expectedReaderConfiguration: reader.configuration,
                    preRecognition: reader.preRecognition == "all-post-bbox" ? .allPostBBox : .observedScheduled,
                    recognitionAdmission: reader.recognitionAdmission, deduplication: reader.deduplication)
                let evaluated = try await HostObservedReaderInput.evaluate(context: context) {
                    let regions = try await ReaderOCRService.shared.recognize(image: image, configuration: reader.configuration)
                    return .init(regions: regions, phases: await ReaderOCRService.shared.lastPhaseMilliseconds)
                }
                try assertReader(evaluated.regions, rows: stageRegions)
                guard matched.owners.count == evaluated.regions.count else { throw Failure.binding }
                var regions = evaluated.regions
                for i in regions.indices {
                    let owner = matched.owners[i], entry = plan.entries[i], r = regions[i]
                    guard owner.id == r.id, entry.id == r.id, owner.source == r.source,
                          owner.bounds == [Double(r.rect.minX), Double(r.rect.minY), Double(r.rect.width), Double(r.rect.height)] else { throw Failure.binding }
                    if let target = entry.approximateTarget, let role = entry.contentClass.flatMap(RemoteTranslationTextRole.init(rawValue:)) {
                        let rawSFX = role == .sfx || (!entry.cachedKeep && [.dialogue, .narration, .storyText].contains(role))
                        regions[i].applyTranslation(.init(id: r.id, text: target, isSFX: rawSFX, textRole: role))
                    } else {
                        regions[i].translation = r.source
                        regions[i].translationRecoveryFailure = "cached-target-unobserved-preserve-original-no-erasure"
                    }
                    regions[i].translationReuseIdentity = nil // Approximation is never an exact reuse identity.
                }
                let renderable = regions.filter { $0.translation != nil && !$0.preservesOriginalText }
                guard !renderable.isEmpty else { throw Failure.noRenderableTarget }
                audit["actualReaderOwners"] = regions.count; audit["approximateRenderableOwners"] = renderable.count
                audit["preservedOriginalOwners"] = regions.count - renderable.count
                // Resolve/stamp ONLY the current DET resource before the sole
                // authorized ensure. The nested renderer is cache-only and may
                // not repair a changed model/capability by another prediction.
                try HostResources.prepare(root: root, tier: reader.configuration.modelTier,
                    renderOnly: true, detectorOnly: true)
                if let replay = request.DBProbabilityReplay {
                    guard detBudget == 0 else { throw Failure.request }
                    let metadata = try JSONDecoder().decode(DBMetadata.self, from: checked(replay.metadata))
                    guard let model = HostResources.bundle.url(forResource: metadata.expected.producer.modelResource,
                        withExtension: "mlmodelc") else { throw Failure.binding }
                    let published = try NativeCoreMLModelStore.shared.modelURL(for: model)
                    let currentSHA = try NativeCoreMLModelStore.shared.packageContentSHA256(at: published)
                    let probability = try probabilityReplay(replay, original: image,
                        sourceEncodedSHA256: spec.sourceEncodedSHA256, currentModelSHA256: currentSHA)
                    try NativeMainEnsembleEvidenceStore.shared.register(probability: probability)
                    audit["DBProbabilityReplay"] = ["metadataSHA256": replay.metadata.SHA256,
                        "valuesSHA256": replay.values.SHA256, "captureReceiptSHA256": replay.captureReceipt.SHA256,
                        "origin": "authenticatedReplay", "actualInstalledModelSHA256": currentSHA,
                        "independentCurrentExpectationRequired": true, "freshDetectorFallbackAllowed": false]
                }
                // True current map computation is optional and capped by the
                // production resolver. Retain its lease through the renderer.
                let db = try await ReaderOCRService.shared.ensureSourceProbability(original: image,
                    configuration: reader.configuration, allowOneCurrentDetector: detBudget == 1)
                guard db.detectorCalls <= detBudget else { throw Failure.binding }
                audit["actualDetectorCalls"] = db.detectorCalls
                if request.DBProbabilityReplay != nil {
                    audit["DBProbabilityReplayCurrentExpectationMatched"] = true
                    audit["DBProbabilityReplayAdmittedDetectorCalls"] = db.detectorCalls
                }
                let probability = db.probability
                try probability.values.withUnsafeBytes { try Data($0).write(to: directory.appendingPathComponent("actual-db-map.f32le"), options: .atomic) }
                try write(["schema": "actual-current-db-map-cache-v1", "sourceEncodedSHA256": spec.sourceEncodedSHA256,
                    "width": probability.width, "height": probability.height,
                    "mapSHA256": probability.capability?.mapSHA256 ?? "unavailable",
                    "expected": try JSONSerialization.jsonObject(with: JSONEncoder().encode(db.expected)),
                    "actualDetectorCalls": db.detectorCalls, "historicalProducerRebranded": false], directory.appendingPathComponent("actual-db-map.json"))
                let renderReceipt = try await render(regions, image, directory, reader.configuration, aotBudget)
                withExtendedLifetime(db) {}
                guard renderReceipt["budgetEnforcedBeforePrediction"] as? Bool == true,
                      let aotCalls = renderReceipt["actualAOTCalls"] as? Int, aotCalls <= aotBudget, aotCalls >= 0 else { throw Failure.binding }
                audit["renderRuntimeReceipt"] = renderReceipt
                let rf = HostRFRawReplay.diagnostics(sourceIdentity: page.contract.sourceImageIdentity)
                guard let rawRecords = rf["rawRecords"] as? [[String: Any]], !rawRecords.isEmpty,
                      rawRecords.allSatisfy({ $0["disposition"] as? String == "disk-replay" }) else { throw Failure.binding }
                audit["RFReplay"] = rf
                audit["status"] = "actual-current-source-style-renderer-completed-approximate-targets-only"
                try dump.requireComplete()
            }
            try write(audit, directory.appendingPathComponent("RESULT.json"))
            return 0
        } catch {
            audit["status"] = "unobserved-or-failed-no-synthetic-success"; audit["error"] = String(describing: error)
            if let output { try? write(audit, output.appendingPathComponent("RESULT.json")) }
            print("Matched Reader render stopped: \(error)"); return 1
        }
    }
}
