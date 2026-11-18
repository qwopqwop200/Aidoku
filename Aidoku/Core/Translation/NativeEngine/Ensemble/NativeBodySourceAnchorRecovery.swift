import CoreGraphics
import Foundation

/// Optional joint terminal source-anchor recovery for complete, known inside
/// bodies, including active soft targets and geometry-unavailable fallbacks.
/// Never reshapes text or claims physical containment. The original pixel/mask
/// domains and optional retained-source risk gate remain admission authorities.
enum NativeBodySourceAnchorRecovery {
    typealias Primitive = NativeAOTTranslationPageComposer.TranslatedFillPrimitive
    typealias Tuple = (fills: [Primitive], audit: [[String: Any]])
    typealias BoundaryGate = (NativeFinalTextPaintAdmission.Footprint, NativeFinalTextPaintAdmission.Footprint)
        -> (allowed: Bool?, audit: [String:Any])
    private typealias Footprint = NativeFinalTextPaintAdmission.Footprint
    private struct Error {
        let center: CGFloat
        let anchor: CGFloat
    }
    private static func error(_ fill: Primitive, bounds: CGRect, page: CGRect) -> Error? {
        guard let guide = fill.textPlacementGuide, guide.valid else { return nil }
        let source = guide.rect(in:page), shift = guide.preferredShift(bounds:bounds,page:page)
        return Error(center:hypot(bounds.midX-source.midX,bounds.midY-source.midY),anchor:hypot(shift.x,shift.y))
    }
    private static func sameStyle(_ a: NativeSourceStylePaint.Style?, _ b: NativeSourceStylePaint.Style?) -> Bool {
        switch (a,b) {
        case (nil,nil): return true
        case let (a?,b?):
            guard NativeSourceStylePaint.sameRoundedContour(a,b),
                  a.sourceFontPixels == b.sourceFontPixels, a.bands.count == b.bands.count,
                  zip(a.bands,b.bands).allSatisfy({ $0.rgb == $1.rgb && $0.width == $1.width }) else { return false }
            switch (a.shadow,b.shadow) {
            case (nil,nil): return true
            case let (x?,y?): return x.rgb == y.rgb && x.offset == y.offset
            default: return false
            }
        default: return false
        }
    }
    private static func sameAppearance(_ a: [String:Any]?, _ b: [String:Any]?) -> Bool {
        switch (a,b) {
        case (nil,nil): return true
        case let (a?,b?): return NSDictionary(dictionary:a).isEqual(to:b)
        default: return false
        }
    }
    static func carrierPreserved(_ a: Primitive, _ b: Primitive, shift: CGPoint, preserveRelaxation: Bool = true) -> Bool {
        a.ownerID == b.ownerID && b.frame == a.frame.offsetBy(dx:shift.x,dy:shift.y) &&
        a.image.width == b.image.width && a.image.height == b.image.height &&
        a.fontOutputPixels == b.fontOutputPixels && a.hasFinalEffects == b.hasFinalEffects &&
        a.sourceContourOnly == b.sourceContourOnly && a.displayStrokeEndpoint == b.displayStrokeEndpoint &&
        a.displayStrokeRatio == b.displayStrokeRatio && a.recheckFinalEndpoint == b.recheckFinalEndpoint &&
        a.minimumFillStrokeContrast == b.minimumFillStrokeContrast && a.minimumCoverageGain == b.minimumCoverageGain &&
        a.textPlacementGuide == b.textPlacementGuide && a.textExpansionPolicy == b.textExpansionPolicy &&
        a.sourceClusterAlignment == b.sourceClusterAlignment && a.balloonPlacement == b.balloonPlacement &&
        (!preserveRelaxation || a.balloonTargetRelaxed == b.balloonTargetRelaxed) && sameStyle(a.sourceStyle,b.sourceStyle) &&
        sameAppearance(a.sourceAppearance,b.sourceAppearance)
    }
    private static func ordered(_ members: [Int], before: [Footprint], after: [Footprint], row: Bool) -> Bool {
        for (n,i) in members.enumerated() { for j in members.dropFirst(n+1) {
            for center in [false,true] {
                func coordinate(_ r: CGRect) -> CGFloat { row ? (center ? r.midX:r.minX) : (center ? r.midY:r.minY) }
                let a = coordinate(before[j].bounds)-coordinate(before[i].bounds)
                let b = coordinate(after[j].bounds)-coordinate(after[i].bounds)
                if a == 0 { if b != 0 { return false } }
                else if a*b <= 0 { return false }
            }
        }}
        return true
    }

