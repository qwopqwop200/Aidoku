import CoreGraphics
import Foundation

/// Streaming host adapter for the same segmentation implementation as the app.
/// The model is loaded once; per-crop JSON inputs contain no target masks.
@main struct NativePixelRFSegmentationReplay {
    struct Expansion: Decodable {
        let seed: [UInt8]
        let width: Int
        let height: Int
        let radius: Int
        let kernel: String
    }
    struct Input: Decodable {
        let rgb: String
        let coarseRF: String
        let fullRF: String?
        let width: Int
        let height: Int
        let polygons: [[[Double]]]
        let fontPixels: Double
        let output: String
        let probabilities: String?
        let nativeBase: String?
        let captureProbabilities: String?
        let captureNativeBase: String?
        let weakRescue: NativePixelRFSegmentation.WeakRescuePolicy?
    }
    static func floats(_ path: String) throws -> [Float] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard data.count % 4 == 0 else { throw CocoaError(.fileReadCorruptFile) }
        return data.withUnsafeBytes { bytes in
            (0..<(data.count / 4)).map { Float(bitPattern: bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)) }
        }
    }
    static func main() throws {
        if CommandLine.arguments.dropFirst().first == "--expansion-parity" {
            while let line = readLine() {
                let input = try JSONDecoder().decode(Expansion.self, from: Data(line.utf8))
                guard input.width > 0, input.height > 0, input.width <= 1_500_000 / input.height,
                      input.seed.count == input.width * input.height, (0...16).contains(input.radius),
                      ["square", "ellipse", "cross"].contains(input.kernel) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let mask = NativePixelRFSegmentation.expand(input.seed, width: input.width,
                    height: input.height, radius: input.radius, kernel: input.kernel)
                var record = try JSONEncoder().encode(mask)
                record.append(10)
                try FileHandle.standardOutput.write(contentsOf: record)
            }
            return
        }
        let model = try NativePixelRFForest(data: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        while let line = readLine() {
            try autoreleasepool {
                let input = try JSONDecoder().decode(Input.self, from: Data(line.utf8))
                let start = Date()
                guard (input.probabilities == nil) == (input.nativeBase == nil) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let result: NativePixelRFSegmentation.Result
                if let probabilities = input.probabilities, let nativeBase = input.nativeBase {
                    guard input.weakRescue == nil else { throw CocoaError(.fileReadCorruptFile) }
                    result = try NativePixelRFSegmentation.complete(probabilities: floats(probabilities),
                        nativeMask: Array(Data(contentsOf: URL(fileURLWithPath: nativeBase))),
                        width: input.width, height: input.height, fontPixels: input.fontPixels, model: model)
                } else {
                    result = try NativePixelRFSegmentation.segmentCrop(
                        rgb: Array(Data(contentsOf: URL(fileURLWithPath: input.rgb))), width: input.width, height: input.height,
                        polygons: input.polygons.map { $0.map { CGPoint(x: $0[0], y: $0[1]) } }, fontPixels: input.fontPixels,
                        coarseRF: floats(input.coarseRF), fullRF: try input.fullRF.map { try floats($0) }, model: model,
                        captureClassifier: { probabilities, nativeBase in
                            if let path = input.captureProbabilities {
                                try probabilities.withUnsafeBytes {
                                    try Data($0).write(to: URL(fileURLWithPath: path), options: .atomic)
                                }
                            }
                            if let path = input.captureNativeBase {
                                try Data(nativeBase).write(to: URL(fileURLWithPath: path), options: .atomic)
                            }
                        }, weakRescue: input.weakRescue)
                }
                try Data(result.mask).write(to: URL(fileURLWithPath: input.output), options: .atomic)
                var audit = result.audit
                audit["seconds"] = Date().timeIntervalSince(start)
                audit["classifierObservationReused"] = input.probabilities != nil
                audit["classifierObservationCaptured"] = input.captureProbabilities != nil
                var record = try JSONSerialization.data(withJSONObject: audit, options: [.sortedKeys])
                record.append(10)
                try FileHandle.standardOutput.write(contentsOf: record)
            }
        }
    }
}
