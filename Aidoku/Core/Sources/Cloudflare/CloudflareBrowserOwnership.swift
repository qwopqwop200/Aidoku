import Foundation

/// Guards generation-bound browser effects on the same executor that performs them.
/// An actor check before hopping to MainActor cannot prevent a stale queued UI effect.
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

    @discardableResult
    func end(expectedID: UUID?, _ cleanup: () -> Void) -> Bool {
        guard isCurrent(expectedID) else { return false }
        challengeID = nil
        popupReserved = false
        cleanup()
        return true
    }
}
