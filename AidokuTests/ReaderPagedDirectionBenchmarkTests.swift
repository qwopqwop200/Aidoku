import AidokuRunner
import Foundation
import Nuke
import Testing
import UIKit
@testable import Aidoku

/// Copy this unchanged to the frozen baseline. Run alone because it swaps Nuke's
/// shared pipeline and reader defaults. No candidate-only APIs or speed assertions.
@Suite(.serialized) @MainActor
struct ReaderPagedDirectionBenchmarkTests {
    @Test func reverseNavigationWithDelayedImages() async throws {
        let defaults = UserDefaults.standard
        let settings: [String: Any] = ["Reader.pagesToPreload": 3, "Reader.pagedPageLayout": "single",
            "Reader.splitWideImages": false, "Reader.translation.automatic": false, "Reader.liveText": false,
            "Dictionary.enable": false, "Reader.upscaleImages": false, "Reader.cropBorders": false,
            "Reader.downsampleImages": false, "Reader.animatePageTransitions": false]
        let saved = settings.keys.reduce(into: [String: Any]()) { $0[$1] = defaults.object(forKey: $1) }
        settings.forEach { defaults.set($0.value, forKey: $0.key) }
        let originalPipeline = ImagePipeline.shared
        ImagePipeline.shared = ImagePipeline {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [PagedDirectionProtocol.self]
            $0.dataLoader = DataLoader(configuration: configuration)
            $0.imageCache = nil
            $0.dataCache = nil
        }
        defer {
            ImagePipeline.shared = originalPipeline
            for key in settings.keys {
                if let value = saved[key] { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        var rows: [[String: Any]] = []
        for iteration in 0..<5 {
            let run = UUID().uuidString
            let reader = ReaderPagedViewController(source: nil,
                manga: .init(sourceKey: "direction-benchmark", key: run, title: "Direction"),
                temporaryPageStore: ReaderTemporaryPageStore())
            let chapter = AidokuRunner.Chapter(key: run)
            reader.chapter = chapter
            reader.viewModel.pages = (0..<60).map { Page(sourceId: "direction-benchmark", chapterId: run,
                index: $0, imageURL: "https://paged-direction.invalid/\(run)/\($0 + 1).png") }
            reader.loadViewIfNeeded()
            reader.loadPageControllers(chapter: chapter)
            let pager = try #require(reader.children.compactMap { $0 as? UIPageViewController }.first)
            let controllers = reader.pageViewControllers
            func settle(_ page: Int) {
                let old = pager.viewControllers ?? []
                pager.setViewControllers([controllers[page]], direction: .forward, animated: false)
                reader.pageViewController(pager, didFinishAnimating: true, previousViewControllers: old, transitionCompleted: true)
            }
            func ready(_ page: Int) async throws {
                for _ in 0..<600 {
                    if controllers[page].pageView?.imageView.image != nil { return }
                    try await Task.sleep(for: .milliseconds(5))
                }
                try #require(controllers[page].pageView?.imageView.image != nil)
            }
            settle(1)
            try await ready(1)
            settle(40)
            try await ready(40)
            try await Task.sleep(for: .milliseconds(250))
            settle(39)
            try await Task.sleep(for: .milliseconds(250))
            let afterSingleReverse = controllers.enumerated().filter { $0.element.page != nil }.map(\.offset)
            settle(38)
            try await Task.sleep(for: .milliseconds(250))
            let afterSustainedReverse = controllers.enumerated().filter { $0.element.page != nil }.map(\.offset)
            let targetAlreadyReady = controllers[36].pageView?.imageView.image != nil
            settle(37)
            try await Task.sleep(for: .milliseconds(20))
            let begin = ProcessInfo.processInfo.systemUptime
            settle(36)
            try await ready(36)
            let targetReadyMS = (ProcessInfo.processInfo.systemUptime - begin) * 1000
            #expect(controllers[36].page?.index == 35)
            #expect(controllers[1].page == nil)
            #expect(afterSingleReverse.count <= 5)
            #expect(afterSustainedReverse.count <= 5)
            // Start fresh speculative work, then jump before its 200ms delay ends.
            settle(20)
            try await Task.sleep(for: .milliseconds(25))
            settle(55)
            try await ready(55)
            try await Task.sleep(for: .milliseconds(250))
            let counts = PagedDirectionProtocol.snapshot(run)
            rows.append(["iteration": iteration, "targetReadyMS": targetReadyMS,
                "targetAlreadyReady": targetAlreadyReady, "singleReverseResources": afterSingleReverse,
                "sustainedReverseResources": afterSustainedReverse, "requests": counts.starts,
                "cancellations": counts.cancels, "peakActive": counts.peak,
                "distantPageReleased": controllers[20].page == nil])
            controllers.forEach { $0.clearPage() }
        }
        let output = URL.documentsDirectory.appendingPathComponent("ReaderPagedDirectionBenchmark.json")
        try JSONSerialization.data(withJSONObject: ["rows": rows,
            "scope": "Actual paged controller and Nuke image pipeline, synthetic 200ms URLProtocol, 1px decoded images, no window/display callback, no WAN/OCR/upscale; 5ms readiness polling; shared pipeline caches disabled"], options: [.prettyPrinted, .sortedKeys])
            .write(to: output, options: .atomic)
        print("PAGED_DIRECTION_BENCHMARK \(output.path)")
    }
}

private final class PagedDirectionProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private struct Counts { var starts = 0; var cancels = 0; var active = 0; var peak = 0 }
    private static var counts: [String: Counts] = [:]
    private var pending: DispatchWorkItem?
    private var finished = false
    static func snapshot(_ run: String) -> (starts: Int, cancels: Int, peak: Int) {
        lock.lock(); defer { lock.unlock() }
        let count = counts[run] ?? Counts()
        return (count.starts, count.cancels, count.peak)
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "paged-direction.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let run = url.pathComponents[1]
        Self.lock.lock()
        var count = Self.counts[run] ?? Counts()
        count.starts += 1; count.active += 1; count.peak = max(count.peak, count.active)
        Self.counts[run] = count
        Self.lock.unlock()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Self.lock.lock()
            guard !self.finished else { Self.lock.unlock(); return }
            self.finished = true
            Self.counts[run]?.active -= 1
            Self.lock.unlock()
            let data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
            self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "image/png"])!, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        pending = work
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(200), execute: work)
    }
    override func stopLoading() {
        guard let url = request.url else { return }
        let run = url.pathComponents[1]
        Self.lock.lock()
        if !finished {
            finished = true
            Self.counts[run]?.cancels += 1
            Self.counts[run]?.active -= 1
        }
        Self.lock.unlock()
        pending?.cancel()
    }
}
