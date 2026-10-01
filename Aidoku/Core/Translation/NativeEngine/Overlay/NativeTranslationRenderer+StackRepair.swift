import CoreGraphics
import Foundation
import UIKit

extension NativeTranslationRenderer {
    /// The same predicate list is used for search and the frozen11936 guard.
    /// Ordinary own plates always add a rectangle, even with clip-path:none.
    static func stackClipConstraints(own: [(rect: CGRect, sourceRotated: Bool)],
                                     parent: NativeTranslationSourceStylePostPolish.Panel?) -> [(CGPoint) -> Bool] {
        var clips: [(CGPoint) -> Bool] = []
        if let parent, parent.clipped {
            let coverage = parent.coverage
            clips.append { point in coverage.contains { $0.contains(point) } }
        }
        for plate in own where !plate.sourceRotated {
            let rect = plate.rect.insetBy(dx: -0.5, dy: -0.5)
            clips.append { point in
                point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
            }
        }
        return clips
    }

    /// Accepted Stack spans inherit their connected plate's CSS overflow.
    /// The frozen11936 writer runs only after verification and uses the actual
    /// parent identity; the owner's own overflow:hidden is not an ancestor clip.
    @discardableResult
    static func releaseStackParentOverflow(cards: inout [Card], index: Int, hasClipConstraints: Bool) -> Bool {
        guard !hasClipConstraints, cards.indices.contains(index), cards[index].captionParentPlate,
              let owner = cards[index].captionParentOwner,
              cards.indices.contains(owner.cardIndex) else { return false }
        if owner.panelIndex == -1 {
            guard var panel = cards[owner.cardIndex].glyphCoverOwnerPanel,
                  !panel.clipped else { return false }
            panel.overflowClip = false
            cards[owner.cardIndex].glyphCoverOwnerPanel = panel
        } else {
            guard cards[owner.cardIndex].sourcePanels.indices.contains(owner.panelIndex),
                  !cards[owner.cardIndex].sourcePanels[owner.panelIndex].sourceErasure,
                  !cards[owner.cardIndex].sourcePanels[owner.panelIndex].clipped else { return false }
            cards[owner.cardIndex].sourcePanels[owner.panelIndex].overflowClip = false
        }
        return true
    }

