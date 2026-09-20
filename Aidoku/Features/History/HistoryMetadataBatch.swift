import AidokuRunner
import CoreData

/// Fetch only metadata referenced by this history page, without faulting in a
/// manga's entire chapter collection or retaining any decoded cover images.
struct HistoryMetadataBatch {
    var manga: [MangaIdentifier: AidokuRunner.Manga] = [:]
    var chapters: [ChapterIdentifier: AidokuRunner.Chapter] = [:]

    static func load(
        chapterIds: [ChapterIdentifier], context: NSManagedObjectContext, cache: HistoryMetadataCache? = nil
    ) -> Self {
        var result = Self()
        let ids = Array(Set(chapterIds))
        // Notifications can contain more than the normal 100-row history page.
        // Bound SQL predicate size even for a large history import.
        for start in stride(from: 0, to: ids.count, by: 100) {
            let batch = ids[start..<min(start + 100, ids.count)]
            let mangaIds = Set(batch.map(\.mangaIdentifier)).filter { result.manga[$0] == nil }
            if !mangaIds.isEmpty {
                let request = MangaObject.fetchRequest()
                request.returnsObjectsAsFaults = false
                request.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: mangaIds.map {
                    NSPredicate(format: "sourceId == %@ AND id == %@", $0.sourceKey, $0.mangaKey)
                })
                for object in (try? context.fetch(request)) ?? [] {
                    result.manga[object.identifier] = object.toNewManga()
                }
            }
            let request = ChapterObject.fetchRequest()
            request.returnsObjectsAsFaults = false
            request.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: batch.map {
                NSPredicate(format: "sourceId == %@ AND mangaId == %@ AND id == %@",
                            $0.sourceKey, $0.mangaKey, $0.chapterKey)
            })
            for object in (try? context.fetch(request)) ?? [] {
                result.chapters[object.identifier] = object.toNewChapter()
            }
        }
        if let cached = cache?.load(chapterIds: chapterIds) {
            result.manga.merge(cached.manga) { stored, _ in stored }
            result.chapters.merge(cached.chapters) { stored, _ in stored }
        }
        return result
    }
}
