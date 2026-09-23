// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import CoreText
import UIKit
import WebKit

struct BrowserStatusAnnouncementState: Equatable, Sendable {
    private(set) var persistentSemanticIDs: Set<String> = []
    private(set) var lastTransientSemanticID: String?

    mutating func shouldAnnounce(
        _ semanticID: String,
        persistsAcrossHides: Bool = true
    ) -> Bool {
        if persistsAcrossHides {
            return persistentSemanticIDs.insert(semanticID).inserted
        }
        guard lastTransientSemanticID != semanticID else { return false }
        lastTransientSemanticID = semanticID
        return true
    }

    mutating func statusHidden() {
        lastTransientSemanticID = nil
    }

    mutating func reset() {
        persistentSemanticIDs.removeAll(keepingCapacity: true)
        lastTransientSemanticID = nil
    }
}

struct BrowserPageImageOverlayDiagnostic: Equatable, Sendable {
    enum Operation: String, Equatable, Sendable {
        case render
        case clear
    }

    enum Failure: String, Equatable, Sendable {
        case webViewUnavailable
        case javaScriptEvaluationFailed
        case malformedJavaScriptResult
    }

    enum Outcome: Equatable, Sendable {
        case committed
        case cleared
        case stale
        case failed(Failure)
    }

    let operation: Operation
    let revision: UInt64
    let outcome: Outcome
    let renderedItemCount: Int
}

/// Serialize CPU-heavy layout away from UIKit. Only immutable data crosses back.
private actor BrowserPageImageOverlayLayoutWorker {
    static let shared = BrowserPageImageOverlayLayoutWorker()
    // Progressive batches revisit the same text/font/width measurements.
    // Actor confinement permits reuse of the existing bounded, exact-key cache.
    private let measurementCache = BrowserOverlayTextMeasurementCache()

    func payload(
        items: [BrowserOverlayItem], imageSize: CGSize, sourceRect: CGRect,
        settings: IPhoneOverlaySettings, targetLanguage: String, viewport: CGSize
    ) throws -> Data {
        try Task.checkCancellation()
        return try autoreleasepool {
            let payload = BrowserPageImageOverlayRenderer.layoutPayload(
                items: items, imageSize: imageSize, sourceRect: sourceRect,
                settings: settings, targetLanguage: targetLanguage, viewport: viewport,
                measurementCache: measurementCache
            )
            try Task.checkCancellation()
            return try JSONSerialization.data(withJSONObject: payload)
        }
    }
}

/// Renders replacement text in the page's own CSS coordinate system. Unlike
/// native sibling UIViews, these nodes inherit the same pinch zoom, scrolling,
/// and compositing transform as the source image while remaining crisp text.
@MainActor
final class BrowserPageImageOverlayRenderer {
    typealias JavaScriptEvaluator = @MainActor (
        _ webView: WKWebView,
        _ script: String,
        _ arguments: [String: Any]
    ) async throws -> Any?

    private var revision: UInt64 = 0
    private var renderTask: Task<Void, Never>?
    /// Revisions are monotonic only for one renderer instance. WKWebView can
    /// preserve the isolated-world globals and DOM across an app/controller
    /// rebuild, so a process-local revision alone cannot order two sessions.
    private let sessionIdentifier = UUID().uuidString
    private let javaScriptEvaluator: JavaScriptEvaluator

    var onDiagnostic: ((BrowserPageImageOverlayDiagnostic) -> Void)?
    private(set) var lastDiagnostic: BrowserPageImageOverlayDiagnostic?

    init(
        javaScriptEvaluator: @escaping JavaScriptEvaluator =
            BrowserPageImageOverlayRenderer.evaluateJavaScript
    ) {
        self.javaScriptEvaluator = javaScriptEvaluator
    }

    deinit { renderTask?.cancel() }

    func cancelPendingRender() {
        revision &+= 1
        renderTask?.cancel()
        renderTask = nil
    }

    func render(
        on webView: WKWebView,
        items: [BrowserOverlayItem],
        imageSize: CGSize,
        sourceRect: CGRect,
        settings: IPhoneOverlaySettings,
        targetLanguage: String,
        layoutCache: ReaderTranslationDiskCache? = nil,
        layoutCacheKey: String? = nil,
        cacheGeneration: UInt64? = nil,
        cacheGenerationTask: Task<UInt64, Never>? = nil,
        preparedLayout: Task<Data, Error>? = nil,
        completion: ((BrowserPageImageOverlayDiagnostic) -> Void)? = nil
    ) {
        renderTask?.cancel()
        revision &+= 1
        let currentRevision = revision
        let viewport = webView.bounds.size
        renderTask = Task { [weak self, weak webView] in
            guard let self else { return }
            do {
                var encoded: Data?
                var generatedLayout = false
                if let preparedLayout {
                    // The offscreen preparer owns this task's cancellation.
                    // Image/WebKit startup runs concurrently with its CPU work.
                    encoded = try await preparedLayout.value
                } else if let layoutCache, let layoutCacheKey {
                    encoded = try? await layoutCache.data(for: layoutCacheKey, kind: .layout)
                    if let candidate = encoded,
                       (try? JSONSerialization.jsonObject(with: candidate) as? [[String: Any]]) == nil { encoded = nil }
                }
                if encoded == nil {
                    encoded = try await Self.prepareLayoutData(items: items, imageSize: imageSize, sourceRect: sourceRect,
                                                              settings: settings, targetLanguage: targetLanguage, viewport: viewport)
                    generatedLayout = true
                }
                try Task.checkCancellation()
                guard revision == currentRevision else { throw CancellationError() }
                guard let webView else {
                    publish(Self.failureDiagnostic(operation: .render, revision: currentRevision, failure: .webViewUnavailable), completion: completion)
                    return
                }
                guard let encoded else { throw CancellationError() }
                let payload = try JSONSerialization.jsonObject(with: encoded)
                let rawResult = try await javaScriptEvaluator(webView, Self.renderScript, [
                    "items": payload,
                    "appearance": ["opacity": min(1, max(0, settings.opacity)),
                                   "preserveSourceTextColor": settings.preserveSourceTextColor,
                                   "preserveSourceBackgroundColor": settings.preserveSourceBackgroundColor,
                                   "inpaintingEnabled": settings.usesSourceInpainting,
                                   "minimumReadableFontSize": BrowserOverlayLayoutPlanner.minimumRenderedFontSize],
                    "revision": String(currentRevision), "session": sessionIdentifier
                ])
                publish(Self.diagnostic(operation: .render, revision: currentRevision, rawResult: rawResult), completion: completion)
                // Rendering must not wait for optional layout persistence or a
                // queued cache-generation read. Join storage only after display.
                if generatedLayout, let layoutCache, let layoutCacheKey {
                    let storageGeneration: UInt64?
                    if let cacheGeneration { storageGeneration = cacheGeneration }
                    else { storageGeneration = await cacheGenerationTask?.value }
                    if let storageGeneration, !Task.isCancelled, revision == currentRevision {
                        try? await layoutCache.store(encoded, for: layoutCacheKey, kind: .layout, generation: storageGeneration)
                    }
                }
            } catch is CancellationError {
                publish(.init(operation: .render, revision: currentRevision, outcome: .stale, renderedItemCount: 0), completion: completion)
            } catch {
                publish(Self.failureDiagnostic(operation: .render, revision: currentRevision, failure: .javaScriptEvaluationFailed), completion: completion)
            }
            if revision == currentRevision { renderTask = nil }
        }
    }

    nonisolated static func prepareLayoutData(items: [BrowserOverlayItem], imageSize: CGSize, sourceRect: CGRect,
                                              settings: IPhoneOverlaySettings, targetLanguage: String, viewport: CGSize) async throws -> Data {
        try await BrowserPageImageOverlayLayoutWorker.shared.payload(items: items, imageSize: imageSize, sourceRect: sourceRect,
                                                                    settings: settings, targetLanguage: targetLanguage, viewport: viewport)
    }

    /// DOM rendering must consume the same card geometry as the native
    /// renderer. In particular, translated vertical manga columns require the
    /// existing expansion, padding, font fitting, reserved-source avoidance,
    /// and 24-candidate collision contraction policy; painting the raw OCR bbox
    /// is not a layout algorithm.
    nonisolated static func layoutPayload(
        items: [BrowserOverlayItem],
        imageSize: CGSize,
        sourceRect: CGRect,
        settings: IPhoneOverlaySettings,
        targetLanguage: String,
        viewport: CGSize,
        measurementCache: BrowserOverlayTextMeasurementCache? = BrowserOverlayTextMeasurementCache()
    ) -> [[String: Any]] {
        guard imageSize.width > 0, imageSize.height > 0,
              viewport.width > 0, viewport.height > 0
        else { return [] }

        let scaleX = sourceRect.width / imageSize.width
        let scaleY = sourceRect.height / imageSize.height
        let sorted = BrowserOverlayItemOrdering.ordered(items)
        var segments = sorted.map { item -> (
            item: BrowserOverlayItem,
            source: CGRect,
            sourceVertical: Bool,
            content: BrowserOverlayCardContent
        ) in
            let sourceVertical =
                BrowserOverlayTextFlow.usesVerticalSourceLayout(
                    rect: item.rect,
                    text: item.sourceText,
                    sourceOrientation: item.sourceOrientation
                )
            let translatedVertical =
                BrowserOverlayTextFlow.displayedTextUsesVerticalLayout(
                    item: item,
                    sourceIsVertical: sourceVertical,
                    targetLanguage: targetLanguage
                )
            let content = BrowserOverlayCardContent.make(
                item: item,
                mode: settings.mode,
                sourceVertical: sourceVertical,
                translatedVertical: translatedVertical
            )
            return (
                item,
                CGRect(
                    x: sourceRect.minX + item.rect.minX * scaleX,
                    y: sourceRect.minY + item.rect.minY * scaleY,
                    width: max(1, item.rect.width * scaleX),
                    height: max(1, item.rect.height * scaleY)
                ),
                sourceVertical,
                content
            )
        }
        let sourceRects = segments.map(\.source)
        let sourceRotations = segments.map {
            BrowserOverlayRotation.mapped(item: $0.item, imageSize: imageSize, sourceRect: sourceRect, settings: settings)
        }
        var intrinsicLayouts = segments.map { segment in
            BrowserOverlayLayoutPlanner.plan(
                source: segment.source,
                variants: [segment.content.displayed],
                settings: settings,
                viewport: viewport,
                occupied: [],
                sourceVertical: segment.sourceVertical,
                singleVerticalColumn:
                    segment.content.singleVerticalColumn,
                reservedSources: [],
                measurementCache: measurementCache
            )
        }
        var verticalContents: [Int: BrowserOverlayCardContent] = [:]
        var verticalLayouts: [Int: BrowserOverlayCardLayout] = [:]
        for index in segments.indices {
            if Task.isCancelled { return [] }
            let segment = segments[index]
            guard let verticalContent =
                BrowserOverlayCardContent.adaptiveVerticalCandidate(
                    item: segment.item,
                    current: segment.content,
                    mode: settings.mode,
                    textPlacement: settings.textPlacement,
                    sourceVertical: segment.sourceVertical,
                    sourceRect: segment.source
                )
            else { continue }
            verticalContents[index] = verticalContent
            verticalLayouts[index] = BrowserOverlayLayoutPlanner.plan(
                source: segment.source,
                variants: [verticalContent.displayed],
                settings: settings,
                viewport: viewport,
                occupied: [],
                sourceVertical: segment.sourceVertical,
                singleVerticalColumn: verticalContent.singleVerticalColumn,
                reservedSources: [],
                measurementCache: measurementCache
            )
        }
        let verticalIndices =
            BrowserOverlayLayoutPlanner.adaptiveVerticalTranslationIndices(
                horizontalLayouts: intrinsicLayouts,
                verticalLayouts: verticalLayouts,
                eligibleIndices: verticalLayouts.isEmpty ? [] :
                    BrowserOverlayLayoutPlanner
                        .severelyDisplacedTranslationIndices(
                            intrinsicLayouts: intrinsicLayouts,
                            sources: sourceRects,
                            variants: segments.map { $0.content.displayed },
                            settings: settings,
                            viewport: viewport,
                            sourceVerticals: segments.map(\.sourceVertical),
                            singleVerticalColumns: segments.map {
                                $0.content.singleVerticalColumn
                            },
                            placementBounds: sourceRect,
                            allowsDetachedPlacements: segments.map {
                                $0.content.hasTranslation &&
                                    settings.mode == .translateOnly
                            },
                            measurementCache: measurementCache
                        )
            )
        for index in verticalIndices {
            guard let content = verticalContents[index],
                  let layout = verticalLayouts[index]
            else { continue }
            let segment = segments[index]
            segments[index] = (
                segment.item,
                segment.source,
                segment.sourceVertical,
                content
            )
            intrinsicLayouts[index] = layout
        }
        let planningOrder = BrowserOverlayLayoutPlanner.packingOrder(
            intrinsicLayouts
        )
        var occupied: [CGRect] = []
        var plannedLayouts = Array<BrowserOverlayCardLayout?>(
            repeating: nil,
            count: segments.count
        )
        for index in planningOrder {
            if Task.isCancelled { return [] }
            let segment = segments[index]
            let reservedSources = sourceRects.enumerated().compactMap {
                otherIndex, rect in otherIndex == index ? nil : rect
            }
            let layout = BrowserOverlayLayoutPlanner.resolvePositionedLayout(
                intrinsicLayouts[index],
                source: segment.source,
                variants: [segment.content.displayed],
                settings: settings,
                viewport: viewport,
                occupied: occupied,
                sourceVertical: segment.sourceVertical,
                singleVerticalColumn:
                    segment.content.singleVerticalColumn,
                reservedSources: reservedSources,
                measurementCache: measurementCache
            )
            guard !layout.rect.isNull,
                  layout.rect.width > 0, layout.rect.height > 0
            else { continue }
            plannedLayouts[index] = layout
            occupied.append(layout.rect)
        }
        let concreteLayouts = plannedLayouts.compactMap { $0 }
        if concreteLayouts.count == plannedLayouts.count {
            let relaxed = BrowserOverlayLayoutPlanner.restoringSourceCoverage(
                BrowserOverlayLayoutPlanner.relaxingCardPositions(
                concreteLayouts,
                sources: sourceRects,
                sourceVerticals: segments.map(\.sourceVertical),
                viewport: viewport,
                placementBounds: sourceRect,
                preferredRects: intrinsicLayouts.map(\.rect),
                allowsDetachedPlacements: segments.map {
                    $0.content.hasTranslation &&
                        settings.mode == .translateOnly
                }
                ),
                sources: sourceRects,
                bounds: sourceRect,
                enabled: settings.mode == .translateOnly && settings.textPlacement == .replace
            )
            for index in relaxed.indices {
                plannedLayouts[index] = relaxed[index]
            }
        }

        var columns = settings.mode == .translateOnly && settings.textPlacement == .replace
            ? BrowserOverlayColumnLayout.plan(sources: sourceRects, variants: segments.map { $0.content.displayed },
                eligible: segments.indices.map { segments[$0].sourceVertical && segments[$0].content.hasTranslation && sourceRotations[$0] == nil },
                bounds: sourceRect, measurementCache: measurementCache,
                sourceSizes: segments.map { BrowserOverlayTypography.sourceSize(text: $0.item.sourceText, rect: $0.source) }) : [:]
        // A rejected neighbor returns to its original footprint. Recheck that
        // footprint before accepting any remaining coordinated column.
        while !columns.isEmpty {
            let rejected = columns.keys.filter { index in
                guard let frame = columns[index]?.rect else { return false }
                return plannedLayouts.indices.contains { other in
                    guard other != index, let obstacle = columns[other]?.rect ?? plannedLayouts[other]?.rect else { return false }
                    let overlap = frame.intersection(obstacle)
                    return !overlap.isNull && overlap.width > 0.25 && overlap.height > 0.25
                }
            }
            if rejected.isEmpty { break }
            for index in rejected { columns.removeValue(forKey: index) }
        }
        var result: [[String: Any]] = []
        for (index, segment) in segments.enumerated() {
            if Task.isCancelled { return [] }
            guard let resolvedLayout = plannedLayouts[index] else { continue }
            // All placement and source-coverage adjustments are finished. Growing
            // fonts earlier feeds back into packing and can shrink other captions.
            let ordinaryLayout = segment.content.hasTranslation
                ? BrowserOverlayLayoutPlanner.fittingFinalHorizontalFont(
                    resolvedLayout, variants: [segment.content.displayed], settings: settings,
                    occupied: plannedLayouts.enumerated().compactMap { $0.offset == index ? nil : $0.element?.rect },
                    reservedSources: sourceRects.enumerated().compactMap { $0.offset == index ? nil : $0.element },
                    measurementCache: measurementCache
                ) : resolvedLayout
            let rotatedLayout = sourceRotations[index].flatMap {
                BrowserOverlayRotation.layout(geometry: $0, variant: segment.content.displayed,
                    maximumFontSize: ordinaryLayout.maximumFontSize, measurementCache: measurementCache)
            }
            let layout = rotatedLayout ?? ordinaryLayout
            let renderedText: String
            if segment.content.hasTranslation,
               settings.mode == .translateOnly
            {
                renderedText =
                    segment.item.translatedText ?? segment.item.sourceText
            } else if !segment.content.hasTranslation {
                renderedText = segment.item.sourceText
            } else {
                renderedText = segment.content.displayed.displayText
            }
            let payload: [String: Any] = [
                "id": String(segment.item.stableRegionID ?? UInt64(index)),
                "rotation": rotatedLayout == nil ? 0 : (sourceRotations[index]?.radians ?? 0),
                "sourceTextOnly": !segment.content.hasTranslation,
                "sourceFontSize": BrowserOverlayTypography.sourceSize(text: segment.item.sourceText, rect: segment.source) as Any? ?? NSNull(),
                "sourceColorEligible": settings.mode == .translateOnly &&
                    settings.textPlacement == .replace,
                "sourcePanelRestorationEligible": settings.mode == .translateOnly &&
                    settings.textPlacement == .replace,
                "sourceCleanupLexical": BrowserSourceInkCleanup.hasColoredCleanupText(segment.item.sourceText),
                "columnLayout": columns[index].map { column -> [String: Any] in
                    let height = segment.content.displayed.measuredSize(
                        width: column.rect.width - column.contentInsets.left - column.contentInsets.right,
                        fontSize: column.maximumFontSize, measurementCache: measurementCache).height
                    return ["x": column.rect.minX, "y": column.rect.minY,
                     "width": column.rect.width, "height": column.rect.height,
                     "inspectionHeight": min(column.rect.height, ceil(height) + 8),
                     "fontSize": column.maximumFontSize,
                     "lineHeight": UIFont.systemFont(ofSize: column.maximumFontSize, weight: .bold).lineHeight,
                     "paddingTop": column.contentInsets.top, "paddingLeft": column.contentInsets.left,
                     "paddingBottom": column.contentInsets.bottom, "paddingRight": column.contentInsets.right,
                     "smallTextReference": NSNull(), "balancedColumn": true,
                     "allowsAutomaticFontRecovery": false]
                } as Any? ?? NSNull(),
                "allowsAutomaticFontRecovery": rotatedLayout == nil && settings.mode == .translateOnly &&
                    settings.textPlacement == .replace,
                "sourceCleanup": settings.mode == .translateOnly &&
                    settings.textPlacement == .replace &&
                    settings.colorMode == .white,
                "sourceBounds": [segment.item.rect.minX / imageSize.width, segment.item.rect.minY / imageSize.height,
                                 segment.item.rect.width / imageSize.width, segment.item.rect.height / imageSize.height],
                "auxiliaryInkRects": segment.item.auxiliaryInkRects.map {
                    [$0.minX / imageSize.width, $0.minY / imageSize.height, $0.width / imageSize.width, $0.height / imageSize.height]
                },
                "auxiliaryInkPolygons": segment.item.auxiliaryInkPolygons.map { $0.map { [$0.x / imageSize.width, $0.y / imageSize.height] } },
                "sourceSingleColumn": segment.item.sourceSingleVerticalColumn == true,
                "sourceRubyEligible": segment.item.sourceText.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) },
                "sourceFrame": [sourceRect.minX, sourceRect.minY, sourceRect.width, sourceRect.height],
                "sourceVertical": segment.sourceVertical,
                "x": layout.rect.minX,
                "y": layout.rect.minY,
                "width": layout.rect.width,
                "height": layout.rect.height,
                "text": renderedText,
                "vertical": segment.content.displayed.vertical,
                "wrappingScript":
                    BrowserOverlayTextFlow.wrappingScript(
                        for: renderedText
                    ).rawValue,
                "fontScript":
                    BrowserOverlayTextFlow.fontScript(
                        for: renderedText
                    ).rawValue,
                "fontSize": layout.maximumFontSize,
                "smallTextReference": layout.smallTextReference.map { reference -> [String: Any] in
                    ["fontSize": reference.fontSize, "additionalLines": reference.additionalLines,
                     "allowsEmergencyWordBreak": reference.allowsEmergencyWordBreak,
                     "fallbackFontSize": reference.fallbackFontSize ?? reference.fontSize,
                     "fallbackPadding": [reference.fallbackInsets?.top ?? reference.insets.top,
                                         reference.fallbackInsets?.right ?? reference.insets.right,
                                         reference.fallbackInsets?.bottom ?? reference.insets.bottom,
                                         reference.fallbackInsets?.left ?? reference.insets.left],
                     "exclusionRects": reference.exclusionRects.map { [$0.minX, $0.minY, $0.width, $0.height] },
                     "padding": [reference.insets.top, reference.insets.right, reference.insets.bottom, reference.insets.left]]
                } as Any? ?? NSNull(),
                "lineHeight": segment.content.displayed.vertical
                    ? layout.maximumFontSize
                    : UIFont.systemFont(
                        ofSize: layout.maximumFontSize,
                        weight: .bold
                    ).lineHeight,
                "paddingTop": layout.contentInsets.top,
                "paddingLeft": layout.contentInsets.left,
                "paddingBottom": layout.contentInsets.bottom,
                "paddingRight": layout.contentInsets.right,
                "lightSurface":
                    settings.colorMode == .white,
                "clipsText": !segment.content.hasTranslation ||
                    segment.content.displayed.vertical ||
                    segment.content.singleVerticalColumn ||
                    settings.textPlacement != .replace,
            ]
            result.append(payload)
        }
        return result
    }

    func clear(
        on webView: WKWebView,
        completion: ((BrowserPageImageOverlayDiagnostic) -> Void)? = nil
    ) {
        renderTask?.cancel()
        revision &+= 1
        let currentRevision = revision
        Task { @MainActor [weak webView] in
            guard let webView else {
                publish(
                    Self.failureDiagnostic(
                        operation: .clear,
                        revision: currentRevision,
                        failure: .webViewUnavailable
                    ),
                    completion: completion
                )
                return
            }
            do {
                let rawResult = try await javaScriptEvaluator(
                    webView,
                    Self.clearScript,
                    [
                        "revision": String(currentRevision),
                        "session": sessionIdentifier,
                    ]
                )
                publish(
                    Self.diagnostic(
                        operation: .clear,
                        revision: currentRevision,
                        rawResult: rawResult
                    ),
                    completion: completion
                )
            } catch {
                publish(
                    Self.failureDiagnostic(
                        operation: .clear,
                        revision: currentRevision,
                        failure: .javaScriptEvaluationFailed
                    ),
                    completion: completion
                )
            }
        }
    }

    static func evaluateJavaScript(
        _ webView: WKWebView,
        _ script: String,
        _ arguments: [String: Any]
    ) async throws -> Any? {
        try await webView.callAsyncJavaScript(
            script,
            arguments: arguments,
            in: nil,
            contentWorld: ReaderTranslationDOM.contentWorld
        )
    }

    private func publish(
        _ diagnostic: BrowserPageImageOverlayDiagnostic,
        completion: ((BrowserPageImageOverlayDiagnostic) -> Void)?
    ) {
        // An old shared layout can finish after the replacement has painted.
        // Notify its caller, but do not overwrite the live snapshot revision.
        if diagnostic.revision == revision {
            lastDiagnostic = diagnostic
            onDiagnostic?(diagnostic)
        }
        completion?(diagnostic)
    }

    private static func diagnostic(
        operation: BrowserPageImageOverlayDiagnostic.Operation,
        revision: UInt64,
        rawResult: Any?
    ) -> BrowserPageImageOverlayDiagnostic {
        guard let result = rawResult as? [String: Any],
              result["revision"] as? String == String(revision),
              let status = result["status"] as? String,
              let itemCount = result["itemCount"] as? NSNumber,
              itemCount.intValue >= 0
        else {
            return failureDiagnostic(
                operation: operation,
                revision: revision,
                failure: .malformedJavaScriptResult
            )
        }
        let outcome: BrowserPageImageOverlayDiagnostic.Outcome
        switch (operation, status) {
        case (.render, "committed"):
            outcome = .committed
        case (.render, "cleared"), (.clear, "cleared"):
            outcome = .cleared
        case (_, "stale"):
            outcome = .stale
        default:
            return failureDiagnostic(
                operation: operation,
                revision: revision,
                failure: .malformedJavaScriptResult
            )
        }
        return BrowserPageImageOverlayDiagnostic(
            operation: operation,
            revision: revision,
            outcome: outcome,
            renderedItemCount: itemCount.intValue
        )
    }

    private static func failureDiagnostic(
        operation: BrowserPageImageOverlayDiagnostic.Operation,
        revision: UInt64,
        failure: BrowserPageImageOverlayDiagnostic.Failure
    ) -> BrowserPageImageOverlayDiagnostic {
        BrowserPageImageOverlayDiagnostic(
            operation: operation,
            revision: revision,
            outcome: .failed(failure),
            renderedItemCount: 0
        )
    }

    // Explicitly release backing stores; detached canvases can otherwise wait
    // for WebKit GC while the next page allocates its own decoded buffers.
    static let releaseResourcesScript = """
    function aidokuReleaseOverlayResources(root, dropCache = false) {
      for (const canvas of root?.querySelectorAll('canvas') || []) {
        canvas.width = 0; canvas.height = 0;
      }
      if (dropCache) {
        const state = globalThis.__aidokuSourceCleanupV1;
        if (state) {
          if (state.last) { state.last.entries.clear(); state.last.pixels = 0; state.last.bytes = 0; }
          state.last = null; state.images = new WeakMap();
        }
      }
    }
    """

    static let clearScript = releaseResourcesScript + """
    const revisionNumber = Number(revision);
    if (!Number.isFinite(revisionNumber)) {
      throw new TypeError('invalid overlay revision');
    }
    const watermarkKey = '__aidokuImageOCROverlayRevision';
    const sessionKey = '__aidokuImageOCROverlaySession';
    const sessionValue = typeof session === 'undefined' ? '' : String(session);
    const acceptedRevision = Number(globalThis[watermarkKey] ?? -1);
    const acceptedSession = String(globalThis[sessionKey] ?? '');
    const existing = document.querySelector('[data-aidoku-image-ocr-overlay="root"]');
    const existingRevision = Number(existing?.dataset.aidokuRevision || -1);
    const existingSession = String(
      existing?.dataset.aidokuSession ?? acceptedSession
    );
    const sameSession = acceptedSession === sessionValue &&
      existingSession === sessionValue;
    if (sameSession &&
        (acceptedRevision > revisionNumber || existingRevision > revisionNumber)) {
      return {
        status: 'stale', revision: String(revision),
        itemCount: existing?.querySelectorAll(
          '[data-aidoku-image-ocr-overlay="item"]'
        ).length || 0
      };
    }
    globalThis[watermarkKey] = revisionNumber;
    globalThis[sessionKey] = sessionValue;
    aidokuReleaseOverlayResources(existing, true);
    existing?.remove();
    return { status: 'cleared', revision: String(revision), itemCount: 0 };
    """

    static let renderScript = releaseResourcesScript + BrowserSourceInkCleanup.script + BrowserSourceTextColor.script + BrowserSourcePanelRestoration.script + BrowserSlantedSourceRestoration.script + BrowserOverlayTypography.script + """
    const revisionNumber = Number(revision);
    if (!Number.isFinite(revisionNumber)) {
      throw new TypeError('invalid overlay revision');
    }
    if (!Array.isArray(items)) {
      throw new TypeError('overlay items must be an array');
    }
    const watermarkKey = '__aidokuImageOCROverlayRevision';
    const sessionKey = '__aidokuImageOCROverlaySession';
    const sessionValue = typeof session === 'undefined' ? '' : String(session);
    const acceptedRevision = Number(globalThis[watermarkKey] ?? -1);
    const acceptedSession = String(globalThis[sessionKey] ?? '');
    const oldRoot = document.querySelector('[data-aidoku-image-ocr-overlay="root"]');
    const oldRevision = Number(oldRoot?.dataset.aidokuRevision || -1);
    const oldSession = String(
      oldRoot?.dataset.aidokuSession ?? acceptedSession
    );
    const sameSession = acceptedSession === sessionValue &&
      oldSession === sessionValue;
    if (sameSession &&
        (acceptedRevision > revisionNumber || oldRevision > revisionNumber)) {
      return {
        status: 'stale', revision: String(revision),
        itemCount: oldRoot?.querySelectorAll(
          '[data-aidoku-image-ocr-overlay="item"]'
        ).length || 0
      };
    }
    if (items.length === 0) {
      globalThis[watermarkKey] = revisionNumber;
      globalThis[sessionKey] = sessionValue;
      aidokuReleaseOverlayResources(oldRoot, true);
      oldRoot?.remove();
      return { status: 'cleared', revision: String(revision), itemCount: 0 };
    }

    const finiteNumber = (value, field) => {
      const number = Number(value);
      if (!Number.isFinite(number)) {
        throw new TypeError(`invalid overlay ${field}`);
      }
      return number;
    };
    const minimumFontSize = finiteNumber(
      appearance?.minimumReadableFontSize,
      'minimum readable font size'
    );
    const opacity = finiteNumber(appearance?.opacity, 'opacity');
    const mount = document.body || document.documentElement;
    if (!mount) throw new Error('overlay mount is unavailable');

    const root = document.createElement('div');
    root.setAttribute('data-aidoku-image-ocr-overlay', 'root');
    root.dataset.aidokuRevision = String(revision);
    root.dataset.aidokuSession = sessionValue;
    Object.assign(root.style, {
      position: 'absolute', left: '0', top: '0', width: '0', height: '0',
      overflow: 'visible', pointerEvents: 'none', zIndex: '2147483646'
    });
    const scrollX = finiteNumber(globalThis.scrollX || 0, 'scroll x');
    const scrollY = finiteNumber(globalThis.scrollY || 0, 'scroll y');
    const measurementHost = document.createElement('div');
    measurementHost.setAttribute(
      'data-aidoku-image-ocr-overlay', 'measurement'
    );
    Object.assign(measurementHost.style, {
      position: 'absolute', left: '-100000px', top: '0', width: '0', height: '0',
      overflow: 'visible', visibility: 'hidden', pointerEvents: 'none',
      contain: 'layout style'
    });
    mount.appendChild(measurementHost);
    // Inspect native-resolution source crops; downsampling can hide thin panel rules.
    // Mask canvases belong to this revision's root and disappear on clear/re-render.
    let coloredCleanupBudget = 262144;
    const coloredCleanupAudit = [];
    const sourceColorCache = new Map();
    const cachedSourceSample = item => {
      if (!sourceColorCache.has(item)) sourceColorCache.set(item,
        item.sourceColorEligible ? (item.sourceTextOnly === false ? translatedSourceColors : sourceColors).sample(item.sourceBounds) : null);
      return sourceColorCache.get(item);
    };
    let cleanupBudget = 2000000;
    let cleanupPixels = 0, cleanupCount = 0;
        const cleanedDenseSourceItems = new Set();
    const cleanupStarted = performance.now();
    const sourceImage = document.getElementById('reader-source-image');
    const sourceColorBudget = {pixels:393216, detailPixels:98304, remainingSamples:items.filter(item=>item.sourceColorEligible).length};
    const sourceColors = aidokuSourceColorSampler(sourceImage,
      Boolean(appearance?.preserveSourceTextColor || appearance?.preserveSourceBackgroundColor), 'ocr', sourceColorBudget);
    const translatedSourceColors = aidokuSourceColorSampler(sourceImage,
      Boolean(appearance?.preserveSourceTextColor || appearance?.preserveSourceBackgroundColor), 'translation', sourceColorBudget);
    function aidokuCleanupContentGeometry(rect,naturalWidth,naturalHeight,style) {
      if (!rect || ![rect.x,rect.y,rect.width,rect.height,naturalWidth,naturalHeight].every(Number.isFinite) ||
          rect.width<=0 || rect.height<=0 || naturalWidth<=0 || naturalHeight<=0 || style.transform!=='none') return null;
      for(const field of ['borderLeftWidth','borderTopWidth','borderRightWidth','borderBottomWidth',
        'paddingLeft','paddingTop','paddingRight','paddingBottom']) if(parseFloat(style[field]||'0')!==0) return null;
      const box=[rect.x,rect.y,rect.width,rect.height],fit=style.objectFit;
      if(fit==='fill')return {frame:box,clip:box};
      if(fit!=='contain'&&fit!=='cover')return null;
      const position=String(style.objectPosition||'50% 50%').trim().split(/\\s+/);
      if(position.length!==2)return null;
      const offset=(token,space,axis)=>{
        const keywords=axis===0?{left:0,center:.5,right:1}:{top:0,center:.5,bottom:1};
        if(Object.prototype.hasOwnProperty.call(keywords,token))return space*keywords[token];
        if(/^-?(?:\\d+\\.?\\d*|\\.\\d+)%$/.test(token)){const fraction=parseFloat(token)/100;return fraction>=0&&fraction<=1?space*fraction:NaN;}
        if(/^-?(?:\\d+\\.?\\d*|\\.\\d+)px$/.test(token))return parseFloat(token);
        return NaN;
      };
      const scale=fit==='contain'?Math.min(rect.width/naturalWidth,rect.height/naturalHeight):Math.max(rect.width/naturalWidth,rect.height/naturalHeight);
      const width=naturalWidth*scale,height=naturalHeight*scale,x=offset(position[0],rect.width-width,0),y=offset(position[1],rect.height-height,1);
      if(!Number.isFinite(x)||!Number.isFinite(y))return null;
      return {frame:[rect.x+x,rect.y+y,width,height],clip:box};
    }
    function aidokuCleanupClip(geometry,x,y,width,height) {
      if(!geometry)return 'none';
      const b=geometry.clip,left=Math.max(0,b[0]-x),top=Math.max(0,b[1]-y),right=Math.max(0,x+width-b[0]-b[2]),bottom=Math.max(0,y+height-b[1]-b[3]);
      if(left>=width||right>=width||top>=height||bottom>=height)return 'inset(50%)';
      return left||top||right||bottom?`inset(${top}px ${right}px ${bottom}px ${left}px)`:'none';
    }

    const cleanupImageGeometry = (() => {
      if(!sourceImage)return null;
      try { return aidokuCleanupContentGeometry(sourceImage.getBoundingClientRect(),sourceImage.naturalWidth,sourceImage.naturalHeight,getComputedStyle(sourceImage)); }
      catch (_) { return null; }
    })();
    const cleanupCacheState = globalThis.__aidokuSourceCleanupV1 ||= {images:new WeakMap(),last:null};
        const cleanupCacheStore = cleanupCacheState.images;
        let cleanupCache = sourceImage ? cleanupCacheStore.get(sourceImage) : null;
        const cleanupSourceKey = sourceImage ? [sourceImage.currentSrc || sourceImage.src, sourceImage.naturalWidth, sourceImage.naturalHeight].join('|') : '';
        if (sourceImage && (!cleanupCache || !Number.isFinite(cleanupCache.bytes) || cleanupCache.source !== cleanupSourceKey)) {
          cleanupCache = {source:cleanupSourceKey,entries:new Map(),pixels:0,bytes:0};
          cleanupCacheStore.set(sourceImage,cleanupCache);
          sourceImage.addEventListener('load', () => cleanupCacheStore.delete(sourceImage), {once:true});
        }
        // Keep pixel buffers for only the most recently rendered source image.
        if(cleanupCacheState.last !== cleanupCache) {
          if(cleanupCacheState.last) { cleanupCacheState.last.entries.clear();cleanupCacheState.last.pixels=0;cleanupCacheState.last.bytes=0; }
          cleanupCacheState.last=cleanupCache;
        }
    // Account actual retained RGBA and safety-mask bytes, not just crop pixels.
    // Evict old settings/geometry variants before retaining a newer result.
    const storeCleanup = (key, prepared, pixels) => {
      if (!cleanupCache) return;
      const bytes = (prepared.restored?.rgba?.byteLength || 0) +
        (prepared.restored?.layoutSafe?.byteLength || 0) + (prepared.restored?.luminance?.byteLength || 0) +
        (prepared.luminance?.byteLength || 0) + (prepared.output?.data?.byteLength || 0);
      const limit = 16 * 1024 * 1024;
      if (bytes > limit || pixels > 4194304) return;
      while (cleanupCache.entries.size && (cleanupCache.bytes + bytes > limit ||
          cleanupCache.pixels + pixels > 4194304 || cleanupCache.entries.size >= 256)) {
        const oldest = cleanupCache.entries.keys().next().value;
        const entry = cleanupCache.entries.get(oldest);
        cleanupCache.bytes -= entry.retainedBytes; cleanupCache.pixels -= entry.retainedPixels;
        cleanupCache.entries.delete(oldest);
      }
      prepared.retainedBytes = bytes; prepared.retainedPixels = pixels;
      cleanupCache.entries.set(key, prepared); cleanupCache.bytes += bytes; cleanupCache.pixels += pixels;
    };
        const cleanupCanvas = document.createElement('canvas');
    const cleanupContext = cleanupCanvas.getContext('2d', {willReadFrequently: true});
    let artworkFirst = false;
    if (opacity === 1 && items.length <= 256 && appearance?.preserveSourceBackgroundColor /* artwork-first */) {
      artworkFirst = true;
    }
    let artworkProbePixels = 32768;
    // Use coordinated columns only in open space. Inspect the proposed text
    // footprint, not the full-height original erasure strip. A fixed page
    // budget keeps this independent of image resolution and OCR region count.
    const columnItems = items.filter(item => item.columnLayout);
    let columnsSafe = columnItems.length > 0 && Boolean(sourceImage?.complete && cleanupContext);
    if (columnsSafe) try {
      const frame = cleanupImageGeometry?.frame || columnItems[0].sourceFrame;
      const rects = columnItems.map(item => item.columnLayout);
      const left = Math.min(...rects.map(r => r.x)), top = Math.min(...rects.map(r => r.y));
      const right = Math.max(...rects.map(r => r.x+r.width));
      const bottom = Math.max(...rects.map(r => r.y+(r.inspectionHeight||r.height)));
      const width = right-left, height = bottom-top;
      const w = Math.max(1,Math.min(512,Math.floor(Math.sqrt(4096*width/height))));
      const h = Math.max(1,Math.min(512,Math.floor(4096/w)));
      const sourceMargin = Math.min(2,Math.max(1,width/w*.5));
      cleanupCanvas.width=w;cleanupCanvas.height=h;
      cleanupContext.drawImage(sourceImage,(left-frame[0])/frame[2]*sourceImage.naturalWidth,
        (top-frame[1])/frame[3]*sourceImage.naturalHeight,width/frame[2]*sourceImage.naturalWidth,
        height/frame[3]*sourceImage.naturalHeight,0,0,w,h);
      const pixels=cleanupContext.getImageData(0,0,w,h).data;
      const sources=items.flatMap(item=>[item.sourceBounds,...(item.auxiliaryInkRects||[])])
        .filter(b=>Array.isArray(b)&&b.length===4&&b.every(Number.isFinite)).map(b=>
          [frame[0]+b[0]*frame[2],frame[1]+b[1]*frame[3],b[2]*frame[2],b[3]*frame[3]]);
      for(const item of columnItems){
        const r=item.columnLayout, samples=[];
        for(let yy=0;yy<h;yy++)for(let xx=0;xx<w;xx++){
          const x=left+(xx+.5)*width/w,y=top+(yy+.5)*height/h;
          if(x<r.x||x>r.x+r.width||y<r.y||y>r.y+(r.inspectionHeight||r.height)||
            sources.some(b=>x>=b[0]-sourceMargin&&x<=b[0]+b[2]+sourceMargin&&y>=b[1]-sourceMargin&&y<=b[1]+b[3]+sourceMargin))continue;
          const p=(yy*w+xx)*4;
          samples.push([pixels[p],pixels[p+1],pixels[p+2],pixels[p+3],xx/w,yy/h]);
        }
        if(samples.length<4){columnsSafe=false;break;}
        // Derive the surface from pixels even in white/manual color mode so
        // the same source page receives the same column layout in both modes.
        const bg=[0,1,2].map(c=>samples.map(p=>p[c]).sort((a,b)=>a-b)[Math.floor(samples.length/2)]);
        const obstructed=samples.filter(p=>p[3]<250||Math.max(...bg.map((v,c)=>Math.abs(v-p[c])))>24).length;
        if(obstructed>Math.max(1,samples.length*.015)){
          // A lighting gradient is still open space. Fit the exposed pixels,
          // requiring the same sparse-outlier limit against a spatial surface.
          // Hard edges and illustration keep the ordinary placement.
          const features=p=>[1,p[4],p[5],p[5]*p[5]];
          const terms=4,matrix=Array.from({length:terms},()=>Array(terms).fill(0));
          const rhs=Array.from({length:3},()=>Array(terms).fill(0));
          for(const p of samples){const a=features(p);
            for(let j=0;j<terms;j++){for(let k=0;k<terms;k++)matrix[j][k]+=a[j]*a[k];
              for(let c=0;c<3;c++)rhs[c][j]+=a[j]*p[c];}}
          const planes=rhs.map(values=>{
            const m=matrix.map((row,i)=>[...row,values[i]]);
            for(let k=0;k<terms;k++){
              let pivot=k;for(let j=k+1;j<terms;j++)if(Math.abs(m[j][k])>Math.abs(m[pivot][k]))pivot=j;
              [m[k],m[pivot]]=[m[pivot],m[k]];
              if(Math.abs(m[k][k])<1e-8)return null;
              const divisor=m[k][k];for(let c=k;c<=terms;c++)m[k][c]/=divisor;
              for(let j=0;j<terms;j++)if(j!==k){const factor=m[j][k];for(let c=k;c<=terms;c++)m[j][c]-=factor*m[k][c];}
            }return m.map(row=>row[terms]);
          });
          const outliers=planes.some(p=>!p)?samples.length:samples.filter(p=>p[3]<250||
            Math.max(...planes.map((a,c)=>Math.abs(p[c]-a.reduce((sum,v,i)=>sum+v*features(p)[i],0))))>14).length;
          if(outliers>Math.max(1,samples.length*.015)){
            // Soft folds need not follow one polynomial over the whole row.
            // Independently exposed adjacent samples must still be smooth;
            // never bridge the excluded original lettering or a hard contour.
            const grid=new Map(samples.map(p=>[Math.round(p[5]*h)*w+Math.round(p[4]*w),p]));
            let links=0,edges=0;
            for(const [i,p] of grid)for(const j of [i%w<w-1?i+1:-1,i+w]){
              const q=grid.get(j);if(!q)continue;links++;
              if(p[3]<250||q[3]<250||Math.max(...[0,1,2].map(c=>Math.abs(p[c]-q[c])))>24)edges++;
            }
            if(links<samples.length*.5||edges>1){columnsSafe=false;break;}
          }
        }
        item.columnLayout.sourceErasureRGB=bg;
      }
      root.dataset.columnInspectionPixels=String(w*h);
    } catch (_) { columnsSafe=false; }
    if(columnsSafe)for(const item of columnItems)Object.assign(item,item.columnLayout);
    root.dataset.balancedColumns=String(columnsSafe?columnItems.length:0);
    const inpaintingEnabled = Boolean(appearance?.inpaintingEnabled &&
      appearance?.preserveSourceTextColor && appearance?.preserveSourceBackgroundColor);
    const restoredSourcePanels = new Set();
    const restoredPanelGeometry = new Map();
    let restoredPanelLookupBudget = 4194304;
    let restoredExteriorPixelBudget = 1048576;
    const panelRestorationPixelLimit = 1572864;
    let panelRestorationBudget = panelRestorationPixelLimit;
    let rubyInspectionBudget = 262144;
    let remainingPanelRestorations = items.filter(item => item.sourcePanelRestorationEligible && item.sourceColorEligible).length;
    const panelRestorationAudit = [];
    const slantedSourcePanels = new Map();
    const prepareSlantedSourcePanel = item => {
      if(!inpaintingEnabled||opacity!==1||!sourceImage?.complete||!cleanupContext)return;
      const f=cleanupImageGeometry?.frame||item.sourceFrame,b=item.sourceBounds;
      if(!f||!b||!f.every(Number.isFinite)||!b.every(Number.isFinite))return;
      const iw=sourceImage.naturalWidth,ih=sourceImage.naturalHeight,sx=iw/f[2],sy=ih/f[3];
      if(Math.abs(sx-sy)>.01*Math.max(sx,sy))return;
      const valid=r=>Array.isArray(r)&&r.length===4&&r.every(Number.isFinite)&&r[2]>0&&r[3]>0;
      const auxiliary=(item.auxiliaryInkRects||[]).filter(valid).slice(0,32);
      const exclusions=items.filter(other=>other!==item).flatMap(other=>[other.sourceBounds,...(other.auxiliaryInkRects||[])])
        .filter(valid).slice(0,256);
      const palette=cachedSourceSample(item);
      const readingAspect=item.sourceVertical?item.height/item.width:item.width/item.height;
      const inferRuby=Boolean(item.sourceRubyEligible&&readingAspect>=2.5&&palette?.foreground&&palette?.background&&
        Math.max(...palette.foreground)<=80&&Math.min(...palette.background)>=220);
      const rubyPadding=inferRuby?Math.min(96,(item.sourceVertical?item.width:item.height)*sx*.8):0;
      const margin=40+Math.ceil(rubyPadding);
      const x=Math.max(0,Math.floor(Math.min(b[0],...auxiliary.map(r=>r[0]))*iw)-margin),
        y=Math.max(0,Math.floor(Math.min(b[1],...auxiliary.map(r=>r[1]))*ih)-margin);
      const w=Math.min(iw,Math.ceil(Math.max(b[0]+b[2],...auxiliary.map(r=>r[0]+r[2]))*iw)+margin)-x,
        h=Math.min(ih,Math.ceil(Math.max(b[1]+b[3],...auxiliary.map(r=>r[1]+r[3]))*ih)+margin)-y;
      // The payload's quad uses its source frame, before WebKit rounds image
      // layout to CSS subpixels. Keep that rounding out of native ink ownership.
      const sourceFrame=item.sourceFrame||f,sourceSX=iw/sourceFrame[2],sourceSY=ih/sourceFrame[3];
      const box=[(item.x-sourceFrame[0])*sourceSX-x,(item.y-sourceFrame[1])*sourceSY-y,
        item.width*sourceSX,item.height*sourceSY];
      const localRect=r=>[r[0]*iw-x,r[1]*ih-y,r[2]*iw,r[3]*ih];
      const auxiliaryPolygons=(item.auxiliaryInkPolygons||[]).slice(0,32)
        .filter(q=>Array.isArray(q)&&q.length===4&&q.every(p=>Array.isArray(p)&&p.length===2&&p.every(Number.isFinite)))
        .map(q=>q.map(p=>[p[0]*iw-x,p[1]*ih-y]));
      const options={auxiliary:auxiliary.map(localRect),auxiliaryPolygons,inferredRubyExclusions:exclusions.map(localRect),inferRuby};
      const geometry=aidokuSlantedLocalGeometry(box,item.rotation,Boolean(item.sourceVertical),options);
      const pixels=w*h+geometry.lw*geometry.lh;
      const allowance=Math.min(524288,Math.floor(panelRestorationBudget/Math.max(1,remainingPanelRestorations--)));
      if(w<8||h<8||w*h>262144||pixels>allowance)return;
      panelRestorationBudget-=pixels;
      try {
        const key=JSON.stringify(['slanted-glyph-mask-v4-native-coordinates',x,y,w,h,box,item.rotation,palette,Boolean(item.sourceVertical),options]);
        let prepared=cleanupCache?.entries.get(key);
        if(!prepared){
          cleanupCanvas.width=w;cleanupCanvas.height=h;cleanupContext.drawImage(sourceImage,x,y,w,h,0,0,w,h);
          const original=cleanupContext.getImageData(0,0,w,h).data;
          prepared={restored:aidokuRestoreSlantedSource(original,w,h,box,item.rotation,palette,Boolean(item.sourceVertical),options)};
          storeCleanup(key,prepared,pixels);
        }
        const result=prepared.restored;
        panelRestorationAudit.push({id:String(item.id),pixels,accepted:Boolean(result),method:result?.method||'slanted-preserved',erased:result?.erased||0});
        if(!result)return;
        const canvas=document.createElement('canvas');canvas.width=w;canvas.height=h;
        const context=canvas.getContext('2d');if(!context)return;
        const output=context.createImageData(w,h);output.data.set(result.rgba);context.putImageData(output,0,0);
        canvas.setAttribute('data-aidoku-image-ocr-overlay','source-panel-restoration');
        canvas.dataset.aidokuRegion=String(item.id);canvas.dataset.slantedGlyphMask='true';
        Object.assign(canvas.style,{position:'absolute',zIndex:'1',pointerEvents:'none',
          left:`${f[0]+x/sx+scrollX}px`,top:`${f[1]+y/sy+scrollY}px`,width:`${w/sx}px`,height:`${h/sy}px`,
          clipPath:aidokuCleanupClip(cleanupImageGeometry,f[0]+x/sx,f[1]+y/sy,w/sx,h/sy)});
        // Commit erasure only after translated glyphs pass the same artwork mask.
        slantedSourcePanels.set(item,{result,canvas,scale:sx});
      }catch(_){}
    };
    const appendRestoredSourcePanel = item => {
      if(item.rotation){prepareSlantedSourcePanel(item);return false;}
      if (!inpaintingEnabled || !item.sourcePanelRestorationEligible ||
          !item.sourceColorEligible || opacity <= 0 || !sourceImage?.complete || !cleanupContext) return false;
      // Reserve a fair share for later balloons; the last caption must not lose
      // all restoration work simply because earlier regions consumed the page cap.
      const allowance=Math.min(262144,Math.floor(panelRestorationBudget/Math.max(1,remainingPanelRestorations--)));
      const b=item.sourceBounds,frame=cleanupImageGeometry?.frame || item.sourceFrame,palette=cachedSourceSample(item);
      if(!Array.isArray(b)||!Array.isArray(frame)||b.length!==4||frame.length!==4||
          ![...b,...frame].every(Number.isFinite)||b[2]<=0||b[3]<=0||frame[2]<=0||frame[3]<=0)return false;
      const iw=sourceImage.naturalWidth,ih=sourceImage.naturalHeight,pad=24;
      const auxiliary=(item.auxiliaryInkRects||[]).slice(0,32).filter(r=>Array.isArray(r)&&r.length===4&&r.every(Number.isFinite)&&r[2]>0&&r[3]>0);
      const leadingRule=Boolean(item.sourceVertical&&item.sourceSingleColumn&&palette?.stroke);
      const topPadding=leadingRule?pad+Math.min(120,b[2]*iw*3):pad;
      const rubyPadding=item.sourceVertical&&item.sourceCleanupLexical&&b[3]*ih>=b[2]*iw*2.5
        ?Math.min(96,b[2]*iw*.8):0;
      const rubyExclusions=items.filter(other=>other!==item).flatMap(other=>[other.sourceBounds,...(other.auxiliaryInkRects||[])])
        .filter(r=>Array.isArray(r)&&r.length===4&&r.every(Number.isFinite));
      const x=Math.max(0,Math.floor(Math.min(b[0],...auxiliary.map(r=>r[0]))*iw)-pad);
      const y=Math.max(0,Math.floor(Math.min(b[1],...auxiliary.map(r=>r[1]))*ih)-topPadding);
      let right=Math.min(iw,Math.ceil(Math.max(b[0]+b[2],...auxiliary.map(r=>r[0]+r[2]))*iw)+pad);
      const bottom=Math.min(ih,Math.ceil(Math.max(b[1]+b[3],...auxiliary.map(r=>r[1]+r[3]))*ih)+pad);
      // Expand only for observed ruby; ordinary balloons keep their exact crop,
      // scale and reconstruction budget. A bounded preview avoids blanket growth.
      if(rubyPadding>0&&auxiliary.length===0&&rubyInspectionBudget>=1024&&palette?.foreground&&palette?.background&&
          Math.max(...palette.foreground)<=80&&Math.min(...palette.background)>=220)try{
        const expanded=Math.min(iw,Math.ceil(right+rubyPadding)),pw=expanded-x,ph=bottom-y;
        const scale=Math.min(1,Math.sqrt(Math.min(32768,rubyInspectionBudget)/(pw*ph)));
        const w=Math.max(1,Math.floor(pw*scale)),h=Math.max(1,Math.floor(ph*scale));
        rubyInspectionBudget-=w*h;cleanupCanvas.width=w;cleanupCanvas.height=h;
        cleanupContext.drawImage(sourceImage,x,y,pw,ph,0,0,w,h);
        const rgba=cleanupContext.getImageData(0,0,w,h).data,raw=new Uint8Array(w*h);
        for(let i=0;i<raw.length;i++)if(Math.max(rgba[i*4],rgba[i*4+1],rgba[i*4+2])<110)raw[i]=1;
        const sx=w/pw,sy=h/ph;
        const inferred=aidokuInferVerticalRuby(raw,rgba,w,h,[(b[0]*iw-x)*sx,(b[1]*ih-y)*sy,b[2]*iw*sx,b[3]*ih*sy],palette.background);
        const exclusions=rubyExclusions.map(r=>[(r[0]*iw-x)*sx,(r[1]*ih-y)*sy,r[2]*iw*sx,r[3]*ih*sy]);
        if(inferred.some(r=>!exclusions.some(q=>r[0]<q[0]+q[2]&&r[0]+r[2]>q[0]&&r[1]<q[1]+q[3]&&r[1]+r[3]>q[1]))&&
            Math.sqrt(allowance/(pw*ph))>=.75)right=expanded;
      }catch(_){}
      const sourceWidth=right-x,sourceHeight=bottom-y;
      // Favor native pixels for fine body strokes and ruby, sharing the larger
      // allowance fairly across the page. Do not upscale or dilute fine ink.
      // Do not discard their spatial background merely because padding crosses the cap.
      const scale=Math.min(1,Math.sqrt(allowance/(sourceWidth*sourceHeight)));
      if(scale<0.75)return false;
      const w=Math.floor(sourceWidth*scale),h=Math.floor(sourceHeight*scale),pixels=w*h;
      const sx=w/sourceWidth,sy=h/sourceHeight;
      if(w<8||h<8||pixels>panelRestorationBudget)return false;
      panelRestorationBudget-=pixels;
      try {
        const key=JSON.stringify(['spatial-panel-v31-observed-lettering',x,y,sourceWidth,sourceHeight,w,h,b,palette,auxiliary,rubyExclusions,leadingRule,Boolean(item.sourceVertical)]);
        let prepared=cleanupCache?.entries.get(key);
        if(!prepared){
          cleanupCanvas.width=w;cleanupCanvas.height=h;
          cleanupContext.drawImage(sourceImage,x,y,sourceWidth,sourceHeight,0,0,w,h);
          const original=cleanupContext.getImageData(0,0,w,h).data;
          const restored=aidokuRestoreSourcePanel(original,w,h,
            [(b[0]*iw-x)*sx,(b[1]*ih-y)*sy,b[2]*iw*sx,b[3]*ih*sy],palette,
            {readabilityGate:true,sampleScale:Math.min(sx,sy),auxiliary:auxiliary.map(r=>[(r[0]*iw-x)*sx,(r[1]*ih-y)*sy,r[2]*iw*sx,r[3]*ih*sy]),
              inferredRubyExclusions:rubyExclusions.map(r=>[(r[0]*iw-x)*sx,(r[1]*ih-y)*sy,r[2]*iw*sx,r[3]*ih*sy]),leadingRule,vertical:Boolean(item.sourceVertical)});
          // Readability is checked against actual composited pixels, without
          // changing the source foreground/background estimators.
          let luminance=null;
          if(restored){
            luminance=new Uint8Array(pixels);
            const linear=v=>{v/=255;return v<=.04045?v/12.92:((v+.055)/1.055)**2.4;};
            for(let i=0;i<pixels;i++){
              const data=restored.rgba[i*4+3]?restored.rgba:original;
              luminance[i]=Math.round(255*(.2126*linear(data[i*4])+.7152*linear(data[i*4+1])+.0722*linear(data[i*4+2])));
            }
          }
          prepared={restored,luminance};
          storeCleanup(key, prepared, pixels);
        }
        const result=prepared.restored;
        panelRestorationAudit.push({id:String(item.id),pixels,sourcePixels:sourceWidth*sourceHeight,scale,accepted:Boolean(result),method:result?.method||'',surface:result?.surfaceQuality?.reason||'',erased:result?.erased||0,companions:result?.companions||0,preservedPixels:result?.preservedPixels||0,preservedCore:result?.preservedCore||0,sourceErasureVerified:Boolean(result?.sourceErasureVerified)});
        if(!result)return false;
        const canvas=document.createElement('canvas');canvas.width=w;canvas.height=h;
        const context=canvas.getContext('2d');if(!context)return false;
        const output=context.createImageData(w,h);output.data.set(result.rgba);context.putImageData(output,0,0);
        canvas.setAttribute('data-aidoku-image-ocr-overlay','source-panel-restoration');
        Object.assign(canvas.style,{position:'absolute',zIndex:'1',pointerEvents:'none',
          left:`${frame[0]+x/iw*frame[2]+scrollX}px`,top:`${frame[1]+y/ih*frame[3]+scrollY}px`,
          width:`${sourceWidth/iw*frame[2]}px`,height:`${sourceHeight/ih*frame[3]}px`,
          clipPath:aidokuCleanupClip(cleanupImageGeometry,frame[0]+x/iw*frame[2],frame[1]+y/ih*frame[3],sourceWidth/iw*frame[2],sourceHeight/ih*frame[3])});
        root.appendChild(canvas);restoredSourcePanels.add(item);
        restoredPanelGeometry.set(item,{canvas,safe:result.layoutSafe,luminance:prepared.luminance,w,h,x,y,frame,iw,ih,sx,sy,
          surfaceQuality:result.surfaceQuality,sourceErasureVerified:result.sourceErasureVerified,erasureComplete:result.erased>0&&result.preservedPixels===0&&result.preservedCore===0});return true;
      } catch (_) { return false; }
    };
    const appendSourceCleanup = item => {
      if(item.rotation)return;
      // Colored cleanup must obey the same translation boundary as white cleanup.
      const coloredGate = Boolean(item.sourceCleanupLexical && item.sourceColorEligible);
      const cleanupPalette = coloredGate && item.sourceColorEligible ? cachedSourceSample(item) : null;
      const cleanupBG = cleanupPalette?.background;
      const coloredEligible = Boolean(cleanupBG && (Math.max(...cleanupBG)-Math.min(...cleanupBG)>12 || Math.max(...cleanupBG)<220 || cleanupPalette?.stroke));
      // Off-white/gray balloons can fail the white mask without reaching the
      // colored gate. Retry only failed white masks under the same flatness and
      // pixel budgets; a successful white cleanup does not spend this allowance.
      const neutralFallbackEligible = Boolean(item.sourceCleanup && cleanupBG && Math.max(...cleanupBG) < 250);
      if ((!item.sourceCleanup && !coloredEligible) || opacity <= 0 || !sourceImage?.complete ||
          !sourceImage.naturalWidth || !cleanupContext) return;
      const b = item.sourceBounds, frame = cleanupImageGeometry?.frame || item.sourceFrame;
      if (!Array.isArray(b) || !Array.isArray(frame) || b.length !== 4 || frame.length !== 4 ||
          !b.every(Number.isFinite) || !frame.every(Number.isFinite) ||
          b[2] <= 0 || b[3] <= 0 || frame[2] <= 0 || frame[3] <= 0) return;
      const iw = sourceImage.naturalWidth, ih = sourceImage.naturalHeight;
      const x = Math.floor(b[0] * iw), y = Math.floor(b[1] * ih);
      const right = Math.ceil((b[0] + b[2]) * iw), bottom = Math.ceil((b[1] + b[3]) * ih);
      const w = right - x + 5, h = bottom - y + 5;
      const pixels = w * h;
      if (x < 2 || y < 2 || right + 2 >= iw || bottom + 2 >= ih ||
          w < 14 || h < 14 || pixels > 262144 || pixels > cleanupBudget) return;
      cleanupBudget -= pixels;
      try {
        const coloredAllowed = Boolean((coloredEligible || neutralFallbackEligible) && pixels <= 131072 && pixels <= coloredCleanupBudget);
            const cacheKey = JSON.stringify([x,y,w,h,Boolean(item.sourceCleanup),Boolean(item.sourceVertical),coloredAllowed,cleanupPalette]);
            let prepared = cleanupCache?.entries.get(cacheKey);
            if (!prepared) {
              cleanupCanvas.width = w; cleanupCanvas.height = h;
              cleanupContext.drawImage(sourceImage, x - 2, y - 2, w, h, 0, 0, w, h);
              const rgba = cleanupContext.getImageData(0, 0, w, h).data;
              let mask = item.sourceCleanup ? aidokuSourceInkMask(rgba,w,h,Boolean(item.sourceVertical)) : null;
              let restorationRGB=[255,255,255], audit=null;
              if (coloredAllowed && (coloredEligible || !mask)) {
                const colored=aidokuColoredSourceInkMask({width:w,height:h,rgba,palette:cleanupPalette});
                audit={reason:colored.reason,erased:colored.erased||0,haloAdded:colored.haloAdded||0};
                if (colored.mask) { mask=Uint8Array.from(colored.mask,value=>value?255:0);restorationRGB=colored.fill; }
              }
              let output=null,count=0;
              if (mask) {
                output=cleanupContext.createImageData(w,h);
                for(let i=0;i<mask.length;i++) {
                  if(!mask[i])continue;
                  const p=i*4;output.data[p]=restorationRGB[0];output.data[p+1]=restorationRGB[1];output.data[p+2]=restorationRGB[2];output.data[p+3]=mask[i];count++;
                }
              }
              prepared={output,count,dense:Boolean(mask?.denseSurfaceRecovered),audit};
              // Bound retained pixel data to the existing per-page inspection budget.
              storeCleanup(cacheKey, prepared, pixels);
            }
            if(coloredAllowed && prepared.audit) {
              coloredCleanupBudget-=pixels;
              if(prepared.audit)coloredCleanupAudit.push({id:String(item.id),pixels,...prepared.audit});
            }
            if(!prepared.output)return;
            if(prepared.dense)cleanedDenseSourceItems.add(item);
            const canvas=document.createElement('canvas');canvas.width=w;canvas.height=h;
            const context=canvas.getContext('2d');if(!context)return;
            cleanupPixels+=prepared.count;
            context.putImageData(prepared.output,0,0);
        canvas.setAttribute('data-aidoku-image-ocr-overlay', 'source-cleanup');
        Object.assign(canvas.style, {
          position: 'absolute', zIndex: '1', pointerEvents: 'none',
          left: `${frame[0] + (x - 2) / iw * frame[2] + scrollX}px`,
          top: `${frame[1] + (y - 2) / ih * frame[3] + scrollY}px`,
          width: `${w / iw * frame[2]}px`, height: `${h / ih * frame[3]}px`,
          clipPath: aidokuCleanupClip(cleanupImageGeometry,frame[0]+(x-2)/iw*frame[2],frame[1]+(y-2)/ih*frame[3],w/iw*frame[2],h/ih*frame[3]),
          // Background translucency must not leave recognized source ink visible.
          opacity: '1'
        });
        root.appendChild(canvas); cleanupCount++;
      } catch (_) {
        // Missing/tainted pixels are not evidence; rendering still succeeds.
      }
    };
    // Optional restoration; failed ownership/surface checks retain boxes.
    if(inpaintingEnabled)for(const item of items)appendRestoredSourcePanel(item);
    root.dataset.panelRestorationAudit = JSON.stringify(panelRestorationAudit);
    root.dataset.panelRestorationPixels = String(panelRestorationPixelLimit-panelRestorationBudget);
    root.dataset.cleanupCount = String(cleanupCount);
    root.dataset.cleanupPixels = String(cleanupPixels);
    root.dataset.cleanupMilliseconds = String(performance.now() - cleanupStarted);
    root.dataset.coloredCleanupAudit = JSON.stringify(coloredCleanupAudit);
    root.dataset.coloredCleanupBudgetUsed = String(262144-coloredCleanupBudget);
    let renderedItemCount = 0;
    let refinementCharacterBudget = 16384;
    // Reserve the original allowance for emergency-size captions, regardless
    // of item order. New 8–9 pt proposals only spend otherwise unused capacity.
    const emergencyCharacters = items.reduce((total, item) => {
      const length = String(item?.text || '').length;
      return total + (item?.smallTextReference?.fontSize < 8 && length <= 512 ? length : 0);
    }, 0);
    let readableRefinementBudget = Math.min(2048, Math.max(0, refinementCharacterBudget - emergencyCharacters));
    const captionTextReflows = new Map();
    const typographyInkFrames = new Map();
    const typographyEntries = [];
    let artworkTypeBudget = 8192;
    let balloonTypeBudget = 8192;
    let balloonSurfaceBudget = 524288;
    let artworkSurfaceBudget = 262144;
    let typographyCharacterBudget = 8192;
    let captionReflowCharacterBudget = 8192;
    let koreanWrapCharacterBudget = 2048;
    let readableParagraphBudget = 512;
    let captionRecoveryCharacterBudget = 16384;
    let paragraphSourcePixelBudget = 262144;
    let paragraphSourceLookupBudget = 524288;
    // Bound paragraph growth using the original image, independently of erasure.
    function paragraphSafePixels(rgba, w, h) {
      const n=w*h;
      if(n>131072 || rgba.length!==n*4) return null;
      const blocked=new Uint8Array(n), seen=new Uint8Array(n), queue=new Int32Array(n);
      let white=0,colored=0;
      for(let i=0;i<n;i++) {
        const p=i*4,lo=Math.min(rgba[p],rgba[p+1],rgba[p+2]),hi=Math.max(rgba[p],rgba[p+1],rgba[p+2]);
        if(rgba[p+3]!==255)return null;
        if(lo>=245 && hi-lo<=10)white++;
        else blocked[i]=1;
        if(hi-lo>20)colored++;
      }
      if(white/n<0.5 || colored/n>0.02)return null;
      const safe=new Uint8Array(n);safe.fill(1);
      for(let seed=0;seed<n;seed++) {
        if(!blocked[seed]||seen[seed])continue;
        let head=0,tail=1,edge=false,minX=w,minY=h,maxX=0,maxY=0;
        queue[0]=seed;seen[seed]=1;
        while(head<tail){
          const i=queue[head++],x=i%w,y=Math.floor(i/w);
          if(x===0||y===0||x===w-1||y===h-1)edge=true;
          minX=Math.min(minX,x);maxX=Math.max(maxX,x);minY=Math.min(minY,y);maxY=Math.max(maxY,y);
          for(let dy=-1;dy<=1;dy++)for(let dx=-1;dx<=1;dx++){
            const xx=x+dx,yy=y+dy;if(xx<0||yy<0||xx>=w||yy>=h)continue;
            const j=yy*w+xx;if(blocked[j]&&!seen[j]){seen[j]=1;queue[tail++]=j;}
          }
        }
        const cw=maxX-minX+1,ch=maxY-minY+1;
        if(edge||tail>n*.25||cw>w*.8||ch>h*.8)
          for(let j=0;j<tail;j++)safe[queue[j]]=0;
      }
      return safe;
    }

    let paragraphRecoveryProbeBudget = 512;
        const koreanWrapMeasure = document.createElement('canvas').getContext('2d');
    try {
      for (const item of items) {
        if (!item || typeof item !== 'object') {
          throw new TypeError('invalid overlay item');
        }
        const node = document.createElement('div');
        node.setAttribute('data-aidoku-image-ocr-overlay', 'item');
        node.dataset.aidokuRegion = String(item.id);
        node.id = `aidoku-image-ocr-${String(item.id)}`;
        const displayedText = String(item.text || '');
        node.textContent = displayedText;
        node.setAttribute('role', 'text');
        node.setAttribute('aria-label', displayedText);
        const vertical = Boolean(item.vertical);
        const wrappingScript = String(item.wrappingScript || 'word');
        const fontScript = String(item.fontScript || 'word');
        node.lang = fontScript === 'japanese' ? 'ja' :
          (fontScript === 'han' ? 'zh' :
            (fontScript === 'korean' ? 'ko' : 'und'));
        const fontFamily = fontScript === 'japanese'
          ? "'Hiragino Sans','YuGothic','Noto Sans CJK JP'," +
            "-apple-system,BlinkMacSystemFont,sans-serif"
          : (fontScript === 'han'
            ? "'PingFang SC','PingFang TC','Noto Sans CJK SC'," +
              "-apple-system,BlinkMacSystemFont,sans-serif"
            : (fontScript === 'korean'
              ? "'Apple SD Gothic Neo','Noto Sans CJK KR','Noto Sans KR'," +
                "-apple-system,BlinkMacSystemFont,sans-serif"
              : "-apple-system,BlinkMacSystemFont,sans-serif"));
        let x = finiteNumber(item.x, 'x');
        let y = finiteNumber(item.y, 'y');
        let width = Math.max(1, finiteNumber(item.width, 'width'));
        let height = Math.max(1, finiteNumber(item.height, 'height'));
        const fontSize = finiteNumber(item.fontSize, 'font size');
        const lineHeight = finiteNumber(item.lineHeight, 'line height');
        const paddingTop = finiteNumber(item.paddingTop, 'padding top');
        const paddingRight = finiteNumber(item.paddingRight, 'padding right');
        const paddingBottom = finiteNumber(item.paddingBottom, 'padding bottom');
        const paddingLeft = finiteNumber(item.paddingLeft, 'padding left');
        if (fontSize < minimumFontSize) continue;
        const sampled = cachedSourceSample(item);
        const sampledSurface = appearance?.preserveSourceBackgroundColor ? sampled?.surface : null;
        const panelCandidate = appearance?.preserveSourceBackgroundColor
          ? (sampledSurface?.color || (sampled?.confidence?.background >= 0.5 ? sampled.background : null)) : null;
        const panelForeground = aidokuPanelForeground(panelCandidate, opacity);
        const sampledBackground = panelForeground ? panelCandidate : null;
        // An unavailable source sample is not evidence for a white panel.
        // Keep the original pixels visible when preservation cannot resolve a surface.
        const preserveOriginalBackground = Boolean(appearance?.preserveSourceBackgroundColor && item.sourceColorEligible);
        const unresolvedSourceBackground = preserveOriginalBackground && !sampledBackground;
        const lightSurface = panelForeground ? panelForeground[0] !== 255 : Boolean(item.lightSurface);
        const surface = sampledBackground ? sampledBackground.join(',') : (lightSurface ? '255,254,249' : '7,9,13');
        const surfaceGradient = sampledSurface && sampledBackground
          ? `linear-gradient(to ${sampledSurface.vertical ? 'bottom' : 'right'},${sampledSurface.stops.map((rgb,i)=>
              `rgba(${rgb.join(',')},${opacity}) ${i*100/(sampledSurface.stops.length-1)}%`).join(',')})` : null;
        const veil = lightSurface ? '255,255,255' : '7,9,13';
        const veilAlpha = lightSurface ? 0.42 : 0.64;
        const readableColor = appearance?.preserveSourceTextColor
          ? aidokuReadableSourceColor(aidokuSourceDisplayInk(sampled), lightSurface, opacity, sampledBackground) : null;
        const foreground = readableColor ? readableColor.join(',') : (lightSurface ? '17,18,23' : '255,255,255');
        // Source outlines remain sampling evidence only. Display uses a single
        // readable fill: colored rings and synthetic halos crowd small glyphs.
        const sampledStroke = sampled?.stroke;
        const sourceTextOutline = false;
        node.dataset.sourceSampledStrokeRGB = Array.isArray(sampledStroke) ? sampledStroke.join(',') : '';
        node.dataset.sourceAppliedStrokeRGB = '';
        node.dataset.sourceStrokeColor = 'none';
        node.dataset.sourceReadabilityAssist = 'false';
        node.dataset.sourceReadabilityAssistOrigin = '';
        node.dataset.sourceStrokeConfidence = String(sampled?.confidence?.stroke ?? '');
        node.dataset.sourceSampledTextRGB = (sampled?.foreground||sampled?.displayForeground)?.join(',') || '';
        node.dataset.sourceAppliedTextRGB = foreground;
        node.dataset.sourceSampledBackgroundRGB = sampled?.background?.join(',') || '';
        node.dataset.sourceAppliedBackgroundRGB = preserveOriginalBackground ? '' : surface;
        node.dataset.sourceTextOutline = String(sourceTextOutline);
        node.dataset.sourceTextColor = readableColor ? 'preserved' : 'fallback';
        node.dataset.sourceTextColorAdjusted = String(Boolean(readableColor && sampled?.foreground &&
          readableColor.some((value, channel) => value !== sampled.foreground[channel])));
        node.dataset.sourceBackgroundColor = unresolvedSourceBackground ? 'unresolved-transparent' : preserveOriginalBackground ? 'original' : surfaceGradient ? 'observed-surface' : sampledBackground ? 'preserved' : 'fallback';
        node.dataset.sourceBackgroundStops = sampledSurface ? JSON.stringify(sampledSurface.stops) : '';
        Object.assign(node.style, {
          position: 'absolute',
          zIndex: '2',
          left: `${x + scrollX}px`,
          top: `${y + scrollY}px`,
          width: `${width}px`, height: `${height}px`,
          boxSizing: 'border-box',
          overflow: Boolean(item.clipsText) ? 'hidden' : 'visible',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          padding: `${paddingTop}px ${paddingRight}px ` +
            `${paddingBottom}px ${paddingLeft}px`,
          margin: '0', borderRadius: '6px',
          border: '0',
          backgroundColor: surfaceGradient ? 'transparent' : `rgba(${surface},${opacity})`,
          backgroundImage: surfaceGradient || (sampledBackground ? 'none' :
            `linear-gradient(rgba(${veil},${veilAlpha}),` +
            `rgba(${veil},${veilAlpha}))`),
          color: `rgb(${foreground})`,
          fontFamily,
          fontWeight: vertical ? '800' : '700',
          fontSize: `${fontSize}px`,
          lineHeight: `${Math.max(fontSize, lineHeight)}px`,
          letterSpacing: '-0.012em', textAlign: 'center',
          webkitTextStroke: '0px transparent', paintOrder: 'normal',
          textShadow: 'none',
          boxShadow: 'none',
          backdropFilter: 'none', webkitBackdropFilter: 'none',
          webkitTextSizeAdjust: 'none', textSizeAdjust: 'none',
          contain: 'layout style',
          whiteSpace: 'pre-wrap', overflowWrap: 'anywhere',
          wordBreak: wrappingScript === 'korean' ? 'keep-all' : 'normal',
          // Balance short Korean dialogue without changing its words or card.
          // The cloned measurement node uses the same policy during font fitting.
          textWrap: !vertical && wrappingScript === 'korean' &&
            displayedText.length <= 180 && !/[\\r\\n]/.test(displayedText)
              ? 'balance' : 'wrap',
          lineBreak: wrappingScript === 'cjk' ? 'strict' : 'auto',
          hyphens: wrappingScript === 'word' ? 'auto' : 'manual',
          direction: wrappingScript === 'rightToLeft' ? 'rtl' : 'ltr',
          unicodeBidi: 'plaintext',
          writingMode: vertical ? 'vertical-rl' : 'horizontal-tb',
          textOrientation: 'mixed'
        });
        if (item.balancedColumn) {
          node.style.alignItems = 'flex-start';
          node.dataset.balancedColumn = 'true';
        }
        // A successful RGB estimate does not describe the picture showing through
        // a translucent balloon. Keep spatial pixels, even when restoration fails.
        if (restoredSourcePanels.has(item) || preserveOriginalBackground) {
          node.style.backgroundColor = 'transparent';
          node.style.backgroundImage = 'none';
          node.style.backdropFilter = 'none';
          node.style.webkitBackdropFilter = 'none';
          if (restoredSourcePanels.has(item)) node.dataset.sourceBackgroundColor = 'restored';
        }
        // A coordinated column can move off its source strip. Manual palettes
        // must erase that strip too, using the flat surface verified above;
        // otherwise colored source glyphs remain between the translated cards.
        if (item.balancedColumn && !preserveOriginalBackground && opacity > 0 &&
            Array.isArray(item.sourceErasureRGB) && item.sourceErasureRGB.length === 3) {
          const frame = cleanupImageGeometry?.frame || item.sourceFrame;
          const pad = Math.max(3, Math.min(6, fontSize * .3));
          if (frame) for (const b of [item.sourceBounds, ...(item.auxiliaryInkRects || [])]) {
            if (!Array.isArray(b) || b.length !== 4 || !b.every(Number.isFinite)) continue;
            const left = Math.max(frame[0], frame[0] + b[0] * frame[2] - pad);
            const top = Math.max(frame[1], frame[1] + b[1] * frame[3] - pad);
            const right = Math.min(frame[0] + frame[2], frame[0] + (b[0] + b[2]) * frame[2] + pad);
            const bottom = Math.min(frame[1] + frame[3], frame[1] + (b[1] + b[3]) * frame[3] + pad);
            const erasure = document.createElement('div');
            erasure.setAttribute('data-aidoku-image-ocr-overlay', 'source-readability-panel');
            erasure.dataset.aidokuRegion = String(item.id); erasure.dataset.sourceErasure = 'true';
            Object.assign(erasure.style, {position:'absolute', zIndex:'1', pointerEvents:'none',
              left:`${left+scrollX}px`, top:`${top+scrollY}px`,
              width:`${Math.max(1,right-left)}px`, height:`${Math.max(1,bottom-top)}px`,
              backgroundColor:`rgb(${item.sourceErasureRGB.join(',')})`});
            root.appendChild(erasure);
          }
        }
        root.appendChild(node);
        const measurementNode = node.cloneNode(true);
        measurementNode.removeAttribute('id');
        measurementNode.removeAttribute(
          'data-aidoku-image-ocr-overlay'
        );
        measurementNode.removeAttribute('role');
        measurementNode.removeAttribute('aria-label');
        measurementNode.setAttribute('aria-hidden', 'true');
        measurementHost.appendChild(measurementNode);
        const lineHeightRatio = Math.max(
          1,
          lineHeight / Math.max(1, fontSize)
        );
        const applyMeasuredFontSize = size => {
          node.style.fontSize = String(size) + 'px';
          node.style.lineHeight = String(size * lineHeightRatio) + 'px';
          measurementNode.style.fontSize = String(size) + 'px';
          measurementNode.style.lineHeight =
            String(size * lineHeightRatio) + 'px';
        };
        const contentFits = () =>
          measurementNode.scrollWidth <= measurementNode.clientWidth + 0.5 &&
          measurementNode.scrollHeight <= measurementNode.clientHeight + 0.5;
        const fitMeasuredFont = maximum => {
          applyMeasuredFontSize(maximum);
          if (!contentFits() && maximum > minimumFontSize) {
            applyMeasuredFontSize(minimumFontSize);
            if (contentFits()) {
              let lower = minimumFontSize, upper = maximum;
              for (let step = 0; step < 9; step += 1) {
                const candidate = (lower + upper) / 2;
                applyMeasuredFontSize(candidate);
                if (contentFits()) lower = candidate; else upper = candidate;
              }
              applyMeasuredFontSize(Math.floor(lower * 4) / 4);
            }
          }
          return parseFloat(node.style.fontSize);
        };
        // Fit in the quad's local axes first. Subsequent page-axis paragraph,
        // column and source-anchor heuristics must not flatten this geometry.
        if (Number.isFinite(item.rotation) && item.rotation !== 0) {
          node.style.overflow = 'hidden';
          measurementNode.style.overflow = 'hidden';
          fitMeasuredFont(fontSize);
          node.dataset.sourceRotation = String(item.rotation);
          node.dataset.rotatingPanel = 'true';
          // The text and its opaque replacement panel are one element. A
          // separate page-axis readability plate would flatten the source box.
          if (appearance?.preserveSourceBackgroundColor && item.sourceColorEligible) {
            const palette = aidokuCaptionPalette(sampled, foreground.split(',').map(Number),
              Boolean(appearance?.preserveSourceTextColor));
            const contrast = rgb => aidokuSourceColorContrast(rgb, true, opacity, palette.background);
            const readableInk = opacity === 1 ? aidokuAdjustInkForContrast(palette.foreground, contrast) : palette.foreground;
            node.style.color = `rgb(${readableInk.join(',')})`;
            node.style.backgroundColor = `rgba(${palette.background.join(',')},${opacity})`;
            node.style.backgroundImage = 'none';
            node.dataset.sourceAppliedTextRGB = readableInk.join(',');
            node.dataset.sourceTextColorAdjusted = String(readableInk.some((value,i)=>value!==palette.foreground[i]));
            node.dataset.sourceContrastBefore = String(contrast(palette.foreground));
            node.dataset.sourceContrastAfter = String(contrast(readableInk));
            node.dataset.sourceAppliedBackgroundRGB = palette.background.join(',');
            node.dataset.sourceBackgroundColor = 'rotated-panel';
            node.dataset.sourceTextColor = palette.preserved ? 'preserved' : 'fallback';
          }
          if(inpaintingEnabled&&opacity===1){
            const restored=slantedSourcePanels.get(item);
            node.dataset.slantedSourcePrepared=String(Boolean(restored));
            const originalFont=parseFloat(node.style.fontSize);
            // Artwork fitting may reflow a caption, but must not make a
            // previously readable translation arbitrarily small.
            const slantedFontFloor=Math.min(originalFont,Math.max(8.5,Math.min(18,originalFont*.8),minimumFontSize));
            node.dataset.slantedOriginalFont=String(originalFont);
            node.dataset.slantedFontFloor=String(slantedFontFloor);
            let accepted=false;
            const palette=aidokuCaptionPalette(sampled,foreground.split(',').map(Number),Boolean(appearance?.preserveSourceTextColor));
            const candidates=[palette.foreground,[17,18,23],[0,0,0],[255,255,255]].filter(Array.isArray);
            const glyphRects=()=>{
              const frame=measurementNode.getBoundingClientRect(),range=document.createRange(),rects=[];
              const text=measurementNode.firstChild;if(!text||text.nodeType!==Node.TEXT_NODE)return rects;
              const style=getComputedStyle(measurementNode);
              if(koreanWrapMeasure)koreanWrapMeasure.font=`${style.fontWeight} ${style.fontSize} ${style.fontFamily}`;
              let offset=0;
              for(const character of text.textContent){
                const next=offset+character.length;
                if(!/\\s/u.test(character)){
                  range.setStart(text,offset);range.setEnd(text,next);
                  for(const r of range.getClientRects()){
                    let bounds=[r.left-frame.left,r.top-frame.top,r.right-frame.left,r.bottom-frame.top];
                    // DOM ranges include the font's empty ascent/descent area.
                    // Preserve the font size when only that whitespace touches
                    // art, using measured glyph bounds with a CSS-pixel guard.
                    const m=!vertical&&koreanWrapMeasure?.measureText(character);
                    if(m&&[m.fontBoundingBoxAscent,m.fontBoundingBoxDescent,m.actualBoundingBoxAscent,
                        m.actualBoundingBoxDescent,m.actualBoundingBoxLeft,m.actualBoundingBoxRight].every(Number.isFinite)&&
                        m.actualBoundingBoxRight+m.actualBoundingBoxLeft>0){
                      const baseline=bounds[1]+(r.height-m.fontBoundingBoxAscent-m.fontBoundingBoxDescent)/2+m.fontBoundingBoxAscent;
                      bounds=[bounds[0]-m.actualBoundingBoxLeft-1,baseline-m.actualBoundingBoxAscent-1,
                        bounds[0]+m.actualBoundingBoxRight+1,baseline+m.actualBoundingBoxDescent+1];
                    }
                    rects.push(bounds);
                  }
                }
                offset=next;
              }
              return rects;
            };
            const originalHorizontalPadding=[node.style.paddingLeft,node.style.paddingRight];
            const insetText=fraction=>{
              const inset=item.width*(1-fraction)/2;
              for(const target of [node,measurementNode]){
                target.style.paddingLeft=`${parseFloat(originalHorizontalPadding[0])+inset}px`;
                target.style.paddingRight=`${parseFloat(originalHorizontalPadding[1])+inset}px`;
              }
            };
            const trySlantedSize=(size,fraction)=>{
              insetText(fraction);
              applyMeasuredFontSize(size);
              if(contentFits()){
                const rects=glyphRects();
                const safety={};
                const ink=candidates.find(color=>aidokuSlantedInkFits(restored.result,rects,restored.scale,color,safety));
                if(ink){
                  node.style.color=`rgb(${ink.join(',')})`;node.dataset.sourceAppliedTextRGB=ink.join(',');
                  node.dataset.sourceContrastAfter=String(safety.minimumContrast);
                  root.appendChild(restored.canvas);accepted=true;
                  node.dataset.slantedTextWidthFraction=String(fraction);
                  return true;
                }
              }
              return false;
            };
            if(restored)for(let size=originalFont;size>=slantedFontFloor;size=Math.max(slantedFontFloor,size-.5)){
              if(trySlantedSize(size,1))break;
              if(size===slantedFontFloor)break;
            }
            // A multi-lobed balloon can narrow through its middle. Shrinking
            // letters alone still leaves a full-width line across that contour.
            // Reflow inside the same centered, rotated quad; neither its source
            // erasure nor its position grows to accommodate the translation.
            // Bound the extra DOM measurements even with a large user font.
            const reflowStep=Math.max(.5,Math.ceil((originalFont-slantedFontFloor)/16*2)/2);
            // This reflow converts broad vertical dialogue into a paragraph.
            // A narrow strip or horizontal source row cannot establish that
            // interior: narrowing it can expose adjacent untranslated words.
            if(restored&&!accepted&&!vertical&&item.sourceVertical&&item.width>=item.height*.6)
              for(let size=originalFont;size>=slantedFontFloor;size=Math.max(slantedFontFloor,size-reflowStep)){
                if([.9,.8,.7,.6,.5,.45].some(fraction=>trySlantedSize(size,fraction)))break;
                if(size===slantedFontFloor)break;
              }
            if(!accepted)insetText(1);
            node.style.backgroundColor='transparent';node.style.backgroundImage='none';
            node.dataset.sourceBackgroundColor=accepted?'slanted-glyph-restored':'slanted-preserved';
            node.dataset.slantedSourceErased=String(accepted);
            node.dataset.slantedArtworkSafe=String(accepted);
            if(!accepted){
              // Erasure and replacement are atomic. An ambiguous source keeps
              // its original pixels instead of receiving an oversized plate.
              applyMeasuredFontSize(originalFont);node.style.visibility='hidden';
            }
          }
          node.style.transformOrigin = '50% 50%';
          node.style.transform = `rotate(${item.rotation}rad)`;
          // Clip the rotated container to the image, in the container's own
          // axes. Neither edge-of-page panels nor their glyphs may spill out.
          const f = item.sourceFrame, c = Math.cos(item.rotation), s = Math.sin(item.rotation);
          if (Array.isArray(f) && f.length === 4 && f.every(Number.isFinite)) {
            const cx = x + width / 2, cy = y + height / 2;
            const corners = [[f[0],f[1]],[f[0]+f[2],f[1]],[f[0]+f[2],f[1]+f[3]],[f[0],f[1]+f[3]]];
            node.style.clipPath = `polygon(${corners.map(([px,py])=>
              `${(px-cx)*c+(py-cy)*s+width/2}px ${-(px-cx)*s+(py-cy)*c+height/2}px`).join(',')})`;
          }
          node.dataset.sourcePanelTextFit = 'caption';
          measurementNode.remove();
          renderedItemCount += 1;
          continue;
        }
        const setPadding = padding => {
          const value = padding.map(p => `${p}px`).join(' ');
          node.style.padding = value; measurementNode.style.padding = value;
        };
        // Compare actual WebKit line breaks, not only UIKit's longest-token width.
        // A previously oversized word must not disable protection for every other word.
        const lineProfile = () => {
          const text = {data:measurementNode.textContent};
          if (!text.data) return null;
          const walker=document.createTreeWalker(measurementNode,NodeFilter.SHOW_TEXT), textNodes=[];
          while(walker.nextNode())textNodes.push(walker.currentNode);
          let textIndex=0,textBase=0;
          const range = document.createRange(), rows = [], breaks = [], starts = [], ends = [], ink = [];
          const frame = measurementNode.getBoundingClientRect();
          const tolerance = parseFloat(node.style.fontSize) * lineHeightRatio * 0.4;
          let offset = 0, previousRow = -1, previousLeft = -Infinity, previousTop = -Infinity, joined = false;
          for (const character of text.data) {
            const next = offset + character.length;
            if (/\\s/u.test(character)) { joined = false; offset = next; continue; }
            while(textIndex<textNodes.length-1 && offset>=textBase+textNodes[textIndex].length){
              textBase+=textNodes[textIndex].length;textIndex++;
            }
            range.setStart(textNodes[textIndex], offset-textBase); range.setEnd(textNodes[textIndex], next-textBase);
            // A wrapped character range can include a zero-width rectangle on the
            // preceding line. Its bounding union invents a second break at the
            // following character; use the last non-empty glyph fragment instead.
            const fragments = Array.from(range.getClientRects()).filter(rect => rect.width > 0 && rect.height > 0);
            const box = fragments.length ? fragments[fragments.length - 1] : range.getBoundingClientRect();
            ink.push([box.left - frame.left + x, box.top - frame.top + y, box.width, box.height]);
            const axis = vertical ? box.right : box.top;
            let row = rows.findIndex(y => Math.abs(y - axis) <= tolerance);
            if (row < 0) { row = rows.length; rows.push(axis); starts[row] = {character, offset}; }
            ends[row] = {character, offset};
            // WebKit can report the prior line's top for its first wrapped glyph
            // under text-wrap:balance. Its horizontal reset still exposes the break.
            const wrapsBack = vertical ? box.top < previousTop - 0.5 :
              wrappingScript !== 'rightToLeft' && box.left < previousLeft - 0.5;
            if (joined && (row !== previousRow || wrapsBack)) breaks.push(offset);
            previousLeft = box.left; previousTop = box.top;
            previousRow = row; joined = true; offset = next;
          }
          const badStarts = starts.filter(x => /^[、。，．,.！？!?…‥）)\\]」』】》〉:;]$/u.test(x.character)).map(x => x.offset);
          const badEnds = ends.filter(x => /^[（(\\[「『【《〈]$/u.test(x.character)).map(x => x.offset);
          const isolated = starts.flatMap((start, row) =>
                ends[row]?.offset === start.offset ? [start.offset] : []);
              const hangulIsolated = starts.filter((start, row) => {
                const end = ends[row];
                if (!end) return false;
                const visible = text.data.slice(start.offset, end.offset + end.character.length)
                  .normalize('NFC').replace(/[\\p{P}\\p{Z}\\s]/gu, '');
                return /^[\\p{Script=Hangul}]$/u.test(visible);
              }).length;
              const punctuationOnly = starts.filter((start, row) => {
                const end = ends[row];
                return end && /^[\\p{P}\\s]+$/u.test(text.data.slice(start.offset, end.offset + end.character.length));
              }).length;
              return {lines: rows.length, lineStarts:starts.map(s=>s.offset), breaks, badStarts, badEnds, ink, isolated, hangulIsolated, punctuationOnly,
                hangulFragments:aidokuKoreanFragments(text.data,breaks)};
        };
        // Reflow roomy paragraphs within their existing card using measured free height.
            let paragraphBaseline = null;
            let reference = item.smallTextReference;
            let refinementMaximum = fontSize;
            const paragraphUsableWidth = width - paddingLeft - paddingRight;
            const paragraphUsableHeight = height - paddingTop - paddingBottom;
            if (item.allowsAutomaticFontRecovery && !reference && !vertical && wrappingScript === 'korean' &&
            fontSize >= 9 && fontSize < 12 && displayedText.length <= paragraphRecoveryProbeBudget &&
                ((displayedText.length >= 40 && displayedText.length <= 180 &&
                  displayedText.trim().split(/\\s+/u).length >= 8 && paragraphUsableWidth >= fontSize * 12) ||
                 (item.sourceVertical === true && fontSize <= 11.5 &&
                  displayedText.length >= 5 && displayedText.length <= 32 &&
                  displayedText.trim().split(/\\s+/u).length >= 2)) &&
                !/[\\r\\n]/u.test(displayedText) &&
                displayedText.length <= refinementCharacterBudget && displayedText.length <= readableRefinementBudget) {
              paragraphRecoveryProbeBudget -= displayedText.length;
              const originalFont = fitMeasuredFont(fontSize);
              if (originalFont >= 9) {
                const profile = lineProfile();
                const usedHeight = profile ? profile.lines * originalFont * lineHeightRatio : Infinity;
                if (profile && profile.lines >= 2 && usedHeight <= paragraphUsableHeight * 0.5 &&
                    paragraphUsableHeight - usedHeight >= 2 * 12 * lineHeightRatio) {
                  paragraphBaseline = profile;
                  const exclusions = items.filter(other => other !== item).flatMap(other => {
                    const result = [[Number(other.x), Number(other.y), Number(other.width), Number(other.height)]];
                    const b = other.sourceBounds, f = other.sourceFrame;
                    if (Array.isArray(b) && Array.isArray(f) && b.length === 4 && f.length === 4 &&
                        b.every(Number.isFinite) && f.every(Number.isFinite)) result.push([
                      f[0] + b[0] * f[2], f[1] + b[1] * f[3], b[2] * f[2], b[3] * f[3]]);
                    return result.filter(r => r.every(Number.isFinite) && r[2] > 0 && r[3] > 0);
                  });
                  reference = {fontSize: originalFont,
                    padding: [paddingTop, paddingRight, paddingBottom, paddingLeft],
                    additionalLines: Math.min(displayedText.length <= 32 ? 2 : 3, Math.floor((paragraphUsableHeight - usedHeight) / (12 * lineHeightRatio))),
                    exclusionRects: exclusions, paragraphRecovery: true};
                  refinementMaximum = 12;
                  node.dataset.fixedParagraphRecovery = 'proposed';
                }
              }
            }
        const hasReference = reference && Number.isFinite(reference.fontSize) &&
          Array.isArray(reference.padding) && reference.padding.length === 4 && reference.padding.every(Number.isFinite);
        const refinementStarted = performance.now();
        if (hasReference) {
          setPadding(reference.padding);
          const baselineFont = fitMeasuredFont(reference.fontSize);
          const emergency = reference.fontSize < 8;
          const canProfile = displayedText.length <= 512 && displayedText.length <= refinementCharacterBudget &&
            (emergency || displayedText.length <= readableRefinementBudget);
          if (canProfile) {
            refinementCharacterBudget -= displayedText.length;
            if (!emergency) readableRefinementBudget -= displayedText.length;
          }
          const baseline = canProfile ? (paragraphBaseline || lineProfile()) : null;
          if (baseline) {
            setPadding([paddingTop, paddingRight, paddingBottom, paddingLeft]);
            const exclusions = Array.isArray(reference.exclusionRects) ? reference.exclusionRects : [];
            const extraLines = Number.isFinite(reference.additionalLines) ? Math.max(1, Math.min(32, reference.additionalLines)) : 1;
            const acceptable = (maximum, allowance, requireContainedGlyphs = true) => {
              const candidateFont = fitMeasuredFont(maximum), candidate = lineProfile();
              const adds = (a, b) => a.some(offset => !b.includes(offset));
              const allowsEmergencyWordBreak = reference.fontSize < 8 &&
                reference.allowsEmergencyWordBreak === true && wrappingScript === 'korean';
              const protectsWords = !vertical && !allowsEmergencyWordBreak &&
                (wrappingScript === 'korean' || wrappingScript === 'word');
              const hitsObstacle = candidate && candidate.ink.some(a => exclusions.some(b =>
                Math.min(a[0] + a[2], b[0] + b[2]) - Math.max(a[0], b[0]) > 0.5 &&
                Math.min(a[1] + a[3], b[1] + b[3]) - Math.max(a[1], b[1]) > 0.5));
              const escapesCard = candidate && candidate.ink.some(a =>
                a[0] < x - 0.5 || a[1] < y - 0.5 ||
                a[0] + a[2] > x + width + 0.5 || a[1] + a[3] > y + height + 0.5);
              return candidate && contentFits() && candidateFont >= baselineFont + 0.5 &&
                candidate.lines <= baseline.lines + allowance && !hitsObstacle &&
                    (!reference.paragraphRecovery || (!adds(candidate.isolated, baseline.isolated) && candidate.hangulIsolated <= baseline.hangulIsolated)) &&
                (!requireContainedGlyphs || !escapesCard) &&
                !(protectsWords && adds(candidate.breaks, baseline.breaks)) &&
                !adds(candidate.badStarts, baseline.badStarts) && !adds(candidate.badEnds, baseline.badEnds);
            };
            let accepted = acceptable(refinementMaximum, extraLines);
            // A maximal fit can touch a nearby source or strand punctuation even
            // when a slightly smaller readable size is safe. Bounded descending
            // probes retain the old proposal if none passes every actual-DOM guard.
            if (!accepted && extraLines > 1) {
              const upper = Math.min(refinementMaximum, parseFloat(node.style.fontSize));
              for (let step = 1; step <= 8 && !accepted; step += 1) {
                const size = Math.floor((upper - step * 0.5) * 4) / 4;
                if (size < Math.max(8, baselineFont + 0.5)) break;
                accepted = acceptable(size, extraLines);
              }
            }
            // The text may move within its existing envelope when a small
            // neighbouring source blocks the centre. Never move the card itself.
            if (!accepted && !reference.paragraphRecovery && !vertical && exclusions.length > 0 && extraLines > 1) {
              const originalPadding = [paddingTop, paddingRight, paddingBottom, paddingLeft];
              for (const shift of [-6, 6, -12, 12]) {
                if (Math.abs(shift) > height * 0.2) continue;
                const padding = originalPadding.slice();
                padding[shift < 0 ? 2 : 0] += Math.abs(shift) * 2;
                setPadding(padding);
                accepted = acceptable(fontSize, extraLines);
                if (accepted) break;
              }
              if (!accepted) setPadding(originalPadding);
            }
            if (Number.isFinite(reference.fallbackFontSize) &&
                (!accepted || parseFloat(node.style.fontSize) < reference.fallbackFontSize) &&
                Array.isArray(reference.fallbackPadding) && reference.fallbackPadding.length === 4) {
              const savedFont = parseFloat(node.style.fontSize);
              const savedPadding = node.style.padding;
              const savedAccepted = accepted;
              setPadding(reference.fallbackPadding);
              // This exact previous proposal keeps its prior boundary semantics;
              // the stricter new glyph rule must not shrink an existing layout.
              const fallbackAccepted = acceptable(reference.fallbackFontSize, 1, false);
              if (savedAccepted && (!fallbackAccepted || parseFloat(node.style.fontSize) < savedFont)) {
                node.style.padding = savedPadding; measurementNode.style.padding = savedPadding;
                applyMeasuredFontSize(savedFont);
                accepted = true;
              } else { accepted = fallbackAccepted; }
            }
            if (!accepted) {
              setPadding(reference.padding); applyMeasuredFontSize(baselineFont);
              node.dataset.smallTextRefinement = 'retained-baseline';
            } else { node.dataset.smallTextRefinement = 'accepted'; }
          } else { node.dataset.smallTextRefinement = 'retained-baseline'; }
        } else { fitMeasuredFont(fontSize); }
            if (reference?.paragraphRecovery) node.dataset.fixedParagraphRecovery = node.dataset.smallTextRefinement;
        if (hasReference) root.dataset.smallTextRefinementMilliseconds = String(
          Number(root.dataset.smallTextRefinementMilliseconds || 0) + performance.now() - refinementStarted);
        // Repair existing Korean emergency breaks inside the same card. Two
        // bounded probes trade at most 12% type size for intact words/closing
        // punctuation; never expand boxes or touch the translation string.
        const koreanWrapStarted = performance.now();
        let mayBreakKoreanWord = false;
        if (!vertical && wrappingScript === 'korean' && koreanWrapMeasure && displayedText.length <= 180) {
          koreanWrapMeasure.font = `${node.style.fontWeight} ${node.style.fontSize} ${node.style.fontFamily}`;
          const available = width - parseFloat(node.style.paddingLeft || 0) - parseFloat(node.style.paddingRight || 0);
          // Canvas omits the small negative letter spacing, so this estimate
          // errs toward checking a word rather than missing an overflow.
          mayBreakKoreanWord = displayedText.split(/\\s+/u).some(word => koreanWrapMeasure.measureText(word).width > available);
        }
        if (mayBreakKoreanWord && displayedText.length <= koreanWrapCharacterBudget) {
          koreanWrapCharacterBudget -= displayedText.length;
          const originalFont = parseFloat(node.style.fontSize);
          const original = lineProfile();
          const penalty = profile => profile.badStarts.length * 4 + profile.badEnds.length * 4 + profile.breaks.length;
          if (original && penalty(original) > 0) {
            let chosenFont = originalFont, chosen = original;
            const exclusions = Array.isArray(reference?.exclusionRects) ? reference.exclusionRects : [];
            const violations = profile => profile.ink.filter(a =>
              a[0] < x - 0.5 || a[1] < y - 0.5 || a[0] + a[2] > x + width + 0.5 ||
              a[1] + a[3] > y + height + 0.5 || exclusions.some(b =>
                Math.min(a[0] + a[2], b[0] + b[2]) - Math.max(a[0], b[0]) > 0.5 &&
                Math.min(a[1] + a[3], b[1] + b[3]) - Math.max(a[1], b[1]) > 0.5)).length;
            const originalViolations = violations(original);
            for (const ratio of [0.94, 0.88]) {
              const size = Math.max(Math.ceil(originalFont * 0.88 * 4) / 4, Math.floor(originalFont * ratio * 4) / 4);
              if (size < minimumFontSize) continue;
              applyMeasuredFontSize(size);
              const candidate = lineProfile();
              if (candidate && contentFits() && candidate.lines <= original.lines &&
                  candidate.badStarts.length <= original.badStarts.length &&
                  candidate.badEnds.length <= original.badEnds.length &&
                  candidate.breaks.every(offset => original.breaks.includes(offset)) &&
                  violations(candidate) <= originalViolations && penalty(candidate) < penalty(chosen)) {
                chosenFont = size; chosen = candidate;
                if (penalty(chosen) === 0) break;
              }
            }
            applyMeasuredFontSize(chosenFont);
            if (chosenFont < originalFont) node.dataset.koreanWrapRepair = 'accepted';
          }
        }
        root.dataset.koreanWrapMilliseconds = String(
          Number(root.dataset.koreanWrapMilliseconds || 0) + performance.now() - koreanWrapStarted);
        // Repair isolated closing punctuation in short Korean responses inside
        // the existing card. Keep the font and reject new word breaks or edge hits.
        if (!vertical && wrappingScript === 'korean' && displayedText.length <= 8 &&
            !/\\s/u.test(displayedText)) {
          const original = lineProfile();
          if (original && original.badStarts.length > 0) {
            const savedPadding = node.style.padding;
            const savedWordBreak = node.style.wordBreak;
            const savedLineBreak = node.style.lineBreak;
            const savedOverflowWrap = node.style.overflowWrap;
            for (const target of [node, measurementNode]) {
              target.style.paddingLeft = `${Math.min(1, parseFloat(target.style.paddingLeft || 0))}px`;
              target.style.paddingRight = `${Math.min(1, parseFloat(target.style.paddingRight || 0))}px`;
              target.style.wordBreak = 'normal';
              target.style.lineBreak = 'strict';
              target.style.overflowWrap = 'normal';
            }
            const candidate = lineProfile();
            const exclusions = Array.isArray(reference?.exclusionRects) ? reference.exclusionRects : [];
            const violates = profile => profile.ink.some(a =>
              a[0] < x + 0.9 || a[1] < y - 0.5 ||
              a[0] + a[2] > x + width - 0.9 || a[1] + a[3] > y + height + 0.5 ||
              exclusions.some(b => Math.min(a[0] + a[2], b[0] + b[2]) - Math.max(a[0], b[0]) > 0.5 &&
                Math.min(a[1] + a[3], b[1] + b[3]) - Math.max(a[1], b[1]) > 0.5));
            const accepted = candidate && contentFits() && candidate.lines <= original.lines &&
              candidate.badStarts.length < original.badStarts.length &&
              candidate.badEnds.length <= original.badEnds.length &&
              candidate.breaks.every(offset => original.breaks.includes(offset)) && !violates(candidate);
            if (accepted) node.dataset.koreanPunctuationRepair = 'accepted';
            else for (const target of [node, measurementNode]) {
              target.style.padding = savedPadding;
              target.style.wordBreak = savedWordBreak;
              target.style.lineBreak = savedLineBreak;
              target.style.overflowWrap = savedOverflowWrap;
            }
          }
        }
        // Preserve word and punctuation repairs while recovering readable paragraphs.
        // Same card, padding, alignment and neighboring cards; at most nine font probes.
        const paragraphStart = performance.now();
        const paragraphOriginalFont = parseFloat(node.style.fontSize);
        if (item.allowsAutomaticFontRecovery && !vertical && wrappingScript === 'korean' && paragraphOriginalFont < 8 &&
            displayedText.length >= 20 && displayedText.length <= 140 &&
            displayedText.length <= readableParagraphBudget && (/[가-힣]{5}/u.test(displayedText) || displayedText.trim().split(/\\s+/u).length >= 4)) {
          readableParagraphBudget -= displayedText.length;
          const original = lineProfile();
          const exclusions = items.filter(other => other !== item).flatMap(other => {
            const result = [[Number(other.x), Number(other.y), Number(other.width), Number(other.height)]];
            const b = other.sourceBounds, f = other.sourceFrame;
            if (Array.isArray(b) && Array.isArray(f)) result.push([
              f[0] + b[0] * f[2], f[1] + b[1] * f[3], b[2] * f[2], b[3] * f[3]]);
            return result;
          });
          if (Array.isArray(reference?.exclusionRects)) exclusions.push(...reference.exclusionRects);
          const safeSplits = profile => profile.breaks.every((offset, index, all) => {
            if (original.breaks.includes(offset)) return true;
            const left = displayedText.slice(0, offset).match(/[가-힣]+$/u)?.[0] || '';
            const right = displayedText.slice(offset).match(/^[가-힣]+/u)?.[0] || '';
            if (left.length + right.length < 5) return false;
            const previous = all[index - 1] ?? 0, next = all[index + 1] ?? displayedText.length;
            return Math.min(left.length, offset - previous) >= 2 &&
              Math.min(right.length, next - offset) >= 2;
          });
          let paragraphSourceCache;
          const sourceAllows = profile => {
            if (paragraphSourceCache === undefined) {
              paragraphSourceCache = null;
              const started = performance.now();
              const b = item.sourceBounds, f = item.sourceFrame;
              if (sourceImage?.complete && sourceImage.naturalWidth && cleanupContext &&
                  Array.isArray(b) && Array.isArray(f) && b.length === 4 && f.length === 4 &&
                  b.every(Number.isFinite) && f.every(Number.isFinite) && f[2] > 0 && f[3] > 0) {
                const iw=sourceImage.naturalWidth, ih=sourceImage.naturalHeight;
                const sx=iw/f[2], sy=ih/f[3];
                const left=Math.max(0,Math.floor(Math.min(b[0]*iw,(x-f[0])*sx)-3*sx));
                const top=Math.max(0,Math.floor(Math.min(b[1]*ih,(y-f[1])*sy)-3*sy));
                const right=Math.min(iw,Math.ceil(Math.max((b[0]+b[2])*iw,(x+width-f[0])*sx)+3*sx));
                const bottom=Math.min(ih,Math.ceil(Math.max((b[1]+b[3])*ih,(y+height-f[1])*sy)+3*sy));
                const w=right-left,h=bottom-top,n=w*h;
                if(w>=14&&h>=14&&n<=131072&&n<=paragraphSourcePixelBudget) {
                  paragraphSourcePixelBudget-=n;
                  root.dataset.readableParagraphSourcePixels=String(Number(root.dataset.readableParagraphSourcePixels||0)+n);
                  try {
                    cleanupCanvas.width=w;cleanupCanvas.height=h;
                    cleanupContext.drawImage(sourceImage,left,top,w,h,0,0,w,h);
                    const rgba=cleanupContext.getImageData(0,0,w,h).data;
                    const safe=paragraphSafePixels(rgba,w,h);
                    if(safe)paragraphSourceCache={safe,w,h,left,top,sx,sy,frame:f};
                  } catch (_) {}
                }
              }
              root.dataset.readableParagraphSourceMilliseconds=String(Number(root.dataset.readableParagraphSourceMilliseconds||0)+performance.now()-started);
            }
            const c=paragraphSourceCache;if(!c)return false;
            for(const a of profile.ink) {
              const l=Math.floor((a[0]-c.frame[0])*c.sx)-c.left;
              const t=Math.floor((a[1]-c.frame[1])*c.sy)-c.top;
              const r=Math.ceil((a[0]+a[2]-c.frame[0])*c.sx)-c.left;
              const b=Math.ceil((a[1]+a[3]-c.frame[1])*c.sy)-c.top;
              const count=(r-l)*(b-t);
              if(l<0||t<0||r>c.w||b>c.h||count<0||count>paragraphSourceLookupBudget)return false;
              paragraphSourceLookupBudget-=count;
              for(let yy=t;yy<b;yy++)for(let xx=l;xx<r;xx++)if(!c.safe[yy*c.w+xx])return false;
            }
            return true;
          };
          let accepted = false;
          if (original) for (let size = 10; size >= Math.max(8, paragraphOriginalFont + 0.75); size -= 0.25) {
            applyMeasuredFontSize(size);
            const profile = lineProfile();
            const safe = profile && contentFits() &&
              profile.badStarts.length <= original.badStarts.length &&
              profile.badEnds.length <= original.badEnds.length && safeSplits(profile) && profile.hangulIsolated <= original.hangulIsolated && (/[가-힣]{5}/u.test(displayedText) || profile.breaks.every(offset => original.breaks.includes(offset))) &&
              profile.ink.every(a => a[0] >= x + 0.9 && a[1] >= y + 0.9 &&
                a[0] + a[2] <= x + width - 0.9 && a[1] + a[3] <= y + height - 0.9 &&
                !exclusions.some(b => Math.min(a[0] + a[2], b[0] + b[2]) - Math.max(a[0], b[0]) > 0.25 &&
                  Math.min(a[1] + a[3], b[1] + b[3]) - Math.max(a[1], b[1]) > 0.25));
            if (safe && sourceAllows(profile)) { accepted = true; node.dataset.readableParagraph = 'accepted'; break; }
          }
          if (!accepted) applyMeasuredFontSize(paragraphOriginalFont);
        }
        root.dataset.readableParagraphMilliseconds = String(
          Number(root.dataset.readableParagraphMilliseconds || 0) + performance.now() - paragraphStart);

        // Transparent restored panels must fit the actual balloon surface,
        // not just the former rectangular card. Shrink only when measured
        // glyph boxes cross surviving ink or leave the reconstructed crop.
        const preRecoveryPadding=node.style.padding;
        const preRecoveryFont=parseFloat(node.style.fontSize);
        const preRecoveryProfile=preserveOriginalBackground?lineProfile():null;
        if(preserveOriginalBackground&&item.allowsAutomaticFontRecovery&&
            !vertical&&displayedText.length<=180){
          const initial=parseFloat(node.style.fontSize);
          // Restore dialogue to a readable size inside the already collision-
          // checked card, without increasing its footprint or changing wording.
          if(initial<10.5){
            applyMeasuredFontSize(10.5);
            if(!contentFits())applyMeasuredFontSize(initial);
            else node.dataset.captionFontRecovery='accepted';
          }
        }
        const panelGeometry=restoredPanelGeometry.get(item);
        let fitsRestoredSurface = null, readableRestoredInk = null;
        if(panelGeometry?.safe&&displayedText.length<=180){
          const c=panelGeometry,initial=parseFloat(node.style.fontSize);
          const finalPalette=aidokuCaptionPalette(sampled,foreground.split(',').map(Number),true);
          const linear=v=>{v/=255;return v<=.04045?v/12.92:((v+.055)/1.055)**2.4;};
          const inkL=.2126*linear(finalPalette.foreground[0])+.7152*linear(finalPalette.foreground[1])+.0722*linear(finalPalette.foreground[2]);
          let surfaceKey=null,surfaceRange=null;
          const inspectSurface=(profile,allowExterior=false)=>{
            if(!profile||!contentFits())return null;
            const key=JSON.stringify([profile.ink,allowExterior]);
            if(key===surfaceKey)return surfaceRange;
            surfaceKey=key;surfaceRange=null;
            let exterior=null;
            // Erasure stays at native OCR geometry. Read-only surface sampling
            // may extend to the final Korean glyphs; wider translation is not
            // evidence that the original must be covered by a wider rectangle.
            if(allowExterior&&c.surfaceQuality?.safe&&sourceImage?.complete&&cleanupContext){
              const rects=profile.ink.map(a=>[(a[0]-c.frame[0])*c.iw/c.frame[2],
                (a[1]-c.frame[1])*c.ih/c.frame[3],a[2]*c.iw/c.frame[2],a[3]*c.ih/c.frame[3]]);
              const l=Math.floor(Math.min(...rects.map(r=>r[0]))),t=Math.floor(Math.min(...rects.map(r=>r[1])));
              const r=Math.ceil(Math.max(...rects.map(r=>r[0]+r[2]))),b=Math.ceil(Math.max(...rects.map(r=>r[1]+r[3])));
              const pixels=(r-l)*(b-t),margin=24*c.iw/c.frame[2];
              if((l<c.x||t<c.y||r>c.x+c.w/c.sx||b>c.y+c.h/c.sy)&&
                  l>=0&&t>=0&&r<=c.iw&&b<=c.ih&&l>=c.x-margin&&r<=c.x+c.w/c.sx+margin&&
                  t>=c.y-margin&&b<=c.y+c.h/c.sy+margin&&pixels>0&&pixels<=Math.min(262144,restoredExteriorPixelBudget))try{
                restoredExteriorPixelBudget-=pixels;
                cleanupCanvas.width=r-l;cleanupCanvas.height=b-t;
                cleanupContext.drawImage(sourceImage,l,t,r-l,b-t,0,0,r-l,b-t);
                exterior={x:l,y:t,w:r-l,h:b-t,rgba:cleanupContext.getImageData(0,0,r-l,b-t).data};
              }catch(_){}
            }
            let minimum=Infinity,maximum=-Infinity;
            for(const a of profile.ink){
              const l=Math.floor(((a[0]-c.frame[0])*c.iw/c.frame[2]-c.x)*c.sx);
              const t=Math.floor(((a[1]-c.frame[1])*c.ih/c.frame[3]-c.y)*c.sy);
              const r=Math.ceil(((a[0]+a[2]-c.frame[0])*c.iw/c.frame[2]-c.x)*c.sx);
              const b=Math.ceil(((a[1]+a[3]-c.frame[1])*c.ih/c.frame[3]-c.y)*c.sy);
              const count=(r-l)*(b-t);
              if((!exterior&&(l<0||t<0||r>c.w||b>c.h))||count<0||count>restoredPanelLookupBudget)return null;
              restoredPanelLookupBudget-=count;
              for(let yy=t;yy<b;yy++)for(let xx=l;xx<r;xx++){
                let luminance;
                if(xx>=0&&yy>=0&&xx<c.w&&yy<c.h){
                  const i=yy*c.w+xx;if(!c.safe[i]||!c.luminance)return null;
                  luminance=c.luminance[i];
                }else{
                  if(!exterior)return null;
                  const x=Math.floor(c.x+(xx+.5)/c.sx)-exterior.x,y=Math.floor(c.y+(yy+.5)/c.sy)-exterior.y;
                  if(x<0||y<0||x>=exterior.w||y>=exterior.h)return null;
                  const i=(y*exterior.w+x)*4,rgb=Array.from(exterior.rgba.subarray(i,i+3));
                  const plane=c.surfaceQuality.coefficients.map(a=>a[0]+a[1]*xx/c.w+a[2]*yy/c.h);
                  // Coordinated columns have already passed the independent
                  // exposed-pixel gradient/edge gate across their full height.
                  // Permit its 24 RGB lighting tolerance beyond the OCR crop;
                  // ordinary balloons retain the stricter surface boundary.
                  const tolerance=item.balancedColumn&&c.sourceErasureVerified?24:18;
                  if(exterior.rgba[i+3]<254||Math.max(...rgb.map((v,c)=>Math.abs(v-plane[c])))>tolerance)return null;
                  luminance=255*aidokuSourceColorLuminance(rgb);
                }
                minimum=Math.min(minimum,luminance);maximum=Math.max(maximum,luminance);
              }
            }
            if(!Number.isFinite(minimum))return null;
            // Keep half a quantization step of contrast headroom. Reuse these
            // bounds when trying another ink color, without rereading pixels.
            surfaceRange=[Math.max(0,(minimum-.5)/255),Math.min(1,(maximum+.5)/255)];
            return surfaceRange;
          };
          const surfaceContrast=(range,foregroundL)=>{
            if(!range)return 0;
            const [lo,hi]=range;
            return foregroundL<lo?(lo+.05)/(foregroundL+.05):foregroundL>hi?(foregroundL+.05)/(hi+.05):1;
          };
          const onSurface=(profile,foregroundL=inkL)=>{
            const contrast=surfaceContrast(inspectSurface(profile),foregroundL);
            if(contrast<4.5)return false;
            node.dataset.sourcePanelMinimumContrast=String(contrast);return true;
          };
          fitsRestoredSurface=onSurface;
          readableRestoredInk=(profile,ink)=>{
            const range=inspectSurface(profile,true);if(!range)return null;
            const contrast=rgb=>surfaceContrast(range,aidokuSourceColorLuminance(rgb));
            const adjusted=aidokuAdjustInkForContrast(ink,contrast);
            if(contrast(adjusted)<4.5)return null;
            node.dataset.sourcePanelMinimumContrast=String(contrast(adjusted));
            node.dataset.sourcePanelSurfaceLuminance=JSON.stringify(range);return adjusted;
          };
          // Check the normal size first. A bounded artwork-protection pass
          // may later trade a little size for a verified balloon surface.
          const fits=onSurface(lineProfile());
          node.dataset.sourcePanelInitialFont=String(initial);
          if(!fits)restoredSourcePanels.delete(item);
          node.dataset.sourcePanelTextFit=fits?'inside':'caption';
          node.dataset.sourcePanelFinalFont=String(parseFloat(node.style.fontSize));
        }
        if(node.dataset.captionFontRecovery==='accepted'&&preRecoveryProfile){
          const profile=lineProfile();
          if(!profile||profile.breaks.length>preRecoveryProfile.breaks.length||
              profile.badStarts.length>preRecoveryProfile.badStarts.length||
              profile.punctuationOnly>preRecoveryProfile.punctuationOnly||
              profile.hangulIsolated>preRecoveryProfile.hangulIsolated){
            applyMeasuredFontSize(preRecoveryFont);node.dataset.captionFontRecovery='retained-word-flow';
          }
        }
        // Search intermediate sizes instead of choosing between an oversized
        // 10.5 pt proposal and the original emergency font. Every accepted size
        // preserves whole-word flow and the already validated source surface.
        if (preserveOriginalBackground && item.allowsAutomaticFontRecovery && !vertical &&
            wrappingScript === 'korean' && displayedText.length <= 180 &&
            displayedText.length <= readableRefinementBudget) {
          const originalSize = parseFloat(node.style.fontSize);
          if (originalSize < 10.25) {
            readableRefinementBudget -= displayedText.length;
            const original = lineProfile();
            let accepted = false;
            const savedPadding = node.style.padding;
            const paddings = [...new Set([savedPadding, preRecoveryPadding])];
            if (original) recovery: for (let candidate = 10.5; candidate >= originalSize + 0.5; candidate -= 0.25) {
              applyMeasuredFontSize(candidate);
              for (const padding of paddings) {
                node.style.padding = padding; measurementNode.style.padding = padding;
                if (!contentFits()) continue;
                if (displayedText.length > captionRecoveryCharacterBudget) break recovery;
                captionRecoveryCharacterBudget -= displayedText.length;
                const profile = lineProfile();
                if (!profile || profile.breaks.some(offset => !original.breaks.includes(offset)) ||
                    profile.badStarts.length > original.badStarts.length ||
                    profile.badEnds.length > original.badEnds.length ||
                    profile.punctuationOnly > original.punctuationOnly ||
                    profile.hangulIsolated > original.hangulIsolated) continue;
                accepted = true;
                node.dataset.captionFontRecovery = 'measured-word-flow';
                break recovery;
              }
            }
            if (!accepted) {
              applyMeasuredFontSize(originalSize);
              node.style.padding = savedPadding; measurementNode.style.padding = savedPadding;
            }
          }
        }
        if(panelGeometry){
          const fits=Boolean(fitsRestoredSurface&&fitsRestoredSurface(lineProfile()));
          if(fits)restoredSourcePanels.add(item);
          else restoredSourcePanels.delete(item);
          node.dataset.sourcePanelTextFit=fits?'inside':'caption';
        }
        // Defer text-only reflow until the existing algorithm has frozen the
        // background box. These probes must never feed back into box geometry.
        captionTextReflows.set(item, (box, pad) => {
          if (!preserveOriginalBackground || opacity <= 0 || !item.allowsAutomaticFontRecovery ||
              vertical || wrappingScript !== 'korean' || displayedText.length > 180 ||
              /[\\r\\n]/u.test(displayedText) || displayedText.length * 4 > captionReflowCharacterBudget) return;
          captionReflowCharacterBudget -= displayedText.length * 4;
          root.appendChild(measurementNode);
          measurementNode.style.visibility = 'hidden';
          try {
            const original = lineProfile();
            if (!original || original.lines < 2) return;
            const savedX = x, savedWidth = width, savedPadding = node.style.padding;
            const style = getComputedStyle(node);
            const usableWidth = width - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight);
            const available = box.right - box.left - pad * 2;
            if (available <= usableWidth + .5) return;
            const obstacles = Array.from(root.querySelectorAll('[data-aidoku-image-ocr-overlay="item"]'))
              .filter(other => other !== node).map(other => other.getBoundingClientRect());
            for (const scale of [1, .67, .33]) {
              width = usableWidth + (available - usableWidth) * scale;
              x = box.left + (box.right - box.left - width) / 2;
              for (const n of [node, measurementNode]) {
                n.style.left = `${x+scrollX}px`; n.style.width = `${width}px`;
                n.style.paddingLeft = '0px'; n.style.paddingRight = '0px';
              }
              const profile = lineProfile();
              if (profile && contentFits() && profile.lines <= original.lines &&
                  profile.breaks.every(offset => original.breaks.includes(offset)) &&
                  profile.badStarts.length <= original.badStarts.length &&
                  profile.badEnds.length <= original.badEnds.length &&
                  profile.hangulIsolated <= original.hangulIsolated &&
                  profile.punctuationOnly <= original.punctuationOnly &&
                  profile.ink.every(r => r[0] >= box.left + pad - .5 && r[0]+r[2] <= box.right-pad+.5 &&
                    r[1] >= box.top-.5 && r[1]+r[3] <= box.bottom+.5 &&
                    !obstacles.some(o => Math.min(r[0]+r[2],o.right)-Math.max(r[0],o.left)>.5 &&
                      Math.min(r[1]+r[3],o.bottom)-Math.max(r[1],o.top)>.5)) &&
                  (profile.lines < original.lines || profile.breaks.length < original.breaks.length ||
                    profile.hangulIsolated < original.hangulIsolated)) {
                node.dataset.captionReflow = 'inside-fixed-box';
                node.dataset.captionOriginalWidth = String(savedWidth);
                node.dataset.captionOriginalLines = String(original.lines);
                node.dataset.captionFinalLines = String(profile.lines);
                return;
              }
              x = savedX; width = savedWidth;
              for (const n of [node, measurementNode]) {
                n.style.left = `${x+scrollX}px`; n.style.width = `${width}px`; n.style.padding = savedPadding;
              }
            }
          } finally { measurementNode.remove(); }
        });
        if (item.sourceColorEligible && item.sourceTextOnly === false && !vertical &&
            displayedText.length <= 180 && displayedText.length * 3 <= typographyCharacterBudget) {
          typographyCharacterBudget -= displayedText.length * 3;
          const profilePenalty=p=>p.breaks.length*4+p.hangulFragments*12+p.punctuationOnly*12+
            p.badStarts.length*12+p.badEnds.length*12;
          const rememberInk=p=>{
            if(p&&!typographyInkFrames.has(item))typographyInkFrames.set(item,
              aidokuCaptionInkFrame(p.ink,parseFloat(node.style.fontSize)));
          };
          const contained=(p,baseline)=>p && p.ink.every(r=>r[0]>=x-.5&&r[0]+r[2]<=x+width+.5&&
            r[1]>=y-.5&&r[1]+r[3]<=Math.min(y+height,item.balancedColumn
              ? Math.max(y+(Number(item.columnLayout?.inspectionHeight)||height),
                  ...baseline.ink.map(glyph=>glyph[1]+glyph[3])) : y+height)+.5);
          // Establish the readable cohort and word flow before considering
          // a bounded size reduction to protect surrounding artwork.
          const saveType=()=>({display:node.style.display,padding:node.style.padding,
            children:Array.from(node.childNodes).map(child=>child.cloneNode(true))});
          const restoreType=saved=>{
            for(const n of [node,measurementNode]){
              n.style.display=saved.display;n.style.padding=saved.padding;
              n.replaceChildren(...saved.children.map(child=>child.cloneNode(true)));
            }
          };
          const wordLines=maxLines=>{
            if(wrappingScript!=='korean'||/[\\r\\n]/u.test(displayedText)||!koreanWrapMeasure)return false;
            const size=parseFloat(node.style.fontSize);
            const available=width-parseFloat(node.style.paddingLeft)-parseFloat(node.style.paddingRight);
            if(available/size>8)return false;
            koreanWrapMeasure.font=`${node.style.fontWeight} ${node.style.fontSize} ${node.style.fontFamily}`;
            const lines=aidokuKoreanLines(displayedText,available,maxLines,part=>
              koreanWrapMeasure.measureText(part).width+Math.max(0,Array.from(part).length-1)*size*(-.012));
            if(!lines||lines.length<2)return false;
            for(const n of [node,measurementNode]){
              n.textContent='';n.style.display='block';
              for(const line of lines){
                const span=document.createElement('span');span.textContent=line;
                Object.assign(span.style,{display:'block',width:'max-content',maxWidth:'100%',margin:'0 auto',whiteSpace:'nowrap'});
                n.appendChild(span);
              }
              if(!item.balancedColumn)n.style.paddingTop=`${Math.max(parseFloat(n.style.paddingTop),
                (height-lines.length*size*lineHeightRatio)/2)}px`;
            }
            return true;
          };
          typographyEntries.push({id:item.id,source:item.sourceFontSize,font:parseFloat(node.style.fontSize),
            script:fontScript,vertical,column:Boolean(item.balancedColumn),
            apply: target => {
              const originalSize=parseFloat(node.style.fontSize);
              node.dataset.fontClusterOriginal=String(originalSize);
              node.dataset.fontClusterTarget=String(target);
              const candidates=aidokuCohortFontCandidates(originalSize,target,minimumFontSize);
              if(!candidates.length){
                if(Math.abs(target-originalSize)<.01)node.dataset.fontCluster=String(target);
                return;
              }
              measurementHost.appendChild(measurementNode);
              try {
                const original=lineProfile(), saved=saveType();
                if(!original)return;
                rememberInk(original);
                // Compare against the readable wrapping available at the old
                // font, not just its uncorrected browser wrapping. Otherwise
                // growing a caption can reintroduce an orphan that wrap()
                // would have removed without changing its size.
                let flowBaseline=original;
                if(original.hangulFragments>0&&wordLines(original.lines)){
                  const reflow=lineProfile();
                  if(aidokuKoreanWrapImproves(reflow,original)&&contentFits()&&contained(reflow,original))
                    flowBaseline=reflow;
                  restoreType(saved);
                }
                // A constrained caption may approach the cohort size without
                // making all of its neighbors inherit that emergency font.
                const allowance=candidates[0]>originalSize ? Math.max(2,Math.ceil(original.lines*.35)) : 0;
                for(const size of candidates){
                  restoreType(saved);applyMeasuredFontSize(size);
                  let candidate=lineProfile(), wordAware=false;
                  const measured=saveType();
                  if(wordLines(original.lines+allowance)){
                    const words=lineProfile();
                    if(words&&contentFits()&&contained(words,original)&&(!candidate||profilePenalty(words)<profilePenalty(candidate))){
                      candidate=words;wordAware=true;
                    } else restoreType(measured);
                  }
                  const extraWordBreaks=wrappingScript==='korean'&&originalSize<8&&size>originalSize ? 2 : 0;
                  if(candidate&&contentFits()&&contained(candidate,original)&&candidate.lines<=original.lines+allowance&&
                      // Rebalancing existing cuts is valid: the number of split
                      // words and isolated syllables, not their old offsets,
                      // determines whether the larger cohort font still reads well.
                      aidokuFontFlowFits(candidate,flowBaseline,extraWordBreaks)){
                    node.dataset.fontCluster=String(target);
                    if(wordAware){node.dataset.koreanLineLayout='word-aware';captionTextReflows.delete(item);}
                    return;
                  }
                }
                restoreType(saved);applyMeasuredFontSize(originalSize);
              } finally {measurementNode.remove();}
            },
            restoreReadableInk: () => {
              if(!readableRestoredInk||!panelGeometry?.erasureComplete||opacity!==1)return false;
              // Readable new glyphs alone do not prove that source glyphs over
              // artwork elsewhere in the OCR box have all been removed.
              if(!panelGeometry.sourceErasureVerified&&!restoredSourcePanels.has(item))return false;
              const ink=node.dataset.sourceAppliedTextRGB?.split(',').map(Number);
              if(ink?.length!==3||!ink.every(Number.isFinite))return false;
              measurementNode.style.cssText=node.style.cssText;
              measurementNode.replaceChildren(...Array.from(node.childNodes).map(child=>child.cloneNode(true)));
              measurementNode.style.visibility='hidden';measurementHost.appendChild(measurementNode);
              const saved={x,y,width,height};
              x=parseFloat(node.style.left)-scrollX;y=parseFloat(node.style.top)-scrollY;
              width=parseFloat(node.style.width);height=parseFloat(node.style.height);
              try {
                const adjusted=readableRestoredInk(lineProfile(),ink);if(!adjusted)return false;
                node.style.color=`rgb(${adjusted.join(',')})`;
                node.dataset.sourceAppliedTextRGB=adjusted.join(',');
                node.dataset.sourceRestoredInkAdjusted=String(adjusted.some((v,c)=>v!==ink[c]));
                node.dataset.sourcePanelTextFit='inside';restoredSourcePanels.add(item);return true;
              } finally {({x,y,width,height}=saved);measurementNode.remove();}
            },
            fitBalloon: () => {
              if(item.balancedColumn||item.rotation||wrappingScript!=='korean'||!fitsRestoredSurface||
                  /[\\r\\n]/u.test(displayedText)||displayedText.length>80)return false;
              const font=parseFloat(node.style.fontSize),priorFont=Number(node.dataset.artworkOriginalFont);
              const sizes=aidokuBalloonFontSizes(font).filter(size=>!priorFont||size>=Math.max(8.5,priorFont*.8));
              if(!sizes.length)return false;
              const plate=Array.from(root.querySelectorAll('[data-aidoku-image-ocr-overlay="source-readability-panel"]'))
                .find(p=>p.dataset.aidokuRegion===String(item.id)&&p.dataset.sourceErasure!=='true');
              if(!plate)return false;
              const p=plate.getBoundingClientRect(),intersects=r=>r[0]<p.right&&r[0]+r[2]>p.left&&r[1]<p.bottom&&r[1]+r[3]>p.top;
              const otherBackgrounds=Array.from(root.querySelectorAll('[data-aidoku-image-ocr-overlay="source-readability-panel"], [data-aidoku-image-ocr-overlay="source-readability-backing"]'))
                .filter(layer=>layer!==plate).map(layer=>layer.getBoundingClientRect());
              // Removing this card must not uncover another original or deprive
              // a neighboring caption of its readable backing.
              if(items.some(other=>other!==item&&[other.sourceBounds,...(other.auxiliaryInkRects||[])].some(b=>{
                const f=cleanupImageGeometry?.frame||other.sourceFrame;
                return f&&b&&intersects([f[0]+b[0]*f[2]-3,f[1]+b[1]*f[3]-3,b[2]*f[2]+6,b[3]*f[3]+6]);
              }))||Array.from(root.querySelectorAll('[data-aidoku-image-ocr-overlay="item"]')).some(other=>{
                if(other===node)return false;const range=document.createRange();range.selectNodeContents(other);
                const r=range.getBoundingClientRect();return intersects([r.left,r.top,r.width,r.height]);
              }))return false;
              measurementNode.style.cssText=node.style.cssText;
              measurementNode.replaceChildren(...Array.from(node.childNodes).map(c=>c.cloneNode(true)));
              measurementNode.style.visibility='hidden';measurementHost.appendChild(measurementNode);
              const saved={x,y,width,height,style:node.style.cssText,children:Array.from(node.childNodes).map(c=>c.cloneNode(true))};
              // Anchoring already committed directly to the live DOM. Measure
              // that final position, not the closure's earlier planner values.
              x=parseFloat(node.style.left)-scrollX;y=parseFloat(node.style.top)-scrollY;
              width=parseFloat(node.style.width);height=parseFloat(node.style.height);
              let accepted=false;
              try {
                const original=lineProfile(),box=aidokuCaptionInkFrame(original?.ink,font);
                if(!box)return false;
                const liveRange=document.createRange();liveRange.selectNodeContents(node);
                const liveOriginal=liveRange.getBoundingClientRect();
                const cx=(box.left+box.right)/2,cy=(box.top+box.bottom)/2;
                // A certified erasure no longer makes a tall backing plate.
                // Keep that original vertical room available to the font-fit
                // search; every proposed glyph must still pass the pixel gate.
                const sourceFrame=cleanupImageGeometry?.frame||item.sourceFrame,b=item.sourceBounds;
                const top=sourceFrame&&b?Math.min(p.top,sourceFrame[1]+b[1]*sourceFrame[3]):p.top;
                const bottom=sourceFrame&&b?Math.max(p.bottom,sourceFrame[1]+(b[1]+b[3])*sourceFrame[3]):p.bottom;
                const availableHeight=2*Math.min(cy-top-2,bottom-cy-2);
                const widths=[...new Set([1,.9,.8,.7,.6].map(scale=>Math.floor((box.right-box.left)*scale*4)/4))];
                const ink=node.dataset.sourceAppliedTextRGB?.split(',').map(Number);
                if(ink?.length!==3||!ink.every(Number.isFinite))return false;
                for(const size of sizes)for(const candidateWidth of widths){
                  if(candidateWidth<size*1.8||displayedText.length>balloonTypeBudget||balloonSurfaceBudget<=0)continue;
                  balloonTypeBudget-=displayedText.length;
                  x=cx-candidateWidth/2;y=cy-availableHeight/2;width=candidateWidth;height=availableHeight;
                  for(const n of [node,measurementNode]){
                    Object.assign(n.style,{left:`${x+scrollX}px`,top:`${y+scrollY}px`,width:`${width}px`,height:`${height}px`,
                      display:'block',padding:'0px',whiteSpace:'pre-wrap'});
                    n.textContent=displayedText;
                  }
                  applyMeasuredFontSize(size);
                  const maxLines=Math.min(original.lines+3,Math.floor(height/(size*lineHeightRatio)));
                  if(maxLines<1)continue;
                  if(!wordLines(maxLines)){
                    if(!koreanWrapMeasure||koreanWrapMeasure.measureText(displayedText).width>width)continue;
                    for(const n of [node,measurementNode])n.style.paddingTop=`${Math.max(0,(height-size*lineHeightRatio)/2)}px`;
                  }
                  const candidate=lineProfile();
                  if(!candidate||!contentFits()||!aidokuFontFlowFits(candidate,original,1)||candidate.lines>maxLines)continue;
                  const next=aidokuCaptionInkFrame(candidate.ink,size);
                  if(!next||next.left<p.left||next.right>p.right||next.top<top||next.bottom>bottom)continue;
                  // The image's clean pixels are not the visible surface when
                  // another opaque layer still covers the proposed lettering.
                  if(otherBackgrounds.some(r=>next.left-1<r.right&&next.right+1>r.left&&
                      next.top-.75<r.bottom&&next.bottom+.75>r.top))continue;
                  // A little breathing room inside the actual restored balloon,
                  // with the final clustered ink color, is mandatory.
                  const probe={...candidate,ink:candidate.ink.map(r=>[r[0]-1,r[1]-.75,r[2]+2,r[3]+1.5])};
                  const previous=restoredPanelLookupBudget,allowance=Math.min(balloonSurfaceBudget,65536);
                  restoredPanelLookupBudget=allowance;let fits=false;
                  try {fits=fitsRestoredSurface(probe,aidokuSourceColorLuminance(ink));}
                  finally {balloonSurfaceBudget-=allowance-restoredPanelLookupBudget;restoredPanelLookupBudget=previous;}
                  if(!fits)continue;
                  // The offscreen measurement host can round differently from
                  // the page. Verify the actual displayed DOM, including its
                  // whitespace and font metrics, before removing the backing.
                  liveRange.selectNodeContents(node);const liveNext=liveRange.getBoundingClientRect();
                  if(Math.abs(liveNext.left+liveNext.width/2-liveOriginal.left-liveOriginal.width/2)>1.5||
                      Math.abs(liveNext.top+liveNext.height/2-liveOriginal.top-liveOriginal.height/2)>1.5)continue;
                  const flow=p=>({lines:p.lines,breaks:p.breaks.length,fragments:p.hangulFragments,
                    punctuation:p.punctuationOnly,badStarts:p.badStarts.length,badEnds:p.badEnds.length});
                  node.dataset.balloonFontFit='restored-surface';node.dataset.balloonOriginalFont=String(font);
                  node.dataset.balloonOriginalInk=JSON.stringify([liveOriginal.left,liveOriginal.top,liveOriginal.width,liveOriginal.height]);
                  node.dataset.balloonOriginalFlow=JSON.stringify(flow(original));node.dataset.balloonFinalFlow=JSON.stringify(flow(candidate));
                  node.dataset.sourcePanelFinalFont=String(size);node.dataset.sourcePanelTextFit='inside';
                  node.dataset.sourceBackgroundColor='inpainted';node.dataset.sourceAppliedBackgroundRGB='';
                  delete node.dataset.inpaintingFallback;plate.remove();readabilityPanels--;accepted=true;return true;
                }
                return false;
              } finally {
                if(!accepted){
                  ({x,y,width,height}=saved);node.style.cssText=saved.style;
                  node.replaceChildren(...saved.children.map(c=>c.cloneNode(true)));
                }
                measurementNode.remove();
              }
            },
            protectArtwork: () => {
              if(!artworkFirst||item.balancedColumn||item.rotation||wrappingScript==='rightToLeft'||
                  /[\\r\\n]/u.test(displayedText)||restoredSourcePanels.has(item))return;
              const originalFont=parseFloat(node.style.fontSize),sizes=aidokuArtworkFontSizes(originalFont);
              if(!sizes.length||displayedText.length*sizes.length>artworkTypeBudget)return;
              artworkTypeBudget-=displayedText.length*sizes.length;
              measurementNode.style.cssText=node.style.cssText;
              measurementNode.replaceChildren(...Array.from(node.childNodes).map(c=>c.cloneNode(true)));
              measurementNode.style.visibility='hidden';
              measurementHost.appendChild(measurementNode);
              const saved={x,y,width,height,style:node.style.cssText,measurement:measurementNode.style.cssText,
                children:Array.from(node.childNodes).map(c=>c.cloneNode(true))};
              let accepted=false;
              try {
                const original=lineProfile(),box=aidokuCaptionInkFrame(original?.ink,originalFont);
                if(!original||!box)return;
                const f=cleanupImageGeometry?.frame||item.sourceFrame,b=item.sourceBounds;
                if(!f||!b)return;
                if(panelGeometry?.erasureComplete&&panelGeometry.residualLettering===undefined){
                  const c=panelGeometry;
                  const regions=[b,...(item.auxiliaryInkRects||[])].map(r=>
                    [(r[0]*c.iw-c.x)*c.sx,(r[1]*c.ih-c.y)*c.sy,r[2]*c.iw*c.sx,r[3]*c.ih*c.sy]);
                  const glyph=Math.max(4,(Number(item.sourceFontSize)||originalFont)*c.iw/c.frame[2]*c.sx);
                  c.residualLettering=aidokuHasResidualLettering(c.safe,c.w,c.h,regions,glyph);
                }
                const plate=Array.from(root.querySelectorAll('[data-aidoku-image-ocr-overlay="source-readability-panel"]'))
                  .find(p=>p.dataset.aidokuRegion===String(item.id)&&p.dataset.sourceErasure!=='true');
                if(!plate)return;
                const p=plate.getBoundingClientRect();
                const overlaps=r=>Math.min(p.right,r[0]+r[2])-Math.max(p.left,r[0])>.04&&
                  Math.min(p.bottom,r[1]+r[3])-Math.max(p.top,r[1])>.04;
                // Even a verified restoration owns only this source's ink.
                // Keep a plate that also erases another source or backs its text.
                const shared=items.some(other=>other!==item&&[other.sourceBounds,...(other.auxiliaryInkRects||[])].some(r=>{
                  const frame=cleanupImageGeometry?.frame||other.sourceFrame;
                  return frame&&r&&overlaps([frame[0]+r[0]*frame[2]-3,frame[1]+r[1]*frame[3]-3,r[2]*frame[2]+6,r[3]*frame[3]+6]);
                }))||Array.from(root.querySelectorAll('[data-aidoku-image-ocr-overlay="item"]')).some(other=>{
                  if(other===node)return false;
                  const range=document.createRange();range.selectNodeContents(other);const r=range.getBoundingClientRect();
                  return overlaps([r.left,r.top,r.width,r.height]);
                });
                const source=[f[0]+b[0]*f[2]-3,f[1]+b[1]*f[3]-3,b[2]*f[2]+6,b[3]*f[3]+6];
                const bg=aidokuCaptionPalette(sampled,null,true).background;
                const points=[];
                if(sourceImage?.complete&&cleanupContext&&artworkProbePixels>=1024){
                  cleanupCanvas.width=32;cleanupCanvas.height=32;artworkProbePixels-=1024;
                  cleanupContext.drawImage(sourceImage,(box.left-f[0])/f[2]*sourceImage.naturalWidth,
                    (box.top-f[1])/f[3]*sourceImage.naturalHeight,(box.right-box.left)/f[2]*sourceImage.naturalWidth,
                    (box.bottom-box.top)/f[3]*sourceImage.naturalHeight,0,0,32,32);
                  const pixels=cleanupContext.getImageData(0,0,32,32).data;
                  for(let yy=0;yy<32;yy++)for(let xx=0;xx<32;xx++){
                    const px=box.left+(xx+.5)/32*(box.right-box.left),py=box.top+(yy+.5)/32*(box.bottom-box.top);
                    if(px>=source[0]&&px<=source[0]+source[2]&&py>=source[1]&&py<=source[1]+source[3])continue;
                    const p=(yy*32+xx)*4;
                    if(pixels[p+3]>=250&&Math.max(...bg.map((v,c)=>Math.abs(v-pixels[p+c])))>48)points.push([px,py]);
                  }
                }
                const risk=r=>points.filter(([px,py])=>px>=r.left-3&&px<=r.right+3&&py>=r.top-3&&py<=r.bottom+3).length;
                const before=risk(box),riskArea=before/1024*(box.right-box.left)*(box.bottom-box.top);
                if(riskArea<80&&!fitsRestoredSurface)return;
                // Freeze the accepted word breaks, then scale real font metrics
                // inside the old ink footprint. No shifted caption or new orphan.
                const starts=[...new Set([0,...original.lineStarts])].sort((a,b)=>a-b);
                const lines=starts.map((start,i)=>displayedText.slice(start,starts[i+1]??displayedText.length));
                x=box.left;y=box.top;width=box.right-box.left;height=box.bottom-box.top;
                for(const n of [node,measurementNode]){
                  Object.assign(n.style,{left:`${x+scrollX}px`,top:`${y+scrollY}px`,width:`${width}px`,height:`${height}px`,
                    padding:'0px',display:'flex',flexDirection:'column',alignItems:'center',justifyContent:'center'});
                  n.replaceChildren(...lines.map(line=>{const span=document.createElement('span');span.textContent=line;
                    Object.assign(span.style,{display:'block',whiteSpace:'pre',flexShrink:'0',width:'max-content',maxWidth:'100%'});return span;}));
                }
                for(const size of sizes){
                  applyMeasuredFontSize(size);
                  const candidate=lineProfile(),next=aidokuCaptionInkFrame(candidate?.ink,size);
                  if(!next||!contentFits()||!aidokuFontFlowFits(candidate,original)||candidate.lines!==original.lines||
                      next.left<box.left-.04||next.top<box.top-.04||next.right>box.right+.04||next.bottom>box.bottom+.04)continue;
                  let surface=false;
                  if(!shared&&panelGeometry?.erasureComplete&&!panelGeometry.residualLettering&&fitsRestoredSurface&&artworkSurfaceBudget>0){
                    const previous=restoredPanelLookupBudget,allowance=Math.min(artworkSurfaceBudget,65536);
                    restoredPanelLookupBudget=allowance;
                    try {surface=fitsRestoredSurface(candidate);}
                    finally {artworkSurfaceBudget-=allowance-restoredPanelLookupBudget;restoredPanelLookupBudget=previous;}
                  }
                  if(!surface&&!(riskArea>=80&&risk(next)<=before*.65))continue;
                  node.dataset.artworkFit=surface?'restored-surface':'smaller-caption';
                  node.dataset.artworkOriginalFont=String(originalFont);
                  node.dataset.artworkOriginalInk=JSON.stringify([box.left,box.top,box.right-box.left,box.bottom-box.top]);
                  node.dataset.artworkFinalFont=String(size);
                  node.dataset.artworkSourceErasure=surface?'restored':'covered';
                  node.dataset.artworkRiskBefore=String(before);node.dataset.artworkRiskAfter=String(risk(next));
                  captionTextReflows.delete(item);
                  if(surface){
                    restoredSourcePanels.add(item);node.dataset.sourcePanelTextFit='inside';
                    node.dataset.sourceBackgroundColor='inpainted';node.dataset.sourceAppliedBackgroundRGB='';
                    delete node.dataset.inpaintingFallback;
                    plate.remove();readabilityPanels--;
                  }
                  node.dataset.sourcePanelFinalFont=String(size);
                  accepted=true;break;
                }
              } catch (_) {} finally {
                if(!accepted){
                  ({x,y,width,height}=saved);
                  node.style.cssText=saved.style;measurementNode.style.cssText=saved.measurement;
                  for(const n of [node,measurementNode])n.replaceChildren(...saved.children.map(c=>c.cloneNode(true)));
                }
                measurementNode.remove();
              }
            },
            finalize: () => {
              if(!panelGeometry)return;
              measurementHost.appendChild(measurementNode);
              try {
                const fits=Boolean(fitsRestoredSurface&&fitsRestoredSurface(lineProfile()));
                if(fits)restoredSourcePanels.add(item);else restoredSourcePanels.delete(item);
                node.dataset.sourcePanelTextFit=fits?'inside':'caption';
                node.dataset.sourcePanelFinalFont=String(parseFloat(node.style.fontSize));
              } finally {measurementNode.remove();}
            },
            wrap: () => {
              if(wrappingScript!=='korean'||node.dataset.koreanLineLayout==='word-aware')return;
              measurementHost.appendChild(measurementNode);
              try {
                const original=lineProfile(),saved=saveType();
                rememberInk(original);
                if(!original||original.lines<2||profilePenalty(original)===0||!wordLines(original.lines))return;
                const candidate=lineProfile();
                if(!aidokuKoreanWrapImproves(candidate,original)||!contentFits()||!contained(candidate,original))
                  restoreType(saved);
                else {node.dataset.koreanLineLayout='word-aware';captionTextReflows.delete(item);}
              } finally {measurementNode.remove();}
            }});
        }
        if(node.dataset.sourcePanelFinalFont)node.dataset.sourcePanelFinalFont=String(parseFloat(node.style.fontSize));
        measurementNode.remove();
        renderedItemCount += 1;
      }
      for (const group of aidokuFontClusters(typographyEntries))
        for (const entry of group.members) entry.apply(group.font);
      for (const entry of typographyEntries) entry.wrap();
      for (const entry of typographyEntries) entry.finalize();
    } catch (error) {
      aidokuReleaseOverlayResources(root);
      throw error;
    } finally {
      measurementHost.remove();
      cleanupCanvas.width = 0; cleanupCanvas.height = 0;
    }

    const acceptedAtCommit = Number(globalThis[watermarkKey] ?? -1);
    const sessionAtCommit = String(globalThis[sessionKey] ?? '');
    const rootAtCommit = document.querySelector(
      '[data-aidoku-image-ocr-overlay="root"]'
    );
    const revisionAtCommit = Number(
      rootAtCommit?.dataset.aidokuRevision || -1
    );
    const rootSessionAtCommit = String(
      rootAtCommit?.dataset.aidokuSession ?? sessionAtCommit
    );
    const sameSessionAtCommit = sessionAtCommit === sessionValue &&
      rootSessionAtCommit === sessionValue;
    if (sameSessionAtCommit &&
        (acceptedAtCommit > revisionNumber || revisionAtCommit > revisionNumber)) {
      aidokuReleaseOverlayResources(root);
      return {
        status: 'stale', revision: String(revision),
        itemCount: rootAtCommit?.querySelectorAll(
          '[data-aidoku-image-ocr-overlay="item"]'
        ).length || 0
      };
    }
    globalThis[watermarkKey] = revisionNumber;
    globalThis[sessionKey] = sessionValue;
    root.dataset.sourceColorPixels = String(sourceColors.stats.pixels + translatedSourceColors.stats.pixels);
    root.dataset.sourceColorCacheHits = String(sourceColors.stats.hits + translatedSourceColors.stats.hits);
    root.dataset.sourceColorSamples = String(sourceColors.stats.samples + translatedSourceColors.stats.samples);
    root.dataset.sourceColorMilliseconds = String(sourceColors.stats.milliseconds + translatedSourceColors.stats.milliseconds);
    root.dataset.cleanupCacheBytes = String(cleanupCache?.bytes || 0);
    if (rootAtCommit) {
      rootAtCommit.replaceWith(root);
      aidokuReleaseOverlayResources(rootAtCommit);
    } else mount.appendChild(root);
    // Verified, readable restorations keep their spatial background. Other
    // captions cover translated ink and any unerased source ink separately
    // when joining a tall source column would needlessly hide its surroundings.
    let readabilityPanels=0;
    const typographyByID=new Map(typographyEntries.map(entry=>[String(entry.id),entry]));
    mount.appendChild(measurementHost);
    for(const item of items){
      if(!appearance?.preserveSourceBackgroundColor||!item.sourceColorEligible||opacity<=0||item.rotation)continue;
      const node=Array.from(root.querySelectorAll('[data-aidoku-image-ocr-overlay="item"]')).find(n=>n.dataset.aidokuRegion===String(item.id));
      if(!node)continue;
      const sourceSample=cachedSourceSample(item);
      const ink=node.dataset.sourceAppliedTextRGB.split(',').map(Number);
      const palette=aidokuCaptionPalette(sourceSample,ink,Boolean(appearance?.preserveSourceTextColor));
      node.style.color=`rgb(${palette.foreground.join(',')})`;
      node.dataset.sourceAppliedTextRGB=palette.foreground.join(',');
      node.dataset.sourceTextColor=palette.preserved?'preserved':'fallback';
      node.dataset.sourceTextColorAdjusted=String(palette.preserved&&
        palette.foreground.some((v,i)=>v!==(sourceSample.foreground||sourceSample.displayForeground||aidokuSourceDisplayInk(sourceSample))[i]));
      node.dataset.captionSurface=palette.observed?'observed':'paper-fallback';
      node.style.textShadow='none';node.style.removeProperty('-webkit-text-stroke');
      node.style.webkitTextStrokeWidth='0px';node.style.webkitTextStrokeColor='transparent';
      node.style.paintOrder='normal';
      node.dataset.sourceTextOutline='false';node.dataset.sourceStrokeColor='none';node.dataset.sourceAppliedStrokeRGB='';
      if(inpaintingEnabled)typographyByID.get(String(item.id))?.restoreReadableInk();
      if(inpaintingEnabled&&restoredSourcePanels.has(item)&&node.dataset.sourcePanelTextFit==='inside'){
        node.dataset.sourceBackgroundColor='inpainted';
        node.dataset.sourceAppliedBackgroundRGB='';
        continue;
      }
      node.dataset.inpaintingFallback=inpaintingEnabled
        ? (restoredPanelGeometry.has(item)?'readability':'mask-or-surface') : 'disabled';
      const range=document.createRange();range.selectNodeContents(node);
      let r=range.getBoundingClientRect();
      if(r.width<=0||r.height<=0)continue;
      const background=palette.background;
      // Typography changes transparent glyphs only. Keep the prior caption
      // footprint and padding so smaller type cannot uncover source remnants.
      const priorInk=typographyInkFrames.get(item);
      if(priorInk)node.dataset.typographyInkFrame=JSON.stringify(priorInk);
      const pad=Math.max(priorInk?.pad||0,Math.max(3,Math.min(6,parseFloat(node.style.fontSize)*.3)));
      const frame=cleanupImageGeometry?.frame||item.sourceFrame;
      let l=Math.min(r.left,priorInk?.left??r.left)-pad,t=Math.min(r.top,priorInk?.top??r.top)-pad;
      let rr=Math.max(r.right,priorInk?.right??r.right)+pad,bb=Math.max(r.bottom,priorInk?.bottom??r.bottom)+pad;
      // When no owned mask could erase the original, the plate must contain
      // both languages' footprints. A tiny label on a long source column leaves
      // competing source text above and below the translation.
      // Retain this temporary union through source anchoring. Its empty
      // corners are trimmed after positioning and erasure certification.
      if(frame&&!restoredSourcePanels.has(item)){
        const bounds=[item.sourceBounds,...(item.auxiliaryInkRects||[])];
        for(const b of bounds){
          if(!Array.isArray(b)||b.length!==4||!b.every(Number.isFinite))continue;
          if(item.balancedColumn&&!restoredPanelGeometry.has(item)&&b[3]*frame[3]>r.height*1.5&&b[2]*frame[2]<r.width*.75){
            // Keep source erasure separate from the translated ink. A union
            // rectangle fills unused corners and needlessly covers artwork.
            const erasurePad=pad;
            const left=Math.max(frame[0],frame[0]+b[0]*frame[2]-erasurePad);
            const top=Math.max(frame[1],frame[1]+b[1]*frame[3]-erasurePad);
            const right=Math.min(frame[0]+frame[2],frame[0]+(b[0]+b[2])*frame[2]+erasurePad);
            const bottom=Math.min(frame[1]+frame[3],frame[1]+(b[1]+b[3])*frame[3]+erasurePad);
            const erasure=document.createElement('div');
            erasure.setAttribute('data-aidoku-image-ocr-overlay','source-readability-panel');
            erasure.dataset.aidokuRegion=String(item.id);erasure.dataset.sourceErasure='true';
            Object.assign(erasure.style,{position:'absolute',zIndex:'1',pointerEvents:'none',
              left:`${left+scrollX}px`,top:`${top+scrollY}px`,
              width:`${Math.max(1,right-left)}px`,height:`${Math.max(1,bottom-top)}px`,
              backgroundColor:`rgb(${background.join(',')})`});
            root.appendChild(erasure);readabilityPanels++;
            continue;
          }
          l=Math.min(l,frame[0]+b[0]*frame[2]-pad);t=Math.min(t,frame[1]+b[1]*frame[3]-pad);
          rr=Math.max(rr,frame[0]+(b[0]+b[2])*frame[2]+pad);bb=Math.max(bb,frame[1]+(b[1]+b[3])*frame[3]+pad);
        }
      }
      const left=Math.max(frame?.[0]??0,l),top=Math.max(frame?.[1]??0,t);
      const right=Math.min(frame?frame[0]+frame[2]:rr,rr),bottom=Math.min(frame?frame[1]+frame[3]:bb,bb);
      const panel=document.createElement('div');
      panel.setAttribute('data-aidoku-image-ocr-overlay','source-readability-panel');panel.dataset.aidokuRegion=String(item.id);
      Object.assign(panel.style,{position:'absolute',zIndex:'1',pointerEvents:'none',
        left:`${left+scrollX}px`,top:`${top+scrollY}px`,width:`${Math.max(1,right-left)}px`,height:`${Math.max(1,bottom-top)}px`,
        backgroundColor:`rgb(${background.join(',')})`,borderRadius:'3px'});
      root.appendChild(panel);readabilityPanels++;
      node.dataset.sourceBackgroundColor='readability-panel';node.dataset.sourceAppliedBackgroundRGB=background.join(',');
      // The panel above is final: only transparent text layout may change now.
      captionTextReflows.get(item)?.({left,top,right,bottom},pad);
    }
    measurementHost.remove();
    // The normal Korean reflow has now committed. Fit smaller type only after
    // that decision, preserving every accepted line break and source-erasure
    // footprint. A plate disappears only over an already verified restoration.
    if(artworkFirst){
      mount.appendChild(measurementHost);
      try {for(const entry of typographyEntries)entry.protectArtwork();}
      finally {measurementHost.remove();cleanupCanvas.width=0;cleanupCanvas.height=0;}
    }
    // Cluster only the final observed display inks. Panel restoration and
    // readability palettes above must finish before applying a shared swatch.
    if (appearance?.preserveSourceTextColor && items.length<=256) {
      const nodes=new Map(Array.from(root.querySelectorAll('[data-aidoku-image-ocr-overlay="item"]'))
        .map(n=>[n.dataset.aidokuRegion,n]));
      const entries=items.filter(item=>item.sourceColorEligible&&item.sourceTextOnly===false).flatMap(item=>{
        const node=nodes.get(String(item.id)),sample=cachedSourceSample(item);
        if(!node||node.dataset.sourceTextColor!=='preserved')return [];
        const confidence=Math.max(sample?.confidence?.foreground||0,sample?.confidence?.stroke||0,
          sample?.lettering?.confidence||0,sample?.displayEvidence?.confidence||0);
        const rgb=node.dataset.sourceAppliedTextRGB.split(',').map(Number);
        const background=aidokuCaptionPalette(sample,rgb,true).background;
        return [{id:item.id,node,rgb,confidence,background}];
      });
      let clustered=0;
      for(const group of aidokuInkClusters(entries))for(const entry of group.members){
        const original=aidokuSourceColorContrast(entry.rgb,true,1,entry.background);
        const candidate=aidokuSourceColorContrast(group.rgb,true,1,entry.background);
        if(candidate+.05<Math.min(4.5,original))continue;
        if(entry.node.dataset.sourceBackgroundColor==='inpainted'&&entry.node.dataset.sourcePanelSurfaceLuminance){
          const range=JSON.parse(entry.node.dataset.sourcePanelSurfaceLuminance);
          if(aidokuLuminanceContrast(aidokuSourceColorLuminance(group.rgb),...range)<4.5)continue;
        }
        entry.node.style.color=`rgb(${group.rgb.join(',')})`;
        entry.node.dataset.sourceAppliedTextRGB=group.rgb.join(',');
        entry.node.dataset.inkCluster=group.rgb.join(',');
        if(group.rgb.some((v,i)=>v!==entry.rgb[i]))entry.node.dataset.sourceTextColorAdjusted='true';
        clustered++;
      }
      root.dataset.clusteredInks=String(clustered);
    }
    // Compare final visible lettering with its source, not with the already
    // displaced planner card. Frozen plates keep erasure and artwork coverage
    // invariant; approved column groups and restored/translucent surfaces stay put.
    if (opacity === 1 && items.length <= 256) {
      const nodes=new Map(Array.from(root.querySelectorAll('[data-aidoku-image-ocr-overlay="item"]'))
        .map(n=>[n.dataset.aidokuRegion,n]));
      const plates=new Map(Array.from(root.querySelectorAll('[data-aidoku-image-ocr-overlay="source-readability-panel"]'))
        .filter(n=>n.dataset.sourceErasure!=='true').map(n=>[n.dataset.aidokuRegion,n]));
      const rect=r=>[r.left,r.top,r.width,r.height];
      const panelLayers=Array.from(root.querySelectorAll('[data-aidoku-image-ocr-overlay="source-readability-panel"]'))
        .map(node=>({node,rect:rect(node.getBoundingClientRect()),color:node.style.backgroundColor}));
      const keepsContrast=(ink,owner,node)=>{
        const foreground=node.dataset.sourceAppliedTextRGB?.split(',').map(Number);
        if(!foreground||foreground.length!==3||!foreground.every(Number.isFinite))return false;
        return aidokuTextBackingKeepsContrast(ink,owner,panelLayers,color=>{
          const background=color.match(/[0-9.]+/g)?.map(Number);
          return background?.length===3?aidokuSourceColorContrast(foreground,true,1,background):NaN;
        });
      };
      const inks=new Map(Array.from(nodes,([id,n])=>{
        const range=document.createRange();range.selectNodeContents(n);return [id,rect(range.getBoundingClientRect())];
      }));
      const sources=new Map(items.flatMap(item=>{
        const b=item.sourceBounds,f=cleanupImageGeometry?.frame||item.sourceFrame;
        return Array.isArray(b)&&Array.isArray(f)&&b.length===4&&f.length===4&&
          b.every(Number.isFinite)&&f.every(Number.isFinite)&&b[2]>0&&b[3]>0&&f[2]>0&&f[3]>0
          ? [[String(item.id),[f[0]+b[0]*f[2],f[1]+b[1]*f[3],b[2]*f[2],b[3]*f[3]]]] : [];
      }));
      for(const item of items){
        if(!item.sourceColorEligible||item.sourceTextOnly!==false||item.balancedColumn||item.vertical||item.rotation)continue;
        const id=String(item.id),node=nodes.get(id),panel=plates.get(id),ink=inks.get(id),source=sources.get(id);
        if(!node||!panel||!source||node.style.backgroundColor!=='transparent')continue;
        const obstacles=[...Array.from(inks,([other,r])=>[other,[r[0]-1,r[1]-1,r[2]+2,r[3]+2]]),...sources]
          .filter(([other,r])=>other!==id&&r[2]>0&&r[3]>0).map(([,r])=>r);
        const shift=aidokuSourceAnchorShift(ink,source,rect(panel.getBoundingClientRect()),obstacles);
        if(!shift)continue;
        const moved=[ink[0]+shift.dx,ink[1]+shift.dy,ink[2],ink[3]];
        const owner=panelLayers.findIndex(p=>p.node===panel);
        const neighbors=Array.from(inks).filter(([other,r])=>other!==id&&r[2]>0&&r[3]>0).map(([,r])=>r);
        if(!keepsContrast(ink,owner,node)||!keepsContrast(moved,owner,node))continue;
        if(aidokuNeedsTextBacking(moved,owner,panelLayers)&&
            !aidokuTextBackingRect(moved,panelLayers[owner].rect,neighbors))continue;
        node.dataset.sourceAnchorOriginalInk=JSON.stringify(ink);
        node.dataset.sourceAnchorShift=JSON.stringify([shift.dx,shift.dy]);
        node.style.left=`${parseFloat(node.style.left)+shift.dx}px`;
        node.style.top=`${parseFloat(node.style.top)+shift.dy}px`;
        const range=document.createRange();range.selectNodeContents(node);
        inks.set(id,rect(range.getBoundingClientRect()));
      }
      // All text remains above every background. Inside overlapping cards,
      // each caption's own color is painted last only underneath its lettering.
      // Clipping the existing panel preserves its outline, source erasure and
      // artwork coverage while avoiding cyclic whole-card stacking conflicts.
      for(const [id,panel] of plates){
        const node=nodes.get(id),ink=inks.get(id),owner=panelLayers.findIndex(p=>p.node===panel);
        if(!node||!aidokuNeedsTextBacking(ink,owner,panelLayers)||!keepsContrast(ink,owner,node))continue;
        const neighbors=Array.from(inks).filter(([other,r])=>other!==id&&r[2]>0&&r[3]>0).map(([,r])=>r);
        const frame=panelLayers[owner].rect,backing=aidokuTextBackingRect(ink,frame,neighbors);
        if(!backing)continue;
        const layer=panel.cloneNode(false);
        layer.setAttribute('data-aidoku-image-ocr-overlay','source-readability-backing');
        const [left,top,width,height]=backing;
        layer.style.clipPath=`inset(${(top-frame[1])/frame[3]*100}% ${(frame[0]+frame[2]-left-width)/frame[2]*100}% ${(frame[1]+frame[3]-top-height)/frame[3]*100}% ${(left-frame[0])/frame[2]*100}%)`;
        root.appendChild(layer);
        node.dataset.sourceTextBacking=JSON.stringify(backing);
        node.dataset.sourceTextBackingColor=panel.style.backgroundColor;
      }
    }
    // Final appearance only: anchoring, font cohorts and Korean wrapping are
    // already committed. Preserve background samples and correct unreadable ink
    // against the surfaces that are actually visible after clipping/stacking.
    if (opacity === 1 && items.length <= 256 && appearance?.preserveSourceBackgroundColor) {
      const nodes=new Map(Array.from(root.querySelectorAll('[data-aidoku-image-ocr-overlay="item"]'))
        .map(n=>[n.dataset.aidokuRegion,n]));
      const plates=new Map(Array.from(root.querySelectorAll('[data-aidoku-image-ocr-overlay="source-readability-panel"]'))
        .filter(n=>n.dataset.sourceErasure!=='true').map(n=>[n.dataset.aidokuRegion,n]));
      const rect=r=>[r.left,r.top,r.width,r.height];
      const inks=new Map(Array.from(nodes,([id,node])=>{
        const range=document.createRange();range.selectNodeContents(node);return [id,rect(range.getBoundingClientRect())];
      }));
      const certifiedErasure=new Set();
      if (true /* separate-erasure-backing */) {
        let certificationBudget=524288;
        // Certify each card's own footprint. Neighbor erasure requirements
        // below remain intact, including areas outside this card's crop.
        for(const item of items){
          const c=restoredPanelGeometry.get(item),id=String(item.id),node=nodes.get(id),panel=plates.get(id);
          if(!c?.erasureComplete||!node||!panel||item.balancedColumn||item.rotation||
              item.sourceTextOnly!==false||c.w*c.h>certificationBudget)continue;
          // Body-mask completion cannot certify a wider former card: missed
          // ruby and punctuation may sit outside the OCR body. Keep the full
          // observed-margin certification before shrinking that footprint.
          const f=cleanupImageGeometry?.frame||item.sourceFrame;
          if(!Array.isArray(f)||f.length!==4||!f.every(Number.isFinite))continue;
          const pad=Math.max(typographyInkFrames.get(item)?.pad||0,Math.max(3,Math.min(6,parseFloat(node.style.fontSize)*.3)));
          const cross=Math.max(pad,Math.min(16,Number.isFinite(item.sourceFontSize)?item.sourceFontSize:pad));
          const px=item.sourceVertical?cross:pad,py=item.sourceVertical?pad:cross;
          const old=rect(panel.getBoundingClientRect());
          const bounds=[item.sourceBounds,...(item.auxiliaryInkRects||[])];
          if(!bounds.every(b=>Array.isArray(b)&&b.length===4&&b.every(Number.isFinite)&&b[2]>0&&b[3]>0))continue;
          const coverage=bounds.map(b=>{
            const l=Math.max(old[0],f[0]+b[0]*f[2]-px),t=Math.max(old[1],f[1]+b[1]*f[3]-py);
            const r=Math.min(old[0]+old[2],f[0]+(b[0]+b[2])*f[2]+px),bottom=Math.min(old[1]+old[3],f[1]+(b[1]+b[3])*f[3]+py);
            return [l,t,r-l,bottom-t];
          }).filter(r=>r[2]>0&&r[3]>0);
          const regions=coverage.map(r=>[((r[0]-c.frame[0])*c.iw/c.frame[2]-c.x)*c.sx,
            ((r[1]-c.frame[1])*c.ih/c.frame[3]-c.y)*c.sy,r[2]*c.iw/c.frame[2]*c.sx,r[3]*c.ih/c.frame[3]*c.sy]);
          const core=bounds.map(b=>[(b[0]*c.iw-c.x)*c.sx,(b[1]*c.ih-c.y)*c.sy,b[2]*c.iw*c.sx,b[3]*c.ih*c.sy]);
          certificationBudget-=c.w*c.h;
          const glyph=Math.max(4,(Number(item.sourceFontSize)||parseFloat(node.style.fontSize))*c.iw/c.frame[2]*c.sx);
          // A multi-column vertical OCR box can omit a partly occluded first
          // column attached to the artwork on its right. Repeated protruding
          // strokes veto release, while smooth balloon contours still allow
          // smaller lettering and removal of the old oversized panel.
          if(item.sourceVertical&&!item.sourceSingleColumn&&
              aidokuHasAttachedLeadingInk(c.safe,c.w,c.h,core,glyph))continue;
          // A proven body can sit next to large connected artwork outside
          // the source crop. It need not keep a blank card over that artwork,
          // but small surviving ruby/punctuation still veto release.
          const ownedBodyClear=c.sourceErasureVerified&&
            !aidokuHasResidualLettering(c.safe,c.w,c.h,core,glyph);
          if(!ownedBodyClear&&!aidokuRestoredErasureCovers(c.safe,c.w,c.h,regions,glyph,core))continue;
          certifiedErasure.add(item);
          node.dataset.sourceErasureRestored='true';
          node.dataset.sourceErasureReleased=JSON.stringify(coverage);
          node.dataset.sourceErasureCrop=JSON.stringify([c.frame[0]+c.x/c.iw*c.frame[2],c.frame[1]+c.y/c.ih*c.frame[3],
            c.w/c.sx/c.iw*c.frame[2],c.h/c.sy/c.ih*c.frame[3]]);
        }
      }
      if(certifiedErasure.size){
        mount.appendChild(measurementHost);
        try {for(const entry of typographyEntries){
          const item=items.find(item=>item.id===entry.id),id=String(entry.id);
          if(!certifiedErasure.has(item)||!entry.fitBalloon())continue;
          plates.delete(id);
          const range=document.createRange();range.selectNodeContents(nodes.get(id));
          inks.set(id,rect(range.getBoundingClientRect()));
        }} finally {measurementHost.remove();}
      }
      for(const item of items){
        const id=String(item.id),node=nodes.get(id),panel=plates.get(id),ink=inks.get(id);
        if(!node||!panel||item.balancedColumn||item.sourceTextOnly!==false)continue;
        const frame=cleanupImageGeometry?.frame||item.sourceFrame;
        if(!Array.isArray(frame)||frame.length!==4||!frame.every(Number.isFinite))continue;
        const pad=Math.max(typographyInkFrames.get(item)?.pad||0,Math.max(3,Math.min(6,parseFloat(node.style.fontSize)*.3)));
        // OCR rectangles can omit the slanted edge of an effect or a small
        // companion glyph. Preserve one source-glyph width across the writing
        // direction, even when reconstruction could not certify a clean mask.
        const fringe=Math.max(0,Math.min(16,Number.isFinite(item.sourceFontSize)?item.sourceFontSize:pad)-pad);
        const required=restoredSourcePanels.has(item)||certifiedErasure.has(item)?[]:[item.sourceBounds,...(item.auxiliaryInkRects||[])]
          .map(b=>Array.isArray(b)&&b.length===4?
            [frame[0]+b[0]*frame[2]-(item.sourceVertical?fringe:0),frame[1]+b[1]*frame[3]-(item.sourceVertical?0:fringe),
              b[2]*frame[2]+(item.sourceVertical?fringe*2:0),b[3]*frame[3]+(item.sourceVertical?0:fringe*2)]:null);
        const old=rect(panel.getBoundingClientRect());
        const neighbors=Array.from(inks).filter(([other,r])=>other!==id&&r[2]>0&&r[3]>0).map(([,r])=>r);
        // A card may also have been erasing part of a neighboring source. Keep
        // that contribution, including its source-size fringe, when trimming.
        const otherErasure=items.filter(other=>other!==item&&!restoredSourcePanels.has(other)).flatMap(other=>{
          const f=cleanupImageGeometry?.frame||other.sourceFrame;
          if(!Array.isArray(f)||f.length!==4||!f.every(Number.isFinite))return [];
          const cross=Math.max(3,Math.min(16,Number.isFinite(other.sourceFontSize)?other.sourceFontSize:3));
          const px=other.sourceVertical?cross:3,py=other.sourceVertical?3:cross;
          return [other.sourceBounds,...(other.auxiliaryInkRects||[])].filter(b=>Array.isArray(b)&&b.length===4&&b.every(Number.isFinite))
            .map(b=>[f[0]+b[0]*f[2]-px,f[1]+b[1]*f[3]-py,b[2]*f[2]+px*2,b[3]*f[3]+py*2])
            .filter(r=>r[0]<old[0]+old[2]&&r[0]+r[2]>old[0]&&r[1]<old[1]+old[3]&&r[1]+r[3]>old[1]);
        });
        neighbors.push(...otherErasure);
        const compact=aidokuCompactPanel(old,ink,required,neighbors,pad);
        if(!compact)continue;
        if(compact.coverage.length===1&&compact.coverage[0].every((v,i)=>Math.abs(v-old[i])<.01))continue;
        const [left,top,width,height]=compact.frame;
        Object.assign(panel.style,{left:`${left+scrollX}px`,top:`${top+scrollY}px`,width:`${width}px`,height:`${height}px`});
        // Nonzero winding fills the union, leaving unused connecting corners
        // clear while preserving every original source/ruby erasure footprint.
        panel.style.clipPath=`path('${compact.coverage.map(r=>
          `M ${r[0]-left} ${r[1]-top} h ${r[2]} v ${r[3]} h ${-r[2]} Z`).join(' ')}')`;
        panel.dataset.panelCoverage=JSON.stringify(compact.coverage);
        node.dataset.sourcePanelOriginalFrame=JSON.stringify(old);
        node.dataset.sourcePanelCoverage=JSON.stringify(compact.coverage);
        node.dataset.sourcePanelRequiredErasure=JSON.stringify(required);
        node.dataset.sourcePanelNeighborErasure=JSON.stringify(otherErasure);
      }
      const layers=Array.from(root.querySelectorAll('[data-aidoku-image-ocr-overlay="source-readability-panel"], [data-aidoku-image-ocr-overlay="source-readability-backing"]'))
        .map(panel=>({color:panel.style.backgroundColor.match(/[0-9.]+/g)?.map(Number),coverage:
          panel.dataset.panelCoverage?JSON.parse(panel.dataset.panelCoverage):
          panel.dataset.aidokuImageOcrOverlay==='source-readability-backing'?
            [JSON.parse(nodes.get(panel.dataset.aidokuRegion).dataset.sourceTextBacking)]:[rect(panel.getBoundingClientRect())]}));
      for(const item of items){
        const id=String(item.id),node=nodes.get(id),ink=inks.get(id),panel=plates.get(id);
        // Restored pixels already passed their spatial contrast check. A
        // sampled flat palette must not override that stronger evidence.
        if(!node||!panel||!item.sourceColorEligible||item.sourceTextOnly!==false||ink[2]<=0||ink[3]<=0)continue;
        const foreground=node.dataset.sourceAppliedTextRGB?.split(',').map(Number);
        if(foreground?.length!==3||!foreground.every(Number.isFinite))continue;
        const background=aidokuCaptionPalette(cachedSourceSample(item),foreground,true).background;
        let surfaces=aidokuVisiblePanelColors(ink,layers,background);
        const contrast=rgb=>Math.min(...surfaces.map(bg=>aidokuSourceColorContrast(rgb,true,1,bg)));
        const before=contrast(foreground);
        if(before>=4.5)continue;
        // Restore the existing owner's color only under its text when several
        // surfaces cannot provide a consistent backing. Neighbor glyphs veto it.
        if(panel&&surfaces.some(bg=>bg.join(',')!==background.join(','))){
          const neighbors=Array.from(inks).filter(([other,r])=>other!==id&&r[2]>0&&r[3]>0).map(([,r])=>r);
          const frame=rect(panel.getBoundingClientRect()),backing=aidokuTextBackingRect(ink,frame,neighbors);
          if(backing){
            const layer=panel.cloneNode(false),[left,top,width,height]=backing;
            layer.setAttribute('data-aidoku-image-ocr-overlay','source-readability-backing');
            layer.removeAttribute('data-panel-coverage');
            layer.style.clipPath=`inset(${(top-frame[1])/frame[3]*100}% ${(frame[0]+frame[2]-left-width)/frame[2]*100}% ${(frame[1]+frame[3]-top-height)/frame[3]*100}% ${(left-frame[0])/frame[2]*100}%)`;
            root.appendChild(layer);layers.push({color:background,coverage:[backing]});
            node.dataset.sourceTextBacking=JSON.stringify(backing);
            node.dataset.sourceTextBackingColor=panel.style.backgroundColor;
            surfaces=[background];
          }
        }
        const adjusted=aidokuAdjustInkForContrast(foreground,contrast);
        if(contrast(adjusted)<contrast(foreground))continue;
        node.style.color=`rgb(${adjusted.join(',')})`;
        node.dataset.sourceAppliedTextRGB=adjusted.join(',');
        node.dataset.sourceTextColorAdjusted='true';
        node.dataset.sourceContrastOriginalInk=foreground.join(',');
        node.dataset.sourceContrastSurfaces=JSON.stringify(surfaces);
        node.dataset.sourceContrastBefore=String(before);
        node.dataset.sourceContrastAfter=String(contrast(adjusted));
      }
    }
    root.dataset.readabilityPanels=String(readabilityPanels);
    return {
      status: 'committed', revision: String(revision),
      itemCount: renderedItemCount
    };
    """
}

struct BrowserOverlayItem: Equatable, Sendable {
    /// Stable identity assigned by the temporal OCR tracker. Rendering must
    /// preserve this identity instead of treating every OCR/translation
    /// publication as a brand-new card.
    let stableRegionID: UInt64?
    let rect: CGRect
    let sourcePolygon: [CGPoint]
    let auxiliaryInkRects: [CGRect]
    let auxiliaryInkPolygons: [[CGPoint]]
    let sourceText: String
    let translatedText: String?
    let confidence: Double
    let sourceOrientation: BrowserOCRSourceOrientation
    let sourceSingleVerticalColumn: Bool?
    let translationReuseIdentity: NativeTranslationReuseIdentity?

    init(
        stableRegionID: UInt64? = nil,
        rect: CGRect,
        sourceText: String,
        translatedText: String?,
        confidence: Double,
        sourceOrientation: BrowserOCRSourceOrientation = .unknown,
        sourceSingleVerticalColumn: Bool? = nil,
        translationReuseIdentity: NativeTranslationReuseIdentity? = nil,
        sourcePolygon: [CGPoint] = [],
        auxiliaryInkRects: [CGRect] = [],
        auxiliaryInkPolygons: [[CGPoint]] = []
    ) {
        self.stableRegionID = stableRegionID
        self.rect = rect
        self.sourcePolygon = sourcePolygon
        self.auxiliaryInkRects = auxiliaryInkRects
        self.auxiliaryInkPolygons = auxiliaryInkPolygons
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.confidence = confidence
        self.sourceOrientation = sourceOrientation
        self.sourceSingleVerticalColumn = sourceSingleVerticalColumn
        self.translationReuseIdentity = translationReuseIdentity
    }
}

/// Stable layout order is separate from the language-aware translation order.
/// An approximate comparator can form cycles (A~B, B~C, A<C); anchor rows
/// before sorting their members so publication order cannot jitter placement.
struct BrowserOverlayItemOrdering {
    static func ordered(_ items: [BrowserOverlayItem]) -> [BrowserOverlayItem] {
        var counts: [UInt64: Int] = [:]
        for item in items { if let id = item.stableRegionID { counts[id, default: 0] += 1 } }
        let valid = items.filter { item in
            let r = item.rect
            return !r.isNull && !r.isEmpty &&
                [r.minX, r.minY, r.maxX, r.maxY].allSatisfy(\.isFinite) &&
                (item.stableRegionID.map { counts[$0] == 1 } ?? true)
        }
        func tie(_ a: BrowserOverlayItem, _ b: BrowserOverlayItem) -> Bool {
            if a.rect.width != b.rect.width { return a.rect.width < b.rect.width }
            if a.rect.height != b.rect.height { return a.rect.height < b.rect.height }
            if a.stableRegionID != b.stableRegionID { return (a.stableRegionID ?? .max) < (b.stableRegionID ?? .max) }
            if a.sourceText != b.sourceText { return a.sourceText < b.sourceText }
            return (a.translatedText ?? "") < (b.translatedText ?? "")
        }
        let byY = valid.sorted {
            if $0.rect.minY != $1.rect.minY { return $0.rect.minY < $1.rect.minY }
            if $0.rect.minX != $1.rect.minX { return $0.rect.minX < $1.rect.minX }
            return tie($0, $1)
        }
        var result: [BrowserOverlayItem] = []
        var start = 0
        while start < byY.count {
            var end = start + 1
            while end < byY.count && byY[end].rect.minY <= byY[start].rect.minY + 2 { end += 1 }
            result.append(contentsOf: byY[start..<end].sorted {
                if $0.rect.minX != $1.rect.minX { return $0.rect.minX < $1.rect.minX }
                if $0.rect.minY != $1.rect.minY { return $0.rect.minY < $1.rect.minY }
                return tie($0, $1)
            })
            start = end
        }
        // Different tracker IDs may still describe the exact same painted
        // source. Collapse only exact geometry/text/orientation duplicates;
        // repeated dialogue elsewhere and competing translations remain distinct.
        struct PaintIdentity: Hashable {
            let x: CGFloat; let y: CGFloat; let width: CGFloat; let height: CGFloat
            let source: String; let translation: String?; let orientation: String
            let singleColumn: Bool?
        }
        var seen = Set<PaintIdentity>()
        return result.filter { item in
            seen.insert(PaintIdentity(x: item.rect.minX, y: item.rect.minY,
                width: item.rect.width, height: item.rect.height,
                source: item.sourceText, translation: item.translatedText,
                orientation: item.sourceOrientation.rawValue,
                singleColumn: item.sourceSingleVerticalColumn)).inserted
        }
    }
}

struct BrowserOverlayVisibility {
    static func visibleItems(
        _ items: [BrowserOverlayItem]
    ) -> [BrowserOverlayItem] {
        return items.compactMap { item in
            let sourceIsEmpty = item.sourceText.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
            let translationIsEmpty = item.translatedText?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty ?? true
            guard !sourceIsEmpty || !translationIsEmpty else { return nil }
            let visibleItem: BrowserOverlayItem
            if translationIsEmpty, item.translatedText != nil {
                // Treat a blank provider response as untranslated so it can
                // never create an empty replacement surface.
                visibleItem = BrowserOverlayItem(
                    stableRegionID: item.stableRegionID,
                    rect: item.rect,
                    sourceText: item.sourceText,
                    translatedText: nil,
                    confidence: item.confidence,
                    sourceOrientation: item.sourceOrientation,
                    sourceSingleVerticalColumn:
                        item.sourceSingleVerticalColumn,
                    translationReuseIdentity: item.translationReuseIdentity,
                    sourcePolygon: item.sourcePolygon, auxiliaryInkRects: item.auxiliaryInkRects, auxiliaryInkPolygons: item.auxiliaryInkPolygons
                )
            } else {
                visibleItem = item
            }
            return visibleItem
        }
    }
}

/// Matches the established image-overlay display boundary: line grouping is
/// owned by OCR, and presentation removes only an exact repeated string in the
/// same region.
struct BrowserImageSourceOverlayConsolidator {
    static func consolidate(
        _ input: [BrowserOverlayItem]
    ) -> [BrowserOverlayItem] {
        // Preserve the c1b89c7 display-boundary contract: OCR owns text-line
        // grouping, while the presentation boundary removes only an exact
        // repeated string occupying the same region. Geometry-only joining
        // changes the recognized sentence and made upgraded capture output
        // differ from the established renderer result.
        var unique: [BrowserOverlayItem] = []
        for item in input.sorted(by: readingOrder) {
            let normalized = normalizedText(item.sourceText)
            let duplicate = unique.contains { existing in
                normalizedText(existing.sourceText) == normalized &&
                    overlapRatio(existing.rect, item.rect) >= 0.70
            }
            if !duplicate { unique.append(item) }
        }
        return unique
    }

    private static func normalizedText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func overlapRatio(_ left: CGRect, _ right: CGRect) -> CGFloat {
        let intersection = left.intersection(right)
        guard !intersection.isNull else { return 0 }
        let smallerArea = min(
            left.width * left.height,
            right.width * right.height
        )
        guard smallerArea > 0 else { return 0 }
        return intersection.width * intersection.height / smallerArea
    }

    private static func readingOrder(
        _ left: BrowserOverlayItem,
        _ right: BrowserOverlayItem
    ) -> Bool {
        if abs(left.rect.minY - right.rect.minY) > 2 {
            return left.rect.minY < right.rect.minY
        }
        return left.rect.minX < right.rect.minX
    }
}

struct BrowserSidePanelHistoryEntry: Equatable {
    let id: String
    let item: BrowserOverlayItem
}

struct BrowserOverlayLayoutCacheStatistics: Equatable {
    let hits: Int
    let misses: Int
}

struct BrowserOverlayRenderStatistics: Equatable {
    let semanticNoOp: Bool
    let usedFullLayoutFallback: Bool
    let cardUpdates: Int
    let cardFrameChanges: Int
    let intrinsicLayoutHits: Int
    let intrinsicLayoutMisses: Int
    let textMeasurementHits: Int
    let textMeasurementMisses: Int

    static let empty = Self(
        semanticNoOp: false,
        usedFullLayoutFallback: false,
        cardUpdates: 0,
        cardFrameChanges: 0,
        intrinsicLayoutHits: 0,
        intrinsicLayoutMisses: 0,
        textMeasurementHits: 0,
        textMeasurementMisses: 0
    )
}

struct BrowserOverlayTextMeasurementCacheStatistics: Equatable {
    let hits: Int
    let misses: Int
}

/// Bounded, view-owned memoization for the Core Text work shared by the
/// planner and the painted label. Exact CGFloat keys keep cached measurements
/// semantically identical to uncached UIKit measurements.
final class BrowserOverlayTextMeasurementCache {
    private struct SizeKey: Hashable {
        let variant: BrowserOverlayDisplayVariant
        let width: CGFloat
        let fontSize: CGFloat
    }

    private struct UnbrokenWidthKey: Hashable {
        let variant: BrowserOverlayDisplayVariant
        let fontSize: CGFloat
    }

    private struct MeasurementStringKey: Hashable {
        let variant: BrowserOverlayDisplayVariant
        let fontSize: CGFloat
        let primaryBreakMode: Int
        let secondaryBreakMode: Int
    }

    private let reusesMeasurementStrings: Bool
    private var measurementStrings: [MeasurementStringKey: NSAttributedString] = [:]
    private(set) var measurementStringHits = 0

    init(reusesMeasurementStrings: Bool = true) {
        self.reusesMeasurementStrings = reusesMeasurementStrings
    }

    // Width affects measurement attributes only through the wrapping mode.
    // Reuse immutable attributes across widths without reusing measured bounds.
    func measurementString(for variant: BrowserOverlayDisplayVariant, width: CGFloat,
                           fontSize: CGFloat, calculate: () -> NSAttributedString) -> NSAttributedString {
        guard reusesMeasurementStrings else { return calculate() }
        let secondaryMode: Int
        if case .originalAndTranslation = variant.content {
            secondaryMode = variant.lineBreakMode(availableWidth: width, fontSize: max(7, fontSize * 0.64),
                                                  measurementCache: self).rawValue
        } else {
            secondaryMode = -1
        }
        let key = MeasurementStringKey(variant: variant, fontSize: fontSize,
            primaryBreakMode: variant.lineBreakMode(availableWidth: width, fontSize: fontSize,
                                                   measurementCache: self).rawValue,
            secondaryBreakMode: secondaryMode)
        if let cached = measurementStrings[key] {
            measurementStringHits += 1
            return cached
        }
        let value = NSAttributedString(attributedString: calculate())
        if measurementStrings.count >= 256 { measurementStrings.removeAll(keepingCapacity: true) }
        measurementStrings[key] = value
        return value
    }

    private static let maximumEntryCount = 2_048
    private var sizes: [SizeKey: CGSize] = [:]
    private var unbrokenWidths: [UnbrokenWidthKey: CGFloat] = [:]
    private(set) var passHits = 0
    private(set) var passMisses = 0

    var passStatistics: BrowserOverlayTextMeasurementCacheStatistics {
        BrowserOverlayTextMeasurementCacheStatistics(
            hits: passHits,
            misses: passMisses
        )
    }

    func beginPass() {
        passHits = 0
        passMisses = 0
    }

    func measuredSize(
        for variant: BrowserOverlayDisplayVariant,
        width: CGFloat,
        fontSize: CGFloat,
        calculate: () -> CGSize
    ) -> CGSize {
        let key = SizeKey(
            variant: variant,
            width: width,
            fontSize: fontSize
        )
        if let cached = sizes[key] {
            passHits += 1
            return cached
        }
        let measured = calculate()
        makeRoomIfNeeded()
        sizes[key] = measured
        passMisses += 1
        return measured
    }

    func minimumUnbrokenWidth(
        for variant: BrowserOverlayDisplayVariant,
        fontSize: CGFloat,
        calculate: () -> CGFloat
    ) -> CGFloat {
        let key = UnbrokenWidthKey(
            variant: variant,
            fontSize: fontSize
        )
        if let cached = unbrokenWidths[key] {
            passHits += 1
            return cached
        }
        let measured = calculate()
        makeRoomIfNeeded()
        unbrokenWidths[key] = measured
        passMisses += 1
        return measured
    }

    func removeAll() {
        sizes.removeAll(keepingCapacity: true)
        unbrokenWidths.removeAll(keepingCapacity: true)
        measurementStrings.removeAll(keepingCapacity: true)
        measurementStringHits = 0
        beginPass()
    }

    private func makeRoomIfNeeded() {
        guard sizes.count + unbrokenWidths.count >=
                Self.maximumEntryCount
        else {
            return
        }
        // Measurements are cheap to rebuild compared with carrying an
        // unbounded session history containing translated text.
        sizes.removeAll(keepingCapacity: true)
        unbrokenWidths.removeAll(keepingCapacity: true)
    }
}

struct BrowserOverlayPositionedCollisionDependency: Equatable {
    let key: String
    let rect: CGRect
}

struct BrowserOverlayPositionedLayoutCacheInput: Equatable {
    let source: CGRect
    let intrinsicLayout: BrowserOverlayCardLayout
    let viewport: CGSize
    let occupiedDependencies: [BrowserOverlayPositionedCollisionDependency]
    let reservedSources: [CGRect]
}

struct BrowserOverlayPositionedLayoutCache {
    private struct Record {
        let input: BrowserOverlayPositionedLayoutCacheInput
        let layout: BrowserOverlayCardLayout
    }

    private var records: [String: Record] = [:]
    private(set) var passHits = 0
    private(set) var passMisses = 0

    mutating func beginPass() {
        passHits = 0
        passMisses = 0
    }

    mutating func layout(
        for key: String,
        input: BrowserOverlayPositionedLayoutCacheInput,
        invalidated: Bool,
        calculate: () -> BrowserOverlayCardLayout
    ) -> BrowserOverlayCardLayout {
        if !invalidated,
           let record = records[key],
           record.input == input
        {
            passHits += 1
            return record.layout
        }
        let layout = calculate()
        records[key] = Record(input: input, layout: layout)
        passMisses += 1
        return layout
    }

    mutating func finishPass(retaining keys: Set<String>) {
        records = records.filter { keys.contains($0.key) }
    }

    mutating func removeAll() {
        records.removeAll(keepingCapacity: true)
        beginPass()
    }
}

struct BrowserOverlayPositionedIntrinsicLayoutCacheInput: Equatable {
    let source: CGRect
    let displayedVariant: BrowserOverlayDisplayVariant
    let settings: IPhoneOverlaySettings
    let viewport: CGSize
    let sourceVertical: Bool
    let singleVerticalColumn: Bool
}

struct BrowserOverlayPositionedIntrinsicLayoutCache {
    private struct Record {
        let input: BrowserOverlayPositionedIntrinsicLayoutCacheInput
        let layout: BrowserOverlayCardLayout
    }

    private var records: [String: Record] = [:]
    private(set) var passHits = 0
    private(set) var passMisses = 0

    mutating func beginPass() {
        passHits = 0
        passMisses = 0
    }

    mutating func layout(
        for key: String,
        input: BrowserOverlayPositionedIntrinsicLayoutCacheInput,
        invalidated: Bool,
        calculate: () -> BrowserOverlayCardLayout
    ) -> BrowserOverlayCardLayout {
        if !invalidated,
           let record = records[key],
           record.input == input
        {
            passHits += 1
            return record.layout
        }
        let layout = calculate()
        records[key] = Record(input: input, layout: layout)
        passMisses += 1
        return layout
    }

    mutating func finishPass(retaining keys: Set<String>) {
        records = records.filter { keys.contains($0.key) }
    }

    mutating func removeAll() {
        records.removeAll(keepingCapacity: true)
        beginPass()
    }
}

enum BrowserOCRInvalidationScope: Equatable {
    case display
    case session

    var clearsSidePanelSessionHistory: Bool {
        self == .session
    }
}

struct BrowserOverlayTextFlow {
    enum WrappingScript: String {
        case cjk
        case korean
        case rightToLeft
        case word
    }

    enum FontScript: String {
        case japanese
        case han
        case korean
        case rightToLeft
        case word
    }

    static func usesVerticalLayout(
        rect: CGRect,
        texts: [String]
    ) -> Bool {
        guard let source = texts.first else { return false }
        return usesVerticalSourceLayout(rect: rect, text: source)
    }

    static func usesVerticalSourceLayout(
        rect: CGRect,
        text: String,
        sourceOrientation: BrowserOCRSourceOrientation = .unknown
    ) -> Bool {
        switch sourceOrientation {
        case .vertical:
            return textPrefersVerticalWriting(text)
        case .horizontal:
            return false
        case .unknown:
            break
        }
        guard rect.width > 0, rect.height > 0 else { return false }
        var verticalCJKCount = 0
        var otherAlphabeticCount = 0
        var visibleCharacters = 0
        for scalar in text.unicodeScalars {
            guard scalar.properties.isAlphabetic ||
                    scalar.properties.numericType != nil
            else {
                continue
            }
            visibleCharacters += 1
            if isVerticalCJK(scalar.value) {
                verticalCJKCount += 1
            } else if scalar.properties.isAlphabetic {
                otherAlphabeticCount += 1
            }
        }
        guard visibleCharacters >= 2,
              Double(verticalCJKCount) / Double(visibleCharacters) >= 0.6
        else {
            return false
        }
        let aspectRatio = rect.height / rect.width
        let minimumAspectRatio = max(
            1.8,
            min(6, CGFloat(visibleCharacters) * 0.55)
        )
        let glyphHeightRatio =
            rect.height / CGFloat(visibleCharacters) / rect.width
        return aspectRatio >= minimumAspectRatio &&
            glyphHeightRatio >= 0.35 &&
            glyphHeightRatio <= 2.4 &&
            verticalCJKCount >= otherAlphabeticCount
    }

    static func translatedTextUsesVerticalLayout(
        sourceIsVertical: Bool,
        targetLanguage: String,
        text: String
    ) -> Bool {
        guard sourceIsVertical else { return false }
        let language = targetLanguage
            .lowercased()
            .split(separator: "-", maxSplits: 1)
            .first
            .map(String.init) ?? ""
        guard ["ja", "zh", "yue"].contains(language),
              !isRightToLeft(text)
        else {
            return false
        }
        return text.unicodeScalars.contains { isCJK($0.value) }
    }

    /// Source geometry describes how OCR read the original language; it must
    /// not force the translated language into the same writing direction.
    /// Korean and other horizontal target languages remain horizontal even
    /// when PP-OCR reports one explicit Japanese vertical column. Before a
    /// translation arrives, retaining the source direction avoids a visible
    /// source-card reflow.
    static func displayedTextUsesVerticalLayout(
        item: BrowserOverlayItem,
        sourceIsVertical: Bool,
        targetLanguage: String
    ) -> Bool {
        guard let translatedText = item.translatedText else {
            return sourceIsVertical
        }
        return translatedTextUsesVerticalLayout(
            sourceIsVertical: sourceIsVertical,
            targetLanguage: targetLanguage,
            text: translatedText
        )
    }

    static func isSingleLogicalLine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !text.contains(where: \.isNewline)
    }

    static func wrappingScript(for text: String) -> WrappingScript {
        if isRightToLeft(text) {
            return .rightToLeft
        }
        var verticalCJKCount = 0
        var hangulCount = 0
        var otherAlphabeticCount = 0
        for scalar in text.unicodeScalars {
            if isHangul(scalar.value) {
                hangulCount += 1
            } else if isVerticalCJK(scalar.value) {
                verticalCJKCount += 1
            } else if scalar.properties.isAlphabetic {
                otherAlphabeticCount += 1
            }
        }
        if hangulCount > 0,
           hangulCount >= verticalCJKCount,
           hangulCount >= otherAlphabeticCount
        {
            return .korean
        }
        if verticalCJKCount > 0,
           verticalCJKCount >= otherAlphabeticCount
        {
            return .cjk
        }
        return .word
    }

    static func fontScript(for text: String) -> FontScript {
        if text.unicodeScalars.contains(where: {
            switch $0.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF:
                return true
            default:
                return false
            }
        }) {
            return .japanese
        }
        switch wrappingScript(for: text) {
        case .cjk:
            return .han
        case .korean:
            return .korean
        case .rightToLeft:
            return .rightToLeft
        case .word:
            return .word
        }
    }

    static func isRightToLeft(_ text: String) -> Bool {
        var rightToLeftCount = 0
        var otherAlphabeticCount = 0
        for scalar in text.unicodeScalars {
            if isRightToLeft(scalar.value) {
                rightToLeftCount += 1
            } else if scalar.properties.isAlphabetic {
                otherAlphabeticCount += 1
            }
        }
        return rightToLeftCount > 0 &&
            rightToLeftCount >= otherAlphabeticCount
    }

    static func verticalized(_ text: String) -> String {
        // Match the desktop vertical planner: spaces and model-inserted line
        // separators are not glyph cells. Counting Korean word spaces as rows
        // made otherwise identical text fit at a visibly smaller point size.
        text.filter { !$0.isWhitespace && !$0.isNewline }
            .map(String.init)
            .joined(separator: "\n")
    }

    static func isCJKForLayout(_ value: UInt32) -> Bool {
        isCJK(value)
    }

    private static func isCJK(_ value: UInt32) -> Bool {
        switch value {
        case 0x1100...0x11FF,
             0x2E80...0x2FDF,
             0x3040...0x30FF,
             0x3130...0x318F,
             0x31F0...0x31FF,
             0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xAC00...0xD7AF,
             0xF900...0xFAFF,
             0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }

    private static func textPrefersVerticalWriting(_ text: String) -> Bool {
        var verticalCJKCount = 0
        var otherVisibleCount = 0
        for scalar in text.unicodeScalars {
            guard scalar.properties.isAlphabetic ||
                    scalar.properties.numericType != nil
            else {
                continue
            }
            if isVerticalCJK(scalar.value) {
                verticalCJKCount += 1
            } else {
                otherVisibleCount += 1
            }
        }
        let visibleCount = verticalCJKCount + otherVisibleCount
        return verticalCJKCount >= 2 &&
            verticalCJKCount >= otherVisibleCount &&
            Double(verticalCJKCount) / Double(max(1, visibleCount)) >= 0.6
    }

    private static func isHangul(_ value: UInt32) -> Bool {
        switch value {
        case 0x1100...0x11FF,
             0x3130...0x318F,
             0xAC00...0xD7AF:
            return true
        default:
            return false
        }
    }

    private static func isVerticalCJK(_ value: UInt32) -> Bool {
        switch value {
        case 0x2E80...0x2FDF,
             0x3040...0x30FF,
             0x31A0...0x31BF,
             0x31F0...0x31FF,
             0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xF900...0xFAFF,
             0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }

    private static func isRightToLeft(_ value: UInt32) -> Bool {
        switch value {
        case 0x0590...0x08FF,
             0xFB1D...0xFDFF,
             0xFE70...0xFEFF,
             0x1EE00...0x1EEFF:
            return true
        default:
            return false
        }
    }
}

/// In-memory-only history for one native-browser OCR session.
///
/// Stable segment IDs update their existing row so a translated result can
/// replace the source-only row from the same frame. Importantly, the whole
/// item is replaced: a new source-only item never inherits a translation just
/// because its text is unchanged.
struct BrowserSidePanelSessionHistory {
    static let defaultMaximumItems = 100

    let maximumItems: Int
    private(set) var entries: [BrowserSidePanelHistoryEntry] = []

    init(maximumItems: Int = Self.defaultMaximumItems) {
        self.maximumItems = max(0, maximumItems)
    }

    var items: [BrowserOverlayItem] {
        entries.map(\.item)
    }

    mutating func remember(
        _ newEntries: [BrowserSidePanelHistoryEntry]
    ) {
        guard maximumItems > 0 else {
            removeAll()
            return
        }
        for entry in newEntries {
            if let index = entries.firstIndex(where: {
                $0.id == entry.id
            }) {
                entries[index] = entry
            } else {
                entries.append(entry)
            }
        }
        if entries.count > maximumItems {
            entries.removeFirst(entries.count - maximumItems)
        }
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: true)
    }
}

@MainActor
final class BrowserOverlayView: UIView {
    private struct PositionedCardPresentationInput: Equatable {
        let sourceText: String
        let translatedText: String?
        let confidence: Double
        let content: BrowserOverlayCardContent
        let settings: IPhoneOverlaySettings
        let maximumFontSize: CGFloat
        let contentInsets: UIEdgeInsets
        let locale: IPhoneUILocale
    }

    private struct PositionedCardRecord {
        let card: OverlayCardView
        let item: BrowserOverlayItem
        let presentation: PositionedCardPresentationInput
    }

    private struct PositionedSegment {
        let key: String
        let item: BrowserOverlayItem
        let sourceRect: CGRect
        let sourceVertical: Bool
        let content: BrowserOverlayCardContent
    }

    private struct PositionedGeometrySignature: Equatable {
        let key: String
        let stableRegionID: UInt64
        let sourceRect: CGRect
        let sourceText: String
        let sourceOrientation: BrowserOCRSourceOrientation
        let sourceSingleVerticalColumn: Bool?
    }

    private struct PositionedLayoutContext: Equatable {
        let imageSize: CGSize
        let sourceRect: CGRect
        let settings: IPhoneOverlaySettings
        let targetLanguage: String
        let viewport: CGSize
        let locale: IPhoneUILocale
    }

    private struct PositionedRenderRequest: Equatable {
        let items: [BrowserOverlayItem]
        let context: PositionedLayoutContext
    }

    private let statusContainer = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    private let statusLabel = UILabel()
    private var statusAnnouncementState = BrowserStatusAnnouncementState()
    private let itemsContainer = UIView()
    private var itemHitViews: [UIView] = []
    private var positionedCards: [String: PositionedCardRecord] = [:]
    private var viewportTransformCardFrames: [String: CGRect]?
    private var viewportTransformCardTransforms:
        [String: CGAffineTransform]?
    private var positionedLayoutCache = BrowserOverlayPositionedLayoutCache()
    private var positionedIntrinsicLayoutCache =
        BrowserOverlayPositionedIntrinsicLayoutCache()
    private let textMeasurementCache =
        BrowserOverlayTextMeasurementCache()
    private var lastPositionedRenderRequest: PositionedRenderRequest?
    private var lastPositionedGeometry: [PositionedGeometrySignature]?
    private var lastPositionedLayoutContext: PositionedLayoutContext?
    private var renderedMode: IPhoneOverlayMode?
    private var subtitleView: OverlaySubtitleView?
    private var sidePanelView: OverlaySidePanelView?
    private var isRenderingPositionedCards = false
    private var localizer = IPhoneLocalizer(locale: .korean)
    private(set) var lastLayoutCacheStatistics =
        BrowserOverlayLayoutCacheStatistics(hits: 0, misses: 0)
    private(set) var lastRenderStatistics =
        BrowserOverlayRenderStatistics.empty

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        backgroundColor = .clear
        accessibilityIdentifier = "aidoku.reader.overlay"

        itemsContainer.backgroundColor = .clear
        itemsContainer.accessibilityIdentifier =
            "aidoku.reader.overlay.items"
        addSubview(itemsContainer)
        addSubview(statusContainer)

        statusContainer.clipsToBounds = true
        statusContainer.layer.cornerRadius = 15
        statusContainer.accessibilityIdentifier =
            "aidoku.reader.overlay.status.container"
        statusLabel.textColor = .white
        statusLabel.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(
            for: .systemFont(ofSize: 12, weight: .semibold)
        )
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.numberOfLines = 0
        statusLabel.accessibilityIdentifier =
            "aidoku.reader.overlay.status"
        // Updates are announced explicitly below so repeated semantic states
        // do not interrupt VoiceOver.
        statusLabel.accessibilityTraits = [.staticText]
        statusContainer.contentView.addSubview(statusLabel)

        itemsContainer.translatesAutoresizingMaskIntoConstraints = false
        statusContainer.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            itemsContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            itemsContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            itemsContainer.topAnchor.constraint(equalTo: topAnchor),
            itemsContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusContainer.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusContainer.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            statusContainer.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
            statusLabel.leadingAnchor.constraint(equalTo: statusContainer.contentView.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: statusContainer.contentView.trailingAnchor, constant: -12),
            statusLabel.topAnchor.constraint(equalTo: statusContainer.contentView.topAnchor, constant: 7),
            statusLabel.bottomAnchor.constraint(equalTo: statusContainer.contentView.bottomAnchor, constant: -7)
        ])
        hideStatus()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        itemHitViews.contains { view in
            !view.isHidden &&
                view.alpha > 0.01 &&
                view.frame.insetBy(dx: -6, dy: -6).contains(point)
        }
    }

    func showStatus(
        _ text: String,
        isError: Bool = false,
        announcementID: String? = nil
    ) {
        statusLabel.text = text
        statusLabel.textColor = isError ? UIColor(red: 1, green: 0.78, blue: 0.80, alpha: 1) : .white
        statusContainer.isHidden = false
        // Visible counters can change on every OCR pass even though their
        // meaning has not changed. Let callers provide a stable semantic ID so
        // VoiceOver does not repeatedly interrupt itself with run numbers.
        let semanticID = announcementID ?? text
        if UIAccessibility.isVoiceOverRunning,
           statusAnnouncementState.shouldAnnounce(
               semanticID,
               persistsAcrossHides: announcementID != nil
           )
        {
            UIAccessibility.post(notification: .announcement, argument: text)
        }
    }

    func hideStatus() {
        statusLabel.text = nil
        statusContainer.isHidden = true
        statusAnnouncementState.statusHidden()
    }

    func resetStatusAnnouncements() {
        statusAnnouncementState.reset()
    }

    func setLocale(_ locale: IPhoneUILocale) {
        guard localizer.locale != locale else { return }
        localizer = IPhoneLocalizer(locale: locale)
        resetStatusAnnouncements()
    }

    func clearItems() {
        itemsContainer.subviews.forEach { $0.removeFromSuperview() }
        itemHitViews.removeAll(keepingCapacity: true)
        positionedCards.removeAll(keepingCapacity: true)
        viewportTransformCardFrames = nil
        viewportTransformCardTransforms = nil
        positionedLayoutCache.removeAll()
        positionedIntrinsicLayoutCache.removeAll()
        textMeasurementCache.removeAll()
        lastPositionedRenderRequest = nil
        lastPositionedGeometry = nil
        lastPositionedLayoutContext = nil
        subtitleView = nil
        sidePanelView = nil
        renderedMode = nil
        isRenderingPositionedCards = false
        lastLayoutCacheStatistics = BrowserOverlayLayoutCacheStatistics(
            hits: 0,
            misses: 0
        )
        lastRenderStatistics = .empty
    }

    func render(
        _ items: [BrowserOverlayItem],
        imageSize: CGSize,
        sourceRect: CGRect,
        settings: IPhoneOverlaySettings,
        targetLanguage: String = "ko",
        invalidatingStableRegionIDs: Set<UInt64> = []
    ) {
        guard imageSize.width > 0, imageSize.height > 0 else {
            clearItems()
            return
        }
        if renderedMode != settings.mode {
            clearItems()
            renderedMode = settings.mode
        }
        switch settings.mode {
        case .translateOnly, .originalAndTranslation:
            if !isRenderingPositionedCards {
                isRenderingPositionedCards = true
            }
            renderPositionedItems(
                items,
                imageSize: imageSize,
                sourceRect: sourceRect,
                settings: settings,
                targetLanguage: targetLanguage,
                invalidatingStableRegionIDs: invalidatingStableRegionIDs
            )
        case .subtitle:
            renderSubtitle(items, settings: settings)
        case .sidePanel:
            renderSidePanel(items, settings: settings)
        }
    }

    /// Moves and scales the already-settled cards with WebKit during a
    /// viewport interaction. This path performs no OCR, translation, text
    /// fitting, line breaking, or collision planning.
    func beginViewportTransform() {
        guard viewportTransformCardFrames == nil else { return }
        viewportTransformCardFrames = positionedCards.mapValues { $0.card.frame }
        viewportTransformCardTransforms = positionedCards.mapValues {
            $0.card.transform
        }
    }

    func applyViewportTransform(
        scale: CGFloat,
        translation: CGPoint
    ) {
        guard scale.isFinite, scale > 0 else { return }
        beginViewportTransform()
        for (key, record) in positionedCards {
            guard let base = viewportTransformCardFrames?[key],
                  let baseTransform = viewportTransformCardTransforms?[key]
            else { continue }
            record.card.transform = baseTransform.scaledBy(
                x: scale,
                y: scale
            )
            record.card.center = CGPoint(
                x: base.midX * scale + translation.x,
                y: base.midY * scale + translation.y
            )
        }
    }

    private func renderPositionedItems(
        _ items: [BrowserOverlayItem],
        imageSize: CGSize,
        sourceRect: CGRect,
        settings: IPhoneOverlaySettings,
        targetLanguage: String,
        invalidatingStableRegionIDs: Set<UInt64>
    ) {
        let layoutContext = PositionedLayoutContext(
            imageSize: imageSize,
            sourceRect: sourceRect,
            settings: settings,
            targetLanguage: targetLanguage,
            viewport: bounds.size,
            locale: localizer.locale
        )
        let renderRequest = PositionedRenderRequest(
            items: items,
            context: layoutContext
        )
        if invalidatingStableRegionIDs.isEmpty,
           viewportTransformCardFrames == nil,
           lastPositionedRenderRequest == renderRequest
        {
            lastLayoutCacheStatistics = BrowserOverlayLayoutCacheStatistics(
                hits: positionedCards.count,
                misses: 0
            )
            lastRenderStatistics = BrowserOverlayRenderStatistics(
                semanticNoOp: true,
                usedFullLayoutFallback: false,
                cardUpdates: 0,
                cardFrameChanges: 0,
                intrinsicLayoutHits: 0,
                intrinsicLayoutMisses: 0,
                textMeasurementHits: 0,
                textMeasurementMisses: 0
            )
            return
        }
        positionedIntrinsicLayoutCache.beginPass()
        textMeasurementCache.beginPass()

        let scaleX = sourceRect.width / imageSize.width
        let scaleY = sourceRect.height / imageSize.height
        let stableRegionIDCounts = items.reduce(
            into: [UInt64: Int](),
            { counts, item in
                guard let stableRegionID = item.stableRegionID else { return }
                counts[stableRegionID, default: 0] += 1
            }
        )
        // A repeated temporal identity is ambiguous. Match the desktop planner:
        // exclude every occurrence instead of choosing one arbitrarily. This
        // also guarantees that no card can be created without an owning map
        // entry and survive later cleanup as an orphaned subview.
        let unambiguousItems = items.filter { item in
            guard let stableRegionID = item.stableRegionID else { return true }
            return stableRegionIDCounts[stableRegionID] == 1
        }
        let sorted = BrowserOverlayItemOrdering.ordered(unambiguousItems)
        var segments: [PositionedSegment] = sorted.enumerated().map {
            index, item in
            let sourceVertical =
                BrowserOverlayTextFlow.usesVerticalSourceLayout(
                    rect: item.rect,
                    text: item.sourceText,
                    sourceOrientation: item.sourceOrientation
                )
            let translatedVertical =
                BrowserOverlayTextFlow.displayedTextUsesVerticalLayout(
                    item: item,
                    sourceIsVertical: sourceVertical,
                    targetLanguage: targetLanguage
                )
            let content = BrowserOverlayCardContent.make(
                item: item,
                mode: settings.mode,
                sourceVertical: sourceVertical,
                translatedVertical: translatedVertical
            )
            let mappedSource = CGRect(
                x: sourceRect.minX + item.rect.minX * scaleX,
                y: sourceRect.minY + item.rect.minY * scaleY,
                width: max(1, item.rect.width * scaleX),
                height: max(1, item.rect.height * scaleY)
            )
            let key = item.stableRegionID.map {
                "region:\($0)"
            } ?? "transient:\(index):\(item.sourceText)"
            return PositionedSegment(
                key: key,
                item: item,
                sourceRect: mappedSource,
                sourceVertical: sourceVertical,
                content: content
            )
        }
        let geometry: [PositionedGeometrySignature]? = {
            guard unambiguousItems.count == items.count,
                  !segments.contains(where: { BrowserOverlayRotation.mapped(item: $0.item, imageSize: imageSize,
                      sourceRect: sourceRect, settings: settings) != nil }),
                  segments.allSatisfy({ $0.item.stableRegionID != nil })
            else {
                return nil
            }
            return segments.compactMap { segment in
                guard let stableRegionID = segment.item.stableRegionID else {
                    return nil
                }
                return PositionedGeometrySignature(
                    key: segment.key,
                    stableRegionID: stableRegionID,
                    sourceRect: segment.sourceRect,
                    sourceText: segment.item.sourceText,
                    sourceOrientation: segment.item.sourceOrientation,
                    sourceSingleVerticalColumn:
                        segment.item.sourceSingleVerticalColumn
                )
            }
        }()
        if invalidatingStableRegionIDs.isEmpty,
           let previousGeometry = lastPositionedGeometry,
           let geometry,
           let baseViewportTransformCardFrames = viewportTransformCardFrames,
           let baseViewportTransformCardTransforms =
            viewportTransformCardTransforms,
           previousGeometry.count >= geometry.count,
           !geometry.isEmpty,
           lastPositionedLayoutContext?.settings == settings,
           lastPositionedLayoutContext?.targetLanguage == targetLanguage,
           lastPositionedLayoutContext?.locale == localizer.locale
        {
            let previousByKey = Dictionary(
                uniqueKeysWithValues: previousGeometry.map { ($0.key, $0) }
            )
            let first = geometry[0]
            if let oldFirst = previousByKey[first.key],
               oldFirst.sourceRect.width > 0,
               oldFirst.sourceRect.height > 0
            {
                let scaleX = first.sourceRect.width /
                    oldFirst.sourceRect.width
                let scaleY = first.sourceRect.height /
                    oldFirst.sourceRect.height
                let scale = (scaleX + scaleY) / 2
                let translation = CGPoint(
                    x: first.sourceRect.minX -
                        oldFirst.sourceRect.minX * scale,
                    y: first.sourceRect.minY -
                        oldFirst.sourceRect.minY * scale
                )
                let tolerance: CGFloat = 1.25
                let isUniform = scale.isFinite && scale > 0 &&
                    abs(scaleX - scaleY) <= 0.01 &&
                    geometry.allSatisfy { current in
                        guard let old = previousByKey[current.key] else {
                            return false
                        }
                        let projected = CGRect(
                            x: old.sourceRect.minX * scale + translation.x,
                            y: old.sourceRect.minY * scale + translation.y,
                            width: old.sourceRect.width * scale,
                            height: old.sourceRect.height * scale
                        )
                        return abs(projected.minX - current.sourceRect.minX) <= tolerance &&
                            abs(projected.minY - current.sourceRect.minY) <= tolerance &&
                            abs(projected.width - current.sourceRect.width) <= tolerance &&
                            abs(projected.height - current.sourceRect.height) <= tolerance
                    }
                if isUniform {
                    let segmentsByKey = Dictionary(
                        uniqueKeysWithValues: segments.map { ($0.key, $0) }
                    )
                    let currentGeometryByKey = Dictionary(
                        uniqueKeysWithValues: geometry.map { ($0.key, $0) }
                    )
                    var nextCards: [String: PositionedCardRecord] = [:]
                    var nextHitViews: [UIView] = []
                    var isSemanticallyStable = true
                    for segment in segments {
                        guard let existing = positionedCards[segment.key],
                              existing.presentation.sourceText ==
                                segment.item.sourceText,
                              existing.presentation.translatedText ==
                                segment.item.translatedText,
                              existing.presentation.confidence ==
                                segment.item.confidence,
                              existing.presentation.content == segment.content
                        else {
                            isSemanticallyStable = false
                            break
                        }
                    }
                    for oldGeometry in previousGeometry {
                        guard isSemanticallyStable,
                              let existing = positionedCards[oldGeometry.key],
                              let base = baseViewportTransformCardFrames[
                                oldGeometry.key
                              ],
                              let baseTransform =
                                baseViewportTransformCardTransforms[
                                    oldGeometry.key
                                ]
                        else {
                            isSemanticallyStable = false
                            break
                        }
                        let currentSegment = segmentsByKey[oldGeometry.key]
                        let item = currentSegment?.item ?? existing.item
                        existing.card.transform = baseTransform.scaledBy(
                            x: scale,
                            y: scale
                        )
                        existing.card.center = CGPoint(
                            x: base.midX * scale + translation.x,
                            y: base.midY * scale + translation.y
                        )
                        nextCards[oldGeometry.key] = PositionedCardRecord(
                            card: existing.card,
                            item: item,
                            presentation: existing.presentation
                        )
                        nextHitViews.append(existing.card)
                    }
                    if isSemanticallyStable,
                       nextCards.count == previousGeometry.count
                    {
                        let projectedGeometry = previousGeometry.map { old in
                            if let current = currentGeometryByKey[old.key] {
                                return current
                            }
                            return PositionedGeometrySignature(
                                key: old.key,
                                stableRegionID: old.stableRegionID,
                                sourceRect: CGRect(
                                    x: old.sourceRect.minX * scale +
                                        translation.x,
                                    y: old.sourceRect.minY * scale +
                                        translation.y,
                                    width: old.sourceRect.width * scale,
                                    height: old.sourceRect.height * scale
                                ),
                                sourceText: old.sourceText,
                                sourceOrientation: old.sourceOrientation,
                                sourceSingleVerticalColumn:
                                    old.sourceSingleVerticalColumn
                            )
                        }
                        positionedCards = nextCards
                        itemHitViews = nextHitViews
                        viewportTransformCardFrames = nil
                        viewportTransformCardTransforms = nil
                        positionedLayoutCache.removeAll()
                        positionedIntrinsicLayoutCache.removeAll()
                        lastPositionedRenderRequest = renderRequest
                        lastPositionedGeometry = projectedGeometry
                        lastPositionedLayoutContext = layoutContext
                        lastLayoutCacheStatistics =
                            BrowserOverlayLayoutCacheStatistics(
                                hits: nextCards.count,
                                misses: 0
                            )
                        lastRenderStatistics = BrowserOverlayRenderStatistics(
                            semanticNoOp: false,
                            usedFullLayoutFallback: false,
                            cardUpdates: 0,
                            cardFrameChanges: nextCards.count,
                            intrinsicLayoutHits: nextCards.count,
                            intrinsicLayoutMisses: 0,
                            textMeasurementHits: 0,
                            textMeasurementMisses: 0
                        )
                        return
                    }
                }
            }
        }
        if let baseFrames = viewportTransformCardFrames {
            for (key, record) in positionedCards {
                record.card.transform = .identity
                if let base = baseFrames[key] { record.card.frame = base }
            }
            viewportTransformCardFrames = nil
            viewportTransformCardTransforms = nil
        }
        let hasPreviousLayout = lastPositionedLayoutContext != nil
        let canUseIncrementalLayout = geometry != nil &&
            lastPositionedGeometry == geometry &&
            lastPositionedLayoutContext == layoutContext
        if !canUseIncrementalLayout {
            // Geometry, ordering, style, mode-adjacent context, or transient
            // identity is ambiguous. Retain expensive text measurements, but
            // conservatively recompute every collision placement.
            positionedLayoutCache.removeAll()
        }
        // PP-OCR has already performed the canonical fragment merge and
        // pre-translation deduplication. The renderer is deliberately
        // one-region-in/one-card-out; merging translated strings here changes
        // sentence meaning and was the source of repeated price/line output.
        let sourceRects = segments.map { $0.sourceRect }
        var occupied: [BrowserOverlayPositionedCollisionDependency] = []
        var plannedLayouts = Array<BrowserOverlayCardLayout?>(
            repeating: nil,
            count: segments.count
        )
        var nextCards: [String: PositionedCardRecord] = [:]
        var nextHitViews: [UIView] = []
        var retainedLayoutKeys = Set<String>()
        var cardUpdates = 0
        var cardFrameChanges = 0
        positionedLayoutCache.beginPass()

        var intrinsicLayouts = segments.map { segment in
            let explicitlyInvalidated =
                segment.item.stableRegionID.map {
                    invalidatingStableRegionIDs.contains($0)
                } ?? false
            let intrinsicInput =
                BrowserOverlayPositionedIntrinsicLayoutCacheInput(
                    source: segment.sourceRect,
                    displayedVariant: segment.content.displayed,
                    settings: settings,
                    viewport: bounds.size,
                    sourceVertical: segment.sourceVertical,
                    singleVerticalColumn:
                        segment.content.singleVerticalColumn
                )
            retainedLayoutKeys.insert(segment.key)
            return positionedIntrinsicLayoutCache.layout(
                for: segment.key,
                input: intrinsicInput,
                invalidated: explicitlyInvalidated
            ) {
                BrowserOverlayLayoutPlanner.plan(
                    source: segment.sourceRect,
                    variants: [segment.content.displayed],
                    settings: settings,
                    viewport: bounds.size,
                    occupied: [],
                    sourceVertical: segment.sourceVertical,
                    singleVerticalColumn:
                        segment.content.singleVerticalColumn,
                    reservedSources: [],
                    measurementCache: textMeasurementCache
                )
            }
        }
        var verticalContents: [Int: BrowserOverlayCardContent] = [:]
        var verticalLayouts: [Int: BrowserOverlayCardLayout] = [:]
        for index in segments.indices {
            let segment = segments[index]
            guard let verticalContent =
                BrowserOverlayCardContent.adaptiveVerticalCandidate(
                    item: segment.item,
                    current: segment.content,
                    mode: settings.mode,
                    textPlacement: settings.textPlacement,
                    sourceVertical: segment.sourceVertical,
                    sourceRect: segment.sourceRect
                )
            else { continue }
            verticalContents[index] = verticalContent
            verticalLayouts[index] = BrowserOverlayLayoutPlanner.plan(
                source: segment.sourceRect,
                variants: [verticalContent.displayed],
                settings: settings,
                viewport: bounds.size,
                occupied: [],
                sourceVertical: segment.sourceVertical,
                singleVerticalColumn: verticalContent.singleVerticalColumn,
                reservedSources: [],
                measurementCache: textMeasurementCache
            )
        }
        let verticalIndices =
            BrowserOverlayLayoutPlanner.adaptiveVerticalTranslationIndices(
                horizontalLayouts: intrinsicLayouts,
                verticalLayouts: verticalLayouts,
                eligibleIndices:
                    BrowserOverlayLayoutPlanner
                        .severelyDisplacedTranslationIndices(
                            intrinsicLayouts: intrinsicLayouts,
                            sources: sourceRects,
                            variants: segments.map { $0.content.displayed },
                            settings: settings,
                            viewport: bounds.size,
                            sourceVerticals: segments.map(\.sourceVertical),
                            singleVerticalColumns: segments.map {
                                $0.content.singleVerticalColumn
                            },
                            placementBounds: sourceRect,
                            allowsDetachedPlacements: segments.map {
                                $0.content.hasTranslation &&
                                    settings.mode == .translateOnly
                            }
                        )
            )
        for index in verticalIndices {
            guard let content = verticalContents[index],
                  let layout = verticalLayouts[index]
            else { continue }
            let segment = segments[index]
            segments[index] = PositionedSegment(
                key: segment.key,
                item: segment.item,
                sourceRect: segment.sourceRect,
                sourceVertical: segment.sourceVertical,
                content: content
            )
            intrinsicLayouts[index] = layout
        }
        let planningOrder = BrowserOverlayLayoutPlanner.packingOrder(
            intrinsicLayouts
        )

        for index in planningOrder {
            let segment = segments[index]
            let item = segment.item
            let mappedSource = segment.sourceRect
            // Desktop sizes the card for the text that is actually painted,
            // not for both the hidden source and the visible translation at
            // once. Reserving the envelope for a much longer hidden source
            // unnecessarily shrank short translations on iPhone.
            let visiblePlanningVariants = [
                segment.content.displayed,
            ]
            let reservedSources = sourceRects.enumerated().compactMap {
                otherIndex, rect in
                otherIndex == index ? nil : rect
            }
            let explicitlyInvalidated =
                segment.item.stableRegionID.map {
                    invalidatingStableRegionIDs.contains($0)
                } ?? false
            let intrinsicLayout = intrinsicLayouts[index]
            let occupiedDependencies =
                BrowserOverlayLayoutPlanner.collisionDependencies(
                    intrinsicLayout: intrinsicLayout,
                    source: mappedSource,
                    variants: visiblePlanningVariants,
                    settings: settings,
                    viewport: bounds.size,
                    occupied: occupied,
                    sourceVertical: segment.sourceVertical,
                    singleVerticalColumn:
                        segment.content.singleVerticalColumn
                )
            let cacheInput = BrowserOverlayPositionedLayoutCacheInput(
                source: mappedSource,
                intrinsicLayout: intrinsicLayout,
                viewport: bounds.size,
                occupiedDependencies: occupiedDependencies,
                reservedSources: reservedSources
            )
            let layout = positionedLayoutCache.layout(
                for: segment.key,
                input: cacheInput,
                invalidated: explicitlyInvalidated
            ) {
                BrowserOverlayLayoutPlanner.resolvePositionedLayout(
                    intrinsicLayout,
                    source: mappedSource,
                    variants: visiblePlanningVariants,
                    settings: settings,
                    viewport: bounds.size,
                    occupied: occupied.map(\.rect),
                    sourceVertical: segment.sourceVertical,
                    singleVerticalColumn:
                        segment.content.singleVerticalColumn,
                    reservedSources: reservedSources
                )
            }
            let mapped = layout.rect
            guard !mapped.isNull, mapped.width > 0, mapped.height > 0 else { continue }
            plannedLayouts[index] = layout
            occupied.append(BrowserOverlayPositionedCollisionDependency(
                key: segment.key,
                rect: mapped
            ))

            let presentation = PositionedCardPresentationInput(
                sourceText: item.sourceText,
                translatedText: item.translatedText,
                confidence: item.confidence,
                content: segment.content,
                settings: settings,
                maximumFontSize: layout.maximumFontSize,
                contentInsets: layout.contentInsets,
                locale: localizer.locale
            )

            let existing = positionedCards[segment.key]
            let card: OverlayCardView
            if let existing {
                card = existing.card
                if existing.presentation != presentation || existing.item.sourcePolygon != item.sourcePolygon ||
                    existing.card.transform != .identity {
                    card.update(
                        item: item,
                        content: segment.content,
                        settings: settings,
                        maximumFontSize: layout.maximumFontSize,
                        contentInsets: layout.contentInsets,
                        localizer: localizer,
                        measurementCache: textMeasurementCache
                    )
                    cardUpdates += 1
                }
            } else {
                card = OverlayCardView(
                    item: item,
                    content: segment.content,
                    settings: settings,
                    maximumFontSize: layout.maximumFontSize,
                    contentInsets: layout.contentInsets,
                    localizer: localizer,
                    measurementCache: textMeasurementCache
                )
                cardUpdates += 1
            }
            card.transform = .identity
            card.layer.mask = nil
            if card.frame != mapped {
                card.frame = mapped
                cardFrameChanges += 1
            }
            if card.superview == nil {
                itemsContainer.addSubview(card)
            } else {
                itemsContainer.bringSubviewToFront(card)
            }
            nextHitViews.append(card)
            nextCards[segment.key] = PositionedCardRecord(
                card: card,
                item: item,
                presentation: presentation
            )
        }
        let concreteLayouts = plannedLayouts.compactMap { $0 }
        if concreteLayouts.count == plannedLayouts.count {
            let relaxed = BrowserOverlayLayoutPlanner.restoringSourceCoverage(
                BrowserOverlayLayoutPlanner.relaxingCardPositions(
                concreteLayouts,
                sources: sourceRects,
                sourceVerticals: segments.map(\.sourceVertical),
                viewport: bounds.size,
                placementBounds: sourceRect,
                preferredRects: intrinsicLayouts.map(\.rect),
                allowsDetachedPlacements: segments.map {
                    $0.content.hasTranslation &&
                        settings.mode == .translateOnly
                }
                ),
                sources: sourceRects,
                bounds: sourceRect,
                enabled: settings.mode == .translateOnly && settings.textPlacement == .replace
            )
            for index in relaxed.indices {
                guard let record = nextCards[segments[index].key] else {
                    continue
                }
                let relaxedFrame = relaxed[index].rect
                if record.card.frame != relaxedFrame {
                    record.card.frame = relaxedFrame
                    cardFrameChanges += 1
                }
            }
        }
        for (key, record) in positionedCards where nextCards[key] == nil {
            record.card.removeFromSuperview()
        }
        // Match the reader DOM path. The ordinary placement pass still reserves
        // the source footprint for neighbors; rotation stays inside that quad.
        for segment in segments {
            guard let record = nextCards[segment.key],
                  let rotation = BrowserOverlayRotation.mapped(item: segment.item, imageSize: imageSize,
                      sourceRect: sourceRect, settings: settings),
                  let layout = BrowserOverlayRotation.layout(geometry: rotation, variant: segment.content.displayed,
                      maximumFontSize: record.presentation.maximumFontSize, measurementCache: textMeasurementCache) else { continue }
            record.card.update(item: segment.item, content: segment.content, settings: settings,
                maximumFontSize: layout.maximumFontSize, contentInsets: layout.contentInsets,
                localizer: localizer, measurementCache: textMeasurementCache)
            record.card.bounds = CGRect(origin: .zero, size: layout.rect.size)
            record.card.center = CGPoint(x: layout.rect.midX, y: layout.rect.midY)
            record.card.transform = CGAffineTransform(rotationAngle: rotation.radians)
            let mask = CAShapeLayer()
            mask.frame = record.card.bounds
            let path = CGMutablePath()
            let corners = [CGPoint(x: sourceRect.minX, y: sourceRect.minY), CGPoint(x: sourceRect.maxX, y: sourceRect.minY),
                           CGPoint(x: sourceRect.maxX, y: sourceRect.maxY), CGPoint(x: sourceRect.minX, y: sourceRect.maxY)]
            let c = cos(rotation.radians), s = sin(rotation.radians)
            let local = corners.map { point -> CGPoint in
                let x = point.x - layout.rect.midX, y = point.y - layout.rect.midY
                return CGPoint(x: x * c + y * s + layout.rect.width / 2,
                               y: -x * s + y * c + layout.rect.height / 2)
            }
            path.addLines(between: local); path.closeSubpath()
            mask.path = path; record.card.layer.mask = mask
        }
        positionedCards = nextCards
        itemHitViews = nextHitViews
        positionedLayoutCache.finishPass(retaining: retainedLayoutKeys)
        positionedIntrinsicLayoutCache.finishPass(
            retaining: retainedLayoutKeys
        )
        lastLayoutCacheStatistics = BrowserOverlayLayoutCacheStatistics(
            hits: positionedLayoutCache.passHits,
            misses: positionedLayoutCache.passMisses
        )
        let measurementStatistics = textMeasurementCache.passStatistics
        lastRenderStatistics = BrowserOverlayRenderStatistics(
            semanticNoOp: false,
            usedFullLayoutFallback:
                hasPreviousLayout && !canUseIncrementalLayout,
            cardUpdates: cardUpdates,
            cardFrameChanges: cardFrameChanges,
            intrinsicLayoutHits:
                positionedIntrinsicLayoutCache.passHits,
            intrinsicLayoutMisses:
                positionedIntrinsicLayoutCache.passMisses,
            textMeasurementHits: measurementStatistics.hits,
            textMeasurementMisses: measurementStatistics.misses
        )
        lastPositionedRenderRequest = renderRequest
        lastPositionedGeometry = geometry
        lastPositionedLayoutContext = layoutContext
    }

    private func renderSubtitle(
        _ items: [BrowserOverlayItem],
        settings: IPhoneOverlaySettings
    ) {
        let text = items.compactMap { item -> String? in
            let value = item.translatedText ?? item.sourceText
            return value.isEmpty ? nil : value
        }.joined(separator: "  ")
        guard !text.isEmpty else {
            subtitleView?.removeFromSuperview()
            subtitleView = nil
            itemHitViews.removeAll(keepingCapacity: true)
            return
        }

        let sourceText = items.map(\.sourceText).joined(separator: "  ")
        let subtitle: OverlaySubtitleView
        if let existing = subtitleView {
            subtitle = existing
            subtitle.update(
                text: text,
                sourceText: sourceText,
                settings: settings,
                localizer: localizer
            )
        } else {
            subtitle = OverlaySubtitleView(
                text: text,
                sourceText: sourceText,
                settings: settings,
                localizer: localizer
            )
            subtitleView = subtitle
            itemsContainer.addSubview(subtitle)
        }
        let height = CGFloat(settings.subtitleMaxLines == 1 ? 54 : 86)
        let inset: CGFloat = 12
        let y = settings.subtitlePosition == .top
            ? safeAreaInsets.top + 44
            : bounds.height - safeAreaInsets.bottom - height - 12
        subtitle.frame = CGRect(
            x: inset,
            y: max(inset, y),
            width: max(1, bounds.width - inset * 2),
            height: height
        ).intersection(bounds)
        itemHitViews = [subtitle]
    }

    private func renderSidePanel(
        _ items: [BrowserOverlayItem],
        settings: IPhoneOverlaySettings
    ) {
        guard !items.isEmpty else {
            sidePanelView?.removeFromSuperview()
            sidePanelView = nil
            itemHitViews.removeAll(keepingCapacity: true)
            return
        }
        let width = min(max(190, bounds.width * 0.52), bounds.width - 16)
        let panel: OverlaySidePanelView
        if let existing = sidePanelView {
            panel = existing
            panel.update(
                items: items,
                settings: settings,
                localizer: localizer
            )
        } else {
            panel = OverlaySidePanelView(
                items: items,
                settings: settings,
                localizer: localizer
            )
            sidePanelView = panel
            itemsContainer.addSubview(panel)
        }
        panel.frame = CGRect(
            x: bounds.width - width - 8,
            y: safeAreaInsets.top + 44,
            width: width,
            height: max(80, bounds.height - safeAreaInsets.top -
                safeAreaInsets.bottom - 100)
        ).intersection(bounds)
        itemHitViews = [panel]
    }

}

struct BrowserOverlayPresentationSegment: Equatable {
    let sourceRect: CGRect
    let sourceText: String
    let translatedText: String?
    let confidence: Double
    let sourceVertical: Bool
    let translatedVertical: Bool
    let displayVertical: Bool
}

struct BrowserOverlayPresentationGroup: Equatable {
    let segments: [BrowserOverlayPresentationSegment]

    var sourceRects: [CGRect] {
        segments.map(\.sourceRect)
    }

    var sourceBounds: CGRect {
        sourceRects.dropFirst().reduce(sourceRects.first ?? .null) {
            $0.union($1)
        }
    }

    var sourceVertical: Bool {
        segments.count == 1 && segments[0].sourceVertical
    }

    var translatedVertical: Bool {
        segments.count == 1 && segments[0].translatedVertical
    }

    var displayVertical: Bool {
        segments.count == 1 && segments[0].displayVertical
    }

    var overlayItem: BrowserOverlayItem {
        let translations = segments.compactMap(\.translatedText)
        let translation = translations.count == segments.count
            ? Self.joinWrappedLines(translations)
            : nil
        return BrowserOverlayItem(
            rect: sourceBounds,
            sourceText: segments.map(\.sourceText).joined(separator: "\n"),
            translatedText: translation,
            confidence: segments.reduce(0) { $0 + $1.confidence } /
                Double(max(1, segments.count)),
            sourceOrientation: sourceVertical ? .vertical : .horizontal
        )
    }

    private static func joinWrappedLines(_ lines: [String]) -> String {
        lines.reduce(into: "") { result, line in
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            if result.isEmpty {
                result = value
            } else if result.last == "-" {
                result.removeLast()
                result += value
            } else if value.first?.isPunctuation == true {
                result += value
            } else {
                result += " " + value
            }
        }
    }
}

struct BrowserOverlayPresentationGrouper {
    static func groups(
        _ segments: [BrowserOverlayPresentationSegment]
    ) -> [BrowserOverlayPresentationGroup] {
        let sorted = BrowserOverlayPresentationDeduplicator
            .deduplicate(segments)
            .sorted {
            if abs($0.sourceRect.minY - $1.sourceRect.minY) > 2 {
                return $0.sourceRect.minY < $1.sourceRect.minY
            }
            return $0.sourceRect.minX < $1.sourceRect.minX
        }
        var result: [[BrowserOverlayPresentationSegment]] = []
        for segment in sorted {
            let candidates = result.indices.filter {
                canAppend(segment, to: result[$0])
            }
            if let index = candidates.min(by: {
                groupingDistance(segment, from: result[$0]) <
                    groupingDistance(segment, from: result[$1])
            }) {
                result[index].append(segment)
            } else {
                result.append([segment])
            }
        }
        return result.map(BrowserOverlayPresentationGroup.init)
    }

    private static func canAppend(
        _ segment: BrowserOverlayPresentationSegment,
        to group: [BrowserOverlayPresentationSegment]
    ) -> Bool {
        guard let previous = group.max(by: {
            $0.sourceRect.maxY < $1.sourceRect.maxY
        }),
              !segment.sourceVertical,
              !previous.sourceVertical,
              (segment.translatedText != nil) ==
                (previous.translatedText != nil)
        else {
            return false
        }
        let current = segment.sourceRect
        let last = previous.sourceRect
        let verticalOverlap = min(current.maxY, last.maxY) -
            max(current.minY, last.minY)
        if verticalOverlap >= min(current.height, last.height) * 0.45 {
            let gap = max(
                0,
                max(current.minX, last.minX) -
                    min(current.maxX, last.maxX)
            )
            return gap <= max(12, min(current.height, last.height))
        }

        let verticalGap = current.minY - last.maxY
        guard verticalGap >= -min(current.height, last.height) * 0.2,
              verticalGap <= max(10, min(current.height, last.height) * 0.7)
        else {
            return false
        }
        let widthRatio = min(current.width, last.width) /
            max(1, max(current.width, last.width))
        let leadingTolerance = max(
            10,
            min(current.width, last.width) * 0.18
        )
        guard widthRatio >= 0.55,
              abs(current.minX - last.minX) <= leadingTolerance
        else {
            return false
        }
        let bounds = group.dropFirst().reduce(
            group.first?.sourceRect ?? .null
        ) { $0.union($1.sourceRect) }
        let combined = bounds.union(current)
        let widest = max(
            current.width,
            group.map { $0.sourceRect.width }.max() ?? 0
        )
        return combined.width <= widest * 1.35
    }

    private static func groupingDistance(
        _ segment: BrowserOverlayPresentationSegment,
        from group: [BrowserOverlayPresentationSegment]
    ) -> CGFloat {
        guard let last = group.max(by: {
            $0.sourceRect.maxY < $1.sourceRect.maxY
        }) else {
            return .greatestFiniteMagnitude
        }
        let dx = segment.sourceRect.minX - last.sourceRect.minX
        let dy = segment.sourceRect.minY - last.sourceRect.maxY
        return dx * dx + dy * dy
    }
}

struct BrowserOverlayPresentationDeduplicator {
    static func deduplicate(
        _ segments: [BrowserOverlayPresentationSegment]
    ) -> [BrowserOverlayPresentationSegment] {
        var result: [BrowserOverlayPresentationSegment] = []
        for segment in segments {
            guard let index = result.firstIndex(where: {
                isDuplicate(segment, of: $0)
            }) else {
                result.append(segment)
                continue
            }
            if prefers(segment, over: result[index]) {
                result[index] = segment
            }
        }
        return result
    }

    private static func isDuplicate(
        _ left: BrowserOverlayPresentationSegment,
        of right: BrowserOverlayPresentationSegment
    ) -> Bool {
        let intersection = left.sourceRect.intersection(right.sourceRect)
        guard !intersection.isNull else { return false }
        let smallerArea = min(
            left.sourceRect.width * left.sourceRect.height,
            right.sourceRect.width * right.sourceRect.height
        )
        guard smallerArea > 0,
              intersection.width * intersection.height / smallerArea >= 0.78,
              related(left.sourceText, right.sourceText),
              relatedTranslations(left.translatedText, right.translatedText)
        else {
            return false
        }
        return true
    }

    private static func relatedTranslations(
        _ left: String?,
        _ right: String?
    ) -> Bool {
        switch (left, right) {
        case (.none, .none):
            return true
        case let (.some(left), .some(right)):
            return related(left, right)
        default:
            return false
        }
    }

    private static func related(_ left: String, _ right: String) -> Bool {
        let left = normalized(left)
        let right = normalized(right)
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left == right { return true }
        let shorter = left.count < right.count ? left : right
        let longer = left.count < right.count ? right : left
        return shorter.count >= 3 && longer.contains(shorter)
    }

    private static func prefers(
        _ left: BrowserOverlayPresentationSegment,
        over right: BrowserOverlayPresentationSegment
    ) -> Bool {
        let leftLength = normalized(left.sourceText).count +
            normalized(left.translatedText ?? "").count
        let rightLength = normalized(right.sourceText).count +
            normalized(right.translatedText ?? "").count
        if leftLength != rightLength {
            return leftLength > rightLength
        }
        if abs(left.confidence - right.confidence) > 0.0001 {
            return left.confidence > right.confidence
        }
        let leftArea = left.sourceRect.width * left.sourceRect.height
        let rightArea = right.sourceRect.width * right.sourceRect.height
        return leftArea < rightArea
    }

    private static func normalized(_ text: String) -> String {
        var result = ""
        for scalar in text.lowercased().unicodeScalars where
            scalar.properties.isAlphabetic ||
            scalar.properties.numericType != nil
        {
            result.unicodeScalars.append(scalar)
        }
        return result
    }
}

enum BrowserOverlayDOMTypography {
    /// c1's Korean CSS stack starts with Apple SD Gothic Neo and paints a
    /// horizontal translated card at weight 700. Use the same face for the
    /// final native glyph pass without feeding its metrics back into layout.
    static func font(
        for text: String,
        pointSize: CGFloat,
        weight: UIFont.Weight
    ) -> UIFont {
        guard BrowserOverlayTextFlow.fontScript(for: text) == .korean else {
            return .systemFont(ofSize: pointSize, weight: weight)
        }
        let postScriptName: String
        if weight.rawValue >= UIFont.Weight.heavy.rawValue {
            postScriptName = "AppleSDGothicNeo-ExtraBold"
        } else if weight.rawValue >= UIFont.Weight.bold.rawValue {
            postScriptName = "AppleSDGothicNeo-Bold"
        } else if weight.rawValue >= UIFont.Weight.semibold.rawValue {
            postScriptName = "AppleSDGothicNeo-SemiBold"
        } else if weight.rawValue >= UIFont.Weight.medium.rawValue {
            postScriptName = "AppleSDGothicNeo-Medium"
        } else {
            postScriptName = "AppleSDGothicNeo-Regular"
        }
        return UIFont(name: postScriptName, size: pointSize) ??
            .systemFont(ofSize: pointSize, weight: weight)
    }
}

struct BrowserOverlayDisplayVariant: Equatable, Hashable {
    enum Content: Equatable, Hashable {
        case plain(String)
        case originalAndTranslation(
            source: String,
            translation: String,
            separator: String
        )
    }

    let content: Content
    let vertical: Bool

    static func plain(_ text: String, vertical: Bool) -> Self {
        Self(content: .plain(text), vertical: vertical)
    }

    var displayText: String {
        switch content {
        case let .plain(text):
            text
        case let .originalAndTranslation(source, translation, separator):
            source + separator + translation
        }
    }

    func attributedString(
        fontSize: CGFloat,
        foregroundColor: UIColor? = nil,
        secondaryForegroundColor: UIColor? = nil,
        textShadow: NSShadow? = nil,
        availableWidth: CGFloat? = nil,
        measurementCache: BrowserOverlayTextMeasurementCache? = nil,
        usesDOMFontFamily: Bool = false
    ) -> NSAttributedString {
        func attributes(
            scriptText: String,
            pointSize: CGFloat,
            weight: UIFont.Weight,
            color: UIColor?,
            includesTextShadow: Bool
        ) -> [NSAttributedString.Key: Any] {
            let planningFont = UIFont.systemFont(
                ofSize: pointSize,
                weight: weight
            )
            let font = usesDOMFontFamily
                ? BrowserOverlayDOMTypography.font(
                    for: scriptText,
                    pointSize: pointSize,
                    weight: weight
                )
                : planningFont
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = lineBreakMode(
                availableWidth: availableWidth,
                fontSize: pointSize,
                measurementCache: measurementCache
            )
            paragraph.lineBreakStrategy = [.standard, .hangulWordPriority]
            paragraph.alignment = .center
            // Horizontal cards must reserve UIKit's real font line height.
            // A point-size multiplier can be shorter than the current SF font
            // metrics, so the planner approves a card that UILabel later clips.
            // Explicit vertical columns intentionally keep one glyph per point-
            // size cell; their compact column spacing is a separate contract.
            // c1 plans geometry with the system font, then paints Korean with
            // Apple SD Gothic Neo while retaining the planned CSS line-height
            // ratio. Keeping those responsibilities separate preserves every
            // existing card frame while matching the DOM painter's glyphs.
            let lineHeight = vertical ? pointSize : planningFont.lineHeight
            paragraph.minimumLineHeight = lineHeight
            paragraph.maximumLineHeight = lineHeight
            var result: [NSAttributedString.Key: Any] = [
                .font: font,
                .paragraphStyle: paragraph,
                .kern: pointSize * -0.012,
            ]
            if let color {
                result[.foregroundColor] = color
            }
            if includesTextShadow, let textShadow {
                result[.shadow] = textShadow
            }
            return result
        }

        switch content {
        case let .plain(text):
            return NSAttributedString(
                string: text,
                attributes: attributes(
                    scriptText: text,
                    pointSize: fontSize,
                    weight: vertical ? .heavy : .bold,
                    color: foregroundColor,
                    includesTextShadow: true
                )
            )
        case let .originalAndTranslation(source, translation, separator):
            let result = NSMutableAttributedString()
            let sourceFontSize = max(7, fontSize * 0.64)
            result.append(NSAttributedString(
                string: source,
                attributes: attributes(
                    scriptText: source,
                    pointSize: sourceFontSize,
                    weight: .medium,
                    color: secondaryForegroundColor ?? foregroundColor,
                    includesTextShadow: false
                )
            ))
            result.append(NSAttributedString(
                string: separator,
                attributes: attributes(
                    scriptText: source,
                    pointSize: sourceFontSize,
                    weight: .medium,
                    color: secondaryForegroundColor ?? foregroundColor,
                    includesTextShadow: false
                )
            ))
            result.append(NSAttributedString(
                string: translation,
                attributes: attributes(
                    scriptText: translation,
                    pointSize: fontSize,
                    weight: .bold,
                    color: foregroundColor,
                    includesTextShadow: true
                )
            ))
            return result
        }
    }

    func measuredSize(
        width: CGFloat,
        fontSize: CGFloat,
        measurementCache: BrowserOverlayTextMeasurementCache? = nil
    ) -> CGSize {
        guard width > 0, fontSize > 0 else { return .zero }
        let calculate = { () -> CGSize in
            let makeString = {
                attributedString(fontSize: fontSize, availableWidth: width, measurementCache: measurementCache)
            }
            let string = measurementCache?.measurementString(for: self, width: width, fontSize: fontSize,
                                                              calculate: makeString) ?? makeString()
            let measured = string.boundingRect(
                with: CGSize(
                    width: width,
                    height: .greatestFiniteMagnitude
                ),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )
            return CGSize(
                width: ceil(measured.width),
                height: ceil(measured.height)
            )
        }
        guard let measurementCache else { return calculate() }
        return measurementCache.measuredSize(
            for: self,
            width: width,
            fontSize: fontSize,
            calculate: calculate
        )
    }

    func fits(
        available: CGSize,
        fontSize: CGFloat,
        measurementCache: BrowserOverlayTextMeasurementCache? = nil
    ) -> Bool {
        guard available.width > 0, available.height > 0 else {
            return false
        }
        // The planner's vertical compatibility string has one explicit line per
        // glyph. Measuring thousands of forced lines at unbounded height makes
        // UIKit repeatedly shape the remaining string. Mandatory line advances
        // alone can prove non-fit without changing fonts, geometry or the text.
        // Ignore the first/last line extents, so this remains a lower bound.
        if case let .plain(text) = content {
            let minimumAdvance = vertical ? fontSize : UIFont.systemFont(ofSize: fontSize, weight: .bold).lineHeight
            if minimumAdvance > 0 {
                var forcedAdvance: CGFloat = 0
                for scalar in text.unicodeScalars where scalar.value == 10 {
                    forcedAdvance += minimumAdvance
                    if forcedAdvance > available.height + 0.5 { return false }
                }
            }
        }
        let measured = measuredSize(
            width: available.width,
            fontSize: fontSize,
            measurementCache: measurementCache
        )
        return measured.width <= available.width + 0.5 &&
            measured.height <= available.height + 0.5
    }

    func minimumUnbrokenWidth(
        fontSize: CGFloat,
        measurementCache: BrowserOverlayTextMeasurementCache? = nil
    ) -> CGFloat {
        let calculate = { () -> CGFloat in
            switch content {
            case let .plain(text):
                return Self.minimumUnbrokenWidth(
                    text,
                    fontSize: fontSize,
                    weight: vertical ? .heavy : .bold
                )
            case let .originalAndTranslation(source, translation, _):
                return max(
                    Self.minimumUnbrokenWidth(
                        source,
                        fontSize: max(7, fontSize * 0.64),
                        weight: .medium
                    ),
                    Self.minimumUnbrokenWidth(
                        translation,
                        fontSize: fontSize,
                        weight: .bold
                    )
                )
            }
        }
        guard let measurementCache else { return calculate() }
        return measurementCache.minimumUnbrokenWidth(
            for: self,
            fontSize: fontSize,
            calculate: calculate
        )
    }

    /// A whole Korean utterance must not stay microscopic merely because
    /// shrinking it made one long token fit on a single line. The final DOM
    /// guard still owns glyph containment, obstacles and punctuation.
    func allowsEmergencyKoreanWordBreak(at referenceFont: CGFloat) -> Bool {
        let text = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !vertical && referenceFont < 8 && text.count >= 10 && text.count <= 180 &&
            !text.contains(where: \.isWhitespace) &&
            BrowserOverlayTextFlow.wrappingScript(for: text) == .korean
    }

    func lineBreakMode(
        availableWidth: CGFloat?,
        fontSize: CGFloat,
        measurementCache: BrowserOverlayTextMeasurementCache? = nil
    ) -> NSLineBreakMode {
        guard let availableWidth, availableWidth > 0,
              minimumUnbrokenWidth(
                  fontSize: fontSize,
                  measurementCache: measurementCache
              ) > availableWidth + 0.5
        else {
            return .byWordWrapping
        }
        return .byCharWrapping
    }

    private static func minimumUnbrokenWidth(
        _ text: String,
        fontSize: CGFloat,
        weight: UIFont.Weight
    ) -> CGFloat {
        text.split(whereSeparator: { character in
            character.isWhitespace || character.isNewline
        }).reduce(CGFloat.zero) { widest, token in
            let value = String(token)
            let containsBreakableCJK = value.unicodeScalars.contains {
                BrowserOverlayTextFlow.isCJKForLayout($0.value) &&
                    !($0.value >= 0xAC00 && $0.value <= 0xD7AF)
            }
            guard !containsBreakableCJK else {
                return max(widest, fontSize)
            }
            let width = ceil((value as NSString).size(withAttributes: [
                .font: UIFont.systemFont(ofSize: fontSize, weight: weight),
            ]).width)
            return max(widest, width)
        }
    }
}

struct BrowserOverlayVerticalTextLayoutSnapshot: Equatable {
    let visibleUTF16Range: NSRange
    let utf16Length: Int
    let lineOrigins: [CGPoint]
    let paintedInkBounds: CGRect
    let availableBounds: CGRect
    let usesVerticalForms: Bool
    let progressesRightToLeft: Bool

    var fits: Bool {
        visibleUTF16Range.location == 0 &&
            NSMaxRange(visibleUTF16Range) >= utf16Length &&
            availableBounds.insetBy(dx: -0.5, dy: -0.5)
                .contains(paintedInkBounds)
    }
}

/// Core Text owns the final native vertical painter. The existing display
/// variant remains the layout planner's compatibility contract, but the text
/// handed to this renderer is the unmodified OCR/translation string rather
/// than a string with a synthetic newline inserted after every character.
enum BrowserOverlayVerticalTextRenderer {
    static let verticalFormsAttributeKey = NSAttributedString.Key(
        kCTVerticalFormsAttributeName as String
    )

    static func attributedString(
        text: String,
        fontSize: CGFloat,
        weight: UIFont.Weight,
        foregroundColor: UIColor? = nil,
        textShadow: NSShadow? = nil
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byCharWrapping
        paragraph.minimumLineHeight = fontSize
        paragraph.maximumLineHeight = fontSize
        var attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize, weight: weight),
            .paragraphStyle: paragraph,
            .kern: fontSize * -0.012,
            verticalFormsAttributeKey: true,
        ]
        if let foregroundColor {
            attributes[.foregroundColor] = foregroundColor
        }
        if let textShadow {
            attributes[.shadow] = textShadow
        }
        return NSAttributedString(string: text, attributes: attributes)
    }

    static func snapshot(
        text: String,
        bounds: CGSize,
        fontSize: CGFloat,
        weight: UIFont.Weight = .heavy
    ) -> BrowserOverlayVerticalTextLayoutSnapshot {
        guard !text.isEmpty, bounds.width > 0, bounds.height > 0,
              fontSize > 0
        else {
            return BrowserOverlayVerticalTextLayoutSnapshot(
                visibleUTF16Range: NSRange(location: 0, length: 0),
                utf16Length: text.utf16.count,
                lineOrigins: [],
                paintedInkBounds: .zero,
                availableBounds: CGRect(origin: .zero, size: bounds),
                usesVerticalForms: true,
                progressesRightToLeft: true
            )
        }
        let frame = makeFrame(
            attributedString: attributedString(
                text: text,
                fontSize: fontSize,
                weight: weight
            ),
            bounds: bounds
        )
        let visibleRange = CTFrameGetVisibleStringRange(frame)
        let lines = CTFrameGetLines(frame)
        let lineCount = CFArrayGetCount(lines)
        var origins = Array(
            repeating: CGPoint.zero,
            count: lineCount
        )
        if lineCount > 0 {
            CTFrameGetLineOrigins(
                frame,
                CFRange(location: 0, length: 0),
                &origins
            )
        }
        let inkBounds = verticalInkBounds(in: frame)
        let horizontalOffset = centeredHorizontalOffset(
            inkBounds: inkBounds,
            boundsWidth: bounds.width
        )
        let paintedInkBounds = inkBounds.offsetBy(
            dx: horizontalOffset,
            dy: 0
        )
        return BrowserOverlayVerticalTextLayoutSnapshot(
            visibleUTF16Range: NSRange(
                location: max(0, visibleRange.location),
                length: max(0, visibleRange.length)
            ),
            utf16Length: text.utf16.count,
            lineOrigins: origins,
            paintedInkBounds: paintedInkBounds,
            availableBounds: CGRect(origin: .zero, size: bounds),
            usesVerticalForms: true,
            progressesRightToLeft: true
        )
    }

    static func fits(
        text: String,
        available: CGSize,
        fontSize: CGFloat,
        weight: UIFont.Weight
    ) -> Bool {
        snapshot(
            text: text,
            bounds: available,
            fontSize: fontSize,
            weight: weight
        ).fits
    }

    static func draw(
        text: String,
        in rect: CGRect,
        context: CGContext,
        fontSize: CGFloat,
        weight: UIFont.Weight,
        foregroundColor: UIColor?,
        textShadow: NSShadow?
    ) {
        guard !text.isEmpty, rect.width > 0, rect.height > 0 else { return }
        let attributed = attributedString(
            text: text,
            fontSize: fontSize,
            weight: weight,
            foregroundColor: foregroundColor,
            textShadow: textShadow
        )
        let frame = makeFrame(
            attributedString: attributed,
            bounds: rect.size
        )
        let inkBounds = verticalInkBounds(in: frame)
        let horizontalOffset = centeredHorizontalOffset(
            inkBounds: inkBounds,
            boundsWidth: rect.width
        )

        context.saveGState()
        // The card keeps masksToBounds disabled so its c1 drop shadow can
        // remain visible. Clip only this text pass to the label's content
        // rectangle, preventing a Core Text column or glyph overhang from
        // escaping the card while leaving the outer shadow untouched.
        context.clip(to: rect)
        context.translateBy(
            x: rect.minX + horizontalOffset,
            y: rect.maxY
        )
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    private static func makeFrame(
        attributedString: NSAttributedString,
        bounds: CGSize
    ) -> CTFrame {
        let framesetter = CTFramesetterCreateWithAttributedString(
            attributedString
        )
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: bounds))
        let attributes: [CFString: Any] = [
            kCTFrameProgressionAttributeName:
                CTFrameProgression.rightToLeft.rawValue,
        ]
        return CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: 0),
            path,
            attributes as CFDictionary
        )
    }

    private static func origins(in frame: CTFrame) -> [CGPoint] {
        let lineCount = CFArrayGetCount(CTFrameGetLines(frame))
        guard lineCount > 0 else { return [] }
        var origins = Array(repeating: CGPoint.zero, count: lineCount)
        CTFrameGetLineOrigins(
            frame,
            CFRange(location: 0, length: 0),
            &origins
        )
        return origins
    }

    /// CTLine glyph bounds use the line's horizontal coordinates even when
    /// the frame progresses vertically. For a vertical line, local X maps to
    /// frame Y (in reverse) and local Y maps to frame X. Using just the line
    /// origins plus `fontSize` shifted the left-most column baseline to zero,
    /// leaving its negative glyph-side bearing outside narrow cards.
    private static func verticalInkBounds(in frame: CTFrame) -> CGRect {
        let lines = CTFrameGetLines(frame)
        let lineCount = CFArrayGetCount(lines)
        guard lineCount > 0 else { return .zero }
        let lineOrigins = origins(in: frame)
        var union = CGRect.null
        for index in 0..<lineCount {
            let line = unsafeBitCast(
                CFArrayGetValueAtIndex(lines, index),
                to: CTLine.self
            )
            let local = CTLineGetBoundsWithOptions(
                line,
                [.useGlyphPathBounds, .excludeTypographicLeading]
            )
            guard !local.isNull,
                  local.width > 0,
                  local.height > 0
            else { continue }
            let origin = lineOrigins[index]
            let vertical = CGRect(
                x: origin.x + local.minY,
                y: origin.y - local.maxX,
                width: local.height,
                height: local.width
            )
            union = union.union(vertical)
        }
        return union.isNull ? .zero : union
    }

    private static func centeredHorizontalOffset(
        inkBounds: CGRect,
        boundsWidth: CGFloat
    ) -> CGFloat {
        guard !inkBounds.isNull, inkBounds.width > 0 else { return 0 }
        let targetMinimumX = max(0, (boundsWidth - inkBounds.width) / 2)
        return targetMinimumX - inkBounds.minX
    }
}

enum BrowserOverlayVerticalTextPainter {
    static func text(
        for item: BrowserOverlayItem,
        content: BrowserOverlayCardContent,
        mode: IPhoneOverlayMode
    ) -> String? {
        guard content.displayed.vertical else { return nil }
        guard let translatedText = item.translatedText else {
            return item.sourceText
        }
        switch mode {
        case .translateOnly:
            return translatedText
        case .originalAndTranslation:
            // Preserve the established dual-language payload contract. c1's
            // DOM renderer receives the already composed display variant for
            // this mode, including its explicit source/translation separator.
            return content.displayed.displayText
        case .subtitle, .sidePanel:
            return nil
        }
    }
}

struct BrowserOverlayCardContent: Equatable {
    let source: BrowserOverlayDisplayVariant
    let translated: BrowserOverlayDisplayVariant
    let hasTranslation: Bool
    let singleVerticalColumn: Bool

    static func make(
        item: BrowserOverlayItem,
        mode: IPhoneOverlayMode,
        sourceVertical: Bool,
        translatedVertical: Bool
    ) -> Self {
        let sourceDisplay = sourceVertical
            ? BrowserOverlayTextFlow.verticalized(item.sourceText)
            : item.sourceText
        let source = BrowserOverlayDisplayVariant.plain(
            sourceDisplay,
            vertical: sourceVertical
        )
        guard let translation = item.translatedText else {
            return Self(
                source: source,
                translated: source,
                hasTranslation: false,
                singleVerticalColumn:
                    (item.sourceSingleVerticalColumn ??
                        (item.sourceOrientation == .vertical)) &&
                    sourceVertical &&
                    BrowserOverlayTextFlow.isSingleLogicalLine(
                        item.sourceText
                    )
            )
        }

        let translatedDisplay = translatedVertical
            ? BrowserOverlayTextFlow.verticalized(translation)
            : translation
        let translated: BrowserOverlayDisplayVariant
        if mode == .originalAndTranslation {
            let dualSource = translatedVertical
                ? BrowserOverlayTextFlow.verticalized(item.sourceText)
                : item.sourceText
            translated = BrowserOverlayDisplayVariant(
                content: .originalAndTranslation(
                    source: dualSource,
                    translation: translatedDisplay,
                    separator: translatedVertical ? "\n\n" : "\n"
                ),
                vertical: translatedVertical
            )
        } else {
            translated = .plain(
                translatedDisplay,
                vertical: translatedVertical
            )
        }
        return Self(
            source: source,
            translated: translated,
            hasTranslation: true,
            singleVerticalColumn:
                (item.sourceSingleVerticalColumn ??
                    (item.sourceOrientation == .vertical)) &&
                sourceVertical && translatedVertical &&
                BrowserOverlayTextFlow.isSingleLogicalLine(item.sourceText)
        )
    }

    /// Korean normally reads horizontally, but a dense row of narrow manga
    /// columns can require much more displacement than the source geometry.
    /// Offer a vertical alternative only for translated replacement cards;
    /// the global direction selector below still keeps horizontal text unless
    /// this alternative removes an intrinsic card collision.
    static func adaptiveVerticalCandidate(
        item: BrowserOverlayItem,
        current: Self,
        mode: IPhoneOverlayMode,
        textPlacement: IPhoneOverlayTextPlacement,
        sourceVertical: Bool,
        sourceRect: CGRect
    ) -> Self? {
        guard mode == .translateOnly,
              textPlacement == .replace,
              sourceVertical,
              current.hasTranslation,
              !current.displayed.vertical,
              sourceRect.height >= sourceRect.width * 1.8,
              let translatedText = item.translatedText,
              BrowserOverlayTextFlow.wrappingScript(for: translatedText) ==
                .korean
        else { return nil }
        return make(
            item: item,
            mode: mode,
            sourceVertical: sourceVertical,
            translatedVertical: true
        )
    }

    var displayed: BrowserOverlayDisplayVariant {
        hasTranslation ? translated : source
    }

}

struct BrowserOverlayFontReference: Equatable {
    let fontSize: CGFloat
    let insets: UIEdgeInsets
    var additionalLines: Int = 1
    var exclusionRects: [CGRect] = []
    var fallbackFontSize: CGFloat? = nil
    var fallbackInsets: UIEdgeInsets? = nil
    var allowsEmergencyWordBreak: Bool = false
}

struct BrowserOverlayCardLayout: Equatable {
    let rect: CGRect
    let maximumFontSize: CGFloat
    let contentInsets: UIEdgeInsets
    var smallTextReference: BrowserOverlayFontReference? = nil
}

struct BrowserOverlayCardTextInsets {
    static let regular = UIEdgeInsets(
        top: 4,
        left: 6,
        bottom: 4,
        right: 6
    )
    static let singleVerticalColumn = UIEdgeInsets(
        top: 0.5,
        left: 0.5,
        bottom: 0.5,
        right: 0.5
    )
}

struct BrowserOverlayLayoutPlanner {
    private struct JointPackingState {
        var placements: [Int: CGRect]
        var overlapPairs: Int
        var overlapArea: CGFloat
        var maximumSquaredDisplacement: CGFloat
        var totalSquaredDisplacement: CGFloat
        var totalHorizontalDisplacement: CGFloat
        var totalVerticalDisplacement: CGFloat
    }

    /// Match the desktop auto-fit floor. The previous 11-point mobile-only
    /// floor expanded compact cards beyond their OCR bbox and hid nearby text.
    static let minimumAutoFontSize: CGFloat = 7
    /// Dense manga translations may contract this far, but never below it.
    /// This is intentionally lower than the regular auto-fit floor so compact
    /// horizontal Hangul stays near its OCR source instead of covering panels.
    static let minimumReadableHorizontalFontSize: CGFloat = 5
    static let minimumRenderedFontSize: CGFloat = 5
    static let maximumAutoFontSize: CGFloat = 32
    private static let minimumConstrainedMangaFontSize: CGFloat = 5
    private static let minimumSingleVerticalColumnFontSize: CGFloat = 1

    /// Pick vertical Korean only where it prevents the intrinsic cards from
    /// colliding. This happens before positional packing, so changing writing
    /// direction can remove the reason a card would otherwise be thrown far
    /// from its OCR bbox. A no-collision horizontal layout is never changed.
    static func adaptiveVerticalTranslationIndices(
        horizontalLayouts: [BrowserOverlayCardLayout],
        verticalLayouts: [Int: BrowserOverlayCardLayout],
        eligibleIndices: Set<Int>? = nil
    ) -> Set<Int> {
        guard horizontalLayouts.count > 1,
              !verticalLayouts.isEmpty
        else { return [] }

        struct Score {
            let pairs: Int
            let area: CGFloat
        }
        func score(_ rects: [CGRect]) -> Score {
            let geometry = rects.map(BrowserOverlayCollisionGeometry.init)
            let areas = rects.map { $0.width * $0.height }
            var pairs = 0
            var area: CGFloat = 0
            for left in rects.indices {
                for right in (left + 1)..<rects.count {
                    let overlap = geometry[left].overlapArea(with: geometry[right], minimumExtent: 0.25)
                    let smallerArea = min(areas[left], areas[right])
                    guard overlap > 0,
                          smallerArea > 0,
                          overlap >=
                            smallerArea * 0.5
                    else { continue }
                    pairs += 1
                    area += overlap
                }
            }
            return Score(pairs: pairs, area: area)
        }
        func isBetter(_ candidate: Score, than current: Score) -> Bool {
            if candidate.pairs != current.pairs {
                return candidate.pairs < current.pairs
            }
            return candidate.area + 0.25 < current.area
        }

        var rects = horizontalLayouts.map(\.rect)
        var selected = Set<Int>()
        let candidateIndices = verticalLayouts.keys.sorted()
        var currentScore = score(rects)
        guard currentScore.pairs > 0 else { return [] }

        // Coordinate descent is deterministic and intentionally conservative:
        // every accepted direction change must immediately improve the full
        // page's collision score. Re-evaluation lets several adjacent columns
        // verticalize together without forcing unrelated translations to do so.
        while true {
            var bestIndex: Int?
            var bestScore = currentScore
            for index in candidateIndices
            where !selected.contains(index) {
                guard rects.indices.contains(index),
                      let alternative = verticalLayouts[index]?.rect,
                      eligibleIndices?.contains(index) ?? true
                else { continue }
                var trial = rects
                trial[index] = alternative
                let trialScore = score(trial)
                if isBetter(trialScore, than: bestScore) {
                    bestIndex = index
                    bestScore = trialScore
                }
            }
            guard let bestIndex,
                  let alternative = verticalLayouts[bestIndex]?.rect
            else { break }
            rects[bestIndex] = alternative
            selected.insert(bestIndex)
            currentScore = bestScore
        }
        return selected
    }

    /// Run the complete horizontal packing pass first and expose only cards
    /// whose centers actually leave their source-anchored intrinsic position
    /// by at least 24 points. Minor overlap and short local shifts therefore
    /// keep the target language horizontal.
    static func severelyDisplacedTranslationIndices(
        intrinsicLayouts: [BrowserOverlayCardLayout],
        sources: [CGRect],
        variants: [BrowserOverlayDisplayVariant],
        settings: IPhoneOverlaySettings,
        viewport: CGSize,
        sourceVerticals: [Bool],
        singleVerticalColumns: [Bool],
        placementBounds: CGRect,
        allowsDetachedPlacements: [Bool],
        measurementCache: BrowserOverlayTextMeasurementCache? = nil
    ) -> Set<Int> {
        let count = intrinsicLayouts.count
        guard count > 1,
              sources.count == count,
              variants.count == count,
              sourceVerticals.count == count,
              singleVerticalColumns.count == count
        else { return [] }

        var occupied: [CGRect] = []
        var planned = Array<BrowserOverlayCardLayout?>(
            repeating: nil,
            count: count
        )
        for index in packingOrder(intrinsicLayouts) {
            let reservedSources = sources.indices.compactMap {
                $0 == index ? nil : sources[$0]
            }
            let layout = resolvePositionedLayout(
                intrinsicLayouts[index],
                source: sources[index],
                variants: [variants[index]],
                settings: settings,
                viewport: viewport,
                occupied: occupied,
                sourceVertical: sourceVerticals[index],
                singleVerticalColumn: singleVerticalColumns[index],
                reservedSources: reservedSources,
                measurementCache: measurementCache
            )
            guard !layout.rect.isNull,
                  layout.rect.width > 0,
                  layout.rect.height > 0
            else { continue }
            planned[index] = layout
            occupied.append(layout.rect)
        }
        let concrete = planned.compactMap { $0 }
        guard concrete.count == count else { return [] }
        let final = relaxingCardPositions(
            concrete,
            sources: sources,
            sourceVerticals: sourceVerticals,
            viewport: viewport,
            placementBounds: placementBounds,
            preferredRects: intrinsicLayouts.map(\.rect),
            allowsDetachedPlacements: allowsDetachedPlacements
        )
        // Vertical target text is a last resort, not a normal dense-row
        // packing tool. Require an escape larger than roughly one quarter of
        // an iPhone-width page before even offering that writing direction.
        let minimumDistance: CGFloat = 120
        return Set(final.indices.filter { index in
            guard allowsDetachedPlacements.indices.contains(index),
                  allowsDetachedPlacements[index]
            else { return false }
            let dx = final[index].rect.midX - intrinsicLayouts[index].rect.midX
            let dy = final[index].rect.midY - intrinsicLayouts[index].rect.midY
            return hypot(dx, dy) >= minimumDistance
        })
    }

    /// Greedy placement is order-sensitive. Give the cards that need the
    /// largest envelope first choice, then fit smaller cards around them.
    /// Returning indices keeps payload and accessibility order independent
    /// from the packing order.
    static func packingOrder(
        _ intrinsicLayouts: [BrowserOverlayCardLayout]
    ) -> [Int] {
        intrinsicLayouts.indices.sorted { left, right in
            let leftRect = intrinsicLayouts[left].rect
            let rightRect = intrinsicLayouts[right].rect
            let leftArea = leftRect.width * leftRect.height
            let rightArea = rightRect.width * rightRect.height
            if abs(leftArea - rightArea) > 0.25 {
                return leftArea > rightArea
            }
            let leftLongestSide = max(leftRect.width, leftRect.height)
            let rightLongestSide = max(rightRect.width, rightRect.height)
            if abs(leftLongestSide - rightLongestSide) > 0.25 {
                return leftLongestSide > rightLongestSide
            }
            return left < right
        }
    }

    /// Greedy placement can leave an earlier card in a position that blocks a
    /// later neighbor. Revisit every card against the complete placed set and
    /// accept only moves that reduce positive-area overlap. Sizes, fonts,
    /// viewport bounds, and full source coverage are preserved whenever the
    /// OCR boxes permit it. Translation-only callers can opt into a detached
    /// fallback, but it must not leave a blank replacement surface behind.
    static func relaxingCardPositions(
        _ layouts: [BrowserOverlayCardLayout],
        sources: [CGRect],
        sourceVerticals: [Bool]? = nil,
        viewport: CGSize,
        placementBounds: CGRect? = nil,
        preferredRects: [CGRect]? = nil,
        allowsDetachedPlacements: [Bool] = []
    ) -> [BrowserOverlayCardLayout] {
        guard layouts.count > 1, layouts.count == sources.count else {
            return layouts
        }

        let viewportRect = CGRect(origin: .zero, size: viewport)
        let requestedPlacementBounds = placementBounds ?? viewportRect
        let effectivePlacementBounds = requestedPlacementBounds
            .standardized
            .intersection(viewportRect)
        guard !effectivePlacementBounds.isNull,
              effectivePlacementBounds.width > 0,
              effectivePlacementBounds.height > 0
        else { return layouts }
        let effectivePreferredRects: [CGRect]
        if let preferredRects, preferredRects.count == layouts.count {
            effectivePreferredRects = preferredRects
        } else {
            effectivePreferredRects = layouts.map(\.rect)
        }

        let jointlyPacked = jointlyPackingOverlappingClusters(
            layouts,
            sources: sources,
            sourceVerticals: sourceVerticals,
            viewport: viewport,
            placementBounds: effectivePlacementBounds,
            preferredRects: effectivePreferredRects,
            allowsDetachedPlacements: allowsDetachedPlacements
        )
        if !hasAnyCardOverlap(jointlyPacked) {
            return jointlyPacked
        }

        func overlapMetrics(
            _ candidates: [BrowserOverlayCardLayout]
        ) -> (pairs: Int, area: CGFloat, displacement: CGFloat) {
            var pairs = 0
            var area: CGFloat = 0
            for left in candidates.indices {
                for right in candidates.indices where right > left {
                    let intersection = candidates[left].rect.intersection(
                        candidates[right].rect
                    )
                    guard !intersection.isNull,
                          intersection.width > 0.25,
                          intersection.height > 0.25
                    else { continue }
                    pairs += 1
                    area += intersection.width * intersection.height
                }
            }
            let displacement = candidates.indices.reduce(CGFloat.zero) {
                total, index in
                let dx = candidates[index].rect.midX - layouts[index].rect.midX
                let dy = candidates[index].rect.midY - layouts[index].rect.midY
                return total + dx * dx + dy * dy
            }
            return (pairs, area, displacement)
        }

        func reducesOverlap(
            _ candidate: (
                pairs: Int,
                area: CGFloat,
                displacement: CGFloat
            ),
            over current: (
                pairs: Int,
                area: CGFloat,
                displacement: CGFloat
            )
        ) -> Bool {
            if candidate.pairs != current.pairs {
                return candidate.pairs < current.pairs
            }
            if abs(candidate.area - current.area) > 0.25 {
                return candidate.area < current.area
            }
            return false
        }

        func isBetterCandidate(
            _ candidate: (
                pairs: Int,
                area: CGFloat,
                displacement: CGFloat
            ),
            than current: (
                pairs: Int,
                area: CGFloat,
                displacement: CGFloat
            )
        ) -> Bool {
            if reducesOverlap(candidate, over: current) {
                return true
            }
            guard candidate.pairs == current.pairs,
                  abs(candidate.area - current.area) <= 0.25
            else { return false }
            return candidate.displacement + 0.25 < current.displacement
        }

        var current = layouts
        for _ in 0..<(layouts.count * 4) {
            if Task.isCancelled { return current }
            let currentMetrics = overlapMetrics(current)
            guard currentMetrics.pairs > 0 else { break }
            var best = current
            var bestMetrics = currentMetrics
            for index in current.indices {
                let otherRects = current.indices.compactMap {
                    $0 == index ? nil : current[$0].rect
                }
                let reservedSources = sources.indices.compactMap {
                    $0 == index ? nil : sources[$0]
                }
                let resolved = resolveCollision(
                    layouts[index].rect,
                    source: clippedSource(sources[index], viewport: viewport),
                    occupied: otherRects,
                    reservedSources: reservedSources,
                    viewport: viewport
                )
                var trial = current
                trial[index] = BrowserOverlayCardLayout(
                    rect: resolved,
                    maximumFontSize: current[index].maximumFontSize,
                    contentInsets: current[index].contentInsets
                )
                let trialMetrics = overlapMetrics(trial)
                if isBetterCandidate(trialMetrics, than: bestMetrics) {
                    best = trial
                    bestMetrics = trialMetrics
                }

                let allowsDetached =
                    allowsDetachedPlacements.indices.contains(index) &&
                    allowsDetachedPlacements[index]
                guard allowsDetached,
                      let detached = resolveDetachedCollision(
                          layouts[index].rect,
                          source: clippedSource(
                              sources[index],
                              viewport: viewport
                          ),
                          occupied: otherRects,
                          placementBounds: effectivePlacementBounds
                      )
                else { continue }
                var detachedTrial = current
                detachedTrial[index] = BrowserOverlayCardLayout(
                    rect: detached,
                    maximumFontSize: current[index].maximumFontSize,
                    contentInsets: current[index].contentInsets
                )
                let detachedMetrics = overlapMetrics(detachedTrial)
                if isBetterCandidate(detachedMetrics, than: bestMetrics) {
                    best = detachedTrial
                    bestMetrics = detachedMetrics
                }
            }
            guard reducesOverlap(bestMetrics, over: currentMetrics) else {
                break
            }
            current = best
        }
        return current
    }

    /// Recover exposed original lettering only when the extra surface stays local
    /// and cannot cover another OCR region or translation. Detached cards are
    /// deliberately excluded: joining those to their source would paint artwork.
    static func restoringSourceCoverage(
        _ layouts: [BrowserOverlayCardLayout],
        sources: [CGRect],
        bounds: CGRect,
        enabled: Bool
    ) -> [BrowserOverlayCardLayout] {
        guard enabled, layouts.count == sources.count else { return layouts }
        var result = layouts
        for index in result.indices {
            let layout = result[index]
            let source = sources[index].intersection(bounds)
            let intersection = layout.rect.intersection(source)
            guard !source.isNull, source.width > 0, source.height > 0,
                  !intersection.isNull,
                  intersection.width * intersection.height >= source.width * source.height * 0.5,
                  !layout.rect.contains(source)
            else { continue }
            let candidate = layout.rect.union(source)
            guard bounds.contains(candidate),
                  candidate.width * candidate.height <= layout.rect.width * layout.rect.height * 1.75
            else { continue }
            let obstructsNeighbor = result.indices.contains { other in
                guard other != index else { return false }
                return [result[other].rect, sources[other]].contains { obstacle in
                    let overlap = candidate.intersection(obstacle)
                    return !overlap.isNull && overlap.width > 0.25 && overlap.height > 0.25
                }
            }
            guard !obstructsNeighbor else { continue }
            result[index] = BrowserOverlayCardLayout(
                rect: candidate, maximumFontSize: layout.maximumFontSize,
                contentInsets: layout.contentInsets
            )
        }
        return result
    }

    /// Solve every connected overlap cluster as one bounded assignment. The
    /// previous coordinate-descent fallback could only move one card at a
    /// time, so it anchored the rest and threw a single translation far away.
    /// Keeping several partial assignments lets neighboring cards share the
    /// displacement and selects the zero-overlap result with the least total
    /// squared movement from the original layout.
    private static func jointlyPackingOverlappingClusters(
        _ layouts: [BrowserOverlayCardLayout],
        sources: [CGRect],
        sourceVerticals: [Bool]?,
        viewport: CGSize,
        placementBounds: CGRect,
        preferredRects: [CGRect],
        allowsDetachedPlacements: [Bool]
    ) -> [BrowserOverlayCardLayout] {
        var result = layouts
        let clusters = overlapClusters(preferredRects)
        for cluster in clusters where cluster.count > 1 {
            if Task.isCancelled { return result }
            // Irregular real pages form several medium clusters; each used to
            // keep 192 states even when the whole page contained 29+ cards.
            // Bound those combinations as well as the single dense-cluster case.
            let beamWidth = cluster.count > 24 ? 4 : (cluster.count > 12 ? 16 : (cluster.count > 4 ? 32 : 192))
            let candidateLimit = cluster.count > 24 ? 24 : (cluster.count > 12 ? 48 : (cluster.count > 4 ? 96 : 160))
            guard cluster.contains(where: { index in
                allowsDetachedPlacements.indices.contains(index) &&
                    allowsDetachedPlacements[index]
            }) else { continue }
            let external = result.indices.compactMap { index in
                cluster.contains(index) ? nil : result[index].rect
            }
            let externalGeometry = external.map(BrowserOverlayCollisionGeometry.init)
            let preferredClusterRects = cluster.map { preferredRects[$0] }
            let clusterBounds = preferredClusterRects.dropFirst().reduce(
                preferredClusterRects[0]
            ) { $0.union($1) }
            let horizontalChain =
                clusterBounds.width >= clusterBounds.height * 1.35
            let verticalChain =
                clusterBounds.height >= clusterBounds.width * 1.35
            let order = cluster.sorted { left, right in
                if horizontalChain,
                   abs(preferredRects[left].midX -
                       preferredRects[right].midX) > 0.25 {
                    return preferredRects[left].midX <
                        preferredRects[right].midX
                }
                if verticalChain,
                   abs(preferredRects[left].midY -
                       preferredRects[right].midY) > 0.25 {
                    return preferredRects[left].midY <
                        preferredRects[right].midY
                }
                let leftArea = layouts[left].rect.width *
                    layouts[left].rect.height
                let rightArea = layouts[right].rect.width *
                    layouts[right].rect.height
                if abs(leftArea - rightArea) > 0.25 {
                    return leftArea > rightArea
                }
                return left < right
            }
            var beam = [JointPackingState(
                placements: [:],
                overlapPairs: 0,
                overlapArea: 0,
                maximumSquaredDisplacement: 0,
                totalSquaredDisplacement: 0,
                totalHorizontalDisplacement: 0,
                totalVerticalDisplacement: 0
            )]
            for index in order {
                if Task.isCancelled { return result }
                let comparisonKeys = ((beam.first.map { Array($0.placements.keys) } ?? []) + [index]).sorted()
                let canDetach =
                    allowsDetachedPlacements.indices.contains(index) &&
                    allowsDetachedPlacements[index]
                let baseCandidates = jointPackingCandidates(
                    for: index,
                    cluster: cluster,
                    layouts: layouts,
                    preferredRects: preferredRects,
                    source: clippedSource(
                        sources[index],
                        viewport: viewport
                    ),
                    placementBounds: placementBounds,
                    canDetach: canDetach
                )
                var next: [JointPackingState] = []
                next.reserveCapacity(
                    min(30_720, beam.count * baseCandidates.count)
                )
                for state in beam {
                    let placed = Array(state.placements.values)
                    let candidates = orderedUniquePackingCandidates(
                        baseCandidates + dynamicPackingCandidates(
                            for: index,
                            layouts: layouts,
                            preferredRects: preferredRects,
                            placementBounds: placementBounds,
                            placed: placed
                        ),
                        preferredRect: preferredRects[index],
                        limit: candidateLimit
                    )
                    let intersections = placed.map(BrowserOverlayCollisionGeometry.init) + externalGeometry
                    for candidate in candidates {
                        var addedPairs = 0
                        var addedArea: CGFloat = 0
                        let geometry = BrowserOverlayCollisionGeometry(candidate)
                        for obstacle in intersections {
                            let area = geometry.overlapArea(with: obstacle, minimumExtent: 0.25)
                            guard area > 0 else { continue }
                            addedPairs += 1
                            addedArea += area
                        }
                        let dx = candidate.midX - preferredRects[index].midX
                        let dy = candidate.midY - preferredRects[index].midY
                        var placements = state.placements
                        placements[index] = candidate
                        next.append(JointPackingState(
                            placements: placements,
                            overlapPairs: state.overlapPairs + addedPairs,
                            overlapArea: state.overlapArea + addedArea,
                            maximumSquaredDisplacement: max(
                                state.maximumSquaredDisplacement,
                                dx * dx + dy * dy
                            ),
                            totalSquaredDisplacement:
                                state.totalSquaredDisplacement + dx * dx + dy * dy,
                            totalHorizontalDisplacement:
                                state.totalHorizontalDisplacement + dx,
                            totalVerticalDisplacement:
                                state.totalVerticalDisplacement + dy
                        ))
                    }
                }
                next.sort { jointPackingStateIsBetter($0, $1, placementKeys: comparisonKeys) }
                if next.count > beamWidth {
                    next.removeLast(next.count - beamWidth)
                }
                beam = next
                if beam.isEmpty { break }
            }
            guard let best = beam.min(by: { jointPackingStateIsBetter($0, $1) }),
                  best.placements.count == cluster.count
            else { continue }
            let currentOverlap = overlapScore(
                cluster.map { result[$0].rect },
                external: external
            )
            var currentState = JointPackingState(
                placements: [:],
                overlapPairs: currentOverlap.pairs,
                overlapArea: currentOverlap.area,
                maximumSquaredDisplacement: 0,
                totalSquaredDisplacement: 0,
                totalHorizontalDisplacement: 0,
                totalVerticalDisplacement: 0
            )
            for index in cluster {
                let rect = result[index].rect
                let dx = rect.midX - preferredRects[index].midX
                let dy = rect.midY - preferredRects[index].midY
                currentState.placements[index] = rect
                currentState.maximumSquaredDisplacement = max(
                    currentState.maximumSquaredDisplacement,
                    dx * dx + dy * dy
                )
                currentState.totalSquaredDisplacement += dx * dx + dy * dy
                currentState.totalHorizontalDisplacement += dx
                currentState.totalVerticalDisplacement += dy
            }
            if jointPackingStateIsBetter(best, currentState) {
                for index in cluster {
                    guard let rect = best.placements[index] else { continue }
                    result[index] = BrowserOverlayCardLayout(
                        rect: rect,
                        maximumFontSize: result[index].maximumFontSize,
                        contentInsets: result[index].contentInsets
                    )
                }
            }
            // Even a non-overlapping greedy result can have crossed the source
            // order by ejecting one card beyond its neighbor. Always run the
            // source-row pass; it restores the original X order and lets the
            // neighboring cards share the horizontal displacement.
            guard let sourceBand = horizontallyPackedSourceBand(
                cluster: cluster,
                sources: sources,
                sourceVerticals: sourceVerticals,
                layouts: result,
                preferredRects: preferredRects,
                placementBounds: placementBounds,
                external: external
            ) else { continue }
            // A caption stack can share a cluster with nearby credit columns.
            // The row-order fallback must not replace a collision-free, small
            // vertical nudge with a much longer sideways move. Keep its legacy
            // reading-order repair for vertical manga columns.
            if let sourceVerticals, sourceVerticals.count == sources.count,
               cluster.allSatisfy({ !sourceVerticals[$0] }),
               !BrowserOverlayCollisionGeometry.hasOverlap(in: cluster.map { result[$0].rect }, external: external) {
                func movement(_ rect: CGRect, at index: Int) -> CGFloat {
                    let dx = rect.midX - preferredRects[index].midX
                    let dy = rect.midY - preferredRects[index].midY
                    return dx * dx + dy * dy
                }
                let currentMovement = cluster.reduce(CGFloat.zero) { $0 + movement(result[$1].rect, at: $1) }
                let rowMovement = sourceBand.reduce(CGFloat.zero) { $0 + movement($1.value, at: $1.key) }
                if rowMovement > currentMovement + 0.25 { continue }
            }
            for (index, rect) in sourceBand {
                result[index] = BrowserOverlayCardLayout(
                    rect: rect,
                    maximumFontSize: result[index].maximumFontSize,
                    contentInsets: result[index].contentInsets
                )
            }
        }
        return result
    }

    /// Dense manga dialogue often forms one visual row of tall vertical source
    /// columns. Once collision contraction makes their widths fit, keep every
    /// card on its source y and solve only x. Do not classify the row by its
    /// union aspect ratio: a short run of two or three tall columns is naturally
    /// taller than it is wide, but still needs to move together horizontally.
    private static func horizontallyPackedSourceBand(
        cluster: [Int],
        sources: [CGRect],
        sourceVerticals: [Bool]?,
        layouts: [BrowserOverlayCardLayout],
        preferredRects: [CGRect],
        placementBounds: CGRect,
        external: [CGRect]
    ) -> [Int: CGRect]? {
        let order = cluster.sorted {
            preferredRects[$0].midX < preferredRects[$1].midX
        }
        let spacing: CGFloat = 0.5
        func overlapsVertically(_ left: CGRect, _ right: CGRect) -> Bool {
            min(left.maxY, right.maxY) - max(left.minY, right.minY) > 0.25
        }

        // Only a source cluster classified as horizontal in one source column
        // can be a stack of caption lines. Unknown or mixed writing directions
        // retain the existing column-packing behavior.
        var horizontalCaptionColumn = sourceVerticals.map { orientations in
            orientations.count == sources.count && order.allSatisfy {
                !orientations[$0]
            }
        } ?? false
        if horizontalCaptionColumn {
            for (position, index) in order.enumerated() {
                for previous in order[..<position] {
                    let narrowerWidth = min(sources[index].width, sources[previous].width)
                    let overlapWidth = min(sources[index].maxX, sources[previous].maxX) -
                        max(sources[index].minX, sources[previous].minX)
                    if narrowerWidth <= 0 || overlapWidth < narrowerWidth * 0.75 {
                        horizontalCaptionColumn = false
                        break
                    }
                }
                if !horizontalCaptionColumn { break }
            }
        }
        if horizontalCaptionColumn {
            // Minimum height or insets can make distinct original lines touch.
            // Do not turn their padded envelopes into side-by-side columns.
            for (position, index) in order.enumerated() {
                let proposed = CGRect(
                    x: preferredRects[index].minX,
                    y: preferredRects[index].minY,
                    width: layouts[index].rect.width,
                    height: layouts[index].rect.height
                )
                for previous in order[..<position] {
                    let previousProposed = CGRect(
                        x: preferredRects[previous].minX,
                        y: preferredRects[previous].minY,
                        width: layouts[previous].rect.width,
                        height: layouts[previous].rect.height
                    )
                    if overlapsVertically(proposed, previousProposed),
                       !overlapsVertically(sources[index], sources[previous]) {
                        return nil
                    }
                }
            }
        }

        var row: [Int: CGRect] = [:]
        for (position, index) in order.enumerated() {
            let size = layouts[index].rect.size
            var x = preferredRects[index].midX - size.width / 2
            let y = preferredRects[index].minY
            let proposed = CGRect(x: x, y: y, width: size.width, height: size.height)
            for previous in order[..<position] {
                guard let previousRect = row[previous],
                      overlapsVertically(proposed, previousRect)
                else { continue }
                x = max(x, previousRect.maxX + spacing)
            }
            let rect = CGRect(
                x: x,
                y: y,
                width: size.width,
                height: size.height
            )
            row[index] = rect
        }
        guard let first = order.first,
              let firstRect = row[first]
        else { return nil }
        let rowRects = order.compactMap { row[$0] }
        let rowBounds = rowRects.dropFirst().reduce(firstRect) {
            $0.union($1)
        }
        let preferredRowRects = order.map { preferredRects[$0] }
        let preferredBounds = preferredRowRects.dropFirst().reduce(
            preferredRowRects[0]
        ) { $0.union($1) }
        let requestedDX = preferredBounds.midX - rowBounds.midX
        let dx = min(
            placementBounds.maxX - rowBounds.maxX,
            max(placementBounds.minX - rowBounds.minX, requestedDX)
        )
        if abs(dx) > 0.001 {
            for index in order {
                row[index] = row[index]?.offsetBy(dx: dx, dy: 0)
            }
        }
        // After correcting whole-row bias, use any remaining gutter to pull
        // each card toward its own source. Running this last avoids undoing
        // the local attachment with a second global recenter.
        for _ in 0..<2 {
            for (position, index) in order.enumerated() {
                guard let current = row[index] else { continue }
                var lowerX = placementBounds.minX
                for previous in order[..<position] {
                    guard let previousRect = row[previous],
                          overlapsVertically(current, previousRect)
                    else { continue }
                    lowerX = max(lowerX, previousRect.maxX + spacing)
                }
                var upperX = placementBounds.maxX - current.width
                for next in order[(position + 1)...] {
                    guard let nextRect = row[next],
                          overlapsVertically(current, nextRect)
                    else { continue }
                    upperX = min(
                        upperX,
                        nextRect.minX - spacing - current.width
                    )
                }
                guard lowerX <= upperX else { continue }
                let preferredX = preferredRects[index].midX -
                    current.width / 2
                row[index] = CGRect(
                    x: min(upperX, max(lowerX, preferredX)),
                    y: current.minY,
                    width: current.width,
                    height: current.height
                )
            }
        }
        let rects = order.compactMap { row[$0] }
        guard rects.count == order.count,
              // A row wider than the image cannot be recentered into it.
              // Reject that fallback instead of hiding the leading translation
              // beyond the viewport merely to achieve zero pairwise overlap.
              rects.allSatisfy({ placementBounds.contains($0) }),
              !BrowserOverlayCollisionGeometry.hasOverlap(in: rects, external: external)
        else { return nil }
        return row
    }

    private static func jointPackingStateIsBetter(
        _ left: JointPackingState,
        _ right: JointPackingState,
        placementKeys: [Int]? = nil
    ) -> Bool {
        if left.overlapPairs != right.overlapPairs {
            return left.overlapPairs < right.overlapPairs
        }
        if abs(left.overlapArea - right.overlapArea) > 0.25 {
            return left.overlapArea < right.overlapArea
        }
        // Minimize the movement paid by the whole cluster first. Squared
        // distance already makes a single far outlier expensive, while still
        // allowing a short chain shift into a neighbor's vacated bbox.
        if abs(
            left.totalSquaredDisplacement -
                right.totalSquaredDisplacement
        ) > 0.25 {
            return left.totalSquaredDisplacement <
                right.totalSquaredDisplacement
        }
        if abs(
            left.maximumSquaredDisplacement -
                right.maximumSquaredDisplacement
        ) > 0.25 {
            return left.maximumSquaredDisplacement <
                right.maximumSquaredDisplacement
        }
        let leftCount = CGFloat(max(1, left.placements.count))
        let rightCount = CGFloat(max(1, right.placements.count))
        let leftCentroidDrift =
            pow(left.totalHorizontalDisplacement / leftCount, 2) +
            pow(left.totalVerticalDisplacement / leftCount, 2)
        let rightCentroidDrift =
            pow(right.totalHorizontalDisplacement / rightCount, 2) +
            pow(right.totalVerticalDisplacement / rightCount, 2)
        if abs(leftCentroidDrift - rightCentroidDrift) > 0.25 {
            return leftCentroidDrift < rightCentroidDrift
        }
        let keys = placementKeys ?? Set(left.placements.keys)
            .union(right.placements.keys)
            .sorted()
        for key in keys {
            guard let leftRect = left.placements[key],
                  let rightRect = right.placements[key]
            else { continue }
            if abs(leftRect.minX - rightRect.minX) > 0.25 {
                return leftRect.minX < rightRect.minX
            }
            if abs(leftRect.minY - rightRect.minY) > 0.25 {
                return leftRect.minY < rightRect.minY
            }
        }
        return false
    }

    private static func overlapScore(
        _ rects: [CGRect],
        external: [CGRect] = []
    ) -> (pairs: Int, area: CGFloat) {
        let geometry = rects.map(BrowserOverlayCollisionGeometry.init)
        let obstacles = external.map(BrowserOverlayCollisionGeometry.init)
        var pairs = 0
        var area: CGFloat = 0
        for left in geometry.indices {
            for right in (left + 1)..<geometry.count {
                let overlap = geometry[left].overlapArea(with: geometry[right], minimumExtent: 0.25)
                guard overlap > 0 else { continue }
                pairs += 1
                area += overlap
            }
            for obstacle in obstacles {
                let overlap = geometry[left].overlapArea(with: obstacle, minimumExtent: 0.25)
                guard overlap > 0 else { continue }
                pairs += 1
                area += overlap
            }
        }
        return (pairs, area)
    }

    private static func hasAnyCardOverlap(
        _ layouts: [BrowserOverlayCardLayout]
    ) -> Bool {
        BrowserOverlayCollisionGeometry.hasOverlap(in: layouts.map(\.rect))
    }

    private static func overlapClusters(_ rects: [CGRect]) -> [[Int]] {
        // Cards separated by only a narrow gutter still constrain one
        // another's useful movement. Include those neighbors so a crowded row
        // can shift together instead of treating them as fixed obstacles and
        // ejecting only the final overlapping card.
        let interactionPadding: CGFloat = 24
        var remaining = Set(rects.indices)
        var clusters: [[Int]] = []
        while let seed = remaining.first {
            remaining.remove(seed)
            var cluster = [seed]
            var cursor = 0
            while cursor < cluster.count {
                let current = cluster[cursor]
                cursor += 1
                let neighbors = remaining.filter { index in
                    rects[current]
                        .insetBy(
                            dx: -interactionPadding,
                            dy: -interactionPadding
                        )
                        .intersects(rects[index])
                }
                for neighbor in neighbors {
                    remaining.remove(neighbor)
                    cluster.append(neighbor)
                }
            }
            clusters.append(cluster.sorted())
        }
        return clusters
    }

    private static func jointPackingCandidates(
        for index: Int,
        cluster: [Int],
        layouts: [BrowserOverlayCardLayout],
        preferredRects: [CGRect],
        source: CGRect,
        placementBounds: CGRect,
        canDetach: Bool
    ) -> [CGRect] {
        let layoutRect = layouts[index].rect
        let original = CGRect(
            x: preferredRects[index].midX - layoutRect.width / 2,
            y: preferredRects[index].midY - layoutRect.height / 2,
            width: layoutRect.width,
            height: layoutRect.height
        )
        guard canDetach else { return [original] }
        let spacing: CGFloat = 2
        guard placementBounds.width >= original.width,
              placementBounds.height >= original.height
        else { return [original] }
        let minimumX = placementBounds.minX
        let minimumY = placementBounds.minY
        let maximumX = placementBounds.maxX - original.width
        let maximumY = placementBounds.maxY - original.height
        let clusterRects = cluster.map { clusterIndex in
            let rect = layouts[clusterIndex].rect
            let preferred = preferredRects[clusterIndex]
            return CGRect(
                x: preferred.midX - rect.width / 2,
                y: preferred.midY - rect.height / 2,
                width: rect.width,
                height: rect.height
            )
        }
        var xSeeds: [CGFloat] = [
            original.minX,
            source.minX,
            source.midX - original.width / 2,
            source.maxX - original.width,
            minimumX,
            maximumX,
        ]
        var ySeeds: [CGFloat] = [
            original.minY,
            source.minY,
            source.midY - original.height / 2,
            source.maxY - original.height,
            minimumY,
            maximumY,
        ]
        for rect in clusterRects {
            // A jointly moved neighbor vacates its old bbox. Make that exact
            // slot available instead of offering only positions outside its
            // edges, which prevents short chain shifts through the cluster.
            xSeeds.append(rect.minX)
            xSeeds.append(rect.midX - original.width / 2)
            xSeeds.append(rect.maxX - original.width)
            xSeeds.append(rect.minX - original.width - spacing)
            xSeeds.append(rect.maxX + spacing)
            ySeeds.append(rect.minY)
            ySeeds.append(rect.midY - original.height / 2)
            ySeeds.append(rect.maxY - original.height)
            ySeeds.append(rect.minY - original.height - spacing)
            ySeeds.append(rect.maxY + spacing)
        }
        // A cluster of four equal cards needs three successive neighbor slots,
        // not merely the edge of one original card. Add a bounded lattice in
        // both axes so the beam can distribute the entire group around its
        // source centroid instead of ejecting the last card by one full height.
        for step in 1...cluster.count {
            let horizontalOffset = CGFloat(step) *
                (original.width + spacing)
            let verticalOffset = CGFloat(step) *
                (original.height + spacing)
            xSeeds.append(original.minX - horizontalOffset)
            xSeeds.append(original.minX + horizontalOffset)
            ySeeds.append(original.minY - verticalOffset)
            ySeeds.append(original.minY + verticalOffset)
        }
        // Also expose complete row/column slots from both placement edges.
        // Without these, an adjacent non-overlapping card can become a fixed
        // wall and the last card is offered only a distant perpendicular slot.
        for step in 0..<cluster.count {
            let horizontalOffset = CGFloat(step) *
                (original.width + spacing)
            let verticalOffset = CGFloat(step) *
                (original.height + spacing)
            xSeeds.append(minimumX + horizontalOffset)
            xSeeds.append(maximumX - horizontalOffset)
            ySeeds.append(minimumY + verticalOffset)
            ySeeds.append(maximumY - verticalOffset)
        }
        let xValues = uniqueValues(xSeeds).map {
            min(max(minimumX, $0), maximumX)
        }
        let yValues = uniqueValues(ySeeds).map {
            min(max(minimumY, $0), maximumY)
        }
        var candidates = xValues.flatMap { x in
            yValues.map { y in
                CGRect(
                    x: x,
                    y: y,
                    width: original.width,
                    height: original.height
                )
            }
        }
        candidates = orderedPackingCandidates(candidates, preferredRect: original)
        let alignedY = min(max(minimumY, original.minY), maximumY)
        let alignedX = min(max(minimumX, original.minX), maximumX)
        var alignedCandidates = xValues.map { x in
            CGRect(
                x: x,
                y: alignedY,
                width: original.width,
                height: original.height
            )
        }
        alignedCandidates.append(contentsOf: yValues.map { y in
            CGRect(
                x: alignedX,
                y: y,
                width: original.width,
                height: original.height
            )
        })
        alignedCandidates.sort { left, right in
            let leftDistance = hypot(
                left.midX - original.midX,
                left.midY - original.midY
            )
            let rightDistance = hypot(
                right.midX - original.midX,
                right.midY - original.midY
            )
            return leftDistance < rightDistance
        }
        return uniquePackingCandidatesInOrder(alignedCandidates + candidates, limit: 128)
    }

    /// Candidate slots created by earlier beam assignments cannot be known
    /// from the original geometry. Offer the exact four sides of every card
    /// already moved in this partial state so later cards can perform a short
    /// chain shift through the newly vacated/adjacent space.
    private static func dynamicPackingCandidates(
        for index: Int,
        layouts: [BrowserOverlayCardLayout],
        preferredRects: [CGRect],
        placementBounds: CGRect,
        placed: [CGRect]
    ) -> [CGRect] {
        let size = layouts[index].rect.size
        let preferred = preferredRects[index]
        let original = CGRect(
            x: preferred.midX - size.width / 2,
            y: preferred.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        let minimumX = placementBounds.minX
        let minimumY = placementBounds.minY
        let maximumX = placementBounds.maxX - size.width
        let maximumY = placementBounds.maxY - size.height
        guard maximumX >= minimumX, maximumY >= minimumY else { return [] }
        let spacing: CGFloat = 2
        var result: [CGRect] = []
        for neighbor in placed {
            let horizontalX = [
                neighbor.minX - size.width - spacing,
                neighbor.maxX + spacing,
            ]
            let horizontalY = [
                original.minY,
                neighbor.minY,
                neighbor.midY - size.height / 2,
                neighbor.maxY - size.height,
            ]
            for x in horizontalX {
                for y in horizontalY {
                    result.append(CGRect(
                        x: min(max(minimumX, x), maximumX),
                        y: min(max(minimumY, y), maximumY),
                        width: size.width,
                        height: size.height
                    ))
                }
            }
            let verticalY = [
                neighbor.minY - size.height - spacing,
                neighbor.maxY + spacing,
            ]
            let verticalX = [
                original.minX,
                neighbor.minX,
                neighbor.midX - size.width / 2,
                neighbor.maxX - size.width,
            ]
            for y in verticalY {
                for x in verticalX {
                    result.append(CGRect(
                        x: min(max(minimumX, x), maximumX),
                        y: min(max(minimumY, y), maximumY),
                        width: size.width,
                        height: size.height
                    ))
                }
            }
        }
        return result
    }

    /// Compute geometry once per candidate, retaining the exact existing
    /// comparator and stable input order during the much larger sort.
    static func orderedPackingCandidates(_ candidates: [CGRect], preferredRect: CGRect) -> [CGRect] {
        let center = CGPoint(x: preferredRect.midX, y: preferredRect.midY)
        return candidates.map { rect in
            let dx = rect.midX - center.x
            let dy = rect.midY - center.y
            return (rect: rect, distance: dx * dx + dy * dy, x: rect.minX, y: rect.minY)
        }.sorted { left, right in
            if abs(left.distance - right.distance) > 0.25 { return left.distance < right.distance }
            if abs(left.x - right.x) > 0.25 { return left.x < right.x }
            return left.y < right.y
        }.map(\.rect)
    }

    private static func orderedUniquePackingCandidates(
        _ candidates: [CGRect],
        preferredRect: CGRect,
        limit: Int
    ) -> [CGRect] {
        let ordered = orderedPackingCandidates(candidates, preferredRect: preferredRect)
        return uniquePackingCandidatesInOrder(ordered, limit: limit)
    }

    private struct PackingCell: Hashable {
        let x: CGFloat
        let y: CGFloat
    }

    /// Preserve the original first-wins 0.25-point rule without comparing each
    /// candidate against every accepted CGRect in every beam state.
    static func uniquePackingCandidatesInOrder(_ ordered: [CGRect], limit: Int) -> [CGRect] {
        var cells: [PackingCell: [CGPoint]] = [:]
        var unique: [CGRect] = []
        for candidate in ordered {
            let point = CGPoint(x: candidate.minX, y: candidate.minY)
            let cell = PackingCell(x: floor(point.x * 4), y: floor(point.y * 4))
            // Clamped candidates most often repeat their own cell. Probe it
            // first, preserving the same any-neighbour proximity predicate.
            var duplicate = cells[cell]?.contains(where: {
                abs($0.x - point.x) < 0.25 && abs($0.y - point.y) < 0.25
            }) == true
            for dx: CGFloat in [-1, 0, 1] where !duplicate {
                for dy: CGFloat in [-1, 0, 1] where dx != 0 || dy != 0 {
                    if cells[PackingCell(x: cell.x + dx, y: cell.y + dy)]?.contains(where: {
                        abs($0.x - point.x) < 0.25 && abs($0.y - point.y) < 0.25
                    }) == true {
                        duplicate = true
                        break
                    }
                }
                if duplicate { break }
            }
            guard !duplicate else { continue }
            unique.append(candidate)
            cells[cell, default: []].append(point)
            if unique.count == limit { break }
        }
        return unique
    }

    /// Source-containing placement has no solution when OCR boxes themselves
    /// overlap. Translated cards may use a nearby empty slot without creating
    /// a second, text-free card over the original location.
    private static func resolveDetachedCollision(
        _ candidate: CGRect,
        source: CGRect,
        occupied: [CGRect],
        placementBounds: CGRect
    ) -> CGRect? {
        guard placementBounds.width >= candidate.width,
              placementBounds.height >= candidate.height
        else { return nil }
        // Once a translated card has to detach, other OCR source boxes are no
        // longer useful obstacles: every one owns its own translated card.
        // Treating those narrow source columns as blocked space caused the
        // whole cluster to jump toward the viewport edges despite nearby gaps.
        let obstacles = occupied
        let spacing: CGFloat = 2
        let minimumX = placementBounds.minX
        let minimumY = placementBounds.minY
        let maximumX = placementBounds.maxX - candidate.width
        let maximumY = placementBounds.maxY - candidate.height
        let xValues = exactUniqueValues(uniqueValues([
            candidate.minX,
            source.minX,
            source.midX - candidate.width / 2,
            source.maxX - candidate.width,
            minimumX,
            maximumX,
        ] + obstacles.flatMap { other in
            [
                other.minX - candidate.width - spacing,
                other.maxX + spacing,
            ]
        }).map { min(max(minimumX, $0), maximumX) })
        let yValues = exactUniqueValues(uniqueValues([
            candidate.minY,
            source.minY,
            source.midY - candidate.height / 2,
            source.maxY - candidate.height,
            minimumY,
            maximumY,
        ] + obstacles.flatMap { other in
            [
                other.minY - candidate.height - spacing,
                other.maxY + spacing,
            ]
        }).map { min(max(minimumY, $0), maximumY) })
        return xValues.flatMap { x in
            yValues.map { y in
                CGRect(
                    x: x,
                    y: y,
                    width: candidate.width,
                    height: candidate.height
                )
            }
        }.filter { rect in
            return !hasVisualCollision(
                rect,
                occupied: occupied,
                reservedSources: []
            )
        }.min { left, right in
            let leftDX = left.midX - candidate.midX
            let leftDY = left.midY - candidate.midY
            let rightDX = right.midX - candidate.midX
            let rightDY = right.midY - candidate.midY
            return leftDX * leftDX + leftDY * leftDY <
                rightDX * rightDX + rightDY * rightDY
        }
    }

    static func plan(
        source: CGRect,
        text: String,
        vertical: Bool,
        settings: IPhoneOverlaySettings,
        viewport: CGSize,
        occupied: [CGRect],
        sourceVertical: Bool? = nil,
        singleVerticalColumn: Bool = false,
        reservedSources: [CGRect] = [],
        measurementCache: BrowserOverlayTextMeasurementCache? = nil
    ) -> BrowserOverlayCardLayout {
        plan(
            source: source,
            variants: [.plain(text, vertical: vertical)],
            settings: settings,
            viewport: viewport,
            occupied: occupied,
            sourceVertical: sourceVertical,
            singleVerticalColumn: singleVerticalColumn,
            reservedSources: reservedSources,
            measurementCache: measurementCache
        )
    }

    static func plan(
        source: CGRect,
        variants: [BrowserOverlayDisplayVariant],
        settings: IPhoneOverlaySettings,
        viewport: CGSize,
        occupied: [CGRect],
        sourceVertical: Bool? = nil,
        singleVerticalColumn: Bool = false,
        reservedSources: [CGRect] = [],
        measurementCache: BrowserOverlayTextMeasurementCache? = nil
    ) -> BrowserOverlayCardLayout {
        guard viewport.width > 0, viewport.height > 0 else {
            return BrowserOverlayCardLayout(
                rect: .null,
                maximumFontSize: minimumAutoFontSize,
                contentInsets: BrowserOverlayCardTextInsets.regular
            )
        }
        let clippedSource = source.standardized.intersection(
            CGRect(origin: .zero, size: viewport)
        )
        guard !clippedSource.isNull,
              clippedSource.width > 0,
              clippedSource.height > 0
        else {
            return BrowserOverlayCardLayout(
                rect: .null,
                maximumFontSize: minimumAutoFontSize,
                contentInsets: BrowserOverlayCardTextInsets.regular
            )
        }
        let safeVariants = variants.isEmpty
            ? [.plain("", vertical: false)]
            : variants
        let isExactVerticalReplacement =
            settings.textPlacement == .replace &&
            sourceVertical == true &&
            safeVariants.allSatisfy(\.vertical)
        if isExactVerticalReplacement
        {
            let contentInsets = singleVerticalColumn
                ? BrowserOverlayCardTextInsets.singleVerticalColumn
                : BrowserOverlayCardTextInsets.regular
            let fittedAtNormalScale = singleVerticalColumn
                ? fittedSingleVerticalColumnFontSize(
                    variants: safeVariants,
                    size: clippedSource.size,
                    maximum: maximumAutoFontSize,
                    measurementCache: measurementCache
                )
                : fittedSourceFontSize(
                    variants: safeVariants,
                    size: clippedSource.size,
                    minimumHorizontalUnits: 1,
                    minimum: minimumSingleVerticalColumnFontSize,
                    maximum: maximumAutoFontSize,
                    contentInsets: contentInsets,
                    measurementCache: measurementCache
                )
            let fittedInSource = fittedAtNormalScale
            let readableFloor = minimumReadableFontSize(
                variants: safeVariants,
                settings: settings
            )
            guard fittedInSource + 0.001 >= readableFloor,
                  variantsFit(
                      safeVariants,
                      size: clippedSource.size,
                      fontSize: fittedInSource,
                      minimumHorizontalUnits: 1,
                      contentInsets: contentInsets,
                      measurementCache: measurementCache
                  )
            else {
                // A valid OCR source must never disappear merely because its
                // text cannot fully fit the source bbox. Exact vertical
                // replacement remains attached to that bbox and paints at the
                // five-point emergency floor; clipping is preferable to
                // dropping the OCR/translation card altogether.
                return BrowserOverlayCardLayout(
                    rect: clippedSource,
                    maximumFontSize: bestEffortFontSize(
                        settings: settings,
                        fittedFontSize: fittedInSource
                    ),
                    contentInsets: contentInsets
                )
            }
            // Replacement cards must stay on the vertical OCR bbox even when
            // first-frame merging has not yet settled the single-column bit.
            // Growing a long vertical string down the page covers unrelated
            // content; fitting inside the source is the stable fallback.
            return BrowserOverlayCardLayout(
                rect: clippedSource,
                maximumFontSize: fittedInSource,
                contentInsets: contentInsets
            )
        }
        let containsHorizontal = safeVariants.contains { !$0.vertical }
        let contentInsets = plannedContentInsets(
            source: clippedSource,
            settings: settings,
            vertical: !containsHorizontal
        )
        let isHorizontalTranslationOfVerticalSource =
            (sourceVertical ?? false) && containsHorizontal
        // Six Hangul cells remain usable at the 5pt emergency floor while
        // avoiding the old eight-cell card that routinely crossed manga gutters.
        let minimumHorizontalUnits: CGFloat = isHorizontalTranslationOfVerticalSource ? 6 : 1
        // Legacy expanded presentation remains readable when decoding older data.
        let usesLegacyExpandedPresentation = settings.textPlacement == .expanded
        let minimumExpandedSize = usesLegacyExpandedPresentation
            ? (safeVariants.allSatisfy(\.vertical)
                ? CGSize(width: 64, height: 112)
                : CGSize(width: 112, height: 36))
            : .zero
        let maximumEnvelopeWidth: CGFloat = {
            guard !usesLegacyExpandedPresentation,
                  isHorizontalTranslationOfVerticalSource
            else {
                return viewport.width
            }
            let horizontalInsets = contentInsets.left + contentInsets.right
            let readableFloor =
                minimumHorizontalUnits * minimumReadableFontSize(
                    variants: safeVariants,
                    settings: settings
                ) +
                horizontalInsets
            let proportionalCap = min(
                clippedSource.width * 2.25,
                max(
                    clippedSource.width * 1.75,
                    clippedSource.height * 0.45
                )
            )
            return min(
                viewport.width,
                max(clippedSource.width, readableFloor, proportionalCap)
            )
        }()

        let maximumFontSize: CGFloat
        let fittedBase = usesLegacyExpandedPresentation
            ? maximumAutoFontSize
            : fittedSourceFontSize(
                variants: safeVariants,
                size: clippedSource.size,
                minimumHorizontalUnits: minimumHorizontalUnits,
                maximum: maximumAutoFontSize,
                contentInsets: contentInsets,
                measurementCache: measurementCache
            )
        let scaledMinimum = minimumReadableFontSize(
            variants: safeVariants,
            settings: settings
        )
        let desired = min(64, max(scaledMinimum, fittedBase))
        maximumFontSize = fittedEnvelopeFontSize(
            variants: safeVariants,
            source: clippedSource,
            minimumSize: minimumExpandedSize,
            minimumHorizontalUnits: minimumHorizontalUnits,
            viewport: viewport,
            maximumWidth: maximumEnvelopeWidth,
            minimum: scaledMinimum,
            maximum: desired,
            contentInsets: contentInsets,
            measurementCache: measurementCache
        )

        let requested: CGSize
        if !usesLegacyExpandedPresentation,
           variantsFit(
               safeVariants,
               size: clippedSource.size,
               fontSize: maximumFontSize,
               minimumHorizontalUnits: minimumHorizontalUnits,
               contentInsets: contentInsets,
               measurementCache: measurementCache
           )
        {
            requested = clippedSource.size
        } else {
            guard let readableSize = readableEnvelopeSize(
                variants: safeVariants,
                source: clippedSource,
                minimumSize: minimumExpandedSize,
                minimumHorizontalUnits: minimumHorizontalUnits,
                fontSize: maximumFontSize,
                viewport: viewport,
                maximumWidth: maximumEnvelopeWidth,
                contentInsets: contentInsets,
                measurementCache: measurementCache
            ) else {
                return bestEffortAttachedLayout(
                    source: clippedSource,
                    variants: safeVariants,
                    settings: settings,
                    viewport: viewport,
                    occupied: occupied,
                    reservedSources: reservedSources,
                    contentInsets: contentInsets,
                    maximumWidth: maximumEnvelopeWidth,
                    measurementCache: measurementCache
                )
            }
            requested = readableSize
        }
        let anchored = anchoredRect(
            source: clippedSource,
            requested: requested,
            viewport: viewport
        )
        return resolveCollisionAwareLayout(
            BrowserOverlayCardLayout(
                rect: anchored,
                maximumFontSize: maximumFontSize,
                contentInsets: contentInsets
            ),
            source: clippedSource,
            variants: safeVariants,
            settings: settings,
            occupied: occupied,
            reservedSources: reservedSources,
            viewport: viewport,
            measurementCache: measurementCache
        )
    }

    /// Returns only preceding cards that could overlap any legal collision
    /// placement for this card. The rectangle is a conservative superset of
    /// the exact candidate grid, so excluding a card cannot alter scoring;
    /// including an extra nearby card merely causes a safe cache miss.
    static func collisionDependencies(
        intrinsicLayout: BrowserOverlayCardLayout,
        source: CGRect,
        variants: [BrowserOverlayDisplayVariant],
        settings: IPhoneOverlaySettings,
        viewport: CGSize,
        occupied: [BrowserOverlayPositionedCollisionDependency],
        sourceVertical: Bool?,
        singleVerticalColumn: Bool
    ) -> [BrowserOverlayPositionedCollisionDependency] {
        guard requiresCollisionResolution(
            variants: variants,
            settings: settings,
            sourceVertical: sourceVertical,
            singleVerticalColumn: singleVerticalColumn
        ) else {
            return []
        }
        let influence = collisionInfluenceBounds(
            intrinsicLayout: intrinsicLayout,
            source: source,
            viewport: viewport
        )
        return occupied.filter { dependency in
            let intersection = influence.intersection(dependency.rect)
            return !intersection.isNull &&
                intersection.width > 0.25 &&
                intersection.height > 0.25
        }
    }

    /// Applies only the inexpensive collision phase to a cached intrinsic
    /// layout. Exact source-bounds and one-column vertical replacements retain
    /// the planner's original early-return semantics.
    static func resolvePositionedLayout(
        _ intrinsicLayout: BrowserOverlayCardLayout,
        source: CGRect,
        variants: [BrowserOverlayDisplayVariant],
        settings: IPhoneOverlaySettings,
        viewport: CGSize,
        occupied: [CGRect],
        sourceVertical: Bool?,
        singleVerticalColumn: Bool,
        reservedSources: [CGRect],
        measurementCache: BrowserOverlayTextMeasurementCache? = nil
    ) -> BrowserOverlayCardLayout {
        guard requiresCollisionResolution(
            variants: variants,
            settings: settings,
            sourceVertical: sourceVertical,
            singleVerticalColumn: singleVerticalColumn
        ) else {
            return intrinsicLayout
        }
        return resolveCollisionAwareLayout(
            intrinsicLayout,
            source: clippedSource(source, viewport: viewport),
            variants: variants,
            settings: settings,
            occupied: occupied,
            reservedSources: reservedSources,
            viewport: viewport,
            measurementCache: measurementCache
        )
    }

    /// Recover readable text only after every card position and source-coverage
    /// adjustment is final. The original layout is retained if growth cannot fit.
    static func fittingFinalHorizontalFont(
        _ layout: BrowserOverlayCardLayout,
        variants: [BrowserOverlayDisplayVariant],
        settings: IPhoneOverlaySettings,
        occupied: [CGRect],
        reservedSources: [CGRect],
        measurementCache: BrowserOverlayTextMeasurementCache? = nil
    ) -> BrowserOverlayCardLayout {
        guard settings.textPlacement == .replace,
              !variants.isEmpty,
              variants.allSatisfy({ if case .plain = $0.content { return true }; return false })
        else { return layout }
        guard !(occupied + reservedSources).contains(where: { $0.contains(layout.rect) }) else { return layout }
        let hasCollision = hasVisualCollision(layout.rect, occupied: occupied, reservedSources: reservedSources)
        let vertical = variants.allSatisfy(\.vertical)
        let strictFont = vertical || hasCollision ? layout.maximumFontSize :
            (readableFontSize(variants: variants, rect: layout.rect,
                ceiling: max(layout.maximumFontSize, maximumAutoFontSize), settings: settings,
                contentInsets: layout.contentInsets, measurementCache: measurementCache,
                preservingLineLayoutAt: layout.maximumFontSize) ?? layout.maximumFontSize)
        var best = BrowserOverlayCardLayout(rect: layout.rect,
            maximumFontSize: max(layout.maximumFontSize, strictFont), contentInsets: layout.contentInsets)
        // Korean captions just above the emergency size can still be difficult
        // to read. Offer the same guarded, fixed-card refinement below 9 pt;
        // WebKit must still preserve word boundaries and avoid nearby sources.
        let refinementFloor: CGFloat = !vertical && variants.allSatisfy {
            BrowserOverlayTextFlow.wrappingScript(for: $0.displayText) == .korean
        } ? 9 : 8
        guard best.maximumFontSize < refinementFloor else { return best }
        let referenceFont = best.maximumFontSize
        let old = layout.contentInsets
        func reduced(_ value: CGFloat) -> CGFloat { min(value, max(2, value * 0.65)) }
        let compact = UIEdgeInsets(top: reduced(old.top), left: reduced(old.left),
                                   bottom: reduced(old.bottom), right: reduced(old.right))
        // Preserve the previous v10 proposal as an independently verified fallback.
        var fallback = best
        if !vertical && !hasCollision {
            for insets in [old, compact] {
                if fallback.maximumFontSize >= 8 { break }
                if let font = readableFontSize(variants: variants, rect: layout.rect,
                    ceiling: 8, settings: settings, contentInsets: insets,
                    measurementCache: measurementCache, preservingLineLayoutAt: referenceFont,
                    additionalLineAllowance: 1), font >= fallback.maximumFontSize + 0.5 {
                    fallback = .init(rect: layout.rect, maximumFontSize: font, contentInsets: insets)
                }
            }
        }
        let extraLines = min(32, max(1, Int((vertical ? layout.rect.width : layout.rect.height) / 10)))
        if vertical {
            // UIKit measures horizontal attributed strings; WebKit measures the
            // actual vertical columns and shrinks this ceiling inside the same card.
            best = .init(rect: layout.rect, maximumFontSize: 12, contentInsets: old)
        } else {
            for insets in [old, compact] {
                if best.maximumFontSize >= refinementFloor { break }
                if let font = readableFontSize(variants: variants, rect: layout.rect,
                    ceiling: 12, settings: settings, contentInsets: insets,
                    measurementCache: measurementCache, preservingLineLayoutAt: referenceFont,
                    additionalLineAllowance: extraLines), font >= best.maximumFontSize + 0.5 {
                    best = .init(rect: layout.rect, maximumFontSize: font, contentInsets: insets)
                }
            }
        }
        if fallback.maximumFontSize > best.maximumFontSize { best = fallback }
        if best.maximumFontSize > referenceFont {
            best.smallTextReference = BrowserOverlayFontReference(fontSize: referenceFont, insets: old,
                additionalLines: extraLines, exclusionRects: hasCollision ? occupied + reservedSources : [],
                fallbackFontSize: fallback.maximumFontSize, fallbackInsets: fallback.contentInsets,
                allowsEmergencyWordBreak: variants.allSatisfy { $0.allowsEmergencyKoreanWordBreak(at: referenceFont) })
        }
        return best
    }

    /// Position-only collision handling cannot solve dense manga layouts when
    /// several expanded translations all have to cover nearby source boxes.
    /// Keep the largest readable envelope that has no positive-area overlap;
    /// if necessary, contract toward the source bbox and auto-fit the text.
    private static func resolveCollisionAwareLayout(
        _ intrinsicLayout: BrowserOverlayCardLayout,
        source: CGRect,
        variants: [BrowserOverlayDisplayVariant],
        settings: IPhoneOverlaySettings,
        occupied: [CGRect],
        reservedSources: [CGRect],
        viewport: CGSize,
        measurementCache: BrowserOverlayTextMeasurementCache?
    ) -> BrowserOverlayCardLayout {
        guard !intrinsicLayout.rect.isNull,
              intrinsicLayout.rect.width > 0,
              intrinsicLayout.rect.height > 0
        else {
            return intrinsicLayout
        }
        let resolved = resolveCollision(
            intrinsicLayout.rect,
            source: source,
            occupied: occupied,
            reservedSources: reservedSources,
            viewport: viewport
        )
        guard hasVisualCollision(
            resolved,
            occupied: occupied,
            reservedSources: reservedSources
        ) else {
            // The source-derived ceiling can remain at the emergency floor
            // after horizontal text has gained a collision-free envelope.
            // Recover the normal floor only inside that existing envelope;
            // never enlarge a card for this.
            let restoresNormalFloor = settings.textPlacement == .replace
                && !variants.isEmpty && variants.allSatisfy { !$0.vertical }
            let fittedCeiling = restoresNormalFloor
                ? max(intrinsicLayout.maximumFontSize, minimumAutoFontSize)
                : intrinsicLayout.maximumFontSize
            guard let readableFontSize = readableFontSize(
                variants: variants,
                rect: resolved,
                ceiling: fittedCeiling,
                settings: settings,
                contentInsets: intrinsicLayout.contentInsets,
                measurementCache: measurementCache
            ) else {
                return bestEffortAttachedLayout(
                    source: source,
                    variants: variants,
                    settings: settings,
                    viewport: viewport,
                    occupied: occupied,
                    reservedSources: reservedSources,
                    contentInsets: intrinsicLayout.contentInsets,
                    maximumWidth: intrinsicLayout.rect.width,
                    measurementCache: measurementCache
                )
            }
            return BrowserOverlayCardLayout(
                rect: resolved,
                maximumFontSize: readableFontSize,
                contentInsets: intrinsicLayout.contentInsets
            )
        }

        let safeVariants = variants.isEmpty
            ? [.plain("", vertical: false)]
            : variants
        let expandedSize = intrinsicLayout.rect.size
        var lastCollidingScale: CGFloat = 1

        // Coarse-to-fine search avoids an expensive two-dimensional packing
        // pass on every frame while still finding a near-maximal envelope.
        for step in 1...24 {
            let scale = 1 - CGFloat(step) / 24
            let candidate = collisionCandidate(
                source: source,
                expandedSize: expandedSize,
                scale: scale,
                occupied: occupied,
                reservedSources: reservedSources,
                viewport: viewport
            )
            guard !hasVisualCollision(
                candidate,
                occupied: occupied,
                reservedSources: reservedSources
            ) else {
                lastCollidingScale = scale
                continue
            }

            guard readableFontSize(
                variants: safeVariants,
                rect: candidate,
                ceiling: intrinsicLayout.maximumFontSize,
                settings: settings,
                contentInsets: intrinsicLayout.contentInsets,
                measurementCache: measurementCache
            ) != nil else {
                // Every later candidate is smaller, so it cannot restore the
                // minimum readable font size once this one no longer fits.
                break
            }

            var acceptedScale = scale
            var acceptedRect = candidate
            var rejectedScale = lastCollidingScale
            for _ in 0..<8 {
                let probeScale = (acceptedScale + rejectedScale) / 2
                let probe = collisionCandidate(
                    source: source,
                    expandedSize: expandedSize,
                    scale: probeScale,
                    occupied: occupied,
                    reservedSources: reservedSources,
                    viewport: viewport
                )
                if hasVisualCollision(
                    probe,
                    occupied: occupied,
                    reservedSources: reservedSources
                ) {
                    rejectedScale = probeScale
                } else {
                    acceptedScale = probeScale
                    acceptedRect = probe
                }
            }

            guard let maximumFontSize = readableFontSize(
                variants: safeVariants,
                rect: acceptedRect,
                ceiling: intrinsicLayout.maximumFontSize,
                settings: settings,
                contentInsets: intrinsicLayout.contentInsets,
                measurementCache: measurementCache
            ) else {
                break
            }
            return BrowserOverlayCardLayout(
                rect: acceptedRect,
                maximumFontSize: maximumFontSize,
                contentInsets: intrinsicLayout.contentInsets
            )
        }

        // A perfect packing is not always possible when OCR source boxes are
        // themselves dense or overlapping. Preserve one source-attached card
        // per OCR result: find the smallest envelope that can paint at 5pt and
        // select its least-overlapping legal placement. This deliberately
        // accepts unavoidable overlap instead of silently dropping the card.
        return bestEffortAttachedLayout(
            source: source,
            variants: safeVariants,
            settings: settings,
            viewport: viewport,
            occupied: occupied,
            reservedSources: reservedSources,
            contentInsets: intrinsicLayout.contentInsets,
            maximumWidth: intrinsicLayout.rect.width,
            measurementCache: measurementCache
        )
    }

    private static func bestEffortAttachedLayout(
        source: CGRect,
        variants: [BrowserOverlayDisplayVariant],
        settings: IPhoneOverlaySettings,
        viewport: CGSize,
        occupied: [CGRect],
        reservedSources: [CGRect],
        contentInsets: UIEdgeInsets,
        maximumWidth: CGFloat,
        measurementCache: BrowserOverlayTextMeasurementCache?
    ) -> BrowserOverlayCardLayout {
        let safeVariants = variants.isEmpty
            ? [.plain("", vertical: false)]
            : variants
        let fontSize = bestEffortFontSize(settings: settings)
        let readableSize = readableEnvelopeSize(
            variants: safeVariants,
            source: source,
            minimumSize: .zero,
            minimumHorizontalUnits: 1,
            fontSize: fontSize,
            viewport: viewport,
            maximumWidth: max(source.width, maximumWidth),
            contentInsets: contentInsets,
            measurementCache: measurementCache
        )
        // An arbitrarily long provider response may not fit even the available
        // viewport at 5pt. The source-sized card is still a visible, attached,
        // bounded result; renderer clipping/overflow policy can then degrade
        // locally without turning the whole OCR item into `.null`.
        let requested = readableSize ?? source.size
        let anchored = anchoredRect(
            source: source,
            requested: requested,
            viewport: viewport
        )
        let placed = resolveCollision(
            anchored,
            source: source,
            occupied: occupied,
            reservedSources: reservedSources,
            viewport: viewport
        )
        return BrowserOverlayCardLayout(
            rect: placed,
            maximumFontSize: fontSize,
            contentInsets: contentInsets
        )
    }

    private static func bestEffortFontSize(
        settings: IPhoneOverlaySettings,
        fittedFontSize: CGFloat? = nil
    ) -> CGFloat {
        return max(
            minimumRenderedFontSize,
            fittedFontSize ?? minimumRenderedFontSize
        )
    }

    private static func readableFontSize(
        variants: [BrowserOverlayDisplayVariant],
        rect: CGRect,
        ceiling: CGFloat,
        settings: IPhoneOverlaySettings,
        contentInsets: UIEdgeInsets,
        measurementCache: BrowserOverlayTextMeasurementCache?,
        preservingLineLayoutAt referenceFont: CGFloat? = nil,
        additionalLineAllowance: Int = 0
    ) -> CGFloat? {
        let floor = minimumReadableFontSize(
            variants: variants,
            settings: settings
        )
        guard ceiling + 0.001 >= floor else { return nil }
        let usableWidth = max(1, rect.width - contentInsets.left - contentInsets.right)
        // Enlarging into unused height must not turn a horizontal utterance into
        // a narrow stack or introduce emergency breaks inside previously fitting words.
        let lineBudgets: [(count: Int, protectsWords: Bool)]? = referenceFont.map { reference in
            variants.map { variant in
                let height = variant.measuredSize(width: usableWidth, fontSize: reference,
                    measurementCache: measurementCache).height
                let lineHeight = UIFont.systemFont(ofSize: reference, weight: .bold).lineHeight
                return (max(1, Int(ceil(max(0, height - 1) / lineHeight))),
                    !variant.allowsEmergencyKoreanWordBreak(at: reference) &&
                    variant.minimumUnbrokenWidth(fontSize: reference,
                        measurementCache: measurementCache) <= usableWidth + 0.5)
            }
        }
        let preservesLineLayout: ((CGFloat) -> Bool)? = lineBudgets.map { budgets in
            { candidate in
                // The prior accepted size remains admissible despite metric rounding.
                if let referenceFont, candidate <= referenceFont { return true }
                let lineHeight = UIFont.systemFont(ofSize: candidate, weight: .bold).lineHeight
                return zip(variants, budgets).allSatisfy { variant, budget in
                    let height = variant.measuredSize(width: usableWidth, fontSize: candidate,
                        measurementCache: measurementCache).height
                    return height <= CGFloat(budget.count + max(0, additionalLineAllowance)) * lineHeight + 1 &&
                        (!budget.protectsWords || variant.minimumUnbrokenWidth(fontSize: candidate,
                            measurementCache: measurementCache) <= usableWidth + 0.5)
                }
            }
        }
        let fitted: CGFloat
        fitted = min(
            ceiling,
            fittedSourceFontSize(
                variants: variants,
                size: rect.size,
                minimumHorizontalUnits: 1,
                minimum: max(floor, referenceFont ?? floor),
                maximum: ceiling,
                contentInsets: contentInsets,
                measurementCache: measurementCache,
                additionalFit: preservesLineLayout
            )
        )
        guard fitted + 0.001 >= floor,
              variantsFit(
                  variants,
                  size: rect.size,
                  fontSize: fitted,
                  minimumHorizontalUnits: 1,
                  contentInsets: contentInsets,
                  measurementCache: measurementCache
              )
        else {
            return nil
        }
        return fitted
    }

    private static func minimumReadableFontSize(
        variants: [BrowserOverlayDisplayVariant],
        settings: IPhoneOverlaySettings
    ) -> CGFloat {
        return variants.contains(where: { !$0.vertical })
            ? minimumReadableHorizontalFontSize
            : minimumAutoFontSize
    }

    private static func collisionCandidate(
        source: CGRect,
        expandedSize: CGSize,
        scale: CGFloat,
        occupied: [CGRect],
        reservedSources: [CGRect],
        viewport: CGSize
    ) -> CGRect {
        let clampedScale = min(1, max(0, scale))
        let requested = CGSize(
            width: source.width +
                max(0, expandedSize.width - source.width) * clampedScale,
            height: source.height +
                max(0, expandedSize.height - source.height) * clampedScale
        )
        return resolveCollision(
            anchoredRect(
                source: source,
                requested: requested,
                viewport: viewport
            ),
            source: source,
            occupied: occupied,
            reservedSources: reservedSources,
            viewport: viewport
        )
    }

    private static func collisionInfluenceBounds(
        intrinsicLayout: BrowserOverlayCardLayout,
        source: CGRect,
        viewport: CGSize
    ) -> CGRect {
        let maximumWidth = max(source.width, intrinsicLayout.rect.width)
        let maximumHeight = max(source.height, intrinsicLayout.rect.height)
        let legalPlacementBounds = CGRect(
            x: source.minX - maximumWidth,
            y: source.minY - maximumHeight,
            width: source.width + maximumWidth * 2,
            height: source.height + maximumHeight * 2
        )
        return legalPlacementBounds
            .union(intrinsicLayout.rect)
            .intersection(CGRect(origin: .zero, size: viewport))
    }

    private static func hasVisualCollision(
        _ rect: CGRect,
        occupied: [CGRect],
        reservedSources: [CGRect]
    ) -> Bool {
        (occupied + reservedSources).contains { other in
            let intersection = rect.intersection(other)
            return !intersection.isNull &&
                intersection.width > 0.25 &&
                intersection.height > 0.25
        }
    }

    private static func requiresCollisionResolution(
        variants: [BrowserOverlayDisplayVariant],
        settings: IPhoneOverlaySettings,
        sourceVertical: Bool?,
        singleVerticalColumn: Bool
    ) -> Bool {
        let safeVariants = variants.isEmpty
            ? [.plain("", vertical: false)]
            : variants
        if settings.textPlacement == .replace,
           sourceVertical == true,
           safeVariants.allSatisfy(\.vertical)
        {
            return false
        }
        return true
    }

    private static func clippedSource(
        _ source: CGRect,
        viewport: CGSize
    ) -> CGRect {
        source.standardized.intersection(
            CGRect(origin: .zero, size: viewport)
        )
    }

    private static func fittedSourceFontSize(
        variants: [BrowserOverlayDisplayVariant],
        size: CGSize,
        minimumHorizontalUnits: CGFloat,
        minimum: CGFloat = minimumAutoFontSize,
        maximum: CGFloat,
        contentInsets: UIEdgeInsets,
        measurementCache: BrowserOverlayTextMeasurementCache?,
        additionalFit: ((CGFloat) -> Bool)? = nil
    ) -> CGFloat {
        guard variantsFit(
            variants,
            size: size,
            fontSize: minimum,
            minimumHorizontalUnits: minimumHorizontalUnits,
            contentInsets: contentInsets,
            measurementCache: measurementCache
        ) else {
            return minimum
        }
        var lower = minimum
        var upper = max(minimum, maximum)
        for _ in 0..<10 {
            let candidate = (lower + upper) / 2
            if variantsFit(
                variants,
                size: size,
                fontSize: candidate,
                minimumHorizontalUnits: minimumHorizontalUnits,
                contentInsets: contentInsets,
                measurementCache: measurementCache
            ) && (additionalFit?(candidate) ?? true) {
                lower = candidate
            } else {
                upper = candidate
            }
        }
        return floor(lower * 4) / 4
    }

    private static func fittedSingleVerticalColumnFontSize(
        variants: [BrowserOverlayDisplayVariant],
        size: CGSize,
        maximum: CGFloat,
        measurementCache: BrowserOverlayTextMeasurementCache?
    ) -> CGFloat {
        let upperBound = max(
            minimumSingleVerticalColumnFontSize,
            maximum
        )
        func fits(_ fontSize: CGFloat) -> Bool {
            variantsFit(
                variants,
                size: size,
                fontSize: fontSize,
                minimumHorizontalUnits: 1,
                contentInsets:
                    BrowserOverlayCardTextInsets.singleVerticalColumn,
                measurementCache: measurementCache
            )
        }
        guard !fits(upperBound) else { return upperBound }
        guard fits(minimumSingleVerticalColumnFontSize) else {
            return minimumSingleVerticalColumnFontSize
        }
        var lower = minimumSingleVerticalColumnFontSize
        var upper = upperBound
        for _ in 0..<10 {
            let candidate = (lower + upper) / 2
            if fits(candidate) {
                lower = candidate
            } else {
                upper = candidate
            }
        }
        return floor(lower * 4) / 4
    }

    private static func fittedEnvelopeFontSize(
        variants: [BrowserOverlayDisplayVariant],
        source: CGRect,
        minimumSize: CGSize,
        minimumHorizontalUnits: CGFloat,
        viewport: CGSize,
        maximumWidth: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat,
        contentInsets: UIEdgeInsets,
        measurementCache: BrowserOverlayTextMeasurementCache?
    ) -> CGFloat {
        func fits(_ fontSize: CGFloat) -> Bool {
            guard let size = readableEnvelopeSize(
                variants: variants,
                source: source,
                minimumSize: minimumSize,
                minimumHorizontalUnits: minimumHorizontalUnits,
                fontSize: fontSize,
                viewport: viewport,
                maximumWidth: maximumWidth,
                contentInsets: contentInsets,
                measurementCache: measurementCache
            ) else {
                return false
            }
            return variantsFit(
                variants,
                size: size,
                fontSize: fontSize,
                minimumHorizontalUnits: minimumHorizontalUnits,
                contentInsets: contentInsets,
                measurementCache: measurementCache
            )
        }

        let policyFloor = maximumWidth + 0.5 < viewport.width
            ? minimumConstrainedMangaFontSize
            : minimumSingleVerticalColumnFontSize
        let lowerBound = max(policyFloor, minimum)
        let upperBound = max(lowerBound, maximum)
        guard !fits(upperBound) else { return upperBound }
        guard fits(lowerBound) else { return lowerBound }
        var lower = lowerBound
        var upper = upperBound
        for _ in 0..<10 {
            let candidate = (lower + upper) / 2
            if fits(candidate) {
                lower = candidate
            } else {
                upper = candidate
            }
        }
        return floor(lower * 4) / 4
    }

    private static func readableEnvelopeSize(
        variants: [BrowserOverlayDisplayVariant],
        source: CGRect,
        minimumSize: CGSize,
        minimumHorizontalUnits: CGFloat,
        fontSize: CGFloat,
        viewport: CGSize,
        maximumWidth: CGFloat,
        contentInsets: UIEdgeInsets,
        measurementCache: BrowserOverlayTextMeasurementCache?
    ) -> CGSize? {
        let horizontalInsets = contentInsets.left + contentInsets.right
        let verticalInsets = contentInsets.top + contentInsets.bottom
        let tokenWidth = variants.reduce(CGFloat.zero) {
            max(
                $0,
                $1.minimumUnbrokenWidth(
                    fontSize: fontSize,
                    measurementCache: measurementCache
                )
            )
        }
        let boundedMaximumWidth = min(
            viewport.width,
            max(source.width, maximumWidth)
        )
        let minimumWidth = min(
            boundedMaximumWidth,
            max(
                source.width,
                minimumSize.width,
                minimumHorizontalUnits * fontSize + horizontalInsets,
                tokenWidth + horizontalInsets
            )
        )
        let widthSpan = max(0, boundedMaximumWidth - minimumWidth)
        var candidateWidths = (0...24).map { step in
            minimumWidth + widthSpan * CGFloat(step) / 24
        }
        candidateWidths.append(contentsOf: [
            source.width,
            minimumSize.width,
            boundedMaximumWidth * 0.72,
            boundedMaximumWidth,
        ])
        candidateWidths = uniqueValues(candidateWidths)
            .map { min(boundedMaximumWidth, max(minimumWidth, $0)) }

        var candidates: [CGSize] = []
        for width in candidateWidths {
            let usableWidth = max(1, width - horizontalInsets)
            let measuredHeight = variants.reduce(CGFloat.zero) {
                max(
                    $0,
                    $1.measuredSize(
                        width: usableWidth,
                        fontSize: fontSize,
                        measurementCache: measurementCache
                    ).height
                )
            }
            let size = CGSize(
                width: max(source.width, minimumSize.width, width),
                height: min(
                    viewport.height,
                    max(
                        source.height,
                        minimumSize.height,
                        measuredHeight + verticalInsets
                    )
                )
            )
            if size.width <= boundedMaximumWidth,
               variantsFit(
                   variants,
                   size: size,
                   fontSize: fontSize,
                   minimumHorizontalUnits: minimumHorizontalUnits,
                   contentInsets: contentInsets,
                   measurementCache: measurementCache
               )
            {
                candidates.append(size)
            }
        }

        return candidates.min { left, right in
            let leftExpansion = max(
                left.width / source.width,
                left.height / source.height
            )
            let rightExpansion = max(
                right.width / source.width,
                right.height / source.height
            )
            if abs(leftExpansion - rightExpansion) > 0.001 {
                return leftExpansion < rightExpansion
            }
            return left.width * left.height < right.width * right.height
        }
    }

    private static func variantsFit(
        _ variants: [BrowserOverlayDisplayVariant],
        size: CGSize,
        fontSize: CGFloat,
        minimumHorizontalUnits: CGFloat,
        contentInsets: UIEdgeInsets = BrowserOverlayCardTextInsets.regular,
        measurementCache: BrowserOverlayTextMeasurementCache? = nil
    ) -> Bool {
        let usable = CGSize(
            width: max(
                1,
                size.width - contentInsets.left - contentInsets.right
            ),
            height: max(
                1,
                size.height - contentInsets.top - contentInsets.bottom
            )
        )
        if variants.contains(where: { !$0.vertical }),
           usable.width + 0.5 < minimumHorizontalUnits * fontSize
        {
            return false
        }
        return variants.allSatisfy {
            $0.fits(
                available: usable,
                fontSize: fontSize,
                measurementCache: measurementCache
            )
        }
    }

    /// Mirrors desktop replacement padding and its conservative border/font
    /// metric reserves. Small OCR boxes no longer lose a fixed 12x8 points of
    /// content area before auto-fit even starts.
    private static func plannedContentInsets(
        source: CGRect,
        settings: IPhoneOverlaySettings,
        vertical: Bool
    ) -> UIEdgeInsets {
        let minorAxis = max(1, min(source.width, source.height))
        let padding: CGFloat
        if settings.textPlacement == .replace {
            padding = min(4, max(1, minorAxis * 0.055))
        } else {
            padding = min(10, max(4, minorAxis * 0.06))
        }
        let roundedPadding = (padding * 100).rounded() / 100
        let borderReservePerEdge: CGFloat = settings.reservesSurfaceBorder ? 2 : 0
        let verticalOverhangPerHorizontalEdge: CGFloat = vertical ? 2 : 0
        return UIEdgeInsets(
            top: roundedPadding + borderReservePerEdge,
            left: roundedPadding + borderReservePerEdge +
                verticalOverhangPerHorizontalEdge,
            bottom: roundedPadding + borderReservePerEdge,
            right: roundedPadding + borderReservePerEdge +
                verticalOverhangPerHorizontalEdge
        )
    }

    /// Uses the same UIKit font and wrapping policy as the painted label.
    /// Keeping this measurement authoritative prevents the planner from
    /// approving an 11pt layout that UILabel later clips.
    static func measuredHorizontalTextSize(
        _ text: String,
        width: CGFloat,
        fontSize: CGFloat,
        weight: UIFont.Weight = .semibold
    ) -> CGSize {
        guard width > 0, fontSize > 0 else { return .zero }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineBreakStrategy = [.standard, .hangulWordPriority]
        let measured = (text as NSString).boundingRect(
            with: CGSize(
                width: width,
                height: .greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [
                .font: UIFont.systemFont(ofSize: fontSize, weight: weight),
                .paragraphStyle: paragraph,
            ],
            context: nil
        )
        return CGSize(
            width: ceil(measured.width),
            height: ceil(measured.height)
        )
    }

    static func horizontalTextFits(
        _ text: String,
        available: CGSize,
        fontSize: CGFloat,
        weight: UIFont.Weight = .semibold
    ) -> Bool {
        let measured = measuredHorizontalTextSize(
            text,
            width: available.width,
            fontSize: fontSize,
            weight: weight
        )
        return measured.width <= available.width + 0.5 &&
            measured.height <= available.height + 0.5
    }

    private static func anchoredRect(
        source: CGRect,
        requested: CGSize,
        viewport: CGSize
    ) -> CGRect {
        let width = min(viewport.width, max(source.width, requested.width))
        let height = min(viewport.height, max(source.height, requested.height))
        return CGRect(
            x: min(
                max(0, source.midX - width / 2),
                max(0, viewport.width - width)
            ),
            y: min(
                max(0, source.midY - height / 2),
                max(0, viewport.height - height)
            ),
            width: width,
            height: height
        )
    }

    private static func resolveCollision(
        _ candidate: CGRect,
        source: CGRect,
        occupied: [CGRect],
        reservedSources: [CGRect],
        viewport: CGSize
    ) -> CGRect {
        guard !occupied.isEmpty || !reservedSources.isEmpty else {
            return candidate
        }
        let minimumX = max(0, source.maxX - candidate.width)
        let maximumX = min(
            source.minX,
            max(0, viewport.width - candidate.width)
        )
        let minimumY = max(0, source.maxY - candidate.height)
        let maximumY = min(
            source.minY,
            max(0, viewport.height - candidate.height)
        )
        let obstacles = occupied + reservedSources
        let xValues = exactUniqueValues(uniqueValues([
            candidate.minX, minimumX, maximumX,
            source.minX, source.maxX - candidate.width,
        ] + obstacles.flatMap { other in
            [other.minX - candidate.width, other.maxX]
        }).map { min(max(minimumX, $0), maximumX) })
        let yValues = exactUniqueValues(uniqueValues([
            candidate.minY, minimumY, maximumY,
            source.minY, source.maxY - candidate.height,
        ] + obstacles.flatMap { other in
            [other.minY - candidate.height, other.maxY]
        }).map { min(max(minimumY, $0), maximumY) })
        // Clamping can collapse almost every seed onto the same boundary.
        // Score each distinct location once, retaining first-candidate tie order.
        // Padding is invariant across all candidates and belongs outside the loop.
        let paddedCards = occupied.map { BrowserOverlayCollisionGeometry($0.insetBy(dx: -2, dy: -2)) }
        let reservedGeometry = reservedSources.map(BrowserOverlayCollisionGeometry.init)
        var best = candidate
        var bestScore: CGFloat?
        for x in xValues {
            if Task.isCancelled { return best }
            for y in yValues {
                let rect = CGRect(x: x, y: y, width: candidate.width, height: candidate.height)
                let value = score(rect, anchor: candidate, occupied: paddedCards, reservedSources: reservedGeometry)
                if bestScore.map({ value < $0 }) ?? true {
                    best = rect
                    bestScore = value
                }
            }
        }
        return best
    }

    private static func score(
        _ rect: CGRect,
        anchor: CGRect,
        occupied: [BrowserOverlayCollisionGeometry],
        reservedSources: [BrowserOverlayCollisionGeometry]
    ) -> CGFloat {
        let geometry = BrowserOverlayCollisionGeometry(rect)
        let sourceOverlap = reservedSources.reduce(CGFloat.zero) {
            total, other in
            total + geometry.overlapArea(with: other)
        }
        let cardOverlap = occupied.reduce(CGFloat.zero) { total, other in
            total + geometry.overlapArea(with: other)
        }
        let dx = rect.minX - anchor.minX
        let dy = rect.minY - anchor.minY
        return sourceOverlap * 1_000_000 +
            cardOverlap * 1_000 + dx * dx + dy * dy
    }

    /// Exact deduplication AFTER the original tolerance-based seed selection
    /// and clamping preserves the original candidate grid and tie order.
    private static func exactUniqueValues(_ values: [CGFloat]) -> [CGFloat] {
        var seen = Set<CGFloat>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func uniqueValues(_ values: [CGFloat]) -> [CGFloat] {
        var result: [CGFloat] = []
        for value in values where value.isFinite {
            if !result.contains(where: { abs($0 - value) < 0.25 }) {
                result.append(value)
            }
        }
        return result
    }
}

private struct OverlayPalette {
    let isLightSurface: Bool
    let foreground: UIColor
    let secondary: UIColor
    let background: UIColor
    let border: UIColor

    func applyDropShadow(to layer: CALayer, compact: Bool) {
        layer.shadowColor = UIColor.black.cgColor
        if isLightSurface {
            layer.shadowOpacity = compact ? 0.26 : 0.32
            layer.shadowRadius = compact ? 3.5 : 9
            layer.shadowOffset = CGSize(width: 0, height: compact ? 2 : 5)
        } else {
            layer.shadowOpacity = compact ? 0.38 : 0.58
            layer.shadowRadius = compact ? 4 : 13
            layer.shadowOffset = CGSize(width: 0, height: compact ? 2 : 7)
        }
    }

    func makeTextShadow() -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = isLightSurface
            ? UIColor.white.withAlphaComponent(0.75)
            : UIColor.black.withAlphaComponent(0.95)
        shadow.shadowOffset = CGSize(width: 0, height: 1)
        shadow.shadowBlurRadius = isLightSurface ? 0 : 2
        return shadow
    }

    func applyTextShadow(to layer: CALayer) {
        layer.shadowColor = isLightSurface
            ? UIColor.white.cgColor
            : UIColor.black.cgColor
        layer.shadowOpacity = isLightSurface ? 0.75 : 0.95
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.shadowRadius = isLightSurface ? 0 : 2
    }

    static func make(
        mode: IPhoneOverlayColorMode,
        opacity: Double
    ) -> Self {
        let useLightSurface = mode == .white
        let baseAlpha = min(max(opacity, 0), 1)
        if !useLightSurface {
            // CSS parity: rgba(7,9,13,opacity) with a second
            // rgba(7,9,13,.64) background-image composited above it.
            let effectiveAlpha = 0.64 + (baseAlpha * (1 - 0.64))
            return Self(
                isLightSurface: false,
                foreground: .white,
                secondary: UIColor.white.withAlphaComponent(0.72),
                background: UIColor(
                    red: 7 / 255,
                    green: 9 / 255,
                    blue: 13 / 255,
                    alpha: effectiveAlpha
                ),
                border: UIColor.white.withAlphaComponent(0.40)
            )
        }
        // CSS parity: rgba(255,254,249,opacity) under rgba(255,255,255,.42).
        // Collapse the two layers into one UIColor while preserving the
        // resulting alpha and premultiplied RGB values.
        let imageAlpha = 0.42
        let effectiveAlpha = imageAlpha + (baseAlpha * (1 - imageAlpha))
        let baseContribution = baseAlpha * (1 - imageAlpha)
        let compositeChannel: (CGFloat) -> CGFloat = { baseChannel in
            guard effectiveAlpha > 0 else { return 0 }
            return CGFloat(
                (imageAlpha + (Double(baseChannel) * baseContribution)) /
                    effectiveAlpha
            )
        }
        return Self(
            isLightSurface: true,
            foreground: UIColor(red: 17 / 255, green: 18 / 255, blue: 23 / 255, alpha: 1),
            secondary: UIColor(red: 17 / 255, green: 18 / 255, blue: 23 / 255, alpha: 0.66),
            background: UIColor(
                red: compositeChannel(1),
                green: compositeChannel(254 / 255),
                blue: compositeChannel(249 / 255),
                alpha: effectiveAlpha
            ),
            border: UIColor(red: 17 / 255, green: 18 / 255, blue: 23 / 255, alpha: 0.72)
        )
    }
}

private final class OverlayCardView: UIView, UIContextMenuInteractionDelegate {
    /// UIKit does not expose the exact CSS `blur(2px) saturate(...)` controls
    /// used by c1. A material view is the public native approximation: it
    /// obscures sharp source-image glyphs before the configured translucent
    /// palette tint is composited above them.
    private let backdropView = UIVisualEffectView()
    private let surfaceTintView = UIView()
    private let label = OverlayFittingInsetLabel()
    private var backdropConstraints: [NSLayoutConstraint] = []
    private var sourceText: String
    private var translatedText: String?
    private var content: BrowserOverlayCardContent
    private var localizer: IPhoneLocalizer

    init(
        item: BrowserOverlayItem,
        content: BrowserOverlayCardContent,
        settings: IPhoneOverlaySettings,
        maximumFontSize: CGFloat,
        contentInsets: UIEdgeInsets,
        localizer: IPhoneLocalizer,
        measurementCache: BrowserOverlayTextMeasurementCache
    ) {
        sourceText = item.sourceText
        translatedText = item.translatedText
        self.content = content
        self.localizer = localizer
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityIdentifier =
            "aidoku.reader.overlay.item"

        backdropView.isUserInteractionEnabled = false
        backdropView.isAccessibilityElement = false
        backdropView.accessibilityElementsHidden = true
        backdropView.accessibilityIdentifier =
            "aidoku.reader.overlay.item.backdrop"
        backdropView.clipsToBounds = true
        surfaceTintView.isUserInteractionEnabled = false
        surfaceTintView.isAccessibilityElement = false
        surfaceTintView.accessibilityIdentifier =
            "aidoku.reader.overlay.item.surface"
        backdropView.contentView.addSubview(surfaceTintView)

        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.lineBreakStrategy = [.standard, .hangulWordPriority]
        label.accessibilityIdentifier =
            "aidoku.reader.overlay.item.text"
        addSubview(label)

        backdropView.translatesAutoresizingMaskIntoConstraints = false
        surfaceTintView.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        backdropConstraints = [
            backdropView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdropView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdropView.topAnchor.constraint(equalTo: topAnchor),
            backdropView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        NSLayoutConstraint.activate([
            surfaceTintView.leadingAnchor.constraint(
                equalTo: backdropView.contentView.leadingAnchor
            ),
            surfaceTintView.trailingAnchor.constraint(
                equalTo: backdropView.contentView.trailingAnchor
            ),
            surfaceTintView.topAnchor.constraint(
                equalTo: backdropView.contentView.topAnchor
            ),
            surfaceTintView.bottomAnchor.constraint(
                equalTo: backdropView.contentView.bottomAnchor
            ),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        addInteraction(UIContextMenuInteraction(delegate: self))
        apply(
            item: item,
            content: content,
            settings: settings,
            maximumFontSize: maximumFontSize,
            contentInsets: contentInsets,
            localizer: localizer,
            measurementCache: measurementCache
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        item: BrowserOverlayItem,
        content: BrowserOverlayCardContent,
        settings: IPhoneOverlaySettings,
        maximumFontSize: CGFloat,
        contentInsets: UIEdgeInsets,
        localizer: IPhoneLocalizer,
        measurementCache: BrowserOverlayTextMeasurementCache
    ) {
        apply(
            item: item,
            content: content,
            settings: settings,
            maximumFontSize: maximumFontSize,
            contentInsets: contentInsets,
            localizer: localizer,
            measurementCache: measurementCache
        )
    }

    private func apply(
        item: BrowserOverlayItem,
        content: BrowserOverlayCardContent,
        settings: IPhoneOverlaySettings,
        maximumFontSize: CGFloat,
        contentInsets: UIEdgeInsets,
        localizer: IPhoneLocalizer,
        measurementCache: BrowserOverlayTextMeasurementCache
    ) {
        sourceText = item.sourceText
        translatedText = item.translatedText
        self.content = content
        self.localizer = localizer

        let palette = OverlayPalette.make(
            mode: settings.colorMode,
            opacity: settings.opacity
        )
        let isReplacement = settings.textPlacement == .replace
        let isFinalTranslationReplacement =
            content.hasTranslation &&
            settings.mode == .translateOnly &&
            isReplacement
        if isReplacement {
            // Keep the c1 opacity contract. The material blur removes sharp
            // source-image detail; the configured palette alpha remains the
            // tint alpha instead of being silently promoted to opaque.
            installBackdropIfNeeded()
            backgroundColor = .clear
            backdropView.effect = UIBlurEffect(
                style: palette.isLightSurface
                    ? .systemThinMaterialLight
                    : .systemThinMaterialDark
            )
            surfaceTintView.backgroundColor = palette.background
        } else {
            // Expanded/subtitle-adjacent cards retain their established plain
            // surface and do not pay for a backdrop effect they never used.
            backgroundColor = palette.background
            backdropView.effect = nil
            surfaceTintView.backgroundColor = .clear
            removeBackdropIfNeeded()
        }
        let compact = settings.textPlacement == .replace
        let overlayBaseFontSize: CGFloat = 14
        layer.cornerRadius = compact
            ? 6
            : overlayBaseFontSize * (content.source.vertical ? 1.45 : 1.05)
        backdropView.layer.cornerRadius = layer.cornerRadius
        layer.borderWidth = !compact && content.source.vertical ? 2 : 1
        layer.borderColor = palette.border.cgColor
        palette.applyDropShadow(to: layer, compact: compact)
        layer.masksToBounds = false
        // Explicit one-line vertical OCR stays in one column; the planner may
        // grow its painted card around the source to preserve the mobile
        // readability floor. Clip only as a final font-metric safety net.
        clipsToBounds = false
        label.clipsToBounds = !content.hasTranslation ||
            content.displayed.vertical ||
            content.singleVerticalColumn ||
            settings.textPlacement != .replace

        label.setContentInsets(contentInsets)
        label.configure(
            displayVariant: displayedVariant,
            verticalRawText: BrowserOverlayVerticalTextPainter.text(
                for: item,
                content: content,
                mode: settings.mode
            ),
            foregroundColor: palette.foreground,
            secondaryForegroundColor: isFinalTranslationReplacement
                ? nil
                : palette.secondary,
            textShadow: palette.makeTextShadow(),
            maximumPointSize: maximumFontSize,
            // c1 chooses 800/700 from the displayed writing flow, not from
            // the source OCR orientation. A Korean translation of Japanese
            // vertical text is horizontal and therefore uses weight 700.
            weight: content.displayed.vertical ? .heavy : .bold,
            minimumScaleFactor: 0.42,
            minimumPointSize:
                BrowserOverlayLayoutPlanner.minimumAutoFontSize,
            measurementCache: measurementCache
        )
        accessibilityHint = localizer.string(.overlayCopyHint)
        updateTextFlow()
        updateAccessibility()
        setNeedsLayout()
        label.setNeedsLayout()
    }

    private func installBackdropIfNeeded() {
        guard backdropView.superview !== self else { return }
        insertSubview(backdropView, belowSubview: label)
        NSLayoutConstraint.activate(backdropConstraints)
    }

    private func removeBackdropIfNeeded() {
        guard backdropView.superview === self else { return }
        NSLayoutConstraint.deactivate(backdropConstraints)
        backdropView.removeFromSuperview()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else {
            layer.shadowPath = nil
            return
        }
        layer.shadowPath = UIBezierPath(
            roundedRect: bounds,
            cornerRadius: layer.cornerRadius
        ).cgPath
    }

    private func updateTextFlow() {
        let rawText = translatedText ?? sourceText
        let rightToLeft = BrowserOverlayTextFlow.isRightToLeft(rawText)
        // Desktop translation cards center both horizontal and vertical text;
        // direction still controls glyph order and accessibility semantics.
        label.textAlignment = .center
        label.semanticContentAttribute =
            rightToLeft ? .forceRightToLeft : .unspecified
    }

    private var displayedVariant: BrowserOverlayDisplayVariant {
        content.displayed
    }

    private func updateAccessibility() {
        accessibilityLabel = localizer.format(
            .overlayTranslationFormat,
            translatedText ?? sourceText
        )
        accessibilityValue = nil
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) {
            [sourceText, translatedText, localizer] _ in
            var actions = [
                UIAction(
                    title: localizer.string(.overlayCopySource),
                    image: UIImage(systemName: "doc.on.doc")
                ) { _ in
                    UIPasteboard.general.string = sourceText
                },
            ]
            if let translatedText {
                actions.append(
                    UIAction(
                        title: localizer.string(.overlayCopyTranslation),
                        image: UIImage(systemName: "character.book.closed")
                    ) { _ in
                        UIPasteboard.general.string = translatedText
                    }
                )
            }
            return UIMenu(title: sourceText, children: actions)
        }
    }
}

private final class OverlaySubtitleView: UIView, UIContextMenuInteractionDelegate {
    private let label = OverlayFittingLabel()
    private var sourceText: String
    private var translatedText: String
    private var localizer: IPhoneLocalizer

    init(
        text: String,
        sourceText: String,
        settings: IPhoneOverlaySettings,
        localizer: IPhoneLocalizer
    ) {
        self.sourceText = sourceText
        translatedText = text
        self.localizer = localizer
        super.init(frame: .zero)
        let palette = OverlayPalette.make(
            mode: settings.colorMode,
            opacity: settings.opacity
        )
        backgroundColor = palette.background
        layer.cornerRadius = 0.72 * 14
        layer.borderWidth = 1
        layer.borderColor = palette.border.cgColor
        palette.applyDropShadow(to: layer, compact: false)
        layer.masksToBounds = false
        isAccessibilityElement = true
        accessibilityIdentifier =
            "aidoku.reader.overlay.item"
        label.text = text
        label.textColor = palette.foreground
        palette.applyTextShadow(to: label.layer)
        label.configure(
            maximumPointSize: 18,
            weight: .semibold,
            minimumScaleFactor: 0.55
        )
        label.textAlignment = BrowserOverlayTextFlow.isRightToLeft(text)
            ? .right
            : .center
        label.semanticContentAttribute =
            BrowserOverlayTextFlow.isRightToLeft(text)
                ? .forceRightToLeft
                : .unspecified
        label.numberOfLines = settings.subtitleMaxLines
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
        accessibilityLabel = text
        accessibilityHint = localizer.string(.overlayCopyHint)
        addInteraction(UIContextMenuInteraction(delegate: self))
    }

    func update(
        text: String,
        sourceText: String,
        settings: IPhoneOverlaySettings,
        localizer: IPhoneLocalizer
    ) {
        self.sourceText = sourceText
        translatedText = text
        self.localizer = localizer
        let palette = OverlayPalette.make(
            mode: settings.colorMode,
            opacity: settings.opacity
        )
        backgroundColor = palette.background
        layer.cornerRadius = 0.72 * 14
        layer.borderWidth = 1
        layer.borderColor = palette.border.cgColor
        palette.applyDropShadow(to: layer, compact: false)
        label.text = text
        label.textColor = palette.foreground
        palette.applyTextShadow(to: label.layer)
        label.configure(
            maximumPointSize: 18,
            weight: .semibold,
            minimumScaleFactor: 0.55
        )
        label.textAlignment = BrowserOverlayTextFlow.isRightToLeft(text)
            ? .right
            : .center
        label.semanticContentAttribute =
            BrowserOverlayTextFlow.isRightToLeft(text)
                ? .forceRightToLeft
                : .unspecified
        label.numberOfLines = settings.subtitleMaxLines
        accessibilityLabel = text
        accessibilityHint = localizer.string(.overlayCopyHint)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else {
            layer.shadowPath = nil
            return
        }
        layer.shadowPath = UIBezierPath(
            roundedRect: bounds,
            cornerRadius: layer.cornerRadius
        ).cgPath
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) {
            [sourceText, translatedText, localizer] _ in
            var actions = [
                UIAction(
                    title: localizer.string(.overlayCopySource),
                    image: UIImage(systemName: "doc.on.doc")
                ) { _ in
                    UIPasteboard.general.string = sourceText
                },
            ]
            if translatedText != sourceText {
                actions.append(
                    UIAction(
                        title:
                            localizer.string(.overlayCopyTranslation),
                        image: UIImage(
                            systemName: "character.book.closed"
                        )
                    ) { _ in
                        UIPasteboard.general.string = translatedText
                    }
                )
            }
            return UIMenu(children: actions)
        }
    }
}

private final class OverlaySidePanelView: UIView {
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var rowsByKey: [String: OverlayRevealLabel] = [:]

    init(
        items: [BrowserOverlayItem],
        settings: IPhoneOverlaySettings,
        localizer: IPhoneLocalizer
    ) {
        super.init(frame: .zero)
        accessibilityIdentifier =
            "aidoku.reader.overlay.side-panel"
        layer.cornerRadius = 15
        layer.borderWidth = 1
        layer.masksToBounds = false
        scroll.clipsToBounds = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 8
        addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
        ])
        update(items: items, settings: settings, localizer: localizer)
    }

    func update(
        items: [BrowserOverlayItem],
        settings: IPhoneOverlaySettings,
        localizer: IPhoneLocalizer
    ) {
        let palette = OverlayPalette.make(
            mode: settings.colorMode,
            opacity: settings.opacity
        )
        backgroundColor = palette.background
        layer.borderColor = palette.border.cgColor
        palette.applyDropShadow(to: layer, compact: false)

        let stableRegionIDCounts = items.reduce(into: [UInt64: Int]()) {
            counts, item in
            if let stableRegionID = item.stableRegionID {
                counts[stableRegionID, default: 0] += 1
            }
        }
        var nextRows: [String: OverlayRevealLabel] = [:]
        for (index, item) in items.enumerated() {
            let output = item.translatedText ?? item.sourceText
            let key: String
            if let stableRegionID = item.stableRegionID,
               stableRegionIDCounts[stableRegionID] == 1
            {
                key = "region:\(stableRegionID)"
            } else {
                key = "transient:\(index):\(item.sourceText)"
            }
            let label = rowsByKey[key] ?? OverlayRevealLabel(
                prefix: "",
                sourceText: "",
                translatedText: nil,
                localizer: localizer
            )
            label.update(
                prefix: "\(index + 1). ",
                sourceText: item.sourceText,
                translatedText: item.translatedText,
                localizer: localizer
            )
            label.text = "\(index + 1). \(output)"
            label.font = .systemFont(
                ofSize: 14,
                weight: .medium
            )
            label.numberOfLines = 0
            label.textColor = palette.foreground
            label.accessibilityLabel = output
            label.accessibilityIdentifier =
                "aidoku.reader.overlay.item"
            if stack.arrangedSubviews.indices.contains(index),
               stack.arrangedSubviews[index] === label
            {
                // Already in the correct stable position.
            } else {
                if stack.arrangedSubviews.contains(where: { $0 === label }) {
                    stack.removeArrangedSubview(label)
                    label.removeFromSuperview()
                }
                stack.insertArrangedSubview(
                    label,
                    at: min(index, stack.arrangedSubviews.count)
                )
            }
            nextRows[key] = label
        }
        for (key, label) in rowsByKey where nextRows[key] == nil {
            stack.removeArrangedSubview(label)
            label.removeFromSuperview()
        }
        rowsByKey = nextRows
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else {
            layer.shadowPath = nil
            return
        }
        layer.shadowPath = UIBezierPath(
            roundedRect: bounds,
            cornerRadius: layer.cornerRadius
        ).cgPath
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class OverlayRevealLabel: UILabel,
    UIContextMenuInteractionDelegate
{
    private var prefix: String
    private var sourceText: String
    private var translatedText: String?
    private var localizer: IPhoneLocalizer

    init(
        prefix: String,
        sourceText: String,
        translatedText: String?,
        localizer: IPhoneLocalizer
    ) {
        self.prefix = prefix
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.localizer = localizer
        super.init(frame: .zero)
        isUserInteractionEnabled = true
        accessibilityHint = localizer.string(.overlayCopyHint)
        addInteraction(UIContextMenuInteraction(delegate: self))
        updateAccessibility()
    }

    func update(
        prefix: String,
        sourceText: String,
        translatedText: String?,
        localizer: IPhoneLocalizer
    ) {
        self.prefix = prefix
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.localizer = localizer
        accessibilityHint = localizer.string(.overlayCopyHint)
        updateAccessibility()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateAccessibility() {
        accessibilityLabel = translatedText ?? sourceText
        accessibilityValue = nil
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) {
            [sourceText, translatedText, localizer] _ in
            var actions = [
                UIAction(
                    title: localizer.string(.overlayCopySource),
                    image: UIImage(systemName: "doc.on.doc")
                ) { _ in
                    UIPasteboard.general.string = sourceText
                },
            ]
            if let translatedText, translatedText != sourceText {
                actions.append(
                    UIAction(
                        title:
                            localizer.string(.overlayCopyTranslation),
                        image: UIImage(
                            systemName: "character.book.closed"
                        )
                    ) { _ in
                        UIPasteboard.general.string = translatedText
                    }
                )
            }
            return UIMenu(children: actions)
        }
    }
}

private class OverlayFittingLabel: UILabel {
    private struct FontFitInput: Equatable {
        let text: String
        let displayVariant: BrowserOverlayDisplayVariant?
        let verticalRawText: String?
        let availableSize: CGSize
        let minimumPointSize: CGFloat
        let maximumPointSize: CGFloat
        let weightRawValue: CGFloat
    }

    private var maximumPointSize: CGFloat = 17
    private var minimumFittingScale: CGFloat = 0.5
    private var weight: UIFont.Weight = .regular
    private var explicitMinimumPointSize: CGFloat?
    private var displayVariant: BrowserOverlayDisplayVariant?
    private var verticalRawText: String?
    private var displayForegroundColor: UIColor?
    private var displaySecondaryForegroundColor: UIColor?
    private var displayTextShadow: NSShadow?
    private var measurementCache: BrowserOverlayTextMeasurementCache?
    private var cachedFontFitInput: FontFitInput?
    private var cachedFittedPointSize: CGFloat?
    private var appliedDisplayVariant: BrowserOverlayDisplayVariant?
    private var appliedDisplayForegroundColor: UIColor?
    private var appliedDisplaySecondaryForegroundColor: UIColor?
    private var appliedDisplayTextShadow: NSShadow?
    private var appliedDisplayPointSize: CGFloat?
    private var appliedDisplayWidth: CGFloat?
    private var appliedDisplayLineBreakMode: NSLineBreakMode?
    private var appliedVerticalRawText: String?
    private let renderedMeasurementLabel: UILabel = {
        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakStrategy = [.standard, .hangulWordPriority]
        label.textAlignment = .center
        return label
    }()

    fileprivate var usesVerticalCoreTextPainter: Bool {
        verticalRawText != nil
    }

    func configure(
        displayVariant: BrowserOverlayDisplayVariant? = nil,
        verticalRawText: String? = nil,
        foregroundColor: UIColor? = nil,
        secondaryForegroundColor: UIColor? = nil,
        textShadow: NSShadow? = nil,
        maximumPointSize: CGFloat,
        weight: UIFont.Weight,
        minimumScaleFactor: CGFloat,
        minimumPointSize: CGFloat? = nil,
        measurementCache: BrowserOverlayTextMeasurementCache? = nil
    ) {
        self.maximumPointSize = maximumPointSize
        self.weight = weight
        minimumFittingScale = minimumScaleFactor
        explicitMinimumPointSize = minimumPointSize
        self.displayVariant = displayVariant
        self.verticalRawText = verticalRawText
        displayForegroundColor = foregroundColor
        displaySecondaryForegroundColor = secondaryForegroundColor
        displayTextShadow = textShadow
        self.measurementCache = measurementCache
        if verticalRawText != nil {
            lineBreakMode = .byCharWrapping
        } else if displayVariant == nil {
            lineBreakMode = .byWordWrapping
        }
        lineBreakStrategy = [.standard, .hangulWordPriority]
        applyFont(pointSize: maximumPointSize)
        setNeedsLayout()
    }

    func measurementBounds() -> CGRect {
        bounds
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let layoutText = verticalRawText ?? text,
              !layoutText.isEmpty
        else {
            return
        }
        let available = measurementBounds()
        guard available.width > 0, available.height > 0 else { return }

        let minimumPointSize: CGFloat
        if verticalRawText != nil {
            // Match c1's public render contract: the DOM fitter never shrank
            // below `minimumRenderedFontSize`. Preserve that readability floor
            // and let the explicit Core Text clip be the bounded fallback when
            // an adversarially long source still cannot fit.
            minimumPointSize = min(
                maximumPointSize,
                BrowserOverlayLayoutPlanner.minimumRenderedFontSize
            )
        } else {
            minimumPointSize = min(
                maximumPointSize,
                explicitMinimumPointSize ?? max(
                    8,
                    maximumPointSize * minimumFittingScale
                )
            )
        }
        let fitInput = FontFitInput(
            text: layoutText,
            displayVariant: displayVariant,
            verticalRawText: verticalRawText,
            availableSize: available.size,
            minimumPointSize: minimumPointSize,
            maximumPointSize: maximumPointSize,
            weightRawValue: weight.rawValue
        )
        if cachedFontFitInput == fitInput,
           let cachedFittedPointSize
        {
            applyFont(pointSize: cachedFittedPointSize)
            return
        }
        let fittedPointSize: CGFloat
        if textFits(
            layoutText,
            pointSize: maximumPointSize,
            available: available
        ) {
            // The DOM keeps the payload font verbatim when it already fits.
            fittedPointSize = maximumPointSize
        } else if !textFits(
            layoutText,
            pointSize: minimumPointSize,
            available: available
        ) {
            fittedPointSize = minimumPointSize
        } else {
            var low = minimumPointSize
            var high = maximumPointSize
            for _ in 0..<9 {
                let candidate = (low + high) / 2
                if textFits(
                    layoutText,
                    pointSize: candidate,
                    available: available
                ) {
                    low = candidate
                } else {
                    high = candidate
                }
            }
            // c1 floors the paint-time CSS fit to quarter-point increments.
            fittedPointSize = floor(low * 4) / 4
        }
        cachedFontFitInput = fitInput
        cachedFittedPointSize = fittedPointSize
        applyFont(pointSize: fittedPointSize)
    }

    private func textFits(
        _ text: String,
        pointSize: CGFloat,
        available: CGRect
    ) -> Bool {
        if verticalRawText != nil {
            return BrowserOverlayVerticalTextRenderer.fits(
                text: text,
                available: available.size,
                fontSize: pointSize,
                weight: weight
            )
        }
        if let displayVariant {
            let rendered = displayVariant.attributedString(
                fontSize: pointSize,
                availableWidth: available.width,
                measurementCache: measurementCache,
                usesDOMFontFamily: true
            )
            renderedMeasurementLabel.attributedText = rendered
            renderedMeasurementLabel.lineBreakMode =
                displayVariant.lineBreakMode(
                    availableWidth: available.width,
                    fontSize: pointSize,
                    measurementCache: measurementCache
                )
            let measured = renderedMeasurementLabel.textRect(
                forBounds: CGRect(origin: .zero, size: available.size),
                limitedToNumberOfLines: 0
            )
            return ceil(measured.width) <= available.width + 0.5 &&
                ceil(measured.height) <= available.height + 0.5
        }
        return BrowserOverlayLayoutPlanner.horizontalTextFits(
            text,
            available: available.size,
            fontSize: pointSize,
            weight: weight
        )
    }

    private func applyFont(pointSize: CGFloat) {
        if let verticalRawText {
            applyVerticalFont(
                text: verticalRawText,
                pointSize: pointSize
            )
            return
        }
        if appliedVerticalRawText != nil {
            appliedDisplayVariant = nil
        }
        appliedVerticalRawText = nil
        guard let displayVariant else {
            appliedDisplayVariant = nil
            appliedDisplayForegroundColor = nil
            appliedDisplaySecondaryForegroundColor = nil
            appliedDisplayTextShadow = nil
            appliedDisplayPointSize = nil
            appliedDisplayWidth = nil
            appliedDisplayLineBreakMode = nil
            if abs(font.pointSize - pointSize) > 0.01 {
                font = .systemFont(ofSize: pointSize, weight: weight)
            }
            return
        }

        // Attributed variants carry a font on every run. Writing UILabel.font
        // as well makes UIKit invalidate its baseline constraints and then
        // restore the first run's font while laying out the attributed text.
        // The next layout writes UILabel.font again, creating an unbounded
        // layout loop (and visible flicker) for dual source/translation cards.
        // Cache the semantic render state and never mutate UILabel from inside
        // layout when the rendered value is already current.
        let availableWidth = measurementBounds().width
        let nextLineBreakMode = displayVariant.lineBreakMode(
            availableWidth: availableWidth,
            fontSize: pointSize,
            measurementCache: measurementCache
        )
        let sameForeground = colorsEqual(
            appliedDisplayForegroundColor,
            displayForegroundColor
        )
        let sameSecondaryForeground = colorsEqual(
            appliedDisplaySecondaryForegroundColor,
            displaySecondaryForegroundColor
        )
        let sameTextShadow = textShadowsEqual(
            appliedDisplayTextShadow,
            displayTextShadow
        )
        let isAlreadyApplied =
            appliedDisplayVariant == displayVariant &&
            sameForeground &&
            sameSecondaryForeground &&
            sameTextShadow &&
            appliedDisplayPointSize.map {
                abs($0 - pointSize) <= 0.01
            } == true &&
            appliedDisplayWidth.map {
                abs($0 - availableWidth) <= 0.01
            } == true &&
            appliedDisplayLineBreakMode == nextLineBreakMode
        guard !isAlreadyApplied else { return }

        // Store first so even a synchronous UIKit invalidation cannot apply
        // the same state recursively.
        appliedDisplayVariant = displayVariant
        appliedDisplayForegroundColor = displayForegroundColor
        appliedDisplaySecondaryForegroundColor =
            displaySecondaryForegroundColor
        appliedDisplayTextShadow = displayTextShadow
        appliedDisplayPointSize = pointSize
        appliedDisplayWidth = availableWidth
        appliedDisplayLineBreakMode = nextLineBreakMode
        if lineBreakMode != nextLineBreakMode {
            lineBreakMode = nextLineBreakMode
        }
        attributedText = displayVariant.attributedString(
            fontSize: pointSize,
            foregroundColor: displayForegroundColor,
            secondaryForegroundColor: displaySecondaryForegroundColor,
            textShadow: displayTextShadow,
            availableWidth: availableWidth,
            measurementCache: measurementCache,
            usesDOMFontFamily: true
        )
    }

    override func drawText(in rect: CGRect) {
        guard let verticalRawText,
              let context = UIGraphicsGetCurrentContext()
        else {
            super.drawText(in: rect)
            return
        }
        BrowserOverlayVerticalTextRenderer.draw(
            text: verticalRawText,
            in: rect,
            context: context,
            fontSize: appliedDisplayPointSize ?? maximumPointSize,
            weight: weight,
            foregroundColor: displayForegroundColor,
            textShadow: displayTextShadow
        )
    }

    private func applyVerticalFont(
        text: String,
        pointSize: CGFloat
    ) {
        let availableWidth = measurementBounds().width
        let sameForeground = colorsEqual(
            appliedDisplayForegroundColor,
            displayForegroundColor
        )
        let sameTextShadow = textShadowsEqual(
            appliedDisplayTextShadow,
            displayTextShadow
        )
        let isAlreadyApplied =
            appliedVerticalRawText == text &&
            sameForeground &&
            sameTextShadow &&
            appliedDisplayPointSize.map {
                abs($0 - pointSize) <= 0.01
            } == true &&
            appliedDisplayWidth.map {
                abs($0 - availableWidth) <= 0.01
            } == true
        guard !isAlreadyApplied else { return }

        appliedVerticalRawText = text
        appliedDisplayVariant = displayVariant
        appliedDisplayForegroundColor = displayForegroundColor
        appliedDisplaySecondaryForegroundColor = nil
        appliedDisplayTextShadow = displayTextShadow
        appliedDisplayPointSize = pointSize
        appliedDisplayWidth = availableWidth
        appliedDisplayLineBreakMode = .byCharWrapping
        if lineBreakMode != .byCharWrapping {
            lineBreakMode = .byCharWrapping
        }
        attributedText = BrowserOverlayVerticalTextRenderer.attributedString(
            text: text,
            fontSize: pointSize,
            weight: weight,
            foregroundColor: displayForegroundColor,
            textShadow: displayTextShadow
        )
        setNeedsDisplay()
    }

    private func colorsEqual(_ left: UIColor?, _ right: UIColor?) -> Bool {
        switch (left, right) {
        case (nil, nil):
            return true
        case let (left?, right?):
            return left.isEqual(right)
        default:
            return false
        }
    }

    private func textShadowsEqual(
        _ left: NSShadow?,
        _ right: NSShadow?
    ) -> Bool {
        switch (left, right) {
        case (nil, nil):
            return true
        case let (left?, right?):
            guard left.shadowOffset == right.shadowOffset,
                  abs(left.shadowBlurRadius - right.shadowBlurRadius) <= 0.01
            else {
                return false
            }
            return colorsEqual(
                left.shadowColor as? UIColor,
                right.shadowColor as? UIColor
            )
        default:
            return false
        }
    }
}

private final class OverlayFittingInsetLabel: OverlayFittingLabel {
    private var contentInsets = BrowserOverlayCardTextInsets.regular

    func setContentInsets(_ next: UIEdgeInsets) {
        guard contentInsets != next else { return }
        contentInsets = next
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        setNeedsDisplay()
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: effectiveContentInsets))
    }

    override func measurementBounds() -> CGRect {
        bounds.inset(by: effectiveContentInsets)
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        let insets = effectiveContentInsets
        return CGSize(
            width: size.width + insets.left + insets.right,
            height: size.height + insets.top + insets.bottom
        )
    }

    private var effectiveContentInsets: UIEdgeInsets { contentInsets }
}
