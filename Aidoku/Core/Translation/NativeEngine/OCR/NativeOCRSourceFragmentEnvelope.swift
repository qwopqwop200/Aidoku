import Foundation

/// Source-owned geometry proposals only. This helper never recognizes, filters,
/// consumes, merges or mutates input packets. Explicit replay is required: these
/// geometric checks do not establish that aligned fragments form one text unit.
/// No image/GT lookup, recognized text, model state or platform graphics API.
enum NativeOCRSourceFragmentEnvelope {
    struct Point: Codable, Equatable, Sendable {
        let x: Double
        let y: Double
    }

    struct ComponentID: Codable, Hashable, Sendable {
        let gridID: String
        let ownerID: String
        let seed: Int
    }

    enum Ownership: String, Codable, Sendable { case exclusive, ambiguous }

    /// Hull of actual source-scaled detector cells or producer-owned stroke
    /// points, not the detector rectangle filled in as synthetic support.
    struct Component: Codable, Equatable, Sendable {
        let id: ComponentID
        let ownership: Ownership
        let hull: [Point]
    }

    struct Member: Codable, Equatable, Sendable {
        let sourceIndex: Int
        let sourceParent: Int
        let frameToken: String
        /// Original immutable packet IDs, including all members of a group.
        let lineage: [Int]
        let polygon: [Point]
        let completeSeedScan: Bool
        let components: [Component]
    }

    enum ScopeKind: String, Codable, Sendable {
        case text, soundEffect
        /// Requires a producer-certified convex mask interior, NEVER RF bbox.
        case certifiedBalloonInterior
    }

    struct Scope: Codable, Equatable, Sendable {
        let queryID: Int
        let frameToken: String
        let kind: ScopeKind
        let confidence: Double
        let polygon: [Point]
    }

    /// Supply all immutable foreign detections, including ambiguous/unread ones.
    /// Bounds are conservatively projected: uncertain blockers cause abstention.
    struct Blocker: Codable, Equatable, Sendable {
        let frameToken: String
        let lineage: [Int]
        let polygon: [Point]
    }

    enum Mode: String, Codable, Sendable { case disabled, replayOnly }

    /// Missing RF coverage is observable, not permission to alter production.
    /// The seed-only arm is an explicit diagnostic to expose missed proposals.
    enum ScopePolicy: String, Codable, Sendable { case commonRF, sourceOwnedReplay }

    struct Configuration: Sendable {
        var maximumMembers = 4
        var maximumCandidates = 16
        var maximumGapInNormalWidths = 3.0
        var maximumCenterOffsetInNormalWidths = 0.2
        var maximumPeerWidthRatio = 1.4
        var maximumNormalGrowthRatio = 0.4
        var minimumAxisAgreement = 0.9902680687415704 // cos(8 degrees)
        var maximumAlongOverlapFraction = 0.1
    }

    struct Candidate: Codable, Equatable, Sendable {
        let anchorSourceIndex: Int
        let anchorSourceParent: Int
        let memberSourceIndices: [Int]
        let memberSourceParents: [Int]
        let lineage: [Int]
        let componentIDs: [ComponentID]
        let scopeQueryIDs: [Int]
        let scopePolicy: ScopePolicy
        let commonRFConfirmed: Bool
        let scopeEvidence: [Scope]
        let polygon: [Point]
        /// Exact helper inputs retained; caller must retain native packet/seed tables.
        let members: [Member]
        let replayOnly: Bool
    }

    struct Result: Codable, Equatable, Sendable {
        let candidates: [Candidate]
        let reasons: [String]
        let mode: Mode
    }

    private struct Rect {
        let left: Double
        let top: Double
        let right: Double
        let bottom: Double
        var width: Double { right - left }
        var height: Double { bottom - top }
        var center: Double { (left + right) / 2 }
        var corners: [Point] {
            [.init(x: left, y: top), .init(x: right, y: top),
             .init(x: right, y: bottom), .init(x: left, y: bottom)]
        }
    }

