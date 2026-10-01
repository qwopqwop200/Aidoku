import CoreGraphics
import Foundation

extension NativeTranslationRenderer {
    /// Original6717–7176 source certificates and mode-specific typography trials.
    /// All closures operate on private page copies, then publish once; callbacks
    /// cannot expose a provisional larger canvas to prior full-fit decisions.
    static func applyEarlyMargins(cards: inout [Card], restoration: inout NativeTranslationRestoration.Result,
        layout: NativeTranslationLayout, source: CGImage?, settings: IPhoneOverlaySettings,
        growth: NativeTypographyPostPolish.RendererGrowthSession, balloons: BalloonRelayoutContext) {
        guard settings.renderedBackgroundOpacity == 1,settings.preserveSourceBackgroundColor,
              layout.items.count<=256 else { return }
        var workCards=cards,work=restoration
        let sourceFrame=work.cleanupGeometry?.frame ?? layout.sourceRect
        let reader=source.map { NativeSourcePixelReader(image:$0) }
        defer { reader?.release() }
        let search=NativeEarlyBalloonSearch.Session()
        let budget=NativeEarlyMarginTrial.Budget(artworkRemaining:growth.artworkSurfaceRemaining,paperRemaining:work.paperProposalRemaining)
        var entries:[NativeEarlyMarginTrial.Entry]=[],savedPatches:[String:NativeTranslationRestoration.Patch]=[:]
        var nextPatches:[String:NativeTranslationRestoration.Patch]=[:]
        func patchIndex(_ id:String)->Int? { work.patches.lastIndex(where:{$0.itemID == id && $0.candidate != nil}) }
        func cardIndex(_ id:String)->Int? { workCards.firstIndex(where:{$0.item.id == id}) }
        func canvas(_ id:String,_ c:NativeRestorationCandidate)->NativeEarlyMarginPixels.Canvas {
            .init(id:id,width:c.surface.width,height:c.surface.height,rgba:c.rawRGBA,safe:c.safe,luminance:c.luminance,
                geometry:.init(frame:c.frame,imageSize:c.imageSize,origin:c.descriptor.crop.origin,
                    scale:.init(width:c.descriptor.sx,height:c.descriptor.sy)),erasureComplete:c.erasureComplete,
                erasureVerified:c.sourceErasureVerified,provisional:c.provisional)
        }
        for p in work.patches {
            guard let id=p.itemID,let c=p.candidate,let index=cardIndex(id),patchIndex(id).map({work.patches[$0].candidate === c}) == true else { continue }
            let card=workCards[index],item=card.item,panel=card.sourcePanels.last(where:{!$0.sourceErasure})
            let pad=max(3,min(6,Double(card.style.fontSize)*0.3))
            // First rememberInk record predates typography/cohort/artwork changes.
            let padding=max(pad,Double(growth.rememberedInk(id:id)?.pad ?? CGFloat(pad)))
            let cross=max(padding,min(16,item.sourceFontSize.map(Double.init) ?? padding))
            let g=NativeFinalRestorationTrial.Geometry(imageSize:c.imageSize,frame:c.frame,cropOrigin:c.descriptor.crop.origin,
                scale:.init(width:c.descriptor.sx,height:c.descriptor.sy),sourceBounds:c.sourceBounds,
                auxiliaryInkRects:c.auxiliaryInkRects,sourceFontSize:c.sourceFontSize)
            guard let coverage=NativeFinalRestorationTrial.marginCoverage(geometry:g,sourceFrame:sourceFrame,
                oldPlate:panel?.rect ?? item.rect,
                padding:.init(width:item.sourceVertical ? cross:padding,height:item.sourceVertical ? padding:cross),
                displayedFontSize:Double(card.style.fontSize)) else { continue }
            let state=NativeEarlyMarginTrial.State(canvas:canvas(id,c),revision:c.revision,partialCertified:c.partialErasureCertified,
                policy:card.sourceRestorationMetadata["sourceErasurePolicy"],residualRefused:card.sourceRestorationMetadata["residualRefused"],
                metadata:card.sourceRestorationMetadata)
            let e=NativeEarlyMarginTrial.Entry(state:state,coverage:coverage,sourceCorePixels:c.sourceCorePixels.map(Double.init) ?? .nan)
            e.sourceVertical=item.sourceVertical;e.sourceSingleColumn=item.sourceSingleColumn;e.balancedColumn=item.balancedColumn
            e.rotation=Double(item.rotation);e.sourceTextOnly=item.sourceTextOnly;e.hasPanel=panel != nil
            e.hasTypographyEntry=growth.context.growth.admitted.contains(id)
            e.method=c.method;e.sourceGlyphsVerified=c.sourceGlyphsVerified;e.sourceRemainingInk=c.sourceRemainingInk.map(Double.init)
            e.sourceBodyCoverage=([item.sourceBounds]+item.auxiliaryInkRects).compactMap { pageRect($0,frame:sourceFrame) }
            entries.append(e)
        }
        func refresh(_ e:NativeEarlyMarginTrial.Entry) {
            guard let i=patchIndex(e.id),let c=work.patches[i].candidate else { return }
            e.state.canvas=canvas(e.id,c);e.state.revision=c.revision;e.state.partialCertified=c.partialErasureCertified
            e.method=c.method;e.sourceGlyphsVerified=c.sourceGlyphsVerified;e.sourceRemainingInk=c.sourceRemainingInk.map(Double.init)
        }
        func publish(_ e:NativeEarlyMarginTrial.Entry) {
            if let i=patchIndex(e.id),let c=work.patches[i].candidate {
                var surface=c.beginTrial();surface.rgba=e.state.canvas.rgba;surface.safe=e.state.canvas.safe
                surface.luminance=e.state.canvas.luminance;surface.surfaceRevision=e.state.revision
                _=c.commit(surface);c.partialErasureCertified=e.state.partialCertified;c.provisional=e.state.canvas.provisional
            }
            guard let index=cardIndex(e.id) else { return }
            workCards[index].sourceRestorationMetadata=e.state.metadata
            workCards[index].sourceRestorationMetadata["sourceErasurePolicy"]=e.state.policy
            workCards[index].sourceRestorationMetadata["residualRefused"]=e.state.residualRefused
        }
        func currentLayout()->NativeTranslationLayout {
            NativeTranslationLayout(imageSize:layout.imageSize,sourceRect:layout.sourceRect,viewport:layout.viewport,
                items:layout.items.map { item in workCards.first(where:{$0.item.id == item.id})?.item ?? item })
        }
        func ownership(_ index:Int)->(panels:[NativeEarlyBalloonOwnership.Panel],captions:[NativeEarlyBalloonOwnership.Caption],owner:Int)? {
            var panels:[NativeEarlyBalloonOwnership.Panel]=[],owner:Int?
            for i in workCards.indices {
                let card=workCards[i]
                for p in card.sourcePanels {
                    if i == index && !p.sourceErasure && owner == nil { owner=panels.count }
                    let explicit=p.clipped || p.captionUnionClipped || p.coverage != [p.rect]
                    panels.append(.init(id:card.item.id,rect:p.rect,clipped:p.clipped || p.captionUnionClipped,
                        sourceErasure:p.sourceErasure,explicitCoverage:explicit ? p.coverage:nil))
                }
                for p in card.backings { panels.append(.init(id:card.item.id,rect:p.frame,explicitCoverage:p.coverage == [p.frame] ? nil:p.coverage)) }
            }
            guard let owner else { return nil }
            let captions=workCards.map { card -> NativeEarlyBalloonOwnership.Caption in
                let c=work.patches.last(where:{$0.itemID == card.item.id})?.candidate
                return .init(id:card.item.id,sources:([card.item.sourceBounds]+card.item.auxiliaryInkRects).compactMap { pageRect($0,frame:sourceFrame) },
                    ink:cardInkRect(card),inpainted:card.sourceBackgroundKind == "inpainted",verified:c?.sourceErasureVerified ?? false,
                    provisional:c?.provisional ?? false,partial:c?.partialErasureCertified ?? false,erasureComplete:c?.erasureComplete ?? false,
                    canvasConnected:c != nil,canvasSize:c.map { CGSize(width:$0.surface.width,height:$0.surface.height) } ?? .zero)
            }
            return (panels,captions,owner)
        }
        let callbacks=NativeEarlyMarginTrial.Callbacks(publish:publish,refresh:refresh,fit:{ e,mode in
            guard let index=cardIndex(e.id),let ownership=ownership(index),let p=patchIndex(e.id),let candidate=work.patches[p].candidate else { return false }
            var card=workCards[index],item=card.item
            item.fontSize=card.style.fontSize;item.lineHeight=card.style.lineHeight
            item.typesettingForeground=rgb(card.style.foreground);item.typesettingOutlineRGB=rgb(card.style.outline)
            item.typesettingOutlineWidth=card.style.outlineWidth
            var interiorInspected=false,observed:NativeBalloonRelayout.Interior?
            let allows:(CGPoint)->Bool = { point in
                if !interiorInspected {
                    interiorInspected=true
                    observed=balloons.interior(card,sources:e.sourceBodyCoverage,unitCount:joinedUnitMembers(item)?.count ?? 0)
                }
                guard let interior=observed,!interior.tight else { return true }
                let x=Int(floor(Double(point.x-interior.rect.minX)*interior.scale)),y=Int(floor(Double(point.y-interior.rect.minY)*interior.scale))
                return x>=0 && y>=0 && x<interior.width && y<interior.height && interior.fill[y*interior.width+x] != 0
            }
            let proposed=NativeTypographyPostPolish.earlyBalloonFit(item:item,originalInk:cardInkRect(card),
                plate:ownership.panels[ownership.owner].rect,foreground:card.style.foreground,
                priorFont:card.artworkRecord.flatMap { Double($0["artworkOriginalFont"] ?? "").map { CGFloat($0) } },erasurePolicy:e.state.policy,
                currentLayout:currentLayout(),restoration:work,growth:growth,search:search,mode:mode,ownership:ownership,
                makeGrid:{
                    let c=candidate,g=c.descriptor
                    let input=NativeEarlyBalloonGrid.Input(geometry:.init(width:c.surface.width,height:c.surface.height,origin:g.crop.origin,
                        sx:Double(g.sx),sy:Double(g.sy),imageWidth:Double(c.imageSize.width),imageHeight:Double(c.imageSize.height),frame:c.frame),
                        safe:c.safe,paintedRGBA:c.rawRGBA,surfaceSafe:c.surfaceQuality?["safe"] as? Bool ?? false,
                        coefficients:c.surfaceQuality?["coefficients"] as? [[Double]],sourceRects:[c.sourceBounds]+c.auxiliaryInkRects,
                        sourceGlyph:c.sourceFontSize ?? 0,font:Double(card.style.fontSize),
                        otherLayers:ownership.panels.enumerated().filter{$0.offset != ownership.owner}.map{$0.element.rect} +
                            ownership.captions.filter{$0.id != e.id && $0.ink.width>0 && $0.ink.height>0}.map(\.ink))
                    guard let grid=NativeEarlyBalloonGrid.build(input,interiorAllows:allows,readExterior:{ crop,w,h in
                        try? reader?.read(x:Double(crop.minX),y:Double(crop.minY),sourceWidth:Double(crop.width),
                            sourceHeight:Double(crop.height),width:w,height:h)
                    }) else { return nil }
                    return .init(width:grid.width,height:grid.height,crop:grid.crop,kx:grid.kx,ky:grid.ky,sourceSpan:grid.sourceSpan,
                        clear:{grid.clear($0,$1,$2,$3)})
                },contentFits:{NativeTypographyPostPolish.contentFits(item:$0.item,typography:$0.shaped)})
            guard let proposed else { return false }
            card.item=proposed.item;card.typography=proposed.typography
            card.style.fontSize=proposed.item.fontSize;card.style.lineHeight=proposed.item.lineHeight;card.style.tracking = -proposed.item.fontSize*0.012
            card.finalFontSize=proposed.item.fontSize;card.item.typesettingText=proposed.item.typesettingText
            card.sourceRestorationMetadata.merge(proposed.metadata,uniquingKeysWith:{_,new in new})
            e.state.metadata.merge(proposed.metadata,uniquingKeysWith:{_,new in new})
            if let owner=card.sourcePanels.firstIndex(where:{!$0.sourceErasure}) { card.sourcePanels.remove(at:owner) }
            card.sourceBackgroundKind="inpainted";card.drawsPanel=false;card.usesFallbackVeil=false
            card.glyphPlateReleased=card.sourcePanels.allSatisfy(\.sourceErasure);card.restoredSurfaceFontFit=true
            workCards[index]=card;return true
        },largerPaper:{ e,remaining in
            guard let index=cardIndex(e.id),let pi=patchIndex(e.id),let old=work.patches[pi].candidate,let reader,
                  let patch=NativeEarlyMarginPaper.makePatch(item:workCards[index].item,fontSize:workCards[index].style.fontSize,
                    previous:old,layout:layout,reader:reader,remaining:&remaining,cleanupClip:work.cleanupGeometry?.clip),let c=patch.candidate else { return nil }
            savedPatches[e.id]=work.patches[pi];nextPatches[e.id]=patch
            var state=e.state;state.canvas=canvas(e.id,c);state.revision=c.revision;return state
        },replaceCandidate:{ e,old,reverting in
            guard let pi=patchIndex(e.id) else { return }
            if reverting,let saved=savedPatches[e.id] {
                work.patches[pi]=saved
                if let c=saved.candidate { var surface=c.beginTrial();surface.surfaceRevision=e.state.revision;_=c.commit(surface) }
            } else if let next=nextPatches[e.id] { work.patches[pi]=next }
            refresh(e);publish(e)
        },sourcePosition:{ e in
            applySourcePosition(cards:&workCards,restoration:work,layout:currentLayout(),settings:settings,ids:[e.id])
            guard cardIndex(e.id).map({workCards[$0].partialSourcePositionProof}) == true else { return false }
            e.state.policy="auxiliary-original-preserved"
            e.state.metadata["sourceErasureRestored"]="partial-mainbody"
            e.state.metadata["partialMainbodyProof"]="outlined-source-position"
            e.state.metadata["sourceErasureReleased"]="[]"
            refresh(e);publish(e);return true
        },eligible:{ e in
            guard let i=cardIndex(e.id),let pi=patchIndex(e.id),let c=work.patches[pi].candidate else { return false }
            return c.restorationFitEligible(item:workCards[i].item,fontSize:Double(workCards[i].style.fontSize),
                alreadyRestored:growth.context.growth.restoredInside.contains(e.id))
        },completeResidual:{ e in
            guard let i=cardIndex(e.id),let pi=patchIndex(e.id),let c=work.patches[pi].candidate,let source,
                  let panel=workCards[i].sourcePanels.last(where:{!$0.sourceErasure}) else { return nil }
            let sample=work.appearances[e.id]?.sourceSample
            return c.completeResidualErasure(item:workCards[i].item,fontSize:Double(workCards[i].style.fontSize),plate:panel.rect,
                sourceImage:source,otherSourceRects:layout.items.filter{$0.id != e.id}.flatMap{ ([$0.sourceBounds]+$0.auxiliaryInkRects).compactMap{pageRect($0,frame:sourceFrame)} },
                sampledForeground:NativeSourceColorSampler.rgb(sample?["foreground"]),sampledBackground:NativeSourceColorSampler.rgb(sample?["background"]))
        },residualKey:{ e in
            guard let pi=patchIndex(e.id),let c=work.patches[pi].candidate else { return "unavailable" }
            guard let i=cardIndex(e.id),let plate=workCards[i].sourcePanels.first(where:{!$0.sourceErasure}) else { return "" }
            return [Double(c.revision),Double(plate.rect.minX),Double(plate.rect.minY),Double(plate.rect.width),Double(plate.rect.height)]
                .enumerated().map { String(format:"%.15g",$0.offset == 0 ? $0.element:floor($0.element+0.5)) }.joined(separator:",")
        },commitResidual:{ e in growth.context.growth.restoredInside.insert(e.id) },donorCanvases:{
            work.patches.compactMap { patch in
                guard let id=patch.itemID,let candidate=patch.candidate else { return nil }
                return canvas(id,candidate)
            }
        })
        NativeEarlyMarginTrial.run(entries,budget:budget,callbacks:callbacks)
        growth.artworkSurfaceRemaining=budget.pixels.exterior;work.paperProposalRemaining=budget.paper
        cards=workCards;restoration=work
        growth.refresh(restoration:work,layout:currentLayout())
    }
    /// Frozen7266–7271 local proposals are still marked after provisional=false.
    /// Their source pixels become visible only after actual typography releases
    /// the owner plate onto the restored surface.
    static func commitLocalRestorationProposals(cards: inout [Card], restoration: inout NativeTranslationRestoration.Result,
        growth: NativeTypographyPostPolish.RendererGrowthSession? = nil, layout: NativeTranslationLayout? = nil) {
        restoration.patches.removeAll { patch in
            guard let candidate=patch.candidate,candidate.localRestorationProposal else { return false }
            guard let index=cards.firstIndex(where:{$0.item.id == patch.itemID}),
                  cards[index].sourceBackgroundKind == "inpainted" else { return true }
            candidate.provisional=false
            cards[index].sourceRestorationMetadata["localRestorationCommitted"]="true"
            return false
        }
        if let growth,let layout { growth.refresh(restoration:restoration,layout:layout) }
    }

}
