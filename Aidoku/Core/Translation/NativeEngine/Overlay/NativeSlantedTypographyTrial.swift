import CoreGraphics
import Foundation

/// Search policy for rotated text. Shaping and source-raster ownership are queries;
/// no speculative candidate mutates a displayed card or its source restoration.
enum NativeSlantedTypographyTrial {
    typealias RGB = [Double]
    typealias Polygon = [[Double]]
    struct Candidate {
        var rect: CGRect
        var font: Double
        var pitch: Double
        var padding: [Double] = [0, 0, 0, 0] // top, right, bottom, left
        var condense: Double = 1
        var angle: Double = 0
        var fraction: Double = 1
    }
    struct Measurement {
        var glyphs: [[Double]]
        var lines: [CGRect]
        var lineCount: Int
        var contentFits: Bool
        var wordBroken: Bool?
        var rangeRects: [CGRect] = []
    }
    struct Surface {
        var id: String
        var method: String = ""
        var isPage = false
        var width = 0
        var height = 0
        var safe: [UInt8] = []
        var luminance: [UInt8] = []
        var expandedPaper = false
        var verifiedNarrowFrame = false
    }
    struct Peer {
        var text: String
        var plannedFont: Double
        var source: CGRect?
        var sourceFont: Double?
        var card: Polygon
    }
    struct Entry {
        var quad: CGRect
        var initial: Candidate
        var plannedFont: Double?
        var minimumFont: Double = 5
        var text: String
        var sourceText: String = ""
        var sourceFont: Double?
        var sourceBounds: CGRect?
        var sourceVertical = false
        var vertical = false
        var wrappingKorean = false
        var canMeasureWords = true
        var sourceForeground: RGB
        var observedForeground: RGB?
        var frame: CGRect?
        var cropFrame: CGRect? = nil // cleanup frame bounds raster preparation, distinct from explicit glyph frame
        var uprightQuad = false
        var backgroundKind = "rotated-panel"
        var peers: [Peer] = []
        var bodyObstacles: [Polygon] = []
        var wideObstacles: [Polygon] = [] // original six-pixel margins already applied
    }
    struct Hooks {
        var measure: (Candidate) -> Measurement?
        var longestWord: (Double) -> Double
        var fits: (Surface, Candidate, [[Double]], RGB, inout NativeSlantedInkSafety.Audit) -> Bool
        var prepareWide: ((CGRect) -> Surface?)?
        /// Returns only source-owned rasters after the original off-quad erasure gate.
        var leftover: ((Surface) -> (area: Int, ink: Int)?)?
    }
    struct Ink {
        var color: RGB
        var safety: NativeSlantedInkSafety.Audit
        var histogram: [Int]?
        var specks: String?
        var narrowSurvey: NativeSlantedInkSafety.Audit?
    }
    struct Result {
        var candidate: Candidate
        var measurement: Measurement?
        var surface: Surface?
        var foreground: RGB
        var accepted = false
        var pendingReadableLift = false
        var metadata: [String: String] = [:]
        var histogram: [Int]?
        var safety: NativeSlantedInkSafety.Audit?
        var measurements = 0
        var sourceSurfaceID: String?
    }
    static func number(_ n: Double) -> String {
        if n.isFinite, n.rounded() == n, n >= Double(Int.min), n < Double(Int.max) { return String(Int(n)) }
        return String(n)
    }
    static func quarter(_ n: Double) -> Double { floor(n * 4) / 4 }
    static func sizes(original: Double, base: Double, floor floorSize: Double, step: Double) -> [Double] {
        guard original.isFinite, base.isFinite, floorSize.isFinite, step.isFinite,
              original > 0, base > 0, floorSize > 0, step > 0 else { return [] }
        var result: [Double] = [], size = original
        let factor = original > 32 ? 0.94 : 0.9
        while size > base {
            result.append(size)
            let next = quarter(size * factor)
            guard next < size else { break }; size = next
        }
        size = base
        while true {
            result.append(size)
            if size <= floorSize { break }
            size = max(floorSize, size - step)
        }
        return result
    }
    static func growthKeepsLineLength(text: String, before: Int, after: Int) -> Bool {
        let n = String(String.UnicodeScalarView(text.unicodeScalars.filter { !whitespace($0) })).utf16.count
        guard n > 0, after >= 1 else { return false }
        return after < 3 || n < 8 || Double(n) / Double(after) >= 2.5 ||
            Double(n) / Double(after) >= Double(n) / Double(max(1, before))
    }
    static func condensedWordBound(_ longest: Double, _ available: Double) -> Bool {
        longest > available && longest * 0.9 <= available
    }
    static func surfaceRange(_ histogram: [Int]?) -> [Double]? {
        guard let histogram, histogram.count == 256 else { return nil }
        let total = histogram.reduce(0, +); guard total >= 16 else { return nil }
        func at(_ q: Int) -> Double {
            var count = 0
            for v in 0..<256 { count += histogram[v]; if count > q { return Double(v) / 255 } }
            return 1
        }
        return [at(Int(floor(Double(total - 1) * 0.02))), at(Int(ceil(Double(total - 1) * 0.98)))]
    }
    static func ink(source: RGB, observed: RGB?, surface: Surface,
                    fits: (RGB, inout NativeSlantedInkSafety.Audit) -> Bool) -> Ink? {
        guard source.count == 3 else { return nil }
        let candidates = [source, [17, 18, 23], [0, 0, 0], [255, 255, 255]]
        var survey = NativeSlantedInkSafety.Audit(survey: true, histogram: [Int](repeating: 0, count: 256))
        var safety = NativeSlantedInkSafety.Audit(), chosen: RGB?, specks: String?
        if fits(source, &survey) { chosen = source; safety = survey; safety.histogram = nil }
        else if survey.unsafeCount == 0, let range = survey.range, range.count == 2 {
            let lo = range[0] / 255, hi = range[1] / 255
            func contrast(_ rgb: RGB) -> Double {
                let l = NativeTranslationSourceStylePostPolish.luminance(rgb)
                return l < lo ? (lo + 0.05) / (l + 0.05) : l > hi ? (l + 0.05) / (hi + 0.05) : 1
            }
            func side(_ l: Double) -> Int { l < lo ? -1 : l > hi ? 1 : 0 }
            let adjusted = NativeTranslationSourceStylePostPolish.adjustInkForContrast(source, contrast: contrast)
            let polarity = side(NativeTranslationSourceStylePostPolish.luminance(source))
            let corrected = polarity != 0 && side(NativeTranslationSourceStylePostPolish.luminance(adjusted)) == polarity &&
                contrast(adjusted) >= 4.5 && adjusted != source ? [adjusted] : []
            for color in corrected + Array(candidates.dropFirst()) {
                if fits(color, &safety) { chosen = color; break }
            }
            if let color = chosen, let observed, observed.count == 3, let histogram = survey.histogram,
               let robust = NativeTranslationSourceStylePostPolish.robustSurfaceInk(source: source, histogram: histogram) {
                func distance(_ rgb: RGB) -> Double { zip(rgb, observed).reduce(0) { $0 + abs($1.0 - $1.1) } }
                if distance(robust.ink) < distance(color) {
                    chosen = robust.ink; safety.minimumContrast = robust.contrast; specks = "\(robust.dim)/\(robust.total)"
                }
            }
        }
        guard let chosen else { return nil }
        var accepted = NativeSlantedInkSafety.Audit(survey: true, histogram: [Int](repeating: 0, count: 256))
        _ = fits(chosen, &accepted)
        return Ink(color: chosen, safety: safety, histogram: accepted.histogram, specks: specks,
                   narrowSurvey: surface.method == "rectified-narrow-paper-glyphs" ? survey : nil)
    }
    static func fitMeasuredFont(_ input: Candidate, maximum: Double, minimum: Double,
                                measure: (Candidate) -> Measurement?) -> Candidate {
        guard maximum.isFinite, minimum.isFinite, maximum > 0, minimum > 0 else { return input }
        var c = input; let ratio = max(1, input.pitch / max(1, input.font))
        func apply(_ size: Double) { c.font = size; c.pitch = size * ratio }
        apply(maximum)
        if measure(c)?.contentFits != true && maximum > minimum {
            apply(minimum)
            if measure(c)?.contentFits == true {
                var low = minimum, high = maximum
                for _ in 0..<9 {
                    let middle = (low + high) / 2; apply(middle)
                    if measure(c)?.contentFits == true { low = middle } else { high = middle }
                }
                apply(quarter(low))
            }
        }
        return c
    }
    static func preparedEntry(_ entry: Entry, measure: (Candidate) -> Measurement?) -> Entry {
        var output = entry, c = entry.initial
        var planned: Double?, plannedLines = 0
        if let p = entry.plannedFont, p.isFinite, p < c.font {
            c = fitMeasuredFont(c, maximum: p, minimum: entry.minimumFont, measure: measure)
            planned = c.font; plannedLines = measure(c)?.lineCount ?? 0
        }
        c = fitMeasuredFont(c, maximum: entry.initial.font, minimum: entry.minimumFont, measure: measure)
        if let planned {
            let allowed = max(plannedLines, words(entry.text).count)
            while c.font > planned && (measure(c)?.lineCount ?? 0) > allowed {
                c.font = max(planned, quarter(c.font * 0.9)); c.pitch = c.font * max(1, entry.initial.pitch / max(1, entry.initial.font))
            }
        }
        output.initial = c; output.plannedFont = planned; return output
    }
    static func baseline(_ entry: Entry, measure: (Candidate) -> Measurement?) -> Candidate {
        preparedEntry(entry, measure: measure).initial
    }
    static func whitespace(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (9...13).contains(v) || [0x20,0xA0,0x1680,0x2028,0x2029,0x202F,0x205F,0x3000,0xFEFF].contains(v) || (0x2000...0x200A).contains(v)
    }
    static func words(_ text: String) -> [String] {
        text.unicodeScalars.split(whereSeparator: whitespace).map(String.init)
    }
    static func polygons(_ m: Measurement, _ c: Candidate, margin: Double = 0, paintedWidth: Double? = nil) -> [Polygon] {
        let w = paintedWidth ?? Double(c.rect.width) * c.condense, h = Double(c.rect.height)
        let cs = cos(c.angle), sn = sin(c.angle), cx = Double(c.rect.midX), cy = Double(c.rect.midY)
        return m.glyphs.filter { $0.count == 4 }.map { r in
            let dx = (r[0] + r[2]) / 2 - w / 2, dy = (r[1] + r[3]) / 2 - h / 2
            return NativeSlantedGeometry.rotatedCard(cx: cx + dx * cs - dy * sn, cy: cy + dx * sn + dy * cs,
                width: r[2] - r[0], height: r[3] - r[1], angle: c.angle, margin: margin)
        }
    }
    static func reach(_ cards: [Polygon], obstacles: [Polygon]) -> [Double] {
        obstacles.map { obstacle in cards.map { NativeSlantedGeometry.convexDepth($0, obstacle) }.max() ?? 0 }
    }
    static func lineReach(_ m: Measurement, _ c: Candidate, peers: [Peer]) -> [Double] {
        let cs = cos(c.angle), sn = sin(c.angle), cx = Double(c.rect.midX), cy = Double(c.rect.midY)
        var points: [[Double]] = []
        for r in m.lines {
            for p in [[Double(r.minX), Double(r.minY)], [Double(r.maxX), Double(r.minY)],
                      [Double(r.maxX), Double(r.maxY)], [Double(r.minX), Double(r.maxY)]] {
                let dx = (p[0] - Double(c.rect.width) / 2) * c.condense, dy = p[1] - Double(c.rect.height) / 2
                points.append([cx + dx * cs - dy * sn, cy + dx * sn + dy * cs])
            }
        }
        guard let envelope = bounds(points) else { return peers.map { _ in 0 } }
        return peers.map { peer in
            guard let b = bounds(peer.card) else { return 0 }
            let intersection = envelope.intersection(b)
            let area = intersection.isNull ? 0 : max(0, Double(intersection.width)) * max(0, Double(intersection.height))
            return area / max(1, min(Double(envelope.width * envelope.height), Double(b.width * b.height)))
        }
    }
    static func bounds(_ points: [[Double]]) -> CGRect? {
        guard !points.isEmpty, points.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) else { return nil }
        let xs = points.map { $0[0] }, ys = points.map { $0[1] }
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
    static func peerCap(_ entry: Entry, glyph: Double) -> Double {
        var cap = Double.infinity
        func key(_ text: String) -> String { String(String.UnicodeScalarView(text.unicodeScalars.filter { !whitespace($0) && !".,!?~…—-".unicodeScalars.contains($0) })) }
        let ownKey = key(entry.sourceText)
        for peer in entry.peers where peer.plannedFont > 0 {
            let peerKey = key(peer.text)
            if !peerKey.isEmpty && peerKey == ownKey { cap = min(cap, peer.plannedFont * 1.2); continue }
            guard let r = peer.source, let own = entry.sourceBounds else { continue }
            let g = peer.sourceFont.flatMap { $0 > 0 ? $0 : nil } ?? Double(min(r.width, r.height))
            guard g > 0 else { continue }
            let ratio = max(g, glyph) / min(g, glyph)
            let gap = max(own.minX - r.maxX, r.minX - own.maxX, own.minY - r.maxY, r.minY - own.maxY)
            if ratio <= 1.22 && Double(gap) <= 3 * max(g, glyph) { cap = min(cap, peer.plannedFont * 1.2) }
            guard ratio <= 1.35 else { continue }
            let row = min(own.maxY, r.maxY) - max(own.minY, r.minY) > 0.6 * min(own.height, r.height) &&
                max(own.minX, r.minX) - min(own.maxX, r.maxX) < 3 * max(own.height, r.height)
            let column = min(own.maxX, r.maxX) - max(own.minX, r.minX) > 0.6 * min(own.width, r.width) &&
                max(own.minY, r.minY) - min(own.maxY, r.maxY) < 3 * max(own.width, r.width)
            if row || column { cap = min(cap, peer.plannedFont * 1.12) }
        }
        return cap
    }
    static func inFrame(_ cards: [Polygon], _ frame: CGRect?, tolerance: Double = 0) -> Bool {
        guard let frame else { return true }
        return cards.allSatisfy { $0.allSatisfy { p in p[0] >= Double(frame.minX) - tolerance &&
            p[1] >= Double(frame.minY) - tolerance && p[0] <= Double(frame.maxX) + tolerance && p[1] <= Double(frame.maxY) + tolerance } }
    }
    static func wideCrop(center: CGPoint, width: Double, height: Double, angle: Double, frame: CGRect?) -> CGRect? {
        let cs = abs(cos(angle)), sn = abs(sin(angle)), hw = width / 2 * cs + height / 2 * sn, hh = width / 2 * sn + height / 2 * cs
        var r = CGRect(x: Double(center.x) - hw, y: Double(center.y) - hh, width: hw * 2, height: hh * 2)
        if let frame { r = r.intersection(frame) }
        return !r.isNull && r.size.width > 0 && r.size.height > 0 ? r : nil
    }
    static func run(_ entry: Entry, surface initialSurface: Surface?, hooks: Hooks) -> Result {
        let original = entry.initial.font, ratio = max(1, entry.initial.pitch / max(1, original))
        let base = entry.plannedFont.flatMap { $0.isFinite && $0 > 0 ? min(original, $0) : nil } ?? original
        let floorSize = min(base, max(8.5, min(18, base * 0.8), entry.minimumFont))
        let reflowStep = max(0.5, ceil((base - floorSize) / 16 * 2) / 2)
        var c = entry.initial, currentSurface = initialSurface, upright = entry.uprightQuad
        var result = Result(candidate: c, surface: initialSurface, foreground: entry.sourceForeground)
        result.sourceSurfaceID = initialSurface?.id
        result.metadata = ["slantedOriginalFont": String(original), "slantedBaseFont": String(base), "slantedFontFloor": String(floorSize)]
        func measure() -> Measurement? { result.measurements += 1; return hooks.measure(c) }
        func setFont(_ size: Double) { c.font = size; c.pitch = size * ratio }
        func inset(_ fraction: Double) {
            let d = Double(entry.quad.width) * (1 - fraction) / 2
            c.padding[1] = entry.initial.padding[1] + d; c.padding[3] = entry.initial.padding[3] + d; c.fraction = fraction
        }
        func commit(_ chosen: Ink, _ m: Measurement, _ surface: Surface) {
            result.accepted = true; result.candidate = c; result.measurement = m; result.surface = surface
            result.foreground = chosen.color; result.histogram = chosen.histogram; result.safety = chosen.safety
            result.metadata["sourceContrastAfter"] = String(chosen.safety.minimumContrast)
            result.metadata["slantedTextWidthFraction"] = String(c.fraction)
            result.metadata["slantedInkSpecks"] = chosen.specks
            if let a = chosen.narrowSurvey {
                result.metadata["narrowPaperFit"] = "{\"unsafe\":\(a.unsafeCount),\"dim\":\(a.dim),\"samples\":\(a.samples)}"
            }
        }
        func trial(_ size: Double, _ fraction: Double, pitch: Double? = nil, locked: Bool = false) -> Bool {
            guard let surface = currentSurface else { return false }
            inset(fraction); setFont(size); if let pitch { c.pitch = pitch }
            guard let m = measure(), m.contentFits else { return false }
            func pick() -> Ink? { ink(source: entry.sourceForeground, observed: entry.observedForeground, surface: surface) { color, audit in
                hooks.fits(surface, c, m.glyphs, color, &audit)
            } }
            var chosen = pick()
            if chosen == nil && upright && !locked {
                upright = false; c.angle = entry.initial.angle == 0 ? 0 : entry.initial.angle
                // For an upright quad the original source angle is carried separately in Entry.initial.angle.
                chosen = pick()
                if chosen != nil { result.metadata["uprightQuad"] = "rotated-for-size" } else { upright = true; c.angle = 0 }
            }
            guard let chosen else { return false }; commit(chosen, m, surface); return true
        }
        if upright { c.angle = 0 }
        let glyph = entry.sourceFont.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? Double(min(entry.quad.width, entry.quad.height))
        let ordinaryText = !entry.text.contains("\r") && !entry.text.contains("\n")
        let available = Double(entry.quad.width) - entry.initial.padding[1] - entry.initial.padding[3]
        if currentSurface != nil && !entry.vertical && glyph >= 40 && entry.canMeasureWords && entry.text.utf16.count <= 40 && ordinaryText {
            setFont(original); let beforeLines = max(1, measure()?.lineCount ?? 0)
            var size = quarter(min(128, glyph * 0.8)), tries = 0
            while !result.accepted && size > original * 1.08 && tries < 8 {
                defer { size = quarter(size * 0.9); tries += 1 }
                if hooks.longestWord(size) > available - 2 { continue }
                setFont(size)
                guard let m = measure(), m.contentFits, growthKeepsLineLength(text: entry.text, before: beforeLines, after: max(1, m.lineCount)) else { continue }
                if trial(size, 1) { result.metadata["displayGrowth"] = "slanted" }
            }
            if !result.accepted { setFont(original) }
        }
        if currentSurface != nil && !result.accepted && !entry.vertical && glyph < 40 && entry.canMeasureWords && entry.text.utf16.count <= 180 && ordinaryText {
            setFont(original)
            let beforeM = measure(), beforeLines = max(1, beforeM?.lineCount ?? 0)
            let beforeDepth = beforeM.map { reach(polygons($0, c, margin: max(2, original * 0.2)), obstacles: entry.bodyObstacles) } ?? []
            let beforeReach = beforeM.map { lineReach($0, c, peers: entry.peers) } ?? []
            let target = quarter(min(32, glyph * 0.9, max(original, peerCap(entry, glyph: glyph))))
            let count = target > original * 1.04 && !beforeReach.contains(where: { $0 > 0.25 }) ?
                min(10, Int(ceil(log(target / (original * 1.04)) / log(1 / 0.95))) + 1) : 0
            var growthSizes: [Double] = []
            for i in 0..<count {
                let size = quarter(target * pow(original * 1.04 / target, count > 1 ? Double(i) / Double(count - 1) : 0))
                if size > original && !growthSizes.contains(size) { growthSizes.append(size) }
            }
            for size in growthSizes {
                if result.accepted { break }
                let longest = hooks.longestWord(size)
                for k in [1.0, 0.9] {
                    if k < 1 ? !condensedWordBound(longest, available - 2) : longest > available - 2 { continue }
                    c.rect = entry.initial.rect; c.condense = k
                    if k < 1 {
                        let width = entry.initial.rect.width / k
                        c.rect.origin.x -= (width - entry.initial.rect.width) / 2; c.rect.size.width = width
                    }
                    setFont(size); c.padding[0] = 0; c.padding[2] = 0
                    guard let m = measure() else { continue }
                    let n = max(1, m.lineCount), pitch = min(size * ratio, Double(entry.quad.height) / Double(n))
                    if n > beforeLines || !growthKeepsLineLength(text: entry.text, before: beforeLines, after: n) || pitch < size * 1.1 { continue }
                    c.pitch = pitch
                    guard let p = measure(), max(1, p.lineCount) == n, p.wordBroken != true else { continue }
                    let depths = reach(polygons(p, c, margin: max(2, original * 0.2)), obstacles: entry.bodyObstacles)
                    let reaches = lineReach(p, c, peers: entry.peers)
                    if zip(depths, beforeDepth).contains(where: { $0.0 > $0.1 + 0.5 }) ||
                        zip(reaches, beforeReach).contains(where: { $0.0 > ($0.1 > 0 ? $0.1 + 0.001 : 0.04) }) { continue }
                    if trial(size, 1, pitch: pitch, locked: true) {
                        result.metadata["bodyGrowth"] = "slanted-ink"; if k < 1 { result.metadata["bodyCondensed"] = String(k) }; break
                    }
                }
            }
            if !result.accepted { c = entry.initial; if upright { c.angle = 0 }; setFont(original) }
        }
        if currentSurface != nil && !result.accepted {
            for size in sizes(original: original, base: base, floor: floorSize, step: 0.5) { if trial(size, 1) { break } }
        }
        if currentSurface != nil && !result.accepted && !entry.vertical && entry.sourceVertical &&
            (entry.quad.width >= entry.quad.height * 0.6 || currentSurface?.method == "rectified-narrow-paper-glyphs" ||
                (currentSurface?.isPage == true && currentSurface?.verifiedNarrowFrame == true)) {
            outer: for size in sizes(original: original, base: base, floor: floorSize, step: reflowStep) {
                for fraction in [0.9, 0.8, 0.7, 0.6, 0.5, 0.45] { if trial(size, fraction) { break outer } }
            }
        }
        if !result.accepted { inset(1) }
        if let surface = currentSurface, !result.accepted {
            let leftover = hooks.leftover?(surface)
            result.metadata["slantedPlateLeftover"] = leftover.map { "\($0.ink)/\($0.area)" } ?? "unknown"
            if let leftover, leftover.ink <= 2 {
                for size in sizes(original: original, base: base, floor: floorSize, step: 0.5) {
                    setFont(size); guard let m = measure(), m.contentFits else { continue }
                    func loose() -> Ink? {
                        for color in [entry.sourceForeground, [17, 18, 23], [0, 0, 0], [255, 255, 255]] {
                            var audit = NativeSlantedInkSafety.Audit(survey: true, histogram: [Int](repeating: 0, count: 256))
                            _ = hooks.fits(surface, c, m.glyphs, color, &audit)
                            if audit.range == nil || Double(audit.dim + audit.unsafeDim) > max(2, Double(audit.samples) * 0.0005) ||
                                Double(audit.unsafeCount) > max(4, Double(audit.samples) * 0.003) { continue }
                            return Ink(color: color, safety: audit, histogram: audit.histogram, narrowSurvey: nil)
                        }
                        return nil
                    }
                    var chosen = loose()
                    if chosen == nil && upright {
                        upright = false; c.angle = entry.initial.angle; chosen = loose()
                        if chosen != nil { result.metadata["uprightQuad"] = "rotated-for-size" } else { upright = true; c.angle = 0 }
                    }
                    if let chosen { commit(chosen, m, surface); result.metadata["slantedUnprovenPixels"] = String(chosen.safety.unsafeCount); break }
                }
            }
        }
        if result.accepted && c.condense == 1 && !entry.vertical && entry.sourceVertical && entry.wrappingKorean && result.measurement?.wordBroken == true {
            let saved = c, narrowFont = c.font
            if let surface = currentSurface, !surface.isPage,
               let crop = wideCrop(center: entry.quad.center, width: Double(entry.quad.width) * 4,
                                   height: Double(entry.quad.height), angle: c.angle, frame: entry.cropFrame ?? entry.frame),
               let wide = hooks.prepareWide?(crop) { currentSurface = wide }
            outer: for size in sizes(original: original, base: base, floor: floorSize, step: reflowStep) {
                if size < narrowFont * 0.85 - 1e-6 { break }
                setFont(size)
                for k in [1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 3.5, 4.0] {
                    let width = entry.quad.width * k
                    c.rect.origin.x = entry.quad.midX - width / 2; c.rect.size.width = width
                    guard let m = measure(), m.contentFits, m.wordBroken == false, !m.glyphs.isEmpty else { continue }
                    let cards = polygons(m, c)
                    if !inFrame(cards, entry.frame) || cards.contains(where: { q in entry.wideObstacles.contains { NativeSlantedGeometry.convexOverlap(q, $0) } }) { continue }
                    guard let surface = currentSurface else { continue }
                    let chosen = ink(source: entry.sourceForeground, observed: entry.observedForeground, surface: surface) { color, audit in
                        hooks.fits(surface, c, m.glyphs, color, &audit)
                    }
                    if let chosen { commit(chosen, m, surface); result.metadata["slantedTextWidened"] = String(floor(k * 100 + 0.5) / 100); break outer }
                }
            }
            if result.metadata["slantedTextWidened"] == nil { c = saved; currentSurface = result.surface }
        }
        if result.accepted {
            result.pendingReadableLift = !entry.vertical && entry.wrappingKorean && c.font < 8.5 && entry.canMeasureWords && entry.text.utf16.count <= 180 && ordinaryText
            result.metadata["sourceBackgroundColor"] = "slanted-glyph-restored"
            if let range = surfaceRange(result.histogram) { result.metadata["slantedSurfaceLuminance"] = "[\(range[0]),\(range[1])]" }
        } else {
            c = entry.initial; if upright { c.angle = 0 }; setFont(original); result.candidate = c; result.measurement = measure()
            result.metadata["sourceBackgroundColor"] = entry.backgroundKind == "rotated-panel" ? "rotated-panel" : "slanted-preserved"
        }
        return result
    }

