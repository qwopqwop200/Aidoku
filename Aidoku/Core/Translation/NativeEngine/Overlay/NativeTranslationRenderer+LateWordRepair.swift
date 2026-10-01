import CoreGraphics
import Foundation

extension NativeTranslationRenderer {
    static func lateWordRepairFrame(_ sourceFrame:[CGFloat],cleanupFrame:CGRect?)->CGRect? {
        let frame:CGRect
        if let cleanupFrame {frame=cleanupFrame}
        else {
            guard sourceFrame.count==4,sourceFrame.allSatisfy(\.isFinite),sourceFrame[2]>0,sourceFrame[3]>0 else{return nil}
            frame=CGRect(x:sourceFrame[0],y:sourceFrame[1],width:sourceFrame[2],height:sourceFrame[3])
        }
        guard [frame.minX,frame.minY,frame.width,frame.height].allSatisfy(\.isFinite),frame.width>0,frame.height>0 else{return nil}
        return frame
    }

    static func lateWordRepairProfile(_ card:Card)->NativeLateWordRepair.Profile {
        let p=NativeTypographyPostPolish.profile(card.typography,originalText:card.item.text)
        let text=card.item.text as NSString
        let hangul=try! NSRegularExpression(pattern:"\\p{Script=Hangul}")
        func isHangul(_ at:Int)->Bool {
            guard at>=0,at<text.length else{return false}
            return hangul.firstMatch(in:text.substring(with:NSRange(location:at,length:1)),range:NSRange(location:0,length:1)) != nil
        }
        let splits=p.breaks.filter {isHangul($0-1)&&isHangul($0) && !NativeTypographyPostPolish.reduplicationBreak(text:card.item.text,offset:$0)}.count
        let bad=p.breaks.filter {NativeTypographyPostPolish.badBreak(text:card.item.text,offset:$0) && !NativeTypographyPostPolish.reduplicationBreak(text:card.item.text,offset:$0)}.count
        return .init(ink:cardPageRangeRects(card),lines:p.lines,splits:splits,bad:bad,isolated:p.hangulIsolated,
            fragments:p.hangulFragments,punctuationOnly:p.punctuationOnly,badStarts:p.badStarts.count,badEnds:p.badEnds.count)
    }

    /// Fresh whole-word span children preserve inherited font/paint attributes;
    /// their parent is block/pre-wrap and their own white-space is nowrap.
    static func lateWordRepairTrial(_ original:Card,candidate:NativeLateWordRepair.Candidate,late:Bool=true)->Card? {
        var next=original,style=original.style,item=original.item
        let font=CGFloat(candidate.font),k=late ? CGFloat(candidate.condense):original.style.horizontalScale
        style.fontSize=font;style.lineHeight=CGFloat(candidate.pitch)
        if style.trackingScalesWithFont {style.tracking = original.style.tracking*font/original.finalFontSize}
        style.horizontalScale=k;style.optimizesKoreanWrapping=false;style.balancesHorizontalLines=false
        style.balancesExplicitParagraphs=false;style.keepsWholeWords=false;style.horizontalWrapping = .keepAllWithEmergency
        style.horizontalWhitespace = .preWrap;style.koreanQuoteMode=0
        // The line breaker measures the unscaled CSS width with Canvas advances.
        var measureStyle=style;measureStyle.horizontalScale=1
        func width(_ text:String)->CGFloat {
            let advance=NativeTranslationTypography.canvasTextMetrics(text:text,style:measureStyle)?.advance ?? .infinity
            return advance+CGFloat(max(0,text.unicodeScalars.count-1))*(-font*0.012)
        }
        guard let lines=NativeTranslationTypography.koreanLines(text:item.text,available:candidate.rect.size,
            style:measureStyle,maxLines:candidate.maxLines,width:width),!lines.isEmpty else{return nil}
        item.x=candidate.rect.minX;item.y=candidate.rect.minY;item.width=candidate.rect.width;item.height=candidate.rect.height
        item.fontSize=font;item.lineHeight=CGFloat(candidate.pitch)
        item.paddingLeft=0;item.paddingRight=0;item.paddingBottom=0
        item.paddingTop=max(0,(candidate.rect.height-CGFloat(lines.count)*CGFloat(candidate.pitch))/2)
        item.typesettingText=lines.joined(separator:"\n");item.typesettingQuoteMode=0
        item.typesettingPreformattedRows=nil;item.typesettingPreservedBlockWrapper=nil;item.typesettingBlockDisplay=true
        item.typesettingWidthScale=k==1 ? nil:k
        let css=usedLayoutItem(item)
        item=css
        // Scale transforms the used CSS box about its centre, independently of
        // authored left/top. Do not truncate the transformed physical origin.
        item.x=css.rect.midX-css.width*k/2;item.width=css.width*k
        style.usesBlockWordLayout=true;style.usesPreformattedBlockRows=false
        style.blockWordLayoutUsesTopPadding=true;style.blockRowHorizontalAlignment=nil
        next.authoredTextOrigin=candidate.rect.origin;next.item=item;next.style=style
        next.finalFontSize=font;next.textShift = .zero;next.typographyWidth=nil;next.lineOffsets=[]
        next.typography=remeasureTypography(next)
        return next
    }
}

