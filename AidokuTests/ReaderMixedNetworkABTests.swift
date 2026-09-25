import CryptoKit
import Foundation
import Nuke
import Testing
import UIKit
@testable import Aidoku

/// Copy this file unchanged to the frozen baseline. Uses only pre-phase2 APIs.
/// Requires network-fixture.py on host loopback port 8766 (iOS Simulator).
@Suite(.serialized) @MainActor
struct ReaderMixedNetworkABTests {
    @Test(arguments: ["idle", "backlog", "repeat", "cancel", "coalesced"])
    func coldVisibleReaderWithFiniteSharedBandwidth(scenario: String) async throws {
        let endpoint = "http://127.0.0.1:8766"
        let run = UUID().uuidString
        let control = URLSession(configuration: .ephemeral)
        defer { control.invalidateAndCancel() }
        _ = try await control.data(from: URL(string: endpoint + "/health")!)

        let defaults = UserDefaults.standard
        let keys = ["Reader.liveText", "Dictionary.enable", "Reader.upscaleImages", "Reader.downsampleImages",
                    "Reader.cropBorders", "Reader.translation.automatic"]
        let saved = keys.reduce(into: [String: Any]()) { $0[$1] = defaults.object(forKey: $1) }
        keys.forEach { defaults.set(false, forKey: $0) }
        defer {
            for key in keys {
                if let value = saved[key] { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        let originalPipeline = ImagePipeline.shared
        let pipeline = ImagePipeline {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpMaximumConnectionsPerHost = 12
            $0.dataLoader = DataLoader(configuration: configuration)
            $0.imageCache = nil
            $0.dataCache = nil
        }
        ImagePipeline.shared = pipeline
        defer { pipeline.invalidate(); ImagePipeline.shared = originalPipeline }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = 12
        let transport = URLSession(configuration: configuration)
        defer { transport.invalidateAndCancel() }
        let cache = DownloadCache()
        let start = ProcessInfo.processInfo.systemUptime
        let bulkCount = scenario == "idle" ? 0 : 18
        let bulk = (0..<bulkCount).map { index in
            Task { () -> ABNetworkBulkResult in
                let url = URL(string: endpoint + "/page?run=\(run)&kind=bulk&id=\(index)&bytes=262144")!
                let request = URLRequest(url: url)
                let worker = DownloadTask(id: "ab-\(run)-\(index)", cache: cache, downloads: [])
                let result = await worker.fetchPageResource(for: request, tmpDirectory: .temporaryDirectory,
                    fetch: { try await transport.data(for: request) }, cleanup: { _ in })
                return ABNetworkBulkResult(bytes: result?.0.count ?? 0,
                    completedAt: ProcessInfo.processInfo.systemUptime - start)
            }
        }
        defer { bulk.forEach { $0.cancel() } }
        if bulkCount > 0 {
            try await waitUntil {
                let records = try await stats(control, endpoint: endpoint, run: run).records
                return records.filter { $0.kind == "bulk" && $0.completed == nil && $0.cancelled == nil }.count >= 5
            }
        }
        var readers: [ReaderPageView] = []
        defer { readers.forEach { $0.releasePageResources() } }
        func view() -> ReaderPageView {
            let result = ReaderPageView(temporaryPageStore: ReaderTemporaryPageStore())
            result.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
            result.imageLoadPriority = .high
            readers.append(result)
            return result
        }
        func source(_ index: Int) -> Aidoku.Page {
            Page(sourceId: "mixed-network-ab", chapterId: run, index: index,
                imageURL: endpoint + "/page?run=\(run)&kind=reader&id=\(index)&bytes=524288")
        }
        var readerLatencies: [Double] = []
        var digests: [String] = []
        var decodedBytes: [Int] = []
        var cancellationMS: Double?
        func inspect(_ reader: ReaderPageView, since: TimeInterval) throws {
            let image = try #require(reader.imageView.image?.cgImage)
            let data = try #require(image.dataProvider?.data) as Data
            readerLatencies.append((ProcessInfo.processInfo.systemUptime - since) * 1000)
            digests.append(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
            decodedBytes.append(image.bytesPerRow * image.height)
            #expect(image.width == 64 && image.height == 64)
        }
        if scenario == "cancel" {
            let outgoing = view()
            let pending = Task { await outgoing.setPage(source(90)) }
            try await waitUntil {
                try await stats(control, endpoint: endpoint, run: run).records.contains { $0.kind == "reader" }
            }
            try await Task.sleep(for: .milliseconds(80))
            let cancelledAt = ProcessInfo.processInfo.systemUptime
            outgoing.releasePageResources()
            pending.cancel()
            #expect(await pending.value == false)
            try await waitUntil {
                try await stats(control, endpoint: endpoint, run: run).records
                    .filter { $0.kind == "reader" }.allSatisfy { $0.completed != nil || $0.cancelled != nil }
            }
            cancellationMS = (ProcessInfo.processInfo.systemUptime - cancelledAt) * 1000
        }
        if scenario == "coalesced" {
            let first = view(), second = view()
            let issued = ProcessInfo.processInfo.systemUptime
            let firstLoad = Task { await first.setPage(source(0)) }
            let secondLoad = Task { await second.setPage(source(0)) }
            #expect(await firstLoad.value)
            #expect(await secondLoad.value)
            try inspect(first, since: issued)
            try inspect(second, since: issued)
        } else {
            for index in 0..<(scenario == "repeat" ? 3 : 1) {
                let current = view()
                let issued = ProcessInfo.processInfo.systemUptime
                #expect(await current.setPage(source(index)))
                try inspect(current, since: issued)
                current.releasePageResources()
            }
        }
        let readerFinishedAt = ProcessInfo.processInfo.systemUptime - start
        var results: [ABNetworkBulkResult] = []
        for task in bulk { results.append(await task.value) }
        #expect(results.allSatisfy { $0.bytes == 262144 })
        #expect(Set(digests).count == 1, "Navigation, cancellation, and coalescing must preserve decoded pixels")
        let final = try await stats(control, endpoint: endpoint, run: run)
        let networkReaderCount = final.records.filter { $0.kind == "reader" }.count
        #expect(networkReaderCount == (scenario == "repeat" ? 3 : scenario == "cancel" ? 2 : 1))
        #expect(final.records.filter { $0.kind == "bulk" && $0.completed != nil }.count == bulkCount)
        let report: [String: Any] = [
            "scenario": scenario, "run": run, "aggregateServerBytesPerSecond": final.rateBytesPerSecond,
            "scope": "actual loopback URLSession + Nuke + ReaderPageView image assignment; fixed fair aggregate bandwidth",
            "visibleImageAssignmentMS": readerLatencies, "readerFinishedFromStartSeconds": readerFinishedAt,
            "bulkCompletionFromStartSeconds": results.map(\.completedAt).max() ?? 0,
            "bulkCount": bulkCount, "bulkBytes": results.reduce(0) { $0 + $1.bytes },
            "readerNetworkRequests": networkReaderCount, "imageSHA256": digests,
            "decodedImageBytes": decodedBytes, "readerCancelToServerDisconnectMS": cancellationMS as Any? ?? NSNull(),
            "serverRecords": final.records.map { $0.dictionary }
        ]
        let folder = URL.documentsDirectory.appendingPathComponent("ReaderSchedulingPhase2Evidence")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: folder.appendingPathComponent("mixed-network-\(scenario).json"))
        print("MIXED_NETWORK_AB \(scenario) readerMS=\(readerLatencies) bulkSeconds=\(results.map(\.completedAt).max() ?? 0) digest=\(digests.first ?? "")")
    }

    private func stats(_ session: URLSession, endpoint: String, run: String) async throws -> ABNetworkStats {
        let (data, _) = try await session.data(from: URL(string: endpoint + "/stats?run=" + run)!)
        return try JSONDecoder().decode(ABNetworkStats.self, from: data)
    }
    private func waitUntil(_ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !(try await condition()) {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct ABNetworkBulkResult: Sendable { let bytes: Int; let completedAt: Double }
private struct ABNetworkStats: Decodable { let rateBytesPerSecond: Int; let records: [ABNetworkRecord] }
private struct ABNetworkRecord: Decodable {
    let kind: String
    let id: String
    let bytes: Int
    let started: Double
    let completed: Double?
    let cancelled: Double?
    var dictionary: [String: Any] {
        ["kind": kind, "id": id, "bytes": bytes, "started": started,
         "completed": completed as Any? ?? NSNull(), "cancelled": cancelled as Any? ?? NSNull()]
    }
}
