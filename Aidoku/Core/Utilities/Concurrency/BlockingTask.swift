import Foundation

#if canImport(Darwin)
import Darwin
#endif

private enum BlockingTaskPriority {
    static func current() -> TaskPriority {
        if let priority = withUnsafeCurrentTask(body: { $0?.priority }) {
            return priority
        }
        // A synchronous Nuke/WASM callback may be on a dispatch worker without
        // a Swift task. Preserve that worker's effective QoS as well.
        #if canImport(Darwin)
        switch qos_class_self() {
        case QOS_CLASS_USER_INTERACTIVE: return TaskPriority(rawValue: 33)
        case QOS_CLASS_USER_INITIATED: return .high
        case QOS_CLASS_UTILITY: return .low
        case QOS_CLASS_BACKGROUND: return .background
        default: return .medium
        }
        #else
        return .medium
        #endif
    }
}

/// Condition state distinguishes an unfinished operation from a completed optional nil.
/// Every waiter observes the same completion, including repeated reads after a failure.
final class BlockingTask<T>: @unchecked Sendable {
    private let condition = NSCondition()
    private var result: T?
    private var completed = false

    private var operation: Task<Void, Never>?
    private let forwardsCancellation: Bool

    init(priority: TaskPriority? = nil, forwardsCancellation: Bool = false, block: @escaping @Sendable () async -> T) {
        self.forwardsCancellation = forwardsCancellation
        operation = Task.detached(priority: priority ?? BlockingTaskPriority.current()) {
            self.finish(await block())
        }
    }

    private func finish(_ value: T) {
        condition.lock()
        result = value
        completed = true
        condition.broadcast()
        condition.unlock()
    }

    func get() -> T {
        condition.lock()
        defer { condition.unlock() }
        // Opt in only for a cancellation-aware operation. The synchronous
        // caller must still join actual completion so admission/resources stay
        // owned until the model has stopped, including a noninterruptible tile.
        let observesCancellation = forwardsCancellation && withUnsafeCurrentTask { $0 != nil }
        var forwarded = false
        while !completed {
            if observesCancellation {
                if !forwarded, Task.isCancelled {
                    forwarded = true
                    // Task.cancel may run cancellation handlers synchronously.
                    condition.unlock()
                    operation?.cancel()
                    condition.lock()
                    if completed { break }
                }
                _ = condition.wait(until: Date().addingTimeInterval(0.02))
            } else {
                condition.wait()
            }
        }
        return result!
    }
}

final class BlockingThrowingTask<T>: @unchecked Sendable {
    private let condition = NSCondition()
    private var result: Result<T, Error>?

    init(priority: TaskPriority? = nil, block: @escaping @Sendable () async throws -> T) {
        Task.detached(priority: priority ?? BlockingTaskPriority.current()) {
            do {
                self.finish(.success(try await block()))
            } catch {
                self.finish(.failure(error))
            }
        }
    }

    private func finish(_ value: Result<T, Error>) {
        condition.lock()
        result = value
        condition.broadcast()
        condition.unlock()
    }

    func get() throws -> T {
        condition.lock()
        defer { condition.unlock() }
        while result == nil { condition.wait() }
        return try result!.get()
    }
}