    private struct Basis {
        let origin: Point
        let along: Point
        var normal: Point { .init(x: along.y, y: -along.x) }
        func project(_ p: Point) -> Point {
            let dx = p.x - origin.x, dy = p.y - origin.y
            return .init(x: dx * normal.x + dy * normal.y, y: dx * along.x + dy * along.y)
        }
        func restore(_ p: Point) -> Point {
            .init(x: origin.x + normal.x * p.x + along.x * p.y,
                  y: origin.y + normal.y * p.x + along.y * p.y)
        }
    }

    /// All coordinates are source pixels in one source frame. Disabled by
    /// default; no candidate has authority to replace an existing emission.
    static func propose(anchorSourceIndex: Int, members: [Member], scopes: [Scope],
                        blockers: [Blocker], frameWidth: Double, frameHeight: Double,
                        frameToken: String, mode: Mode = .disabled,
                        scopePolicy: ScopePolicy = .commonRF,
                        configuration: Configuration = .init()) -> Result {
        func stop(_ reason: String) -> Result { .init(candidates: [], reasons: [reason], mode: mode) }
        guard mode == .replayOnly else { return stop("disabled") }
        let config = configuration
        guard config.maximumMembers >= 1, config.maximumMembers <= 4,
              config.maximumCandidates >= 1, config.maximumCandidates <= 32,
              config.maximumGapInNormalWidths.isFinite, (0...6).contains(config.maximumGapInNormalWidths),
              config.maximumCenterOffsetInNormalWidths.isFinite,
              (0...0.5).contains(config.maximumCenterOffsetInNormalWidths),
              config.maximumPeerWidthRatio.isFinite, (1...2).contains(config.maximumPeerWidthRatio),
              config.maximumNormalGrowthRatio.isFinite, (0...0.75).contains(config.maximumNormalGrowthRatio),
              config.minimumAxisAgreement.isFinite, (0.95...1).contains(config.minimumAxisAgreement),
              config.maximumAlongOverlapFraction.isFinite,
              (0...0.25).contains(config.maximumAlongOverlapFraction) else { return stop("invalid-configuration") }
        guard frameWidth.isFinite, frameHeight.isFinite, frameWidth > 0, frameHeight > 0,
              frameWidth <= 131072, frameHeight <= 131072, !frameToken.isEmpty, frameToken.utf8.count <= 256,
              !members.isEmpty, members.count <= 128, scopes.count <= 128, blockers.count <= 512 else {
            return stop("invalid-frame-or-budget")
        }
        func validPolygon(_ points: [Point]) -> Bool {
            points.count >= 3 && points.count <= 64 && isConvex(points) && points.allSatisfy {
                $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.y >= 0 &&
                    $0.x <= frameWidth && $0.y <= frameHeight
            }
        }
        func validLineage(_ ids: [Int]) -> Bool {
            !ids.isEmpty && ids.count <= 64 && ids.allSatisfy { $0 >= 0 } && Set(ids).count == ids.count
        }
        var indices = Set<Int>(), allIDs: [ComponentID: Component] = [:]
        var cells: [String: String] = [:]
        var totalPoints = 0
        for member in members {
            guard member.sourceIndex >= 0, member.sourceParent >= 0, indices.insert(member.sourceIndex).inserted,
                  member.frameToken == frameToken, validLineage(member.lineage), member.polygon.count == 4,
                  validPolygon(member.polygon), member.components.count <= 256 else { return stop("invalid-member") }
            for component in member.components {
                let id = component.id
                guard id.seed >= 0, !id.gridID.isEmpty, id.gridID.utf8.count <= 160,
                      !id.ownerID.isEmpty, id.ownerID.utf8.count <= 160, validPolygon(component.hull) else {
                    return stop("invalid-component")
                }
                totalPoints += component.hull.count
                guard totalPoints <= 8192 else { return stop("component-budget") }
                if let previous = allIDs[id], previous != component { return stop("contradictory-component") }
                allIDs[id] = component
                // A definite grid seed claimed by two distinct owners is not a
                // source-owned detached component, even if both hulls align.
                if component.ownership == .exclusive {
                    let cell = "\(id.gridID.utf8.count):\(id.gridID):\(id.seed)"
                    if let owner = cells[cell], owner != id.ownerID { return stop("conflicting-seed-owners") }
                    cells[cell] = id.ownerID
                }
            }
        }
        for blocker in blockers {
            guard blocker.frameToken == frameToken, validLineage(blocker.lineage), validPolygon(blocker.polygon) else { return stop("invalid-blocker") }
        }
        var scopeKeys = Set<String>(), queryPolygons: [Int: [Point]] = [:]
        for scope in scopes {
            guard scope.queryID >= 0, scopeKeys.insert("\(scope.queryID):\(scope.kind.rawValue)").inserted,
                  scope.frameToken == frameToken,
                  scope.confidence.isFinite, (0...1).contains(scope.confidence), validPolygon(scope.polygon) else {
                return stop("invalid-scope")
            }
            if let prior = queryPolygons[scope.queryID], prior != scope.polygon {
                return stop("contradictory-scope-query")
            }
            queryPolygons[scope.queryID] = scope.polygon
        }
        guard let anchor = members.first(where: { $0.sourceIndex == anchorSourceIndex }),
              let basis = makeBasis(anchor.polygon) else { return stop("missing-anchor-or-axis") }
        let anchorRect = bounds(anchor.polygon.map(basis.project)), width = anchorRect.width
        guard width > 0, anchorRect.height >= width * 1.5 else { return stop("anchor-not-column") }
        func supported(_ member: Member) -> Bool {
            member.completeSeedScan && !member.components.isEmpty &&
                member.components.allSatisfy { $0.ownership == .exclusive } &&
                Set(member.components.map(\.id)).count == member.components.count
        }
        guard supported(anchor), anchor.components.contains(where: { component in
            intersects(bounds(component.hull.map(basis.project)), anchorRect)
        }) else { return stop("anchor-ownership-unresolved") }
        let ordered = members.sorted { $0.sourceIndex < $1.sourceIndex }
        let eligibleScopes = scopes.filter { scope in
            let threshold: Double
            switch scope.kind {
            case .text: threshold = 0.5
            case .soundEffect: threshold = 0.6
            case .certifiedBalloonInterior: threshold = 0.9
            }
            return scope.confidence >= threshold
        }
        var reasons = Set<String>(), candidates: [Candidate] = [], visited = Set<[Int]>()
        var frontier = [[anchor]], processed = 0
        while !frontier.isEmpty && processed < 128 && candidates.count < config.maximumCandidates {
            let group = frontier.removeFirst()
            let key = group.map(\.sourceIndex).sorted()
            guard visited.insert(key).inserted else { continue }
            processed += 1
            let selectedLineage = Set(group.flatMap(\.lineage))
            let components = group.flatMap(\.components)
            let supportRects = components.map { bounds($0.hull.map(basis.project)) }
            let extent = bounds((group.flatMap(\.polygon) + components.flatMap(\.hull)).map(basis.project))
            let normalOK = supportRects.allSatisfy { rect in
                rect.width <= width * config.maximumPeerWidthRatio &&
                    abs(rect.center - anchorRect.center) <= width * config.maximumCenterOffsetInNormalWidths
            } && extent.width <= width * (1 + config.maximumNormalGrowthRatio)
            let chainRects = ([anchorRect] + supportRects).sorted { $0.top < $1.top }
            var end = chainRects[0].bottom, gapOK = true
            for rect in chainRects.dropFirst() {
                if rect.top - end > width * config.maximumGapInNormalWidths { gapOK = false }
                end = max(end, rect.bottom)
            }
            let polygon = extent.corners.map(basis.restore)
            let scopeEvidence = eligibleScopes.filter { scope in polygon.allSatisfy { contains(scope.polygon, $0) } }
                .sorted { $0.queryID == $1.queryID ? $0.kind.rawValue < $1.kind.rawValue : $0.queryID < $1.queryID }
            let scopeIDs = Set(scopeEvidence.map(\.queryID)).sorted()
            // Derived geometry must also remain inside the source frame. A
            // rotated enclosing rectangle can protrude beyond valid input hulls.
            let insideFrame = validPolygon(polygon)
            let foreign = blockers + members.filter { !Set($0.lineage).isSubset(of: selectedLineage) }
                .map { Blocker(frameToken: frameToken, lineage: $0.lineage, polygon: $0.polygon) }
            let additions = difference(extent, anchorRect)
            let blocked = foreign.contains { blocker in
                guard !Set(blocker.lineage).isSubset(of: selectedLineage) else { return false }
                let rect = bounds(blocker.polygon.map(basis.project))
                return additions.contains { intersects($0, rect) }
            }
            let extendsAlong = extent.top < anchorRect.top - 1e-6 || extent.bottom > anchorRect.bottom + 1e-6
            let scopeOK = !scopeIDs.isEmpty || scopePolicy == .sourceOwnedReplay
            if normalOK && gapOK && scopeOK && !blocked && insideFrame && extendsAlong {
                let sorted = group.sorted { $0.sourceIndex < $1.sourceIndex }
                let ids = Set(components.map(\.id)).sorted { a, b in
                    if a.gridID != b.gridID { return a.gridID < b.gridID }
                    if a.ownerID != b.ownerID { return a.ownerID < b.ownerID }
                    return a.seed < b.seed
                }
                candidates.append(.init(anchorSourceIndex: anchor.sourceIndex, anchorSourceParent: anchor.sourceParent,
                    memberSourceIndices: sorted.map(\.sourceIndex), memberSourceParents: sorted.map(\.sourceParent),
                    lineage: selectedLineage.sorted(), componentIDs: ids, scopeQueryIDs: scopeIDs,
                    scopePolicy: scopePolicy, commonRFConfirmed: !scopeIDs.isEmpty, scopeEvidence: scopeEvidence, polygon: polygon, members: sorted, replayOnly: true))
            } else {
                if !normalOK { reasons.insert("normal-axis-incompatible") }
                if !gapOK { reasons.insert("detached-gap-too-large") }
                if scopeIDs.isEmpty { reasons.insert("no-common-rf-scope") }
                if blocked { reasons.insert("foreign-owner-in-added-area") }
                if !insideFrame { reasons.insert("envelope-outside-frame") }
                if !extendsAlong { reasons.insert("no-along-completeness-gain") }
            }
            guard group.count < config.maximumMembers, normalOK, insideFrame,
                  frontier.count < 128 else { continue }
            // Missing intermediate roots may repair a large gap. Scope/blocker
            // checks therefore apply to complete proposals, not partial states.
            let groupExtent = bounds(group.flatMap(\.polygon).map(basis.project))
            for peer in ordered where !key.contains(peer.sourceIndex) {
                guard supported(peer) else {
                    reasons.insert("peer-\(peer.sourceIndex)-ownership-unresolved")
                    continue
                }
                guard Set(peer.lineage).isDisjoint(with: selectedLineage),
                      Set(peer.components.map(\.id)).isDisjoint(with: Set(components.map(\.id))) else {
                    reasons.insert("peer-\(peer.sourceIndex)-overlapping-lineage-or-components")
                    continue
                }
                let rect = bounds(peer.polygon.map(basis.project))
                guard rect.width <= width * config.maximumPeerWidthRatio,
                      abs(rect.center - anchorRect.center) <= width * config.maximumCenterOffsetInNormalWidths,
                      min(rect.right, anchorRect.right) - max(rect.left, anchorRect.left) >= min(rect.width, width) * 0.6,
                      let peerBasis = makeBasis(peer.polygon) else {
                    reasons.insert("peer-\(peer.sourceIndex)-normal-axis-incompatible")
                    continue
                }
                if rect.height >= rect.width * 1.5 {
                    let dot = abs(peerBasis.along.x * basis.along.x + peerBasis.along.y * basis.along.y)
                    guard dot >= config.minimumAxisAgreement else {
                        reasons.insert("peer-\(peer.sourceIndex)-axis-angle-incompatible")
                        continue
                    }
                }
                let overlap = max(0, min(rect.bottom, groupExtent.bottom) - max(rect.top, groupExtent.top))
                guard overlap <= min(rect.height, groupExtent.height) * config.maximumAlongOverlapFraction else {
                    reasons.insert("peer-\(peer.sourceIndex)-parallel-overlap")
                    continue
                }
                // Avoid unbounded combinatorics even with many aligned sources.
                if frontier.count < 128 { frontier.append(group + [peer]) }
            }
        }
        if !frontier.isEmpty { reasons.insert("search-budget-reached") }
        return .init(candidates: candidates, reasons: reasons.sorted(), mode: mode)
    }

