import CoreGraphics
import Foundation

/// Complete original-span recognition transaction. RF TEXT is a nomination,
/// never a balloon-wide merge or new removal-mask permission.
enum NativeCausalRFParagraphRecognition {
    struct Policy: Equatable, Sendable {
        let minimumConfidence: Double
        let punctuationOnlyConsensus: Bool
        let requiresLiteralLegacySource: Bool
        let parameterGrid: Bool
        init(minimumConfidence: Double, punctuationOnlyConsensus: Bool,
             requiresLiteralLegacySource: Bool, parameterGrid: Bool = false) {
            self.minimumConfidence = minimumConfidence; self.punctuationOnlyConsensus = punctuationOnlyConsensus
            self.requiresLiteralLegacySource = requiresLiteralLegacySource; self.parameterGrid = parameterGrid
        }
        static let legacy = Policy(minimumConfidence: 0.95, punctuationOnlyConsensus: false,
            requiresLiteralLegacySource: true)

        static func optimized(minimumConfidence: Double, punctuationOnlyConsensus: Bool) -> Policy? {
            guard [0.90, 0.925, 0.95].contains(minimumConfidence) else { return nil }
            return Policy(minimumConfidence: minimumConfidence, punctuationOnlyConsensus: punctuationOnlyConsensus,
                requiresLiteralLegacySource: false)
        }

        /// Explicit padded-original experiment only; regular optimized() remains unchanged.
        static func actualReadGrid(minimumConfidence: Double) -> Policy? {
            guard [0.75, 0.8, 0.85, 0.9].contains(minimumConfidence) else { return nil }
            return Policy(minimumConfidence: minimumConfidence, punctuationOnlyConsensus: true,
                requiresLiteralLegacySource: false, parameterGrid: true)
        }

        static func configured(environment: [String: String] = ProcessInfo.processInfo.environment) -> Policy {
            guard environment["AIDOKU_OCR_RF_PARAGRAPH_ACCEPTANCE_OPTIMIZATION"] == "1",
                  let raw = environment["AIDOKU_OCR_RF_PARAGRAPH_MIN_CONFIDENCE"], let value = Double(raw) else { return .legacy }
            let dots = environment["AIDOKU_OCR_RF_PARAGRAPH_DOT_CONSENSUS"] == "1"
            if environment["AIDOKU_OCR_RF_PARAGRAPH_ACTUAL_READ_GRID"] == "1" {
                guard dots, let policy = actualReadGrid(minimumConfidence: value) else { return .legacy }
                return policy
            }
            return optimized(minimumConfidence: value, punctuationOnlyConsensus: dots) ?? .legacy
        }
    }
    struct Run: Equatable, Sendable {
        let ordinal: Int
        let text: String
        let polygon: [CGPoint] // original pixels, immutable accepted primary
    }
    struct Owner: Equatable, Sendable {
        let id: String
        let source: String
        let bounds: CGRect // original pixels
        let operationID: String
        let runs: [Run]
    }
    struct Support: Sendable { let queryID: Int; let confidence: Double; let bounds: CGRect }
    struct Crop: Equatable, Sendable {
        let identifier: Int
        let column: Int
        let variant: Int
        let polygon: [CGPoint]
    }
    struct Plan: Equatable, Sendable {
        let sourceIdentity: String
        let queryID: Int
        let originals: [Owner]
        let primaryUnion: [Int]
        let bounds: CGRect
        let centers: [CGFloat] // right-to-left
        let crops: [Crop]
        let longitudinalSampling: NativeCausalRFLongitudinalSampling.Evidence?
        init(sourceIdentity: String, queryID: Int, originals: [Owner], primaryUnion: [Int], bounds: CGRect,
             centers: [CGFloat], crops: [Crop], longitudinalSampling: NativeCausalRFLongitudinalSampling.Evidence? = nil) {
            self.sourceIdentity = sourceIdentity; self.queryID = queryID; self.originals = originals
            self.primaryUnion = primaryUnion; self.bounds = bounds; self.centers = centers; self.crops = crops
            self.longitudinalSampling = longitudinalSampling
        }
    }
    struct Read: Equatable, Sendable {
        let identifier: Int
        let polygon: [CGPoint]
        let text: String
        let confidence: Double
    }
    struct Correction: Equatable, Sendable {
        let plan: Plan
        let source: String
        let columns: [String]
        let reads: [Read]
        let confidence: Double
        let acceptancePolicy: Policy
        var adaptiveSampling: NativeCausalRFAdaptiveSampling.Evidence? = nil
        let grantsNewErasureAuthority = false
    }

