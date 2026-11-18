import CoreGraphics
import Foundation

/// Source-leading relationships for stacked horizontal single source rows.
/// This is a placement convention, not font-fit membership, paragraph merging,
/// or a physical certificate that an unsegmented surface is outside a balloon.
enum NativeHorizontalSourceLeading {
    static let identity = "horizontal-source-leading-effect-anchor-v1"
    private static let prefix = "native-horizontal-leading-v1-"

    struct Result {
        let items: [[String: Any]]
        let groups: [[String: Any]]
    }

    private struct Row {
        let index: Int
        let id: String
        let source: CGRect
        let em: CGFloat
        let role: String
    }

    /// sourceFontSize and member polygons are ORIGINAL source pixels; all
    /// relationship distances below are in the supplied viewport plane.
    static func annotate(_ items: [[String: Any]], viewport: CGSize, sourcePixelSize: CGSize) -> Result {
        guard items.count <= 256, viewport.width.isFinite, viewport.height.isFinite,
              viewport.width > 0, viewport.height > 0,
              sourcePixelSize.width.isFinite, sourcePixelSize.height.isFinite,
              sourcePixelSize.width > 0, sourcePixelSize.height > 0 else { return .init(items: items, groups: []) }
        let sourceToViewport = viewport.width / sourcePixelSize.width
        guard abs(sourceToViewport - viewport.height / sourcePixelSize.height) <= 1e-9 * max(1, sourceToViewport) else {
            return .init(items: items, groups: [])
        }
        // Re-evaluate our own evidence after a contour refresh. A newly found
        // body must revoke an earlier exterior grouping, not inherit it.
        var items = items
        for i in items.indices where items[i]["sourceHorizontalLeadingAuthority"] as? String == identity {
            if let packet = items[i]["sourceClusterAlignment"] as? [String: Any],
               (packet["groupID"] as? String)?.hasPrefix(prefix) == true {
                items[i].removeValue(forKey: "sourceClusterAlignment")
            }
            if var guide = items[i]["textPlacementGuide"] as? [String: Any],
               let original = items[i]["sourceHorizontalLeadingOriginalHorizontal"] as? String {
                guide["horizontal"] = original; items[i]["textPlacementGuide"] = guide
            }
            items[i].removeValue(forKey: "sourceHorizontalLeadingAuthority")
            items[i].removeValue(forKey: "sourceHorizontalLeadingOriginalHorizontal")
        }
        let ids = items.compactMap { $0["id"] as? String }
        let counts = ids.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        func absent(_ raw: [String: Any], _ key: String) -> Bool {
            raw[key] == nil || raw[key] is NSNull
        }
        let rows: [Row] = items.enumerated().compactMap { index, raw in
            // Missing body identity alone is never exterior evidence. Require
            // the native producer's measured local expansion policy as well.
            guard let id = raw["id"] as? String, !id.isEmpty, counts[id] == 1,
                  raw["sourceVertical"] as? Bool == false,
                  raw["vertical"] as? Bool != true,
                  raw["keptLettering"] as? Bool != true, raw["sourceTextOnly"] as? Bool != true,
                  absent(raw, "sourceClusterAlignment"), absent(raw, "balloonPlacement"),
                  absent(raw, "balloonInterior"), absent(raw, "balloonUnit"),
                  absent(raw, "balloonLayoutRectNormalized"),
                  raw["renderExpansionBoundaryAuthority"] as? String == "local-source-window",
                  let policy = raw["textExpansionPolicy"] as? [String: Any],
                  policy["kind"] as? String == "source-near-limited-expansion",
                  absent(policy, "maskRectNormalized"), absent(policy, "maskSpansNormalized"),
                  let risks = policy["backgroundRisk"] as? [Double],
                  let candidates = policy["candidates"] as? [[Double]], risks.count == candidates.count,
                  let b = raw["sourceBounds"] as? [Double], b.count == 4,
                  b.allSatisfy(\.isFinite), b[0] >= 0, b[1] >= 0, b[2] > 0, b[3] > 0,
                  b[0] + b[2] <= 1.000000001, b[1] + b[3] <= 1.000000001,
                  let sourceEm = (raw["sourceFontSize"] as? NSNumber)?.doubleValue, sourceEm.isFinite, sourceEm > 0,
                  abs((raw["rotation"] as? NSNumber)?.doubleValue ?? 0) < 0.001,
                  let members = raw["sourceMemberPolygons"] as? [[[Double]]], members.count == 1,
                  (3...256).contains(members[0].count),
                  members[0].allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }),
                  let guide = raw["textPlacementGuide"] as? [String: Any],
                  guide["vertical"] as? String == "center",
                  absent(guide, "sourceRotationRadians"), absent(guide, "rotationAnchorNormalized") else { return nil }
            let role = (raw["role"] as? String ?? raw["semanticRole"] as? String ?? "").lowercased()
            // Explicit dialogue, titles, labels and SFX retain their own policy.
            // Unknown is allowed only with the complete geometric row witness.
            guard ["", "narration", "story_text", "caption"].contains(role) else { return nil }
            let source = CGRect(x: b[0] * viewport.width, y: b[1] * viewport.height,
                                width: b[2] * viewport.width, height: b[3] * viewport.height)
            let em = CGFloat(sourceEm) * sourceToViewport
            let xs = members[0].map { $0[0] }, ys = members[0].map { $0[1] }
            guard let x = xs.min(), let X = xs.max(), let y = ys.min(), let Y = ys.max(),
                  X - x >= 2 * (Y - y), Y > y,
                  source.width >= 2 * source.height, source.height <= 2 * em,
                  candidates.indices.contains(where: { i in
                      let c = candidates[i]
                      return c.count == 4 && c.allSatisfy(\.isFinite) && risks[i].isFinite &&
                          risks[i] <= 0.12 && c[2] > 0 && c[3] > 0 &&
                          c[2] * c[3] > b[2] * b[3]
                  }) else { return nil }
            return Row(index: index, id: id, source: source, em: em, role: role)
        }
        func compatible(_ a: Row, _ b: Row) -> Bool {
            let gap = max(a.source.minY, b.source.minY) - min(a.source.maxY, b.source.maxY)
            // Existing source-alignment tolerances: .5em leading edge,
            // 1.3 font ratio and 3em cross-paragraph proximity. No learned fit.
            return a.role == b.role && max(a.em, b.em) <= 1.3 * min(a.em, b.em) &&
                abs(a.source.minX - b.source.minX) <= max(2, 0.5 * min(a.em, b.em)) &&
                gap >= 0 && gap <= 3 * max(a.em, b.em)
        }
        var clusters: [[Row]] = []
        let ordered = rows.sorted {
            if $0.source.minY != $1.source.minY { return $0.source.minY < $1.source.minY }
            if $0.source.minX != $1.source.minX { return $0.source.minX < $1.source.minX }
            return $0.id < $1.id
        }
        for row in ordered {
            if let group = clusters.firstIndex(where: { $0.allSatisfy { compatible($0, row) } }) {
                clusters[group].append(row)
            } else { clusters.append([row]) }
        }
        var output = items, reports: [[String: Any]] = [], ordinal = 0
        let reserved = Set(items.compactMap { ($0["sourceClusterAlignment"] as? [String: Any])?["groupID"] as? String })
        for members in clusters where members.count > 1 {
            let centers = members.map { $0.source.midX }, starts = members.map { $0.source.minX }
            let centerSpread = centers.max()! - centers.min()!, startSpread = starts.max()! - starts.min()!
            // Equal-centred titles and ambiguous equal-width rows abstain.
            guard centerSpread > members.map(\.em).min()!, centerSpread > 2 * startSpread else { continue }
            let sorted = starts.sorted(), n = sorted.count
            let anchor = n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
            while reserved.contains(prefix + String(ordinal)) { ordinal += 1 }
            let groupID = prefix + String(ordinal); ordinal += 1
            let packet: [String: Any] = ["groupID": groupID, "axis": "left",
                "anchorNormalized": Double(anchor / viewport.width),
                "anchorPolicy": "source-near-final-alpha", "anchorsToSourceStart": true]
            for row in members {
                output[row.index]["sourceClusterAlignment"] = packet
                var guide = output[row.index]["textPlacementGuide"] as! [String: Any]
                output[row.index]["sourceHorizontalLeadingOriginalHorizontal"] = guide["horizontal"]
                guide["horizontal"] = "left"
                output[row.index]["textPlacementGuide"] = guide
                output[row.index]["sourceHorizontalLeadingAuthority"] = identity
            }
            reports.append(["groupID": groupID, "owners": members.map(\.id),
                "sourceLeadingViewport": Double(anchor), "sourceCenterSpreadViewport": Double(centerSpread),
                "sourceLeadingSpreadViewport": Double(startSpread), "axis": "left",
                "authority": identity, "physicalOutsideBalloonCertified": false,
                "unchanged": "source/text/paragraph/font/Y/internal-row-alignment; final alpha/domain/peer admission still required"])
        }
        return .init(items: output, groups: reports)
    }
}
