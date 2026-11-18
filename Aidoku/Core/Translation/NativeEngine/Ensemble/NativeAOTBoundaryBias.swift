import Foundation

/// Original unmasked context calibrates model RGB, never original masked ink.
/// Does not change masks, source predictions, typography or display palettes.
enum NativeAOTBoundaryBias {
    static let policyVersion = "original-unmasked-flat-ring-v1"
    static let noNewSaturationPolicy = "original-unmasked-flat-ring-no-new-saturation-v1"
    static func policy(meanClamp: Int?, rejectNewSaturation: Bool = false) -> String {
        if rejectNewSaturation { return noNewSaturationPolicy }
        return meanClamp.map { "original-unmasked-flat-ring-mean-clamp\($0)-v1" } ?? policyVersion
    }
    static func supportedPolicy(_ value: String?) -> Bool {
        value == nil || value == policyVersion || value == noNewSaturationPolicy
            || value == policy(meanClamp: 8) || value == policy(meanClamp: 16)
    }
    static func validConfiguration(enabled: Bool, meanClamp: Int?, rejectNewSaturation: Bool) -> Bool {
        if rejectNewSaturation { return enabled && meanClamp == nil }
        return meanClamp == nil || (enabled && (meanClamp == 8 || meanClamp == 16))
    }
    struct Region {
        let pixels: [Int]
        let ring: [Int]
    }
    struct Plan {
        let samplingMask: [UInt8]
        let regions: [Region]
        let audit: [String: Any]
    }

    static func prepare(source: [UInt8], mask: [UInt8], width: Int, height: Int) -> Plan? {
        guard let validatedMask = try? NativeAOTValidatedMask(validating: mask, width: width,
            height: height, domain: .logical01Or255) else { return nil }
        return prepare(source: source, validatedMask: validatedMask)
    }

    static func prepare(source: [UInt8], validatedMask: NativeAOTValidatedMask) -> Plan? {
        let width = validatedMask.width, height = validatedMask.height, mask = validatedMask.bytes
        guard source.count == width * height * 3 else { return nil }
        // This bounds optional scratch, not extraction or translation quality.
        // Large masks keep the unchanged AOT result and expose the bypass.
        let count = validatedMask.foregroundCount
        guard count > 0, count <= 262_144 else { return nil }
        var seen = [UInt8](repeating: 0, count: mask.count)
        var regions: [Region] = [], sampling = mask
        var components = 0, nonflat = 0, insufficient = 0, edge = 0
        for start in mask.indices where mask[start] != 0 && seen[start] == 0 {
            components += 1
            var pixels = [start], next = 0
            seen[start] = 1
            var touchesEdge = false
            while next < pixels.count {
                let p = pixels[next], x = p % width, y = p / width
                next += 1
                if x < 2 || y < 2 || x >= width - 2 || y >= height - 2 { touchesEdge = true }
                for yy in max(0, y - 1)...min(height - 1, y + 1) {
                    for xx in max(0, x - 1)...min(width - 1, x + 1) {
                        let q = yy * width + xx
                        if mask[q] != 0 && seen[q] == 0 { seen[q] = 1; pixels.append(q) }
                    }
                }
            }
            if touchesEdge { edge += 1; continue }
            var ringSet = Set<Int>()
            for p in pixels {
                let x = p % width, y = p / width
                for dy in -2...2 {
                    let reach = 2 - abs(dy), yy = y + dy
                    guard yy >= 0 && yy < height else { continue }
                    for dx in -reach...reach {
                        let xx = x + dx
                        guard xx >= 0 && xx < width else { continue }
                        let q = yy * width + xx
                        if mask[q] == 0 { ringSet.insert(q) }
                    }
                }
            }
            guard ringSet.count >= 12 else { insufficient += 1; continue }
            let ring = ringSet.sorted()
            var minimum = [255, 255, 255], maximum = [0, 0, 0]
            for p in ring { for c in 0..<3 {
                minimum[c] = min(minimum[c], Int(source[p * 3 + c]))
                maximum[c] = max(maximum[c], Int(source[p * 3 + c]))
            } }
            guard (0..<3).allSatisfy({ maximum[$0] - minimum[$0] <= 2 }) else { nonflat += 1; continue }
            for p in ring { sampling[p] = 255 }
            regions.append(Region(pixels: pixels, ring: ring))
        }
        return Plan(samplingMask: sampling, regions: regions, audit: [
            "components": components, "sourceFlatRegions": regions.count, "sourceNonflatRegions": nonflat,
            "insufficientContextRegions": insufficient, "edgeRegions": edge,
            "sourceSpreadMaximum": 2, "ringDistanceSourcePixels": 2, "minimumRingSamples": 12,
            "maskPixelCount": count, "optionalScratchMaskPixelLimit": 262_144])
    }