    struct Validation {
        let accepted: Bool
        let reason: String
        let audit: [String:Any]
    }
    private enum ContractFailure: String, Swift.Error {
        case malformed = "malformed-source-contract"
        case cost = "source-cost-regression"
        case cap = "source-shift-cap"
        case flow = "flow-axis-drift"
        case order = "source-body-order-regression"
        case mask = "assigned-mask-outside"
        case margin = "assigned-mask-margin-regression"
        case gap = "source-aware-gap-regression"
        case peerGap = "peer-gap-regression"
        case improvement = "no-source-improvement"
    }
    private struct Contract {
        var beforeErrors: [Int:Error] = [:], afterErrors: [Int:Error] = [:]
        var beforeMargins: [Int:Int] = [:], afterMargins: [Int:Int] = [:]
        var gapPairs = 0
        var minimumSurplus: CGFloat?
        var gaps: [[String:Any]] = []
    }
    /// One geometric contract for proposed helper movements AND the final
    /// tuple after later physical correction. No shaping/placement recursion.
    private static func contract(_ fills: [Primitive], before: [Footprint], after: [Footprint],
                                 bodyIDs: Set<String>, page: CGRect) throws -> Contract {
        guard fills.count == before.count, fills.count == after.count else { throw ContractFailure.malformed }
        var result = Contract()
        for bodyID in bodyIDs.sorted() {
            let members = fills.indices.filter { fills[$0].balloonPlacement?.bodyID == bodyID }
            guard members.count > 1, let first = members.first, let packet = fills[first].balloonPlacement,
                  packet.valid else { throw ContractFailure.malformed }
            let row = packet.flow == .row
            var improved = false
            for i in members {
                let f = fills[i]
                guard f.balloonPlacement?.valid == true, f.balloonPlacement?.flow == packet.flow,
                      let policy = f.textExpansionPolicy, policy.valid, policy.insideBalloon,
                      let old = error(f,bounds:before[i].bounds,page:page),
                      let new = error(f,bounds:after[i].bounds,page:page) else { throw ContractFailure.malformed }
                let dx = after[i].bounds.minX-before[i].bounds.minX, dy = after[i].bounds.minY-before[i].bounds.minY
                guard hypot(dx,dy) <= floor(f.fontOutputPixels*0.5)+1e-9 else { throw ContractFailure.cap }
                guard row ? dy == 0 : dx == 0 else { throw ContractFailure.flow }
                guard new.center <= old.center+1e-7, new.anchor <= old.anchor+1e-7 else { throw ContractFailure.cost }
                guard after[i].runs.allSatisfy({ r in policy.allows(CGRect(x:r.left,y:r.y,width:r.right-r.left,height:1),page:page) })
                else { throw ContractFailure.mask }
                let oldMargin = maskMargin(before[i],fill:f,page:page), newMargin = maskMargin(after[i],fill:f,page:page)
                guard newMargin >= oldMargin else { throw ContractFailure.margin }
                result.beforeErrors[i] = old; result.afterErrors[i] = new
                result.beforeMargins[i] = oldMargin; result.afterMargins[i] = newMargin
                if old.center-new.center >= 1-1e-7 || old.anchor-new.anchor >= 1-1e-7 { improved = true }
            }
            guard improved else { throw ContractFailure.improvement }
            guard ordered(members,before:before,after:after,row:row) else { throw ContractFailure.order }
        }
        // Include every pair affected by the final transaction, including a
        // member that the helper left still but the physical pass later moved.
        for i in fills.indices {
            for j in fills.indices where j > i && (before[i].bounds != after[i].bounds || before[j].bounds != after[j].bounds) {
                let gap = pairGap(fills,i,j,oldA:before[i],oldB:before[j],newA:after[i],newB:after[j],page:page)
                guard gap.comparable else { continue }
                guard gap.allowed else { throw gap.sameBody ? ContractFailure.gap : ContractFailure.peerGap }
                result.gapPairs += 1
                result.minimumSurplus = min(result.minimumSurplus ?? .greatestFiniteMagnitude,gap.new!-gap.required)
                if result.gaps.count < 256 {
                    result.gaps.append(["owners":[fills[i].ownerID ?? String(i),fills[j].ownerID ?? String(j)],
                        "old":gap.old as Any? ?? NSNull(),"new":gap.new!,"required":gap.required])
                }
            }
        }
        return result
    }

