import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized) @MainActor
struct DownloadTransportAdmissionTests {
    private actor Probe {
        var active = 0
        var peak = 0
        var starts = 0

        func fetch(_ request: URLRequest, status: Int = 200, delay: Duration = .milliseconds(30)) async throws -> (Data, URLResponse) {
            active += 1
            starts += 1
            peak = max(peak, active)
            defer { active -= 1 }
            try await Task.sleep(for: delay)
            return (Data([1]), HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: ["Retry-After": "60"])!)
        }
    }

    private var request: URLRequest { URLRequest(url: URL(string: "https://download-fixture.invalid/page.png")!) }

    @Test func separateSourceWorkersShareOneBulkTransportCeiling() async {
        let probe = Probe()
        let request = request
        let cache = DownloadCache()
        await withTaskGroup(of: Bool.self) { group in
            // Separate workers model simultaneous ordinary and translated source
            // queues. The production default, rather than an injected cap, is used.
            for index in 0..<24 {
                group.addTask {
                    let worker = DownloadTask(id: "source-\(index)", cache: cache, downloads: [])
                    return await worker.fetchPageResource(for: request, tmpDirectory: .temporaryDirectory,
                        fetch: { try await probe.fetch(request) }, cleanup: { _ in }) != nil
                }
            }
            for await succeeded in group { #expect(succeeded) }
        }
        #expect(await probe.starts == 24)
        #expect(await probe.peak <= 5)
        #expect(await probe.peak > 1)
    }

    @Test func cancelledQueuedDownloadNeverStartsTransportAndNextRequestRecovers() async throws {
        let limiter = TranslationProviderRequestLimiter(maximumConcurrentRequests: 1)
        let probe = Probe()
        let request = request
        let active = Task {
            try await limiter.withPermit { try await probe.fetch(request, delay: .seconds(60)) }
        }
        defer { active.cancel() }
        try await waitUntil { await probe.starts == 1 }
        let worker = DownloadTask(id: "queued", cache: DownloadCache(), downloads: [], transportLimiter: limiter)
        let queued = Task {
            await worker.fetchPageResource(for: request, tmpDirectory: .temporaryDirectory,
                fetch: { try await probe.fetch(request) }, cleanup: { _ in })
        }
        defer { queued.cancel() }
        try await waitUntil { await limiter.queuedRequestCount == 1 }
        queued.cancel()
        #expect(await queued.value == nil)
        #expect(await probe.starts == 1)
        #expect(await limiter.queuedRequestCount == 0)
        active.cancel()
        _ = try? await active.value
        let recovered = await worker.fetchPageResource(for: request, tmpDirectory: .temporaryDirectory,
            fetch: { try await probe.fetch(request) }, cleanup: { _ in })
        #expect(recovered != nil)
        #expect(await probe.starts == 2)
    }

    @Test func rateLimitedSourceReleasesTransportWhileBackingOff() async throws {
        let limiter = TranslationProviderRequestLimiter(maximumConcurrentRequests: 1)
        let probe = Probe()
        let request = request
        let retryingWorker = DownloadTask(id: "rate-limited", cache: DownloadCache(), downloads: [], transportLimiter: limiter)
        let retrying = Task {
            await retryingWorker.fetchPageResource(for: request, tmpDirectory: .temporaryDirectory,
                fetch: { try await probe.fetch(request, status: 429) }, cleanup: { _ in })
        }
        defer { retrying.cancel() }
        try await waitUntil {
            let starts = await probe.starts
            let active = await probe.active
            return starts == 1 && active == 0
        }
        let otherWorker = DownloadTask(id: "other-source", cache: DownloadCache(), downloads: [], transportLimiter: limiter)
        let other = Task {
            await otherWorker.fetchPageResource(for: request, tmpDirectory: .temporaryDirectory,
                fetch: { try await probe.fetch(request) }, cleanup: { _ in })
        }
        defer { other.cancel() }
        try await waitUntil { await probe.starts == 2 }
        #expect(await other.value != nil)
        retrying.cancel()
        #expect(await retrying.value == nil)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for download transport state")
        throw CancellationError()
    }
}
