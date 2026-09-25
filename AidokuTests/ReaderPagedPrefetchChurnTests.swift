import AidokuRunner
import Foundation
import Testing
import UIKit
@testable import Aidoku

/// Actual paged reader navigation and displayed pixels, synthetic delayed Runner.
/// Programmatic navigation is intentionally separate from the actual CUA gesture test.
@Suite(.serialized) @MainActor
struct ReaderPagedPrefetchChurnTests {
    @Test(.enabled(if: FileManager.default.fileExists(atPath:
        URL.documentsDirectory.appendingPathComponent("ReaderPrefetchChurn/enabled").path)), arguments: [false, true])
    func repeatedTailNavigationDoesNotRestartSameChapterWork(exitAndReturn: Bool) async throws {
        let output = URL.documentsDirectory.appendingPathComponent("ReaderPrefetchChurn/\(UUID())")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let defaults = UserDefaults.standard
        let overrides: [String: Any] = ["Reader.pagesToPreload": 3, "Reader.pagedPageLayout": "single",
            "Reader.translation.automatic": false, "Reader.liveText": false, "Dictionary.enable": false,
            "Reader.cropBorders": false, "Reader.downsampleImages": false, "Reader.upscaleImages": false,
            "Reader.splitWideImages": false, "Reader.animatePageTransitions": false]
        let saved = Dictionary(uniqueKeysWithValues: overrides.keys.compactMap { k in defaults.object(forKey: k).map { (k, $0) } })
        for (key, value) in overrides { defaults.set(value, forKey: key) }
        defer { for key in overrides.keys { if let value = saved[key] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let sourceImage = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 64), format: format).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 64))
            UIColor.blue.setFill(); ctx.fill(CGRect(x: 4, y: 8, width: 20, height: 48))
        }
        let expectedRGBA = try rgba(sourceImage)
        let png = try #require(sourceImage.pngData())
        let inputs = (0..<5).map { output.appendingPathComponent("source-\($0).png") }
        for input in inputs { try png.write(to: input) }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let old = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil; old?.makeKey() }
        var rows: [[String: Any]] = []
        for iteration in 0..<5 {
            let counter = ChurnSourceCounter()
            let source = AidokuRunner.Source(url: nil, key: "churn-\(UUID())", name: "Churn", version: 1,
                languages: ["en"], contentRating: .safe, runner: ChurnRunner(counter: counter, inputs: inputs))
            let reader = ReaderPagedViewController(source: source,
                manga: .init(sourceKey: source.key, key: "book", title: "Book"), temporaryPageStore: ReaderTemporaryPageStore())
            let delegate = ChurnDelegate()
            reader.delegate = delegate; reader.readingMode = .ltr
            window.rootViewController = reader; window.makeKeyAndVisible()
            reader.loadViewIfNeeded(); reader.view.layoutIfNeeded()
            reader.chapter = .init(key: "origin")
            await reader.loadChapter(startPage: 1)
            try await wait { reader.currentPage == 1 && !reader.translationPages().isEmpty }
            reader.move(toPage: 3, animated: false)
            try await wait { await counter.starts >= 1 }
            if exitAndReturn {
                // Exit the entire bounded lookahead range while the list is suspended.
                reader.move(toPage: 1, animated: false)
                try await wait { let c = await counter.snapshot(); return c["cancelled"] == 1 && c["active"] == 0 }
                reader.move(toPage: 3, animated: false)
                try await wait { await counter.starts == 2 }
            }
            try await Task.sleep(for: .milliseconds(250))
            reader.move(toPage: 4, animated: false)
            try await Task.sleep(for: .milliseconds(250))
            reader.move(toPage: 5, animated: false)
            try await Task.sleep(for: .milliseconds(250))
            let adoption = ProcessInfo.processInfo.systemUptime
            reader.loadNextChapter()
            try await wait {
                reader.viewModel.chapter?.key == "next" && reader.viewModel.pages.count == 3 &&
                reader.translationPages().contains { $0.sourcePage?.chapterId == "next" && $0.imageView?.image != nil && $0.imageView?.window != nil }
            }
            try await Task.sleep(for: .milliseconds(34))
            let elapsed = (ProcessInfo.processInfo.systemUptime - adoption) * 1000
            let shown = try #require(reader.translationPages().first { $0.sourcePage?.chapterId == "next" }?.imageView?.image)
            let exactRGBA = try rgba(shown) == expectedRGBA
            #expect(exactRGBA)
            try #require(shown.pngData()).write(to: output.appendingPathComponent("displayed-\(iteration).png"))
            let counts = await counter.snapshot()
            rows.append(["iteration": iteration, "exitAndReturn": exitAndReturn, "counts": counts, "adoptionToVisibleMS": elapsed,
                         "pageOrder": reader.viewModel.pages.map { URL(string: $0.imageURL ?? "")?.lastPathComponent ?? "missing" }, "exactRGBA": exactRGBA])
            try JSONSerialization.data(withJSONObject: ["rows": rows,
                "scope": "Actual ReaderPagedViewController, controlled 1s delayed Runner, programmatic tail pages3/4/5 at250ms gaps then chapter handoff; no physical gesture/network/OCR/upscale. 34ms settle is not display callback proof."], options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("results.json"), options: .atomic)
            #expect(reader.viewModel.pages.map(\.imageURL) == Array(inputs.prefix(3)).map { $0.absoluteString })
            #expect(counts["active"] == 0)
            // Baseline n5 measured 3 starts / 2 cancellations; retaining identical work must remove both restarts.
            #expect(counts["starts"] == (exitAndReturn ? 2 : 1))
            #expect(counts["cancelled"] == (exitAndReturn ? 1 : 0))
            #expect(counts["maximumActive"] == 1)
            window.rootViewController = nil
        }
    }
    private func wait(_ predicate: @escaping () async -> Bool) async throws {
        for _ in 0..<1000 { if await predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
        try #require(await predicate())
    }
    private func rgba(_ image: UIImage) throws -> Data {
        let cg = try #require(image.cgImage); var data = Data(count: cg.width * cg.height * 4)
        try data.withUnsafeMutableBytes { b in
            let ctx = try #require(CGContext(data: b.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8,
                bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }; return data
    }
}
private actor ChurnSourceCounter {
    private(set) var starts = 0
    private var cancelled = 0
    private var active = 0
    private var maximumActive = 0
    func delay() async throws {
        starts += 1; active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        do { try await Task.sleep(for: .seconds(1)) }
        catch { cancelled += 1; throw error }
    }
    func snapshot() -> [String: Int] { ["starts": starts, "cancelled": cancelled, "active": active, "maximumActive": maximumActive] }
}
private final class ChurnRunner: AidokuRunner.Runner {
    let features = AidokuRunner.SourceFeatures()
    let counter: ChurnSourceCounter
    let inputs: [URL]
    init(counter: ChurnSourceCounter, inputs: [URL]) { self.counter = counter; self.inputs = inputs }
    func getSearchMangaList(query: String?, page: Int, filters: [AidokuRunner.FilterValue]) async throws -> AidokuRunner.MangaPageResult { .init(entries: [], hasNextPage: false) }
    func getMangaUpdate(manga: AidokuRunner.Manga, needsDetails: Bool, needsChapters: Bool) async throws -> AidokuRunner.Manga { manga }
    func getPageList(manga: AidokuRunner.Manga, chapter: AidokuRunner.Chapter) async throws -> [AidokuRunner.Page] {
        if chapter.key == "next" { try await counter.delay() }
        return inputs.prefix(chapter.key == "origin" ? 5 : 3).map { .init(content: .url(url: $0)) }
    }
}
@MainActor private final class ChurnDelegate: ReaderHoldingDelegate {
    let barsHidden = true
    private var chapter = "origin"
    func hideBars() {}
    func getNextChapter() -> AidokuRunner.Chapter? { chapter == "origin" ? .init(key: "next") : nil }
    func getPreviousChapter() -> AidokuRunner.Chapter? { nil }
    func setChapter(_ chapter: AidokuRunner.Chapter) { self.chapter = chapter.key }
    func setCurrentPage(_ page: Int, position: Double?) {}
    func setCurrentPages(_ pages: ClosedRange<Int>) {}
    func setPages(_ pages: [Aidoku.Page]) {}
    func displayPage(_ page: Int) {}
    func setSliderOffset(_ offset: CGFloat) {}
    func setCompleted() {}
}
