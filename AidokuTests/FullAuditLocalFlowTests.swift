import AidokuRunner
import CryptoKit
import Foundation
import Testing
import UIKit
import ZIPFoundation
@testable import Aidoku

/// Opt-in, additive fixture import in an isolated audit simulator only.
/// Controller/service invocation is not a physical tap test. No network download is used.
/// Run again in a NEW app process with the same Documents directory to verify persistence.
@Suite(.serialized) @MainActor
struct FullAuditLocalFlowTests {
    @Test(.enabled(if: FileManager.default.fileExists(atPath:
        URL.documentsDirectory.appendingPathComponent("FullAuditLocalFlow/enabled").path)))
    func localArchiveThroughDisplayedReaderAndHistory() async throws {
        let defaults = UserDefaults.standard
        let disabledKeys = ["Reader.translation.automatic", "Reader.liveText", "Dictionary.enable",
                            "Reader.cropBorders", "Reader.downsampleImages", "Reader.upscaleImages"]
        let savedSettings = Dictionary(uniqueKeysWithValues: disabledKeys.compactMap { key in
            defaults.object(forKey: key).map { (key, $0) }
        })
        for key in disabledKeys { defaults.set(false, forKey: key) }
        defer {
            for key in disabledKeys {
                if let value = savedSettings[key] { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        let directory = URL.documentsDirectory.appendingPathComponent("FullAuditLocalFlow")
        let stateURL = directory.appendingPathComponent("state.json")
        let pid = ProcessInfo.processInfo.processIdentifier
        let previousState = (try? Data(contentsOf: stateURL)).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        let pass = (previousState?["pass"] as? Int ?? 0) + 1
        var rows: [[String: Any]] = []
        func record(_ row: [String: Any]) throws {
            rows.append(row)
            try JSONSerialization.data(withJSONObject: ["pid": pid, "pass": pass, "rows": rows,
                "scope": "Real local CBZ import, real DB and visible controllers; programmatic controls; no image processors, automatic translation, dictionary OCR or Live Text; no network download or mock",
                "restart": previousState == nil ? "pending separate process" : "checked below"], options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("evidence-\(pass).json"), options: .atomic)
        }
        try record(["phase": "start"])
        #expect(!AppSettings.general.incognitoMode.get())
        let archive = directory.appendingPathComponent("chapter.cbz")
        let archiveHash = SHA256.hash(data: try Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined()
        let zip = try Archive(url: archive, accessMode: .read)
        let entries = zip.filter { $0.type == .file && $0.path.lowercased().hasSuffix(".png")
            && !$0.path.split(separator: "/").contains(where: { $0.hasPrefix(".") || $0 == "__MACOSX" }) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        try #require(entries.count == 3, "Fixture contract: exactly three PNG pages")
        var goldens: [UIImage] = []
        for (index, entry) in entries.enumerated() {
            var data = Data()
            _ = try zip.extract(entry) { data.append($0) }
            goldens.append(try #require(UIImage(data: data)))
            try data.write(to: directory.appendingPathComponent("input-\(index + 1).png"), options: .atomic)
            try record(["phase": "input", "page": index + 1, "entry": entry.path,
                        "fileSHA256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()])
        }
        let title = "Full Audit Local Flow Fixture"
        let manga: AidokuRunner.Manga
        if let previousState {
            #expect(previousState["pid"] as? Int != Int(pid), "Root must relaunch the app process for restart verification")
            #expect(previousState["archiveSHA256"] as? String == archiveHash)
            let key = try #require(previousState["mangaKey"] as? String)
            manga = try #require(await LocalFileDataManager.shared.fetchLocalSeries(id: key))
        } else {
            #expect(await SourceManager.shared.ensureLocalSourceForImport())
            try await LocalFileManager.shared.uploadFile(from: archive, mangaName: title, chapterName: "Audit chapter", chapter: 1)
            manga = try #require(await LocalFileDataManager.shared.fetchLocalSeries(query: title).first(where: { $0.title == title }))
        }
        let chapters = await LocalFileDataManager.shared.fetchChapters(mangaId: manga.key)
        let chapter = try #require(chapters.first)
        let source = try #require(await SourceManager.shared.source(for: manga.sourceKey))
        let pages = try await source.getPageList(manga: manga, chapter: chapter)
        #expect(pages.count == 3)
        let identifier = ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: chapter.key)
        if previousState != nil {
            #expect(CoreDataManager.shared.getProgress(chapterId: identifier).completed)
            #expect(CoreDataManager.shared.hasLibraryManga(mangaId: manga.identifier, context: CoreDataManager.shared.context))
        }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let oldWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let host = UINavigationController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; oldWindow?.makeKey() }
        let details = MangaViewController(source: source, manga: manga, parent: host)
        host.setViewControllers([details], animated: false)
        try await Task.sleep(for: .milliseconds(500))
        try capture(window, to: directory.appendingPathComponent("details-\(pass).png"))
        await MangaManager.shared.addToLibrary(manga: manga, chapters: chapters)
        #expect(CoreDataManager.shared.hasLibraryManga(mangaId: manga.identifier, context: CoreDataManager.shared.context))
        let reader = ReaderViewController(source: source, manga: manga, chapter: chapter, startPage: 1)
        let navigation = ReaderNavigationController(readerViewController: reader)
        navigation.modalPresentationStyle = .fullScreen
        host.present(navigation, animated: false)
        var pageHashes: [String] = []
        for page in 1...3 {
            let started = ProcessInfo.processInfo.systemUptime
            let deadline = Date().addingTimeInterval(30)
            while (reader.reader == nil || reader.pages.filter { $0.type == .imagePage }.count != 3), Date() < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(reader.pages.filter { $0.type == .imagePage }.count == 3)
            let actualReader = try #require(reader.reader)
            actualReader.sliderMoved(value: CGFloat(page - 1) / 2)
            actualReader.sliderStopped(value: CGFloat(page - 1) / 2)
            let targetPage = try #require(reader.pages.filter { $0.type == .imagePage }.dropFirst(page - 1).first)
            var loaded: ReaderTranslationPage?
            while Date() < deadline {
                loaded = actualReader.translationPages().first {
                    $0.sourcePage?.translationCacheKey == targetPage.translationCacheKey
                        && $0.imageView?.image != nil && $0.imageView?.window != nil
                }
                if loaded != nil { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            let image = try #require(loaded?.imageView?.image, "Actual visible page did not load")
            let inputPixels = try pixels(goldens[page - 1])
            let shownPixels = try pixels(image)
            #expect(image.cgImage?.width == goldens[page - 1].cgImage?.width)
            #expect(image.cgImage?.height == goldens[page - 1].cgImage?.height)
            #expect(shownPixels == inputPixels, "Visible image must preserve exact decoded fixture pixels")
            let png = try #require(image.pngData())
            let hash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
            pageHashes.append(hash)
            try png.write(to: directory.appendingPathComponent("page-\(pass)-\(page).png"), options: .atomic)
            try capture(window, to: directory.appendingPathComponent("screen-\(pass)-\(page).png"))
            try record(["phase": "displayed", "page": page, "pngSHA256": hash, "width": image.size.width, "height": image.size.height,
                "displayMS": (ProcessInfo.processInfo.systemUptime - started) * 1000])
        }
        await reader.updateReadPosition(currentPage: 3, totalPages: 3)
        reader.setCompleted()
        let completionDeadline = Date().addingTimeInterval(10)
        while !CoreDataManager.shared.getProgress(chapterId: identifier).completed, Date() < completionDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(CoreDataManager.shared.getProgress(chapterId: identifier).completed)
        if let expected = previousState?["pageHashes"] as? [String] { #expect(pageHashes == expected) }
        try record(["phase": "history_saved", "completed": CoreDataManager.shared.getProgress(chapterId: identifier).completed])
        try JSONSerialization.data(withJSONObject: ["pid": pid, "pass": pass, "mangaKey": manga.key,
            "archiveSHA256": archiveHash, "pageHashes": pageHashes], options: [.prettyPrinted, .sortedKeys])
            .write(to: stateURL, options: .atomic)
        reader.close(animated: false)
    }

    private func pixels(_ image: UIImage) throws -> Data {
        let cg = try #require(image.cgImage)
        var bytes = Data(count: cg.width * cg.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        return bytes
    }

    private func capture(_ window: UIWindow, to url: URL) throws {
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try #require(image.pngData()).write(to: url, options: .atomic)
    }
}
