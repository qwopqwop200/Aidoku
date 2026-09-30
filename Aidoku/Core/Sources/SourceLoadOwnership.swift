/// Actor-owned tickets prevent suspended source loads from publishing obsolete state.
struct SourceLoadOwnership: Sendable {
    struct SourceTicket: Sendable, Equatable {
        fileprivate let sourceKey: String
        fileprivate let revision: UInt64
        fileprivate let resetRevision: UInt64
    }

    struct SnapshotTicket: Sendable, Equatable {
        fileprivate let revision: UInt64
        fileprivate let request: UInt64
    }

    private var revision: UInt64 = 0
    private var resetRevision: UInt64 = 0
    private var snapshotRequest: UInt64 = 0
    private var sourceRevisions: [String: UInt64] = [:]

    mutating func invalidate(sourceKey: String) {
        revision &+= 1
        sourceRevisions[sourceKey] = revision
    }

    mutating func invalidateAll() {
        revision &+= 1
        resetRevision = revision
        sourceRevisions = [:]
    }

    func capture(sourceKey: String) -> SourceTicket {
        .init(sourceKey: sourceKey, revision: sourceRevisions[sourceKey] ?? 0, resetRevision: resetRevision)
    }

    func isCurrent(_ ticket: SourceTicket, sourceKey: String) -> Bool {
        ticket.sourceKey == sourceKey
            && ticket.resetRevision == resetRevision
            && ticket.revision == (sourceRevisions[sourceKey] ?? 0)
    }

    mutating func beginSnapshot() -> SnapshotTicket {
        snapshotRequest &+= 1
        return .init(revision: revision, request: snapshotRequest)
    }

    func isCurrent(_ ticket: SnapshotTicket) -> Bool {
        ticket.request == snapshotRequest && ticket.revision == revision
    }

    /// Retry a changed snapshot, but never restart a request superseded by another reload.
    func refreshedSnapshot(_ ticket: SnapshotTicket) -> SnapshotTicket? {
        guard ticket.request == snapshotRequest else { return nil }
        return .init(revision: revision, request: snapshotRequest)
    }
}
