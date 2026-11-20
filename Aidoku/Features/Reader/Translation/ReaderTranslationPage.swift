import UIKit

/// The translation presentation of one reader image view. Every page renders
/// through V2 (`processV2`): the result is a complete page bitmap attached
/// through the cached-page canvas above the source image.
@MainActor
final class ReaderTranslationPage {
    static let sourceImageReady = Notification.Name("Reader.translation.sourceImageReady")
    static func sourceDidLoad(_ image: UIImage, page: Page) {
        guard page.translationSourceRect == nil || page.translationSourceRect == CGRect(x: 0, y: 0, width: 1, height: 1) else { return }
        NotificationCenter.default.post(name: sourceImageReady, object: nil)
    }
    static let imageChanged = Notification.Name("Reader.translation.imageChanged")
    weak var imageView: UIImageView?
    var sourcePage: Page? {
        didSet {
            if oldValue != nil, oldValue?.translationCacheKey != sourcePage?.translationCacheKey ||
                oldValue?.translationSourceRect != sourcePage?.translationSourceRect ||
                oldValue?.translationSplitSource != sourcePage?.translationSplitSource {
                reset()
            }
            diagnosticContext = sourcePage.map { ReaderTranslationDiagnostics.makeContext(pageKey: $0.translationCacheKey) }
        }
    }
    var diagnosticContext: ReaderTranslationDiagnostics.Context?
    private var generation = UUID()
    private var cachedOverlay: ReaderTranslationCachedPageView?
    // One fully rendered V2 page bitmap per source image.
    private var v2Task: Task<Void, Never>?
    private var v2Identity: String?
    private weak var v2Source: UIImage?
    private var v2Failed = false
    private(set) var isPresentingV2 = false

    init(imageView: UIImageView) {
        self.imageView = imageView
    }

    deinit {
        v2Task?.cancel()
    }

    func reset() {
        cancel()
        releaseOverlay()
    }

    func cancel() {
        generation = UUID()
        cancelV2Work()
    }

    func releaseOverlay() {
        cachedOverlay?.removeFromSuperview()
        cachedOverlay = nil
        isPresentingV2 = false
        if v2Task == nil {
            v2Identity = nil
            v2Failed = false
        }
    }

    /// Only a presented V2 page bitmap can be saved; it is the finished page.
    var canExportTranslation: Bool {
        isPresentingV2 && cachedOverlay?.snapshotImage != nil
    }

    func exportTranslatedImage() throws -> UIImage {
        guard isPresentingV2, let snapshot = cachedOverlay?.snapshotImage else {
            throw ReaderTranslationImageExporter.ExportError.unavailable
        }
        return snapshot
    }

    /// Called inside the loader's synchronous source + presentation commit.
    func displayLoadedImage(_ prepared: ReaderTranslationPreparedImage) {
        guard !Task.isCancelled, let source = imageView?.image, prepared.isCurrent(for: source),
              let key = prepared.v2CacheKey else { return }
        displayLoadedV2(prepared.image, key: key, source: source, settings: prepared.settings)
    }

    private func displaySnapshot(_ snapshot: UIImage, settings: ReaderTranslationSettings) {
        guard let imageView else { return }
        releaseOverlay()
        let canvas = ReaderTranslationCachedPageView()
        canvas.snapshotImage = snapshot
        canvas.frame = imageView.bounds
        canvas.contentMode = imageView.contentMode
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvas.setPresentationHidden(!settings.overlay.visible)
        canvas.accessibilityIdentifier = "reader.translation.cachedOverlay"
        if imageView.bounds.width <= 0 || imageView.bounds.height <= 0 {
            ReaderTranslationDiagnostics.record("bitmap_attached_before_layout", context: diagnosticContext)
        }
        cachedOverlay = canvas
        imageView.insertSubview(canvas, at: 0)
        ReaderTranslationDiagnostics.record("visible_bitmap_attached", page: diagnosticContext?.page ?? -1,
                                            count: Int(imageView.bounds.width), code: Int(imageView.bounds.height), context: diagnosticContext)
    }
}

