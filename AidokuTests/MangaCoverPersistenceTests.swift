import AidokuRunner
import CoreData
import Foundation
import Testing
import UIKit
@testable import Aidoku

@MainActor
struct MangaCoverPersistenceTests {
    @Test func unencodableCoverDoesNotReplacePersistedCover() async throws {
        let id = MangaIdentifier(sourceKey: "cover-persistence-fixture", mangaKey: UUID().uuidString)
        let context = CoreDataManager.shared.context
        let manga = MangaObject(context: context)
        manga.sourceId = id.sourceKey
        manga.id = id.mangaKey
        manga.title = "Cover fixture"
        manga.cover = "https://example.invalid/original.png"
        try context.save()
        defer {
            context.delete(manga)
            try? context.save()
        }

        let result = await MangaManager.shared.setCover(
            manga: AidokuRunner.Manga(sourceKey: id.sourceKey, key: id.mangaKey, title: manga.title),
            cover: UIImage()
        )
        context.refresh(manga, mergeChanges: false)
        #expect(result == nil)
        #expect(manga.cover == "https://example.invalid/original.png")
        #expect(!EditedKeys(rawValue: manga.editedKeys).contains(.cover))
    }
}
