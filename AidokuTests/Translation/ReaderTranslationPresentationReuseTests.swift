import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderTranslationPresentationReuseTests {
    @Test func sameSourceFitChangeReusesNativeCanvas() async throws {
        let (host, overlay) = try makeOverlay()
        let previous = host.windowScene?.windows.first { $0.isKeyWindow && $0 !== host }
        host.makeKeyAndVisible()
        defer { overlay.cancelWork(); host.isHidden = true; previous?.makeKey() }
        let source = image()
        let settings = ReaderTranslationSettings()
        overlay.update(regions: [], imageSize: source.size, aspectFit: true, settings: settings, image: source)
        try await wait { overlay.sourceImage === source && overlay.renderedAspectFit }
        let canvas = overlay.renderedImageView
        overlay.update(regions: [], imageSize: source.size, aspectFit: true, settings: settings, image: source)
        #expect(overlay.sourceImage === source)
        #expect(overlay.renderedImageView === canvas)
        overlay.update(regions: [], imageSize: source.size, aspectFit: false, settings: settings, image: source)
        try await wait { overlay.sourceImage === source && !overlay.renderedAspectFit }
        #expect(overlay.renderedImageView === canvas)
        #expect(overlay.subviews.filter { $0 is UIImageView }.count == 1)
    }

    @Test func textOnlyReuseRemovesPreviousSourceAndDoesNotRestoreCancelledEncoding() async throws {
        let (host, overlay) = try makeOverlay()
        let previous = host.windowScene?.windows.first { $0.isKeyWindow && $0 !== host }
        host.makeKeyAndVisible()
        defer { overlay.cancelWork(); host.isHidden = true; previous?.makeKey() }
        let source = image()
        let settings = ReaderTranslationSettings()
        overlay.update(regions: [], imageSize: source.size, aspectFit: true, settings: settings, image: source)
        try await wait { overlay.sourceImage === source }
        overlay.update(regions: [], imageSize: source.size, aspectFit: false, settings: settings, image: nil)
        try await wait { overlay.sourceImage == nil }
        // A new source immediately followed by nil also cancels queued encoding.
        let replacement = image()
        overlay.update(regions: [], imageSize: replacement.size, aspectFit: true, settings: settings, image: replacement)
        overlay.update(regions: [], imageSize: replacement.size, aspectFit: false, settings: settings, image: nil)
        try await Task.sleep(for: .milliseconds(150))
        #expect(overlay.sourceImage == nil)
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

    private func wait(predicate: () -> Bool) async throws {
        for _ in 0..<400 {
            if predicate() { return }
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
