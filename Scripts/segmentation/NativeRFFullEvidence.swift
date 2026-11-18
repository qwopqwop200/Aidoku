import CoreML
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// Source-only evidence export. All 300 queries, five class logits, boxes and
/// native mask logits survive export; no GT masks or acceptance thresholds.
@main struct NativeRFFullEvidence {
    struct Input: Decodable { let source: String; let sourceSHA256: String }
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 4 else { throw CocoaError(.fileReadInvalidFileName) }
        let inputs = try JSONDecoder().decode([Input].self,
            from: Data(contentsOf: URL(fileURLWithPath: args[1])))
        let config = MLModelConfiguration(); config.computeUnits = .cpuAndGPU
        let model = try MLModel(contentsOf: URL(fileURLWithPath: args[2]), configuration: config)
        try NativeRFDETRLayoutTensorContract.validate(model: model)
        let destination = URL(fileURLWithPath: args[3], isDirectory: true)
        for item in inputs {
            try autoreleasepool {
                let started = Date()
                let data = try Data(contentsOf: URL(fileURLWithPath: item.source))
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard hash == item.sourceSHA256,
                      let decoder = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(decoder, 0, nil) else {
                    throw NativeRFDETRLayoutError.invalidImage
                }
                let source = try NativeRFDETRSourceImage.decode(image)
                let tensor = try NativeRFDETRLayoutTensorContract.preprocess(source)
                let provider = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(multiArray: tensor)])
                let output = try model.prediction(from: provider)
                let decoded = try NativeRFDETRLayoutTensorContract.decode(output, source: source, maximumMaskQueries: 160)
                // Honor arbitrary Core ML strides instead of dumping padded storage.
                for name in ["boxes", "logits", "instance_masks"] {
                    guard let a = output.featureValue(for: name)?.multiArrayValue,
                          a.dataType == .float32,
                          a.shape.map(\.intValue) == NativeRFDETRLayoutTensorContract.outputShapes[name] else {
                        throw NativeRFDETRLayoutError.unsupportedModelContract(name)
                    }
                    let shape = a.shape.map(\.intValue), strides = a.strides.map(\.intValue)
                    let pointer = a.dataPointer.assumingMemoryBound(to: Float.self)
                    var values = [Float](repeating: 0, count: a.count)
                    for index in values.indices {
                        var offset = 0, rest = index
                        for dimension in shape.indices.reversed() {
                            offset += (rest % shape[dimension]) * strides[dimension]
                            rest /= shape[dimension]
                        }
                        guard pointer[offset].isFinite else { throw NativeRFDETRLayoutError.nonfiniteOutput }
                        values[index] = pointer[offset]
                    }
                    try values.withUnsafeBytes { bytes in
                        try Data(bytes).write(to: destination.appendingPathComponent("\(hash)-\(name).f32"), options: .atomic)
                    }
                }
                let metadata = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
                let record: [String: Any] = ["sourceSHA256": hash, "imageIdentity": source.identity,
                    "width": source.width, "height": source.height, "queries": 300,
                    "maskSide": 162, "classLogits": 5, "dtype": "float32-little-endian",
                    "seconds": Date().timeIntervalSince(started), "GTRead": false,
                    "modelWeightsSHA256": metadata["weights_sha256"] ?? "", "modelRevision": metadata["source_revision"] ?? "",
                    "selectedPrimitives": decoded.primitives.map { p in
                        ["queryID": p.queryID, "semanticClass": p.semanticClass.rawValue, "confidence": Double(p.confidence)] as [String: Any]
                    }]
                var line = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                line.append(10)
                try FileHandle.standardOutput.write(contentsOf: line)
                // Handshake bounds the raw tensor spool to one source (~32MB).
                guard readLine() == hash else { throw CocoaError(.userCancelled) }
            }
        }
    }
}
