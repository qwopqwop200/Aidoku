import AidokuRunner
import CoreData
import Foundation
import Testing
@testable import Aidoku

private var round2LibrarySaveFailureEnabled: Bool {
    #if targetEnvironment(simulator)
    let marker = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Round2Data/enabled")
    return (try? String(contentsOf: marker, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)) == "dedicated-audit-simulator"
    #else
    return false
    #endif
}

@MainActor
@Suite(.serialized, .enabled(if: round2LibrarySaveFailureEnabled))
struct Round2LibrarySaveFailureTests {
    private func requireDedicatedSimulator() throws {
        #if targetEnvironment(simulator)
        let marker = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Round2Data/enabled")
        let value = try String(contentsOf: marker, encoding: .utf8)
        try #require(value.trimmingCharacters(in: .whitespacesAndNewlines) == "dedicated-audit-simulator")
        #else
        throw NSError(domain: "Round2DedicatedSimulatorOnly", code: 1)
        #endif
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var injected = 0
        private var notifications = 0
        func didInject() { lock.lock(); injected += 1; lock.unlock() }
        func didNotify() { lock.lock(); notifications += 1; lock.unlock() }
        var counts: (Int, Int) { lock.lock(); defer { lock.unlock() }; return (injected, notifications) }
    }

    private func run(remove: Bool, batch: Bool) async throws {
        try requireDedicatedSimulator()
        let key = "round2-data-save-failure-" + UUID().uuidString
        let manga = AidokuRunner.Manga(sourceKey: key, key: "m", title: "Persistence fixture")
        let chapter = AidokuRunner.Chapter(key: "c")
        if remove {
            try await CoreDataManager.shared.container.performBackgroundTask { context in
                CoreDataManager.shared.addToLibrary(manga: manga, chapters: [chapter], context: context)
                try context.save()
            }
        }
        let state = State()
        let center = NotificationCenter.default
        let saveToken = center.addObserver(forName: .NSManagedObjectContextWillSave, object: nil, queue: nil) { note in
            guard let context = note.object as? NSManagedObjectContext else { return }
            let affected = context.insertedObjects.union(context.deletedObjects)
            guard affected.contains(where: { ($0 as? MangaObject)?.sourceId == key }) else { return }
            // This invalid object exists only in this operation's context. It forces the real
            // SQLite save path to fail validation; no filesystem permissions or live data altered.
            let invalid = CategoryObject(context: context)
            invalid.setValue(nil, forKey: "title")
            state.didInject()
        }
        let notificationToken = center.addObserver(forName: remove ? .removeFromLibrary : .addToLibrary,
            object: nil, queue: nil) { note in
            if (note.object as? MangaIdentifier) == manga.identifier { state.didNotify() }
        }
        if remove {
            if batch { await MangaManager.shared.removeFromLibrary(mangaIds: [manga.identifier]) }
            else { await MangaManager.shared.removeFromLibrary(mangaId: manga.identifier) }
        } else {
            await MangaManager.shared.addToLibrary(manga: manga, chapters: [chapter])
        }
        center.removeObserver(saveToken)
        center.removeObserver(notificationToken)
        let persisted = await CoreDataManager.shared.container.performBackgroundTask { context in
            CoreDataManager.shared.hasLibraryManga(mangaId: manga.identifier, context: context)
        }
        // Clean only this UUID fixture after removing injection. Assertions do not prevent cleanup.
        if remove {
            try await CoreDataManager.shared.container.performBackgroundTask { context in
                CoreDataManager.shared.removeFromLibrary(ids: [manga.identifier], context: context)
                try context.save()
            }
        }
        #expect(state.counts.0 == 1)
        #expect(state.counts.1 == 0)
        #expect(persisted == remove)
    }

    @Test func failedAddDoesNotPublishSuccess() async throws { try await run(remove: false, batch: false) }
    @Test func failedSingleRemovalPreservesLibraryWithoutSuccess() async throws { try await run(remove: true, batch: false) }
    @Test func failedBatchRemovalPreservesLibraryWithoutSuccess() async throws { try await run(remove: true, batch: true) }
}
