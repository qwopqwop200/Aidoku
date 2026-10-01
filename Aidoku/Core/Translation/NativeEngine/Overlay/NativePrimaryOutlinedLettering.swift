import Foundation

/// Paint decisions of the frozen primary outlined-lettering pass. Source ring
/// evidence and already painted state are separate inputs; plate ownership must
/// be supplied from the caller's actual overlapping painted glyphs.
enum NativePrimaryOutlinedLettering {
    typealias RGB = [Double]
    struct State {
        var sample: [String: Any]
        var font: Double
        var foreground: RGB?
        var stroke: RGB?
        var strokeWidth: Double = 0
        var plate: RGB?
        var restored = false
        var slanted = false
        var missingColumnRing = false
        var plateIsAlone = true
        var overlappingInks: [RGB?] = []
        var sourceContrastBefore: Double? = nil
        var slantedSurfaceLuminance: [Double]? = nil
    }
    struct Decision {
        let fill: RGB?
        let stroke: RGB?
        let strokeWidth: Double?
        let background: RGB?
        let clearsStroke: Bool
        let record: [String: Any]
        let rejection: String?
    }
    private struct Style { let fill: RGB; let stroke: RGB?; var hollow = false }

    static func decide(ring r: NativeSourceOutlineEvidence.Ring, state s: State) -> Decision {
        let core = r.core, outline = r.outline, surface = r.surface
        let sample = s.sample, ink = valid(s.foreground) ? s.foreground : nil
        let plate = valid(s.plate) ? s.plate : nil
        let font = s.font.isFinite && s.font != 0 ? s.font : 10
        let required = font >= 18 ? 3.0 : 4.5, stroked = s.strokeWidth > 0
        let sourceForeground = rgb(sample["foreground"]), sourceStroke = rgb(sample["stroke"])
        func rounded(_ x: Double) -> Double { floor(x * 100 + 0.5) / 100 }
        var record: [String: Any] = ["kind": r.kind, "core": core, "outline": outline,
            "plate": plate as Any? ?? NSNull(), "uniform": rounded(r.uniform), "hug": rounded(r.hug),
            "exterior": r.exterior.map(rounded) as Any? ?? NSNull(), "width": rounded(r.width),
            "reached": rounded(r.reached), "boxRing": r.boxRing.map(rounded) as Any? ?? NSNull(),
            "surface": surface.map { $0.rgb + [$0.flat ? 1 : 0] } as Any? ?? NSNull(), "action": "none"]
        if let ink { record["ink"] = ink }
        func unchanged(_ action: String = "none", reject: String? = nil) -> Decision {
            record["action"] = action
            return Decision(fill: nil, stroke: nil, strokeWidth: nil, background: nil, clearsStroke: false, record: record, rejection: reject)
        }
        guard valid(core), valid(outline), [r.uniform, r.hug, r.width, r.reached].allSatisfy(\.isFinite) else { return unchanged() }
        if let sourceForeground, gap(sourceForeground, outline) <= 40 && gap(sourceForeground, core) > 40 {
            let roles = r.structure
            record["roles"] = [rounded(roles.band), rounded(roles.deep)]
            let widthEvidence = sample["widthEvidence"] as? [String: Any]
            let carried = stroked && valid(s.stroke) && plate != nil && pair(s.stroke!, plate!) >= 3 && ink != nil &&
                pair(ink!, s.stroke!) >= 4.5 && gap(ink!, plate!) >= 10 &&
                number(widthEvidence?["samplePixels"]) >= 2.5 && number(widthEvidence?["relativeToGlyph"]) >= 0.17
            let lost = !carried && plate != nil && ink != nil && pair(ink!, plate!) < 2 && pair(core, plate!) >= 4.5
            if lost { record["rolesForReadability"] = true }
            if !lost && (roles.band < 0.6 || roles.deep > 0.3 || roles.fillN < 30 || roles.ringN < 30) {
                return unchanged(reject: "sampled-ink-is-ring")
            }
            record["rolesFromStructure"] = true
        }
        let sampled = sourceStroke != nil && confidence(sample, "stroke") >= 0.55
        let sampledOutline = sampled && gap(sourceStroke!, outline) <= 40
        func pairStyle(_ backing: RGB) -> Style? {
            let coreReads = pair(core, backing), outlineReads = pair(outline, backing)
            if outlineReads < 3 {
                return coreReads >= 4.5 && outlineReads >= 1.4 && gap(outline, backing) > 40 && sampledOutline ? Style(fill: core, stroke: outline) : nil
            }
            if coreReads >= 4.5 || coreReads >= 1.5 && pair(core, outline) >= 4.5 && font >= 9 { return Style(fill: core, stroke: outline) }
            if font >= 18 && outlineReads >= 4.5 && pair(core, outline) >= 3 && r.hug >= 0.8 && r.uniform >= 0.5 &&
                r.width <= 0.2 && sampledOutline { return Style(fill: core, stroke: outline, hollow: true) }
            if font >= 9 && outlineReads >= 4.5 && pair(core, outline) >= 4.5 && sourceForeground != nil &&
                gap(sourceForeground!, core) <= 40 && r.hug >= 0.9 && r.uniform >= 0.8 && r.width <= 0.1 {
                return Style(fill: core, stroke: outline, hollow: true)
            }
            return nil
        }
        var fill: RGB?, stroke: RGB?, newPlate: RGB?, action: String?
        if s.restored {
            guard r.kind == "outline", let surface, gap(outline, surface.rgb) > 40 else { return unchanged() }
            let owned = sourceForeground != nil && (gap(sourceForeground!, core) <= 40 || record["rolesFromStructure"] as? Bool == true)
            if sampled {
                if gap(sourceStroke!, outline) > 40 { return unchanged() }
            } else if !((s.slanted || s.missingColumnRing) && owned && r.width <= 0.2 &&
                (r.boxRing == nil || r.boxRing! < 0.55) && r.uniform >= 0.6 && r.hug >= 0.8 && r.reached >= 0.8) { return unchanged() }
            var style: Style?
            if sampled || s.missingColumnRing {
                if surface.flat {
                    style = pairStyle(surface.rgb) ?? (pair(core, surface.rgb) >= required ? Style(fill: core, stroke: outline) : nil)
                    if style == nil && s.missingColumnRing && record["rolesFromStructure"] as? Bool == true &&
                        pair(core, outline) >= 4.5 && pair(outline, surface.rgb) >= required { style = Style(fill: core, stroke: outline) }
                } else if pair(core, outline) >= 4.5 && font >= 9 && surface.reads(outline, ratio: 3) >= 0.85 {
                    style = Style(fill: core, stroke: outline)
                }
            }
            if style == nil && s.slanted && font >= 9, let range = s.slantedSurfaceLuminance, range.count == 2, range.allSatisfy(\.isFinite) {
                let low = range.min()!, high = range.max()!, outlineLuminance = luminance(outline)
                func pairReads(_ rgb: RGB, _ edge: RGB) -> Double {
                    let l = luminance(rgb), le = luminance(edge)
                    var worst = Double.infinity
                    for k in 0...32 {
                        let surface = low + (high - low) * Double(k) / 32
                        worst = min(worst, max(ratio(l, surface), ratio(le, surface)))
                    }
                    return worst
                }
                let target = luminance(core) < outlineLuminance ? 0.0 : 255.0
                func blend(_ t: Double) -> RGB { core.map { floor($0 + (target - $0) * t + 0.5) } }
                func fits(_ rgb: RGB) -> Bool { pair(rgb, outline) >= 4.5 && pairReads(rgb, outline) >= required }
                var chosen: RGB? = fits(core) ? core : nil, edge = outline
                if chosen == nil && fits(blend(1)) {
                    var a = 0.0, b = 1.0
                    for _ in 0..<12 { let m = (a + b) / 2; if fits(blend(m)) { b = m } else { a = m } }
                    chosen = blend(b)
                }
                if chosen == nil && sampled {
                    let away = target == 0 ? 255.0 : 0.0, beyond = target == 0 ? outlineLuminance > high : outlineLuminance < low
                    func raise(_ t: Double) -> RGB { outline.map { floor($0 + (away - $0) * t + 0.5) } }
                    func raised(_ rgb: RGB) -> Bool { pair(core, rgb) >= 4.5 && pairReads(core, rgb) >= required }
                    if beyond && raised(raise(1)) {
                        var a = 0.0, b = 1.0
                        for _ in 0..<12 { let m = (a + b) / 2; if raised(raise(m)) { b = m } else { a = m } }
                        chosen = core; edge = raise(b); record["outlineRaised"] = edge
                    }
                }
                if let chosen, !(ink != nil && gap(chosen, core) > gap(ink!, core)) {
                    style = Style(fill: chosen, stroke: edge)
                    record["slantedPair"] = rounded(pairReads(chosen, edge)); record["sampledStroke"] = sampled
                }
            }
            guard let style else { return unchanged() }
            if let ink, gap(ink, style.fill) <= 40 && stroked { return unchanged("kept") }
            fill = style.fill; stroke = style.stroke; action = "restored-outline"
        } else {
            guard let plate else { return unchanged() }
            func lighter(_ a: RGB, _ b: RGB) -> Bool { luminance(a) > luminance(b) }
            func flips(_ colour: RGB) -> Bool {
                ink != nil && lighter(ink!, plate) != lighter(core, colour) && r.kind != "outline" &&
                    !(sourceForeground != nil && gap(sourceForeground!, core) <= 40) &&
                    !(spread(core) < 24 && spread(outline) < 24 && lighter(outline, core))
            }
            func clear(_ colour: RGB) -> Bool {
                s.plateIsAlone && !flips(colour) && s.overlappingInks.allSatisfy { valid($0) && pair($0!, colour) >= 3 }
            }
            if (r.kind == "paper" || r.width >= 0.2) && r.exterior != nil && (r.boxRing ?? 0) >= 0.55 && r.reached >= 0.8 &&
                r.uniform >= 0.6 && pair(core, plate) < 3 && pair(core, outline) >= max(4.5, required) && gap(outline, plate) > 40 && clear(outline) {
                newPlate = outline; fill = core; action = "halo-plate"
            }
            if newPlate == nil && (r.kind == "paper" || r.width < 0.2), let surface, surface.flat,
                gap(surface.rgb, plate) > 48 && clear(surface.rgb) {
                var style = r.kind == "outline" && gap(outline, surface.rgb) > 40 ? pairStyle(surface.rgb) : nil
                if style == nil && pair(core, surface.rgb) >= required { style = Style(fill: core, stroke: nil) }
                if let style { newPlate = surface.rgb; fill = style.fill; stroke = style.stroke; action = "surface-plate" }
            }
            func raisedOutline() -> RGB? {
                let lc = luminance(core), lp = luminance(plate), lo = luminance(outline)
                guard sampledOutline, font >= 9, pair(core, plate) >= 1.5, pair(core, outline) >= 4.5,
                      lc < lp && lp < lo || lc > lp && lp > lo else { return nil }
                let away = lc < lp ? 255.0 : 0.0
                func raise(_ t: Double) -> RGB { outline.map { floor($0 + (away - $0) * t + 0.5) } }
                func raised(_ rgb: RGB) -> Bool { pair(rgb, plate) >= required && pair(core, rgb) >= 4.5 }
                guard raised(raise(1)) else { return nil }
                var a = 0.0, b = 1.0
                for _ in 0..<12 { let m = (a + b) / 2; if raised(raise(m)) { b = m } else { a = m } }
                return raise(b)
            }
            if newPlate == nil {
                let coreReads = pair(core, plate)
                let raised = r.kind == "outline" && pair(outline, plate) < 3 && pairStyle(plate) == nil ? raisedOutline() : nil
                if let raised {
                    if let ink, gap(ink, core) <= 40 && stroked { return unchanged("kept") }
                    fill = core; stroke = raised; action = "raised-outline"; record["outlineRaised"] = raised
                } else if r.kind == "outline" && (pair(outline, plate) >= 3 || pairStyle(plate) != nil) {
                    if let style = pairStyle(plate) {
                        if let ink, gap(ink, core) <= 40 && stroked { return unchanged("kept") }
                        fill = style.fill; stroke = style.stroke; action = style.hollow ? "hollow" : "outline"
                    } else if coreReads < 1.5 && pair(outline, plate) >= 4.5 && ink != nil &&
                        (pair(ink!, plate) < 4.5 || spread(ink!) < 24 && ink!.max()! >= 80 && ink!.min()! <= 200) &&
                        spread(core) < 24 && spread(outline) < 24 && surface != nil && gap(surface!.rgb, plate) <= 24 {
                        fill = outline; action = "outline-as-fill"
                    } else { return unchanged() }
                } else {
                    let framed = record["rolesFromStructure"] as? Bool == true && r.kind == "outline" && font >= 9 &&
                        coreReads >= required && pair(core, outline) >= 4.5
                    if let ink, gap(ink, core) <= 40 && coreReads >= 3 && (!framed || stroked) { return unchanged("kept") }
                    if framed { fill = core; stroke = outline; action = "outline" }
                    else {
                        if coreReads < required && !(coreReads >= 3 && ink != nil && pair(ink!, plate) < required && coreReads > pair(ink!, plate)) { return unchanged() }
                        if let ink {
                            let midGray = spread(ink) < 24 && ink.max()! >= 80 && ink.min()! <= 200
                            let lost = spread(ink) < 24 && (s.sourceContrastBefore ?? .infinity) < 1.5 && spread(core) >= 24
                            if !((midGray && coreReads > pair(ink, plate) * 1.2) || spread(core) >= 60 && spread(ink) < 24 || lost ||
                                lighter(ink, plate) != lighter(core, plate)) { return unchanged() }
                        }
                        fill = core; action = "fill"
                    }
                }
            }
        }
        guard let fill, let action else { return unchanged() }
        if let newPlate { record["plateTo"] = newPlate }
        record["action"] = action
        return Decision(fill: fill, stroke: stroke, strokeWidth: stroke.map { _ in max(0.75, min(3.5, font * 0.14)) },
            background: newPlate, clearsStroke: stroke == nil && newPlate != nil && stroked, record: record, rejection: nil)
    }

    private static func rgb(_ value: Any?) -> RGB? { NativeSourceColorSampler.rgb(value) }
    private static func number(_ value: Any?) -> Double { NativeSourceColorSampler.number(value) }
    private static func valid(_ rgb: RGB?) -> Bool { rgb != nil && rgb!.count == 3 && rgb!.allSatisfy { $0.isFinite && (0...255).contains($0) } }
    private static func confidence(_ sample: [String: Any], _ key: String) -> Double { number((sample["confidence"] as? [String: Any])?[key]) }
    private static func spread(_ rgb: RGB) -> Double { rgb.max()! - rgb.min()! }
    private static func gap(_ a: RGB, _ b: RGB) -> Double { zip(a, b).map { abs($0 - $1) }.max() ?? 0 }
    private static func luminance(_ rgb: RGB) -> Double { NativeSourceColorSampler.luminance(rgb) }
    private static func ratio(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }
    private static func pair(_ a: RGB, _ b: RGB) -> Double { ratio(luminance(a), luminance(b)) }
}
