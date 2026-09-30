import Foundation

/// Revokes queued partial callbacks before a newer load or the final result is applied.
@MainActor
final class MangaDataLoadOwnership {
    private var requestID: UUID?
    private var acceptsPartialResults = false

    func begin() -> UUID {
        let id = UUID()
        requestID = id
        acceptsPartialResults = true
        return id
    }

    func isCurrent(_ id: UUID) -> Bool { requestID == id }

    @discardableResult
    func performPartial(expectedID: UUID, _ effect: () -> Void) -> Bool {
        guard isCurrent(expectedID), acceptsPartialResults else { return false }
        effect()
        return true
    }

    func closePartialResults(expectedID: UUID) {
        guard isCurrent(expectedID) else { return }
        acceptsPartialResults = false
    }

    func finish(expectedID: UUID) {
        guard isCurrent(expectedID) else { return }
        invalidate()
    }

    func invalidate() {
        requestID = nil
        acceptsPartialResults = false
    }
}