    static func apply(source: [UInt8], predicted: [UInt8], mask: [UInt8], plan: Plan) -> (rgb: [UInt8], audit: [String: Any]) {
        var output = predicted
        let audit = applyInPlace(source: source, predicted: &output, mask: mask, plan: plan)
        return (output, audit)
    }

    /// Production owns this already-composed RGB buffer. Avoid another complete
    /// page-sized COW allocation; exterior rings stay untouched until all votes.
    static func applyInPlace(source: [UInt8], predicted: inout [UInt8], mask: [UInt8], plan: Plan,
                             rejectNewSaturation: Bool = false) -> [String: Any] {
        precondition(source.count == predicted.count && source.count == mask.count * 3)
        var records: [[String: Any]] = []
        var correctedRegions = 0, correctedPixels = 0, admittedRegions = 0, admittedPixels = 0
        // A guarded page publishes all median corrections or the original prediction.
        // Stage only masked RGB bytes, bounded by the plan's foreground limit.
        var deferredCorrections: [(pixels: [Int], rgb: [UInt8])] = []
        var saturationRejected = false
        regions: for region in plan.regions {
            var bias = [Double](repeating: 0, count: 3), minimum = [255, 255, 255], maximum = [-255, -255, -255]
            for c in 0..<3 {
                var histogram = [Int](repeating: 0, count: 511)
                for p in region.ring {
                    let delta = Int(source[p * 3 + c]) - Int(predicted[p * 3 + c])
                    histogram[delta + 255] += 1
                    minimum[c] = min(minimum[c], delta); maximum[c] = max(maximum[c], delta)
                }
                let lower = (region.ring.count - 1) / 2, upper = region.ring.count / 2
                var cumulative = 0, a: Int?, b: Int?
                for i in histogram.indices {
                    cumulative += histogram[i]
                    if a == nil && cumulative > lower { a = i - 255 }
                    if cumulative > upper { b = i - 255; break }
                }
                bias[c] = Double(a! + b!) / 2
            }
            let deviation = (0..<3).map { max(abs(Double(minimum[$0]) - bias[$0]), abs(Double(maximum[$0]) - bias[$0])) }.max()!
            let accepted = deviation <= 6 && bias.allSatisfy { abs($0) <= 16 }
            var changed = 0
            if accepted {
                admittedRegions += 1; admittedPixels += region.pixels.count
                var deferredRGB: [UInt8] = []
                if rejectNewSaturation { deferredRGB.reserveCapacity(region.pixels.count * 3) }
                for p in region.pixels {
                    var differs = false
                    for c in 0..<3 {
                        let index = p * 3 + c, original = predicted[index]
                        let value = UInt8(max(0, min(255, floor(Double(original) + bias[c] + 0.5))))
                        if rejectNewSaturation {
                            if original > 0 && original < 255 && (value == 0 || value == 255) {
                                saturationRejected = true
                                break regions
                            }
                            deferredRGB.append(value)
                        } else { predicted[index] = value }
                        differs = differs || value != original
                    }
                    if differs { changed += 1 }
                }
                if changed > 0 {
                    correctedRegions += 1; correctedPixels += changed
                    if rejectNewSaturation { deferredCorrections.append((region.pixels, deferredRGB)) }
                }
            }
            if records.count < 128 {
                records.append(["accepted": accepted, "pixels": region.pixels.count, "ringSamples": region.ring.count,
                    "biasRGB": bias, "changedPixels": changed, "maximumResidualSpread": deviation])
            }
        }
        // Do this only AFTER evaluating every region. Shared exterior samples
        // must never see an earlier region's restored context instead of raw NN.
        for region in plan.regions { for p in region.ring { for c in 0..<3 { predicted[p * 3 + c] = source[p * 3 + c] } } }
        if !saturationRejected {
            for correction in deferredCorrections {
                for (offset, pixel) in correction.pixels.enumerated() {
                    for c in 0..<3 { predicted[pixel * 3 + c] = correction.rgb[offset * 3 + c] }
                }
            }
        }
        var audit = plan.audit
        audit["correctedRegions"] = saturationRejected ? 0 : correctedRegions
        audit["correctedPixels"] = saturationRejected ? 0 : correctedPixels
        audit["admittedRegions"] = saturationRejected ? 0 : admittedRegions
        audit["admittedMaskPixels"] = saturationRejected ? 0 : admittedPixels
        audit["countSemantics"] = "corrected means actual RGB changed, not merely accepted or zero bias"
        audit["regions"] = saturationRejected ? [] : records
        audit["regionRecordsTruncated"] = !saturationRejected && plan.regions.count > records.count
        audit["policy"] = policy(meanClamp: nil, rejectNewSaturation: rejectNewSaturation)
        if rejectNewSaturation { audit["newSaturationRejected"] = saturationRejected }
        audit["maximumBias"] = 16; audit["maximumResidualSpread"] = 6
        audit["authority"] = "source/model exterior discrepancy estimate; not background gold or complete source removal proof"
        return audit
    }

