import AidokuRunner
import Foundation
import Nuke
import Testing
import UIKit
@testable import Aidoku

/// Opt-in diagnostic against a COPY of a saved database/source installation.
/// Run twice in separate app processes; keep disk cache, discard memory cache.
@Suite(.serialized) @MainActor
struct ColdLaunchImageProbeTests {
    @Test(.enabled(if: FileManager.default.fileExists(atPath:
        URL.documentsDirectory.appendingPathComponent("ColdLaunchProbe/enabled").path)))
    func coldProcessHistoryAndReader() async throws {
        let directory = URL.documentsDirectory.appendingPathComponent("ColdLaunchProbe")
        let pass = ((try? String(contentsOf: directory.appendingPathComponent("pass"), encoding: .utf8))
            .flatMap { Int($0) } ?? 0) + 1
        var rows: [[String: Any]] = []
        func save() throws {
            try JSONSerialization.data(withJSONObject: ["pass": pass, "pid": ProcessInfo.processInfo.processIdentifier,
                "rows": rows], options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("pass-\(pass).json"), options: .atomic)
        }
        func elapsed(_ start: TimeInterval) -> Double { (ProcessInfo.processInfo.systemUptime - start) * 1000 }
        let begin = ProcessInfo.processInfo.systemUptime
        let historyID = try #require(await CoreDataManager.shared.container.performBackgroundTask { context in
            CoreDataManager.shared.getRecentHistory(limit: 1, offset: 0, context: context).first?.identifier
        })
        let model = HistoryView.ViewModel()
        await model.loadMore()
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("expect-metadata-hit").path) {
            #expect(model.mangaCache[historyID.mangaIdentifier]?.cover != nil)
            #expect(model.chapterCache[historyID] != nil)
        }
        rows.append(["phase": "history_local_load", "ms": elapsed(begin), "mangaReady": model.mangaCache.count])
        try save()
        let deadline = Date().addingTimeInterval(90)
        while model.mangaCache[historyID.mangaIdentifier]?.cover == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        rows.append(["phase": "history_target_metadata_ready", "ms_since_history_start": elapsed(begin),
                     "mangaReady": model.mangaCache.count])
        try save()
        let manga = try #require(model.mangaCache[historyID.mangaIdentifier])
        let cover = try #require(manga.cover.flatMap(URL.init(string:)))
        let metrics = ColdImageMetrics()
        let original = ImagePipeline.shared
        var configuration = original.configuration
        configuration.dataLoader = ColdImageLoader(base: configuration.dataLoader, metrics: metrics)
        if let cache = configuration.dataCache { configuration.dataCache = ColdImageCache(base: cache, metrics: metrics) }
        let makeDecoder = configuration.makeImageDecoder
        configuration.makeImageDecoder = { context in
            makeDecoder(context).map { ColdImageDecoder(base: $0, metrics: metrics) }
        }
        let pipeline = ImagePipeline(configuration: configuration, delegate: UIApplication.shared.delegate as? AppDelegate)
        ImagePipeline.shared = pipeline
        defer { ImagePipeline.shared = original; pipeline.invalidate() }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }

        func sample(_ label: String, request: ImageRequest, readerPage: Aidoku.Page? = nil) async throws {
            metrics.reset()
            var request = request
            request.processors = request.processors.map { ColdImageProcessor(base: $0, metrics: metrics) }
            let start = ProcessInfo.processInfo.systemUptime
            let response: ImageResponse
            do {
                response = try await pipeline.imageTask(with: request).response
            } catch {
                var row: [String: Any] = metrics.snapshot()
                row["phase"] = label
                row["pipeline_ms"] = elapsed(start)
                row["error"] = String(describing: error)
                rows.append(row)
                try save()
                throw error
            }
            let pipelineMS = elapsed(start)
            let displayStart = ProcessInfo.processInfo.systemUptime
            if var page = readerPage {
                page.image = response.image
                let view = ReaderPageView(parent: host, temporaryPageStore: ReaderTemporaryPageStore())
                view.frame = host.view.bounds
                host.view.addSubview(view)
                #expect(await view.setPage(page, skipProcessing: true))
                view.layoutIfNeeded()
                try await ColdImageFrames.wait()
                #expect(view.imageView.image != nil)
                view.releasePageResources()
                view.removeFromSuperview()
            } else {
                let view = UIImageView(image: response.image)
                view.frame = CGRect(x: 20, y: 100, width: 56, height: 84)
                view.contentMode = .scaleAspectFill
                host.view.addSubview(view)
                try await ColdImageFrames.wait()
                view.removeFromSuperview()
            }
            var row: [String: Any] = metrics.snapshot()
            row["phase"] = label
            row["pipeline_ms"] = pipelineMS
            row["attach_plus_two_frames_ms"] = elapsed(displayStart)
            row["cache_type"] = String(describing: response.cacheType)
            row["pixel_width"] = response.image.cgImage?.width
            row["pixel_height"] = response.image.cgImage?.height
            rows.append(row)
            print("COLD_IMAGE_PROBE \(label) \(row)")
            try save()
        }
        let coverRequest = ImageRequest(url: cover, processors: [DownsampleProcessor(width: 56)])
        do {
            try await sample("cover_first_after_process_start", request: coverRequest)
            try await sample("cover_same_process_repeat", request: coverRequest)
        } catch { print("COLD_IMAGE_PROBE raw history cover failed") }
        let sourceStart = ProcessInfo.processInfo.systemUptime
        let source = try #require(await SourceManager.shared.source(for: historyID.sourceKey))
        rows.append(["phase": "source_ready", "ms": elapsed(sourceStart),
                     "coverHost": cover.host ?? "", "processesCovers": source.features.processesCovers])
        let modifiedCover = await source.getModifiedImageRequest(url: cover, context: nil)
        var coverProcessors: [any ImageProcessing] = [DownsampleProcessor(width: 56)]
        if source.features.processesCovers { coverProcessors.append(CoverInterceptorProcessor(source: source)) }
        let correctedCoverRequest = ImageRequest(urlRequest: modifiedCover, processors: coverProcessors,
            userInfo: [.processesKey: source.features.processesCovers])
        do {
            try await sample("cover_with_source_request", request: correctedCoverRequest)
            try await sample("cover_with_source_repeat", request: correctedCoverRequest)
        } catch { print("COLD_IMAGE_PROBE source-aware cover failed") }
        // Bypass both caches to distinguish missing source headers from a
        // transient server error; these are diagnostic requests, never app code.
        for attempt in 1...2 {
            var raw = coverRequest
            raw.options.formUnion([.disableDiskCache, .disableMemoryCache])
            var corrected = correctedCoverRequest
            corrected.options.formUnion([.disableDiskCache, .disableMemoryCache])
            do { try await sample("cover_raw_network_control_\(attempt)", request: raw) }
            catch { print("COLD_IMAGE_PROBE raw control failed") }
            try await sample("cover_corrected_network_control_\(attempt)", request: corrected)
        }
        let chapter = try #require(model.chapterCache[historyID])
        let pagesStart = ProcessInfo.processInfo.systemUptime
        let readerModel = ReaderPagedViewModel(source: source, manga: manga)
        await readerModel.loadPages(chapter: chapter)
        rows.append(["phase": "reader_page_list", "ms": elapsed(pagesStart), "pages": readerModel.pages.count])
        try save()
        let page = try #require(readerModel.pages.first)
        let url = try #require(page.imageURL.flatMap(URL.init(string:)))
        let requestStart = ProcessInfo.processInfo.systemUptime
        let pageRequest = await ReaderPageView.imageRequest(url: url, context: page.context, source: source)
        rows.append(["phase": "reader_request_preparation", "ms": elapsed(requestStart)])
        try await sample("reader_first_after_process_start", request: pageRequest, readerPage: page)
        try await sample("reader_same_process_repeat", request: pageRequest, readerPage: page)
        // Include the real controller's chapter-sized view construction and
        // bounded neighbor loading, not just a stand-alone UIImageView.
        let controllerStart = ProcessInfo.processInfo.systemUptime
        let reader = ReaderPagedViewController(source: source, manga: manga, temporaryPageStore: ReaderTemporaryPageStore())
        reader.viewModel.preloadedChapter = chapter
        reader.viewModel.preloadedPages = readerModel.pages
        window.rootViewController = reader
        reader.setChapter(chapter, startPage: 1)
        let presentationDeadline = Date().addingTimeInterval(20)
        while reader.pageViewControllers.first(where: { $0.page?.index == page.index })?.pageView?.imageView.image == nil,
              Date() < presentationDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let displayed = reader.pageViewControllers.first(where: { $0.page?.index == page.index })?.pageView?.imageView.image != nil
        #expect(displayed)
        try await ColdImageFrames.wait()
        rows.append(["phase": "actual_paged_controller_first_image", "ms": elapsed(controllerStart),
                     "controllers": reader.pageViewControllers.count, "displayed": displayed,
                     "scope": "page list already fetched; includes controller construction, cached image load and two display frames"])
        window.rootViewController = host
        try save()
        if let cache = original.configuration.dataCache as? DataCache { cache.flush() }
        try String(pass).write(to: directory.appendingPathComponent("pass"), atomically: true, encoding: .utf8)
        try save()
    }
}

