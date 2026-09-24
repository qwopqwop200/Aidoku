import AidokuRunner
import CoreData
import Foundation
import Testing
@testable import Aidoku

@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["AIDOKU_ROUND2_CATEGORY_REFERENCES"] == "1"))
struct Round2AddToCategorySaveTests {
    private final class Counts: @unchecked Sendable {
        private let lock = NSLock()
        private var injected = 0
        private var notified = 0
        func inject() { lock.lock(); injected += 1; lock.unlock() }
        func notify() { lock.lock(); notified += 1; lock.unlock() }
        var result: (Int, Int) { lock.lock(); defer { lock.unlock() }; return (injected, notified) }
    }

    @Test func failedBatchIsAtomicAndRetryPublishesExactlyOnce() async throws {
        let source = "round2-category-save-" + UUID().uuidString
        let category = source + "-category"
        let manga = ["a", "b"].map { AidokuRunner.Manga(sourceKey: source, key: $0, title: $0) }
        let infos = manga.map { MangaInfo(id: $0.identifier, title: $0.title) }
        let manager = CoreDataManager.shared
        try await manager.container.performBackgroundTask { context in
            let isolatedCategory = CategoryObject(context: context)
            isolatedCategory.title = category
            isolatedCategory.sort = 0
            isolatedCategory.group = false
            for entry in manga { manager.addToLibrary(manga: entry, chapters: [], context: context) }
            try context.save()
        }
        let counts = Counts(), center = NotificationCenter.default
        let token = center.addObserver(forName: .NSManagedObjectContextWillSave, object: nil, queue: nil) { note in
            guard let context = note.object as? NSManagedObjectContext,
                  context.updatedObjects.contains(where: {
                      ($0 as? LibraryMangaObject)?.manga?.sourceId == source
                  }) else { return }
            let invalid = CategoryObject(context: context)
            invalid.title = nil
            counts.inject()
        }
        let notification = center.addObserver(forName: .updateMangaCategories, object: nil, queue: nil) { note in
            if let values = note.object as? [MangaInfo], values.contains(where: { $0.id.sourceKey == source }) { counts.notify() }
        }
        let controller = AddToCategoryViewController(manga: infos)
        controller.selectedCategories = [category]
        let failed = await controller.saveSelectedCategories()
        center.removeObserver(token)
        let failedMembership = await manager.container.performBackgroundTask { context in
            manga.map { manager.getCategories(mangaId: $0.identifier, context: context).compactMap(\.title) }
        }
        #expect(!failed)
        #expect(counts.result.0 == 1)
        #expect(counts.result.1 == 0)
        #expect(failedMembership == [[], []])
        let succeeded = await controller.saveSelectedCategories()
        center.removeObserver(notification)
        let finalMembership = await manager.container.performBackgroundTask { context in
            manga.map { manager.getCategories(mangaId: $0.identifier, context: context).compactMap(\.title) }
        }
        // Cleanup only private UUID fixture after capturing persisted results.
        try await manager.container.performBackgroundTask { context in
            for entry in manga { manager.removeManga(mangaId: entry.identifier, context: context) }
            if let isolatedCategory = manager.getCategory(title: category, context: context) { context.delete(isolatedCategory) }
            try context.save()
        }
        #expect(succeeded)
        #expect(counts.result.1 == 1)
        #expect(finalMembership == [[category], [category]])
    }
}
