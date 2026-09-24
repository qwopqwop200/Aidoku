import AidokuRunner
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderHistoryCompletionAcknowledgmentTests {
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
