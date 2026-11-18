import CoreGraphics
import Foundation

/// Minimal retained-alpha page-inset rescue. No glyph drawing or layout search.
/// Every implicated body/source cohort translates coherently by its unique
/// nearest integer inset correction; valid pages return the exact incumbent.
enum NativeRetainedPageEdgeRecovery {
    typealias Primitive = NativeAOTTranslationPageComposer.TranslatedFillPrimitive
    typealias Tuple = (fills: [Primitive], audit: [[String: Any]])
    typealias Footprint = NativeFinalTextPaintAdmission.Footprint
    typealias BoundaryGate = (Footprint, Footprint) -> (allowed: Bool?, audit: [String: Any])
    /// Saved adapters may revalidate complete legacy-unknown body state at the
    /// NEW fixed origins. Production defaults to real native fixed admission.
    typealias Admission = (Tuple, CGRect) throws -> Tuple
    struct Result {
        let tuple: Tuple
        let changedOwnerIDs: [String]
        let metadata: [String: Any]
    }
    private enum Failure: Error { case invalid(String) }

    static func recover(_ incumbent: Tuple, page: CGRect, protectedOwners: Set<String> = [],
                        boundaryGate: BoundaryGate? = nil, admission: Admission? = nil) -> Result {
        let tuple = refine(incumbent, page: page, protectedOwners: protectedOwners, boundaryGate: boundaryGate, admission: admission)
        let changed = incumbent.fills.indices.filter { tuple.fills[$0].frame != incumbent.fills[$0].frame }
            .compactMap { incumbent.fills[$0].ownerID }
        let attempt = tuple.audit.first?["retainedPageEdgeRecoveryAttempt"]
        return Result(tuple: tuple, changedOwnerIDs: changed, metadata: ["mode":"exterior-retained-page-edge-inset1",
            "changedOwnerIDs":changed,"status":changed.isEmpty ? (attempt == nil ? "noop":"baseline-preserved") : "validated-edge-rescue",
            "nativeFixedOriginTransactionVerified":!changed.isEmpty,"unaffectedPositionChanges":0,
            "attempt":attempt ?? NSNull(),"physicalContainmentMeasured":false])
    }

    private static func costs(_ fill: Primitive, bounds: CGRect, page: CGRect) -> (CGFloat, CGFloat)? {
        guard let guide = fill.textPlacementGuide, guide.valid else { return nil }
        let source = guide.rect(in: page), preferred = guide.preferredShift(bounds: bounds, page: page)
        return (hypot(bounds.midX-source.midX,bounds.midY-source.midY),hypot(preferred.x,preferred.y))
    }
    private static func nearest(_ lower: CGFloat, _ upper: CGFloat) -> CGFloat? {
        let lo = ceil(lower), hi = floor(upper)
        guard lo <= hi else { return nil }
        return min(hi,max(lo,0))
    }