private final class ColdImageMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Double] = [:]
    func add(_ key: String, _ value: Double) {
        lock.lock(); defer { lock.unlock() }
        values[key, default: 0] += value
    }
    func reset() { lock.lock(); values = [:]; lock.unlock() }
    func snapshot() -> [String: Double] { lock.lock(); defer { lock.unlock() }; return values }
}
private struct ColdImageLoader: DataLoading {
    let base: any DataLoading
    let metrics: ColdImageMetrics
    func loadData(with request: URLRequest, didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
                  completion: @escaping @Sendable (Error?) -> Void) -> any Cancellable {
        let start = ProcessInfo.processInfo.systemUptime
        metrics.add("network_requests", 1)
        return base.loadData(with: request, didReceiveData: { data, response in
            metrics.add("network_bytes", Double(data.count)); didReceiveData(data, response)
        }, completion: { error in
            metrics.add("network_ms", (ProcessInfo.processInfo.systemUptime - start) * 1000); completion(error)
        })
    }
}
private struct ColdImageCache: DataCaching {
    let base: any DataCaching
    let metrics: ColdImageMetrics
    func cachedData(for key: String) -> Data? {
        let start = ProcessInfo.processInfo.systemUptime
        let data = base.cachedData(for: key)
        metrics.add("disk_lookup_ms", (ProcessInfo.processInfo.systemUptime - start) * 1000)
        metrics.add(data == nil ? "disk_misses" : "disk_hits", 1)
        return data
    }
    func containsData(for key: String) -> Bool { base.containsData(for: key) }
    func storeData(_ data: Data, for key: String) { base.storeData(data, for: key) }
    func removeData(for key: String) { base.removeData(for: key) }
    func removeAll() { base.removeAll() }
}
private struct ColdImageDecoder: ImageDecoding {
    let base: any ImageDecoding
    let metrics: ColdImageMetrics
    var isAsynchronous: Bool { base.isAsynchronous }
    func decode(_ data: Data) throws -> ImageContainer {
        let start = ProcessInfo.processInfo.systemUptime
        defer { metrics.add("decoder_ms", (ProcessInfo.processInfo.systemUptime - start) * 1000) }
        return try base.decode(data)
    }
    func decodePartiallyDownloadedData(_ data: Data) -> ImageContainer? { base.decodePartiallyDownloadedData(data) }
}
private struct ColdImageProcessor: ImageProcessing {
    let base: any ImageProcessing
    let metrics: ColdImageMetrics
    var identifier: String { base.identifier }
    func process(_ image: PlatformImage) -> PlatformImage? { base.process(image) }
    func process(_ container: ImageContainer, context: ImageProcessingContext) throws -> ImageContainer {
        let start = ProcessInfo.processInfo.systemUptime
        defer { metrics.add("processor_ms", (ProcessInfo.processInfo.systemUptime - start) * 1000) }
        return try base.process(container, context: context)
    }
}
@MainActor private final class ColdImageFrames: NSObject {
    private var continuation: CheckedContinuation<Void, Never>?
    private var link: CADisplayLink?
    private var frames = 0
    static func wait() async {
        let observer = ColdImageFrames()
        await withCheckedContinuation { continuation in
            observer.continuation = continuation
            observer.link = CADisplayLink(target: observer, selector: #selector(tick))
            observer.link?.add(to: .main, forMode: .common)
        }
    }
    @objc private func tick() {
        frames += 1
        if frames >= 2 { link?.invalidate(); link = nil; continuation?.resume(); continuation = nil }
    }
}