    private static func makeBasis(_ polygon: [Point]) -> Basis? {
        guard polygon.count == 4 else { return nil }
        let edges = (0..<4).map { i -> Point in
            let next = polygon[(i + 1) % 4]
            return .init(x: next.x - polygon[i].x, y: next.y - polygon[i].y)
        }
        guard let edge = edges.max(by: { hypot($0.x, $0.y) < hypot($1.x, $1.y) }) else { return nil }
        let length = hypot(edge.x, edge.y)
        guard length.isFinite, length > 1e-9 else { return nil }
        let sign = edge.y > 1e-9 || (abs(edge.y) <= 1e-9 && edge.x >= 0) ? 1.0 : -1.0
        return .init(origin: polygon[0], along: .init(x: sign * edge.x / length, y: sign * edge.y / length))
    }

    private static func bounds(_ points: [Point]) -> Rect {
        .init(left: points.map(\.x).min()!, top: points.map(\.y).min()!,
              right: points.map(\.x).max()!, bottom: points.map(\.y).max()!)
    }

    private static func intersects(_ a: Rect, _ b: Rect) -> Bool {
        min(a.right, b.right) - max(a.left, b.left) > 1e-6 &&
            min(a.bottom, b.bottom) - max(a.top, b.top) > 1e-6
    }

