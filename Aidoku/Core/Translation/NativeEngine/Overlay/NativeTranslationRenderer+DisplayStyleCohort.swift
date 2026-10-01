import Foundation
import CoreGraphics

extension NativeTranslationRenderer {
    /// Dataset state produced by the actual preceding paint mutations. Missing
    /// state is never replaced with a guessed restoration/outline role.
    struct DisplayCohortMetadata {
        var backgroundKind: String?
        var strokeKind: String?
        var surfaceRange: [Double]?
            }
    struct DisplayCohortDiagnostic {
        var decisions: [NativeDisplayStyleCohort.Decision]
        var unclassifiedIDs: [String]
        var backingSamples: Int
    }
    @discardableResult
    static func reconcileDisplayStyleCohorts(cards: inout [Card],layout: NativeTranslationLayout,
                                             restoration: NativeTranslationRestoration.Result,
                                             settings: IPhoneOverlaySettings,
                                             gloss: NativeTranslationEffectGloss.Refinement,
                                             metadata: [String:DisplayCohortMetadata]) -> DisplayCohortDiagnostic {
        typealias Policy=NativeDisplayStyleCohort
        guard settings.renderedBackgroundOpacity==1,settings.preserveSourceTextColor,
              settings.preserveSourceBackgroundColor,layout.items.count<=256 else {
            return .init(decisions:[],unclassifiedIDs:[],backingSamples:0)
        }
        let budget=Policy.BackingBudget(),snapshot=cards
        let panels=snapshot.flatMap {$0.sourcePanels.filter {!$0.sourceErasure}.map {Policy.Panel(rect:$0.rect,color:$0.background)}}
        var members:[Policy.Member]=[],ownerIndices:[String:Int]=[:],ownersAreNodes=Set<String>(),unclassified:[String]=[]
        func triple(_ value:Any?)->[Double]? {
            guard let result=NativeRestorationPixels.rgb(value)?.channels,Policy.valid(result) else{return nil};return result
        }
        func visible(_ card:Card)->Bool {!gloss.hiddenIDs.contains(card.item.id) && !gloss.removedLayerIDs.contains(card.item.id)}
        for card in snapshot {
            let item=card.item,id=item.id
            guard item.sourceColorEligible,visible(card),!item.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
                  let sample=restoration.appearances[id]?.sourceSample,let sampled=triple(sample["foreground"]) ?? triple(sample["displayForeground"]),
                  let fill=rgb(card.style.foreground),Policy.valid(fill) else{continue}
            let state=metadata[id]
            if state?.backgroundKind==nil || state?.strokeKind==nil {unclassified.append(id)}
            let mode=state?.backgroundKind
            let ring=card.outlinedRecord ?? card.outlineEvidence?.ringData ?? [:]
            let kind=ring["kind"] as? String,action=ring["action"] as? String
            let stroke=card.style.outlineWidth>0 ? rgb(card.style.outline):nil
            let ink=cardInkRect(card)
            var owner:NativeTranslationSourceStylePostPolish.Panel?,ownerIsNode=false
            if mode=="rotated-panel" {
                if let i=card.sourcePanels.firstIndex(where:{!$0.sourceErasure && $0.rotated}) {owner=card.sourcePanels[i];ownerIndices[id]=i}
                else if card.drawsPanel,let background=rgb(card.background) {
                    owner = .init(rect:card.item.rect,background:background,coverage:[]);ownerIsNode=true;ownersAreNodes.insert(id)
                }
            } else if mode=="readability-panel" {
                let own=card.sourcePanels.indices.filter {!card.sourcePanels[$0].sourceErasure}
                // The actual native owner is the containing source panel; a
                // root child chooses its own standalone plate only if unique.
                if own.count==1 {owner=card.sourcePanels[own[0]];ownerIndices[id]=own[0]}
            }
            let plate=owner.flatMap {Policy.valid($0.background) ? $0.background:nil}
            var backing=plate.map {[Policy.luminance($0),Policy.luminance($0)]}
            if backing==nil,(mode=="inpainted" || mode=="slanted-glyph-restored") {
                if let patch=restoration.patches.last(where:{$0.itemID==id}),let geometry=patch.rasterGeometry {
                    let input=Policy.BackingInput(ink:ink,frame:geometry.frame,imageWidth:Double(geometry.imageSize.width),
                        imageHeight:Double(geometry.imageSize.height),originX:Double(geometry.origin.x),originY:Double(geometry.origin.y),
                        scaleX:Double(geometry.scale.width),scaleY:Double(geometry.scale.height),width:patch.image.width,height:patch.image.height,
                        luminance:patch.surfaceLuminance,connected:settings.visible && valid(patch.rect) && !gloss.removedLayerIDs.contains(id),fallback:state?.surfaceRange)
                    backing=Policy.backing(input,panels:panels,budget:budget)
                } else if let fallback=state?.surfaceRange {
                    let empty=Policy.BackingInput(ink:ink,frame:layout.sourceRect,imageWidth:0,imageHeight:0,originX:0,originY:0,
                        scaleX:0,scaleY:0,width:0,height:0,luminance:nil,connected:false,fallback:fallback)
                    backing=Policy.backing(empty,panels:panels,budget:budget)
                }
            }
            let confidence=sample["confidence"] as? [String:Any] ?? [:]
            let sampledStroke=(confidence["stroke"] as? Double ?? 0)>=0.55 ? triple(sample["stroke"]):nil
            let foreign=owner.map {panel in snapshot.filter {$0.item.id != id}.contains {other in
                other.foreignFills.contains {$0.color==panel.background}
            }} ?? false
            // Native panels have one declared owner. Foreign text is queried
            // by the policy's shared physical-ink contrast test, independently.
            let alone=(owner?.hasForeignChildren != true) && !foreign
            members.append(.init(id:id,sampled:sampled,fill:fill,stroke:stroke,sampledStroke:sampledStroke,
                sampledBack:triple(sample["background"]),strokeSource:state?.strokeKind ?? "",glyph:item.sourceFontSize.flatMap {$0>0 ? Double($0):nil},
                font:Double(card.finalFontSize),outlined:kind=="outline",
                locked:card.displayLetteringRecord != nil || sample["displayLettering"] as? Bool == true || mode=="display-restored" || card.style.outlineGlow>0,
                strokeLocked:stroke != nil && ["outline","restored-outline","hollow","kept"].contains(action ?? ""),
                fillLocked:action=="outline-as-fill",ringKind:kind,ringCore:triple(ring["core"]),
                ringSurface:ring["surface"] as? [Double],ringPlateTo:ring["plateTo"] != nil,
                plate:plate,backing:backing,ink:ink,ownerRect:owner?.rect,ownerIsNode:ownerIsNode,ownerAlone:alone))
        }
        let decisions=Policy.decisions(members)
        for decision in decisions {
            guard let index=cards.firstIndex(where:{$0.item.id==decision.id}) else{continue}
            if let plate=decision.plate {
                if ownersAreNodes.contains(decision.id) {cards[index].background=color(plate.map {CGFloat($0)})}
                else if let owner=ownerIndices[decision.id],cards[index].sourcePanels.indices.contains(owner) {cards[index].sourcePanels[owner].background=plate}
                for i in cards[index].backings.indices {cards[index].backings[i].color=plate}
            }
            if let fill=decision.fill {cards[index].style.foreground=color(fill.map {CGFloat($0)})}
            if decision.dropStroke {
                cards[index].style.outline=nil;cards[index].style.outlineWidth=0;cards[index].strokePreserved=false
                cards[index].sourceStrokeKind="none"
            }
            cards[index].typography=remeasureTypography(cards[index])
        }
        return .init(decisions:decisions,unclassifiedIDs:unclassified,backingSamples:600_000-budget.samples)
    }
}
