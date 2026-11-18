import CoreGraphics
import Foundation

/// Fresh predicted OWN masks from the selected source-only policy, bound to the
/// same upright original object and immutable erasure-owner geometry. No disk lookup.
struct NativeSelectedSourceSegmentationMasks {
    /// Created only from the live producer's typed canonical RGB observation,
    /// never a render-item/caller string. Keeps the SAME original object alive;
    /// it does not retain the large decoded RGB buffer. This is producer
    /// attestation, not an independent rehash of the image at final erasure.
    struct ProducerIdentity {
        fileprivate let original: CGImage
        fileprivate let width: Int
        fileprivate let height: Int
        let canonicalRGBSHA256: String

        init?(producerOriginal: CGImage, decodedSource: NativeRFDETRSourceImage) {
            let w = decodedSource.width, h = decodedSource.height
            guard w > 0, h > 0, w <= 16_384, h <= 16_384, w <= 16_777_216 / h,
                  producerOriginal.width == w, producerOriginal.height == h,
                  decodedSource.rgb.count == w * h * 3 else { return nil }
            let identity = decodedSource.identity
            guard NativeSelectedSourceSegmentationMasks.isCanonicalProducerSHA256(identity) else { return nil }
            original = producerOriginal; width = w; height = h; canonicalRGBSHA256 = identity
        }
    }
    struct RGBConsumers: OptionSet, Sendable {
        let rawValue: UInt8
        static let legacyFactory = Self(rawValue: 1)
        static let sourceWitness = Self(rawValue: 2)
        static let connectedFringe = Self(rawValue: 4)
        static let glyphBoundary = Self(rawValue: 8)
        static let generatedErasure = Self(rawValue: 16)
    }
    struct SourceIdentityResolution: Sendable {
        let identity: String
        let authority: String
        let producerIdentityReused: Bool
    }
    struct Entry {
        let ownerPolygon: [CGPoint] // Actual removal owner's page-pixel polygon.
        let crop: CGRect // Original-resolution page-pixel inference crop.
        let mask: [UInt8] // Full predicted crop, never clipped to owner bbox/polygon.
        var positiveSourceSeed: NativeSourceBackedRFProtection.PackedSeed? = nil
    }
    enum Failure: Error { case invalidSource, invalidMask }
    let original: CGImage
    let entries: [Entry]
    let policySHA256: String
    let producerIdentity: ProducerIdentity?

    init(original: CGImage, entries: [Entry], producerIdentity: ProducerIdentity? = nil) {
        self.original = original
        self.entries = entries
        self.producerIdentity = producerIdentity
        policySHA256 = NativeSourceSegmentationExecution.erasurePolicySHA256
    }

    static func isCanonicalProducerSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    func validatedProducerIdentity(for source: CGImage) -> String? {
        guard source === original, let producerIdentity, producerIdentity.original === source,
              producerIdentity.width == source.width, producerIdentity.height == source.height,
              source.width > 0, source.height > 0, source.width <= 16_384, source.height <= 16_384,
              source.width <= 16_777_216 / source.height,
              Self.isCanonicalProducerSHA256(producerIdentity.canonicalRGBSHA256) else { return nil }
        return producerIdentity.canonicalRGBSHA256
    }

    /// Every RGB consumer must be absent before this optimization is allowed.
    /// The fallback closure is the original real decode/hash path, not a dummy
    /// RGB source. Composition/input RGBA verification remains outside this API.
    static func resolveSourceIdentity(original: CGImage, selectedMasks: Self?, rgbConsumers: RGBConsumers,
                                      decode: () throws -> String) rethrows -> SourceIdentityResolution {
        if rgbConsumers.isEmpty, let identity = selectedMasks?.validatedProducerIdentity(for: original) {
            return .init(identity: identity, authority: "producer-attested-canonical-rgb-same-original",
                producerIdentityReused: true)
        }
        return .init(identity: try decode(), authority: "independently-decoded-and-rehashed-canonical-rgb",
            producerIdentityReused: false)
    }