    /// Runs after all cards are placed; the caller shares one 600-layout budget.
    static func lift(_ entry: Entry, result initial: Result, obstacles: [Polygon], budget: inout Int, hooks: Hooks) -> Result {
        guard initial.accepted, initial.pendingReadableLift,
              let originalSurface = initial.surface, let originalM = initial.measurement else { return initial }
        var result = initial, c = initial.candidate, surface = originalSurface
        if budget <= 0 { result.pendingReadableLift = false; return result }
        let from = c.font, center = CGPoint(x: c.rect.midX, y: entry.quad.midY)
        let originalHeight = Double(entry.quad.height), paintedWidth = Double(c.rect.width) * c.condense
        let ratio = max(1, entry.initial.pitch / max(1, entry.initial.font))
        let before = reach(polygons(originalM, c, margin: max(2, 9 * 0.25), paintedWidth: paintedWidth), obstacles: obstacles)
        var misses: [(Double, Double, Double, Double)] = [], collectMisses = true, found = false
        func measure() -> Measurement? { result.measurements += 1; return hooks.measure(c) }
        func attempt(_ size: Double, _ k: Double, _ width: Double) -> Bool {
            budget -= 1; if budget < 0 { return false }
            let side = max(1, size * 0.1), margin = max(1, size * 0.1), layoutWidth = width / k
            c = initial.candidate; c.condense = k; c.font = size; c.pitch = size * ratio
            c.rect = CGRect(x: Double(center.x) - layoutWidth / 2, y: entry.quad.minY,
                            width: layoutWidth, height: max(originalHeight, size * 1.2) * 8)
            c.padding = [0, side / k, 0, side / k]
            guard let first = measure(), first.lineCount > 0 else { return false }
            let pitch = size * max(1.1, min(1.2, ratio)), height = max(originalHeight, Double(first.lineCount) * pitch + margin * 2)
            c.rect.size.height = height; c.rect.origin.y = Double(center.y) - height / 2; c.pitch = pitch
            guard let m = measure(), m.contentFits, m.lineCount == first.lineCount, m.wordBroken == false, !m.glyphs.isEmpty else { return false }
            let cards = polygons(m, c, paintedWidth: width)
            if !inFrame(cards, entry.frame, tolerance: 0.5) { return false }
            let depths = reach(polygons(m, c, margin: max(2, size * 0.25), paintedWidth: width), obstacles: obstacles)
            if zip(depths, before).contains(where: { $0.0 > $0.1 + 0.5 }) { return false }
            let g = max(1, size * 0.12), probe = m.glyphs.map { [$0[0] - g, $0[1] - g, $0[2] + g, $0[3] + g] }
            let chosen = ink(source: entry.sourceForeground, observed: entry.observedForeground, surface: surface) { color, audit in
                hooks.fits(surface, c, probe, color, &audit)
            }
            guard let chosen else { if collectMisses { misses.append((size, k, width, height)) }; return false }
            result.candidate = c; result.measurement = m; result.foreground = chosen.color; result.surface = surface
            result.safety = chosen.safety; result.histogram = chosen.histogram
            result.metadata["sourceContrastAfter"] = String(chosen.safety.minimumContrast)
            result.metadata["slantedInkSpecks"] = chosen.specks
            result.metadata["readableLift"] = "\(number(from))->\(number(size))"; result.metadata["readablePeer"] = String(from)
            result.metadata["readableLiftBox"] = "\(number(floor(width / paintedWidth * 100 + 0.5) / 100))x\(number(floor(height / originalHeight * 100 + 0.5) / 100))"
            result.metadata["bodyCondensed"] = k < 1 ? String(k) : nil
            if surface.id != originalSurface.id { result.metadata["readableLiftSurface"] = "widened" }
            else if surface.expandedPaper { result.metadata["readableLiftSurface"] = "paper" }
            result.pendingReadableLift = false; found = true; return true
        }
        let liftSizes = [9.0, 8.75, 8.5].filter { $0 >= from + 0.25 && $0 <= from * 2 }
        outer: for factor in [1.0, 1.15, 1.3, 1.5, 1.75, 2.0, 2.5] {
            for size in liftSizes {
                let width = paintedWidth * factor, bound = width - max(1, size * 0.1) * 2, longest = hooks.longestWord(size)
                for k in [1.0, 0.9] {
                    if k < 1 ? !condensedWordBound(longest, bound) : longest > bound { continue }
                    if attempt(size, k, width) { break outer }
                }
            }
        }
        if !found && !misses.isEmpty && !surface.isPage, let paper = paperExpanded(surface) {
            surface = paper; let retry = misses; misses = []
            for m in retry { if attempt(m.0, m.1, m.2) { break } }
            if !found { surface = originalSurface }
        }
        if !found && !misses.isEmpty && !surface.isPage && surface.id == initial.surface?.id &&
            initial.sourceSurfaceID == originalSurface.id {
            let width = (misses.map { $0.2 }.max() ?? 0) + 8, height = (misses.map { $0.3 }.max() ?? 0) + 8
            if let crop = wideCrop(center: center, width: width, height: height, angle: c.angle, frame: entry.frame),
               let wide = hooks.prepareWide?(crop) {
                surface = wide; let retry = misses; collectMisses = false
                for m in retry { if attempt(m.0, m.1, m.2) { break } }
            }
        }
        if !found {
            // Keep only cost accounting; every visible property and diagnostic is restored.
            var back = initial; back.measurements = result.measurements; back.pendingReadableLift = false; return back
        }
        return result
    }
    static func paperExpanded(_ surface: Surface) -> Surface? {
        let w = surface.width, h = surface.height
        guard w >= 3, h >= 3, w <= Int.max / h, surface.safe.count == w * h, surface.luminance.count == w * h else { return nil }
        var histogram = [Int](repeating: 0, count: 256), total = 0
        for i in 0..<(w * h) where surface.safe[i] != 0 { histogram[Int(surface.luminance[i])] += 1; total += 1 }
        guard total >= 64 else { return nil }
        var n = 0, median = 255
        for value in 0..<256 { n += histogram[value]; if n > total / 2 { median = value; break } }
        let flat = histogram[max(0, median - 6)...min(255, median + 6)].reduce(0, +)
        guard Double(flat) >= Double(total) * 0.85 else { return nil }
        var paper = surface
        func near(_ i: Int) -> Bool { abs(Int(surface.luminance[i]) - median) <= 4 }
        for y in 1..<(h - 1) { for x in 1..<(w - 1) {
            let i = y * w + x
            if paper.safe[i] == 0 && near(i) && near(i - 1) && near(i + 1) && near(i - w) && near(i + w) { paper.safe[i] = 1 }
        } }
        paper.expandedPaper = true; return paper
    }
    struct Clip {
        var result: Result
        var polygon: Polygon?
    }
    /// Final opaque upright-quad plate fit and image clipping, in container axes.
    static func finalClip(_ entry: Entry, result initial: Result, measure: (Candidate) -> Measurement?) -> Clip {
        var result = initial, c = initial.candidate
        let upright = c.angle == 0 && entry.uprightQuad && !result.accepted && entry.backgroundKind == "rotated-panel"
        let outline: Polygon? = upright ? NativeSlantedGeometry.rotatedCard(cx: entry.quad.midX, cy: entry.quad.midY,
            width: entry.quad.width, height: entry.quad.height, angle: entry.initial.angle, margin: 2) : nil
        if let outline {
            let start = c.font, ratio = max(1, entry.initial.pitch / max(1, entry.initial.font))
            func inside() -> Bool {
                guard let m = measure(c) else { return true }
                return m.rangeRects.allSatisfy { r in
                    [[Double(r.minX + entry.quad.minX), Double(r.minY + entry.quad.minY)],
                     [Double(r.maxX + entry.quad.minX), Double(r.minY + entry.quad.minY)],
                     [Double(r.maxX + entry.quad.minX), Double(r.maxY + entry.quad.minY)],
                     [Double(r.minX + entry.quad.minX), Double(r.maxY + entry.quad.minY)]].allSatisfy {
                        NativeSlantedGeometry.pointInConvex(outline, point: $0)
                    }
                }
            }
            while c.font > entry.minimumFont && !inside() {
                c.font = max(entry.minimumFont, floor((c.font - 0.25) * 4 + 0.5) / 4); c.pitch = c.font * ratio
            }
            if c.font != start { result.metadata["uprightQuadFit"] = "\(start)->\(c.font)" }
            result.candidate = c; result.measurement = measure(c)
        }
        guard let frame = entry.frame else { return Clip(result: result) }
        var corners: Polygon = [[frame.minX, frame.minY], [frame.maxX, frame.minY], [frame.maxX, frame.maxY], [frame.minX, frame.maxY]]
        if let outline { corners = NativeSlantedGeometry.clipConvex(subject: corners, clip: outline) }
        let cs = cos(c.angle), sn = sin(c.angle), cx = Double(c.rect.midX), cy = Double(c.rect.minY + entry.quad.height / 2)
        let polygon = corners.map { p in
            [((p[0] - cx) * cs + (p[1] - cy) * sn) / c.condense + Double(c.rect.width) / 2,
             -(p[0] - cx) * sn + (p[1] - cy) * cs + Double(entry.quad.height) / 2]
        }
        return Clip(result: result, polygon: polygon)
    }
    struct Upright {
        var rect: CGRect
        var content: CGRect
        var font: Double
        var pitch: Double
    }
    /// Earlier alternative placement is independent of late quad restoration.
    static func upright(_ entry: Entry, alternative: Upright, surface: Surface, obstacles: [CGRect], hooks: Hooks) -> Result? {
        let fields = [alternative.rect.minX, alternative.rect.minY, alternative.rect.width, alternative.rect.height,
                      alternative.content.minX, alternative.content.minY, alternative.content.width, alternative.content.height,
                      CGFloat(alternative.font), CGFloat(alternative.pitch)]
        guard !entry.vertical, fields.allSatisfy(\.isFinite), alternative.rect.size.width > 0, alternative.rect.size.height > 0 else { return nil }
        if let frame = entry.frame, alternative.rect.minX < frame.minX - 0.5 || alternative.rect.minY < frame.minY - 0.5 ||
            alternative.rect.maxX > frame.maxX + 0.5 || alternative.rect.maxY > frame.maxY + 0.5 { return nil }
        let ratio = max(1, alternative.pitch / max(1, alternative.font))
        let floorSize = max(entry.minimumFont, min(alternative.font, max(8.5, entry.initial.font * 0.85)))
        var size = max(alternative.font, entry.initial.font), measurements = 0
        while size >= floorSize - 1e-6 {
            for fraction in [1.0, 0.8, 0.65] {
                let inset = Double(alternative.content.width) * (1 - fraction) / 2
                var c = Candidate(rect: alternative.rect, font: size, pitch: size * ratio,
                    padding: [Double(alternative.content.minY - alternative.rect.minY),
                              Double(alternative.rect.maxX - alternative.content.maxX) + inset,
                              Double(alternative.rect.maxY - alternative.content.maxY),
                              Double(alternative.content.minX - alternative.rect.minX) + inset], angle: 0, fraction: fraction)
                measurements += 1
                guard let m = hooks.measure(c), m.contentFits, !m.glyphs.isEmpty, m.wordBroken != true else { continue }
                var shifts = [CGPoint.zero]
                for d in [2.0, 4, 6, 9] { shifts += [CGPoint(x: -d, y: 0), CGPoint(x: d, y: 0), CGPoint(x: 0, y: -d), CGPoint(x: 0, y: d)] }
                for shift in shifts {
                    c.rect = alternative.rect
                    let pageRects = m.glyphs.map { r in CGRect(x: r[0] + Double(c.rect.minX + shift.x), y: r[1] + Double(c.rect.minY + shift.y),
                        width: r[2] - r[0], height: r[3] - r[1]) }
                    if pageRects.contains(where: { r in
                        let leaves = shift != .zero && (r.minX < alternative.rect.minX || r.minY < alternative.rect.minY ||
                            r.maxX > alternative.rect.maxX || r.maxY > alternative.rect.maxY)
                        return leaves || obstacles.contains { $0.intersects(r) }
                    }) { continue }
                    c.rect.origin.x = alternative.rect.minX + shift.x; c.rect.origin.y = alternative.rect.minY + shift.y
                    var safety = NativeSlantedInkSafety.Audit(), picked: RGB?
                    for color in [entry.sourceForeground, [17, 18, 23], [0, 0, 0], [255, 255, 255]] {
                        if hooks.fits(surface, c, m.glyphs, color, &safety) { picked = color; break }
                    }
                    guard var color = picked else { continue }
                    var specks: String?
                    if color != entry.sourceForeground {
                        var survey = NativeSlantedInkSafety.Audit(survey: true, histogram: [Int](repeating: 0, count: 256))
                        _ = hooks.fits(surface, c, m.glyphs, entry.sourceForeground, &survey)
                        if survey.unsafeCount == 0, let observed = entry.observedForeground, let hist = survey.histogram,
                           let robust = NativeTranslationSourceStylePostPolish.robustSurfaceInk(source: entry.sourceForeground, histogram: hist) {
                            func distance(_ rgb: RGB) -> Double { zip(rgb, observed).reduce(0) { $0 + abs($1.0 - $1.1) } }
                            if distance(robust.ink) < distance(color) { color = robust.ink; safety.minimumContrast = robust.contrast; specks = "\(robust.dim)/\(robust.total)" }
                        }
                    }
                    var result = Result(candidate: c, measurement: m, surface: surface, foreground: color, accepted: true, safety: safety,
                                        measurements: measurements)
                    result.metadata = ["uprightFromSlant": "true", "sourceBackgroundColor": "slanted-glyph-restored",
                        "uprightSourceRotation": String(entry.initial.angle), "sourceContrastAfter": String(safety.minimumContrast)]
                    result.metadata["slantedInkSpecks"] = specks
                    return result
                }
            }
            size = floor((size - 0.5) * 4 + 0.5) / 4
        }
        return nil
    }
}
private extension CGRect { var center: CGPoint { CGPoint(x: midX, y: midY) } }
