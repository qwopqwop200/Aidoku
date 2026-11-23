import UIKit

/// The translation presentation of one reader image view. Every page renders
/// through the pipeline (`processPipeline`): the result is a complete page bitmap attached
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
    private var diagnosticContext: ReaderTranslationDiagnostics.Context?
    private var generation = UUID()
    private var cachedOverlay: ReaderTranslationCachedPageView?
    // One fully rendered pipeline page bitmap per source image.
    private var pipelineTask: Task<Void, Never>?
    private var pipelineIdentity: String?
    private weak var pipelineSource: UIImage?
    private var pipelineFailed = false
    private(set) var isPresentingPipeline = false
    var hasPipelineWork: Bool { pipelineTask != nil }

    /// Live pages, so a page finished by look-ahead attaches before it turns or scrolls into view.
    private static let live = NSHashTable<ReaderTranslationPage>.weakObjects()
    /// Bumped whenever a finished page becomes presentable; a view that probed the cache earlier probes again.
    static var finishedGeneration = 0

    init(imageView: UIImageView) {
        self.imageView = imageView
        Self.live.add(self)
    }

    deinit { pipelineTask?.cancel() }

    func reset() {
        generation = UUID()
        cancelPipelineWork()
        releaseOverlay()
    }

    private func releaseOverlay() {
        cachedOverlay?.removeFromSuperview()
        cachedOverlay = nil
        isPresentingPipeline = false
        if pipelineTask == nil {
            pipelineIdentity = nil
            pipelineFailed = false
        }
    }

    /// Only a presented pipeline page bitmap can be saved; it is the finished page.
    var canExportTranslation: Bool { isPresentingPipeline && cachedOverlay?.snapshotImage != nil }

    func exportTranslatedImage() throws -> UIImage {
        guard isPresentingPipeline, let snapshot = cachedOverlay?.snapshotImage else {
            throw ReaderTranslationImageExporter.ExportError.unavailable
        }
        return snapshot
    }

    /// Called inside the loader's synchronous source + presentation commit.
    func displayLoadedImage(_ prepared: ReaderTranslationPreparedImage) {
        guard !Task.isCancelled, let source = imageView?.image, prepared.isCurrent(for: source),
              let key = prepared.pipelineCacheKey else { return }
        displayLoadedPipeline(prepared.image, key: key, source: source, settings: prepared.settings)
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
        ReaderTranslationDiagnostics.record("visible_bitmap_attached", count: Int(imageView.bounds.width),
                                            code: Int(imageView.bounds.height), context: diagnosticContext)
    }
}

// MARK: - Pipeline presentation

extension ReaderTranslationPage {
    /// Starts (or keeps) pipeline translation of the displayed image. Repeated calls for the same
    /// source and identity are free, and a failure is not retried until `retryPipeline()`.
    func processPipeline(settings: ReaderTranslationSettings, persistsCache: Bool,
                   onPresented: @escaping @MainActor () -> Void,
                   onFailure: @escaping @MainActor (Error) -> Void) {
        guard #available(iOS 18.0, *), let imageView, let image = imageView.image, let sourcePage else { return }
        let crop = sourcePage.translationSourceRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let key = ReaderTranslationPipelineService.cacheKey(page: sourcePage.translationCacheKey, crop: crop, settings: settings)
        if pipelineIdentity == key, pipelineSource === image {
            if isPresentingPipeline {
                cachedOverlay?.setPresentationHidden(!settings.overlay.visible)
                // Already translated when it became visible (cache or look-ahead): no wait.
                ReaderTranslationDiagnostics.record("pipeline_visible_ready", page: sourcePage.index + 1, elapsedMilliseconds: 0, outcome: 2)
            }
            return
        }
        begin(key: key, source: image)
        let issued = generation
        let visibleStart = ProcessInfo.processInfo.systemUptime
        pipelineTask = Task { [weak self] in
            do {
                let pixels = await Task.detached(priority: .userInitiated) {
                    ReaderTranslationImagePreparation.uprightSourceImage(image).cgImage
                }.value
                try Task.checkCancellation()
                guard let pixels else { throw NativeCoreMLDetectorError.imageConversionFailed }
                let output = try await ReaderTranslationPipelineService.shared.translatePage(
                    pixels, cacheKey: key, persists: persistsCache, settings: settings, priority: .foreground)
                try Task.checkCancellation()
                guard let self, generation == issued, pipelineIdentity == key, self.imageView?.image === image else { return }
                pipelineTask = nil
                if let timings = output.timings {
                    ReaderTranslationDiagnostics.record("pipeline_page", page: sourcePage.index + 1,
                        elapsedMilliseconds: timings.stages[TranslationPipeline.Stage.nonLLM])
                    for (stage, ms) in timings.stages {
                        ReaderTranslationDiagnostics.record("stage_" + stage, page: sourcePage.index + 1, elapsedMilliseconds: ms)
                    }
                }
                // Visible request to presented bitmap: the wait a reader actually sees (0 work = cache/look-ahead join).
                ReaderTranslationDiagnostics.record("pipeline_visible_ready", page: sourcePage.index + 1,
                    elapsedMilliseconds: (ProcessInfo.processInfo.systemUptime - visibleStart) * 1000,
                    outcome: output.timings == nil ? 1 : 0)
                displayPipeline(UIImage(cgImage: output.image, scale: image.scale, orientation: .up), source: image, settings: settings)
                onPresented()
            } catch {
                guard let self, generation == issued, pipelineIdentity == key else { return }
                pipelineTask = nil
                guard !(error is CancellationError) else { pipelineIdentity = nil; return }
                pipelineFailed = true
                onFailure(error)
            }
        }
    }

