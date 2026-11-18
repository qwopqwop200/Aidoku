import CoreGraphics
import Foundation

/// Recognition nomination only. Closed ORIGINAL DB evidence supplies column
/// axes when a broad/noisy OCR quad cannot. Raw primary polygons remain intact;
/// no glyph/font, paragraph-completion or new erasure authority is granted.
enum NativeCausalRFComponentParagraphRequests {
    typealias P = NativeCausalRFParagraphRecognition
    typealias Evidence = NativeOCRDetectorSeedEvidence
    static var runtimeEnabled: Bool {
        ProcessInfo.processInfo.environment["AIDOKU_OCR_RF_COMPONENT_PARAGRAPH"] == "1"
    }
    static let cacheVersion = "rf-source-closed-component-columns-v184-plan-owner-binding"

    static func plans(owners: [P.Owner], recordsByOwner: [String: [Evidence]], allDetectors: [Evidence],
                      supports: [P.Support], sourceIdentity: String, imageSize: CGSize,
                      enabled: Bool = false, longitudinalFraction: Double = 0,
                      separates: (CGRect, CGRect) -> Bool,
                      audit: ((String) -> Void)? = nil) -> [P.Plan] {
        guard enabled, sourceIdentity.hasPrefix("canonical-rgb8:"), owners.count <= 256,
              allDetectors.count <= 256, supports.count <= 512,
              imageSize.width > 0, imageSize.height > 0,
              [0, 0.1, 0.2].contains(longitudinalFraction) else { return [] }
        let canvas = CGRect(origin: .zero, size: imageSize)
        var result = [P.Plan](), used = Set<String>()
        for rf in supports.sorted(by: { $0.confidence > $1.confidence }) {
            guard result.count < 2, rf.confidence.isFinite, rf.confidence >= 0.55 else { continue }
            let selected = owners.filter { $0.bounds.intersects(rf.bounds) }
            guard (2...16).contains(selected.count), let first = selected.first,
                  !first.operationID.isEmpty, Set(selected.map(\.id)).count == selected.count,
                  used.isDisjoint(with: selected.map(\.id)),
                  selected.allSatisfy({ $0.operationID == first.operationID && !$0.runs.isEmpty &&
                      !$0.source.isEmpty && !$0.source.contains("\n\n") && !$0.source.contains("\u{2029}") &&
                      canvas.contains($0.bounds) }) else { continue }
            let runs = selected.flatMap(\.runs)
            guard runs.count <= 64, Set(runs.map(\.ordinal)).count == runs.count,
                  runs.allSatisfy({ box($0.polygon) != nil && !$0.text.isEmpty && $0.text.utf16.count <= 512 }) else { continue }
            let scope = selected.map(\.bounds).reduce(CGRect.null) { $0.union($1) }
            guard area(scope) <= 1_048_576,
                  runs.allSatisfy({ scope.insetBy(dx: -1e-6, dy: -1e-6).contains(box($0.polygon)!) }) else { continue }
            var records = [Evidence]()
            for owner in selected {
                guard let own = recordsByOwner[owner.id], !own.isEmpty else { records = []; break }
                for record in own where !records.contains(record) { records.append(record) }
            }
            guard let grid = records.first, records.count <= 128,
                  records.allSatisfy({ record in
                      record.isValid && record.ownershipVersion == 2 && record.completeCCScan == true &&
                      record.sourceWidth == Int(imageSize.width) && record.sourceHeight == Int(imageSize.height) &&
                      record.mapFullWidth == grid.mapFullWidth && record.mapFullHeight == grid.mapFullHeight &&
                      record.mapOriginX == grid.mapOriginX && record.mapOriginY == grid.mapOriginY &&
                      allDetectors.contains(record)
                  }) else { audit?("missing-current-complete-detector-records"); continue }
            let detectorIDs = Set(records.map(\.ownerID))
            var closed = [Int: Evidence.Component](), consistent = true
            for record in records {
                for c in components(record) {
                    if let old = closed[c.seed], old != c { consistent = false }
                    closed[c.seed] = c
                }
            }
            guard consistent, !closed.isEmpty, closed.count <= 256,
                  closed.values.reduce(0, { $0 + $1.runs.count }) <= 8192 else { continue }
            // Shared/candidate DB hypotheses may be used for recognition only
            // after EVERY actual referring detector and competitor is selected.
            // One unknown/outside source invalidates the entire proposed scope.
            for component in closed.values {
                let references = allDetectors.filter { components($0).contains(where: { $0.seed == component.seed }) }
                if references.isEmpty || !references.allSatisfy({ record in
                    detectorIDs.contains(record.ownerID) && record.isValid &&
                    components(record).filter({ $0.seed == component.seed }).allSatisfy({ $0 == component }) &&
                    (record.candidateComponents ?? []).filter({ $0.component.seed == component.seed }).allSatisfy({
                        Set($0.competingOwnerIDs).isSubset(of: detectorIDs)
                    })
                }) { consistent = false; break }
            }
            guard consistent else { audit?("outside-detector-component-owner"); continue }
            let sx = imageSize.width / CGFloat(grid.mapFullWidth), sy = imageSize.height / CGFloat(grid.mapFullHeight)
            func bounds(_ c: Evidence.Component) -> CGRect {
                c.runs.reduce(CGRect.null) { $0.union(CGRect(x: CGFloat($1.x) * sx, y: CGFloat($1.y) * sy,
                    width: CGFloat($1.count) * sx, height: sy)) }
            }
            let anchors = closed.values.filter { c in
                let b = bounds(c)
                return c.pixelCount >= 6 && b.height >= b.width * 2 && b.height >= sy * 4
            }.sorted { bounds($0).midX < bounds($1).midX }
            guard anchors.count >= 2 else { audit?("no-original-vertical-component-chain"); continue }
            // Do not drop a short/horizontal-labeled OCR owner. Its OWN raw DB
            // references must participate in the same measured vertical lanes.
            guard selected.allSatisfy({ owner in
                let seeds = Set((recordsByOwner[owner.id] ?? []).flatMap(components).map(\.seed))
                let own = anchors.filter { seeds.contains($0.seed) }
                return !own.isEmpty && own.allSatisfy({
                    area(bounds($0).intersection(rf.bounds)) / area(bounds($0)) >= 0.9
                })
            }) else { audit?("owner-original-support-not-rf-aligned"); continue }
            // Unknown detector islands inside a broad OCR envelope remain
            // keepouts, even if RF or another selected owner's quad covers them.
            guard allDetectors.filter({ !detectorIDs.contains($0.ownerID) }).allSatisfy({ record in
                components(record).allSatisfy({ !bounds($0).intersects(scope) })
            }) else { audit?("foreign-detector-island-in-scope"); continue }
            var lanes = [[Evidence.Component]]()
            for c in anchors {
                if let last = lanes.last {
                    let boxes = (last + [c]).map(bounds), centers = boxes.map(\.midX)
                    if boxes.map(\.minX).max()! < boxes.map(\.maxX).min()!,
                       centers.max()! - centers.min()! <= boxes.map(\.width).min()! * 0.5 {
                        lanes[lanes.count - 1].append(c); continue
                    }
                }
                lanes.append([c])
            }
            guard (2...4).contains(lanes.count) else { audit?("component-columns-outside-live-eight-crop-budget"); continue }
            let centers = lanes.map { lane -> CGFloat in
                let xs = lane.map { bounds($0).midX }.sorted(); return xs[xs.count / 2]
            }
            let pitches = zip(centers.dropFirst(), centers).map(-)
            guard let pitch = pitches.min(), pitch >= 6, pitches.max()! <= pitch * 1.5,
                  anchors.allSatisfy({ bounds($0).width <= pitch * 0.8 }) else { audit?("incoherent-original-column-pitch"); continue }
            var separated = false
            for i in selected.indices { for j in selected.indices where j > i {
                if separates(selected[i].bounds, selected[j].bounds) { separated = true }
            } }
            guard !separated else { audit?("explicit-source-separator"); continue }
            var cuts = [scope.minX]
            for i in 1..<centers.count { cuts.append((centers[i - 1] + centers[i]) / 2) }
            cuts.append(scope.maxX)
            guard zip(cuts.dropFirst(), cuts).allSatisfy({ $0 > $1 }) else { continue }
            var crops = [P.Crop]()
            for (column, i) in (0..<lanes.count).reversed().enumerated() {
                let a = cuts[i], b = cuts[i + 1], pad = (b - a) * 0.1
                for variant in 0...1 {
                    let left = variant == 0 ? a : max(scope.minX, a - pad)
                    let right = variant == 0 ? b : min(scope.maxX, b + pad)
                    crops.append(.init(identifier: column * 2 + variant, column: column, variant: variant,
                        polygon: quad(CGRect(x: left, y: scope.minY, width: right - left, height: scope.height))))
                }
            }
            var sampling: NativeCausalRFLongitudinalSampling.Evidence?
            if longitudinalFraction > 0 {
                guard let evidence = NativeCausalRFLongitudinalSampling.evidence(fraction: longitudinalFraction,
                    centers: centers, canvas: imageSize, originals: selected, current: owners) else {
                    audit?("invalid-longitudinal-sampling-evidence"); continue
                }
                var padded = [P.Crop]()
                for crop in crops {
                    guard let base = box(crop.polygon),
                          let sampled = NativeCausalRFLongitudinalSampling.padded(base, source: scope, evidence: evidence)
                    else { break }
                    padded.append(.init(identifier: crop.identifier, column: crop.column, variant: crop.variant,
                        polygon: quad(sampled)))
                }
                guard padded.count == crops.count else {
                    audit?("longitudinal-original-source-keepout"); continue
                }
                crops = padded; sampling = evidence
            }
            result.append(.init(sourceIdentity: sourceIdentity, queryID: rf.queryID, originals: selected,
                primaryUnion: runs.map(\.ordinal).sorted(), bounds: scope, centers: centers.reversed(), crops: crops,
                longitudinalSampling: sampling))
            used.formUnion(selected.map(\.id))
            audit?("closed-original-component-paragraph-requested")
        }
        return result
    }

    private static func components(_ record: Evidence) -> [Evidence.Component] {
        record.components + (record.ambiguousComponents ?? []) + (record.candidateComponents ?? []).map(\.component)
    }
    private static func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : max(0, r.width) * max(0, r.height) }
    private static func box(_ q: [CGPoint]) -> CGRect? {
        guard q.count == 4, q.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let xs = q.map(\.x), ys = q.map(\.y)
        let b = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        return b.width > 0 && b.height > 0 ? b : nil
    }
    private static func quad(_ r: CGRect) -> [CGPoint] {
        [.init(x: r.minX, y: r.minY), .init(x: r.maxX, y: r.minY),
         .init(x: r.maxX, y: r.maxY), .init(x: r.minX, y: r.maxY)]
    }
}
