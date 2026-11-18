import CoreGraphics
import CryptoKit
import Foundation

/// Fixed-raster, complete exterior-cohort source-centre improvement. Caller
/// supplies authenticated DECLARED membership and an original-RGB boundary gate.
/// A boundary observation is not universal physical-interior certification.
enum NativeSourceCohortCenterBalance {
    typealias Primitive = NativeAOTTranslationPageComposer.TranslatedFillPrimitive
    typealias Tuple = (fills: [Primitive], audit: [[String: Any]])
    typealias Footprint = NativeFinalTextPaintAdmission.Footprint
    typealias BoundaryGate = (Footprint, Footprint) -> (allowed: Bool?, audit: [String: Any])
    private typealias N = NativeFinalTextPaintAdmission
    private typealias State = NativeBalloonPlacement.RetainedState
    static let auditKey = "sourceCohortCenterBalance"
    private static let version = "source-cohort-center-balance-v1"
    enum Failure: Error { case invalid, budget, binding, partialGroup }

    /// Qualified by the full paired corpus and every changed-page crop review.
    /// Explicit zero retains the original placement path.
    static var enabled: Bool { ProcessInfo.processInfo.environment["AIDOKU_SOURCE_COHORT_CENTER_BALANCE"] != "0" }

    static var currentBoundaryContext: NativeSourcePhysicalInteriorContext? {
        NativeSourcePhysicalInteriorContext.cohortBoundaryContext ?? NativeSourcePhysicalInteriorContext.current
    }

    /// Image-free structural record, shared by raw context allocation and typed
    /// terminal preflight. Raw absence is NOT known historical body state.
    private struct EligibilityMember {
        let owner: String
        let packet: NativeSourceClusterAlignment?
        let guide: NativeTextPlacementGuide?
        let policy: NativeTextExpansionPolicy?
        let hasBody: Bool
        let rendered: Bool
    }
    private static func eligibleCohorts(_ members: [EligibilityMember], declared: [String: Set<String>],
                                        protected: Set<String> = []) -> [String: [Int]] {
        guard !members.isEmpty, members.count <= 256, declared.count <= 256,
              members.allSatisfy({ !$0.owner.isEmpty }), Set(members.map(\.owner)).count == members.count else { return [:] }
        // Group ALL declared packets first. Never create a smaller group by
        // removing an inside/held/protected/malformed/unrendered member.
        let groups = Dictionary(grouping: members.indices.filter { members[$0].packet != nil },
            by: { members[$0].packet!.groupID })
        return groups.filter { group, indices in
            let owners = Set(indices.map { members[$0].owner })
            guard (2...64).contains(indices.count), declared[group] == owners,
                  owners.isDisjoint(with: protected), let first = indices.first,
                  let packet = members[first].packet else { return false }
            return indices.allSatisfy { i in
                let m = members[i]
                guard m.rendered, !m.hasBody, let p = m.packet, p.valid,
                      p.axis == packet.axis, p.anchorPolicy == "source-near-final-alpha", p.anchorsToSourceStart == true,
                      abs(p.anchorNormalized - packet.anchorNormalized) <= 1e-9,
                      let guide = m.guide, guide.valid, let policy = m.policy, policy.valid, !policy.insideBalloon else { return false }
                return packet.axis == .top ? guide.vertical == .center : guide.horizontal == .center
            }
        }
    }

