import CoreGraphics
import Foundation

extension NativeTranslationRenderer {
    /// The renderer's retained typography surface session supplies the original
    /// source mask, exterior plane, pool and budget; geometry alone cannot certify it.
    typealias ArtworkSurfaceQuery = (Card, [CGRect], CGColor, inout Int) -> Bool

    static func artworkLineStarts(_ layout: NativeTranslationTypography.Layout) -> [Int] {
        let text = layout.shapedText as NSString
        var offsets: [Int] = [],base = 0
        for range in layout.lineRanges where range.location >= 0 && NSMaxRange(range) <= text.length {
            let raw = text.substring(with:range).replacingOccurrences(of:"\n",with:"")
            var at = base
            for scalar in raw.unicodeScalars {
                if !NativeSlantedTypographyTrial.whitespace(scalar) { offsets.append(at);break }
                at += scalar.utf16.count
            }
            base += raw.utf16.count
        }
        return offsets
    }
    static func artworkFlow(_ layout: NativeTranslationTypography.Layout,text: String) -> NativeArtworkProtection.Flow {
        let p = NativeTypographyPostPolish.profile(layout,originalText:text)
        return .init(breaks:p.breaks.count,badStarts:p.badStarts.count,badEnds:p.badEnds.count,
                     hangulFragments:p.hangulFragments,punctuationOnly:p.punctuationOnly)
    }
    /// Initial source-readable plates and fixed-box reflow are complete; final
    /// source ink clustering has not started. Every speculation is rolled back.
    static func protectInitialArtwork(cards: inout [Card],restoration: inout NativeTranslationRestoration.Result,
                                      layout: NativeTranslationLayout,source: CGImage?,settings: IPhoneOverlaySettings,
                                      surfaceQuery: @escaping ArtworkSurfaceQuery) throws -> NativeArtworkProtection.Budget {
        typealias Policy = NativeArtworkProtection
        var budget = Policy.Budget()
        guard settings.renderedBackgroundOpacity == 1,layout.items.count <= 256,settings.preserveSourceBackgroundColor else { return budget }
        var entryCharacters = 8192,inspectionCharacters = 8192
        let candidates = Dictionary(restoration.patches.compactMap { p -> (String,NativeRestorationCandidate)? in
            guard let id = p.itemID,let c = p.candidate else { return nil };return (id,c)
        },uniquingKeysWith: { _,last in last })
        func rangeRects(_ card: Card) -> [CGRect] {card.typography.rangeBounds.map { $0.offsetBy(dx:card.textOrigin.x,dy:card.textOrigin.y) }}
        var captured: Set<String> = [],inspectable: Set<String> = []
        for item in layout.items where !item.keptLettering && !item.text.isEmpty {
            let length = item.text.utf16.count
            if candidates[item.id] != nil,length <= inspectionCharacters {inspectionCharacters -= length;inspectable.insert(item.id)}
            if item.sourceColorEligible,!item.sourceTextOnly,!item.vertical,length <= 180,length*3 <= entryCharacters {
                entryCharacters -= length*3;captured.insert(item.id)
            }
        }
        for index in cards.indices {
            try Task.checkCancellation()
            let original = cards[index],item = original.item
            guard captured.contains(item.id) else { continue }
            let sample = restoration.appearances[item.id]?.sourceSample ?? [:]
            let palette = NativeTranslationSourceStylePostPolish.captionPalette(sample:sample,ink:rgb(original.style.foreground),
                preserveText:true,displayInk:NativeObservedSourcePalette.sourceDisplayInk(sample:sample))
            let patch = candidates[item.id]
            let initial = Policy.Measurement(ink:rangeRects(original),lines:NativeTypographyPostPolish.profile(original.typography,originalText:item.text).lines,
                lineStarts:artworkLineStarts(original.typography),flow:artworkFlow(original.typography,text:item.text),contentFits:original.typography.fits)
            let plateIndex = original.sourcePanels.firstIndex { !$0.sourceErasure }
            guard let sourceRect = pageRect(item.sourceBounds,frame:layout.sourceRect) else { continue }
            var e = Policy.Entry(id:item.id,text:item.text,font:Double(original.style.fontSize),
                sizes:NativeTypographyPostPolish.artworkFontSizes(font:original.style.fontSize).map { Double($0) },
                frame:layout.sourceRect,source:sourceRect,background:palette.background,
                plate:plateIndex.map { original.sourcePanels[$0].rect },original:initial)
            e.balancedColumn = item.balancedColumn;e.rotation = Double(item.rotation);e.rightToLeft = item.wrappingScript == "rightToLeft"
            e.alreadyRestored = original.sourcePanels.isEmpty && restoration.appearances[item.id]?.restored == true && restoration.appearances[item.id]?.erasureComplete == true
            e.erasureComplete = patch?.erasureComplete == true;e.residualLettering = patch?.surface.residualLettering
            e.hasSurfaceQuery = inspectable.contains(item.id);e.hasSourceImage = source != nil
            e.otherSources = layout.items.filter { $0.id != item.id }.flatMap { other in
                ([other.sourceBounds]+other.auxiliaryInkRects).compactMap { pageRect($0,frame:layout.sourceRect) }
            }
            e.otherText = cards.filter { $0.item.id != item.id }.map(cardInkRect)
            var proposed: [(CGFloat,Card)] = []
            let result = Policy.run(e,budget:&budget,hooks:.init(residualLettering: {
                guard let patch else { return false }
                let regions = patch.viewportRegions(([item.sourceBounds]+item.auxiliaryInkRects).compactMap { pageRect($0,frame:layout.sourceRect) })
                let glyph = max(4,Double(item.sourceFontSize ?? original.style.fontSize)*Double(patch.imageSize.width/patch.frame.width)*patch.descriptor.sx)
                let residual = NativeResidualTopology.hasResidualLettering(safe:patch.safe,width:patch.surface.width,height:patch.surface.height,regions:regions,glyphSize:glyph)
                patch.cacheProof(residualLettering:residual);return residual
            },read:{ box in
                guard let source else { return nil }
                let frame = layout.sourceRect,kx = Double(source.width)/Double(frame.width),ky = Double(source.height)/Double(frame.height)
                return try? NativeSourcePixelReader.draw(image:source,x:Double(box.minX-frame.minX)*kx,y:Double(box.minY-frame.minY)*ky,
                    sourceWidth:Double(box.width)*kx,sourceHeight:Double(box.height)*ky,width:32,height:32)
            },measure:{ candidate in
                var next = original
                let ratio = max(1,Double(original.style.lineHeight/max(1,original.style.fontSize))),c = candidate
                next.item.x = c.rect.minX;next.item.y = c.rect.minY;next.item.width = c.rect.width;next.item.height = c.rect.height
                next.item.paddingTop = 0;next.item.paddingRight = 0;next.item.paddingBottom = 0;next.item.paddingLeft = 0
                next.item.fontSize = CGFloat(c.font);next.item.lineHeight = CGFloat(c.font*ratio)
                next.item.typesettingText = c.frozenLines.joined(separator:"\n")
                next.style.fontSize = CGFloat(c.font);next.style.lineHeight = CGFloat(c.font*ratio)
                next.style.tracking = next.style.fontSize * original.style.tracking/original.style.fontSize
                next.style.optimizesKoreanWrapping = false;next.style.balancesHorizontalLines = false;next.style.balancesExplicitParagraphs = false
                next.style.keepsWholeWords = false;next.style.alignsToTop = false
                next.typographyWidth = nil;next.lineOffsets = [];next.textShift = .zero
                next.typography = NativeTranslationTypography.layout(text:next.item.typesettingText!,in:next.item.contentRect.size,style:next.style)
                next.finalFontSize = CGFloat(c.font)
                let profile = NativeTypographyPostPolish.profile(next.typography,originalText:item.text)
                let measurement = Policy.Measurement(ink:rangeRects(next),lines:profile.lines,lineStarts:artworkLineStarts(next.typography),
                    flow:artworkFlow(next.typography,text:item.text),contentFits:next.typography.fits)
                proposed.append((CGFloat(c.font),next));return measurement
            },surface:{ measurement,allowance in
                guard let next = proposed.last?.1 else { return false }
                return surfaceQuery(next,measurement.ink,color(palette.foreground.map { CGFloat($0) }),&allowance)
            }))
            guard let result,var committed = proposed.last(where: { Double($0.0) == result.candidate.font })?.1 else { continue }
            committed.artworkRecord = result.metadata
            if result.releasedPlate,let plateIndex {
                committed.sourcePanels.remove(at:plateIndex);committed.sourceBackgroundKind = "inpainted"
                committed.restoredSurfaceFontFit = true
                if let old = restoration.appearances[item.id] {
                    restoration.appearances[item.id] = .init(foreground:old.foreground,background:old.background,restored:true,
                        stroke:old.stroke,strokeWidth:old.strokeWidth,erasureComplete:true,letteringStyle:old.letteringStyle,
                        fontName:old.fontName,sourceStrokeWeight:old.sourceStrokeWeight,sourceSample:old.sourceSample,
                        restorationMethod:old.restorationMethod,sourceGlyphsVerified:old.sourceGlyphsVerified,
                        finalForcedErasure:old.finalForcedErasure,provisional:old.provisional)
                }
            }
            cards[index] = committed
        }
        return budget
    }
}
