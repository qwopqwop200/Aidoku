import CoreGraphics
import Foundation

extension NativeTranslationRenderer {
    /// The absolute DIV inherits white-space from its parent; the frozen
    /// producer writes only word-break:keep-all and overflow-wrap:normal.
    static func unitPartTypographyStyle(parent: NativeTranslationTypography.Style,
                                        font: CGFloat, pitch: CGFloat) -> NativeTranslationTypography.Style {
        var style = parent
        style.fontSize = font; style.lineHeight = pitch
        style.tracking = font * parent.tracking / parent.fontSize
        style.optimizesKoreanWrapping = false
        style.keepsWholeWords = false
        style.horizontalWrapping = .keepAll
        // These DIVs replace the former nowrap/preformatted SPAN tree.
        style.usesBlockWordLayout = false
        style.blockWordLayoutUsesTopPadding = false
        style.usesPreformattedBlockRows = false
        style.horizontalAlignment = .center; style.alignsToTop = false
        return style
    }

    static func splitBalloonUnitParts(cards:inout [Card],gloss:NativeTranslationEffectGloss.Refinement,
        layout:NativeTranslationLayout,restoration:NativeTranslationRestoration.Result,settings:IPhoneOverlaySettings,
        balloons:BalloonRelayoutContext) {
        guard settings.renderedBackgroundOpacity==1,layout.items.count<=256 else {return}
        let frame = restoration.cleanupGeometry?.frame ?? layout.sourceRect
        func visible(_ card:Card)->Bool {!gloss.hiddenIDs.contains(card.item.id) && !gloss.removedLayerIDs.contains(card.item.id)}
        func sourceRects(_ item:NativeTranslationLayoutItem)->[CGRect] {
            ((joinedUnitMembers(item) ?? [item.sourceBounds])+item.auxiliaryInkRects).compactMap {pageRect($0,frame:frame)}
        }
        for index in cards.indices {
            let original=cards[index],item=original.item
            guard visible(original),item.rotation==0,!item.vertical,original.effectiveTextRotation==0,
                original.unitTextParts.isEmpty,joinedUnitMembers(item) != nil,item.unitMemberRects.count==2,
                !restoration.unitResidueRiskIDs.contains(item.id),!item.text.isEmpty,
                !item.text.contains("\n"),!item.text.contains("\r"),original.style.fontSize>0 else {continue}
            let members=item.unitMemberRects.compactMap {pageRect($0,frame:frame)}
            guard members.count==2,let interior=balloons.interior(original,sources:sourceRects(item),unitCount:2) else {continue}
            let parent=original.captionParentPlate ? original.sourcePanels.lastIndex(where:{!$0.sourceErasure && !$0.rotated}):nil
            let isRoot=parent==nil
            let obstacles=layout.items.filter {$0.id != item.id}.flatMap(sourceRects)+cards.filter {$0.item.id != item.id && visible($0)}.map {cardInkRect($0)}
            let entry=NativeBalloonUnitParts.Entry(id:item.id,text:item.text,members:members,font:Double(original.style.fontSize),ratio:Double(original.style.lineHeight/original.style.fontSize),interiorSpan:Double(interior.width)/interior.scale,isRoot:isRoot,obstacles:obstacles,panel:parent.map {original.sourcePanels[$0].rect},coverage:parent.map {original.sourcePanels[$0].coverage} ?? [])
            func shaped(_ text:String,_ frame:CGRect,_ font:Double,_ pitch:Double)->TextPart {
                let style = unitPartTypographyStyle(parent: original.style,
                    font: CGFloat(font), pitch: CGFloat(pitch))
                let scale=style.horizontalScale,old=shiftedTextNodeRect(original),nodeBox=physicalTextNodeRect(original)
                func used(_ value:CGFloat)->CGFloat {(CGFloat(Float(value))*64).rounded(.towardZero)/64}
                // The div's left/top are assigned relative to the current DOM
                // node box. CSS rounds those relative values independently.
                let relativeX=used(frame.minX-nodeBox.minX),relativeY=used(frame.minY-nodeBox.minY)
                let transformed=CGRect(x:old.minX+scale*relativeX,y:old.minY+relativeY,
                    width:used(frame.width)*scale,height:used(frame.height))
                let typography=NativeTranslationTypography.layout(text:text,in:transformed.size,style:style)
                return .init(text:text,frame:transformed,typography:typography,style:style)
            }
            guard let result=NativeBalloonUnitParts.place(entry,measure:{text,frame,font,pitch in
                let part=shaped(text,frame,font,pitch)
                let lines=NativeTranslationTypography.captionLineMetrics(layout:part.typography).map {$0.rect.offsetBy(dx:part.frame.minX,dy:part.frame.minY)}
                let flow=NativeTranslationTypography.wordFlow(layout:part.typography,originalText:text)
                return .init(lines:lines,scrollWidth:Double(max(part.frame.width,part.typography.size.width)),clientWidth:Double(part.frame.width),splits:flow.wordSplits>0)
            },outside:interior.outside) else {continue}
            // The frozen producer replaces the old children before creating absolute DIVs.
            // Keep source/fixed-box history, but discard metadata describing the removed SPAN wrapper.
            cards[index].item.typesettingText=nil;cards[index].item.typesettingQuoteMode=nil
            cards[index].item.typesettingBlockDisplay=nil;cards[index].item.typesettingPreservedBlockWrapper=nil
            cards[index].item.typesettingPreformattedRows=nil
            cards[index].style.usesBlockWordLayout=false;cards[index].style.blockWordLayoutUsesTopPadding=false
            cards[index].style.usesPreformattedBlockRows=false
            cards[index].unitTextParts=result.parts.map {shaped($0.text,$0.frame,result.font,result.font*entry.ratio)}
            cards[index].unitTextPartsOrigin=item.rect.origin
            cards[index].textShift = .zero
            cards[index].unitParts=[result.originalFont,result.font,Double(result.firstUTF16Length)]
            cards[index].style.fontSize=CGFloat(result.font);cards[index].style.lineHeight=CGFloat(result.font*entry.ratio)
            cards[index].style.tracking=CGFloat(result.font)*original.style.tracking/original.style.fontSize
            cards[index].finalFontSize=CGFloat(result.font)
            if let parent,let panel=result.panel {
                cards[index].sourcePanels[parent].rect=panel;cards[index].sourcePanels[parent].coverage=result.coverage
                if cards[index].sourcePanels[parent].clipped {
                    cards[index].sourcePanels[parent].coverageClip = NativeCSSCoveragePath.declaration(coverage: result.coverage, origin: panel.origin, commands: .relative)
                }
            }
        }
    }
}
