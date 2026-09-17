import AidokuRunner
import Foundation
import Testing
@testable import Aidoku

/// Local HTTP fixture exercises URLSession's actual download-to-file path,
/// including status-code retry and cancellation; no remote provider involved.
@Suite(.serialized) @MainActor
struct DownloadFilePipelineTests {
    private static var configuration: URL { URL.documentsDirectory.appendingPathComponent("OptimizationFixtures/download-server.txt") }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: URL.documentsDirectory.appendingPathComponent("OptimizationFixtures/download-server.txt").path)))
    func fileBackedResponseRetryAndCancellation() async throws {
        let base = try String(contentsOf: Self.configuration, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = DownloadTask(id: "file-test", cache: DownloadCache(), downloads: [],
            network: SourceNetwork(enabled: { false }, directSession: session))
        let source = AidokuRunner.Source.test(runner: TestableSourceRunner(processesPages: false))
        let direct = DownloadTask.NetworkPage(url: URL(string: base + "/image.png")!, context: nil,
            targetPath: root.appendingPathComponent("001"), pageNumber: 1)
        let result = await task.downloadPage(direct, source: source, tmpDirectory: root)
        #expect(result.data == nil)
        let file = try #require(result.stagedFile)
        #expect(file.deletingLastPathComponent().path == root.path)
        #expect(result.targetPath?.pathExtension == "png")
        let expected = try Data(contentsOf: file)
        #expect(expected.starts(with: [137, 80, 78, 71]))
        file.removeItem()

        let retry = DownloadTask.NetworkPage(url: URL(string: base + "/retry.png?" + UUID().uuidString)!, context: nil,
            targetPath: root.appendingPathComponent("002"), pageNumber: 2)
        let retried = await task.downloadPage(retry, source: source, tmpDirectory: root)
        let retryFile = try #require(retried.stagedFile)
        #expect(try Data(contentsOf: retryFile) == expected)
        retryFile.removeItem()

        let slow = DownloadTask.NetworkPage(url: URL(string: base + "/slow.png")!, context: nil,
            targetPath: root.appendingPathComponent("003"), pageNumber: 3)
        let pending = Task { await task.downloadPage(slow, source: source, tmpDirectory: root) }
        try await Task.sleep(for: .milliseconds(100))
        pending.cancel()
        let cancelled = await pending.value
        #expect(cancelled.stagedFile == nil)
        #expect(cancelled.targetPath == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}
