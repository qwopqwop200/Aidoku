import CoreGraphics
import Foundation

/// Focused typed-producer integration harness; no corpus metadata or target inputs.
@main struct NativeSourceSegmentationReplay {
    struct Input: Decodable {
        let rgb: String
        let coarseRF: String
        let fullRF: String
        let width: Int
        let height: Int
        let polygons: [[[Double]]]
        let fontPixels: Double
        let output: String
        let rfModelWeightsSHA256: String
    }
    static func floats(_ path: String) throws -> [Float] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard data.count % 4 == 0 else { throw CocoaError(.fileReadCorruptFile) }
        return data.withUnsafeBytes { bytes in
            (0..<(data.count / 4)).map { Float(bitPattern: bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)) }
        }
    }
    static func main() throws {
        let models = try NativeSourceSegmentationObservations.Models()
        while let line = readLine() {
            let i = try JSONDecoder().decode(Input.self, from: Data(line.utf8))
            let result = try NativeSourceSegmentationObservations.sourceCrop(
                rgb: Array(Data(contentsOf: URL(fileURLWithPath: i.rgb))), width: i.width, height: i.height,
                polygons: i.polygons.map { $0.map { CGPoint(x: $0[0], y: $0[1]) } }, fontPixels: i.fontPixels,
                coarseRF: floats(i.coarseRF), fullRF: floats(i.fullRF),
                rfModelWeightsSHA256: i.rfModelWeightsSHA256, models: models)
            for (suffix, values) in [(".p.f32", result.primary), (".q.f32", result.boundary)] {
                try values.withUnsafeBytes { try Data($0).write(to: URL(fileURLWithPath: i.output + suffix)) }
            }
            try Data(result.rawNative).write(to: URL(fileURLWithPath: i.output + ".native.u8"))
            try Data(result.completed.mask).write(to: URL(fileURLWithPath: i.output + ".completed.u8"))
            print("{\"GTRead\":false,\"primaryFresh\":true,\"boundaryFresh\":true}")
        }
    }
}
