//
//  CoreDataManager+History.swift
//  Aidoku (iOS)
//
//  Created by Skitty on 8/14/22.
//

import CoreData

extension CoreDataManager {
    /// Remove all history objects.
    @discardableResult
    func clearHistory(context: NSManagedObjectContext) -> Bool {
        clearHistoryMetadata(context: context)
        return clear(request: HistoryObject.fetchRequest(), context: context)
    }

    // Clear again after the context's current block so a racing recovery cannot leave an entry.
    private func clearHistoryMetadata(context: NSManagedObjectContext) {
        HistoryMetadataCache.shared.clear()
        context.perform { HistoryMetadataCache.shared.clear() }
    }

    /// Remove all history objects from manga not in library
    @discardableResult
    func clearHistoryExcludingLibrary(context: NSManagedObjectContext) -> Bool {
        clearHistoryMetadata(context: context)
        // A per-manga OR predicate exceeds SQLite's expression depth for large libraries.
        let libraryKeys = Set(getLibraryManga(context: context).compactMap { $0.manga?.identifier })
        let request = HistoryObject.fetchRequest()
        request.propertiesToFetch = ["sourceId", "mangaId"]
        request.fetchBatchSize = 500
        guard let rows = try? context.fetch(request) else { return false }
        let objectIds = rows.compactMap { row -> NSManagedObjectID? in
            let key = MangaIdentifier(sourceKey: row.sourceId, mangaKey: row.mangaId)
            return libraryKeys.contains(key) ? nil : row.objectID
        }
        for batch in objectIds.chunked(into: 500) {
            do {
                let request = NSBatchDeleteRequest(objectIDs: batch)
                request.resultType = .resultTypeObjectIDs
                mergeBatchDelete(try context.execute(request), from: context)
            } catch {
                LogManager.logger.error("CoreDataManager.clearHistoryExcludingLibrary: \(error.localizedDescription)")
                return false
            }
        }
        return true
    }

    /// Gets all history objects.
    func getHistory(context: NSManagedObjectContext) -> [HistoryObject] {
        (try? context.fetch(HistoryObject.fetchRequest())) ?? []
    }

    /// Get history objects for a source.
    func getHistory(
        sourceKey: String,
        context: NSManagedObjectContext
    ) -> [HistoryObject] {
        let request = HistoryObject.fetchRequest()
        request.predicate = NSPredicate(format: "sourceId == %@", sourceKey)
        return (try? context.fetch(request)) ?? []
    }

