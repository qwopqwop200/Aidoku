//
//  BlockingTask.swift
//  Aidoku
//
//  Created by Skitty on 5/8/25.
//

import Foundation

private enum BlockingTaskPriority {
    static func current() -> TaskPriority {
        if let priority = withUnsafeCurrentTask(body: { $0?.priority }) {
            return priority
        }
        // A synchronous Nuke/WASM callback may be on a dispatch worker without
        // a Swift task. Preserve that worker's effective QoS as well.
        switch qos_class_self() {
        case QOS_CLASS_USER_INTERACTIVE: return TaskPriority(rawValue: 33)
        case QOS_CLASS_USER_INITIATED: return .high
        case QOS_CLASS_UTILITY: return .low
        case QOS_CLASS_BACKGROUND: return .background
        default: return .medium
        }
    }
}

/// Condition state distinguishes an unfinished operation from a completed optional nil.
/// Every waiter observes the same completion, including repeated reads after a failure.
private final class BlockingResult<Success, Failure: Error>: @unchecked Sendable {
    private let condition = NSCondition()
    private var result: Result<Success, Failure>?

    func finish(_ value: Result<Success, Failure>) {
        condition.lock()
        result = value
        condition.broadcast()
        condition.unlock()
    }

    func get() throws(Failure) -> Success {
        condition.lock()
        defer { condition.unlock() }
        while result == nil { condition.wait() }
        return try result!.get()
    }
}

final class BlockingTask<T>: @unchecked Sendable {
    private let result = BlockingResult<T, Never>()

    init(priority: TaskPriority? = nil, block: @escaping @Sendable () async -> T) {
        Task.detached(priority: priority ?? BlockingTaskPriority.current()) {
            self.result.finish(.success(await block()))
        }
    }

    func get() -> T { result.get() }
}

final class BlockingThrowingTask<T>: @unchecked Sendable {
    private let result = BlockingResult<T, Error>()

    init(block: @escaping @Sendable () async throws -> T) {
        Task.detached(priority: BlockingTaskPriority.current()) {
            do {
                self.result.finish(.success(try await block()))
            } catch {
                self.result.finish(.failure(error))
            }
        }
    }

    func get() throws -> T { try result.get() }
}
