// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import CoreGraphics
import Foundation
import UIKit

/// A single worker bounds bitmap allocation and keeps final text work off the reader's main actor.
private actor NativeTranslationRenderWorker {
    static let shared = NativeTranslationRenderWorker()
    private let admission = NativeTranslationRenderAdmission()

    func render(layout: NativeTranslationLayout, image: UIImage?, settings: IPhoneOverlaySettings,
                scale: CGFloat, dark: Bool, renderBounds: CGRect?, composeSource: Bool, outputPixelSize: CGSize?, collectDiagnostics: Bool, capturePDF: Bool, pdfDeviceScale: CGFloat) async throws -> NativeTranslationRenderer.Result {
        let lease = try await admission.acquire()
        let result: NativeTranslationRenderer.Result
        do {
            // The helper unwinds its mutable plan/context/session before this lease is released.
            result = try await NativeTranslationRenderer.renderOnWorker(layout: layout, image: image,
                settings: settings, scale: scale, dark: dark, renderBounds: renderBounds,
                composeSource: composeSource, outputPixelSize: outputPixelSize,
                collectDiagnostics: collectDiagnostics, capturePDF: capturePDF, pdfDeviceScale: pdfDeviceScale)
        } catch {
            await lease.release()
            throw error
        }
        await lease.release()
        try Task.checkCancellation()
        return result
    }
}

/// Native bitmap composition. The transparent layer is shared by live presentation and cache/export replay,
/// so those routes never rasterize the same translated glyphs through different rendering engines.
enum NativeTranslationRenderer {
    struct SourcePatch: @unchecked Sendable {
        let image: CGImage
        let rect: CGRect
        let cleanupClip: CGRect?
        let liveOrder: Double?
        /// Original canvas CSS assignments, before LayoutUnit conversion.
        let authoredCanvasRect: CGRect?
        init(image: CGImage, rect: CGRect, cleanupClip: CGRect? = nil, liveOrder: Double? = nil,
             authoredCanvasRect: CGRect? = nil) {
            self.image = image; self.rect = rect; self.cleanupClip = cleanupClip; self.liveOrder = liveOrder
            self.authoredCanvasRect = authoredCanvasRect
        }
    }

    struct Result: @unchecked Sendable {
        let image: UIImage
        let overlayImage: UIImage
        let layoutData: Data
        let renderedItemCount: Int
        let limitations: [String]
        let renderBounds: CGRect
        let diagnosticData: Data?
        let exportPDFData: Data?
        let sourceRestorationRects: [CGRect]
        let paintBounds: [CGRect]
        let sourcePatches: [SourcePatch]
    }

    enum RenderError: Error {
        case invalidGeometry
        case bitmapTooLarge
        case incompatibleLayout
        case sourceImageUnavailable
    }

    struct TextPart {
        let text: String
        let frame: CGRect
        let typography: NativeTranslationTypography.Layout
        let style: NativeTranslationTypography.Style
    }

    struct Card {
        var item: NativeTranslationLayoutItem
        var typography: NativeTranslationTypography.Layout
        var style: NativeTranslationTypography.Style
        var strokePreserved = false
        var darkMeasured = false
        var inkBeforeSurface: [Double]?
        var clusterRGB: [Double]?
        var sourceRestorationMetadata: [String:String] = [:]
        var artworkRecord: [String:String]?
        var sourceAlignment: String?
        var sourceHeading: String?
        var restoredSurfaceFontFit = false
        /// Membership in the early margin certificate Set, independent of canvas completion.
        var earlyErasureCertified = false
        var sourcePanelTextFit: String?
        var readableFloorHeld: [Double]?
        var balloonCenterShift: CGPoint?
        var plateGrowthRecord: [String: Any]?
        var edgeFit: String?
        var rotatedReadability: [String: String]?
        var stackRepair: [Any]?
        var stackRepairDeclined: [String: Any]?
        var unitTextParts: [TextPart] = []
        var unitTextPartsOrigin: CGPoint?
        var unitParts: [Double]?
        var unitContainment: [Any]?
        // Page-space authored CSS origin; a child local zero is its used parent origin.
        // The origin precedes node LayoutUnit quantization and horizontal scaling.
        var authoredTextOrigin: CGPoint?
        var initialCaptionCSS: InitialCaptionCSS?
        var harmonyRecord: [String: Any] = [:]
        /// Exact displayGrowth mode written by the original typography producer.
        var typographyDisplayGrowth: String? = nil
        var sourceBackgroundKind: String?
        var sourceStrokeKind: String? = "none"
        var captionParentPlate = false
        var captionParentOwner: CaptionParentOwner?
        var captionReflow: [String:Any]?
        var captionPackingRecord: [String:Any]?
        var sourcePanelZ = 1
        var paintOrderLift: String?
        var textZ = 2
        var textRootOrder: Double?
        var sourceColumnAuthoredTop: CGFloat?
        var sourceTopAnchored = false
        var lateSourcePatchOrder: Double?
        var rotatedPlateZ = 1
        var rotatedPlateOrder: Double?
        var sourceLayersSuppressed = false
        var finalPlateTrim: [Int]?
        var latePlateTrimTrace: [[String: Any]] = []
        var displayLetteringRecord: [String: Any]?
        var displayLetteringReject: String?
        var displayRestored = false
        var displayCardGrowth = false
        var displayGroup: [String: Any]?
        var letteringUnitRecord: [String: Any]?
        var polarityRecord: [String: Any]?
        var polarityRejection: String?
        var sourcePlateOwnerRect: CGRect?
        var sourcePlateRect: CGRect { sourcePlateOwnerRect ?? item.rect }
        var textRotation: CGFloat?
        var effectiveTextRotation: CGFloat { textRotation ?? (item.drawsUprightQuadText ? 0 : item.rotation) }
        var columnFrameImages: [SourcePatch] = []
        var lineOffsets: [CGPoint] = []
        var typographyWidth: CGFloat?
        var textLayoutSize: CGSize { CGSize(width: typographyWidth ?? item.contentRect.width,height: item.contentRect.height) }
        var glyphCoverRecord: [String: Any]?
        var glyphCoverPatch: SourcePatch?
        var glyphCoverLayerZ: Int?
        var glyphCoverLayerOrder: Double?
        var glyphCoverOwnerPanel: NativeTranslationSourceStylePostPolish.Panel?
        var slantedTrial: NativeSlantedTypographyTrial.Result?
        var slantedClip: [[Double]]?
        var glyphCoverReject: String?
        var outlinedRecord: [String: Any]?
        var outlineEvidence: NativeSourceOutlineScan.Analysis?
        var glyphPlateReleased = false
        var partialSourcePositionProof = false
        var outlineGlow: CGFloat = 0
        var lightLetteringRecord: [String: Any]?
        var lightLetteringReject: String?
        var rotatesSourcePanels = false
        var finalUprightText = false
        var panelStraightened = false
        var straightenedPanelRect: CGRect?
        var preservedGloss = false
        var preservedErasure = false
        var sourcePanels: [NativeTranslationSourceStylePostPolish.Panel] = []
        var backings: [NativePanelGeometry.Backing] = []
        var foreignFills: [NativeCaptionPacking.ForeignFill] = []
        var textShift: CGPoint = .zero
        var textOrigin: CGPoint { CGPoint(x: item.contentRect.minX + textShift.x, y: item.contentRect.minY + textShift.y) }
        var cleanupSourceFrame: CGRect?
        var drawsPanel: Bool
        var background: CGColor
        var usesFallbackVeil: Bool
        let lightSurface: Bool
        var heavyStrokeWidth: CGFloat
        var finalFontSize: CGFloat
    }

    struct GlossCard {
        let note: NativeTranslationEffectGloss.Note
        var typography: NativeTranslationTypography.Layout
        var style: NativeTranslationTypography.Style
    }

    static func sourceRect(imageSize: CGSize, viewport: CGSize, aspectFit: Bool) -> CGRect {
        ReaderTranslationGeometry.displayRect(CGRect(x: 0, y: 0, width: 1, height: 1), imageSize: imageSize,
                                             bounds: CGRect(origin: .zero, size: viewport), aspectFit: aspectFit)
    }

    /// Preserve logical card geometry while bounding the uncached reader's device-density bitmap.
    static func boundedRasterScale(viewport: CGSize, requestedScale: CGFloat) -> CGFloat {
        guard valid(viewport), requestedScale.isFinite, requestedScale > 0 else { return 0 }
        var upper = min(requestedScale, 16_384 / max(viewport.width, viewport.height),
                        sqrt(12_000_000 / viewport.width / viewport.height))
        if (try? validate(viewport: viewport, scale: upper)) != nil { return upper }
        var lower: CGFloat = 0
        for _ in 0..<32 {
            let candidate = (lower + upper) / 2
            if (try? validate(viewport: viewport, scale: candidate)) != nil { lower = candidate } else { upper = candidate }
        }
        return lower
    }

    static func render(image: UIImage?, imageSize: CGSize, items: [BrowserOverlayItem], settings: IPhoneOverlaySettings,
                       targetLanguage: String, viewport: CGSize, scale: CGFloat = 1, aspectFit: Bool = true,
                       dark: Bool = false, preparedLayout: Data? = nil, renderBounds: CGRect? = nil,
                       composeSource: Bool = true, outputPixelSize: CGSize? = nil, collectDiagnostics: Bool = false, capturePDF: Bool = false, pdfDeviceScale: CGFloat = 1) async throws -> Result {
        try Task.checkCancellation()
        guard valid(viewport), scale.isFinite, scale > 0 else { throw RenderError.invalidGeometry }
        try validate(viewport: outputPixelSize ?? renderBounds?.size ?? viewport, scale: outputPixelSize == nil ? scale : 1)
        let frame = sourceRect(imageSize: imageSize, viewport: viewport, aspectFit: aspectFit)
        var layout: NativeTranslationLayout
        if let preparedLayout,
           let candidate = try? JSONDecoder().decode(NativeTranslationLayout.self, from: preparedLayout),
           candidate.version == NativeTranslationLayout.currentVersion,
           candidate.imageSize == imageSize, candidate.sourceRect == frame,
           ReaderTranslationGeometry.sameViewport(candidate.viewport, viewport) {
            layout = candidate
        } else {
            let data = try await NativeTranslationLayoutPlanner.prepareLayoutData(
                items: settings.visible ? items : [], imageSize: imageSize, sourceRect: frame,
                settings: settings, targetLanguage: targetLanguage, viewport: viewport)
            layout = try JSONDecoder().decode(NativeTranslationLayout.self, from: data)
        }
        layout = NativeTranslationLayout(imageSize: layout.imageSize, sourceRect: layout.sourceRect, viewport: layout.viewport,
            items: layout.items, readableRecoveryRemaining: layout.readableRecoveryRemaining, sourceObjectFit: aspectFit ? "contain" : "fill")
        try Task.checkCancellation()
        return try await NativeTranslationRenderWorker.shared.render(
            layout: layout, image: image, settings: settings, scale: scale, dark: dark,
            renderBounds: renderBounds, composeSource: composeSource, outputPixelSize: outputPixelSize, collectDiagnostics: collectDiagnostics, capturePDF: capturePDF, pdfDeviceScale: pdfDeviceScale)
    }

    /// Callers outside the async entrypoint must serialize this CPU-heavy operation themselves.
    static func renderSynchronously(layout: NativeTranslationLayout, image: UIImage?, settings: IPhoneOverlaySettings,
                                    scale: CGFloat = 1, dark: Bool = false, renderBounds: CGRect? = nil,
                                    composeSource: Bool = true, outputPixelSize: CGSize? = nil, collectDiagnostics: Bool = false, capturePDF: Bool = false, pdfDeviceScale: CGFloat = 1) throws -> Result {
        let plan = try prepareRenderSynchronously(layout: layout, image: image, settings: settings,
            scale: scale, dark: dark, renderBounds: renderBounds, composeSource: composeSource,
            outputPixelSize: outputPixelSize, collectDiagnostics: collectDiagnostics, capturePDF: capturePDF,
            pdfDeviceScale: pdfDeviceScale)
        return try finishPreparedSynchronously(plan)
    }

    /// Private worker value. CoreText/layout/context values never cross to UIKit's actor.
    struct PreparedRender {
        let inputLayout: NativeTranslationLayout
        let layout: NativeTranslationLayout
        let image: UIImage?
        let source: CGImage?
        let restoration: NativeTranslationRestoration.Result
        let cards: [Card]
        let glossCards: [GlossCard]
        let gloss: NativeTranslationEffectGloss.Refinement
        let settings: IPhoneOverlaySettings
        let bounds: CGRect
        let pixels: CGSize
        let scale: CGFloat
        let composeSource: Bool
        let capturePDF: Bool
        let pdfDeviceScale: CGFloat
        let sourcePatches: [SourcePatch]
        let sourcePieces: [CGRect]
        let limitations: [String]
        let diagnosticData: Data?
    }
    /// Callers outside the async entrypoint must serialize this CPU-heavy operation themselves.
    static func prepareRenderSynchronously(layout: NativeTranslationLayout, image: UIImage?, settings: IPhoneOverlaySettings,
                                    scale: CGFloat = 1, dark: Bool = false, renderBounds: CGRect? = nil,
                                    composeSource: Bool = true, outputPixelSize: CGSize? = nil, collectDiagnostics: Bool = false, capturePDF: Bool = false, pdfDeviceScale: CGFloat = 1) throws -> PreparedRender {
        try Task.checkCancellation()
        let inputLayout = layout
        let bounds = renderBounds ?? CGRect(origin: .zero, size: layout.viewport)
        guard valid(bounds), valid(layout.viewport), scale.isFinite, scale > 0 else { throw RenderError.invalidGeometry }
        try validate(viewport: outputPixelSize ?? bounds.size, scale: outputPixelSize == nil ? scale : 1)
        guard layout.version == NativeTranslationLayout.currentVersion else { throw RenderError.incompatibleLayout }
        guard valid(layout.sourceRect), valid(layout.imageSize), layout.items.count <= 4_096 else { throw RenderError.invalidGeometry }
        return try autoreleasepool {
            let needsSourceSampling = settings.visible && layout.items.contains { !$0.keptLettering && !$0.text.isEmpty }
            let source = needsSourceSampling ? try restorationImage(image) : nil
            let cleanupGeometry = source.flatMap { normalizedCleanupGeometry(layout: layout, naturalSize: CGSize(width: $0.width, height: $0.height)) }
            let slantedContext = SlantedContext(layout: layout, source: source, settings: settings, cleanupGeometry: cleanupGeometry)
            var restoration = settings.visible
                ? try NativeTranslationRestoration.prepare(image: source, layout: layout, settings: settings,
                    acceptSlanted: { item,appearance,proof,pixelScale in
                        slantedContext.admit(item: item, appearance: appearance, proof: proof, scale: pixelScale)
                    }, acceptPageSlanted: { item,appearance,prepared,pixels in
                        slantedContext.admitPage(item: item, appearance: appearance, prepared: prepared, pixels: pixels)
                    }, cleanupGeometry: cleanupGeometry, collectDiagnostics: collectDiagnostics)
                : NativeTranslationRestoration.Result()
            let initialPatchCapture = collectDiagnostics ? NativeRestorationDiagnosticCapture.capture(restoration) : nil
            var layout = try NativeTranslationLayoutPlanner.refining(
                layout: slantedContext.applyInitial(to: adjustInitialJoinedUnits(layout: layout, restoration: restoration)), restoration: restoration, settings: settings, sourceImage: source, lockedIDs: slantedContext.lockedIDs)
            let growthSession = NativeTypographyPostPolish.rendererGrowthSession(
                layout: layout, restoration: restoration, settings: settings, sourceImage: source)
            growthSession.collectInitialDiagnostics = collectDiagnostics
            layout = try NativeTypographyPostPolish.refining(
                layout: layout, restoration: restoration, settings: settings, sourceImage: source, growthSession: growthSession, lockedIDs: slantedContext.lockedIDs, phase: .initial)
            var cards: [Card] = []
            var limitations = restoration.limitations
            let sourceWeights = restoration.sourceLetterWeights
            let pageWeight = sourceWeights.count >= 3 ? sourceWeights[sourceWeights.count / 2] : Double.nan
            for var item in settings.visible ? layout.items : [] where !item.keptLettering && !item.text.isEmpty {
                try Task.checkCancellation()
                let authoredOrigin = CGPoint(x: item.x, y: item.y)
                let initialCaptionCSS = InitialCaptionCSS(item: item)
                item = usedLayoutItem(item)
                guard valid(item.rect), valid(item.contentRect),
                      [item.fontSize, item.lineHeight, item.rotation].allSatisfy(\.isFinite),
                      item.fontSize >= BrowserOverlayLayoutPlanner.minimumRenderedFontSize else { continue }
                // Invalid cached metrics must not let a CoreText frame allocate arbitrary amounts of memory.
                guard item.fontSize <= 2_048, item.lineHeight <= 4_096,
                      [item.paddingTop, item.paddingLeft, item.paddingBottom, item.paddingRight].allSatisfy({ $0.isFinite && $0 >= 0 }),
                      item.text.utf16.count <= 32_768 else { throw RenderError.invalidGeometry }
                let appearance = restoration.appearances[item.id]
                let restoredCanvasAttached = restoration.patches.contains { $0.itemID == item.id && !$0.independentArtworkCover }
                if item.uprightQuadText, !item.vertical, item.rotation != 0, let source {
                    item.drawsUprightQuadText = try quadInkFitsUprightBox(item, image: source, appearance: appearance)
                }
                let foreground = settings.preserveSourceTextColor ? appearance?.foreground : nil
                let surface = settings.preserveSourceBackgroundColor ? appearance?.background : nil
                let panelInk = surface.map { panelForeground($0, opacity: CGFloat(settings.renderedBackgroundOpacity)) }
                let lightSurface = panelInk.map { ($0.components?.first ?? 1) < 1 } ?? item.lightSurface
                var style = NativeTranslationTypography.Style(
                    fontName: settings.preserveSourceColors && item.fontScript == "korean" ? appearance?.fontName : nil,
                    fontScript: item.fontScript, fontSize: item.fontSize, vertical: item.vertical,
                    foreground: item.typesettingForeground.map { color($0.map { CGFloat($0) }) } ?? foreground ?? panelInk ?? color(lightSurface ? [17, 18, 23] : [255, 255, 255]),
                    outlinePaintOrder: .fillThenStroke,
                    tracking: -item.fontSize * 0.012, lineHeight: max(item.fontSize, item.lineHeight),
                    alignsToTop: item.balancedColumn)
                style.balancesHorizontalLines = item.wrappingScript == "korean" && !item.vertical &&
                    item.text.utf16.count <= 180 && !item.text.contains("\n")
                style.horizontalScale = item.typesettingWidthScale ?? 1
                style.outline = item.typesettingOutlineRGB.map { color($0.map { CGFloat($0) }) }
                style.outlineWidth = item.typesettingOutlineWidth ?? 0
                if style.outline != nil, style.outlineWidth > 0 { style.outlinePaintOrder = .strokeThenFill }
                style.optimizesKoreanWrapping = false
                style.koreanQuoteMode = item.typesettingQuoteMode ?? 0
                style.usesBlockWordLayout = item.typesettingText != nil && item.typesettingQuoteMode != nil
                style.usesPreformattedBlockRows = item.typesettingText != nil && item.typesettingPreformattedRows == true
                style.blockWordLayoutUsesTopPadding = (style.usesBlockWordLayout || style.usesPreformattedBlockRows) && item.typesettingBlockDisplay == true
                style.strictLineBreak = item.typesettingStrictLineBreak ?? false
                style.horizontalWrapping = item.wrappingScript == "korean" && !style.strictLineBreak ? .keepAllWithEmergency : .normal
                let typography = fitted(text: item.typesettingText ?? item.text, size: item.contentRect.size, style: &style, item: item)
                if !typography.fits { limitations.append("text-overflow:\(item.id)") }
                if item.smallTextReference != nil, !item.smallTextReferenceResolved {
                    limitations.append("small-text-reference-unresolved:\(item.id)")
                }
                if style.fontName == "AidokuSerifKR-Bold", !NativeTranslationTypography.isBundledSerifAvailable {
                    limitations.append("serif-font-unavailable:\(item.id)")
                }
                let sourceWeight = appearance?.sourceStrokeWeight ?? 0
                let heavy = settings.preserveSourceColors && appearance?.letteringStyle == "gothic" &&
                    ((sourceWeight >= 0.14 && style.fontSize >= 14) ||
                     (sourceWeight >= 0.11 && sourceWeight >= pageWeight * 1.3 && style.fontSize >= 12))
                if heavy { style.outlinePaintOrder = .strokeThenFill }
                // Observed source surfaces receive a separate final readability plate when glyph safety remains unproven.
                let preservesSurface = settings.preserveSourceBackgroundColor && item.sourceColorEligible
                cards.append(Card(item: item, typography: typography, style: style, inkBeforeSurface: rgb(style.foreground),
                    authoredTextOrigin: authoredOrigin, initialCaptionCSS: initialCaptionCSS,
                    sourceBackgroundKind: initialSourceBackgroundKind(item: item, appearance: appearance, settings: settings, restoredCanvasAttached: restoredCanvasAttached),
                    cleanupSourceFrame: restoration.cleanupGeometry?.frame ?? layout.sourceRect,
                    drawsPanel: !restoredCanvasAttached && !preservesSurface,
                    background: surface ?? color(lightSurface ? [255, 254, 249] : [7, 9, 13]),
                    usesFallbackVeil: surface == nil, lightSurface: lightSurface,
                    heavyStrokeWidth: heavy ? (style.fontSize * 0.045 * 100).rounded() / 100 : 0,
                    finalFontSize: style.fontSize))
            }
            prepareSourcePanels(cards: &cards, restoration: restoration, layout: layout, settings: settings, growthSession: growthSession)
            applyCaptionFixedBoxReflow(cards: &cards, layout: layout, settings: settings)
            let artworkBudget = try protectInitialArtwork(cards: &cards, restoration: &restoration,
                layout: layout, source: source, settings: settings, surfaceQuery: { card,rects,foreground,remaining in
                    guard let ink = rgb(foreground), let range = growthSession.inspectSurface(item: card.item,
                        typography: card.typography, rects: rects, allowExterior: true, lookupBudget: &remaining), range.count == 2 else { return false }
                    return NativeTranslationSourceStylePostPolish.luminanceContrast(NativeSourceColorSampler.luminance(ink),range[0],range[1]) >= 4.5
                }, restoredSourcePanelIDs: Set(cards.filter { growthSession.context.restored($0.item.id) }.map { $0.item.id }))
            growthSession.artworkSurfaceRemaining = artworkBudget.surface
            for card in cards {
                if let record = card.artworkRecord, let original = Double(record["artworkOriginalFont"] ?? "") {
                    growthSession.commitArtwork(item: card.item, originalFont: CGFloat(original),
                        restoredInside: record["artworkFit"] == "restored-surface")
                }
            }
            applySourceStyles(to: &cards, restoration: restoration, settings: settings, stage: .initialInk, itemCount: layout.items.count)
            let balloons = BalloonRelayoutContext(layout: layout, source: source, restoration: restoration, cards: cards)
            polishPanelGeometry(cards: &cards, gloss: .init(), layout: layout, restoration: restoration, settings: settings, phase: .anchorBacking, restoredSourcePanelIDs: Set(cards.filter { growthSession.context.restored($0.item.id) }.map { $0.item.id }), rememberedPadding: Dictionary(cards.map { ($0.item.id, growthSession.rememberedInk(id: $0.item.id)?.pad ?? 0) }, uniquingKeysWith: { _, last in last }))
            applyEarlyMargins(cards: &cards, restoration: &restoration, layout: layout, source: source, settings: settings,
                growth: growthSession, balloons: balloons)
            polishPanelGeometry(cards: &cards, gloss: .init(), layout: layout, restoration: restoration, settings: settings, phase: .compactOnly, restoredSourcePanelIDs: Set(cards.filter { growthSession.context.restored($0.item.id) }.map { $0.item.id }), rememberedPadding: Dictionary(cards.map { ($0.item.id, growthSession.rememberedInk(id: $0.item.id)?.pad ?? 0) }, uniquingKeysWith: { _, last in last }))
            applyEarlyPlateContrast(cards: &cards, layout: layout, restoration: restoration, settings: settings)
            if settings.renderedBackgroundOpacity == 1, settings.preserveSourceBackgroundColor, layout.items.count <= 256 {
                let currentLayout = NativeTranslationLayout(imageSize: layout.imageSize, sourceRect: layout.sourceRect,
                    viewport: layout.viewport, items: layout.items.map { item in cards.first(where: { $0.item.id == item.id })?.item ?? item },
                    readableRecoveryRemaining: layout.readableRecoveryRemaining, sourceObjectFit: layout.sourceObjectFit)
                commitLocalRestorationProposals(cards: &cards, restoration: &restoration, growth: growthSession, layout: currentLayout)
            }
            applySlantedTrials(cards: &cards, restoration: &restoration, layout: layout, source: source, settings: settings, context: slantedContext)
            var gloss = oversizedTitleGloss(cards: &cards, layout: layout, restoration: restoration, settings: settings, source: source)
            balloons.refresh(cards: cards, restoration: restoration)
            packCaptions(cards: &cards, gloss: gloss, layout: layout, restoration: restoration, settings: settings, source: source, balloons: balloons, collectDiagnostics: collectDiagnostics,
                rememberedPadding: Dictionary(cards.map { ($0.item.id, growthSession.rememberedInk(id: $0.item.id)?.pad ?? 0) }, uniquingKeysWith: { _, last in last }))
            let plateSession = PlateGrowthSession()
            defer { plateSession.close() }
            try growPlateTypography(cards: &cards, layout: layout, restoration: restoration, settings: settings, source: source, gloss: gloss, growthSession: growthSession, plateSession: plateSession)
            repairGrownTypographyWords(cards: &cards, restoration: restoration, layout: layout, growthSession: growthSession,
                hiddenIDs: gloss.hiddenIDs, removedIDs: gloss.removedLayerIDs)
            try reconcileTypographyHarmony(cards: &cards, layout: layout, restoration: restoration, settings: settings, source: source, growthSession: growthSession, lockedIDs: slantedContext.lockedIDs, plateSession: plateSession, hiddenIDs: gloss.hiddenIDs.union(gloss.removedLayerIDs), removedIDs: gloss.removedLayerIDs)
            prepareFinalTrials(cards: &cards,restoration: &restoration,gloss: gloss,layout: layout,settings: settings,source: source,balloonStage: true)
            fitLatePageEdges(cards: &cards, gloss: gloss, layout: layout)
            applySourceAlignment(cards: &cards, gloss: gloss, layout: layout, restoration: restoration, settings: settings, source: source)
            if settings.renderedBackgroundOpacity == 1 { commitBalloonUnits(cards: &cards,gloss: gloss,layout: layout,restoration: restoration, restoredSourcePanelIDs: Set(cards.filter { growthSession.context.restored($0.item.id) }.map { $0.item.id })) }
            applySourceStyles(to: &cards,restoration: restoration,settings: settings,stage: .finalContrast, itemCount: layout.items.count)
            minimalRestoredPlates(cards: &cards, gloss: gloss, layout: layout, restoration: restoration, settings: settings)
            containJoinedBalloonUnits(cards: &cards, gloss: gloss, layout: layout, restoration: restoration, settings: settings, balloons: balloons)
            splitBalloonUnitParts(cards: &cards, gloss: gloss, layout: layout, restoration: restoration, settings: settings, balloons: balloons)
            holdLateReadableFloor(cards: &cards, gloss: gloss, layout: layout, restoration: restoration, settings: settings)
            clipLateBalloonPanels(cards: &cards, gloss: gloss, layout: layout, settings: settings, balloons: balloons)
            centerLateBalloonBodies(cards: &cards, gloss: gloss, layout: layout, settings: settings)
            try restoreSourceFrameLines(cards: &cards, gloss: gloss, layout: layout, source: source, settings: settings)
            _ = try liftFinalRotatedReadability(cards: &cards, gloss: gloss, layout: layout, source: source, settings: settings)
            repairKoreanStacks(cards: &cards, gloss: gloss, layout: layout, restoration: restoration, source: source, settings: settings)
            applyPaintOrderLifts(cards: &cards, gloss: gloss, layout: layout, settings: settings)
            var displayRestoreMetadata = Dictionary(cards.map { card in
                (card.item.id, DisplayCohortMetadata(backgroundKind: card.sourceBackgroundKind,
                    strokeKind: card.sourceStrokeKind, surfaceRange: cardSurfaceEvidence(card, restoration: restoration)?.range))
            }, uniquingKeysWith: { _,last in last })
            _ = try restoreDisplayLettering(cards: &cards, gloss: gloss, layout: layout, restoration: &restoration,
                settings: settings, source: source, metadata: &displayRestoreMetadata)
            preparePrimaryOutlines(cards: &cards, gloss: gloss, layout: layout, source: source, restoration: restoration, settings: settings)
            preserveLetteringPolarity(cards: &cards, gloss: gloss, layout: layout, restoration: restoration, settings: settings)
            let displayMetadata = Dictionary(cards.map { card in
                (card.item.id, DisplayCohortMetadata(backgroundKind: card.sourceBackgroundKind,
                    strokeKind: card.sourceStrokeKind, surfaceRange: cardSurfaceEvidence(card, restoration: restoration)?.range))
            }, uniquingKeysWith: { first,_ in first })
            reconcileDisplayStyleCohorts(cards: &cards, layout: layout, restoration: restoration, settings: settings, gloss: gloss, metadata: displayMetadata)
            applyLetteringUnitPalette(cards: &cards, gloss: gloss, layout: layout, restoration: restoration, settings: settings)
            applyDisplayGroups(cards: &cards, gloss: gloss, layout: layout, settings: settings)
            let trimmed = applyLatePlateTrim(cards: &cards, gloss: gloss, layout: layout, restoration: restoration, source: source, settings: settings, collectDiagnostics: collectDiagnostics)
            for index in cards.indices { cards[index].finalPlateTrim = trimmed[cards[index].item.id] }
            _ = try linkFinalPlates(cards: &cards, gloss: gloss, layout: layout, restoration: restoration, source: source, settings: settings)
            applyGlyphCover(cards: &cards, restoration: &restoration, layout: layout, source: source, settings: settings, gloss: gloss)
            for index in cards.indices where cards[index].glyphCoverPatch != nil {
                let card = cards[index]
                cards[index].glyphCoverLayerZ = card.rotatesSourcePanels ? card.rotatedPlateZ : (card.captionParentPlate ? card.sourcePanelZ : 1)
                cards[index].glyphCoverLayerOrder = card.rotatesSourcePanels
                    ? card.rotatedPlateOrder ?? Double(cards.count * 3 + index) : Double(cards.count + index)
            }
            extendWidenedDisplayClip(cards: &cards)
            applyLightLettering(cards: &cards,layout: layout,restoration: restoration,settings: settings,source: source)
            for index in cards.indices {
                let card = cards[index], appearance = restoration.appearances[card.item.id], weight = appearance?.sourceStrokeWeight ?? 0
                let heavy = settings.preserveSourceColors && appearance?.letteringStyle == "gothic" &&
                    (appearance?.sourceSample?["displayLettering"] as? Bool != true) && card.style.outline == nil &&
                    ((weight >= 0.14 && card.style.fontSize >= 14) || (weight >= 0.11 && weight >= pageWeight * 1.3 && card.style.fontSize >= 12))
                cards[index].heavyStrokeWidth = heavy ? (card.style.fontSize * 0.045 * 100).rounded() / 100 : 0
                if heavy { cards[index].style.outlinePaintOrder = .strokeThenFill }
            }
            reappendRotatedPlates(cards: &cards, gloss: gloss)
            let effects = effectGloss(cards: cards, layout: layout, restoration: restoration, settings: settings, source: source)
            gloss.notes += effects.notes
            gloss.hiddenIDs.formUnion(effects.hiddenIDs); gloss.removedLayerIDs.formUnion(effects.removedLayerIDs)
            gloss.sourceZones += effects.sourceZones; gloss.rejected.merge(effects.rejected) { _, latest in latest }
            gloss.units += effects.units
            let recovered = try recoverLines(cards: &cards, gloss: &gloss, layout: layout, source: source, settings: settings)
            var glossCards = gloss.notes.compactMap { note -> GlossCard? in
                guard let card = cards.first(where: { $0.item.id == note.id }) else { return nil }
                var style = glossStyle(card: card, size: note.placement.size, lineHeight: note.placement.lineHeight,
                    title: note.title, retained: note.retainedTypography)
                style.foreground = color(note.fill.map { CGFloat($0) })
                style.outline = color(note.outline.map { CGFloat($0) })
                style.outlineWidth = CGFloat(note.strokeWidth)
                style.outlinePaintOrder = .strokeThenFill
                return GlossCard(note: note, typography: NativeTranslationTypography.layout(text: glossText(note.text, title: note.title),
                    in: note.contentSize, style: style), style: style)
            }
            prepareFinalTrials(cards: &cards, restoration: &restoration, gloss: gloss, layout: layout, settings: settings, source: source, balloonStage: false)
            if let deferred = restoration.deferredForced {
                _ = try deferred.apply(to: &restoration, hasReadabilityPanel: { item in
                    guard let card = cards.first(where: { $0.item.id == item.id }),
                          !gloss.hiddenIDs.contains(item.id), !gloss.removedLayerIDs.contains(item.id) else { return false }
                    return readabilityOwnerPanel(card) != nil
                })
            }
            for patch in restoration.patches where patch.finalForcedErasure {
                if let index = cards.firstIndex(where: { $0.item.id == patch.itemID }) {
                    cards[index].lateSourcePatchOrder = nextRootOrder(cards: cards)
                }
            }
            releaseCertifiedPlates(cards: &cards, restoration: restoration, gloss: gloss, layout: layout, settings: settings)
            polishFinalGeometry(cards: &cards, gloss: gloss, layout: layout, restoration: restoration, anchorsOnly: false)
            polishCaptionPanels(cards: &cards, glossCards: glossCards, gloss: gloss, layout: layout, settings: settings, source: source, keptZones: captionPolishKeptZones(layout: layout, restoration: restoration, recovered: recovered))
            containBalloonText(cards: &cards, gloss: gloss, layout: layout)
            polishPanelGeometry(cards: &cards, gloss: gloss, layout: layout, restoration: restoration, settings: settings, containBalloon: true)
            polishFinalGeometry(cards: &cards, gloss: gloss, layout: layout, restoration: restoration, anchorsOnly: true)
            reconcileFinalStrokes(cards: &cards, glossCards: &glossCards, gloss: gloss, layout: layout, source: source, restoration: restoration, settings: settings)
            separateCaptions(cards: &cards, glossCards: glossCards, gloss: gloss, layout: layout, restoration: restoration)
            for index in cards.indices where cards[index].style.outlineWidth > 0 || cards[index].style.outlineGlow > 0 { cards[index].heavyStrokeWidth = 0 }
            try Task.checkCancellation()
            let pixels = outputPixelSize.map { pixelSize(viewport: $0, scale: 1) } ?? pixelSize(viewport: bounds.size, scale: scale)
            let sourcePatches = snapshotSourcePatches(restoration: restoration, cards: cards, gloss: gloss, visible: settings.visible)
            let sourcePieces = settings.visible && settings.renderedBackgroundOpacity == 1 && image != nil
                ? sourceRestorationRects(cards: cards, glossCards: glossCards, gloss: gloss, layout: layout, restoration: restoration, recovered: recovered, settings: settings) : []
            let diagnosticData = collectDiagnostics ? diagnostics(cards: cards, glossCards: glossCards, gloss: gloss,
                restoration: restoration, growthSession: growthSession, initialPatchCapture: initialPatchCapture) : nil
            return PreparedRender(inputLayout: inputLayout, layout: layout, image: image, source: source,
                restoration: restoration, cards: cards, glossCards: glossCards, gloss: gloss, settings: settings,
                bounds: bounds, pixels: pixels, scale: scale, composeSource: composeSource,
                capturePDF: capturePDF, pdfDeviceScale: pdfDeviceScale,
                sourcePatches: sourcePatches, sourcePieces: sourcePieces,
                limitations: limitations, diagnosticData: diagnosticData)
        }
    }

