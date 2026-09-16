import UIKit
import WebKit

@MainActor
enum ReaderTranslationImageExporter {
    enum ExportError: Error { case unavailable, renderFailed }

    // Full pages, including tall webtoons, stay within a bounded bitmap allocation.
    static func outputSize(for image: UIImage) -> CGSize {
        outputSize(for: CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale))
    }

    static func outputSize(for pixels: CGSize) -> CGSize {
        guard pixels.width.isFinite, pixels.height.isFinite, pixels.width > 0, pixels.height > 0 else { return .zero }
        let scale = min(1, 16_384 / max(pixels.width, pixels.height), sqrt(12_000_000 / pixels.width / pixels.height))
        return CGSize(width: max(1, floor(pixels.width * scale)), height: max(1, floor(pixels.height * scale)))
    }

    static func render(image: UIImage, regions: [ReaderTranslationRegion], settings: ReaderTranslationSettings,
                       viewport: CGSize, aspectFit: Bool, host: UIView) async throws -> UIImage {
        guard viewport.width > 0, viewport.height > 0, host.window != nil else { throw ExportError.unavailable }
        let overlay = ReaderTranslationOverlayView(frame: CGRect(origin: .zero, size: viewport))
        // A separate renderer avoids changing the reader's zoom, cached rendering, or visible DOM.
        host.insertSubview(overlay, at: 0)
        defer { overlay.cancelWork(); overlay.removeFromSuperview() }
        var exportSettings = settings
        exportSettings.overlay.visible = true
        overlay.update(regions: regions, imageSize: image.size, aspectFit: aspectFit, settings: exportSettings, image: image)
        let deadline = Date().addingTimeInterval(20)
        while overlay.lastDiagnostic?.outcome != .committed {
            try Task.checkCancellation()
            guard Date() < deadline, !overlay.hasExhaustedRecovery else { throw ExportError.renderFailed }
            overlay.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        // Sampled erasure masks and typography remain. Composite them over the original
        // pixels, not the lower-resolution background copy used by the live WebKit view.
        _ = try await overlay.webView.callAsyncJavaScript("""
        await document.fonts.ready;
        const source = document.getElementById('reader-source-image');
        if (source) source.style.visibility = 'hidden';
        await new Promise(resolve => setTimeout(resolve, 100));
        """, arguments: [:], in: nil, contentWorld: ReaderTranslationDOM.contentWorld)
        let rect = ReaderTranslationGeometry.displayRect(
            CGRect(x: 0, y: 0, width: 1, height: 1), imageSize: image.size,
            bounds: CGRect(origin: .zero, size: viewport), aspectFit: aspectFit
        )
        let size = outputSize(for: image)
        let configuration = WKSnapshotConfiguration()
        configuration.rect = rect
        configuration.snapshotWidth = NSNumber(value: Double(size.width / max(1, overlay.traitCollection.displayScale)))
        let translation: UIImage = try await withCheckedThrowingContinuation { continuation in
            overlay.webView.takeSnapshot(with: configuration) { image, error in
                if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: error ?? ExportError.renderFailed) }
            }
        }
        try Task.checkCancellation()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let destination = CGRect(origin: .zero, size: size)
            image.draw(in: destination)
            translation.draw(in: destination)
        }
    }

    static func saveAction(page: ReaderTranslationPage?, presenter: UIViewController) -> UIAction {
        UIAction(title: NSLocalizedString("SAVE_TRANSLATED_IMAGE"), image: UIImage(systemName: "character.bubble"),
                 attributes: page?.canExportTranslation == true ? [] : [.disabled]) { [weak page, weak presenter] _ in
            guard let page, let presenter else { return }
            Task { @MainActor in
                let progress = UIAlertController(title: NSLocalizedString("SAVE_TRANSLATED_IMAGE"),
                    message: NSLocalizedString("LOADING_ELLIPSIS"), preferredStyle: .alert)
                presenter.present(progress, animated: true)
                do {
                    let image = try await page.exportTranslatedImage(host: presenter.view)
                    progress.dismiss(animated: true) { image.saveToAlbum(viewController: presenter) }
                } catch {
                    progress.dismiss(animated: true) {
                        let alert = UIAlertController(title: NSLocalizedString("SAVE_TRANSLATED_IMAGE"),
                            message: NSLocalizedString("TRANSLATED_IMAGE_SAVE_FAILED"), preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: NSLocalizedString("OK"), style: .default))
                        presenter.present(alert, animated: true)
                    }
                }
            }
        }
    }
}