    /// Potential allocation only; final typed/Snapshot/actual-alpha admission
    /// remains mandatory. No RGB decoding, raster support or audit hashing.
    static func requiresOriginalBoundaryContext(rawItems: [[String: Any]], renderedOwnerIDs: Set<String>) throws -> Bool {
        guard rawItems.count <= 256, renderedOwnerIDs.count <= 256 else { return false }
        var members: [EligibilityMember] = [], declared: [String: Set<String>] = [:], seen = Set<String>()
        for raw in rawItems {
            guard let owner = raw["id"] as? String, !owner.isEmpty, seen.insert(owner).inserted else { throw Failure.invalid }
            let packet = try NativeSourceClusterAlignment.decode(raw["sourceClusterAlignment"])
            if let packet { declared[packet.groupID, default: []].insert(owner) }
            // Non-cohort fields follow their normal renderer validation path.
            // Do not decode unrelated policies merely to allocate evidence.
            var guide: NativeTextPlacementGuide?, policy: NativeTextExpansionPolicy?
            var hasBody = false
            if packet != nil {
                guide = try NativeTextPlacementGuide.decode(raw["textPlacementGuide"])
                policy = try NativeTextExpansionPolicy.decode(raw["textExpansionPolicy"])
                hasBody = try NativeBalloonPlacement.decode(raw["balloonPlacement"]) != nil
            }
            members.append(EligibilityMember(owner:owner,packet:packet,guide:guide,policy:policy,
                hasBody:hasBody,rendered:renderedOwnerIDs.contains(owner)))
        }
        return !eligibleCohorts(members, declared:declared).isEmpty
    }

    static func sourceContextRequest(physicalRequested: Bool, rawItems: [[String: Any]], renderedOwnerIDs: Set<String>) throws
        -> (needed: Bool, cohortBoundary: Bool) {
        var cohort = false
        if enabled { cohort = try requiresOriginalBoundaryContext(rawItems:rawItems,renderedOwnerIDs:renderedOwnerIDs) }
        return (physicalRequested || cohort, cohort)
    }

    /// Cohort-only stricter policy: no lost pixel of clearance when the new
    /// alpha is within two pixels of preserved source boundaries. Existing
    /// callers of context.boundaryClearance retain their default loss budget 1.
    static func originalSourceBoundaryGate(_ context: NativeSourcePhysicalInteriorContext) -> BoundaryGate {
        { before, after in
            context.boundaryClearance(before: before, after: after, maximumAllowedDecreasePixels: 0, minimumChannelContrast: 32)
        }
    }

