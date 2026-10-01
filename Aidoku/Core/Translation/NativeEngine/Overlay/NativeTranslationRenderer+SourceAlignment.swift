import CoreGraphics
import Foundation

extension NativeTranslationRenderer {
    /// The frozen heading producer replaces wrapper/span children with one Text
    /// node. Its parent CSS display survives; child-only Range state does not.
    static func replaceSourceHeadingChildren(_ card: inout Card, text: String) {
        card.item.typesettingText = text
        card.item.typesettingQuoteMode = nil
        card.item.typesettingPreservedBlockWrapper = nil
        card.item.typesettingPreformattedRows = nil
        card.style.usesBlockWordLayout = false
        card.style.usesPreformattedBlockRows = false
        card.style.blockWordLayoutUsesTopPadding = false
        // Replacing children does not restore a retained block parent to flex.
        // A raw heading in that block starts at its existing top padding.
        if card.item.typesettingBlockDisplay == true {card.style.alignsToTop = true}
        card.lineOffsets = []
    }

    /// Preserve the node's current background mode independently of canvas
    /// completion and whether a source plate remains elsewhere on the page.
    static func sourceAlignmentEntry(card:Card,frame:CGRect,restoration:NativeTranslationRestoration.Result,
        gloss:NativeTranslationEffectGloss.Refinement) -> NativeTranslationSourceAlignment.Entry? {
        let item=card.item
        guard let bounds=pageRect(item.sourceBounds,frame:frame) else {return nil}
        let appearance=restoration.appearances[item.id],sample=appearance?.sourceSample ?? [:]
        var e=NativeTranslationSourceAlignment.Entry(id:item.id,text:item.text,renderedText:item.typesettingText ?? item.text,
            source:bounds,font:Double(card.finalFontSize),sourceFont:item.sourceFontSize.map(Double.init),
            lines:NativeTranslationTypography.captionLineMetrics(layout:card.typography).map {$0.rect.offsetBy(dx:card.textOrigin.x,dy:card.textOrigin.y)},ink:cardInkRect(card),nodeRect:item.rect)
        e.visible = !gloss.hiddenIDs.contains(item.id) && !gloss.removedLayerIDs.contains(item.id)
        e.sourceRotation=item.rotation != 0;e.horizontalWriting = !item.vertical;e.rtl=item.wrappingScript=="rightToLeft"
        e.transformNone=item.rotation==0;e.hasScale=card.style.horizontalScale != 1;e.sourceVertical=item.sourceVertical
        e.rotation=Double(item.rotation);e.automaticRecovery=item.allowsAutomaticFontRecovery
        e.children=item.typesettingText?.contains("\n") == true ? .blockSpans:.plain
        e.wrap=card.style.balancesHorizontalLines ? "balance":"wrap"
        e.backgroundKind=card.sourceBackgroundKind ?? ""
        e.isRoot=card.sourcePanels.allSatisfy(\.sourceErasure);e.paintsBackground=card.drawsPanel;e.hasBackgroundImage=card.drawsPanel && card.usesFallbackVeil
        e.sampledForeground=sample["foreground"] as? [Double];e.sampledBackground=sample["background"] as? [Double]
        e.sourcePanelCoverage=card.sourcePanels.last?.coverage
        return e
    }

