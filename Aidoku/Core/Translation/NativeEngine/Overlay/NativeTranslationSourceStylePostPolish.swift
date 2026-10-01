import CoreGraphics
import Foundation

/// Complete-link source style policies. These helpers only reconcile independently
/// sampled display styles; restoration's original ink hypotheses remain separate.
enum NativeTranslationSourceStylePostPolish {
    struct Ink: Codable {
        let id: String
        let rgb: [Double]
        let confidence: Double
    }
    struct InkCluster: Codable {
        let members: [Ink]
        let rgb: [Double]
    }
    struct Stroke: Codable {
        let id: String
        let key: String
        let glyph: Double
        let font: Double
        let width: Double
        let fill: [Double]
        let stroke: [Double]
        let preserved: Bool
        let darkMeasured: Bool
    }
    struct StrokeResult: Codable {
        let id: String
        var width: Double
        var count: Int
    }

    static func colorClass(_ rgb: [Double]) -> String {
        guard rgb.count >= 3, valid(Array(rgb.prefix(3))) else { return "?" }
        let r = rgb[0] / 255, g = rgb[1] / 255, b = rgb[2] / 255
        let high = max(r, g, b), low = min(r, g, b), delta = high - low
        if delta * 255 > 60 {
            let hue = high == r ? ((g - b) / delta + 6).truncatingRemainder(dividingBy: 6) :
                high == g ? (b - r) / delta + 2 : (r - g) / delta + 4
            return "h\(Int(floor((hue * 60 + 30).truncatingRemainder(dividingBy: 360) / 60)))"
        }
        let level = 0.299 * r + 0.587 * g + 0.114 * b
        return level < 0.3 ? "dark" : level > 0.72 ? "light" : "mid"
    }

    static func inkLab(_ rgb: [Double]) -> [Double] {
        let c = rgb.map { value -> Double in
            let v = value / 255
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let l = cbrt(0.4122214708 * c[0] + 0.5363325363 * c[1] + 0.0514459929 * c[2])
        let m = cbrt(0.2119034982 * c[0] + 0.6806995451 * c[1] + 0.1073969566 * c[2])
        let s = cbrt(0.0883024619 * c[0] + 0.2817188376 * c[1] + 0.6299787005 * c[2])
        return [0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s]
    }

    static func inkClusters(_ entries: [Ink]) -> [InkCluster] {
        guard entries.count <= 256 else { return [] }
        let entries = entries.filter { $0.confidence >= 0.5 && valid($0.rgb) }
        let labs = Dictionary(entries.enumerated().map { ($0.offset, inkLab($0.element.rgb)) }, uniquingKeysWith: { a, _ in a })
        func distance(_ a: Int, _ b: Int) -> Double {
            let lhs = labs[a]!, rhs = labs[b]!
            return sqrt(zip(lhs, rhs).reduce(0) { $0 + pow($1.0 - $1.1, 2) })
        }
        let sorted = entries.indices.sorted { a, b in
            for c in 0..<3 where entries[a].rgb[c] != entries[b].rgb[c] { return entries[a].rgb[c] < entries[b].rgb[c] }
            let order = entries[a].id.compare(entries[b].id, options: [], locale: Locale(identifier: "en_US"))
            return order == .orderedAscending || order == .orderedSame && a < b
        }
        var groups: [[Int]] = []
        for index in sorted {
            let rgb = entries[index].rgb, neutral = (rgb.max()! - rgb.min()!) < 24
            if let group = groups.firstIndex(where: { members in members.allSatisfy { other in
                let color = entries[other].rgb
                return neutral == (color.max()! - color.min()! < 24) &&
                    zip(rgb, color).map { abs($0 - $1) }.max()! <= 20 && distance(index, other) <= 0.035
            } }) { groups[group].append(index) } else { groups.append([index]) }
        }
        return groups.filter { $0.count >= 2 }.map { group in
            var best = group[0], score = Double.infinity
            for candidate in group {
                let cost = group.reduce(0.0) { $0 + distance(candidate, $1) * entries[$1].confidence }
                if cost < score { score = cost; best = candidate }
            }
            return InkCluster(members: group.map { entries[$0] }, rgb: entries[best].rgb)
        }
    }

    static func strokeWidths(_ records: [Stroke]) -> [StrokeResult] {
        guard records.count <= 256 else { return [] }
        let records = records.filter { valid($0.fill) && valid($0.stroke) && $0.width.isFinite && $0.width > 0 }
        var results = records.map { StrokeResult(id: $0.id, width: $0.width, count: 1) }
        let eligible = records.indices.filter { records[$0].glyph.isFinite && records[$0].glyph > 0 &&
            records[$0].font.isFinite && records[$0].font > 0 }.sorted { a, b in
            let first = records[a], second = records[b]
            let order = first.key.compare(second.key, options: [], locale: Locale(identifier: "en_US"))
            if order != .orderedSame { return order == .orderedAscending }
            return first.glyph == second.glyph ? a < b : first.glyph < second.glyph
        }
        var groups: [[Int]] = []
        for index in eligible {
            if let group = groups.firstIndex(where: { members in members.allSatisfy { other in
                records[index].key == records[other].key && max(records[index].glyph, records[other].glyph) /
                    min(records[index].glyph, records[other].glyph) <= 1.25
            } }) { groups[group].append(index) } else { groups.append([index]) }
        }
        for group in groups where group.count >= 2 {
            let widths = group.map { records[$0].width }.sorted(), width = widths[widths.count / 2]
            for i in group { results[i].width = width; results[i].count = group.count }
        }
        for i in records.indices where records[i].preserved {
            let record = records[i], minimum = chromaticOutlineMinimum(record.fill, record.stroke, record.font)
            let cap = max(record.darkMeasured ? 2 : 1, minimum, min(3.5, record.font * 0.2))
            results[i].width = max(minimum, min(results[i].width, cap))
        }
        return results
    }

    static func luminance(_ rgb: [Double]) -> Double {
        zip(rgb, [0.2126, 0.7152, 0.0722]).reduce(0) { sum, pair in
            let value = pair.0 / 255
            return sum + pair.1 * (value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4))
        }
    }
    static func chromaticOutlineMinimum(_ fill: [Double], _ stroke: [Double], _ font: Double) -> Double {
        guard valid(fill), valid(stroke), font > 0, fill.min()! >= 225, stroke.max()! - stroke.min()! >= 60 else { return 0 }
        let a = luminance(fill), b = luminance(stroke), contrast = (max(a, b) + 0.05) / (min(a, b) + 0.05)
        return contrast >= 3 && contrast < 4.5 ? max(1.8, min(2.4, font * 0.24)) : 0
    }
    static func valid(_ rgb: [Double]) -> Bool { rgb.count == 3 && rgb.allSatisfy { $0.isFinite && (0...255).contains($0) } }
}

