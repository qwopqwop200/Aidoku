import CoreGraphics
import Foundation

extension NativeTranslationRenderer {
    static func containJoinedBalloonUnits(cards: inout [Card], gloss: NativeTranslationEffectGloss.Refinement,
        layout: NativeTranslationLayout, restoration: NativeTranslationRestoration.Result,
        settings: IPhoneOverlaySettings, balloons: BalloonRelayoutContext) {
        let frame = restoration.cleanupGeometry?.frame ?? layout.sourceRect
        guard settings.renderedBackgroundOpacity == 1, layout.items.count <= 256 else { return }
        func withoutSpace(_ text:String)->String {String(text.unicodeScalars.filter{!CharacterSet.whitespacesAndNewlines.contains($0)})}
        for i in cards.indices {
            let card=cards[i],item=card.item
            guard let members=joinedUnitMembers(item),!restoration.unitResidueRiskIDs.contains(item.id),
                  item.rotation==0,!item.vertical,card.effectiveTextRotation==0,card.style.horizontalScale==1,
                  !gloss.hiddenIDs.contains(item.id),!gloss.removedLayerIDs.contains(item.id),
                  !item.text.isEmpty,!item.text.contains("\n"),!item.text.contains("\r"),
                  withoutSpace(item.text)==withoutSpace(item.typesettingText ?? item.text) else {continue}
            let sources=(members+item.auxiliaryInkRects).compactMap{pageRect($0,frame:frame)}
            guard let interior=balloons.interior(card,sources:sources,unitCount:members.count),
                  let source=pageRect(item.sourceBounds,frame:frame) else {continue}
            let parentIndex=card.captionParentPlate ? card.sourcePanels.lastIndex(where:{!$0.sourceErasure}):nil
            let parent=parentIndex.map{card.sourcePanels[$0].rect}
            var centres:[CGPoint]=[]
            if interior.native,let center=item.balloonInterior?.center,center.count==2 {
                centres.append(CGPoint(x:frame.minX+center[0]*frame.width,
                    y:frame.minY+center[1]*frame.height))
            }
            centres.append(CGPoint(x:source.midX,y:source.midY))
            let patch=restoration.patches.last(where:{$0.itemID==item.id && !$0.independentArtworkCover}),candidate=patch?.candidate
            let canGrow=parent==nil && (candidate?.erasureComplete ?? restoration.appearances[item.id]?.erasureComplete ?? false) &&
                (candidate?.sourceGlyphsVerified ?? restoration.appearances[item.id]?.sourceGlyphsVerified ?? false) &&
                !(candidate?.provisional ?? true) && !(candidate?.partialErasureCertified ?? false)
            let otherSources=layout.items.filter{$0.id != item.id}.flatMap{other in
                ((joinedUnitMembers(other) ?? [other.sourceBounds])+other.auxiliaryInkRects).compactMap{pageRect($0,frame:frame)}
            }
            let otherInk=cards.indices.filter{$0 != i && !gloss.hiddenIDs.contains(cards[$0].item.id)}.map{cardInkRect(cards[$0])}.filter(valid)
            let input=NativeJoinedUnitContainment.Input(font:Double(card.style.fontSize),pitch:Double(card.style.lineHeight),
                lines:cardPageLineRects(card),parentPlate:parent,span:Double(interior.width)/interior.scale,
                centres:centres,canGrow:canGrow,sourceFont:item.sourceFontSize.map{Double($0)},obstacles:otherSources+otherInk)
            let result=NativeJoinedUnitContainment.contain(input,outside:interior.outside) { proposal in
                let shaped=balloons.shape(card,rect:proposal.rect,font:proposal.font,pitch:proposal.pitch)
                let flow=NativeTranslationTypography.wordFlow(layout:shaped.typography,originalText:item.text)
                return .init(lines:cardPageLineRects(shaped),widthFits:shaped.typography.size.width<=shaped.textLayoutSize.width+1,
                    splitsWord:flow.wordSplits>0)
            }
            guard result.searched else {continue}
            guard let accepted=result.candidate else {
                cards[i].unitContainment=["kept",result.before.rounded()];continue
            }
            var committed=balloons.shape(card,rect:accepted.rect,font:accepted.font,pitch:accepted.pitch)
            committed.unitContainment=[result.before.rounded(),input.font,accepted.font]+(result.partial ? [result.after?.rounded() ?? 0]:[])
            if let parentIndex {
                let final=cardPageLineRects(committed).reduce(CGRect.null){$0.union($1)}
                guard valid(final) else {continue}
                let pad=max(3,min(6,CGFloat(accepted.font)*0.3)),footprint=final.insetBy(dx:-pad,dy:-pad)
                var panel=card.sourcePanels[parentIndex]
                let coverage=panel.coverage.isEmpty ? [panel.rect]:panel.coverage
                let authored = panel.rect.union(footprint)
                panel.rect=usedRect(authored);panel.coverage=coverage+[footprint]
                if panel.clipped { panel.coverageClip = NativeCSSCoveragePath.declaration(coverage: panel.coverage, origin: authored.origin, commands: .relative) }
                panel.captionUnionClipped=true
                committed.sourcePanels[parentIndex]=panel
            }
            cards[i]=committed
        }
    }
}
