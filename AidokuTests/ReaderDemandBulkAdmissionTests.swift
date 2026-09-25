import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderDemandBulkAdmissionTests {
    private actor Probe {
        var starts: [Int] = []
        func fetch(_ index: Int, request: URLRequest) async throws -> (Data, URLResponse) {
            starts.append(index)
            try await Task.sleep(for: .seconds(60))
            return (Data([1]), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test func slowActiveTransfersDrainWithoutCancellationAndIdleCapacityRecovers() async throws {
        let admission = BulkDownloadAdmission(demandGraceNanoseconds: 0)
        let probe = Probe()
        let cache = DownloadCache()
        let request = URLRequest(url: URL(string: "https://bulk-admission.invalid/page")!)
        var tasks: [Task<(Data, URLResponse)?, Never>] = []
        defer { tasks.forEach { $0.cancel() } }
        for index in 0..<12 {
            let worker = DownloadTask(id: "bulk-\(index)", cache: cache, downloads: [], bulkAdmission: admission)
            tasks.append(Task {
                await worker.fetchPageResource(for: request, tmpDirectory: .temporaryDirectory,
                    fetch: { try await probe.fetch(index, request: request) }, cleanup: { _ in })
            })
            if index < 5 { try await waitUntil { await probe.starts.count == index + 1 } }
        }
        try await waitUntil { await admission.snapshot.queuedDownloads == 7 }
        let reader = try await admission.acquireReaderDemand()
        #expect(await admission.snapshot.activeDownloads == 5,
                "Visible demand must never terminate active bulk transfers")
        #expect(await admission.snapshot.limit == 2)
        for index in 0..<3 {
            tasks[index].cancel()
            #expect(await tasks[index].value == nil)
        }
        #expect(await admission.snapshot.activeDownloads == 2)
        #expect(await probe.starts.count == 5, "No refill until the reduced ceiling has room")
        tasks[3].cancel()
        #expect(await tasks[3].value == nil)
        try await waitUntil { await probe.starts.count == 6 }
        #expect(await admission.snapshot.activeDownloads == 2)
        await admission.releaseReaderDemand(reader)
        try await waitUntil { await probe.starts.count == 9 }
        #expect(await admission.snapshot.activeDownloads == 5)
        #expect(await admission.snapshot.limit == 5)
        tasks.forEach { $0.cancel() }
        for task in tasks { _ = await task.value }
        #expect(await admission.snapshot.activeDownloads == 0)
        #expect(await admission.snapshot.queuedDownloads == 0)
    }

    @Test func multipleReaderLeasesRequireLastReleaseAndCancelledWaitersDoNotConsumeRecoverySlots() async throws {
        let admission = BulkDownloadAdmission(demandGraceNanoseconds: 0)
        let firstReader = try await admission.acquireReaderDemand()
        let secondReader = try await admission.acquireReaderDemand()
        let first = Task { try await admission.withPermit { try await Task.sleep(for: .seconds(60)) } }
        let second = Task { try await admission.withPermit { try await Task.sleep(for: .seconds(60)) } }
        defer { first.cancel(); second.cancel() }
        try await waitUntil { await admission.snapshot.activeDownloads == 2 }
        let cancelled = Task { try await admission.withPermit { Issue.record("Cancelled bulk request entered transport") } }
        defer { cancelled.cancel() }
        try await waitUntil { await admission.snapshot.queuedDownloads == 1 }
        cancelled.cancel()
        _ = try? await cancelled.value
        #expect(await admission.snapshot.queuedDownloads == 0)
        await admission.releaseReaderDemand(firstReader)
        await admission.releaseReaderDemand(firstReader) // stale/double release cannot clear another reader
        #expect(await admission.snapshot.readerDemands == 1)
        #expect(await admission.snapshot.limit == 2)
        let recovered = Task { try await admission.withPermit { 42 } }
        defer { recovered.cancel() }
        try await waitUntil { await admission.snapshot.queuedDownloads == 1 }
        await admission.releaseReaderDemand(secondReader)
        #expect(try await recovered.value == 42)
        #expect(await admission.snapshot.readerDemands == 0)
        #expect(await admission.snapshot.limit == 5)
        first.cancel(); second.cancel()
        _ = try? await first.value
        _ = try? await second.value
        #expect(await admission.snapshot.activeDownloads == 0)
    }

    @Test func cancelledAcquisitionDoesNotLeaveReaderDemand() async throws {
        let admission = BulkDownloadAdmission(demandGraceNanoseconds: 0)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await admission.acquireReaderDemand()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await admission.snapshot.readerDemands == 0)
        #expect(await admission.snapshot.limit == 5)
    }

    @Test func defaultGraceDoesNotThrottleShortDemandOrReactivateAfterRelease() async throws {
        let admission = BulkDownloadAdmission()
        let token = try await admission.acquireReaderDemand()
        #expect(await admission.snapshot.limit == 5)
        #expect(await admission.snapshot.pendingReaderDemands == 1)
        // Completing/cancelling the load before grace cancels its timer.
        await admission.releaseReaderDemand(token)
        #expect(await admission.snapshot.pendingReaderDemands == 0)
        try await Task.sleep(for: .milliseconds(380))
        #expect(await admission.snapshot.readerDemands == 0)
        #expect(await admission.snapshot.eligibleReaderDemands == 0)
        #expect(await admission.snapshot.limit == 5)
    }

    @Test func defaultGraceActivatesPersistentDemandThenRestoresCapacity() async throws {
        let admission = BulkDownloadAdmission()
        let token = try await admission.acquireReaderDemand()
        #expect(await admission.snapshot.limit == 5)
        try await waitUntil { await admission.snapshot.eligibleReaderDemands == 1 }
        #expect(await admission.snapshot.pendingReaderDemands == 0)
        #expect(await admission.snapshot.limit == 2)
        await admission.releaseReaderDemand(token)
        #expect(await admission.snapshot.limit == 5)
        #expect(await admission.snapshot.readerDemands == 0)
    }

    @Test func overlappingDemandHasIndependentGraceAndReleasedTimersCannotRethrottle() async throws {
        let admission = BulkDownloadAdmission(demandGraceNanoseconds: 100_000_000)
        let first = try await admission.acquireReaderDemand()
        try await waitUntil { await admission.snapshot.eligibleReaderDemands == 1 }
        let second = try await admission.acquireReaderDemand()
        let cancelled = try await admission.acquireReaderDemand()
        await admission.releaseReaderDemand(cancelled)
        await admission.releaseReaderDemand(first)
        // An old eligible load must not donate its age to a new viewport load.
        #expect(await admission.snapshot.limit == 5)
        #expect(await admission.snapshot.readerDemands == 1)
        #expect(await admission.snapshot.pendingReaderDemands == 1)
        try await waitUntil { await admission.snapshot.eligibleReaderDemands == 1 }
        #expect(await admission.snapshot.limit == 2)
        await admission.releaseReaderDemand(second)
        try await Task.sleep(for: .milliseconds(130))
        #expect(await admission.snapshot.pendingReaderDemands == 0)
        #expect(await admission.snapshot.eligibleReaderDemands == 0)
        #expect(await admission.snapshot.limit == 5)
    }

    @Test func pendingGraceDoesNotRetainAdmissionOwner() async throws {
        var admission: BulkDownloadAdmission? = BulkDownloadAdmission(demandGraceNanoseconds: 60_000_000_000)
        weak var owner = admission
        _ = try await admission?.acquireReaderDemand()
        admission = nil
        #expect(owner == nil, "A grace timer must not retain its admission owner until expiry")
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for bulk admission state")
        throw CancellationError()
    }
}
