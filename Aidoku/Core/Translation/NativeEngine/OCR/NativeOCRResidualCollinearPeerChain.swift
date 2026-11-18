import CoreGraphics
import Foundation

/// ADD ONLY real-piece unions; original owner inventories never change. Caller owns global safe/semantic gates.
@available(iOS 18.0, *)
enum NativeOCRResidualCollinearPeerChain {
    typealias M = NativeOCRSourceComponentMeasurements.Measurement
    typealias Member = NativeOCRResidualMembership
    struct Piece { let m: M; let cells: Set<Member.Cell>; let rect: CGRect; let support: [CGPoint] }

    /// Each supplied entry must include that child's actual guard/visible ink/originalGuard/caps/fresh terminals.
    /// Missing child support abstains. There is no inferred empty-cap fallback.
    static func candidates(_ m: M, context: NativeOCRResidualSourceContext,
                           protectedSupport: [Int: [CGPoint]]) -> [NativeOCRResidualCandidate] {
        guard m.status == "measured", m.rect.width >= 5, m.rect.height >= m.rect.width * 3,
              let layout = context.layout, let ownCaps = protectedSupport[m.index],
              let own = Member.observedSupport(m, context: context) else { return [] }
        let width = m.rect.width
        let originalPairs = Member.candidates(m, context: context).filter { !$0.consumedIndices.isEmpty }
        var measured: [Int: Piece] = [m.index: .init(m: m, cells: own.cells, rect: m.rect,
            support: Member.protectedInk(m) + ownCaps)]
        func piece(_ region: NativeOCRResidualSourceContext.Region) -> Piece? {
            if let p = measured[region.index] { return p }
            guard let caps = protectedSupport[region.index],
                  let peer = context.measure(region.index, region.polygon), peer.status == "measured",
                  let support = Member.observedSupport(peer, context: context) else { return nil }
            let value = Piece(m: peer, cells: support.cells, rect: Member.bounds(peer.polygon.map(m.project)),
                              support: Member.protectedInk(peer) + caps)
            measured[region.index] = value
            return value
        }
        var frontier = [[m.index]], seen = Set<[Int]>([[m.index]]), result: [NativeOCRResidualCandidate] = []
        var resultKeys = Set<String>()
        // At most4 distinct pieces,16 frontier states/level. No transitive palette-only nomination.
        for count in 2...4 {
            var next: [[Int]] = []
            for chain in frontier {
                let parts = chain.compactMap { measured[$0] }
                let extent = Member.bounds(parts.flatMap { $0.m.polygon }.map(m.project))
                let peers = context.regions.filter { !chain.contains($0.index) && $0.polygon.count == 4 }.compactMap { region -> (NativeOCRResidualSourceContext.Region, CGFloat, Bool)? in
                    let r = Member.bounds(region.polygon.map(m.project))
                    guard r.width >= width * 0.65, r.width <= width * 1.4,
                          abs(r.midX - m.rect.midX) <= width * 0.22, r.height >= width * 0.45,
                          Member.axisAgreement(region.polygon, along: m.along) else { return nil }
                    let head = r.midY < extent.midY
                    let gap = head ? extent.minY - r.maxY : r.minY - extent.maxY
                    guard gap >= 0, gap <= width * 1.6 else { return nil }
                    return (region, gap, head)
                }.sorted { $0.1 == $1.1 ? $0.0.index < $1.0.index : $0.1 < $1.1 }
                for (region, _, head) in peers {
                    guard let peer = piece(region), parts.allSatisfy({ $0.cells.isDisjoint(with: peer.cells) }) else { continue }
                    let end = parts.min { head ? $0.rect.minY < $1.rect.minY : $0.rect.maxY > $1.rect.maxY }!
                    guard Member.compatibleInk(end.m, peer.m),
                          Member.separateGlyphSupport(m, peer.m, before: head) else { continue }
                    let ids = (chain + [region.index]).sorted()
                    guard seen.insert(ids).inserted else { continue }
                    let all = parts + [peer], supports = all.flatMap(\.support)
                    let rect = Member.bounds((all.flatMap { $0.m.polygon } + supports).map(m.project)).insetBy(dx: -0.5, dy: -0.5)
                    let polygon = Member.quad(rect).map(m.restore)
                    guard Member.valid(polygon), supports.allSatisfy({ Member.contains(polygon, $0) }),
                          sharedScope(polygon, inputs: all.map { $0.m.polygon }, layout: layout),
                          Member.corridorClear(polygon, inputs: all.map { $0.m.polygon }, context: context) else { continue }
                    // Any unselected real source entering the newly bridged band remains a keepout,
                    // including ambiguous sources lacking definitive private inventory.
                    let ordered = all.sorted { $0.rect.minY < $1.rect.minY }
                    let gaps = zip(ordered, ordered.dropFirst()).map { ($0.0.rect.maxY, $0.1.rect.minY) }
                    let blocked = context.regions.contains { other in
                        guard !ids.contains(other.index), other.polygon.count == 4 else { return false }
                        let r = Member.bounds(other.polygon.map(m.project))
                        let cross = min(r.maxX, m.rect.maxX) - max(r.minX, m.rect.minX)
                        guard cross >= min(r.width, width) * 0.4,
                              gaps.contains(where: { r.minY < $0.1 && r.maxY > $0.0 }) else { return false }
                        guard let otherM = context.measure(other.index, other.polygon), otherM.status == "measured" else { return true }
                        return otherM.components.contains { component in
                            guard component.ownedPixels >= 2 || component.foreignPixels >= 2 else { return false }
                            let ink = Member.bounds(component.hull.map(otherM.restore).map(m.project))
                            return ink.maxX > m.rect.minX && ink.minX < m.rect.maxX &&
                                gaps.contains(where: { ink.minY < $0.1 && ink.maxY > $0.0 })
                        }
                    }
                    guard !blocked else { continue }
                    if next.count < 16 { next.append(ids) }
                    let children = ids.filter { $0 != m.index }
                    // Do not duplicate the existing2-piece Membership menu (including nested absorptions).
                    if count == 2 && originalPairs.contains(where: { Set($0.consumedIndices) == Set(children) }) { continue }
                    let headPresent = all.contains { $0.rect.minY < m.rect.minY - 0.5 }
                    let tailPresent = all.contains { $0.rect.maxY > m.rect.maxY + 0.5 }
                    let direction = headPresent && tailPresent ? "both" : headPresent ? "head" : "tail"
                    let key = "peer-chain-v1-p\(count)-\(direction)-rf050-sfx060-balloon090-gap1p6-offset0p22"
                    if resultKeys.insert(key).inserted {
                        result.append(.init(key: key, polygon: polygon, consumedIndices: children,
                                            supportPoints: NativeOCRSourceComponentMeasurements.convexHull(supports)))
                    }
                }
            }
            frontier = next
            if frontier.isEmpty { break }
        }
        return result
    }

