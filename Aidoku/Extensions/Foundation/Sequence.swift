//
//  Sequence.swift
//  Aidoku
//
//  Created by Skitty on 1/3/22.
//

import Foundation

extension Sequence where Self: Sendable, Element: Sendable {
    /// Structured children inherit cancellation; only a bounded window is issued.
    /// Results retain input order even when requests finish out of order.
    func concurrentMap<T: Sendable>(
        maximumConcurrentTasks: Int = 4,
        _ transform: @Sendable @escaping (Element) async throws -> T
    ) async throws -> [T] {
        try await withThrowingTaskGroup(of: (Int, T).self) { group in
            var iterator = enumerated().makeIterator()
            func enqueue() throws -> Bool {
                try Task.checkCancellation()
                guard let (index, element) = iterator.next() else { return false }
                group.addTask {
                    try Task.checkCancellation()
                    return (index, try await transform(element))
                }
                return true
            }
            for _ in 0..<Swift.max(1, maximumConcurrentTasks) {
                if try !enqueue() { break }
            }
            var results: [(Int, T)] = []
            while let result = try await group.next() {
                results.append(result)
                _ = try enqueue()
            }
            return results.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    func concurrentFilter(
        _ predicate: @Sendable @escaping (Element) async -> Bool
    ) async -> [Element] {
        await withTaskGroup(of: Element?.self) { group in
            for element in self {
                group.addTask {
                    await predicate(element) ? element : nil
                }
            }

            var results: [Element] = []
            for await result in group {
                if let value = result {
                    results.append(value)
                }
            }
            return results
        }
    }
}

extension Sequence where Element: Sendable {
    func asyncMap<T>(
        _ transform: @Sendable (Element) async throws -> T
    ) async rethrows -> [T] {
        var values = [T]()

        for element in self {
            try await values.append(transform(element))
        }

        return values
    }

    func asyncCompactMap<T>(
        _ transform: @Sendable (Element) async throws -> T?
    ) async rethrows -> [T] {
        var values = [T]()

        for element in self {
            let result = try await transform(element)
            if let result {
                values.append(result)
            }
        }

        return values
    }

//    func asyncForEach(
//        _ operation: (Element) async throws -> Void
//    ) async rethrows {
//        for element in self {
//            try await operation(element)
//        }
//    }

//    func concurrentForEach(
//        _ operation: @escaping (Element) async -> Void
//    ) async {
//        // A task group automatically waits for all of its
//        // sub-tasks to complete, while also performing those
//        // tasks in parallel:
//        await withTaskGroup(of: Void.self) { group in
//            for element in self {
//                group.addTask {
//                    await operation(element)
//                }
//            }
//        }
//    }
}

extension Sequence where Iterator.Element: Hashable {
    func unique() -> [Iterator.Element] {
        var seen: Set<Iterator.Element> = []
        return filter { seen.insert($0).inserted }
    }
}
