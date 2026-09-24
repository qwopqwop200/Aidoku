import AidokuRunner
import CryptoKit
import Foundation
import Testing
import UIKit
import ZIPFoundation
@testable import Aidoku

@Suite(.serialized) @MainActor
struct Round2DownloadedRestartTests {
    @Test(.enabled(if: FileManager.default.fileExists(atPath:
        URL.documentsDirectory.appendingPathComponent("Round2DownloadFlow/restart-enabled").path)))
    func downloadedPagesSurviveNewProcessWithSourceOffline() async throws {
#if targetEnvironment(simulator)
        let root = URL.documentsDirectory.appendingPathComponent("Round2DownloadFlow")
        let marker = try String(contentsOf: root.appendingPathComponent("restart-enabled"), encoding: .utf8)
        try #require(marker.trimmingCharacters(in: .whitespacesAndNewlines) == "dedicated-audit-simulator")
        let state = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("restart.json"))) as? [String: Any])
        let pid = ProcessInfo.processInfo.processIdentifier
        try #require(state["pid"] as? Int != Int(pid), "Must restart app process after download flow")
        let run = try #require(state["run"] as? String)
        let key = try #require(state["sourceKey"] as? String)
        let mangaKey = try #require(state["mangaKey"] as? String)
        let chapterKey = try #require(state["chapterKey"] as? String)
        let firstEvidence = root.appendingPathComponent(run)
        let evidence = firstEvidence.appendingPathComponent("restart-\(pid)")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        var rows: [[String: Any]] = []
        func record(_ row: [String: Any]) throws {
            rows.append(row)
            try JSONSerialization.data(withJSONObject: ["previousPID": state["pid"]!, "pid": pid, "rows": rows], options: [.prettyPrinted, .sortedKeys])
                .write(to: evidence.appendingPathComponent("evidence.json"), options: .atomic)
        }
        try record(["phase": "restart_begin"])
        let source = try #require(await SourceManager.shared.source(for: key))
        let identifier = ChapterIdentifier(sourceKey: key, mangaKey: mangaKey, chapterKey: chapterKey)
        let manga = try #require(CoreDataManager.shared.getManga(mangaId: identifier.mangaIdentifier)?.toNewManga())
        let chapter = try #require(CoreDataManager.shared.getChapter(chapterId: identifier, context: CoreDataManager.shared.context)?.toNewChapter())
        try #require(CoreDataManager.shared.hasLibraryManga(mangaId: manga.identifier, context: CoreDataManager.shared.context))
        try #require(DownloadManager.shared.isChapterDownloaded(chapter: identifier))
        let expectedBytes = try (1...3).map { try Data(contentsOf: firstEvidence.appendingPathComponent("expected-\($0).png")) }
        let saved = await DownloadManager.shared.getDownloadedPages(for: identifier)
        try #require(saved.count == 3)
        for (index, page) in saved.enumerated() {
            #expect(try pageData(page) == expectedBytes[index])
        }
        let base = try #require(URL(string: "http://127.0.0.1:18761/flow/\(run)/"))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        // Reassert offline after server restart; only this unique fixture scope changes.
        var offline = URLRequest(url: base.appendingPathComponent("offline"))
        offline.httpMethod = "POST"
        let (_, ack) = try await session.data(for: offline)
        try #require((ack as? HTTPURLResponse)?.statusCode == 200)
        let (_, rejected) = try await session.data(from: base.appendingPathComponent("api/v1/books/audit-book/pages/1"))
        try #require((rejected as? HTTPURLResponse)?.statusCode == 503)
        try record(["phase": "stored_files_and_library_restored", "sourceStatus": 503])
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
        try record(["phase": "restart_complete"])
#else
        Issue.record("Dedicated simulator only")
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
