import CoreGraphics
import Foundation

extension NativeTranslationRenderer {
    struct DisplayLetteringReport {
        var acceptedIDs: Set<String> = []
        var records: [String:[String:Any]] = [:]
        var rejected: [String:String] = [:]
        var remainingColour = 393216
        var remainingBlackWhite = 262144
    }
    private static func displayNumber(_ value: Double) -> String {
        let result = String(value); return result.hasSuffix(".0") ? String(result.dropLast(2)) : result
    }
    @discardableResult
    static func restoreDisplayLettering(cards: inout [Card],gloss: NativeTranslationEffectGloss.Refinement,
        layout: NativeTranslationLayout,restoration: inout NativeTranslationRestoration.Result,settings: IPhoneOverlaySettings,
        source: CGImage?,metadata: inout [String:DisplayCohortMetadata]) throws -> DisplayLetteringReport {
        var report = DisplayLetteringReport()
        guard settings.renderedBackgroundOpacity == 1, settings.usesSourceInpainting,settings.preserveSourceBackgroundColor,
              let source,source.width > 0,layout.items.count <= 256 else { return report }
        let budget = NativeDisplayLetteringStage.Budget(), reader = NativeSourcePixelReader(image:source)
        defer { reader.release() }
        func visible(_ card: Card)->Bool { !gloss.hiddenIDs.contains(card.item.id) && !gloss.removedLayerIDs.contains(card.item.id) }
        for item in layout.items {
            try Task.checkCancellation()
            guard let index = cards.firstIndex(where: { $0.item.id == item.id }) else { continue }
            let card = cards[index]
            guard visible(card),metadata[item.id]?.backgroundKind == "readability-panel",item.rotation == 0,!item.vertical,
                  item.allowsAutomaticFontRecovery,item.sourceColorEligible,["korean","word"].contains(item.wrappingScript),
                  !item.text.isEmpty,item.text.utf16.count <= 48,let font = item.sourceFontSize,font.isFinite,font >= 24,
                  card.sourcePanels.count == 1,!card.sourcePanels[0].hasForeignChildren,card.backings.isEmpty,
                  item.sourceBounds.count == 4 else { continue }
            let frame = restoration.cleanupGeometry?.frame ?? layout.sourceRect,bounds = item.sourceBounds.map(Double.init)
            let others = layout.items.filter { $0.id != item.id }.map { other in
                NativeDisplayLetteringStage.Other(bounds:other.sourceBounds.map(Double.init),mode:metadata[other.id]?.backgroundKind,
                    plates:cards.first(where: { $0.item.id == other.id })?.sourcePanels.map(\.rect) ?? [])
            }
            let hides = NativeDisplayLetteringStage.hidesOther(plate:card.sourcePanels[0].rect,frame:frame,others:others)
            if NativeDisplayLetteringStage.crowded(bounds:bounds,others:others) || hides { if hides { report.rejected[item.id] = "hides-source" }; continue }
            let imageSize = CGSize(width:source.width,height:source.height)
            guard let crop = NativeDisplayLetteringStage.crop(bounds:bounds,frame:frame,imageSize:imageSize,glyph:Double(font),budget:budget) else { continue }
            let sample = restoration.appearances[item.id]?.sourceSample
            guard let pixels = try? reader.read(x:Double(crop.x),y:Double(crop.y),sourceWidth:Double(crop.sw),sourceHeight:Double(crop.sh),width:crop.width,height:crop.height) else { continue }
            var result = NativeDisplayLetteringPixels.colour(rgba:pixels,width:crop.width,height:crop.height,box:crop.box,glyph:crop.glyph,
                surface:NativeRestorationPixels.rgb(sample?["background"])?.channels,text:NativeRestorationPixels.rgb(sample?["foreground"])?.channels)
            if let colourReject = result.reject {
                var blackWhite = NativeDisplayLetteringPixels.Result(reject:"bw-budget")
                if crop.width*crop.height <= budget.blackWhite {
                    budget.blackWhite -= crop.width*crop.height
                    blackWhite = NativeDisplayLetteringPixels.blackWhite(rgba:pixels,width:crop.width,height:crop.height,box:crop.box,glyph:crop.glyph,borders:crop.borders)
                }
                if let bwReject = blackWhite.reject { report.rejected[item.id] = colourReject+"; "+bwReject; continue }
                result = blackWhite
            }
            guard result.reject == nil,let fill = result.fill,let outline = result.outline else { continue }
            let fillL = NativeTranslationSourceStylePostPolish.luminance(fill),outlineL = NativeTranslationSourceStylePostPolish.luminance(outline)
            let contrast = (max(fillL,outlineL)+0.05)/(min(fillL,outlineL)+0.05)
            let stroke = contrast >= 3 ? outline : fillL > 0.3 ? [0.0,0.0,0.0] : [255.0,255.0,255.0]
            let originalInk = cardInkRect(card), otherInk = cards.filter { $0.item.id != item.id && visible($0) }.map(cardInkRect).filter { $0.width > 0 && $0.height > 0 }
            let sourceRect = CGRect(x:Double(frame.minX)+bounds[0]*Double(frame.width),y:Double(frame.minY)+bounds[1]*Double(frame.height),width:bounds[2]*Double(frame.width),height:bounds[3]*Double(frame.height))
            let trial = NativeDisplayLetteringTrial.Input(text:item.text,source:sourceRect,frame:frame,glyph:Double(font),current:Double(card.finalFontSize),
                ratio:Double(card.style.lineHeight/card.finalFontSize),priorInk:originalInk,others:otherInk)
            var acceptedCard: Card?
            let accepted = NativeDisplayLetteringTrial.prepare(trial) { probe in
                var next = card
                next.item.x = probe.rect.minX; next.item.y = probe.rect.minY; next.item.width = probe.rect.width; next.item.height = probe.rect.height
                next.item.paddingTop = CGFloat(probe.inset); next.item.paddingRight = CGFloat(probe.inset)
                next.item.paddingBottom = CGFloat(probe.inset); next.item.paddingLeft = CGFloat(probe.inset)
                next.item.fontSize = CGFloat(probe.size); next.item.lineHeight = CGFloat(probe.lineHeight); next.item.rotation = 0
                next.item.typesettingText = item.text; next.item.typesettingWidthScale = nil
                next.item.typesettingQuoteMode = nil; next.item.typesettingBlockDisplay = nil
                next.item.typesettingPreservedBlockWrapper = nil; next.item.typesettingPreformattedRows = nil
                next.style.usesBlockWordLayout = false; next.style.usesPreformattedBlockRows = false
                next.style.blockWordLayoutUsesTopPadding = false
                next.item = usedLayoutItem(next.item)
                next.style.fontSize = CGFloat(probe.size); next.style.lineHeight = CGFloat(probe.lineHeight)
                next.style.alignsToTop = false; next.style.horizontalAlignment = .center; next.style.horizontalScale = 1
                next.textShift = .zero; next.textRotation = 0; next.lineOffsets = []; next.typographyWidth = nil
                next.unitTextParts = []; next.unitTextPartsOrigin = nil; next.unitParts = nil
                next.finalFontSize = CGFloat(probe.size)
                next.typography = NativeTranslationTypography.layout(text:item.text,in:next.item.contentRect.size,style:next.style)
                let longest = item.text.components(separatedBy:" ").filter { !$0.isEmpty }.map { word in
                    Double(NativeTranslationTypography.canvasTextMetrics(text:word,style:next.style)?.advance ?? 0)
                }.max() ?? -Double.infinity
                acceptedCard = next
                return .init(ink:cardInkRect(next),longestWord:longest,contentFits:next.typography.fits)
            }
            guard let accepted,var next = acceptedCard else { report.rejected[item.id] = "layout"; continue }
            var repaint = NativeRestorationPixels(width:crop.width,height:crop.height); repaint.rgba = result.output
            guard let image = repaint.image() else { continue }
            restoration.patches.append(.init(image:image,rect:crop.rect,itemID:item.id,
                rasterGeometry:.init(frame:frame,imageSize:imageSize,origin:CGPoint(x:crop.x,y:crop.y),scale:CGSize(width:Double(crop.width)/Double(crop.sw),height:Double(crop.height)/Double(crop.sh))),
                cleanupClip:restoration.cleanupGeometry?.clip))
            next.style.foreground = color(fill.map { CGFloat($0) }); next.style.outline = color(stroke.map { CGFloat($0) })
            next.style.outlineWidth = CGFloat(accepted.probe.strokeWidth); next.style.outlineGlow = 0
            next.outlineGlow = 0; next.strokePreserved = true; next.heavyStrokeWidth = 0
            next.sourcePanels = []; next.backings = []; next.columnFrameImages = []; next.foreignFills = []; next.drawsPanel = false
            next.sourcePlateOwnerRect = nil
            next.background = CGColor(gray:0,alpha:0); next.rotatesSourcePanels = false
            next.sourceBackgroundKind = "display-restored"; next.sourceStrokeKind = "preserved"
            next.displayRestored = true; next.captionParentPlate = false; next.textZ = 3
            next.typography = remeasureTypography(next)
            cards[index] = next
            appendTextToRoot(cards: &cards, index: index)
            metadata[item.id] = .init(backgroundKind:"display-restored",strokeKind:"preserved",surfaceRange:nil)
            report.acceptedIDs.insert(item.id)
            var record: [String:Any] = ["font":"\(displayNumber(Double(card.finalFontSize)))->\(displayNumber(accepted.probe.size))","outlineWidth":result.width,
                "masked":floor(result.masked*100+0.5)/100,"fill":fill,"outline":outline,"kind":result.polarity ?? "colour"]
            if let halo = result.halo { record["halo"] = halo }; report.records[item.id] = record
            cards[index].displayLetteringRecord = record; cards[index].displayLetteringReject = nil
        }
        for index in cards.indices { if let reason = report.rejected[cards[index].item.id] { cards[index].displayLetteringReject = reason } }
        report.remainingColour = budget.colour; report.remainingBlackWhite = budget.blackWhite
        return report
    }
}
