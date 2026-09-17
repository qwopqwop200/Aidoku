import Darwin
import Foundation
import Testing
import UIKit
@testable import Aidoku

/// Opt-in, local-only continuous workload. Does not change settings, call a
/// provider, or purge between pages: warm runtime growth must remain visible.
@Suite(.serialized)
struct ReaderContinuousMemoryTests {
    @Test func changingSourceGraphMemory() async throws {
        try await Self.changingSources(bounded: false)
    }

    @Test func changingSourceBoundedMemory() async throws {
        try await Self.changingSources(bounded: true)
    }

    private static func changingSources(bounded: Bool) async throws {
        guard #available(iOS 18.0, *) else { return }
        let root = URL.documentsDirectory.appendingPathComponent("LookaheadDevice")
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("comic-0001.png").path) else { return }
        let original = try #require(UIImage(contentsOfFile: root.appendingPathComponent("comic-0001.png").path)?.cgImage)
        let output = URL.documentsDirectory.appendingPathComponent("ReaderMemoryInvestigation")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var rows: [[String: Any]] = [["initialMiB": footprintMiB()]]
        for index in 0..<18 {
            let start = ProcessInfo.processInfo.systemUptime
            let size = try await prepareChangingSource(original, index: index, bounded: bounded)
            try await Task.sleep(for: .milliseconds(100))
            rows.append(["page": index + 1, "width": size.width, "height": size.height,
                         "footprintMiB": footprintMiB(), "milliseconds": (ProcessInfo.processInfo.systemUptime - start) * 1_000])
            try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent(bounded ? "shapes-bounded.json" : "shapes-graph.json"), options: .atomic)
        }
        if bounded {
            let initial = try #require(rows.first?["initialMiB"] as? Double)
            let peak = try #require(rows.dropFirst().compactMap { $0["footprintMiB"] as? Double }.max())
            #expect(peak - initial < 128, "Source-size variation must not accumulate full-resolution tensor graphs")
        }
    }

    private static func prepareChangingSource(_ original: CGImage, index: Int, bounded: Bool) async throws -> CGSize {
        let pixels = try #require(original.cropping(to: CGRect(x: 0, y: 0,
            width: original.width - index * 3, height: original.height - index * 5)))
        let frame = try #require(NativeOCRCGImageAdapter.makeRGBAFrame(from: pixels))
        let canvas = try #require(NativeCoreMLDetectionCanvas.exact(sourceWidth: frame.width, sourceHeight: frame.height, maximumSide: 960))
        let tensor = try NativeCoreMLDetectionPreprocessor.prepare(frame: frame, canvas: canvas, useBoundedMemory: bounded)
        let values = await tensor.values()
        #expect(values.count == canvas.width * canvas.height * 3)
        return CGSize(width: pixels.width, height: pixels.height)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath:
        URL.documentsDirectory.appendingPathComponent("LookaheadDevice/manifest.json").path)))
    func continuousOCRMemory() async throws {
        struct Fixture: Decodable { let id: String; let image: String }
        let root = URL.documentsDirectory.appendingPathComponent("LookaheadDevice")
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        let configuration = await MainActor.run { ReaderTranslationSettings().ocrConfiguration }
        let output = URL.documentsDirectory.appendingPathComponent("ReaderMemoryInvestigation")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var rows: [[String: Any]] = []
        await ReaderOCRService.shared.purge()
        for index in 0..<18 {
            let fixture = fixtures[index % fixtures.count]
            let start = ProcessInfo.processInfo.systemUptime
            let regions = try await Self.recognize(root.appendingPathComponent(fixture.image), configuration: configuration)
            try await Task.sleep(for: .milliseconds(150))
            rows.append(["page": index + 1, "fixture": fixture.id, "footprintMiB": Self.footprintMiB(),
                         "milliseconds": (ProcessInfo.processInfo.systemUptime - start) * 1_000,
                         "texts": regions.map(\.source)])
            try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("continuous.json"), options: .atomic)
            #expect(!regions.isEmpty)
        }
        await ReaderOCRService.shared.purge()
        try await Task.sleep(for: .milliseconds(300))
        rows.append(["afterPurgeMiB": Self.footprintMiB()])
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("continuous.json"), options: .atomic)
    }

    private static func recognize(_ url: URL, configuration: ReaderOCRConfiguration) async throws -> [ReaderTranslationRegion] {
        let image = try #require(UIImage(contentsOfFile: url.path)?.cgImage)
        return try await ReaderOCRService.shared.recognize(image: image, configuration: configuration)
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
