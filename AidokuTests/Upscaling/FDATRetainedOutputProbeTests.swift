import CryptoKit
import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct FDATRetainedOutputProbeTests {
    @Test(.enabled(if: FileManager.default.fileExists(atPath:
        URL.documentsDirectory.appendingPathComponent("FullAuditUpscale/fdat-retained-enabled").path)))
    func sameRealCanonicalInputWhileFirstOutputIsRetained() async throws {
        let root = URL.documentsDirectory.appendingPathComponent("FullAuditUpscale")
        let image = try #require(UIImage(contentsOfFile: root.appendingPathComponent("input.png").path)?.cgImage)
        try #require(image.width > 0 && image.height > 0 && image.width <= 200 && image.height <= 200)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { folder.removeItem() }
        let manager = ModelManager(directory: folder)
        let entry = try #require(await manager.bundledModels().first { $0.file == "IllustrationJaNaiV3-FDATM.mlpackage" })
        try await manager.downloadModel(entry)
        let model = try #require(try await manager.getModel(fileName: entry.file))
        let output = root.appendingPathComponent("FDATRetained-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try #require(UIImage(cgImage: image).pngData()).write(to: output.appendingPathComponent("input.png"), options: .atomic)
        var rows: [[String: Any]] = []
        var allExact = true
        func saveReport(completed: Bool, preCancelledReturnedNil: Bool? = nil) throws {
            var report: [String: Any] = ["calls": rows, "allCompletedPNGsExact": allExact,
                "completed": completed,
                "scope": "One fixed real source <=200x200; first call plus three repeated identical canonical inputs, first CGImage explicitly alive through every repeat. Same probe on baseline/candidate. sameOutputObject is diagnostic, not baseline expectation. Timers cover model.process only, exclude install/load/PNG. Actual reader UI performance and peak/device memory unverified."]
            if let preCancelledReturnedNil { report["preCancelledReturnedNil"] = preCancelledReturnedNil }
            try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
                .write(to: output.appendingPathComponent("results.json"), options: .atomic)
        }
        let firstStart = ProcessInfo.processInfo.systemUptime
        let first = try #require(await model.process(image))
        let firstMS = (ProcessInfo.processInfo.systemUptime - firstStart) * 1000
        let firstPNG = try #require(UIImage(cgImage: first).pngData())
        try firstPNG.write(to: output.appendingPathComponent("call-0.png"), options: .atomic)
        rows.append(["call": 0, "milliseconds": firstMS, "sameOutputObject": true,
            "exactPNGWithFirst": true, "outputPNG": "call-0.png",
            "sha256": SHA256.hash(data: firstPNG).map { String(format: "%02x", $0) }.joined()])
        try saveReport(completed: false)
        #expect(first.width == image.width * 4 && first.height == image.height * 4)
        for repeatIndex in 1...3 {
            let samePixels = try #require(image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: image.height)))
            let start = ProcessInfo.processInfo.systemUptime
            let repeated = try #require(await model.process(samePixels))
            let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
            let png = try #require(UIImage(cgImage: repeated).pngData())
            let exact = png == firstPNG
            allExact = allExact && exact
            let name = "call-\(repeatIndex).png"
            try png.write(to: output.appendingPathComponent(name), options: .atomic)
            rows.append(["call": repeatIndex, "milliseconds": elapsed, "sameOutputObject": repeated === first,
                "exactPNGWithFirst": exact, "outputPNG": name,
                "sha256": SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()])
            // Persist each successful call before assertions or any later inference/cancellation.
            try saveReport(completed: false)
            #expect(exact)
            #expect(repeated.width == first.width && repeated.height == first.height)
        }
        // Actor-isolated task cannot start before synchronous cancellation on this actor.
        let cancelled = Task { await model.process(image) }
        cancelled.cancel()
        let preCancelledReturnedNil = await cancelled.value == nil
        try saveReport(completed: true, preCancelledReturnedNil: preCancelledReturnedNil)
        #expect(preCancelledReturnedNil)
        #expect(allExact)
        withExtendedLifetime(first) { }
        await manager.removeModel(withFile: entry.file)
    }
}
