import AidokuRunner
import Foundation
import UIKit
import Testing
@testable import Aidoku

@Suite(.serialized)
@MainActor
struct TranslatedDownloadTests {
    private func download() -> Download {
        .from(manga: AidokuRunner.Manga(sourceKey: "test", key: "manga", title: "Test"),
              chapter: AidokuRunner.Chapter(key: "chapter", title: "Chapter"))
    }

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

    @Test func originalDownloadSuspendsWithoutBackgroundExecutionGrant() async throws {
        let savedQueue = UserDefaults.standard.data(forKey: "Data.downloadQueueState")
        defer { UserDefaults.standard.set(savedQueue, forKey: "Data.downloadQueueState") }
        let queue = DownloadQueue(cache: DownloadCache())
        let manga = AidokuRunner.Manga(sourceKey: "background-original-test", key: UUID().uuidString, title: "Test")
        _ = await queue.add(chapters: [.init(key: "chapter", title: "Chapter")], manga: manga, autoStart: false)
        await queue.applicationDidEnterBackground()
        #expect(await queue.suspendedForBackground)
        let item = try #require(await queue.queue[manga.sourceKey]?.first)
        await queue.cancelDownloads(for: [item.chapterIdentifier])
    }

    @Test(arguments: [false, true])
    func foregroundRestartsSuspendedWorkerWithoutBackgroundGrant(translatesImages: Bool) async throws {
        let wifiOnly = AppSettings.downloads.downloadOnlyOnWifi.get()
        AppSettings.downloads.downloadOnlyOnWifi.set(false)
        defer { AppSettings.downloads.downloadOnlyOnWifi.set(wifiOnly) }
        let savedQueue = UserDefaults.standard.data(forKey: "Data.downloadQueueState")
        defer { UserDefaults.standard.set(savedQueue, forKey: "Data.downloadQueueState") }
        let queue = DownloadQueue(cache: DownloadCache())
        let manga = AidokuRunner.Manga(sourceKey: "missing-background-resume-test", key: UUID().uuidString, title: "Test")
        _ = await queue.add(chapters: [.init(key: "chapter", title: "Chapter")], manga: manga, autoStart: false, translatesImages: translatesImages)
        await queue.applicationDidEnterBackground()
        #expect(await queue.hasQueuedDownloads())
        await queue.applicationDidBecomeActive()
        // A resumed worker processes even an unavailable source, draining its
        // entry. Merely clearing the suspension flag leaves this queue stuck.
        for _ in 0..<100 {
            if await !queue.hasQueuedDownloads() { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await !queue.hasQueuedDownloads())
        #expect(await !queue.suspendedForBackground)
    }

    @Test(arguments: [false, true])
    func wifiRecoveryPreservesManualPause(manuallyPaused: Bool) async throws {
        let savedQueue = UserDefaults.standard.data(forKey: "Data.downloadQueueState")
        let wifiOnly = AppSettings.downloads.downloadOnlyOnWifi.get()
        defer {
            UserDefaults.standard.set(savedQueue, forKey: "Data.downloadQueueState")
            AppSettings.downloads.downloadOnlyOnWifi.set(wifiOnly)
        }
        AppSettings.downloads.downloadOnlyOnWifi.set(true)
        let queue = DownloadQueue(cache: DownloadCache())
        await queue.setWifiAvailable(false)
        let manga = AidokuRunner.Manga(sourceKey: "missing-network-resume-test", key: UUID().uuidString, title: "Test")
        let items = await queue.add(chapters: [.init(key: "chapter", title: "Chapter")], manga: manga)
        if manuallyPaused { await queue.pause() }
        await queue.applicationDidEnterBackground()
        await queue.applicationDidBecomeActive()
        #expect(await queue.hasQueuedDownloads())
        #expect(await !queue.isRunning())
        await queue.setWifiAvailable(true)
        if manuallyPaused {
            #expect(await !queue.isRunning())
            #expect(await queue.hasQueuedDownloads())
            // Explicit user resume still starts the ordinary queue.
            await queue.resume()
        }
        for _ in 0..<100 {
            if await !queue.hasQueuedDownloads() { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await !queue.hasQueuedDownloads())
        for item in items { DownloadManager.directory.appendingPathComponent(item.chapterIdentifier.sourceKey).removeItem() }
    }

    @Test func wifiReturnInBackgroundWaitsForForeground() async throws {
        let savedQueue = UserDefaults.standard.data(forKey: "Data.downloadQueueState")
        let wifiOnly = AppSettings.downloads.downloadOnlyOnWifi.get()
        defer {
            UserDefaults.standard.set(savedQueue, forKey: "Data.downloadQueueState")
            AppSettings.downloads.downloadOnlyOnWifi.set(wifiOnly)
        }
        AppSettings.downloads.downloadOnlyOnWifi.set(true)
        let queue = DownloadQueue(cache: DownloadCache())
        await queue.setWifiAvailable(false)
        let manga = AidokuRunner.Manga(sourceKey: "missing-background-wifi-test", key: UUID().uuidString, title: "Test")
        let items = await queue.add(chapters: [.init(key: "chapter", title: "Chapter")], manga: manga)
        await queue.applicationDidEnterBackground()
        await queue.setWifiAvailable(true)
        #expect(await queue.suspendedForBackground)
        #expect(await !queue.isRunning())
        await queue.applicationDidBecomeActive()
        for _ in 0..<100 {
            if await !queue.hasQueuedDownloads() { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await !queue.hasQueuedDownloads())
        for item in items { DownloadManager.directory.appendingPathComponent(item.chapterIdentifier.sourceKey).removeItem() }
    }

    @Test func translationChoiceSurvivesQueuePersistence() throws {
        var item = download()
        item.translatesImages = true
        let restored = try JSONDecoder().decode(Download.self, from: JSONEncoder().encode(item))
        #expect(restored.translatesImages == true)
        #expect(restored.chapterIdentifier == item.chapterIdentifier)
    }

    @Test func oldQueueWithoutTranslationFieldStillDecodesAsOriginalDownload() throws {
        let encoded = try JSONEncoder().encode(download())
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "translatesImages")
        let restored = try JSONDecoder().decode(Download.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(restored.translatesImages != true)
    }

    @Test func cancelledTranslationDoesNotWaitForAWindowOrStartOCR() async {
        let operation = Task {
            // Cancellation must be checked before touching a window or OCR models.
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DownloadImageTranslator.translate(Data(), settings: ReaderTranslationSettings())
        }
        do {
            _ = try await operation.value
            Issue.record("Cancelled download unexpectedly produced an image")
        } catch is CancellationError {
            // Expected: no unstructured OCR/export work outlives the download.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func downloadEncodesTranslatedPixelsAndPropagatesProviderFailure() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let original = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
        }
        let input = try #require(original.pngData())
        let translated = try await DownloadImageTranslator.translate(input, settings: ReaderTranslationSettings()) { _, _ in
            [ReaderTranslationRegion(id: "download", rect: CGRect(x: 0.15, y: 0.25, width: 0.7, height: 0.2),
                source: "Hello", translation: "다운로드한 번역 이미지입니다.")]
        }
        let decoded = try #require(UIImage(data: translated))
        #expect(decoded.size == original.size)
        #expect(translated.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]))
        let before = try #require(original.cgImage?.dataProvider?.data) as Data
        let after = try #require(decoded.cgImage?.dataProvider?.data) as Data
        #expect(before != after)
        enum ProviderFailure: Error { case unavailable }
        do {
            _ = try await DownloadImageTranslator.translate(input, settings: ReaderTranslationSettings()) { _, _ in
                throw ProviderFailure.unavailable
            }
            Issue.record("Provider failure must not save the original as a translated download")
        } catch ProviderFailure.unavailable {
            // The download task receives this error and marks the page failed.
        }
    }

}
