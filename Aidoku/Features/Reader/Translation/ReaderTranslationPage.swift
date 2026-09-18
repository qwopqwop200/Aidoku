import UIKit

@MainActor
final class ReaderTranslationPage {
    static let imageChanged = Notification.Name("Reader.translation.imageChanged")
    typealias Recognizer = @Sendable (CGImage, ReaderOCRConfiguration) async throws -> [ReaderTranslationRegion]
    typealias Translator = @Sendable ([ReaderTranslationRegion], ReaderTranslationSettings) async throws -> [ReaderTranslationRegion]
    typealias ProgressiveTranslator = @Sendable (
        [ReaderTranslationRegion], ReaderTranslationSettings, ReaderTranslationService.Progress?
    ) async throws -> [ReaderTranslationRegion]
    weak var imageView: UIImageView?
    var sourcePage: Page?
    var renderCache: ReaderTranslationRenderCache?
    private weak var analyzedImage: UIImage?
    private var analyzedConfiguration: ReaderOCRConfiguration?
    private weak var recognizedImage: UIImage?
    private var recognizedConfiguration: ReaderOCRConfiguration?
    private var recognizedRegions: [ReaderTranslationRegion]?
    private var lastSettings: ReaderTranslationSettings?
    private var completedTranslation = false
    private var isExportingTranslation = false
    private(set) var regions: [ReaderTranslationRegion] = []
    private var generation = UUID()
    private var task: Task<[ReaderTranslationRegion], Error>?
    private var overlay: ReaderTranslationOverlayView?
    private var cachedOverlay: ReaderTranslationCachedPageView?
    private var renderLookupTask: Task<Void, Never>?
    private var renderLookupKey: String?
    private var previewRegions: [ReaderTranslationRegion]?
    var isUsingCachedRendering: Bool { cachedOverlay != nil }
    private let recognize: Recognizer
    private let translateRegions: Translator?
    private let progressiveTranslate: ProgressiveTranslator?
    private var settingsObserver: NSObjectProtocol?
    private var memoryObserver: NSObjectProtocol?

