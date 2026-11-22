import AidokuRunner
import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized)
@MainActor
struct TranslatedDownloadTests {
    @Test func backgroundSuspensionRetainsTranslatedQueueAndManualPause() async throws {
        let savedQueue = UserDefaults.standard.data(forKey: "Data.downloadQueueState")
        defer { UserDefaults.standard.set(savedQueue, forKey: "Data.downloadQueueState") }
        let queue = DownloadQueue(cache: DownloadCache())
        let manga = AidokuRunner.Manga(sourceKey: "background-resume-test", key: UUID().uuidString, title: "Test")
        let chapter = AidokuRunner.Chapter(key: "chapter", title: "Chapter")
        _ = await queue.add(chapters: [chapter], manga: manga, autoStart: false, translatesImages: true)
        await queue.applicationDidEnterBackground()
        #expect(await queue.suspendedForBackground)
        #expect(await queue.hasQueuedDownloads())
        await queue.pause()
        await queue.applicationDidBecomeActive()
        #expect(await !queue.suspendedForBackground)
        #expect(await !queue.isRunning())
        #expect(await queue.hasQueuedDownloads())
        let restored = try #require(await queue.queue[manga.sourceKey]?.first)
        #expect(restored.translatesImages == true)
        await queue.cancelDownloads(for: [restored.chapterIdentifier])
    }

    @Test func translationChoiceSurvivesQueuePersistenceAndOldQueuesStillDecode() throws {
        var item = Download.from(manga: AidokuRunner.Manga(sourceKey: "test", key: "manga", title: "Test"),
                                 chapter: AidokuRunner.Chapter(key: "chapter", title: "Chapter"))
        item.translatesImages = true
        let encoded = try JSONEncoder().encode(item)
        let restored = try JSONDecoder().decode(Download.self, from: encoded)
        #expect(restored.translatesImages == true)
        #expect(restored.chapterIdentifier == item.chapterIdentifier)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "translatesImages")
        let legacy = try JSONDecoder().decode(Download.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.translatesImages != true)
    }
}
