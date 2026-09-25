import Testing
import UIKit
import WebKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderTranslationPresentationReuseTests {
    @Test func sameSourceFitChangeUpdatesBackgroundWithoutReloadingDocument() async throws {
        let (host, overlay) = try makeOverlay()
        let previous = host.windowScene?.windows.first { $0.isKeyWindow && $0 !== host }
        host.makeKeyAndVisible()
        defer { overlay.cancelWork(); host.isHidden = true; previous?.makeKey() }
        let source = image()
        let settings = ReaderTranslationSettings()
        overlay.update(regions: [], imageSize: source.size, aspectFit: true, settings: settings, image: source)
        try await wait(overlay) { "document.getElementById('reader-source-image')?.style.objectFit === 'contain'" }
        _ = try await overlay.webView.evaluateJavaScript("""
            document.documentElement.dataset.presentationIdentity = 'same-document';
            document.getElementById('reader-source-image').dataset.reuseIdentity = 'same-image';
            """)
        overlay.update(regions: [], imageSize: source.size, aspectFit: true, settings: settings, image: source)
        #expect(try await overlay.webView.evaluateJavaScript(
            "document.getElementById('reader-source-image')?.dataset.reuseIdentity") as? String == "same-image")
        overlay.update(regions: [], imageSize: source.size, aspectFit: false, settings: settings, image: source)
        try await wait(overlay) { "document.getElementById('reader-source-image')?.style.objectFit === 'fill'" }
        #expect(try await overlay.webView.evaluateJavaScript(
            "document.documentElement.dataset.presentationIdentity") as? String == "same-document")
        #expect(try await overlay.webView.evaluateJavaScript(
            "document.querySelectorAll('#reader-source-image').length") as? Int == 1)
    }

    @Test func textOnlyReuseRemovesPreviousSourceAndDoesNotRestoreCancelledEncoding() async throws {
        let (host, overlay) = try makeOverlay()
        let previous = host.windowScene?.windows.first { $0.isKeyWindow && $0 !== host }
        host.makeKeyAndVisible()
        defer { overlay.cancelWork(); host.isHidden = true; previous?.makeKey() }
        let source = image()
        let settings = ReaderTranslationSettings()
        overlay.update(regions: [], imageSize: source.size, aspectFit: true, settings: settings, image: source)
        try await wait(overlay) { "document.getElementById('reader-source-image')?.complete === true" }
        overlay.update(regions: [], imageSize: source.size, aspectFit: false, settings: settings, image: nil)
        try await wait(overlay) { "document.getElementById('reader-source-image') === null" }
        // A new source immediately followed by nil also cancels queued encoding.
        let replacement = image()
        overlay.update(regions: [], imageSize: replacement.size, aspectFit: true, settings: settings, image: replacement)
        overlay.update(regions: [], imageSize: replacement.size, aspectFit: false, settings: settings, image: nil)
        try await Task.sleep(for: .milliseconds(150))
        #expect(try await overlay.webView.evaluateJavaScript(
            "document.getElementById('reader-source-image') === null") as? Bool == true)
    }

    private func makeOverlay() throws -> (UIWindow, ReaderTranslationOverlayView) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIWindow(windowScene: scene)
        host.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        host.rootViewController = UIViewController()
        let overlay = ReaderTranslationOverlayView(frame: host.bounds)
        host.rootViewController?.view.addSubview(overlay)
        return (host, overlay)
    }

    private func wait(_ overlay: ReaderTranslationOverlayView, predicate: () -> String) async throws {
        for _ in 0..<400 {
            if !overlay.webView.isLoading,
               (try? await overlay.webView.evaluateJavaScript(predicate())) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Background presentation did not reach the requested state")
        throw URLError(.timedOut)
    }

    private func image() -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20), format: format).image {
            UIColor.red.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
            UIColor.blue.setFill(); $0.fill(CGRect(x: 20, y: 0, width: 20, height: 20))
        }
    }
}
