import CoreFoundation
import CoreGraphics
import Foundation
import ImageIO

/// Exact shared Reader stage execution, not a final-owner or grouping proxy.
/// Native inference is replaced at compile time; RF is authenticated replay-only.
@available(macOS 15.0, *)
enum HostObservedReaderStage {
    enum Failure: Error { case request, binding, configuration, existingOutput, unsupportedRecognitionBank, missingStage }
    struct Reference: Codable, Sendable { let path: String; let SHA256: String }
    struct ChangedRecognition: Decodable, Sendable {
        let bank: HostObservedChangedOCRReplay.Reference
        let geometry: HostObservedChangedOCRReplay.Reference
    }
    struct PageSpec: Decodable, Sendable {
        let pageID: String
        let split: String
        let source: String
        let directory: String
        let sourceEncodedSHA256: String
        let moduleManifestSHA256: String
        let contract: HostModuleBank.Contract
        let priorSourceStatus: String
    }
    struct Request: Decodable, Sendable {
        let schema: String
        let corpusSHA256: String
        let selectionBasis: String
        let outputDirectory: String
        let centralResults: Reference
        let producerManifest: Reference
        let configurationReceipt: Reference
        let configuration: ReaderOCRConfiguration
        let RFArchive: String
        let recognitionBank: String
        let changedRecognition: ChangedRecognition?
        let preRecognition: String
        let recognitionAdmission: NativeSimpleRecognitionAdmission.Configuration?
        let deduplication: NativeSimpleOCRDedup.Configuration
        let pages: [PageSpec]
    }
    private final class Trace: @unchecked Sendable {
        let lock = NSLock()
        var native: HostObservedReaderInput.Result?
        var simpleInput: [ReaderTranslationRegion]?
        var simple: NativeParagraphFragmentGrouping.SimpleResult?
        var duplicate: NativeFinalOutputDuplicateResolver.Result?
        var complement: NativeFinalOutputDuplicateResolver.Result?
        var filter: [NativeFinalOutputContentFilter.AuditRow]?
        func recordNative(_ value: HostObservedReaderInput.Result) { lock.lock(); native = value; lock.unlock() }
        func recordSimple(_ input: [ReaderTranslationRegion], _ value: NativeParagraphFragmentGrouping.SimpleResult) {
            lock.lock(); simpleInput = input; simple = value; lock.unlock()
        }
        func recordDuplicate(_ value: NativeFinalOutputDuplicateResolver.Result) { lock.lock(); duplicate = value; lock.unlock() }
        func recordComplement(_ value: NativeFinalOutputDuplicateResolver.Result) { lock.lock(); complement = value; lock.unlock() }
        func recordFilter(_ value: [NativeFinalOutputContentFilter.AuditRow]) { lock.lock(); filter = value; lock.unlock() }
    }