extension NativeTranslationRenderer {
    /// The caller supplies the retained page budgets and original Entry capture.
    /// A source repair is not admitted merely because its Appearance is restored.
    static func repairLateTypographyWord(at index:Int,cards:inout [Card],
        restoration:NativeTranslationRestoration.Result,layout:NativeTranslationLayout,
        growthSession:NativeTypographyPostPolish.RendererGrowthSession,
        registered:Bool,textInside:Bool,hiddenIDs:Set<String>,removedIDs:Set<String>,
        budget:inout NativeLateWordRepair.Budget,late:Bool=true,accept:([Card])->Bool)->Bool {
        guard cards.indices.contains(index),registered,
            let patch=growthSession.context.patches[cards[index].item.id] else{return false}
        defer {growthSession.restoredExteriorRemaining=budget.exterior}
        let initial=cards[index],item=initial.item
        guard let frame=lateWordRepairFrame(item.sourceFrame,cleanupFrame:restoration.cleanupGeometry?.frame) else{return false}
        guard let source=pageRect(item.sourceBounds,frame:frame) else{return false}
        guard let ink=rgb(initial.style.foreground),ink.count==3,ink.allSatisfy(\.isFinite) else{return false}
        let metadata=initial.sourceRestorationMetadata
        let sourceKind=initial.sourceBackgroundKind ?? metadata["sourceBackgroundColor"]
        let sourceFont=item.sourceFontSize ?? 0
        let glyph=sourceFont.isFinite && sourceFont>0 ? sourceFont:min(source.width,source.height)
        let inPlace=growthSession.context.restored(item.id)
        let obstacles=cards.enumerated().filter{!removedIDs.contains($0.element.item.id)}.flatMap { _,card in
            card.sourcePanels.map {p in card.rotatesSourcePanels ? rotatedBounds(p.rect,about:card.sourcePlateRect,angle:card.item.rotation):p.rect} + card.backings.map(\.frame)
        } + cards.enumerated().filter{$0.offset != index && !removedIDs.contains($0.element.item.id)}.compactMap {cardWholeRangeRect($0.element)}.filter{$0.width>0&&$0.height>0}
        var input=NativeLateWordRepair.Input(utf16Length:item.text.utf16.count,font:Double(initial.finalFontSize),
            pitchRatio:Double(initial.style.lineHeight/initial.finalFontSize),sourceGlyph:Double(glyph),source:source,
            frame:frame,crop:patch.rect,sourceInkLuminance:NativeSourceColorSampler.luminance(ink),obstacles:obstacles)
        input.balanced=item.balancedColumn;input.rotated=item.rotation != 0;input.automatic=item.allowsAutomaticFontRecovery
        input.korean=item.wrappingScript=="korean";input.containsNewline=(item.text.contains("\n") || item.text.contains("\r"))
        input.rootChild = !initial.captionParentPlate;input.hidden=hiddenIDs.contains(item.id)
        input.transformed=initial.effectiveTextRotation != 0
        input.inpainted=sourceKind=="inpainted";input.textInside=textInside
        input.restored=inPlace;input.balloonRestored=metadata["balloonFontFit"]=="restored-surface"
        input.late=late;input.preGrowthFont=growthSession.context.growth.original[item.id].map {Double($0.fontSize)}
        input.hasScale=initial.style.horizontalScale != 1 || item.typesettingWidthScale != nil
        input.cropSafe=patch.surfaceQuality?["safe"] as? Bool ?? false
        let original=lateWordRepairProfile(initial)
        var live=initial
        let result=NativeLateWordRepair.repair(input:input,original:original,budget:&budget,
            snapshot:{initial},restore:{live=$0},wordWidth:{size in
                var style=initial.style;style.fontSize=CGFloat(size);style.tracking = -CGFloat(size)*0.012;style.horizontalScale=1
                let words=item.text.split(whereSeparator:\.isWhitespace).map(String.init)
                let widths:[CGFloat]=words.map {part -> CGFloat in
                    let advance:CGFloat=CGFloat(NativeTranslationTypography.canvasTextMetrics(text:part,style:style)?.advance ?? .infinity)
                    return advance+CGFloat(max(0,part.unicodeScalars.count-1))*style.tracking
                }
                return Double(widths.max() ?? 0)+1
            },measure:{proposal in
                guard let next=lateWordRepairTrial(initial,candidate:proposal,late:late),let range=cardWholeRangeRect(next) else{return nil}
                live=next
                return .init(profile:lateWordRepairProfile(next),contentFits:NativeTypographyPostPolish.contentFits(item:next.item,typography:next.typography),live:range)
            },surface:{profile,luminance,pool in
                var lookup=pool.lookup
                defer {pool.exterior=growthSession.restoredExteriorRemaining}
                guard let range=growthSession.inspectSurface(item:live.item,typography:live.typography,
                    rects:profile.ink,allowExterior:true,lookupBudget:&lookup) else{pool.lookup=lookup;return false}
                pool.lookup=lookup
                // SourceReader is the same retained pool; the borrowed exterior
                // allowance is restored by the enclosing page session caller.
                pool.exterior=growthSession.restoredExteriorRemaining
                let lo=range[0],hi=range[1]
                let contrast=luminance<lo ? (lo+0.05)/(luminance+0.05) : luminance>hi ? (luminance+0.05)/(hi+0.05):1
                return contrast>=4.5
            },accept:{
                // The consistency function observes the live candidate only
                // during this test, never a rejected geometry after restoration.
                cards[index]=live
                return accept(cards)
            })
        guard let result else{cards[index]=initial;return false}
        if late {
            live.harmonyRecord["lateWordRepair"]=result.diagnostic
            if result.candidate.condense<1 {live.harmonyRecord["wordRepairCondensed"]=result.candidate.condense}
        } else {
            live.harmonyRecord["wordRepair"]=[Double(original.splits),Double(original.lines),Double(result.profile.lines),
                Double(initial.finalFontSize),result.candidate.font,Double((original.bounds?.width ?? 0).rounded()),
                Double(result.candidate.rect.width.rounded())]
        }
        if result.candidate.font != Double(initial.finalFontSize) {live.sourceRestorationMetadata["sourcePanelFinalFont"]=String(result.candidate.font)}
        cards[index]=live;return true
    }
}

