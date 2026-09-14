import CryptoKit
import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderRealComicOCRAuditTests {
    // Opt-in, original-image audit of the actual ReaderOCRService route,
    // including Vision reconciliation and UIKit word-boundary resolution.
    // No provider request or translation-quality assertion is made here.
    @Test(.enabled(if: FileManager.default.fileExists(atPath:
        URL.documentsDirectory.appendingPathComponent("RealComicOCRAudit/manifest.json").path)))
    func actualReaderOCRExportsVerifiedOriginals() async throws {
        let directory = URL.documentsDirectory.appendingPathComponent("RealComicOCRAudit")
        let manifest = try JSONDecoder().decode(Manifest.self,
            from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        #expect(!manifest.fixtures.isEmpty)
        #expect(Set(manifest.fixtures.map(\.sha256)).count == manifest.fixtures.count)
        let output = directory.appendingPathComponent(manifest.runLabel)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let configuration = ReaderOCRConfiguration(modelTier: .medium)
        await ReaderOCRService.shared.purge()
        do {
            for (index, fixture) in manifest.fixtures.enumerated() {
                let data = try Data(contentsOf: directory.appendingPathComponent(fixture.image))
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                #expect(hash == fixture.sha256)
                guard hash == fixture.sha256 else { throw CocoaError(.fileReadCorruptFile) }
                let image = try #require(UIImage(data: data)?.cgImage)
                let start = ContinuousClock.now
                let regions = try await ReaderOCRService.shared.recognize(image: image, configuration: configuration)
                let elapsed = start.duration(to: .now).components
                let report: [String: Any] = [
                    "sha256": hash, "work": fixture.work, "run_label": manifest.runLabel,
                    "width": image.width, "height": image.height, "sequence_index": index,
                    "ocr_ms": Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15,
                    "scope": "Simulator ReaderOCRService: native + Vision + UIKit resolver + merger; no provider",
                    "regions": regions.map { region -> [String: Any] in
                        ["id": region.id, "text": region.source, "confidence": region.confidence,
                         "rect": [region.rect.minX, region.rect.minY, region.rect.width, region.rect.height],
                         "polygon": region.polygon.map { [$0.x, $0.y] },
                         "orientation": region.sourceOrientation.rawValue,
                         "single_vertical_column": region.sourceSingleVerticalColumn]
                    }
                ]
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent(hash + ".json"), options: .atomic)
            }
        } catch {
            await ReaderOCRService.shared.purge()
            throw error
        }
        await ReaderOCRService.shared.purge()
    }

    private struct Manifest: Decodable {
        let runLabel: String
        let fixtures: [Fixture]
    }
    private struct Fixture: Decodable {
        let image: String
        let sha256: String
        let work: String
    }
}