extension NativeTranslationSourceStylePostPolish {
    struct Outline: Codable {
        let foreground: [Double]
        let stroke: [Double]
        let width: Double
        var expansion: Double { width / 2 }
        let minimumContrast: Double
    }

    static func luminanceContrast(_ text: Double, _ low: Double, _ high: Double) -> Double {
        if text >= low && text <= high { return 1 }
        func ratio(_ background: Double) -> Double { (max(text, background) + 0.05) / (min(text, background) + 0.05) }
        return min(ratio(low), ratio(high))
    }

    static func adjustInkForContrast(_ color: [Double], contrast: ([Double]) -> Double, target: Double = 4.5) -> [Double] {
        if contrast(color) >= target { return color }
        let neutral = color.max()! - color.min()! < 24, before = contrast(color), lost = before < 1.5
        var candidates: [(rgb: [Double], distance: Double)] = []
        for endpoint in [0.0, 255.0] {
            if contrast([endpoint, endpoint, endpoint]) < target { continue }
            var low = 0.0, high = 1.0
            func blend(_ fraction: Double) -> [Double] { color.map { floor($0 + (endpoint - $0) * fraction + 0.5) } }
            for _ in 0..<12 {
                let mid = (low + high) / 2
                if contrast(blend(mid)) >= target { high = mid } else { low = mid }
            }
            let rgb = blend(high), crossing = neutral && (lost || contrast(blend(0.08)) < before - 0.001)
            let distance = zip(rgb, color).reduce(0) { $0 + pow($1.0 - $1.1, 2) }
            candidates.append((crossing ? blend(1) : rgb, distance))
        }
        // Stable ties choose the first endpoint, matching ECMAScript stable sort.
        if let best = candidates.enumerated().min(by: { a, b in
            a.element.distance == b.element.distance ? a.offset < b.offset : a.element.distance < b.element.distance
        }) { return best.element.rgb }
        return contrast([0, 0, 0]) >= contrast([255, 255, 255]) ? [0, 0, 0] : [255, 255, 255]
    }

    static func readableSourceOutline(sample: [String: Any], ink: [Double], range: [Double], font: Double) -> Outline? {
        guard valid(ink), let stroke = sample["stroke"] as? [Double], valid(stroke),
              confidence(sample, "stroke") >= 0.55, validRange(range), font.isFinite, font >= 12 else { return nil }
        func contrast(_ color: [Double]) -> Double { luminanceContrast(luminance(color), range[0], range[1]) }
        if contrast(ink) >= 4.5 { return nil }
        let a = luminance(ink), b = luminance(stroke), pair = (max(a, b) + 0.05) / (min(a, b) + 0.05), edge = contrast(stroke)
        if pair < 4.5 || edge < 4.5 { return nil }
        let dark = range[1] <= 0.08 && contrast(ink) < 3 && edge >= 7
        let relative = (sample["widthEvidence"] as? [String: Any])?["relativeToGlyph"] as? Double ?? .nan
        let measured = relative.isFinite && relative > 0 && relative <= 0.3 ? 2 * relative * font : font * 0.14
        let width = dark ? min(3.5, font * 0.2, max(2, measured)) : min(1.15, font * 0.035)
        return Outline(foreground: ink, stroke: stroke, width: width, minimumContrast: min(pair, edge))
    }

