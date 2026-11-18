import Gifu
import Testing
import UIKit
@testable import Aidoku

/// Synthetic reader state; no model, provider, network, or source image fixture.
@Suite(.serialized) @MainActor
struct ReaderTranslationSettledHighlightIntegrationTests {
    @Test(arguments: [false, true])
    func toggleResetAndDelayedPage(gifu: Bool) throws {
        let view: UIImageView = gifu ? GIFImageView() : UIImageView()
        let source = sample(.red)
        let settled = sample(.green)
        view.frame = CGRect(x: 0, y: 0, width: 15, height: 20)
        view.traitOverrides.displayScale = 2
        view.contentMode = .scaleAspectFit
        view.image = source
        let page = ReaderTranslationPage(imageView: view)
        let first = prepare(source: source, settled: settled, view: view)
        page.displayLoadedImage(first, isKnownStatic: true)
        let canvas = try #require(view.subviews.first as? UIImageView)
        #expect(view.image === source && view.isHighlighted)
        #expect(canvas.image == nil)

        var off = first.settings
        off.automaticallyTranslate = false
        page.applySettings(off)
        #expect(!view.isHighlighted && view.highlightedImage == nil)
        #expect(canvas.isHidden)
        page.applySettings(first.settings)
        #expect(view.image === source && view.isHighlighted && canvas.image == nil)

        page.reset()
        let nextSource = sample(.blue)
        view.image = nextSource
        page.displayLoadedImage(first, isKnownStatic: true)
        #expect(view.image === nextSource && !view.isHighlighted)
        #expect(view.subviews.isEmpty)
    }

    @Test
    func unknownAnimationAndViewportUseFallback() throws {
        let view = GIFImageView()
        view.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
        view.traitOverrides.displayScale = 2
        view.contentMode = .scaleToFill
        let source = sample(.blue)
        let settled = sample(.yellow)
        view.image = source
        let page = ReaderTranslationPage(imageView: view)
        let prepared = prepare(source: source, settled: settled, view: view)

        page.displayLoadedImage(prepared, isKnownStatic: false)
        #expect(!view.isHighlighted && view.highlightedImage == nil)
        #expect((view.subviews.first as? UIImageView)?.image === settled)

        page.reset()
        page.displayLoadedImage(prepared, isKnownStatic: true)
        #expect(view.isHighlighted)
        page.disallowSettledHighlight() // Same image, GIF data arrives before decoder.
        #expect(!view.isHighlighted && view.highlightedImage == nil)
        #expect((view.subviews.first as? UIImageView)?.image === settled)

        page.reset()
        view.bounds.size.width += 5
        page.displayLoadedImage(prepared, isKnownStatic: true)
        #expect(!view.isHighlighted && view.highlightedImage == nil)
        #expect((view.subviews.first as? UIImageView)?.image === settled)
    }

    @Test func externalHighlightAndCancelledAcquisitionAreNotOverwritten() {
        let view = UIImageView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        view.traitOverrides.displayScale = 2
        view.contentMode = .scaleToFill
        let source = sample(.red)
        let external = sample(.blue)
        let settled = sample(.yellow)
        view.image = source
        let geometry = geometry(for: view)
        let lease = ReaderTranslationSettledHighlight()
        #expect(!lease.acquire(view: view, source: source, settled: settled,
                               geometry: geometry, isKnownStatic: true, cancelled: true))
        #expect(lease.acquire(view: view, source: source, settled: settled, geometry: geometry, isKnownStatic: true))
        view.highlightedImage = external
        lease.release()
        #expect(view.highlightedImage === external && view.isHighlighted)
        #expect(!lease.acquire(view: view, source: source, settled: settled, geometry: geometry, isKnownStatic: true))
    }

    @Test func delayedBoundsPresentationDoesNotBlankOrCoverAnotherSource() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        let view = GIFImageView()
        root.view.addSubview(view)
        let source = sample(.red)
        let settled = sample(.green)
        view.image = source
        view.contentMode = .scaleAspectFit
        let page = ReaderTranslationPage(imageView: view)
        var prepared = prepare(source: source, settled: settled, view: view)
        let expected = CGRect(x: 0, y: 0, width: 15, height: 20)
        prepared.freshSettledGeometry = .init(viewport: expected.size, scale: view.traitCollection.displayScale,
            aspectFit: true, dark: view.traitCollection.userInterfaceStyle == .dark)
        page.displayLoadedImage(prepared, isKnownStatic: true)
        let canvas = try #require(view.subviews.first as? UIImageView)
        #expect(!view.isHighlighted && canvas.image === settled)

        view.frame = expected
        root.view.layoutIfNeeded()
        view.layoutIfNeeded()
        canvas.setNeedsLayout()
        canvas.layoutIfNeeded()
        #expect(geometry(for: view) == prepared.freshSettledGeometry)
        #expect(view.image === source && view.isHighlighted && canvas.image == nil)

        let next = sample(.blue)
        view.image = next
        canvas.setNeedsLayout()
        canvas.layoutIfNeeded()
        #expect(view.image === next && view.highlightedImage == nil && canvas.image == nil)
    }

    private func sample(_ color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10), format: format).image { renderer in
            renderer.cgContext.setFillColor(color.withAlphaComponent(0.5).cgColor)
            renderer.cgContext.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
    }

    private func geometry(for view: UIImageView) -> ReaderTranslationImageGeometry {
        .init(viewport: view.bounds.size, scale: view.traitCollection.displayScale,
              aspectFit: view.contentMode == .scaleAspectFit, dark: view.traitCollection.userInterfaceStyle == .dark)
    }

    private func prepare(source: UIImage, settled: UIImage, view: UIImageView) -> ReaderTranslationPreparedImage {
        var settings = ReaderTranslationSettings()
        settings.automaticallyTranslate = true
        settings.overlay.visible = true
        var prepared = ReaderTranslationPreparedImage(image: settled, regions: [], settings: settings)
        prepared.freshSettledGeometry = geometry(for: view)
        prepared.matchesSourceImage = { $0 === source }
        return prepared
    }
}
