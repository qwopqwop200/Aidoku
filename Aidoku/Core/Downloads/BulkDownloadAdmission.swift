import Foundation

/// Lowers the bulk transfer ceiling while a visible reader image is loading.
actor BulkDownloadAdmission {
    static let shared = BulkDownloadAdmission()

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private let idleLimit = 5
    private let readerLimit = 2
    private let demandGraceNanoseconds: UInt64 = 300_000_000
    private var readers = Set<UUID>()
    private var eligibleReaders = Set<UUID>()
    private var pendingReaders: [UUID: Task<Void, Never>] = [:]
    private var activeDownloads = 0
    private var waiters: [Waiter] = []

    deinit { pendingReaders.values.forEach { $0.cancel() } }

    private var limit: Int { eligibleReaders.isEmpty ? idleLimit : readerLimit }

    /// The caller owns the lease until it releases it.
    func acquireReaderDemand() throws -> UUID {
        try Task.checkCancellation()
        let id = UUID()
        readers.insert(id)
        // Demand counts only after a grace period, so brief loads never throttle.
        let grace = demandGraceNanoseconds
        pendingReaders[id] = Task.detached(priority: .utility) { [weak self] in
            do { try await Task.sleep(nanoseconds: grace) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.activateReaderDemand(id)
        }
        return id
    }

    func releaseReaderDemand(_ id: UUID) {
        guard readers.remove(id) != nil else { return }
        pendingReaders.removeValue(forKey: id)?.cancel()
        eligibleReaders.remove(id)
        admitWaiters()
    }

    private func activateReaderDemand(_ id: UUID) {
        guard readers.contains(id), pendingReaders.removeValue(forKey: id) != nil else { return }
        eligibleReaders.insert(id)
    }

    func withPermit<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let id = UUID()
        try await acquire(id)
        defer { activeDownloads -= 1; admitWaiters() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire(_ id: UUID) async throws {
        try Task.checkCancellation()
        if activeDownloads < limit {
            activeDownloads += 1
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append(Waiter(id: id, continuation: continuation)) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func admitWaiters() {
        while activeDownloads < limit, !waiters.isEmpty {
            activeDownloads += 1
            waiters.removeFirst().continuation.resume()
        }
    }
}