    /// Validate the original-to-terminal transaction, not an intermediate
    /// helper receipt. Physical-only peers may retain legitimate body-flag
    /// updates only within a proved recovered body: false->true is explicit,
    /// group-wide and audited. All external carrier flags remain exact.
    static func validateTerminal(_ incumbent: Tuple, terminal: Tuple, recoveredBodyIDs: Set<String>, page: CGRect, boundaryGate: BoundaryGate? = nil) -> Validation {
        func rejected(_ reason: String) -> Validation { Validation(accepted:false,reason:reason,audit:["accepted":false,"reason":reason]) }
        guard !recoveredBodyIDs.isEmpty else { return Validation(accepted:true,reason:"no-recovered-bodies",audit:["accepted":true]) }
        guard !incumbent.fills.isEmpty, incumbent.fills.count <= 256, incumbent.fills.count == terminal.fills.count,
              incumbent.audit.count == incumbent.fills.count, terminal.audit.count == terminal.fills.count,
              [page.minX,page.minY,page.width,page.height].allSatisfy(\.isFinite),
              page.minX == 0, page.minY == 0, page == page.integral, page.width > 0, page.height > 0,
              page.width <= 16_384, page.height <= 16_384 else { return rejected("malformed-terminal-tuple") }
        let owners = incumbent.fills.compactMap(\.ownerID)
        guard owners.count == incumbent.fills.count, Set(owners).count == owners.count,
              !owners.contains(where: \.isEmpty), terminal.fills.map(\.ownerID) == incumbent.fills.map(\.ownerID)
        else { return rejected("malformed-terminal-owners") }
        var controlledBodies = Set<String>()
        for bodyID in recoveredBodyIDs {
            let members = incumbent.fills.indices.filter { incumbent.fills[$0].balloonPlacement?.bodyID == bodyID }
            if members.contains(where:{ incumbent.fills[$0].balloonTargetRelaxed != terminal.fills[$0].balloonTargetRelaxed }) {
                guard members.count > 1, knownBody(incumbent,members:members) else { return rejected("unproved-body-relaxation") }
                let groupOwners = members.map { owners[$0] }.sorted()
                for i in members {
                    guard terminal.fills[i].balloonTargetRelaxed,
                          let policy = terminal.audit[i]["bodySourceAnchorRecoveryPolicy"] as? [String:Any],
                          policy["reason"] as? String == jointPolicyReason, policy["bodyID"] as? String == bodyID,
                          policy["members"] as? [String] == groupOwners, policy["completeGroupProved"] as? Bool == true,
                          policy["previousRelaxed"] as? Bool == incumbent.fills[i].balloonTargetRelaxed,
                          terminal.audit[i]["balloonBodyPlaced"] as? Bool == false,
                          terminal.audit[i]["balloonCapacityFallback"] as? Bool == true,
                          terminal.audit[i]["balloonTargetRelaxed"] as? Bool == true,
                          let stateValue = terminal.audit[i][NativeBalloonPlacement.RetainedState.auditKey],
                          let state = try? NativeBalloonPlacement.RetainedState.decode(stateValue,owner:owners[i]),
                          state.effectivePacket == terminal.fills[i].balloonPlacement,
                          state.target == .fallback, state.balloonTargetRelaxed == true,
                          !state.requiresFixedOriginRevalidation else { return rejected("unproved-body-relaxation") }
                }
                guard knownBody(terminal,members:members) else { return rejected("inconsistent-terminal-body-state") }
                controlledBodies.insert(bodyID)
            }
        }
        var pixels = 0
        for i in incumbent.fills.indices {
            let a = incumbent.fills[i], b = terminal.fills[i]
            guard a.fontOutputPixels.isFinite, a.fontOutputPixels > 0,
                  a.frame == a.frame.integral, b.frame == b.frame.integral, page.contains(a.frame), page.contains(b.frame),
                  a.frame.width == CGFloat(a.image.width), a.frame.height == CGFloat(a.image.height),
                  a.image.width <= 8_000_000/a.image.height,
                  incumbent.audit[i]["owner"] as? String == owners[i],terminal.audit[i]["owner"] as? String == owners[i]
            else { return rejected("malformed-terminal-carrier") }
            pixels += a.image.width*a.image.height
            guard pixels <= 16_777_216 else { return rejected("terminal-budget") }
            let shift = CGPoint(x:b.frame.minX-a.frame.minX,y:b.frame.minY-a.frame.minY)
            let controlled = a.balloonPlacement.map { controlledBodies.contains($0.bodyID) } ?? false
            guard carrierPreserved(a,b,shift:shift,preserveRelaxation:!controlled),
                  let oldBytes = try? NativeMandatoryDisplayStroke.rgba(a.image),
                  let newBytes = try? NativeMandatoryDisplayStroke.rgba(b.image), oldBytes == newBytes
            else { return rejected("terminal-carrier-changed") }
        }
        guard let before = try? incumbent.fills.map({ try NativeFinalTextPaintAdmission.retainedFootprint($0) }),
              let after = try? terminal.fills.map({ try NativeFinalTextPaintAdmission.retainedFootprint($0) }),
              before.reduce(0, { $0+$1.runs.count }) <= 1_000_000,after.reduce(0, { $0+$1.runs.count }) <= 1_000_000
        else { return rejected("terminal-footprint-budget") }
        do {
            let validated = try contract(incumbent.fills,before:before,after:after,bodyIDs:recoveredBodyIDs,page:page)
            var boundaryChecks: [String:[String:Any]] = [:]
            if let boundaryGate {
                for i in before.indices where incumbent.fills[i].frame != terminal.fills[i].frame {
                    if Task<Never,Never>.isCancelled { return rejected("cancelled") }
                    let check = boundaryGate(before[i],after[i]); boundaryChecks[owners[i]] = check.audit
                    if Task<Never,Never>.isCancelled { return rejected("cancelled") }
                    if check.allowed == nil {
                        return Validation(accepted:false,reason:"terminal-source-boundary-unknown",
                            audit:["accepted":false,"reason":"terminal-source-boundary-unknown","sourceBoundaryChecks":boundaryChecks])
                    }
                    if check.allowed == false {
                        return Validation(accepted:false,reason:"terminal-source-boundary-veto",
                            audit:["accepted":false,"reason":"terminal-source-boundary-veto","sourceBoundaryChecks":boundaryChecks])
                    }
                }
            }
            if let risk = NativeFinalTextPaintAdmission.retainedSourceRiskGate {
                for i in before.indices where incumbent.fills[i].frame != terminal.fills[i].frame {
                    guard risk.evaluate(before[i],after[i]) == true else { return rejected("terminal-source-risk-veto") }
                }
            }
            var members: [String:[String:Any]] = [:]
            for i in validated.beforeErrors.keys {
                members[owners[i]] = ["centerBefore":validated.beforeErrors[i]!.center,"centerAfter":validated.afterErrors[i]!.center,
                    "anchorBefore":validated.beforeErrors[i]!.anchor,"anchorAfter":validated.afterErrors[i]!.anchor,
                    "maskMarginBefore":validated.beforeMargins[i]!,"maskMarginAfter":validated.afterMargins[i]!]
            }
            return Validation(accepted:true,reason:"terminal-source-contract-preserved",audit:["accepted":true,
                "scope":"original-to-final tuple after physical pass","recoveredBodyIDs":recoveredBodyIDs.sorted(),
                "controlledBodyRelaxations":controlledBodies.sorted(),
                "members":members,"sourceBoundaryChecks":boundaryChecks,"gapPairsChecked":validated.gapPairs,"gapChecks":validated.gaps,
                "gapChecksTruncated":validated.gapPairs>validated.gaps.count,"physicalContainmentMeasured":false])
        } catch let failure as ContractFailure { return rejected(failure.rawValue) }
        catch { return rejected("terminal-contract-unavailable") }
    }

