import CoreGraphics
import Foundation

/// Frozen6717–7176 ordered certificate/layout trials. Actual typography and
/// candidate replacement stay explicit callbacks, never implied by source proof.
enum NativeEarlyMarginTrial {
    enum FitMode:String { case normal, incomplete, partial }
    struct State {
        var canvas:NativeEarlyMarginPixels.Canvas
        var revision=0
        var partialCertified=false
        var policy:String?
        var residualRefused:String?
        var metadata:[String:String]=[:]
    }
    final class Entry {
        var state:State
        var coverage:NativeFinalRestorationTrial.MarginCoverage
        var sourceVertical=false
        var sourceSingleColumn=false
        var balancedColumn=false
        var rotation=0.0
        var sourceTextOnly=false
        var nodePresent=true
        var hasPanel=true
        var hasTypographyEntry=true
        var method:String?
        var sourceGlyphsVerified=false
        var sourceRemainingInk:Double?
        var sourceCorePixels:Double
        var sourceBodyCoverage:[CGRect] = []
        init(state:State,coverage:NativeFinalRestorationTrial.MarginCoverage,sourceCorePixels:Double) {
            self.state=state;self.coverage=coverage;self.sourceCorePixels=sourceCorePixels
        }
        var id:String { state.canvas.id }
    }
    struct Callbacks {
        /// Publish changed source proof and policy before measuring real glyphs.
        var publish:(_ entry:Entry)->Void
        /// Refresh transport after completeResidualErasure/commit callbacks.
        var refresh:(_ entry:Entry)->Void
        /// Each failed fit rolls back all caption geometry/style itself.
        var fit:(_ entry:Entry,_ mode:FitMode)->Bool
        /// Construct actual larger96px enclosed-paper proposal after budget charge.
        var largerPaper:(_ entry:Entry,_ remaining:inout Int)->State?
        /// Replace/restore full retained candidate transport, including dimensions.
        var replaceCandidate:(_ entry:Entry,_ previous:State,_ reverting:Bool)->Void
        var sourcePosition:(_ entry:Entry)->Bool
        var eligible:(_ entry:Entry)->Bool
        var completeResidual:(_ entry:Entry)->(() -> Void)?
        var residualKey:(_ entry:Entry)->String
        var commitResidual:(_ entry:Entry)->Void
        var donorCanvases:(() -> [NativeEarlyMarginPixels.Canvas])? = nil
    }
    final class Budget {
        let pixels:NativeEarlyMarginPixels.Budget
        var partial=2_097_152
        var paper:Int
        init(artworkRemaining:Int,paperRemaining:Int) {
            pixels = .init(artworkSurfaceRemaining:artworkRemaining);paper=paperRemaining
        }
    }
    static func run(_ entries:[Entry],budget:Budget,callbacks:Callbacks) {
        var certified=Set<String>(),pending:[Entry]=[]
        func attached(_ e:Entry)->Bool {
            e.sourceVertical && !e.sourceSingleColumn && NativeResidualTopology.hasAttachedLeadingInk(
                safe:e.state.canvas.safe,width:e.state.canvas.width,height:e.state.canvas.height,
                core:e.coverage.core,glyph:e.coverage.glyphSize)
        }
        func direct(_ e:Entry,group:Bool=false)->Bool {
            let c=e.state.canvas,surface=NativeResidualTopology.Surface(width:c.width,height:c.height,rgba:c.rgba,safe:c.safe,luminance:c.luminance)
            return NativeFinalRestorationTrial.certifiesEarlyMargin(surface:surface,coverage:e.coverage,
                sourceVertical:e.sourceVertical,sourceSingleColumn:e.sourceSingleColumn,restorationMethod:e.method,
                sourceGlyphsVerified:e.sourceGlyphsVerified,sourceErasureVerified:c.erasureVerified,groupRecheck:group)
        }
        func certify(_ e:Entry,_ kind:String="true") {
            certified.insert(e.id);e.state.metadata["sourceErasureRestored"]=kind
            e.state.metadata["sourceErasureReleased"] = json(e.coverage.viewportRects.map { [Double($0.minX),Double($0.minY),Double($0.width),Double($0.height)] })
            callbacks.publish(e)
        }
        for e in entries {
            let c=e.state.canvas,n=c.width*c.height
            guard c.erasureComplete,e.nodePresent,e.hasPanel,!e.balancedColumn,e.rotation==0,!e.sourceTextOnly,n<=budget.pixels.certification else { continue }
            budget.pixels.certification-=n
            if direct(e) {
                let g=c.geometry
                e.state.metadata["sourceErasureCrop"] = json([Double(g.frame.minX)+Double(g.origin.x)/Double(g.imageSize.width)*Double(g.frame.width),
                    Double(g.frame.minY)+Double(g.origin.y)/Double(g.imageSize.height)*Double(g.frame.height),
                    Double(c.width)/Double(g.scale.width)/Double(g.imageSize.width)*Double(g.frame.width),
                    Double(c.height)/Double(g.scale.height)/Double(g.imageSize.height)*Double(g.frame.height)])
                certify(e)
            } else { pending.append(e) }
        }
        for e in pending {
            guard let group=NativeEarlyMarginPixels.reconcile(e.state.canvas,donors:callbacks.donorCanvases?() ?? entries.map { $0.state.canvas },budget:budget.pixels) else { continue }
            e.state.canvas.safe=group.safe;e.state.canvas.luminance=group.luminance;e.state.revision+=1
            e.state.metadata["sourceErasureGroupPixels"]=String(group.added);callbacks.publish(e)
            if direct(e,group:true) { e.state.metadata["sourceErasureGroup"]="true";certify(e) }
        }
        for e in pending {
            let c=e.state.canvas,n=c.width*c.height
            guard !certified.contains(e.id),c.erasureVerified,c.erasureComplete,n<=budget.pixels.exterior else { continue }
            budget.pixels.exterior-=n
            if attached(e) { continue }
            guard let exterior=NativeEarlyMarginPixels.exterior(c,core:e.coverage.core,glyph:e.coverage.glyphSize,budget:budget.pixels),
                  !NativeResidualTopology.hasResidualLettering(safe:exterior.safe,width:c.width,height:c.height,
                    regions:e.coverage.core,glyphSize:e.coverage.glyphSize) else { continue }
            e.state.metadata["sourceErasureOccludedPixels"]=String(exterior.ignored)
            e.state.metadata["sourceErasureOccludedComponents"]=String(exterior.components);certify(e)
        }
        // Every ordinary/group/exterior fit runs before any partial fit.
        for e in entries where certified.contains(e.id) && e.hasTypographyEntry {
            if callbacks.fit(e,.normal) || callbacks.fit(e,.incomplete) || callbacks.fit(e,.partial) { e.hasPanel=false }
        }
        let partial=pending.filter { !certified.contains($0.id) };var preserved:[Entry]=[],residual:[Entry]=[]
        for pass in 0..<3 {
            for e in pass==2 ? residual:pass==1 ? preserved:partial {
                let c=e.state.canvas,n=c.width*c.height
                guard e.hasTypographyEntry,e.hasPanel,c.erasureComplete,!certified.contains(e.id),n<=budget.partial else { continue }
                budget.partial-=n
                if attached(e) { continue }
                if NativePartialSourceProof.hasLargePartialResidual(safe:c.safe,width:c.width,height:c.height,
                    core:e.coverage.core.map { CGRect(x:$0[0],y:$0[1],width:$0[2],height:$0[3]) },glyph:e.coverage.glyphSize,vertical:e.sourceVertical) {
                    e.state.metadata["partialResidualRejected"]="large-reading";continue
                }
                let strict=NativeResidualTopology.mainbodyCellsClear(safe:c.safe,width:c.width,height:c.height,regions:e.coverage.core)
                if !c.erasureVerified && !strict {
                    if !e.sourceGlyphsVerified {
                        if e.coverage.core.dropFirst().contains(where:{ !NativeResidualTopology.mainbodyCellsClear(safe:c.safe,width:c.width,height:c.height,regions:[$0]) }) { continue }
                        guard let ink=e.sourceRemainingInk,ink.isFinite,e.sourceCorePixels.isFinite,ink<=min(96,e.sourceCorePixels*0.08) else { continue }
                        if pass<2 { residual.append(e);continue }
                    }
                    if pass==0 { preserved.append(e);continue }
                }
                let oldPolicy=e.state.policy,oldPartial=e.state.partialCertified
                e.state.policy="auxiliary-original-preserved";e.state.partialCertified=true;callbacks.publish(e)
                if !(callbacks.fit(e,.normal) || callbacks.fit(e,.partial)) {
                    e.state.policy=oldPolicy;e.state.partialCertified=oldPartial;callbacks.publish(e);continue
                }
                certified.insert(e.id);e.hasPanel=false;e.state.metadata["sourceErasureRestored"]="partial-mainbody"
                e.state.metadata["partialMainbodyProof"]=strict ? "all-core-safe":c.erasureVerified ? "owned-glyph-mask":e.sourceGlyphsVerified ? "resolved-body-preserved-art":"residual-specks-preserved"
                // Source body coverage is supplied by the caller; a partial mask
                // never advertises the wider old observed-margin rectangle.
                e.state.metadata["sourceErasureReleased"]=strict ? json(e.sourceBodyCoverage.map { [Double($0.minX),Double($0.minY),Double($0.width),Double($0.height)] }):"[]";callbacks.publish(e)
            }
        }
        for e in entries where e.nodePresent && e.hasTypographyEntry && e.hasPanel && e.rotation==0 && budget.paper>=1024 {
            let old=e.state
            guard let proposal=callbacks.largerPaper(e,&budget.paper) else { continue }
            e.state=proposal;e.state.policy="auxiliary-original-preserved";e.state.partialCertified=true
            e.state.canvas.provisional=true;e.state.revision=old.revision+1;callbacks.replaceCandidate(e,old,false)
            if !(callbacks.fit(e,.normal) || callbacks.fit(e,.partial)) {
                let next=e.state.revision+1;e.state=old;e.state.revision=next;callbacks.replaceCandidate(e,old,true);continue
            }
            e.state.canvas.provisional=false;e.hasPanel=false;e.state.metadata["sourceErasureRestored"]="partial-mainbody"
            e.state.metadata["partialMainbodyProof"]="enclosed-paper-ink";e.state.metadata["sourceErasureReleased"]="[]";callbacks.publish(e)
        }
        for e in entries where e.hasPanel && e.nodePresent && e.state.canvas.erasureComplete && e.rotation==0 && !e.sourceTextOnly {
            if callbacks.sourcePosition(e) { e.hasPanel=false;callbacks.refresh(e) }
        }
        for e in entries where e.nodePresent && e.hasPanel && !certified.contains(e.id) && e.hasTypographyEntry {
            var undo:(() -> Void)?
            if !callbacks.eligible(e) {
                undo=callbacks.completeResidual(e);callbacks.refresh(e)
                guard let undo else { e.state.residualRefused=callbacks.residualKey(e);callbacks.publish(e);continue }
                if !callbacks.eligible(e) { undo();callbacks.refresh(e);continue }
            }
            if !callbacks.fit(e,.incomplete) { undo?();callbacks.refresh(e);continue }
            callbacks.commitResidual(e);callbacks.refresh(e);e.hasPanel=false
            e.state.metadata["sourceErasureRestored"]="complete-restoration";callbacks.publish(e)
        }
    }
    private static func json(_ value:Any)->String {
        (try? JSONSerialization.data(withJSONObject:value)).flatMap { String(data:$0,encoding:.utf8) } ?? "[]"
    }
}