    static func sourceStyleOutline(sample: [String: Any], range: [Double], font: Double) -> Outline? {
        guard let fill = sample["foreground"] as? [Double], let stroke = sample["stroke"] as? [Double], valid(fill), valid(stroke),
              confidence(sample, "stroke") >= 0.55, confidence(sample, "foreground") >= 0.55,
              validRange(range), font.isFinite, font >= 8 else { return nil }
        let a = luminance(fill), b = luminance(stroke), pair = (max(a, b) + 0.05) / (min(a, b) + 0.05)
        if pair < 3 { return nil }
        let edge = max(luminanceContrast(a, range[0], range[1]), luminanceContrast(b, range[0], range[1]))
        if edge < 3 { return nil }
        return Outline(foreground: fill, stroke: stroke, width: max(1, min(3.5, font * 0.14)), minimumContrast: min(pair, edge))
    }
    private static func confidence(_ sample: [String: Any], _ role: String) -> Double {
        (sample["confidence"] as? [String: Any])?[role] as? Double ?? 0
    }
    private static func validRange(_ range: [Double]) -> Bool {
        range.count == 2 && range.allSatisfy(\.isFinite) && range[0] >= 0 && range[1] <= 1 && range[0] <= range[1]
    }
}

extension NativeTranslationSourceStylePostPolish {
    /// A measured, final-font display record. Surface ranges are accepted only
    /// after the caller audits the actual glyph footprint, never the OCR box.
    struct Display {
        let id: String
        let eligible: Bool
        let sourceTextOnly: Bool
        let rotation: Double
        let script: String
        let vertical: Bool
        let fontName: String
        let fontWeight: String
        let glyph: Double
        let font: Double
        let sample: [String: Any]
        var foreground: [Double]
        var stroke: [Double]?
        var strokeWidth: Double
        var textPreserved: Bool
        var strokePreserved: Bool
        var darkMeasured: Bool
        let captionBackground: [Double]?
        let ownerBackground: [Double]?
        let restored: Bool
        let surfaceRange: [Double]?
        let overlappingSurfaceLuminances: [Double]
        var cluster: [Double]?
        var partialSourcePositionProof = false
        var inkBeforeSurface: [Double]? = nil
        var surfaceHistogram: [Int]? = nil
        /// An accepted source-outline producer explicitly selects stroke-first paint.
        var replacesStroke = false
    }

    static func sourceColorContrast(_ color: [Double], light: Bool = true, opacity: Double = 1, panel: [Double]? = nil) -> Double {
        guard valid(color), opacity.isFinite else { return 0 }
        let surface = panel ?? (light ? [255, 254, 249] : [7, 9, 13])
        let veil: [Double] = light ? [255, 255, 255] : [7, 9, 13], alpha = panel != nil ? 0 : light ? 0.42 : 0.64
        let a = min(1, max(0, opacity))
        let backgrounds = [0.0, 255.0].map { base in
            luminance((0..<3).map { veil[$0] * alpha + (surface[$0] * a + base * (1 - a)) * (1 - alpha) })
        }
        return luminanceContrast(luminance(color), backgrounds[0], backgrounds[1])
    }

    enum Stage { case all, initialInk, finalContrast }