    private static func check(_ value: Bool) throws { if !value { throw Failure.binding } }
    private static func rectArray(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height].map(Double.init) }
    private static func number(_ value: Any?) -> CGFloat? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return CGFloat(n.doubleValue)
    }
    private static func rect(_ value: Any?) -> CGRect? {
        guard let a = value as? [Any], a.count == 4 else { return nil }
        let v = a.compactMap { number($0) }
        guard v.count == 4, v[2] > 0, v[3] > 0 else { return nil }
        let r = CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
        return r == r.integral ? r : nil
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func object<T: Encodable>(_ value: T?) throws -> Any {
        guard let value else { return NSNull() }
        return try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
    private static func boundedJSON(_ value: Any, depth: Int = 0, path: String = "", nodes: inout Int) throws {
        nodes += 1
        guard nodes <= 8192, depth <= 12 else { throw Failure.budget }
        if let s = value as? String { guard s.utf8.count <= 4096 else { throw Failure.budget } }
        else if let a = value as? [Any] {
            // This typed policy permits up to 4096 exclusion rows and 1024
            // interval endpoints per row. Bind EVERY entry; do not confuse
            // geometry rows with an arbitrary appearance/provenance array.
            let limit = path == "policy.forbiddenBalloonRowsNormalized" ? 4096
                : (path == "policy.forbiddenBalloonRowsNormalized[]" ? 1024 : 256)
            guard a.count <= limit else { throw Failure.budget }
            for v in a { try boundedJSON(v, depth: depth + 1, path: path + "[]", nodes: &nodes) }
        } else if let d = value as? [String: Any] {
            guard d.count <= 128 else { throw Failure.budget }
            for (k, v) in d {
                guard k.utf8.count <= 256 else { throw Failure.budget }
                try boundedJSON(v, depth: depth + 1, path: path.isEmpty ? k : path + "." + k, nodes: &nodes)
            }
        } else if !(value is NSNumber) && !(value is NSNull) { throw Failure.invalid }
    }
    /// Binds all paint/style/packet inputs AND actual fill bytes, but excludes
    /// position. Full styled alpha is separately reconstructed and compared.
    private static func binding(_ f: Primitive) throws -> String {
        var style: Any = NSNull()
        if let s = f.sourceStyle {
            style = ["font": s.sourceFontPixels, "bands": s.bands.map { ["rgb": $0.rgb, "width": $0.width] as [String: Any] },
                "shadowRGB": s.shadow.map { $0.rgb as Any } ?? NSNull(), "shadowOffset": s.shadow.map { $0.offset as Any } ?? NSNull(),
                "roundedContour": s.roundedContour.map { $0.identity as Any } ?? NSNull()] as [String: Any]
        }
        let fields: [String: Any] = ["owner": f.ownerID as Any? ?? NSNull(), "font": Double(f.fontOutputPixels),
            "size": [f.image.width, f.image.height], "finalEffects": f.hasFinalEffects, "sourceContourOnly": f.sourceContourOnly,
            "endpoint": f.displayStrokeEndpoint.map { Int($0) as Any } ?? NSNull(),
            "ratio": f.displayStrokeRatio.map { Double($0) as Any } ?? NSNull(), "recheck": f.recheckFinalEndpoint,
            "contrast": f.minimumFillStrokeContrast, "coverage": f.minimumCoverageGain, "style": style,
            "appearance": f.sourceAppearance as Any? ?? NSNull(), "cohort": try object(f.sourceClusterAlignment),
            "guide": try object(f.textPlacementGuide), "policy": try object(f.textExpansionPolicy),
            "body": try object(f.balloonPlacement), "relaxed": f.balloonTargetRelaxed]
        var nodes = 0; try boundedJSON(fields, nodes: &nodes)
        var data = try JSONSerialization.data(withJSONObject: fields, options: .sortedKeys)
        guard data.count <= 131072 else { throw Failure.budget }
        data.append(contentsOf: try NativeMandatoryDisplayStroke.rgba(f.image))
        return digest(data)
    }
    private static func same(_ a: Footprint, _ b: Footprint) -> Bool {
        a.bounds == b.bounds && a.readableBounds == b.readableBounds && a.pixels == b.pixels &&
            a.runs.count == b.runs.count && zip(a.runs, b.runs).allSatisfy {
                $0.0.y == $0.1.y && $0.0.left == $0.1.left && $0.0.right == $0.1.right
            }
    }
    private static func state(_ row: [String: Any], fill: Primitive) throws -> State.Snapshot {
        guard let owner = fill.ownerID, row["owner"] as? String == owner,
              case .state(let s) = try State.read(row, owner: owner), !s.requiresFixedOriginRevalidation,
              s.effectivePacket == fill.balloonPlacement, s.balloonTargetRelaxed == fill.balloonTargetRelaxed else { throw Failure.binding }
        return s
    }
    private static func absent(_ row: [String: Any], fill: Primitive) throws -> State.Snapshot {
        let s = try state(row, fill: fill)
        guard s.presence == .absent, s.target == .absent, s.inputPacket == nil,
              fill.balloonPlacement == nil, !fill.balloonTargetRelaxed else { throw Failure.binding }
        return s
    }
    private static func boundaryEvidence(_ audit: [String: Any], pixels: Int) -> String? {
        guard audit["policy"] as? String == "source-preserved-boundary-chebyshev-v1",
              number(audit["maximumAllowedDecreasePixels"]) == 0,
              number(audit["contrastRange"]) == 32,
              let source = audit["sourceIdentity"] as? String, !source.isEmpty, source.utf8.count <= 512,
              audit["evidenceAvailable"] as? Bool == true, audit["observationComplete"] as? Bool == true,
              number(audit["comparedAlphaPixels"]) == CGFloat(pixels), number(audit["adverseAlphaPixels"]) == 0,
              number(audit["unobservedAlphaPixels"]) == 0 else { return nil }
        return source
    }

    /// Complete ORIGINAL-incumbent readable-peer check. Reuses the established
    /// measured projection rule and .35em larger-font floor; inherited smaller
    /// gaps need not improve, but must not shrink. A new comparable neighbour
    /// must meet the floor. No new alpha threshold or source interpretation.
    static func peerGutterSafety(fills: [Primitive], before: [Footprint], after: [Footprint],
                                movedOwners: Set<String>) -> (allowed: Bool, audit: [String: Any]) {
        guard fills.count == before.count, fills.count == after.count, fills.count <= 256,
              movedOwners.count <= 256 else { return (false, ["reason": "peer-inventory-budget"]) }
        let ids = fills.compactMap(\.ownerID)
        guard ids.count == fills.count, Set(ids).count == ids.count, movedOwners.isSubset(of: Set(ids)),
              fills.allSatisfy({ $0.fontOutputPixels.isFinite && $0.fontOutputPixels > 0 }) else {
            return (false, ["reason": "invalid-peer-carrier"])
        }
        var checked = 0
        for i in fills.indices { for j in fills.indices where j > i {
            guard movedOwners.contains(ids[i]) || movedOwners.contains(ids[j]) else { continue }
            let a = before[i].readableBounds ?? before[i].bounds, b = before[j].readableBounds ?? before[j].bounds
            let c = after[i].readableBounds ?? after[i].bounds, d = after[j].readableBounds ?? after[j].bounds
            let old = NativeAdaptiveTextGutter.clearance(a, b), new = NativeAdaptiveTextGutter.clearance(c, d)
            guard old != nil || new != nil else { continue }
            checked += 1
            let floor = ceil(0.35 * max(fills[i].fontOutputPixels, fills[j].fontOutputPixels))
            let required = min(old ?? floor, floor)
            // If projection ceased to be comparable, a bounding-box distance
            // at least the required gap still proves sufficient separation.
            let dx = max(0, max(c.minX - d.maxX, d.minX - c.maxX))
            let dy = max(0, max(c.minY - d.maxY, d.minY - c.maxY))
            let measured = new ?? hypot(dx, dy)
            if measured + 1e-7 < required {
                return (false, ["reason": "readable-peer-gutter", "owners": [ids[i], ids[j]],
                    "oldGap": old.map { Double($0) as Any } ?? NSNull(), "newGap": Double(measured),
                    "requiredGap": Double(required), "fontFloor": Double(floor), "checkedPairs": checked])
            }
        }}
        return (true, ["reason": "complete-peer-readable-gutters-preserved", "checkedPairs": checked])
    }

    /// Receipt validation for shared final verification, reload and a second
    /// admission. It grants ONLY the bound complete fixed-raster anchor. Native
    /// place/verify still owns page, domain, peers, bodies and clipping checks.
    static func verifiedRetainedAnchors(_ fills: [Primitive], footprints: [Footprint],
                                       audit: [[String: Any]], page: CGRect) throws -> [String: CGFloat] {
        guard fills.count == footprints.count, fills.count == audit.count, fills.count <= 256 else { throw Failure.invalid }
        let owners = fills.compactMap(\.ownerID)
        guard owners.count == fills.count, Set(owners).count == owners.count else { throw Failure.invalid }
        let groups = Dictionary(grouping: fills.indices.filter { fills[$0].sourceClusterAlignment != nil },
            by: { fills[$0].sourceClusterAlignment!.groupID })
        var result: [String: CGFloat] = [:], consumed = Set<Int>(), pixels = 0
        for i in fills.indices where audit[i][auditKey] != nil {
            if consumed.contains(i) { continue }
            guard let packet = fills[i].sourceClusterAlignment, let members = groups[packet.groupID],
                  (2...64).contains(members.count) else { throw Failure.partialGroup }
            let cohort = members.map { owners[$0] }.sorted(), vertical = packet.axis == .top
            var oldAnchor: CGFloat?, newAnchor: CGFloat?, sourceIdentity: String?
            var beforeCost: CGFloat = 0, afterCost: CGFloat = 0
            for j in members {
                let fill = fills[j], actual = footprints[j], row = audit[j]
                guard let p = fill.sourceClusterAlignment, p.valid, p.axis == packet.axis,
                      p.anchorPolicy == "source-near-final-alpha", p.anchorsToSourceStart == true,
                      abs(p.anchorNormalized - packet.anchorNormalized) <= 1e-9,
                      let policy = fill.textExpansionPolicy, policy.valid, !policy.insideBalloon,
                      let guide = fill.textPlacementGuide, guide.valid,
                      vertical ? guide.vertical == .center : guide.horizontal == .center,
                      fill.frame == fill.frame.integral, page.contains(fill.frame),
                      fill.image.width > 0, fill.image.height > 0, fill.image.width <= 8_000_000 / fill.image.height,
                      fill.frame.width == CGFloat(fill.image.width), fill.frame.height == CGFloat(fill.image.height),
                      fill.fontOutputPixels.isFinite, fill.fontOutputPixels > 0,
                      let proof = row[auditKey] as? [String: Any], proof.count <= 24,
                      proof["version"] as? String == version, proof["groupID"] as? String == packet.groupID,
                      proof["owners"] as? [String] == cohort, proof["axis"] as? String == packet.axis.rawValue,
                      let old = number(proof["oldAnchor"]), let new = number(proof["newAnchor"]),
                      old == old.rounded(), new == new.rounded(), old != new,
                      let beforeFrame = rect(proof["beforeFrame"]), let beforeBounds = rect(proof["beforeBounds"]),
                      rect(proof["afterFrame"]) == fill.frame, rect(proof["afterBounds"]) == actual.bounds,
                      page.contains(beforeFrame), page.contains(beforeBounds),
                      row["retainedSourceClusterAnchorApplied"] as? Bool == true,
                      row["sourceClusterID"] as? String == packet.groupID,
                      row["sourceClusterAxis"] as? String == packet.axis.rawValue,
                      row["effectsIncluded"] as? Bool == true,
                      rect(row["finalFootprintOutputPixels"]) == actual.bounds,
                      number(row["paintedPixels"]) == CGFloat(actual.pixels),
                      number(row["sourceClusterAnchorOutputPixels"]) == new,
                      let evidence = proof["sourceBoundary"] as? [String: Any],
                      let source = boundaryEvidence(evidence, pixels: actual.pixels),
                      sourceIdentity == nil || sourceIdentity == source,
                      oldAnchor == nil || oldAnchor == old, newAnchor == nil || newAnchor == new else { throw Failure.binding }
                let snapshot = try absent(row, fill: fill)
                try check(proof["stateSHA256"] as? String == digest(try JSONSerialization.data(withJSONObject: State.encode(snapshot), options: .sortedKeys)))
                try check(proof["carrierSHA256"] as? String == binding(fill))
                let delta = vertical ? CGPoint(x: 0, y: new - old) : CGPoint(x: new - old, y: 0)
                try check(beforeFrame.offsetBy(dx: delta.x, dy: delta.y) == fill.frame)
                var before = fill; before.frame = beforeFrame
                let original = try N.retainedFootprint(before), fresh = try N.retainedFootprint(fill)
                pixels += fill.image.width * fill.image.height
                guard pixels <= 16_777_216 else { throw Failure.budget }
                try check(original.bounds == beforeBounds && same(fresh, actual) && same(original.translated(delta), actual))
                try check((vertical ? beforeBounds.minY : beforeBounds.minX) == old && (vertical ? actual.bounds.minY : actual.bounds.minX) == new)
                let sourceRect = guide.rect(in: page)
                let a = hypot(beforeBounds.midX - sourceRect.midX, beforeBounds.midY - sourceRect.midY)
                let b = hypot(actual.bounds.midX - sourceRect.midX, actual.bounds.midY - sourceRect.midY)
                try check(b <= a + 1e-7)
                beforeCost += pow(a / fill.fontOutputPixels, 2); afterCost += pow(b / fill.fontOutputPixels, 2)
                oldAnchor = old; newAnchor = new; sourceIdentity = source; consumed.insert(j)
            }
            try check(afterCost < beforeCost - 1e-9)
            result[packet.groupID] = newAnchor!
        }
        return result
    }

    /// Retains proof across a fresh native admission ONLY if the complete bound
    /// cohort is stationary with identical carriers and known absent body state.
    /// Other bodies' explicit transitions are reconciled by their existing owner.
    static func preservingReceipts(prior: Tuple, admitted: Tuple, page: CGRect) throws -> Tuple {
        guard prior.fills.count == admitted.fills.count, prior.audit.count == prior.fills.count,
              admitted.audit.count == admitted.fills.count else { throw Failure.invalid }
        let priorSupport = try prior.fills.map { try N.retainedFootprint($0) }
        let retained = try verifiedRetainedAnchors(prior.fills, footprints: priorSupport, audit: prior.audit, page: page)
        var next = admitted
        let indices = prior.fills.indices.filter { i in
            prior.fills[i].sourceClusterAlignment.map { retained[$0.groupID] != nil } ?? false
        }
        // Balanced members have known ABSENT singleton body states. Restore
        // their full lineage from a fresh native capture, without imposing a
        // policy on unrelated bodies' separately authorized transitions.
        let reconciled = try State.preservingKnownSnapshots(priorAudit: indices.map { prior.audit[$0] },
            admittedAudit: indices.map { admitted.audit[$0] }, unknownPolicy: .reject)
        for (position, i) in indices.enumerated() { next.audit[i] = reconciled[position] }
        for i in prior.fills.indices {
            guard prior.fills[i].ownerID == admitted.fills[i].ownerID else { throw Failure.binding }
            guard let group = prior.fills[i].sourceClusterAlignment?.groupID, retained[group] != nil else { continue }
            try check(NativeBodySourceAnchorRecovery.carrierPreserved(prior.fills[i], admitted.fills[i], shift: .zero))
            try check(try binding(prior.fills[i]) == binding(admitted.fills[i]))
            try check(try absent(prior.audit[i], fill: prior.fills[i]) == absent(next.audit[i], fill: admitted.fills[i]))
            next.audit[i][auditKey] = prior.audit[i][auditKey]
        }
        let nextSupport = try next.fills.map { try N.retainedFootprint($0) }
        try check(prior.fills.indices.allSatisfy { prior.fills[$0].fontOutputPixels == next.fills[$0].fontOutputPixels })
        try check(peerGutterSafety(fills: prior.fills, before: priorSupport, after: nextSupport,
            movedOwners: Set(indices.map { prior.fills[$0].ownerID! })).allowed)
        _ = try verifiedRetainedAnchors(next.fills, footprints: nextSupport, audit: next.audit, page: page)
        return next
    }

    static func refine(_ incumbent: Tuple, page: CGRect, declaredCohorts: [String: Set<String>],
                       boundaryGate: BoundaryGate? = nil, protectedOwners: Set<String> = []) -> Tuple {
        guard enabled,
              let boundaryGate, !Task<Never, Never>.isCancelled, !incumbent.fills.isEmpty,
              incumbent.fills.count <= 256, incumbent.fills.count == incumbent.audit.count,
              page == page.integral, page.origin == .zero, page.width > 2, page.height > 2,
              page.width <= 16384, page.height <= 16384 else { return incumbent }
        let owners = incumbent.fills.compactMap(\.ownerID)
        guard owners.count == incumbent.fills.count, Set(owners).count == owners.count,
              declaredCohorts.count <= 256 else { return incumbent }
        let descriptors = incumbent.fills.map { f in
            EligibilityMember(owner:f.ownerID!,packet:f.sourceClusterAlignment,guide:f.textPlacementGuide,
                policy:f.textExpansionPolicy,hasBody:f.balloonPlacement != nil,rendered:true)
        }
        var groups = eligibleCohorts(descriptors,declared:declaredCohorts,protected:protectedOwners)
        guard !groups.isEmpty else { return incumbent }
        // Existing runtime-only state/receipt gates precede all RGBA bindings
        // and styled footprint preparation. Every peer is STILL validated below
        // once any candidate remains; unknown states never become permission.
        groups = groups.filter { _, members in
            members.allSatisfy { i in
                incumbent.audit[i][auditKey] == nil && (try? absent(incumbent.audit[i],fill:incumbent.fills[i])) != nil
            }
        }
        guard !groups.isEmpty else { return incumbent }
        do {
            var total = 0, snapshots: [String: State.Snapshot] = [:], bindings = [String]()
            for i in incumbent.fills.indices {
                let f = incumbent.fills[i]
                guard !owners[i].isEmpty, f.frame == f.frame.integral, page.contains(f.frame),
                      f.image.height > 0, f.image.width > 0, f.image.width <= 8_000_000 / f.image.height,
                      f.frame.width == CGFloat(f.image.width), f.frame.height == CGFloat(f.image.height),
                      f.fontOutputPixels.isFinite, f.fontOutputPixels > 0 else { return incumbent }
                total += f.image.width * f.image.height
                guard total <= 16_777_216 else { return incumbent }
                snapshots[owners[i]] = try state(incumbent.audit[i], fill: f)
                bindings.append(try binding(f))
            }
            try State.validateGroups(snapshots)
            let original = try incumbent.fills.map { try N.retainedFootprint($0) }
            guard original.reduce(0, { $0 + $1.runs.count }) <= 1_000_000,
                  var anchors = NativeReadablePeerGutter.retainedAnchors(packets: incumbent.fills.map(\.sourceClusterAlignment),
                    origins: original.map { $0.bounds.origin }) else { return incumbent }
            var current = incumbent
            for group in groups.keys.sorted() {
                if Task<Never, Never>.isCancelled { return incumbent }
                let members = groups[group]!, cohort = members.map { owners[$0] }.sorted()
                guard let old = anchors[group] else { continue }
                let packet = incumbent.fills[members[0]].sourceClusterAlignment!, vertical = packet.axis == .top
                var lo = -CGFloat.infinity, hi = CGFloat.infinity, sum = CGFloat(0), weight = CGFloat(0), ideals: [Int: CGFloat] = [:]
                for i in members {
                    let f = incumbent.fills[i], box = original[i].bounds, source = f.textPlacementGuide!.rect(in: page)
                    let ideal = vertical ? source.midY - box.height / 2 : source.midX - box.width / 2
                    ideals[i] = ideal
                    lo = max(lo, min(old, 2 * ideal - old)); hi = min(hi, max(old, 2 * ideal - old))
                    let capacity = NativeTextExpansionPolicy.rect(f.textExpansionPolicy!.allowedRectNormalized, page: page)
                    if vertical {
                        lo = max(lo, old - f.frame.minY, old + capacity.minY - box.minY)
                        hi = min(hi, old + page.height - f.frame.maxY, old + capacity.maxY - box.maxY)
                    } else {
                        lo = max(lo, old - f.frame.minX, old + capacity.minX - box.minX)
                        hi = min(hi, old + page.width - f.frame.maxX, old + capacity.maxX - box.maxX)
                    }
                    let w = 1 / (f.fontOutputPixels * f.fontOutputPixels); sum += ideal * w; weight += w
                }
                let lower = ceil(lo), upper = floor(hi)
                guard lower <= upper, sum.isFinite, weight.isFinite, weight > 0 else { continue }
                let target = min(upper, max(lower, (sum / weight).rounded()))
                var tried = Set<CGFloat>()
                for fraction: CGFloat in [1, 0.75, 0.5, 0.25] {
                    if Task<Never, Never>.isCancelled { return incumbent }
                    let next = (old + fraction * (target - old)).rounded()
                    guard next != old, next >= lower, next <= upper, tried.insert(next).inserted else { continue }
                    let delta = vertical ? CGPoint(x: 0, y: next - old) : CGPoint(x: next - old, y: 0)
                    var proposed = current.fills, beforeCost = CGFloat(0), afterCost = CGFloat(0), valid = true
                    for i in members {
                        let before = abs(old - ideals[i]!), after = abs(next - ideals[i]!), font = incumbent.fills[i].fontOutputPixels
                        if after > before + 1e-7 { valid = false }
                        beforeCost += pow(before / font, 2); afterCost += pow(after / font, 2)
                        proposed[i].frame = incumbent.fills[i].frame.offsetBy(dx: delta.x, dy: delta.y)
                    }
                    guard valid, afterCost < beforeCost - 1e-9 else { continue }
                    let supports = try proposed.map { try N.retainedFootprint($0) }
                    guard peerGutterSafety(fills: incumbent.fills, before: original, after: supports,
                        movedOwners: Set(cohort)).allowed else { continue }
                    var evidence: [Int: [String: Any]] = [:], sourceIdentity: String?
                    for i in members {
                        let checked = boundaryGate(original[i], supports[i])
                        guard checked.allowed == true, let source = boundaryEvidence(checked.audit, pixels: supports[i].pixels),
                              sourceIdentity == nil || sourceIdentity == source else { valid = false; break }
                        sourceIdentity = source; evidence[i] = checked.audit
                        if let risk = N.retainedSourceRiskGate, risk.evaluate(original[i], supports[i]) != true { valid = false; break }
                    }
                    guard valid else { continue }
                    do {
                        var retained = anchors; retained[group] = next
                        let fixed = Dictionary(uniqueKeysWithValues: owners.indices.map { (owners[$0], supports[$0].bounds.origin) })
                        var admitted = try N.place(proposed, page: page, fixedOrigins: fixed, retainedClusterAnchors: retained)
                        guard admitted.fills.count == owners.count, admitted.audit.count == owners.count else { continue }
                        admitted.audit = try State.preservingKnownSnapshots(priorAudit: current.audit, admittedAudit: admitted.audit,
                            unknownPolicy: .reject)
                        let actual = try admitted.fills.map { try N.retainedFootprint($0) }
                        try check(peerGutterSafety(fills: incumbent.fills, before: original, after: actual,
                            movedOwners: Set(cohort)).allowed)
                        for i in owners.indices {
                            let shift = members.contains(i) ? delta : CGPoint.zero
                            let oldFill = members.contains(i) ? incumbent.fills[i] : current.fills[i]
                            try check(NativeBodySourceAnchorRecovery.carrierPreserved(oldFill, admitted.fills[i], shift: shift))
                            try check(try binding(admitted.fills[i]) == bindings[i])
                            try check(same(actual[i], supports[i]))
                            try check(try state(admitted.audit[i], fill: admitted.fills[i]) == snapshots[owners[i]]!)
                            var merged = current.audit[i].merging(admitted.audit[i]) { _, fresh in fresh }
                            if current.audit[i]["retainedSourceClusterAnchorApplied"] as? Bool != true && !members.contains(i) {
                                merged.removeValue(forKey: "retainedSourceClusterAnchorApplied")
                            }
                            admitted.audit[i] = merged
                        }
                        try N.verifyRetainedPlacement(admitted.fills, footprints: actual, page: page, retainedClusterAnchors: retained)
                        for i in members {
                            let snapshot = snapshots[owners[i]]!
                            admitted.audit[i][auditKey] = ["version": version, "groupID": group, "owners": cohort,
                                "axis": packet.axis.rawValue, "oldAnchor": Double(old), "newAnchor": Double(next),
                                "beforeFrame": rectArray(incumbent.fills[i].frame), "afterFrame": rectArray(admitted.fills[i].frame),
                                "beforeBounds": rectArray(original[i].bounds), "afterBounds": rectArray(actual[i].bounds),
                                "carrierSHA256": bindings[i], "stateSHA256": digest(try JSONSerialization.data(withJSONObject: State.encode(snapshot), options: .sortedKeys)),
                                "sourceBoundary": evidence[i]!, "physicalContainmentMeasured": false,
                                "fixedRasterOnly": true, "fraction": Double(fraction)] as [String: Any]
                            if let oldEdge = admitted.audit[i].removeValue(forKey: "retainedPageEdgeRecovery") {
                                admitted.audit[i]["preCohortCenterPageEdgeRecovery"] = oldEdge
                            }
                        }
                        _ = try verifiedRetainedAnchors(admitted.fills, footprints: actual, audit: admitted.audit, page: page)
                        current = admitted; anchors = retained; break
                    } catch {
                        if error is CancellationError { return incumbent }
                        continue
                    }
                }
            }
            return current
        } catch { return incumbent }
    }
}