    /// Read the original page before late unit stacking. The retained inner flow
    /// width and per-line offsets survive subsequent outline-only reshaping.
    static func applySourceAlignment(cards: inout [Card], gloss: NativeTranslationEffectGloss.Refinement, layout: NativeTranslationLayout,
        restoration: NativeTranslationRestoration.Result, settings: IPhoneOverlaySettings, source: CGImage?) {
        guard let source, cards.count <= 256 else { return }
        let frame = restoration.cleanupGeometry?.frame ?? layout.sourceRect
        let snapshot=cards
        let entries=cards.compactMap { sourceAlignmentEntry(card:$0,frame:frame,restoration:restoration,gloss:gloss) }
        let plates=cards.filter { !gloss.hiddenIDs.contains($0.item.id) && !gloss.removedLayerIDs.contains($0.item.id) }.flatMap {card in card.sourcePanels.map {panel in
            NativeTranslationSourceAlignment.Plate(rect:panel.rect,coverage:panel.coverage,parent:!panel.sourceErasure,ownerID:card.item.id)
        } + card.backings.map {backing in .init(rect:backing.frame,coverage:backing.coverage,parent:false,ownerID:card.item.id)} }
        func shaped(_ e:NativeTranslationSourceAlignment.Entry,_ text:String,_ wrap:String,_ width:CGFloat?,left:Bool,explicit:Bool)
            -> (NativeTranslationTypography.Style,NativeTranslationTypography.Layout,CGPoint)? {
            guard var card=snapshot.first(where:{$0.item.id==e.id}) else {return nil}
            if explicit {replaceSourceHeadingChildren(&card,text:text)}
            var style=card.style
            style.optimizesKoreanWrapping=false;style.keepsWholeWords=false
            style.horizontalAlignment=left ? .left:.center
            style.balancesHorizontalLines=wrap=="balance" && card.item.wrappingScript=="korean"
            style.balancesExplicitParagraphs=explicit && wrap=="balance"
            let size=CGSize(width:width ?? card.textLayoutSize.width,height:card.textLayoutSize.height)
            let measured=NativeTranslationTypography.layout(text:text,in:size,style:style)
            let origin=CGPoint(x:card.textOrigin.x+(width.map {(card.textLayoutSize.width-$0)/2} ?? 0),y:card.textOrigin.y)
            return (style,measured,origin)
        }
        func committed(_ e:NativeTranslationSourceAlignment.Entry,_ original:Card)->Card? {
            var card=original
            let heading=e.heading=="label" || e.heading=="sentence"
            if heading {replaceSourceHeadingChildren(&card,text:e.renderedText)}
            card.item.width=e.nodeRect.width;card.item.height=e.nodeRect.height
            if let width=e.wrapperWidth {card.typographyWidth=width;card.style.horizontalAlignment = .left;card.lineOffsets=[]}
            card.style.balancesHorizontalLines=e.wrap=="balance";card.style.optimizesKoreanWrapping=false
            card.style.balancesExplicitParagraphs=heading && e.wrap=="balance"
            if let offsets=e.lineOffsets,e.wrapperWidth==nil {card.lineOffsets=offsets.map {CGPoint(x:$0,y:0)}}
            let measured=remeasureTypography(card),local=measured.rangeBounds.reduce(CGRect.null) {$0.union($1)}
            guard !local.isNull else {return nil}
            card.typography=measured
            card.textShift=CGPoint(x:e.ink.minX-local.minX-card.item.contentRect.minX,y:e.ink.minY-local.minY-card.item.contentRect.minY)
            return card
        }
        let result=NativeTranslationSourceAlignment.apply(entries,frame:frame,sourcePixelWidth:source.width,
            plates:plates,reader:{rect,w,h in sampleSource(source,rect:rect,frame:frame,width:w,height:h)},shape:{e,request in
                guard let (_,measured,origin)=shaped(e,request.text,request.wrap,request.width,left:request.mode == .flushPlain,explicit:request.mode == .heading || e.heading=="label" || e.heading=="sentence") else {return nil}
                let lineRects=NativeTranslationTypography.captionLineMetrics(layout:measured).map {$0.rect.offsetBy(dx:origin.x,dy:origin.y)}
                let ink=measured.rangeBounds.reduce(CGRect.null) {$0.union($1)}.offsetBy(dx:origin.x,dy:origin.y)
                guard !ink.isNull else {return nil}
                let labels=measured.lineRanges.filter {NSIntersectionRange($0,NSRange(location:0,length:request.headUTF16Length)).length>0}.count
                return .init(lines:lineRects,ink:ink,nodeRect:e.nodeRect,scrollSize:CGSize(width:max(e.nodeRect.width,measured.size.width+(snapshot.first(where:{$0.item.id==e.id}).map {$0.item.paddingLeft+$0.item.paddingRight} ?? 0)),
                    height:max(e.nodeRect.height,measured.size.height+(snapshot.first(where:{$0.item.id==e.id}).map {$0.item.paddingTop+$0.item.paddingBottom} ?? 0))),clientSize:e.nodeRect.size,labelRows:labels)
            },holdsSurface:{entry in
                guard let original=snapshot.first(where:{$0.item.id==entry.id}),let proposed=committed(entry,original) else {return false}
                var item=proposed.item
                item.x+=proposed.textShift.x;item.y+=proposed.textShift.y
                return NativeTypographyPostPolish.holdsSurface(item:item,typography:proposed.typography,
                    restoration:restoration,settings:settings,layout:layout,foreground:proposed.style.foreground)
            })
        for e in result.entries {
            guard let index=cards.firstIndex(where:{$0.item.id==e.id}) else {continue}
            cards[index].sourceHeading=e.heading;cards[index].sourceAlignment=e.alignment
            let heading=e.heading=="label" || e.heading=="sentence"
            guard heading || e.wrapperWidth != nil || e.lineOffsets != nil || e.edgeShift != nil else {continue}
            guard var committed=committed(e,cards[index]) else {continue}
            committed.sourceHeading=e.heading;committed.sourceAlignment=e.alignment
            cards[index]=committed
        }
    }
}
