import AidokuRunner
import CoreData
import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized) @MainActor
struct MangaMigrationIdentityTests {
    @Test(arguments: [false, true], [false, true])
    func sameDestinationPreservesLibraryHistoryDownloadsAndSettings(copy: Bool, forceRemove: Bool) async throws {
        let id = MangaIdentifier(sourceKey: "migration-identity-fixture", mangaKey: UUID().uuidString)
        let key = "Reader.readingMode.\(id)"
        let context = CoreDataManager.shared.context
        let manga = MangaObject(context: context)
        manga.sourceId = id.sourceKey
        manga.id = id.mangaKey
        manga.title = "Original"
        let library = LibraryMangaObject(context: context)
        library.manga = manga
        let chapter = ChapterObject(context: context)
        chapter.sourceId = id.sourceKey
        chapter.mangaId = id.mangaKey
        chapter.id = "chapter"
        chapter.manga = manga
        let file = LocalFileInfoObject(context: context)
        file.path = "migration-fixture.cbz"
        chapter.fileInfo = file
        let history = HistoryObject(context: context)
        history.sourceId = id.sourceKey
        history.mangaId = id.mangaKey
        history.chapterId = chapter.id
        history.progress = 7
        history.total = 20
        history.scrollPosition = 0.375
        chapter.history = history
        try context.save()
        UserDefaults.standard.set("rtl", forKey: key)
        defer {
            UserDefaults.standard.removeObject(forKey: key)
            for object in [manga, library, chapter, file, history] as [NSManagedObject] where !object.isDeleted {
                context.delete(object)
            }
            try? context.save()
        }

        let original = AidokuRunner.Manga(sourceKey: id.sourceKey, key: id.mangaKey, title: "Original")
        let replacement = AidokuRunner.Manga(sourceKey: id.sourceKey, key: id.mangaKey, title: "Replacement")
        let result = await MangaManager.migrate(copy: copy, forceRemoveFromLibrary: forceRemove,
            from: original, to: replacement, withChapters: [])
        context.refreshAllObjects()

        #expect(result == nil)
        let stored = try #require(CoreDataManager.shared.getManga(mangaId: id, context: context))
        #expect(stored.title == "Original")
        #expect(stored.libraryObject != nil)
        let chapters = CoreDataManager.shared.getChapters(mangaId: id, context: context)
        let retained = try #require(chapters.first)
        #expect(chapters.count == 1)
        #expect(retained.fileInfo?.path == "migration-fixture.cbz")
        #expect(retained.history?.progress == 7)
        #expect(retained.history?.scrollPosition?.doubleValue == 0.375)
        #expect(UserDefaults.standard.string(forKey: key) == "rtl")
    }
}
