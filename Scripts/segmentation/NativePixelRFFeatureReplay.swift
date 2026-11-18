import CoreGraphics
import Foundation

@main struct NativePixelRFFeatureReplay {
    struct Input: Decodable {
        let rgb: String
        let baseline: String
        let coarseRF: String
        let fullRF: String?
        let width: Int
        let height: Int
        let polygons: [[[Double]]]
        let fontPixels: Double
        let output: String
    }
    static func floats(_ path: String) throws -> [Float] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard data.count % 4 == 0 else { throw CocoaError(.fileReadCorruptFile) }
        return data.withUnsafeBytes { bytes in
            (0..<(data.count / 4)).map { Float(bitPattern: bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)) }
        }
    }
    static func main() throws {
        let entries = try JSONDecoder().decode([Input].self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        for entry in entries {
            try autoreleasepool {
                let matrix = try NativePixelRFFeatures.extract(.init(width: entry.width, height: entry.height,
                    rgb: Array(Data(contentsOf: URL(fileURLWithPath: entry.rgb))),
                    nativeMask: Array(Data(contentsOf: URL(fileURLWithPath: entry.baseline))),
                    polygons: entry.polygons.map { $0.map { CGPoint(x: $0[0], y: $0[1]) } },
                    fontPixels: entry.fontPixels, coarseRF: floats(entry.coarseRF),
                    fullRF: try entry.fullRF.map { try floats($0) }))
                try matrix.values.withUnsafeBytes {
                    try Data($0).write(to: URL(fileURLWithPath: entry.output), options: .atomic)
                }
            }
        }
    }
}
