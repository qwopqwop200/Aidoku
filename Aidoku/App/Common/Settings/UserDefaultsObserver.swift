//
//  UserDefaultsObserver.swift
//  Aidoku
//
//  Created by Skitty on 5/5/25.
//

import Combine
import SwiftUI

@MainActor
class UserDefaultsObserver: ObservableObject {
    @Published var observedValues: [String: Any?] = [:]

    private var cancellable: AnyCancellable?

    init(keys: [String], defaults: UserDefaults = .standard, notificationCenter: NotificationCenter = .default) {
        var observedValues: [String: Any?] = [:]
        for key in keys {
            let value = defaults.object(forKey: key)
            observedValues[key] = value
        }
        self.observedValues = observedValues

        cancellable = notificationCenter.publisher(for: UserDefaults.didChangeNotification)
            .throttle(for: .milliseconds(16), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                guard let self else { return }
                var updated = self.observedValues
                var changed = false
                for key in keys where !key.isEmpty {
                    let newValue = defaults.object(forKey: key)
                    if !Self.isEqual(updated[key, default: nil], newValue) {
                        updated[key] = newValue
                        changed = true
                    }
                }
                if changed { self.observedValues = updated }
            }
    }

    convenience init(key: String) {
        self.init(keys: [key])
    }

    private static func isEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        if let lhs = lhs as? NSObject, let rhs = rhs as? NSObject {
            return lhs == rhs
        } else {
            return lhs == nil && rhs == nil
        }
    }
}

class UserDefaultsBool: ObservableObject {
    @Published var value: Bool {
        didSet {
            if !isReconciling, oldValue != value { defaults.set(value, forKey: key) }
        }
    }

    private let key: String
    private let defaults: UserDefaults
    private var isReconciling = false
    private var cancellable: AnyCancellable?

    init(
        key: String, defaultValue: Bool = false,
        defaults: UserDefaults = .standard, notificationCenter: NotificationCenter = .default
    ) {
        self.defaults = defaults
        self.key = key
        self.value = defaults.object(forKey: key) == nil ? defaultValue : defaults.bool(forKey: key)

        cancellable = notificationCenter.publisher(for: UserDefaults.didChangeNotification)
            .throttle(for: .milliseconds(16), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                guard let self else { return }
                let newValue = defaults.object(forKey: self.key) == nil ? defaultValue : defaults.bool(forKey: self.key)
                if self.value != newValue {
                    self.isReconciling = true
                    self.value = newValue
                    self.isReconciling = false
                }
            }
    }
}

/// One active refresh plus one latest replacement. Cancelled work drains before replacement starts.
@MainActor
final class SettingsRefreshScheduler {
    private var task: Task<Void, Never>?
    private var pending: (@MainActor () async -> Void)?
    private var generation = UUID()

    func request<Value>(
        operation: @escaping @MainActor () async -> Value,
        commit: @escaping @MainActor (Value) -> Void
    ) {
        let current = UUID()
        generation = current
        pending = { [weak self] in
            let value = await operation()
            guard !Task.isCancelled, self?.generation == current else { return }
            commit(value)
        }
        task?.cancel()
        startPending()
    }

    func cancel() {
        generation = UUID()
        pending = nil
        task?.cancel()
    }

    private func startPending() {
        guard task == nil, let operation = pending else { return }
        pending = nil
        task = Task { [weak self] in
            await operation()
            self?.task = nil
            self?.startPending()
        }
    }

    deinit { task?.cancel() }
}
