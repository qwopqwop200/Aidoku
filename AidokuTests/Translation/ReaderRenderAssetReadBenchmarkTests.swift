import CryptoKit
import Foundation
import Testing
import UIKit
@testable import Aidoku

/// This file deliberately uses the pre-existing public cache API so it also runs on the frozen baseline.
@MainActor
struct ReaderRenderAssetReadBenchmarkTests {
    @Test func concurrentColdAssetReadDecodeBenchmark() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("asset-read-benchmark-" + UUID().uuidString)
        let disk = ReaderTranslationDiskCache(directory: root)
        let cache = ReaderTranslationRenderCache(disk: disk)
        defer { cache.clearMemory(); try? FileManager.default.removeItem(at: root) }
        let bounds = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        let pdf = Self.pdfFixture()
        #expect(CGPDFDocument(CGDataProvider(data: pdf as CFData)!)?.numberOfPages == 1)
        let asset = ReaderTranslationRenderAsset(typography: pdf,
            layers: .init(masks: [], surfaces: [], paintBounds: []), displayRect: bounds,
            sourceSize: bounds.size, regions: [], sourceDigest: "benchmark-fixed-source")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(asset)
        let expectedDigest = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        try await disk.store(encoded, for: ReaderTranslationRenderCache.renderAssetStorageKey("shared"), kind: .layout, generation: await disk.currentGeneration())
        var durations: [Double] = []
        var completed = 0
        for _ in 0..<8 {
            cache.clearMemory()
            let started = ContinuousClock.now
            let tasks = (0..<24).map { _ in Task { await cache.renderAsset(for: "shared") } }
            var outputs: [ReaderTranslationRenderAsset] = []
            for task in tasks { outputs.append(try #require(await task.value)) }
            let elapsed = started.duration(to: .now).components
            durations.append(Double(elapsed.attoseconds) / 1e15 + Double(elapsed.seconds) * 1000)
            for output in outputs {
                #expect(try encoder.encode(output) == encoded)
                completed += 1
            }
        }
        let report: [String: Any] = ["scenario": "24 concurrent cold readers of one real PDF asset, eight rounds",
            "apiReads": completed, "encodedAssetBytes": encoded.count, "typographyBytes": pdf.count,
            "deliveredEncodedBytes": completed * encoded.count, "outputSHA256": expectedDigest,
            "durationMilliseconds": durations, "measurementScope": "public API latency and exact outputs; no internal operation inference"]
        let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("RENDER_ASSET_READ_BENCHMARK " + String(decoding: json, as: UTF8.self))
    }
    // A deterministic, valid vector PDF: identical bytes across paired simulator launches.
    static func pdfFixture() -> Data {
        let stream = (0..<16_000).map {
            "0.3 0.2 0.6 rg \(($0 * 47) % 1000) \(($0 * 97) % 1000) 12 12 re f\n"
        }.joined()
        let objects = ["<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 1024 1024] /Contents 4 0 R >>",
            "<< /Length \(stream.utf8.count) >>\nstream\n" + stream + "endstream"]
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 5\n0000000000 65535 f \n"
        for offset in offsets { pdf += String(format: "%010d 00000 n \n", offset) }
        pdf += "trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(pdf.utf8)
    }

}
