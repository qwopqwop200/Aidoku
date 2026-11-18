//
//  CoreDataManager+Updates.swift
//  Aidoku
//
//  Created by axiel7 on 09/02/2024.
//

import CoreData

extension CoreDataManager {
    /// Remove all update objects.
    func clearUpdates(context: NSManagedObjectContext) {
        clear(request: MangaUpdateObject.fetchRequest(), context: context)
    }

    /// Gets all update objects.
    func getUpdates(context: NSManagedObjectContext) -> [MangaUpdateObject] {
        (try? context.fetch(MangaUpdateObject.fetchRequest())) ?? []
    }

    /// Gets sorted manga update objects.
    func getRecentMangaUpdates(limit: Int, offset: Int, context: NSManagedObjectContext) -> [MangaUpdateObject] {
        let request = MangaUpdateObject.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        request.relationshipKeyPathsForPrefetching = ["chapter", "chapter.manga"]
        request.fetchLimit = limit
        request.fetchOffset = offset
        return (try? context.fetch(request)) ?? []
    }

    /// Creates updates in source order and returns the number of new feed entries.
    @discardableResult
    func createMangaUpdates(
        mangaId: MangaIdentifier,
        chapters: [ChapterObject],
        language: String?,
        scanlators: [String],
        context: NSManagedObjectContext
    ) throws -> Int {
        let selectedScanlators = Set(scanlators)
        let eligible = chapters.filter { chapter in
            guard language == nil || chapter.lang == language else { return false }
            guard !selectedScanlators.isEmpty else { return true }
            // ChapterObject stores multiple scanlators joined with ", ".
            let stored = chapter.scanlator ?? ""
            if selectedScanlators.contains(stored) { return true }
            return stored.components(separatedBy: ", ").contains(where: selectedScanlators.contains)
        }
        var known: Set<String> = []
        for start in stride(from: 0, to: eligible.count, by: 500) {
            let batch = eligible[start..<min(start + 500, eligible.count)]
            let request = MangaUpdateObject.fetchRequest()
            request.predicate = NSPredicate(
                format: "sourceId == %@ AND mangaId == %@ AND chapterId IN %@",
                mangaId.sourceKey, mangaId.mangaKey, batch.map(\.id)
            )
            request.returnsObjectsAsFaults = false
            known.formUnion(try context.fetch(request).compactMap(\.chapterId))
        }

        var inserted = 0
        for chapter in eligible where known.insert(chapter.id).inserted {
            let update = MangaUpdateObject(context: context)
            update.sourceId = mangaId.sourceKey
            update.mangaId = mangaId.mangaKey
            update.chapterId = chapter.id
            update.date = Date()
            update.chapter = chapter
            inserted += 1
        }
        return inserted
    }

    /// Removes manga update objects by their composite keys
    func removeMangaUpdates(
        updates: [ChapterIdentifier],
        context: NSManagedObjectContext
    ) {
        let request = MangaUpdateObject.fetchRequest()

        var predicates: [NSPredicate] = []
        for update in updates {
            predicates.append(NSPredicate(
                format: "sourceId == %@ AND chapterId == %@ AND mangaId == %@",
                update.sourceKey, update.chapterKey, update.mangaKey
            ))
        }
        request.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: predicates)

        if let fetchedUpdates = try? context.fetch(request) {
            for update in fetchedUpdates {
                context.delete(update)
            }
        }
    }

    /// Gets all unviewed updates of a manga
    func getUnviewedMangaUpdates(
        mangaId: MangaIdentifier,
        context: NSManagedObjectContext
    ) -> [MangaUpdateObject] {
        let request = MangaUpdateObject.fetchRequest()
        request.predicate = NSPredicate(
            format: "mangaId == %@ AND sourceId == %@ AND viewed == false",
            mangaId.mangaKey, mangaId.sourceKey
        )
        return (try? context.fetch(request)) ?? []
    }

    /// Mark all updates of a manga as viewed
    /// - Returns: The Manga Updates marked as read
    @discardableResult
    func setMangaUpdatesViewed(
        viewed: Bool = true,
        mangaId: MangaIdentifier,
        context: NSManagedObjectContext
    ) -> [MangaUpdateObject] {
        let unviewedUpdates = getUnviewedMangaUpdates(mangaId: mangaId, context: context)
        if unviewedUpdates.isEmpty { return [] }
        for update in unviewedUpdates {
            update.viewed = viewed
        }
        do {
            try context.save()
            return unviewedUpdates
        } catch {
            LogManager.logger.error("CoreDataManager.setMangaUpdatesViewed: \(error.localizedDescription)")
            return []
        }
    }
}

/// The two library refresh paths share a write turn per title, from initial reads through save.
/// Each operation keeps its own context and its existing save/error handling.
actor MangaUpdateWriter {
    static let shared = MangaUpdateWriter()
    private var waiting: [MangaIdentifier: [CheckedContinuation<Void, Never>]] = [:]

    func perform<Result>(
        for id: MangaIdentifier,
        in container: NSPersistentContainer = CoreDataManager.shared.container,
        _ changes: @escaping @Sendable (NSManagedObjectContext) throws -> Result
    ) async rethrows -> Result {
        if waiting[id] != nil {
            await withCheckedContinuation { waiting[id, default: []].append($0) }
        } else {
            waiting[id] = []
        }
        defer {
            if waiting[id]?.isEmpty == false {
                waiting[id]?.removeFirst().resume()
            } else {
                waiting[id] = nil
            }
        }
        return try await container.performBackgroundTask(changes)
    }
}
