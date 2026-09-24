//
//  ReaderWebtoonPageNode.swift
//  Aidoku (iOS)
//
//  Created by Skitty on 3/1/23.
//

import AidokuRunner
import AsyncDisplayKit
import Gifu
import Nuke
import SwiftUI
import Vision
import VisionKit
import ZIPFoundation

class ReaderWebtoonPageNode: BaseObservingCellNode {
    let source: AidokuRunner.Source?
    let page: Page
    let temporaryPageStore: ReaderTemporaryPageStore
    let pillarboxLayoutState: ReaderPillarboxLayoutState

    weak var delegate: ReaderWebtoonViewController?

    var image: UIImage? {
        didSet {
            guard let image, image.size.width > 0 else { return }
            ratio = image.size.height / image.size.width
        }
    }
    var prepareTranslationForDisplay: ReaderTranslationImagePreparer?
    private var preparedTranslation: ReaderTranslationPreparedImage?
    private var hasLoadFailure = false
    private var lastTranslationLayoutSize = CGSize.zero
    var text: String?
    var ratio: CGFloat?

    private var pageLoadTask: Task<Void, Never>?
    private var pageLoadGeneration = UUID()
    private var imageTask: ImageTask?
    private var imageProcessingTask: Task<UIImage?, Never>?

    private var shouldShowLiveTextButton = false
    private var liveTextAnalysisTask: Task<Void, Never>?

    private var hasScheduledDictionaryTextAnalysis = false
    private var needsDictionaryOverlayRender = false
    private var dictionaryAnalysisTask: Task<Void, Never>?
    private var _translationPage: ReaderTranslationPage?

    @MainActor
    var translationPage: ReaderTranslationPage? {
        guard let imageView = imageNode.imageView else { return nil }
        if let existing = _translationPage, existing.imageView === imageView { return existing }
        let page = ReaderTranslationPage(imageView: imageView)
        page.sourcePage = self.page
        _translationPage = page
        return page
    }
    var onDictionaryOverlayTap: ((String, String, CGRect, [CGRect]) -> Void)? {
        get { dictionaryOverlayController.onLookup }
        set { dictionaryOverlayController.onLookup = newValue }
    }
    private let dictionaryOverlayController = DictionaryOverlayController()

    private var _textRecognizer: Any?
    @available(iOS 18.0, *)
    var textRecognizer: TextRecognizer? {
        get { _textRecognizer as? TextRecognizer }
        set { _textRecognizer = newValue }
    }

    private var currentImageRequest: ImageRequest?

    var pillarbox = UserDefaults.standard.bool(forKey: "Reader.pillarbox")
    var pillarboxAmount = CGFloat(UserDefaults.standard.double(forKey: "Reader.pillarboxAmount"))
    var pillarboxOrientation = UserDefaults.standard.string(forKey: "Reader.pillarboxOrientation")

    static let defaultRatio: CGFloat = 1.435

    private var pageWidth: CGFloat {
        calculatedSize.width
    }

    var progressView: CircularProgressView {
        (progressNode.view as? CircularProgressView)!
    }

    lazy var imageNode: GIFImageNode = {
        let node = GIFImageNode()
        node.alpha = 0
        node.contentMode = .scaleToFill
        node.shouldAnimateSizeChanges = false
        node.isUserInteractionEnabled = false
        node.onImageAssigned = { [weak self] imageView in
            guard let self else { return false }
            guard let image = imageView.image else {
                self._translationPage?.reset()
                return true
            }
            if let prepared = self.preparedTranslation {
                guard prepared.isCurrent() else {
                    self._translationPage?.reset()
                    self.refreshPreparedImage(image)
                    return false
                }
                self.translationPage?.displayLoadedImage(prepared)
            }
            return true
        }
        return node
    }()

    lazy var textNode = HostingNode(content: MarkdownView(page.text ?? ""))

    lazy var progressNode = ASCellNode(viewBlock: {
        CircularProgressView()
    })