    /// Complete owner coverage is required before replacing the legacy union.
    /// Missing owners never erase their source through another owner's crop.
    func resolve(original source: CGImage, translatedPolygons: [[CGPoint]],
                 admitOwnerMajorityComponents: Bool = false) throws -> (mask: [UInt8]?, audit: [String: Any]) {
        guard source === original, source.width > 0, source.height > 0,
              source.width <= 16_777_216 / source.height,
              policySHA256 == NativeSourceSegmentationExecution.erasurePolicySHA256,
              entries.count <= 256, translatedPolygons.count <= 256 else { throw Failure.invalidSource }
        let w = source.width, h = source.height
        var covered = Set<Int>(), pixels = 0
        for entry in entries {
            let r = entry.crop
            guard r.minX.isFinite, r.minY.isFinite, r.width.isFinite, r.height.isFinite,
                  r == r.integral, r.minX >= 0, r.minY >= 0, r.maxX <= CGFloat(w), r.maxY <= CGFloat(h),
                  r.width > 0, r.height > 0, r.width <= 1_500_000 / r.height,
                  (3...16).contains(entry.ownerPolygon.count),
                  entry.ownerPolygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
                  entry.mask.count == Int(r.width) * Int(r.height), entry.mask.allSatisfy({ $0 == 0 || $0 == 255 }),
                  pixels <= 24_000_000 - entry.mask.count else { throw Failure.invalidMask }
            pixels += entry.mask.count
            let matches = translatedPolygons.indices.filter { Self.same(entry.ownerPolygon, translatedPolygons[$0]) }
            guard matches.count == 1, let owner = matches.first, !covered.contains(owner) else {
                return (nil, audit(status: "incomplete-or-ambiguous-owner-geometry", covered: covered.count, expected: translatedPolygons.count))
            }
            covered.insert(owner)
        }
        guard !translatedPolygons.isEmpty, covered.count == translatedPolygons.count else {
            return (nil, audit(status: "incomplete-translated-owner-coverage", covered: covered.count, expected: translatedPolygons.count))
        }
        var union = [UInt8](repeating: 0, count: w * h)
        var componentAudit: [[String: Any]] = []
        for entry in entries {
            let cw = Int(entry.crop.width), ch = Int(entry.crop.height)
            let x0 = Int(entry.crop.minX), y0 = Int(entry.crop.minY)
            let admitted: [UInt8]
            if admitOwnerMajorityComponents {
                let local = entry.ownerPolygon.map { CGPoint(x: $0.x - entry.crop.minX, y: $0.y - entry.crop.minY) }
                guard let result = NativeSourceBackedRFProtection.admitOwnerMajorityComponents(mask: entry.mask,
                    width: cw, height: ch, localPolygon: local) else { throw Failure.invalidMask }
                admitted = result.mask; componentAudit.append(result.audit)
            } else { admitted = entry.mask }
            for y in 0..<ch { for x in 0..<cw where admitted[y * cw + x] != 0 {
                union[(y0 + y) * w + x0 + x] = 255
            } }
        }
        var finalAudit = audit(status: "selected-source-own-masks-before-final-protection", covered: covered.count, expected: translatedPolygons.count)
        if admitOwnerMajorityComponents { finalAudit["finalOwnerComponentAdmission"] = componentAudit }
        return (union, finalAudit)
    }

    private func audit(status: String, covered: Int, expected: Int) -> [String: Any] {
        ["policySHA256": policySHA256, "status": status, "executed": status == "selected-source-own-masks-before-final-protection",
         "coveredOwners": covered, "expectedOwners": expected, "sourceReferenceBound": true,
         "storedMaskLookup": false, "GTRead": false, "bboxMaskClipping": false]
    }
    static func same(_ a: [CGPoint], _ b: [CGPoint]) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return false }
        func near(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) <= 1e-7 && abs(a.y - b.y) <= 1e-7 }
        for start in b.indices where near(a[0], b[start]) {
            if a.indices.allSatisfy({ near(a[$0], b[(start + $0) % b.count]) }) ||
                a.indices.allSatisfy({ near(a[$0], b[(start - $0 + b.count) % b.count]) }) { return true }
        }
        return false
    }
}
