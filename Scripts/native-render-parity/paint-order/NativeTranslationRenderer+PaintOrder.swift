import CoreGraphics
import Foundation
import UIKit

extension NativeTranslationRenderer {
    enum PaintOperation { case column(Int),panel(Int,Int),rotated(Int),backing(Int,Int),node(Int),parent(Int,Int) }
    struct PaintCommand { let operation:PaintOperation; let z:Int; let order:Double }
    struct PaintScene { let nodes:[NativeTranslationPaintOrder.Node];let layers:[NativeTranslationPaintOrder.Layer];let commands:[PaintCommand] }
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
            guard visible else {continue}
            let nodeID="node:\(i)",rotID="rotated:\(i)",parent=card.captionParentPlate ? card.sourcePanels.lastIndex(where:{!$0.sourceErasure}):nil
            let isRotated=card.rotatesSourcePanels || (card.item.rotation != 0 && card.drawsPanel && card.straightenedPanelRect == nil) ||
                (card.rotatesSourcePanels && card.glyphCoverOwnerPanel != nil)
            let nodeOrder=Double(i),nodeQuad=physicalQuad(card.item.rect.offsetBy(dx:card.textShift.x,dy:card.textShift.y),
                anchor:card.item.rect.offsetBy(dx:card.textShift.x,dy:card.textShift.y),angle:card.effectiveTextRotation)
            var nodeLayerID=nodeID
            for (p,panel) in card.sourcePanels.enumerated() where !isRotated {
                let id="panel:\(i):\(p)",z=parent==p ? card.sourcePanelZ:1,order=count+Double(i)+Double(p)*0.001
                let coverage=panel.clipped && !panel.coverage.isEmpty ? panel.coverage:[panel.rect]
                layers.append(.init(id:id,z:z,order:order,quad:physicalQuad(panel.rect,anchor:panel.rect,angle:0),coverage:coverage,
                    usesQuad:false,opaque:true,shown:true,background:panel.background))
                if parent==p {nodeLayerID=id;commands.append(.init(operation:.parent(i,p),z:z,order:order))}
                else {commands.append(.init(operation:.panel(i,p),z:z,order:order))}
            }
            for (b,backing) in card.backings.enumerated() {
                let id="backing:\(i):\(b)",order=count+Double(i)-0.5+Double(b)*0.001
                layers.append(.init(id:id,z:card.sourcePanelZ,order:order,quad:physicalQuad(backing.frame,anchor:backing.frame,angle:0),
                    coverage:backing.coverage.isEmpty ? [backing.frame]:backing.coverage,usesQuad:false,opaque:true,shown:true,background:backing.color))
                commands.append(.init(operation:.backing(i,b),z:card.sourcePanelZ,order:order))
            }
            if isRotated {
                let panel=readabilityOwnerPanel(card),rect=panel?.rect ?? card.sourcePlateRect
                let order=card.rotatedPlateOrder ?? count*2+Double(i)
                layers.append(.init(id:rotID,z:card.rotatedPlateZ,order:order,
                    quad:physicalQuad(rect,anchor:card.sourcePlateRect,angle:card.item.rotation),usesQuad:true,
                    opaque:true,shown:true,background:card.glyphCoverOwnerPanel != nil ? nil:panel?.background ?? rgb(card.background)))
                commands.append(.init(operation:.rotated(i),z:card.rotatedPlateZ,order:order))
            }
            if parent == nil {
                layers.append(.init(id:nodeID,z:card.textZ,order:nodeOrder,quad:nodeQuad,usesQuad:true,
                    opaque:card.drawsPanel && !isRotated && (settings.renderedBackgroundOpacity>0.5 || card.usesFallbackVeil),shown:true,background:rgb(card.background)))
                commands.append(.init(operation:.node(i),z:card.textZ,order:nodeOrder))
            }
            nodes.append(.init(id:card.item.id,layerID:nodeLayerID,glyphs:cardPageRangeRects(card),quad:nodeQuad,
                isRoot:parent==nil,opaque:card.drawsPanel && !isRotated && (settings.renderedBackgroundOpacity>0.5 || card.usesFallbackVeil),
                rotatingPanel:isRotated,ownRotatedPlate:isRotated ? rotID:nil,foreground:rgb(card.style.foreground)))
            if !columnSourceErasureRects(card,settings:settings).isEmpty {
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
        context:CGContext,pixelSnapScale:CGFloat?) {
        let scene=paintScene(cards:cards,gloss:gloss,settings:settings)
        let ordered=scene.commands.enumerated().sorted { a,b in
            a.element.z != b.element.z ? a.element.z<b.element.z:
                a.element.order != b.element.order ? a.element.order<b.element.order:a.offset<b.offset
        }.map(\.element)
        for command in ordered {
            if Task.isCancelled {return}
            switch command.operation {
            case .column(let i):drawColumnSourceErasure(cards[i],context:context,settings:settings)
            case .panel(let i,let p):
                var card=cards[i];card.sourcePanels=[card.sourcePanels[p]]
                draw(card,context:context,opacity:CGFloat(settings.renderedBackgroundOpacity),paintsBackground:false,paintsText:false,paintsSourcePanels:true,pixelSnapScale:pixelSnapScale)
            case .rotated(let i):
                draw(cards[i],context:context,opacity:CGFloat(settings.renderedBackgroundOpacity),paintsBackground:true,paintsText:false,paintsSourcePanels:true,pixelSnapScale:pixelSnapScale)
            case .parent(let i,let p):
                var card=cards[i];card.sourcePanels=[card.sourcePanels[p]]
                draw(card,context:context,opacity:CGFloat(settings.renderedBackgroundOpacity),paintsBackground:false,paintsText:true,paintsSourcePanels:true,pixelSnapScale:pixelSnapScale)
            case .node(let i):
                draw(cards[i],context:context,opacity:CGFloat(settings.renderedBackgroundOpacity),paintsBackground:cards[i].item.rotation==0,paintsText:true,paintsSourcePanels:false,pixelSnapScale:pixelSnapScale)
            case .backing(let i,let b):
                let backing=cards[i].backings[b]
                context.saveGState();context.addPath(CGPath(roundedRect:backing.frame,cornerWidth:3,cornerHeight:3,transform:nil));context.clip()
                context.addRects(backing.coverage);context.clip();context.setFillColor(color(backing.color.map{CGFloat($0)}));context.fill(backing.frame);context.restoreGState()
            }
        }
    }
}
