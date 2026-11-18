import CoreGraphics
import Foundation

/// Intersect the solver's domain with the final gutter polish motion budget.
/// Testing only the unconstrained optimum can discard feasible local repairs.
/// Caller retains the shared cross-axis anchor and performs final alpha,
/// page/mask, source-cost and all-peer admission on the resulting proposal.
enum NativeReadablePeerGutter {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["AIDOKU_RETAINED_PEER_GUTTER_REPLAY"] == "1"
    }

    static func boundedOptions(
        _ options: [NativeSourceCohortPacking.Option],
        origins: [CGFloat],
        pageInterval: ClosedRange<CGFloat>? = nil,
        maximumMotionEm: CGFloat = 0.75
    ) -> [NativeSourceCohortPacking.Option]? {
        guard !options.isEmpty, options.count <= 256, options.count == origins.count,
              maximumMotionEm.isFinite, maximumMotionEm >= 0, maximumMotionEm <= 0.75 else { return nil }
        var result: [NativeSourceCohortPacking.Option] = []
        for (option, origin) in zip(options, origins) {
            guard origin.isFinite, option.unit.isFinite, option.unit > 0,
                  option.extent.isFinite, option.extent > 0,
                  option.lower.isFinite, option.upper.isFinite,
                  option.preferred.isFinite, option.cost.isFinite else { return nil }
            let radius = option.unit * maximumMotionEm
            guard radius.isFinite else { return nil }
            if let pageInterval {
                guard pageInterval.lowerBound.isFinite, pageInterval.upperBound.isFinite else { return nil }
            }
            let lower = max(option.lower, origin - radius, pageInterval?.lowerBound ?? option.lower)
            let upper = min(option.upper, origin + radius, (pageInterval?.upperBound ?? (option.upper + option.extent)) - option.extent)
            guard lower.isFinite, upper.isFinite, ceil(lower) <= floor(upper) else { return nil }
            result.append(.init(index: option.index, extent: option.extent, lower: lower, upper: upper,
                                preferred: option.preferred, unit: option.unit, cost: option.cost))
        }
        return result
    }

    /// Preserve an already admitted common start during fixed-origin replay.
    /// Normal place() still validates the retained anchor against capacity.
    static func retainedAnchors(
        packets: [NativeSourceClusterAlignment?], origins: [CGPoint]
    ) -> [String: CGFloat]? {
        guard packets.count == origins.count, packets.count <= 256 else { return nil }
        var groups: [String: [Int]] = [:]
        for (i, packet) in packets.enumerated() {
            guard origins[i].x.isFinite, origins[i].y.isFinite else { return nil }
            guard let packet else { continue }
            guard packet.valid else { return nil }
            groups[packet.groupID, default: []].append(i)
        }
        var result: [String: CGFloat] = [:]
        for (group, indices) in groups where indices.count > 1 {
            let first = packets[indices[0]]!
            let anchor = first.axis == .top ? origins[indices[0]].y : origins[indices[0]].x
            guard indices.allSatisfy({ i in
                let packet = packets[i]!
                let value = first.axis == .top ? origins[i].y : origins[i].x
                return packet.axis == first.axis && packet.anchorPolicy == first.anchorPolicy &&
                    abs(packet.anchorNormalized - first.anchorNormalized) <= 1e-9 && abs(value - anchor) < 0.01
            }) else { return nil }
            result[group] = anchor
        }
        return result
    }
}
