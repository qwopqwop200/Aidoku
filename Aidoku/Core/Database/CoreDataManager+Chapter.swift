//
//  CoreDataManager+Chapter.swift
//  Aidoku (iOS)
//
//  Created by Skitty on 8/13/22.
//

import CoreData
import AidokuRunner

extension CoreDataManager {
    /// Remove all chapter objects.
    func clearChapters(context: NSManagedObjectContext) {
        clear(request: ChapterObject.fetchRequest(), context: context)
    }

    /// Gets all chapter objects.
    func getChapters(context: NSManagedObjectContext) -> [ChapterObject] {
        (try? context.fetch(ChapterObject.fetchRequest())) ?? []
    }

    /// Gets all chapter objects for a source.
    func getChapters(sourceKey: String, context: NSManagedObjectContext) -> [ChapterObject] {
        let request = ChapterObject.fetchRequest()
        request.predicate = NSPredicate(format: "sourceId == %@", sourceKey)
        return (try? context.fetch(request)) ?? []
    }

    /// Get a particular chapter object.
    func getChapter(chapterId: ChapterIdentifier, context: NSManagedObjectContext) -> ChapterObject? {
        let request = ChapterObject.fetchRequest()
        request.predicate = NSPredicate(
            format: "id == %@ AND mangaId == %@ AND sourceId == %@ ",
            chapterId.chapterKey, chapterId.mangaKey, chapterId.sourceKey
        )
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    /// Get the chapter objects for a manga.
    func getChapters(mangaId: MangaIdentifier, context: NSManagedObjectContext) -> [ChapterObject] {
        let request = ChapterObject.fetchRequest()
        request.predicate = NSPredicate(
            format: "mangaId == %@ AND sourceId == %@",
            mangaId.mangaKey, mangaId.sourceKey
        )
        request.sortDescriptors = [NSSortDescriptor(key: "sourceOrder", ascending: true)]
        return (try? context.fetch(request)) ?? []
    }

    func getChapters(mangaId: MangaIdentifier) async -> [Chapter] {
        await container.performBackgroundTask { context in
            let objects = self.getChapters(mangaId: mangaId, context: context)
            return objects.map { $0.toChapter() }
        }
    }

    /// Create a chapter object.
    @discardableResult
    func createChapter(
        _ chapter: AidokuRunner.Chapter,
        mangaId: MangaIdentifier,
        sourceOrder: Int,
        mangaObject: MangaObject? = nil,
        context: NSManagedObjectContext
    ) -> ChapterObject? {
        guard let mangaObject = mangaObject ?? getManga(
            mangaId: mangaId,
            context: context
        ) else {
            return nil
        }
        let object = ChapterObject(context: context)
        object.load(
            from: chapter,
            mangaId: mangaId,
            sourceOrder: sourceOrder
        )
        object.manga = mangaObject
        object.history = getHistory(
            chapterId: .init(
                sourceKey: mangaId.sourceKey,
                mangaKey: mangaId.mangaKey,
                chapterKey: chapter.id
            ),
            context: context
        )
        return object
    }

    /// Check if a chapter exists in the data store.
    func hasChapter(chapterId: ChapterIdentifier, context: NSManagedObjectContext) -> Bool {
        let request = ChapterObject.fetchRequest()
        request.predicate = NSPredicate(
            format: "id == %@ AND mangaId == %@ AND sourceId == %@ ",
            chapterId.chapterKey, chapterId.mangaKey, chapterId.sourceKey
        )
        request.fetchLimit = 1
        return (try? context.count(for: request)) ?? 0 > 0
    }

    /// Removes chapters for manga.
    func removeChapters(mangaId: MangaIdentifier, context: NSManagedObjectContext) {
        let chapters = getChapters(mangaId: mangaId, context: context)
        for chapter in chapters where chapter.fileInfo == nil {
            context.delete(chapter)
        }
    }

    /// Set a list of chapters for a manga.
    /// - Returns: New created chapters
    @discardableResult
    func setChapters(
        _ chapters: [AidokuRunner.Chapter],
        mangaId: MangaIdentifier,
        context: NSManagedObjectContext
    ) -> [ChapterObject] {
        guard let manga = getManga(mangaId: mangaId, context: context) else { return [] }

        let incoming = Dictionary(chapters.indices.lazy.map { (chapters[$0].key, $0) }, uniquingKeysWith: { first, _ in first })
        var existing: [String: ChapterObject] = [:]
        var newChaptersCreated: [ChapterObject] = []
        for object in getChapters(mangaId: mangaId, context: context) {
            if let keeper = existing[object.id] {
                if keeper.fileInfo == nil { keeper.fileInfo = object.fileInfo }
                if keeper.history == nil { keeper.history = object.history }
                if keeper.mangaUpdate == nil { keeper.mangaUpdate = object.mangaUpdate }
                context.delete(object)
                continue
            }
            existing[object.id] = object
            guard let offset = incoming[object.id] else { continue }
            let chapter = chapters[offset]
            let becameUnlocked = object.locked && !chapter.locked
            object.load(from: chapter, mangaId: mangaId, sourceOrder: offset)
            if object.manga !== manga { object.manga = manga }
            if becameUnlocked { newChaptersCreated.append(object) }
        }
        // Duplicates were merged above, so a kept row may now own the download.
        for (key, object) in existing where incoming[key] == nil && object.fileInfo == nil {
            context.delete(object)
        }
        let missing = chapters.indices.filter { offset in
            let key = chapters[offset].key
            return existing[key] == nil && incoming[key] == offset
        }
        for start in stride(from: 0, to: missing.count, by: 500) {
            let batch = missing[start..<min(start + 500, missing.count)]
            let request = HistoryObject.fetchRequest()
            request.predicate = NSPredicate(
                format: "sourceId == %@ AND mangaId == %@ AND chapterId IN %@",
                mangaId.sourceKey, mangaId.mangaKey, batch.map { chapters[$0].key }
            )
            request.returnsObjectsAsFaults = false
            let histories = (try? context.fetch(request)).map { Dictionary(grouping: $0, by: \.chapterId) }
            for offset in batch {
                let chapter = chapters[offset]
                let object = ChapterObject(context: context)
                object.load(from: chapter, mangaId: mangaId, sourceOrder: offset)
                object.manga = manga
                let matches = histories?[chapter.key]
                if histories == nil || (matches?.count ?? 0) > 1 {
                    // Keep the existing single-row choice for legacy duplicate history.
                    object.history = getHistory(chapterId: object.identifier, context: context)
                } else if let history = matches?.first {
                    object.history = history
                }
                newChaptersCreated.append(object)
            }
        }
        return newChaptersCreated
    }

    /// Get the number of unread chapters for a manga.
    func unreadCount(
        mangaId: MangaIdentifier,
        lang: String?,
        scanlators: [String]?,
        context: NSManagedObjectContext
    ) -> Int {
        let scanlators: [String]? = if scanlators?.isEmpty ?? true {
            nil
        } else {
            scanlators
        }
        let request = ChapterObject.fetchRequest()
        if let scanlators, let lang {
            request.predicate = NSPredicate(
                format: """
                sourceId == %@
                AND mangaId == %@
                AND lang == %@
                AND ((scanlator IN %@) OR (scanlator == nil AND %@ CONTAINS ''))
                AND (history == nil OR history.completed == false)
                AND locked == false
                """,
                mangaId.sourceKey, mangaId.mangaKey, lang, scanlators, scanlators
            )
        } else if let scanlators {
            request.predicate = NSPredicate(
                format: """
                sourceId == %@
                AND mangaId == %@
                AND ((scanlator IN %@) OR (scanlator == nil AND %@ CONTAINS ''))
                AND (history == nil OR history.completed == false)
                AND locked == false
                """,
                mangaId.sourceKey, mangaId.mangaKey, scanlators, scanlators
            )
        } else if let lang {
            request.predicate = NSPredicate(
                format: """
                sourceId == %@
                AND mangaId == %@
                AND lang == %@
                AND (history == nil OR history.completed == false)
                AND locked == false
                """,
                mangaId.sourceKey, mangaId.mangaKey, lang
            )
        } else {
            request.predicate = NSPredicate(
                format: """
                sourceId == %@
                AND mangaId == %@
                AND (history == nil OR history.completed == false)
                AND locked == false
                """,
                mangaId.sourceKey, mangaId.mangaKey
            )
        }
        return (try? context.count(for: request)) ?? 0
    }

    /// Get the number of read chapters for a manga.
    func readCount(
        mangaId: MangaIdentifier,
        lang: String?,
        scanlators: [String]?,
        context: NSManagedObjectContext
    ) -> Int {
        // An empty saved filter means "all scanlators", matching unreadCount.
        let scanlators = scanlators?.isEmpty == false ? scanlators : nil
        let request = ChapterObject.fetchRequest()
        if let scanlators, let lang {
            request.predicate = NSPredicate(
                format: """
                sourceId == %@
                AND mangaId == %@
                AND lang == %@
                AND ((scanlator IN %@) OR (scanlator == nil AND %@ CONTAINS ''))
                AND history.completed == true
                """,
                mangaId.sourceKey, mangaId.mangaKey, lang, scanlators, scanlators
            )
        } else if let scanlators {
            request.predicate = NSPredicate(
                format: """
                sourceId == %@
                AND mangaId == %@
                AND ((scanlator IN %@) OR (scanlator == nil AND %@ CONTAINS ''))
                AND history.completed == true
                """,
                mangaId.sourceKey, mangaId.mangaKey, scanlators, scanlators
            )
        } else if let lang {
            request.predicate = NSPredicate(
                format: "sourceId == %@ AND mangaId == %@ AND history != nil AND lang == %@ AND history.completed == true",
                mangaId.sourceKey, mangaId.mangaKey, lang
            )
        } else {
            request.predicate = NSPredicate(
                format: "sourceId == %@ AND mangaId == %@ AND history != nil AND history.completed == true",
                mangaId.sourceKey, mangaId.mangaKey
            )
        }
        return (try? context.count(for: request)) ?? 0
    }
}
