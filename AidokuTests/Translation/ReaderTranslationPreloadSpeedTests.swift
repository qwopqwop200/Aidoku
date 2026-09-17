import CryptoKit
import Darwin
import Foundation
import Nuke
import Testing
import UIKit
@testable import Aidoku

/// Local real-page benchmark. Measures actual OCR/image preparation/cache replay;
/// the translator is an identity function, so no provider latency is claimed.
@Suite(.serialized) @MainActor
struct ReaderTranslationPreloadSpeedTests {
    private nonisolated static var folder: URL { URL.documentsDirectory.appendingPathComponent("PreloadSpeed") }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: folder.appendingPathComponent("run.json").path)))
    func realPageCacheReplay() async throws {
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: Self.folder.appendingPathComponent("run.json")))
        let output = Self.folder.appendingPathComponent(config.label)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let suite = "preload-speed-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = ReaderTranslationSettings(defaults: defaults)
        settings.rightToLeftPanelOrder = true
        settings.filterJapaneseSFX = false
        settings.filterJapaneseSFXContext = false
        settings.translationSourceLanguages = []
        settings.includePageImage = false
        var rows: [[String: Any]] = []
        for fixture in config.fixtures {
            let url = Self.folder.appendingPathComponent(fixture.file)
            let bytes = try Data(contentsOf: url)
            #expect(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == fixture.sha256)
            let source = try #require(UIImage(data: bytes))
            let pixels = try #require(source.cgImage)
            let ocrStart = ContinuousClock.now
            let raw = try await ReaderOCRService.shared.recognize(image: pixels, configuration: settings.ocrConfiguration)
            let ocrMS = milliseconds(ocrStart)
            #expect(raw.count > 1)
            let preparationStart = ContinuousClock.now
            let prepared = ReaderTranslationImagePreparation.apply(raw, image: source, settings: settings)
            let preparationMS = milliseconds(preparationStart)
            let expected = ReaderTranslationService.plans(regions: prepared, settings: settings).map(\.request)
            let root = output.appendingPathComponent(fixture.id + "-cache")
            let disk = ReaderTranslationDiskCache(directory: root)
            let page = Page(sourceId: "preload-speed", chapterId: fixture.id, index: 0, imageURL: url.absoluteString)
            try await disk.storeRegions(prepared,
                for: ReaderTranslationCacheIdentity.ocr(page: page.translationCacheKey, settings: settings), kind: .ocr,
                generation: await disk.currentGeneration(settings: settings))
            var samples: [Double] = []
            let startFootprint = Self.footprintMiB()
            let monitor = Task.detached { () -> Double in
                var peak = Self.footprintMiB()
                while !Task.isCancelled {
                    peak = max(peak, Self.footprintMiB())
                    try? await Task.sleep(for: .milliseconds(5))
                }
                return max(peak, Self.footprintMiB())
            }
            defer { monitor.cancel() }
            for _ in 0..<7 {
                // Force a disk-only reopen, not Nuke's decoded-image cache.
                ImagePipeline.shared.configuration.imageCache?.removeAll()
                let reopened = ReaderTranslationPreloader(diskCache: ReaderTranslationDiskCache(directory: root),
                    translator: { regions, _, _ in regions }, recognizer: { _, _ in
                        Issue.record("A disk OCR hit must not repeat OCR")
                        return []
                    })
                let start = ContinuousClock.now
                let result = try await reopened.translate(page, settings: settings)
                samples.append(milliseconds(start))
                reopened.cancel()
                #expect(result.map(\.id) == prepared.map(\.id))
                #expect(result.map(\.source) == prepared.map(\.source))
                #expect(result.map(\.rect) == prepared.map(\.rect))
                #expect(result.map(\.translationOrder) == prepared.map(\.translationOrder))
                #expect(ReaderTranslationService.plans(regions: result, settings: settings).map(\.request) == expected)
            }
            monitor.cancel()
            let peak = await monitor.value
            let encoded = try JSONEncoder().encode(prepared.map(ReaderTranslationStoredRegion.init))
            try encoded.write(to: output.appendingPathComponent(fixture.id + "-regions.json"))
            rows.append(["id": fixture.id, "sha256": fixture.sha256, "regions": raw.count,
                         "width": pixels.width, "height": pixels.height, "ocrMS": ocrMS,
                         "imagePreparationMS": preparationMS, "cacheReplayMS": samples,
                         "medianCacheReplayMS": samples.sorted()[samples.count / 2],
                         "startFootprintMiB": startFootprint, "sampledPeakFootprintMiB": peak])
            try JSONSerialization.data(withJSONObject: ["label": config.label,
                "scope": "Simulator; real local images and OCR; seven disk cache reopens; identity translator; no live API or network timing; footprint sampled every 5ms",
                "rows": rows], options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("results.json"), options: .atomic)
        }
    }

    private func milliseconds(_ start: ContinuousClock.Instant) -> Double {
        let value = start.duration(to: .now).components
        return Double(value.seconds) * 1_000 + Double(value.attoseconds) / 1e15
    }
    private nonisolated static func footprintMiB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
    private struct Configuration: Decodable { let label: String; let fixtures: [Fixture] }
    private struct Fixture: Decodable { let id: String; let file: String; let sha256: String }
}
