import CryptoKit
import Foundation
import Testing
import UIKit
@testable import Aidoku

/// Opt-in corpus export before region merging, so ruby decisions can be
/// replayed against exactly the same detections without rerunning Core ML.
@Suite(.serialized) @MainActor
struct ReaderFuriganaCorpusTests {
    private nonisolated static var folder: URL { URL.documentsDirectory.appendingPathComponent("FuriganaCorpus") }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: folder.appendingPathComponent("selection.json").path)))
    func exportNativeLines() async throws {
        let root = Self.folder
        let fixtures = try JSONDecoder().decode([Fixture].self,
            from: Data(contentsOf: root.appendingPathComponent("selection.json")))
        #expect(!fixtures.isEmpty)
        let output = root.appendingPathComponent("raw")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let pipeline = NativeCoreMLOCRPipeline(modelTier: .medium)
        do {
            for (index, fixture) in fixtures.enumerated() {
                try Task.checkCancellation()
                let data = try Data(contentsOf: root.appendingPathComponent(fixture.id + ".png"))
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                #expect(hash == fixture.sha256)
                guard hash == fixture.sha256 else { throw CocoaError(.fileReadCorruptFile) }
                let destination = output.appendingPathComponent(fixture.id + ".json")
                if FileManager.default.fileExists(atPath: destination.path) { continue }
                let image = try #require(UIImage(data: data)?.cgImage)
                let result = try await pipeline.recognize(image: image, requestID: fixture.id,
                    confidenceThreshold: ReaderOCRConfiguration(modelTier: .medium).confidenceThreshold)
                let report: [String: Any] = [
                    "id": fixture.id, "sha256": hash, "width": image.width, "height": image.height,
                    "lines": result.lines.enumerated().map { index, line -> [String: Any] in
                        ["index": index, "text": line.text, "score": line.score,
                         "polygon": line.polygon.map { [$0.x, $0.y] },
                         "orientation": line.orientation.rawValue, "estimated": line.orientationIsEstimated]
                    }
                ]
                try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
                    .write(to: destination, options: .atomic)
                print("FuriganaCorpus \(index + 1)/\(fixtures.count) \(fixture.id) lines=\(result.lines.count)")
            }
        } catch {
            await pipeline.purgeResources()
            throw error
        }
        await pipeline.purgeResources()
    }

    private struct Fixture: Decodable { let id: String; let sha256: String }
}
