import Foundation

/// One gate per render worker. A lease covers preparation, UI awaits and owned-job
/// teardown; cancellation never revokes an active owner's resources behind it.
actor NativeTranslationRenderAdmission {
    enum Failure: Error { case queueFull }

    struct Lease: Sendable {
        private let admission: NativeTranslationRenderAdmission
        fileprivate let token: UUID

        fileprivate init(admission: NativeTranslationRenderAdmission, token: UUID) {
            self.admission = admission
            self.token = token
        }

        /// The owner explicitly awaits this after its job/UI/bitmap teardown.
        /// Copied or repeated releases cannot release a subsequent owner.
        @discardableResult
        func release() async -> Bool { await admission.release(token) }
    }

    private struct Waiter {
        let token: UUID
        let continuation: CheckedContinuation<Lease, any Error>
    }

    private let maximumQueuedWaiters: Int
    private var owner: UUID?
    private var waiters: [Waiter] = []

    init(maximumQueuedWaiters: Int = 64) {
        precondition(maximumQueuedWaiters >= 0)
        self.maximumQueuedWaiters = maximumQueuedWaiters
    }

    var queuedCount: Int { waiters.count }

    func acquire() async throws -> Lease {
        let token = UUID()
        return try await withTaskCancellationHandler {
            let lease: Lease = try await withCheckedThrowingContinuation { continuation in
                // Handles cancellation before enqueue even if the cancellation
                // handler's actor message has not arrived yet.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if owner == nil {
                    owner = token
                    continuation.resume(returning: Lease(admission: self, token: token))
                } else if waiters.count >= maximumQueuedWaiters {
                    continuation.resume(throwing: Failure.queueFull)
                } else {
                    waiters.append(Waiter(token: token, continuation: continuation))
                }
            }
            do {
                // A release may grant before the queued cancellation message
                // arrives. The canceled acquire returns its own permit here.
                try Task.checkCancellation()
                return lease
            } catch {
                _ = release(token)
                throw error
            }
        } onCancel: {
            Task { await self.cancelQueued(token) }
        }
    }

    private func cancelQueued(_ token: UUID) {
        guard let index = waiters.firstIndex(where: { $0.token == token }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release(_ token: UUID) -> Bool {
        guard owner == token else { return false }
        if waiters.isEmpty {
            owner = nil
        } else {
            let next = waiters.removeFirst()
            owner = next.token
            next.continuation.resume(returning: Lease(admission: self, token: next.token))
        }
        return true
    }
}
