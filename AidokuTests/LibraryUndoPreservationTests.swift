import AidokuRunner
import CoreData
import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized)
@MainActor
struct LibraryUndoPreservationTests {
    @Test func categorySelectionCancelUndoAndRedoAfterSwitchRestoreOnlySelectedRelationships() async throws {
        let store = CoreDataManager.shared
        let token = UUID().uuidString
        let category = "category-A-" + token, otherCategory = "category-B-" + token
        let selected = MangaIdentifier(sourceKey: token, mangaKey: "shared")
        let sameKey = MangaIdentifier(sourceKey: token + "-other", mangaKey: "shared")
        let context = store.container.newBackgroundContext()
        let endpoints = try await context.perform {
            let first = try store.createCategory(title: category, context: context)
            let duplicate = try store.createCategory(title: category, context: context)
            let other = try store.createCategory(title: otherCategory, context: context)
            func row(_ id: MangaIdentifier, _ categories: [CategoryObject]) -> LibraryMangaObject {
                let library = LibraryMangaObject(context: context)
                library.manga = store.createManga(.init(sourceKey: id.sourceKey, key: id.mangaKey, title: token), context: context)
                for category in categories { library.addToCategories(category) }
                return library
            }
            let rows = [row(selected, [first, other]), row(selected, [duplicate]), row(selected, [other]), row(sameKey, [first, other])]
            try context.save()
            return (rows.map(\.objectID), [first, duplicate, other].map(\.objectID), rows.compactMap { $0.manga?.objectID })
        }
        defer {
            context.performAndWait {
                for id in endpoints.0 + endpoints.1 + endpoints.2 {
                    if let object = try? context.existingObject(with: id) { context.delete(object) }
                }
                try? context.save()
            }
        }
        func memberships() throws -> [Set<NSManagedObjectID>] {
            try context.performAndWait {
                context.reset()
                return try endpoints.0.map {
                    let row = try #require(context.existingObject(with: $0) as? LibraryMangaObject)
                    return Set((row.categories?.allObjects as? [CategoryObject] ?? []).map(\.objectID))
                }
            }
        }

        let original = try memberships()
        let limited: [Set<NSManagedObjectID>] = [[endpoints.1[2]], [], [endpoints.1[2]], original[3]]
        let controller = LibraryViewController()
        let oldCategory = AppSettings.library.currentCategory.get()
        defer { AppSettings.library.currentCategory.set(oldCategory) }
        let input = [MangaInfo(id: selected), MangaInfo(id: selected)]
        let cancelled = controller.removeFromCategory(mangaInfo: input, category: category)
        cancelled.cancel()
        await cancelled.value
        #expect(try memberships() == original)
        #expect(!controller.undoManager.canUndo)

        controller.undoManager.groupsByEvent = false
        controller.undoManager.beginUndoGrouping()
        await controller.removeFromCategory(mangaInfo: input, category: category).value
        controller.undoManager.endUndoGrouping()
        #expect(try memberships() == limited)
        controller.viewModel.currentCategory = otherCategory
        controller.undoManager.undo()
        #expect(try memberships() == original)
        controller.undoManager.redo()
        #expect(try memberships() == limited)
    }

    @Test func undoRestoresTrackerOffsetAndLibraryDates() async throws {
        // Unique records in the isolated simulator test host, removed after the check.
        let mangaId = MangaIdentifier(sourceKey: "audit-undo", mangaKey: UUID().uuidString)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let manga = Aidoku.Manga(sourceId: mangaId.sourceKey, id: mangaId.mangaKey, title: "Undo fixture",
            lastOpened: date, lastUpdated: date, lastUpdatedChapters: date,
            lastRead: date, dateAdded: date)
        defer {
            let context = CoreDataManager.shared.context
            CoreDataManager.shared.removeTracks(mangaId: mangaId, context: context)
            CoreDataManager.shared.removeManga(mangaId: mangaId, context: context)
            try? context.save()
        }
        let track = TrackItem(id: "fixture-track", trackerId: "fixture-tracker", mangaId: mangaId,
            title: "Original track", chapterOffset: -7)
        await MangaManager.shared.restoreToLibrary(manga: manga, chapters: [], trackItems: [track], categories: [])
        let restored = await CoreDataManager.shared.container.performBackgroundTask { context in
            let tracker = CoreDataManager.shared.getTrack(trackerId: "fixture-tracker", mangaId: mangaId, context: context)
            let library = CoreDataManager.shared.getLibraryManga(mangaId: mangaId, context: context)
            return (tracker?.chapterOffset, tracker?.title, library?.dateAdded, library?.lastOpened)
        }
        #expect(restored.0 == -7)
        #expect(restored.1 == "Original track")
        #expect(restored.2 == date)
        #expect(restored.3 == date)
    }
}
