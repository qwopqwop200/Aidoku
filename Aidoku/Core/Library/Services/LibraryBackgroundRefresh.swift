import Foundation

/// Arbitrates the system expiration callback and the refresh's normal completion.
final class LibraryBackgroundRefresh: @unchecked Sendable {
    private let lock = NSLock()
    private var worker: Task<Void, Never>?
    private var completion: (@Sendable (Bool) -> Void)?

    init(completion: @escaping @Sendable (Bool) -> Void) {
        self.completion = completion
    }

    func start(_ refresh: @escaping @Sendable () async -> Bool) {
        lock.withLock {
            guard completion != nil, worker == nil else { return }
            worker = Task {
                let success = await refresh()
                finish(success: success)
            }
        }
    }

    func expire() {
        finish(success: false)
    }

    private func finish(success: Bool) {
        lock.lock()
        guard let completion else {
            lock.unlock()
            return
        }
        self.completion = nil
        let worker = self.worker
        self.worker = nil
        lock.unlock()

        if !success { worker?.cancel() }
        completion(success)
    }
}

enum LibraryAutomaticRefresh: Equatable {
    case disabled
    case start
    case schedule(Date)

    static func action(
        interval: String, lastUpdated: Date, retryAfter: Date, now: Date, canStart: Bool
    ) -> Self {
        let seconds: TimeInterval
        switch interval {
            case "12hours": seconds = 43_200
            case "daily": seconds = 86_400
            case "2days": seconds = 172_800
            case "weekly": seconds = 604_800
            default: return .disabled
        }
        let due = max(lastUpdated.addingTimeInterval(seconds), retryAfter)
        return canStart && due <= now ? .start : .schedule(max(due, now))
    }
}
