import CoreGraphics
import Foundation

/// Standalone production-helper regression. Compile with the actual policy,
/// selected-mask carrier, and extracted old/current protection raster kernels.
@main enum NativeSourceBackedRFProtectionTests {
    static func image(_ w: Int = 32, _ h: Int = 32) -> CGImage {
        let bytes = Data(repeating: 220, count: w * h * 3)
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: w * 3,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: CGDataProvider(data: bytes as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    static func main() throws {
        typealias Policy = NativeSourceBackedRFProtection
        var checks = 0
        func check(_ condition: Bool, _ message: String) { precondition(condition, message); checks += 1 }
        let original = image(), n = 32 * 32, source = "same-original-pixels"
        let polygon = [CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 10), CGPoint(x: 20, y: 20), CGPoint(x: 10, y: 20)]
        let weak = Ensemble100RFRegion(queryID: 4, classID: 1, confidence: 0.9,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1), exterior: [], holes: [])
        let crop = CGRect(x: 0, y: 0, width: 32, height: 32)
        var selected = [UInt8](repeating: 0, count: n), raw = selected, rgb = [UInt8](repeating: 220, count: n * 3)
        let inside = 15 * 32 + 15, outside = 15 * 32 + 9, hard = 15 * 32 + 16, lowContrast = 15 * 32 + 17
        for k in [inside, outside, hard, lowContrast] {
            selected[k] = 255; raw[k] = 1
            if k != lowContrast { for c in 0..<3 { rgb[k * 3 + c] = 20 } }
        }
        let flag = "AIDOKU_SOURCE_BACKED_RF_PROTECTION", prior = getenv("AIDOKU_SOURCE_BACKED_RF_PROTECTION").map { String(cString: $0) }
        let simpleFlag = "AIDOKU_FINAL_RF_PROTECTION_POLICY"
        let priorSimple = getenv("AIDOKU_FINAL_RF_PROTECTION_POLICY").map { String(cString: $0) }
        defer { if let priorSimple { setenv(simpleFlag, priorSimple, 1) } else { unsetenv(simpleFlag) } }
        unsetenv(simpleFlag)
        defer { if let prior { setenv(flag, prior, 1) } else { unsetenv(flag) } }
        unsetenv(flag)
        check(Policy.cacheProjection.isEmpty && Policy.request(original: original, regions: [weak]) == nil, "absent means no request/cache change")
        setenv(flag, "0", 1)
        check(Policy.cacheProjection.isEmpty && Policy.request(original: original, regions: [weak]) == nil, "OFF means no request/cache change")
        var work = 0
        check(Policy.pack(rawNative: [], selected: [], crop: .null, sourceIdentity: "", original: original,
            request: nil, work: &work) == nil && work == 0, "nil/off skips malformed arrays without scan/packing")
        setenv(flag, "1", 1)
        check(!Policy.cacheProjection.isEmpty, "enabled final policy has separate cache projection")
        let request = Policy.request(original: original, regions: [weak])!
        let seed = Policy.pack(rawNative: raw, selected: selected, crop: crop, sourceIdentity: source,
            original: original, request: request, work: &work)!
        check(seed.bits.count == (n + 7) / 8 && work == n, "one bit per crop pixel with bounded work")
        var labels = [UInt8](repeating: 1, count: n); labels[hard] = 255
        let owner = Policy.Owner(polygon: polygon, background: [220, 220, 220])
        func evaluate(_ witness: Policy.PackedSeed?, image: CGImage? = nil, identity: String = source,
                      regions: [Ensemble100RFRegion] = [weak], evidenceOwner: Policy.Owner? = nil) -> Policy.Result {
            let masks = NativeSelectedSourceSegmentationMasks(original: original,
                entries: [.init(ownerPolygon: polygon, crop: crop, mask: selected, positiveSourceSeed: witness)])
            return Policy.evaluate(original: image ?? original, sourceIdentity: identity, rgb: rgb, selected: selected,
                labels: labels, masks: masks, owners: [evidenceOwner ?? owner], regions: regions, sourceContrast: 32)
        }
        let result = evaluate(seed)
        check(result.exemptions.contains(inside), "selected + primary + original contrast defeats weak box")
        check(result.exemptions.contains(outside), "source support outside owner polygon is not bbox clipped")
        check(!result.exemptions.contains(hard), "hard keepout always wins, including real certified boundaries")
        check(!result.exemptions.contains(lowContrast), "predicted seed without RGB contrast is insufficient")
        check(!result.exemptions.contains(0), "never invents erasure outside selected")
        check(evaluate(nil).audit["exemptedPixels"] as? Int == 0, "missing witness abstains")
        check(evaluate(seed, identity: "different").audit["exemptedPixels"] as? Int == 0, "source pixel identity mismatch abstains")
        check(evaluate(seed, image: image()).audit["exemptedPixels"] as? Int == 0, "same-looking other source object abstains")
        var changed = weak
        changed = .init(queryID: 5, classID: 1, confidence: 0.9, bounds: weak.bounds, exterior: [], holes: [])
        check(evaluate(seed, regions: [changed]).audit["exemptedPixels"] as? Int == 0, "different actual RF request abstains")
        check(evaluate(seed, evidenceOwner: .init(polygon: polygon, background: [.nan, 220, 220])).audit["exemptedPixels"] as? Int == 0,
            "unknown original background abstains")
        var budget = 24_000_000
        check(Policy.pack(rawNative: raw, selected: selected, crop: crop, sourceIdentity: source, original: original,
            request: request, work: &budget) == nil && budget == 24_000_000, "existing page-work budget retained")
        var emptyWork = 0
        check(Policy.pack(rawNative: raw, selected: selected, crop: crop, sourceIdentity: source, original: image(),
            request: request, work: &emptyWork) == nil && emptyWork == 0, "pack binds exact original object")
        let ring = [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.2), CGPoint(x: 0.8, y: 0.8), CGPoint(x: 0.2, y: 0.8)]
        let contouredSFX = Ensemble100RFRegion(queryID: 8, classID: 1, confidence: 0.9, bounds: weak.bounds, exterior: ring, holes: [])
        let frame = Ensemble100RFRegion(queryID: 9, classID: 3, confidence: 0.9, bounds: weak.bounds, exterior: ring, holes: [])
        let balloon = Ensemble100RFRegion(queryID: 10, classID: 2, confidence: 0.9, bounds: weak.bounds, exterior: ring, holes: [])
        check(!Policy.isWeak(contouredSFX), "contoured RF SFX remains hard as policy, not falsely called certified")
        check(!Policy.isWeak(frame), "frame remains hard")
        check(Policy.isWeak(balloon), "RF-only balloon contour is an estimate")
        setenv(simpleFlag, "simple-hard", 1)
        check(Policy.simpleHardConstraintsEnabled && !Policy.runtimeEnabled, "simple policy replaces, not combines with source-backed exceptions")
        check(Policy.request(original: original, regions: [weak, balloon]) == nil, "simple mode does not request primary witness or scan source arrays")
        check(Policy.cacheProjection == ["finalRFProtectionPolicy": "preserved-owner-contours-no-sfx-box-v1"], "simple mode has an explicit cache identity")
        check(Policy.simpleRegions([weak, contouredSFX, frame, balloon]).map(\.queryID) == [8, 9, 10],
            "simple baseline removes only SFX boxes; explicit contour hard policy is retained")
        let simpleKeepout = try CurrentProtection.protection(owners: [.init(id: "explicit-keep", polygon: polygon, translated: false)],
            rf: Policy.simpleRegions([weak]), w: 32, h: 32)
        var simpleMask = selected
        _ = CurrentProtection.applyFinalProtection(mask: &simpleMask, blocked: simpleKeepout, hard: nil, exemptions: [])
        check(simpleMask[inside] == 0 && simpleMask[outside] == 255,
            "simple baseline preserves explicit owner while retaining selected support outside its polygon")
        setenv(simpleFlag, "owner-majority", 1)
        check(Policy.simpleHardConstraintsEnabled && Policy.ownerMajorityComponentsEnabled && !Policy.runtimeEnabled,
            "component owner admission retains simple contour policy and disables old witness exceptions")
        check(Policy.cacheProjection == ["finalRFProtectionPolicy": "preserved-contours-owner-majority-components-v1"],
            "owner component candidate has a distinct cache identity")
        var componentSeed = [UInt8](repeating: 0, count: n)
        for x in 9...10 { componentSeed[15 * 32 + x] = 255 }
        for x in 18...22 { componentSeed[12 * 32 + x] = 255 }
        componentSeed[2 * 32 + 2] = 255
        let originalComponentSeed = componentSeed
        let admitted = Policy.admitOwnerMajorityComponents(mask: componentSeed, width: 32, height: 32, localPolygon: polygon)!
        check(admitted.mask[15 * 32 + 9] == 255 && admitted.mask[15 * 32 + 10] == 255,
            "exact-half component keeps its whole outside tail, not polygon clipped")
        check((18...22).allSatisfy { admitted.mask[12 * 32 + $0] == 0 },
            "minority-owned component is omitted whole, including its owned portion")
        check(admitted.mask[2 * 32 + 2] == 0 && componentSeed == originalComponentSeed,
            "unowned component omitted without mutating source NN bytes")
        check(admitted.audit["components"] as? Int == 3 && admitted.audit["keptComponents"] as? Int == 1,
            "component audit distinguishes retained and omitted groups")
        let componentMasks = NativeSelectedSourceSegmentationMasks(original: original,
            entries: [.init(ownerPolygon: polygon, crop: crop, mask: componentSeed)])
        check(componentMasks.policySHA256 == NativeSourceSegmentationExecution.erasurePolicySHA256,
            "final mask carrier binds erasure policy, not rich feature observation policy")
        typealias Masks = NativeSelectedSourceSegmentationMasks
        let decodedOriginal = try NativeRFDETRSourceImage.decode(original)
        let identityToken = Masks.ProducerIdentity(producerOriginal: original, decodedSource: decodedOriginal)!
        let attestedMasks = Masks(original: original, entries: componentMasks.entries, producerIdentity: identityToken)
        check(attestedMasks.validatedProducerIdentity(for: original) == decodedOriginal.identity,
            "live typed producer identity binds exact original object and canonical source dimensions/hash")
        let otherOriginal = image()
        check(attestedMasks.validatedProducerIdentity(for: otherOriginal) == nil,
            "same-looking different original object cannot reuse producer identity")
        let rebound = Masks(original: otherOriginal, entries: componentMasks.entries, producerIdentity: identityToken)
        check(rebound.validatedProducerIdentity(for: otherOriginal) == nil,
            "rebinding carrier cannot transfer a token to a different original")
        let differentShape = try NativeRFDETRSourceImage(width: 31, height: 32, rgb: Data(repeating: 220, count: 31 * 32 * 3))
        check(Masks.ProducerIdentity(producerOriginal: original, decodedSource: differentShape) == nil,
            "different decoded dimensions cannot attest original identity")
        do {
            _ = try NativeRFDETRSourceImage(width: 32, height: 32, rgb: Data(repeating: 220, count: 1))
            check(false, "malformed canonical RGB shape must not enter a typed identity")
        } catch { check(true, "malformed canonical RGB byte count rejected") }
        check(!Masks.isCanonicalProducerSHA256(String(repeating: "g", count: 64)) &&
            !Masks.isCanonicalProducerSHA256(String(repeating: "A", count: 64)) &&
            !Masks.isCanonicalProducerSHA256(String(repeating: "a", count: 63)) &&
            Masks.isCanonicalProducerSHA256(identityToken.canonicalRGBSHA256),
            "only canonical lowercase SHA256 values admitted; caller strings cannot construct tokens")
        var identityDecodeCalls = 0
        let reusedIdentity = try Masks.resolveSourceIdentity(original: original, selectedMasks: attestedMasks, rgbConsumers: []) {
            identityDecodeCalls += 1
            return try NativeRFDETRSourceImage.decode(original).identity
        }
        check(reusedIdentity.producerIdentityReused && identityDecodeCalls == 0 &&
            reusedIdentity.authority == "producer-attested-canonical-rgb-same-original",
            "RGB-free path skips actual redundant decode/hash and labels producer authority truthfully")
        for bits in UInt8(1)...UInt8(31) {
            let previousCalls = identityDecodeCalls
            let independentlyDecoded = try Masks.resolveSourceIdentity(original: original, selectedMasks: attestedMasks,
                rgbConsumers: .init(rawValue: bits)) {
                    identityDecodeCalls += 1
                    return try NativeRFDETRSourceImage.decode(original).identity
                }
            check(!independentlyDecoded.producerIdentityReused && identityDecodeCalls == previousCalls + 1 &&
                independentlyDecoded.identity == identityToken.canonicalRGBSHA256,
                "every legacy/witness/fringe/glyph/generated RGB consumer combination forces the real decode")
        }
        let nilPrevious = identityDecodeCalls
        let nilIdentity = try Masks.resolveSourceIdentity(original: original, selectedMasks: componentMasks, rgbConsumers: []) {
            identityDecodeCalls += 1
            return try NativeRFDETRSourceImage.decode(original).identity
        }
        check(!nilIdentity.producerIdentityReused && identityDecodeCalls == nilPrevious + 1,
            "default nil producer token preserves independent decode behavior")
        let reboundPrevious = identityDecodeCalls
        let reboundIdentity = try Masks.resolveSourceIdentity(original: otherOriginal, selectedMasks: rebound, rgbConsumers: []) {
            identityDecodeCalls += 1
            return try NativeRFDETRSourceImage.decode(otherOriginal).identity
        }
        check(!reboundIdentity.producerIdentityReused && identityDecodeCalls == reboundPrevious + 1,
            "invalid original binding falls back to real source decode, not a fabricated source")
        check(try attestedMasks.resolve(original: original, translatedPolygons: [polygon], admitOwnerMajorityComponents: true).mask == admitted.mask,
            "producer identity optimization cannot alter final owner component mask pixels")
        let defaultResolve = try componentMasks.resolve(original: original, translatedPolygons: [polygon])
        let admittedResolve = try componentMasks.resolve(original: original, translatedPolygons: [polygon], admitOwnerMajorityComponents: true)
        check(defaultResolve.mask == componentSeed && admittedResolve.mask == admitted.mask,
            "final union admission is explicit opt-in, selected carrier default remains byte-identical")
        var diagonal = [UInt8](repeating: 0, count: n); diagonal[9 * 32 + 9] = 255; diagonal[10 * 32 + 10] = 255
        check(Policy.admitOwnerMajorityComponents(mask: diagonal, width: 32, height: 32, localPolygon: polygon)!.mask == diagonal,
            "diagonal contact uses8-connectivity and keeps whole half-owned component")
        check(Policy.admitOwnerMajorityComponents(mask: [], width: 32, height: 32, localPolygon: polygon) == nil,
            "invalid mask cannot become fabricated empty successful output")
        var afterPreservation = admitted.mask
        _ = CurrentProtection.applyFinalProtection(mask: &afterPreservation, blocked: simpleKeepout, hard: nil, exemptions: [])
        check(afterPreservation[15 * 32 + 10] == 0 && afterPreservation[15 * 32 + 9] == 255,
            "explicit preserved-owner keepout still wins after whole-component admission")
        setenv(simpleFlag, "owner-majority-no-frame", 1)
        check(Policy.ownerMajorityComponentsEnabled && Policy.estimatedFrameBoundaryDisabled && !Policy.runtimeEnabled,
            "combined candidate keeps bounded owner admission, not legacy witness exceptions")
        check(Policy.finalRegions([weak, contouredSFX, frame, balloon]).map(\.queryID) == [8, 10],
            "combined candidate drops only weak SFX boxes and estimated model frame strokes, not balloon or SFX contours")
        check(Policy.cacheProjection == ["finalRFProtectionPolicy": "preserved-balloon-sfx-owner-majority-no-model-frame-v1"],
            "combined candidate cannot collide with either simple or all-contour owner cache")
        let combinedKeepout = try CurrentProtection.protection(owners: [.init(id: "explicit-keep", polygon: polygon, translated: false)],
            rf: Policy.finalRegions([weak, frame]), w: 32, h: 32)
        check(combinedKeepout == simpleKeepout, "removing model frame does not remove explicit preserved-owner raster")
        unsetenv(simpleFlag)
        check(Policy.request(original: original, regions: [frame, contouredSFX]) == nil, "no weak RF means no request/packing")
        setenv(flag, "0", 1)
        emptyWork = 0
        check(Policy.pack(rawNative: raw, selected: selected, crop: crop, sourceIdentity: source, original: original,
            request: request, work: &emptyWork) == nil && emptyWork == 0, "OFF ignores even an older ON request")
        setenv(flag, "1", 1)
        // Compare actual CGContext raster kernels, including overlaps/hole paths
        // and noninteger coordinates. New labels remain a private bitmap ABI.
        var state: UInt64 = 20261117
        func random() -> Double { state = state &* 6364136223846793005 &+ 1; return Double(state >> 11) / Double(UInt64.max >> 11) }
        for _ in 0..<80 {
            let x = random() * 0.4, y = random() * 0.4, width = 0.2 + random() * 0.4, height = 0.2 + random() * 0.4
            let r = [CGPoint(x: x, y: y), CGPoint(x: x + width, y: y), CGPoint(x: x + width, y: y + height), CGPoint(x: x, y: y + height)]
            let regions = [weak, frame, contouredSFX, .init(queryID: 11, classID: 2, confidence: 0.85,
                bounds: CGRect(x: x, y: y, width: width, height: height), exterior: r, holes: [ring])]
            let old = try FrozenProtection.protection(owners: [.init(id: "keep", polygon: polygon, translated: false)], rf: regions, w: 32, h: 32)
            let current = try CurrentProtection.protection(owners: [.init(id: "keep", polygon: polygon, translated: false)],
                rf: regions, w: 32, h: 32, classifyWeak: true)
            check(old == current.map { $0 == 0 ? 0 : 255 }, "label union exactly equals old raster")
            check(current.allSatisfy { $0 == 0 || $0 == 1 || $0 == 255 }, "label ABI has only0/1/255")
        }
        var protectedMask = selected
        _ = CurrentProtection.applyFinalProtection(mask: &protectedMask, blocked: labels, hard: nil,
            exemptions: [hard], weakLabels: true, sourceExemptions: result.exemptions)
        check(protectedMask[hard] == 0 && protectedMask[inside] == 255 && protectedMask[outside] == 255,
            "final operation protects hard pixels even if another exemption asks otherwise")
        print("SOURCE_BACKED_RF_PROTECTION_PASS checks=\(checks) models=0")
    }
}
