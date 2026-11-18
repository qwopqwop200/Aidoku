import CoreGraphics
import Foundation

/// A source reread replaces ONE existing display owner, not two invented ones.
/// Offline actual source/provider/table proofs remain mandatory. This runtime
/// check binds the persisted receipt to the CURRENT original and exact owner.
enum NativeCausalPacketColumnRevision {
    static func validates(_ transaction: [String: Any], old: [String: Any], fresh: [String: Any],
                          sourceIdentity: String?, imageSize: CGSize) -> Bool {
        guard transaction["singleOwnerPacketReceiptVerified"] as? Bool == true,
              let receipt = transaction["packetColumnRecognition"] as? [String: Any],
              let plan = receipt["plan"] as? [String: Any],
              let identity = sourceIdentity, identity.hasPrefix("canonical-rgb8:"),
              plan["sourceIdentity"] as? String == identity,
              receipt["grantsNewErasureAuthority"] as? Bool == false,
              receipt["requiresRetranslation"] as? Bool == true,
              let confidence = receipt["confidence"] as? Double, confidence.isFinite, (0.95...1).contains(confidence),
              let source = transaction["correctedSource"] as? String,
              receipt["sourceAfter"] as? String == source,
              let previous = transaction["oldSources"] as? [String], previous.count == 1,
              plan["sourceBefore"] as? String == previous[0], source != previous[0],
              let columns = receipt["columns"] as? [String], (2...4).contains(columns.count),
              columns.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              columns.joined() == source,
              let groups = plan["columnOwnerIDs"] as? [[String]], groups.count == columns.count,
              groups.allSatisfy({ !$0.isEmpty }),
              let owners = plan["ownerIDs"] as? [String],
              Set(groups.flatMap { $0 }) == Set(owners), Set(owners).count == owners.count,
              let bounds = plan["normalizedBounds"] as? [Double], bounds.count == 4,
              let oldBounds = old["sourceBounds"] as? [Double], oldBounds.count == 4,
              let newBounds = fresh["sourceBounds"] as? [Double], newBounds.count == 4,
              zip(bounds, oldBounds).allSatisfy({ $0.isFinite && abs($0 - $1) < 1e-9 }),
              zip(bounds, newBounds).allSatisfy({ $0.isFinite && abs($0 - $1) < 1e-9 }),
              let sourceQuad = quad(plan["sourceQuad"]),
              let crops = plan["crops"] as? [[String: Any]], crops.count == columns.count * 2,
              Set(crops.compactMap { $0["identifier"] as? Int }).count == crops.count,
              imageSize.width > 0, imageSize.height > 0 else { return false }
        let xs = sourceQuad.map(\.x), ys = sourceQuad.map(\.y)
        let scope = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        let envelope = [scope.minX / imageSize.width, scope.minY / imageSize.height,
            scope.width / imageSize.width, scope.height / imageSize.height]
        guard zip(envelope, bounds).allSatisfy({ abs($0 - $1) < 1e-9 }) else { return false }
        var base: [[CGPoint]] = []
        for column in columns.indices {
            let pair = crops.filter { $0["column"] as? Int == column }
            guard pair.count == 2, Set(pair.compactMap { $0["variant"] as? Int }) == Set([0, 1]) else { return false }
            for crop in pair {
                guard let q = quad(crop["originalPixelQuad"]), q.allSatisfy({
                    $0.x >= scope.minX && $0.x <= scope.maxX && $0.y >= scope.minY && $0.y <= scope.maxY
                }) else { return false }
                if crop["variant"] as? Int == 0 { base.append(q) }
            }
        }
        base.reverse()
        guard base.first?[0] == sourceQuad[0], base.first?[3] == sourceQuad[3],
              base.last?[1] == sourceQuad[1], base.last?[2] == sourceQuad[2] else { return false }
        for i in 1..<base.count where base[i - 1][1] != base[i][0] || base[i - 1][2] != base[i][3] { return false }
        return true
    }

    private static func quad(_ value: Any?) -> [CGPoint]? {
        guard let rows = value as? [[String: Double]], rows.count == 4 else { return nil }
        let points = rows.compactMap { row -> CGPoint? in
            guard let x = row["x"], let y = row["y"], x.isFinite, y.isFinite else { return nil }
            return CGPoint(x: x, y: y)
        }
        guard points.count == 4, points[0].x < points[1].x, points[3].x < points[2].x,
              points[0].y < points[3].y, points[1].y < points[2].y else { return nil }
        return points
    }
}
