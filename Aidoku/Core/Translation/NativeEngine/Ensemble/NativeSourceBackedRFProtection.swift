import CoreGraphics
import Foundation

/// Optional final-mask precedence, never a new segmentation/erasure proposal.
/// RF model-only balloon contours and uncontoured SFX boxes may defer to an
/// already-selected primary seed with original RGB contrast. Such evidence is
/// not glyph truth or an independent source-boundary certificate.
enum NativeSourceBackedRFProtection {
    static let sourceEvidenceKey = "sourceBackedRFProtectionRequest"
    /// Simple baseline: upstream owners decide translation/preservation. RF
    /// An RF-SFX box does not overrule that decision at the final mask stage.
    static var simpleHardConstraintsEnabled: Bool {
        let policy = ProcessInfo.processInfo.environment["AIDOKU_FINAL_RF_PROTECTION_POLICY"]
        return policy == "simple-hard" || policy == "owner-majority" || policy == "owner-majority-no-frame"
    }
    static var ownerMajorityComponentsEnabled: Bool {
        let policy = ProcessInfo.processInfo.environment["AIDOKU_FINAL_RF_PROTECTION_POLICY"]
        return policy == "owner-majority" || policy == "owner-majority-no-frame"
    }
    static var estimatedFrameBoundaryDisabled: Bool {
        ProcessInfo.processInfo.environment["AIDOKU_FINAL_RF_PROTECTION_POLICY"] == "owner-majority-no-frame"
    }
    static var runtimeEnabled: Bool {
        !simpleHardConstraintsEnabled && ProcessInfo.processInfo.environment["AIDOKU_SOURCE_BACKED_RF_PROTECTION"] == "1"
    }
    static var cacheProjection: [String: String] {
        if estimatedFrameBoundaryDisabled {
            return ["finalRFProtectionPolicy": "preserved-balloon-sfx-owner-majority-no-model-frame-v1"]
        }
        if ownerMajorityComponentsEnabled {
            return ["finalRFProtectionPolicy": "preserved-contours-owner-majority-components-v1"]
        }
        if simpleHardConstraintsEnabled {
            return ["finalRFProtectionPolicy": "preserved-owner-contours-no-sfx-box-v1"]
        }
        return runtimeEnabled ? ["sourceBackedRFProtectionPolicy": "selected-primary-rgb-over-estimated-rf-v1"] : [:]
    }

    struct Region: Equatable {
        let query: Int
        let kind: Int
        let confidence: Double
        let bounds: CGRect
        let exterior: [CGPoint]
        let holes: [[CGPoint]]
    }
    struct Request {
        let original: CGImage
        fileprivate let regions: [Region]
        fileprivate let domains: [CGRect]
        func intersects(_ crop: CGRect) -> Bool { domains.contains { $0.intersects(crop) } }
    }
    struct PackedSeed {
        let sourceIdentity: String
        let producerPolicySHA256: String
        let crop: CGRect
        let bits: Data
        fileprivate let request: Request
    }
    struct Owner {
        let polygon: [CGPoint]
        let background: [Double]
    }
    struct Exemptions {
        fileprivate var bits: [UInt8] = []
        init() {}
        func contains(_ index: Int) -> Bool {
            index >= 0 && index / 8 < bits.count && (bits[index / 8] & UInt8(1 << (index % 8))) != 0
        }
    }
    struct Result {
        let exemptions: Exemptions
        let audit: [String: Any]
    }

    /// Same validity and confidence admission as the existing protection path.
    /// A model SFX contour remains HARD as a policy choice, not a certificate.
    static func isWeak(_ region: Ensemble100RFRegion) -> Bool {
        guard region.confidence.isFinite, region.confidence >= 0.6 else { return false }
        let rings = ([region.exterior] + region.holes).filter { ring in
            ring.count >= 3 && ring.allSatisfy { $0.x.isFinite && $0.y.isFinite &&
                (0...1).contains($0.x) && (0...1).contains($0.y) }
        }
        return region.classID == 2 ? !rings.isEmpty : region.classID == 1 && rings.isEmpty
    }