    static func refine(_ incumbent: Tuple, page: CGRect, protectedOwners: Set<String> = [],
                       boundaryGate: BoundaryGate? = nil, admission: Admission? = nil) -> Tuple {
        guard !incumbent.fills.isEmpty, incumbent.fills.count <= 256,
              incumbent.fills.count == incumbent.audit.count,
              page == page.integral, page.minX == 0, page.minY == 0,
              page.width > 2, page.height > 2, page.width <= 16_384, page.height <= 16_384 else { return incumbent }
        if Task<Never,Never>.isCancelled { return incumbent }
        let owners = incumbent.fills.compactMap(\.ownerID)
        guard owners.count == incumbent.fills.count, Set(owners).count == owners.count else { return incumbent }
        var supports: [Footprint] = [], totalPixels = 0
        for i in incumbent.fills.indices {
            let fill = incumbent.fills[i]
            guard incumbent.audit[i]["owner"] as? String == owners[i], !owners[i].isEmpty,
                  fill.frame == fill.frame.integral, page.contains(fill.frame), fill.image.height > 0,
                  fill.frame.width == CGFloat(fill.image.width), fill.frame.height == CGFloat(fill.image.height),
                  fill.image.width <= 8_000_000/fill.image.height, fill.fontOutputPixels.isFinite, fill.fontOutputPixels > 0,
                  let footprint = try? NativeFinalTextPaintAdmission.retainedFootprint(fill) else { return incumbent }
            totalPixels += fill.image.width*fill.image.height
            guard totalPixels <= 16_777_216 else { return incumbent }
            supports.append(footprint)
        }
        let inset = page.insetBy(dx:1,dy:1)
        guard supports.contains(where: { !inset.contains($0.bounds) }) else { return incumbent }
        guard supports.reduce(0, { $0+$1.runs.count }) <= 1_000_000 else { return incumbent }
        var parent = Array(incumbent.fills.indices)
        func root(_ index: Int) -> Int { var i=index; while parent[i] != i { i=parent[i] }; return i }
        func join(_ a: Int, _ b: Int) { parent[root(b)] = root(a) }
        for i in incumbent.fills.indices { for j in incumbent.fills.indices where j < i {
            let a=incumbent.fills[i], b=incumbent.fills[j]
            let body=a.balloonPlacement.map { $0.bodyID == b.balloonPlacement?.bodyID } ?? false
            let cohort=a.sourceClusterAlignment.map { $0.groupID == b.sourceClusterAlignment?.groupID } ?? false
            if body || cohort { join(i,j) }
        }}
        let groups=Dictionary(grouping:incumbent.fills.indices,by:{root($0)})
        var shifts=[CGPoint](repeating:.zero,count:owners.count), costsByOwner=[String:[String:Any]](), proposals:[[String:Any]]=[]
        func rejected(_ reason: String) -> Tuple {
            var result=incumbent
            if !result.audit.isEmpty { result.audit[0]["retainedPageEdgeRecoveryAttempt"] = ["status":"baseline-preserved",
                "reason":reason,"groups":proposals,"physicalContainmentMeasured":false] }
            return result
        }
        for key in groups.keys.sorted() {
            let members=groups[key]!, box=members.reduce(CGRect.null) { $0.union(supports[$1].bounds) }
            if inset.contains(box) { continue }
            guard members.allSatisfy({incumbent.fills[$0].textExpansionPolicy?.insideBalloon == false &&
                incumbent.fills[$0].balloonPlacement == nil}) else { return rejected("non-exterior-edge-component") }
            guard !members.contains(where:{protectedOwners.contains(owners[$0])}),
                  let dx=nearest(inset.minX-box.minX,inset.maxX-box.maxX),
                  let dy=nearest(inset.minY-box.minY,inset.maxY-box.maxY),
                  dx != 0 || dy != 0 else { return rejected("protected-or-no-inset-capacity") }
            // Existing alpha is already inside page: inset1 can require no more
            // than one pixel PER AXIS. A corner repair may have norm sqrt(2).
            guard abs(dx) <= 1, abs(dy) <= 1 else { return rejected("not-minimal-one-pixel-per-axis") }
            let shift=CGPoint(x:dx,y:dy), norm=hypot(dx,dy)
            proposals.append(["owners":members.map {owners[$0]},"beforeBounds":array(box),
                "minimalShift":[dx,dy],"minimumRequiredNorm":norm,"insetPixels":1])
            for i in members {
                let fill=incumbent.fills[i], next=supports[i].bounds.offsetBy(dx:dx,dy:dy)
                guard norm <= floor(fill.fontOutputPixels*0.5), let old=costs(fill,bounds:supports[i].bounds,page:page),
                      let new=costs(fill,bounds:next,page:page), new.0 <= old.0+norm+1e-7, new.1 <= old.1+norm+1e-7,
                      fill.textExpansionPolicy?.valid == true, fill.placementDomain != nil else { return rejected("source-cost-cap-or-domain") }
                shifts[i]=shift
                costsByOwner[owners[i]]=["centerBeforePixels":old.0,"centerAfterPixels":new.0,
                    "guideBeforePixels":old.1,"guideAfterPixels":new.1,"exceptionBoundPixels":norm,
                    "sourceCostExceptionApplied":new.0>old.0+1e-7 || new.1>old.1+1e-7,
                    "exceptionAuthority":"minimal-required-page-inset-and-coherent-cohort-only",
                    "cohortOwners":members.map {owners[$0]}.sorted(), "minimalGroupShift":[dx,dy],
                    "minimalGroupBeforeBounds":array(box)]
            }
        }
        let proposed=supports.indices.map { supports[$0].translated(shifts[$0]) }
        guard proposed.allSatisfy({inset.contains($0.bounds)}) else { return rejected("unrepaired-page-inset") }
        for i in incumbent.fills.indices where shifts[i] != .zero {
            guard proposed[i].runs.allSatisfy({ r in incumbent.fills[i].placementDomain?(CGRect(x:r.left,y:r.y,width:r.right-r.left,height:1)) == true }) else {
                return rejected("assigned-domain")
            }
        }
        // Preserve actual order and the same source-aware readable gap floor.
        for i in incumbent.fills.indices { for j in incumbent.fills.indices where j > i && (shifts[i] != .zero || shifts[j] != .zero) {
            let a=supports[i].readableBounds ?? supports[i].bounds, b=supports[j].readableBounds ?? supports[j].bounds
            let A=proposed[i].readableBounds ?? proposed[i].bounds, B=proposed[j].readableBounds ?? proposed[j].bounds
            let first=incumbent.fills[i], second=incumbent.fills[j]
            let sameBody=first.balloonPlacement.map { $0.bodyID == second.balloonPlacement?.bodyID } ?? false
            let sameCohort=first.sourceClusterAlignment.map { $0.groupID == second.sourceClusterAlignment?.groupID } ?? false
            if sameBody || sameCohort {
                for pair in [(b.midX-a.midX,B.midX-A.midX),(b.midY-a.midY,B.midY-A.midY)] {
                    guard pair.0 == 0 ? pair.1 == 0 : pair.0*pair.1 > 0 else { return rejected("body-or-cohort-order") }
                }
            }
            let old=NativeAdaptiveTextGutter.clearance(a,b), new=NativeAdaptiveTextGutter.clearance(A,B)
            if old == nil && new == nil { continue }
            var desired=min(first.fontOutputPixels,second.fontOutputPixels)*0.35
            if sameBody, let packet=first.balloonPlacement, let x=first.textPlacementGuide?.rect(in:page),let y=second.textPlacementGuide?.rect(in:page) {
                let gap=max(0,packet.flow == .row ? max(x.minX,y.minX)-min(x.maxX,y.maxX):max(x.minY,y.minY)-min(x.maxY,y.maxY))
                desired=ceil(max(max(first.fontOutputPixels,second.fontOutputPixels)*0.35,
                    min(gap*0.65,max(first.fontOutputPixels,second.fontOutputPixels)*1.25)))
            }
            guard let new,new+1e-7 >= min(old ?? desired,desired) else { return rejected("readable-peer-or-body-gap") }
        }}
        var boundary=[String:[String:Any]]()
        for i in incumbent.fills.indices where shifts[i] != .zero {
            if let gate=boundaryGate {
                let check=gate(supports[i],proposed[i]); boundary[owners[i]]=check.audit
                if check.allowed == false { return rejected("source-boundary-veto") }
            } else { boundary[owners[i]]=["status":"source-boundary-unavailable","evidenceAvailable":false] }
            if let risk=NativeFinalTextPaintAdmission.retainedSourceRiskGate, risk.evaluate(supports[i],proposed[i]) != true {
                return rejected("retained-source-risk-unavailable-or-veto")
            }
        }
        var candidate=incumbent
        for i in candidate.fills.indices {candidate.fills[i].frame=candidate.fills[i].frame.offsetBy(dx:shifts[i].x,dy:shifts[i].y)}
        guard let anchors=NativeReadablePeerGutter.retainedAnchors(packets:candidate.fills.map(\.sourceClusterAlignment),
            origins:proposed.map {$0.bounds.origin}) else {return rejected("cohort-anchor-inconsistent")}
        do {
            var admitted:Tuple
            if let admission {admitted=try admission(candidate,page)}
            else {admitted=try NativeFinalTextPaintAdmission.place(candidate.fills,page:page,
                fixedOrigins:Dictionary(uniqueKeysWithValues:owners.indices.map {(owners[$0],proposed[$0].bounds.origin)}),retainedClusterAnchors:anchors)}
            if admission == nil {
                admitted.audit = try NativeBalloonPlacement.RetainedState.preservingKnownSnapshots(
                    priorAudit: incumbent.audit, admittedAudit: admitted.audit, unknownPolicy: .reject)
            }
            if Task<Never,Never>.isCancelled { return incumbent }
            guard admitted.fills.count==owners.count,admitted.audit.count==owners.count else {throw Failure.invalid("tuple-count")}
            var actual:[Footprint]=[]
            for i in incumbent.fills.indices {
                let old=incumbent.fills[i], new=admitted.fills[i]
                guard NativeBodySourceAnchorRecovery.carrierPreserved(old,new,shift:shifts[i],preserveRelaxation:false),
                      try NativeMandatoryDisplayStroke.rgba(new.image)==NativeMandatoryDisplayStroke.rgba(old.image) else {
                    throw Failure.invalid("carrier-or-raster-changed")
                }
                let unknown:Bool
                switch try NativeBalloonPlacement.RetainedState.read(incumbent.audit[i],owner:owners[i]) {
                case .missing:unknown=true
                case .state(let state):unknown=state.requiresFixedOriginRevalidation
                }
                if old.balloonTargetRelaxed != new.balloonTargetRelaxed {
                    guard admission != nil, unknown,
                          case .state(let captured) = try NativeBalloonPlacement.RetainedState.read(admitted.audit[i],owner:owners[i]),
                          captured.provenance == .fixedOriginRevalidated, !captured.historicalStateExact,
                          !captured.requiresFixedOriginRevalidation else {throw Failure.invalid("unvalidated-body-relaxation-change")}
                }
                if case .state(let prior) = try NativeBalloonPlacement.RetainedState.read(incumbent.audit[i],owner:owners[i]), !unknown {
                    guard case .state(let captured) = try NativeBalloonPlacement.RetainedState.read(admitted.audit[i],owner:owners[i]),
                          prior == captured else {throw Failure.invalid("known-body-state-changed")}
                }
                let footprint=try NativeFinalTextPaintAdmission.retainedFootprint(new)
                guard footprint.bounds==proposed[i].bounds,footprint.pixels==supports[i].pixels else {throw Failure.invalid("actual-alpha-changed")}
                actual.append(footprint)
            }
            try NativeFinalTextPaintAdmission.verifyRetainedPlacement(admitted.fills,footprints:actual,page:page,retainedClusterAnchors:anchors)
            for i in admitted.audit.indices {
                var row=incumbent.audit[i];row.merge(admitted.audit[i]){_,new in new}
                if incumbent.audit[i]["retainedSourceClusterAnchorApplied"] as? Bool != true {
                    row.removeValue(forKey:"retainedSourceClusterAnchorApplied")
                }
                if shifts[i] != .zero {
                    var info=costsByOwner[owners[i]]!
                    info["version"]="retained-page-edge-inset1-v1";info["shiftPixels"]=[shifts[i].x,shifts[i].y]
                    info["beforeBounds"]=array(supports[i].bounds);info["afterBounds"]=array(actual[i].bounds)
                    info["insetPixels"]=1;info["boundaryGate"]=boundary[owners[i]];info["physicalContainmentMeasured"]=false
                    info["retainedSourceRisk"]=NativeFinalTextPaintAdmission.retainedSourceRiskGate == nil ? "unmeasured":"accepted"
                    info["cohortOldAnchor"]=incumbent.audit[i]["sourceClusterAnchorOutputPixels"] ?? NSNull()
                    info["cohortNewAnchor"]=admitted.audit[i]["sourceClusterAnchorOutputPixels"] ?? NSNull()
                    row["retainedPageEdgeRecovery"]=info
                    if let group=admitted.fills[i].sourceClusterAlignment?.groupID,anchors[group] != nil {
                        row["retainedSourceClusterAnchorApplied"]=true
                    }
                }
                admitted.audit[i]=row
            }
            return admitted
        } catch {return rejected(String(reflecting:error))}
    }

    private static func array(_ rect:CGRect)->[CGFloat] {[rect.minX,rect.minY,rect.width,rect.height]}
}
