import Foundation

/// Opt-in arbitration of RF BALLOON contour strokes against already-produced
/// original glyph support. This never creates a mask from RF rectangles, edits
/// source ownership, or exempts a preserved/unknown owner or structural keepout.
enum NativeOwnedGlyphRFBoundaryProtection {
    /// Parent wiring (NativeMainAOTRemovalMaskBuilder, immediately before its
    /// final `blocked` loop):
    /// 1. Retain the factory `mask` BEFORE final protection. Require the actual
    ///    probability.original === original and measured original font/palette.
    /// 2. Rasterize hard = protection(owners: owners, rf: non-class-2 regions)
    ///    and balloon = protection(owners: [], rf: class-2 regions) independently.
    ///    Any additional veto belongs in hard. Never subtract from `blocked`.
    /// 3. For each translated owner, crop COMPLETE padded original RGB, factory,
    ///    hard, balloon, owner polygon and one unambiguous overlapping RF TEXT
    ///    support to the SAME ROI. Use Caller.raster for owner/text nomination;
    ///    do not clip original connected components to those nomination masks.
    ///    Sample the bound full DB grid with the caller's half-pixel bilinear
    ///    transform; cell area = original pixel count / DB cell count.
    ///    Pad owner bounds by ceil(fontPixels * 0.6) + 4 and intersect the canvas.
    ///    Select one finite class-0 detection with confidence >= 0.55 and owner
    ///    bbox overlap >= 35%; ambiguous nominations get no exemption. Obtain
    ///    backgroundRGB from factoryAudit["base"] for the SAME owner; optional
    ///    chromatic ink comes from factoryAudit["chroma"], never display colors.
    /// 4. Pass actual source/owner provenance (not newly stamped stale evidence).
    ///    Collect returned ROI indices as page indices, at most 131072/page and
    ///    12000000 total input ROI pixels/page. Missing evidence means no exemption.
    /// 5. In the final loop, hard ALWAYS wins; only bypass balloon at accepted
    ///    indices. Keep mask[k] == 0 as zero. `apply` is the exact ROI operation;
    ///    page wiring must use the same hard-first rule when unioning owners.
    /// 6. Record rejections/exemptions and bind changed mask to fresh AOT output.
    /// Parent checks runtimeEnabled; these pure functions are callable directly
    /// for synthetic tests. Invalid/stale evidence skips the owner; propagate
    /// CancellationError. Include this file in parent app/host source lists.
    /// No shared pipeline, source enumeration or host wiring is changed here.
    static var runtimeEnabled: Bool {
        ProcessInfo.processInfo.environment["AIDOKU_MASK_OWNED_GLYPH_RF_BOUNDARY"] == "1"
    }

    struct Input {
        let width: Int
        let height: Int
        let rgb: [UInt8]
        let owned: [UInt8]
        let factoryMask: [UInt8]
        /// Preserved/unknown OCR owners AND SFX/physical-structure keepouts.
        /// Must be built independently; never pass (union minus balloon mask).
        let hardProtection: [UInt8]
        /// RF balloon exterior/hole contour strokes ONLY, not any other veto.
        let balloonBoundary: [UInt8]
        let probability: [Float]
        /// One selected source-bound RF TEXT detection, nomination only.
        let textSupport: [UInt8]
        let background: [Double]
        let fontPixels: Double
        let sourceRevision: String
        let probabilitySourceRevision: String
        let ownerSourceRevision: String
        let factorySourceRevision: String
        let rfSourceRevision: String
        /// IDs identify the actual translated source polygon, not an RF query.
        let ownerID: String
        let factoryOwnerID: String
        let textSupportOwnerID: String
        let originalOpaque: Bool
        /// Optional already-observed ORIGINAL factory palette, never target ink.
        var chromaticInk: [Double]? = nil
        /// Original pixels per actual detector cell, from the bound DB geometry.
        var probabilityCellArea: Double = 1
    }

