import AidokuRunner
import CryptoKit
import SwiftUI
import Testing
import UIKit
import Vision
@testable import Aidoku

@Suite(.serialized) @MainActor
struct DownloadedMangaSortPerformanceTests {
    @Test func actualViewModelSortAndDownloadedScreen() async throws {
        let previous = UserDefaults.standard.object(forKey: "Flag.downloadChapterSortAscending")
        defer { UserDefaults.standard.set(previous, forKey: "Flag.downloadChapterSortAscending") }
        let source = "test.round2.sort." + UUID().uuidString
        let cache = DownloadCache()
        let sourceRoot = cache.directory(sourceKey: source)
        defer { sourceRoot.removeItem() }
        let manga = AidokuRunner.Manga(sourceKey: source, key: "book", title: "Round2 Download Sort")
        let info = DownloadedMangaInfo(sourceId: source, mangaId: "book", title: manga.title,
            totalSize: 0, chapterCount: 500, isInLibrary: false)
        let manager = DownloadManager()
        let expected = (1...500).map { "Chapter \($0)" }
        let chapters = (1...500).map { index in
            // Coprime permutation, all numbers unique: golden order is independent of sort implementation.
            let value = (index * 137) % 500 + 1
            return DownloadedChapterInfo(chapterId: "Chapter \(value)", title: "Chapter \(value)", size: 0)
        }
        // Actual screen's private StateObject loads from disk; do not substitute a lookalike view.
        for chapter in chapters {
            let id = ChapterIdentifier(sourceKey: source, mangaKey: "book", chapterKey: chapter.chapterId)
            let folder = cache.directory(for: id)
            folder.createDirectory()
            try await manager.saveChapterMetadata(manga: manga,
                chapter: .init(key: chapter.chapterId, title: chapter.title), to: folder)
        }
        let output = URL.documentsDirectory.appendingPathComponent("Round2DownloadSort")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let oldKey = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; oldKey?.makeKeyAndVisible() }
        var rows: [[String: Any]] = []
        var diagnostics: [[String: Any]] = []
        func saveReport(phase: String) throws {
            let report: [String: Any] = ["chapters": 500, "samples": rows, "diagnostics": diagnostics,
                "phase": phase,
                "scope": "Actual VM toggle exact full 500-row order; actual production downloaded screen validated from a rendered screenshot using separate fast English Vision diagnostics. Capture observed-ready elapsed is an upper bound including frame polling, capture work and prior OCR polls, not precise first paint. Timestamp precedes current OCR. OCR time is separate, never subtracted. Warmup excluded; n=5 per direction only after completion. No same-instance sort-button, hitch, peak-RSS or user OCR pipeline claim. PNGs need external exact and visual comparison."]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("results.json"), options: .atomic)
        }
        // Persist setup immediately: later screen failure must not erase completed VM evidence.
        try saveReport(phase: "fixture_ready")
        let vm = DownloadedMangaView.ViewModel(manga: info)
        for run in 0..<6 { // run zero is warm-up; n=5 recorded per direction
            for ascending in [true, false] {
                vm.sortAscending = !ascending
                vm.chapters = chapters
                let start = CACurrentMediaTime()
                vm.toggleSortOrder()
                let elapsed = (CACurrentMediaTime() - start) * 1000
                let golden = ascending ? expected : Array(expected.reversed())
                let exact = vm.chapters.map(\.chapterId) == golden
                if run > 0 { rows.append(["kind": "actualViewModelToggle", "run": run,
                    "ascending": ascending, "milliseconds": elapsed, "order": vm.chapters.map(\.chapterId),
                    "orderExact": exact]) }
                try saveReport(phase: "view_model_sample_saved")
                #expect(exact)
            }
        }
        for ascending in [true, false] {
            AppSettings.flags.downloadChapterSortAscending.set(ascending)
            for run in 0..<6 {
                let path = NavigationCoordinator(rootViewController: nil)
                let host = UIHostingController(rootView: DownloadedMangaView(manga: info).environmentObject(path))
                let nav = UINavigationController(rootViewController: host)
                path.rootViewController = nav
                let start = CACurrentMediaTime()
                window.rootViewController = nav
                window.makeKeyAndVisible()
                window.layoutIfNeeded()
                let desired = ascending ? "Chapter 1" : "Chapter 500"
                let deadline = CACurrentMediaTime() + 30
                var found = false
                var attempts: [[String: Any]] = []
                var finalImage: UIImage?
                var observedReadyMS = 0.0
                var totalOCRMS = 0.0
                var totalCaptureMS = 0.0
                repeat {
                    try await twoFrames()
                    let captureStart = CACurrentMediaTime()
                    let format = UIGraphicsImageRendererFormat(); format.scale = 1
                    var drew = false
                    let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                        drew = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                    }
                    let capturedAt = CACurrentMediaTime() // BEFORE diagnostic Vision work
                    let captureMS = (capturedAt - captureStart) * 1000
                    totalCaptureMS += captureMS
                    observedReadyMS = (capturedAt - start) * 1000
                    finalImage = image
                    try #require(drew)
                    let capture = DownloadSortDiagnosticImage(image: try #require(image.cgImage))
                    let ocrStart = CACurrentMediaTime()
                    let recognized: [DownloadSortScreenText]
                    do {
                        recognized = try await Task.detached(priority: .utility) {
                            try Self.recognizedScreenText(capture.image)
                        }.value
                    } catch {
                        let name = "vision-error-\(ascending)-\(run)-\(attempts.count).png"
                        if let png = image.pngData() { try png.write(to: output.appendingPathComponent(name), options: .atomic) }
                        diagnostics.append(["kind": "diagnostic_vision_error", "error": String(describing: error),
                            "png": name, "captureObservedReadyUpperBoundMS": observedReadyMS,
                            "diagnosticOCRMS": (CACurrentMediaTime() - ocrStart) * 1000])
                        try saveReport(phase: "diagnostic_vision_failed")
                        throw error
                    }
                    let ocrMS = (CACurrentMediaTime() - ocrStart) * 1000
                    totalOCRMS += ocrMS
                    // Normalized Vision boxes have bottom-left origin. Sort by
                    // vertical position, not recognition response order.
                    let chapterRows = recognized.filter {
                        $0.text.range(of: #"^Chapter [0-9]+$"#, options: .regularExpression) != nil
                    }.sorted {
                        if $0.top != $1.top { return $0.top > $1.top }
                        return $0.left < $1.left
                    }
                    let titlePresent = recognized.contains { $0.text == "Round2 Download Sort" }
                    let titleAboveFirstChapter = chapterRows.first.map { first in
                        recognized.contains { $0.text == "Round2 Download Sort" && $0.bottom > first.top }
                    } ?? false
                    found = titlePresent && titleAboveFirstChapter && chapterRows.first?.text == desired
                    attempts.append(["attempt": attempts.count, "capturedAtUptime": capturedAt,
                        "captureObservedReadyUpperBoundMS": observedReadyMS, "captureMS": captureMS,
                        "diagnosticOCRMS": ocrMS, "declaredMangaTitleRecognized": titlePresent,
                        "declaredTitleAboveFirstChapter": titleAboveFirstChapter,
                        "topVisibleChapter": chapterRows.first?.text ?? "", "expectedTopVisibleChapter": desired,
                        "exactFirstVisibleChapter": found,
                        "recognizedText": recognized.map(\.json),
                        "chaptersSortedTopToBottom": chapterRows.map(\.json)])
                } while !found && CACurrentMediaTime() < deadline && attempts.count < 12
                let stem = "\(found ? "screen" : "failure")-\(ascending ? "ascending" : "descending")-\(run)"
                let image = try #require(finalImage)
                let png = try #require(image.pngData())
                let file = stem + ".png"
                try png.write(to: output.appendingPathComponent(file), options: .atomic)
                let screenEvidence: [String: Any] = ["kind": "rendered_screen_text_verification", "run": run,
                    "ascending": ascending, "found": found, "expectedVisibleLabel": desired,
                    "attempts": attempts, "pollCount": attempts.count, "sumDiagnosticOCRMS": totalOCRMS,
                    "sumCaptureMS": totalCaptureMS, "captureObservedReadyUpperBoundMS": observedReadyMS,
                    "png": file, "sha256": SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined(),
                    "observedAccessibilityLabels": labels(window).sorted(),
                    "timingContract": "Timestamp before current OCR; later captures include earlier OCR polls. No subtraction or precise-first-paint claim."]
                diagnostics.append(screenEvidence) // All 12 runs, including both warmups.
                if found && run > 0 {
                    rows.append(["kind": "actualScreenCaptureObservedReadyUpperBound", "run": run,
                        "ascending": ascending, "milliseconds": observedReadyMS, "png": file,
                        "pollCount": attempts.count, "sumDiagnosticOCRMS": totalOCRMS, "sumCaptureMS": totalCaptureMS,
                        "sha256": SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()])
                }
                try saveReport(phase: found ? "screen_sample_saved" : "screen_failed_before_require")
                if !found {
                    diagnostics.append(["kind": "failed_screen_hierarchy", "windowBounds": NSCoder.string(for: window.bounds),
                        "isKeyWindow": window.isKeyWindow, "sceneActivationState": scene.activationState.rawValue,
                        "hierarchy": visibleHierarchy(window)])
                    let disk = await DownloadManager.shared.getDownloadedChapters(for: info.mangaIdentifier)
                    diagnostics.append(["kind": "post_failure_actual_disk_read", "count": disk.count,
                        "chapterIDs": disk.map(\.chapterId), "displayTitles": disk.map(\.displayTitle)])
                    try saveReport(phase: "screen_failed_disk_diagnostic_saved")
                }
                try #require(found, "Rendered downloaded screen must show exact title and top chapter \(desired); evidence: \(output.path)")
                window.rootViewController = nil
                try await twoFrames()
            }
        }
        try saveReport(phase: "completed")
    }
    nonisolated private static func recognizedScreenText(_ image: CGImage) throws -> [DownloadSortScreenText] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return DownloadSortScreenText(text: candidate.string, left: Double(box.minX), bottom: Double(box.minY),
                width: Double(box.width), height: Double(box.height))
        }
    }
    private func visibleHierarchy(_ window: UIWindow) -> [[String: Any]] {
        var rows: [[String: Any]] = []
        func visit(_ view: UIView, depth: Int) {
            guard rows.count < 8192, depth < 128, !view.isHidden, view.alpha > 0.01 else { return }
            rows.append(["type": String(describing: type(of: view)), "depth": depth,
                "frameInWindow": NSCoder.string(for: window.convert(view.bounds, from: view)),
                "accessibilityLabel": view.accessibilityLabel ?? "", "isAccessibilityElement": view.isAccessibilityElement,
                "accessibilityElementCount": view.accessibilityElementCount()])
            for child in view.subviews { visit(child, depth: depth + 1) }
        }
        visit(window, depth: 0)
        return rows
    }
    private func twoFrames() async throws {
        let frames = DownloadSortFrames()
        try await frames.wait()
    }
    private func labels(_ window: UIWindow) -> Set<String> {
        var result: Set<String> = []; var seen: Set<ObjectIdentifier> = []
        func visit(_ object: NSObject) {
            guard seen.count < 8192, seen.insert(ObjectIdentifier(object)).inserted else { return }
            if let view = object as? UIView {
                guard !view.isHidden, view.alpha > 0.01,
                    view === window || window.convert(view.bounds, from: view).intersects(window.bounds) else { return }
                if let label = view as? UILabel, let text = label.text { result.insert(text) }
                view.subviews.forEach(visit)
            }
            if let text = object.accessibilityLabel { result.insert(text) }
            for case let element as NSObject in object.accessibilityElements ?? [] { visit(element) }
            let count = object.accessibilityElementCount()
            if count > 0 && count < 1024 {
                for index in 0..<count { if let element = object.accessibilityElement(at: index) as? NSObject { visit(element) } }
            }
        }
        visit(window); return result
    }
}
private struct DownloadSortScreenText: Sendable {
    let text: String
    let left: Double
    let bottom: Double
    let width: Double
    let height: Double
    var top: Double { bottom + height }
    var json: [String: Any] { ["text": text, "left": left, "bottom": bottom, "width": width, "height": height] }
}
// Immutable CGImage snapshot crosses only into one awaited diagnostic worker;
// no UIKit object or mutable pixel buffer is accessed on that worker.
private struct DownloadSortDiagnosticImage: @unchecked Sendable {
    let image: CGImage
}
@MainActor private final class DownloadSortFrames: NSObject {
    private var link: CADisplayLink?
    private var continuation: CheckedContinuation<Void, Error>?
    private var ticks = 0
    private var timeout: Task<Void, Never>?
    func wait() async throws {
        try await withCheckedThrowingContinuation { value in
            continuation = value
            link = CADisplayLink(target: self, selector: #selector(tick))
            link?.add(to: .main, forMode: .common)
            timeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                self?.finish(URLError(.timedOut))
            }
        }
    }
    @objc private func tick() { ticks += 1; if ticks >= 2 { finish(nil) } }
    private func finish(_ error: Error?) {
        link?.invalidate(); link = nil; timeout?.cancel(); timeout = nil
        let pending = continuation; continuation = nil
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
    }
}