    private lazy var retryNode: ASButtonNode = {
        let node = ASButtonNode()
        node.setTitle(NSLocalizedString("RETRY"), with: .systemFont(ofSize: 17), with: .systemBlue, for: .normal)
        node.addTarget(self, action: #selector(retryPageLoad), forControlEvents: .touchUpInside)
        return node
    }()

    init(
        source: AidokuRunner.Source?,
        page: Page,
        temporaryPageStore: ReaderTemporaryPageStore,
        pillarboxLayoutState: ReaderPillarboxLayoutState
    ) {
        self.source = source
        self.page = page
        self.temporaryPageStore = temporaryPageStore
        self.pillarboxLayoutState = pillarboxLayoutState
        super.init()

        automaticallyManagesSubnodes = true
        shouldAnimateSizeChanges = false

        addObserver(forName: "Reader.pillarbox") { [weak self] notification in
            self?.pillarbox = notification.object as? Bool ?? false
            self?.transition()
        }
        addObserver(forName: "Reader.pillarboxAmount") { [weak self] notification in
            guard let doubleValue = notification.object as? Double else { return }
            self?.pillarboxAmount = CGFloat(doubleValue)
            self?.transition()
        }
        addObserver(forName: "Reader.pillarboxOrientation") { [weak self] notification in
            self?.pillarboxOrientation = notification.object as? String ?? "both"
            self?.transition()
        }
        addObserver(forName: UIApplication.didReceiveMemoryWarningNotification.rawValue) { [weak self] _ in
            self?.handleMemoryWarning()
        }
    }

    deinit {
        cancelLiveTextAnalysis()
        cancelDictionaryTextAnalysis()
    }

    override func layout() {
        super.layout()

        if lastTranslationLayoutSize != calculatedSize {
            lastTranslationLayoutSize = calculatedSize
            NotificationCenter.default.post(name: ReaderTranslationLayoutAwaiter.geometryChanged, object: self)
        }

        if needsDictionaryOverlayRender {
            renderDictionaryOverlaysIfNeeded()
        }
    }

    override func didEnterPreloadState() {
        super.didEnterPreloadState()
        startPageLoad()
    }

    override func didExitPreloadState() {
        super.didExitPreloadState()
        cancelPageLoad()
    }

    override func didEnterVisibleState() {
        super.didEnterVisibleState()
        imageTask?.priority = .high
        Task { @MainActor in NotificationCenter.default.post(name: ReaderTranslationPage.imageChanged, object: nil) }
        displayPage()
    }

    override func didEnterDisplayState() {
        super.didEnterDisplayState()
        displayPage()
    }

    override func didExitVisibleState() {
        super.didExitVisibleState()
        imageTask?.priority = .low
        Task { @MainActor in NotificationCenter.default.post(name: ReaderTranslationPage.imageChanged, object: nil) }
    }

    override func didExitDisplayState() {
        super.didExitDisplayState()
        guard !isVisible else { return }

        // don't hide images if zooming in/out
        if let delegate, delegate.isZooming {
            return
        }

        cancelLiveTextAnalysis()
        cancelDictionaryTextAnalysis()
        clearDisplayedImage()
        clearDictionaryOverlays()
        hasScheduledDictionaryTextAnalysis = false
        needsDictionaryOverlayRender = false

        text = nil
        imageNode.alpha = 0
        textNode.alpha = 0
        progressNode.isHidden = false
    }

    override func animateLayoutTransition(_ context: ASContextTransitioning) {
        UIView.animate(
            withDuration: 0.3,
            delay: 0,
            options: [
                .transitionCrossDissolve,
                .allowUserInteraction,
                .curveEaseInOut
            ]
        ) {
            if self.image != nil {
                self.imageNode.alpha = 1
            } else if self.text != nil {
                self.textNode.alpha = 1
            } else {
                self.imageNode.alpha = 0
                self.textNode.alpha = 0
            }
        } completion: { [weak self] _ in
            guard let self = self else { return }
            self.imageNode.frame = context.finalFrame(for: self.imageNode)
            self.textNode.frame = context.finalFrame(for: self.textNode)
            if let delegate = self.delegate {
                Task { @MainActor in
                    delegate.scrollView.contentOffset = delegate.collectionNode.contentOffset
                    delegate.zoomView.adjustContentSize()
                }
            }
            context.completeTransition(true)
        }

        // handle inserting cell above
        guard
            let indexPath,
            let collectionNode = owningNode as? ASCollectionNode,
            let layout = collectionNode.collectionViewLayout as? VerticalContentOffsetPreservingLayout,
            let yOffset = collectionNode.collectionViewLayout.layoutAttributesForItem(at: indexPath)?.frame.origin.y
        else { return }
        layout.isInsertingCellsAbove = yOffset < collectionNode.contentOffset.y
    }
}

extension ReaderWebtoonPageNode {
    func getPillarboxHeight(percent: CGFloat, maxWidth: CGFloat) -> CGFloat {
        guard let image, image.size.width > 0 else { return 0 }
        let width = maxWidth * percent
        return width / image.size.width * image.size.height
    }

