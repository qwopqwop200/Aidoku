import Foundation

/// Checks the challenge generation on MainActor, where stale queued UI effects would run.
@MainActor
final class CloudflareBrowserOwnership {
    private var challengeID: UUID?
    private var popupReserved = false

    func begin(_ id: UUID) -> Bool {
        guard challengeID == nil else { return false }
        challengeID = id
        popupReserved = false
        return true
    }

    func isCurrent(_ id: UUID?) -> Bool {
        id != nil && challengeID == id
    }

    @discardableResult
    func perform(expectedID: UUID?, _ effect: () -> Void) -> Bool {
        guard isCurrent(expectedID) else { return false }
        effect()
        return true
    }

    func reservePopup(expectedID: UUID?) -> Bool {
        guard isCurrent(expectedID), !popupReserved else { return false }
        popupReserved = true
        return true
    }

    func end(expectedID: UUID?, _ cleanup: () -> Void) {
        guard isCurrent(expectedID) else { return }
        challengeID = nil
        popupReserved = false
        cleanup()
    }
}