    /// Get a particular history object.
    func getHistory(
        chapterId: ChapterIdentifier,
        context: NSManagedObjectContext
    ) -> HistoryObject? {
        let request = HistoryObject.fetchRequest()
        request.predicate = NSPredicate(
            format: "chapterId == %@ AND mangaId == %@ AND sourceId == %@",
            chapterId.chapterKey, chapterId.mangaKey, chapterId.sourceKey
        )
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    /// Gets sorted history objects.
    func getRecentHistory(limit: Int, offset: Int, context: NSManagedObjectContext) -> [HistoryObject] {
        let request = HistoryObject.fetchRequest()
        request.sortDescriptors = [
            NSSortDescriptor(key: "dateRead", ascending: false),
            NSSortDescriptor(key: "chapter.chapter", ascending: false)
        ]
        request.fetchLimit = limit
        request.fetchOffset = offset
        return (try? context.fetch(request)) ?? []
    }

    /// Check if history exists for a chapter.
    func hasHistory(
        chapterId: ChapterIdentifier,
        context: NSManagedObjectContext
    ) -> Bool {
        let request = HistoryObject.fetchRequest()
        request.predicate = NSPredicate(
            format: "chapterId == %@ AND mangaId == %@ AND sourceId == %@",
            chapterId.chapterKey, chapterId.mangaKey, chapterId.sourceKey
        )
        request.fetchLimit = 1
        return (try? context.count(for: request)) ?? 0 > 0
    }

    /// Check if history exists for a manga.
    func hasHistory(
        mangaId: MangaIdentifier,
        context: NSManagedObjectContext
    ) -> Bool {
        let request = HistoryObject.fetchRequest()
        request.predicate = NSPredicate(
            format: "mangaId == %@ AND sourceId == %@",
            mangaId.mangaKey, mangaId.sourceKey
        )
        request.fetchLimit = 1
        return (try? context.count(for: request)) ?? 0 > 0
    }

    /// Removes history for manga.
    func removeHistory(mangaId: MangaIdentifier, context: NSManagedObjectContext) {
        HistoryMetadataCache.shared.remove(mangaId: mangaId)
        context.perform { HistoryMetadataCache.shared.remove(mangaId: mangaId) }
        let history = getHistoryForManga(mangaId: mangaId, context: context)
        for item in history {
            context.delete(item)
        }
    }

    @discardableResult
    func removeHistory(chapterIds: [ChapterIdentifier]) async -> Bool {
        HistoryMetadataCache.shared.remove(chapterIds: chapterIds)
        return await container.performBackgroundTask { context in
            do {
                try self.removeHistory(chapterIds: chapterIds, context: context)
                try context.save()
                HistoryMetadataCache.shared.remove(chapterIds: chapterIds)
                return true
            } catch {
                context.rollback()
                LogManager.logger.error("CoreDataManager.removeHistory(sourceId:mangaId:chapterIds:): \(error.localizedDescription)")
                return false
            }
        }
    }

    func removeHistory(chapterIds: [ChapterIdentifier], context: NSManagedObjectContext) throws {
        for (manga, chapters) in Dictionary(grouping: Set(chapterIds), by: \.mangaIdentifier) {
            for keys in chapters.map(\.chapterKey).chunked(into: 500) {
                let request = HistoryObject.fetchRequest()
                request.predicate = NSPredicate(format: "sourceId == %@ AND mangaId == %@ AND chapterId IN %@",
                                                manga.sourceKey, manga.mangaKey, keys)
                for history in try context.fetch(request) {
                    context.delete(history)
                }
            }
        }
    }

    func getOrCreateHistory(
        chapterId: ChapterIdentifier,
        context: NSManagedObjectContext
    ) -> HistoryObject {
        if let historyObject = getHistory(
            chapterId: chapterId,
            context: context
        ) {
            return historyObject
        }
        let historyObject = HistoryObject(context: context)
        historyObject.sourceId = chapterId.sourceKey
        historyObject.mangaId = chapterId.mangaKey
        historyObject.chapterId = chapterId.chapterKey
        if let chapterObject = self.getChapter(chapterId: chapterId, context: context) {
            historyObject.chapter = chapterObject
        }
        return historyObject
    }

    /// Get history objects for a manga.
    func getHistoryForManga(
        mangaId: MangaIdentifier,
        context: NSManagedObjectContext
    ) -> [HistoryObject] {
        let request = HistoryObject.fetchRequest()
        request.predicate = NSPredicate(
            format: "mangaId == %@ AND sourceId == %@",
            mangaId.mangaKey, mangaId.sourceKey
        )
        return (try? context.fetch(request)) ?? []
    }

    // format: [chapterId: (page (-1 if completed), read date)]
    func getReadingHistory(mangaId: MangaIdentifier) async -> [String: (page: Int, date: Int)] {
        await container.performBackgroundTask { context in
            let objects = self.getHistoryForManga(mangaId: mangaId, context: context)

            var needsSave = false
            var historyDict: [String: (page: Int, date: Int)] = [:]

            let inLibrary = self.hasLibraryManga(mangaId: mangaId, context: context)

            var keptHistory: [String: HistoryObject] = [:]
            // One chapter fetch for all unlinked rows instead of one per row.
            lazy var chapters = Dictionary(
                self.getChapters(mangaId: mangaId, context: context).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
            )
            for history in objects.sorted(by: { ($0.dateRead ?? .distantPast) > ($1.dateRead ?? .distantPast) }) {
                // Keep the newest progress and preserve sessions attached to older duplicates.
                if let keeper = keptHistory[history.chapterId] {
                    needsSave = true
                    Self.mergeDuplicateRelationships(from: history, into: keeper)
                    context.delete(history)
                    continue
                }
                keptHistory[history.chapterId] = history
                // link history to chapter if link is missing
                if inLibrary && history.chapter == nil {
                    if let chapter = chapters[history.chapterId] {
                        history.chapter = chapter
                        needsSave = true
                    }
                }
                historyDict[history.chapterId] = (
                    history.completed ? -1 : Int(history.progress),
                    Int(history.dateRead?.timeIntervalSince1970 ?? -1)
                )
            }

            if needsSave {
                try? context.save()
            }

            return historyDict
        }
    }

    @MainActor
    func getProgress(chapterId: ChapterIdentifier) -> (completed: Bool, progress: Int?) {
        getProgress(chapterId: chapterId, context: context)
    }

    /// Get current completion status and page progress for chapter
    func getProgress(
        chapterId: ChapterIdentifier,
        context: NSManagedObjectContext
    ) -> (completed: Bool, progress: Int?) {
        let historyObject = getHistory(chapterId: chapterId, context: context)
        return (historyObject?.completed ?? false, (historyObject?.progress).flatMap(Int.init))
    }

    /// Set page progress for a chapter and creates a history object if it doesn't already exist.
    @discardableResult
    func setProgress(
        _ progress: Int,
        chapterId: ChapterIdentifier,
        totalPages: Int? = nil,
        scrollPosition: Double? = nil,
        dateRead: Date? = nil,
        completed: Bool? = nil,
        context: NSManagedObjectContext
    ) -> HistoryObject {
        let historyObject = self.getOrCreateHistory(
            chapterId: chapterId,
            context: context
        )
        historyObject.progress = Int16(clamping: progress)
        historyObject.dateRead = dateRead ?? Date()
        if let totalPages {
            historyObject.total = Int16(clamping: totalPages)
        }
        if let scrollPosition {
            historyObject.scrollPosition = NSNumber(value: scrollPosition)
        }
        if let completed {
            historyObject.completed = completed
        }
        return historyObject
    }

    /// Marks chapters as completed.
    @discardableResult
    func setCompleted(
        chapterIds: [ChapterIdentifier],
        date: Date = Date(),
        context: NSManagedObjectContext
    ) -> Bool {
        var success = false
        // Prefetch per manga: each single-row fetch also rescans every pending insert.
        var histories: [ChapterIdentifier: HistoryObject] = [:]
        var chapters: [ChapterIdentifier: ChapterObject] = [:]
        var prefetched: Set<ChapterIdentifier> = []
        for (manga, ids) in Dictionary(grouping: Set(chapterIds), by: \.mangaIdentifier) {
            for keys in ids.map(\.chapterKey).chunked(into: 500) {
                let format = "sourceId == %@ AND mangaId == %@ AND %K IN %@"
                let historyRequest = HistoryObject.fetchRequest()
                historyRequest.predicate = NSPredicate(format: format, manga.sourceKey, manga.mangaKey, "chapterId", keys)
                let chapterRequest = ChapterObject.fetchRequest()
                chapterRequest.predicate = NSPredicate(format: format, manga.sourceKey, manga.mangaKey, "id", keys)
                guard
                    let historyRows = try? context.fetch(historyRequest),
                    let chapterRows = try? context.fetch(chapterRequest)
                else { continue }
                let historyGroups = Dictionary(grouping: historyRows, by: \.chapterId)
                let chapterGroups = Dictionary(grouping: chapterRows, by: \.id)
                // Legacy duplicate rows keep the single-row lookup.
                for key in keys where historyGroups[key]?.count ?? 0 < 2 && chapterGroups[key]?.count ?? 0 < 2 {
                    let id = ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.mangaKey, chapterKey: key)
                    histories[id] = historyGroups[key]?.first
                    chapters[id] = chapterGroups[key]?.first
                    prefetched.insert(id)
                }
            }
        }
        for chapterId in chapterIds {
            let historyObject: HistoryObject
            if let history = histories[chapterId] {
                historyObject = history
            } else if prefetched.contains(chapterId) {
                historyObject = HistoryObject(context: context)
                historyObject.sourceId = chapterId.sourceKey
                historyObject.mangaId = chapterId.mangaKey
                historyObject.chapterId = chapterId.chapterKey
                if let chapterObject = chapters[chapterId] {
                    historyObject.chapter = chapterObject
                }
                histories[chapterId] = historyObject
            } else {
                historyObject = self.getOrCreateHistory(chapterId: chapterId, context: context)
            }
            guard !historyObject.completed else { continue }
            historyObject.completed = true
            historyObject.dateRead = date
            success = true
        }
        return success
    }