    /// Optional SIMPLE-restoration family: no511-bin histograms, residual
    /// spread veto or magnitude-admission branches. Fixed8/16 grid only; root
    /// selects/fixes the cap through TRAIN source-group CV before DEV/E2E.
    /// Contextual continuity remains a proxy, never clean hidden-background GT.
    static func applyMeanInPlace(source: [UInt8], predicted: inout [UInt8], mask: [UInt8],
                                 plan: Plan, maximumBias: Int) -> [String: Any] {
        precondition((maximumBias == 8 || maximumBias == 16) && source.count == predicted.count && source.count == mask.count * 3)
        let limit = Double(maximumBias)
        var changedPixels = 0
        for region in plan.regions {
            var sums = [Int64](repeating: 0, count: 3)
            for p in region.ring { for c in 0..<3 { sums[c] += Int64(source[p * 3 + c]) - Int64(predicted[p * 3 + c]) } }
            let bias = sums.map { max(-limit, min(limit, Double($0) / Double(region.ring.count))) }
            for p in region.pixels {
                var changed = false
                for c in 0..<3 {
                    let value = UInt8(max(0, min(255, floor(Double(predicted[p * 3 + c]) + bias[c] + 0.5))))
                    changed = changed || value != predicted[p * 3 + c]; predicted[p * 3 + c] = value
                }
                if changed { changedPixels += 1 }
            }
        }
        for region in plan.regions { for p in region.ring { for c in 0..<3 { predicted[p * 3 + c] = source[p * 3 + c] } } }
        var audit = plan.audit
        audit["policy"] = policy(meanClamp: maximumBias)
        audit["meanResidualNotMedian"] = true; audit["residualSpreadVetoRemoved"] = true
        audit["biasMagnitudeVetoRemoved"] = true; audit["channelOffsetClamp"] = maximumBias
        audit["changedPixels"] = changedPixels; audit["flatSourcePlanRetained"] = true
        audit["authority"] = "observed source-flat context/model residual proxy; clean background and actual final-owner quality unknown"
        return audit
    }
}