    func isPillarboxOrientation() -> Bool {
        pillarboxOrientation == "both"
            || (pillarboxOrientation == "portrait" && pillarboxLayoutState.isPortrait)
            || (pillarboxOrientation == "landscape" && !pillarboxLayoutState.isPortrait)
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        if let image {
            if pillarbox && isPillarboxOrientation() {
                let percent = (100 - pillarboxAmount) / 100
                let height = getPillarboxHeight(percent: percent, maxWidth: constrainedSize.max.width)

                imageNode.style.width = ASDimensionMakeWithFraction(percent)
                imageNode.style.height = ASDimensionMakeWithPoints(height)
                imageNode.style.alignSelf = .center

                return ASCenterLayoutSpec(
                    horizontalPosition: .center,
                    verticalPosition: .center,
                    sizingOption: [],
                    child: imageNode
                )
            } else {
                let ratio = image.size.width > 0
                    ? image.size.height / image.size.width
                    : Self.defaultRatio
                return ASRatioLayoutSpec(ratio: ratio, child: imageNode)
            }
        } else if text != nil {
            // todo: the text node should probably adjust its size based on the text
            if pillarbox && isPillarboxOrientation() {
                let percent = (100 - pillarboxAmount) / 100
                let ratio = percent * (ratio ?? Self.defaultRatio)

                return ASRatioLayoutSpec(
                    ratio: ratio,
                    child: textNode
                )
            } else {
                return ASRatioLayoutSpec(
                    ratio: ratio ?? Self.defaultRatio,
                    child: textNode
                )
            }
        } else {
            let loadingNode: ASDisplayNode = hasLoadFailure ? retryNode : progressNode
            if pillarbox && isPillarboxOrientation() {
                let percent = (100 - pillarboxAmount) / 100
                let ratio = percent * (ratio ?? Self.defaultRatio)

                return ASRatioLayoutSpec(
                    ratio: ratio,
                    child: loadingNode
                )
            } else {
                return ASRatioLayoutSpec(
                    ratio: ratio ?? Self.defaultRatio,
                    child: loadingNode
                )
            }
        }
    }
}

extension ReaderWebtoonPageNode {
    private func startPageLoad() {
        guard pageLoadTask == nil, image == nil, text == nil, !hasLoadFailure else { return }

        pageLoadGeneration = UUID()
        let issued = pageLoadGeneration
        pageLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadPage()
            if self.pageLoadGeneration == issued { self.pageLoadTask = nil }
        }
    }

    private func cancelPageLoad() {
        pageLoadGeneration = UUID()
        pageLoadTask?.cancel()
        pageLoadTask = nil

        imageTask?.cancel()
        imageTask = nil

        imageProcessingTask?.cancel()
        imageProcessingTask = nil
    }

    func loadPage() async {
        guard image == nil, text == nil, !Task.isCancelled else { return }

        imageNode.alpha = 0
        textNode.alpha = 0
        progressNode.isHidden = false
        progressNode.isUserInteractionEnabled = false

        if let image = page.image {
            await prepareAndDisplayImage(image)
        } else if let zipURL = page.zipURL, let url = URL(string: zipURL), let filePath = page.imageURL {
            await loadImage(zipURL: url, filePath: filePath)
        } else if let urlString = page.imageURL, let url = URL(string: urlString) {
            await loadImage(url: url, context: page.context)
        } else if let base64 = page.base64 {
            await loadImage(base64: base64)
        } else if let text = page.text {
            loadText(text)
        } else {
            await showLoadFailure()
        }
    }

