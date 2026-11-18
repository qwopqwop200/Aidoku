import Foundation

/// Retain evidence for the complete admitted OCR -> provider -> render
/// transaction. Cache capacity applies to evictable entries, not active work.
/// No source pixels, paths, page labels, model invocation or cache-size bump.
final class NativeMainEnsembleEvidenceLease: @unchecked Sendable {
    private let lock = NSLock()
    private var releaseAction: (@Sendable () -> Void)?

    init(release: @escaping @Sendable () -> Void) {
        releaseAction = release
    }

    /// Explicit defer is recommended at transaction boundaries. Deinit is a
    /// fallback for thrown errors/cancellation, not a replacement for the defer.
    func release() {
        lock.lock()
        let action = releaseAction
        releaseAction = nil
        lock.unlock()
        // Never execute the store callback with this lease's lock held.
        action?()
    }

    deinit { release() }

    /// Caller MUST hold the evidence store's existing lock for every operation.
    /// Tokens are unique per transaction, even for identical source content.
    struct Registry {
        struct Token: Sendable {
            fileprivate let id: UUID
            fileprivate let identity: String
        }
        enum Failure: Error { case emptyIdentity }
        private var tokens: [UUID: String] = [:]
        private var counts: [String: Int] = [:]

        mutating func acquire(identity: String) throws -> Token {
            guard !identity.isEmpty else { throw Failure.emptyIdentity }
            let token = Token(id: UUID(), identity: identity)
            tokens[token.id] = identity
            counts[identity, default: 0] += 1
            return token
        }

        /// A duplicate release cannot release another transaction's pin.
        @discardableResult
        mutating func release(_ token: Token) -> Bool {
            guard tokens[token.id] == token.identity else { return false }
            tokens.removeValue(forKey: token.id)
            if counts[token.identity] == 1 { counts.removeValue(forKey: token.identity) }
            else if let count = counts[token.identity] { counts[token.identity] = count - 1 }
            return true
        }

        func isPinned(_ identity: String) -> Bool { counts[identity] != nil }

        /// Use inside `while order.count > existingCapacity`. If every entry
        /// belongs to active work, defer eviction until a lease is released.
        func evictionIndex(in order: [String]) -> Int? {
            order.firstIndex { !isPinned($0) }
        }
    }
}
