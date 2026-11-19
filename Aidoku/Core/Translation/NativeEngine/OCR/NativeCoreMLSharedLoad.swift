// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import Foundation

@available(iOS 18.0, *)
struct NativeCoreMLSharedLoadAccess<Value: Sendable>: Sendable {
    let value: Value
    /// True only for the caller that created the shared load task. A recognizer
    /// joining preparation reports zero model-load time in OCR diagnostics.
    let initiatedLoad: Bool
}

/// An explicit preparation lifetime. Frame cancellation intentionally leaves
/// this revision alone so a newer frame can reuse an in-flight specialization;
/// OCR OFF and resource purge invalidate it before any store is cleared.
@available(iOS 18.0, *)
final class NativeCoreMLPreparationRevision: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func token() -> UInt64 {
        lock.withLock { value }
    }

    func invalidate() {
        lock.withLock { value &+= 1 }
    }

    func requireCurrent(_ token: UInt64) throws {
        try Task.checkCancellation()
        let isCurrent = lock.withLock { value == token }
        guard isCurrent else { throw CancellationError() }
    }
}

/// Coalesces one Core ML function specialization per key. Frame cancellation
/// does not cancel this reusable work; only the explicit resource-purge
/// boundary cancels pending tasks and advances the revision.
@available(iOS 18.0, *)
actor NativeCoreMLSharedLoadCoordinator<
    Key: Hashable & Sendable,
    Value: Sendable
> {
    private struct Pending: Sendable {
        let revision: UInt64
        let token: UInt64
        let task: Task<Value, Error>
    }

    private var revision: UInt64 = 0
    private var nextToken: UInt64 = 0
    private var pending: [Key: Pending] = [:]

    func load(
        for key: Key,
        using loader: @escaping @Sendable () async throws -> Value
    ) async throws -> NativeCoreMLSharedLoadAccess<Value> {
        let issuedRevision = revision
        let entry: Pending
        let initiatedLoad: Bool
        if let existing = pending[key],
           existing.revision == issuedRevision {
            entry = existing
            initiatedLoad = false
        } else {
            nextToken &+= 1
            let task = Task { try await loader() }
            entry = Pending(
                revision: issuedRevision,
                token: nextToken,
                task: task
            )
            pending[key] = entry
            initiatedLoad = true
        }

        let value: Value
        do {
            value = try await entry.task.value
        } catch {
            if pending[key]?.token == entry.token {
                pending[key] = nil
            }
            throw error
        }
        guard revision == issuedRevision else {
            throw CancellationError()
        }
        if pending[key]?.token == entry.token {
            pending[key] = nil
        }
        return NativeCoreMLSharedLoadAccess(
            value: value,
            initiatedLoad: initiatedLoad
        )
    }

    func purge() {
        revision &+= 1
        pending.values.forEach { $0.task.cancel() }
        pending.removeAll(keepingCapacity: false)
    }
}