    /// Check if history exists for a manga.
    func getEarliestReadDate(mangaId: MangaIdentifier, context: NSManagedObjectContext) -> Date? {
        let request = HistoryObject.fetchRequest()
        request.predicate = NSPredicate(
            format: "mangaId == %@ AND sourceId == %@ AND completed == true",
            mangaId.mangaKey, mangaId.sourceKey
        )
        request.fetchLimit = 1
        request.sortDescriptors = [NSSortDescriptor(key: "dateRead", ascending: true)]
        let result = (try? context.fetch(request))?.first
        return result?.dateRead
    }

    /// Get the highest read number (chapter or volume) based on forced mode for a manga.
    func getHighestReadNumber(
        mangaId: MangaIdentifier,
        context: NSManagedObjectContext
    ) -> Float? {
        let request = HistoryObject.fetchRequest()
        request.predicate = NSPredicate(
            format: "mangaId == %@ AND sourceId == %@ AND completed == true",
            mangaId.mangaKey, mangaId.sourceKey
        )
        request.fetchLimit = 1

        let key = "Manga.chapterDisplayMode.\(mangaId.description)"
        let displayMode: ChapterTitleDisplayMode = if mangaId.sourceKey.hasPrefix(KomgaSourceRunner.sourceKeyPrefix) {
            UserDefaults.standard.bool(forKey: "\(mangaId.sourceKey).useChapters") ? .chapter : .volume
        } else {
            .init(rawValue: UserDefaults.standard.integer(forKey: key)) ?? .default
        }
        switch displayMode {
            case .default:
                // Default mode: return highest chapter number
                request.sortDescriptors = [NSSortDescriptor(key: "chapter.chapter", ascending: false)]
                let result = (try? context.fetch(request))?.first
                return result?.chapter?.chapter?.floatValue
            case .chapter:
                // Forced chapter mode: return highest chapter number, fallback to volume as chapter
                request.sortDescriptors = [NSSortDescriptor(key: "chapter.chapter", ascending: false)]
                let result = (try? context.fetch(request))?.first
                if let chapter = result?.chapter?.chapter?.floatValue, chapter > 0 {
                    return chapter
                } else if let volume = result?.chapter?.volume?.floatValue {
                    return volume // Use volume number as chapter
                }
            case .volume:
                // Forced volume mode: return highest volume number, fallback to chapter as volume
                request.sortDescriptors = [NSSortDescriptor(key: "chapter.volume", ascending: false)]
                let result = (try? context.fetch(request))?.first
                if let volume = result?.chapter?.volume?.floatValue, volume > 0 {
                    return volume
                } else if let chapter = result?.chapter?.chapter?.floatValue {
                    return chapter // Use chapter number as volume
                }
        }

        return nil
    }
}
