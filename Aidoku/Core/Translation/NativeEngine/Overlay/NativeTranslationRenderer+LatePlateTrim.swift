import CoreGraphics
import Foundation

extension NativeTranslationRenderer {
    /// Frozen14350–14596 runs after all layout and palette passes. Only the
    /// plate rectangle/coverage commits; current typography is never reshaped.
    @discardableResult
    static func applyLatePlateTrim(cards: inout [Card], gloss: NativeTranslationEffectGloss.Refinement,
        layout: NativeTranslationLayout, restoration: NativeTranslationRestoration.Result,
        source: CGImage?, settings: IPhoneOverlaySettings,
        milliseconds: () -> Double = { ProcessInfo.processInfo.systemUptime * 1000 }, collectDiagnostics: Bool = false) -> [String: [Int]] {
        // Frozen `items` contains translated captions; kept lettering lives
        // in its independent ownership list and is not erased by this pass.
        let translatedItems = layout.items.filter { !$0.keptLettering }
        guard settings.renderedBackgroundOpacity == 1, settings.preserveSourceBackgroundColor,
              translatedItems.count <= 256 else { return [:] }
        let began = milliseconds(), budget = NativeLatePlateTrim.Budget()
        let reader = source.map { NativeSourcePixelReader(image: $0) }
        defer { reader?.release() }
        let scene = NativeLatePlateTrim.Scene(opacity: settings.renderedBackgroundOpacity,
            preserveSourceBackground: settings.preserveSourceBackgroundColor, itemCount: translatedItems.count,
            frame: restoration.cleanupGeometry?.frame ?? layout.sourceRect,
            imageSize: source.map { CGSize(width: $0.width, height: $0.height) } ?? .zero,
            imageComplete: source != nil)
        let sources = translatedItems.map { item in NativeLatePlateTrim.Source(id: item.id,
            bounds: item.sourceBounds.map(Double.init), auxiliary: item.auxiliaryInkRects.map { $0.map(Double.init) },
            font: item.sourceFontSize.map(Double.init), vertical: item.sourceVertical, rotation: Double(item.rotation)) }
        let visible = cards.indices.filter { !gloss.hiddenIDs.contains(cards[$0].item.id) && !gloss.removedLayerIDs.contains(cards[$0].item.id) }
        // Frozen inkOf snapshots every visible caption before processing plates.
        let inks = Dictionary(uniqueKeysWithValues: visible.map { ($0,cardWholeRangeRect(cards[$0]) ?? .zero) })
        var records: [String: [Int]] = [:]
        for index in cards.indices {
            let card = cards[index], item = card.item
            guard visible.contains(index), let sourceItem = sources.first(where: { $0.id == item.id }) else { continue }
            for pi in card.sourcePanels.indices {
                if milliseconds() - began > 60 { return records }
                let panel = cards[index].sourcePanels[pi]
                let explicitCoverage = panel.clipped || panel.captionUnionClipped || panel.coverage != [panel.rect]
                let transformed = card.rotatesSourcePanels || panel.rotated
                let sample = restoration.appearances[item.id]?.sourceSample ?? [:]
                let caption = NativeLatePlateTrim.Caption(ink: inks[index] ?? .zero, font: Double(card.style.fontSize),
                    transformed: card.effectiveTextRotation != 0, displayCardGrowth: card.displayCardGrowth,
                    sampledForeground: NativeSourceColorSampler.rgb(sample["foreground"]),
                    sampledStroke: NativeSourceColorSampler.rgb(sample["stroke"]), outlined: card.outlinedRecord, sample: sample)
                let plate = NativeLatePlateTrim.Plate(rect: panel.rect, coverage: explicitCoverage ? panel.coverage : nil,
                    background: panel.background, sourceErasure: panel.sourceErasure,
                    sourcePreservedCaption: card.preservedGloss || card.preservedErasure, transformed: transformed,
                    hasBackgroundImage: panel.sourceFrameImage != nil || !card.foreignFills.isEmpty,
                    hasBacking: !card.backings.isEmpty, otherChildren: panel.hasForeignChildren,
                    clipped: panel.clipped || panel.captionUnionClipped)
                let patch = restoration.patches.last { $0.itemID == item.id }
                let remainingBefore = budget.samples
                let proposal = NativeLatePlateTrim.trim(source: sourceItem, caption: caption, plate: plate,
                    scene: scene, budget: budget, otherSources: sources,
                    otherCaptionInks: visible.filter { $0 != index }.compactMap { inks[$0] }, restoration: patch?.rect,
                    readSource: { crop,w,h in
                        try Task.checkCancellation()
                        guard let reader else { return [] }
                        return try reader.read(x: Double(crop.minX),y: Double(crop.minY),sourceWidth: Double(crop.width),
                            sourceHeight: Double(crop.height),width: w,height: h)
                    }, validate: { _ in
                        // Native source panel coverage does not participate in
                        // line layout: this commits no text coordinates or metrics.
                        .init(ink: inks[index] ?? .zero,fits: card.typography.fits)
                    })
                if collectDiagnostics {
                    func box(_ rect: CGRect) -> [Double] { [Double(rect.minX),Double(rect.minY),Double(rect.width),Double(rect.height)] }
                    cards[index].latePlateTrimTrace.append([
                        "panelIndex": pi, "before": box(panel.rect), "coverage": panel.coverage.map(box),
                        "ink": box(inks[index] ?? .zero), "font": Double(card.style.fontSize),
                        "hasBacking": plate.hasBacking, "backings": card.backings.map { box($0.frame) },
                        "sourceErasure": plate.sourceErasure, "hasBackgroundImage": plate.hasBackgroundImage,
                        "otherChildren": plate.otherChildren, "transformed": plate.transformed,
                        "displayCardGrowth": caption.displayCardGrowth, "clipped": plate.clipped,
                        "sampleBudgetBefore": remainingBefore, "sampleBudgetAfter": budget.samples,
                        "accepted": proposal != nil, "after": proposal.map { box($0.rect) } ?? box(panel.rect),
                        "area": proposal.map { [$0.oldArea,$0.newArea] } ?? []])
                }
                guard let proposal else { continue }
                cards[index].sourcePanels[pi].rect = proposal.rect
                cards[index].sourcePanels[pi].coverage = proposal.coverage ?? [proposal.rect]
                if let coverage = proposal.coverage {
                    cards[index].sourcePanels[pi].clipped = proposal.clipped
                    cards[index].sourcePanels[pi].coverageClip = proposal.clipped ? NativeCSSCoveragePath.declaration(coverage: coverage, origin: proposal.rect.origin, commands: .absolute) : nil
                }
                // The frozen trim updates CSS coverage without deleting the
                // caption-union marker used by later caption-panel admission.
                records[item.id] = [proposal.oldArea,proposal.newArea]
            }
        }
        return records
    }
}
