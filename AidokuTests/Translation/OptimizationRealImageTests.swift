import Darwin
import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct OptimizationRealImageTests {
    private static var folder: URL { URL.documentsDirectory.appendingPathComponent("OptimizationFixtures") }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: URL.documentsDirectory.appendingPathComponent("OptimizationFixtures").path)))
    func detectorInputsAndDownsampleOnRealPages() async throws {
        guard #available(iOS 18.0, *) else { return }
        let files = try FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)
            .filter { ["png", "jpg"].contains($0.pathExtension) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(files.count >= 6)
        var rows: [[String: Any]] = []
        let output = Self.folder.appendingPathComponent("results")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for file in files {
            let image = try #require(UIImage(contentsOfFile: file.path))
            let pixels = try #require(image.cgImage)
            let frame = try #require(NativeOCRCGImageAdapter.makeRGBAFrame(from: pixels))
            let dimensions = try #require(NativeCoreMLDetectionPreprocessor.resizeDimensions(sourceWidth: pixels.width,
                sourceHeight: pixels.height, maximumSide: NativeCoreMLDetectionCanvas.square.width))
            var baseline: [Float] = []
            let start = ContinuousClock.now
            do {
                let original = try NativeCoreMLDetectionPreprocessor.prepare(frame: frame, useBoundedMemory: false)
                baseline = await original.values()
            }
            let baselineMS = Self.milliseconds(start)
            let boundedStart = ContinuousClock.now
            let bounded = try NativeCoreMLDetectionPreprocessor.prepareBounded(frame: frame, canvas: .square, dimensions: dimensions)
            let actual = await bounded.values()
            let boundedMS = Self.milliseconds(boundedStart)
            let maximumError = zip(baseline, actual).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
            #expect(maximumError < 0.001)
            let downsampleStart = ContinuousClock.now
            let downsampled = try #require(DownsampleProcessor(width: 200).process(image))
            let downsampleMS = Self.milliseconds(downsampleStart)
            try downsampled.pngData()?.write(to: output.appendingPathComponent(file.deletingPathExtension().lastPathComponent + "-downsample.png"))
            rows.append(["file": file.lastPathComponent, "width": pixels.width, "height": pixels.height,
                         "referenceMS": baselineMS, "boundedMS": boundedMS, "maxTensorError": maximumError,
                         "downsampleMS": downsampleMS, "footprintMiBAfterComparison": Self.footprintMiB()])
            print("REAL_OPTIMIZATION \(file.lastPathComponent) referenceMS=\(baselineMS) boundedMS=\(boundedMS) error=\(maximumError)")
            try JSONSerialization.data(withJSONObject: ["scope": "Simulator input tensor equivalence, not provider/device end-to-end quality", "rows": rows],
                options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("measurements.json"))
        }
    }

    private static func milliseconds(_ start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
    }

    private static func footprintMiB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}
