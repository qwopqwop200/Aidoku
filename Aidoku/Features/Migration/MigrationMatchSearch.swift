import AidokuRunner
import Foundation

/// Sequential first-match search that stops visiting sources once cancelled.
enum MigrationMatchSearch {
    static func firstMatch(for manga: AidokuRunner.Manga, sources: [AidokuRunner.Source], isNeeded: @escaping @Sendable () -> Bool) async -> AidokuRunner.Manga? {
        for source in sources {
            guard !Task.isCancelled, isNeeded() else { return nil }
            do {
                let result = try await source.getSearchMangaList(query: manga.title, page: 1, filters: [])
                guard !Task.isCancelled, isNeeded() else { return nil }
                if let match = result.entries.first { return match }
            } catch is CancellationError {
                return nil
            } catch {
                // Skip unavailable sources; the loop rechecks cancellation.
            }
        }
        return nil
    }
}

/// Lets one row revoke its matching without cancelling other rows.
final class MigrationRowDemand: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }
    func revoke() { lock.lock(); active = false; lock.unlock() }
}
