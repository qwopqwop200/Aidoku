import Foundation
import Testing
@testable import Nuke

struct ActiveDataPriorityTests {
    @Test func coalescedRunningTransferPromotesDemotesAndOnlyCancelsAtLastSubscriber() async throws {
        let loader = PriorityProbeLoader()
        let pipeline = ImagePipeline { $0.dataLoader = loader; $0.imageCache = nil; $0.isRateLimiterEnabled = false }
        let url = URL(string: "https://priority.invalid/" + UUID().uuidString)!
        let lowRequest = ImageRequest(url: url, priority: .veryLow)
        let highRequest = ImageRequest(url: url, priority: .high)
        let low = Task { try await pipeline.data(for: lowRequest) }
        defer { low.cancel() }
        try await wait { loader.priorities.last == 0 }
        let high = Task { try await pipeline.data(for: highRequest) }
        defer { high.cancel() }
        try await wait { loader.priorities.last == 0.75 }
        #expect(loader.loads == 1, "Promotion must share the already-running transport")
        high.cancel()
        _ = try? await high.value
        try await wait { loader.priorities.last == 0 }
        #expect(loader.cancellations == 0, "Low-priority consumer still owns the transport")
        low.cancel()
        _ = try? await low.value
        try await wait { loader.cancellations == 1 }
        #expect(loader.loads == 1)
    }

    @Test func defaultLoaderForwardsPriorityToRunningURLSessionTask() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PriorityStallURLProtocol.self]
        let loader = DataLoader(configuration: configuration)
        let handle = loader.loadData(with: URLRequest(url: URL(string: "https://priority-stall.invalid/image")!),
                                     didReceiveData: { _, _ in }, completion: { _ in })
        defer { handle.cancel() }
        let prioritizable = try #require(handle as? any DataLoadingPriorityUpdating)
        prioritizable.setPriority(0.9)
        let tasks = await loader.session.allTasks
        let task = try #require(tasks.first)
        #expect(task.priority == 0.9)
        prioritizable.setPriority(0.1)
        #expect(task.priority == 0.1)
        #expect(tasks.count == 1)
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            if Date() >= deadline { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private final class PriorityProbeLoader: DataLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedPriorities: [Float] = []
    private var recordedLoads = 0
    private var recordedCancellations = 0
    var priorities: [Float] { lock.withLock { recordedPriorities } }
    var loads: Int { lock.withLock { recordedLoads } }
    var cancellations: Int { lock.withLock { recordedCancellations } }
    func loadData(with request: URLRequest, didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
                  completion: @escaping @Sendable (Error?) -> Void) -> any Cancellable {
        lock.withLock { recordedLoads += 1 }
        return PriorityProbeHandle(update: { [weak self] priority in
            self?.lock.withLock { self?.recordedPriorities.append(priority) }
        }, cancel: { [weak self] in
            self?.lock.withLock { self?.recordedCancellations += 1 }
            completion(CancellationError())
        })
    }
}

private final class PriorityProbeHandle: DataLoadingPriorityUpdating, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let update: @Sendable (Float) -> Void
    private let onCancel: @Sendable () -> Void
    init(update: @escaping @Sendable (Float) -> Void, cancel: @escaping @Sendable () -> Void) {
        self.update = update; self.onCancel = cancel
    }
    func setPriority(_ priority: Float) { update(priority) }
    func cancel() {
        let first = lock.withLock { if cancelled { return false }; cancelled = true; return true }
        if first { onCancel() }
    }
}

private final class PriorityStallURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "priority-stall.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}
