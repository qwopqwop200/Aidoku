import CoreGraphics
import Foundation

extension NativeTranslationRenderer {
    /// The typography owner supplies its original per-page growth session.
    /// A failed re-fit can still restore the caption's original committed state.
    struct PlateRestoredGrowthBridge {
        var growers: [NativeTypographyPlateGrowth.Grower]
        var refit: (_ id: String, _ cap: Double, _ strict: Bool, _ current: [Card]) -> (card: Card?, size: Double?)
        var peerFont: (_ id: String, _ font: Double, _ beforeInterior: Bool) -> Double
        var interiorGaps: (_ id: String, _ font: Double, _ current: [Card]) -> Int
    }
    struct PlateGrowthDiagnostic {
        let id: String
        let originalFont: Double
        var font: Double?
        var cohort: Double?
        var released: Double?
        var styleCap: Double?
        var interiorRefit: Double?
        var room: [Double]?
    }

    /// Original ordering: plate growth, restored growth, then their combined
    /// live font cohorts. The caller invokes this after caption packing.
    @discardableResult
    static func growPlateTypography(cards: inout [Card], layout: NativeTranslationLayout,
                                     restoration: NativeTranslationRestoration.Result,
                                     settings: IPhoneOverlaySettings, source: CGImage?,
                                     gloss: NativeTranslationEffectGloss.Refinement = .init(),
                                     restoredBridge suppliedBridge: PlateRestoredGrowthBridge? = nil,
                                     growthSession: NativeTypographyPostPolish.RendererGrowthSession? = nil) throws -> [PlateGrowthDiagnostic] {
        guard settings.renderedBackgroundOpacity == 1, layout.items.count <= 256 else {return []}
        typealias Policy = NativeTypographyPlateGrowth
        func currentItem(_ card: Card) -> NativeTranslationLayoutItem {
            var item=card.item
            item.fontSize=card.finalFontSize;item.lineHeight=card.style.lineHeight
            item.x += card.textShift.x;item.y += card.textShift.y
            return item
        }
        func currentItems(_ values: [Card]) -> [NativeTranslationLayoutItem] {
            layout.items.map {item in values.first(where:{$0.item.id==item.id}).map(currentItem) ?? item}
        }
        let budget=Policy.Budget(),widenBudget=NativeTypographyDisplayWidening.Budget()
        var flatRoomIDs=Set<String>()
        let reader=source.map {NativeSourcePixelReader(image:$0)}
        defer {reader?.release()}
        var originals:[String:Card]=[:],states:[String:Policy.State]=[:],readablePeers:[String:Double]=[:]
        var diagnostics:[String:PlateGrowthDiagnostic]=[:]
        var events:[String:[[String:Any]]]=[:]
        func box(_ rect:CGRect)->[Double] {[Double(rect.minX),Double(rect.minY),Double(rect.width),Double(rect.height)]}
        func shape(_ card:Card)->[String:Any] {
            ["font":Double(card.finalFontSize),"rect":box(card.item.rect),"ink":box(cardInkRect(card)),
             "panels":card.sourcePanels.map {["rect":box($0.rect),"coverage":$0.coverage.map(box),
                 "background":$0.background,"sourceErasure":$0.sourceErasure] as [String:Any]}]
        }
        let entering=Dictionary(uniqueKeysWithValues:cards.map {($0.item.id,shape($0))})
        func visible(_ card: Card) -> Bool {
            !card.item.keptLettering && !card.item.text.isEmpty && !gloss.hiddenIDs.contains(card.item.id) && !gloss.removedLayerIDs.contains(card.item.id)
        }
        func glyph(_ card: Card) -> Double {
            if let value=card.item.sourceFontSize,value.isFinite,value>0{return Double(value)}
            guard let r=pageRect(card.item.sourceBounds,frame:layout.sourceRect) else{return .nan}
            return Double(min(r.width,r.height))
        }
        func ownPlate(_ card: Card) -> Int? {card.sourcePanels.firstIndex(where:{!$0.sourceErasure && !$0.rotated})}
        func wordWidth(_ text: String,_ size: Double,_ baseline: Card) -> Double {
            var style=baseline.style
            style.fontSize=CGFloat(size);style.tracking=0;style.horizontalScale=1
            return Double(NativeTranslationTypography.measuredWidth(text:text,style:style))
        }
        func proposalKey(_ p: Policy.Proposal) -> String {
            [Double(p.box.minX),Double(p.box.minY),Double(p.box.width),Double(p.box.height),p.font,p.pitch,p.padding,p.horizontalScale]
                .map {String($0.bitPattern)}.joined(separator:"|")
        }
        func trial(_ baseline: Card,_ p: Policy.Proposal) -> Card? {
            guard valid(p.box),p.font.isFinite,p.font>0 else{return nil}
            var proposed=baseline,item=baseline.item,style=baseline.style
            // Native horizontalScale already acts inside the physical box.
            // The policy's box is the CSS layout box before its scale.
            let width=CGFloat(Double(p.box.width)*p.horizontalScale)
            item.x=p.box.midX-width/2;item.y=p.box.minY;item.width=width;item.height=p.box.height
            item.paddingTop=CGFloat(p.padding);item.paddingBottom=CGFloat(p.padding)
            item.paddingLeft=CGFloat(p.padding);item.paddingRight=CGFloat(p.padding)
            item.fontSize=CGFloat(p.font);item.lineHeight=CGFloat(p.pitch)
            item.typesettingText=nil;item.typesettingQuoteMode=nil
            item.typesettingWidthScale=p.horizontalScale==1 ? nil:CGFloat(p.horizontalScale)
            item.balancedColumn=false
            style.fontSize=CGFloat(p.font);style.lineHeight=CGFloat(p.pitch);style.tracking = -CGFloat(p.font)*0.012
            style.horizontalScale=CGFloat(p.horizontalScale);style.alignsToTop=false;style.horizontalAlignment = .center
            style.optimizesKoreanWrapping=false;style.balancesHorizontalLines=false;style.keepsWholeWords=true
            style.koreanQuoteMode=0
            proposed.item=item;proposed.style=style;proposed.textShift = .zero
            proposed.typographyWidth=nil;proposed.lineOffsets=[]
            proposed.typography=remeasureTypography(proposed)
            proposed.finalFontSize=CGFloat(p.font)
            return proposed
        }
        func lineFlags(_ card: Card) -> (badStart:Bool,lone:Int) {
            let text=card.typography.shapedText as NSString,closing=Set("、。，．,.！？!?…‥）)]」』】》〉:;".unicodeScalars)
            var bad=false,lone=0
            for range in card.typography.lineRanges where range.location>=0 && NSMaxRange(range)<=text.length {
                let raw=text.substring(with:range)
                let visible=raw.unicodeScalars.filter {!CharacterSet.whitespacesAndNewlines.contains($0)}
                if let first=visible.first,closing.contains(first){bad=true}
                let letters=visible.filter {!CharacterSet.punctuationCharacters.contains($0)}
                if letters.count==1,let scalar=letters.first,
                   [(0x1100...0x11FF), (0x302E...0x302F), (0x3131...0x318E), (0x3200...0x321E),
                    (0x3260...0x327E), (0xA960...0xA97C), (0xAC00...0xD7A3), (0xD7B0...0xD7C6),
                    (0xD7CB...0xD7FB), (0xFFA0...0xFFBE), (0xFFC2...0xFFC7), (0xFFCA...0xFFCF),
                    (0xFFD2...0xFFD7), (0xFFDA...0xFFDC)].contains(where:{$0.contains(Int(scalar.value))}){lone+=1}
            }
            return (bad,lone)
        }
        func tryPlate(_ id: String,_ cap: Double,_ strict: Bool) -> Double? {
            guard let index=cards.firstIndex(where:{$0.item.id==id}),visible(cards[index]),
                  let plateIndex=ownPlate(cards[index]) else{return nil}
            if originals[id]==nil {originals[id]=cards[index];states[id]=Policy.State()}
            guard let baseline=originals[id],let state=states[id],baseline.sourcePanels.indices.contains(plateIndex) else{return nil}
            // Every cohort retry starts from the original font/plate snapshot.
            let before=shape(cards[index])
            flatRoomIDs.remove(id)
            let owner=baseline.sourcePanels[plateIndex],g=glyph(baseline),font=Double(baseline.finalFontSize)
            let otherCards=cards.indices.filter {$0 != index && visible(cards[$0])}.map {cards[$0]}
            let otherInk=otherCards.map(cardInkRect).filter {$0.width>0 && $0.height>0}
            let otherPlates=otherCards.flatMap {other in other.sourcePanels.filter {!$0.sourceErasure}.map(\.rect) +
                (other.rotatesSourcePanels ? [other.item.rect]:[])}
            let otherPaint=otherCards.flatMap {other in other.sourcePanels.filter {!$0.sourceErasure}.map(\.rect) + other.backings.map(\.frame) +
                (other.item.rotation != 0 && other.drawsPanel ? [other.item.rect]:[])}
            var input=Policy.Input(text:baseline.item.text,font:font,originalFont:font,sourceGlyph:g,
                cap:cap,ratio:Double(baseline.style.lineHeight)/font,wrappingScript:baseline.item.wrappingScript,
                vertical:baseline.item.vertical,rotated:baseline.item.rotation != 0,allowsRecovery:baseline.item.allowsAutomaticFontRecovery,
                strict:strict,plate:owner.rect,currentInk:cardInkRect(baseline),
                coverage:owner.coverage.isEmpty ? nil:owner.coverage,frame:layout.sourceRect,
                others:otherInk,foreignPlates:otherPlates,foreignCards:otherPaint)
            input.plateVisible=true
            if input.wrappingScript=="korean",g.isFinite,g>0,g*0.9<9 {
                readablePeers[id]=max(readablePeers[id] ?? 0,font,floor(min(32,g*0.95)*4)/4)
            }
            var measured:[String:Card]=[:]
            let result=Policy.grow(input,state:state,budget:budget,advance:{wordWidth($0,$1,baseline)},measure:{p in
                guard let card=trial(baseline,p) else{return nil};measured[proposalKey(p)]=card
                let flags=lineFlags(card),size=card.item.rect.size,fit=card.typography.fits
                return .init(ink:cardInkRect(card),lineRects:cardPageLineRects(card),
                    scrollWidth:Double(size.width)+(fit ? 0:2),clientWidth:Double(size.width),
                    scrollHeight:Double(size.height)+(fit ? 0:2),clientHeight:Double(size.height),
                    badLineStart:flags.badStart,loneSyllableLines:flags.lone)
            },roomProvider:{_,reach in
                guard let source,let reader else{return nil}
                let flat=Policy.FlatRoomInput(plate:owner.rect,glyph:reach,covered:owner.coverage.isEmpty ? [owner.rect]:owner.coverage,
                    frame:layout.sourceRect,imageWidth:source.width,imageHeight:source.height,color:owner.background,
                    hasImage:!baseline.foreignFills.isEmpty,transformed:baseline.rotatesSourcePanels || baseline.item.rotation != 0)
                return Policy.flatRoom(flat,budget:budget,read:{x,y,w,h in
                    try? reader.read(x:Double(x),y:Double(y),sourceWidth:Double(w),sourceHeight:Double(h),width:w,height:h)
                })
            })
            guard let result, var accepted=measured[proposalKey(result.proposal)] else{
                cards[index]=baseline
                events[id,default:[]].append(["phase":"plate","cap":cap.isFinite ? cap as Any:"Infinity","strict":strict,
                    "ownerIndex":plateIndex,"accepted":false,"baseline":shape(baseline),"before":before,"after":shape(baseline),
                    "measurements":measured.count])
                return nil
            }
            accepted.sourcePanels[plateIndex].rect=result.plate
            if let coverage=result.coverage {
                accepted.sourcePanels[plateIndex].coverage=coverage
                accepted.sourcePanels[plateIndex].clipped=coverage.count>1 || baseline.sourcePanels[plateIndex].clipped
            }
            cards[index]=accepted
            if let room=result.flatRoom,!room.isEmpty {flatRoomIDs.insert(id)}
            events[id,default:[]].append(["phase":"plate","cap":cap.isFinite ? cap as Any:"Infinity","strict":strict,
                "ownerIndex":plateIndex,"accepted":true,"baseline":shape(baseline),"before":before,"after":shape(accepted),
                "measurements":measured.count,"room":result.flatRoom as Any? ?? NSNull()])
            diagnostics[id]=PlateGrowthDiagnostic(id:id,originalFont:font,font:result.proposal.font,room:result.flatRoom)
            return result.proposal.font
        }
        func tryPlateWide(_ id:String,_ cap:Double,_ strict:Bool)->Double? {
            let grown=tryPlate(id,cap,strict)
            guard let index=cards.firstIndex(where:{$0.item.id==id}),let baseline=originals[id],
                  let ownerIndex=ownPlate(cards[index]),let source,let reader else{return grown}
            let owner=cards[index].sourcePanels[ownerIndex],ink=cardInkRect(baseline)
            var visiblePlate=owner.rect
            if !owner.coverage.isEmpty {
                let owners=owner.coverage.filter {$0.minX<=ink.midX && ink.midX<=$0.maxX && $0.minY<=ink.midY && ink.midY<=$0.maxY}
                    .sorted {$0.width*$0.height>$1.width*$1.height}
                guard let largest=owners.first else{return grown};visiblePlate=largest
            }
            let pageGlyphs=layout.items.filter {!$0.keptLettering}.compactMap {item -> Double? in
                if let value=item.sourceFontSize,value>0 {return Double(value)}
                guard let r=pageRect(item.sourceBounds,frame:layout.sourceRect) else{return nil}
                let value=Double(min(r.width,r.height));return value>0 ? value:nil
            }.sorted()
            let pageGlyph=pageGlyphs.isEmpty ? Double.nan:pageGlyphs[(pageGlyphs.count-1)/2]
            guard let sourceRect=pageRect(baseline.item.sourceBounds,frame:layout.sourceRect) else{return grown}
            let foreign=cards.filter {$0.item.id != id && visible($0)}
            let input=NativeTypographyDisplayWidening.Input(text:baseline.item.text,font:Double(baseline.finalFontSize),
                glyph:glyph(baseline),pageGlyph:pageGlyph,cap:cap,grown:grown,flatRoom:flatRoomIDs.contains(id),
                rotation:baseline.item.rotation != 0,vertical:baseline.item.vertical,sourceVertical:baseline.item.sourceVertical,
                allowsRecovery:baseline.item.allowsAutomaticFontRecovery,wrappingScript:baseline.item.wrappingScript,
                visible:visible(baseline),ratio:Double(baseline.style.lineHeight/baseline.finalFontSize),strict:strict,
                plate:owner.rect,visiblePlate:visiblePlate,color:owner.background,frame:layout.sourceRect,source:sourceRect,
                imageWidth:source.width,imageHeight:source.height,others:foreign.map(cardInkRect),
                foreignCards:foreign.flatMap {$0.sourcePanels.filter {!$0.sourceErasure}.map(\.rect) + $0.backings.map(\.frame) +
                    ($0.item.rotation != 0 && $0.drawsPanel ? [$0.item.rect]:[])},
                foreignSourceRects:layout.items.filter {$0.id != id && !$0.keptLettering}.flatMap {item in
                    ([item.sourceBounds]+item.auxiliaryInkRects).compactMap {pageRect($0,frame:layout.sourceRect)}
                })
            let before=shape(cards[index]);var measured:[String:Card]=[:]
            let result=NativeTypographyDisplayWidening.widen(input,budget:widenBudget,advance:{wordWidth($0,$1,baseline)},
                read:{crop,w,h in try? reader.read(x:Double(crop.minX),y:Double(crop.minY),sourceWidth:Double(crop.width),
                    sourceHeight:Double(crop.height),width:w,height:h)},measure:{p in
                    guard let next=trial(baseline,p) else{return nil};measured[proposalKey(p)]=next
                    let fit=next.typography.fits,size=next.item.rect.size
                    return .init(ink:cardInkRect(next),lineRects:cardPageLineRects(next),
                        scrollWidth:Double(size.width)+(fit ? 0:2),clientWidth:Double(size.width),
                        scrollHeight:Double(size.height)+(fit ? 0:2),clientHeight:Double(size.height),badLineStart:lineFlags(next).badStart)
                })
            guard let result,var next=measured[proposalKey(result.proposal)] else{return grown}
            // The wider text uses the current plate verbatim, including any
            // accepted axis pass. No expanded source erasure/coverage is added.
            next.sourcePanels=cards[index].sourcePanels;next.backings=cards[index].backings;next.displayCardGrowth=true
            cards[index]=next
            events[id,default:[]].append(["phase":"widen","before":before,"after":shape(next),"sampledPixels":result.sampledPixels])
            diagnostics[id] = .init(id:id,originalFont:Double(baseline.finalFontSize),font:result.proposal.font)
            return result.proposal.font
        }
        var growers:[Policy.Grower]=[]
        for id in cards.filter(visible).map({$0.item.id}) {
            if let size=tryPlateWide(id,.infinity,false),let card=cards.first(where:{$0.item.id==id}) {
                growers.append(.init(id:id,source:glyph(card),script:card.item.fontScript,vertical:card.item.vertical,size:size))
            }
        }
        // Original collect order: all plate growers, then one restored-surface
        // growth pass. Upfront refining runs only initial cohort/word repair.
        if let session=growthSession {
            let foregrounds=Dictionary(uniqueKeysWithValues:cards.map {($0.item.id,$0.style.foreground)})
            let grown=try session.growRestored(items:currentItems(cards),
                lockedIDs:gloss.hiddenIDs.union(gloss.removedLayerIDs),foregrounds:foregrounds)
            for index in cards.indices {
                guard let item=grown.first(where:{$0.id==cards[index].item.id}),item != currentItem(cards[index]) else{continue}
                let before=shape(cards[index]);var next=cards[index],style=next.style
                style.fontSize=item.fontSize;style.lineHeight=item.lineHeight;style.tracking = -item.fontSize*0.012
                style.horizontalScale=item.typesettingWidthScale ?? 1;style.alignsToTop=item.balancedColumn
                style.koreanQuoteMode=item.typesettingQuoteMode ?? 0;style.strictLineBreak=item.typesettingStrictLineBreak ?? false
                style.foreground=item.typesettingForeground.map {color($0.map {CGFloat($0)})} ?? style.foreground
                style.outline=item.typesettingOutlineRGB.map {color($0.map {CGFloat($0)})} ?? style.outline
                style.outlineWidth=item.typesettingOutlineWidth ?? style.outlineWidth
                next.item=item;next.style=style;next.finalFontSize=item.fontSize;next.textShift = .zero
                next.typographyWidth=nil;next.lineOffsets=[];next.typography=remeasureTypography(next);cards[index]=next
                events[item.id,default:[]].append(["phase":"initial-restored","before":before,"after":shape(next)])
            }
        }
        let restoredBridge:PlateRestoredGrowthBridge?
        if let suppliedBridge {restoredBridge=suppliedBridge}
        else if let session=growthSession {
            let records=session.records(items:cards.map(currentItem))
            restoredBridge=PlateRestoredGrowthBridge(growers:records.map {record in
                .init(id:record.id,source:Double(record.sourceGlyph),script:record.original.fontScript,vertical:record.vertical,
                      inPlace:record.inPlace,size:Double(record.font),extended:record.extended,base:Double(record.base),
                      interiorBase:record.interiorGrowth ? Double(record.beforeInteriorFont):nil)
            },refit:{id,cap,strict,current in
                guard let card=current.first(where:{$0.item.id==id}),let record=records.first(where:{$0.id==id}),
                      let item=session.grow(item:currentItem(card),others:currentItems(current),cap:CGFloat(cap),
                                            strict:strict,foreground:card.style.foreground) else{return (nil,nil)}
                var next=card,style=card.style
                style.fontSize=item.fontSize;style.lineHeight=item.lineHeight;style.tracking = -item.fontSize*0.012
                style.horizontalScale=item.typesettingWidthScale ?? 1;style.alignsToTop=item.balancedColumn
                style.koreanQuoteMode=item.typesettingQuoteMode ?? 0;style.strictLineBreak=item.typesettingStrictLineBreak ?? false
                style.foreground=item.typesettingForeground.map {color($0.map {CGFloat($0)})} ?? style.foreground
                style.outline=item.typesettingOutlineRGB.map {color($0.map {CGFloat($0)})} ?? style.outline
                style.outlineWidth=item.typesettingOutlineWidth ?? style.outlineWidth
                next.item=item;next.style=style;next.finalFontSize=item.fontSize;next.textShift = .zero
                next.typographyWidth=nil;next.lineOffsets=[];next.typography=remeasureTypography(next)
                return (next,item.fontSize>=record.original.fontSize*1.08 ? Double(item.fontSize):nil)
            },peerFont:{id,font,before in Double(session.peerFont(id:id,font:CGFloat(font),beforeInterior:before))},
            interiorGaps:{id,font,current in session.interiorGaps(id:id,font:CGFloat(font),items:currentItems(current))})
        } else {restoredBridge=nil}
        // Restored growth is supplied by its own persistent typography session;
        // a final font alone cannot fabricate its original/base/interior flags.
        if let bridge=restoredBridge {growers += bridge.growers}
        func sampledRGB(_ value: Any?) -> [Double]? {NativeRestorationPixels.rgb(value)?.channels}
        func members() -> [Policy.Member] {
            cards.filter(visible).map {card in
                let item=card.item,font=Double(card.finalFontSize),sample=restoration.appearances[item.id]?.sourceSample ?? [:]
                let ink=sampledRGB(sample["foreground"]),paper=sampledRGB(sample["background"])
                let style=[NativeTranslationSourceStylePostPolish.colorClass(ink ?? []),NativeTranslationSourceStylePostPolish.colorClass(paper ?? []),card.style.outlineWidth>0 ? "true":"false"].joined(separator:"|")
                let peer=readablePeers[item.id]
                let cohort=min(restoredBridge?.peerFont(item.id,font,true) ?? font,peer ?? font)
                let current=min(restoredBridge?.peerFont(item.id,font,false) ?? font,peer ?? font)
                return .init(id:item.id,source:glyph(card),script:item.fontScript,vertical:item.vertical,sourceVertical:item.sourceVertical,
                    sourceRect:pageRect(item.sourceBounds,frame:layout.sourceRect),cohortFont:cohort,memberFont:current,styleKey:style,
                    rotation:Double(item.rotation),nearUprightRotation:Double(item.nearUprightRotation ?? 0))
            }
        }
        let kept=layout.items.filter(\.keptLettering).compactMap {item -> Policy.Member? in
            guard let source=item.sourceFontSize,source.isFinite,source>0 else{return nil}
            let font=min(32,Double(source)*0.9)
            return .init(id:item.id,source:Double(source),script:item.fontScript,vertical:item.vertical,sourceVertical:item.sourceVertical,
                sourceRect:pageRect(item.sourceBounds,frame:layout.sourceRect),cohortFont:font,memberFont:font)
        }
        let inPlace=Set(growers.filter(\.inPlace).map(\.id))
        Policy.reconcile(&growers,members:members,kept:kept,run:{id,cap,strict in
            if inPlace.contains(id),let bridge=restoredBridge {
                let before=cards.first(where:{$0.item.id==id}).map(shape)
                let outcome=bridge.refit(id,cap,strict,cards)
                events[id,default:[]].append(["phase":"restored","cap":cap.isFinite ? cap as Any:"Infinity","strict":strict,
                    "accepted":outcome.size != nil,"before":before as Any? ?? NSNull(),
                    "after":outcome.card.map(shape) as Any? ?? NSNull()])
                if let card=outcome.card,let index=cards.firstIndex(where:{$0.item.id==id}) {cards[index]=card}
                return outcome.size
            }
            return tryPlateWide(id,cap,strict)
        },readableHold:{id in
            guard let card=cards.first(where:{$0.item.id==id}) else{return 0}
            return Policy.readableHold(source:glyph(card),script:card.item.fontScript,font:Double(card.finalFontSize),
                ink:cardInkRect(card),otherVisibleInk:cards.filter {visible($0) && $0.item.id != id}.map(cardInkRect))
        },plateFilled:{id in
            guard let card=cards.first(where:{$0.item.id==id}),let index=ownPlate(card) else{return false}
            return Policy.plateFilled(plate:card.sourcePanels[index].rect,font:Double(card.finalFontSize),
                wordWidths:card.item.text.split(whereSeparator:{$0.isWhitespace}).map {wordWidth(String($0),Double(card.finalFontSize),card)},
                inkHeight:Double(cardInkRect(card).height),displayCardGrowth:card.displayCardGrowth)
        },interiorGaps:{id,font in restoredBridge?.interiorGaps(id,font,cards) ?? 0})
        for grower in growers {
            var record=diagnostics[grower.id] ?? .init(id:grower.id,originalFont:grower.base,font:grower.size)
            record.font=grower.size;record.cohort=grower.cohortTarget;record.released=grower.releasedTarget
            record.styleCap=grower.styleCap;record.interiorRefit=grower.interiorRefit
            diagnostics[grower.id]=record
        }
        for index in cards.indices {
            let id=cards[index].item.id
            cards[index].plateGrowthRecord=["entering":entering[id] as Any? ?? NSNull(),"leaving":shape(cards[index]),
                "events":events[id] ?? [],"grew":diagnostics[id]?.font as Any? ?? NSNull(),
                "cohort":diagnostics[id]?.cohort as Any? ?? NSNull()]
        }
        return cards.compactMap {diagnostics[$0.item.id]}
    }
}