    static func stackRows(_ card:Card,text:String)->[NativeKoreanStackRepair.Row] {
        var originals:[(Unicode.Scalar,Int)]=[],at=0
        for scalar in text.unicodeScalars {if !CharacterSet.whitespacesAndNewlines.contains(scalar) {originals.append((scalar,at))};at+=scalar.utf16.count}
        let painted=card.typography.shapedText.unicodeScalars.filter {!CharacterSet.whitespacesAndNewlines.contains($0)}
        guard painted.count==card.typography.rangeBounds.count else {return []}
        var groups:[[(Int,String,CGRect)]]=[],tops:[CGFloat]=[],cursor=0
        for (scalar,local) in zip(painted,card.typography.rangeBounds) where !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            guard cursor<originals.count,originals[cursor].0==scalar else {return []}
            let sourceAt=originals[cursor].1;cursor+=1
            guard local.width>0,local.height>0 else {continue}
            let rect=local.offsetBy(dx:card.textOrigin.x-card.item.rect.midX-card.textShift.x,dy:card.textOrigin.y-card.item.rect.midY-card.textShift.y)
            let index=tops.firstIndex(where:{abs($0-rect.minY)<card.style.fontSize*0.5}) ?? tops.count
            if index==tops.count {tops.append(rect.minY);groups.append([])}
            groups[index].append((sourceAt,String(scalar),rect))
        }
        return groups.map {values in let box=values.map(\.2).reduce(CGRect.null) {$0.union($1)}
            return .init(first:values.first!.0,last:values.last!.0,chars:values.map(\.1).joined(),rect:box)
        }.sorted {$0.first<$1.first}
    }

    static func repairKoreanStacks(cards:inout [Card],gloss:NativeTranslationEffectGloss.Refinement,
        layout:NativeTranslationLayout,restoration:NativeTranslationRestoration.Result,source:CGImage?,settings:IPhoneOverlaySettings) {
        let frame = restoration.cleanupGeometry?.frame ?? layout.sourceRect
        guard let source,valid(frame) else {return}
        let session=NativeKoreanStackRepair.Session()
        var declined=Set<String>()
        func visible(_ card:Card)->Bool {!gloss.hiddenIDs.contains(card.item.id) && !gloss.removedLayerIDs.contains(card.item.id)}
        struct Plate {let owner:String;let polygon:[[Double]];let frame:CGRect;let color:[Double];let rotated:Bool;let panel:NativeTranslationSourceStylePostPolish.Panel?;var opaque=true;var parent:CaptionParentOwner?}
        func polygon(_ rect:CGRect,_ owner:CGRect,_ angle:CGFloat)->[[Double]] {
            let c=cos(angle),s=sin(angle)
            return [CGPoint(x:rect.minX,y:rect.minY),CGPoint(x:rect.maxX,y:rect.minY),CGPoint(x:rect.maxX,y:rect.maxY),CGPoint(x:rect.minX,y:rect.maxY)].map {p in
                let dx=p.x-owner.midX,dy=p.y-owner.midY
                return [Double(owner.midX+dx*c-dy*s),Double(owner.midY+dx*s+dy*c)]
            }
        }
        func plates(_ snapshot:[Card])->[Plate] {snapshot.enumerated().filter {visible($0.element)}.flatMap {index, card -> [Plate] in
            var result=card.sourcePanels.indices.filter {!card.sourcePanels[$0].sourceErasure}.map {panelIndex in
                let p=card.sourcePanels[panelIndex]
                return Plate(owner:card.item.id,polygon:polygon(p.rect,card.sourcePlateRect,card.rotatesSourcePanels ? card.item.rotation:0),frame:p.rect,color:Array(p.background.prefix(3)),rotated:card.rotatesSourcePanels,panel:p,parent:.init(cardIndex:index,panelIndex:panelIndex))
            }
            if let p=card.glyphCoverOwnerPanel {
                result.append(.init(owner:card.item.id,polygon:polygon(p.rect,card.sourcePlateRect,p.rotated ? card.item.rotation:0),frame:p.rect,color:Array(p.background.prefix(3)),rotated:p.rotated,panel:p,opaque:false,parent:.init(cardIndex:index,panelIndex:-1)))
            }
            result+=card.backings.map {p in .init(owner:card.item.id,polygon:polygon(p.frame,p.frame,0),frame:p.frame,color:Array(p.color.prefix(3)),rotated:false,panel:nil)}
            if card.drawsPanel,card.item.rotation != 0,let rgb=rgb(card.background) {result.append(.init(owner:card.item.id,polygon:polygon(card.sourcePlateRect,card.sourcePlateRect,card.item.rotation),frame:card.sourcePlateRect,color:rgb,rotated:card.item.rotation != 0,panel:nil,opaque:settings.renderedBackgroundOpacity==1))}
            return result
        }}
        func shaped(_ original:Card,_ proposal:NativeKoreanStackRepair.Candidate)->Card {
            var card=original
            card.sourcePlateOwnerRect=original.sourcePlateRect
            let angle=original.effectiveTextRotation,c=cos(angle),s=sin(angle),px=proposal.offset.x*c-proposal.offset.y*s,py=proposal.offset.x*s+proposal.offset.y*c
            let movedNode=shiftedTextNodeRect(original)
            card.item.x=movedNode.midX-CGFloat(proposal.width)/2+px
            card.item.y=movedNode.midY-CGFloat(proposal.height)/2+py
            card.item.width=CGFloat(proposal.width);card.item.height=CGFloat(proposal.height)
            card.item.paddingTop=0;card.item.paddingRight=0;card.item.paddingBottom=0;card.item.paddingLeft=0
            card.item.typesettingText=proposal.lines.joined(separator:"\n");card.item.typesettingQuoteMode=nil
            card.item.typesettingPreservedBlockWrapper=nil;card.item.typesettingBlockDisplay=true
            card.item.typesettingPreformattedRows=true
            card.style.usesBlockWordLayout=false;card.style.usesPreformattedBlockRows=true
            card.style.blockWordLayoutUsesTopPadding=true
            card.item.fontSize=CGFloat(proposal.font);card.item.lineHeight=CGFloat(proposal.pitch)
            card.typographyWidth=nil;card.lineOffsets=[];card.textShift = .zero
            card.style.fontSize=CGFloat(proposal.font);card.style.lineHeight=CGFloat(proposal.pitch)
            card.style.tracking=CGFloat(proposal.font)*original.style.tracking/original.style.fontSize
            card.style.horizontalScale=CGFloat(proposal.condense);card.style.horizontalAlignment = .center
            card.style.optimizesKoreanWrapping=false;card.style.balancesHorizontalLines=false;card.style.balancesExplicitParagraphs=false
            card.style.keepsWholeWords=false;card.style.alignsToTop=true
            card.item=usedScaledTextItem(card.item,scale:CGFloat(proposal.condense));card.typography=remeasureTypography(card)
            // max-content spans may paint beyond the provisional width. CSS
            // grows the unscaled layout box by offsetWidth+2 and keeps its centre.
            let widest=NativeTranslationTypography.captionLineMetrics(layout:card.typography).map {ceil($0.rect.width/CGFloat(proposal.condense))}.max() ?? 0
            if widest>card.item.width/CGFloat(proposal.condense)-1 {
                let oldWidth=card.item.width/CGFloat(proposal.condense),grown=widest+2
                card.item.x -= (oldWidth-card.item.width)/2+(grown-oldWidth)/2
                card.item.width=grown
                card.item=usedScaledTextItem(card.item,scale:CGFloat(proposal.condense));card.typography=remeasureTypography(card)
            }
            card.finalFontSize=CGFloat(proposal.font)
            return card
        }
        for round in 0..<2 {
            var count=0
            let ids=cards.filter {visible($0) && (round==0 || declined.contains($0.item.id))}.map { $0.item.id }
            for id in ids {
                if session.tries<=0 || session.samples<=0 {break}
                declined.remove(id)
                guard let index=cards.firstIndex(where:{$0.item.id==id}) else {continue}
                let original=cards[index],item=original.item
                guard !item.vertical,(item.wrappingScript=="korean" || item.fontScript=="korean"),
                    item.allowsAutomaticFontRecovery || item.rotation != 0,
                    original.typographyWidth==nil,original.unitTextParts.isEmpty else {continue}
                let text=item.text
                guard original.sourceHeading != "label", original.sourceHeading != "sentence" else { continue }
                if let shapedText=item.typesettingText {
                    let raw=shapedText.replacingOccurrences(of:"\n",with:"")
                    guard raw.split(whereSeparator:\.isWhitespace).joined(separator:" ")==text.split(whereSeparator:\.isWhitespace).joined(separator:" ") else {continue}
                }
                guard !text.isEmpty,text.utf16.count<=80,!text.contains("\n"),!text.contains("\r") else {continue}
                let rows=stackRows(original,text:text)
                guard !rows.isEmpty else {continue}
                let allPlates=plates(cards)
                let parentIdentity=original.captionParentPlate ? original.captionParentOwner:nil
                let ownIndices=Set(allPlates.indices.filter {allPlates[$0].owner==id || (parentIdentity != nil && allPlates[$0].parent==parentIdentity)})
                let own=allPlates.indices.filter {ownIndices.contains($0)}.map {allPlates[$0]}
                let foreign=allPlates.indices.filter {!ownIndices.contains($0)}.map {allPlates[$0]}
                let parent=parentIdentity.flatMap {identity in allPlates.first {$0.parent==identity}?.panel}
                let clipTests=stackClipConstraints(own:own.map {(rect:$0.frame,sourceRotated:$0.rotated)},parent:parent)
                let oldInk=cardInkRect(original)
                var kept:[CGRect]=[]
                for p in own where !p.rotated {kept.append(oldInk);if let source=pageRect(item.sourceBounds,frame:frame) {kept.append(source)}}
                var obstacles=foreign.map(\.polygon)
                for other in cards where other.item.id != id && visible(other) {obstacles+=cardPageLineRects(other).map {polygon($0.insetBy(dx:-1,dy:-1),$0,0)}}
                let movedNode=shiftedTextNodeRect(original)
                let entry=NativeKoreanStackRepair.Entry(id:id,text:text,rows:rows,font:Double(original.style.fontSize),ratio:Double(original.style.lineHeight/original.style.fontSize),spacing:Double(original.style.tracking/original.style.fontSize),angle:Double(original.effectiveTextRotation),condense:Double(original.style.horizontalScale),center:CGPoint(x:movedNode.midX,y:movedNode.midY),nodeRect:movedNode,outerHeight:Double(rotatedBounds(item.rect,about:item.rect,angle:original.effectiveTextRotation).height),frame:frame,sourcePixelWidth:Double(source.width),unit:joinedUnitMembers(item) != nil,obstacles:obstacles,kept:kept,ownColors:own.filter(\.opaque).map(\.color).filter {$0.count==3})
                var candidate:Card?
                let result=NativeKoreanStackRepair.search(entry,session:session,measure:{text,font in
                    var style=original.style;style.fontSize=CGFloat(font);style.tracking=0
                    return Double(NativeTranslationTypography.measuredWidth(text:text,style:style))
                },lineLayout:{text,width,maxLines,measure in
                    var style=original.style;style.horizontalScale=1
                    return withoutActuallyEscaping(measure) { calibrated in
                        NativeTranslationTypography.koreanLines(text:text,available:CGSize(width:width,height:Double(maxLines)*Double(style.lineHeight)*2),style:style,maxLines:maxLines,width:{CGFloat(calibrated($0))})
                    }
                },reduplication:{NativeTypographyPostPolish.reduplicationBreak(text:text,offset:$0)},read:{crop in
                    var bytes=[UInt8](repeating:0,count:crop.width*crop.height*4),page:[UInt8]?
                    let okay=bytes.withUnsafeMutableBytes {buffer -> Bool in
                        guard let context=CGContext(data:buffer.baseAddress,width:crop.width,height:crop.height,bitsPerComponent:8,bytesPerRow:crop.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else {return false}
                        UIGraphicsPushContext(context);defer {UIGraphicsPopContext()}
                        context.saveGState()
                        context.translateBy(x:0,y:CGFloat(crop.height))
                        context.scaleBy(x:CGFloat(crop.width)/crop.rect.width,y:-CGFloat(crop.height)/crop.rect.height)
                        context.translateBy(x:-crop.rect.minX,y:-crop.rect.minY)
                        context.interpolationQuality = .low
                        UIImage(cgImage:source).draw(in:frame)
                        context.restoreGState()
                        context.translateBy(x:0,y:CGFloat(crop.height));context.scaleBy(x:CGFloat(crop.scale),y:-CGFloat(crop.scale));context.translateBy(x:-crop.rect.minX,y:-crop.rect.minY)
                        for patch in restoration.patches where !gloss.removedLayerIDs.contains(patch.itemID ?? "") {UIImage(cgImage:patch.image).draw(in:patch.rect)}
                        if !kept.isEmpty {page=Array(buffer.bindMemory(to:UInt8.self))}
                        for p in own where p.opaque && p.color.count==3 {
                            context.setFillColor(color(p.color.map {CGFloat($0)}));context.beginPath()
                            for (i,v) in p.polygon.enumerated() {let point=CGPoint(x:v[0],y:v[1]);if i==0 {context.move(to:point)}else {context.addLine(to:point)}}
                            context.closePath();context.fillPath()
                        }
                        return true
                    }
                    return okay ? .init(data:bytes,page:page):nil
                },clips:{point in clipTests.allSatisfy {$0(point)}},verify:{proposal in
                    let proposed=shaped(original,proposal),after=stackRows(proposed,text:proposal.lines.joined())
                    guard after.count==proposal.lines.count,
                        NativeKoreanStackRepair.kind(text:proposal.lines.joined(),rows:after,unit:entry.unit,reduplication:{NativeTypographyPostPolish.reduplicationBreak(text:proposal.lines.joined(),offset:$0)})==nil else {return false}
                    candidate=proposed;return true
                })
                if result.declined {declined.insert(id)}
                if let proposal=result.candidate,var candidate {
                    candidate.stackRepair=[proposal.kind,entry.font,proposal.font,proposal.condense,rows.count,proposal.lines.count,Int(floor(Double(item.width/original.style.horizontalScale)+0.5)),Int(floor(proposal.width*proposal.condense+0.5))]
                    candidate.stackRepairDeclined=nil;cards[index]=candidate
                    releaseStackParentOverflow(cards:&cards,index:index,hasClipConstraints:!clipTests.isEmpty)
                    count+=1
                } else if result.declined {
                    var evidence:[String:Any]=result.rejected
                    if let best=result.best {evidence["best"]=best};if let ref=result.reference {evidence["ref"]=ref}
                    cards[index].stackRepairDeclined=["kind":NativeKoreanStackRepair.kind(text:text,rows:rows,unit:entry.unit,reduplication:{NativeTypographyPostPolish.reduplicationBreak(text:text,offset:$0)}) ?? "", "rejected":evidence]
                }
            }
            if count==0 {break}
        }
    }
}