    /// Initial cohorts and final contrast run on opposite sides of the geometry
    /// passes. Keep their cluster provenance while refreshing owner/surface data.
    /// `.all` remains useful for a fixed-geometry policy comparison.
    /// Original final ink cohort admission and final source-style contrast pass.
    /// The caller supplies actual panel ownership and independently measured
    /// restored luminance ranges; absent evidence does not authorize a release.
    static func resolve(_ input: [Display], preserveText: Bool, opacity: Double, clusterStrokes: Bool = true,
                        stage: Stage = .all) -> [Display] {
        guard input.count <= 256 else { return input }
        var records = input
        if preserveText && stage != .finalContrast {
            var inks: [Ink] = []
            for record in records where record.eligible && !record.sourceTextOnly && record.textPreserved {
                let confidence = record.sample["confidence"] as? [String: Any] ?? [:]
                let value = max(confidence["foreground"] as? Double ?? 0, confidence["stroke"] as? Double ?? 0,
                    (record.sample["lettering"] as? [String: Any])?["confidence"] as? Double ?? 0,
                    (record.sample["displayEvidence"] as? [String: Any])?["confidence"] as? Double ?? 0)
                inks.append(Ink(id: record.id, rgb: record.foreground, confidence: value))
            }
            for cluster in inkClusters(inks) {
                for member in cluster.members {
                    guard let index = records.firstIndex(where: { $0.id == member.id }) else { continue }
                    let record = records[index]
                    let original = sourceColorContrast(record.foreground, panel: record.captionBackground)
                    let candidate = sourceColorContrast(cluster.rgb, panel: record.captionBackground)
                    if candidate + 0.05 < min(4.5, original) { continue }
                    if record.restored, let range = record.surfaceRange, validRange(range),
                       luminanceContrast(luminance(cluster.rgb), range[0], range[1]) < 4.5 { continue }
                    records[index].foreground = cluster.rgb; records[index].cluster = cluster.rgb
                }
            }
        }
        if preserveText && opacity == 1 && stage != .initialInk {
            var cohortIndices: [String: [Int]] = [:]
            for i in records.indices {
                let record = records[i]
                guard record.eligible, !record.sourceTextOnly, record.rotation == 0, valid(record.foreground) else { continue }
                let range: [Double]?
                if let background = record.ownerBackground, valid(background) {
                    let l = luminance(background); range = [l, l]
                } else { range = record.restored ? record.surfaceRange : nil }
                if record.partialSourcePositionProof, let stroke = record.stroke, valid(stroke),
                   sourceColorContrast(record.foreground, panel: stroke) >= 4.5 { continue }
                guard var range, validRange(range) else { continue }
                var outline: Outline?
                if record.ownerBackground != nil,
                   let sourceInk = record.sample["foreground"] as? [Double], confidence(record.sample, "foreground") >= 0.55 {
                    outline = readableSourceOutline(sample: record.sample, ink: sourceInk, range: range, font: record.font)
                }
                outline = outline ?? sourceStyleOutline(sample: record.sample, range: range, font: record.font)
                if outline == nil, record.restored, let before = record.inkBeforeSurface, valid(before),
                   let histogram = record.surfaceHistogram, let robust = robustSurfaceInk(source: before, histogram: histogram),
                   let observed = (record.sample["foreground"] as? [Double]) ?? (record.sample["displayForeground"] as? [Double]), valid(observed) {
                    func distance(_ rgb: [Double]) -> Double { zip(rgb, observed).reduce(0) { $0 + abs($1.0 - $1.1) } }
                    if distance(robust.ink) < distance(record.foreground) {
                        records[i].foreground = robust.ink; records[i].cluster = nil; range = robust.range
                    }
                }
                if let outline {
                    records[i].foreground = outline.foreground; records[i].stroke = outline.stroke
                    records[i].strokeWidth = outline.width; records[i].strokePreserved = true; records[i].cluster = nil
                    records[i].replacesStroke = true
                    continue
                }
                func contrast(_ rgb: [Double]) -> Double {
                    let l = luminance(rgb)
                    return min(luminanceContrast(l, range[0], range[1]),
                               record.overlappingSurfaceLuminances.map { luminanceContrast(l, $0, $0) }.min() ?? .infinity)
                }
                let ink = records[i].foreground, level = luminance(ink)
                let target = record.font >= 18 && ink.max()! - ink.min()! >= 40 && level < range[0] &&
                    !record.overlappingSurfaceLuminances.contains(where: { $0 <= level }) ? 3.0 : 4.5
                let adjusted = adjustInkForContrast(ink, contrast: contrast, target: target)
                if contrast(adjusted) >= target { records[i].foreground = adjusted }
                if let cluster = records[i].cluster, valid(cluster) {
                    let key = cluster.map(String.init(describing:)).joined(separator: ",")
                    cohortIndices[key, default: []].append(i)
                }
            }
            for members in cohortIndices.values where members.count >= 2 {
                guard let original = records[members[0]].cluster else { continue }
                func contrast(_ rgb: [Double]) -> Double {
                    let l = luminance(rgb)
                    return members.map { i -> Double in
                        let record = records[i]
                        let range: [Double]
                        if let background = record.ownerBackground { let v = luminance(background); range = [v, v] }
                        else { range = record.surfaceRange! }
                        return min(luminanceContrast(l, range[0], range[1]),
                            record.overlappingSurfaceLuminances.map { luminanceContrast(l, $0, $0) }.min() ?? .infinity)
                    }.min()!
                }
                let shared = adjustInkForContrast(original, contrast: contrast)
                if contrast(shared) < 4.5 || zip(shared, original).map({ abs($0 - $1) }).max()! > 32 { continue }
                for i in members { records[i].foreground = shared }
            }
        }
        guard clusterStrokes else { return records }
        let strokes = records.compactMap { record -> Stroke? in
            guard let stroke = record.stroke, valid(stroke), valid(record.foreground), record.strokeWidth > 0 else { return nil }
            let key = [record.script, record.vertical ? "v" : "h", record.fontName, record.fontWeight,
                       record.strokePreserved ? "preserved" : "default", colorClass(record.foreground), colorClass(stroke)].joined(separator: "|")
            return Stroke(id: record.id, key: key, glyph: record.glyph, font: record.font, width: record.strokeWidth,
                          fill: record.foreground, stroke: stroke, preserved: record.strokePreserved, darkMeasured: record.darkMeasured)
        }
        for stroke in strokeWidths(strokes) {
            if let i = records.firstIndex(where: { $0.id == stroke.id }) { records[i].strokeWidth = stroke.width }
        }
        return records
    }
}

