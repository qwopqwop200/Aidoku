import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor struct ReaderTranslationOverlayLifecycleTests {
    @Test func replacingPageReleasesHiddenPreviousBitmap() {
        let overlay = ReaderTranslationOverlayView(frame: CGRect(x: 0, y: 0, width: 24, height: 32))
        var oldFrame: UIImage? = image()
        weak var releasedFrame = oldFrame
        overlay.renderedImageView.image = oldFrame
        oldFrame = nil
        overlay.update(regions: [], imageSize: overlay.bounds.size, aspectFit: false, settings: settings())
        #expect(overlay.renderedImage == nil)
        #expect(overlay.renderedImageView.isHidden)
        #expect(releasedFrame == nil, "A hidden replacement must release the prior page's raster")
        overlay.cancelWork()
    }

    @Test func explicitProvisionalRetentionKeepsOnlyTheSameSource() {
        let overlay = ReaderTranslationOverlayView(frame: CGRect(x: 0, y: 0, width: 24, height: 32))
        let source = image(), replacement = image(), frame = image()
        let configuration = settings()
        overlay.update(regions: [], imageSize: source.size, aspectFit: false, settings: configuration, image: source)
        overlay.renderedImageView.image = frame
        overlay.renderedImageView.isHidden = false
        overlay.update(regions: [], imageSize: source.size, aspectFit: false, settings: configuration,
            image: source, retainsCommittedFrame: true)
        #expect(overlay.renderedImage === frame)
        #expect(!overlay.renderedImageView.isHidden)
        overlay.cancelWork()
        #expect(overlay.renderedImage === frame, "Cancelling work preserves a reusable committed presentation")
        overlay.update(regions: [], imageSize: replacement.size, aspectFit: false, settings: configuration,
            image: replacement, retainsCommittedFrame: true)
        #expect(overlay.renderedImage == nil)
        #expect(overlay.renderedImageView.isHidden)
        overlay.cancelWork()
    }

    @Test func cancelledSharedLayoutWaitDoesNotKeepDetachedOverlayAlive() async throws {
        let gate = PendingOverlayLayout()
        let layout = Task<Data, Error> { await gate.value() }
        let viewport = CGSize(width: 24, height: 32)
        let empty = try JSONEncoder().encode(NativeTranslationLayout(imageSize: viewport,
            sourceRect: CGRect(origin: .zero, size: viewport), viewport: viewport, items: []))
        defer { gate.finish(empty); layout.cancel() }
        var overlay: ReaderTranslationOverlayView? = ReaderTranslationOverlayView(frame: CGRect(origin: .zero, size: viewport))
        weak var releasedOverlay = overlay
        overlay?.update(regions: [], imageSize: viewport, aspectFit: false,
            settings: settings(), preparedLayout: layout)
        overlay?.layoutIfNeeded()
        for _ in 0..<20 {
            if gate.isWaiting { break }
            await Task.yield()
        }
        #expect(gate.isWaiting)
        // Allow the overlay's consumer to suspend on the shared task too.
        await Task.yield()
        overlay?.cancelWork()
        overlay = nil
        await Task.yield()
        #expect(releasedOverlay == nil, "Shared preparation may outlive the consumer, but cannot retain its UIView")
        #expect(!layout.isCancelled, "The overlay does not own the shared layout producer")
    }

    private func image() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 24, height: 32), format: format).image { renderer in
            UIColor.white.setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: 24, height: 32))
        }
    }

    private func settings() -> ReaderTranslationSettings {
        let name = "ReaderTranslationOverlayLifecycleTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        return ReaderTranslationSettings(defaults: defaults)
    }
}

@MainActor private final class PendingOverlayLayout {
    private var continuation: CheckedContinuation<Data, Never>?
    var isWaiting: Bool { continuation != nil }
    func value() async -> Data { await withCheckedContinuation { continuation = $0 } }
    func finish(_ data: Data) { continuation?.resume(returning: data); continuation = nil }
}
