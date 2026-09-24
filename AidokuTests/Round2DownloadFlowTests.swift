import AidokuRunner
import CryptoKit
import Foundation
import Testing
import UIKit
import ZIPFoundation
@testable import Aidoku

/// Opt-in isolated-simulator flow: mock Komga HTTP server, real source runner,
/// DB/library, download queue, final files and visible offline reader.
/// Adds UUID-owned data only; deliberately leaves evidence and fixture records.
@Suite(.serialized) @MainActor
struct Round2DownloadFlowTests {
    @Test(.enabled(if: FileManager.default.fileExists(atPath:
        URL.documentsDirectory.appendingPathComponent("Round2DownloadFlow/enabled").path)))
    func komgaToDownloadedOfflineDisplay() async throws {
#if targetEnvironment(simulator)
        let root = URL.documentsDirectory.appendingPathComponent("Round2DownloadFlow")
        let marker = try String(contentsOf: root.appendingPathComponent("enabled"), encoding: .utf8)
        try #require(marker.trimmingCharacters(in: .whitespacesAndNewlines) == "dedicated-audit-simulator")
        let run = UUID().uuidString
        let evidence = root.appendingPathComponent(run)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let base = try #require(URL(string: "http://127.0.0.1:18761/flow/\(run)/"))
        var rows: [[String: Any]] = []
        func record(_ row: [String: Any]) throws {
            rows.append(row)
            try JSONSerialization.data(withJSONObject: ["scope": "Mock Komga server; real application source, DB, queue, disk and reader; programmatic controls", "run": run, "rows": rows], options: [.prettyPrinted, .sortedKeys])
                .write(to: evidence.appendingPathComponent("evidence.json"), options: .atomic)
        }
        try record(["phase": "start", "pid": ProcessInfo.processInfo.processIdentifier])
        let key = try #require(await SourceManager.shared.createCustomSource(.komga(.init(
            name: "Full Audit Download \(run)", server: base, username: "fixture", password: "fixture"))))
        let source = try #require(await SourceManager.shared.source(for: key))
        let search = try await source.getSearchMangaList(query: "Full Audit", page: 1, filters: [])
        #expect(search.entries.count == 1)
        #expect(!search.hasNextPage)
        let initial = try #require(search.entries.first)
        let manga = try await source.getMangaUpdate(manga: initial, needsDetails: true, needsChapters: true)
        #expect(manga.title == "Full Audit Download Fixture")
        let chapters = try #require(manga.chapters)
        #expect(chapters.count == 1)
        let chapter = try #require(chapters.first)
        let pages = try await source.getPageList(manga: manga, chapter: chapter)
        #expect(pages.count == 3)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var expectedBytes: [Data] = []
        for (index, page) in pages.enumerated() {
            guard case .url(let url, _) = page.content else {
                Issue.record("Expected URL page from actual Komga runner")
                return
            }
            #expect(url.lastPathComponent == String(index + 1))
            let (bytes, response) = try await session.data(from: url)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(UIImage(data: bytes) != nil)
            expectedBytes.append(bytes)
            try bytes.write(to: evidence.appendingPathComponent("expected-\(index + 1).png"))
        }
        #expect(Set(expectedBytes.map(digest)).count == 3)
        await MangaManager.shared.addToLibrary(manga: manga, chapters: chapters)
        #expect(CoreDataManager.shared.hasLibraryManga(mangaId: manga.identifier, context: CoreDataManager.shared.context))
        try record(["phase": "source_and_library", "sourceKey": key, "pages": pages.count, "expectedSHA256": expectedBytes.map(digest)])
        do {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let oldWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let host = UINavigationController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; oldWindow?.makeKey() }
        let details = MangaViewController(source: source, manga: manga, parent: host)
        host.setViewControllers([details], animated: false)
        let reader = ReaderViewController(source: source, manga: manga, chapter: chapter, startPage: 1)
        let navigation = ReaderNavigationController(readerViewController: reader)
        navigation.modalPresentationStyle = .fullScreen
        host.present(navigation, animated: false)
        defer { reader.close(animated: false) }
        for page in 1...3 {
            let displayStart = ProcessInfo.processInfo.systemUptime
            let displayDeadline = Date().addingTimeInterval(30)
            while (reader.reader == nil || reader.pages.filter { $0.type == .imagePage }.count != 3), Date() < displayDeadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            let actualReader = try #require(reader.reader)
            actualReader.sliderMoved(value: CGFloat(page - 1) / 2)
            actualReader.sliderStopped(value: CGFloat(page - 1) / 2)
            let targetPage = try #require(reader.pages.filter { $0.type == .imagePage }.dropFirst(page - 1).first)
            var loaded: ReaderTranslationPage?
            while Date() < displayDeadline {
                loaded = actualReader.translationPages().first {
                    $0.sourcePage?.translationCacheKey == targetPage.translationCacheKey
                        && $0.imageView?.image != nil && $0.imageView?.window != nil
                }
                if loaded != nil { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            let image = try #require(loaded?.imageView?.image, "Online visible image did not load")
            let png = try #require(image.pngData())
            let expectedPNG = try #require(UIImage(data: expectedBytes[page - 1])?.pngData())
            #expect(png == expectedPNG, "Actual reader decoded image differs from source fixture")
            try png.write(to: evidence.appendingPathComponent("online-displayed-\(page).png"))
            window.layoutIfNeeded()
            let screen = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try #require(screen.pngData()).write(to: evidence.appendingPathComponent("online-screen-\(page).png"))
            try record(["phase": "online_display", "page": page, "pngSHA256": digest(png),
                "width": image.size.width, "height": image.size.height,
                "displayMS": (ProcessInfo.processInfo.systemUptime - displayStart) * 1000])
        }
        }
        // Preserve global Wi-Fi, compression and translation policies. A paused or
        // unsupported environment fails visibly instead of weakening admission.
        let identifier = ChapterIdentifier(sourceKey: key, mangaKey: manga.key, chapterKey: chapter.key)
        let started = ProcessInfo.processInfo.systemUptime
        await DownloadManager.shared.download(manga: manga, chapters: [chapter], translatesImages: false)
        let deadline = Date().addingTimeInterval(90)
        while !DownloadManager.shared.isChapterDownloaded(chapter: identifier), Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(DownloadManager.shared.isChapterDownloaded(chapter: identifier), "Queue did not finish within bounded deadline; inspect Wi-Fi/pause/status without changing policy")
        let saved = await DownloadManager.shared.getDownloadedPages(for: identifier)
        try #require(saved.count == 3)
        var savedHashes: [String] = []
        for (index, page) in saved.enumerated() {
            let bytes = try pageData(page)
            #expect(bytes == expectedBytes[index], "Downloaded bytes/order differ")
            #expect(UIImage(data: bytes) != nil)
            savedHashes.append(digest(bytes))
            try bytes.write(to: evidence.appendingPathComponent("downloaded-\(index + 1).png"))
        }
        let cache = DownloadCache()
        let folder = cache.directory(for: identifier)
        let archive = folder.appendingPathExtension("cbz")
        let finalURL = FileManager.default.fileExists(atPath: archive.path) ? archive : folder
        let metadata = try #require(DownloadedChapterFile.comicInfo(in: finalURL))
        #expect(metadata.series == manga.title)
        #expect(metadata.title == chapter.title)
        #expect(DownloadedChapterFile.pageCount(in: finalURL) == 3)
        try record(["phase": "download_committed", "finalPath": finalURL.path, "sha256": savedHashes,
            "elapsedMS": (ProcessInfo.processInfo.systemUptime - started) * 1000,
            "compressed": finalURL.pathExtension == "cbz"])
        var offlineRequest = URLRequest(url: base.appendingPathComponent("offline"))
        offlineRequest.httpMethod = "POST"
        let (_, offlineResponse) = try await session.data(for: offlineRequest)
        #expect((offlineResponse as? HTTPURLResponse)?.statusCode == 200)
        let (_, rejected) = try await session.data(from: base.appendingPathComponent("api/v1/books/audit-book/pages/1"))
        #expect((rejected as? HTTPURLResponse)?.statusCode == 503)
        try record(["phase": "mock_source_offline_confirmed", "status": 503])
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let oldWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let host = UINavigationController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; oldWindow?.makeKey() }
        let details = MangaViewController(source: source, manga: manga, parent: host)
        host.setViewControllers([details], animated: false)
        let reader = ReaderViewController(source: source, manga: manga, chapter: chapter, startPage: 1)
        let navigation = ReaderNavigationController(readerViewController: reader)
        navigation.modalPresentationStyle = .fullScreen
        host.present(navigation, animated: false)
        defer { reader.close(animated: false) }
        for page in 1...3 {
            let displayStart = ProcessInfo.processInfo.systemUptime
            let displayDeadline = Date().addingTimeInterval(30)
            while (reader.reader == nil || reader.pages.filter { $0.type == .imagePage }.count != 3), Date() < displayDeadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            let actualReader = try #require(reader.reader)
            actualReader.sliderMoved(value: CGFloat(page - 1) / 2)
            actualReader.sliderStopped(value: CGFloat(page - 1) / 2)
            let targetPage = try #require(reader.pages.filter { $0.type == .imagePage }.dropFirst(page - 1).first)
            var loaded: ReaderTranslationPage?
            while Date() < displayDeadline {
                loaded = actualReader.translationPages().first {
                    $0.sourcePage?.translationCacheKey == targetPage.translationCacheKey
                        && $0.imageView?.image != nil && $0.imageView?.window != nil
                }
                if loaded != nil { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            let image = try #require(loaded?.imageView?.image, "Offline visible image did not load")
            let png = try #require(image.pngData())
            let expectedPNG = try #require(UIImage(data: expectedBytes[page - 1])?.pngData())
            #expect(png == expectedPNG, "Actual reader decoded image differs from source fixture")
            try png.write(to: evidence.appendingPathComponent("displayed-\(page).png"))
            window.layoutIfNeeded()
            let screen = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try #require(screen.pngData()).write(to: evidence.appendingPathComponent("screen-\(page).png"))
            try record(["phase": "offline_display", "page": page, "pngSHA256": digest(png),
                "width": image.size.width, "height": image.size.height,
                "displayMS": (ProcessInfo.processInfo.systemUptime - displayStart) * 1000])
        }
        try record(["phase": "complete", "sourceKey": key, "mangaKey": manga.key, "chapterKey": chapter.key])
        try JSONSerialization.data(withJSONObject: ["run": run, "pid": ProcessInfo.processInfo.processIdentifier,
            "sourceKey": key, "mangaKey": manga.key, "chapterKey": chapter.key], options: [.sortedKeys])
            .write(to: root.appendingPathComponent("restart.json"), options: .atomic)
#else
        Issue.record("This additive fixture harness is restricted to a dedicated simulator")
#endif
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func pageData(_ page: AidokuRunner.Page) throws -> Data {
        switch page.content {
        case .url(let url, _):
            try #require(url.isFileURL)
            return try Data(contentsOf: url)
        case .zipFile(let url, let path):
            let archive = try Archive(url: url, accessMode: .read)
            let entry = try #require(archive[path])
            var bytes = Data()
            _ = try archive.extract(entry) { bytes.append($0) }
            return bytes
        default:
            throw NSError(domain: "Round2DownloadFlow", code: 1)
        }
    }
}
