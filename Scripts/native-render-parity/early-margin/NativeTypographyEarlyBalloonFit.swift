import CoreGraphics
import Foundation

extension NativeTypographyPostPolish {
    struct EarlyBalloonResult {
        var item: NativeTranslationLayoutItem
        var typography: NativeTranslationTypography.Layout
        var metadata: [String:String]
    }
    /// Ordinary, clear-region and offset-search callbacks for the early margin
    /// pass. The late safe-area routine is deliberately a different entrypoint.
    static func earlyBalloonFit(item: NativeTranslationLayoutItem,
        originalInk: CGRect, plate: CGRect, foreground: CGColor, priorFont: CGFloat? = nil, erasurePolicy: String? = nil,
        currentLayout: NativeTranslationLayout, restoration: NativeTranslationRestoration.Result,
        growth: RendererGrowthSession, search: NativeEarlyBalloonSearch.Session,
        mode: NativeEarlyMarginTrial.FitMode,
        ownership: (panels:[NativeEarlyBalloonOwnership.Panel],captions:[NativeEarlyBalloonOwnership.Caption],owner:Int),
        makeGrid: () -> NativeEarlyBalloonSearch.Grid?,
        contentFits: (Candidate) -> Bool) -> EarlyBalloonResult? {
        guard !item.balancedColumn,item.rotation == 0,item.wrappingScript == "korean",
              !item.text.contains(where:\.isNewline),item.text.utf16.count<=180,
              let patch=restoration.patches.last(where:{$0.itemID == item.id}),let candidate=patch.candidate,
              candidate.safe.count == candidate.surface.width*candidate.surface.height else { return nil }
        let offset=mode == .partial,clear=mode == .incomplete
        if offset && candidate.partialErasureCertified && !NativePartialSourceProof.outlineSourceResolved(
            safe:candidate.safe,width:candidate.surface.width,height:candidate.surface.height,
            core:candidate.coreRects.map { CGRect(x:$0[0],y:$0[1],width:$0[2],height:$0[3]) },
            erasureVerified:candidate.sourceErasureVerified,glyphsVerified:candidate.sourceGlyphsVerified,
            pixelRatio:Double(candidate.imageSize.width/candidate.frame.width*candidate.descriptor.sx)) { return nil }
        guard NativeEarlyBalloonOwnership.permits(ownerIndex:ownership.owner,panels:ownership.panels,
            captions:ownership.captions,legible:clear).accepted else { return nil }
        let context=growth.context.refreshed(restoration:restoration,layout:currentLayout)
        let baseline=context.candidate(item),font=item.fontSize,frame=candidate.frame,b=item.sourceBounds
        guard b.count==4,!originalInk.isNull,!baseline.inkFrame.isNull,
              let components=foreground.converted(to:CGColorSpace(name:CGColorSpace.sRGB)!,intent:.defaultIntent,options:nil)?.components,
              components.count>=3 else { return nil }
        let inkL=NativeSourceColorSampler.luminance(components.prefix(3).map { Double($0)*255 })
        let sourceCentre=CGPoint(x:frame.minX+(b[0]+b[2]/2)*frame.width,y:frame.minY+(b[1]+b[3]/2)*frame.height)
        let sourceGlyph=item.sourceFontSize.flatMap { $0>0 ? $0:nil } ?? min(b[2]*frame.width,b[3]*frame.height)
        let reached=clear && candidate.surfaceQuality?["safe"] as? Bool == true &&
            candidate.surfaceQuality?["coefficients"] is [[Double]] ? CGFloat(64):0
        let room=plate.union(patch.rect.insetBy(dx:-reached,dy:-reached))
        let others=ownership.panels.enumerated().filter { $0.offset != ownership.owner }.map { $0.element.rect } +
            ownership.captions.filter { $0.id != item.id && $0.ink.width>0 && $0.ink.height>0 }.map(\.ink)
        let ratio=font>0 ? item.lineHeight/font:1.2
        func style(_ size:CGFloat)->NativeTranslationTypography.Style { context.style(context.resized(item,size:size)) }
        func advance(_ size:CGFloat)->CGFloat {
            let s=style(size)
            return NativeTranslationTypography.measuredWidth(text:item.text,style:s)-CGFloat(max(0,item.text.unicodeScalars.count-1))*s.tracking
        }
        let input=NativeEarlyBalloonSearch.Input(id:item.id,font:font,
            priorFont:priorFont,
            minimum:BrowserOverlayLayoutPlanner.minimumRenderedFontSize,sourceGlyph:sourceGlyph,
            sourceWidth:b[2]*frame.width,baseWidth:baseline.inkFrame.width,sourceCentre:sourceCentre,
            originalCentre:CGPoint(x:baseline.inkFrame.midX,y:baseline.inkFrame.midY),offsetSearch:offset,clearSearch:clear,
            provisional:candidate.provisional,auxiliaryOriginalPreserved:erasurePolicy == "auxiliary-original-preserved")
        let accepted:NativeEarlyBalloonSearch.Accepted<Candidate>?=NativeEarlyBalloonSearch.run(input,session:search,
            fontSizes:{balloonFontSizes(font:$0,minimum:$1)},restoredFloor:{restoredFontFloor(original:$0,minimum:$1)},
            emergencySizes:{emergencyBalloonFontSizes(font:$0,minimum:$1,preferred:$2)},lineWidth:advance,
            wordWidth:{koreanWordWidth(text:item.text,style:style($0))},makeGrid:makeGrid,
            layout:{ size,anchor,width,margin -> NativeEarlyBalloonSearch.Attempt<Candidate> in
                let height=2*min(anchor.y-room.minY-2,room.maxY-anchor.y-2)
                guard (width>=size*1.8 || width>=advance(size)+1),height>0,
                      item.text.utf16.count<=search.typeBudget,search.surfaceBudget>0 else { return .init() }
                search.typeBudget-=item.text.utf16.count
                var proposed=context.resized(item,size:size)
                proposed.x=anchor.x-width/2;proposed.y=anchor.y-height/2;proposed.width=width;proposed.height=height
                proposed.paddingTop=0;proposed.paddingRight=0;proposed.paddingBottom=0;proposed.paddingLeft=0
                proposed.typesettingText=nil;proposed.typesettingQuoteMode=nil
                let maxLines=min(baseline.profile.lines+8,Int(floor(height/(size*ratio))))
                guard maxLines>=1 else { return .init() }
                let result:Candidate
                if let words=context.words(proposed,maxLines:maxLines,strict:false) { result=words }
                else {
                    guard advance(size)<=width else { return .init() }
                    result=context.candidate(proposed)
                }
                guard contentFits(result),fontFlowFits(result.profile,baseline.profile,extraWordBreaks:1),result.profile.lines<=maxLines,
                      size<=font || growthKeepsLineLength(text:item.text,originalLines:baseline.profile.lines,lines:result.profile.lines),
                      !result.inkFrame.isNull else { return .init() }
                let measured=result.inkFrame
                let refused=NativeEarlyBalloonSearch.Attempt<Candidate>(frame:measured)
                guard measured.minX>=room.minX,measured.maxX<=room.maxX,measured.minY>=room.minY,measured.maxY<=room.maxY,
                      !others.contains(where:{$0.minX<measured.maxX+1 && $0.maxX>measured.minX-1 &&
                        $0.minY<measured.maxY+0.75 && $0.maxY>measured.minY-0.75}) else { return refused }
                var probe=result;probe.surfaceInk=result.ink.map{$0.insetBy(dx:-margin.width,dy:-margin.height)}
                let allowance=min(search.surfaceBudget,65_536);var lookup=allowance
                let surface=context.inspectedSurface(probe,allowExterior:true,requiresCommittedRestoration:false,lookupBudget:&lookup)
                search.surfaceBudget-=allowance-lookup
                guard let surface else { return refused }
                let contrast=inkL<surface[0] ? (surface[0]+0.05)/(inkL+0.05):inkL>surface[1] ? (inkL+0.05)/(surface[1]+0.05):1
                guard contrast>=4.5,abs(measured.midX-anchor.x)<=1.5,abs(measured.midY-anchor.y)<=1.5 else { return refused }
                let rank=(result.profile.hangulFragments+result.profile.punctuationOnly+result.profile.badStarts.count+result.profile.badEnds.count)*100+result.profile.breaks.count
                return .init(frame:measured,value:result,rank:rank)
            })
        guard let accepted else { return nil }
        func string(_ x:CGFloat)->String { String(format:"%.15g",Double(x)) }
        func json(_ value:Any)->String { (try? JSONSerialization.data(withJSONObject:value)).flatMap{String(data:$0,encoding:.utf8)} ?? "[]" }
        func flow(_ p:Profile)->[String:Int] { ["lines":p.lines,"breaks":p.breaks.count,"fragments":p.hangulFragments,
            "punctuation":p.punctuationOnly,"badStarts":p.badStarts.count,"badEnds":p.badEnds.count] }
        var metadata:[String:String]=["balloonFontFit":"restored-surface","balloonOriginalFont":string(font),
            "balloonOriginalInk":json([originalInk.minX,originalInk.minY,originalInk.width,originalInk.height]),
            "balloonOriginalFlow":json(flow(baseline.profile)),"balloonFinalFlow":json(flow(accepted.value.profile)),
            "sourcePanelFinalFont":string(accepted.size),"sourcePanelTextFit":"inside","sourceBackgroundColor":"inpainted",
            "sourceAppliedBackgroundRGB":"","balloonCardRect":json([plate.minX,plate.minY,plate.maxX,plate.maxY])]
        if accepted.wordFlow { metadata["balloonFitWidth"]="word-flow" }
        if accepted.emergency { metadata["balloonEmergencyFontFit"]="true" }
        if accepted.clearRegion { metadata["balloonClearRegion"]="true" }
        return .init(item:accepted.value.item,typography:accepted.value.shaped,metadata:metadata)
    }
}
