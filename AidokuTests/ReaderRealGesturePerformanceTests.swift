import AidokuRunner
import CryptoKit
import Foundation
import Testing
import UIKit
@testable import Aidoku

// Root installs this test only in its frozen audit variants. Actual gestures are supplied
// by Simulator CUA while ready.json exists. No programmatic page/scroll API is invoked.
@Suite(.serialized) @MainActor
struct ReaderRealGesturePerformanceTests {
    @Test(.enabled(if: FileManager.default.fileExists(atPath:
        URL.documentsDirectory.appendingPathComponent("ReaderRealGesture/enabled").path)))
    func actualReaderGestures() async throws {
        let root = URL.documentsDirectory.appendingPathComponent("ReaderRealGesture")
        let mode = try String(contentsOf: root.appendingPathComponent("enabled"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try #require(["ltr", "webtoon"].contains(mode))
        let out = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        var urls: [URL] = []
        var expected: [Int: Data] = [:]
        for index in 0..<8 {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 720), format: format).image { context in
                UIColor(white: 1, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 0, width: 320, height: 720))
                UIColor(hue: CGFloat(index) / 8, saturation: 0.7, brightness: 0.8, alpha: 1).setFill()
                for stripe in 0..<12 { context.fill(CGRect(x: 10, y: CGFloat(stripe * 60), width: 300, height: 24)) }
                ("PAGE \(index + 1)" as NSString).draw(at: CGPoint(x: 24, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 28)])
            }
            expected[index] = try rgba(image)
            let url = out.appendingPathComponent("input-\(index).png")
            try #require(image.pngData()).write(to: url); urls.append(url)
        }
        let prepared = try #require(await LocalFileManager.shared.prepareImageImport(from: urls, name: "Gesture audit"))
        let session = try TemporarySharedImageSession(fileInfo: prepared)
        defer { session.removeFiles() }
        let modeKey = "Reader.readingMode.\(session.manga.identifier)"
        let defaults = UserDefaults.standard
        let disabled = ["Reader.translation.automatic", "Reader.liveText", "Dictionary.enable", "Reader.cropBorders", "Reader.downsampleImages", "Reader.upscaleImages"]
        let keys = disabled + [modeKey, "Reader.pagedPageLayout"]
        let saved = Dictionary(uniqueKeysWithValues: keys.compactMap { key in defaults.object(forKey: key).map { (key, $0) } })
        for key in disabled { defaults.set(false, forKey: key) }
        defaults.set(mode, forKey: modeKey)
        defaults.set("single", forKey: "Reader.pagedPageLayout")
        defer { for key in keys { if let value = saved[key] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let old = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let reader = ReaderViewController(source: session.source, manga: session.manga, chapter: session.chapter,
            startPage: 1, temporaryImageSession: session)
        let navigation = ReaderNavigationController(readerViewController: reader)
        window.rootViewController = navigation
        let started = ProcessInfo.processInfo.systemUptime
        window.makeKeyAndVisible()
        defer { window.isHidden = true; old?.makeKey() }
        let deadline = started + 30
        while ProcessInfo.processInfo.systemUptime < deadline {
            if reader.reader?.translationPages().contains(where: { $0.imageView?.image != nil && $0.imageView?.window != nil }) == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let actual = try #require(reader.reader)
        try #require(actual.translationPages().contains { $0.imageView?.image != nil && $0.imageView?.window != nil })
        let entryMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
        let probe = GestureFrameProbe(scrollViews: scrollViews(in: actual.view))
        probe.start()
        defer { probe.stop() }
        // Longer observation is diagnostic-only; ordinary paired runs remain 45 seconds.
        let observationSeconds: Double = ProcessInfo.processInfo.environment["AUDIT_GESTURE_PROFILE_SECONDS"] == "120" ? 120 : 45
        let ready: [String: Any] = ["output": out.path, "mode": mode, "durationSeconds": observationSeconds,
            "pid": ProcessInfo.processInfo.processIdentifier, "entryMS": entryMS]
        try JSONSerialization.data(withJSONObject: ready, options: [.sortedKeys]).write(to: root.appendingPathComponent("ready.json"), options: .atomic)
        defer { try? FileManager.default.removeItem(at: root.appendingPathComponent("ready.json")) }
        var observations: [[String: Any]] = []
        var seen = Set<Int>()
        var displayed: [Int: UIImage] = [:]
        let gestureStart = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - gestureStart < observationSeconds {
            let visible = actual.translationPages().filter { $0.imageView?.window != nil }
            var indices: [Int] = []
            for page in visible {
                guard let sourcePage = page.sourcePage, let index = reader.pages.firstIndex(of: sourcePage),
                      let image = page.imageView?.image else { continue }
                indices.append(index); seen.insert(index); displayed[index] = image
            }
            observations.append(["elapsed": ProcessInfo.processInfo.systemUptime - gestureStart, "visibleReadyIndices": indices])
            try await Task.sleep(for: .milliseconds(100))
        }
        probe.stop() // Exclude PNG encoding/screenshot work from gesture frame timings.
        var comparisons: [[String: Any]] = []
        for (index, image) in displayed.sorted(by: { $0.key < $1.key }) {
            let exact = expected[index] == (try rgba(image))
            #expect(exact, "Actual visible source image pixels changed")
            let png = try #require(image.pngData())
            try png.write(to: out.appendingPathComponent("displayed-\(index).png"))
            comparisons.append(["index": index, "exactRGBA": exact, "pngSHA256": SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()])
        }
        let shot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        try #require(shot.pngData()).write(to: out.appendingPathComponent("final-screen.png"))
        let result: [String: Any] = ["mode": mode, "entryMS": entryMS, "frameSamples": probe.samples,
            "observations": observations, "comparisons": comparisons, "dragBeginCount": probe.dragBegins,
            "seenIndices": seen.sorted(), "scope": "Actual external gestures only; frame callback gaps, not Instruments hitch duration; 10Hz ready-image polling; processors/OCR disabled; local temporary archive; no persistent user data"]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("results.json"), options: .atomic)
        #expect(probe.dragBegins >= 5, "At least five real drags must be supplied by CUA during ready window")
        #expect(seen.count >= 3, "At least three distinct pages must actually appear")
    }
    private func scrollViews(in view: UIView) -> [UIScrollView] {
        ((view as? UIScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
    }
    private func rgba(_ image: UIImage) throws -> Data {
        let cg = try #require(image.cgImage)
        var bytes = Data(count: cg.width * cg.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let ctx = try #require(CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        return bytes
    }
}

@MainActor private final class GestureFrameProbe: NSObject {
    let scrollViews: [UIScrollView]
    var samples: [[String: Any]] = []
    var dragBegins = 0
    private var wasDragging = false
    private var previous: CFTimeInterval?
    private var link: CADisplayLink?
    init(scrollViews: [UIScrollView]) { self.scrollViews = scrollViews }
    func start() { let value = CADisplayLink(target: self, selector: #selector(tick(_:))); link = value; value.add(to: .main, forMode: .common) }
    func stop() { link?.invalidate(); link = nil }
    @objc private func tick(_ value: CADisplayLink) {
        let dragging = scrollViews.contains { $0.isDragging }
        if dragging && !wasDragging { dragBegins += 1 }
        if samples.count < 12000 {
            samples.append(["timestamp": value.timestamp, "intervalMS": previous.map { (value.timestamp - $0) * 1000 } ?? 0,
                "expectedIntervalMS": (value.targetTimestamp - value.timestamp) * 1000,
                "dragging": dragging, "decelerating": scrollViews.contains { $0.isDecelerating },
                "offsets": scrollViews.map { [Double($0.contentOffset.x), Double($0.contentOffset.y)] }])
        }
        previous = value.timestamp; wasDragging = dragging
    }
}