    private func loadImage(url: URL, context: PageContext?) async {
        let urlRequest = if !url.isFileURL, let source {
            await source.getModifiedImageRequest(url: url, context: context)
        } else {
            URLRequest(url: url)
        }

        let width = pageWidth
        let shouldDownsample = UserDefaults.standard.bool(forKey: "Reader.downsampleImages") && width > 0
        let shouldUpscale = UserDefaults.standard.bool(forKey: "Reader.upscaleImages")
        let shouldCropBorders = UserDefaults.standard.bool(forKey: "Reader.cropBorders")
        var processors: [ImageProcessing] = []
        var usePageProcessor = false
        if
            let source,
            source.features.processesPages,
            !url.isFileURL
        {
            // only process pages if the source supports it and the image isn't downloaded
            processors.append(PageInterceptorProcessor(source: source, pageContext: context))
            usePageProcessor = true
        }
        if shouldCropBorders {
            processors.append(CropBordersProcessor())
        }
        if shouldDownsample {
            processors.append(await DownsampleProcessor(width: width))
        } else if shouldUpscale {
            processors.append(UpscaleProcessor())
        }

        let request = ImageRequest(
            urlRequest: urlRequest,
            processors: processors,
            priority: isVisible ? .high : .low,
            userInfo: [.processesKey: usePageProcessor]
        )

        // Store current image request for reload functionality
        self.currentImageRequest = request

        let imageTask = ImagePipeline.shared.loadImage(
            with: request,
            progress: { [weak progressView] _, completed, total in
                guard let progressView else { return }
                Task { @MainActor in
                    progressView.setProgress(value: Float(completed) / Float(total), withAnimation: false)
                }
            },
            completion: { _ in }
        )
        self.imageTask = imageTask

        do {
            let response = try await imageTask.response
            guard !Task.isCancelled else { return }
            await prepareAndDisplayImage(response.image, gifData: response.container.type == .gif ? response.container.data : nil)
        } catch {
            guard !Task.isCancelled else { return }

            switch error {
                case .dataLoadingFailed, .dataIsEmpty:
                    // we can still send to image processor even if the request failed
                    if request.userInfo[.processesKey] as? Bool == true {
                        let processor = request.processors.first(where: { $0 is PageInterceptorProcessor }) as? PageInterceptorProcessor
                        if let processor {
                            let result = await Task.detached {
                                try? processor.processWithoutImage(request: request)
                            }.value

                            guard !Task.isCancelled else { return }

                            if let result {
                                await prepareAndDisplayImage(result.image, gifData: result.type == .gif ? result.data : nil)
                                return
                            }
                        }
                    }
                default:
                    break
            }

            await showLoadFailure()
        }
    }

    private func loadImage(base64: String) async {
        let fullKey = "\(page.key)-\(ImageProcessingSettingsKey.getProcessorSettingsKey())"
        let request = ImageRequest(
            id: fullKey,
            data: { Data() },
            userInfo: [:]
        )

        // Store current image request for reload functionality
        self.currentImageRequest = request

        progressNode.isHidden = false

        // check cache
        if ImagePipeline.shared.cache.containsCachedImage(for: request) {
            let imageContainer = ImagePipeline.shared.cache.cachedImage(for: request)
            await prepareAndDisplayImage(imageContainer?.image)
            return
        }

        let downsampleWidth = pageWidth
        let shouldDownsample = UserDefaults.standard.bool(forKey: "Reader.downsampleImages") && downsampleWidth > 0

        let processingTask = Task.detached { () -> UIImage? in
            guard
                let imageData = Data(base64Encoded: base64),
                var image = UIImage(data: imageData)
            else {
                return nil
            }

            if UserDefaults.standard.bool(forKey: "Reader.cropBorders") {
                let processor = CropBordersProcessor()
                if let processedImage = processor.process(image) {
                    image = processedImage
                }
            }
            if shouldDownsample {
                let processor = await DownsampleProcessor(width: downsampleWidth)
                if let processedImage = processor.process(image) {
                    image = processedImage
                }
            } else if UserDefaults.standard.bool(forKey: "Reader.upscaleImages") {
                let processor = UpscaleProcessor()
                if let processedImage = processor.process(image) {
                    image = processedImage
                }
            }

            return image
        }
        let processingGeneration = pageLoadGeneration
        self.imageProcessingTask = processingTask
        let image = await processingTask.value
        if pageLoadGeneration == processingGeneration { self.imageProcessingTask = nil }
        guard !Task.isCancelled else { return }
        guard let image else {
            await showLoadFailure()
            return
        }

        ImagePipeline.shared.cache.storeCachedImage(ImageContainer(image: image), for: request)
        await prepareAndDisplayImage(image)
    }