    /// Preserve existing actual contour keepouts, including contoured SFX as
    /// an explicit policy choice. Only the unsegmented SFX rectangle is omitted.
    static func simpleRegions(_ regions: [Ensemble100RFRegion]) -> [Ensemble100RFRegion] {
        regions.filter { $0.classID != 1 || !isWeak($0) }
    }

    /// Only this opt-in omits estimated RF frame strokes. It does not remove
    /// preserved-owner, balloon or SFX contour precedence. No balloon assignment
    /// is changed. Current M1 TRAIN groupCV selected the combined simplification.
    static func finalRegions(_ regions: [Ensemble100RFRegion]) -> [Ensemble100RFRegion] {
        let simple = simpleRegions(regions)
        return estimatedFrameBoundaryDisabled ? simple.filter { $0.classID != 3 } : simple
    }

    /// Final erasure-owner admission, not a replacement source NN mask. Keep
    /// or omit each complete8-connected selected component; never bbox/polygon
    /// clip it. The fixed half-occupancy budget was selected on TRAIN-group CV.
    /// RGB, RF scores, text, GT and page IDs cannot affect this operation.
    static func admitOwnerMajorityComponents(mask: [UInt8], width: Int, height: Int,
                                             localPolygon: [CGPoint]) -> (mask: [UInt8], audit: [String: Any])? {
        guard width > 0, height > 0, width <= 1_500_000 / height,
              mask.count == width * height, mask.allSatisfy({ $0 == 0 || $0 == 255 }),
              (3...16).contains(localPolygon.count),
              localPolygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let count = width * height
        var owner = [UInt8](repeating: 0, count: count)
        // Pixel-centre even-odd membership, no antialiasing or bbox expansion.
        for y in 0..<height {
            let py = Double(y) + 0.5
            var crossings: [Double] = []
            for i in localPolygon.indices {
                let a = localPolygon[i], b = localPolygon[(i + 1) % localPolygon.count]
                guard (a.y > py) != (b.y > py) else { continue }
                let x = (b.x - a.x) * (py - a.y) / (b.y - a.y) + a.x
                guard x.isFinite else { return nil }
                crossings.append(x)
            }
            crossings.sort()
            guard crossings.count % 2 == 0 else { return nil }
            for pair in stride(from: 0, to: crossings.count, by: 2) {
                let left = Int(ceil(max(0, min(Double(width), crossings[pair] - 0.5))))
                let right = Int(ceil(max(0, min(Double(width), crossings[pair + 1] - 0.5))))
                if left < right { for x in left..<right { owner[y * width + x] = 1 } }
            }
        }
        var pending = mask, admitted = [UInt8](repeating: 0, count: count), queue: [Int] = []
        queue.reserveCapacity(min(count, 4096))
        var components = 0, kept = 0, selectedPixels = 0, admittedPixels = 0, largestComponent = 0
        for seed in 0..<count where pending[seed] != 0 {
            components += 1; queue.removeAll(keepingCapacity: true); queue.append(seed); pending[seed] = 0
            var head = 0, owned = 0
            while head < queue.count {
                let pixel = queue[head]; head += 1; owned += Int(owner[pixel])
                let x = pixel % width, y = pixel / width
                for ny in max(0, y - 1)...min(height - 1, y + 1) {
                    for nx in max(0, x - 1)...min(width - 1, x + 1) {
                        let next = ny * width + nx
                        if pending[next] != 0 { pending[next] = 0; queue.append(next) }
                    }
                }
            }
            selectedPixels += queue.count; largestComponent = max(largestComponent, queue.count)
            if owned >= (queue.count + 1) / 2 {
                kept += 1; admittedPixels += queue.count
                for pixel in queue { admitted[pixel] = 255 }
            }
        }
        return (admitted, ["policy": "whole-8-connected-component-owner-fraction-ge-half-v1",
            "components": components, "keptComponents": kept, "selectedPixels": selectedPixels,
            "admittedPixels": admittedPixels, "omittedPixels": selectedPixels - admittedPixels,
            "largestComponentPixels": largestComponent, "cropPixels": count,
            "GTRead": false, "RGBRead": false, "RFRead": false, "bboxMaskClipping": false,
            "sourceNNMaskMutated": false])
    }