    private static func checked(_ reference: Reference) throws -> Data {
        let url = URL(fileURLWithPath: reference.path)
        guard try HostRenderProvenance.fileSHA256(url) == reference.SHA256 else { throw Failure.binding }
        return try Data(contentsOf: url)
    }
    private static func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    private static func exact(_ value: Any, depth: Int = 0) throws -> Any {
        guard depth < 64 else { throw Failure.request }
        if let value = value as? String { return value }
        if type(of: value) == Double.self, let n = value as? Double { return ["$f64": String(format: "%016llx", n.bitPattern)] }
        if type(of: value) == Float.self, let n = value as? Float { return ["$f32": String(format: "%08x", n.bitPattern)] }
        if type(of: value) == CGFloat.self, let n = value as? CGFloat { return ["$f64": String(format: "%016llx", Double(n).bitPattern)] }
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
            if String(cString: n.objCType) == "d" { return ["$f64": String(format: "%016llx", n.doubleValue.bitPattern)] }
            if String(cString: n.objCType) == "f" { return ["$f32": String(format: "%08x", n.floatValue.bitPattern)] }
            return n
        }
        if value is NSNull { return NSNull() }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let item = mirror.children.first else { return NSNull() }
            return try exact(item.value, depth: depth + 1)
        }
        if let raw = value as? any RawRepresentable { return try exact(raw.rawValue, depth: depth + 1) }
        if mirror.displayStyle == .collection || mirror.displayStyle == .set {
            return try mirror.children.map { try exact($0.value, depth: depth + 1) }
        }
        var object: [String: Any] = [:]
        if mirror.displayStyle == .dictionary {
            for child in mirror.children {
                let pair = Array(Mirror(reflecting: child.value).children)
                guard pair.count == 2, let key = pair[0].value as? String else { throw Failure.request }
                object[key] = try exact(pair[1].value, depth: depth + 1)
            }
        } else {
            guard mirror.displayStyle == .struct || mirror.displayStyle == .tuple else { throw Failure.request }
            for (index, child) in mirror.children.enumerated() {
                object[child.label ?? String(index)] = try exact(child.value, depth: depth + 1)
            }
        }
        return object
    }
    private static func polygon(_ value: [CGPoint]) -> [[String]] {
        value.map { [String(format: "%016llx", Double($0.x).bitPattern), String(format: "%016llx", Double($0.y).bitPattern)] }
    }
    private static func region(_ value: ReaderTranslationRegion, native: HostObservedReaderInput.Result?) throws -> [String: Any] {
        var object: [String: Any] = ["id": value.id, "source": value.source,
            "polygonF64": polygon(value.polygon), "coordinateSpace": "normalized-original-top-left",
            "rectF64": [value.rect.minX, value.rect.minY, value.rect.width, value.rect.height].map { String(format: "%016llx", Double($0).bitPattern) },
            "confidenceF64": String(format: "%016llx", value.confidence.bitPattern),
            "orientation": value.sourceOrientation.rawValue, "translationOrder": value.translationOrder as Any? ?? NSNull(),
            "sourceRoleEvidence": try exact(value.sourceRoleEvidence as Any),
            "postLLMContentEvidence": try exact(value.postLLMContentEvidence as Any)]
        if let m = value.acceptedSource.membership {
            object["body"] = m.body.sorted(); object["readings"] = m.readings.sorted(); object["unknownDedup"] = m.unknownDedup.sorted()
            object["hasUntrackedInputs"] = m.hasUntrackedInputs; object["tablePacketCount"] = m.table.packets.count
            let sameTable = native?.lines.first?.acceptedSource.membership?.table === m.table
            if sameTable, let map = native?.originalPacketOrdinals,
               m.body.union(m.readings).union(m.unknownDedup).allSatisfy(map.indices.contains) {
                object["originalBody"] = m.body.sorted().map { map[$0] }
                object["originalReadings"] = m.readings.sorted().map { map[$0] }
                object["originalUnknownDedup"] = m.unknownDedup.sorted().map { map[$0] }
                object["originalMappingAvailable"] = true
            } else { object["originalMappingAvailable"] = false }
            if sameTable, let native, native.packetOrdinalDomain == "new-actual-rec-after-optional-gate-before-nms",
               m.body.union(m.readings).union(m.unknownDedup).allSatisfy(native.tableScheduledSourceIndices.indices.contains) {
                object["newScheduledBody"] = m.body.sorted().map { native.tableScheduledSourceIndices[$0] }
                object["newScheduledReadings"] = m.readings.sorted().map { native.tableScheduledSourceIndices[$0] }
                object["newScheduledUnknownDedup"] = m.unknownDedup.sorted().map { native.tableScheduledSourceIndices[$0] }
                object["packetOrdinalDomain"] = native.packetOrdinalDomain
            }
        } else { object["membershipAvailable"] = false }
        return object
    }

    @MainActor
    static func run(root: URL, arguments: [String]) async -> Int32 {
        do {
            guard arguments.count == 2 else { throw Failure.request }
            let requestURL = URL(fileURLWithPath: arguments[1])
            let bytes = try Data(contentsOf: requestURL)
            let requestSHA = HostModuleBank.digest(bytes)
            let request = try JSONDecoder().decode(Request.self, from: bytes)
            guard request.schema == "aidoku-observed-reader-stage-request-v1",
                  request.corpusSHA256 == "ed45e6ea008c7b8d410a827548f7d06a5c8ec3238e900e21601af4a43e42d739",
                  ["old-authenticated-module", "changed-quad-actual-v3-incident"].contains(request.recognitionBank),
                  !request.pages.isEmpty, request.pages.count <= 685,
                  Set(request.pages.map(\.pageID)).count == request.pages.count,
                  request.pages.allSatisfy({ ["train", "dev"].contains($0.split) }),
                  ["full_train_dev", "code_smoke_only"].contains(request.selectionBasis),
                  HostBuildMode.savedReaderReplay,
                  ProcessInfo.processInfo.environment["AIDOKU_HOST_RF_RAW_MODE"] == "replay-only",
                  ProcessInfo.processInfo.environment["AIDOKU_HOST_RF_RAW_ARCHIVE"] == request.RFArchive else { throw Failure.request }
            if request.selectionBasis == "full_train_dev" {
                guard request.pages.count == 685, request.pages.filter({ $0.split == "train" }).count == 506,
                      request.pages.filter({ $0.split == "dev" }).count == 179 else { throw Failure.request }
            }
            let changedBank: HostObservedChangedOCRReplay.Bank?
            if request.recognitionBank == "changed-quad-actual-v3-incident" {
                guard let changed = request.changedRecognition, request.preRecognition == "all-post-bbox" else { throw Failure.request }
                changedBank = try .init(reference: changed.bank, geometryReference: changed.geometry)
            } else {
                guard request.changedRecognition == nil else { throw Failure.request }
                changedBank = nil
            }
            let centralBytes = try checked(request.centralResults)
            guard let central = try JSONSerialization.jsonObject(with: centralBytes) as? [String: Any],
                  central["observationComplete"] as? Bool == true, let centralRows = central["pages"] as? [[String: Any]] else { throw Failure.binding }
            let centralIndex = Dictionary(uniqueKeysWithValues: centralRows.compactMap { row -> (String, [String: Any])? in
                guard let id = row["page_id"] as? String else { return nil }; return (id, row)
            })
            let producerBytes = try checked(request.producerManifest)
            let producer = try JSONDecoder().decode(HostModuleBankBootstrap.ProducerManifest.self, from: producerBytes)
            let settings = try JSONSerialization.jsonObject(with: checked(request.configurationReceipt)) as? [String: Any]
            guard let value = settings?["value"] as? [String: Any], let ocr = value["ocr"],
                  try JSONDecoder().decode(ReaderOCRConfiguration.self, from: json(ocr)) == request.configuration else { throw Failure.configuration }
            if ProcessInfo.processInfo.environment["AIDOKU_HOST_MODEL_BUNDLE"] == nil {
                guard let cache = ProcessInfo.processInfo.environment["AIDOKU_HOST_MODEL_CACHE"], Bundle(path: cache) != nil else { throw Failure.request }
                setenv("AIDOKU_HOST_MODEL_BUNDLE", cache, 1)
            }
            try HostRFRawReplay.preflight()
            guard let model = HostResources.bundle.url(forResource: NativeRFDETRLayoutResource.resourceName, withExtension: "mlmodelc"),
                  let expectedModel = request.pages.first?.contract.modelSHA256["rf-detr"],
                  try HostRFRawReplay.treeDigest(model) == expectedModel else { throw Failure.binding }
            let selection: HostObservedOCRReplay.PreRecognition
            switch request.preRecognition {
            case "all-post-bbox": selection = .allPostBBox
            case "observed-scheduled": selection = .observedScheduled
            default: throw Failure.request
            }
            let output = URL(fileURLWithPath: request.outputDirectory)
            try FileManager.default.createDirectory(at: output.appendingPathComponent("pages"), withIntermediateDirectories: true)
            let consumer = try HostRenderProvenance.fileSHA256(URL(fileURLWithPath: CommandLine.arguments[0]))
            let identity: [String: Any] = ["requestSHA256": requestSHA, "consumerBinarySHA256": consumer,
                "consumerPipelineFingerprint": ProcessInfo.processInfo.environment["AIDOKU_PIPELINE_FINGERPRINT"] ?? "unavailable"]
            let identityFile = output.appendingPathComponent("identity.json")
            if FileManager.default.fileExists(atPath: identityFile.path) {
                guard try Data(contentsOf: identityFile) == json(identity) else { throw Failure.existingOutput }
            } else { try json(identity).write(to: identityFile, options: .atomic) }
            let service = ReaderOCRService()
            var rows: [[String: Any]] = []
            for spec in request.pages {
                let file = output.appendingPathComponent("pages/\(spec.pageID).json")
                var row: [String: Any] = ["pageID": spec.pageID, "split": spec.split,
                    "sourceEncodedSHA256": spec.sourceEncodedSHA256, "priorSourceFactoryStatus": spec.priorSourceStatus,
                    "requestSHA256": requestSHA, "consumerBinarySHA256": consumer]
                do {
                    guard let rootRow = centralIndex[spec.pageID], rootRow["sourceEncodedSHA256"] as? String == spec.sourceEncodedSHA256,
                          rootRow["split"] as? String == spec.split,
                          let qualification = rootRow["qualification"] as? [String: Any],
                          qualification["moduleManifestSHA256"] as? String == spec.moduleManifestSHA256,
                          spec.contract.sourceEncodedSHA256 == spec.sourceEncodedSHA256,
                          spec.contract.producerSHA256 == producer.producerSHA256,
                          spec.contract.stageSchemas == producer.stageSchemas else { throw Failure.binding }
                    let page = try HostObservedOCRReplay.loadObservedBank(directory: URL(fileURLWithPath: spec.directory),
                        sourceURL: URL(fileURLWithPath: spec.source), expected: spec.contract, expectedManifestSHA256: spec.moduleManifestSHA256)
                    guard let imageSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: spec.source) as CFURL, nil),
                          let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { throw Failure.binding }
                    let context = HostObservedReaderInput.Context(page: page, expectedReaderConfiguration: request.configuration,
                        preRecognition: selection, recognitionAdmission: request.recognitionAdmission, deduplication: request.deduplication,
                        changedCoreReplay: changedBank.map { bank in
                            { @Sendable in
                                let result = try bank.replay(pageID: spec.pageID, original: page,
                                    expectedOriginalModuleSHA256: spec.moduleManifestSHA256,
                                    recognitionAdmission: request.recognitionAdmission, deduplication: request.deduplication)
                                var receipt = try JSONSerialization.jsonObject(with: result.receipt) as! [String: Any]
                                receipt["boundaryCorrection"] = try exact(result.correction)
                                return .init(lines: result.lines, geometry: result.geometry.individuals,
                                    selectedBoxes: page.postBBox.individuals.count,
                                    tableScheduledSourceIndices: result.tableScheduledSourceIndices, receipt: try json(receipt))
                            }
                        })
                    let trace = Trace()
                    let result = try await HostObservedReaderInput.$observer.withValue({ trace.recordNative($0) }) {
                        try await NativeParagraphFragmentGrouping.$simpleNativeObserver.withValue({ trace.recordSimple($0, $1) }) {
                            try await NativeFinalOutputDuplicateResolver.$observer.withValue({ trace.recordDuplicate($0) }) {
                                try await NativeFinalOutputContentFilter.$observer.withValue({ trace.recordFilter($0) }) {
                                    try await NativeFinalOutputDuplicateResolver.$complementObserver.withValue({ trace.recordComplement($0) }) {
                                        try await HostObservedReaderInput.evaluate(context: context) {
                                            let regions = try await service.recognize(image: image, configuration: request.configuration)
                                            return .init(regions: regions, phases: await service.lastPhaseMilliseconds)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    guard let native = trace.native, let simpleInput = trace.simpleInput, let simple = trace.simple,
                          let duplicate = trace.duplicate, let filter = trace.filter else { throw Failure.missingStage }
                    let rf = HostRFRawReplay.diagnostics(sourceIdentity: page.contract.sourceImageIdentity)
                    guard let records = rf["rawRecords"] as? [[String: Any]], !records.isEmpty,
                          records.allSatisfy({ $0["disposition"] as? String == "disk-replay" }) else { throw Failure.binding }
                    row["status"] = "observed-current-reader-success"; row["observationComplete"] = true
                    row["native"] = ["width": native.width, "height": native.height,
                        "originalPacketOrdinals": native.originalPacketOrdinals,
                        "lines": native.lines.map { ["polygonF64": polygon($0.polygon), "source": $0.text,
                            "confidenceF64": String(format: "%016llx", $0.score.bitPattern)] }]
                    row["literalSimpleInput"] = try simpleInput.map { try region($0, native: native) }
                    row["simpleGrouped"] = try simple.regions.map { try region($0, native: native) }
                    row["simpleOutcome"] = simple.outcome.rawValue
                    row["finalDuplicate"] = ["keep": duplicate.keep, "aliases": try exact(duplicate.aliases)]
                    if let complement = trace.complement {
                        row["postAdmissionComplementDuplicate"] = ["keep": complement.keep, "aliases": try exact(complement.aliases)]
                    }
                    row["finalFilterInputAndDecisions"] = try exact(filter)
                    row["outputRegions"] = try result.regions.map { try region($0, native: native) }
                    row["phases"] = try exact(result.phases); row["RFReplay"] = rf
                    row["actualObservedEmptyOutput"] = result.regions.isEmpty
                    if changedBank != nil {
                        row["recognitionBank"] = request.recognitionBank
                        row["preclaimIncident"] = true
                        row["newCoreBankReceipt"] = try native.recognitionBankReceipt.map { try JSONSerialization.jsonObject(with: $0) } ?? NSNull()
                        row["newCoreGeometry"] = try exact(native.individualGeometry)
                        row["newTableScheduledSourceIndices"] = native.tableScheduledSourceIndices
                        row["packetOrdinalDomain"] = native.packetOrdinalDomain
                    }
                    row["sourceFactoryInvoked"] = false; row["providerInvoked"] = false; row["AOTInvoked"] = false
                    row["newPPOCRPredictions"] = 0; row["newRECPredictions"] = 0; row["newRFPredictions"] = 0
                } catch {
                    row["status"] = "observed-reader-stage-failure"; row["observationComplete"] = false
                    row["errorType"] = String(reflecting: type(of: error)); row["error"] = String(describing: error)
                    row["outputUnavailable"] = true // Never a fabricated empty prediction.
                }
                try json(row).write(to: file, options: .atomic)
                rows.append(["pageID": spec.pageID, "split": spec.split, "status": row["status"]!,
                    "path": file.path, "SHA256": try HostRenderProvenance.fileSHA256(file)])
                if rows.count % 25 == 0 || rows.count == request.pages.count {
                    let failures = rows.filter { $0["status"] as? String != "observed-current-reader-success" }.count
                    try json(["schema": "aidoku-observed-reader-stage-index-v1", "identity": identity,
                        "requiredPages": request.pages.count, "observedPages": rows.count, "failures": failures,
                        "complete": rows.count == request.pages.count && failures == 0, "pages": rows,
                        "NNCalls": 0, "APICalls": 0, "GTAtInference": false, "TESTPages": 0]).write(to: output.appendingPathComponent("index.json"), options: .atomic)
                }
                print("Observed Reader stage \(rows.count)/\(request.pages.count) \(spec.pageID): \(row["status"]!)")
                fflush(stdout)
            }
            return rows.allSatisfy({ $0["status"] as? String == "observed-current-reader-success" }) ? 0 : 1
        } catch { print("Observed Reader stage preflight failed: \(error)"); return 2 }
    }
}