    static func plans(owners: [Owner], supports: [Support], sourceIdentity: String, imageSize: CGSize,
                      enabled: Bool = false, nomination: NativeCausalRFNominationPolicy = .legacy, longitudinalFraction: Double = 0,
                      separates: (CGRect, CGRect) -> Bool) -> [Plan] {
        guard [0, 0.1, 0.2].contains(longitudinalFraction), enabled, sourceIdentity.hasPrefix("canonical-rgb8:"), owners.count <= 256,
              supports.count <= 512, imageSize.width > 0, imageSize.height > 0 else { return [] }
        let canvas = CGRect(origin: .zero, size: imageSize)
        var plans = [Plan](), seen = Set<String>()
        for rf in nomination.ranked(supports, owners: owners) {
            guard plans.count < nomination.maximumPlans, rf.confidence.isFinite, rf.confidence >= nomination.supportFloor else { continue }
            let selected = owners.filter { $0.bounds.intersects(rf.bounds) }
            guard (2...16).contains(selected.count), Set(selected.map(\.id)).count == selected.count,
                  let first = selected.first, !first.operationID.isEmpty,
                  selected.allSatisfy({ $0.operationID == first.operationID && !$0.runs.isEmpty &&
                      !$0.source.isEmpty && !$0.source.contains("\n\n") && !$0.source.contains("\u{2029}") &&
                      canvas.contains($0.bounds) && area($0.bounds.intersection(rf.bounds)) / area($0.bounds) >= 0.9 }) else { continue }
            let runs = selected.flatMap(\.runs)
            guard runs.count <= 64, Set(runs.map(\.ordinal)).count == runs.count,
                  runs.allSatisfy({ !$0.text.isEmpty && $0.text.utf16.count <= 512 && box($0.polygon) != nil }) else { continue }
            let scope = selected.map(\.bounds).reduce(CGRect.null) { $0.union($1) }
            guard area(scope) <= 1_048_576,
                  runs.allSatisfy({ scope.insetBy(dx: -1e-6, dy: -1e-6).contains(box($0.polygon)!) }) else { continue }
            // Each accepted-primary packet supplies an original OCR axis. A
            // shared x intersection prevents transitive column/owner drift.
            let sorted = runs.sorted { box($0.polygon)!.midX < box($1.polygon)!.midX }
            var lanes = [[Run]]()
            for run in sorted {
                if let last = lanes.last {
                    let boxes = (last + [run]).map { box($0.polygon)! }
                    let mids = boxes.map(\.midX), widths = boxes.map(\.width)
                    if boxes.map(\.minX).max()! < boxes.map(\.maxX).min()!,
                       mids.max()! - mids.min()! <= widths.min()! * 0.5 {
                        lanes[lanes.count - 1].append(run); continue
                    }
                }
                lanes.append([run])
            }
            guard (2...4).contains(lanes.count) else { continue }
            let centers = lanes.map { lane -> CGFloat in
                let values = lane.map { box($0.polygon)!.midX }.sorted()
                return values[values.count / 2]
            }
            let pitch = zip(centers.dropFirst(), centers).map(-)
            guard let minimum = pitch.min(), minimum >= 6, pitch.max()! <= minimum * 1.5,
                  centers.first! - scope.minX <= minimum, scope.maxX - centers.last! <= minimum else { continue }
            var boundary = false
            for i in selected.indices { for j in selected.indices where j > i {
                if separates(selected[i].bounds, selected[j].bounds) { boundary = true }
            } }
            guard !boundary else { continue }
            if nomination.ownerCountExponent > 0, plans.contains(where: { existing in
                !Set(existing.primaryUnion).isDisjoint(with: Set(runs.map(\.ordinal)))
            }) { continue }
            let key = selected.map(\.id).sorted().joined(separator: "\u{0}")
            guard seen.insert(key).inserted else { continue }
            var cuts = [scope.minX]
            for i in 1..<centers.count { cuts.append((centers[i - 1] + centers[i]) / 2) }
            cuts.append(scope.maxX)
            var crops = [Crop]()
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
                    centers: centers, canvas: imageSize, originals: selected, current: owners) else { continue }
                var padded = [Crop]()
                for crop in crops {
                    guard let base = box(crop.polygon),
                          let sampled = NativeCausalRFLongitudinalSampling.padded(base, source: scope, evidence: evidence)
                    else { break }
                    padded.append(.init(identifier: crop.identifier, column: crop.column, variant: crop.variant,
                        polygon: quad(sampled)))
                }
                guard padded.count == crops.count else { continue }
                crops = padded; sampling = evidence
            }
            plans.append(.init(sourceIdentity: sourceIdentity, queryID: rf.queryID, originals: selected,
                primaryUnion: runs.map(\.ordinal).sorted(), bounds: scope, centers: centers.reversed(), crops: crops,
                longitudinalSampling: sampling))
        }
        return plans
    }

    static func accept(_ plan: Plan, reads: [Read], current: [Owner], enabled: Bool = false,
                       policy: Policy = .legacy) -> Correction? {
        if policy.parameterGrid {
            guard !policy.requiresLiteralLegacySource, policy.punctuationOnlyConsensus,
                  [0.75, 0.8, 0.85, 0.9].contains(policy.minimumConfidence),
                  plan.longitudinalSampling != nil else { return nil }
        } else {
            guard policy == .legacy || (!policy.requiresLiteralLegacySource &&
                [0.90, 0.925, 0.95].contains(policy.minimumConfidence)) else { return nil }
        }
        guard enabled, (4...8).contains(plan.crops.count), reads.count == plan.crops.count,
              Set(reads.map(\.identifier)).count == reads.count,
              plan.originals.allSatisfy({ original in current.filter { $0.id == original.id } == [original] }) else { return nil }
        // Any newly appeared overlapping owner invalidates this whole source
        // transaction, including protected/kept owners. Never erase by RF bbox.
        let ids = Set(plan.originals.map(\.id))
        guard current.filter({ !ids.contains($0.id) }).allSatisfy({ !$0.bounds.intersects(plan.bounds) }) else { return nil }
        if let sampling = plan.longitudinalSampling {
            guard NativeCausalRFLongitudinalSampling.matchesCurrent(sampling, originals: plan.originals, current: current)
            else { return nil }
        }
        if !policy.requiresLiteralLegacySource || plan.longitudinalSampling != nil {
            guard completeGeometry(plan) else { return nil }
        }
        var columns = [String](), confidence = 1.0
        for column in plan.centers.indices {
            let crops = plan.crops.filter { $0.column == column }
            var paired = [Read]()
            for crop in crops {
                guard let read = reads.first(where: { $0.identifier == crop.identifier }), read.polygon == crop.polygon,
                      read.confidence.isFinite, (policy.minimumConfidence...1).contains(read.confidence), !read.text.isEmpty,
                      read.text.utf16.count <= 512, !read.text.contains("\n\n"), !read.text.contains("\u{2029}") else { return nil }
                paired.append(read); confidence = min(confidence, read.confidence)
            }
            guard paired.count == 2 else { return nil }
            let exact = paired[0].text.utf8.elementsEqual(paired[1].text.utf8)
            guard exact || (policy.punctuationOnlyConsensus &&
                dotComparisonKey(paired[0].text).utf8.elementsEqual(dotComparisonKey(paired[1].text).utf8)) else { return nil }
            // Preserve an ACTUAL read, never the comparison key. Legacy tie/
            // selection behavior remains unchanged unless optimization is ON.
            let chosen = policy.requiresLiteralLegacySource || paired[0].confidence >= paired[1].confidence ? paired[0] : paired[1]
            columns.append(chosen.text)
        }
        // Account for EVERY actual primary source, including kept one-character
        // children, in physical top-to-bottom order on its original column.
        // This deliberately abstains when raw-source evidence cannot be found;
        // confidence alone never certifies a complete paragraph.
        let runs = plan.originals.flatMap(\.runs)
        for column in plan.centers.indices where policy.requiresLiteralLegacySource {
            let lane = runs.filter { run in
                let x = box(run.polygon)!.midX
                return plan.centers.indices.min(by: { abs(plan.centers[$0] - x) < abs(plan.centers[$1] - x) }) == column
            }.sorted { box($0.polygon)!.minY < box($1.polygon)!.minY }
            var cursor = columns[column].startIndex
            for run in lane {
                guard let match = columns[column].range(of: run.text, options: .literal,
                    range: cursor..<columns[column].endIndex) else { return nil }
                cursor = match.upperBound
            }
        }
        let source = columns.joined()
        guard source.utf16.count <= 2048 else { return nil }
        return .init(plan: plan, source: source, columns: columns, reads: reads, confidence: confidence,
            acceptancePolicy: policy)
    }

    /// ASCII period and U+2026 ellipsis RUNS only. No whitespace folding,
    /// Unicode canonicalization, words, diacritics, exclamation or other marks.
    static func dotComparisonKey(_ text: String) -> String {
        var result = String.UnicodeScalarView(), inDots = false
        for scalar in text.unicodeScalars {
            if scalar.value == 0x2E || scalar.value == 0x2026 {
                if !inDots { result.append(".") }
                inDots = true
            } else { result.append(scalar); inDots = false }
        }
        return String(result)
    }

    static func completeGeometry(_ plan: Plan) -> Bool {
        guard (2...16).contains(plan.originals.count), (2...4).contains(plan.centers.count),
              plan.crops.count == plan.centers.count * 2,
              Set(plan.originals.map(\.id)).count == plan.originals.count,
              Set(plan.originals.map(\.operationID)).count == 1,
              plan.originals.allSatisfy({ !$0.operationID.isEmpty && !$0.runs.isEmpty }) else { return false }
        let runs = plan.originals.flatMap(\.runs), ordinals = runs.map(\.ordinal)
        let scope = plan.originals.map(\.bounds).reduce(CGRect.null) { $0.union($1) }
        guard Set(ordinals).count == ordinals.count, ordinals.sorted() == plan.primaryUnion,
              close(scope.minX, plan.bounds.minX), close(scope.minY, plan.bounds.minY),
              close(scope.width, plan.bounds.width), close(scope.height, plan.bounds.height),
              runs.allSatisfy({ run in
                  guard let b = box(run.polygon) else { return false }
                  return scope.insetBy(dx: -1e-6, dy: -1e-6).contains(b)
              }) else { return false }
        let centers = Array(plan.centers.reversed())
        guard centers.allSatisfy({ $0.isFinite && $0 > scope.minX && $0 < scope.maxX }),
              zip(centers.dropFirst(), centers).allSatisfy({ $0 > $1 }) else { return false }
        if let sampling = plan.longitudinalSampling {
            guard NativeCausalRFLongitudinalSampling.validatedPitch(sampling, centers: centers) else { return false }
        }
        var cuts = [scope.minX]
        for i in 1..<centers.count { cuts.append((centers[i - 1] + centers[i]) / 2) }
        cuts.append(scope.maxX)
        for (column, i) in (0..<centers.count).reversed().enumerated() {
            let pair = plan.crops.filter { $0.column == column }
            guard pair.count == 2, Set(pair.map(\.variant)) == Set([0, 1]) else { return false }
            for crop in pair {
                let pad = crop.variant == 0 ? 0 : (cuts[i + 1] - cuts[i]) * 0.1
                let left = max(scope.minX, cuts[i] - pad), right = min(scope.maxX, cuts[i + 1] + pad)
                let base = CGRect(x: left, y: scope.minY, width: right - left, height: scope.height)
                let sampled: CGRect
                if let evidence = plan.longitudinalSampling {
                    guard let padded = NativeCausalRFLongitudinalSampling.padded(base, source: scope, evidence: evidence)
                    else { return false }
                    sampled = padded
                } else { sampled = base }
                let expected = quad(sampled)
                guard crop.polygon.count == 4, zip(crop.polygon, expected).allSatisfy({
                    close($0.x, $1.x) && close($0.y, $1.y)
                }) else { return false }
            }
        }
        return true
    }

    private static func close(_ a: CGFloat, _ b: CGFloat) -> Bool { a.isFinite && b.isFinite && abs(a - b) < 1e-6 }

    private static func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : max(0, r.width) * max(0, r.height) }
    private static func box(_ q: [CGPoint]) -> CGRect? {
        guard q.count == 4, q.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let xs = q.map(\.x), ys = q.map(\.y)
        let r = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        return r.width > 0 && r.height > 0 ? r : nil
    }
    private static func quad(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }
}