extension NativeTranslationSourceStylePostPolish {
    struct CaptionPalette {
        let background: [Double]
        let foreground: [Double]
        let observed: Bool
        let preserved: Bool
    }
    /// displayInk must come from the original native sourceDisplayInk policy.
    /// Its optionality carries the same absent-sample meaning as the web oracle.
    static func captionPalette(sample: [String: Any], ink: [Double]?, preserveText: Bool,
                               displayInk: [Double]?) -> CaptionPalette {
        let caption = sample["captionBackground"] as? [Double]
        let surface = (sample["surface"] as? [String: Any])?["color"] as? [Double]
        let sampled = sample["background"] as? [Double]
        let observed = [caption, surface, sampled].compactMap { $0 }.first(where: valid)
        let background = observed ?? [242, 240, 235]
        let preserved = preserveText && displayInk != nil
        let inkColor = preserved ? displayInk! : ink.flatMap { valid($0) ? $0 : nil } ?? [17, 18, 23]
        let defaultInk = ink == nil || !valid(ink!) || ink! == [17, 18, 23] || ink! == [255, 255, 255]
        let foreground: [Double]
        if preserved { foreground = inkColor }
        else if defaultInk {
            foreground = sourceColorContrast([17, 18, 23], panel: background) >=
                sourceColorContrast([255, 255, 255], light: false, panel: background) ? [17, 18, 23] : [255, 255, 255]
        } else { foreground = adjustInkForContrast(inkColor, contrast: { sourceColorContrast($0, panel: background) }) }
        return CaptionPalette(background: background, foreground: foreground, observed: observed != nil, preserved: preserved)
    }
}

extension NativeTranslationSourceStylePostPolish {
    struct Panel {
        /// Initial fallback CSS box, leased only to the immediately following
        /// fixed-box caption callback. Clear before later panel mutations.
        var authoredRect: CGRect? = nil
        var rect: CGRect
        var background: [Double]
        var radius: Double = 3
        var coverage: [CGRect]
        var sourceErasure = false
        var clipped = false
        /// Current CSS declaration; immutable local coordinates survive owner moves.
        var coverageClip: NativeCSSCoveragePath.Declaration? = nil
        /// CSS overflow:hidden belongs to the connected owner, independent
        /// of a caption later moving back to the root.
        var overflowClip = false
        var isFlat = true
        var captionUnionClipped = false
        var sourceBridgeClipped = false
        var hasForeignChildren = false
        var rotated = false
        var sourceFrameImage: CGImage?
        var sourceFrameLineCount = 0
        var balloonInteriorClipped: Int?
    }
    /// Original readability fallback6550–6607. Admission requires both a
    /// certified restored source and measured inside text fit before hiding it.
    static func fallbackPanel(currentInk: CGRect, priorInk: CGRect? = nil, priorPadding: Double = 0,
                              font: Double, frame: CGRect?, sources: [CGRect],
                              background: [Double], restoredPanelProof: Bool, insideTextFit: Bool) -> Panel? {
        if restoredPanelProof && insideTextFit { return nil }
        guard currentInk.width > 0, currentInk.height > 0 else { return nil }
        let padding = max(priorPadding, max(3, min(6, font * 0.3)))
        let prior = priorInk ?? currentInk
        var left = min(currentInk.minX, prior.minX) - padding, top = min(currentInk.minY, prior.minY) - padding
        var right = max(currentInk.maxX, prior.maxX) + padding, bottom = max(currentInk.maxY, prior.maxY) + padding
        if frame != nil && !restoredPanelProof {
            for source in sources where [source.minX, source.minY, source.width, source.height].allSatisfy(\.isFinite) {
                left = min(left, source.minX - padding); top = min(top, source.minY - padding)
                right = max(right, source.maxX + padding); bottom = max(bottom, source.maxY + padding)
            }
        }
        left = max(frame?.minX ?? 0, left); top = max(frame?.minY ?? 0, top)
        right = min(frame.map { Double($0.maxX) } ?? right, right); bottom = min(frame.map { Double($0.maxY) } ?? bottom, bottom)
        let rect = CGRect(x: left, y: top, width: max(1, right - left), height: max(1, bottom - top))
        return Panel(rect: rect, background: background, coverage: [rect])
    }
}