    static func finishPreparedSynchronously(_ plan: PreparedRender) throws -> Result {
        try autoreleasepool {
            let layout = plan.layout, image = plan.image, source = plan.source
            let restoration = plan.restoration, cards = plan.cards, glossCards = plan.glossCards, gloss = plan.gloss
            let settings = plan.settings, bounds = plan.bounds, pixels = plan.pixels
            let capturePDF = plan.capturePDF, pdfDeviceScale = plan.pdfDeviceScale
            let sourcePatches = plan.sourcePatches, sourcePieces = plan.sourcePieces
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.preferredRange = .standard
            format.opaque = false
            let contextScaleX = pixels.width / bounds.width, contextScaleY = pixels.height / bounds.height
            var cancelled = false
            let canvasSession: NativeCanvasTextureResampler.Session? = capturePDF ? nil : .init()
            defer { canvasSession?.close() }
            let paint: (CGContext, NativeCanvasBacking?) -> Void = { context, canvasBacking in
                UIGraphicsPushContext(context)
                defer { UIGraphicsPopContext() }
                for patch in capturePDF ? [] : sourcePatches {
                    if patch.liveOrder != nil || cards.contains(where: { $0.glyphCoverPatch?.image === patch.image }) { continue }
                    if Task.isCancelled { cancelled = true; break }
                    drawSourcePatch(patch, context: context, usesLiveTextureSampling: !capturePDF, canvasSession: canvasSession, canvasBacking: canvasBacking, allowsOpaqueAffineSampling: !capturePDF)
                }
                drawPaintScene(cards: cards, gloss: gloss, settings: settings, context: context,
                    pixelSnapScale: capturePDF ? pdfDeviceScale : nil, latePatches: capturePDF ? [] : sourcePatches.filter { $0.liveOrder != nil },
                    usesLiveTextureSampling: !capturePDF, canvasSession: canvasSession, canvasBacking: canvasBacking, allowsOpaqueAffineSampling: !capturePDF)
                for card in glossCards {
                    if Task.isCancelled { cancelled = true; break }
                    drawGloss(card, context: context, pixelSnapScale: capturePDF ? pdfDeviceScale : nil)
                }
                if !capturePDF, !sourcePieces.isEmpty {
                    if let source, let geometry = restoration.cleanupGeometry {
                        drawKeptSourceCopy(source: source, geometry: geometry, pieces: sourcePieces, context: context)
                    } else if let image {
                        context.saveGState(); context.addRects(sourcePieces); context.clip()
                        image.draw(in: layout.sourceRect); context.restoreGState()
                    }
                }
            }
            let overlayCGImage: CGImage
            let exportPDFData: Data?
            if capturePDF {
                let capture = try NativeTranslationPDFCapture.capture(bounds: bounds, pixels: pixels, deviceScale: pdfDeviceScale, paint: { paint($0, nil) })
                overlayCGImage = capture.image; exportPDFData = capture.data
            } else {
                let bitmap = UIGraphicsImageRenderer(size: pixels, format: format).image { renderer in
                    renderer.cgContext.scaleBy(x: contextScaleX, y: contextScaleY)
                    renderer.cgContext.translateBy(x: -bounds.minX, y: -bounds.minY)
                    let canvasBacking = NativeCanvasBacking.freshCanonicalBitmap(context: renderer.cgContext, pixelExtent: pixels)
                    paint(renderer.cgContext, canvasBacking)
                }
                guard let bitmapImage = bitmap.cgImage else { throw RenderError.invalidGeometry }
                overlayCGImage = bitmapImage; exportPDFData = nil
            }
            if cancelled { throw CancellationError() }
            try Task.checkCancellation()
            return try finishPreparedResult(plan, overlayCGImage: overlayCGImage, exportPDFData: exportPDFData)
        }
    }

    static func finishPreparedResult(_ plan: PreparedRender, overlayCGImage: CGImage, exportPDFData: Data?) throws -> Result {
        try autoreleasepool {
            let inputLayout = plan.inputLayout, layout = plan.layout, image = plan.image
            let cards = plan.cards, glossCards = plan.glossCards, gloss = plan.gloss
            let settings = plan.settings, bounds = plan.bounds, pixels = plan.pixels, scale = plan.scale
            let composeSource = plan.composeSource, capturePDF = plan.capturePDF
            let sourcePatches = plan.sourcePatches, sourcePieces = plan.sourcePieces
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1; format.preferredRange = .standard; format.opaque = false
            let contextScaleX = pixels.width / bounds.width, contextScaleY = pixels.height / bounds.height
            let overlay = UIImage(cgImage: overlayCGImage, scale: scale, orientation: .up)
            try Task.checkCancellation()
            let composite: UIImage
            if composeSource, let image {
                let compositePixels = UIGraphicsImageRenderer(size: pixels, format: format).image { renderer in
                    // Letterbox margins stay transparent; reader/background appearance owns their color.
                    renderer.cgContext.scaleBy(x: contextScaleX, y: contextScaleY)
                    renderer.cgContext.translateBy(x: -bounds.minX, y: -bounds.minY)
                    image.draw(in: layout.sourceRect)
                    if capturePDF { for patch in sourcePatches { drawSourcePatch(patch, context: renderer.cgContext, appliesCanvasClip: false) } }
                    overlay.draw(in: bounds)
                    if capturePDF, !sourcePieces.isEmpty {
                        renderer.cgContext.saveGState(); renderer.cgContext.addRects(sourcePieces); renderer.cgContext.clip()
                        image.draw(in: layout.sourceRect); renderer.cgContext.restoreGState()
                    }
                }
                guard let compositeCGImage = compositePixels.cgImage else { throw RenderError.invalidGeometry }
                composite = UIImage(cgImage: compositeCGImage, scale: scale, orientation: .up)
            } else { composite = overlay }
            try Task.checkCancellation()
            return Result(image: composite, overlayImage: overlay, layoutData: try JSONEncoder().encode(inputLayout),
                          renderedItemCount: cards.count - gloss.hiddenIDs.count, limitations: Array(Set(plan.limitations)).sorted(), renderBounds: bounds,
                          diagnosticData: plan.diagnosticData,
                          exportPDFData: exportPDFData, sourceRestorationRects: capturePDF ? sourcePieces : [], paintBounds: finalPaintBounds(cards: cards,glossCards: glossCards,gloss: gloss,settings: settings), sourcePatches: capturePDF ? sourcePatches : [])
        }
    }

    static func initialSlantedTypography(item: NativeTranslationLayoutItem,
                                                appearance: NativeTranslationRestoration.Appearance,
                                                settings: IPhoneOverlaySettings) -> (NativeTranslationTypography.Layout, NativeTranslationTypography.Style)? {
        guard valid(item.contentRect), item.fontSize.isFinite, item.fontSize > 0, item.text.utf16.count <= 32_768 else { return nil }
        let surface = settings.preserveSourceBackgroundColor ? appearance.background : nil
        let panelInk = surface.map { panelForeground($0, opacity: CGFloat(settings.renderedBackgroundOpacity)) }
        let light = panelInk.map { ($0.components?.first ?? 1) < 1 } ?? item.lightSurface
        var style = NativeTranslationTypography.Style(
            fontName: settings.preserveSourceColors && item.fontScript == "korean" ? appearance.fontName : nil,
            fontScript: item.fontScript, fontSize: item.fontSize, vertical: item.vertical,
            foreground: (settings.preserveSourceTextColor ? appearance.foreground : nil) ?? panelInk ?? color(light ? [17, 18, 23] : [255, 255, 255]),
            tracking: -item.fontSize * 0.012, lineHeight: max(item.fontSize, item.lineHeight), alignsToTop: item.balancedColumn)
        style.balancesHorizontalLines = item.wrappingScript == "korean" && !item.vertical && item.text.utf16.count <= 180 && !item.text.contains("\n")
        style.optimizesKoreanWrapping = false
        let measured = fitted(text: item.text, size: item.contentRect.size, style: &style)
        return measured.fits ? (measured,style) : nil
    }

    static func initialSlantedInkFits(item: NativeTranslationLayoutItem,
                                             appearance: NativeTranslationRestoration.Appearance,
                                             proof: NativeSlantedRestoration.ProofRaster, pixelScale: CGFloat,
                                             settings: IPhoneOverlaySettings) -> Bool {
        guard let (measured,style) = initialSlantedTypography(item: item, appearance: appearance, settings: settings) else { return false }
        guard measured.fits, let foreground = rgb(style.foreground), !measured.glyphBounds.isEmpty else { return false }
        let local = measured.glyphBounds.map { rect -> [Double] in
            [Double(rect.minX + item.paddingLeft), Double(rect.minY + item.paddingTop),
             Double(rect.maxX + item.paddingLeft), Double(rect.maxY + item.paddingTop)]
        }
        var audit = NativeSlantedInkSafety.Audit()
        return NativeSlantedInkSafety.inkFits(proof: proof, rects: local, scale: Double(pixelScale), foreground: foreground, audit: &audit)
    }

    static func initialPageSlantedInkFits(item: NativeTranslationLayoutItem,
                                                 appearance: NativeTranslationRestoration.Appearance,
                                                 prepared: NativeSpatialSourceCrop.Prepared, pixels: NativeRestorationPixels,
                                                 imageSize: CGSize, settings: IPhoneOverlaySettings) -> Bool {
        guard let (measured,style) = initialSlantedTypography(item: item, appearance: appearance, settings: settings),
              let foreground = rgb(style.foreground), item.sourceFrame.count == 4, item.sourceFrame[2] > 0, item.sourceFrame[3] > 0 else { return false }
        let rects = measured.glyphBounds.map { r in [Double(r.minX + item.paddingLeft), Double(r.minY + item.paddingTop),
            Double(r.maxX + item.paddingLeft), Double(r.maxY + item.paddingTop)] }
        let luminance = NativeSlantedPixels.compositeLuminance(pixels.rgba, local: prepared.pixels.rgba, n: pixels.width * pixels.height)
        var audit = NativeSlantedInkSafety.Audit()
        return NativeSlantedInkSafety.rotatedPageInkFits(width: pixels.width, height: pixels.height,
            safe: pixels.layoutSafe, luminance: luminance, sx: Double(prepared.sx), sy: Double(prepared.sy),
            ox: Double(prepared.crop.minX), oy: Double(prepared.crop.minY), rects: rects,
            node: [Double(item.x), Double(item.y), Double(item.width), Double(item.height)], angle: Double(item.rotation),
            toImage: { x,y in [Double((CGFloat(x) - item.sourceFrame[0]) / item.sourceFrame[2] * imageSize.width),
                              Double((CGFloat(y) - item.sourceFrame[1]) / item.sourceFrame[3] * imageSize.height)] },
            foreground: foreground, audit: &audit)
    }

    static func snapshotSourcePatches(restoration: NativeTranslationRestoration.Result, cards: [Card],
                                      gloss: NativeTranslationEffectGloss.Refinement, visible: Bool) -> [SourcePatch] {
        let patches = (visible ? restoration.patches : []).compactMap { patch -> SourcePatch? in
            guard valid(patch.rect), !gloss.removedLayerIDs.contains(patch.itemID ?? "") else { return nil }
            // The canvas CSS box is used geometry; its crop/raster evidence keeps the authored frame.
            return SourcePatch(image: patch.image, rect: usedRect(patch.rect), cleanupClip: patch.cleanupClip,
                liveOrder: patch.finalForcedErasure ? cards.first(where: { $0.item.id == patch.itemID })?.lateSourcePatchOrder : nil,
                authoredCanvasRect: patch.rect)
        }
        return patches
    }