    private func loadImage(zipURL: URL, filePath: String) async {
        guard let extractedURL = await self.temporaryPageStore.storeArchiveEntry(
            from: zipURL,
            path: filePath
        ) else {
            if !Task.isCancelled { await showLoadFailure() }
            return
        }
        guard !Task.isCancelled else { return }
        await loadImage(url: extractedURL, context: nil)
    }

    @MainActor
    func translationImageGeometry(for image: UIImage) -> ReaderTranslationImageGeometry? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        var width = calculatedSize.width
        if width <= 0 { width = delegate?.collectionNode.bounds.width ?? 0 }
        if pillarbox && isPillarboxOrientation() { width *= (100 - pillarboxAmount) / 100 }
        let traits = imageNode.imageView?.traitCollection ?? delegate?.traitCollection ?? UITraitCollection.current
        return ReaderTranslationImageGeometry(
            viewport: CGSize(width: width, height: width * image.size.height / image.size.width),
            scale: traits.displayScale,
            aspectFit: false,
            dark: traits.userInterfaceStyle == .dark
        )
    }

    @MainActor
    @discardableResult
    private func prepareAndDisplayImage(_ sourceImage: UIImage?, gifData: Data? = nil) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard let sourceImage else {
            showLoadFailure()
            return false
        }
        let issued = pageLoadGeneration
        do {
            while true {
                try Task.checkCancellation()
                let prepared: ReaderTranslationPreparedImage?
                if let prepareTranslationForDisplay {
                    prepared = try await prepareTranslationForDisplay(sourceImage, page)
                } else {
                    prepared = try await delegate?.delegate?.prepareCachedTranslationForDisplay(image: sourceImage, page: page, geometry: { [weak self] in
                        self?.translationImageGeometry(for: sourceImage)
                    })
                }
                try Task.checkCancellation()
                guard issued == pageLoadGeneration else { return false }
                if prepared?.isCurrent() == false { continue }

                // Keep decoded source pixels for OCR and save/share. The backing view
                // receives them together with this source-aspect translated canvas.
                _translationPage?.reset()
                preparedTranslation = prepared
                imageNode.animatedData = gifData
                image = sourceImage
                imageNode.image = sourceImage
                if imageNode.imageView != nil, !imageNode.commitImage() { continue }
                ReaderTranslationPage.sourceDidLoad(sourceImage, page: page)
                if isNodeLoaded { displayPage() }
                return true
            }
        } catch is CancellationError {
            return false
        } catch {
            guard !Task.isCancelled, issued == pageLoadGeneration else { return false }
            // A failed cached overlay does not invalidate the decoded source.
            ReaderTranslationDiagnostics.record("loaded_presentation_fallback")
            _translationPage?.reset()
            preparedTranslation = nil
            imageNode.animatedData = gifData
            image = sourceImage
            imageNode.image = sourceImage
            if imageNode.imageView != nil { imageNode.commitImage() }
            ReaderTranslationPage.sourceDidLoad(sourceImage, page: page)
            if isNodeLoaded { displayPage() }
            return true
        }
    }

    @MainActor
    private func refreshPreparedImage(_ image: UIImage) {
        let issued = pageLoadGeneration
        let finishingLoad = pageLoadTask
        Task { @MainActor [weak self] in
            await finishingLoad?.value
            guard let self, issued == pageLoadGeneration, self.image === image,
                  preparedTranslation?.isCurrent() == false else { return }
            // A late Texture backing view can bind after rotation/settings changed.
            // Retry from the retained decoded image; generation deduplicates callbacks.
            pageLoadGeneration = UUID()
            let refresh = pageLoadGeneration
            pageLoadTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await prepareAndDisplayImage(image, gifData: imageNode.animatedData)
                if pageLoadGeneration == refresh { pageLoadTask = nil }
            }
        }
    }

    @MainActor
    private func showLoadFailure() {
        preparedTranslation = nil
        image = nil
        imageNode.reset()
        _translationPage?.reset()
        hasLoadFailure = true
        progressNode.isHidden = true
        transition()
    }

    @objc private func retryPageLoad() {
        hasLoadFailure = false
        startPageLoad()
        transition()
    }

    private func loadText(_ text: String) {
        self.text = text
        if isNodeLoaded {
            displayPage()
        }
    }

    func displayPage() {
        guard text != nil || image != nil else {
            startPageLoad()
            return
        }

        if let image {
            progressNode.isHidden = true
            imageNode.image = image

            Task { @MainActor in
                imageNode.isUserInteractionEnabled = true
                imageNode.view.interactions
                    .filter { $0 is UIContextMenuInteraction }
                    .forEach { imageNode.view.removeInteraction($0) }
                if let delegate {
                    imageNode.addInteraction(UIContextMenuInteraction(delegate: delegate))
                }

                if
                    #available(iOS 16.0, *),
                    UserDefaults.standard.bool(forKey: "Reader.liveText"),
                    ImageAnalyzer.isSupported,
                    imageNode.imageAnalaysisInteraction == nil
                {
                    let interaction = ImageAnalysisInteraction()
                    interaction.preferredInteractionTypes = .automatic
                    imageNode.addInteraction(interaction)
                    await analyzeLiveText()
                }

                if isVisible, !hasScheduledDictionaryTextAnalysis {
                    hasScheduledDictionaryTextAnalysis = true
                    scheduleDictionaryTextAnalysis()
                }
            }
        } else if let text {
            progressNode.isHidden = true
            textNode.content = MarkdownView(text)
            clearDictionaryOverlays()
        }

        transition()
    }

    private func clearDisplayedImage() {
        cancelPageLoad()
        preparedTranslation = nil
        hasLoadFailure = false
        Task { @MainActor [weak self, page = _translationPage] in
            guard self?.image == nil else { return }
            page?.reset()
        }
        imageNode.reset()
        image = nil
    }

    private func transition() {
        let width = pageWidth
        guard width > 0 else { return }
        let ratio = if let image, image.size.width > 0 {
            image.size.height / image.size.width
        } else {
            ratio ?? Self.defaultRatio
        }
        let size = CGSize(width: width, height: width * ratio)
        frame = CGRect(origin: .zero, size: size)
        transitionLayout(with: ASSizeRange(min: .zero, max: size), animated: true, shouldMeasureAsync: false)
    }

    @MainActor
    private func analyzeLiveText() async {
        guard #available(iOS 16.0, *), let image else { return }

        if let liveTextAnalysisTask {
            return await liveTextAnalysisTask.value
        }

        liveTextAnalysisTask = Task { @MainActor [weak self] in
            let analyzer = ImageAnalyzer()
            let analysis = try? await analyzer.analyze(image, configuration: .init([.text, .machineReadableCode]))

            guard
                !Task.isCancelled,
                let self,
                let interaction = self.imageNode.imageAnalaysisInteraction
            else {
                return
            }

            interaction.analysis = analysis
            interaction.isSupplementaryInterfaceHidden = !self.shouldShowLiveTextButton
        }

        await liveTextAnalysisTask?.value
    }

    private func cancelLiveTextAnalysis() {
        liveTextAnalysisTask?.cancel()
        liveTextAnalysisTask = nil

        if #available(iOS 16.0, *) {
            Task { @MainActor [weak imageNode] in
                imageNode?.removeImageAnalysisInteraction()
            }
        }
    }

    @MainActor
    private func scheduleDictionaryTextAnalysis() {
        needsDictionaryOverlayRender = false
        clearDictionaryOverlays()

        if #available(iOS 18.0, *) {
            DictionaryTextAnalysisScheduler.schedule(
                task: &dictionaryAnalysisTask,
                recognizer: &textRecognizer,
                image: image,
                language: page.language
            ) { [weak self] in
                self?.renderDictionaryOverlaysIfNeeded()
            }
        }
    }

    private func cancelDictionaryTextAnalysis() {
        if #available(iOS 18.0, *) {
            DictionaryTextAnalysisScheduler.cancel(
                task: &dictionaryAnalysisTask,
                recognizer: textRecognizer
            )
        }
    }

    @MainActor
    func setLiveTextHidden(_ hidden: Bool) {
        if #available(iOS 16.0, *) {
            shouldShowLiveTextButton = !hidden
            // don't hide if the text highlighting is active
            guard imageNode.imageAnalaysisInteraction?.selectableItemsHighlighted == false else { return }
            imageNode.imageAnalaysisInteraction?.isSupplementaryInterfaceHidden = hidden
        }
    }

    private func handleMemoryWarning() {
        cancelLiveTextAnalysis()
        cancelDictionaryTextAnalysis()
        clearDictionaryOverlays()

        // remove data from non-visible pages
        guard !isVisible else { return }

        cancelPageLoad()
        clearDisplayedImage()
        text = nil

        imageNode.alpha = 0
        textNode.alpha = 0
        progressNode.isHidden = false
    }

}

