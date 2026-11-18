import CoreGraphics
import Foundation

/// Original merged-packet rereads BEFORE translation. Reuses worker4's positive
/// exclusive anchors without declaring partial packets complete or changing
/// their erasure authority. Every source lane is read twice, not just DB cores.
enum NativeCausalPacketColumnRecognition {
    struct Crop: Equatable, Sendable {
        let identifier: Int
        let column: Int
        let variant: Int
        let originalPixelQuad: [CGPoint]
    }
    struct Plan: Equatable, Sendable {
        let sourceIdentity: String
        let rowIndex: Int
        let sourceBefore: String
        let normalizedBounds: [Double]
        let sourceQuad: [CGPoint]
        let ownerIDs: [String]
        let columnOwnerIDs: [[String]]
        let crops: [Crop]
    }
    struct Observation: Equatable, Sendable {
        let identifier: Int
        let sourceIdentity: String
        let originalPixelQuad: [CGPoint]
        let text: String
        let confidence: Double
    }
    struct Correction: Equatable, Sendable {
        let plan: Plan
        let sourceAfter: String
        let columns: [String]
        let confidence: Double
        // Geometry, accepted-primary membership and removal owners stay intact.
        let requiresRetranslation = true
        let grantsNewErasureAuthority = false
    }

    static func plans(evidence: [String: Any], originalSize: CGSize, enabled: Bool = false) -> [Plan] {
        guard enabled, let ocr = evidence["originalOCR"] as? [String: Any],
              let rows = ocr["regions"] as? [[String: Any]], rows.count <= 256,
              let identity = evidence["sourceSHA256"] as? String else { return [] }
        let anchors = NativeCausalParagraphAxisGrouping.observedExclusiveSubcolumns(evidence: evidence,
            originalSize: originalSize, enabled: true)
        var result = [Plan]()
        for index in Set(anchors.map(\.originalOCRRowIndex)).sorted() {
            guard result.count < 2, rows.indices.contains(index) else { continue }
            let row = rows[index]
            guard row["sourceSingleVerticalColumn"] as? Bool == false,
                  let partial = row["sourceObservedExclusiveSubcolumns"] as? [String: Any],
                  (partial["ambiguousComponentCount"] as? Int ?? 0) +
                    (partial["candidateComponentCount"] as? Int ?? 0) +
                    (partial["excludedInvalidRecords"] as? Int ?? 0) > 0,
                  let source = row["source"] as? String, !source.isEmpty, source.utf16.count <= 512,
                  (row["confidence"] as? Double ?? 0) >= 0.8,
                  !source.contains("\n\n"), !source.contains("\u{2029}"),
                  let bounds = row["rect"] as? [Double] ?? row["sourceBounds"] as? [Double], bounds.count == 4,
                  bounds.allSatisfy(\.isFinite), bounds[0] >= 0, bounds[1] >= 0, bounds[2] > 0, bounds[3] > 0,
                  bounds[0] + bounds[2] <= 1.000000001, bounds[1] + bounds[3] <= 1.000000001,
                  let points = row["polygon"] as? [[Double]], points.count == 4,
                  points.allSatisfy({ $0.count == 2 && $0.allSatisfy({ $0.isFinite && (0...1).contains($0) }) }) else { continue }
            let xs = points.map { $0[0] }, ys = points.map { $0[1] }
            guard zip([xs.min()!, ys.min()!, xs.max()! - xs.min()!, ys.max()! - ys.min()!], bounds)
                .allSatisfy({ abs($0 - $1) < 1e-6 }) else { continue }
            let q = points.map { CGPoint(x: $0[0] * originalSize.width, y: $0[1] * originalSize.height) }
            let selected = anchors.filter { $0.originalOCRRowIndex == index }.sorted {
                $0.originalPixelObservedEnvelope.midX < $1.originalPixelObservedEnvelope.midX
            }
            guard (2...16).contains(selected.count), Set(selected.map(\.ownerID)).count == selected.count,
                  selected.allSatisfy({ $0.sourceIdentity == identity }),
                  q[1].x > q[0].x, q[2].x > q[3].x, q[3].y > q[0].y, q[2].y > q[1].y,
                  abs(q[3].x - q[0].x) <= (q[1].x - q[0].x) * 0.1,
                  abs(q[2].x - q[1].x) <= (q[1].x - q[0].x) * 0.1 else { continue }
            let left = min(q[0].x, q[3].x), right = max(q[1].x, q[2].x)
            // DB owners may be vertically separated fragments of ONE source
            // column. Require a common x intersection and bounded total spread;
            // pairwise overlap alone could walk transitively into another lane.
            var lanes = [[NativeCausalParagraphAxisGrouping.ObservedExclusiveSubcolumn]]()
            for anchor in selected {
                if let last = lanes.last {
                    let proposed = last + [anchor]
                    let boxes = proposed.map(\.originalPixelObservedEnvelope)
                    let commonLeft = boxes.map(\.minX).max()!, commonRight = boxes.map(\.maxX).min()!
                    let centers = boxes.map(\.midX), width = boxes.map(\.width).min()!
                    if commonRight > commonLeft, centers.max()! - centers.min()! <= width * 0.5 {
                        lanes[lanes.count - 1].append(anchor)
                        continue
                    }
                }
                lanes.append([anchor])
            }
            guard (2...4).contains(lanes.count) else { continue }
            let envelopes = lanes.map { $0.map(\.originalPixelObservedEnvelope).reduce(CGRect.null) { $0.union($1) } }
            let centers = envelopes.map(\.midX)
            let pitches = zip(centers.dropFirst(), centers).map(-)
            guard let minimum = pitches.min(), minimum >= 6, pitches.max()! <= minimum * 1.35,
                  envelopes.allSatisfy({ $0.width <= minimum * 0.8 }),
                  centers[0] > left, centers.last! < right,
                  centers[0] - left <= minimum, right - centers.last! <= minimum else { continue }
            var cuts = [0.0]
            for i in 1..<centers.count { cuts.append(((centers[i - 1] + centers[i]) / 2 - left) / (right - left)) }
            cuts.append(1)
            guard zip(cuts.dropFirst(), cuts).allSatisfy({ $0 > $1 }) else { continue }
            func strip(_ a: Double, _ b: Double) -> [CGPoint] {
                func mix(_ p: CGPoint, _ r: CGPoint, _ t: Double) -> CGPoint {
                    CGPoint(x: p.x + (r.x - p.x) * t, y: p.y + (r.y - p.y) * t)
                }
                return [mix(q[0], q[1], a), mix(q[0], q[1], b), mix(q[3], q[2], b), mix(q[3], q[2], a)]
            }
            var crops = [Crop]()
            // Right-to-left column order. The base strips tile the ENTIRE
            // original quad: no unrecognized gap is silently dropped.
            for (column, i) in (0..<lanes.count).reversed().enumerated() {
                let a = cuts[i], b = cuts[i + 1], margin = (b - a) * 0.1
                crops.append(Crop(identifier: column * 2, column: column, variant: 0, originalPixelQuad: strip(a, b)))
                crops.append(Crop(identifier: column * 2 + 1, column: column, variant: 1,
                    originalPixelQuad: strip(max(0, a - margin), min(1, b + margin))))
            }
            result.append(Plan(sourceIdentity: identity, rowIndex: index, sourceBefore: source,
                normalizedBounds: bounds, sourceQuad: q, ownerIDs: selected.reversed().map(\.ownerID),
                columnOwnerIDs: lanes.reversed().map { $0.map(\.ownerID) }, crops: crops))
        }
        return result
    }