    /// No RGB decode, model call, source registry or work when disabled.
    static func request(original: CGImage, regions: [Ensemble100RFRegion]) -> Request? {
        guard runtimeEnabled, original.width > 0, original.height > 0,
              original.width <= 16_777_216 / original.height, regions.count <= 4096,
              regions.reduce(0, { $0 + $1.exterior.count + $1.holes.reduce(0, { $0 + $1.count }) }) <= 65_536
        else { return nil }
        let weak = regions.filter(isWeak)
        guard !weak.isEmpty else { return nil }
        let page = CGRect(x: 0, y: 0, width: original.width, height: original.height)
        var signatures: [Region] = [], domains: [CGRect] = []
        for region in weak {
            let b = region.bounds
            guard [b.minX, b.minY, b.width, b.height].allSatisfy(\.isFinite), b.width > 0, b.height > 0 else { return nil }
            signatures.append(.init(query: region.queryID, kind: region.classID, confidence: region.confidence,
                bounds: b, exterior: region.exterior, holes: region.holes))
            // Existing protection stroke is4 original pixels wide. Padding2
            // only nominates work near that stroke; it never expands a mask.
            domains.append(CGRect(x: b.minX * Double(original.width), y: b.minY * Double(original.height),
                width: b.width * Double(original.width), height: b.height * Double(original.height))
                .insetBy(dx: -2, dy: -2).integral.intersection(page))
        }
        return .init(original: original, regions: signatures, domains: domains)
    }

    static func requested(_ evidence: [String: Any], original: CGImage) -> Request? {
        guard runtimeEnabled, let value = evidence[sourceEvidenceKey] as? Request, value.original === original else { return nil }
        return value
    }

    /// Borrow already-produced arrays while alive. The one-bit payload is
    /// selected AND rawNative, not a copy of raw model tensors or RGB.
    /// Existing selected-mask budgets cap payload at187500B/owner,3MB/page.
    static func pack(rawNative: [UInt8], selected: [UInt8], crop: CGRect, sourceIdentity: String,
                     original: CGImage, request: Request?, work: inout Int) -> PackedSeed? {
        guard runtimeEnabled, let request, request.original === original, request.intersects(crop) else { return nil }
        guard !sourceIdentity.isEmpty, crop == crop.integral, crop.width > 0, crop.height > 0,
              crop.minX >= 0, crop.minY >= 0, crop.maxX <= Double(original.width), crop.maxY <= Double(original.height),
              crop.width <= 1_500_000 / crop.height else { return nil }
        let n = Int(crop.width) * Int(crop.height)
        guard selected.count == n, rawNative.count == n, work <= 24_000_000 - n else { return nil }
        work += n
        var bits = Data(count: (n + 7) / 8), positive = false
        for k in 0..<n {
            guard selected[k] == 0 || selected[k] == 255,
                  rawNative[k] == 0 || rawNative[k] == 1 || rawNative[k] == 255 else { return nil }
            if selected[k] != 0 && rawNative[k] != 0 {
                bits[k / 8] |= UInt8(1 << (k % 8)); positive = true
            }
        }
        guard positive else { return nil }
        return .init(sourceIdentity: sourceIdentity, producerPolicySHA256: NativeSourceSegmentationExecution.erasurePolicySHA256,
            crop: crop, bits: bits, request: request)
    }