    init(
        imageView: UIImageView,
        recognize: @escaping Recognizer = { image, configuration in
            guard #available(iOS 18.0, *) else { return [] }
            return try await TranslationImageWorkBudget.shared.withPermit(
                decodedBytes: UInt64(image.bytesPerRow) * UInt64(image.height)) {
                try await ReaderOCRService.shared.recognize(image: image, configuration: configuration)
            }
        },
        translate: Translator? = nil,
        progressiveTranslate: ProgressiveTranslator? = nil
    ) {
        self.imageView = imageView
        self.recognize = recognize
        self.translateRegions = translate
        self.progressiveTranslate = progressiveTranslate
        settingsObserver = NotificationCenter.default.addObserver(
            forName: ReaderTranslationSettings.changed, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in
            guard let self else { return }
            var saved = ReaderTranslationSettings()
            saved.rightToLeftPanelOrder = self.lastSettings?.rightToLeftPanelOrder ?? false
            self.applySettings(saved)
        } }
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.discardRecognitionCache() } }
    }

    deinit {
        task?.cancel()
        renderLookupTask?.cancel()
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) }
    }

    // Memory pressure must not erase a visible translation or interrupt its render.
    private func discardRecognitionCache() {
        recognizedImage = nil
        recognizedConfiguration = nil
        recognizedRegions = nil
    }

    func reset() {
        cancel()
        previewRegions = nil
        regions = []
        recognizedImage = nil
        recognizedConfiguration = nil
        recognizedRegions = nil
        analyzedImage = nil
        analyzedConfiguration = nil
        lastSettings = nil
        completedTranslation = false
        releaseOverlay()
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        renderLookupTask?.cancel()
        renderLookupTask = nil
        renderLookupKey = nil
    }

    func hidePreparedTranslation() {
        cancel()
        overlay?.isHidden = true
        cachedOverlay?.isHidden = true
    }

    func showOriginal() {
        cancel()
        releaseOverlay()
    }

    func releaseOverlay() {
        renderLookupTask?.cancel()
        renderLookupTask = nil
        renderLookupKey = nil
        cachedOverlay?.removeFromSuperview()
        cachedOverlay = nil
        overlay?.cancelWork()
        overlay?.removeFromSuperview()
        overlay = nil
    }

    func process(translate: Bool, settings: ReaderTranslationSettings, renderOverlay: Bool = true) async throws -> Int {
        guard #available(iOS 18.0, *), let image = imageView?.image else { return 0 }
        cancel()
        completedTranslation = false
        let issued = generation
        let cached = recognizedImage === image && recognizedConfiguration == settings.ocrConfiguration ? recognizedRegions : nil
        let recognize = recognize
        let translateRegions = translateRegions
        let progressiveTranslate = progressiveTranslate
        let task = Task<[ReaderTranslationRegion], Error> {
            let recognized: [ReaderTranslationRegion]
            if let cached {
                recognized = cached
            } else {
                // UIImage orientation must be applied before computing OCR coordinates.
                let pixels = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                    if image.imageOrientation == .up, let pixels = image.cgImage { return pixels }
                    let format = UIGraphicsImageRendererFormat()
                    format.scale = image.scale
                    return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
                        image.draw(at: .zero)
                    }.cgImage
                }.value
                try Task.checkCancellation()
                guard let pixels else { throw NativeCoreMLDetectorError.imageConversionFailed }
                recognized = try await recognize(pixels, settings.ocrConfiguration)
            }
            try Task.checkCancellation()
            guard generation == issued, imageView?.image === image else { throw CancellationError() }
            recognizedImage = image
            recognizedConfiguration = settings.ocrConfiguration
            recognizedRegions = recognized
            let filteringTask = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                let prepared = ReaderTranslationImagePreparation.apply(recognized, image: image, settings: settings)
                let filtered = ReaderTranslationLanguageFilter.apply(prepared, settings: settings)
                try Task.checkCancellation()
                return filtered
            }
            let eligible = try await withTaskCancellationHandler {
                try await filteringTask.value
            } onCancel: { filteringTask.cancel() }
            try Task.checkCancellation()
            if translate && !eligible.isEmpty {
                try publish(eligible, image: image, settings: settings, generation: issued, renderOverlay: renderOverlay)
                if let translateRegions { return try await translateRegions(eligible, settings) }
                let progress: ReaderTranslationService.Progress = { [weak self] partial in
                    try Task.checkCancellation()
                    try await self?.publish(partial, image: image, settings: settings, generation: issued, renderOverlay: renderOverlay)
                }
                if let progressiveTranslate { return try await progressiveTranslate(eligible, settings, progress) }
                return try await ReaderTranslationService.shared.translate(
                    regions: eligible, settings: settings, image: image, onProgress: progress
                )
            }
            return eligible.map {
                var region = $0
                region.translation = nil
                region.translationReuseIdentity = nil
                return region
            }
        }
        self.task = task
        defer { if generation == issued { self.task = nil } }
        let result = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        guard generation == issued, let imageView, imageView.image === image else { throw CancellationError() }
        completedTranslation = translate
        try publish(result, image: image, settings: settings, generation: issued, renderOverlay: renderOverlay)
        return result.count
    }

    var canExportTranslation: Bool {
        !isExportingTranslation && completedTranslation && analyzedImage != nil && analyzedImage === imageView?.image &&
            regions.contains { !($0.translation?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
    }

    func exportTranslatedImage(host: UIView) async throws -> UIImage {
        guard canExportTranslation, let imageView, let image = imageView.image, let settings = lastSettings else {
            throw ReaderTranslationImageExporter.ExportError.unavailable
        }
        isExportingTranslation = true
        defer { isExportingTranslation = false }
        // Freeze the tapped page, including its already-cropped regions, before any await.
        return try await ReaderTranslationImageExporter.render(
            image: image, regions: regions, settings: settings, viewport: imageView.bounds.size,
            aspectFit: imageView.contentMode == .scaleAspectFit, host: host
        )
    }

    func hasCompletedTranslation(settings: ReaderTranslationSettings) -> Bool {
        completedTranslation && analyzedImage != nil && analyzedImage === imageView?.image &&
            lastSettings?.hasSameTranslation(as: settings) == true
    }

    func showCompletedTranslation(settings: ReaderTranslationSettings) {
        previewRegions = nil
        guard hasCompletedTranslation(settings: settings) else { return }
        if (overlay == nil && cachedOverlay == nil) || lastSettings?.overlay != settings.overlay ||
            (renderCache != nil && overlay?.canCacheRendering == false), !regions.isEmpty, let image = imageView?.image {
            try? publish(regions, image: image, settings: settings, generation: generation)
        }
        overlay?.isHidden = !settings.overlay.visible
        cachedOverlay?.isHidden = !settings.overlay.visible
    }

    private func publish(
        _ result: [ReaderTranslationRegion], image: UIImage, settings: ReaderTranslationSettings, generation issued: UUID,
        renderOverlay: Bool = true
    ) throws {
        guard generation == issued, let imageView, imageView.image === image else { throw CancellationError() }
        regions = result
        analyzedImage = image
        analyzedConfiguration = settings.ocrConfiguration
        lastSettings = settings
        guard renderOverlay else { return }
        guard !result.isEmpty else { releaseOverlay(); return }
        if completedTranslation, let renderCache, let sourcePage, imageView.bounds.width > 0, imageView.bounds.height > 0 {
            let viewport = imageView.bounds.size
            let dark = imageView.traitCollection.userInterfaceStyle == .dark
            let key = ReaderTranslationCacheIdentity.render(
                page: sourcePage.translationCacheKey, settings: settings, imageSize: image.size, viewport: imageView.bounds.size,
                scale: imageView.traitCollection.displayScale, aspectFit: imageView.contentMode == .scaleAspectFit,
                crop: sourcePage.translationSourceRect ?? CGRect(x: 0, y: 0, width: 1, height: 1),
                dark: imageView.traitCollection.userInterfaceStyle == .dark
            )
            if let cached = renderCache.cachedImage(for: key) {
                displaySnapshot(cached, source: image, settings: settings)
                return
            }
            if renderLookupKey == key, renderLookupTask != nil { return }
            renderLookupTask?.cancel()
            renderLookupKey = key
            renderLookupTask = Task { [weak self] in
                let diskGeneration = await renderCache.disk.currentGeneration(settings: settings)
                let pageIdentity = ReaderTranslationCacheIdentity.translation(page: sourcePage.translationCacheKey, settings: settings)
                let cached = await renderCache.load(key, pageIdentity: pageIdentity)
                guard !Task.isCancelled, let self, generation == issued, imageView.image === image, renderLookupKey == key else { return }
                renderLookupTask = nil
                guard imageView.bounds.size == viewport, (imageView.traitCollection.userInterfaceStyle == .dark) == dark else {
                    renderLookupKey = nil
                    try? publish(result, image: image, settings: settings, generation: issued)
                    return
                }
                if let cached {
                    displaySnapshot(cached, source: image, settings: settings)
                } else {
                    let target = ReaderTranslationSnapshotTarget(
                        cache: renderCache, key: key, pageIdentity: pageIdentity,
                        diskGeneration: diskGeneration, viewport: imageView.bounds.size,
                        dark: imageView.traitCollection.userInterfaceStyle == .dark,
                        preparedLayout: renderCache.cachedLayout(for: key).map { data in Task { data } }
                    )
                    displayLive(result, image: image, settings: settings, target: target)
                }
                let crop = sourcePage.translationSourceRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
                // Split images round to whole pixels; reversing their crop can
                // invent a different full-page width. Only record exact sizes.
                if crop == CGRect(x: 0, y: 0, width: 1, height: 1) {
                    try? await renderCache.disk.storeImageSize(image.size,
                        page: sourcePage.translationCacheKey, generation: diskGeneration)
                }
            }
            return
        }
        displayLive(result, image: image, settings: settings, target: nil)
    }

    private func displayLive(_ result: [ReaderTranslationRegion], image: UIImage, settings: ReaderTranslationSettings,
                             target: ReaderTranslationSnapshotTarget?) {
        guard let imageView else { return }
        cachedOverlay?.removeFromSuperview()
        cachedOverlay = nil
        let overlay = overlay ?? ReaderTranslationOverlayView()
        if overlay.superview == nil {
            overlay.frame = imageView.bounds
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            // Keep dictionary selection and Live Text controls above the translated image.
            imageView.insertSubview(overlay, at: 0)
        }
        self.overlay = overlay
        let issued = generation
        overlay.onSnapshotStored = { [weak self, weak overlay, weak imageView] snapshot in
            guard let self, let overlay, self.overlay === overlay, generation == issued,
                  imageView?.image === image, completedTranslation, lastSettings == settings,
                  let target, imageView?.bounds.size == target.viewport,
                  (imageView?.traitCollection.userInterfaceStyle == .dark) == target.dark else { return }
            displaySnapshot(snapshot, source: image, settings: settings)
        }
        overlay.onCacheGeometryChanged = { [weak self] in
            guard let self, self.imageView?.image === image else { return }
            try? publish(regions, image: image, settings: settings, generation: generation)
        }
        overlay.isHidden = !settings.overlay.visible
        overlay.update(
            regions: result, imageSize: image.size, aspectFit: imageView.contentMode == .scaleAspectFit,
            settings: settings, image: image, snapshotTarget: target
        )
        overlay.layoutIfNeeded()
    }

    private func displaySnapshot(_ snapshot: UIImage, source: UIImage, settings: ReaderTranslationSettings) {
        guard let imageView else { return }
        releaseOverlay()
        let canvas = ReaderTranslationCachedPageView(image: snapshot)
        canvas.frame = imageView.bounds
        canvas.initialSize = imageView.bounds.size
        canvas.initialStyle = imageView.traitCollection.userInterfaceStyle
        canvas.initialScale = imageView.traitCollection.displayScale
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvas.isHidden = !settings.overlay.visible
        canvas.accessibilityIdentifier = "reader.translation.cachedOverlay"
        canvas.onGeometryChanged = { [weak self, weak canvas, weak imageView] in
            guard let self, let canvas, cachedOverlay === canvas, imageView?.image === source else { return }
            releaseOverlay()
            if let previewRegions {
                displayPreparedSnapshot(previewRegions, settings: settings)
            } else {
                try? publish(regions, image: source, settings: settings, generation: generation)
            }
        }
        cachedOverlay = canvas
        imageView.insertSubview(canvas, at: 0)
    }

    func displayPrepared(_ result: [ReaderTranslationRegion], settings: ReaderTranslationSettings, completed: Bool = true) {
        previewRegions = nil
        guard let image = imageView?.image else { return }
        if hasCompletedTranslation(settings: settings) {
            showCompletedTranslation(settings: settings)
            return
        }
        let rect = sourcePage?.translationSourceRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let displayed = result.compactMap { $0.cropped(to: rect) }
        if analyzedImage === image, regions == displayed, lastSettings == settings, completedTranslation == completed,
           overlay != nil || cachedOverlay != nil {
            return
        }
        cancel()
        completedTranslation = completed
        try? publish(displayed, image: image, settings: settings, generation: generation)
    }

    /// Attach a finished composite to an adjacent reader view before a swipe.
    /// A cache miss leaves the source alone; only the session's bounded renderer
    /// may create missing pixels. Never create a WebKit view per preload page.
    func displayPreparedSnapshot(_ result: [ReaderTranslationRegion], settings: ReaderTranslationSettings) {
        guard let imageView, let image = imageView.image, let sourcePage, let renderCache,
              imageView.bounds.width > 0, imageView.bounds.height > 0 else { return }
        if isUsingCachedRendering, analyzedImage === image, lastSettings == settings { return }
        let viewport = imageView.bounds.size
        let dark = imageView.traitCollection.userInterfaceStyle == .dark
        let crop = sourcePage.translationSourceRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let key = ReaderTranslationCacheIdentity.render(page: sourcePage.translationCacheKey, settings: settings,
            imageSize: image.size, viewport: viewport, scale: imageView.traitCollection.displayScale,
            aspectFit: imageView.contentMode == .scaleAspectFit, crop: crop, dark: dark)
        if let snapshot = renderCache.cachedImage(for: key) {
            acceptPreview(snapshot, result: result, image: image, crop: crop, settings: settings)
            return
        }
        guard renderLookupKey != key || renderLookupTask == nil else { return }
        renderLookupTask?.cancel()
        renderLookupKey = key
        let issued = generation
        let identity = ReaderTranslationCacheIdentity.translation(page: sourcePage.translationCacheKey, settings: settings)
        renderLookupTask = Task { [weak self, weak imageView] in
            let snapshot = await renderCache.load(key, pageIdentity: identity, cancelPreparation: false)
            guard !Task.isCancelled, let self, let imageView, generation == issued,
                  imageView.image === image, renderLookupKey == key else { return }
            renderLookupTask = nil
            guard let snapshot, imageView.bounds.size == viewport,
                  (imageView.traitCollection.userInterfaceStyle == .dark) == dark else { return }
            acceptPreview(snapshot, result: result, image: image, crop: crop, settings: settings)
        }
    }

    private func acceptPreview(_ snapshot: UIImage, result: [ReaderTranslationRegion], image: UIImage,
                               crop: CGRect, settings: ReaderTranslationSettings) {
        cancel()
        previewRegions = result
        regions = result.compactMap { $0.cropped(to: crop) }
        analyzedImage = image
        analyzedConfiguration = settings.ocrConfiguration
        lastSettings = settings
        completedTranslation = true
        displaySnapshot(snapshot, source: image, settings: settings)
    }

    func applySettings(_ settings: ReaderTranslationSettings) {
        cancel()
        guard let old = lastSettings, let image = imageView?.image, analyzedImage === image else { return }
        if let previewRegions {
            releaseOverlay()
            if old.hasSameTranslation(as: settings), settings.automaticallyTranslate {
                displayPreparedSnapshot(previewRegions, settings: settings)
            } else {
                self.previewRegions = nil
                completedTranslation = false
                lastSettings = settings
            }
            return
        }
        guard old.ocrConfiguration == settings.ocrConfiguration else { reset(); return }
        if old.rightToLeftPanelOrder != settings.rightToLeftPanelOrder || old.sourceLanguage != settings.sourceLanguage ||
            ReaderTranslationLanguageFilter.identity(settings: old) != ReaderTranslationLanguageFilter.identity(settings: settings) {
            completedTranslation = false
            regions = []
            lastSettings = settings
            releaseOverlay()
            return
        }
        let wasHidden = overlay?.isHidden ?? cachedOverlay?.isHidden ?? true
        if old.includePageImage != settings.includePageImage || old.configuration != settings.configuration || old.sourceLanguage != settings.sourceLanguage ||
            old.targetLanguage != settings.targetLanguage {
            completedTranslation = false
            regions = regions.map {
                var region = $0
                region.translation = nil
                region.translationReuseIdentity = nil
                return region
            }
        }
        guard overlay != nil || cachedOverlay != nil else { lastSettings = settings; return }
        try? publish(regions, image: image, settings: settings, generation: generation)
        if wasHidden || !settings.automaticallyTranslate { overlay?.isHidden = true; cachedOverlay?.isHidden = true }
    }
}

@MainActor private final class ReaderTranslationCachedPageView: UIImageView {
    var initialSize = CGSize.zero
    var initialStyle: UIUserInterfaceStyle = .unspecified
    var initialScale: CGFloat = 0
    var onGeometryChanged: (() -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != initialSize { onGeometryChanged?() }
    }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.userInterfaceStyle != initialStyle || traitCollection.displayScale != initialScale { onGeometryChanged?() }
    }
}