    static func sharedScope(_ polygon: [CGPoint], inputs: [[CGPoint]], layout: NativeRFDETRLayoutResult) -> Bool {
        let union = Member.bounds(polygon)
        guard union.minX >= 0, union.minY >= 0, union.maxX <= CGFloat(layout.sourceWidth), union.maxY <= CGFloat(layout.sourceHeight) else { return false }
        let common = layout.primitives.filter { p in
            let eligible = (p.semanticClass == .text && p.confidence >= 0.5) || (p.semanticClass == .soundEffect && p.confidence >= 0.6)
            return eligible && (inputs + [polygon]).allSatisfy { NativeOCRDirectionAdapters.coverage($0, by: p) >= 0.9 }
        }
        let frames = layout.primitives.filter { $0.semanticClass == .frame && $0.confidence >= 0.9 }
        guard !frames.contains(where: { p in
            let contained = inputs.map { p.sourceBounds.contains(Member.bounds($0)) }
            return contained.contains(true) && contained.contains(false)
        }) else { return false }
        let balloons = layout.primitives.filter { $0.semanticClass == .balloon && $0.confidence >= 0.9 && $0.sourceBounds.intersects(union) }
        guard balloons.count <= 1 else { return false }
        if let balloon = balloons.first {
            guard let mask = balloon.mask, mask.sourceWidth == layout.sourceWidth, mask.sourceHeight == layout.sourceHeight else { return false }
            let left = Int(floor(union.minX)), top = Int(floor(union.minY)), right = Int(ceil(union.maxX)), bottom = Int(ceil(union.maxY))
            guard right > left, bottom > top, right - left <= 120_000 / (bottom - top) else { return false }
            for y in top..<bottom { for x in left..<right where !mask.contains(sourceX: x, sourceY: y) { return false } }
            return common.count <= 1
        }
        return common.count == 1
    }
}
