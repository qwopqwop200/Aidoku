import CoreGraphics
import Foundation
import UIKit

extension NativeTranslationRenderer {
    enum PaintOperation { case column(Int),panel(Int,Int),rotated(Int),backing(Int,Int),node(Int),parent(Int,Int),transparentOwner(Int),cover(Int),forced(Int) }
    struct PaintCommand { let operation:PaintOperation; let z:Int; let order:Double }
    struct PaintScene { let nodes:[NativeTranslationPaintOrder.Node];let layers:[NativeTranslationPaintOrder.Layer];let commands:[PaintCommand] }
    /// DOM append tokens are local to one render. Raising z alone preserves the token.
    static func nextRootOrder(cards: [Card]) -> Double {
        max(Double(cards.count * 4), cards.flatMap {
            [$0.textRootOrder, $0.rotatedPlateOrder, $0.glyphCoverLayerOrder, $0.lateSourcePatchOrder].compactMap { $0 }
        }.max() ?? 0) + 1
    }
    static func appendTextToRoot(cards: inout [Card], index: Int) {
        cards[index].textRootOrder = nextRootOrder(cards: cards)
        cards[index].captionParentPlate = false; cards[index].captionParentOwner = nil
    }
    static func reappendRotatedPlates(cards: inout [Card], gloss: NativeTranslationEffectGloss.Refinement) {
        for index in cards.indices where !gloss.removedLayerIDs.contains(cards[index].item.id) {
            let card = cards[index]
            // Glyph-cover canvases are inserted immediately before the owner
            // in the frozen rotatedPlates array; the z1 loop appends both.
            if card.glyphCoverPatch != nil, card.glyphCoverLayerZ == 1,
               card.rotatesSourcePanels || card.item.rotation != 0 {
                cards[index].glyphCoverLayerOrder = nextRootOrder(cards: cards)
            }
            guard card.rotatedPlateZ == 1, !card.sourceLayersSuppressed,
                (card.rotatesSourcePanels && (!card.sourcePanels.isEmpty || card.glyphCoverOwnerPanel != nil)) ||
                (card.item.rotation != 0 && card.drawsPanel && card.straightenedPanelRect == nil) else { continue }
            cards[index].rotatedPlateOrder = nextRootOrder(cards: cards)
        }
    }
    static func drawSourcePatch(_ patch: SourcePatch, context: CGContext, appliesCanvasClip: Bool = true,
                                usesLiveTextureSampling: Bool = false, canvasSession: NativeCanvasTextureResampler.Session? = nil,
                                canvasBacking: NativeCanvasBacking? = nil, allowsOpaqueAffineSampling: Bool = false) {
        let canonicalBacking = usesLiveTextureSampling && (canvasBacking?.matchesFreshState(context) ?? false)
        context.saveGState()
        defer { context.restoreGState() }
        if appliesCanvasClip, let rawClip = patch.cleanupClip {
            var clip: CGRect? = rawClip
            if let authored = patch.authoredCanvasRect {
                let matrix = context.ctm
                let xScale = hypot(matrix.a, matrix.b), yScale = hypot(matrix.c, matrix.d)
                // The observed CSS device-scale contract is uniform. Keep the
                // prior global clip for unsupported nonuniform transforms.
                if xScale.isFinite, yScale.isFinite, xScale > 0, Float(xScale) == Float(yScale) {
                    clip = NativeSourceCanvasClip.liveClip(authoredRect: authored, domRect: patch.rect,
                        cleanupClip: rawClip, deviceScale: xScale)
                }
            }
            if let clip {
                guard clip.width > 0, clip.height > 0 else { return }
                context.clip(to: clip)
            }
        }
        // Live canvas painting rounds CSS edges independently of its clip
        // reference box. Saved source masks retain their DOM-used frame.
        let frame: CGRect
        if appliesCanvasClip {
            guard let live = NativeSourceCanvasImageFrame.liveFrame(domRect: patch.rect) else { return }
            frame = live
        } else { frame = patch.rect }
        if usesLiveTextureSampling {
            let matrix = context.ctm
            let scale = matrix.a
            let fullSize = CGSize(width: frame.width * scale, height: frame.height * scale)
            let deviceOrigin = context.convertToDeviceSpace(frame.origin)
            // The experimental live path currently proves axis-aligned,
            // integral device pixels only. Preserve CG sampling elsewhere.
            if scale.isFinite, scale > 0, matrix.b == 0, matrix.c == 0, abs(matrix.d) == scale,
               [fullSize.width, fullSize.height, deviceOrigin.x, deviceOrigin.y].allSatisfy({ $0.isFinite && $0.rounded(.towardZero) == $0 }),
               fullSize.width > 0, fullSize.height > 0 {
                let visible = frame.intersection(context.boundingBoxOfClipPath)
                guard visible.width > 0, visible.height > 0 else { return }
                let left = max(0, floor((visible.minX - frame.minX) * scale))
                let top = max(0, floor((visible.minY - frame.minY) * scale))
                let right = min(fullSize.width, ceil((visible.maxX - frame.minX) * scale))
                let bottom = min(fullSize.height, ceil((visible.maxY - frame.minY) * scale))
                let crop = CGRect(x: left, y: top, width: right - left, height: bottom - top)
                let tileFrame = CGRect(x: frame.minX + left / scale,
                    y: frame.minY + top / scale, width: crop.width / scale, height: crop.height / scale)
                do {
                    // Expansion/identity only: no new minification contract is
                    // inferred from the separate linear-filter primitive.
                    if canonicalBacking, fullSize.width >= CGFloat(patch.image.width),
                       fullSize.height >= CGFloat(patch.image.height),
                       let background = canvasBacking?.backgroundRGBA(context: context, userRect: tileFrame) {
                        let composited = try NativeCanvasTextureResampler.compositeCanvasImage(image: patch.image,
                            destinationPixels: fullSize, cropPixels: crop, backgroundRGBA: background, session: canvasSession)
                        context.interpolationQuality = .none
                        UIImage(cgImage: composited).draw(in: tileFrame, blendMode: .copy, alpha: 1)
                        return
                    }
                    let tile = try NativeCanvasTextureResampler.canvasImage(image: patch.image,
                        destinationPixels: fullSize, cropPixels: crop, session: canvasSession)
                    context.interpolationQuality = .none
                    UIImage(cgImage: tile).draw(in: tileFrame)
                    return
                } catch is CancellationError { return }
                catch { /* Unsupported hardware/bounds retain the existing CG path. */ }
            }
            // Only fresh bitmap owners attest normal blending and alpha one.
            // This permission does not widen destination-byte/clip ownership.
            if allowsOpaqueAffineSampling, appliesCanvasClip, patch.cleanupClip == nil,
               let canvasSession {
                do {
                    if try drawOpaqueAffineSourcePatch(patch, context: context, session: canvasSession) { return }
                } catch is CancellationError { return }
                catch { /* Unsupported source, geometry or hardware retains CG painting. */ }
            }
        }
        UIImage(cgImage: patch.image).draw(in: frame)
    }
    static func physicalQuad(_ rect:CGRect,anchor:CGRect,angle:CGFloat)->[CGPoint] {
        let cosine=cos(angle),sine=sin(angle)
        return [CGPoint(x:rect.minX,y:rect.minY),CGPoint(x:rect.maxX,y:rect.minY),CGPoint(x:rect.maxX,y:rect.maxY),CGPoint(x:rect.minX,y:rect.maxY)].map { p in
            CGPoint(x:anchor.midX+(p.x-anchor.midX)*cosine-(p.y-anchor.midY)*sine,
                y:anchor.midY+(p.x-anchor.midX)*sine+(p.y-anchor.midY)*cosine)
        }
    }
    static func paintScene(cards:[Card],gloss:NativeTranslationEffectGloss.Refinement,settings:IPhoneOverlaySettings)->PaintScene {
        let count=Double(cards.count)
        var nodes:[NativeTranslationPaintOrder.Node]=[],layers:[NativeTranslationPaintOrder.Layer]=[],commands:[PaintCommand]=[]
        for (i,card) in cards.enumerated() {
            let visible = !gloss.hiddenIDs.contains(card.item.id) && !gloss.removedLayerIDs.contains(card.item.id)
            guard !gloss.removedLayerIDs.contains(card.item.id) else {continue}
            // Cover canvases are independent siblings. A later owner append
            // must not move its previously inserted canvas along with the plate.
            if card.glyphCoverPatch != nil {
                commands.append(.init(operation:.cover(i),z:card.glyphCoverLayerZ ?? 1,
                    order:card.glyphCoverLayerOrder ?? count+Double(i)))
            }
            let nodeID="node:\(i)",rotID="rotated:\(i)",parent=card.captionParentPlate && card.glyphCoverOwnerPanel == nil ? card.sourcePanels.lastIndex(where:{!$0.sourceErasure}):nil
            let transparentParent = card.captionParentPlate && card.glyphCoverOwnerPanel != nil
            let isRotated=(card.rotatesSourcePanels && (!card.sourcePanels.isEmpty || card.glyphCoverOwnerPanel != nil)) ||
                (card.item.rotation != 0 && card.drawsPanel && card.straightenedPanelRect == nil)
            let nodeOrder=card.textRootOrder ?? Double(i),nodeFrame=shiftedTextNodeRect(card)
            let nodeQuad=physicalQuad(nodeFrame,anchor:nodeFrame,angle:card.effectiveTextRotation)
            var nodeLayerID=nodeID
            for (p,panel) in card.sourcePanels.enumerated() where !isRotated && !card.sourceLayersSuppressed {
                let id="panel:\(i):\(p)",z=card.sourcePanelZ,order=count+Double(i)+Double(p)*0.001
                let coverage=panel.clipped && !panel.coverage.isEmpty ? panel.coverage:[panel.rect]
                layers.append(.init(id:id,z:z,order:order,quad:physicalQuad(panel.rect,anchor:panel.rect,angle:0),coverage:coverage,
                    usesQuad:false,opaque:true,shown:true,background:panel.background))
                if parent==p {nodeLayerID=id;commands.append(.init(operation:.parent(i,p),z:z,order:order))}
                else {commands.append(.init(operation:.panel(i,p),z:z,order:order))}
            }
            if !isRotated, let owner=card.glyphCoverOwnerPanel, !card.sourceLayersSuppressed {
                let id="transparent-owner:\(i)",z=transparentParent ? card.sourcePanelZ:1,order=count+Double(i)
                layers.append(.init(id:id,z:z,order:order,quad:physicalQuad(owner.rect,anchor:owner.rect,angle:0),
                    coverage:owner.coverage,usesQuad:false,opaque:false,shown:true))
                commands.append(.init(operation:.transparentOwner(i),z:z,order:order))
                if transparentParent {nodeLayerID=id}
            }
            for (b,backing) in card.backings.enumerated() where !card.sourceLayersSuppressed {
                let id="backing:\(i):\(b)",order=count*2+Double(i)+Double(b)*0.001
                layers.append(.init(id:id,z:card.sourcePanelZ,order:order,quad:physicalQuad(backing.frame,anchor:backing.frame,angle:0),
                    coverage:backing.coverage.isEmpty ? [backing.frame]:backing.coverage,usesQuad:false,opaque:true,shown:true,background:backing.color))
                commands.append(.init(operation:.backing(i,b),z:card.sourcePanelZ,order:order))
            }
            if isRotated && !card.sourceLayersSuppressed {
                let panel=readabilityOwnerPanel(card),rect=panel?.rect ?? card.sourcePlateRect
                let order=card.rotatedPlateOrder ?? count*3+Double(i)
                // Frozen rotated-plate selector admits connected shown layers even
                // after their background becomes transparent; this is the policy
                // occluder flag, not a claim that the stored RGB is still painted.
                layers.append(.init(id:rotID,z:card.rotatedPlateZ,order:order,
                    quad:physicalQuad(rect,anchor:card.sourcePlateRect,angle:card.item.rotation),usesQuad:true,
                    opaque:true,shown:true,background:card.glyphCoverOwnerPanel != nil ? nil:panel?.background ?? rgb(card.background)))
                commands.append(.init(operation:.rotated(i),z:card.rotatedPlateZ,order:order))
            }
            if parent == nil && !transparentParent && visible {
                layers.append(.init(id:nodeID,z:card.textZ,order:nodeOrder,quad:nodeQuad,usesQuad:true,
                    opaque:card.drawsPanel && !isRotated && (settings.renderedBackgroundOpacity>0.5 || card.usesFallbackVeil),shown:true,background:rgb(card.background)))
                commands.append(.init(operation:.node(i),z:card.textZ,order:nodeOrder))
            }
            if visible {nodes.append(.init(id:card.item.id,layerID:nodeLayerID,glyphs:cardPageRangeRects(card),quad:nodeQuad,
                isRoot:parent==nil && !transparentParent,opaque:card.drawsPanel && !isRotated && (settings.renderedBackgroundOpacity>0.5 || card.usesFallbackVeil),
                rotatingPanel:isRotated,ownRotatedPlate:isRotated ? rotID:nil,foreground:rgb(card.style.foreground)))}
            if !card.sourceLayersSuppressed && !columnSourceErasureRects(card,settings:settings).isEmpty {
                commands.append(.init(operation:.column(i),z:1,order:-count+Double(i)))
            }
        }
        return .init(nodes:nodes,layers:layers,commands:commands)
    }
    static func applyPaintOrderLifts(cards:inout [Card],gloss:NativeTranslationEffectGloss.Refinement,
        layout:NativeTranslationLayout,settings:IPhoneOverlaySettings) {
        let scene=paintScene(cards:cards,gloss:gloss,settings:settings)
        let result=NativeTranslationPaintOrder.apply(nodes:scene.nodes,layers:scene.layers,itemCount:layout.items.count)
        for node in result.nodes {
            guard let i=cards.firstIndex(where:{$0.item.id==node.id}) else {continue}
            cards[i].paintOrderLift=node.lift
            if let layer=result.layers.first(where:{$0.id=="node:\(i)"}) {cards[i].textZ=layer.z}
            if let plate=result.layers.first(where:{$0.id=="rotated:\(i)"}) {
                cards[i].rotatedPlateZ=plate.z;cards[i].rotatedPlateOrder=plate.order
            }
        }
    }
    static func drawPaintScene(cards:[Card],gloss:NativeTranslationEffectGloss.Refinement,settings:IPhoneOverlaySettings,
        context:CGContext,pixelSnapScale:CGFloat?,latePatches:[SourcePatch] = [],
        usesLiveTextureSampling:Bool=false,canvasSession:NativeCanvasTextureResampler.Session?=nil,canvasBacking:NativeCanvasBacking?=nil,
        allowsOpaqueAffineSampling:Bool=false) {
        let ordered = orderedPaintCommands(cards: cards, gloss: gloss, settings: settings, latePatches: latePatches)
        for command in ordered {
            if Task.isCancelled { return }
            drawPaintCommand(command, cards: cards, gloss: gloss, settings: settings, context: context,
                pixelSnapScale: pixelSnapScale, latePatches: latePatches, usesLiveTextureSampling: usesLiveTextureSampling,
                canvasSession: canvasSession, canvasBacking: canvasBacking, allowsOpaqueAffineSampling: allowsOpaqueAffineSampling)
        }
    }
    static func orderedPaintCommands(cards: [Card], gloss: NativeTranslationEffectGloss.Refinement,
                                     settings: IPhoneOverlaySettings, latePatches: [SourcePatch]) -> [PaintCommand] {
        let scene=paintScene(cards:cards,gloss:gloss,settings:settings)
        let patchCommands = latePatches.enumerated().map { i, patch in PaintCommand(operation: .forced(i), z: 1, order: patch.liveOrder ?? 0) }
        return (scene.commands + patchCommands).enumerated().sorted { a,b in
            a.element.z != b.element.z ? a.element.z<b.element.z:
                a.element.order != b.element.order ? a.element.order<b.element.order:a.offset<b.offset
        }.map(\.element)
    }
    static func drawPaintCommand(_ command: PaintCommand, cards: [Card], gloss: NativeTranslationEffectGloss.Refinement,
        settings: IPhoneOverlaySettings, context: CGContext, pixelSnapScale: CGFloat?, latePatches: [SourcePatch],
        usesLiveTextureSampling: Bool, canvasSession: NativeCanvasTextureResampler.Session?, canvasBacking: NativeCanvasBacking?,
        allowsOpaqueAffineSampling: Bool) {
        switch command.operation {
        case .forced(let i):drawSourcePatch(latePatches[i],context:context,usesLiveTextureSampling:usesLiveTextureSampling,canvasSession:canvasSession,canvasBacking:canvasBacking,allowsOpaqueAffineSampling:allowsOpaqueAffineSampling)
        case .column(let i):drawColumnSourceErasure(cards[i],context:context,settings:settings)
        case .panel(let i,let p):
            var card=cards[i];card.sourcePanels=[card.sourcePanels[p]];card.glyphCoverPatch=nil
            draw(card,context:context,opacity:CGFloat(settings.renderedBackgroundOpacity),paintsBackground:false,paintsText:false,paintsSourcePanels:true,pixelSnapScale:pixelSnapScale,canvasBacking:usesLiveTextureSampling ? canvasBacking:nil)
        case .rotated(let i):
            var card=cards[i]
            card.glyphCoverPatch=nil
            draw(card,context:context,opacity:CGFloat(settings.renderedBackgroundOpacity),paintsBackground:true,paintsText:false,paintsSourcePanels:true,pixelSnapScale:pixelSnapScale)
        case .parent(let i,let p):
            var card=cards[i];card.sourcePanels=[card.sourcePanels[p]];card.glyphCoverPatch=nil
            draw(card,context:context,opacity:CGFloat(settings.renderedBackgroundOpacity),paintsBackground:false,paintsText:!gloss.hiddenIDs.contains(card.item.id),paintsSourcePanels:true,pixelSnapScale:pixelSnapScale,canvasBacking:usesLiveTextureSampling ? canvasBacking:nil)
        case .cover(let i):
            if pixelSnapScale == nil,let patch=cards[i].glyphCoverPatch {drawSourcePatch(patch,context:context,usesLiveTextureSampling:usesLiveTextureSampling,canvasSession:canvasSession,canvasBacking:canvasBacking,allowsOpaqueAffineSampling:allowsOpaqueAffineSampling)}
        case .transparentOwner(let i):
            var card=cards[i];card.sourcePanels=[];card.glyphCoverPatch=nil
            draw(card,context:context,opacity:CGFloat(settings.renderedBackgroundOpacity),paintsBackground:false,
                paintsText:cards[i].captionParentPlate && !gloss.hiddenIDs.contains(cards[i].item.id),paintsSourcePanels:true,pixelSnapScale:pixelSnapScale)
        case .node(let i):
            draw(cards[i],context:context,opacity:CGFloat(settings.renderedBackgroundOpacity),paintsBackground:cards[i].item.rotation==0,paintsText:true,paintsSourcePanels:false,pixelSnapScale:pixelSnapScale)
        case .backing(let i,let b):
            drawSourceBacking(cards[i].backings[b],context:context,pixelSnapScale:pixelSnapScale)
        }
    }
}