    /// Cancels in-flight pipeline work for a page leaving the viewport. A finished
    /// presentation stays attached; unfinished work restarts when visible again.
    func cancelPipelineWork() {
        guard let pipelineTask else { return }
        pipelineTask.cancel()
        self.pipelineTask = nil
        if !isPresentingPipeline, !pipelineFailed { pipelineIdentity = nil }
    }

    /// Removes the pipeline presentation and any pending pipeline work.
    func hidePipeline() {
        guard isPresentingPipeline || pipelineTask != nil || pipelineIdentity != nil else { return }
        reset()
        pipelineIdentity = nil
        pipelineFailed = false
    }

    func retryPipeline() {
        guard pipelineFailed else { return }
        pipelineFailed = false
        pipelineIdentity = nil
    }

    /// A cached pipeline bitmap attached in the loader's source commit; a later `processPipeline` is then free.
    private func displayLoadedPipeline(_ output: UIImage, key: String, source: UIImage, settings: ReaderTranslationSettings) {
        if isPresentingPipeline, pipelineIdentity == key, pipelineSource === source {
            cachedOverlay?.setPresentationHidden(!settings.overlay.visible)
            return
        }
        begin(key: key, source: source)
        displayPipeline(output, source: source, settings: settings)
    }

    /// Attaches a page that finished elsewhere (look-ahead) to every live view showing its source,
    /// such as a paged neighbour or a webtoon page below the viewport that loaded before it finished.
    static func presentFinished(_ output: CGImage, key: String, settings: ReaderTranslationSettings) {
        guard #available(iOS 18.0, *) else { return }
        finishedGeneration &+= 1
        for page in live.allObjects {
            // A page with its own pipeline task joins the same computation and presents it itself.
            guard page.pipelineTask == nil, !(page.isPresentingPipeline && page.pipelineIdentity == key),
                  let source = page.imageView?.image, let sourcePage = page.sourcePage, fits(output, source: source),
                  ReaderTranslationPipelineService.cacheKey(page: sourcePage.translationCacheKey,
                      crop: sourcePage.translationSourceRect ?? ReaderTranslationSplitGeometry.unit, settings: settings) == key
            else { continue }
            ReaderTranslationDiagnostics.record("pipeline_lookahead_attached", page: sourcePage.index + 1)
            page.displayLoadedPipeline(UIImage(cgImage: output, scale: source.scale, orientation: .up),
                                 key: key, source: source, settings: settings)
        }
    }

    /// A pipeline bitmap is the upright source: it must match the source's pixel size.
    static func fits(_ output: CGImage, source image: UIImage) -> Bool {
        let upright = [.up, .upMirrored, .down, .downMirrored].contains(image.imageOrientation)
        let pixelSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let expected = upright ? pixelSize : CGSize(width: pixelSize.height, height: pixelSize.width)
        return abs(CGFloat(output.width) - expected.width) <= 1 && abs(CGFloat(output.height) - expected.height) <= 1
    }

    private func begin(key: String, source: UIImage) {
        reset()
        pipelineIdentity = key
        pipelineSource = source
        pipelineFailed = false
    }

    private func displayPipeline(_ output: UIImage, source: UIImage, settings: ReaderTranslationSettings) {
        let identity = pipelineIdentity
        displaySnapshot(output, settings: settings)
        pipelineIdentity = identity
        pipelineSource = source
        isPresentingPipeline = true
    }
}

@MainActor private final class ReaderTranslationCachedPageView: UIImageView {
    var snapshotImage: UIImage?

    func setPresentationHidden(_ hidden: Bool) {
        isHidden = hidden
        if image !== snapshotImage { image = snapshotImage }
    }
}