extension NativeTranslationSourceStylePostPolish {
    static func dialogueStrokeWidth(fill: [Double], outline: [Double], background: [Double]?,
                                    font: Double, width: Double, releasedPreserved: Bool = false) -> Double {
        if releasedPreserved { return width }
        let cap = max(1, min(2.2, font * 0.11))
        let contrast: Double
        if let background, valid(background), valid(fill) {
            let a = luminance(fill), b = luminance(background)
            contrast = (max(a, b) + 0.05) / (min(a, b) + 0.05)
        } else { contrast = 0 }
        let safe = valid(fill) && valid(outline) && (luminance(outline) < luminance(fill) || contrast >= 4.5)
        if width > cap && outline != fill && safe { return cap }
        let minimum = min(cap, max(1, font * 0.1))
        if width > 0 && outline != fill && width < minimum { return minimum }
        return width
    }
}

extension NativeTranslationSourceStylePostPolish {
    static func observedCaptionStyle(sample: [String: Any], font: Double) -> Outline? {
        guard let fill = sample["foreground"] as? [Double], let stroke = sample["stroke"] as? [Double], valid(fill), valid(stroke),
              font.isFinite, font > 0, confidence(sample, "foreground") >= 0.55, confidence(sample, "stroke") >= 0.55 else { return nil }
        let pair = sourceColorContrast(fill, panel: stroke)
        if pair < 3 { return nil }
        let background = sample["background"] as? [Double]
        let dark = background.map { valid($0) && luminance($0) < 0.08 } ?? false
        if dark && luminance(fill) > 0.7 && luminance(stroke) < 0.08 { return nil }
        let relative = (sample["widthEvidence"] as? [String: Any])?["relativeToGlyph"] as? Double ?? .nan
        let ratio = relative.isFinite && relative > 0 ? max(0.1, min(0.2, relative * 2)) : 0.14
        let darkEdge = dark && luminance(fill) < 0.08 && luminance(stroke) > 0.7
        return Outline(foreground: fill, stroke: stroke,
            width: max(darkEdge ? 2 : 1, chromaticOutlineMinimum(fill, stroke, font), min(3.5, font * ratio)), minimumContrast: pair)
    }

    static func darkSurfaceSourceOutline(sample: [String: Any], ring: [String: Any], font: Double,
                                         certifiedSourcePosition: Bool = false) -> Outline? {
        func rgb(_ payload: [String: Any], _ key: String) -> [Double]? {
            (payload[key] as? [Double]).flatMap { valid($0) ? $0 : nil }
        }
        func num(_ payload: [String: Any], _ key: String) -> Double { payload[key] as? Double ?? .nan }
        let ink = sample["sourceInk"] as? [String: Any] ?? [:]
        let foreground = rgb(ink, "foreground"), stroke = rgb(ink, "stroke")
        let back = rgb(sample, "captionBackground") ?? rgb(sample, "background")
        let sampledPair = foreground != nil && stroke != nil && confidence(ink, "foreground") >= 0.7 && confidence(ink, "stroke") >= 0.7 &&
            foreground!.max()! <= 100 && stroke!.min()! >= 225
        let surface = ring["surface"] as? [Double]
        let nativeProof = certifiedSourcePosition && rgb(sample, "foreground") == nil && confidence(sample, "background") >= 0.8 &&
            num(ring, "reached") >= 0.9 && num(ring, "boxRing") <= 0.4 && surface?.count == 4 &&
            surface!.allSatisfy(\.isFinite) && surface![3] == 1 && surface!.prefix(3).max()! <= 32
        guard sampledPair || nativeProof, let back, back.max()! <= 32, ring["kind"] as? String == "outline",
              let core = rgb(ring, "core"), let outline = rgb(ring, "outline"), num(ring, "hug") >= 0.95,
              num(ring, "uniform") >= 0.35, num(ring, "exterior") <= 0.03, num(ring, "width").isFinite,
              num(ring, "width") >= 0.04, num(ring, "width") <= 0.18, core.max()! <= 48, outline.min()! >= 225,
              !sampledPair || zip(outline, stroke!).map({ abs($0 - $1) }).max()! <= 24, font.isFinite, font >= 7 else { return nil }
        let width = max(2, min(3.5, font * 0.25, 2 * num(ring, "width") * font))
        return Outline(foreground: core, stroke: outline, width: width, minimumContrast: sourceColorContrast(core, panel: outline))
    }

