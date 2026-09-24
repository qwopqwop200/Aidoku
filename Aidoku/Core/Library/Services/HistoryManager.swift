//
//  HistoryManager.swift
//  Aidoku
//
//  Created by Skitty on 1/9/23.
//

import AidokuRunner
import CoreData

final class HistoryManager: Sendable {
    static let shared = HistoryManager()
}

extension HistoryManager {
    func setProgress(
        chapterId: ChapterIdentifier,
        chapter: AidokuRunner.Chapter,
        manga: AidokuRunner.Manga? = nil,
        progress: Int,
        totalPages: Int? = nil,
        scrollPosition: Double? = nil,
        completed: Bool
    ) async {
        let mangaId = chapterId.mangaIdentifier
        let metadataGeneration = HistoryMetadataCache.shared.generation
        let saved = await CoreDataManager.shared.container.performBackgroundTask { context in
            do {
                try Self.saveMutationWithRetry(context: context) {
                    CoreDataManager.shared.setRead(mangaId: mangaId, context: context)
                    CoreDataManager.shared.setProgress(
                        progress,
                        chapterId: chapterId,
                        totalPages: totalPages,
                        scrollPosition: scrollPosition,
                        context: context
                    )
                    return true
                }
                if let manga {
                    HistoryMetadataCache.shared.store(manga: manga, chapters: [chapter], generation: metadataGeneration)
                }
                return true
            } catch {
                context.rollback()
                LogManager.logger.error("HistoryManager.setProgress: \(error)")
                return false
            }
        }
        guard saved else { return }
        NotificationCenter.default.post(name: .historySet, object: (chapterId, progress))
        if !completed {
            Task {
                // update page trackers with progress
                await TrackerManager.shared.setProgress(
                    mangaId: mangaId,
                    chapter: chapter,
                    progress: .init(completed: false, page: progress)
                )
            }
        }
    }

    struct ReadingSessionData {
        let startDate: Date
        let endDate: Date
        let pagesRead: Int
    }

    func addSession(chapterId: ChapterIdentifier, data: ReadingSessionData) async {
        await CoreDataManager.shared.container.performBackgroundTask { context in
            CoreDataManager.shared.createSession(
                chapterId: chapterId,
                data: data,
                context: context
            )
            do {
                try context.save()
            } catch {
                LogManager.logger.error("HistoryManager.addSession: \(error)")
            }
        }
    }

    @discardableResult
    func addHistory(
        mangaId: MangaIdentifier,
        chapters: [AidokuRunner.Chapter],
        manga: AidokuRunner.Manga? = nil,
        date: Date = Date(),
        skipTracker: Tracker? = nil
    ) async -> Bool {
        guard !chapters.isEmpty else { return false }
        let metadataGeneration = HistoryMetadataCache.shared.generation
        let result = await CoreDataManager.shared.container.performBackgroundTask { context in
            do {
                let changed = try Self.saveMutationWithRetry(context: context) {
                    let changed = CoreDataManager.shared.setCompleted(
                        chapterIds: chapters.map {
                            .init(sourceKey: mangaId.sourceKey, mangaKey: mangaId.mangaKey, chapterKey: $0.key)
                        },
                        date: date,
                        context: context
                    )
                    if changed {
                        CoreDataManager.shared.setRead(mangaId: mangaId, date: date, context: context)
                    }
                    return changed
                }
                if changed, let manga {
                    HistoryMetadataCache.shared.store(manga: manga, chapters: chapters, generation: metadataGeneration)
                }
                return (saved: true, changed: changed)
            } catch {
                context.rollback()
                LogManager.logger.error("HistoryManager.addHistory: \(error.localizedDescription)")
                return (saved: false, changed: false)
            }
        }
        guard result.saved else { return false }
        // Already-completed persisted chapters acknowledge success without duplicate events.
        guard result.changed else { return true }
        NotificationCenter.default.post(
            name: .historyAdded,
            object: chapters.map {
                ChapterIdentifier(sourceKey: mangaId.sourceKey, mangaKey: mangaId.mangaKey, chapterKey: $0.key)
            }
        )
        Task {
            if AppSettings.tracking.updateAfterReading.get() {
                // update tracker with chapter with largest number
                if let maxChapter = chapters.max(by: { $0.chapterNumber ?? 0 < $1.chapterNumber ?? 0 }) {
                    await TrackerManager.shared.setCompleted(
                        mangaId: mangaId,
                        chapter: maxChapter,
                        skipTracker: skipTracker
                    )
                }
            }

            await TrackerManager.shared.setProgress(
                mangaId: mangaId,
                chapters: chapters,
                progress: .init(completed: true, page: 0)
            )
        }
        return true
    }

    /// Retry only optimistic locking conflicts on a private history transaction.
    /// Refetch before replay so unrelated changes (for example lastOpened) survive.
    @discardableResult
    static func saveMutationWithRetry(
        context: NSManagedObjectContext,
        mutation: () throws -> Bool
    ) throws -> Bool {
        for attempt in 0..<3 {
            let changed = try mutation()
            guard changed else { return false }
            do {
                try context.save()
                return true
            } catch {
                context.rollback()
                guard attempt < 2, isOptimisticMergeConflict(error as NSError) else { throw error }
                context.reset()
            }
        }
        return false // The final failed attempt throws; no unbounded retries.
    }

    private static func isOptimisticMergeConflict(_ error: NSError) -> Bool {
        guard error.domain == NSCocoaErrorDomain else { return false }
        if error.code == NSManagedObjectMergeError { return true }
        guard let errors = error.userInfo[NSDetailedErrorsKey] as? [NSError], !errors.isEmpty else { return false }
        return errors.allSatisfy(isOptimisticMergeConflict)
    }

    func removeHistory(chapterIds: [ChapterIdentifier]) async {
        guard !chapterIds.isEmpty else { return }
        guard await CoreDataManager.shared.removeHistory(chapterIds: chapterIds) else { return }
        NotificationCenter.default.post(name: .historyRemoved, object: chapterIds)
        Task {
            for (mangaId, identifiers) in Dictionary(grouping: chapterIds, by: \.mangaIdentifier) {
                await TrackerManager.shared.setProgress(
                    mangaId: mangaId,
                    chapters: identifiers.map { .init(key: $0.chapterKey) },
                    progress: .init(completed: false, page: 0)
                )
            }
        }
    }

    func removeHistory(mangaId: MangaIdentifier) async {
        let saved = await CoreDataManager.shared.container.performBackgroundTask { context in
            CoreDataManager.shared.removeHistory(mangaId: mangaId, context: context)
            do {
                try context.save()
                return true
            } catch {
                context.rollback()
                LogManager.logger.error("HistoryManager.removeHistory: \(error)")
                return false
            }
        }
        guard saved else { return }
        NotificationCenter.default.post(name: .historyRemoved, object: mangaId)
        Task {
            let chapters = await CoreDataManager.shared.getChapters(mangaId: mangaId)
            await TrackerManager.shared.setProgress(
                mangaId: mangaId,
                chapters: chapters.map { $0.toNew() },
                progress: .init(completed: false, page: 0)
            )
        }
    }
}