    static func accept(_ plan: Plan, observations: [Observation], currentEvidence: [String: Any],
                       originalSize: CGSize, enabled: Bool = false) -> Correction? {
        guard enabled, plans(evidence: currentEvidence, originalSize: originalSize, enabled: true).contains(plan),
              observations.count == plan.crops.count,
              Set(observations.map(\.identifier)).count == observations.count,
              Set(observations.map(\.identifier)) == Set(plan.crops.map(\.identifier)) else { return nil }
        var columns = [String](), confidence = 1.0
        for column in 0..<plan.columnOwnerIDs.count {
            let crops = plan.crops.filter { $0.column == column }
            guard crops.count == 2 else { return nil }
            var reads = [Observation]()
            for crop in crops {
                guard let read = observations.first(where: { $0.identifier == crop.identifier }),
                      read.sourceIdentity == plan.sourceIdentity, read.originalPixelQuad == crop.originalPixelQuad,
                      read.confidence.isFinite, (0.95...1).contains(read.confidence),
                      !read.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      read.text.utf16.count <= 256, !read.text.contains("\n\n"), !read.text.contains("\u{2029}") else { return nil }
                reads.append(read); confidence = min(confidence, read.confidence)
            }
            guard reads[0].text.utf8.elementsEqual(reads[1].text.utf8) else { return nil }
            columns.append(reads[0].text)
        }
        let source = columns.joined()
        guard source.utf16.count <= 512, !source.utf8.elementsEqual(plan.sourceBefore.utf8) else { return nil }
        return Correction(plan: plan, sourceAfter: source, columns: columns, confidence: confidence)
    }
}