// MARK: - Dictionary Overlay
extension ReaderWebtoonPageNode {
    private func clearDictionaryOverlays() {
        dictionaryOverlayController.clear()
    }

    private func renderDictionaryOverlaysIfNeeded() {
        guard imageNode.bounds.width > 0 else {
            needsDictionaryOverlayRender = true
            return
        }

        needsDictionaryOverlayRender = false
        clearDictionaryOverlays()

        guard
            #available(iOS 18.0, *),
            AppSettings.dictionary.enable.get(),
            AppSettings.dictionary.textOverlayMode.get(),
            let textRecognizer,
            let image,
            let imageView = imageNode.imageView
        else {
            return
        }

        let overlays = textRecognizer.paragraphOverlays(in: imageView, imageSize: image.size)
        dictionaryOverlayController.containerView = imageView
        dictionaryOverlayController.render(overlays: overlays)
    }

    @discardableResult
    func dismissActiveDictionaryOverlay() -> Bool {
        dictionaryOverlayController.dismissActive()
    }

    func setDictionaryOverlayInteractionMode(_ mode: DictionaryOverlayInteractionMode) {
        dictionaryOverlayController.interactionMode = mode
        renderDictionaryOverlaysIfNeeded()
    }
}

// MARK: - Image Reload Functionality
extension ReaderWebtoonPageNode {
    /// Reloads the current image by clearing its cache and re-fetching from the source
    @MainActor
    func reloadCurrentImage() async -> Bool {
        cancelPageLoad()
        // Clear the cache for the current image
        clearCurrentImageCache()

        // Clear the current image and text to show loading state
        clearDisplayedImage()
        text = nil

        // Reload the image using the original page data
        startPageLoad()
        await pageLoadTask?.value
        return image != nil || text != nil
    }

