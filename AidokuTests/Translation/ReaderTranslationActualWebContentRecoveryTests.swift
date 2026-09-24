import Foundation
import Testing
import UIKit
import WebKit
@testable import Aidoku

/// Opt-in test. External root kills only dedicated simulator WebContent
/// processes after readiness. No private process APIs are called by this test.
@Suite(.serialized) @MainActor
struct ReaderTranslationActualWebContentRecoveryTests {
    private nonisolated static var directory: URL {
        URL.documentsDirectory.appendingPathComponent("DisplayPerformance")
    }

    @Test(.enabled(if: FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("termination-run.json").path)))
    func actualWebContentTerminationRecoversIndependentOverlays() async throws {
        let folder = Self.directory
        let config = try JSONDecoder().decode(Configuration.self, from: Data(
            contentsOf: folder.appendingPathComponent("termination-run.json")))
        let runID = UUID().uuidString
        let output = folder.appendingPathComponent("termination-" + runID)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let readyMarker = folder.appendingPathComponent("termination-ready")
        let acknowledgedMarker = folder.appendingPathComponent("termination-triggered")
        // These two files are owned only by this opt-in external-process test.
        try? FileManager.default.removeItem(at: readyMarker)
        try? FileManager.default.removeItem(at: acknowledgedMarker)
        defer { try? FileManager.default.removeItem(at: readyMarker) }
        let suite = "AidokuTests.ActualWebContentRecovery." + runID
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ReaderTranslationSettings(defaults: defaults)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.overrideUserInterfaceStyle = .light
        window.makeKeyAndVisible()
        let width = min(300, window.bounds.width)
        let height: CGFloat = 190
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        func source(_ color: UIColor, _ label: String) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image {
                color.setFill(); $0.fill(CGRect(x: 0, y: 0, width: width, height: height))
                (label as NSString).draw(at: CGPoint(x: 12, y: 145),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 20), .foregroundColor: UIColor.black])
            }
        }
        let images = [source(.cyan, "SOURCE A"), source(.yellow, "SOURCE B")]
        let texts = ["첫 번째 문서", "두 번째 문서"]
        var hosts: [UIImageView] = []
        var overlays: [ReaderTranslationOverlayView] = []
        for index in 0..<2 {
            let host = UIImageView(image: images[index])
            host.frame = CGRect(x: 10, y: 80 + CGFloat(index) * (height + 20), width: width, height: height)
            let overlay = ReaderTranslationOverlayView(frame: host.bounds)
            host.addSubview(overlay); window.addSubview(host)
            overlay.update(regions: [ReaderTranslationRegion(id: "same-region",
                rect: CGRect(x: 0.125, y: 0.125, width: 0.625, height: 0.25),
                source: "Hello", translation: texts[index])],
                imageSize: images[index].size, aspectFit: false, settings: settings, image: images[index])
            overlay.layoutIfNeeded()
            hosts.append(host); overlays.append(overlay)
        }
        defer {
            overlays.forEach { $0.cancelWork(); $0.removeFromSuperview() }
            window.isHidden = true; previous?.makeKey()
        }
        let initialDeadline = Date().addingTimeInterval(20)
        while !overlays.allSatisfy({ $0.lastDiagnostic?.outcome == .committed }) {
            try #require(Date() < initialDeadline, "Initial overlays did not commit")
            try await Task.sleep(for: .milliseconds(10))
        }
        try await capture(overlays, window: window, output: output, label: "before")
        let initialRevisions = overlays.map { $0.lastDiagnostic?.revision ?? 0 }
        let ready: [String: Any] = [
            "runID": runID, "appPID": ProcessInfo.processInfo.processIdentifier,
            "outputDirectory": output.lastPathComponent, "overlayCount": 2,
            "action": "Terminate dedicated simulator WebContent processes externally; write runID as plain UTF8 to termination-triggered after signals are sent",
            "expectsAllViewsTerminated": config.expectsAllViewsTerminated ?? false
        ]
        try JSONSerialization.data(withJSONObject: ready, options: [.sortedKeys])
            .write(to: readyMarker, options: .atomic)
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = Date().addingTimeInterval(45)
        var acknowledged = false
        var notified: [Int] = []
        while Date() < deadline {
            acknowledged = (try? String(contentsOf: acknowledgedMarker, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)) == runID
            notified = overlays.indices.filter { overlays[$0].contentTerminationCount > 0 }
            let expectedNotifications = config.expectsAllViewsTerminated == true ? notified.count == 2 : !notified.isEmpty
            if acknowledged && expectedNotifications &&
                overlays.allSatisfy({ $0.lastDiagnostic?.outcome == .committed }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let report: [String: Any] = [
            "runID": runID, "acknowledgedExternalTrigger": acknowledged,
            "notificationCounts": overlays.map(\.contentTerminationCount),
            "initialRevisions": initialRevisions,
            "recoveryRevisions": overlays.map { $0.lastDiagnostic?.revision ?? 0 },
            "committed": overlays.map { $0.lastDiagnostic?.outcome == .committed },
            "webViewHidden": overlays.map { $0.webView.isHidden },
            "exhausted": overlays.map(\.hasExhaustedRecovery),
            "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started,
            "scope": "external WebContent process termination, two visible local documents; failure recovery uses source UIImageViews plus text-only document",
            "normalPixelEqualityClaimed": false
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("recovery.json"))
        try #require(acknowledged, "External termination was not acknowledged within45seconds")
        try #require(!notified.isEmpty, "No real WebContent termination callback observed")
        if config.expectsAllViewsTerminated == true {
            #expect(notified.count == 2, "Root requested terminating all dedicated simulator WebContent processes")
        }
        for index in overlays.indices {
            let overlay = overlays[index]
            try #require(overlay.lastDiagnostic?.outcome == .committed)
            #expect(!overlay.webView.isHidden)
            #expect(!overlay.hasExhaustedRecovery)
            #expect(hosts[index].image === images[index])
            let actual = try await overlay.webView.evaluateJavaScript(
                "Array.from(document.querySelectorAll('[data-aidoku-image-ocr-overlay=\"item\"]')).map(x=>x.textContent)")
            #expect(actual as? [String] == [texts[index]])
            if overlay.contentTerminationCount > 0 {
                #expect(overlay.lastDiagnostic?.revision != initialRevisions[index])
                #expect(!overlay.canCacheRendering)
                let backgroundAbsent = try await overlay.webView.evaluateJavaScript(
                    "document.getElementById('reader-source-image') === null")
                #expect(backgroundAbsent as? Bool == true)
            }
        }
        try await capture(overlays, window: window, output: output, label: "after")
    }

    private func capture(_ overlays: [ReaderTranslationOverlayView], window: UIWindow,
                         output: URL, label: String) async throws {
        for (index, overlay) in overlays.enumerated() {
            _ = try await overlay.webView.callAsyncJavaScript(
                "await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))",
                arguments: [:], in: nil, contentWorld: ReaderTranslationDOM.contentWorld)
            let snapshot: UIImage = try await withCheckedThrowingContinuation { continuation in
                overlay.webView.takeSnapshot(with: nil) { image, error in
                    if let image { continuation.resume(returning: image) }
                    else { continuation.resume(throwing: error ?? URLError(.cannotDecodeContentData)) }
                }
            }
            try #require(snapshot.pngData()).write(to: output.appendingPathComponent("\(label)-overlay-\(index).png"))
        }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try #require(image.pngData()).write(to: output.appendingPathComponent("\(label)-window.png"))
    }

    private struct Configuration: Decodable {
        let expectsAllViewsTerminated: Bool?
    }
}
