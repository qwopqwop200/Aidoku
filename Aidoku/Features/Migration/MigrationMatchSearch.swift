import AidokuRunner
import Foundation

/// Sequential source fallback preserves first-match order and silent ordinary
/// failures, but cancelled read-only matching must not visit further sources.
enum MigrationMatchSearch {
    static func firstMatch(for manga: AidokuRunner.Manga, sources: [AidokuRunner.Source], isNeeded: @escaping @Sendable () -> Bool = { true }) async -> AidokuRunner.Manga? {
        for source in sources {
            guard !Task.isCancelled, isNeeded() else { return nil }
            do {
                let result = try await source.getSearchMangaList(query: manga.title, page: 1, filters: [])
                guard !Task.isCancelled, isNeeded() else { return nil }
                if let match = result.entries.first { return match }
            } catch is CancellationError {
                return nil
            } catch {
                // Unavailable sources remain a silent fallback, as before.
                guard !Task.isCancelled, isNeeded() else { return nil }
            }
        }
        return nil
    }
}

/// A row can revoke read-only matching without cancelling another row or
/// releasing an in-flight source slot before its callback actually finishes.
final class MigrationRowDemand: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }
    func revoke() { lock.lock(); active = false; lock.unlock() }
}