// MARK: - V2 pipeline presentation

extension ReaderTranslationPage {
    /// Starts (or keeps) V2 translation of the displayed image. The result is a
    /// complete page bitmap presented through the cached-page canvas. Repeated calls for the same source
    /// and identity are free, and a failure is not retried until `retryV2()`.
    func processV2(settings: ReaderTranslationSettings, persistsCache: Bool,
                   onPresented: @escaping @MainActor () -> Void,
                   onFailure: @escaping @MainActor (Error) -> Void) {
        guard #available(iOS 18.0, *), let imageView, let image = imageView.image, let sourcePage else { return }
        let crop = sourcePage.translationSourceRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let key = ReaderTranslationV2Service.cacheKey(page: sourcePage.translationCacheKey, crop: crop, settings: settings)
        if v2Identity == key, v2Source === image {
            if isPresentingV2 { cachedOverlay?.setPresentationHidden(!settings.overlay.visible) }
            return
        }
        reset()
        v2Identity = key
        v2Source = image
        v2Failed = false
        let issued = generation
        v2Task = Task { [weak self] in
            do {
                let pixels = await Task.detached(priority: .userInitiated) {
                    ReaderTranslationImagePreparation.uprightSourceImage(image).cgImage
                }.value
                try Task.checkCancellation()
                guard let pixels else { throw NativeCoreMLDetectorError.imageConversionFailed }
                let output = try await ReaderTranslationV2Service.shared.translatePage(
                    pixels, cacheKey: key, persists: persistsCache, settings: settings, priority: .foreground)
                try Task.checkCancellation()
                guard let self, generation == issued, v2Identity == key, self.imageView?.image === image else { return }
                v2Task = nil
                if let timings = output.timings {
                    ReaderTranslationDiagnostics.record("v2_page", page: sourcePage.index + 1,
                        elapsedMilliseconds: timings.stages[V2Pipeline.Stage.nonLLM])
                }
                displayV2(UIImage(cgImage: output.image, scale: image.scale, orientation: .up), source: image, settings: settings)
                onPresented()
            } catch {
                guard let self, generation == issued, v2Identity == key else { return }
                v2Task = nil
                guard !(error is CancellationError) else { v2Identity = nil; return }
                v2Failed = true
                onFailure(error)
            }
        }
    }

    /// Cancels in-flight V2 work for a page leaving the viewport. A finished
    /// presentation stays attached; unfinished work restarts when visible again.
    func cancelV2Work() {
        guard let v2Task else { return }
        v2Task.cancel()
        self.v2Task = nil
        if !isPresentingV2, !v2Failed { v2Identity = nil }
    }

    /// Removes the V2 presentation and any pending V2 work.
    func hideV2() {
        guard isPresentingV2 || v2Task != nil || v2Identity != nil else { return }
        cancel()
        releaseOverlay()
        v2Identity = nil
        v2Failed = false
    }

    func retryV2() {
        guard v2Failed else { return }
        v2Failed = false
        v2Identity = nil
    }

    /// A cached V2 bitmap attached in the loader's source commit (no source flash).
    /// The later `processV2` call for the same key and source is then free.
    private func displayLoadedV2(_ output: UIImage, key: String, source: UIImage, settings: ReaderTranslationSettings) {
        if isPresentingV2, v2Identity == key, v2Source === source {
            cachedOverlay?.setPresentationHidden(!settings.overlay.visible)
            return
        }
        reset()
        v2Identity = key
        v2Source = source
        v2Failed = false
        displayV2(output, source: source, settings: settings)
    }

    private func displayV2(_ output: UIImage, source: UIImage, settings: ReaderTranslationSettings) {
        let identity = v2Identity
        displaySnapshot(output, settings: settings)
        v2Identity = identity
        v2Source = source
        isPresentingV2 = true
    }
}

@MainActor private final class ReaderTranslationCachedPageView: UIImageView {
    var snapshotImage: UIImage?

    func setPresentationHidden(_ hidden: Bool) {
        isHidden = hidden
        if image !== snapshotImage { image = snapshotImage }
    }
}
