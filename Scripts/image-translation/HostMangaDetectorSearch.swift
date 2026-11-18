import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO

/// Offline experiment entry. Uses the production Manga detector and DB decoder;
/// labels never enter inference, and no provider, renderer or RF model is run.
enum HostMangaDetectorSearch {
    /// Private DET-only builds insert `note` immediately before the actual
    /// Core ML prediction statements. Ordinary host builds retain false.
    enum NeuralCounters {
        static let instrumented = false
        private static let lock = NSLock()
        private static var counts = [String: Int]()
        static func note(_ kind: String) { lock.lock(); counts[kind, default: 0] += 1; lock.unlock() }
        static func snapshot() -> [String: Int] { lock.lock(); defer { lock.unlock() }; return counts }
    }
    /// Apply the production language policy to verified saved merge strings only.
    /// No image, OCR model, rendering, role classifier or provider is involved.
    static func auditLanguageReview(source: URL, output: URL, root: URL) throws -> Int32 {
        try HostEnvironment.load(root: root)
        let options = try HostOptions(root: root, arguments: ["--ocr-only"])
        let settings = ReaderTranslationSettings(includePageImage: false,
            sourceLanguage: options.source, targetLanguage: options.target,
            translationSourceLanguages: options.translationSourceLanguages,
            filterSFXWithLLM: false, filterBackgroundWithLLM: false,
            rightToLeftPanelOrder: options.rtl, modelTier: options.tier)
        let bytes = try Data(contentsOf: source)
        guard let report = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let pages = report["pages"] as? [[String: Any]] else {
            throw HostError.message("Invalid saved merge review")
        }
        var rows: [[String: Any]] = []
        for page in pages {
            guard let number = page["page"] as? String, let entries = page["regions"] as? [[String: Any]] else {
                throw HostError.message("Invalid saved merge page")
            }
            let regions = try entries.map { entry -> ReaderTranslationRegion in
                guard let id = entry["id"] as? String, let text = entry["source"] as? String,
                      let r = entry["rect"] as? [String: Double],
                      let x = r["x"], let y = r["y"], let w = r["width"], let h = r["height"] else {
                    throw HostError.message("Invalid saved merge region")
                }
                return .init(id: id, rect: CGRect(x: x, y: y, width: w, height: h), source: text)
            }
            let eligible = ReaderTranslationLanguageFilter.apply(regions, settings: settings)
            rows.append(["page": number, "admittedIDs": eligible.map(\.id), "total": regions.count])
        }
        try write(["pages": rows, "sourceSHA256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            "sourceLanguage": options.source, "targetLanguage": options.target,
            "translationSourceLanguages": options.translationSourceLanguages, "modelTier": options.tier.rawValue,
            "languageFilter": "ReaderTranslationLanguageFilter.apply", "LLM_filter": false,
            "OCR_calls": 0, "provider_calls": 0], to: output)
        print("Language-only policy evaluated \(rows.count) pages")
        return 0
    }
    struct MissingReadRequest: Decodable {
        struct Box: Decodable {
            let sourceIndex: Int
            let polygon: [CGPoint]
            let samplingPolygon: [CGPoint]?
        }
        struct Page: Decodable {
            let id: String
            let source: String
            let sourceSHA256: String
            let width: Int
            let height: Int
            let boxes: [Box]
        }
        let pages: [Page]
        let output: String
        let maximumRecognitionWidth: Int
        let confidenceThreshold: Double?
    }
    final class RawReadCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var rows: [[String: Any]] = []
        func observe(_ event: NativeCoreMLRecognitionAuditEvent) {
            guard case let .decoded(requestID, region, text, confidence, threshold, cacheHit) = event else { return }
            lock.lock(); defer { lock.unlock() }
            rows.append(["requestID": requestID, "sourceIndex": region.sourceIndex,
                "text": text, "confidence": confidence, "threshold": threshold,
                "empty": text.isEmpty, "cacheHit": cacheHit])
        }
        func take() -> [[String: Any]] {
            lock.lock(); defer { lock.unlock() }
            let result = rows; rows = []; return result
        }
    }
    /// Recognition-only audit on explicitly saved polygons; no detector/provider or admission changes.
    static func recognizeMissing(request: URL, root: URL) async throws -> Int32 {
        let bytes = try Data(contentsOf: request)
        let spec = try JSONDecoder().decode(MissingReadRequest.self, from: bytes)
        let fingerprint = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard !spec.pages.isEmpty, (32...2400).contains(spec.maximumRecognitionWidth) else {
            throw HostError.message("Invalid saved recognition audit request")
        }
        // Omitted keeps the existing unfiltered audit contract. Explicit values
        // exercise production admission without changing the saved polygons.
        let threshold = spec.confidenceThreshold ?? 0
        guard threshold.isFinite, (0...1).contains(threshold) else {
            throw HostError.message("Invalid saved recognition confidence threshold")
        }
        try HostResources.prepare(root: root, tier: .manga)
        let capture = RawReadCapture()
        let recognizer = NativeCoreMLRecognizer(bundle: HostResources.bundle,
            maximumRecognitionWidth: spec.maximumRecognitionWidth, auditObserver: { capture.observe($0) })
        let out = URL(fileURLWithPath: spec.output)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for (index, page) in spec.pages.enumerated() {
            guard page.id.count == 4, page.id.allSatisfy(\.isNumber),
                  Set(page.boxes.map(\.sourceIndex)).count == page.boxes.count else {
                throw HostError.message("Invalid saved page identifiers")
            }
            let source = try Data(contentsOf: URL(fileURLWithPath: page.source))
            guard SHA256.hash(data: source).map({ String(format: "%02x", $0) }).joined() == page.sourceSHA256,
                  let imageSource = CGImageSourceCreateWithData(source as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
                  image.width == page.width, image.height == page.height else {
                throw HostError.message("Saved source image mismatch")
            }
            let regions = page.boxes.map { NativeCoreMLRecognitionRegion(sourceIndex: $0.sourceIndex,
                polygon: $0.polygon, samplingPolygon: $0.samplingPolygon) }
            guard let pixels = NativeOCRV2SourcePixelDecoder.decode(image),
                  let frame = NativeOCRRGBAFrame(width:pixels.width,height:pixels.height,
                    bytesPerRow:pixels.bytesPerRow,bytes:pixels.bytes) else {
                throw HostError.message("Saved recognition probe canonical source frame unavailable")
            }
            let result = try await recognizer.recognize(frame: frame, regions: regions,
                requestID: page.id, confidenceThreshold: threshold)
            let raw = capture.take()
            try write(["page": page.id, "requestSHA256": fingerprint, "sourceSHA256": page.sourceSHA256,
                "sourcePixelDecoderABI": NativeOCRV2SourcePixelDecoder.abi,
                "sourcePixelBytesSHA256": SHA256.hash(data:Data(pixels.bytes)).map { String(format:"%02x",$0) }.joined(),
                "modelName": result.diagnostics.modelName,
                "requested": regions.count, "rawDecodes": raw,
                "accepted": result.regions.map { ["sourceIndex": $0.sourceIndex, "text": $0.text,
                    "confidence": $0.confidence] as [String: Any] },
                "maximumRecognitionWidth": spec.maximumRecognitionWidth, "confidenceThreshold": threshold,
                "predicted": result.diagnostics.predictedRegions,
                "skippedInvalid": result.diagnostics.skippedInvalidRegions,
                "detectorCalls": 0, "providerCalls": 0], to: out.appendingPathComponent(page.id + ".json"))
            print("Saved missing OCR \(index + 1)/\(spec.pages.count): \(page.id), \(regions.count) boxes, \(raw.count) raw decodes")
            fflush(stdout)
        }
        return 0
    }
    struct Case: Decodable {
        let id: String
        let source: String
        let sourceSHA256: String
        let dimensions: [Int]
    }
    struct Request: Decodable {
        let cases: [Case]
        let output: String
        let sides: [Int]
        let pixelThresholds: [Double]
        let unclipRatios: [Double]
        let retainRawIdentity: Bool?
        let requirePredictionCounters: Bool?
        let replayRoot: String?
    }
    struct Captured: Sendable {
        let map: NativeCoreMLDetectionMap
        let geometry: NativeCoreMLDetectionMapGeometry
        let producer: NativeMainEnsembleDBCapability.Producer?
        let inputSHA256: String?
        let consumerSHA256: String?
    }
    struct RecognitionRequest: Decodable {
        let cases: [Case]
        let output: String
        let predictionRoot: String
        let detectorRequestSHA256: String
        let side: Int
        let pixelThreshold: Double
        let unclipRatio: Double
    }
    final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Captured?
        func put(_ value: Captured) { lock.lock(); stored = value; lock.unlock() }
        func take() -> Captured? { lock.lock(); defer { lock.unlock() }; let value = stored; stored = nil; return value }
    }
    static func write(_ value: [String: Any], to path: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: path, options: .atomic)
    }
    static func peakBytes() -> Int64 {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Int64(usage.ru_maxrss)
    }
    static func recognize(request: URL, root: URL) async throws -> Int32 {
        let requestData = try Data(contentsOf: request)
        let spec = try JSONDecoder().decode(RecognitionRequest.self, from: requestData)
        let fingerprint = SHA256.hash(data: requestData).map { String(format: "%02x", $0) }.joined()
        setenv("AIDOKU_DISABLE_RF_LAYOUT", "1", 1)
        setenv("AIDOKU_LEGACY_PANEL_RENDERER", "1", 1)
        try HostResources.prepare(root: root, tier: .manga)
        let recognizer = NativeCoreMLRecognizer(bundle: HostResources.bundle, maximumRecognitionWidth: 1184)
        let output = URL(fileURLWithPath: spec.output)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var complete = 0, failed = 0
        let started = ProcessInfo.processInfo.systemUptime
        for item in spec.cases {
            let path = output.appendingPathComponent(item.id + ".json")
            if let data = try? Data(contentsOf: path),
               let old = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               old["requestSHA256"] as? String == fingerprint, old["status"] as? String == "complete" {
                complete += 1
                continue
            }
            do {
                let saved = URL(fileURLWithPath: spec.predictionRoot).appendingPathComponent("\(spec.side)/\(item.id)/result.json")
                guard let detector = try JSONSerialization.jsonObject(with: Data(contentsOf: saved)) as? [String: Any],
                      detector["requestSHA256"] as? String == spec.detectorRequestSHA256,
                      detector["sourceSHA256"] as? String == item.sourceSHA256,
                      let variants = detector["variants"] as? [[String: Any]],
                      let variant = variants.first(where: { $0["pixelThreshold"] as? Double == spec.pixelThreshold
                          && $0["unclipRatio"] as? Double == spec.unclipRatio }),
                      let boxes = variant["boxes"] as? [[String: Any]] else { throw HostError.message("Detector cache mismatch") }
                let data = try Data(contentsOf: URL(fileURLWithPath: item.source), options: .mappedIfSafe)
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard digest == item.sourceSHA256,
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                      [image.width, image.height] == item.dimensions,
                      let frame = NativeOCRCGImageAdapter.makeRGBAFrame(from: image) else {
                    throw HostError.message("Recognition source mismatch")
                }
                let regions = try boxes.enumerated().map { index, box -> NativeCoreMLRecognitionRegion in
                    guard let polygon = box["polygon"] as? [[Double]], polygon.count == 4,
                          polygon.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) else {
                        throw HostError.message("Invalid cached detector polygon")
                    }
                    return .init(sourceIndex: index, polygon: polygon.map {
                        CGPoint(x: $0[0] * Double(image.width), y: $0[1] * Double(image.height))
                    })
                }
                let start = ProcessInfo.processInfo.systemUptime
                let result = try await recognizer.recognize(frame: frame, regions: regions,
                    requestID: item.id, confidenceThreshold: 0.01)
                let reads = Dictionary(uniqueKeysWithValues: result.regions.map { ($0.sourceIndex, $0) })
                let rows = boxes.enumerated().map { index, box -> [String: Any] in
                    var row = box
                    if let read = reads[index] {
                        row["text"] = read.text
                        row["recognitionConfidence"] = read.confidence
                    } else {
                        row["text"] = ""
                        row["recognitionConfidence"] = NSNull()
                    }
                    return row
                }
                let d = result.diagnostics
                try write(["id": item.id, "status": "complete", "requestSHA256": fingerprint,
                    "sourceSHA256": digest, "side": spec.side, "pixelThreshold": spec.pixelThreshold,
                    "unclipRatio": spec.unclipRatio, "recognizerWidth": 1184, "confidenceFloor": 0.01,
                    "recognitionWallMs": (ProcessInfo.processInfo.systemUptime - start) * 1000,
                    "modelWasAlreadyLoaded": d.modelWasAlreadyLoaded, "modelLoadMs": d.modelLoadMilliseconds,
                    "predictionMs": d.predictionMilliseconds, "preprocessMs": d.preprocessingMilliseconds,
                    "functionLoadMs": d.modelFunctionLoadMilliseconds,
                    "requestedRegions": d.requestedRegions, "skippedInvalidRegions": d.skippedInvalidRegions,
                    "processPeakRSSBytes": peakBytes(), "boxes": rows], to: path)
                complete += 1
            } catch {
                failed += 1
                try write(["id": item.id, "status": "failed", "requestSHA256": fingerprint,
                    "error": String(describing: error)], to: path)
                fputs("Manga recognition \(item.id): \(error)\n", stderr)
            }
            if (complete + failed) % 20 == 0 {
                print("Manga recognition \(complete) complete, \(failed) failed / \(spec.cases.count)")
                try write(["complete": complete, "failed": failed, "expected": spec.cases.count,
                    "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started,
                    "processPeakRSSBytes": peakBytes()], to: output.appendingPathComponent("progress.json"))
            }
        }
        try write(["complete": complete, "failed": failed, "expected": spec.cases.count,
            "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started,
            "processPeakRSSBytes": peakBytes()], to: output.appendingPathComponent("progress.json"))
        return failed == 0 ? 0 : 1
    }
    static func run(request: URL, root: URL) async throws -> Int32 {
        let requestData = try Data(contentsOf: request)
        let spec = try JSONDecoder().decode(Request.self, from: requestData)
        return try await NativeOCRDirectionGeometry.$mainMangaPolicy.withValue(spec.retainRawIdentity == true) {
            try await runConfigured(request: request, root: root)
        }
    }
    private static func runConfigured(request: URL, root: URL) async throws -> Int32 {
        let requestData = try Data(contentsOf: request)
        let spec = try JSONDecoder().decode(Request.self, from: requestData)
        if let replayRoot = spec.replayRoot {
            return try runMapReplay(spec: spec, root: URL(fileURLWithPath: replayRoot), requestData: requestData)
        }
        let retainsIdentity = spec.retainRawIdentity == true
        guard spec.requirePredictionCounters != true || NeuralCounters.instrumented else {
            throw HostError.message("DET-only request requires a separately instrumented private producer")
        }
        guard !spec.cases.isEmpty, !spec.sides.isEmpty,
              Set(spec.cases.map(\.id)).count == spec.cases.count,
              spec.cases.allSatisfy({ !$0.id.isEmpty && $0.id.allSatisfy(\.isNumber) && $0.dimensions.count == 2 }),
              spec.sides.allSatisfy({ (32...1184).contains($0) }),
              spec.pixelThresholds.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              spec.unclipRatios.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw HostError.message("Invalid Manga search request")
        }
        // Model preparation compiles/reuses only Manga OCR resources.
        setenv("AIDOKU_DISABLE_RF_LAYOUT", "1", 1)
        setenv("AIDOKU_LEGACY_PANEL_RENDERER", "1", 1)
        try HostResources.prepare(root: root, tier: .manga, renderOnly: true, detectorOnly: true)
        let output = URL(fileURLWithPath: spec.output)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var fingerprintData = requestData
        if retainsIdentity { fingerprintData.append(Data(("|inputABI=" + NativeCoreMLDetectionPreprocessor.provenanceABI).utf8)) }
        let fingerprint = SHA256.hash(data: fingerprintData).map { String(format: "%02x", $0) }.joined()
        let binarySHA = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0])))
            .map { String(format: "%02x", $0) }.joined()
        let producerManifestPath = ProcessInfo.processInfo.environment["AIDOKU_DET_ONLY_BUILD_MANIFEST"]
        let producerManifestSHA = try producerManifestPath.map {
            SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: $0))).map { String(format: "%02x", $0) }.joined()
        }
        guard !retainsIdentity || producerManifestSHA != nil else {
            throw HostError.message("DET-only identity export requires an immutable compiled producer manifest")
        }
        var completed = 0, failed = 0
        let start = ProcessInfo.processInfo.systemUptime
        for side in spec.sides {
            let detector = NativeCoreMLDetector(bundle: HostResources.bundle, maximumSide: side)
            for item in spec.cases {
                let directory = output.appendingPathComponent("\(side)/\(item.id)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let resultPath = directory.appendingPathComponent("result.json")
                if let data = try? Data(contentsOf: resultPath),
                   let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   saved["requestSHA256"] as? String == fingerprint,
                   saved["status"] as? String == "complete",
                   !retainsIdentity || (saved["binarySHA256"] as? String == binarySHA
                       && saved["producerManifestSHA256"] as? String == producerManifestSHA
                       && saved["inputABI"] as? String == NativeCoreMLDetectionPreprocessor.provenanceABI
                       && saved["sourceSHA256"] as? String == item.sourceSHA256
                       // Optional equality must not accept a missing map and missing SHA as nil == nil.
                       && (saved["mapSHA256"] as? String) != nil
                       && (try? Data(contentsOf: directory.appendingPathComponent("probability.f32"))).map {
                           SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
                       } == saved["mapSHA256"] as? String) {
                    completed += 1
                    continue
                }
                do {
                    let data = try Data(contentsOf: URL(fileURLWithPath: item.source), options: .mappedIfSafe)
                    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    guard digest == item.sourceSHA256,
                          let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
                          let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
                          [image.width, image.height] == item.dimensions,
                          let frame = NativeOCRCGImageAdapter.makeRGBAFrame(from: image) else {
                        throw HostError.message("Source identity/geometry/decode mismatch: \(item.id)")
                    }
                    let captured = Capture()
                    let countersBefore = NeuralCounters.snapshot()
                    if retainsIdentity {
                        let attempt = directory.appendingPathComponent("model-submission.json")
                        guard !FileManager.default.fileExists(atPath: attempt.path) else {
                            throw HostError.message("Previously submitted DET case refuses a duplicate neural call")
                        }
                        try write(["requestSHA256": fingerprint, "sourceSHA256": digest,
                            "binarySHA256": binarySHA, "inputABI": NativeCoreMLDetectionPreprocessor.provenanceABI,
                            "state": "one-detector-submission-admitted-no-automatic-retry"], to: attempt)
                    }
                    let inferenceStart = ProcessInfo.processInfo.systemUptime
                    let result = try await detector.detect(frame: frame, requestID: item.id,
                        configuration: .init(threshold: retainsIdentity ? 0.85 : 0.15,
                                             boxThreshold: retainsIdentity ? 0.25 : 0.01, unclipRatio: 1.4,
                                             maximumCandidates: 3000, minimumBoxSide: 3),
                        recognitionScopes: nil, probabilityObserver: { sample in
                            captured.put(.init(map: .init(width: sample.width, height: sample.height, values: sample.values),
                                geometry: .init(originX: Int(sample.region.minX), originY: Int(sample.region.minY),
                                                fullWidth: sample.resizedWidth, fullHeight: sample.resizedHeight),
                                producer: sample.producer, inputSHA256: sample.detectorInputIdentity,
                                consumerSHA256: sample.consumerConfigurationSHA256))
                            return .init(status: .registered, width: sample.width, height: sample.height)
                        }, cancellationCheck: {})
                    let detectorWallMs = (ProcessInfo.processInfo.systemUptime - inferenceStart) * 1000
                    guard let capture = captured.take() else { throw HostError.message("No probability map") }
                    let countersAfter = NeuralCounters.snapshot()
                    let actualDETCalls = countersAfter["det", default: 0] - countersBefore["det", default: 0]
                    let warmupCalls = countersAfter["warmup", default: 0] - countersBefore["warmup", default: 0]
                    if spec.requirePredictionCounters == true {
                        guard actualDETCalls == 1, warmupCalls == 0 else {
                            throw HostError.message("DET-only neural budget violated")
                        }
                    }
                    if retainsIdentity {
                        guard let producer = capture.producer, let inputSHA = capture.inputSHA256, inputSHA.count == 64,
                              producer.preprocessABI == NativeCoreMLDetectionPreprocessor.provenanceABI,
                              producer.preprocessSHA256 == NativeCoreMLDetectionPreprocessor.normalizationConfigurationSHA256,
                              capture.geometry.originX == 0, capture.geometry.originY == 0,
                              capture.map.width == producer.resizedWidth, capture.map.height == producer.resizedHeight,
                              capture.geometry.fullWidth == producer.resizedWidth, capture.geometry.fullHeight == producer.resizedHeight
                        else { throw HostError.message("Missing actual producer/input/full content map identity") }
                    }
                    try capture.map.values.withUnsafeBytes { bytes in
                        guard let base = bytes.baseAddress else { throw HostError.message("Empty probability map") }
                        try Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: bytes.count, deallocator: .none)
                            .write(to: directory.appendingPathComponent("probability.f32"), options: .atomic)
                    }
                    let searchStart = ProcessInfo.processInfo.systemUptime
                    var variants: [[String: Any]] = []
                    for threshold in spec.pixelThresholds {
                        for unclip in spec.unclipRatios {
                            let decodeStart = ProcessInfo.processInfo.systemUptime
                            let decoded = try NativeCoreMLDBPostprocessor.decode(map: capture.map,
                                sourceWidth: image.width, sourceHeight: image.height, geometry: capture.geometry,
                                configuration: .init(threshold: threshold, boxThreshold: retainsIdentity ? 0.25 : 0.01,
                                    unclipRatio: unclip, maximumCandidates: 3000, minimumBoxSide: 3))
                            variants.append(["pixelThreshold": threshold, "unclipRatio": unclip,
                                "candidateComponents": decoded.candidateComponents,
                                "candidateLimitReached": decoded.candidateComponents >= 3000,
                                "decodeMs": (ProcessInfo.processInfo.systemUptime - decodeStart) * 1000,
                                "boxes": decoded.boxes.map { box -> [String: Any] in
                                    ["score": box.score, "polygon": box.polygon.map {
                                        [Double($0.x) / Double(image.width), Double($0.y) / Double(image.height)]
                                    }]
                                }])
                        }
                    }
                    let d = result.diagnostics
                    var record: [String: Any] = ["id": item.id, "status": "complete", "requestSHA256": fingerprint,
                        "sourceSHA256": digest, "side": side, "dimensions": item.dimensions,
                        "map": ["width": capture.map.width, "height": capture.map.height,
                            "originX": capture.geometry.originX, "originY": capture.geometry.originY,
                            "fullWidth": capture.geometry.fullWidth, "fullHeight": capture.geometry.fullHeight,
                            "dtype": "little-endian-float32", "path": "probability.f32"],
                        "detectorWallMs": detectorWallMs, "modelLoadMs": d.modelLoadMilliseconds,
                        "modelWasAlreadyLoaded": d.modelWasAlreadyLoaded,
                        "preprocessMs": d.preprocessingMilliseconds, "predictionMs": d.predictionMilliseconds,
                        "materializationMs": d.outputMaterializationMilliseconds,
                        "searchMs": (ProcessInfo.processInfo.systemUptime - searchStart) * 1000,
                        "processPeakRSSBytes": peakBytes(), "variants": variants]
                    if retainsIdentity, let producer = capture.producer {
                        record["schema"] = "actual-det-only-content-map-v2"
                        record["binarySHA256"] = binarySHA
                        record["producerManifestSHA256"] = producerManifestSHA
                        record["inputABI"] = producer.preprocessABI
                        record["detectorInputSHA256"] = capture.inputSHA256
                        record["consumerConfigurationSHA256"] = capture.consumerSHA256
                        record["mapSHA256"] = NativeMainEnsembleDBCapability.digest(capture.map.values)
                        record["producer"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(producer))
                        record["actualDETCalls"] = actualDETCalls
                        record["warmupPredictions"] = warmupCalls
                        record["RECRequested"] = false; record["RFRequested"] = false
                        record["AOTRequested"] = false; record["providerRequested"] = false
                        record["boxThreshold"] = 0.25
                        record["originalBoxes"] = result.boxes.map { box -> [String: Any] in
                            ["score": box.score, "polygon": box.polygon.map { [Double($0.x), Double($0.y)] }]
                        }
                    }
                    try write(record, to: resultPath)
                    completed += 1
                } catch {
                    failed += 1
                    try write(["id": item.id, "status": "failed", "side": side,
                        "requestSHA256": fingerprint, "sourceSHA256": item.sourceSHA256,
                        "inputABI": NativeCoreMLDetectionPreprocessor.provenanceABI,
                        "error": String(describing: error)], to: resultPath)
                    fputs("Manga \(side)/\(item.id): \(error)\n", stderr)
                }
                if (completed + failed) % 20 == 0 {
                    print("Manga detector \(completed) complete, \(failed) failed / \(spec.cases.count * spec.sides.count)")
                    try write(["complete": completed, "failed": failed, "expected": spec.cases.count * spec.sides.count,
                        "elapsedSeconds": ProcessInfo.processInfo.systemUptime - start,
                        "processPeakRSSBytes": peakBytes()], to: output.appendingPathComponent("progress.json"))
                }
            }
        }
        try write(["complete": completed, "failed": failed, "expected": spec.cases.count * spec.sides.count,
            "elapsedSeconds": ProcessInfo.processInfo.systemUptime - start,
            "processPeakRSSBytes": peakBytes()], to: output.appendingPathComponent("progress.json"))
        return failed == 0 ? 0 : 1
    }

    /// Deterministic DB-only continuation from the retained actual producer.
    /// Missing/corrupt maps are errors, never permission for another prediction.
    private static func runMapReplay(spec: Request, root: URL, requestData: Data) throws -> Int32 {
        let before = NeuralCounters.snapshot()
        let requestSHA = SHA256.hash(data: requestData).map { String(format: "%02x", $0) }.joined()
        let output = URL(fileURLWithPath: spec.output)
        var completed = 0
        for side in spec.sides { for item in spec.cases {
            let direct = root.appendingPathComponent("\(side)/\(item.id)/result.json")
            let sourceResult: URL
            if FileManager.default.fileExists(atPath: direct.path) {
                sourceResult = direct
            } else {
                let workers = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                    .filter { $0.lastPathComponent.hasPrefix("worker-") }
                let candidates = workers.map { $0.appendingPathComponent("\(side)/\(item.id)/result.json") }
                    .filter { FileManager.default.fileExists(atPath: $0.path) }
                guard candidates.count == 1 else { throw HostError.message("Missing or ambiguous actual DET map") }
                sourceResult = candidates[0]
            }
            let recordData = try Data(contentsOf: sourceResult)
            guard let record = try JSONSerialization.jsonObject(with: recordData) as? [String: Any],
                  record["schema"] as? String == "actual-det-only-content-map-v2",
                  record["status"] as? String == "complete", record["sourceSHA256"] as? String == item.sourceSHA256,
                  record["dimensions"] as? [Int] == item.dimensions, record["side"] as? Int == side,
                  record["inputABI"] as? String == NativeCoreMLDetectionPreprocessor.provenanceABI,
                  let mapInfo = record["map"] as? [String: Any], let mw = mapInfo["width"] as? Int,
                  let mh = mapInfo["height"] as? Int, let producerObject = record["producer"] as? [String: Any]
            else { throw HostError.message("Unattested, wrong-source or incompatible raw DET map") }
            let producer = try JSONDecoder().decode(NativeMainEnsembleDBCapability.Producer.self,
                from: JSONSerialization.data(withJSONObject: producerObject))
            guard producer.preprocessABI == NativeCoreMLDetectionPreprocessor.provenanceABI,
                  producer.preprocessSHA256 == NativeCoreMLDetectionPreprocessor.normalizationConfigurationSHA256,
                  producer.resizedWidth == mw, producer.resizedHeight == mh,
                  mapInfo["originX"] as? Int == 0, mapInfo["originY"] as? Int == 0,
                  mapInfo["fullWidth"] as? Int == mw, mapInfo["fullHeight"] as? Int == mh,
                  mw > 0, mh > 0, mw <= 2_000, mh <= 2_000 else {
                throw HostError.message("Wrong actual DET map geometry or preprocessing")
            }
            let mapData = try Data(contentsOf: sourceResult.deletingLastPathComponent().appendingPathComponent("probability.f32"))
            guard mapData.count == mw * mh * 4,
                  SHA256.hash(data: mapData).map({ String(format: "%02x", $0) }).joined() == record["mapSHA256"] as? String else {
                throw HostError.message("Actual DET raw map checksum mismatch")
            }
            let values = mapData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            guard values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                throw HostError.message("Invalid actual DET probability")
            }
            let map = NativeCoreMLDetectionMap(width: mw, height: mh, values: values)
            var variants = [[String: Any]]()
            for threshold in spec.pixelThresholds { for unclip in spec.unclipRatios {
                let started = ProcessInfo.processInfo.systemUptime
                let decoded = try NativeCoreMLDBPostprocessor.decode(map: map,
                    sourceWidth: item.dimensions[0], sourceHeight: item.dimensions[1],
                    configuration: .init(threshold: threshold, boxThreshold: 0.25, unclipRatio: unclip,
                        maximumCandidates: 3_000, minimumBoxSide: 3))
                variants.append(["pixelThreshold": threshold, "unclipRatio": unclip,
                    "candidateComponents": decoded.candidateComponents,
                    "decodeMs": (ProcessInfo.processInfo.systemUptime - started) * 1_000,
                    "boxes": decoded.boxes.map { box -> [String: Any] in
                        ["score": box.score, "polygon": box.polygon.map {
                            [Double($0.x) / Double(item.dimensions[0]), Double($0.y) / Double(item.dimensions[1])]
                        }]
                    }])
            } }
            let destination = output.appendingPathComponent("\(side)/\(item.id)")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try write(["schema": "actual-det-map-postprocess-replay-v1", "status": "complete", "id": item.id,
                "sourceSHA256": item.sourceSHA256, "dimensions": item.dimensions, "requestSHA256": requestSHA,
                "rawProducer": producerObject, "rawRecordPath": sourceResult.path,
                "rawRecordSHA256": SHA256.hash(data: recordData).map { String(format: "%02x", $0) }.joined(),
                "rawMapSHA256": record["mapSHA256"] as Any, "variants": variants,
                "actualDETCalls": 0, "warmupPredictions": 0, "RECRequested": false, "RFRequested": false,
                "providerRequested": false], to: destination.appendingPathComponent("result.json"))
            completed += 1
        } }
        guard before == NeuralCounters.snapshot() else { throw HostError.message("Map replay submitted a neural prediction") }
        print("DET map replay completed \(completed) pages, zero neural calls")
        return 0
    }
}
