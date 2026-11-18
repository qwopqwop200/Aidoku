import CoreGraphics
@preconcurrency import CoreML
import CryptoKit
import Darwin
import Foundation
import ImageIO

/// Fixed production648 input and normalization. Save raw outputs before the
/// production confidence/mask cap for offline search; labels never enter here.
enum HostRFParameterSearch {
    struct Case: Decodable {
        let id: String
        let source: String
        let sourceSHA256: String
        let dimensions: [Int]
    }
    struct Request: Decodable {
        let cases: [Case]
        let output: String
        let floor: Double
        let limit: Int?
    }
    static func save(_ object: [String: Any], to path: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: path, options: .atomic)
    }
    static func peakBytes() -> Int64 {
        var value = rusage()
        getrusage(RUSAGE_SELF, &value)
        return Int64(value.ru_maxrss)
    }
    static func array(_ feature: MLFeatureProvider, name: String, shape: [Int]) throws -> MLMultiArray {
        guard let value = feature.featureValue(for: name)?.multiArrayValue,
              value.dataType == .float32, value.shape.map(\.intValue) == shape else {
            throw HostError.message("RF648 output contract mismatch: \(name)")
        }
        return value
    }
    static func run(request: URL, root: URL) async throws -> Int32 {
        let bytes = try Data(contentsOf: request)
        let spec = try JSONDecoder().decode(Request.self, from: bytes)
        guard spec.floor.isFinite, (0.0001...1).contains(spec.floor),
              !spec.cases.isEmpty, Set(spec.cases.map(\.id)).count == spec.cases.count else {
            throw HostError.message("Invalid RF648 capture request")
        }
        let output = URL(fileURLWithPath: spec.output)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let bundle = root.appendingPathComponent("build/image-translation-host/Models.bundle")
        guard let modelBundle = Bundle(path: bundle.path) else { throw HostError.message("Missing current model bundle") }
        let url = try NativeRFDETRLayoutResource.bundledModelURL(bundle: modelBundle)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        let loadStarted = ProcessInfo.processInfo.systemUptime
        let model = try MLModel(contentsOf: url, configuration: configuration)
        try NativeRFDETRLayoutTensorContract.validate(model: model)
        let loadMs = (ProcessInfo.processInfo.systemUptime - loadStarted) * 1000
        // limit controls only this invocation, not cache identity.
        let identity = "rf648-raw-v1:floor=\(spec.floor):source=" + NativeRFDETRLayoutResource.sourceWeightsSHA256
        var complete = 0, failed = 0
        let started = ProcessInfo.processInfo.systemUptime
        for item in spec.cases.prefix(spec.limit ?? spec.cases.count) {
            let folder = output.appendingPathComponent(item.id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let receipt = folder.appendingPathComponent("result.json")
            if let oldData = try? Data(contentsOf: receipt),
               let old = try? JSONSerialization.jsonObject(with: oldData) as? [String: Any],
               old["captureIdentity"] as? String == identity, old["status"] as? String == "complete",
               old["sourceSHA256"] as? String == item.sourceSHA256 {
                complete += 1
                continue
            }
            do {
                let saved: [String: Any] = try autoreleasepool {
                    let sourceBytes = try Data(contentsOf: URL(fileURLWithPath: item.source), options: .mappedIfSafe)
                    let digest = SHA256.hash(data: sourceBytes).map { String(format: "%02x", $0) }.joined()
                    guard digest == item.sourceSHA256,
                          let decoder = CGImageSourceCreateWithData(sourceBytes as CFData, nil),
                          let image = CGImageSourceCreateImageAtIndex(decoder, 0, nil),
                          [image.width, image.height] == item.dimensions else { throw HostError.message("RF source mismatch") }
                    let pageStarted = ProcessInfo.processInfo.systemUptime
                    let source = try NativeRFDETRSourceImage.decode(image)
                    let prepStarted = ProcessInfo.processInfo.systemUptime
                    let input = try NativeRFDETRLayoutTensorContract.preprocess(source)
                    let prepMs = (ProcessInfo.processInfo.systemUptime - prepStarted) * 1000
                    let features = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(multiArray: input)])
                    let predictStarted = ProcessInfo.processInfo.systemUptime
                    let result = try model.prediction(from: features)
                    let predictMs = (ProcessInfo.processInfo.systemUptime - predictStarted) * 1000
                    let boxes = try array(result, name: "boxes", shape: [1,300,4])
                    let logits = try array(result, name: "logits", shape: [1,300,5])
                    let masks = try array(result, name: "instance_masks", shape: [1,300,162,162])
                    let bp = boxes.dataPointer.assumingMemoryBound(to: Float.self), bs = boxes.strides.map(\.intValue)
                    let lp = logits.dataPointer.assumingMemoryBound(to: Float.self), ls = logits.strides.map(\.intValue)
                    let mp = masks.dataPointer.assumingMemoryBound(to: Float.self), ms = masks.strides.map(\.intValue)
                    var rawLogits: [[Float]] = [], rawBoxes: [[Float]] = []
                    var ranked: [(flat: Int, score: Double)] = []
                    for q in 0..<300 {
                        let l = (0..<5).map { lp[q * ls[1] + $0 * ls[2]] }
                        let b = (0..<4).map { bp[q * bs[1] + $0 * bs[2]] }
                        guard l.allSatisfy(\.isFinite), b.allSatisfy(\.isFinite) else { throw HostError.message("Nonfinite RF outputs") }
                        rawLogits.append(l); rawBoxes.append(b)
                        for c in 0..<5 {
                            let v = Double(l[c]), score = v >= 0 ? 1 / (1 + exp(-v)) : exp(v) / (1 + exp(v))
                            ranked.append((q * 5 + c, score))
                        }
                    }
                    ranked.sort { $0.score == $1.score ? $0.flat < $1.flat : $0.score > $1.score }
                    let top = Array(ranked.prefix(160))
                    let queries = Set(top.filter { $0.flat % 5 < 4 && $0.score >= spec.floor }.map { $0.flat / 5 }).sorted()
                    var rawMasks = [Float](); rawMasks.reserveCapacity(queries.count * 162 * 162)
                    for q in queries {
                        for y in 0..<162 {
                            for x in 0..<162 {
                                let v = mp[q * ms[1] + y * ms[2] + x * ms[3]]
                                guard v.isFinite else { throw HostError.message("Nonfinite RF mask") }
                                rawMasks.append(v)
                            }
                        }
                    }
                    let data = rawMasks.withUnsafeBytes { Data($0) }
                    try data.write(to: folder.appendingPathComponent("masks.f32"), options: .atomic)
                    return ["status": "complete", "id": item.id, "side": 648, "maskSide": 162,
                        "captureIdentity": identity, "sourceSHA256": digest, "sourceRGBIdentity": source.identity,
                        "dimensions": item.dimensions, "computeUnits": "cpuAndGPU", "maskFloor": spec.floor,
                        "top160": top.map { ["flat": $0.flat, "score": $0.score] },
                        "logits": rawLogits, "boxesCXCYWH": rawBoxes, "maskQueryIDs": queries,
                        "masksBytes": data.count, "masksSHA256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                        "preprocessMs": prepMs, "predictionMs": predictMs,
                        "captureWallMs": (ProcessInfo.processInfo.systemUptime - pageStarted) * 1000,
                        "processPeakRSSBytes": peakBytes()]
                }
                try save(saved, to: receipt)
                complete += 1
                print("RF648 capture \(complete)/\(spec.limit ?? spec.cases.count), \(failed) failed; \(item.id) model \(saved["predictionMs"]!) ms")
            } catch {
                failed += 1
                try save(["status": "failed", "id": item.id, "side": 648,
                    "captureIdentity": identity, "sourceSHA256": item.sourceSHA256, "error": String(describing: error)], to: receipt)
                print("RF648 failed \(item.id): \(error)")
            }
            try save(["complete": complete, "failed": failed, "expected": spec.cases.count,
                "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started,
                "modelLoadMs": loadMs, "processPeakRSSBytes": peakBytes()], to: output.appendingPathComponent("progress.json"))
        }
        return failed == 0 ? 0 : 1
    }
}
