//
//  ReaderPagedViewModel.swift
//  Aidoku (iOS)
//
//  Created by Skitty on 8/15/22.
//

import Foundation
import AidokuRunner

/// Owns a transferred page-list operation until the foreground load finishes.
/// Dropping an unused handoff cancels it; it is never a completed-image cache.
final class ReaderChapterPageHandoff: Sendable {
    let chapter: AidokuRunner.Chapter
    fileprivate let owner: UUID
    fileprivate let task: Task<[Page], Never>

    fileprivate init(chapter: AidokuRunner.Chapter, owner: UUID, task: Task<[Page], Never>) {
        self.chapter = chapter
        self.owner = owner
        self.task = task
    }

    deinit { task.cancel() }
}

private final class ReaderPendingChapterPreload: @unchecked Sendable {
    let chapter: AidokuRunner.Chapter
    let task: Task<[Page], Never>
    private let lock = NSLock()
    private var transferred = false
    private var cancelled = false

    init(chapter: AidokuRunner.Chapter, task: Task<[Page], Never>) {
        self.chapter = chapter
        self.task = task
    }

    func take(owner: UUID) -> ReaderChapterPageHandoff? {
        lock.withLock {
            guard !transferred, !cancelled else { return nil }
            transferred = true
            return ReaderChapterPageHandoff(chapter: chapter, owner: owner, task: task)
        }
    }

    func cancelUnlessTransferred() {
        let shouldCancel = lock.withLock {
            guard !transferred else { return false }
            cancelled = true
            return true
        }
        if shouldCancel { task.cancel() }
    }
}

@MainActor
class ReaderPagedViewModel {
    let source: AidokuRunner.Source?
    let manga: AidokuRunner.Manga
    let temporaryPageStore: ReaderTemporaryPageStore?

    var chapter: AidokuRunner.Chapter?
    var pages: [Page] = []

    var preloadedChapter: AidokuRunner.Chapter?
    var preloadedPages: [Page] = []
    private var loadGeneration = UUID()
    private var preloadGeneration = UUID()
    private let handoffOwner = UUID()
    private var pendingPreload: ReaderPendingChapterPreload?

    init(
        source: AidokuRunner.Source?,
        manga: AidokuRunner.Manga,
        temporaryPageStore: ReaderTemporaryPageStore? = nil
    ) {
        self.source = source
        self.manga = manga
        self.temporaryPageStore = temporaryPageStore
    }

    /// Call synchronously before cancelling the speculative consumer.
    func takePendingPreload(for chapter: AidokuRunner.Chapter) -> ReaderChapterPageHandoff? {
        guard let pendingPreload, pendingPreload.chapter == chapter,
              let handoff = pendingPreload.take(owner: handoffOwner) else { return nil }
        self.pendingPreload = nil
        // The old consumer must not publish a second preload cache after transfer.
        preloadGeneration = UUID()
        return handoff
    }

    func loadPages(chapter: AidokuRunner.Chapter, handoff: ReaderChapterPageHandoff? = nil) async {
        guard !Task.isCancelled else { handoff?.task.cancel(); return }
        loadGeneration = UUID()
        let issued = loadGeneration
        if preloadedChapter == chapter {
            handoff?.task.cancel()
            self.chapter = chapter
            pages = preloadedPages
            preloadedPages = []
            preloadedChapter = nil
        } else {
            if !pages.isEmpty {
                preloadedChapter = self.chapter
                preloadedPages = pages
            }
            self.chapter = chapter
            let loaded: [Page]
            if let handoff, handoff.owner == handoffOwner, handoff.chapter == chapter {
                loaded = await withTaskCancellationHandler {
                    await handoff.task.value
                } onCancel: {
                    handoff.task.cancel()
                }
            } else {
                handoff?.task.cancel()
                loaded = await Self.getPages(chapter: chapter, source: source, manga: manga, temporaryPageStore: temporaryPageStore)
            }
            guard !Task.isCancelled, issued == loadGeneration else { return }
            pages = loaded
        }
    }

    @discardableResult
    func preload(chapter: AidokuRunner.Chapter) async -> [Page] {
        guard !Task.isCancelled else { return [] }
        if preloadedChapter == chapter { return preloadedPages }
        preloadGeneration = UUID()
        let issued = preloadGeneration
        // Capture immutable inputs, not the model that retains pendingPreload.
        let operation = Task { [source, manga, temporaryPageStore] in
            await Self.getPages(chapter: chapter, source: source, manga: manga, temporaryPageStore: temporaryPageStore)
        }
        let pending = ReaderPendingChapterPreload(chapter: chapter, task: operation)
        pendingPreload = pending
        defer { if pendingPreload === pending { pendingPreload = nil } }
        let loaded = await withTaskCancellationHandler {
            await operation.value
        } onCancel: {
            pending.cancelUnlessTransferred()
        }
        guard !Task.isCancelled else { return [] }
        if issued == preloadGeneration {
            preloadedPages = loaded
            preloadedChapter = chapter
        }
        return loaded
    }

    private static func getPages(
        chapter: AidokuRunner.Chapter, source: AidokuRunner.Source?, manga: AidokuRunner.Manga,
        temporaryPageStore: ReaderTemporaryPageStore?
    ) async -> [Page] {
        guard !Task.isCancelled else { return [] }
        let sourceId = source?.key ?? manga.sourceKey
        let identifier = ChapterIdentifier(
            sourceKey: sourceId,
            mangaKey: manga.key,
            chapterKey: chapter.key
        )
        let language = chapter.language ?? source?.languages.first
        let isDownloaded = DownloadManager.shared.isChapterDownloaded(chapter: identifier)
        if isDownloaded {
            return await DownloadManager.shared.getDownloadedPages(for: identifier)
                .map {
                    $0.toOld(sourceId: sourceId, chapterId: chapter.key, language: language)
                }
        } else {
            guard var sourcePages = try? await source?.getPageList(
                manga: manga,
                chapter: chapter
            ) else {
                return []
            }

            var pages: [Page] = []
            pages.reserveCapacity(sourcePages.count)

            // iterate in reverse so pages with image data are dropped
            while let sourcePage = sourcePages.popLast() {
                guard !Task.isCancelled else { return [] }
                var page = sourcePage.toOld(
                    sourceId: sourceId,
                    chapterId: chapter.key,
                    language: language
                )
                if
                    let temporaryPageStore,
                    let image = page.image,
                    let fileURL = await temporaryPageStore.store(
                        image,
                        chapterKey: chapter.key,
                        pageIndex: sourcePages.count
                    )
                {
                    page.image = nil
                    page.imageURL = fileURL.absoluteString
                }
                pages.append(page)
            }

            return pages.reversed()
        }
    }
}
