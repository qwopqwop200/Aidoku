import CoreGraphics
import Foundation

extension NativeTranslationRenderer {
    static func snapTypographyCohorts(cards:inout [Card], restoration:NativeTranslationRestoration.Result,
        layout:NativeTranslationLayout, growthSession:NativeTypographyPostPolish.RendererGrowthSession,
        plateSession:PlateGrowthSession?, rowGroups:[[String]], originalFonts:[String:CGFloat],
        beforeCondensed:[String:Card], hiddenIDs:Set<String>, removedIDs:Set<String>, lockedIDs:Set<String>,
        ownerOf:(Card,[Card])->TypographyHarmonyOwner?) {
        func pageItem(_ card:Card)->NativeTranslationLayoutItem {
            var item=card.item;item.x+=card.textShift.x;item.y+=card.textShift.y
            item.fontSize=card.finalFontSize;item.lineHeight=card.style.lineHeight
            return item
        }
        func source(_ card:Card)->CGRect? {
            let item=card.item
            let frame=restoration.cleanupGeometry?.frame ?? CGRect(x:item.sourceFrame[0],y:item.sourceFrame[1],
                width:item.sourceFrame[2],height:item.sourceFrame[3])
            return pageRect(item.sourceBounds,frame:frame)
        }
        func glyph(_ card:Card)->CGFloat {
            if let g=card.item.sourceFontSize,g.isFinite,g>0 { return g }
            guard let rect=source(card) else { return .nan }
            return min(rect.width,rect.height)
        }
        let restoredRecords=Dictionary(growthSession.records(items:cards.map(pageItem)).map { ($0.id,$0) },uniquingKeysWith:{a,_ in a})
        let platePeers=plateSession?.snapshot?.readablePeers ?? [:]
        let members=cards.map { card->NativeTypographyCohortSnap.Member in
            let item=card.item
            let frame=restoration.cleanupGeometry?.frame ?? CGRect(x:item.sourceFrame[0],y:item.sourceFrame[1],
                width:item.sourceFrame[2],height:item.sourceFrame[3])
            let sample=restoration.appearances[item.id]?.sourceSample ?? [:]
            var bases:[CGFloat]=[]
            if let record=restoredRecords[item.id] {bases.append(record.base)}
            if let record=card.plateGrowthRecord,record["grew"] is NSNumber {
                if let entering=record["entering"] as? [String:Any],let font=entering["font"] as? NSNumber {bases.append(CGFloat(font.doubleValue))}
            }
            if let original=originalFonts[item.id],abs(card.finalFontSize-original)>0.01 {bases.append(original)}
            let metadata=card.sourceRestorationMetadata
            let readable=platePeers[item.id].map {CGFloat($0)} ?? growthSession.context.growth.readablePeer[item.id]
            let prior=beforeCondensed[item.id]
            let condensedFrom=(card.style.horizontalScale != 1 && prior?.style.horizontalScale == 1) ? prior?.finalFontSize:nil
            let applied=card.sourcePanels.last(where:{!$0.sourceErasure})?.background ?? (card.drawsPanel ? rgb(card.background):nil)
            let captured=NativeTypographyCohortSnap.capture(.init(id:item.id,text:item.text,
                bounds:item.sourceBounds,frame:[frame.minX,frame.minY,frame.width,frame.height],glyph:glyph(card),
                font:card.finalFontSize,vertical:item.sourceVertical,rotation:item.rotation != 0,
                nearRotation:(item.nearUprightRotation ?? 0) != 0,sourceRotation:metadata["sourceRotation"] != nil,
                hidden:hiddenIDs.contains(item.id),automatic:item.allowsAutomaticFontRecovery,
                displayGrowth:card.typographyDisplayGrowth != nil || item.typesettingDisplayGrowth != nil,
                rotatingPanel:card.rotatesSourcePanels,sampledInk:NativeSourceColorSampler.rgb(sample["foreground"]),
                sampledBackground:NativeSourceColorSampler.rgb(sample["background"]),appliedBackground:applied,
                outlined:card.style.outline != nil,growthFonts:bases,readablePeer:readable,condensedFrom:condensedFrom))
            if var captured { captured.captured = !lockedIDs.contains(item.id);return captured }
            // Harmony row peers remain observable even when this node is
            // outside the snap capture; they cannot disappear from row spread.
            return .init(id:item.id,source:source(card) ?? .zero,vertical:item.sourceVertical,glyph:glyph(card),
                line:glyph(card),font:card.finalFontSize,base:.infinity,readablePeer:.infinity,readableHeld:0,
                condensedFrom:nil,key:"",captured:false)
        }
        let byID=Dictionary(cards.indices.map {(cards[$0].item.id,$0)},uniquingKeysWith:{a,_ in a})
        let rows=rowGroups.map {$0.compactMap {byID[$0]}}
        func spread(_ values:[CGFloat])->CGFloat {(values.max() ?? 0)/(values.min() ?? 0)}
        func inconsistent()->Int {
            var count=0
            for i in cards.indices where !hiddenIDs.contains(cards[i].item.id) {
                guard members[i].glyph>0,members[i].source.width>0,members[i].source.height>0 else {continue}
                for j in cards.indices where j>i && !hiddenIDs.contains(cards[j].item.id) {
                    let a=members[i],b=members[j]
                    guard b.glyph>0,b.source.width>0,b.source.height>0 else {continue}
                    if spread([a.glyph,b.glyph])>1.15 && spread([a.source.width,b.source.width])>1.15 && spread([a.source.height,b.source.height])>1.15 {continue}
                    if spread([cards[i].finalFontSize,cards[j].finalFontSize])>1.25 {count+=1}
                }
            }
            return count
        }
        func clearance(_ i:Int)->CGFloat {
            guard let ink=cardWholeRangeRect(cards[i]) else {return .infinity}
            let boxes=cards.indices.filter {$0 != i && !hiddenIDs.contains(cards[$0].item.id)}.compactMap {cardWholeRangeRect(cards[$0])}
            return boxes.map {other in
                max(ink.minX-other.maxX,other.minX-ink.maxX,ink.minY-other.maxY,other.minY-ink.maxY)
            }.min() ?? .infinity
        }
        let result=NativeTypographyCohortSnap.snap(members:members,rowGroups:rows,font:{cards[$0].finalFontSize},
            clearance:clearance,inconsistent:inconsistent,snapshot:{cards[$0]},restore:{cards[$0]=$1},scale:{i,size in
                let original=cards[i],owner=ownerOf(original,cards)
                guard let proposed=scaleTypographyHarmony(original,size:size,peers:cards,
                    frame:restoration.cleanupGeometry?.frame,owner:owner,hiddenIDs:hiddenIDs,removedIDs:removedIDs,
                    surfaceFits:{candidate in growthSession.holdsSurface(item:pageItem(candidate),typography:candidate.typography,
                        foreground:candidate.style.foreground)}) else {return false}
                cards[i]=proposed;return true
            })
        for (i,fonts) in result.changed {cards[i].harmonyRecord["cohortSnap"]=fonts.map(Double.init)}
        for (i,fonts) in result.held {cards[i].harmonyRecord["cohortSnapHeld"]=fonts.map(Double.init)}
        repairLateTypographyWords(cards:&cards,members:members,harmonyRows:rows,sourceRows:result.sourceRows,
            restoration:restoration,layout:layout,growthSession:growthSession,hiddenIDs:hiddenIDs,removedIDs:removedIDs)
    }
}
