//
//  SinglePublisher.swift
//  AidokuRunner
//
//  Created by Skitty on 5/28/25.
//

import Foundation

/// Carries the subscriber owner through an async source invocation, including
/// actor queueing before the invocation begins. Callback closures capture it.
public enum PartialResultSubscription {
    @TaskLocal public static var id: UUID?
}

public actor SinglePublisher<T: Sendable> {
    private var sink: ((T) -> Void)?
    public private(set) var subscriptionID: UUID?

    public func send(_ value: T) { sink?(value) }

    /// A result from an obsolete invocation cannot enter a replacement sink.
    public func send(_ value: T, to token: UUID?) {
        guard let token, token == subscriptionID else { return }
        sink?(value)
    }

    @discardableResult
    public func sink(to closure: @escaping (T) -> Void) -> UUID {
        let token = UUID()
        subscriptionID = token
        sink = closure
        return token
    }

    public func removeSink(token: UUID) {
        guard subscriptionID == token else { return }
        removeSink()
    }

    public func removeSink() {
        sink = nil
        subscriptionID = nil
    }
}
