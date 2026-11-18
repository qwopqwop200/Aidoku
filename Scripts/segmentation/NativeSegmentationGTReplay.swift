import CoreGraphics
import Foundation

/// Host measurement of unchanged production source-base/chromatic kernels.
/// Inputs contain source RGB and localization geometry, never target mask pixels.
@main struct NativeSegmentationGTReplay {
    struct Input: Decodable {
        let id: String
        let rgb: String
        let width: Int
        let height: Int
        let polygons: [[[Double]]]
        let fontPixels: Double
        let output: String
    }
    static func main() throws {
        let entries = try JSONDecoder().decode([Input].self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        typealias F = NativeMainRemovalSourceFactory
        for entry in entries {
            try autoreleasepool {
                let started = Date()
                let bytes = Array(try Data(contentsOf: URL(fileURLWithPath: entry.rgb)))
                guard bytes.count == entry.width * entry.height * 3 else { throw CocoaError(.fileReadCorruptFile) }
                let source = F.NativeCurrentMaskCaller.Source(width: entry.width, height: entry.height,
                    rgb: bytes, revision: "source-bound-crop")
                let owners = entry.polygons.enumerated().map { index, polygon in
                    F.NativeCurrentMaskCaller.Owner(id: String(index),
                        polygon: polygon.map { CGPoint(x: $0[0], y: $0[1]) },
                        fontPixels: entry.fontPixels, translated: true, balloon: false)
                }
                let base = try F.NativeSourceBaseMask.extract(source: source, owners: owners)
                let result = try F.NativeChromaticMaskCompletion.complete(rgb: bytes,
                    width: entry.width, height: entry.height, base: base.mask,
                    protection: [UInt8](repeating: 0, count: entry.width * entry.height),
                    owners: owners.map { .init(id: $0.id, polygon: $0.polygon, fontPixels: $0.fontPixels) })
                try Data(result.mask.map { $0 == 0 ? 0 : 255 }).write(
                    to: URL(fileURLWithPath: entry.output), options: .atomic)
                let record: [String: Any] = ["id": entry.id, "pixels": result.mask.count,
                    "seconds": Date().timeIntervalSince(started), "scope": "production-source-base-and-chromatic-kernels",
                    "GTMaskRead": false, "RFProtectionExecuted": false, "fullProductionPipeline": false]
                var line = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                line.append(10)
                try FileHandle.standardOutput.write(contentsOf: line)
            }
        }
    }
}
