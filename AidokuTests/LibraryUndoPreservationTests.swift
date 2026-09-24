import CoreData
import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized)
@MainActor
struct LibraryUndoPreservationTests {
    @Test func undoRestoresTrackerOffsetAndLibraryDates() async throws {
        // Unique records in the isolated simulator test host, removed after the check.
        let mangaId = MangaIdentifier(sourceKey: "audit-undo", mangaKey: UUID().uuidString)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let manga = Manga(sourceId: mangaId.sourceKey, id: mangaId.mangaKey, title: "Undo fixture",
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
