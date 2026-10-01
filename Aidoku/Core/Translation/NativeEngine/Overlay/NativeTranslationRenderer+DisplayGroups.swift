import CoreGraphics
import Foundation

extension NativeTranslationRenderer {
    /// Share translated lines across the actual detached, rotated source plates.
    /// The original plates retain their own frame and angle after the text moves.
    static func applyDisplayGroups(cards: inout [Card], gloss: NativeTranslationEffectGloss.Refinement,
                                   layout: NativeTranslationLayout, settings: IPhoneOverlaySettings) {
        guard settings.renderedBackgroundOpacity == 1, layout.items.count <= 256 else { return }
        let snapshot=cards
        var cells:[NativeTranslationDisplayGroups.Cell]=[]
        func visible(_ card:Card)->Bool { !gloss.hiddenIDs.contains(card.item.id) && !gloss.removedLayerIDs.contains(card.item.id) }
        for card in snapshot {
            let item=card.item
            guard visible(card), item.rotation != 0, item.sourceVertical, !item.vertical,
                  !item.text.isEmpty, item.text.utf16.count<=60,
                  item.wrappingScript=="korean" || item.wrappingScript=="word",
                  item.typesettingText == nil || item.typesettingText == item.text,
                  card.lineOffsets.isEmpty, card.typographyWidth == nil else { continue }
            let plate:CGRect,channels:[Double]
            if card.rotatesSourcePanels, let panel=card.sourcePanels.last(where:{!$0.sourceErasure}) {
                plate=panel.rect;channels=Array(panel.background.prefix(3))
            } else if card.drawsPanel, let background=rgb(card.background) {
                plate=card.sourcePlateRect;channels=background
            } else {continue}
            guard plate.width>0,plate.height>0,channels.count==3 else {continue}
            // The page reader may normalize the image independently of the
            // original OCR frame retained on the item.
            let frame=card.cleanupSourceFrame ?? CGRect(x:item.sourceFrame[0],y:item.sourceFrame[1],
                width:item.sourceFrame[2],height:item.sourceFrame[3])
            let glyph=item.sourceFontSize.flatMap {$0.isFinite && $0>0 ? Double($0):nil}
                ?? min(item.sourceBounds.count>=4 ? Double(item.sourceBounds[2]*frame.width):0,
                       item.sourceBounds.count>=4 ? Double(item.sourceBounds[3]*frame.height):0)
            guard glyph>=24, card.finalFontSize>0 else {continue}
            let physical=rotatedBounds(plate,about:card.sourcePlateRect,angle:item.rotation)
            cells.append(.init(id:item.id,text:item.text,glyph:glyph,font:Double(card.finalFontSize),color:channels,
                width:Double(plate.width),height:Double(plate.height),angle:Double(item.rotation),
                center:CGPoint(x:physical.midX,y:physical.midY)))
        }
        guard cells.count>=2 else {return}
        var foreign:[String:CGRect]=[:]
        for card in snapshot where visible(card) {foreign[card.item.id]=cardPageLineRects(card).reduce(CGRect.null) {$0.union($1)}}
        func shaped(_ original:Card,_ font:Double,_ width:Double,_ pitch:Double,_ pad:Double)
            -> (Card,NativeTranslationDisplayGroups.Measurement)? {
            var candidate=original
            let scale=original.style.horizontalScale
            candidate.item.width=CGFloat(width);candidate.item.height=CGFloat(pitch*Double(original.item.text.utf16.count+2))
            candidate.item.paddingTop=0;candidate.item.paddingBottom=0
            candidate.item.paddingLeft=CGFloat(pad);candidate.item.paddingRight=CGFloat(pad)
            candidate.item=usedScaledTextItem(candidate.item,scale:scale)
            candidate.typographyWidth=nil;candidate.lineOffsets=[];candidate.textShift = .zero
            candidate.style.fontSize=CGFloat(font);candidate.style.lineHeight=CGFloat(pitch)
            candidate.style.optimizesKoreanWrapping=false;candidate.style.horizontalWhitespace = .normal; candidate.style.horizontalWrapping = .keepAll; candidate.style.keepsWholeWords=false
            candidate.style.horizontalAlignment = .center;candidate.style.alignsToTop=true
            candidate.typography=remeasureTypography(candidate,text:original.item.text)
            let count=candidate.typography.lineCount
            guard count>0 else {return nil}
            let height=(CGFloat(pitch)*64).rounded(.towardZero)/64*CGFloat(count)
            candidate.item.height=height
            candidate.typography=remeasureTypography(candidate,text:original.item.text)
            let lines=NativeTranslationTypography.captionLineMetrics(layout:candidate.typography).map {
                $0.rect.offsetBy(dx:candidate.item.paddingLeft,dy:0)
            }
            let widest=lines.map(\.maxX).max() ?? 0
            let scroll=max(candidate.item.width,widest+candidate.item.paddingRight)/scale
            return (candidate,.init(size:candidate.item.rect.size,lines:lines,scrollWidth:Double(scroll),clientWidth:Double(candidate.item.width/scale)))
        }
        let result=NativeTranslationDisplayGroups.arrange(cells,foreign:foreign) {cell,font,width,pitch,pad in
            guard let original=snapshot.first(where:{$0.item.id==cell.id}) else {return nil}
            return shaped(original,font,width,pitch,pad)?.1
        }
        for placement in result.placements {
            guard let index=cards.firstIndex(where:{$0.item.id==placement.id}),
                  let original=snapshot.first(where:{$0.item.id==placement.id}),
                  var candidate=shaped(original,placement.font,Double(placement.rect.width),placement.pitch,placement.padding)?.0 else {continue}
            candidate.sourcePlateOwnerRect=original.sourcePlateRect
            candidate.item.x=placement.rect.minX;candidate.item.y=placement.rect.minY
            candidate.item.width=placement.rect.width;candidate.item.height=placement.rect.height
            candidate.item.paddingLeft=CGFloat(placement.padding);candidate.item.paddingRight=CGFloat(placement.padding)
            candidate.item=usedScaledTextItem(candidate.item,scale:candidate.style.horizontalScale)
            candidate.item.fontSize=CGFloat(placement.font);candidate.item.lineHeight=CGFloat(placement.pitch)
            candidate.textRotation=CGFloat(placement.angle);candidate.finalFontSize=CGFloat(placement.font)
            candidate.typography=remeasureTypography(candidate,text:original.item.text)
            candidate.displayGroup=["members":placement.members,"order":placement.order,"from":placement.originalFont,"size":placement.font]
            cards[index]=candidate
        }
    }
}