    private static func diagnostics(cards: [Card], glossCards: [GlossCard], gloss: NativeTranslationEffectGloss.Refinement,
                                    restoration: NativeTranslationRestoration.Result,
                                    growthSession: NativeTypographyPostPolish.RendererGrowthSession? = nil,
                                    initialPatchCapture: NativeRestorationDiagnosticCapture.Report? = nil) -> Data? {
        func box(_ rect: CGRect) -> [Double] { [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)] }
        let records: [[String: Any]] = cards.map { card in
            let item = card.item, appearance = restoration.appearances[item.id]
            let evidence = cardSurfaceEvidence(card,restoration: restoration)
            var record: [String: Any] = ["id": item.id, "text": item.typesettingText ?? item.text,
                "rect": box(item.rect), "contentRect": box(item.contentRect), "ink": box(cardInkRect(card)),
                "rotation": Double(item.rotation), "upright": item.drawsUprightQuadText, "vertical": item.vertical,
                "fontSize": Double(card.style.fontSize), "fontName": card.style.fontName ?? "system",
                "lineHeight": Double(card.style.lineHeight), "tracking": Double(card.style.tracking),
                "horizontalScale": Double(card.style.horizontalScale), "horizontalWrapping": String(describing: card.style.horizontalWrapping), "horizontalWhitespace": String(describing: card.style.horizontalWhitespace),
                "sourceColumnAuthoredTop": card.sourceColumnAuthoredTop.map { Double($0) as Any } ?? NSNull(), "usesBlockWordLayout": card.style.usesBlockWordLayout, "usesPreformattedBlockRows": card.style.usesPreformattedBlockRows, "hasControlledText": item.typesettingText != nil, "preservesBlockWrapper": item.typesettingPreservedBlockWrapper == true,
                "typesettingQuoteMode": item.typesettingQuoteMode.map { $0 as Any } ?? NSNull(), "foreground": rgb(card.style.foreground) ?? [],
                "outline": rgb(card.style.outline) ?? [], "outlineWidth": Double(card.style.outlineWidth),
                "outlinePaintOrder": card.style.outlinePaintOrder.rawValue,
                "strokePreserved": card.strokePreserved, "glyphPlateReleased": card.glyphPlateReleased,
                "glyphCover": card.glyphCoverRecord ?? NSNull(), "glyphCoverReject": card.glyphCoverReject ?? "",
                "lightLettering": card.lightLetteringRecord ?? NSNull(), "lightLetteringReject": card.lightLetteringReject ?? "", "outlineGlow": card.outlineGlow,
                "plateGrowth": card.plateGrowthRecord ?? NSNull(), "readableFloorHeld": card.readableFloorHeld ?? [],
                "displayGroup": card.displayGroup ?? NSNull(), "letteringUnit": card.letteringUnitRecord ?? NSNull(),
                "outlinedLettering": card.outlinedRecord ?? [:], "heavyStrokeWidth": Double(card.heavyStrokeWidth),
                "paintOrderLift": card.paintOrderLift ?? "", "textZ": card.textZ,
                "textRootOrder": card.textRootOrder.map { $0 as Any } ?? NSNull(),
                "lateSourcePatchOrder": card.lateSourcePatchOrder.map { $0 as Any } ?? NSNull(), "rotatedPlateZ": card.rotatedPlateZ, "artwork": card.artworkRecord ?? [:],
                "drawsPanel": card.drawsPanel, "background": rgb(card.background) ?? [],
                "sourceTopAnchored": card.sourceTopAnchored,
                "sourceColorEligible": item.sourceColorEligible, "sourceBounds": item.sourceBounds.map { Double($0) },
                "sourceFontSize": item.sourceFontSize.map { Double($0) } ?? 0,
                "restored": appearance?.restored ?? false, "erasureComplete": appearance?.erasureComplete ?? false,
                "restorationMethod": appearance?.restorationMethod ?? "", "sourceGlyphsVerified": appearance?.sourceGlyphsVerified ?? false,
                "sourceSample": appearance?.sourceSample ?? [:], "surfaceRange": evidence?.range ?? [],
                "surfaceHistogram": evidence?.histogram ?? [], "preservedGloss": card.preservedGloss,
                "preservedErasure": card.preservedErasure, "hidden": gloss.hiddenIDs.contains(item.id),
                "removed": gloss.removedLayerIDs.contains(item.id), "fits": card.typography.fits, "contentFits": cardContentFits(card),
                "glyphBounds": card.typography.glyphBounds.map(box), "rangeBounds": card.typography.rangeBounds.map(box),
                "lineRects": cardPageLineRects(card).map(box), "pageRangeBounds": cardPageRangeRects(card).map(box),
                "rotatedReadability": card.rotatedReadability ?? [:],
                "slantedTrial": card.slantedTrial?.metadata ?? [:],
                "sourceBackgroundKind": card.sourceBackgroundKind ?? "", "sourceStrokeKind": card.sourceStrokeKind ?? "",
                "captionParentPlate": card.captionParentPlate, "sourcePanelZ": card.sourcePanelZ,
                "harmony": card.harmonyRecord, "typographyDisplayGrowth": card.typographyDisplayGrowth ?? NSNull(), "authoredTextOrigin": card.authoredTextOrigin.map { [Double($0.x),Double($0.y)] } ?? [],
                "unitParts": card.unitParts ?? [], "unitContainment": card.unitContainment ?? [], "captionReflow": card.captionReflow ?? [:], "captionPacking": card.captionPackingRecord ?? [:], "stackRepair": card.stackRepair ?? [],
                "unitTextParts": card.unitTextParts.map { ["text": $0.text, "rect": box(textPartFrame($0,card: card)), "font": Double($0.style.fontSize)] as [String:Any] },
                "panels": card.sourcePanels.map { ["rect": box($0.rect), "background": $0.background,
                    "coverage": $0.coverage.map(box), "radius": $0.radius, "sourceBridgeClipped": $0.sourceBridgeClipped, "overflowClip": $0.overflowClip] as [String: Any] }]
            if let analysis = card.outlineEvidence {
                record["outlineObservation"] = ["restored": analysis.restored, "slanted": analysis.slanted,
                    "missingColumnRing": analysis.missingColumnRing, "ring": analysis.ringData ?? [:],
                    "enclosed": analysis.enclosed ?? [:], "rejection": analysis.rejection ?? ""]
            }
            record["latePlateTrim"] = card.latePlateTrimTrace
            record["finalPlateTrim"] = card.finalPlateTrim ?? []
            record["backings"] = card.backings.map { ["frame": box($0.frame), "coverage": $0.coverage.map(box), "color": $0.color] as [String: Any] }
            record["foreignFills"] = card.foreignFills.map { fill in
                ["frame": box(fill.rect), "color": fill.color,
                 "backgroundPosition": fill.backgroundPosition.map { [Double($0.x), Double($0.y)] } ?? [],
                 "backgroundSize": fill.backgroundSize.map { [Double($0.width), Double($0.height)] } ?? []] as [String: Any]
            }
            record["typographyInitial"] = growthSession?.initialTypographyTrace(id: item.id) ?? []
            record["sourcePanelTextFit"] = card.sourcePanelTextFit ?? NSNull()
            record["earlyErasureCertified"] = card.earlyErasureCertified
            record["typographyFinal"] = finalTypographyDiagnostics(card)
            if !JSONSerialization.isValidJSONObject(record["sourceSample"] as Any) { record["sourceSample"] = [:] }
            return record
        }
        let notes: [[String: Any]] = glossCards.map { card in
            ["id": card.note.id, "text": card.note.text, "title": card.note.title,
             "fontSize": Double(card.style.fontSize), "outlineWidth": Double(card.style.outlineWidth),
             "foreground": rgb(card.style.foreground) ?? [], "outline": rgb(card.style.outline) ?? [],
             "retainedCardLayout": card.note.retainedTypography != nil,
             "contentSize": [Double(card.note.contentSize.width), Double(card.note.contentSize.height)],
             "placement": ["size": card.note.placement.size, "width": card.note.placement.width,
                "rank": card.note.placement.rank, "edge": card.note.placement.edge,
                "origin": [Double(card.note.origin.x), Double(card.note.origin.y)],
                "moves": card.note.placement.moves.map { [Double($0.x), Double($0.y)] }]]
        }
        let finalPatchCapture = NativeRestorationDiagnosticCapture.capture(restoration)
        return try? JSONSerialization.data(withJSONObject: ["cards": records, "gloss": notes,
            "restorationAttempts": restoration.restorationAttempts,
            "initialPatches": initialPatchCapture?.records ?? [],
            "initialPatchCaptureFailures": initialPatchCapture?.failures ?? [],
            "finalPatches": finalPatchCapture.records,
            "finalPatchCaptureFailures": finalPatchCapture.failures,
            "cleanupFrame": restoration.cleanupGeometry.map { box($0.frame) } ?? [],
            "cleanupClip": restoration.cleanupGeometry.map { box($0.clip) } ?? [],
            "patches": restoration.patches.map { ["id": $0.itemID ?? "", "rect": box($0.rect),
                "width": $0.image.width, "height": $0.image.height,
                "safePixels": $0.layoutSafe?.reduce(0) { $0 + ($1 != 0 ? 1 : 0) } ?? 0] as [String: Any] }], options: [.sortedKeys])
    }

    static func rotatedBounds(_ rect: CGRect, about anchor: CGRect, angle: CGFloat) -> CGRect {
        let center = CGPoint(x: anchor.midX, y: anchor.midY), cosine = cos(angle), sine = sin(angle)
        let corners = [CGPoint(x: rect.minX,y: rect.minY),CGPoint(x: rect.maxX,y: rect.minY),
                       CGPoint(x: rect.maxX,y: rect.maxY),CGPoint(x: rect.minX,y: rect.maxY)].map { p in
            CGPoint(x: center.x + (p.x-center.x)*cosine - (p.y-center.y)*sine,
                    y: center.y + (p.x-center.x)*sine + (p.y-center.y)*cosine)
        }
        let left = corners.map(\.x).min()!, top = corners.map(\.y).min()!
        return CGRect(x: left,y: top,width: corners.map(\.x).max()!-left,height: corners.map(\.y).max()!-top)
    }

    static func usedRect(_ rect: CGRect) -> CGRect {
        func unit(_ value: CGFloat) -> CGFloat { CGFloat((Float(value) * 64).rounded(.towardZero)) / 64 }
        return CGRect(x: unit(rect.minX), y: unit(rect.minY), width: unit(rect.width), height: unit(rect.height))
    }

    /// CSS LayoutUnit stores each assigned box metric independently in 1/64 points.
    static func usedLayoutItem(_ item: NativeTranslationLayoutItem) -> NativeTranslationLayoutItem {
        var used = item
        func unit(_ value: CGFloat) -> CGFloat { CGFloat((Float(value) * 64).rounded(.towardZero)) / 64 }
        used.x = unit(item.x); used.y = unit(item.y)
        used.width = unit(item.width); used.height = unit(item.height)
        used.paddingTop = unit(item.paddingTop); used.paddingRight = unit(item.paddingRight)
        used.paddingBottom = unit(item.paddingBottom); used.paddingLeft = unit(item.paddingLeft)
        used.preservePaddingDeclarations(from: item)
        return used
    }

    static func remeasureTypography(_ card: Card, style: NativeTranslationTypography.Style? = nil,
                                    text: String? = nil) -> NativeTranslationTypography.Layout {
        var effectiveStyle = style ?? card.style
        // Fixed rows belong to the current controlled block children. Raw
        // textContent replacement removes those children and restores wrapping.
        effectiveStyle.usesBlockWordLayout = card.item.typesettingText != nil && card.item.typesettingQuoteMode != nil &&
            (text == nil || text == card.item.typesettingText)
        effectiveStyle.usesPreformattedBlockRows = card.item.typesettingText != nil && card.item.typesettingPreformattedRows == true &&
            (text == nil || text == card.item.typesettingText)
        effectiveStyle.blockWordLayoutUsesTopPadding = (effectiveStyle.usesBlockWordLayout || effectiveStyle.usesPreformattedBlockRows) && card.item.typesettingBlockDisplay == true
        let shaped = NativeTranslationTypography.layout(text: text ?? card.item.typesettingText ?? card.item.text,
            in: card.textLayoutSize,style: effectiveStyle)
        return NativeTranslationTypography.applyingLineOffsets(layout: shaped,offsets: card.lineOffsets)
    }

    static func textPartFrame(_ part: TextPart, card: Card) -> CGRect {
        let original = card.unitTextPartsOrigin ?? card.item.rect.origin
        return part.frame.offsetBy(dx: card.item.x-original.x+card.textShift.x,dy: card.item.y-original.y+card.textShift.y)
    }

    static func cardPageRangeRects(_ card: Card) -> [CGRect] {
        if !card.unitTextParts.isEmpty {
            return card.unitTextParts.flatMap { part in
                let frame = textPartFrame(part,card: card)
                return part.typography.rangeBounds.map { $0.offsetBy(dx: frame.minX,dy: frame.minY) }
            }
        }
        return card.typography.rangeBounds.map { local in
            let rect = local.offsetBy(dx: card.textOrigin.x,dy: card.textOrigin.y)
            return card.effectiveTextRotation != 0 ? rotatedBounds(rect,about: card.item.rect,angle: card.effectiveTextRotation) : rect
        }
    }

    static func cardPageLineRects(_ card: Card) -> [CGRect] {
        if !card.unitTextParts.isEmpty {
            return card.unitTextParts.flatMap { part in
                let frame = textPartFrame(part,card: card)
                return NativeTranslationTypography.captionLineMetrics(layout: part.typography).map { $0.rect.offsetBy(dx: frame.minX,dy: frame.minY) }
            }
        }
        return NativeTranslationTypography.captionLineMetrics(layout: card.typography).map { metric in
            let rect = metric.rect.offsetBy(dx: card.textOrigin.x,dy: card.textOrigin.y)
            return card.effectiveTextRotation != 0
                ? rotatedBounds(rect,about: card.item.rect,angle: card.effectiveTextRotation) : rect
        }
    }

    /// The selected DOM contents include whitespace and controlled row boxes;
    /// this contract stays separate from per-scalar surface ownership ranges.
    static func cardWholeRangeRect(_ card: Card, preservesBlockWrapper: Bool = false) -> CGRect? {
        if !card.unitTextParts.isEmpty {
            let rects = card.unitTextParts.flatMap { part -> [CGRect] in
                let frame = textPartFrame(part, card: card)
                var selected = [frame] // Selecting parent contents includes the absolute child DIV.
                if let text = NativeTranslationTypography.wholeRangeBounds(layout: part.typography, style: part.style,
                    available: part.frame.size) { selected.append(text.offsetBy(dx: frame.minX, dy: frame.minY)) }
                return selected.map { card.effectiveTextRotation != 0
                    ? rotatedBounds($0, about: card.item.rect, angle: card.effectiveTextRotation) : $0 }
            }
            let range = rects.reduce(CGRect.null) { $0.union($1) }
            return range.isNull ? nil : range
        }
        var style = card.style
        style.usesBlockWordLayout = card.item.typesettingText != nil && card.item.typesettingQuoteMode != nil
        style.usesPreformattedBlockRows = card.item.typesettingText != nil && card.item.typesettingPreformattedRows == true
        style.blockWordLayoutUsesTopPadding = (style.usesBlockWordLayout || style.usesPreformattedBlockRows) && card.item.typesettingBlockDisplay == true
        guard let local = NativeTranslationTypography.wholeRangeBounds(layout: card.typography, style: style,
            available: card.textLayoutSize, preservesBlockWrapper: preservesBlockWrapper || card.item.typesettingPreservedBlockWrapper == true) else { return nil }
        let rect = local.offsetBy(dx: card.textOrigin.x, dy: card.textOrigin.y)
        return card.effectiveTextRotation != 0 ? rotatedBounds(rect, about: card.item.rect, angle: card.effectiveTextRotation) : rect
    }

    /// Each frozen stage owns its tolerance; packing preserves CSS overflow of one pixel.
    static func cardScrollFits(_ card: Card, allowance: Int) -> Bool {
        var item = card.item
        item.fontSize = card.style.fontSize; item.lineHeight = card.style.lineHeight
        item.typesettingWidthScale = card.style.horizontalScale
        guard let metrics = NativeTypographyPostPolish.contentFitMetrics(item: item, typography: card.typography) else { return false }
        return metrics.scrollWidth <= metrics.clientWidth + allowance && metrics.scrollHeight <= metrics.clientHeight + allowance
    }

    static func cardContentFits(_ card: Card) -> Bool {
        var item = card.item
        item.fontSize = card.style.fontSize; item.lineHeight = card.style.lineHeight
        item.typesettingWidthScale = card.style.horizontalScale
        return NativeTypographyPostPolish.contentFits(item: item,typography: card.typography)
    }

    static func cardSurfaceEvidence(_ card: Card, restoration: NativeTranslationRestoration.Result) -> NativeTypographyPostPolish.SurfaceEvidence? {
        guard !card.unitTextParts.isEmpty || cardContentFits(card) else { return nil }
        var item = card.item
        item.fontSize = card.finalFontSize; item.lineHeight = card.style.lineHeight
        item.rotation = card.effectiveTextRotation
        return NativeTypographyPostPolish.surfaceEvidence(item: item,pageRangeBounds: cardPageRangeRects(card),
            restoration: restoration)
    }

    static func cardInkRect(_ card: Card) -> CGRect {
        if !card.unitTextParts.isEmpty { return cardPageRangeRects(card).reduce(CGRect.null) { $0.union($1) } }
        let item = card.item
        let ranges = card.typography.rangeBounds
        let local = ranges.reduce(CGRect.null) { $0.union($1) }
        let ink = (local.isNull ? CGRect.zero : local).offsetBy(dx: card.textOrigin.x, dy: card.textOrigin.y)
        guard card.effectiveTextRotation != 0 else { return ink }
        let center = CGPoint(x: item.rect.midX, y: item.rect.midY)
        let cosine = cos(card.effectiveTextRotation), sine = sin(card.effectiveTextRotation)
        let corners = [CGPoint(x: ink.minX,y: ink.minY),CGPoint(x: ink.maxX,y: ink.minY),
                       CGPoint(x: ink.maxX,y: ink.maxY),CGPoint(x: ink.minX,y: ink.maxY)].map { p in
            CGPoint(x: center.x + (p.x-center.x)*cosine - (p.y-center.y)*sine,
                    y: center.y + (p.x-center.x)*sine + (p.y-center.y)*cosine)
        }
        let left = corners.map(\.x).min()!, top = corners.map(\.y).min()!
        return CGRect(x: left,y: top,width: corners.map(\.x).max()!-left,height: corners.map(\.y).max()!-top)
    }

    static func glossText(_ text: String, title: Bool) -> String {
        // The source note is assigned with textContent; CSS whitespace handles
        // ASCII collapsing and hard breaks without replacing NBSP or U+3000.
        text
    }

    static func glossStyle(card: Card, size: Double, lineHeight: Double, title: Bool = false,
                           retained: NativeTranslationEffectGloss.RetainedTypography? = nil) -> NativeTranslationTypography.Style {
        if let retained { return retained.style(size: size, lineHeight: lineHeight) }
        var style = card.style
        let overflowNormal = style.horizontalWrapping == .keepAll || style.keepsWholeWords || style.strictLineBreak
        style.fontSize = CGFloat(size); style.lineHeight = CGFloat(lineHeight)
        style.vertical = false; style.tracking = 0; style.alignsToTop = true; style.horizontalScale = 1
        style.outline = nil; style.outlineWidth = 0; style.outlineGlow = 0; style.optimizesKoreanWrapping = false
        style.horizontalWhitespace = title ? .preLine : .normal
        style.horizontalWrapping = overflowNormal ? .keepAll : .keepAllWithEmergency
        style.keepsWholeWords = false; style.koreanQuoteMode = 0
        style.usesBlockWordLayout = false; style.usesPreformattedBlockRows = false
        style.blockWordLayoutUsesTopPadding = false; style.blockRowHorizontalAlignment = nil
        return style
    }

    static func sampleSource(_ source: CGImage, rect: CGRect, frame: CGRect, width: Int, height: Int) -> [UInt8]? {
        guard valid(rect), valid(frame), width > 0, height > 0, width * height <= 262_144 else { return nil }
        let x = Double((rect.minX - frame.minX) / frame.width) * Double(source.width)
        let y = Double((rect.minY - frame.minY) / frame.height) * Double(source.height)
        return try? NativeSourcePixelReader.draw(image: source, x: x, y: y,
            sourceWidth: Double(rect.width / frame.width) * Double(source.width),
            sourceHeight: Double(rect.height / frame.height) * Double(source.height), width: width, height: height)
    }

    private static func oversizedTitleGloss(cards: inout [Card], layout: NativeTranslationLayout,
                                           restoration: NativeTranslationRestoration.Result, settings: IPhoneOverlaySettings,
                                           source: CGImage?) -> NativeTranslationEffectGloss.Refinement {
        guard settings.renderedBackgroundOpacity == 1, source != nil else { return .init() }
        let records = cards.compactMap { card -> NativeTranslationOversizedTitleGloss.Record? in
            let item = card.item, sample = restoration.appearances[item.id]?.sourceSample ?? [:]
            guard item.sourceBounds.count == 4 else { return nil }
            return .init(id: item.id, text: item.typesettingText ?? item.text,
                normalizedSourceBounds: CGRect(x: item.sourceBounds[0], y: item.sourceBounds[1],
                    width: item.sourceBounds[2], height: item.sourceBounds[3]), sourceFontSize: item.sourceFontSize.map { Double($0) },
                rotation: Double(item.rotation), hasRestorationProposal: restoration.patches.contains { $0.itemID == item.id },
                origin: item.contentRect.origin, ink: cardWholeRangeRect(card) ?? cardInkRect(card),
                fontSize: Double(card.finalFontSize), panels: card.sourcePanels,
                sampledForeground: NativeSourceColorSampler.rgb(sample["foreground"]),
                sampledStroke: NativeSourceColorSampler.rgb(sample["stroke"]), sampledBackground: NativeSourceColorSampler.rgb(sample["background"]), backings: card.backings,
                rotatedCoverFrames: (card.rotatesSourcePanels ? card.sourcePanels.map { rotatedBounds($0.rect, about: card.sourcePlateRect, angle: item.rotation) } : []) +
                    (item.rotation != 0 && card.drawsPanel ? [rotatedBounds(item.rect, about: item.rect, angle: item.rotation)] : []),
                rotatesSourcePanels: card.rotatesSourcePanels)
        }
        let snapshot = cards
        let kept = layout.items.filter(\.keptLettering).compactMap { item -> CGRect? in
            guard item.sourceBounds.count == 4 else { return nil }
            return CGRect(x: item.sourceBounds[0], y: item.sourceBounds[1], width: item.sourceBounds[2], height: item.sourceBounds[3])
        }
        func retainedTypography(_ card: Card) -> NativeTranslationEffectGloss.RetainedTypography {
            .init(sourceStyle: card.style,
                  horizontalPadding: card.item.paddingLeft + card.item.paddingRight,
                  verticalPadding: card.item.paddingTop + card.item.paddingBottom)
        }
        var result = NativeTranslationOversizedTitleGloss.refining(records: records, frame: layout.sourceRect,
            image: source, keptSources: kept, erased: restoration.patches.map(\.rect),
            measure: { id,text,size,width,lineHeight,origin in
                guard let card = snapshot.first(where: { $0.item.id == id }) else { return .zero }
                let retained = retainedTypography(card)
                let style = retained.style(size: size, lineHeight: lineHeight)
                let contentSize = retained.contentSize(width: width, lineHeight: lineHeight)
                let measured = NativeTranslationTypography.layout(text: text, in: contentSize, style: style)
                // The frozen search measures Range contents, not painted glyph
                // ink. Padding and line boxes participate in placement sizing.
                return NativeTranslationTypography.wholeRangeBounds(layout: measured, style: style, available: contentSize)?
                    .offsetBy(dx: origin.x, dy: origin.y) ?? .zero
            })
        for index in result.gloss.notes.indices {
            if let card = snapshot.first(where: { $0.item.id == result.gloss.notes[index].id }) {
                result.gloss.notes[index].retainedTypography = retainedTypography(card)
            }
        }
        for record in result.records {
            guard let index = cards.firstIndex(where: { $0.item.id == record.id }) else { continue }
            let delta = CGPoint(x: record.origin.x - cards[index].item.contentRect.minX,
                                y: record.origin.y - cards[index].item.contentRect.minY)
            cards[index].item.x += delta.x; cards[index].item.y += delta.y
            cards[index].authoredTextOrigin?.x += delta.x; cards[index].authoredTextOrigin?.y += delta.y
            cards[index].sourcePanels = record.panels; cards[index].backings = record.backings; cards[index].preservedGloss = record.preservedGloss
            cards[index].preservedErasure = record.preservedErasure
            if record.preservedErasure { cards[index].sourceRestorationMetadata["sourceErasurePreserved"] = "oversized-unrestored" }
        }
        return result.gloss
    }

    private static func separateCaptions(cards: inout [Card], glossCards: [GlossCard],
                                         gloss: NativeTranslationEffectGloss.Refinement, layout: NativeTranslationLayout,
                                         restoration: NativeTranslationRestoration.Result) {
        let snapshot = cards
        var entries = cards.compactMap { card -> NativeTranslationCaptionSeparation.Entry? in
            let item = card.item
            guard let source = pageRect(item.sourceBounds, frame: layout.sourceRect) else { return nil }
            let metrics = NativeTranslationTypography.captionLineMetrics(layout: card.typography)
            let lines = metrics.map { $0.rect.offsetBy(dx: card.textOrigin.x, dy: card.textOrigin.y) }
            return .init(id: item.id, frame: layout.sourceRect, source: source, text: item.typesettingText ?? item.text,
                sourceVertical: item.sourceVertical, vertical: item.vertical, rotation: Double(item.rotation),
                hasBalloon: item.balloonInterior != nil, isRoot: !card.captionParentPlate,
                inpainted: card.sourceBackgroundKind == "inpainted",
                keepsSource: card.preservedGloss || card.preservedErasure,
                visible: !gloss.hiddenIDs.contains(item.id) && !gloss.removedLayerIDs.contains(item.id),
                horizontalWriting: !item.vertical, horizontalTransform: item.rotation == 0,
                font: Double(card.finalFontSize), stroke: Double(card.style.outlineWidth),
                metrics: metrics.map { .init(ascent: Double($0.ascent), descent: Double($0.descent)) },
                lineHeight: Double(card.style.lineHeight), height: Double(item.height), lines: lines)
        }
        for glossCard in glossCards {
            guard let owner = cards.first(where: { $0.item.id == glossCard.note.id }), let move = glossCard.note.placement.moves.first else { continue }
            let note = glossCard.note, origin = CGPoint(x: note.origin.x + move.x, y: note.origin.y + move.y)
            let lines = NativeTranslationTypography.captionLineMetrics(layout: glossCard.typography).map { metric in
                let rect = metric.rect.offsetBy(dx: origin.x, dy: origin.y)
                guard let angle = note.placement.angle, let center = note.placement.center else { return rect }
                return rotatedBounds(rect, about: CGRect(x: center.x, y: center.y, width: 0, height: 0), angle: CGFloat(angle))
            }
            entries.append(.init(id: "gloss:" + note.id, frame: layout.sourceRect,
                source: pageRect(owner.item.sourceBounds, frame: layout.sourceRect) ?? owner.item.rect,
                text: note.text, sourceVertical: owner.item.sourceVertical, vertical: false,
                rotation: note.placement.angle ?? 0, hasBalloon: false, isRoot: true, inpainted: false,
                keepsSource: true, visible: true, horizontalWriting: true, horizontalTransform: note.placement.angle == nil,
                font: Double(glossCard.style.fontSize), stroke: Double(glossCard.style.outlineWidth), metrics: [],
                lineHeight: Double(glossCard.style.lineHeight), height: Double(glossCard.typography.size.height), lines: lines))
        }
        var proposed: [String: Card] = [:]
        let leading = NativeTranslationCaptionSeparation.separateLines(entries, itemCount: layout.items.count, reshape: { entry,pitch in
            guard let card = snapshot.first(where: { $0.item.id == entry.id }), let first = entry.lines.first else { return nil }
            guard let candidate = reshapeCaptionLineSpacing(card, pitch: CGFloat(pitch), firstTop: first.minY) else { return nil }
            proposed[card.item.id] = candidate
            return .init(lines: cardPageLineRects(candidate), height: Double(candidate.item.height),
                shiftY: Double(candidate.item.y - card.item.y))
        })
        let kept = layout.items.filter(\.keptLettering).compactMap { pageRect($0.sourceBounds, frame: layout.sourceRect) }
        let separated = NativeTranslationCaptionSeparation.separateColumns(leading, keptSources: kept, itemCount: layout.items.count)
        for entry in separated {
            guard let index = cards.firstIndex(where: { $0.item.id == entry.id }) else { continue }
            if entry.measuredPitch != nil, let candidate = proposed[entry.id] {
                cards[index].item = candidate.item; cards[index].style = candidate.style; cards[index].typography = candidate.typography
                cards[index].sourceColumnAuthoredTop = candidate.sourceColumnAuthoredTop
            }
            cards[index].item.x += entry.shift.x
        }
    }

    private static func effectGloss(cards: [Card], layout: NativeTranslationLayout,
                                    restoration: NativeTranslationRestoration.Result, settings: IPhoneOverlaySettings,
                                    source: CGImage?) -> NativeTranslationEffectGloss.Refinement {
        let frame = layout.sourceRect
        let records = cards.compactMap { card -> NativeTranslationEffectGloss.Record? in
            let item = card.item
            guard let sourceRect = pageRect(item.sourceBounds, frame: frame) else { return nil }
            let sample = restoration.appearances[item.id]?.sourceSample ?? [:]
            let quad = item.sourceQuad.flatMap { q -> [Double]? in
                guard q.count == 5 else { return nil }
                return [Double(frame.minX + q[0] * frame.width), Double(frame.minY + q[1] * frame.height),
                        Double(q[2] * frame.width), Double(q[3] * frame.width), Double(q[4])]
            }
            var record = NativeTranslationEffectGloss.Record(id: item.id, text: item.typesettingText ?? item.text,
                role: item.sourceLettering, source: sourceRect,
                ink: cardInkRect(card),
                fontSize: Double(card.finalFontSize))
            record.auxiliary = item.auxiliaryInkRects.compactMap { pageRect($0, frame: frame) }
            record.sourceFontSize = item.sourceFontSize.map { Double($0) }; record.sourceVertical = item.sourceVertical
            record.sourceQuad = quad; record.hasBalloon = item.balloonInterior != nil
            record.preservedGloss = card.preservedGloss; record.preservedErasure = card.preservedErasure
            let appearance = restoration.appearances[item.id]
            record.glyphReplacement = appearance?.restorationMethod == "chromatic-balloon-glyphs" && appearance?.sourceGlyphsVerified == true
            record.sampledForeground = NativeSourceColorSampler.rgb(sample["foreground"])
            record.sampledStroke = NativeSourceColorSampler.rgb(sample["stroke"])
            record.sampledBackground = NativeSourceColorSampler.rgb(sample["background"])
            record.appliedForeground = rgb(card.style.foreground)
            record.plates = card.sourcePanels.map { panel in
                .init(rect: card.rotatesSourcePanels ? rotatedBounds(panel.rect, about: card.sourcePlateRect, angle: item.rotation) : panel.rect,
                      colour: panel.background)
            }
            if item.rotation != 0, card.drawsPanel, let background = rgb(card.background) {
                record.plates.append(.init(rect: rotatedBounds(item.rect, about: item.rect, angle: item.rotation), colour: background))
            }
            return record
        }
        let kept = layout.items.filter(\.keptLettering).compactMap { pageRect($0.sourceBounds, frame: frame) }
        return NativeTranslationEffectGloss.refining(records: records, keptSources: kept, frame: frame,
            opacity: settings.renderedBackgroundOpacity, inpaintingEnabled: settings.usesSourceInpainting, image: source,
            readSource: { rect,width,height in source.flatMap { sampleSource($0, rect: rect, frame: frame, width: width, height: height) } },
            measure: { id,text,size,width,lineHeight,origin,title in
                guard let card = cards.first(where: { $0.item.id == id }) else { return [] }
                let style = glossStyle(card: card, size: size, lineHeight: lineHeight, title: title)
                let measured = NativeTranslationTypography.layout(text: glossText(text, title: title),
                    in: CGSize(width: width, height: ceil(lineHeight * 3)), style: style)
                return measured.inkBounds.isEmpty ? [] : [measured.inkBounds.offsetBy(dx: origin.x, dy: origin.y)]
            })
    }

    static func captionPolishKeptZones(layout: NativeTranslationLayout,
                                      restoration: NativeTranslationRestoration.Result,
                                      recovered: NativeRecoveredLineProtection.Result) -> [CGRect] {
        let frame = restoration.cleanupGeometry?.frame ?? layout.sourceRect
        let recoveredKept = recovered.kept.map {
            NativeKeptSourceRestoration.Kept(id: $0.id, rect: $0.rect, sourceFontSize: $0.sourceFontSize)
        }
        return (NativeKeptSourceRestoration.zones(items: layout.items, cleanupFrame: frame) +
            NativeKeptSourceRestoration.zones(kept: recoveredKept, painted: recovered.painted)).map(\.rect)
    }

    static func polishCaptionPanels(cards: inout [Card], glossCards: [GlossCard],
                                            gloss: NativeTranslationEffectGloss.Refinement, layout: NativeTranslationLayout,
                                            settings: IPhoneOverlaySettings, source: CGImage?, keptZones: [CGRect] = []) {
        let records = cards.filter { !gloss.hiddenIDs.contains($0.item.id) }.map { card -> NativeTranslationCaptionPanelPolish.Entry in
            let item = card.item
            var ink = cardWholeRangeRect(card) ?? .zero
            var font = Double(card.finalFontSize)
            if let note = glossCards.first(where: { $0.note.id == item.id }), let move = note.note.placement.moves.first {
                ink = note.typography.inkBounds.offsetBy(dx: note.note.origin.x + move.x, dy: note.note.origin.y + move.y)
                if let center = note.note.placement.center, let angle = note.note.placement.angle {
                    let cosine = cos(angle), sine = sin(angle)
                    let corners = [CGPoint(x: ink.minX,y: ink.minY),CGPoint(x: ink.maxX,y: ink.minY),
                                   CGPoint(x: ink.maxX,y: ink.maxY),CGPoint(x: ink.minX,y: ink.maxY)].map { p in
                        CGPoint(x: center.x + (p.x-center.x)*cosine - (p.y-center.y)*sine,
                                y: center.y + (p.x-center.x)*sine + (p.y-center.y)*cosine)
                    }
                    let left = corners.map(\.x).min()!, top = corners.map(\.y).min()!
                    ink = CGRect(x: left,y: top,width: corners.map(\.x).max()!-left,height: corners.map(\.y).max()!-top)
                }
                font = note.note.placement.size
            }
            return .init(id: item.id, sourceTextOnly: item.sourceTextOnly, rotation: Double(item.rotation),
                vertical: item.vertical, lettering: item.sourceLettering, wrappingScript: item.wrappingScript,
                font: font, frame: layout.sourceRect,
                sources: ([item.sourceBounds] + item.auxiliaryInkRects).compactMap { pageRect($0, frame: layout.sourceRect) },
                balancedColumn: item.balancedColumn, column: item.columnLayout?.rect,
                columnPaddingTop: Double(item.columnLayout?.paddingTop ?? 0), ink: ink,
                panels: gloss.removedLayerIDs.contains(item.id) ? [] : card.sourcePanels,
                backings: gloss.removedLayerIDs.contains(item.id) ? [] : card.backings, isFlat: card.style.horizontalScale == 1,
                hasForeignFills: !card.foreignFills.isEmpty)
        }
        let kept = keptZones.isEmpty ? layout.items.filter(\.keptLettering).compactMap { NativeKeptSourceRestoration.sourceRect($0) } : keptZones
        let result = NativeTranslationCaptionPanelPolish.polish(records, opacity: settings.renderedBackgroundOpacity, kept: kept,
            readSource: { rect,frame in
                guard let source else { return nil }
                let width = max(1, Int(ceil(rect.width * CGFloat(source.width) / frame.width)))
                let height = max(1, Int(ceil(rect.height * CGFloat(source.height) / frame.height)))
                return sampleSource(source, rect: rect, frame: frame, width: width, height: height).map { ($0,width) }
            }, committedPanelRect: usedRect)
        for record in result {
            guard let index = cards.firstIndex(where: { $0.item.id == record.id }) else { continue }
            cards[index].sourcePanels = record.panels; cards[index].backings = record.backings
            // Frozen detach(e) preserves the current node box before appending
            // it to root; subsequent panel changes no longer move its children.
            if record.detached, cards[index].captionParentPlate {
                appendTextToRoot(cards: &cards, index: index)
                cards[index].textZ = 3
                cards[index].authoredTextOrigin = cards[index].item.rect.origin
            }
            if record.shift.x != 0 || record.shift.y != 0 {
                var moved = cards[index].item
                moved.x = (cards[index].authoredTextOrigin?.x ?? moved.x) + record.shift.x
                moved.y = (cards[index].sourceColumnAuthoredTop ?? cards[index].authoredTextOrigin?.y ?? moved.y) + record.shift.y
                cards[index].authoredTextOrigin = CGPoint(x: moved.x, y: moved.y)
                if cards[index].sourceColumnAuthoredTop != nil { cards[index].sourceColumnAuthoredTop = moved.y }
                cards[index].item = usedLayoutItem(moved)
            }
        }
    }

    static func polishFinalGeometry(cards: inout [Card], gloss: NativeTranslationEffectGloss.Refinement,
                                            layout: NativeTranslationLayout, restoration: NativeTranslationRestoration.Result,
                                            anchorsOnly: Bool) {
        let snapshot = cards
        let input = cards.compactMap { card -> NativeTranslationFinalGeometry.Entry? in
            let item = card.item
            guard item.sourceFrame.count == 4, item.sourceFrame.allSatisfy(\.isFinite) else { return nil }
            let frame = CGRect(x: item.sourceFrame[0], y: item.sourceFrame[1], width: item.sourceFrame[2], height: item.sourceFrame[3])
            guard let source = pageRect(item.sourceBounds, frame: frame) else { return nil }
            var entry = NativeTranslationFinalGeometry.Entry(id: item.id, frame: frame, source: source,
                lines: cardPageLineRects(card), font: Double(card.finalFontSize), pitch: Double(card.style.lineHeight), stroke: Double(card.style.outlineWidth), plate: nil)
            entry.uprightQuadText = item.uprightQuadText; entry.sourceDisplay = item.sourceLettering == "display"
            entry.sourceVertical = item.sourceVertical; entry.vertical = item.vertical; entry.originalRotation = Double(item.rotation)
            entry.hasBalloon = item.balloonInterior != nil; entry.hasBalancedColumnPlan = item.columnLayout?.balancedColumn == true
            entry.isRoot = !card.captionParentPlate; entry.inpainted = card.sourceBackgroundKind == "inpainted"
            entry.keepsSource = card.preservedGloss || card.preservedErasure
            entry.visible = !gloss.hiddenIDs.contains(item.id) && !gloss.removedLayerIDs.contains(item.id)
            entry.horizontalScale = Double(card.style.horizontalScale); entry.textUpright = card.finalUprightText || item.drawsUprightQuadText
            if let panel = card.sourcePanels.last, card.rotatesSourcePanels || card.panelStraightened {
                var matrix = NativeTranslationFinalGeometry.Matrix()
                if !card.panelStraightened {
                    matrix.a = cos(Double(item.rotation)); matrix.b = sin(Double(item.rotation))
                    matrix.c = -matrix.b; matrix.d = matrix.a
                }
                entry.plate = .init(rect: card.panelStraightened ? panel.rect : rotatedBounds(panel.rect, about: card.sourcePlateRect, angle: item.rotation),
                    size: panel.rect.size, matrix: matrix, hasBackgroundImage: panel.sourceFrameImage != nil)
            } else if card.drawsPanel, item.rotation != 0 {
                var matrix = NativeTranslationFinalGeometry.Matrix()
                matrix.a = cos(Double(item.rotation)); matrix.b = sin(Double(item.rotation)); matrix.c = -matrix.b; matrix.d = matrix.a
                entry.plate = .init(rect: rotatedBounds(item.rect, about: item.rect, angle: item.rotation), size: item.rect.size,
                    matrix: matrix, hasBackgroundImage: card.usesFallbackVeil)
            }
            return entry
        }
        var proposals: [String: (NativeTranslationTypography.Style, NativeTranslationTypography.Layout)] = [:]
        let result: [NativeTranslationFinalGeometry.Entry]
        if anchorsOnly {
            result = NativeTranslationFinalGeometry.anchorVerticalTops(input, itemCount: layout.items.count)
        } else {
            let upright = NativeTranslationFinalGeometry.uprightText(input, reshape: { entry,font,pitch,scale in
                guard let card = snapshot.first(where: { $0.item.id == entry.id }) else { return nil }
                var style = card.style
                style.fontSize = CGFloat(font); style.lineHeight = CGFloat(pitch); style.tracking = -CGFloat(font) * 0.012; style.horizontalScale = CGFloat(scale)
                let measured = remeasureTypography(card,style: style)
                let lines = NativeTranslationTypography.captionLineMetrics(layout: measured).map { $0.rect.offsetBy(dx: card.textOrigin.x, dy: card.textOrigin.y) }
                proposals[entry.id] = (style,measured)
                return .init(lines: lines, scrollSize: measured.size, clientSize: card.item.contentRect.size)
            })
            result = NativeTranslationFinalGeometry.uprightPlate(upright)
        }
        for entry in result {
            guard let index = cards.firstIndex(where: { $0.item.id == entry.id }) else { continue }
            cards[index].sourceTopAnchored = cards[index].sourceTopAnchored || entry.sourceTopAnchored
            if entry.shift != .zero {
                cards[index].item.x += entry.shift.x
                let authoredTop = anchorsOnly ? cards[index].sourceColumnAuthoredTop : nil
                cards[index].item.y = (authoredTop ?? cards[index].item.y) + entry.shift.y
                if authoredTop != nil { cards[index].sourceColumnAuthoredTop = cards[index].item.y }
                cards[index].item = usedLayoutItem(cards[index].item)
            }
            if entry.textUpright, !anchorsOnly, let (style,measured) = proposals[entry.id] {
                cards[index].style = style; cards[index].typography = measured; cards[index].finalFontSize = style.fontSize
                cards[index].item.drawsUprightQuadText = true; cards[index].finalUprightText = true
            }
            if let plate = entry.plate, plate.upright, let panelIndex = cards[index].sourcePanels.indices.last {
                cards[index].sourcePanels[panelIndex].rect = plate.rect; cards[index].sourcePanels[panelIndex].coverage = [plate.rect]
                cards[index].sourcePanels[panelIndex].radius = 0
                cards[index].rotatesSourcePanels = false; cards[index].panelStraightened = true
            } else if let plate = entry.plate, plate.upright, cards[index].drawsPanel {
                cards[index].straightenedPanelRect = plate.rect; cards[index].panelStraightened = true
            }
        }
    }

    static func polishPanelGeometry(cards: inout [Card], gloss: NativeTranslationEffectGloss.Refinement,
                                            layout: NativeTranslationLayout, restoration: NativeTranslationRestoration.Result,
                                            settings: IPhoneOverlaySettings, containBalloon: Bool = false, phase: NativePanelGeometry.Phase = .all, restoredSourcePanelIDs: Set<String> = [], rememberedPadding: [String: CGFloat] = [:]) {
        let frame = restoration.cleanupGeometry?.frame ?? layout.sourceRect
        let input = cards.filter { !gloss.hiddenIDs.contains($0.item.id) && !gloss.removedLayerIDs.contains($0.item.id) }.map { card -> NativePanelGeometry.Record in
            let item = card.item, appearance = restoration.appearances[item.id]
            let foreground = rgb(card.style.foreground) ?? [17, 18, 23]
            let sample = appearance?.sourceSample ?? [:]
            let caption = NativeTranslationSourceStylePostPolish.captionPalette(sample: sample, ink: foreground,
                preserveText: settings.preserveSourceTextColor, displayInk: NativeSourceColorSampler.displayedInk(sample))
            let balloon = item.balloonInterior ?? item.balloonUnit?.interior
            var record = NativePanelGeometry.Record(id: item.id, ink: cardWholeRangeRect(card) ?? .zero,
                source: pageRect(item.sourceBounds, frame: frame),
                sources: ([item.sourceBounds] + item.auxiliaryInkRects).compactMap { pageRect($0, frame: frame) },
                sourceColorEligible: item.sourceColorEligible, sourceTextOnly: item.sourceTextOnly,
                balancedColumn: item.balancedColumn, vertical: item.vertical, rotation: Double(item.rotation),
                font: Double(card.finalFontSize), sourceFont: item.sourceFontSize.map { Double($0) }, sourceVertical: item.sourceVertical,
                inkPadding: Double(rememberedPadding[item.id] ?? 0),
                foreground: foreground, fallbackBackground: caption.background, panels: card.sourcePanels)
            record.restoredSourcePanels = restoredSourcePanelIDs.contains(item.id)
            record.certifiedErasure = card.earlyErasureCertified
            record.isFlat = item.rotation == 0 && card.style.horizontalScale == 1
            record.transparentBackground = !card.drawsPanel
            record.balloon = balloon.map { .init(frame: frame, rect: $0.normalizedRect, spans: $0.spans, contourVerified: $0.contourVerified) }
            record.glyphs = cardPageLineRects(card)
            record.strokeWidth = Double(card.style.outlineWidth); record.backings = card.backings
            return record
        }
        let polished = containBalloon ? input : NativePanelGeometry.polish(input, opacity: settings.renderedBackgroundOpacity, phase: phase)
        let snapshot = cards
        func proposalKey(_ id: String, _ frame: CGRect, _ font: Double) -> String {
            ([Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height), font].map { String($0.bitPattern) } + [id]).joined(separator: "|")
        }
        var proposals: [String: (NativeTranslationLayoutItem, NativeTranslationTypography.Style, NativeTranslationTypography.Layout)] = [:]
        let result = containBalloon && settings.renderedBackgroundOpacity == 1 ? NativePanelGeometry.containBalloonPanels(polished, measure: { id,frame,font in
            guard let card = snapshot.first(where: { $0.item.id == id }) else { return nil }
            var item = card.item, style = card.style
            item.x = frame.minX; item.y = frame.minY; item.width = frame.width; item.height = frame.height
            item.paddingTop = 1; item.paddingLeft = 1; item.paddingBottom = 1; item.paddingRight = 1
            item.typesettingText = nil; item.typesettingQuoteMode = nil; item.typesettingBlockDisplay = nil; item.typesettingPreformattedRows = nil; item.typesettingPreservedBlockWrapper = nil; item.typesettingWidthScale = nil
            style.usesBlockWordLayout = false; style.usesPreformattedBlockRows = false; style.blockWordLayoutUsesTopPadding = false
            item.balancedColumn = false; style.horizontalScale = 1; style.optimizesKoreanWrapping = false
            style.fontSize = CGFloat(font); style.lineHeight *= CGFloat(font) / card.style.fontSize
            style.tracking *= CGFloat(font) / card.style.fontSize
            let measured = NativeTranslationTypography.layout(text: item.text, in: item.contentRect.size, style: style)
            let glyphs = NativeTranslationTypography.captionLineMetrics(layout: measured).map { $0.rect.offsetBy(dx: item.contentRect.minX, dy: item.contentRect.minY) }
            proposals[proposalKey(id, frame, font)] = (item, style, measured)
            return .init(glyphs: glyphs, scrollFits: measured.fits)
        }) : polished
        for record in result {
            guard let index = cards.firstIndex(where: { $0.item.id == record.id }) else { continue }
            cards[index].sourcePanels = record.panels; cards[index].backings = record.backings
            cards[index].item.x += record.shift.x; cards[index].item.y += record.shift.y
            cards[index].authoredTextOrigin?.x += record.shift.x; cards[index].authoredTextOrigin?.y += record.shift.y
            if let frame = record.reflowFrame, let font = record.reflowFont, let (item,style,typography) = proposals[proposalKey(record.id, frame, font)] {
                cards[index].item = item; cards[index].style = style; cards[index].typography = typography
                cards[index].authoredTextOrigin = frame.origin
                cards[index].finalFontSize = style.fontSize; cards[index].textShift = .zero; cards[index].typographyWidth = nil; cards[index].lineOffsets = []
            }
            cards[index].style.foreground = color(record.foreground.map { CGFloat($0) })
            cards[index].typography = remeasureTypography(cards[index])
        }
    }

    private static func commitBalloonUnits(cards: inout [Card], gloss: NativeTranslationEffectGloss.Refinement,
                                           layout: NativeTranslationLayout, restoration: NativeTranslationRestoration.Result, restoredSourcePanelIDs: Set<String> = []) {
        let snapshot = cards
        let frame = restoration.cleanupGeometry?.frame ?? layout.sourceRect
        let records = cards.map { card -> NativeTranslationBalloonUnitCommit.Record in
            let item = card.item, patch = restoration.patches.last(where: { $0.itemID == item.id && !$0.independentArtworkCover })
            var record = NativeTranslationBalloonUnitCommit.Record(id: item.id,text: item.text,
                sourceBounds: item.sourceBounds.map { Double($0) },
                sourceRects: ([item.sourceBounds]+item.auxiliaryInkRects).compactMap { pageRect($0,frame: frame) },
                ink: cardInkRect(card),font: Double(card.finalFontSize),pitch: Double(card.style.lineHeight),sourceFontSize: item.sourceFontSize.map { Double($0) })
            if let unit = item.balloonUnit {
                record.unit = .init(members: unit.members,interior: .init(rect: unit.interior.rect.map { Double($0) },
                    center: unit.interior.center.map { Double($0) },spans: unit.interior.spans))
            }
            record.hasNode = !gloss.hiddenIDs.contains(item.id) && !gloss.removedLayerIDs.contains(item.id)
            record.sourceVertical = item.sourceVertical; record.rotation = Double(item.rotation); record.vertical = item.vertical
            record.balancedColumn = item.balancedColumn; record.isRoot = !card.captionParentPlate
            record.transformNone = item.rotation == 0; record.preservedGloss = card.preservedGloss || card.preservedErasure
            record.hasScaleStyle = card.style.horizontalScale != 1
            record.backgroundKind = card.sourceBackgroundKind ?? ""
            record.restoredSourcePanel = restoredSourcePanelIDs.contains(item.id)
            record.restoredSurfaceFontFit = card.restoredSurfaceFontFit
            record.sourceAlignment = card.sourceAlignment; record.sourceHeading = card.sourceHeading != nil
            record.hasRestoration = patch != nil; record.erasureComplete = patch?.candidate?.erasureComplete ?? restoration.appearances[item.id]?.erasureComplete ?? false
            record.provisional = patch?.candidate?.provisional ?? restoration.appearances[item.id]?.provisional ?? false
            return record
        }
        let layers = cards.flatMap { card in
            card.sourcePanels.map { NativeTranslationBalloonUnitCommit.Layer(ownerID: card.item.id,rect: $0.rect) } +
                card.backings.map { .init(ownerID: card.item.id,rect: $0.frame) }
        }
        let kept = layout.items.filter(\.keptLettering).map { item in
            NativeTranslationBalloonUnitCommit.ProtectedSource(id: item.id,
                rects: ([item.sourceBounds]+item.auxiliaryInkRects).compactMap { pageRect($0,frame: frame) })
        }
        func shape(_ record: NativeTranslationBalloonUnitCommit.Record,_ font: Double,_ width: Double,_ pitch: Double,_ pad: Double) -> (NativeTranslationLayoutItem,NativeTranslationTypography.Style,NativeTranslationTypography.Layout)? {
            guard let card = snapshot.first(where: { $0.item.id == record.id }) else { return nil }
            var item = card.item, style = card.style
            item.x = 0; item.y = 0; item.width = CGFloat(width+2*pad); item.height = CGFloat(pitch*Double(max(2,item.text.utf16.count+1))+pad*2)
            item.paddingTop = CGFloat(pad); item.paddingLeft = CGFloat(pad); item.paddingBottom = CGFloat(pad); item.paddingRight = CGFloat(pad)
            item.typesettingText = nil; item.typesettingQuoteMode = nil; item.typesettingBlockDisplay = nil; item.typesettingPreformattedRows = nil; item.typesettingPreservedBlockWrapper = nil; item.typesettingWidthScale = nil
            style.usesBlockWordLayout = false; style.usesPreformattedBlockRows = false; style.blockWordLayoutUsesTopPadding = false
            style.fontSize = CGFloat(font); style.lineHeight = CGFloat(pitch); style.tracking = -CGFloat(font)*0.012
            style.horizontalWhitespace = .normal; style.horizontalWrapping = .keepAll; style.keepsWholeWords = false; style.balancesHorizontalLines = false; style.alignsToTop = true; style.horizontalScale = 1
            let first = NativeTranslationTypography.layout(text: item.text,in: item.contentRect.size,style: style)
            item.height = max(CGFloat(pad*2),first.size.height+CGFloat(pad*2))
            let measured = NativeTranslationTypography.layout(text: item.text,in: item.contentRect.size,style: style)
            return (item,style,measured)
        }
        let result = NativeTranslationBalloonUnitCommit.commit(records: records,layers: layers,kept: kept,frame: frame,
            measure: { record,font,width,pitch,pad,_ in
                guard let (item,_,measured) = shape(record,font,width,pitch,pad) else { return nil }
                let ink = measured.rangeBounds.reduce(CGRect.null) { $0.union($1) }.offsetBy(dx: item.contentRect.minX,dy: item.contentRect.minY)
                return .init(ink: ink,nodeRect: item.rect,scrollWidth: Double(measured.size.width),clientWidth: Double(item.contentRect.width))
            },widestWord: { text,font in
                Double(NativeTranslationTypography.widestWord(text: text,style: .init(fontName: "Helvetica-Bold",fontSize: CGFloat(font),tracking: 0)))
            },verify: { record,placement,_ in
                guard var (item,_,measured) = shape(record,placement.font,Double(placement.rect.width)-2*placement.padding,placement.pitch,placement.padding) else { return nil }
                item.x = placement.rect.minX; item.y = placement.rect.minY
                return measured.rangeBounds.reduce(CGRect.null) { $0.union($1) }.offsetBy(dx: item.contentRect.minX,dy: item.contentRect.minY)
            })
        for record in result.records {
            guard let placement = record.placement,let index = cards.firstIndex(where: { $0.item.id == record.id }),
                  var (item,style,measured) = shape(record,placement.font,Double(placement.rect.width)-2*placement.padding,placement.pitch,placement.padding) else { continue }
            item.x = placement.rect.minX; item.y = placement.rect.minY
            cards[index].item = item; cards[index].style = style; cards[index].typography = measured
            cards[index].textShift = .zero; cards[index].typographyWidth = nil; cards[index].lineOffsets = []; cards[index].finalFontSize = style.fontSize
        }
    }

    static func packCaptions(cards: inout [Card], gloss: NativeTranslationEffectGloss.Refinement,
                                     layout: NativeTranslationLayout, restoration: NativeTranslationRestoration.Result,
                                     settings: IPhoneOverlaySettings, source: CGImage?, balloons: BalloonRelayoutContext? = nil, collectDiagnostics: Bool = false,
                                     rememberedPadding: [String: CGFloat] = [:]) {
        let frame = restoration.cleanupGeometry?.frame ?? layout.sourceRect
        let snapshot = cards
        let input = cards.map { card -> NativeCaptionPacking.Entry in
            let item = card.item, visible = !gloss.hiddenIDs.contains(item.id) && !gloss.removedLayerIDs.contains(item.id)
            var entry = NativeCaptionPacking.Entry(id: item.id, text: card.artworkRecord == nil && item.captionFixedBoxReflowDisabled == true && item.typesettingQuoteMode != nil
                    ? (item.typesettingText ?? item.text) : item.text,
                font: Double(card.finalFontSize), ink: visible ? (cardWholeRangeRect(card) ?? .zero) : .zero,
                panels: visible ? card.sourcePanels.map { .init(rect: $0.rect, color: $0.background, coverage: $0.coverage,
                    sourceErasure: $0.sourceErasure, clipped: $0.captionUnionClipped, radius: $0.radius, coverageClip: $0.coverageClip, coverageClipActive: $0.clipped) } : [])
            entry.originalFont = max(Double(card.style.fontSize),card.artworkRecord.flatMap { Double($0["artworkOriginalFont"] ?? "") } ?? Double(card.style.fontSize)); entry.lineRatio = Double(card.style.lineHeight / card.style.fontSize)
            entry.source = pageRect(item.sourceBounds, frame: frame); entry.sourceFont = item.sourceFontSize.map { Double($0) }
            entry.vertical = item.vertical; entry.rotation = Double(item.rotation); entry.balancedColumn = item.balancedColumn
            entry.packingValid = cardScrollFits(card, allowance: 1) && cardWholeRangeRect(card).map { NativePanelGeometry.inside($0, physicalTextNodeRect(card), tolerance: 1) } == true
            entry.sources = ([item.sourceBounds] + item.auxiliaryInkRects).compactMap { pageRect($0, frame: frame) }
            entry.isUnit = joinedUnitMembers(item) != nil; entry.unitResidue = restoration.unitResidueRiskIDs.contains(item.id)
            entry.sourceErasurePreserved = card.preservedErasure || card.preservedGloss
            entry.readabilityPanel = !card.sourcePanels.isEmpty; entry.hasBackgroundImage = false
            entry.panels += visible ? card.backings.map { .init(rect: $0.frame, color: $0.color, coverage: $0.coverage, backing: true, coverageClip: $0.coverageClip, coverageClipActive: $0.clipped) } : []
            if let note = gloss.notes.first(where: { $0.id == item.id }), let move = note.placement.moves.first {
                let style = glossStyle(card: card, size: note.placement.size, lineHeight: note.placement.lineHeight,
                    title: note.title, retained: note.retainedTypography)
                let measured = NativeTranslationTypography.layout(text: glossText(note.text, title: note.title),
                    in: note.contentSize, style: style)
                let bounds = measured.rangeBounds.reduce(CGRect.null) { $0.union($1) }
                entry.ink = bounds.isNull ? .zero : bounds.offsetBy(dx: note.origin.x + move.x, dy: note.origin.y + move.y)
                if let center = note.placement.center, let angle = note.placement.angle {
                    entry.ink = rotatedBounds(entry.ink, about: CGRect(x: center.x, y: center.y, width: 0, height: 0), angle: CGFloat(angle))
                }
                entry.font = note.placement.size; entry.panels = []; entry.sourceErasurePreserved = true
            }
            return entry
        }
        func key(_ id: String, _ rect: CGRect, _ font: Double) -> String {
            ([Double(rect.minX),Double(rect.minY),Double(rect.width),Double(rect.height),font].map { String($0.bitPattern) } + [id]).joined(separator: "|")
        }
        var proposals: [String: (NativeTranslationLayoutItem,NativeTranslationTypography.Style,NativeTranslationTypography.Layout)] = [:]
        let balloonRelayout = balloons ?? BalloonRelayoutContext(layout: layout, source: source, restoration: restoration, cards: snapshot)
        func rectData(_ rect: CGRect) -> [Double] { [Double(rect.minX),Double(rect.minY),Double(rect.width),Double(rect.height)] }
        var packingProbes: [String:[[String:Any]]] = [:]
        let result = NativeCaptionPacking.pack(input, page: frame,
            minimumFont: Double(BrowserOverlayLayoutPlanner.minimumRenderedFontSize), opacity: settings.renderedBackgroundOpacity,
            measure: { entry,cell,font in
                guard let card = snapshot.first(where: { $0.item.id == entry.id }) else { return nil }
                var item = card.item, style = card.style
                item.x = cell.minX; item.y = cell.minY; item.width = cell.width; item.height = cell.height
                item.paddingTop = 3; item.paddingRight = 3; item.paddingBottom = 3; item.paddingLeft = 3
                style.fontSize = CGFloat(font); style.lineHeight = CGFloat(font * entry.lineRatio); style.tracking = -CGFloat(font) * 0.012
                style.alignsToTop = false
                style.usesBlockWordLayout = item.captionFixedBoxReflowDisabled == true && item.typesettingText != nil && item.typesettingQuoteMode != nil && entry.text == item.typesettingText
                style.usesPreformattedBlockRows = false; item.typesettingPreformattedRows = nil
                style.blockWordLayoutUsesTopPadding = false; item.typesettingBlockDisplay = false
                item.typesettingPreservedBlockWrapper = style.usesBlockWordLayout
                if !style.usesBlockWordLayout { item.typesettingText = nil; item.typesettingQuoteMode = nil; item.typesettingBlockDisplay = nil; item.typesettingPreformattedRows = nil; item.typesettingPreservedBlockWrapper = nil }
                item.fontSize = style.fontSize; item.lineHeight = style.lineHeight; item.typesettingWidthScale = style.horizontalScale
                item = usedLayoutItem(item)
                let measured = NativeTranslationTypography.layout(text: entry.text, in: item.contentRect.size, style: style)
                guard let local = NativeTranslationTypography.wholeRangeBounds(layout: measured, style: style, available: item.contentRect.size,
                    preservesBlockWrapper: style.usesBlockWordLayout) else { return nil }
                let ink = local.offsetBy(dx: item.contentRect.minX, dy: item.contentRect.minY)
                proposals[key(entry.id,cell,font)] = (item,style,measured)
                if collectDiagnostics {
                    packingProbes[entry.id,default: []].append(["cell": rectData(cell),"font": font,
                        "text": entry.text,"ink": rectData(ink),"lineCount": measured.lineCount,
                        "lineRects": NativeTranslationTypography.captionLineMetrics(layout: measured).map { rectData($0.rect) },
                        "contentFits": NativeTypographyPostPolish.contentFits(item: item,typography: measured),"inkFits": measured.fits])
                }
                return .init(ink: ink, scrollFits: NativeTypographyPostPolish.contentFits(item: item, typography: measured))
            }, readSource: { rect,width,height in
                guard let source, valid(rect) else { return nil }
                if width > 0, height > 0 {
                    return sampleSource(source, rect: rect, frame: frame, width: width, height: height).map { .init(rgba: $0, width: width, height: height) }
                }
                let sx = CGFloat(source.width) / frame.width, sy = CGFloat(source.height) / frame.height
                let left = max(0, floor((rect.minX-frame.minX)*sx)), top = max(0, floor((rect.minY-frame.minY)*sy))
                let right = min(CGFloat(source.width),ceil((rect.maxX-frame.minX)*sx))
                let bottom = min(CGFloat(source.height),ceil((rect.maxY-frame.minY)*sy))
                guard right > left, bottom > top, (right-left)*(bottom-top) <= 65_536 else { return nil }
                let w = Int(right-left), h = Int(bottom-top)
                return (try? NativeSourcePixelReader.draw(image: source, x: Double(left), y: Double(top), sourceWidth: Double(w), sourceHeight: Double(h), width: w, height: h)).map { .init(rgba: $0,width: w,height: h) }
            }, balloonRelayout: { entry in balloonRelayout.relayout(entry, input: input) }, usedPanelRect: usedRect)
        for entry in result.entries {
            guard let index = cards.firstIndex(where: { $0.item.id == entry.id }) else { continue }
            let previous = cards[index].sourcePanels
            if collectDiagnostics, let initial = input.first(where: { $0.id == entry.id }) {
                cards[index].captionPackingRecord = ["beforeFont": initial.font,"beforeText": initial.text,
                    "beforeInk": rectData(initial.ink),"beforeValid": initial.packingValid,
                    "preservedWordAwareRows": snapshot[index].item.captionFixedBoxReflowDisabled == true && snapshot[index].item.typesettingText != nil && snapshot[index].item.typesettingQuoteMode != nil,
                    "beforePanels": initial.panels.map { rectData($0.rect) },
                    "beforeBackings": snapshot[index].backings.map { ["frame": rectData($0.frame), "coverage": $0.coverage.map(rectData), "color": $0.color] as [String: Any] },
                    "unified": entry.unified,"acceptedCell": entry.cell.map(rectData) ?? [],
                    "afterFont": entry.font,"probes": packingProbes[entry.id] ?? [],
                    "pagePreflightMeasurements": result.measurements,"pageFallbacks": result.fallbacks]
            }
            cards[index].sourcePanels = entry.panels.filter { !$0.backing }.enumerated().map { offset,panel in
                var model = previous.indices.contains(offset) ? previous[offset] : NativeTranslationSourceStylePostPolish.Panel(rect: panel.rect, background: panel.color, coverage: panel.coverage)
                model.rect = usedRect(panel.rect); model.background = panel.color; model.coverage = panel.coverage
                if !panel.clipped && panel.coverage == [panel.rect] { model.coverage = [model.rect] }
                model.sourceErasure = panel.sourceErasure; model.clipped = panel.coverageClipActive ?? panel.clipped; model.coverageClip = panel.coverageClip; model.captionUnionClipped = panel.clipped; model.radius = panel.radius
                if entry.cell != nil { model.overflowClip = true }
                return model
            }
            cards[index].backings = entry.panels.filter(\.backing).map { .init(frame: $0.rect,coverage: $0.coverage,color: $0.color, clipped: $0.coverageClipActive ?? $0.clipped, coverageClip: $0.coverageClip) }
            cards[index].foreignFills = entry.foreignFills
            if entry.cell != nil, let owner = cards[index].sourcePanels.lastIndex(where: { !$0.sourceErasure }) {
                attachCaptionParent(cards: &cards, childIndex: index, ownerIndex: index, panelIndex: owner)
                cards[index].sourcePanelZ = 2
            }
            if let cell = entry.cell, let (item,style,measured) = proposals[key(entry.id,cell,entry.font)] {
                cards[index].item = item; cards[index].style = style; cards[index].typography = measured; cards[index].finalFontSize = style.fontSize
                cards[index].authoredTextOrigin = cards[index].sourcePanels.last(where: { !$0.sourceErasure })?.rect.origin ?? usedRect(cell).origin
                cards[index].textShift = entry.finalAnchorShift ?? .zero
                let packingShift = cards[index].textShift
                cards[index].authoredTextOrigin?.x += packingShift.x
                cards[index].authoredTextOrigin?.y += packingShift.y
                cards[index].typographyWidth = nil; cards[index].lineOffsets = []
            } else if let rect = entry.relayoutTextRect, let pitch = entry.relayoutLinePitch {
                let committed = balloonRelayout.shape(snapshot[index], rect: rect, font: entry.font, pitch: pitch)
                cards[index].authoredTextOrigin = rect.origin
                cards[index].item = committed.item; cards[index].style = committed.style
                cards[index].typography = committed.typography; cards[index].finalFontSize = committed.finalFontSize
                cards[index].typographyWidth = nil; cards[index].lineOffsets = []
                cards[index].textShift = entry.finalAnchorShift ?? .zero
            }
        }
        if settings.renderedBackgroundOpacity == 1, layout.items.count <= 256 {
            clipSkippedCaptionBridges(cards: &cards, skippedIDs: result.skippedIDs, layout: layout,
                restoration: restoration, finalInks: result.entries.map(\.ink), rememberedPadding: rememberedPadding)
        }
        refreshCaptionOwnerGraph(cards: &cards)
    }

    private static func preparePrimaryOutlines(cards: inout [Card], gloss: NativeTranslationEffectGloss.Refinement,
                                               layout: NativeTranslationLayout, source: CGImage?,
                                               restoration: NativeTranslationRestoration.Result, settings: IPhoneOverlaySettings) {
        guard settings.renderedBackgroundOpacity == 1 else { return }
        let frame = restoration.cleanupGeometry?.frame ?? layout.sourceRect
        var outlineEvidence: [String: NativeSourceOutlineScan.Analysis] = [:]
        if settings.preserveSourceTextColor && settings.preserveSourceBackgroundColor, let source {
            let input = cards.map { card -> NativeSourceOutlineScan.Record in
                let item = card.item
                return .init(id: item.id, sourceBounds: item.sourceBounds.map { Double($0) }, sourceFrame: frame,
                    sourceFontSize: item.sourceFontSize.map { Double($0) }, sourceVertical: item.sourceVertical,
                    sourceColorEligible: item.sourceColorEligible,
                    visible: !gloss.hiddenIDs.contains(item.id) && !gloss.removedLayerIDs.contains(item.id),
                    backgroundKind: card.sourceBackgroundKind ?? "",
                    appliedForeground: rgb(card.style.foreground), appliedStrokeWidth: Double(card.style.outlineWidth),
                    opaquePlate: card.sourcePanels.first?.background, sample: restoration.appearances[item.id]?.sourceSample ?? [:],
                    partialMainbodyProof: card.partialSourcePositionProof ? "outlined-source-position" : nil)
            }
            let size = CGSize(width: source.width, height: source.height)
            outlineEvidence = NativeSourceOutlineScan.scan(records: input, imageSize: size, displayFrame: frame,
                reader: { crop,width,height in
                    let rect = CGRect(x: frame.minX + crop.minX / size.width * frame.width,
                        y: frame.minY + crop.minY / size.height * frame.height,
                        width: crop.width / size.width * frame.width, height: crop.height / size.height * frame.height)
                    return sampleSource(source, rect: rect, frame: frame, width: width, height: height)
                })
        }
        for index in cards.indices {
            let item = cards[index].item
            guard !gloss.removedLayerIDs.contains(item.id), !gloss.hiddenIDs.contains(item.id) else { continue }
            cards[index].outlineEvidence = outlineEvidence[item.id]
            let appearance = restoration.appearances[item.id], analysis = outlineEvidence[item.id]
            if let ring = analysis?.ring {
                let owner = cards[index].sourcePanels.last(where: { !$0.sourceErasure })
                let foreign = cards.indices.filter { $0 != index }
                let alone = owner.map { panel in
                    !foreign.contains { other in cards[other].sourcePanels.contains { $0.rect.intersects(panel.rect) } }
                } ?? false
                var state = NativePrimaryOutlinedLettering.State(sample: appearance?.sourceSample ?? [:],
                    font: Double(cards[index].finalFontSize), foreground: rgb(cards[index].style.foreground),
                    stroke: rgb(cards[index].style.outline), strokeWidth: Double(cards[index].style.outlineWidth),
                    plate: owner?.background)
                state.restored = analysis?.restored == true; state.slanted = analysis?.slanted == true
                if state.slanted {
                    state.slantedSurfaceLuminance = NativeSlantedTypographyTrial.surfaceRange(cards[index].slantedTrial?.histogram)
                }
                state.missingColumnRing = analysis?.missingColumnRing == true; state.plateIsAlone = alone
                state.overlappingInks = owner.map { panel in foreign.filter { panelMeetsInk(panel, owner: cards[index], ink: cardInkRect(cards[$0])) }.map { rgb(cards[$0].style.foreground) } } ?? []
                let decision = NativePrimaryOutlinedLettering.decide(ring: ring, state: state)
                cards[index].outlinedRecord = decision.record
                if let fill = decision.fill { cards[index].style.foreground = color(fill.map { CGFloat($0) }) }
                if let stroke = decision.stroke {
                    cards[index].style.outline = color(stroke.map { CGFloat($0) }); cards[index].strokePreserved = true
                    cards[index].sourceStrokeKind = "preserved"
                    cards[index].style.outlinePaintOrder = .strokeThenFill
                }
                if decision.clearsStroke {
                    cards[index].style.outline = nil; cards[index].style.outlineWidth = 0; cards[index].strokePreserved = false
                    cards[index].sourceStrokeKind = "none"
                    cards[index].style.outlinePaintOrder = .fillThenStroke
                }
                if let width = decision.strokeWidth { cards[index].style.outlineWidth = CGFloat(width) }
                if let background = decision.background, let ownerIndex = cards[index].sourcePanels.lastIndex(where: { !$0.sourceErasure }) {
                    cards[index].sourcePanels[ownerIndex].background = background
                }
            }
            let card = cards[index]
            cards[index].typography = remeasureTypography(cards[index])
        }
    }

    private static func reconcileFinalStrokes(cards: inout [Card], glossCards: inout [GlossCard],
                                               gloss: NativeTranslationEffectGloss.Refinement, layout: NativeTranslationLayout, source: CGImage?,
                                               restoration: NativeTranslationRestoration.Result, settings: IPhoneOverlaySettings) {
        guard settings.renderedBackgroundOpacity == 1 else { return }
        var records: [NativeTranslationSourceStylePostPolish.Stroke] = []
        for index in cards.indices {
            let item = cards[index].item
            guard !gloss.removedLayerIDs.contains(item.id), !gloss.hiddenIDs.contains(item.id) else { continue }
            let appearance = restoration.appearances[item.id], analysis = cards[index].outlineEvidence
            if let fill = rgb(cards[index].style.foreground), let outline = rgb(cards[index].style.outline),
               cards[index].style.outlineWidth > 0, !item.sourceTextOnly, item.rotation == 0, !item.vertical,
               item.sourceLettering == nil, item.wrappingScript == "korean", cards[index].style.horizontalScale == 1 {
                let previousWidth = cards[index].style.outlineWidth
                cards[index].style.outlineWidth = CGFloat(NativeTranslationSourceStylePostPolish.dialogueStrokeWidth(
                    fill: fill, outline: outline, background: cards[index].sourcePanels.first?.background,
                    font: Double(cards[index].finalFontSize), width: Double(cards[index].style.outlineWidth),
                    releasedPreserved: cards[index].sourcePanels.isEmpty && cards[index].strokePreserved))
                if cards[index].style.outlineWidth != previousWidth { cards[index].style.outlinePaintOrder = .strokeThenFill }
            }
            if settings.preserveSourceTextColor {
                let appearance = restoration.appearances[item.id], sample = appearance?.sourceSample ?? [:]
                let result = NativeTranslationSourceStylePostPolish.lateSourceOutline(sample: sample,
                    font: Double(cards[index].finalFontSize), eligible: item.sourceColorEligible,
                    keepsSourceLettering: item.keptLettering, rotation: Double(item.rotation),
                    displayLettering: sample["displayLettering"] as? Bool ?? false,
                    backgroundKind: cards[index].sourceBackgroundKind ?? "",
                    appliedBackground: cards[index].sourcePanels.first?.background,
                    surfaceRange: cardSurfaceEvidence(cards[index],restoration: restoration)?.range,
                    ring: cards[index].outlinedRecord ?? cards[index].outlineEvidence?.ringData ?? sample["outlinedLettering"] as? [String: Any],
                    enclosed: cards[index].outlineEvidence?.enclosed ?? sample["enclosedCaptionOutline"] as? [String: Any],
                    certifiedSourcePosition: cards[index].partialSourcePositionProof,
                    appliedForeground: rgb(cards[index].style.foreground))
                if let outline = result.outline {
                    cards[index].style.foreground = color(outline.foreground.map { CGFloat($0) })
                    cards[index].style.outline = color(outline.stroke.map { CGFloat($0) })
                    cards[index].style.outlineWidth = CGFloat(outline.width)
                    cards[index].style.outlinePaintOrder = .strokeThenFill
                    cards[index].strokePreserved = true; cards[index].darkMeasured = result.darkPreserved
                }
            }
            guard let fill = rgb(cards[index].style.foreground), let outline = rgb(cards[index].style.outline),
                  cards[index].style.outlineWidth > 0 else { continue }
            let key = [item.fontScript, item.sourceVertical ? "v" : "h", cards[index].style.fontName ?? "system",
                       item.vertical ? "800" : "700", cards[index].strokePreserved ? "preserved" : "default",
                       NativeTranslationSourceStylePostPolish.colorClass(fill), NativeTranslationSourceStylePostPolish.colorClass(outline)]
                .joined(separator: "|")
            records.append(.init(id: item.id, key: key, glyph: item.sourceFontSize.map { Double($0) } ?? .nan,
                font: Double(cards[index].finalFontSize), width: Double(cards[index].style.outlineWidth), fill: fill,
                stroke: outline, preserved: cards[index].strokePreserved, darkMeasured: cards[index].darkMeasured))
        }
        for card in glossCards {
            guard let owner = cards.first(where: { $0.item.id == card.note.id }),
                  let fill = rgb(card.style.foreground), let outline = rgb(card.style.outline) else { continue }
            let key = [owner.item.fontScript, owner.item.sourceVertical ? "v" : "h", card.style.fontName ?? "system", "700", "gloss",
                       NativeTranslationSourceStylePostPolish.colorClass(fill), NativeTranslationSourceStylePostPolish.colorClass(outline)]
                .joined(separator: "|")
            records.append(.init(id: card.note.id, key: key,
                glyph: owner.item.sourceFontSize.map { Double($0) } ?? .nan,
                font: card.note.placement.size, width: Double(card.style.outlineWidth), fill: fill,
                stroke: outline, preserved: false, darkMeasured: false))
        }
        for result in NativeTranslationSourceStylePostPolish.strokeWidths(records) {
            if let index = glossCards.firstIndex(where: { $0.note.id == result.id }) {
                glossCards[index].style.outlineWidth = CGFloat(result.width)
                let card = glossCards[index]
                glossCards[index].typography = NativeTranslationTypography.layout(text: glossText(card.note.text, title: card.note.title),
                    in: card.note.contentSize, style: card.style)
            } else if let index = cards.firstIndex(where: { $0.item.id == result.id }) {
                cards[index].style.outlineWidth = CGFloat(result.width)
                let card = cards[index]
                cards[index].typography = NativeTranslationTypography.layout(text: card.item.typesettingText ?? card.item.text,
                    in: card.item.contentRect.size, style: card.style)
            }
        }
        for index in cards.indices {
            let card = cards[index]
            cards[index].typography = remeasureTypography(cards[index])
        }
    }

    private static func drawGloss(_ card: GlossCard, context: CGContext, pixelSnapScale: CGFloat? = nil) {
        let note = card.note
        guard let move = note.placement.moves.first else { return }
        context.saveGState(); defer { context.restoreGState() }
        let nodeOrigin = CGPoint(x: note.origin.x + move.x, y: note.origin.y + move.y)
        if let center = note.placement.center,
           let turn = NativeTranslationFinalRenderingHelpers.turnGloss(nodeOrigin: nodeOrigin, angle: note.placement.angle, center: center) {
            let anchor = CGPoint(x: nodeOrigin.x + turn.origin.x, y: nodeOrigin.y + turn.origin.y)
            context.translateBy(x: anchor.x, y: anchor.y); context.rotate(by: CGFloat(turn.angle))
            context.translateBy(x: -anchor.x, y: -anchor.y)
        }
        NativeTranslationTypography.draw(layout: card.typography, in: context,
            at: CGPoint(x: note.origin.x + move.x, y: note.origin.y + move.y),
            outlinePaintOrder: card.style.outlinePaintOrder, pixelSnapScale: pixelSnapScale)
    }

    static func rgb(_ value: CGColor?) -> [Double]? {
        guard let components = value?.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!,
            intent: .defaultIntent, options: nil)?.components, components.count >= 3 else { return nil }
        return components.prefix(3).map { Double($0) * 255 }
    }

    static func pageRect(_ normalized: [CGFloat], frame: CGRect) -> CGRect? {
        guard normalized.count == 4, normalized.allSatisfy(\.isFinite), normalized[2] > 0, normalized[3] > 0 else { return nil }
        return CGRect(x: frame.minX + normalized[0] * frame.width, y: frame.minY + normalized[1] * frame.height,
                      width: normalized[2] * frame.width, height: normalized[3] * frame.height)
    }

    private static func glyphsInsideRestoration(card: Card, restoration: NativeTranslationRestoration.Result) -> Bool {
        guard cardContentFits(card), !card.typography.rangeBounds.isEmpty,
              let patch = restoration.patches.last(where: { $0.itemID == card.item.id && !$0.independentArtworkCover }),
              let safe = patch.layoutSafe, patch.rect.width > 0, patch.rect.height > 0,
              safe.count == patch.image.width * patch.image.height else { return false }
        let sx = CGFloat(patch.image.width) / patch.rect.width, sy = CGFloat(patch.image.height) / patch.rect.height
        for r in cardPageRangeRects(card) {
            let left = Int(floor((r.minX - patch.rect.minX) * sx)), top = Int(floor((r.minY - patch.rect.minY) * sy))
            let right = Int(ceil((r.maxX - patch.rect.minX) * sx)), bottom = Int(ceil((r.maxY - patch.rect.minY) * sy))
            guard left >= 0, top >= 0, right <= patch.image.width, bottom <= patch.image.height else { return false }
            if top < bottom && left < right { for y in top..<bottom { for x in left..<right {
                if safe[y * patch.image.width + x] == 0 { return false }
            } } }
        }
        return true
    }

    static func initialSourceBackgroundKind(item: NativeTranslationLayoutItem,
        appearance: NativeTranslationRestoration.Appearance?, settings: IPhoneOverlaySettings, restoredCanvasAttached: Bool? = nil) -> String {
        if restoredCanvasAttached ?? (appearance?.restored == true) { return "restored" }
        let sample = appearance?.sourceSample ?? [:]
        let sampledSurface = settings.preserveSourceBackgroundColor ? sample["surface"] as? [String:Any]:nil
        let confidence = sample["confidence"] as? [String:Any] ?? [:]
        let candidate = NativeSourceColorSampler.rgb(sampledSurface?["color"]) ??
            (((confidence["background"] as? NSNumber)?.doubleValue ?? 0) >= 0.5 && settings.preserveSourceBackgroundColor
                ? NativeSourceColorSampler.rgb(sample["background"]):nil)
        if settings.preserveSourceBackgroundColor && item.sourceColorEligible {
            return candidate == nil ? "unresolved-transparent":"original"
        }
        if candidate != nil { return sampledSurface != nil ? "observed-surface":"preserved" }
        return "fallback"
    }

    static func prepareSourcePanels(cards: inout [Card], restoration: NativeTranslationRestoration.Result,
                                            layout: NativeTranslationLayout, settings: IPhoneOverlaySettings,
                                            growthSession: NativeTypographyPostPolish.RendererGrowthSession? = nil) {
        let frame = restoration.cleanupGeometry?.frame ?? layout.sourceRect
        guard settings.preserveSourceBackgroundColor, settings.renderedBackgroundOpacity > 0 else { return }
        for index in cards.indices {
            let item = cards[index].item
            guard item.sourceColorEligible else { continue }
            let sample = restoration.appearances[item.id]?.sourceSample ?? [:]
            let palette = NativeTranslationSourceStylePostPolish.captionPalette(sample: sample,
                ink: rgb(cards[index].style.foreground), preserveText: settings.preserveSourceTextColor,
                displayInk: NativeSourceColorSampler.displayedInk(sample))
            cards[index].style.foreground = color(palette.foreground.map { CGFloat($0) })
            // The frozen caption-palette producer skips rotated nodes. Their
            // later release inherits the earlier producer's explicit order.
            if item.rotation == 0 { cards[index].style.outlinePaintOrder = .fillThenStroke }
            cards[index].typography = remeasureTypography(cards[index])
            if item.rotation == 0, let adjusted = growthSession?.restoreReadableInk(item: cards[index].item,
                typography: cards[index].typography, foreground: palette.foreground) {
                cards[index].inkBeforeSurface = adjusted == palette.foreground ? nil : palette.foreground
                cards[index].style.foreground = color(adjusted.map { CGFloat($0) })
                cards[index].typography = remeasureTypography(cards[index])
            }
            guard let ink = cardWholeRangeRect(cards[index]), ink.width > 0, ink.height > 0 else { continue }
            let prior = growthSession?.rememberedInk(id: item.id)
            cards[index].sourcePanelTextFit = growthSession?.sourcePanelTextFit(id: item.id)
            let proposedPlate = NativeTranslationSourceStylePostPolish.fallbackPanel(currentInk: ink, priorInk: prior?.frame, priorPadding: Double(prior?.pad ?? 0),
                font: Double(cards[index].finalFontSize),frame: frame,sources: ([item.sourceBounds]+item.auxiliaryInkRects).compactMap { pageRect($0,frame: frame) },
                background: palette.background,restoredPanelProof: false,insideTextFit: false)
            let candidate = restoration.patches.last(where: { $0.itemID == item.id && !$0.independentArtworkCover })?.candidate
            let proof = settings.usesSourceInpainting && (candidate?.erasureComplete ?? restoration.appearances[item.id]?.erasureComplete ?? false) &&
                candidate.map { c in proposedPlate.map { marginProof(card: cards[index],candidate: c,plate: $0.rect) } ?? false } == true
            if item.rotation != 0 {
                if proof && glyphsInsideRestoration(card: cards[index], restoration: restoration) { continue }
                // The failed slanted repair retains its own opaque quad; detached below all translated lettering.
                cards[index].sourcePanels = [.init(rect: item.rect, background: palette.background, radius: 6, coverage: [item.rect])]
                cards[index].rotatesSourcePanels = true
                cards[index].sourceBackgroundKind = "rotated-panel"
                if settings.renderedBackgroundOpacity == 1 {
                    cards[index].style.foreground = color(NativeTranslationSourceStylePostPolish.adjustInkForContrast(
                        palette.foreground, contrast: { NativeTranslationSourceStylePostPolish.sourceColorContrast($0, panel: palette.background) })
                        .map { CGFloat($0) })
                    cards[index].typography = NativeTranslationTypography.layout(text: item.typesettingText ?? item.text,
                        in: item.contentRect.size, style: cards[index].style)
                }
                continue
            }
            let sources = ([item.sourceBounds] + item.auxiliaryInkRects).compactMap { pageRect($0, frame: frame) }
            let restoredMembership = settings.usesSourceInpainting && growthSession?.context.restored(item.id) == true
            let insideFit = cards[index].sourcePanelTextFit == "inside"
            if let panel = NativeTranslationSourceStylePostPolish.fallbackPanel(currentInk: ink, priorInk: prior?.frame, priorPadding: Double(prior?.pad ?? 0),
                font: Double(cards[index].finalFontSize), frame: frame, sources: sources,
                background: palette.background, restoredPanelProof: restoredMembership,
                insideTextFit: insideFit) {
                var panel = panel
                let assignedRect = panel.rect; panel.authoredRect = assignedRect; panel.rect = usedRect(assignedRect)
                if panel.coverage == [assignedRect] { panel.coverage = [panel.rect] }
                cards[index].sourcePanels = [panel]
                cards[index].sourceBackgroundKind = "readability-panel"
            } else if restoredMembership && insideFit { cards[index].sourceBackgroundKind = "inpainted" }
        }
    }

    static func applySourcePosition(cards: inout [Card], restoration: NativeTranslationRestoration.Result,
                                            layout: NativeTranslationLayout, settings: IPhoneOverlaySettings, ids: Set<String>? = nil) {
        guard settings.renderedBackgroundOpacity == 1, settings.preserveSourceTextColor else { return }
        let snapshot = cards
        let candidates = Dictionary(restoration.patches.compactMap { patch -> (String, NativeRestorationCandidate)? in
            guard let id = patch.itemID, let candidate = patch.candidate else { return nil }; return (id,candidate)
        }, uniquingKeysWith: { _,last in last })
        let sources = layout.items.flatMap { item in
            ([item.sourceBounds] + item.auxiliaryInkRects).compactMap { normalized -> (id: String, rect: CGRect)? in
                pageRect(normalized, frame: layout.sourceRect).map { (item.id,$0) }
            }
        }
        for index in cards.indices {
            let card = snapshot[index], item = card.item
            guard ids == nil || ids!.contains(item.id), let candidate = candidates[item.id], let foreground = rgb(card.style.foreground),
                  let oldPlate = card.sourcePanels.last(where: { !$0.sourceErasure })?.rect else { continue }
            let sample = restoration.appearances[item.id]?.sourceSample ?? [:]
            guard let outline = NativeRendererSourcePosition.decide(item: item, ink: cardInkRect(card),
                font: Double(card.finalFontSize), foreground: foreground, sampledStroke: sample["stroke"] as? [Double],
                oldPlate: oldPlate, candidate: candidate, otherCandidates: candidates, otherSources: sources,
                neighbors: snapshot.filter { $0.item.id != item.id }.map(cardInkRect),
                contentFits: card.typography.size.width <= item.contentRect.width + 1 && card.typography.size.height <= item.contentRect.height + 1) else { continue }
            cards[index].style.foreground = color(outline.foreground.map { CGFloat($0) })
            cards[index].style.outline = color(outline.stroke.map { CGFloat($0) }); cards[index].style.outlineWidth = CGFloat(outline.width)
            cards[index].style.outlinePaintOrder = .strokeThenFill
            cards[index].sourcePanels = []; cards[index].backings = []; cards[index].strokePreserved = false
            cards[index].partialSourcePositionProof = true; candidate.partialErasureCertified = true
            cards[index].sourceBackgroundKind = "inpainted"; cards[index].sourceStrokeKind = "readability-outline"
            cards[index].typography = remeasureTypography(cards[index])
        }
    }

    static func releaseCertifiedPlates(cards: inout [Card], restoration: NativeTranslationRestoration.Result,
                                               gloss: NativeTranslationEffectGloss.Refinement, layout: NativeTranslationLayout,
                                               settings: IPhoneOverlaySettings) {
        guard settings.usesSourceInpainting, settings.renderedBackgroundOpacity == 1 else { return }
        for index in cards.indices {
            refreshCaptionOwnerGraph(cards: &cards)
            let card = cards[index], item = card.item
            guard !item.vertical, !gloss.hiddenIDs.contains(item.id), !gloss.removedLayerIDs.contains(item.id),
                  let patch = restoration.patches.last(where: { $0.itemID == item.id && !$0.independentArtworkCover }),
                  let appearance = restoration.appearances[item.id] else { continue }
            let candidate = patch.candidate
            guard candidate?.erasureComplete ?? appearance.erasureComplete else { continue }
            let glyphVerified = candidate?.sourceGlyphsVerified ?? appearance.sourceGlyphsVerified
            let erasureVerified = candidate?.sourceErasureVerified ?? patch.finalForcedErasure
            guard glyphVerified || erasureVerified, !(candidate?.provisional ?? appearance.provisional),
                  candidate?.partialErasureCertified != true || erasureVerified else { continue }
            guard !card.sourcePanels.contains(where: { $0.hasForeignChildren }),
                  card.glyphCoverOwnerPanel?.hasForeignChildren != true else { continue }
            let sample = appearance.sourceSample ?? [:]
            cards[index].outlineGlow = 0; cards[index].style.outlineGlow = 0
            if item.rotation != 0 {
                guard card.rotatesSourcePanels || !card.backings.isEmpty else { continue }
                cards[index].sourcePanels = []; cards[index].backings = []; cards[index].drawsPanel = false
                if let stroke = sample["background"] as? [Double], stroke.count == 3, stroke.allSatisfy(\.isFinite) {
                    cards[index].style.outline = color(stroke.map { CGFloat($0) })
                    cards[index].style.outlineWidth = max(0.5,min(1.5,card.finalFontSize*0.045))
                }
                // The rotated release changes only the stroke shorthand; it
                // inherits the earlier producer's normal or stroke-first order.
                cards[index].glyphPlateReleased = true
            } else {
                guard item.sourceFrame.count == 4, item.sourceFrame.allSatisfy(\.isFinite) else { continue }
                let sourceFrame = CGRect(x: item.sourceFrame[0], y: item.sourceFrame[1], width: item.sourceFrame[2], height: item.sourceFrame[3])
                let currentInk = appearance.restorationMethod == "chromatic-balloon-glyphs"
                    ? (sample["foreground"] as? [Double]) ?? rgb(card.style.foreground) : rgb(card.style.foreground)
                guard let currentInk, let released = NativeTranslationSourceStylePostPolish.releasedCaptionStyle(sample: sample,
                    ring: card.outlinedRecord ?? card.outlineEvidence?.ringData, currentInk: currentInk,
                    font: Double(card.finalFontSize), preserveText: settings.preserveSourceTextColor,
                    chromaticGlyphs: appearance.restorationMethod == "chromatic-balloon-glyphs" && glyphVerified) else { continue }
                if item.balloonInterior?.contourVerified != true, item.sourceVertical,
                   let column = item.columnLayout, column.balancedColumn == true {
                    var placed = item, style = card.style
                    placed.x = column.x; placed.y = column.y; placed.width = column.width; placed.height = column.height
                    cards[index].sourceColumnAuthoredTop = column.y
                    placed.paddingTop = 2; placed.paddingLeft = 2; placed.paddingBottom = 2; placed.paddingRight = 2
                    placed.typesettingText = nil; placed.typesettingQuoteMode = nil; placed.typesettingBlockDisplay = nil; placed.typesettingPreformattedRows = nil; placed.typesettingPreservedBlockWrapper = nil; placed.typesettingWidthScale = nil; placed.rotation = 0
                    style.fontSize = column.fontSize; style.lineHeight = column.lineHeight; style.tracking = -column.fontSize*0.012
                    style.alignsToTop = true; style.horizontalScale = 1; style.outline = nil; style.outlineWidth = 0
                    // Releasing this CSS column explicitly restores normal word breaking.
                    style.horizontalWrapping = .normal; style.keepsWholeWords = false
                    style.horizontalWhitespace = .normal
                    style.usesBlockWordLayout = false; style.usesPreformattedBlockRows = false; style.blockWordLayoutUsesTopPadding = false
                    placed = usedLayoutItem(placed)
                    let maxHeight = min(column.height,sourceFrame.maxY-column.y)
                    var measured = NativeTranslationTypography.layout(text: item.text,in: placed.contentRect.size,style: style)
                    func blockHeight() -> CGFloat? {
                        var probe = placed
                        probe.fontSize = style.fontSize; probe.lineHeight = style.lineHeight
                        return NativeTypographyPostPolish.blockAutoHeight(item: probe, typography: measured)
                    }
                    guard var height = blockHeight() else { continue }
                    while height > maxHeight && style.fontSize > 5 {
                        style.fontSize = max(5,style.fontSize-0.25); style.lineHeight = style.fontSize*1.2; style.tracking = -style.fontSize*0.012
                        measured = NativeTranslationTypography.layout(text: item.text,in: placed.contentRect.size,style: style)
                        guard let revised = blockHeight() else { break }
                        height = revised
                    }
                    placed.height = max(4,height)
                    placed.fontSize = style.fontSize; placed.lineHeight = style.lineHeight
                    placed = usedLayoutItem(placed)
                    cards[index].item = placed; cards[index].style = style; cards[index].finalFontSize = style.fontSize; cards[index].textShift = .zero; cards[index].typographyWidth = nil; cards[index].lineOffsets = []
                }
                if appearance.restorationMethod == "narrow-paper-glyphs", item.sourceVertical, item.text.unicodeScalars.count <= 12 {
                    var placed = cards[index].item
                    placed.paddingLeft = 1; placed.paddingRight = 1
                    let measured = NativeTranslationTypography.layout(text: placed.typesettingText ?? placed.text,in: placed.contentRect.size,style: cards[index].style)
                    let lines = NativeTranslationTypography.captionLineMetrics(layout: measured).map(\.rect)
                    if !lines.isEmpty, lines.allSatisfy({ $0.width <= item.sourceBounds[2]*sourceFrame.width+0.25 }),
                       (lines.map(\.maxY).max()! - lines.map(\.minY).min()!) <= item.sourceBounds[3]*sourceFrame.height {
                        cards[index].item = placed
                    }
                }
                cards[index].style.foreground = color(released.foreground.map { CGFloat($0) })
                cards[index].style.outline = released.stroke.map { color($0.map { CGFloat($0) }) }
                // Source-outline width uses the final (possibly column-recovered) font.
                let finalRelease = NativeTranslationSourceStylePostPolish.releasedCaptionStyle(sample: sample,
                    ring: card.outlinedRecord ?? card.outlineEvidence?.ringData, currentInk: currentInk,
                    font: Double(cards[index].finalFontSize),preserveText: settings.preserveSourceTextColor,
                    chromaticGlyphs: appearance.restorationMethod == "chromatic-balloon-glyphs" && glyphVerified)
                cards[index].style.outlineWidth = CGFloat(finalRelease?.width ?? released.width)
                cards[index].style.outlinePaintOrder = cards[index].style.outlineWidth > 0 ? .strokeThenFill : .fillThenStroke
                // Releasing the plate replaces the complete CSS stroke, including
                // the earlier fill-coloured weight enhancement when no ring remains.
                cards[index].heavyStrokeWidth = 0
                cards[index].strokePreserved = released.preserved && released.stroke != nil
                cards[index].sourcePanels = []; cards[index].backings = []; cards[index].drawsPanel = false; cards[index].glyphCoverOwnerPanel = nil; cards[index].captionParentPlate = false; cards[index].glyphPlateReleased = true; cards[index].textZ = 3
                appendTextToRoot(cards: &cards, index: index)
            }
            cards[index].sourceBackgroundKind = "inpainted"
            cards[index].sourceStrokeKind = cards[index].strokePreserved ? "preserved":(cards[index].style.outline == nil ? "none":"readability")
            cards[index].glyphCoverOwnerPanel = nil; cards[index].captionParentPlate = false; cards[index].captionParentOwner = nil
            cards[index].typography = remeasureTypography(cards[index])
        }
    }

    private static func containBalloonText(cards: inout [Card], gloss: NativeTranslationEffectGloss.Refinement,
                                           layout: NativeTranslationLayout) {
        let snapshot = cards
        var input = cards.map { card -> NativeBalloonTextContainment.Entry in
            let item = card.item
            var geometry = NativeTranslationFinalGeometry.Entry(id: item.id, frame: layout.sourceRect,
                source: pageRect(item.sourceBounds, frame: layout.sourceRect) ?? .zero,
                lines: cardPageLineRects(card),
                font: Double(card.finalFontSize), pitch: Double(card.style.lineHeight), stroke: Double(card.style.outlineWidth), plate: nil)
            geometry.originalRotation = Double(item.rotation); geometry.vertical = item.vertical
            geometry.keepsSource = card.preservedGloss || card.preservedErasure
            geometry.visible = !gloss.hiddenIDs.contains(item.id) && !gloss.removedLayerIDs.contains(item.id)
            let balloon = item.balloonInterior ?? item.balloonUnit?.interior
            var entry = NativeBalloonTextContainment.Entry(geometry: geometry,
                balloonRect: balloon?.rect ?? [], spans: balloon?.spans ?? [], center: balloon?.center)
            entry.contourVerified = balloon?.contourVerified == true
            entry.horizontalTransform = item.rotation == 0 && card.style.horizontalScale == 1
            entry.horizontalWriting = !item.vertical
            entry.parentBox = card.captionParentPlate ? readabilityOwnerPanel(card)?.rect:nil
            entry.hasPlates = !card.sourcePanels.isEmpty || card.glyphCoverOwnerPanel != nil
            entry.covers = card.sourcePanels.flatMap { $0.coverage.isEmpty ? [$0.rect] : $0.coverage }
            return entry
        }
        for note in gloss.notes {
            guard let card = snapshot.first(where: { $0.item.id == note.id }), let move = note.placement.moves.first else { continue }
            let style = glossStyle(card: card, size: note.placement.size, lineHeight: note.placement.lineHeight,
                title: note.title, retained: note.retainedTypography)
            let measured = NativeTranslationTypography.layout(text: glossText(note.text,title: note.title),
                in: note.contentSize,style: style)
            var lines = NativeTranslationTypography.captionLineMetrics(layout: measured).map { $0.rect.offsetBy(dx: note.origin.x+move.x,dy: note.origin.y+move.y) }
            if let angle = note.placement.angle, let center = note.placement.center {
                lines = lines.map { rotatedBounds($0,about: CGRect(origin: center,size: .zero),angle: CGFloat(angle)) }
            }
            var geometry = NativeTranslationFinalGeometry.Entry(id: "gloss:"+note.id,frame: layout.sourceRect,source: .zero,
                lines: lines,font: note.placement.size,pitch: note.placement.lineHeight,stroke: note.strokeWidth,plate: nil)
            geometry.keepsSource = true
            input.append(.init(geometry: geometry,balloonRect: [],spans: [],center: nil))
        }
        func key(_ id: String,_ font: Double,_ pitch: Double) -> String { "\(id)|\(font.bitPattern)|\(pitch.bitPattern)" }
        var proposals: [String:(NativeTranslationTypography.Style,NativeTranslationTypography.Layout)] = [:]
        let result = NativeBalloonTextContainment.contain(input,itemCount: layout.items.count,reshape: { geometry,font,pitch in
            guard let card = snapshot.first(where: { $0.item.id == geometry.id }) else { return nil }
            var style = card.style
            style.fontSize = CGFloat(font); style.lineHeight = CGFloat(pitch); style.tracking = -CGFloat(font)*0.012
            let measured = NativeTranslationTypography.layout(text: card.item.typesettingText ?? card.item.text,
                in: card.item.contentRect.size,style: style)
            proposals[key(geometry.id,font,pitch)] = (style,measured)
            return NativeTranslationTypography.captionLineMetrics(layout: measured).map { $0.rect.offsetBy(dx: card.textOrigin.x,dy: card.textOrigin.y) }
        })
        for entry in result where entry.fit != nil {
            let geometry = entry.geometry
            guard let index = cards.firstIndex(where: { $0.item.id == geometry.id }),
                  let (style,measured) = proposals[key(geometry.id,geometry.font,geometry.pitch)] else { continue }
            cards[index].style = style; cards[index].typography = measured; cards[index].finalFontSize = style.fontSize
            cards[index].textShift.x += geometry.shift.x; cards[index].textShift.y += geometry.shift.y
            cards[index].authoredTextOrigin?.x += geometry.shift.x; cards[index].authoredTextOrigin?.y += geometry.shift.y
        }
    }

    static func trialGeometry(_ candidate: NativeRestorationCandidate) -> NativeFinalRestorationTrial.Geometry {
        .init(imageSize: candidate.imageSize, frame: candidate.frame, cropOrigin: candidate.descriptor.crop.origin,
            scale: CGSize(width: candidate.descriptor.sx, height: candidate.descriptor.sy),
            sourceBounds: candidate.sourceBounds, auxiliaryInkRects: candidate.auxiliaryInkRects, sourceFontSize: candidate.sourceFontSize)
    }

    static func marginProof(card: Card, candidate: NativeRestorationCandidate, plate: CGRect) -> Bool {
        let item = card.item, pad = max(3, min(6, Double(card.finalFontSize) * 0.3))
        let cross = max(pad, min(16, item.sourceFontSize.map { Double($0) } ?? pad))
        let padding = CGSize(width: item.sourceVertical ? cross : pad, height: item.sourceVertical ? pad : cross)
        guard let coverage = NativeFinalRestorationTrial.marginCoverage(geometry: trialGeometry(candidate),
            sourceFrame: candidate.frame, oldPlate: plate, padding: padding, displayedFontSize: Double(card.finalFontSize)) else { return false }
        return NativeFinalRestorationTrial.certifiesEarlyMargin(surface: candidate.surface, coverage: coverage,
            sourceVertical: item.sourceVertical, sourceSingleColumn: item.sourceSingleColumn,
            restorationMethod: candidate.method, sourceGlyphsVerified: candidate.sourceGlyphsVerified,
            sourceErasureVerified: candidate.sourceErasureVerified)
    }

    static func extendWidenedDisplayClip(cards: inout [Card]) {
        for index in cards.indices where cards[index].displayCardGrowth && cards[index].captionParentPlate {
            let card = cards[index]
            guard var panel = readabilityOwnerPanel(card), panel.clipped, !panel.coverage.isEmpty else { continue }
            let ink = cardInkRect(card), margin = max(2,card.style.fontSize*0.12)
            guard valid(ink) else { continue }
            let spans = [(ink.minX-margin,panel.rect.minX),(panel.rect.maxX,ink.maxX+margin)]
            let extra = spans.compactMap { left,right -> CGRect? in
                right-left > 0.5 ? CGRect(x: left,y: ink.minY-margin,width: right-left,height: ink.height+margin*2):nil
            }
            guard !extra.isEmpty else { continue }
            guard let existing = panel.coverageClip, existing.inset == nil,
                  let appended = NativeCSSCoveragePath.declaration(coverage: extra, origin: panel.rect.origin, commands: .absolute) else { continue }
            // The frozen writer appends to the SVG string, without rewriting
            // its panelCoverage dataset or coercing an inset to a path.
            panel.coverageClip = .init(subpaths: existing.subpaths + appended.subpaths)
            if let owner = cards[index].sourcePanels.lastIndex(where: { !$0.sourceErasure }) { cards[index].sourcePanels[owner] = panel }
            else { cards[index].glyphCoverOwnerPanel = panel }
        }
    }

    static func applyLightLettering(cards: inout [Card], layout: NativeTranslationLayout,
                                             restoration: NativeTranslationRestoration.Result,
                                             settings: IPhoneOverlaySettings, source: CGImage?) {
        guard settings.preserveSourceTextColor, settings.preserveSourceBackgroundColor,
              settings.renderedBackgroundOpacity == 1, source != nil, layout.items.count <= 256 else { return }
        let frame = restoration.cleanupGeometry?.frame ?? layout.sourceRect
        var remaining = 49_152
        for index in cards.indices {
            let card = cards[index], item = card.item, owner = card.sourcePanels.last(where: { !$0.sourceErasure })
            let mode = card.rotatesSourcePanels ? "rotated-panel" : card.sourcePanels.isEmpty ? "inpainted" : "readability-panel"
            let ring = card.outlinedRecord ?? [:]
            var result = NativeLightLettering.saturated(mode: mode,font: Double(card.finalFontSize),
                strokeWidth: Double(card.style.outlineWidth),ring: ring,currentPlate: owner?.background)
            if result == nil, item.sourceColorEligible, mode == "readability-panel", let owner, let source,
               let ink = rgb(card.style.foreground), !card.glyphPlateReleased, card.glyphCoverRecord == nil {
                let others = cards.indices.filter { $0 != index }
                guard card.backings.isEmpty,
                      !others.contains(where: { other in cards[other].foreignFills.contains { $0.color == owner.background } })
                else { cards[index].lightLetteringReject = "owner"; continue }
                if owner.sourceFrameImage != nil || !card.foreignFills.isEmpty { continue } // CSS background image blocks only this pixel-analysis branch.
                guard NativeLightLettering.darkInkEligible(ink,plate: owner.background,font: Double(card.finalFontSize))
                else { cards[index].lightLetteringReject = "ink"; continue }
                let sample = restoration.appearances[item.id]?.sourceSample ?? [:]
                guard NativeLightLettering.hasLightEvidence(sample: sample,ring: ring)
                else { cards[index].lightLetteringReject = "gate"; continue }
                let prepared = NativeLightLettering.crop(bounds: item.sourceBounds.map { Double($0) },frame: frame,
                    imageSize: CGSize(width: source.width,height: source.height),sourceFont: item.sourceFontSize.map { Double($0) },
                    plate: owner.rect,remainingPixels: &remaining)
                guard let crop = prepared.crop else { cards[index].lightLetteringReject = prepared.rejection; continue }
                guard let rgba = try? NativeSourcePixelReader.draw(image: source,x: Double(crop.source.minX),y: Double(crop.source.minY),
                    sourceWidth: Double(crop.source.width),sourceHeight: Double(crop.source.height),width: crop.width,height: crop.height) else { continue }
                let analyzed = NativeLightLettering.analyze(rgba: rgba,crop: crop,font: Double(card.finalFontSize),ink: ink,
                    plate: owner.background,neighborOverlapsPlate: others.contains { panelMeetsInk(owner,owner: card,ink: cardInkRect(cards[$0])) })
                result = analyzed.style; cards[index].lightLetteringReject = analyzed.rejection
                if !analyzed.record.isEmpty { cards[index].lightLetteringRecord = analyzed.record }
            }
            guard let result else { continue }
            cards[index].style.foreground = color(result.fill.map { CGFloat($0) })
            cards[index].style.outline = result.stroke.map { color($0.map { CGFloat($0) }) }; cards[index].style.outlineWidth = CGFloat(result.strokeWidth)
            cards[index].style.outlinePaintOrder = result.stroke == nil ? .fillThenStroke : .strokeThenFill
            if let glow = result.glowRadius { cards[index].outlineGlow = CGFloat(glow); cards[index].style.outlineGlow = CGFloat(glow) }; cards[index].lightLetteringRecord = result.record
            cards[index].strokePreserved = result.stroke != nil
            if let background = result.background, let panel = cards[index].sourcePanels.lastIndex(where: { !$0.sourceErasure }) {
                cards[index].sourcePanels[panel].background = background
            }
            cards[index].typography = remeasureTypography(cards[index])
        }
    }

    private static func prepareFinalTrials(cards: inout [Card], restoration: inout NativeTranslationRestoration.Result,
                                           gloss: NativeTranslationEffectGloss.Refinement, layout: NativeTranslationLayout,
                                           settings: IPhoneOverlaySettings, source: CGImage?, balloonStage: Bool) {
        guard settings.usesSourceInpainting, settings.renderedBackgroundOpacity == 1 else { return }
        let budget = NativeFinalRestorationTrial.BalloonBudget()
        var safeFitBudget = 65_536
        let sourceFrame = restoration.cleanupGeometry?.frame ?? layout.sourceRect
        let allSources = layout.items.flatMap { item in
            ([item.sourceBounds] + item.auxiliaryInkRects).compactMap { pageRect($0, frame: sourceFrame).map { (item.id,$0) } }
        }
        let trialIndices = balloonStage ? cards.indices.sorted { left,right in
            let a = readabilityOwnerPanel(cards[left])?.rect, b = readabilityOwnerPanel(cards[right])?.rect
            let areaA = a.map { $0.width * $0.height } ?? 0, areaB = b.map { $0.width * $0.height } ?? 0
            return areaA != areaB ? areaA > areaB : left < right
        } : Array(cards.indices)
        for index in trialIndices {
            let card = cards[index], item = card.item
            guard !gloss.hiddenIDs.contains(item.id), !gloss.removedLayerIDs.contains(item.id),
                  let plate = readabilityOwnerPanel(card)?.rect,
                  let candidate = restoration.patches.last(where: { $0.itemID == item.id && !$0.independentArtworkCover })?.candidate else { continue }
            if balloonStage {
            var input = NativeFinalRestorationTrial.BalloonInput(geometry: trialGeometry(candidate), plate: plate)
            input.erasureComplete = candidate.erasureComplete; input.partialErasureCertified = candidate.partialErasureCertified
            input.provisional = candidate.provisional; input.localProposalDetached = candidate.provisional
            input.sourceErasureRestored = card.sourceRestorationMetadata["sourceErasureRestored"] == "true"
            let residualKey = ([String(candidate.revision)] + [plate.minX,plate.minY,plate.width,plate.height].map { String(Int(floor($0 + 0.5))) }).joined(separator: ",")
            input.residualRefusedOnCurrentSurfaceAndPlate = card.sourceRestorationMetadata["residualRefused"] == residualKey
            input.rotation = Double(item.rotation); input.balancedColumn = item.balancedColumn
            input.nodeScaled = card.style.horizontalScale != 1; input.parentIsRoot = !card.captionParentPlate; input.parentIsPlate = card.captionParentPlate
            var accepted: Card?
            let currentLayout = NativeTranslationLayout(imageSize: layout.imageSize, sourceRect: layout.sourceRect,
                viewport: layout.viewport, items: layout.items.map { value in cards.first(where: { $0.item.id == value.id })?.item ?? value },
                readableRecoveryRemaining: layout.readableRecoveryRemaining, sourceObjectFit: layout.sourceObjectFit)
            let trialRestoration = restoration
            let obstacles = cards.filter { $0.item.id != item.id && !gloss.hiddenIDs.contains($0.item.id) }.flatMap { other in
                [cardInkRect(other)] + other.sourcePanels.map(\.rect) + other.backings.map(\.frame)
            }
            let callbacks = NativeFinalRestorationTrial.BalloonCallbacks(
                restorationFitEligible: { candidate.restorationFitEligible(item: item,fontSize: Double(card.finalFontSize),inner: true,alreadyRestored: card.glyphPlateReleased) },
                completeResidualErasure: {
                    guard let source else { return nil }
                    let sample = trialRestoration.appearances[item.id]?.sourceSample ?? [:]
                    return candidate.completeResidualErasure(item: item,fontSize: Double(card.finalFontSize),plate: plate,
                        sourceImage: source,otherSourceRects: allSources.filter { $0.0 != item.id }.map { $0.1 },
                        sampledForeground: sample["foreground"] as? [Double],sampledBackground: sample["background"] as? [Double])
                }, sourceResidualFilled: { Double(candidate.sourceResidualFilled ?? 0) },
                fitBalloon: {
                    guard let proposed = NativeTypographyPostPolish.finalRestorationFit(itemID: item.id,
                        currentLayout: currentLayout, restoration: trialRestoration, settings: settings, sourceImage: source,
                        plateRect: plate, obstacles: obstacles, foreground: card.style.foreground,
                        safeFitBudget: &safeFitBudget) else { return false }
                    var next = card, style = card.style
                    style.fontSize = proposed.fontSize; style.lineHeight = proposed.lineHeight; style.tracking = -proposed.fontSize * 0.012
                    style.horizontalScale = proposed.typesettingWidthScale ?? 1
                    style.alignsToTop = proposed.balancedColumn
                    style.foreground = proposed.typesettingForeground.map { color($0.map { CGFloat($0) }) } ?? style.foreground
                    style.outline = proposed.typesettingOutlineRGB.map { color($0.map { CGFloat($0) }) } ?? style.outline
                    style.outlineWidth = proposed.typesettingOutlineWidth ?? style.outlineWidth
                    if proposed.typesettingOutlineRGB != nil, proposed.typesettingOutlineRGB != card.item.typesettingOutlineRGB ||
                        proposed.typesettingOutlineWidth != card.item.typesettingOutlineWidth { style.outlinePaintOrder = .strokeThenFill }
                    next.item = proposed; next.style = style; next.finalFontSize = style.fontSize; next.textShift = .zero
                    next.typography = NativeTranslationTypography.layout(text: proposed.typesettingText ?? proposed.text, in: proposed.contentRect.size, style: style)
                    accepted = next; return true
                }, liftNodeFromPlate: {}, restoreNodeToPlate: {}, attachProposal: {}, detachProposal: {},
                commitRestorationFit: { _,committed in if committed { candidate.provisional = false } })
            let outcome = NativeFinalRestorationTrial.balloonSafeFit(candidate: candidate, input: input, budget: budget, callbacks: callbacks)
            if outcome.accepted, var next = accepted {
                next.sourcePanels = []; next.backings = []; next.glyphCoverOwnerPanel = nil; next.captionParentPlate = false; next.drawsPanel = false; next.sourceBackgroundKind = "inpainted"; next.glyphPlateReleased = true; next.restoredSurfaceFontFit = true; cards[index] = next
                if card.captionParentPlate { appendTextToRoot(cards: &cards, index: index) }
                continue
            }
                continue
            }
            var short = NativeFinalRestorationTrial.ShortCaptionInput(geometry: trialGeometry(candidate), plate: plate)
            short.erasureComplete = candidate.erasureComplete; short.provisional = candidate.provisional
            short.partialErasureCertified = candidate.partialErasureCertified; short.rotation = Double(item.rotation)
            short.sourceSingleColumn = item.sourceSingleColumn; short.text = item.text
            short.sourceRemainingInk = candidate.sourceRemainingInk.map { Double($0) }; short.plateCount = card.sourcePanels.count + (card.glyphCoverOwnerPanel == nil ? 0 : 1)
            short.parentIsRoot = !card.captionParentPlate; short.parentIsPlate = card.captionParentPlate
            short.fontSize = Double(card.finalFontSize); short.otherSourceRects = allSources.filter { $0.0 != item.id }.map { $0.1 }
            let release = NativeFinalRestorationTrial.shortCaption(candidate: candidate, input: short)
            if release.accepted {
                cards[index].sourcePanels = []; cards[index].backings = []; cards[index].glyphCoverOwnerPanel = nil; cards[index].captionParentPlate = false; cards[index].sourceBackgroundKind = "inpainted"; cards[index].sourceStrokeKind = "readability"; cards[index].glyphPlateReleased = true; cards[index].drawsPanel = false; cards[index].textZ = 3
                cards[index].style.foreground = color(NativeFinalRestorationTrial.ShortCaptionOutcome.foreground.map { CGFloat($0) })
                cards[index].style.outline = color(NativeFinalRestorationTrial.ShortCaptionOutcome.stroke.map { CGFloat($0) })
                cards[index].style.outlineWidth = CGFloat(release.strokeWidth ?? 0); cards[index].strokePreserved = false
                cards[index].style.outlinePaintOrder = .strokeThenFill
                cards[index].typography = NativeTranslationTypography.layout(text: item.typesettingText ?? item.text,
                    in: item.contentRect.size, style: cards[index].style)
                if card.captionParentPlate { appendTextToRoot(cards: &cards, index: index) }
            }
        }
    }

    static func panelMeetsInk(_ panel: NativeTranslationSourceStylePostPolish.Panel, owner: Card, ink: CGRect) -> Bool {
        let angle = owner.rotatesSourcePanels ? Double(owner.item.rotation) : 0
        let bounds = angle == 0 ? panel.rect : rotatedBounds(panel.rect, about: owner.sourcePlateRect, angle: owner.item.rotation)
        let matrix: [Double]? = angle == 0 ? nil : [cos(angle),sin(angle),-sin(angle),cos(angle),0,0]
        return NativeTranslationFinalRenderingHelpers.plateMeets(bounds: bounds, width: Double(panel.rect.width),
            height: Double(panel.rect.height), matrix: matrix,
            ink: [Double(ink.minX),Double(ink.minY),Double(ink.maxX),Double(ink.maxY)])
    }

    static func applySourceStyles(to cards: inout [Card], restoration: NativeTranslationRestoration.Result,
                                          settings: IPhoneOverlaySettings, stage: NativeTranslationSourceStylePostPolish.Stage, itemCount: Int) {
        guard settings.preserveSourceTextColor, itemCount <= 256 else { return }
        let records = cards.map { card -> NativeTranslationSourceStylePostPolish.Display in
            let item = card.item, appearance = restoration.appearances[item.id]
            let sample = appearance?.sourceSample ?? [:]
            let foreground = rgb(card.style.foreground) ?? [17, 18, 23]
            let palette = NativeTranslationSourceStylePostPolish.captionPalette(sample: sample, ink: foreground,
                preserveText: true, displayInk: NativeSourceColorSampler.displayedInk(sample))
            let evidence = cardSurfaceEvidence(card,restoration: restoration)
            var display = NativeTranslationSourceStylePostPolish.Display(id: item.id, eligible: item.sourceColorEligible, sourceTextOnly: item.sourceTextOnly,
                rotation: Double(item.rotation), script: item.fontScript, vertical: item.sourceVertical,
                fontName: card.style.fontName ?? "system", fontWeight: item.vertical ? "800" : "700",
                glyph: item.sourceFontSize.map { Double($0) } ?? .nan, font: Double(card.finalFontSize),
                sample: sample, foreground: foreground, stroke: rgb(card.style.outline),
                strokeWidth: Double(card.style.outlineWidth), textPreserved: appearance?.foreground != nil,
                strokePreserved: card.strokePreserved, darkMeasured: card.darkMeasured, captionBackground: palette.background,
                ownerBackground: card.captionParentPlate && card.glyphCoverOwnerPanel == nil ? readabilityOwnerPanel(card)?.background : nil, restored: card.sourceBackgroundKind == "inpainted",
                surfaceRange: evidence?.range,
                overlappingSurfaceLuminances: !card.captionParentPlate ? cards.flatMap { other in
                    let ink = cardInkRect(card)
                    return other.sourcePanels.filter { panelMeetsInk($0, owner: other, ink: ink) }
                        .map { NativeTranslationSourceStylePostPolish.luminance($0.background) }
                } : [], cluster: card.clusterRGB)
            display.partialSourcePositionProof = card.partialSourcePositionProof
            display.inkBeforeSurface = card.inkBeforeSurface; display.surfaceHistogram = evidence?.histogram
            return display
        }
        let resolved = NativeTranslationSourceStylePostPolish.resolve(records, preserveText: true,
            opacity: settings.renderedBackgroundOpacity, clusterStrokes: false, stage: stage)
        for (index, result) in resolved.enumerated() where index < cards.count {
            cards[index].style.foreground = color(result.foreground.map { CGFloat($0) })
            cards[index].style.outline = result.stroke.map { color($0.map { CGFloat($0) }) }
            cards[index].style.outlineWidth = CGFloat(result.strokeWidth)
            if result.replacesStroke { cards[index].style.outlinePaintOrder = .strokeThenFill }
            cards[index].strokePreserved = result.strokePreserved
            if result.stroke == nil { cards[index].sourceStrokeKind = "none" }
            else if result.strokePreserved { cards[index].sourceStrokeKind = "preserved" }
            cards[index].darkMeasured = result.darkMeasured; cards[index].clusterRGB = result.cluster
            if stage == .finalContrast, settings.renderedBackgroundOpacity == 1, !cards[index].captionParentPlate, cards[index].sourceBackgroundKind == "inpainted" { cards[index].textZ = 3 }
            // The final style pass changes glyph paint without fitting or changing accepted line breaks.
            cards[index].typography = remeasureTypography(cards[index])
        }
    }

    static func fitted(text: String, size: CGSize, style: inout NativeTranslationTypography.Style, item: NativeTranslationLayoutItem? = nil) -> NativeTranslationTypography.Layout {
        let maximum = style.fontSize
        let ratio = max(1, style.lineHeight / max(1, maximum))
        var result = NativeTranslationTypography.layout(text: text, in: size, style: style)
        func fits(_ measured: NativeTranslationTypography.Layout) -> Bool {
            guard var probe = item else { return measured.fits }
            probe.fontSize = style.fontSize; probe.lineHeight = style.lineHeight
            probe.typesettingWidthScale = style.horizontalScale
            return NativeTypographyPostPolish.contentFits(item: probe, typography: measured)
        }
        guard !fits(result), maximum > BrowserOverlayLayoutPlanner.minimumRenderedFontSize else { return result }
        func at(_ fontSize: CGFloat) -> NativeTranslationTypography.Layout {
            style.fontSize = fontSize
            style.lineHeight = fontSize * ratio
            style.tracking = -fontSize * 0.012
            return NativeTranslationTypography.layout(text: text, in: size, style: style)
        }
        var lower = BrowserOverlayLayoutPlanner.minimumRenderedFontSize
        var upper = maximum
        result = at(lower)
        guard fits(result) else { return result }
        for _ in 0..<9 {
            let candidate = (lower + upper) / 2
            if fits(at(candidate)) { lower = candidate } else { upper = candidate }
        }
        return at(floor(lower * 4) / 4)
    }

    static func draw(_ card: Card, context: CGContext, opacity: CGFloat, paintsBackground: Bool = true, paintsText: Bool = true, paintsSourcePanels: Bool = true, pixelSnapScale: CGFloat? = nil, canvasBacking: NativeCanvasBacking? = nil) {
        let item = card.item
        context.saveGState()
        defer { context.restoreGState() }
        func rotate(_ angle: CGFloat? = nil, about anchor: CGRect? = nil) {
            let anchor = anchor ?? card.sourcePlateRect
            context.translateBy(x: anchor.midX, y: anchor.midY)
            context.rotate(by: angle ?? item.rotation)
            context.translateBy(x: -anchor.midX, y: -anchor.midY)
        }
        if paintsSourcePanels, pixelSnapScale == nil, let patch = card.glyphCoverPatch {
            drawSourcePatch(patch, context: context)
        }
        for panel in paintsSourcePanels ? card.sourcePanels : [] {
            // Only live owners forward a fresh canonical bitmap capability.
            // Preserve the existing PDF painter and unsupported live contexts.
            if pixelSnapScale == nil, !card.rotatesSourcePanels {
                do {
                    if let composite = try NativeForeignBackgroundCompositor.compose(panel: panel,
                        foreign: card.foreignFills, context: context, backing: canvasBacking) {
                        try Task.checkCancellation()
                        context.saveGState()
                        context.interpolationQuality = .none
                        UIImage(cgImage: composite.image).draw(in: composite.frame, blendMode: .copy, alpha: 1)
                        context.restoreGState()
                        continue
                    }
                } catch is CancellationError { return }
                catch {
                    if Task.isCancelled { return }
                    /* Unsupported hardware/geometry keeps the existing live painter. */
                }
            }
            context.saveGState()
            if card.rotatesSourcePanels { rotate(); drawSlantedClip(card, context: context) }
            let paintFrame = pixelSnapScale.map { NativeTranslationPDFCapture.snappedRect(panel.rect, deviceScale: $0) } ?? panel.rect
            let outline = pixelSnapScale.map {
                NativeTranslationPDFCapture.roundedPath(panel.rect, radius: CGFloat(panel.radius), deviceScale: $0)
            } ?? CGPath(roundedRect: panel.rect, cornerWidth: CGFloat(panel.radius), cornerHeight: CGFloat(panel.radius), transform: nil)
            if pixelSnapScale != nil {
                if panel.overflowClip { context.clip(to: paintFrame) }
            } else { context.addPath(outline); context.clip() }
            // CSS clip-path pieces retain their local widths; only the
            // containing border box origin snaps for PDF painting.
            // Coverage also remains as dataset evidence after clip-path:none.
            // Only the current CSS clip declaration affects painting.
            if panel.clipped, panel.coverageClip != nil || !panel.coverage.isEmpty {
                applyCoverageClip(panel.coverageClip, coverage: panel.coverage, owner: panel.rect,
                    context: context, pixelSnapScale: pixelSnapScale, legacyOrigin: paintFrame.origin)
            }
            context.setFillColor(color(panel.background.map { CGFloat($0) }))
            if card.rotatesSourcePanels { context.setAlpha(pixelSnapScale == nil ? opacity : (opacity*255).rounded()/255) }
            if pixelSnapScale != nil {
                // WebKit paints the rounded border shape, rather than a
                // rectangle beneath a rounded clip: their AA differs.
                context.addPath(outline); context.fillPath()
                context.addPath(outline); context.clip()
            } else { context.fill(panel.rect) }
            // CSS background images paint from the last declaration to the
            // first; their local position/size survive later owner geometry.
            let foreignLayers = Array(card.foreignFills.reversed())
            let foreignDeviceScale: CGFloat? = {
                if let pixelSnapScale { return pixelSnapScale }
                let matrix = context.ctm
                guard matrix.a.isFinite, matrix.a > 0, matrix.b == 0, matrix.c == 0,
                      Float(matrix.a).isFinite, Float(abs(matrix.d)) == Float(matrix.a) else { return nil }
                return matrix.a
            }()
            for foreign in foreignLayers {
                if let deviceScale = foreignDeviceScale,
                   let position = foreign.backgroundPosition, let size = foreign.backgroundSize,
                   NativeForeignBackgroundGradient.draw(context: context, owner: panel.rect,
                       position: position, size: size, color: foreign.color.map { CGFloat($0) }, deviceScale: deviceScale) {
                    continue
                }
                // Unsupported pattern geometry retains the prior paint path.
                context.setFillColor(color(foreign.color.map { CGFloat($0) })); context.fill(foreign.rect)
            }
            if let sourceFrameImage = panel.sourceFrameImage { UIImage(cgImage: sourceFrameImage).draw(in: panel.rect) }
            context.restoreGState()
        }
        if paintsBackground, card.drawsPanel {
            context.saveGState()
            if item.rotation != 0, card.straightenedPanelRect == nil { rotate(); drawSlantedClip(card, context: context) }
            let frame = card.straightenedPanelRect ?? card.sourcePlateRect
            let radius: CGFloat = card.straightenedPanelRect == nil ? 6 : 0
            if let pixelSnapScale {
                context.addPath(NativeTranslationPDFCapture.roundedPath(frame, radius: radius, deviceScale: pixelSnapScale))
            } else { context.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)) }
            context.clip()
            if let pixelSnapScale, card.style.vertical, item.clipsText, !card.glyphPlateReleased {
                context.clip(to: NativeTranslationPDFCapture.snappedRect(frame,deviceScale: pixelSnapScale))
            }
            context.setAlpha(pixelSnapScale == nil ? opacity : (opacity*255).rounded()/255)
            context.setFillColor(card.background)
            context.fill(pixelSnapScale.map { NativeTranslationPDFCapture.snappedRect(frame, deviceScale: $0) } ?? frame)
            // PDF preserves the browser's vector-versus-tiled gradient branch; bitmap presentation keeps alpha.
            if card.usesFallbackVeil {
                if let pixelSnapScale {
                    context.setAlpha(1)
                    NativeTranslationPDFCapture.drawFallbackGradient(context: context, frame: frame,
                        lightSurface: card.lightSurface, deviceScale: pixelSnapScale)
                } else {
                    context.setAlpha(card.lightSurface ? 0.42 : 0.64)
                    context.setFillColor(color(card.lightSurface ? [255, 255, 255] : [7, 9, 13]))
                    context.fill(frame)
                }
            }
            context.restoreGState()
        }
        guard paintsText else { return }
        // A caption genuinely appended to its readability owner inherits the
        // parent's overflow/clip path, including widened display coverage.
        if card.captionParentPlate, let owner = readabilityOwnerPanel(card) {
            if owner.clipped, owner.coverageClip != nil || !owner.coverage.isEmpty {
                applyCoverageClip(owner.coverageClip, coverage: owner.coverage, owner: owner.rect,
                    context: context, pixelSnapScale: pixelSnapScale)
            }
            if owner.overflowClip {
                context.addPath(CGPath(roundedRect: owner.rect,cornerWidth: CGFloat(owner.radius),
                    cornerHeight: CGFloat(owner.radius),transform: nil)); context.clip()
            }
        }
        if card.effectiveTextRotation != 0 { rotate(card.effectiveTextRotation, about: item.rect) }
        drawSlantedClip(card, context: context)
        if item.clipsText, !card.glyphPlateReleased {
            if let pixelSnapScale, card.style.vertical {
                context.addPath(NativeTranslationPDFCapture.roundedPath(item.rect,radius: 6,deviceScale: pixelSnapScale)); context.clip()
                context.clip(to: NativeTranslationPDFCapture.snappedRect(item.rect,deviceScale: pixelSnapScale))
            } else { context.addPath(CGPath(roundedRect: item.rect, cornerWidth: 6, cornerHeight: 6, transform: nil)); context.clip() }
        }
        if !card.unitTextParts.isEmpty {
            for part in card.unitTextParts {
                var style = part.style
                style.foreground = card.style.foreground; style.outline = card.style.outline
                style.outlineWidth = card.style.outlineWidth; style.outlineGlow = card.style.outlineGlow
                style.outlinePaintOrder = card.style.outlinePaintOrder
                let typography = NativeTranslationTypography.layout(text: part.text, in: part.frame.size, style: style)
                NativeTranslationTypography.draw(layout: typography, in: context, at: textPartFrame(part, card: card).origin,
                    additionalFillStrokeWidth: style.outlineWidth == 0 && style.outlineGlow == 0 ? card.heavyStrokeWidth : 0,
                    outlinePaintOrder: style.outlinePaintOrder, pixelSnapScale: pixelSnapScale)
            }
            return
        }
        // Typography centers in its content box, preserving the native planner's asymmetric padding.
        NativeTranslationTypography.draw(layout: card.typography, in: context, at: card.textOrigin,
                                          additionalFillStrokeWidth: card.style.outlineWidth == 0 && card.style.outlineGlow == 0 ? card.heavyStrokeWidth : 0,
                                          outlinePaintOrder: card.style.outlinePaintOrder, pixelSnapScale: pixelSnapScale)
    }

    static func columnSourceErasureRects(_ card: Card, settings: IPhoneOverlaySettings) -> [CGRect] {
        let item = card.item
        guard item.balancedColumn, !settings.preserveSourceBackgroundColor, settings.renderedBackgroundOpacity > 0,
              let rgb = item.sourceErasureRGB, rgb.count == 3, rgb.allSatisfy({ $0.isFinite && (0...255).contains($0) }) else { return [] }
        let frame: CGRect
        if let cleanupFrame = card.cleanupSourceFrame { frame = cleanupFrame }
        else {
            guard item.sourceFrame.count == 4, item.sourceFrame.allSatisfy(\.isFinite) else { return [] }
            frame = CGRect(x: item.sourceFrame[0],y: item.sourceFrame[1],width: item.sourceFrame[2],height: item.sourceFrame[3])
        }
        guard valid(frame) else { return [] }
        let padding = max(3,min(6,card.finalFontSize*0.3))
        return ([item.sourceBounds]+item.auxiliaryInkRects).compactMap { bounds in
            guard bounds.count == 4, bounds.allSatisfy(\.isFinite), bounds[2] > 0, bounds[3] > 0 else { return nil }
            let l = max(frame.minX,frame.minX+bounds[0]*frame.width-padding)
            let t = max(frame.minY,frame.minY+bounds[1]*frame.height-padding)
            let r = min(frame.maxX,frame.minX+(bounds[0]+bounds[2])*frame.width+padding)
            let b = min(frame.maxY,frame.minY+(bounds[1]+bounds[3])*frame.height+padding)
            return r > l && b > t ? CGRect(x: l,y: t,width: r-l,height: b-t) : nil
        }
    }

    static func drawColumnSourceErasure(_ card: Card, context: CGContext, settings: IPhoneOverlaySettings) {
        guard let rgb = card.item.sourceErasureRGB else { return }
        context.saveGState(); defer { context.restoreGState() }
        context.setFillColor(color(rgb))
        for rect in columnSourceErasureRects(card,settings: settings) { context.fill(rect) }
        for patch in card.columnFrameImages { UIImage(cgImage: patch.image).draw(in: patch.rect) }
    }

    /// Port of the oracle's quadInkOutsideBox: only proven paper permits upright text inside a tilted source quad.
    static func quadInkFitsUprightBox(_ item: NativeTranslationLayoutItem, image: CGImage,
                                             appearance: NativeTranslationRestoration.Appearance?) throws -> Bool {
        guard let result = try NativeSlantedQuadOutsideBox.read(item: item, image: image, sample: appearance?.sourceSample) else { return false }
        return Double(result.ink) <= max(2, Double(result.area) * 0.005)
    }

    private static func finalPaintBounds(cards: [Card], glossCards: [GlossCard], gloss: NativeTranslationEffectGloss.Refinement, settings: IPhoneOverlaySettings) -> [CGRect] {
        var result = cards.filter { !gloss.removedLayerIDs.contains($0.item.id) }.flatMap { card in card.sourcePanels.map { card.rotatesSourcePanels ? rotatedBounds($0.rect,about: card.sourcePlateRect,angle: card.item.rotation) : $0.rect } }
        result += cards.filter { !gloss.removedLayerIDs.contains($0.item.id) }.compactMap { card in
            !card.rotatesSourcePanels ? card.glyphCoverOwnerPanel.map(\.rect):nil
        }
        result += cards.filter { !gloss.removedLayerIDs.contains($0.item.id) && !gloss.hiddenIDs.contains($0.item.id) }.flatMap { columnSourceErasureRects($0,settings: settings) }
        for card in cards where !gloss.hiddenIDs.contains(card.item.id) && !gloss.removedLayerIDs.contains(card.item.id) {
            let node = physicalTextNodeRect(card)
            let range = cardInkRect(card)
            if valid(node), valid(range) { result.append(node.union(range).insetBy(dx: -2, dy: -2)) }
            else if valid(node) { result.append(node.insetBy(dx: -2, dy: -2)) }
        }
        for card in glossCards {
            guard let move = card.note.placement.moves.first else { continue }
            let origin = CGPoint(x: card.note.origin.x+move.x, y: card.note.origin.y+move.y)
            var node = CGRect(origin: origin, size: CGSize(width: card.note.placement.width,
                height: card.style.lineHeight * CGFloat(max(1,card.typography.lineCount))))
            var range = card.typography.rangeBounds.reduce(CGRect.null) { $0.union($1) }.offsetBy(dx: origin.x,dy: origin.y)
            if let angle = card.note.placement.angle, let center = card.note.placement.center {
                let pivot = CGRect(origin: center,size: .zero)
                node = rotatedBounds(node,about: pivot,angle: CGFloat(angle)); range = rotatedBounds(range,about: pivot,angle: CGFloat(angle))
            }
            if valid(node), valid(range) { result.append(node.union(range).insetBy(dx: -2,dy: -2)) }
        }
        return result.filter(valid)
    }

    private static func sourceRestorationRects(cards: [Card], glossCards: [GlossCard],
                                               gloss: NativeTranslationEffectGloss.Refinement, layout: NativeTranslationLayout,
                                               restoration: NativeTranslationRestoration.Result,
                                               recovered: NativeRecoveredLineProtection.Result, settings: IPhoneOverlaySettings) -> [CGRect] {
        let kept = layout.items.filter(\.keptLettering)
        guard !kept.isEmpty || !recovered.kept.isEmpty || !gloss.sourceZones.isEmpty else { return [] }
        let visible = cards.filter { !gloss.hiddenIDs.contains($0.item.id) && !gloss.removedLayerIDs.contains($0.item.id) }
        var glyphs = visible.flatMap { cardPageLineRects($0).map { $0.insetBy(dx: -1.5, dy: -1.5) } }
        glyphs += glossCards.flatMap { card -> [CGRect] in
            guard let move = card.note.placement.moves.first else { return [] }
            return NativeTranslationTypography.captionLineMetrics(layout: card.typography).map { metric in
                let rect = metric.rect.offsetBy(dx: card.note.origin.x + move.x, dy: card.note.origin.y + move.y)
                guard let center = card.note.placement.center, let angle = card.note.placement.angle else { return rect.insetBy(dx: -1.5, dy: -1.5) }
                return rotatedBounds(rect, about: CGRect(x: center.x, y: center.y, width: 0, height: 0), angle: CGFloat(angle)).insetBy(dx: -1.5, dy: -1.5)
            }
        }
        let covers = restoration.patches.filter { !gloss.removedLayerIDs.contains($0.itemID ?? "") }.map(\.rect) +
            visible.flatMap { card -> [CGRect] in
                var rects = card.sourcePanels.map { card.rotatesSourcePanels ? rotatedBounds($0.rect, about: card.sourcePlateRect, angle: card.item.rotation) : $0.rect }
                if let retained = card.glyphCoverOwnerPanel {
                    rects.append(card.rotatesSourcePanels ? rotatedBounds(retained.rect,about: card.sourcePlateRect,angle: card.item.rotation):retained.rect)
                }
                rects += card.backings.map(\.frame) + columnSourceErasureRects(card, settings: settings)
                if card.drawsPanel {
                    let plate = card.straightenedPanelRect ?? card.sourcePlateRect
                    rects.append(card.item.rotation != 0 && card.straightenedPanelRect == nil
                        ? rotatedBounds(plate,about: card.sourcePlateRect,angle: card.item.rotation):plate)
                }
                return rects
            }
        let recoveredKept = recovered.kept.map { NativeKeptSourceRestoration.Kept(id: $0.id, rect: $0.rect, sourceFontSize: $0.sourceFontSize) }
        let cleanupFrame = restoration.cleanupGeometry?.frame ?? layout.sourceRect
        let sourceElement = restoration.cleanupGeometry?.clip ?? layout.sourceRect
        let reconstructed = NativeKeptSourceRestoration.reconstructed(layout.items,cleanupFrame: cleanupFrame) + recoveredKept
        let keptZones = NativeKeptSourceRestoration.zones(items: layout.items,cleanupFrame: cleanupFrame) +
            NativeKeptSourceRestoration.zones(kept: recoveredKept, painted: recovered.painted)
        return NativeKeptSourceRestoration.select(kept: reconstructed,
            keptZones: keptZones,
            effectZones: gloss.sourceZones.map { .init(id: $0.id,rect: $0.rect) },glyphLines: glyphs,covers: covers,image: sourceElement).pieces
    }

    /// Match the former browser's background sampling raster budget, including UIImage orientation.
    private static func restorationImage(_ image: UIImage?) throws -> CGImage? {
        guard let image else { return nil }
        try Task.checkCancellation()
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        guard valid(pixels) else { throw RenderError.sourceImageUnavailable }
        let reduction = min(1, 8_192 / max(pixels.width, pixels.height), sqrt(4_000_000 / pixels.width / pixels.height))
        let size = CGSize(width: max(1, floor(pixels.width * reduction)), height: max(1, floor(pixels.height * reduction)))
        if image.imageOrientation == .up, reduction == 1, let source = image.cgImage { return source }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let normalized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        try Task.checkCancellation()
        guard let source = normalized.cgImage else { throw RenderError.sourceImageUnavailable }
        return source
    }

    static func color(_ channels: [CGFloat]) -> CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                components: [channels[0] / 255, channels[1] / 255, channels[2] / 255, 1])!
    }

    static func panelForeground(_ surface: CGColor, opacity: CGFloat) -> CGColor {
        let rgb = surface.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? []
        guard rgb.count >= 3, rgb.prefix(3).allSatisfy(\.isFinite), opacity.isFinite else { return color([17, 18, 23]) }
        let alpha = min(1, max(0, opacity))
        let transparent = 1 - alpha
        func luminance(_ channels: [CGFloat]) -> CGFloat {
            zip(channels, [CGFloat(0.2126), 0.7152, 0.0722]).reduce(0) { value, pair in
                let linear = pair.0 <= 0.04045 ? pair.0 / 12.92 : pow((pair.0 + 0.055) / 1.055, 2.4)
                return value + linear * pair.1
            }
        }
        let againstBlack = luminance(Array(rgb.prefix(3)).map { $0 * alpha })
        let againstWhite = luminance(Array(rgb.prefix(3)).map { $0 * alpha + transparent })
        guard againstBlack.isFinite, againstWhite.isFinite else { return color([17, 18, 23]) }
        // At full opacity the endpoints must be identical. Computing +1-alpha
        // instead of +(1-alpha) can put white below black by an ULP and trap a ClosedRange.
        let low = min(againstBlack, againstWhite), high = max(againstBlack, againstWhite)
        func contrast(_ text: CGFloat) -> CGFloat {
            if text >= low && text <= high { return 1 }
            return min((max(text, low) + 0.05) / (min(text, low) + 0.05),
                       (max(text, high) + 0.05) / (min(text, high) + 0.05))
        }
        let dark = luminance([17 / 255, 18 / 255, 23 / 255])
        return color(contrast(dark) >= contrast(1) ? [17, 18, 23] : [255, 255, 255])
    }

    static func valid(_ size: CGSize) -> Bool { size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0 }
    static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) && rect.width > 0 && rect.height > 0
    }

    private static func validate(viewport: CGSize, scale: CGFloat) throws {
        guard valid(viewport), scale.isFinite, scale > 0 else { throw RenderError.invalidGeometry }
        let pixels = pixelSize(viewport: viewport, scale: scale)
        let width = pixels.width, height = pixels.height
        guard width.isFinite, height.isFinite, width <= 16_384, height <= 16_384,
              width * height <= 12_000_000 else { throw RenderError.bitmapTooLarge }
    }

    private static func pixelSize(viewport: CGSize, scale: CGFloat) -> CGSize {
        func dimension(_ value: CGFloat) -> CGFloat {
            let nearest = value.rounded()
            // Affine scale division can produce 4000.0000000000005 for an exact 4000-pixel target.
            return max(1, abs(value - nearest) <= 0.000_001 ? nearest : ceil(value))
        }
        return CGSize(width: dimension(viewport.width * scale), height: dimension(viewport.height * scale))
    }

    /// Inherits the render worker's actor. The plan/CoreText values are never sent
    /// to the MainActor; only immutable image/numeric requests leave this job.
    nonisolated(nonsending) static func renderOnWorker(layout: NativeTranslationLayout, image: UIImage?,
        settings: IPhoneOverlaySettings, scale: CGFloat, dark: Bool, renderBounds: CGRect?,
        composeSource: Bool, outputPixelSize: CGSize?, collectDiagnostics: Bool,
        capturePDF: Bool, pdfDeviceScale: CGFloat) async throws -> Result {
        let plan = try prepareRenderSynchronously(layout: layout, image: image, settings: settings,
            scale: scale, dark: dark, renderBounds: renderBounds, composeSource: composeSource,
            outputPixelSize: outputPixelSize, collectDiagnostics: collectDiagnostics,
            capturePDF: capturePDF, pdfDeviceScale: pdfDeviceScale)
        try Task.checkCancellation()
        // Preserve the synchronous PDF/ordinary route whenever there is no admitted
        // minified source operation. Eligibility is geometric, not a fixture switch.
        guard !capturePDF, asyncSourceJobIsEligible(plan) else { return try finishPreparedSynchronously(plan) }
        return try await finishPreparedAsynchronously(plan)
    }

    static func asyncSourceJobIsEligible(_ plan: PreparedRender) -> Bool {
        guard plan.bounds.origin == .zero,
              plan.pixels.width / plan.bounds.width == plan.pixels.height / plan.bounds.height,
              plan.pixels.width * plan.pixels.height <= 4_000_000 else { return false }
        let scale = plan.pixels.width / plan.bounds.width
        let initial = plan.sourcePatches.filter { patch in
            patch.liveOrder == nil && !plan.cards.contains(where: { $0.glyphCoverPatch?.image === patch.image })
        }
        let late = plan.sourcePatches.filter { $0.liveOrder != nil }
        let commands = orderedPaintCommands(cards: plan.cards, gloss: plan.gloss, settings: plan.settings, latePatches: late)
        let orderedSources = commands.compactMap { command -> SourcePatch? in
            switch command.operation {
            case .forced(let index): return late[index]
            case .cover(let index): return plan.cards[index].glyphCoverPatch
            default: return nil
            }
        }
        return (initial + orderedSources).contains {
            admittedHierarchySourceFrame($0, viewport: plan.bounds.size, scale: scale) != nil
        }
    }

    /// Pure refusal predicate, evaluated before reading/allocating a prefix.
    static func admittedHierarchySourceFrame(_ patch: SourcePatch, viewport: CGSize, scale: CGFloat) -> CGRect? {
        guard patch.cleanupClip == nil, scale.isFinite, scale > 0,
              viewport.width.isFinite, viewport.height.isFinite, viewport.width > 0, viewport.height > 0,
              viewport.width * scale <= 16_384, viewport.height * scale <= 16_384,
              viewport.width * viewport.height * scale * scale <= 4_000_000,
              let frame = NativeSourceCanvasImageFrame.liveFrame(domRect: patch.rect),
              CGRect(origin: .zero, size: viewport).contains(frame),
              patch.image.width > 0, patch.image.height > 0,
              patch.image.width <= 16_384, patch.image.height <= 16_384,
              patch.image.width <= 12_000_000 / patch.image.height,
              patch.image.bitsPerComponent == 8, patch.image.bitsPerPixel == 32,
              patch.image.colorSpace?.name == CGColorSpace.sRGB,
              [.premultipliedFirst, .premultipliedLast, .noneSkipFirst, .noneSkipLast].contains(patch.image.alphaInfo) else { return nil }
        let width = frame.width * scale, height = frame.height * scale
        let values = [viewport.width * scale, viewport.height * scale,
            frame.minX * scale, frame.minY * scale, width, height]
        guard values.allSatisfy({ $0.isFinite && $0.rounded(.towardZero) == $0 }),
              width > 0, height > 0, width * height <= 4_000_000,
              width <= CGFloat(patch.image.width), height <= CGFloat(patch.image.height),
              width < CGFloat(patch.image.width) || height < CGFloat(patch.image.height) else { return nil }
        return frame
    }

    /// Explicitly owned bitmap: admitted source patches and text draw directly
    /// into its worker-private context without capturing a UIKit hierarchy.
    final class WorkerLiveBitmap {
        private(set) var context: CGContext?
        private(set) var backing: NativeCanvasBacking?
        init(pixels: CGSize, bounds: CGRect) throws {
            guard pixels.width.isFinite, pixels.height.isFinite, pixels.width > 0, pixels.height > 0,
                  pixels.width.rounded(.towardZero) == pixels.width, pixels.height.rounded(.towardZero) == pixels.height,
                  pixels.width <= 16_384, pixels.height <= 16_384, pixels.width * pixels.height <= 4_000_000,
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height),
                    bitsPerComponent: 8, bytesPerRow: Int(pixels.width) * 4, space: space,
                    bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else { throw RenderError.invalidGeometry }
            context.translateBy(x: 0, y: pixels.height)
            context.scaleBy(x: 1, y: -1)
            context.scaleBy(x: pixels.width / bounds.width, y: pixels.height / bounds.height)
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            self.context = context
            backing = NativeCanvasBacking.freshCanonicalBitmap(context: context, pixelExtent: pixels)
            guard backing != nil else { close(); throw RenderError.invalidGeometry }
        }
        func close() { backing = nil; context = nil }
    }

    /// UIKit's thread-local graphics stack exists only for synchronous CPU blocks.
    /// No pushed context survives suspension or a change of executor thread.
    static func withWorkerGraphicsContext<T>(_ context: CGContext, _ body: () throws -> T) rethrows -> T {
        try autoreleasepool {
            UIGraphicsPushContext(context)
            defer { UIGraphicsPopContext() }
            return try body()
        }
    }

    nonisolated(nonsending) static func paintHierarchySourcePatch(_ patch: SourcePatch,
        context: CGContext, backing: NativeCanvasBacking?, viewport: CGSize) async throws -> Bool {
        try Task.checkCancellation()
        let matrix = context.ctm
        guard matrix.a > 0, matrix.d == -matrix.a, matrix.b == 0, matrix.c == 0,
              let frame = admittedHierarchySourceFrame(patch, viewport: viewport, scale: matrix.a),
              let backing, backing.matchesFreshState(context) else { return false }
        // Draw into the already-owned worker bitmap. Copying its full RGBA prefix,
        // capturing a temporary view hierarchy, and replaying the whole page made
        // every small source patch cost another pair of page-sized allocations.
        return try NativeSourceCanvasHierarchyCompositor.draw(source: patch.image,
            sourceFrame: frame, viewport: viewport, scale: matrix.a, in: context)
    }

    nonisolated(nonsending) static func finishPreparedAsynchronously(_ plan: PreparedRender) async throws -> Result {
        let bitmap = try WorkerLiveBitmap(pixels: plan.pixels, bounds: plan.bounds)
        let canvasSession = NativeCanvasTextureResampler.Session()
        defer { canvasSession.close(); bitmap.close() }
        guard let context = bitmap.context else { throw RenderError.invalidGeometry }
        for patch in plan.sourcePatches {
            if patch.liveOrder != nil || plan.cards.contains(where: { $0.glyphCoverPatch?.image === patch.image }) { continue }
            try Task.checkCancellation()
            if try await paintHierarchySourcePatch(patch, context: context, backing: bitmap.backing, viewport: plan.bounds.size) { continue }
            try Task.checkCancellation()
            withWorkerGraphicsContext(context) {
                drawSourcePatch(patch, context: context, usesLiveTextureSampling: true, canvasSession: canvasSession,
                    canvasBacking: bitmap.backing, allowsOpaqueAffineSampling: true)
            }
        }
        let latePatches = plan.sourcePatches.filter { $0.liveOrder != nil }
        let ordered = orderedPaintCommands(cards: plan.cards, gloss: plan.gloss, settings: plan.settings, latePatches: latePatches)
        for command in ordered {
            try Task.checkCancellation()
            let patch: SourcePatch?
            switch command.operation {
            case .forced(let index): patch = latePatches[index]
            case .cover(let index): patch = plan.cards[index].glyphCoverPatch
            default: patch = nil
            }
            if let patch, try await paintHierarchySourcePatch(patch, context: context, backing: bitmap.backing, viewport: plan.bounds.size) { continue }
            try Task.checkCancellation()
            withWorkerGraphicsContext(context) {
                drawPaintCommand(command, cards: plan.cards, gloss: plan.gloss, settings: plan.settings,
                    context: context, pixelSnapScale: nil, latePatches: latePatches, usesLiveTextureSampling: true,
                    canvasSession: canvasSession, canvasBacking: bitmap.backing, allowsOpaqueAffineSampling: true)
            }
        }
        try withWorkerGraphicsContext(context) {
            for card in plan.glossCards {
                try Task.checkCancellation()
                drawGloss(card, context: context, pixelSnapScale: nil)
            }
            if !plan.sourcePieces.isEmpty {
                if let source = plan.source, let geometry = plan.restoration.cleanupGeometry {
                    drawKeptSourceCopy(source: source, geometry: geometry, pieces: plan.sourcePieces, context: context)
                } else if let image = plan.image {
                    context.saveGState(); context.addRects(plan.sourcePieces); context.clip()
                    image.draw(in: plan.layout.sourceRect); context.restoreGState()
                }
            }
        }
        try Task.checkCancellation()
        guard let overlay = context.makeImage() else { throw RenderError.invalidGeometry }
        return try finishPreparedResult(plan, overlayCGImage: overlay, exportPDFData: nil)
    }

}