    private struct PairGap {
        let old: CGFloat?, new: CGFloat?, required: CGFloat
        let sameBody: Bool, comparable: Bool
        var allowed: Bool { !comparable || (new.map { $0+1e-7 >= required } ?? false) }
    }
    private static func pairGap(_ fills: [Primitive], _ i: Int, _ j: Int,
                                oldA: Footprint, oldB: Footprint, newA: Footprint, newB: Footprint,
                                page: CGRect) -> PairGap {
        let old = NativeAdaptiveTextGutter.clearance(oldA.readableBounds ?? oldA.bounds,oldB.readableBounds ?? oldB.bounds)
        let new = NativeAdaptiveTextGutter.clearance(newA.readableBounds ?? newA.bounds,newB.readableBounds ?? newB.bounds)
        var desired = min(fills[i].fontOutputPixels,fills[j].fontOutputPixels)*0.35
        let sameBody = fills[i].balloonPlacement?.bodyID != nil && fills[i].balloonPlacement?.bodyID == fills[j].balloonPlacement?.bodyID
        if sameBody, let packet = fills[i].balloonPlacement,
           let a = fills[i].textPlacementGuide?.rect(in:page), let b = fills[j].textPlacementGuide?.rect(in:page) {
            let observed = max(0,packet.flow == .row ? max(a.minX,b.minX)-min(a.maxX,b.maxX):max(a.minY,b.minY)-min(a.maxY,b.maxY))
            let font = max(fills[i].fontOutputPixels,fills[j].fontOutputPixels)
            desired = ceil(max(font*0.35,min(observed*0.65,font*1.25)))
        }
        return PairGap(old:old,new:new,required:min(old ?? desired,desired),sameBody:sameBody,comparable:old != nil || new != nil)
    }
    private static func maskMargin(_ support: Footprint, fill: Primitive, page: CGRect) -> Int {
        guard let policy = fill.textExpansionPolicy else { return -1 }
        let rows = NativeInkContourClearance.envelope(support.runs.map { .init(y:$0.y,left:$0.left,right:$0.right) })
        return NativeInkContourClearance.margin(rows:rows,bounds:support.bounds,policy:policy,page:page,limit:2)
    }
    /// Native capture or an actual fixed-origin revalidation is required. Raw
    /// requests and scalar historical flags alone never authorize this search.
    private static func knownBody(_ value: Tuple, members: [Int]) -> Bool {
        typealias S = NativeBalloonPlacement.RetainedState
        var states: [String:S.Snapshot] = [:]
        for i in members {
            let f = value.fills[i]
            guard let owner = f.ownerID,
                  let read = try? S.read(value.audit[i],owner:owner), case .state(let state) = read,
                  !state.requiresFixedOriginRevalidation, state.target == .placed || state.target == .fallback,
                  state.effectivePacket == f.balloonPlacement, state.balloonTargetRelaxed == f.balloonTargetRelaxed,
                  value.audit[i]["balloonTargetRelaxed"] as? Bool == f.balloonTargetRelaxed,
                  value.audit[i]["balloonBodyPlaced"] as? Bool == (state.target == .placed),
                  value.audit[i]["balloonCapacityFallback"] as? Bool == (state.target == .fallback) else { return false }
            states[owner] = state
        }
        return (try? S.validateGroups(states)) != nil
    }
    private static let jointPolicyReason = "proved-joint-sourceward-improvement"
    private struct Choice {
        let delta: Int, support: Footprint, cost: Double, improved: Bool
        let boundary: [String:Any]
    }
    private struct Path {
        let choices: [Int], vector: [Int], cost: Double, travel: Int
    }
    private static func precedes(_ a: Path, _ b: Path) -> Bool {
        if a.cost != b.cost { return a.cost < b.cost }
        if a.travel != b.travel { return a.travel < b.travel }
        return a.vector.lexicographicallyPrecedes(b.vector)
    }
    private static func pairOrder(_ oldA: CGRect, _ oldB: CGRect, _ newA: CGRect, _ newB: CGRect, row: Bool) -> Bool {
        for center in [false,true] {
            func coordinate(_ r: CGRect) -> CGFloat { row ? (center ? r.midX:r.minX):(center ? r.midY:r.minY) }
            let old = coordinate(oldB)-coordinate(oldA), new = coordinate(newB)-coordinate(newA)
            if old == 0 { if new != 0 { return false } }
            else if old*new <= 0 { return false }
        }
        return true
    }

