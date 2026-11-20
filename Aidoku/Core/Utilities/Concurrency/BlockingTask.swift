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
final class BlockingTask<T>: @unchecked Sendable {
    private let condition = NSCondition()
    private var result: T?
    private var completed = false

    init(priority: TaskPriority? = nil, block: @escaping @Sendable () async -> T) {
        Task.detached(priority: priority ?? BlockingTaskPriority.current()) {
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
        while !completed { condition.wait() }
        return result!
    }
}

final class BlockingThrowingTask<T>: @unchecked Sendable {
    private let condition = NSCondition()
    private var result: Result<T, Error>?

    init(block: @escaping @Sendable () async throws -> T) {
        Task.detached(priority: BlockingTaskPriority.current()) {
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
