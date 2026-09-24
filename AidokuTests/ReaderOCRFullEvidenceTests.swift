import CryptoKit
import Foundation
import Testing
import UIKit
@testable import Aidoku

/// Staged only. Root must copy into BOTH snapshots and centrally execute.
/// Live CoreML OCR; no provider, model settings change, download or UI rendering.
@Suite(.serialized)
struct ReaderOCRFullEvidenceTests {
    @available(iOS 18.0, *)
    private static func sourceFingerprint(_ image: CGImage) async throws -> NativeOCRFrameFingerprint {
        let frame = try #require(await NativeOCRCGImageAdapter.makeRGBAFrameOffMain(from: image))
        return NativeOCRFrameDigestBuilder.fingerprint(of: frame)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath:
        URL.documentsDirectory.appendingPathComponent("Round2OCR/enabled").path)))
    func fullGeometryOrderAndSourceIdentityAcrossWarmAndPurge() async throws {
        guard #available(iOS 18.0, *) else { return }
        struct Fixture: Decodable { let id: String; let image: String }
        let root = URL.documentsDirectory.appendingPathComponent("LookaheadDevice")
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        try #require(!fixtures.isEmpty && fixtures.count <= 2, "Bounded audit: one or two fixtures only")
        let configuration = await MainActor.run { ReaderTranslationSettings().ocrConfiguration }
        let output = URL.documentsDirectory.appendingPathComponent("Round2OCR").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(configuration).write(to: output.appendingPathComponent("configuration.json"), options: .atomic)
        var firstRegions: [Int: [ReaderTranslationRegion]] = [:]
        var firstSourceHashes: [Int: String] = [:]
        var rows: [[String: Any]] = []
        await ReaderOCRService.shared.purge()
        // Pass0 cold, pass1 resident warm, pass2 after explicit purge/reload.
        for pass in 0..<3 {
            if pass == 2 { await ReaderOCRService.shared.purge() }
            for (index, fixture) in fixtures.enumerated() {
                let inputURL = root.appendingPathComponent(fixture.image)
                let sourceData = try Data(contentsOf: inputURL)
                let image = try #require(UIImage(data: sourceData)?.cgImage)
                let digest = SHA256.hash(data: sourceData).map { String(format: "%02x", $0) }.joined()
                if let first = firstSourceHashes[index] { #expect(first == digest) } else { firstSourceHashes[index] = digest }
                // Keep byte-identical input alongside output; names do not use untrusted fixture ids.
                try sourceData.write(to: output.appendingPathComponent("fixture-\(index)-source.bin"), options: .atomic)
                let fingerprint = try await Self.sourceFingerprint(image)
                try encoder.encode(fingerprint).write(to: output.appendingPathComponent("fixture-\(index)-pass-\(pass)-pixels.json"), options: .atomic)
                let start = ProcessInfo.processInfo.systemUptime
                let regions = try await ReaderOCRService.shared.recognize(image: image, configuration: configuration)
                let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
                let encoded = try encoder.encode(regions.map(ReaderTranslationStoredRegion.init))
                try encoded.write(to: output.appendingPathComponent("fixture-\(index)-pass-\(pass)-regions.json"), options: .atomic)
                // Current full stored schema includes bbox, polygon, confidence, orientation,
                // reading array order, single-column, auxiliary ink and translation-order fields.
                let restored = try JSONDecoder().decode([ReaderTranslationStoredRegion].self, from: encoded).map(\.region)
                #expect(restored == regions, "Full stored schema must preserve every OCR region field")
                let repeatedExactly: Bool
                if let first = firstRegions[index] { repeatedExactly = first == regions }
                else { firstRegions[index] = regions; repeatedExactly = true }
                // Write evidence before a failed equality assertion; never weaken tolerances.
                rows.append(["fixture": fixture.id, "fixtureIndex": index, "pass": pass,
                    "phase": ["cold", "warm", "afterPurge"][pass], "milliseconds": milliseconds,
                    "sourceSHA256": digest, "regionCount": regions.count, "equalToFirstFullRegions": repeatedExactly,
                    "ocrPhaseMilliseconds": await ReaderOCRService.shared.lastPhaseMilliseconds])
                try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys, .prettyPrinted])
                    .write(to: output.appendingPathComponent("summary.json"), options: .atomic)
                #expect(repeatedExactly, "No OCR text/order/geometry/confidence/auxiliary tolerance permitted")
            }
        }
        await ReaderOCRService.shared.purge()
    }
}