    static func evaluate(original: CGImage, sourceIdentity: String, rgb: [UInt8], selected: [UInt8], labels: [UInt8],
                         masks: NativeSelectedSourceSegmentationMasks?, owners: [Owner], regions: [Ensemble100RFRegion],
                         sourceContrast: Double) -> Result {
        func abstain(_ status: String) -> Result {
            .init(exemptions: .init(), audit: ["enabled": runtimeEnabled, "status": status, "exemptedPixels": 0])
        }
        guard runtimeEnabled else { return abstain("disabled") }
        guard let actualRequest = request(original: original, regions: regions) else { return abstain("no-applicable-weak-RF") }
        guard let masks, masks.original === original, masks.policySHA256 == NativeSourceSegmentationExecution.erasurePolicySHA256 else {
            return abstain("missing-source-bound-selected-witness")
        }
        let w = original.width, h = original.height, n = w * h
        guard n > 0, n <= 16_777_216, rgb.count == n * 3, selected.count == n, labels.count == n,
              sourceContrast.isFinite, sourceContrast >= 16, sourceContrast <= 64,
              masks.entries.count <= 256 else { return abstain("invalid-source-geometry-or-budget") }
        var total = 0
        for entry in masks.entries {
            guard entry.mask.count <= 1_500_000, total <= 24_000_000 - entry.mask.count else { return abstain("witness-work-budget") }
            total += entry.mask.count
        }
        var result = Exemptions(), accepted = 0, skipped = 0, packedBytes = 0
        for entry in masks.entries {
            guard let seed = entry.positiveSourceSeed,
                  seed.request.original === original, seed.request.regions == actualRequest.regions,
                  seed.sourceIdentity == sourceIdentity, seed.crop == entry.crop,
                  seed.producerPolicySHA256 == masks.policySHA256 else { skipped += 1; continue }
            let matching = owners.filter { NativeSelectedSourceSegmentationMasks.same(entry.ownerPolygon, $0.polygon) }
            guard matching.count == 1, let owner = matching.first, owner.background.count == 3,
                  owner.background.allSatisfy({ $0.isFinite && (0...255).contains($0) }) else { skipped += 1; continue }
            let crop = entry.crop
            guard [crop.minX, crop.minY, crop.width, crop.height].allSatisfy(\.isFinite),
                  crop.width > 0, crop.height > 0, crop.width <= 1_500_000 / crop.height else { skipped += 1; continue }
            let cw = Int(crop.width), ch = Int(crop.height)
            guard crop == crop.integral, cw > 0, ch > 0, crop.minX >= 0, crop.minY >= 0,
                  crop.maxX <= Double(w), crop.maxY <= Double(h), entry.mask.count == cw * ch,
                  seed.bits.count == (cw * ch + 7) / 8 else { skipped += 1; continue }
            packedBytes += seed.bits.count
            let x0 = Int(crop.minX), y0 = Int(crop.minY)
            for k in 0..<(cw * ch) where seed.bits[k / 8] & UInt8(1 << (k % 8)) != 0 && entry.mask[k] != 0 {
                let q = (y0 + k / cw) * w + x0 + k % cw
                //255 is independently hard; only weak label1 may defer. No
                //polygon/bbox clipping and no pixels outside selected are added.
                guard labels[q] == 1, selected[q] != 0 else { continue }
                let p = q * 3
                let contrast = (0..<3).map { abs(Double(rgb[p + $0]) - owner.background[$0]) }.max()!
                guard contrast >= sourceContrast else { continue }
                if result.bits.isEmpty { result.bits = [UInt8](repeating: 0, count: (n + 7) / 8) }
                if !result.contains(q) { result.bits[q / 8] |= UInt8(1 << (q % 8)); accepted += 1 }
            }
        }
        return .init(exemptions: result, audit: ["enabled": true, "status": "source-backed-over-model-estimate",
            "exemptedPixels": accepted, "skippedEntries": skipped, "packedWitnessBytes": packedBytes,
            "exemptionBitsetBytes": result.bits.count, "sourceContrast": sourceContrast,
            "ownerPolygonClipping": false, "newErasureProposal": false, "independentGlyphCertificate": false,
            "hardPrecedence": "explicit-preserved/frame/contoured-SFX/genuine-source-boundaries"])
    }
}