    /// Late original source-style admission; caller supplies the observed native
    /// ring/enclosed-interior proof rather than synthesizing its metadata.
    static func lateSourceOutline(sample: [String: Any], font: Double, eligible: Bool, keepsSourceLettering: Bool,
                                  rotation: Double, displayLettering: Bool, backgroundKind: String,
                                  appliedBackground: [Double]?, surfaceRange: [Double]?,
                                  ring: [String: Any]?, enclosed: [String: Any]?,
                                  certifiedSourcePosition: Bool,
                                  appliedForeground: [Double]? = nil) -> (outline: Outline?, darkPreserved: Bool) {
        guard eligible else { return (nil, false) }
        var darkPair: Outline?
        if let ring, let pair = darkSurfaceSourceOutline(sample: sample, ring: ring, font: font,
            certifiedSourcePosition: certifiedSourcePosition) {
            var dark = appliedBackground.map { valid($0) && $0.max()! <= 32 } ?? false
            if !dark, let range = surfaceRange, range.count == 2, range.allSatisfy(\.isFinite), range.max()! <= 0.08 { dark = true }
            if !dark, certifiedSourcePosition, let surface = ring["surface"] as? [Double], surface.count == 4,
               surface.allSatisfy(\.isFinite), surface[3] == 1, surface.prefix(3).max()! <= 32 { dark = true }
            if dark { darkPair = pair }
        }
        guard !keepsSourceLettering, rotation == 0, !displayLettering,
              ["inpainted", "slanted-glyph-restored"].contains(backgroundKind) else { return (darkPair, darkPair != nil) }
        var selected = sample, selectedDarkInterior = false
        // Early observation can precede the final source-polarity decision.
        // Dark interiors only corroborate an already applied dark fill here;
        // they never turn retained white lettering into dark lettering.
        let darkInteriorAdmitted = enclosed?["polarity"] as? String != "dark-on-dark" ||
            (certifiedSourcePosition && appliedForeground.map { valid($0) && $0.max()! <= 32 } == true)
        if let enclosed, darkInteriorAdmitted {
            func near(_ a: Any?, _ b: Any?) -> Bool {
                guard let a = a as? [Double], let b = b as? [Double], valid(a), valid(b) else { return false }
                return zip(a, b).allSatisfy { abs($0 - $1) <= 32 }
            }
            let stroke = enclosed["stroke"] as? [Double]
            let neutral = stroke?.isEmpty == false && stroke!.max()! - stroke!.min()! < 40
            let components = enclosed["components"] as? Double ?? 0, filaments = enclosed["filaments"] as? Double ?? 0
            let closed = enclosed["proof"] as? String == "closed thin interiors bounded by observed ink" &&
                components >= 4 && filaments >= 2 && filaments / components >= 0.25
            let reversed = (neutral || !closed) && ring?["kind"] as? String == "paper" &&
                (ring?["hug"] as? Double ?? .nan) >= 0.7 && (ring?["uniform"] as? Double ?? .nan) >= 0.6 &&
                near(ring?["core"], sample["foreground"]) && near(ring?["core"], enclosed["stroke"]) && near(ring?["outline"], enclosed["foreground"])
            if !reversed {
                selected = enclosed
                selectedDarkInterior = closed && enclosed["polarity"] as? String == "dark-on-dark"
            }
        }
        let observed = observedCaptionStyle(sample: selected, font: font)
        // Preserve the accepted dark-source observation through final stroke
        // clustering, just as the independent dark surface ring path does.
        return (observed ?? darkPair, darkPair != nil || observed != nil && selectedDarkInterior)
    }
}

