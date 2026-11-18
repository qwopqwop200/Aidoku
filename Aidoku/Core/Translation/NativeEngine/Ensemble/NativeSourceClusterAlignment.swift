import CoreGraphics
import Foundation

/// A source-inference packet, never a request to merge text or resize glyphs.
/// Coordinates are normalized to the original image, not the reader viewport.
struct NativeSourceClusterAlignment: Codable, Equatable, Sendable {
    enum Axis: String, Codable, Sendable { case top, left }
    let groupID: String
    let axis: Axis
    let anchorNormalized: Double
    var anchorPolicy: String? = nil
    /// A reflowed exterior paragraph retains its source start, not the centre
    /// of the original tall column. Nil keeps the established centring policy.
    var anchorsToSourceStart: Bool? = nil

    enum Failure: Error { case invalidPacket, inconsistentGroup, noPageCapacity }

    var valid: Bool {
        (anchorPolicy == nil || anchorPolicy == "source-near-final-alpha") && !groupID.isEmpty && groupID.count <= 128 && anchorNormalized.isFinite && (0...1).contains(anchorNormalized)
    }

    static func decode(_ value: Any?) throws -> Self? {
        guard let value, !(value is NSNull) else { return nil }
        let packet = try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: value))
        guard packet.valid else { throw Failure.invalidPacket }
        return packet
    }

    /// Resolve the shared anchor once for the complete cohort. Page-edge repair
    /// moves every member's locked axis together; it cannot independently drift.
    static func targets(_ packets: [Self?], bounds: [CGRect], page: CGRect,
                        guides: [NativeTextPlacementGuide?]? = nil, capacities:[NativeTextExpansionPolicy?]?=nil,
                        retainedAnchors:[String:CGFloat]=[:]) throws -> [CGFloat?] {
        guard packets.count == bounds.count, guides == nil || guides!.count == bounds.count,
              capacities == nil || capacities!.count==bounds.count else { throw Failure.invalidPacket }
        var result = [CGFloat?](repeating: nil, count: packets.count)
        var groups: [String: [Int]] = [:]
        for (index, packet) in packets.enumerated() {
            guard let packet else { continue }
            guard packet.valid else { throw Failure.invalidPacket }
            groups[packet.groupID, default: []].append(index)
        }
        for members in groups.values where members.count > 1 {
            let first = packets[members[0]]!
            guard members.allSatisfy({ packets[$0]!.axis == first.axis && packets[$0]!.anchorPolicy == first.anchorPolicy &&
                abs(packets[$0]!.anchorNormalized - first.anchorNormalized) <= 1e-9 }) else {
                throw Failure.inconsistentGroup
            }
            let vertical = first.axis == .top
            let extent = vertical ? page.height : page.width
            let maximum = members.map { vertical ? bounds[$0].height : bounds[$0].width }.max()!
            guard maximum <= extent else { throw Failure.noPageCapacity }
            let lower = vertical ? page.minY : page.minX
            var preferred=lower + CGFloat(first.anchorNormalized)*extent
            if first.anchorPolicy == "source-near-final-alpha", let guides {
                let sourceStart=members.allSatisfy {i in
                    packets[i]?.anchorsToSourceStart == true && capacities?[i]?.insideBalloon == false
                }
                let candidates=members.compactMap { i -> CGFloat? in
                    guard let guide=guides[i],guide.valid else { return nil }
                    let r=guide.rect(in:page)
                    if sourceStart {return vertical ? r.minY:r.minX}
                    return vertical ? r.midY-bounds[i].height/2 : r.midX-bounds[i].width/2
                }.sorted()
                if candidates.count == members.count {
                    let n=candidates.count
                    preferred=n%2 == 1 ? candidates[n/2] : (candidates[n/2-1]+candidates[n/2])/2
                }
            }
            var minAnchor=lower,maxAnchor=lower+floor(extent-maximum)
            if let capacities,capacities.count==packets.count,first.anchorPolicy=="source-near-final-alpha" {
                var lo=minAnchor,hi=maxAnchor
                for i in members {
                    guard let policy=capacities[i] else {continue}
                    let r=NativeTextExpansionPolicy.rect(policy.allowedRectNormalized,page:page)
                    lo=max(lo,vertical ? r.minY:r.minX)
                    hi=min(hi,(vertical ? r.maxY:r.maxX)-(vertical ? bounds[i].height:bounds[i].width))
                }
                if ceil(lo)<=floor(hi) {minAnchor=ceil(lo);maxAnchor=floor(hi)}
            }
            let target:CGFloat
            if let retained=retainedAnchors[first.groupID] {
                guard retained.isFinite,retained>=minAnchor-0.01,retained<=maxAnchor+0.01 else {
                    throw Failure.noPageCapacity
                }
                target=retained
            } else {target=min(maxAnchor,max(minAnchor,preferred.rounded()))}
            for index in members { result[index] = target }
        }
        return result
    }
}