    struct Result {
        /// ROI-local indices. Caller may ignore ONLY balloonBoundary here;
        /// factoryMask and every hard keepout remain mandatory at final union.
        let boundaryExemptions: Set<Int>
        let acceptedComponents: Int
        let hardVetoComponents: Int
        let rejectionCounts: [String: Int]
        let dbRejectedComponentCounts: [[Int]]
    }

    enum Failure: Error { case invalidEvidence, staleSource, mismatchedOwner }

    /// Callable final protection operation for a single owner ROI. The returned
    /// mask remains a subset of the existing factory proposal. No original RGB
    /// or input mask is mutated. Hard protection wins even at RF intersections.
    static func apply(_ input: Input) throws -> (mask: [UInt8], audit: Result) {
        let audit = try evaluate(input)
        var mask = input.factoryMask
        for k in mask.indices {
            if input.hardProtection[k] != 0 ||
                (input.balloonBoundary[k] != 0 && !audit.boundaryExemptions.contains(k)) {
                mask[k] = 0
            } else {
                mask[k] = mask[k] == 0 ? 0 : 255
            }
        }
        return (mask, audit)
    }

    static func evaluate(_ input: Input) throws -> Result {
        let w = input.width, h = input.height
        guard w > 0, h > 0, w <= 1_000_000 / h else { throw Failure.invalidEvidence }
        let n = w * h
        guard input.rgb.count == n * 3,
              [input.owned, input.factoryMask, input.hardProtection, input.balloonBoundary,
               input.textSupport].allSatisfy({ $0.count == n }),
              input.probability.count == n,
              input.probability.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              input.background.count == 3, input.background.allSatisfy({ $0.isFinite && (0...255).contains($0) }),
              input.fontPixels.isFinite, input.fontPixels >= 2, input.fontPixels <= 512,
              input.probabilityCellArea.isFinite, input.probabilityCellArea >= 1,
              input.probabilityCellArea <= Double(n), input.originalOpaque else { throw Failure.invalidEvidence }
        if let ink = input.chromaticInk {
            guard ink.count == 3, ink.allSatisfy({ $0.isFinite && (0...255).contains($0) })
            else { throw Failure.invalidEvidence }
        }
        guard !input.sourceRevision.isEmpty, input.sourceRevision == input.probabilitySourceRevision,
              input.sourceRevision == input.ownerSourceRevision,
              input.sourceRevision == input.factorySourceRevision,
              input.sourceRevision == input.rfSourceRevision else { throw Failure.staleSource }
        guard !input.ownerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              input.ownerID == input.factoryOwnerID,
              input.ownerID == input.textSupportOwnerID else { throw Failure.mismatchedOwner }
        let bg = zip(input.background, [0.2126, 0.7152, 0.0722]).reduce(0) { $0 + $1.0 * $1.1 }
        var result = Set<Int>(), accepted = 0, hardVeto = 0
        var rejected = [String: Int]()
        var dbRejected = [[Int]]()
        func reject(_ reason: String) { rejected[reason, default: 0] += 1 }
        // Components are found in the COMPLETE padded original ROI before
        // checking ownership. Clipping a foreign component cannot invent a glyph.
        for polarity in input.chromaticInk == nil ? [-1.0, 1.0] : [-1.0, 1.0, 0.0] {
            try Task.checkCancellation()
            var core = [UInt8](repeating: 0, count: n)
            for k in 0..<n {
                if k % 16_384 == 0 { try Task.checkCancellation() }
                let r = Double(input.rgb[k * 3]), g = Double(input.rgb[k * 3 + 1]), b = Double(input.rgb[k * 3 + 2])
                let luminance = r * 0.2126 + g * 0.7152 + b * 0.0722
                if polarity == 0, let ink = input.chromaticInk {
                    let distance = zip([r, g, b], ink).map { abs($0 - $1) }.max()!
                    if max(r, max(g, b)) - min(r, min(g, b)) >= 45, distance <= 80 { core[k] = 1 }
                } else if max(r, max(g, b)) - min(r, min(g, b)) <= 40, polarity * (luminance - bg) >= 48 { core[k] = 1 }
            }
            for start in 0..<n where core[start] != 0 {
                core[start] = 0
                var component = [start], cursor = 0
                while cursor < component.count {
                    if cursor % 16_384 == 0 { try Task.checkCancellation() }
                    let k = component[cursor], x = k % w, y = k / w
                    cursor += 1
                    for yy in max(0, y - 1)...min(h - 1, y + 1) {
                        for xx in max(0, x - 1)...min(w - 1, x + 1) {
                            let q = yy * w + xx
                            if core[q] != 0 { core[q] = 0; component.append(q) }
                        }
                    }
                }
                guard component.contains(where: { input.balloonBoundary[$0] != 0 }) else { continue }
                guard component.count >= 8, Double(component.count) <= 1.1 * input.fontPixels * input.fontPixels
                else { reject("component-area"); continue }
                let xs = component.map { $0 % w }, ys = component.map { $0 / w }
                guard xs.min()! > 0, ys.min()! > 0, xs.max()! < w - 1, ys.max()! < h - 1,
                      Double(max(xs.max()! - xs.min()! + 1, ys.max()! - ys.min()! + 1)) <= 1.7 * input.fontPixels
                else { reject("component-extent-or-clipped"); continue }
                guard component.allSatisfy({ input.owned[$0] != 0 }) else { reject("outside-original-owner"); continue }
                guard component.allSatisfy({ input.textSupport[$0] != 0 }) else { reject("outside-RF-text-support"); continue }
                if component.contains(where: { input.hardProtection[$0] != 0 }) { hardVeto += 1; continue }
                let proposed = component.filter { input.factoryMask[$0] != 0 }.count
                let strong = component.filter { input.probability[$0] >= 0.65 }.count
                guard Double(proposed) >= 0.95 * Double(component.count) else { reject("factory-coverage"); continue }
                // DB locates a glyph CORE, not its painted outline. Requiring
                // DB on80% of every source-colored/outline pixel confuses those
                // domains. Require four detector-cell-equivalents of positive
                // core support; the complete original CC/factory/owner checks
                // above remain the independent paint boundary authority.
                guard strong >= max(8, Int(ceil(input.probabilityCellArea * 4))) else {
                    if dbRejected.count < 8 { dbRejected.append([component.count, strong]) }
                    reject("DB-coverage"); continue
                }
                var local = Set<Int>()
                for k in component {
                    // One original-pixel AA shell only. No iterative growth,
                    // foreign owner, weak original contrast or new erasure vote.
                    for yy in max(0, k / w - 1)...min(h - 1, k / w + 1) {
                        for xx in max(0, k % w - 1)...min(w - 1, k % w + 1) {
                            let q = yy * w + xx
                            let distance = (0..<3).map { abs(Double(input.rgb[q * 3 + $0]) - input.background[$0]) }.max()!
                            if input.owned[q] != 0, input.textSupport[q] != 0, input.hardProtection[q] == 0,
                               input.factoryMask[q] != 0, input.balloonBoundary[q] != 0, distance >= 8 { local.insert(q) }
                        }
                    }
                }
                guard !local.isEmpty else { reject("no-factory-boundary-pixels"); continue }
                let newCount = local.reduce(0) { $0 + (result.contains($1) ? 0 : 1) }
                guard result.count <= 65_536 - newCount
                else { reject("output-budget"); continue }
                result.formUnion(local); accepted += 1
            }
        }
        return Result(boundaryExemptions: result, acceptedComponents: accepted, hardVetoComponents: hardVeto,
            rejectionCounts: rejected, dbRejectedComponentCounts: dbRejected)
    }
}