extension NativeTranslationSourceStylePostPolish {
    struct RobustInk {
        let ink: [Double]
        let contrast: Double
        let dim: Int
        let total: Int
        let range: [Double]
    }
    static func robustSurfaceInk(source: [Double], histogram: [Int]) -> RobustInk? {
        guard source.count == 3, source.allSatisfy(\.isFinite), histogram.count == 256 else { return nil }
        let total = histogram.reduce(0, +)
        if total < 64 { return nil }
        func at(_ q: Int) -> Int {
            var n = 0
            for v in 0..<256 { n += histogram[v]; if n > q { return v } }
            return 255
        }
        let low = max(0, (Double(at(Int(floor(Double(total - 1) * 0.02)))) - 0.5) / 255)
        let high = min(1, (Double(at(Int(ceil(Double(total - 1) * 0.98)))) + 0.5) / 255)
        func contrast(_ rgb: [Double]) -> Double {
            let l = luminance(rgb)
            return l < low ? (low + 0.05) / (l + 0.05) : l > high ? (l + 0.05) / (high + 0.05) : 1
        }
        func side(_ l: Double) -> Int { l < low ? -1 : l > high ? 1 : 0 }
        let polarity = side(luminance(source))
        if polarity == 0 { return nil }
        let ink = adjustInkForContrast(source, contrast: contrast)
        if side(luminance(ink)) != polarity || contrast(ink) < 4.5 { return nil }
        let fg = luminance(ink)
        var dim = 0
        for v in 0..<256 where histogram[v] != 0 {
            let q = Double(v) / 255, bg = q >= fg ? max(fg, q - 1.0 / 510) : min(fg, q + 1.0 / 510)
            if (max(bg, fg) + 0.05) / (min(bg, fg) + 0.05) >= 4.5 { continue }
            if (q < low ? (low + 0.05) / (q + 0.05) : q > high ? (q + 0.05) / (high + 0.05) : 1) < 1.5 { return nil }
            dim += histogram[v]
        }
        if dim * 50 > total { return nil }
        return RobustInk(ink: ink, contrast: contrast(ink), dim: dim, total: total, range: [low, high])
    }
    // Frozen source-style policies 1447–1481 and final glyph-plate release.
    static func releasedCaptionOutline(sample: [String: Any], ring: [String: Any]?, font: Double) -> Outline? {
        func rgb(_ value: Any?) -> [Double]? {
            guard let c = value as? [Double], c.count == 3, c.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 255 }) else { return nil }; return c
        }
        guard font.isFinite, font > 0 else { return nil }
        let confidence = sample["confidence"] as? [String: Any] ?? [:]
        var fill = rgb(sample["foreground"]), stroke = rgb(sample["stroke"])
        if fill == nil || stroke == nil || (confidence["foreground"] as? Double ?? 0) < 0.55 || (confidence["stroke"] as? Double ?? 0) < 0.55 {
            func ringNumber(_ value: Any?) -> Double {
                if value is NSNull { return 0 }
                return (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init) ?? .nan
            }
            guard let ring, ring["kind"] as? String == "outline", !(ringNumber(ring["hug"]) < 0.7),
                  !(ringNumber(ring["uniform"]) < 0.6), let core = rgb(ring["core"]), let edge = rgb(ring["outline"]) else { return nil }
            fill = core; stroke = edge
        }
        guard let fill, let stroke else { return nil }
        let pair = sourceColorContrast(fill, light: true, opacity: 1, panel: stroke)
        guard pair >= 3 else { return nil }
        return Outline(foreground: fill, stroke: stroke, width: max(2.2, min(5, font * 0.4)), minimumContrast: pair)
    }
    struct ReleasedFill { let foreground: [Double] }
    static func releasedCaptionFill(sample: [String: Any]) -> ReleasedFill? {
        func rgb(_ value: Any?) -> [Double]? {
            guard let c = value as? [Double], c.count == 3, c.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 255 }) else { return nil }; return c
        }
        let confidence = sample["confidence"] as? [String: Any] ?? [:]
        let exposed = sample["captionBackgroundEvidence"] as? [String: Any] ?? [:]
        let supported = rgb(exposed["color"]) != nil && (exposed["coverage"] as? Double ?? 0) >= 0.5
        let surface = supported ? rgb(exposed["color"]) : rgb((sample["surface"] as? [String: Any])?["color"]) ?? rgb(sample["background"])
        guard let fill = rgb(sample["foreground"]), let surface, (confidence["foreground"] as? Double ?? 0) >= 0.55,
              supported || (confidence["background"] as? Double ?? 0) >= 0.5,
              !(rgb(sample["stroke"]) != nil && (confidence["stroke"] as? Double ?? 0) >= 0.55),
              sourceColorContrast(fill, light: true, opacity: 1, panel: surface) >= 3 else { return nil }
        return ReleasedFill(foreground: fill)
    }
    struct ReleasedStyle { let foreground: [Double]; let stroke: [Double]?; let width: Double; let preserved: Bool }
    static func releasedCaptionStyle(sample: [String: Any], ring: [String: Any]?, currentInk: [Double], font: Double,
                                     preserveText: Bool, chromaticGlyphs: Bool = false) -> ReleasedStyle? {
        guard font.isFinite, font > 0 else { return nil }
        if preserveText, let pair = releasedCaptionOutline(sample: sample, ring: ring, font: font) {
            return ReleasedStyle(foreground: pair.foreground, stroke: pair.stroke, width: pair.width, preserved: true)
        }
        if preserveText, let fill = releasedCaptionFill(sample: sample) {
            return ReleasedStyle(foreground: fill.foreground, stroke: nil, width: 0, preserved: true)
        }
        let rgb = chromaticGlyphs ? sample["foreground"] as? [Double] ?? currentInk : currentInk
        guard rgb.count == 3, rgb.allSatisfy(\.isFinite) else { return nil }
        let white: [Double] = [255, 255, 255]
        let contrast: ([Double]) -> Double = { sourceColorContrast($0, light: true, opacity: 1, panel: white) }
        let fg = adjustInkForContrast(rgb, contrast: contrast)
        guard contrast(fg) >= 4.5 else { return nil }
        return ReleasedStyle(foreground: fg, stroke: white, width: max(1, min(2.2, font * 0.11)), preserved: false)
    }

}