    static func refine(_ incumbent: Tuple, page: CGRect, protectedOwners: Set<String> = [], boundaryGate: BoundaryGate? = nil) -> Tuple {
        guard ProcessInfo.processInfo.environment["AIDOKU_BODY_SOURCE_ANCHOR_RECOVERY"] != "0",
              !incumbent.fills.isEmpty, incumbent.fills.count <= 256, incumbent.fills.count == incumbent.audit.count,
              [page.minX,page.minY,page.width,page.height].allSatisfy(\.isFinite),
              page.minX == 0, page.minY == 0, page == page.integral,
              page.width > 0, page.height > 0, page.width <= 16_384, page.height <= 16_384 else { return incumbent }
        let owners = incumbent.fills.compactMap(\.ownerID)
        guard owners.count == incumbent.fills.count, Set(owners).count == owners.count, !owners.contains(where:\.isEmpty) else { return incumbent }
        var pixels = 0
        for i in incumbent.fills.indices {
            let f = incumbent.fills[i]
            guard incumbent.audit[i]["owner"] as? String == owners[i], f.frame == f.frame.integral, page.contains(f.frame),
                  f.frame.width == CGFloat(f.image.width), f.frame.height == CGFloat(f.image.height), f.image.height > 0,
                  f.fontOutputPixels.isFinite, f.fontOutputPixels > 0, f.image.width <= 8_000_000/f.image.height,
                  f.balloonPlacement?.valid ?? true else { return incumbent }
            pixels += f.image.width*f.image.height
            guard pixels <= 16_777_216 else { return incumbent }
        }
        let groups = Dictionary(grouping:incumbent.fills.indices.filter { incumbent.fills[$0].balloonPlacement != nil },
            by:{ incumbent.fills[$0].balloonPlacement!.bodyID })
        guard groups.count <= 64, var supports = try? incumbent.fills.map({ try NativeFinalTextPaintAdmission.retainedFootprint($0) }),
              supports.reduce(0,{ $0+$1.runs.count }) <= 1_000_000,
              (try? NativeBalloonPlacement.targets(incumbent.fills.map(\.balloonPlacement),bounds:supports.map(\.bounds),
                fonts:incumbent.fills.map(\.fontOutputPixels),page:page,guides:incumbent.fills.map(\.textPlacementGuide))) != nil,
              let originalRGBA = try? incumbent.fills.map({ try NativeMandatoryDisplayStroke.rgba($0.image) }) else { return incumbent }
        var current = incumbent
        // Hard whole-call budgets. K-best state trimming is an approximation,
        // never an exact optimum claim. Every retained path checks ALL previous
        // members, not just chain neighbors (2D readable gaps can be nil).
        let keep = 8, candidateBudget = 16, maxWork = 2_000_000, maxOptionRuns = 250_000
        var work = 0, nativeTransactions = 0
        for bodyID in groups.keys.sorted() {
            if Task<Never,Never>.isCancelled { return incumbent }
            let rawMembers = groups[bodyID]!
            guard rawMembers.count > 1, rawMembers.count <= 32,
                  !rawMembers.contains(where:{ protectedOwners.contains(owners[$0]) }),
                  knownBody(incumbent,members:rawMembers), knownBody(current,members:rawMembers),
                  let first = rawMembers.first, let packet = current.fills[first].balloonPlacement,
                  rawMembers.allSatisfy({ i in
                    let f = current.fills[i]
                    return f.balloonPlacement?.flow == packet.flow && f.textPlacementGuide?.valid == true &&
                        f.textExpansionPolicy?.valid == true && f.textExpansionPolicy?.insideBalloon == true && f.placementDomain != nil &&
                        floor(f.fontOutputPixels*0.5) <= 512
                  }), let anchors = NativeReadablePeerGutter.retainedAnchors(packets:current.fills.map(\.sourceClusterAlignment),
                    origins:supports.map { $0.bounds.origin }) else { continue }
            let row = packet.flow == .row
            let members = rawMembers.sorted { a,b in
                let x = row ? supports[a].bounds.minX:supports[a].bounds.minY
                let y = row ? supports[b].bounds.minX:supports[b].bounds.minY
                return x == y ? owners[a] < owners[b]:x < y
            }
            let memberSet = Set(members), groupOwners = members.map { owners[$0] }.sorted()
            let external = current.fills.indices.filter { !memberSet.contains($0) }
            let risk = NativeFinalTextPaintAdmission.retainedSourceRiskGate
            var options: [[Choice]] = [], optionRuns = 0, generated = 0, localPruned = 0, boundaryPruned = 0, representativePruned = 0
            var vetoes: [[String:Any]] = []
            func searchDeferred(_ reason: String) -> Tuple {
                var result = current
                for i in members {
                    result.audit[i]["bodySourceAnchorSearch"] = ["status":reason,"bodyID":bodyID,"generatedChoices":generated,
                        "localPrunedChoices":localPruned,"workUsed":work,"workBudget":maxWork,"optionRunBudget":maxOptionRuns,
                        "exactOptimumClaimed":false,"physicalContainmentMeasured":false]
                }
                return result
            }
            for i in members {
                let f = current.fills[i], old = supports[i]
                guard let oldError = error(f,bounds:old.bounds,page:page) else { return current }
                let preferred = f.textPlacementGuide!.preferredShift(bounds:old.bounds,page:page)
                let desired = row ? preferred.x:preferred.y
                var limit = Int(floor(min(abs(desired),floor(f.fontOutputPixels*0.5))))
                if let cluster = f.sourceClusterAlignment, anchors[cluster.groupID] != nil,
                   (row && cluster.axis == .left || !row && cluster.axis == .top) { limit = 0 }
                let direction = desired < 0 ? -1:1, oldMargin = maskMargin(old,fill:f,page:page)
                let unit = Double(f.fontOutputPixels*f.fontOutputPixels)
                var choices = [Choice(delta:0,support:old,cost:Double(oldError.center*oldError.center+oldError.anchor*oldError.anchor)/unit,
                    improved:false,boundary:["status":"stationary-incumbent","evidenceAvailable":false])]
                for amount in 1..<(limit+1) {
                    if Task<Never,Never>.isCancelled { return incumbent }
                    let delta = amount*direction, shift = row ? CGPoint(x:delta,y:0):CGPoint(x:0,y:delta)
                    generated += 1; work += old.runs.count+external.count+1
                    if work > maxWork { return searchDeferred("search-work-budget") }
                    let next = old.translated(shift)
                    guard page.contains(next.bounds), let cost = error(f,bounds:next.bounds,page:page),
                          cost.center <= oldError.center+1e-7, cost.anchor <= oldError.anchor+1e-7,
                          next.runs.allSatisfy({ r in
                            let rect = CGRect(x:r.left,y:r.y,width:r.right-r.left,height:1)
                            return f.textExpansionPolicy!.allows(rect,page:page) && f.placementDomain!(rect)
                          }), maskMargin(next,fill:f,page:page) >= oldMargin else { localPruned += 1; continue }
                    // Own-body zero peers are intentionally NOT checked here:
                    // they may need to co-move to preserve their source gap.
                    var safe = true
                    for j in external {
                        if !pairGap(current.fills,i,j,oldA:old,oldB:supports[j],newA:next,newB:supports[j],page:page).allowed {
                            safe = false; break
                        }
                        if next.bounds.intersects(supports[j].bounds) {
                            work += next.runs.count+supports[j].runs.count
                            if work > maxWork { return searchDeferred("search-work-budget") }
                            if NativeFinalTextPaintAdmission.intersects(next,supports[j]) { safe = false; break }
                        }
                    }
                    guard safe else { localPruned += 1; continue }
                    // Pixel clearance is lazy: only selected joint paths are
                    // measured below, never hundreds of eager source samples.
                    optionRuns += next.runs.count
                    if optionRuns > maxOptionRuns { return searchDeferred("option-run-budget") }
                    choices.append(Choice(delta:delta,support:next,cost:Double(cost.center*cost.center+cost.anchor*cost.anchor)/unit,
                        improved:oldError.center-cost.center >= 1-1e-7 || oldError.anchor-cost.anchor >= 1-1e-7,
                        boundary:["status":"not-yet-measured","evidenceAvailable":false]))
                }
                // Keep all small integer choices; larger domains retain a
                // bounded spread plus the best local geometry option and the
                // smallest valid move. This is explicitly approximate.
                if choices.count > 9 {
                    var selected: Set<Int> = [0,1]
                    if let best = choices.indices.min(by:{ choices[$0].cost < choices[$1].cost }) { selected.insert(best) }
                    for fraction in [CGFloat(1),0.75,0.5,0.25,0.125,0.0625] {
                        let target = CGFloat(limit)*fraction
                        if let nearest = choices.indices.dropFirst().min(by:{ a,b in
                            let x = abs(CGFloat(abs(choices[a].delta))-target), y = abs(CGFloat(abs(choices[b].delta))-target)
                            return x == y ? abs(choices[a].delta) < abs(choices[b].delta):x < y
                        }) { selected.insert(nearest) }
                    }
                    representativePruned += choices.count-selected.count
                    choices = selected.sorted().map { choices[$0] }
                }
                options.append(choices)
            }
            guard options.flatMap({ $0 }).contains(where: { $0.improved }) else {
                continue
            }
            var transitions = 0, jointPruned = 0, beamPruned = 0, boundaryCalls = 0, riskPruned = 0
            var banned = [Set<Int>](repeating:[],count:members.count), rejectedVectors = Set<[Int]>()
            var boundaryDeferred = false, recovered = false
            candidateSearch: for attempt in 0..<candidateBudget {
                if Task<Never,Never>.isCancelled { return incumbent }
                var paths = options[0].enumerated().map { n,c in
                    banned[0].contains(n) ? []:[Path(choices:[n],vector:[c.delta],cost:c.cost,travel:abs(c.delta))]
                }
                for position in 1..<members.count {
                    var nextPaths = [[Path]](repeating:[],count:options[position].count)
                    for (index,choice) in options[position].enumerated() where !banned[position].contains(index) {
                        for endings in paths { for path in endings {
                            if Task<Never,Never>.isCancelled { return incumbent }
                            transitions += 1; work += 1
                            if work > maxWork { return searchDeferred("search-work-budget") }
                            var safe = true
                            for previous in 0..<position {
                                work += 1; if work > maxWork { return searchDeferred("search-work-budget") }
                                let i = members[previous], j = members[position], a = options[previous][path.choices[previous]].support
                                if !pairOrder(supports[i].bounds,supports[j].bounds,a.bounds,choice.support.bounds,row:row) ||
                                    !pairGap(current.fills,i,j,oldA:supports[i],oldB:supports[j],newA:a,newB:choice.support,page:page).allowed {
                                    safe = false; break
                                }
                                if a.bounds.intersects(choice.support.bounds) {
                                    work += a.runs.count+choice.support.runs.count
                                    if work > maxWork { return searchDeferred("search-work-budget") }
                                    if NativeFinalTextPaintAdmission.intersects(a,choice.support) { safe = false; break }
                                }
                            }
                            guard safe else { jointPruned += 1; continue }
                            nextPaths[index].append(Path(choices:path.choices+[index],vector:path.vector+[choice.delta],
                                cost:path.cost+choice.cost,travel:path.travel+abs(choice.delta)))
                            nextPaths[index].sort(by:precedes)
                            if nextPaths[index].count > keep { nextPaths[index].removeLast(); beamPruned += 1 }
                        }}
                    }
                    paths = nextPaths
                }
                let ranked = paths.flatMap { $0 }.filter { path in
                    !rejectedVectors.contains(path.vector) && path.choices.indices.contains { options[$0][path.choices[$0]].improved }
                }.sorted(by:precedes)
                guard let path = ranked.first else { break }
                rejectedVectors.insert(path.vector)
                var shifts = [CGPoint](repeating:.zero,count:current.fills.count), proposed = supports
                var boundaryChecks: [String:[String:Any]] = [:]
                for (n,i) in members.enumerated() {
                    let choice = options[n][path.choices[n]]
                    shifts[i] = row ? CGPoint(x:choice.delta,y:0):CGPoint(x:0,y:choice.delta)
                    proposed[i] = choice.support
                }
                guard let validated = try? contract(current.fills,before:supports,after:proposed,bodyIDs:[bodyID],page:page) else { continue }
                // Before expensive native place. A provided gate becoming nil
                // is NOT optional-mode clearance; defer the complete group.
                var vetoed = false
                for (n,i) in members.enumerated() where shifts[i] != .zero {
                    if let boundaryGate {
                        guard boundaryCalls < 64 else { boundaryDeferred = true; break candidateSearch }
                        boundaryCalls += 1
                        let check = boundaryGate(supports[i],proposed[i]); boundaryChecks[owners[i]] = check.audit
                        if Task<Never,Never>.isCancelled { return incumbent }
                        guard let allowed = check.allowed else { boundaryDeferred = true; break candidateSearch }
                        if !allowed {
                            banned[n].insert(path.choices[n]); boundaryPruned += 1; vetoed = true
                            if vetoes.count < 32 { vetoes.append(["owner":owners[i],"delta":path.vector[n],"evidence":check.audit]) }
                        }
                    } else { boundaryChecks[owners[i]] = ["status":"no-source-context","evidenceAvailable":false] }
                }
                if vetoed { continue }
                var replacements = current.fills
                // Only after a complete improving geometry proof may this
                // group's soft target become explicitly relaxed. Peers pinned.
                for i in members { replacements[i].balloonTargetRelaxed = true }
                let fixed = Dictionary(uniqueKeysWithValues:owners.indices.map { (owners[$0],proposed[$0].bounds.origin) })
                guard nativeTransactions < 32 else { return searchDeferred("native-transaction-budget") }
                nativeTransactions += 1
                guard var admitted = try? NativeFinalTextPaintAdmission.place(replacements,page:page,fixedOrigins:fixed,retainedClusterAnchors:anchors),
                      admitted.fills.count == current.fills.count, admitted.audit.count == current.audit.count else { continue }
                var safe = true
                for i in current.fills.indices {
                    let flagAllowed = memberSet.contains(i) ? admitted.fills[i].balloonTargetRelaxed :
                        admitted.fills[i].balloonTargetRelaxed == current.fills[i].balloonTargetRelaxed
                    guard flagAllowed, carrierPreserved(current.fills[i],admitted.fills[i],shift:shifts[i],preserveRelaxation:!memberSet.contains(i)),
                          let bytes = try? NativeMandatoryDisplayStroke.rgba(admitted.fills[i].image), bytes == originalRGBA[i] else { safe = false; break }
                }
                guard safe, let actual = try? admitted.fills.map({ try NativeFinalTextPaintAdmission.retainedFootprint($0) }),
                      actual.indices.allSatisfy({ i in actual[i].bounds == proposed[i].bounds && actual[i].pixels == proposed[i].pixels &&
                        actual[i].runs.count == proposed[i].runs.count && zip(actual[i].runs,proposed[i].runs).allSatisfy({
                            $0.y == $1.y && $0.left == $1.left && $0.right == $1.right }) }),
                      (try? contract(current.fills,before:supports,after:actual,bodyIDs:[bodyID],page:page)) != nil,
                      (try? NativeFinalTextPaintAdmission.verifyRetainedPlacement(admitted.fills,footprints:actual,page:page,retainedClusterAnchors:anchors)) != nil else { continue }
                for (n,i) in members.enumerated() where shifts[i] != .zero {
                    if let risk, risk.evaluate(supports[i],actual[i]) != true {
                        safe = false; riskPruned += 1; banned[n].insert(path.choices[n])
                    }
                }
                guard safe else { continue }
                // Reconcile COMPLETE external groups against the actual fresh
                // audit. A snapshot-only copy could hide target drift or lose
                // an explicit policy reason in a generic inherited recapture.
                guard let externalAudit = try? NativeBalloonPlacement.RetainedState.preservingKnownSnapshots(
                    priorAudit:external.map { current.audit[$0] }, admittedAudit:external.map { admitted.audit[$0] },
                    unknownPolicy:.preservePriorUncertainty, inputPolicy:.retainedEffectivePacket) else { continue }
                for (n,i) in external.enumerated() { admitted.audit[i] = externalAudit[n] }
                let beforeErrors = validated.beforeErrors, costs = validated.afterErrors
                let totalBefore = members.reduce(0.0) { $0+Double(pow(beforeErrors[$1]!.center,2)+pow(beforeErrors[$1]!.anchor,2)) }
                let totalAfter = members.reduce(0.0) { $0+Double(pow(costs[$1]!.center,2)+pow(costs[$1]!.anchor,2)) }
                var audit = current.audit
                for i in audit.indices {
                    audit[i].merge(admitted.audit[i]) { _,new in new }
                    if current.audit[i]["retainedSourceClusterAnchorApplied"] as? Bool != true { audit[i].removeValue(forKey:"retainedSourceClusterAnchorApplied") }
                    guard memberSet.contains(i) else { continue }
                    audit[i].removeValue(forKey:"bodySourceBoundaryGate")
                    audit[i].removeValue(forKey:"bodySourceAnchorSearch")
                    audit[i]["balloonBodyPlaced"] = false; audit[i]["balloonCapacityFallback"] = true
                    audit[i]["balloonTargetRelaxed"] = true; audit[i]["balloonTargetFallbackReason"] = jointPolicyReason
                    audit[i]["bodySourceAnchorRecoveryPolicy"] = ["reason":jointPolicyReason,"bodyID":bodyID,"members":groupOwners,
                        "completeGroupProved":true,"previousRelaxed":current.fills[i].balloonTargetRelaxed,"physicalContainmentMeasured":false]
                    do {
                        let s = try NativeBalloonPlacement.RetainedState.capture(owner:owners[i],inputPacket:replacements[i].balloonPlacement,
                            effectivePacket:admitted.fills[i].balloonPlacement,groupOwners:groupOwners,relaxed:true,targetPlaced:false,fallbackReason:jointPolicyReason)
                        typealias State = NativeBalloonPlacement.RetainedState
                        guard let priorValue = current.audit[i][State.auditKey] else { safe = false; break }
                        let prior = try State.decode(priorValue,owner:owners[i])
                        let receipt = State.Snapshot(schema:s.schema,owner:s.owner,presence:s.presence,inputPacket:prior.inputPacket,
                            effectivePacket:s.effectivePacket,groupOwners:s.groupOwners,balloonTargetRelaxed:s.balloonTargetRelaxed,
                            target:s.target,fallbackReason:s.fallbackReason,provenance:.nativeAdmission,
                            requiresFixedOriginRevalidation:false,historicalStateExact:prior.historicalStateExact,sourceIdentity:prior.sourceIdentity)
                        audit[i][State.auditKey] = try State.encode(receipt)
                    } catch { safe = false; break }
                    if shifts[i] != .zero {
                        audit[i]["bodySourceAnchorRecovery"] = ["version":"body-source-anchor-recovery-v2-joint",
                            "sourceBoundaryGate":boundaryChecks[owners[i]]!,"sourceBoundaryVetoedChoices":vetoes,"sourceBoundaryVetoedChoiceCount":boundaryPruned,
                            "stage":"body-candidate-before-physical","bodyID":bodyID,"axis":row ? "x":"y","candidateOrdinal":attempt+1,
                            "search":"bounded-k-best-chain-dp-all-previous-pairs","exactOptimumClaimed":false,"pathsPerEndingChoice":keep,
                            "generatedChoices":generated,"localPrunedChoices":localPruned,"jointPrunedPaths":jointPruned,"beamPrunedPaths":beamPruned,
                            "transitions":transitions,"candidateBudget":candidateBudget,"candidateBudgetPruned":max(0,ranked.count-1),"boundaryCalls":boundaryCalls,"boundaryCallBudget":64,
                            "boundaryBudgetDeferred":false,"repackBudget":candidateBudget,
                            "representativePrunedChoices":representativePruned,"maximumRetainedChoicesPerOwner":9,"sourceRiskPrunedChoices":riskPruned,
                            "nativeTransactionsUsed":nativeTransactions,"nativeTransactionBudget":32,
                            "searchWorkUsed":work,"searchWorkBudget":maxWork,"optionRunBudget":maxOptionRuns,
                            "shiftOutputPixels":[shifts[i].x,shifts[i].y],"maximumShiftEm":0.5,
                            "centerErrorBeforePixels":beforeErrors[i]!.center,"centerErrorAfterPixels":costs[i]!.center,
                            "guideAnchorErrorBeforePixels":beforeErrors[i]!.anchor,"guideAnchorErrorAfterPixels":costs[i]!.anchor,
                            "assignedMaskMarginBeforePixels":validated.beforeMargins[i]!,"assignedMaskMarginAfterPixels":validated.afterMargins[i]!,
                            "assignedMaskMarginLimitPixels":2,"groupSquaredCostBefore":totalBefore,"groupSquaredCostAfter":totalAfter,
                            "normalizedJointCostAfter":path.cost,"gapPairsChecked":validated.gapPairs,"minimumGapSurplus":validated.minimumSurplus as Any? ?? NSNull(),
                            "gapChecks":validated.gaps,"gapChecksTruncated":validated.gapPairs>validated.gaps.count,
                            "retainedSourceRisk":risk == nil ? "unmeasured":"accepted","physicalContainmentMeasured":false,"fixedRasterOnly":true]
                    }
                }
                guard safe else { continue }
                if Task<Never,Never>.isCancelled { return incumbent }
                admitted.audit = audit; current = admitted; supports = actual; recovered = true
                break
            }
            if !recovered {
                for i in members {
                    current.audit[i]["bodySourceAnchorSearch"] = ["status":boundaryDeferred ? "deferred-unknown-boundary":"no-proved-joint-candidate",
                        "bodyID":bodyID,"generatedChoices":generated,"representativePrunedChoices":representativePruned,
                        "localPrunedChoices":localPruned,"jointPrunedPaths":jointPruned,"beamPrunedPaths":beamPruned,
                        "transitions":transitions,"attemptedJointCandidates":rejectedVectors.count,"candidateBudget":candidateBudget,"sourceRiskPrunedChoices":riskPruned,
                        "boundaryCalls":boundaryCalls,"boundaryCallBudget":64,"workUsed":work,"workBudget":maxWork,
                        "exactOptimumClaimed":false,"physicalContainmentMeasured":false]
                }
            }
            if !recovered && (boundaryDeferred || boundaryPruned > 0) {
                for i in members {
                    current.audit[i]["bodySourceBoundaryGate"] = ["status":boundaryDeferred ? "deferred-unknown-boundary":"retained-after-boundary-veto",
                        "bodyID":bodyID,"vetoedChoices":vetoes,"vetoedChoiceCount":boundaryPruned,
                        "boundaryCalls":boundaryCalls,"boundaryCallBudget":64,"candidateBudget":candidateBudget,
                        "boundaryBudgetDeferred":boundaryDeferred,"physicalContainmentMeasured":false]
                }
            }
        }
        return current
    }
}
