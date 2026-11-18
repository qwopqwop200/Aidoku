import AidokuRunner
import CoreData
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderHistoryCompletionAcknowledgmentTests {
    @Test(arguments: [0, 10], [false, true])
    func firstPageCreatesHistoryOnlyForLoadedNonIncognitoChapter(totalPages: Int, incognito: Bool) async throws {
        let restore = configureDefaults(deleteDownloads: false)
        defer { restore() }
        UserDefaults.standard.set(incognito, forKey: "General.incognitoMode")
        let reader = makeReader()
        let id = ChapterIdentifier(sourceKey: reader.manga.sourceKey, mangaKey: reader.manga.key, chapterKey: reader.chapter.key)

        // Exercise the same save boundary used when leaving the reader, without turning a page.
        await reader.updateReadPosition(currentPage: 1, totalPages: totalPages, position: 0.25)

        let stored = try await CoreDataManager.shared.container.performBackgroundTask { context -> (Int, Int, Bool, Double?)? in
            guard let history = CoreDataManager.shared.getHistory(chapterId: id, context: context) else { return nil }
            let result = (Int(history.progress), Int(history.total), history.completed, history.scrollPosition?.doubleValue)
            context.delete(history)
            try context.save()
            return result
        }
        if totalPages > 0 && !incognito {
            let history = try #require(stored)
            #expect(history.0 == 1)
            #expect(history.1 == totalPages)
            #expect(!history.2, "Opening a chapter must not mark it completed")
            #expect(history.3 == 0.25, "First-page text scroll progress must be retained")
        } else {
            #expect(stored == nil)
        }
    }

    @Test func failedCompletionCanRetryAndSuccessfulCompletionDeduplicates() async throws {
        let restore = configureDefaults(deleteDownloads: false)
        defer { restore() }
        let probe = CompletionProbe()
        let reader = makeReader()
        reader.historyCompletionWriter = { await probe.write($0) }
        reader.setCompleted()
        try await wait { probe.calls.count == 1 }
        for _ in 0..<10 { reader.setCompleted() }
        await Task.yield()
        #expect(probe.calls.count == 1, "An in-flight save must still deduplicate")
        probe.release(false)
        try await wait { reader.setCompleted(); return probe.calls.count == 2 }
        #expect(probe.calls == [["chapter"], ["chapter"]])
        probe.release(true)
        for _ in 0..<20 { await Task.yield(); reader.setCompleted() }
        #expect(probe.calls.count == 2, "Only durable success may permanently suppress repeats")
    }

    @Test func progressNotificationIncludesTheCommittedReadingSession() async throws {
        let restore = configureDefaults(deleteDownloads: false)
        defer { restore() }
        let reader = makeReader()
        let id = ChapterIdentifier(sourceKey: reader.manga.sourceKey, mangaKey: reader.manga.key, chapterKey: reader.chapter.key)
        let session = HistoryManager.ReadingSessionData(startDate: Date(timeIntervalSince1970: 100),
                                                       endDate: Date(timeIntervalSince1970: 120), pagesRead: 3)
        let manager = CoreDataManager.shared
        await confirmation("reader progress is published after its session is saved") { confirmed in
            let token = NotificationCenter.default.addObserver(forName: .historySet, object: nil, queue: nil) { notification in
                guard let (chapterId, _) = notification.object as? (ChapterIdentifier, Int), chapterId == id else { return }
                let context = manager.container.newBackgroundContext()
                context.performAndWait {
                    let history = manager.getHistory(chapterId: id, context: context)
                    let sessions = history?.sessions?.allObjects as? [ReadingSessionObject]
                    #expect(history?.progress == 3)
                    #expect(sessions?.count == 1)
                    #expect(sessions?.first?.pagesRead == 3)
                    #expect(sessions?.first?.startDate == session.startDate)
                    #expect(sessions?.first?.endDate == session.endDate)
                }
                confirmed()
            }
            defer { NotificationCenter.default.removeObserver(token) }
            await reader.updateReadPosition(currentPage: 3, totalPages: 12, position: 0.25, capturedSession: session)
        }
        _ = await manager.removeHistory(chapterIds: [id])
    }

    @Test func foregroundIntervalsSaveOnceInOrderAcrossClockChanges() async throws {
        let restore = configureDefaults(deleteDownloads: false)
        defer { restore() }
        let reader = makeReader()
        let id = ChapterIdentifier(sourceKey: reader.manga.sourceKey, mangaKey: reader.manga.key, chapterKey: reader.chapter.key)
        reader.loadViewIfNeeded()
        reader.setPages((0..<8).map { Aidoku.Page(sourceId: id.sourceKey, chapterId: id.chapterKey, index: $0) })
        reader.beginReadingSession(including: -1, uptime: 100)
        reader.setCurrentPage(2, position: 0.25)
        let firstEnd = Date(timeIntervalSince1970: 10_000)
        let first = reader.endReadingSession(now: firstEnd, uptime: 130)
        #expect(first != nil)
        #expect(reader.endReadingSession(now: firstEnd, uptime: 131) == nil)

        reader.beginReadingSession(including: 2, uptime: 4_000)
        reader.setCurrentPage(4, position: 0.75)
        let secondEnd = Date(timeIntervalSince1970: 5_000)
        let second = reader.endReadingSession(now: secondEnd, uptime: 4_020)
        #expect(second != nil)
        await second?.value

        let manager = CoreDataManager.shared
        try await manager.container.performBackgroundTask { context in
            let history = try #require(manager.getHistory(chapterId: id, context: context))
            let sessions = try #require(history.sessions?.allObjects as? [ReadingSessionObject])
            #expect(history.progress == 4 && history.scrollPosition?.doubleValue == 0.75 && history.dateRead == secondEnd)
            #expect(sessions.count == 2)
            let initial = try #require(sessions.first { $0.endDate == firstEnd })
            let resumed = try #require(sessions.first { $0.endDate == secondEnd })
            #expect(initial.startDate == firstEnd.addingTimeInterval(-30) && initial.pagesRead == 1)
            #expect(resumed.startDate == secondEnd.addingTimeInterval(-20) && resumed.pagesRead == 2)
            context.delete(history)
            try context.save()
        }
    }

    @Test(arguments: [false, true])
    func closeWhileSavingDeletesOnlyAfterSuccessfulAcknowledgment(saved: Bool) async throws {
        let restore = configureDefaults(deleteDownloads: true)
        defer { restore() }
        let probe = CompletionProbe()
        let reader = makeReader()
        var removed: [[ChapterIdentifier]] = []
        reader.historyCompletionWriter = { await probe.write($0) }
        reader.completedDownloadRemover = { removed.append($0) }
        reader.setCompleted()
        try await wait { probe.calls.count == 1 }
        // Exercise the same production close boundary without unrelated progress writes.
        reader.removeCompletedDownloadsAfterPendingHistory()
        reader.removeCompletedDownloadsAfterPendingHistory()
        for _ in 0..<10 { await Task.yield() }
        #expect(removed.isEmpty)
        #expect(UserDefaults.standard.object(forKey: "Data.chaptersToBeDeleted") == nil,
                "Uncommitted history must not queue persistent download deletion")
        probe.release(saved)
        if saved {
            try await wait { removed.count == 1 }
            #expect(removed[0].map(\.chapterKey) == ["chapter"])
        } else {
            for _ in 0..<20 { await Task.yield() }
            #expect(removed.isEmpty)
            try await wait { reader.setCompleted(); return probe.calls.count == 2 }
            probe.release(true)
            reader.removeCompletedDownloadsAfterPendingHistory()
            try await wait { removed.count == 1 }
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(removed.count == 1)
        #expect(UserDefaults.standard.object(forKey: "Data.chaptersToBeDeleted") == nil)
    }

    private func makeReader() -> ReaderViewController {
        let manga = AidokuRunner.Manga(sourceKey: "completion-audit", key: UUID().uuidString, title: "Audit")
        return ReaderViewController(source: nil, manga: manga, chapter: .init(key: "chapter"))
    }
    private func configureDefaults(deleteDownloads: Bool) -> () -> Void {
        let defaults = UserDefaults.standard
        let keys = ["General.incognitoMode", "Library.deleteDownloadAfterReading", "Data.chaptersToBeDeleted"]
        let saved = Dictionary(uniqueKeysWithValues: keys.compactMap { key in defaults.object(forKey: key).map { (key, $0) } })
        defaults.set(false, forKey: keys[0]); defaults.set(deleteDownloads, forKey: keys[1])
        defaults.removeObject(forKey: keys[2])
        return { for key in keys { if let value = saved[key] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
    }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() { try #require(ContinuousClock.now < deadline); await Task.yield() }
    }
}

@MainActor private final class CompletionProbe {
    var calls: [[String]] = []
    private var continuation: CheckedContinuation<Bool, Never>?
    func write(_ chapters: [AidokuRunner.Chapter]) async -> Bool {
        calls.append(chapters.map(\.key))
        return await withCheckedContinuation { continuation = $0 }
    }
    func release(_ success: Bool) {
        let value = continuation; continuation = nil; value?.resume(returning: success)
    }
}