    /// Clears the cache entry for the current image
    private func clearCurrentImageCache() {
        let settingsKey = ImageProcessingSettingsKey.getProcessorSettingsKey()
        // Handle different image types
        if let urlString = page.imageURL, let url = URL(string: urlString) {
            // For URL-based images, remove from both memory and disk cache
            if let currentImageRequest = currentImageRequest {
                ImagePipeline.shared.cache.removeCachedImage(for: currentImageRequest)
            }

            // Also try to remove the basic URL request from cache
            let basicRequest = ImageRequest(url: url)
            ImagePipeline.shared.cache.removeCachedImage(for: basicRequest)

        } else if page.base64 != nil {
            // For base64 images, remove using the page key
            let fullKey = "\(page.key)-\(settingsKey)"
            let request = ImageRequest(id: fullKey, data: { Data() })
            ImagePipeline.shared.cache.removeCachedImage(for: request)

        } else if let zipURL = page.zipURL, let url = URL(string: zipURL), let filePath = page.imageURL {
            // For zip-based images, remove using the generated key
            var hasher = Hasher()
            hasher.combine(url)
            hasher.combine(filePath)
            let key = String(hasher.finalize())
            let fullKey = "\(key)-\(settingsKey)"
            let request = ImageRequest(id: fullKey, data: { Data() })
            ImagePipeline.shared.cache.removeCachedImage(for: request)
        }
    }
}
