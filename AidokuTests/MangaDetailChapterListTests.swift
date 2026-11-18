import AidokuRunner
import Combine
import Foundation
import Testing
@testable import Aidoku

@MainActor
struct MangaDetailChapterListTests {
    @Test func bulkDownloadIndicatorsPublishOnceAndInvalidateRemovableMenu() {
        let manga = AidokuRunner.Manga(sourceKey: "download-indicators", key: "book", title: "Book")
        let other = AidokuRunner.Manga(sourceKey: manga.sourceKey, key: "other", title: "Other")
        let model = MangaView.ViewModel(source: nil, manga: manga)
        let downloads = (0..<256).map { Download.from(manga: manga, chapter: .init(key: "chapter-\($0)")) }
        let unrelated = Download.from(manga: other, chapter: .init(key: "foreign"))
        let keys = downloads.map(\.chapterIdentifier)
        model.downloadStatus = ["chapter-0": .failed]
        #expect(model.hasRemovableDownloads)
        var statusUpdates = 0
        var progressUpdates = 0
        let status = model.$downloadStatus.dropFirst().sink { _ in statusUpdates += 1 }
        let progress = model.$downloadProgress.dropFirst().sink { _ in progressUpdates += 1 }
        defer { status.cancel(); progress.cancel() }

        model.downloadsWereQueued(downloads + [unrelated, downloads[0]])
        #expect(model.downloadStatus.count == keys.count && model.downloadStatus.values.allSatisfy { $0 == .queued })
        #expect(model.downloadProgress.count == keys.count && model.downloadProgress.values.allSatisfy { $0 == 0 })
        #expect(!model.hasRemovableDownloads)
        model.downloadsWereQueued(downloads)
        #expect(statusUpdates == 1 && progressUpdates == 1)

        let cancellation = Notification(name: .downloadsCancelled, object: keys + [unrelated.chapterIdentifier])
        model.removeDownloads(cancellation)
        model.removeDownloads(cancellation)
        #expect(statusUpdates == 2 && progressUpdates == 2)
        #expect(model.downloadStatus.count == keys.count && model.downloadStatus.values.allSatisfy { $0 == .none })
        #expect(model.downloadProgress.isEmpty && !model.hasRemovableDownloads)
        model.downloadStatus["chapter-1"] = .finished
        #expect(model.hasRemovableDownloads)
        model.removeDownloads(.init(name: .downloadsRemoved, object: manga.identifier))
        #expect(!model.hasRemovableDownloads)
    }

    @Test func initialLoadPublishesOneListAndOneStatusSnapshotAcrossBothSections() async throws {
        let sourceKey = "test-manga-detail-" + UUID().uuidString
        var manga = AidokuRunner.Manga(sourceKey: sourceKey, key: "book", title: "Book")
        manga.chapters = [.init(key: "on/list"), .init(key: "no-file")]
        let sourceDirectory = DownloadManager.directory.appendingPathComponent(sourceKey)
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        for directoryName in ["onlist", "unlisted"] {
            let directory = sourceDirectory.appendingPathComponent("book").appendingPathComponent(directoryName)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let model = MangaView.ViewModel(source: nil, manga: manga)
        var chapterUpdates = 0
        var statusUpdates = 0
        let list = model.$chapters.dropFirst().sink { _ in chapterUpdates += 1 }
        let status = model.$downloadStatus.dropFirst().sink { _ in statusUpdates += 1 }
        defer { list.cancel(); status.cancel() }

        await model.fetchDetails()
        #expect(model.chapters.map(\.key) == ["on/list", "no-file"])
        #expect(model.otherDownloadedChapters.map(\.key) == ["unlisted"])
        #expect(model.downloadStatus == ["on/list": .finished, "no-file": .none, "unlisted": .finished])
        #expect(chapterUpdates == 1)
        #expect(statusUpdates == 1)
        await model.fetchData()
        #expect(statusUpdates == 1)
    }

    @Test(arguments: [false, true])
    func removingAllDownloadsClearsOpenDetailAndRejectsOlderFileListing(global: Bool) async throws {
        var manga = AidokuRunner.Manga(sourceKey: "deletion-" + UUID().uuidString, key: "book", title: "Book")
        let listed = AidokuRunner.Chapter(key: "listed")
        manga.chapters = [listed]
        let model = MangaView.ViewModel(source: nil, manga: manga)
        model.chapterFilters = [.init(type: .downloaded, exclude: false)]
        model.chapters = [listed]
        model.otherDownloadedChapters = [.init(key: "unlisted")]
        model.downloadStatus = ["listed": .finished, "unlisted": .finished]
        model.downloadProgress = ["listed": 0.5]
        var continuation: CheckedContinuation<[DownloadedChapterInfo], Never>?
        var listing: Task<Void, Never>?
        await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
            listing = Task {
                await model.fetchDownloadedChapters { _ in
                    await withCheckedContinuation {
                        continuation = $0
                        started.resume()
                    }
                }
            }
        }

        model.removeDownloads(.init(name: .downloadsRemoved, object: MangaIdentifier(sourceKey: "other", mangaKey: manga.key)))
        model.removeDownloads(.init(name: .downloadsCancelled))
        #expect(model.downloadStatus.count == 2)
        #expect(model.otherDownloadedChapters.count == 1)

        model.removeDownloads(.init(name: .downloadsRemoved, object: global ? nil : manga.identifier))
        let stale = DownloadedChapterInfo(chapterId: "unlisted", size: 0)
        continuation?.resume(returning: [stale])
        await listing?.value
        #expect(model.otherDownloadedChapters.isEmpty)
        #expect(model.chapters.isEmpty)
        #expect(model.nextChapter == nil)
        #expect(model.downloadStatus.isEmpty && model.downloadProgress.isEmpty)
    }

    @Test func chapterSortKeepsSourceOrderForTiesAcrossLanguageAndReadFilters() {
        var manga = AidokuRunner.Manga(sourceKey: "test", key: "book", title: "Book")
        manga.chapters = [
            .init(key: "high", chapterNumber: 8, language: "en"),
            .init(key: "read", chapterNumber: 4, language: "en"),
            .init(key: "first", chapterNumber: 3, language: "en"),
            .init(key: "other", chapterNumber: 7, language: "fr"),
            .init(key: "second", chapterNumber: 3, language: "en")
        ]
        let model = MangaView.ViewModel(source: nil, manga: manga)
        model.readingHistory = ["read": (page: -1, date: 1)]
        model.chapterLangFilter = "en"
        model.chapterFilters = [.init(type: .unread, exclude: false)]
        model.chapterSortOption = .chapter
        #expect(model.chapters.map(\.key) == ["high", "first", "second"])
        #expect(model.nextChapter?.key == "second")
        model.chapterSortAscending = true
        #expect(model.chapters.map(\.key) == ["first", "second", "high"])
        #expect(model.nextChapter?.key == "first")
    }
}