extension NativeTranslationRenderer {
    /// The first whole-word pass runs after restored growth, before row and
    /// page harmony capture their geometry. It repairs every Hangul stem split;
    /// the late pass deliberately accepts a narrower set of bad breaks.
    static func repairGrownTypographyWords(cards:inout [Card],restoration:NativeTranslationRestoration.Result,
        layout:NativeTranslationLayout,growthSession:NativeTypographyPostPolish.RendererGrowthSession,
        hiddenIDs:Set<String>,removedIDs:Set<String>) {
        var budget=NativeLateWordRepair.Budget(late:growthSession.wordRepairRemaining,
            type:growthSession.balloonTypeRemaining,surface:growthSession.balloonSurfaceRemaining,
            exterior:growthSession.restoredExteriorRemaining,lookup:growthSession.restoredLookupRemaining)
        defer {
            growthSession.wordRepairRemaining=budget.late
            growthSession.balloonTypeRemaining=budget.type;growthSession.balloonSurfaceRemaining=budget.surface
            growthSession.restoredExteriorRemaining=budget.exterior;growthSession.restoredLookupRemaining=budget.lookup
        }
        for i in cards.indices {
            let id=cards[i].item.id
            guard !removedIDs.contains(id),growthSession.typographyEntryRegistered(id:id) else{continue}
            let inside=(cards[i].sourcePanelTextFit ?? cards[i].sourceRestorationMetadata["sourcePanelTextFit"] ??
                cards[i].artworkRecord?["sourcePanelTextFit"] ?? growthSession.sourcePanelTextFit(id:id))=="inside"
            _ = repairLateTypographyWord(at:i,cards:&cards,restoration:restoration,layout:layout,growthSession:growthSession,
                registered:true,textInside:inside,hiddenIDs:hiddenIDs,removedIDs:removedIDs,budget:&budget,late:false,accept:{_ in true})
        }
    }
    static func lateTypographyPageConflicts(_ cards:[Card],members:[NativeTypographyCohortSnap.Member],hiddenIDs:Set<String>)->Int {
        func spread(_ a:CGFloat,_ b:CGFloat)->CGFloat {max(a,b)/min(a,b)}
        var count=0
        for i in cards.indices where !hiddenIDs.contains(cards[i].item.id) {
            let a=members[i]
            guard a.glyph>0,a.source.width>0,a.source.height>0 else{continue}
            for j in cards.indices where j>i && !hiddenIDs.contains(cards[j].item.id) {
                let b=members[j]
                guard b.glyph>0,b.source.width>0,b.source.height>0 else{continue}
                if spread(a.glyph,b.glyph)>1.15 && spread(a.source.width,b.source.width)>1.15 && spread(a.source.height,b.source.height)>1.15 {continue}
                if spread(cards[i].finalFontSize,cards[j].finalFontSize)>1.25 {count+=1}
            }
        }
        return count
    }
    static func lateTypographyRowConflicts(_ cards:[Card],rows:[[Int]])->Int {
        rows.reduce(0){sum,row in
            var count=sum
            for a in row.indices {for b in row.indices where b>a {
                let x=cards[row[a]].finalFontSize,y=cards[row[b]].finalFontSize
                if max(x,y)/min(x,y)>1.15 {count+=1}
            }}
            return count
        }
    }
    static func repairLateTypographyWords(cards:inout [Card],members:[NativeTypographyCohortSnap.Member],
        harmonyRows:[[Int]],sourceRows:[[Int]],restoration:NativeTranslationRestoration.Result,
        layout:NativeTranslationLayout,growthSession:NativeTypographyPostPolish.RendererGrowthSession,
        hiddenIDs:Set<String>,removedIDs:Set<String>) {
        guard members.count==cards.count else{return}
        var budget=NativeLateWordRepair.Budget(late:growthSession.lateWordRepairRemaining,
            type:growthSession.balloonTypeRemaining,surface:growthSession.balloonSurfaceRemaining,
            exterior:growthSession.restoredExteriorRemaining,lookup:growthSession.restoredLookupRemaining)
        defer {
            growthSession.lateWordRepairRemaining=budget.late
            growthSession.balloonTypeRemaining=budget.type;growthSession.balloonSurfaceRemaining=budget.surface
            growthSession.restoredExteriorRemaining=budget.exterior;growthSession.restoredLookupRemaining=budget.lookup
        }
        for i in cards.indices where members[i].captured {
            let id=cards[i].item.id
            guard growthSession.typographyEntryRegistered(id:id) else{continue}
            let rows=(harmonyRows+sourceRows).filter{$0.contains(i)}
            let beforePage=lateTypographyPageConflicts(cards,members:members,hiddenIDs:hiddenIDs)
            let beforeRows=lateTypographyRowConflicts(cards,rows:rows)
            let inside=(cards[i].sourcePanelTextFit ?? cards[i].sourceRestorationMetadata["sourcePanelTextFit"] ??
                cards[i].artworkRecord?["sourcePanelTextFit"] ?? growthSession.sourcePanelTextFit(id:id))=="inside"
            _ = repairLateTypographyWord(at:i,cards:&cards,restoration:restoration,layout:layout,growthSession:growthSession,
                registered:true,textInside:inside,hiddenIDs:hiddenIDs,removedIDs:removedIDs,budget:&budget,accept:{proposed in
                    lateTypographyPageConflicts(proposed,members:members,hiddenIDs:hiddenIDs)<=beforePage &&
                    lateTypographyRowConflicts(proposed,rows:rows)<=beforeRows
                })
        }
    }
}