    private static func difference(_ outer: Rect, _ inner: Rect) -> [Rect] {
        [Rect(left: outer.left, top: outer.top, right: outer.right, bottom: inner.top),
         Rect(left: outer.left, top: inner.bottom, right: outer.right, bottom: outer.bottom),
         Rect(left: outer.left, top: inner.top, right: inner.left, bottom: inner.bottom),
         Rect(left: inner.right, top: inner.top, right: outer.right, bottom: inner.bottom)]
            .filter { $0.width > 1e-6 && $0.height > 1e-6 }
    }

    private static func cross(_ a: Point, _ b: Point, _ p: Point) -> Double {
        (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
    }

    private static func isConvex(_ polygon: [Point]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var sign = 0.0
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            let value = cross(a, b, polygon[(i + 2) % polygon.count])
            guard value.isFinite else { return false }
            if abs(value) > 1e-9 {
                if sign != 0 && value * sign < 0 { return false }
                sign = value
            }
        }
        guard sign != 0 else { return false }
        // Checking every vertex against every edge rejects star/self-crossing
        // point orders as well as local-turn-only false positives.
        return polygon.indices.allSatisfy { i in
            polygon.allSatisfy { cross(polygon[i], polygon[(i + 1) % polygon.count], $0) * sign >= -1e-7 }
        }
    }

    private static func contains(_ polygon: [Point], _ point: Point) -> Bool {
        let values = polygon.indices.map { cross(polygon[$0], polygon[($0 + 1) % polygon.count], point) }
        return values.allSatisfy { $0 >= -1e-7 } || values.allSatisfy { $0 <= 1e-7 }
    }
}
