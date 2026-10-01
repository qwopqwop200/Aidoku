import CoreGraphics
import Foundation

/// Native page-wide font and word-flow policy. Source geometry determines cohorts;
/// Core Text glyph bounds decide whether each proposed change can actually paint.
enum NativeTypographyPostPolish {
    struct FontEntry: Codable, Equatable {
        let id: String
        let source: CGFloat
        let font: CGFloat
        let script: String
        let vertical: Bool
        let column: Bool
        var kept = false
    }
    struct FontCluster: Codable, Equatable {
        let members: [FontEntry]
        let font: CGFloat
    }
    struct StyleRecord: Codable, Equatable {
        let key: String
        let glyph: CGFloat
        let font: CGFloat
    }
    struct StyleGroup: Codable, Equatable {
        let members: [Int]
        let font: CGFloat
    }
    struct SourceBox: Codable, Equatable {
        let x: CGFloat
        let y: CGFloat
        let w: CGFloat
        let h: CGFloat
        let glyph: CGFloat
        let script: String
        let vertical: Bool
        let style: String
        var valid: Bool { [x, y, w, h, glyph].allSatisfy(\.isFinite) && w > 0 && h > 0 && glyph > 0 }
    }
    struct Link: Codable, Equatable {
        let a: Int
        let b: Int
        let axis: String
        let edge: CGFloat?
        let gap: CGFloat
    }
    struct AlignedGroup: Codable, Equatable {
        var members: [Int]
        var links: [Link]
    }
    struct Profile: Codable, Equatable {
        let lines: Int
        let breaks: [Int]
        let badStarts: [Int]
        let badEnds: [Int]
        let hangulFragments: Int
        let punctuationOnly: Int
        let hangulIsolated: Int
        var penalty: Int {
            breaks.count * 4 + (hangulFragments + punctuationOnly + badStarts.count + badEnds.count) * 12
        }
    }

    private static func completeLink<T>(_ values: [T], compatible: (T, T) -> Bool, less: (T, T) -> Bool) -> [[T]] {
        var groups: [[T]] = []
        for value in values.sorted(by: less) {
            if let index = groups.firstIndex(where: { $0.allSatisfy { compatible(value, $0) } }) {
                groups[index].append(value)
            } else { groups.append([value]) }
        }
        return groups
    }
    private static func roundedQuarter(_ number: CGFloat) -> CGFloat { floor(number * 4 + 0.5) / 4 }
    private static func quarterFloor(_ number: CGFloat) -> CGFloat { floor(number * 4) / 4 }
    private static func compare(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [], range: nil, locale: Locale(identifier: "en_US")) == .orderedAscending
    }

    static func fontClusters(_ entries: [FontEntry]) -> [FontCluster] {
        guard entries.count <= 256 else { return [] }
        let valid = entries.filter { $0.source.isFinite && $0.source > 0 && $0.font.isFinite && $0.font >= 5 }
        return completeLink(valid, compatible: { a, b in
            a.script == b.script && a.vertical == b.vertical && a.column == b.column &&
                max(a.source, b.source) / min(a.source, b.source) <= 1.22
        }, less: { a, b in
            if a.source != b.source { return a.source < b.source }
            if a.font != b.font { return a.font < b.font }
            return compare(a.id, b.id)
        }).filter { $0.count >= 2 }.map { group in
            let fonts = group.map(\.font).sorted(), sources = group.map(\.source).sorted()
            let median = (fonts[fonts.count / 2] + fonts[(fonts.count - 1) / 2]) / 2
            let readable = min(sources[sources.count / 2] * 0.9, median * 1.15, 10.5)
            return FontCluster(members: group, font: roundedQuarter(max(median, readable)))
        }
    }

    static func fontClusterTargets(_ entries: [FontEntry], kept: [FontEntry] = [],
                                   raisable: (FontEntry) -> Bool = { _ in true }) -> [String: CGFloat] {
        var targets: [String: CGFloat] = [:]
        for cluster in fontClusters(entries) {
            for entry in cluster.members { targets[entry.id] = cluster.font }
        }
        guard !kept.isEmpty else { return targets }
        let joined = entries + kept.map { entry in var copy = entry; copy.kept = true; return copy }
        for cluster in fontClusters(joined) where cluster.members.contains(where: \.kept) {
            for entry in cluster.members where !entry.kept && raisable(entry) {
                if cluster.font > (targets[entry.id] ?? entry.font) { targets[entry.id] = cluster.font }
            }
        }
        return targets
    }

    static func pageStyleGroups(_ records: [StyleRecord], tolerance: CGFloat = 1.15) -> [StyleGroup] {
        guard records.count <= 256 else { return [] }
        let valid = records.enumerated().filter { $0.element.glyph.isFinite && $0.element.glyph > 0 &&
            $0.element.font.isFinite && $0.element.font > 0 }
        return completeLink(valid, compatible: { a, b in
            a.element.key == b.element.key &&
                max(a.element.glyph, b.element.glyph) / min(a.element.glyph, b.element.glyph) <= tolerance
        }, less: { a, b in
            if a.element.key != b.element.key { return compare(a.element.key, b.element.key) }
            if a.element.glyph != b.element.glyph { return a.element.glyph < b.element.glyph }
            return a.offset < b.offset
        }).filter { $0.count >= 2 }.map { group in
            let fonts = group.map { $0.element.font }.sorted()
            let upper = Array(fonts.dropFirst(fonts.count / 2))
            return StyleGroup(members: group.map(\.offset), font: upper[(upper.count - 1) / 2])
        }
    }

    static func alignedGroups(_ boxes: [SourceBox?]) -> [AlignedGroup] {
        guard boxes.count >= 2, boxes.count <= 256 else { return [] }
        var links: [Link] = []
        for i in boxes.indices {
            for j in boxes.indices where j > i {
                guard let a = boxes[i], let b = boxes[j], a.valid, b.valid,
                      a.script == b.script, a.vertical == b.vertical, a.style == b.style else { continue }
                let small = min(a.glyph, b.glyph), large = max(a.glyph, b.glyph)
                guard large / small <= 1.25 else { continue }
                let xo = min(a.x + a.w, b.x + b.w) - max(a.x, b.x)
                let yo = min(a.y + a.h, b.y + b.h) - max(a.y, b.y)
                let tolerance = max(2, small * 0.25)
                let nested = max(0, xo) * max(0, yo) >= 0.5 * min(a.w * a.h, b.w * b.h)
                var axis: String?, edge: CGFloat?, gap: CGFloat = 0
                if nested { axis = a.vertical ? "x" : "y" }
                else if !a.vertical {
                    if yo >= 0.6 * min(a.h, b.h), -xo >= -0.25 * small, -xo <= 6 * large {
                        axis = "y"; edge = alignedEdge(a, b, axis: "y", tolerance: tolerance); gap = -xo
                    } else if xo >= 0.5 * min(a.w, b.w), -yo >= -0.25 * small, -yo <= 2 * large,
                              let e = alignedEdge(a, b, axis: "x", tolerance: tolerance) {
                        axis = "x"; edge = e; gap = -yo
                    }
                } else if xo >= 0.6 * min(a.w, b.w), -yo >= -0.25 * small, -yo <= 3 * large {
                    axis = "x"; edge = alignedEdge(a, b, axis: "x", tolerance: tolerance) == 0.5 ? 0.5 : nil; gap = -yo
                } else if yo >= 0.5 * min(a.h, b.h), -xo >= -0.25 * small, -xo <= 2 * large,
                          alignedEdge(a, b, axis: "y", tolerance: tolerance) != nil {
                    axis = "y"; gap = -xo
                }
                if let axis { links.append(Link(a: i, b: j, axis: axis, edge: edge, gap: gap)) }
            }
        }
        links.sort { a, b in a.gap != b.gap ? a.gap < b.gap : a.a != b.a ? a.a < b.a : a.b < b.b }
        var parents = Array(boxes.indices), lows = boxes.map { $0?.glyph ?? .nan }, highs = lows
        func find(_ index: Int) -> Int {
            if parents[index] == index { return index }
            parents[index] = find(parents[index]); return parents[index]
        }
        for link in links {
            let a = find(link.a), b = find(link.b)
            if a == b { continue }
            let low = min(lows[a], lows[b]), high = max(highs[a], highs[b])
            if high / low > 1.3 { continue }
            parents[b] = a; lows[a] = low; highs[a] = high
        }
        var groups: [AlignedGroup] = [], roots: [Int] = []
        for i in boxes.indices where boxes[i]?.valid == true {
            let root = find(i)
            if let index = roots.firstIndex(of: root) { groups[index].members.append(i) }
            else { roots.append(root); groups.append(AlignedGroup(members: [i], links: [])) }
        }
        for link in links where find(link.a) == find(link.b) {
            if let index = roots.firstIndex(of: find(link.a)) { groups[index].links.append(link) }
        }
        return groups.filter { $0.members.count >= 2 }
    }

    private static func alignedEdge(_ a: SourceBox, _ b: SourceBox, axis: String, tolerance: CGFloat,
                                    choices: [CGFloat] = [0.5, 0, 1]) -> CGFloat? {
        let p = axis == "x" ? a.x : a.y, s = axis == "x" ? a.w : a.h
        let q = axis == "x" ? b.x : b.y, t = axis == "x" ? b.w : b.h
        var best = choices[0], distance = CGFloat.infinity
        for edge in choices {
            let next = abs(p + edge * s - q - edge * t)
            if next < distance { distance = next; best = edge }
        }
        return distance <= tolerance ? best : nil
    }

    static func columnRowLinks(_ boxes: [SourceBox?]) -> [Link] {
        guard boxes.count >= 2, boxes.count <= 256 else { return [] }
        var links: [Link] = []
        for i in boxes.indices {
            for j in boxes.indices where j > i {
                guard let a = boxes[i], let b = boxes[j], a.valid, b.valid, a.vertical, b.vertical,
                      a.script == b.script, a.style == b.style else { continue }
                let small = min(a.glyph, b.glyph), large = max(a.glyph, b.glyph)
                guard large / small <= 1.25 else { continue }
                let xo = min(a.x + a.w, b.x + b.w) - max(a.x, b.x)
                let yo = min(a.y + a.h, b.y + b.h) - max(a.y, b.y)
                guard yo >= 0.5 * min(a.h, b.h), -xo >= -0.25 * small, -xo <= 3 * large,
                      max(0, xo) * yo < 0.5 * min(a.w * a.h, b.w * b.h),
                      let edge = alignedEdge(a, b, axis: "y", tolerance: max(2, small * 0.25), choices: [0, 0.5, 1])
                else { continue }
                links.append(Link(a: i, b: j, axis: "y", edge: edge, gap: -xo))
            }
        }
        return links
    }

    static func cohortFontCandidates(original: CGFloat, target: CGFloat, minimum: CGFloat) -> [CGFloat] {
        guard [original, target, minimum].allSatisfy(\.isFinite), original > 0 else { return [] }
        let desired = roundedQuarter(max(original * 0.75, min(original, 7.5), min(target, original + 3)))
        guard desired >= minimum, abs(desired - original) >= 0.01 else { return [] }
        var values: [CGFloat] = [], size = desired
        if desired < original {
            while size < original, values.count < 13 { values.append(size); size += 0.25 }
        } else {
            while size > original, size >= minimum, values.count < 13 { values.append(size); size -= 0.25 }
        }
        return values
    }
    static func fontFlowFits(_ candidate: Profile, _ baseline: Profile, extraWordBreaks: Int = 0) -> Bool {
        candidate.breaks.count <= baseline.breaks.count + extraWordBreaks &&
            candidate.badStarts.count <= baseline.badStarts.count && candidate.badEnds.count <= baseline.badEnds.count &&
            candidate.hangulFragments <= baseline.hangulFragments && candidate.punctuationOnly <= baseline.punctuationOnly
    }
    static func koreanWrapImproves(_ candidate: Profile, _ baseline: Profile) -> Bool {
        guard candidate.lines <= baseline.lines else { return false }
        let next = [candidate.breaks.count, candidate.hangulFragments, candidate.punctuationOnly,
                    candidate.badStarts.count, candidate.badEnds.count]
        let previous = [baseline.breaks.count, baseline.hangulFragments, baseline.punctuationOnly,
                        baseline.badStarts.count, baseline.badEnds.count]
        return zip(next, previous).allSatisfy { $0 <= $1 } && zip(next, previous).contains { $0 < $1 }
    }
    static func styleColorClass(_ color: CGColor?) -> String {
        guard let color, let converted = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
              let components = converted.components, components.count >= 3,
              components.prefix(3).allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else { return "?" }
        let r = components[0], g = components[1], b = components[2], high = max(r, g, b), low = min(r, g, b)
        if (high - low) * 255 > 60 {
            let h = high == r ? ((g - b) / (high - low) + 6).truncatingRemainder(dividingBy: 6)
                : high == g ? (b - r) / (high - low) + 2 : (r - g) / (high - low) + 4
            return "h\(Int(floor((h * 60 + 30).truncatingRemainder(dividingBy: 360) / 60)))"
        }
        let l = 0.299 * r + 0.587 * g + 0.114 * b
        return l < 0.3 ? "dark" : l > 0.72 ? "light" : "mid"
    }

    /// Frozen browser dispatch: narrow default=0, narrow strict=1, wide=2.
    /// Wide lines use code-point advances, then exact whole-line shaping validates them.
    static func wordLines(text: String, size: CGSize, style: NativeTranslationTypography.Style,
                          maxLines: Int, wide: Bool = false, strict: Bool? = nil, any: Bool = false) -> [String]? {
        guard !text.contains(where: \.isNewline), text.utf16.count <= 180, maxLines >= 1,
              any || (size.width / style.fontSize > 8) == wide else { return nil }
        var lineStyle = style
        lineStyle.koreanQuoteMode = wide ? 2 : (strict ?? wide) ? 1 : 0
        func lines(_ width: CGFloat, _ count: Int, scalar: Bool) -> [String]? {
            NativeTranslationTypography.koreanLines(text: text, available: CGSize(width: width, height: size.height),
                                                   style: lineStyle, maxLines: count, measuresScalars: scalar)
        }
        if !wide {
            guard let result = lines(size.width, maxLines, scalar: false), result.count >= 2 else { return nil }
            return result
        }
        func clean(_ candidate: [String]?) -> Bool {
            guard let candidate, candidate.count >= 2 else { return false }
            guard candidate.dropLast().allSatisfy({ $0.last?.isWhitespace == true }) else { return false }
            return candidate.allSatisfy { line in
                let visible = line.precomposedStringWithCanonicalMapping.unicodeScalars.filter {
                    !CharacterSet.punctuationCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0)
                }
                if visible.count == 1, let scalar = visible.first, isHangul(scalar) { return false }
                return NativeTranslationTypography.measuredWidth(text: line.trimmingCharacters(in: .whitespacesAndNewlines),
                                                                 style: lineStyle) <= size.width + 0.25
            }
        }
        let first = lines(size.width - 1, maxLines, scalar: true)
        guard clean(first), let first else { return nil }
        var result = first
        for factor: CGFloat in [0.92, 0.85, 0.78, 0.72, 0.66] {
            let narrower = lines((size.width - 1) * factor, first.count, scalar: true)
            guard clean(narrower), let narrower, narrower.count == first.count else { break }
            result = narrower
        }
        return result
    }

    private static func isHangul(_ scalar: Unicode.Scalar) -> Bool {
        (0x1100...0x11FF).contains(scalar.value) ||
            (0x302E...0x302F).contains(scalar.value) ||
            (0x3131...0x318E).contains(scalar.value) ||
            (0x3200...0x321E).contains(scalar.value) ||
            (0x3260...0x327E).contains(scalar.value) ||
            (0xA960...0xA97C).contains(scalar.value) ||
            (0xAC00...0xD7A3).contains(scalar.value) ||
            (0xD7B0...0xD7C6).contains(scalar.value) ||
            (0xD7CB...0xD7FB).contains(scalar.value) ||
            (0xFFA0...0xFFBE).contains(scalar.value) ||
            (0xFFC2...0xFFC7).contains(scalar.value) ||
            (0xFFCA...0xFFCF).contains(scalar.value) ||
            (0xFFD2...0xFFD7).contains(scalar.value) ||
            (0xFFDA...0xFFDC).contains(scalar.value)
    }

    /// The line profile uses UTF-16 offsets like the browser and ignores whitespace
    /// when locating the first/last visible glyph. Controlled newlines are removed
    /// from that offset space so split-word comparisons retain the original text.
    static func profile(_ shaped: NativeTranslationTypography.Layout, originalText: String? = nil) -> Profile {
        let text = shaped.shapedText as NSString
        var lines = 0, breaks: [Int] = [], starts: [Int] = [], ends: [Int] = []
        var punctuationOnly = 0, isolated = 0, previousEnd: Int?, previousEndScalar: Unicode.Scalar?
        let opening = Set("（([「『【《〈".unicodeScalars), closing = Set("、。，．,.！？!?…‥）)]」』】》〉:;".unicodeScalars)
        var concatenated = "", rowSlices: [(String, Int)] = []
        for range in shaped.lineRanges where range.location >= 0 && NSMaxRange(range) <= text.length {
            let raw = text.substring(with: range)
            let content = originalText?.contains(where: \.isNewline) == true ? raw : raw.replacingOccurrences(of: "\n", with: "")
            let base = concatenated.utf16.count
            concatenated += content
            rowSlices.append((content, base))
        }
        var sourceScalars: [(Unicode.Scalar, Int)] = [], sourceOffset = 0
        if let originalText {
            for scalar in originalText.unicodeScalars {
                if !CharacterSet.whitespacesAndNewlines.contains(scalar) { sourceScalars.append((scalar, sourceOffset)) }
                sourceOffset += scalar.utf16.count
            }
        }
        let paintedScalars = rowSlices.flatMap { $0.0.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) } }
        let usesSourceOffsets = sourceScalars.count == paintedScalars.count &&
            zip(sourceScalars, paintedScalars).allSatisfy { $0.0.0 == $0.1 }
        var sourceIndex = 0
        for (content, base) in rowSlices {
            var visible: [(Unicode.Scalar, Int)] = [], offset = base
            for scalar in content.unicodeScalars {
                if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    visible.append((scalar, usesSourceOffsets ? sourceScalars[sourceIndex].1 : offset))
                    sourceIndex += 1
                }
                offset += scalar.utf16.count
            }
            guard let first = visible.first, let last = visible.last else { continue }
            lines += 1
            if closing.contains(first.0) { starts.append(first.1) }
            if opening.contains(last.0) { ends.append(last.1) }
            if let previousEnd, let previousEndScalar,
               previousEnd + previousEndScalar.utf16.count == first.1 { breaks.append(first.1) }
            previousEnd = last.1; previousEndScalar = last.0
            if visible.allSatisfy({ CharacterSet.punctuationCharacters.contains($0.0) }) { punctuationOnly += 1 }
            let normalized = String(String.UnicodeScalarView(visible.map(\.0))).precomposedStringWithCanonicalMapping.unicodeScalars
                .filter { !CharacterSet.punctuationCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0) }
            if normalized.count == 1, let scalar = normalized.first, isHangul(scalar) { isolated += 1 }
        }
        var fragments = 0, runStart: Int?, offset = 0
        func countRun(_ start: Int, _ end: Int) {
            let cuts = Array(Set(breaks.filter { $0 > start && $0 < end })).sorted()
            guard !cuts.isEmpty else { return }
            let bounds = [start] + cuts + [end]
            for i in 1..<bounds.count where bounds[i] - bounds[i - 1] == 1 { fragments += 1 }
        }
        for scalar in (usesSourceOffsets ? originalText! : concatenated).unicodeScalars {
            if isHangul(scalar) { if runStart == nil { runStart = offset } }
            else if let start = runStart { countRun(start, offset); runStart = nil }
            offset += scalar.utf16.count
        }
        if let start = runStart { countRun(start, offset) }
        return Profile(lines: lines, breaks: breaks, badStarts: starts, badEnds: ends,
                       hangulFragments: fragments, punctuationOnly: punctuationOnly, hangulIsolated: isolated)
    }

    static func growthKeepsLineLength(text: String, originalLines: Int, lines: Int) -> Bool {
        let count = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            .reduce(0) { $0 + $1.utf16.count }
        guard count > 0, lines >= 1 else { return false }
        if lines < 3 || count < 8 { return true }
        let before = CGFloat(count) / CGFloat(max(1, originalLines)), after = CGFloat(count) / CGFloat(lines)
        return after >= 2.5 || after >= before
    }

    static func condensedWordBound(longest: CGFloat, available: CGFloat) -> Bool {
        longest > available && longest * 0.9 <= available
    }
    static func condensedSizes(base: CGFloat, target: CGFloat) -> [CGFloat] {
        guard base > 0, target > 0 else { return [] }
        var values: [CGFloat] = []
        for gain: CGFloat in [1.25, 1.17, 1.11, 1.06] {
            let size = quarterFloor(min(target, base * gain))
            if size >= base * 1.06, !values.contains(size) { values.append(size) }
        }
        return values
    }
    static func koreanWordWidth(text: String, style: NativeTranslationTypography.Style) -> CGFloat {
        guard style.fontSize.isFinite, style.fontSize > 0 else { return 0 }
        let words = text.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return 0 }
        return (words.map { NativeTranslationTypography.measuredWidth(text: String($0), style: style) }.max() ?? 0) + 1
    }
    static func belowReadableSource(_ glyph: CGFloat) -> Bool { glyph.isFinite && glyph > 0 && glyph * 0.9 < 9 }

    static func interfaceRows(_ boxes: [SourceBox?], texts: [String], frame: [CGFloat]) -> [[Int]] {
        guard boxes.count <= 256, texts.count == boxes.count, frame.count == 4,
              frame.allSatisfy(\.isFinite), frame[3] > 0 else { return [] }
        let separators = CharacterSet(charactersIn: ",，、·・|/").union(.whitespacesAndNewlines)
        func words(_ i: Int) -> [String] { texts[i].components(separatedBy: separators).filter { !$0.isEmpty } }
        func label(_ i: Int) -> Bool {
            guard let b = boxes[i], b.valid, !b.vertical, b.glyph <= frame[3] * 0.06, b.h <= b.glyph * 2.2 else { return false }
            let stripped = texts[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if stripped.range(of: #"[.!?。！？…‥~～]["'」』）)]*$"#, options: .regularExpression) != nil { return false }
            let y = b.y + b.h / 2
            return y >= frame[1] + frame[3] * 0.82 || y <= frame[1] + frame[3] * 0.12
        }
        var rows: [[Int]] = []
        for i in boxes.indices where label(i) {
            let w = words(i), letters = texts[i].unicodeScalars.filter { !separators.contains($0) }.count
            if w.count >= 4, w.allSatisfy({ $0.unicodeScalars.count <= 4 }),
               let b = boxes[i], b.w >= 1.2 * b.glyph * CGFloat(letters) { rows.append([i]) }
        }
        let candidates = boxes.indices.filter { label($0) && !words($0).isEmpty && words($0).allSatisfy { $0.unicodeScalars.count <= 6 } }
            .sorted { (boxes[$0]?.x ?? 0) < (boxes[$1]?.x ?? 0) }
        var parents = Dictionary(uniqueKeysWithValues: candidates.map { ($0, $0) })
        func find(_ i: Int) -> Int { parents[i] == i ? i : find(parents[i]!) }
        for p in candidates.indices {
            for q in candidates.indices where q > p {
                let i = candidates[p], j = candidates[q]
                guard let a = boxes[i], let b = boxes[j] else { continue }
                let large = max(a.glyph, b.glyph)
                guard large / min(a.glyph, b.glyph) <= 1.4,
                      abs(a.y + a.h / 2 - b.y - b.h / 2) <= 0.6 * large else { continue }
                let gap = max(a.x, b.x) - min(a.x + a.w, b.x + b.w)
                if gap > 8 * large { continue }
                parents[find(j)] = find(i)
            }
        }
        var groups: [[Int]] = [], roots: [Int] = []
        for i in candidates {
            let root = find(i)
            if let index = roots.firstIndex(of: root) { groups[index].append(i) }
            else { roots.append(root); groups.append([i]) }
        }
        rows += groups.filter { $0.count >= 3 }.map { $0.sorted() }
        return rows
    }

    static func badBreak(text: String, offset: Int) -> Bool {
        let units = Array(text.utf16)
        func hangul(_ index: Int) -> Bool { units.indices.contains(index) && (0xAC00...0xD7A3).contains(units[index]) }
        guard offset > 0, hangul(offset - 1), hangul(offset) else { return false }
        var start = offset
        while start > 0, hangul(start - 1) { start -= 1 }
        let prefix = String(decoding: units[start..<offset], as: UTF16.self)
        var end = offset
        while end < units.count, let scalar = Unicode.Scalar(units[end]), !CharacterSet.whitespacesAndNewlines.contains(scalar) { end += 1 }
        var rest = String(decoding: units[offset..<end], as: UTF16.self)
        guard prefix.utf16.count >= 2, !"하되으시해돼게지".contains(prefix.last ?? " "),
              !["가는", "가고", "에이", "이는", "는데", "가지"].contains(where: rest.hasPrefix) else { return true }
        let particles = ("이 가 은 는 을 를 의 에 에서 에게 에게서 께 께서 한테 한테서 으로 로 으로서 로서 으로써 로써 " +
            "와 과 랑 이랑 하고 도 만 까지 부터 마저 조차 밖에 처럼 보다 같이 이나 이든 이든지 이라도 들 님 씨 이야 이다 이에요 입니다 " +
            "이죠 이지 이고 이며 인데 인가 인지 이라 이라는 이라고 이라니 이란 이니까 이잖아 이었 이었다 이었어 였다 였어 이네 이군 이구나 이래")
            .split(separator: " ").map(String.init).enumerated().sorted {
                $0.element.utf16.count != $1.element.utf16.count ? $0.element.utf16.count > $1.element.utf16.count : $0.offset < $1.offset
            }.map(\.element)
        var matched = false
        while let scalar = rest.unicodeScalars.first, (0xAC00...0xD7A3).contains(scalar.value) {
            guard let particle = particles.first(where: rest.hasPrefix) else { return true }
            rest.removeFirst(particle.count); matched = true
        }
        return !matched || rest.unicodeScalars.contains { $0.properties.isAlphabetic || $0.properties.numericType != nil }
    }

    static func reduplicationBreak(text: String, offset: Int) -> Bool {
        let units = Array(text.utf16)
        guard !text.isEmpty, offset > 1, offset < units.count else { return false }
        var runs = 0, prior = false
        for scalar in text.unicodeScalars {
            if isHangul(scalar) { if !prior { runs += 1 }; prior = true }
            else {
                if scalar.properties.isAlphabetic || scalar.properties.numericType != nil { return false }
                prior = false
            }
        }
        guard runs == 1 else { return false }
        func hangul(_ index: Int) -> Bool { units.indices.contains(index) && Unicode.Scalar(units[index]).map(isHangul) == true }
        if offset + 1 < units.count, units[offset - 1] == units[offset], hangul(offset), hangul(offset - 2), hangul(offset + 1),
           units[offset - 2] == units[offset] || units[offset + 1] == units[offset] { return true }
        for count in 2...3 {
            guard offset >= count, offset + count <= units.count else { continue }
            let next = Array(units[offset..<(offset + count)]), before = Array(units[(offset - count)..<offset])
            if next.allSatisfy({ Unicode.Scalar($0).map(isHangul) == true }), next == before { return true }
        }
        return false
    }

    static func captionFontFloor(original: CGFloat, minimum: CGFloat = 5) -> CGFloat? {
        guard original.isFinite, original > 0, minimum.isFinite, minimum > 0 else { return nil }
        return max(minimum, min(original, 8.5), original * 0.8)
    }
    static func restoredFontFloor(original: CGFloat, minimum: CGFloat = 5) -> CGFloat? {
        guard original.isFinite, original > 0, minimum.isFinite, minimum > 0 else { return nil }
        return max(minimum, min(original, 8), original * 0.75)
    }
    static func artworkFontSizes(font: CGFloat, minimum: CGFloat = 5) -> [CGFloat] {
        guard let bound = restoredFontFloor(original: font, minimum: minimum), bound < font else { return [] }
        let floor = ceil(bound * 4) / 4
        var seen = Set<CGFloat>()
        return [0.9, 0.8, 0.7, 0.65].map { max(floor, quarterFloor(font * $0)) }
            .filter { $0 < font && seen.insert($0).inserted }
    }
    static func balloonFontSizes(font: CGFloat, minimum: CGFloat = 5) -> [CGFloat] {
        guard let bound = restoredFontFloor(original: font, minimum: minimum), bound <= font else { return [] }
        let floor = ceil(bound * 4) / 4
        if floor >= font { return [font] }
        let count = Int(min(8, ceil((font - floor) * 4)))
        var sizes = [font]
        for index in 1...count {
            let size = max(floor, quarterFloor(font - (font - floor) * CGFloat(index) / CGFloat(count)))
            if size < sizes.last! { sizes.append(size) }
        }
        return sizes
    }
    static func emergencyBalloonFontSizes(font: CGFloat, minimum: CGFloat, preferred: [CGFloat]) -> [CGFloat] {
        guard font.isFinite, minimum.isFinite, minimum > 0, font > max(6.5, minimum), let last = preferred.last else { return [] }
        var seen = Set<CGFloat>()
        return [7, minimum].map { max(minimum, $0) }
            .filter { seen.insert($0).inserted && $0 >= 7 && $0 < last && $0 < font }
    }

    /// Frozen nativeBalloonShape: every horizontal band retains its own paper
    /// run; the bounds of an asymmetric balloon never prove its empty corners.
    struct BalloonShape {
        let rect: CGRect
        let center: CGPoint
        let runs: [[CGFloat]?]
        let band: CGFloat
        let area: CGFloat
        var rectangularity: CGFloat { area / (rect.width * rect.height) }
        func rowSpan(_ y: CGFloat) -> [CGFloat]? {
            let index = Int(floor((y - rect.minY) / band))
            return index >= 0 && index < runs.count ? runs[index] : nil
        }
        func contains(_ point: CGPoint) -> Bool {
            guard let span = rowSpan(point.y) else { return false }
            return point.x >= span[0] && point.x <= span[1]
        }
        func outside(_ bounds: CGRect) -> Bool {
            guard bounds.minY >= rect.minY, bounds.maxY <= rect.maxY else { return true }
            let first = max(0, Int(floor((bounds.minY - rect.minY) / band)))
            let last = min(runs.count - 1, Int(floor((max(bounds.minY, bounds.maxY - 1e-6) - rect.minY) / band)))
            guard first <= last else { return false }
            for i in first...last {
                guard let run = runs[i], bounds.minX >= run[0], bounds.maxX <= run[1] else { return true }
            }
            return false
        }
    }
    static func balloonShape(rect: [CGFloat], center: [CGFloat], spans: [Double], frame: CGRect) -> BalloonShape? {
        guard frame.width > 0, frame.height > 0, [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
              rect.count == 4, rect.allSatisfy(\.isFinite), rect[2] > 0, rect[3] > 0,
              center.count == 2, center.allSatisfy(\.isFinite), spans.count >= 2,
              spans.count.isMultiple(of: 2), spans.allSatisfy(\.isFinite) else { return nil }
        let left = frame.minX + rect[0] * frame.width, top = frame.minY + rect[1] * frame.height
        let right = left + rect[2] * frame.width, bottom = top + rect[3] * frame.height
        let bounds = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        let band = bounds.height / CGFloat(spans.count / 2)
        var runs: [[CGFloat]?] = [], area: CGFloat = 0
        for i in stride(from: 0, to: spans.count, by: 2) {
            let left = CGFloat(spans[i]), right = CGFloat(spans[i + 1])
            let run: [CGFloat]? = left >= 0 && right > left
                ? [frame.minX + left * frame.width, frame.minX + right * frame.width] : nil
            runs.append(run)
            if let run { area += (run[1] - run[0]) * band }
        }
        guard area > 0 else { return nil }
        return BalloonShape(rect: bounds, center: CGPoint(x: frame.minX + center[0] * frame.width,
                                                        y: frame.minY + center[1] * frame.height),
                            runs: runs, band: band, area: area)
    }

    /// Frozen inspectSurface range for the native, owned restoration crop.
    /// The original and repaired colours were quantized together by restoration;
    /// transparent patch pixels therefore retain the correct original luminance.
    struct SurfaceEvidence {
        let range: [Double]
        let histogram: [Int]
    }
    static func surfaceRange(item: NativeTranslationLayoutItem, typography: NativeTranslationTypography.Layout,
                             restoration: NativeTranslationRestoration.Result) -> [Double]? {
        surfaceEvidence(item: item, typography: typography, restoration: restoration)?.range
    }
    static func surfaceHistogram(item: NativeTranslationLayoutItem, typography: NativeTranslationTypography.Layout,
                                 restoration: NativeTranslationRestoration.Result) -> [Int]? {
        surfaceEvidence(item: item, typography: typography, restoration: restoration)?.histogram
    }
    static func surfaceEvidence(item: NativeTranslationLayoutItem, typography: NativeTranslationTypography.Layout,
                                restoration: NativeTranslationRestoration.Result, lookupLimit: Int = 4_194_304) -> SurfaceEvidence? {
        guard contentFits(item: item, typography: typography) else { return nil }
        let used = usedLayoutItem(item)
        return surfaceEvidence(item: item, pageRangeBounds: typography.rangeBounds.map {
            $0.offsetBy(dx: used.contentRect.minX, dy: used.contentRect.minY)
        }, restoration: restoration, lookupLimit: lookupLimit)
    }
    static func surfaceEvidence(item: NativeTranslationLayoutItem, pageRangeBounds: [CGRect],
                                restoration: NativeTranslationRestoration.Result, lookupLimit: Int = 4_194_304) -> SurfaceEvidence? {
        guard item.rotation == 0, !pageRangeBounds.isEmpty,
              pageRangeBounds.allSatisfy({ [$0.minX, $0.minY, $0.width, $0.height].allSatisfy(\.isFinite) && $0.width > 0 && $0.height > 0 }),
              let patch = restoration.patches.last(where: { $0.itemID == item.id }),
              let safe = patch.layoutSafe, let luminance = patch.surfaceLuminance,
              safe.count == patch.image.width * patch.image.height, luminance.count == safe.count,
              patch.rect.width > 0, patch.rect.height > 0 else { return nil }
        let sx = CGFloat(patch.image.width) / patch.rect.width, sy = CGFloat(patch.image.height) / patch.rect.height
        var minimum = 256, maximum = -1, budget = lookupLimit
        var histogram = [Int](repeating: 0, count: 256)
        for r in pageRangeBounds {
            let l = Int(floor((r.minX - patch.rect.minX) * sx)), t = Int(floor((r.minY - patch.rect.minY) * sy))
            let right = Int(ceil((r.maxX - patch.rect.minX) * sx)), bottom = Int(ceil((r.maxY - patch.rect.minY) * sy))
            guard l >= 0, t >= 0, right <= patch.image.width, bottom <= patch.image.height, right >= l, bottom >= t else { return nil }
            let count = (right - l) * (bottom - t)
            guard count <= budget else { return nil }
            budget -= count
            for y in t..<bottom {
                for x in l..<right {
                    let i = y * patch.image.width + x
                    guard safe[i] != 0 else { return nil }
                    minimum = min(minimum, Int(luminance[i])); maximum = max(maximum, Int(luminance[i]))
                    histogram[Int(luminance[i])] += 1
                }
            }
        }
        guard minimum <= maximum else { return nil }
        return SurfaceEvidence(range: [max(0, (Double(minimum) - 0.5) / 255), min(1, (Double(maximum) + 0.5) / 255)],
                               histogram: histogram)
    }

    struct ContentFitMetrics: Codable, Equatable {
        let clientWidth: Int
        let clientHeight: Int
        let scrollWidth: Int
        let scrollHeight: Int
        var fits: Bool { scrollWidth <= clientWidth && scrollHeight <= clientHeight }
    }
    /// Integer CSSOM padding-box extents. Font ink and selection overhang do
    /// not contribute to scrollable layout overflow.
    static func layoutOverflowMetrics(box: CGSize, body: CGRect, trailingPadding: CGSize,
                                      block: Bool, clips: Bool) -> ContentFitMetrics {
        func integer(_ value: CGFloat) -> Int { Int(floor(max(0, value) + 0.5)) }
        let right = body.maxX
        var bottom = body.maxY
        if clips {
            if block || bottom > box.height { bottom += trailingPadding.height }
        }
        return ContentFitMetrics(clientWidth: integer(box.width), clientHeight: integer(box.height),
            scrollWidth: integer(max(box.width, right)), scrollHeight: integer(max(box.height, bottom)))
    }
    static func usedLayoutItem(_ item: NativeTranslationLayoutItem) -> NativeTranslationLayoutItem {
        func unit(_ value: CGFloat) -> CGFloat { CGFloat((Float(value) * 64).rounded(.towardZero)) / 64 }
        var used = item
        used.x = unit(item.x); used.y = unit(item.y); used.width = unit(item.width); used.height = unit(item.height)
        used.paddingTop = unit(item.paddingTop); used.paddingRight = unit(item.paddingRight)
        used.paddingBottom = unit(item.paddingBottom); used.paddingLeft = unit(item.paddingLeft)
        used.preservePaddingDeclarations(from: item)
        return used
    }
    static func contentFitMetrics(item: NativeTranslationLayoutItem, typography: NativeTranslationTypography.Layout) -> ContentFitMetrics? {
        let used = usedLayoutItem(item)
        if item.vertical {
            let padding = NativeVerticalContentFit.Padding(top: used.paddingTop, right: used.paddingRight,
                bottom: used.paddingBottom, left: used.paddingLeft)
            guard let inline = NativeVerticalContentFit.inlineExtent(
                advances: NativeTranslationTypography.verticalLineAdvances(layout: typography),
                ranges: typography.lineRanges, text: typography.shapedText, contentHeight: used.contentRect.height),
                let metrics = NativeVerticalContentFit.metrics(box: CGSize(width: used.width, height: used.height),
                    padding: padding, columnCount: typography.lineCount, fontSize: used.fontSize, lineHeight: used.lineHeight,
                    inlineExtent: inline, alignsToRight: used.balancedColumn, clips: used.clipsText) else { return nil }
            return ContentFitMetrics(clientWidth: metrics.clientWidth, clientHeight: metrics.clientHeight,
                scrollWidth: metrics.scrollWidth, scrollHeight: metrics.scrollHeight)
        }
        let scale = item.typesettingWidthScale ?? 1
        guard scale > 0, scale.isFinite else { return nil }
        let box = CGSize(width: used.width / scale, height: used.height)
        let content = CGSize(width: used.contentRect.width / scale, height: used.contentRect.height)
        let advances = NativeTranslationTypography.lineAdvances(layout: typography)
        let width = max(0, advances.max() ?? 0)
        let pitch = floor(max(item.fontSize, item.lineHeight)), height = CGFloat(advances.count) * pitch
        let preservedRows = item.typesettingText != nil && (item.typesettingQuoteMode != nil || item.typesettingPreformattedRows == true)
        let block = preservedRows && item.typesettingBlockDisplay == true
        func unit(_ value: CGFloat) -> CGFloat { CGFloat((Float(value) * 64).rounded(.towardZero)) / 64 }
        let top = block ? (item.balancedColumn ? used.paddingTop : unit(max(used.paddingTop, (used.height - CGFloat(advances.count) * item.lineHeight) / 2)))
            : used.paddingTop + (item.balancedColumn ? 0 : unit((content.height - height) / 2))
        let left = used.paddingLeft / scale + unit(preservedRows ? max(0, (content.width - width) / 2) : (content.width - width) / 2)
        let body = CGRect(x: left, y: top, width: width, height: height)
        return layoutOverflowMetrics(box: box, body: body,
            trailingPadding: CGSize(width: used.paddingRight / scale, height: used.paddingBottom), block: block, clips: item.clipsText)
    }
    /// CSS height:auto uses the line-box flow plus padding. Suggested frame
    /// height and glyph ink overhang do not enlarge an explicit line-height.
    static func blockAutoHeight(item: NativeTranslationLayoutItem,
                                typography: NativeTranslationTypography.Layout) -> CGFloat? {
        guard !item.vertical, item.fontSize.isFinite, item.fontSize > 0,
              item.lineHeight.isFinite, item.lineHeight > 0,
              typography.lineCount > 0, typography.visibleUTF16Range.location == 0,
              typography.visibleUTF16Range.length >= (item.typesettingText ?? item.text).utf16.count else { return nil }
        let used = usedLayoutItem(item)
        return used.paddingTop + used.paddingBottom + CGFloat(typography.lineCount) * floor(max(item.fontSize, item.lineHeight))
    }

    static func contentFits(item: NativeTranslationLayoutItem, typography: NativeTranslationTypography.Layout) -> Bool {
        guard typography.visibleUTF16Range.location == 0,
              typography.visibleUTF16Range.length >= (item.typesettingText ?? item.text).utf16.count else { return false }
        return contentFitMetrics(item: item, typography: typography)?.fits ?? typography.fits
    }

    /// Replacing children with fresh nowrap SPANs removes the Packing wrapper
    /// and switches the parent back to block flow, exactly as wordLines does.
    static func replacingWithBlockWords(_ item: NativeTranslationLayoutItem, lines: [String],
                                       quoteMode: Int) -> NativeTranslationLayoutItem {
        var copy = item
        copy.typesettingText = lines.joined(separator: "\n")
        copy.typesettingQuoteMode = quoteMode
        copy.typesettingPreservedBlockWrapper = nil
        copy.typesettingPreformattedRows = nil
        copy.typesettingBlockDisplay = true
        if !copy.balancedColumn {
            copy.paddingTop = max(copy.paddingTop, (copy.height - CGFloat(lines.count) * copy.lineHeight) / 2)
        }
        return copy
    }

    struct Candidate {
        var item: NativeTranslationLayoutItem
        let shaped: NativeTranslationTypography.Layout
        let profile: Profile
        var surfaceInk: [CGRect]? = nil
        var ink: [CGRect] {
            surfaceInk ?? shaped.rangeBounds.map {
                let used = NativeTypographyPostPolish.usedLayoutItem(item)
                return $0.offsetBy(dx: used.contentRect.minX, dy: used.contentRect.minY)
            }
        }
        var inkFrame: CGRect { ink.reduce(CGRect.null) { $0.union($1) } }
    }
    final class SourceReader {
        struct Tile {
            let rect: CGRect
            let width: Int
            let height: Int
            let rgba: [UInt8]
        }
        let image: CGImage?
        var exteriorBudget = 1_048_576
        var cached: Tile?
        let pixels: NativeSourcePixelReader?
        init(_ image: CGImage?) { self.image = image; pixels = image.map { NativeSourcePixelReader(image: $0) } }
        func read(_ rect: CGRect) -> Tile? {
            let rect = rect.integral
            let count = Int(rect.width * rect.height)
            guard let image, count > 0, count <= min(262_144, exteriorBudget),
                  rect.minX >= 0, rect.minY >= 0, rect.maxX <= CGFloat(image.width), rect.maxY <= CGFloat(image.height) else { return nil }
            exteriorBudget -= count
            if let cached, cached.rect == rect { return cached }
            let width = Int(rect.width), height = Int(rect.height)
            guard let pixels, let rgba = try? pixels.read(x: Double(rect.minX), y: Double(rect.minY),
                sourceWidth: Double(rect.width), sourceHeight: Double(rect.height), width: width, height: height) else { return nil }
            let tile = Tile(rect: rect, width: width, height: height, rgba: rgba)
            cached = tile; return tile
        }
    }
    struct RememberedInk {
        let frame: CGRect
        let font: CGFloat
        let pad: CGFloat
    }
    final class GrowthHistory {
        var original: [String: NativeTranslationLayoutItem] = [:]
        var displayedGlossObstacles: [String: [CGRect]] = [:]
        var collectInitialDiagnostics = false
        var initialTypographyTrace: [String: [[String: Any]]] = [:]
        var registered = false
        var admitted: Set<String> = []
        var finalized: Set<String> = []
        var restoredInside: Set<String> = []
        var interiorFirst: Set<String> = []
        var artworkSurfaceBudget = 1_048_576
        var rememberedInk: [String: RememberedInk] = [:]
        var artworkOriginalFonts: [String: CGFloat] = [:]
        var surfaceInspectionCharacters = 8192
        var surfaceInspectable: Set<String> = []
        var restoredLookupRemaining = 4_194_304
        var wordRepairRemaining = 1_048_576
        var lateWordRepairRemaining = 1_048_576
        var balloonTypeRemaining = 32_768
        var balloonSurfaceRemaining = 2_097_152
        var balloonExtendedRemaining = 1_048_576
        var balloonCondensedRemaining = 1_048_576
        var balloonDisplayRemaining = 1_048_576
        var balloonLiftRemaining = 1_048_576
        var balloonLiftWideRemaining = 524_288
        var recoveryBudget = NativeTypographyCaptionRecovery.Budget(readable: 2048, characters: 16384)
        var recoveryInitialized = false
        var runs: [String: Int] = [:]
        var base: [String: CGFloat] = [:]
        var extended: Set<String> = []
        var interior: Set<String> = []
        var interiorBase: [String: CGFloat] = [:]
        var readablePeer: [String: CGFloat] = [:]
        var interiorBudget = 1_048_576
        var shiftBudget = 2_097_152
    }
    final class GrowthSearch {
        var table: NativeTypographyPlacementSearch.Table?
        var tableAttempted = false
        var movedAttempts = 0
        private(set) var widthAttempts = 0
        private(set) var widthPassExhausted = false

        /// A pass searches several font sizes with one 36-width allowance.
        /// Moved layouts retain their independent per-caption allowance.
        func beginWidthPass() {
            widthAttempts = 0
            widthPassExhausted = false
        }
        func takeWidthAttempt() -> Bool {
            guard widthAttempts < 36 else {
                widthPassExhausted = true
                return false
            }
            widthAttempts += 1
            return true
        }
    }
    struct Context {
        var restoration: NativeTranslationRestoration.Result
        let settings: IPhoneOverlaySettings
        var layout: NativeTranslationLayout
        /// Source sampling follows the normalized image element, independently
        /// of the original OCR frame retained in the layout payload.
        var sourceFrame: CGRect { restoration.cleanupGeometry?.frame ?? layout.sourceRect }
        var patches: [String: NativeTranslationRestoration.Patch]
        let reader: SourceReader
        let growth = GrowthHistory()
        let surfacePool = NativeTranslationSurfacePool.Cache()
        final class SurfaceMemo {
            let image: CGImage
            let boxes: [CGRect]
            let sourceFrame: CGRect
            let exterior: Bool
            let range: [Double]?
            init(image: CGImage, boxes: [CGRect], sourceFrame: CGRect, exterior: Bool, range: [Double]?) {
                self.image = image; self.boxes = boxes; self.sourceFrame = sourceFrame; self.exterior = exterior; self.range = range
            }
        }
        final class SurfaceMemos { var entries: [String: SurfaceMemo] = [:] }
        let surfaceMemos = SurfaceMemos()
        func restored(_ id: String) -> Bool {
            growth.finalized.contains(id) ? growth.restoredInside.contains(id)
                : restoration.appearances[id]?.restored == true
        }

        func refreshed(restoration: NativeTranslationRestoration.Result, layout: NativeTranslationLayout) -> Context {
            var copy = self
            copy.restoration = restoration; copy.layout = layout
            copy.patches = Dictionary(restoration.patches.compactMap { patch in patch.itemID.map { ($0, patch) } }, uniquingKeysWith: { _, last in last })
            return copy
        }
        func peerFont(_ item: NativeTranslationLayoutItem, beforeInterior: Bool = false) -> CGFloat {
            let font = beforeInterior ? growth.interiorBase[item.id] ?? item.fontSize : item.fontSize
            return min(font, growth.readablePeer[item.id] ?? font)
        }
        func style(_ item: NativeTranslationLayoutItem) -> NativeTranslationTypography.Style {
            let appearance = restoration.appearances[item.id]
            return NativeTranslationTypography.Style(
                fontName: settings.preserveSourceColors && item.fontScript == "korean" ? appearance?.fontName : nil,
                fontScript: item.fontScript, fontSize: item.fontSize, vertical: item.vertical,
                foreground: item.typesettingForeground.flatMap { rgb in
                    guard rgb.count == 3, rgb.allSatisfy(\.isFinite) else { return nil }
                    return CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: rgb.map { CGFloat($0) / 255 } + [1])
                } ?? (settings.preserveSourceTextColor ? appearance?.foreground ?? defaultInk(item) : defaultInk(item)),
                outline: item.typesettingOutlineRGB.flatMap { rgb in
                    guard rgb.count == 3 else { return nil }
                    return CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: rgb.map { CGFloat($0) / 255 } + [1])
                }, outlineWidth: item.typesettingOutlineWidth ?? 0,
                tracking: item.fontSize * -0.012, lineHeight: max(item.fontSize, item.lineHeight),
                optimizesKoreanWrapping: false, koreanQuoteMode: item.typesettingQuoteMode ?? 0,
                alignsToTop: item.balancedColumn, horizontalScale: item.typesettingWidthScale ?? 1,
                balancesHorizontalLines: !item.vertical && item.wrappingScript == "korean" &&
                    item.text.utf16.count <= 180 && !item.text.contains(where: \.isNewline),
                horizontalWrapping: item.wrappingScript == "korean" && item.typesettingStrictLineBreak != true ? .keepAllWithEmergency : .normal,
                usesBlockWordLayout: item.typesettingText != nil && item.typesettingQuoteMode != nil,
                usesPreformattedBlockRows: item.typesettingText != nil && item.typesettingPreformattedRows == true,
                blockWordLayoutUsesTopPadding: item.typesettingBlockDisplay ?? false,
                strictLineBreak: item.typesettingStrictLineBreak ?? false)
        }
        private func defaultInk(_ item: NativeTranslationLayoutItem) -> CGColor {
            item.lightSurface ? CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [17.0 / 255, 18.0 / 255, 23.0 / 255, 1])!
                : CGColor(gray: 1, alpha: 1)
        }
        func candidate(_ item: NativeTranslationLayoutItem) -> Candidate {
            let used = usedLayoutItem(item)
            let shaped = NativeTranslationTypography.layout(text: item.typesettingText ?? item.text,
                                                            in: used.contentRect.size, style: style(item))
            return Candidate(item: item, shaped: shaped, profile: NativeTypographyPostPolish.profile(shaped, originalText: item.text))
        }
        func contentFits(_ candidate: Candidate) -> Bool {
            NativeTypographyPostPolish.contentFits(item: candidate.item, typography: candidate.shaped)
        }
        func captionRecovering(_ item: NativeTranslationLayoutItem) -> NativeTranslationLayoutItem {
            typealias State = NativeTypographyCaptionRecovery.State<NativeTranslationLayoutItem>
            func state(_ item: NativeTranslationLayoutItem) -> State {
                State(value: item, font: item.fontSize,
                    padding: [item.paddingTop, item.paddingRight, item.paddingBottom, item.paddingLeft])
            }
            let canInspect: Bool
            if patches[item.id]?.layoutSafe != nil, item.text.utf16.count <= growth.surfaceInspectionCharacters {
                growth.surfaceInspectionCharacters -= item.text.utf16.count
                growth.surfaceInspectable.insert(item.id); canInspect = true
            } else { canInspect = false }
            func finalized(_ value: State) {
                guard patches[item.id] != nil else { return }
                growth.finalized.insert(item.id)
                let fits = growth.surfaceInspectable.contains(item.id) &&
                    holdsSurface(candidate(value.value), allowExterior: true, requiresCommittedRestoration: false)
                if fits { growth.restoredInside.insert(item.id) } else { growth.restoredInside.remove(item.id) }
            }
            var budget = growth.recoveryBudget
            let result = NativeTypographyCaptionRecovery.recovering(state(item), input: .init(
                preserveBackground: settings.preserveSourceBackgroundColor && item.sourceColorEligible,
                automatic: item.allowsAutomaticFontRecovery, vertical: item.vertical,
                korean: item.wrappingScript == "korean", length: item.text.utf16.count), budget: &budget,
                apply: { font, padding in
                    var next = resized(item, size: font)
                    if padding.count == 4 {
                        next.paddingTop = padding[0]; next.paddingRight = padding[1]
                        next.paddingBottom = padding[2]; next.paddingLeft = padding[3]
                    }
                    return state(next)
                }, contentFits: { contentFits(candidate($0.value)) },
                lineProfile: { value in
                    let shaped = candidate(value.value)
                    guard !shaped.ink.isEmpty else { return nil }
                    let profile = shaped.profile
                    return NativeTypographyCaptionRecovery.Profile(breaks: profile.breaks,
                        badStarts: profile.badStarts.count, badEnds: profile.badEnds.count,
                        punctuationOnly: profile.punctuationOnly, hangulIsolated: profile.hangulIsolated)
                }, inspectInitialSurface: canInspect ? { value in finalized(value); return value } : nil,
                inspectFinalSurface: patches[item.id] != nil ? finalized : nil)
            growth.recoveryBudget = budget
            return result.state.value
        }
        func resized(_ item: NativeTranslationLayoutItem, size: CGFloat) -> NativeTranslationLayoutItem {
            var copy = item
            let ratio = item.fontSize > 0 ? item.lineHeight / item.fontSize : 1.2
            copy.fontSize = size; copy.lineHeight = size * ratio
            return copy
        }
        func words(_ item: NativeTranslationLayoutItem, maxLines: Int, wide: Bool = false,
                   strict: Bool? = nil, any: Bool = false) -> Candidate? {
            guard item.wrappingScript == "korean", !item.vertical,
                  let lines = wordLines(text: item.text, size: CGSize(width: item.contentRect.width / (item.typesettingWidthScale ?? 1),
                                                                       height: item.contentRect.height), style: style(item),
                                        maxLines: maxLines, wide: wide, strict: strict, any: any) else { return nil }
            let copy = NativeTypographyPostPolish.replacingWithBlockWords(item, lines: lines,
                quoteMode: wide ? 2 : (strict ?? wide) ? 1 : 0)
            return candidate(copy)
        }
        func contained(_ candidate: Candidate, baseline: Candidate) -> Bool {
            let item = candidate.item
            let bottom = item.balancedColumn
                ? min(item.rect.maxY, max(item.y + (item.columnLayout?.inspectionHeight ?? item.height),
                                         baseline.ink.map(\.maxY).max() ?? item.rect.maxY)) : item.rect.maxY
            return !candidate.ink.isEmpty && candidate.ink.allSatisfy {
                $0.minX >= item.x - 0.5 && $0.maxX <= item.rect.maxX + 0.5 && $0.minY >= item.y - 0.5 && $0.maxY <= bottom + 0.5
            }
        }
        /// A retained gloss replaces its hidden parent in the displayed DOM.
        /// This affects text collisions only, never source erasure ownership.
        func placementObstacles(_ other: NativeTranslationLayoutItem) -> [CGRect] {
            if !other.keptLettering, let displayed = growth.displayedGlossObstacles[other.id] { return displayed }
            return [restored(other.id) ? candidate(other).inkFrame : other.rect]
        }
        func clear(_ candidate: Candidate, others: [NativeTranslationLayoutItem], prior: Candidate? = nil) -> Bool {
            let ink = candidate.ink, priorInk = prior?.ink ?? []
            guard !ink.isEmpty else { return false }
            for other in others where other.id != candidate.item.id {
                let obstacles: [CGRect]
                if other.keptLettering {
                    obstacles = ([other.sourceBounds] + other.auxiliaryInkRects).compactMap { bounds in
                        guard bounds.count == 4 else { return nil }
                        return CGRect(x: sourceFrame.minX + bounds[0] * sourceFrame.width,
                                      y: sourceFrame.minY + bounds[1] * sourceFrame.height,
                                      width: bounds[2] * sourceFrame.width, height: bounds[3] * sourceFrame.height)
                    }
                } else {
                    obstacles = growth.displayedGlossObstacles[other.id] ??
                        (restored(other.id) ? self.candidate(other).ink : [other.rect])
                }
                for glyph in ink {
                    for obstacle in obstacles {
                        let overlap = glyph.intersection(obstacle)
                        if overlap.width > 0.5, overlap.height > 0.5 {
                            let oldOverlap = priorInk.contains { old in
                                let previous = old.intersection(obstacle)
                                return previous.width > 0.5 && previous.height > 0.5
                            }
                            if !oldOverlap { return false }
                        }
                    }
                }
            }
            if let reference = candidate.item.smallTextReference {
                for coordinates in reference.exclusionRects where coordinates.count == 4 {
                    let obstacle = CGRect(x: coordinates[0], y: coordinates[1], width: coordinates[2], height: coordinates[3])
                    if ink.contains(where: { let r = $0.intersection(obstacle); return r.width > 0.5 && r.height > 0.5 }) { return false }
                }
            }
            return true
        }
        /// Surviving source ink/art has a zero mask byte. Every painted glyph
        /// pixel must lie in the caption's own verified patch; a colour match
        /// alone never promotes a drawing to an erased text surface.
        func inspectedSurface(_ candidate: Candidate, expands: Bool = false, allowExterior: Bool = false,
                              margin: CGSize? = nil, lookupLimit: Int? = nil, requiresCommittedRestoration: Bool = true) -> [Double]? {
            var remaining = lookupLimit ?? growth.restoredLookupRemaining
            defer { if lookupLimit == nil { growth.restoredLookupRemaining = remaining } }
            return inspectedSurface(candidate, expands: expands, allowExterior: allowExterior, margin: margin,
                                    requiresCommittedRestoration: requiresCommittedRestoration, lookupBudget: &remaining)
        }
        func inspectedSurface(_ candidate: Candidate, expands: Bool = false, allowExterior: Bool = false,
                              margin: CGSize? = nil, requiresCommittedRestoration: Bool = true,
                              lookupBudget: inout Int) -> [Double]? {
            guard contentFits(candidate), let appearance = restoration.appearances[candidate.item.id],
                  !requiresCommittedRestoration || (growth.finalized.contains(candidate.item.id)
                    ? growth.restoredInside.contains(candidate.item.id) : appearance.restored),
                  let patch = patches[candidate.item.id],
                  let safe = patch.layoutSafe, let luminance = patch.surfaceLuminance,
                  safe.count == patch.image.width * patch.image.height, luminance.count == safe.count,
                  patch.rect.width > 0, patch.rect.height > 0 else { return nil }
            let sx = CGFloat(patch.image.width) / patch.rect.width, sy = CGFloat(patch.image.height) / patch.rect.height
            let inset = margin ?? CGSize(width: expands ? 1 : 0, height: expands ? 0.75 : 0)
            let inspected = candidate.ink.map { $0.insetBy(dx: -inset.width, dy: -inset.height) }
            guard !inspected.isEmpty else { return nil }
            let image = patch.image
            if let memo = surfaceMemos.entries[candidate.item.id], memo.image === image,
               memo.boxes == inspected, memo.sourceFrame == sourceFrame, memo.exterior == allowExterior { return memo.range }
            surfaceMemos.entries[candidate.item.id] = SurfaceMemo(image: image, boxes: inspected,
                sourceFrame: sourceFrame, exterior: allowExterior, range: nil)
            func remembered(_ range: [Double]?) -> [Double]? {
                if let range {
                    surfaceMemos.entries[candidate.item.id] = SurfaceMemo(image: image, boxes: inspected,
                        sourceFrame: sourceFrame, exterior: allowExterior, range: range)
                }
                return range
            }
            let all = inspected.reduce(CGRect.null) { $0.union($1) }
            let exterior = !patch.rect.contains(all)
            var tile: SourceReader.Tile?, coefficients: [[Double]]?
            if exterior {
                guard allowExterior, patch.surfaceQuality?["safe"] as? Bool == true,
                      let plane = patch.surfaceQuality?["coefficients"] as? [[Double]], plane.count == 3,
                      plane.allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isFinite) }),
                      let image = reader.image,
                      patch.rect.insetBy(dx: -64, dy: -64).contains(all), sourceFrame.contains(all) else { return nil }
                coefficients = plane
                let kx = CGFloat(image.width) / sourceFrame.width, ky = CGFloat(image.height) / sourceFrame.height
                let pixels = CGRect(x: (all.minX - sourceFrame.minX) * kx, y: (all.minY - sourceFrame.minY) * ky,
                                    width: all.width * kx, height: all.height * ky).integral
                guard let read = reader.read(pixels) else { return nil }
                tile = read
            }
            var low = Double.infinity, high = -Double.infinity
            func exteriorValue(_ x: Int, _ y: Int) -> Double? {
                guard let tile, let coefficients, let image = reader.image else { return nil }
                let px = patch.rect.minX + (CGFloat(x) + 0.5) / sx
                let py = patch.rect.minY + (CGFloat(y) + 0.5) / sy
                let ix = Int(floor((px - sourceFrame.minX) / sourceFrame.width * CGFloat(image.width) - tile.rect.minX))
                let iy = Int(floor((py - sourceFrame.minY) / sourceFrame.height * CGFloat(image.height) - tile.rect.minY))
                guard ix >= 0, iy >= 0, ix < tile.width, iy < tile.height else { return nil }
                let i = (iy * tile.width + ix) * 4
                guard tile.rgba[i + 3] >= 254 else { return nil }
                let tolerance: Double = candidate.item.balancedColumn && patch.candidate?.sourceErasureVerified == true ? 24 : 18
                var rgb: [Double] = []
                for channel in 0..<3 {
                    let a = coefficients[channel]
                    let plane = max(0, min(255, a[0] + a[1] * Double(x) / Double(patch.image.width)
                                           + a[2] * Double(y) / Double(patch.image.height)))
                    let color = Double(tile.rgba[i + channel])
                    guard abs(color - plane) <= tolerance else { return nil }
                    rgb.append(color)
                }
                return 255 * sourceLuminance(rgb)
            }
            do {
                let iw = Double(reader.image?.width ?? Int(layout.imageSize.width))
                let ih = Double(reader.image?.height ?? Int(layout.imageSize.height))
                let crop = NativeTranslationSurfacePool.Crop(safe: safe, luminance: luminance,
                    width: patch.image.width, height: patch.image.height,
                    x: Double(patch.rect.minX - sourceFrame.minX) * iw / Double(sourceFrame.width),
                    y: Double(patch.rect.minY - sourceFrame.minY) * ih / Double(sourceFrame.height),
                    sx: Double(sx) * Double(sourceFrame.width) / iw,
                    sy: Double(sy) * Double(sourceFrame.height) / ih,
                    imageWidth: iw, imageHeight: ih, frameWidth: Double(sourceFrame.width), frameHeight: Double(sourceFrame.height))
                let identity = String(describing: ObjectIdentifier(patch.image))
                if let pool = surfacePool.pool(crop, safeIdentity: identity, luminanceIdentity: identity) {
                    let boxes = inspected.map { rect in NativeTranslationSurfacePool.Box(
                        left: Int(floor((rect.minX - patch.rect.minX) * sx)), top: Int(floor((rect.minY - patch.rect.minY) * sy)),
                        right: Int(ceil((rect.maxX - patch.rect.minX) * sx)), bottom: Int(ceil((rect.maxY - patch.rect.minY) * sy))) }
                    let range = surfacePool.range(pool, boxes: boxes, lookupBudget: &lookupBudget,
                        exterior: exterior ? exteriorValue : nil)
                    if surfacePool.lastLookupExhausted { surfaceMemos.entries.removeValue(forKey: candidate.item.id) }
                    return remembered(range)
                }
            }
            for rect in inspected {
                let x0 = Int(floor((rect.minX - patch.rect.minX) * sx)), x1 = Int(ceil((rect.maxX - patch.rect.minX) * sx))
                let y0 = Int(floor((rect.minY - patch.rect.minY) * sy)), y1 = Int(ceil((rect.maxY - patch.rect.minY) * sy))
                let cost = (x1 - x0) * (y1 - y0)
                guard cost >= 0 else { return nil }
                guard cost <= lookupBudget else { surfaceMemos.entries.removeValue(forKey: candidate.item.id); return nil }
                lookupBudget -= cost
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        let value: Double
                        if x >= 0, y >= 0, x < patch.image.width, y < patch.image.height {
                            let i = y * patch.image.width + x
                            guard safe[i] != 0 else { return nil }
                            value = Double(luminance[i])
                        } else {
                            guard let sampled = exteriorValue(x, y) else { return nil }
                            value = sampled
                        }
                        low = min(low, value); high = max(high, value)
                    }
                }
            }
            guard low.isFinite, high.isFinite else { return nil }
            let lo = max(0, (low - 0.5) / 255), hi = min(1, (high + 0.5) / 255)
            return remembered([lo, hi])
        }
        func holdsSurface(_ candidate: Candidate, expands: Bool = false, allowExterior: Bool = false,
                          margin: CGSize? = nil, lookupLimit: Int? = nil, requiresCommittedRestoration: Bool = true,
                          foreground: CGColor? = nil, usesBalloonBudget: Bool = false) -> Bool {
            let ink = (foreground ?? style(candidate.item).foreground).converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)
            guard let components = ink?.components, components.count >= 3,
                  components.prefix(3).allSatisfy(\.isFinite) else { return false }
            let inkL = sourceLuminance(components.prefix(3).map { Double($0) * 255 })
            let range: [Double]?
            if usesBalloonBudget {
                guard growth.balloonSurfaceRemaining > 0 else { return false }
                let allowance = min(growth.balloonSurfaceRemaining, lookupLimit ?? 65_536)
                var lookup = allowance
                range = inspectedSurface(candidate, expands: expands, allowExterior: allowExterior, margin: margin,
                    requiresCommittedRestoration: requiresCommittedRestoration, lookupBudget: &lookup)
                growth.balloonSurfaceRemaining -= allowance - lookup
            } else {
                range = inspectedSurface(candidate, expands: expands, allowExterior: allowExterior, margin: margin,
                    lookupLimit: lookupLimit, requiresCommittedRestoration: requiresCommittedRestoration)
            }
            guard let range else { return false }
            let lo = range[0], hi = range[1]
            let contrast = inkL < lo ? (lo + 0.05) / (inkL + 0.05) : inkL > hi ? (inkL + 0.05) / (hi + 0.05) : 1
            return contrast >= 4.5
        }
        func eligible(_ item: NativeTranslationLayoutItem) -> Bool {
            (!growth.registered || growth.admitted.contains(item.id)) && !item.keptLettering && !item.sourceTextOnly && item.sourceColorEligible && !item.vertical &&
                item.text.utf16.count <= 180 && item.fontSize >= BrowserOverlayLayoutPlanner.minimumRenderedFontSize &&
                !item.text.isEmpty && item.contentRect.width > 0 && item.contentRect.height > 0
        }
        func trace(_ stage: String, _ candidate: Candidate, target: CGFloat? = nil,
                   wordAware: Bool? = nil, contained: Bool? = nil, accepted: Bool? = nil) {
            // Keep bounded trial details from crowding out accepted and return state.
            let limit = stage == "growth-shaped-trial" ? 48 : 60
            guard growth.collectInitialDiagnostics,
                  growth.initialTypographyTrace[candidate.item.id, default: []].count < limit else { return }
            let item = candidate.item, profile = candidate.profile
            var record: [String: Any] = ["stage": stage, "font": item.fontSize,
                "text": item.typesettingText ?? item.text,
                "surfaceInk": candidate.ink.map { [$0.minX,$0.minY,$0.width,$0.height] },
                "controlled": item.typesettingText != nil,
                "wordAwareMarker": item.captionFixedBoxReflowDisabled == true,
                "blockDisplay": item.typesettingBlockDisplay == true,
                "preservedWrapper": item.typesettingPreservedBlockWrapper == true,
                "fontSize": item.fontSize, "lineHeight": item.lineHeight,
                "rect": [item.x, item.y, item.width, item.height],
                "padding": [item.paddingTop, item.paddingRight, item.paddingBottom, item.paddingLeft],
                "contentFits": contentFits(candidate), "lines": profile.lines,
                "breaks": profile.breaks, "badStarts": profile.badStarts, "badEnds": profile.badEnds,
                "hangulFragments": profile.hangulFragments, "hangulIsolated": profile.hangulIsolated,
                "punctuationOnly": profile.punctuationOnly, "penalty": profile.penalty]
            if let target { record["target"] = target }
            if let wordAware { record["newWordAware"] = wordAware }
            if let contained { record["contained"] = contained }
            if let accepted { record["accepted"] = accepted }
            if let mode = item.typesettingQuoteMode { record["quoteMode"] = mode }
            growth.initialTypographyTrace[item.id, default: []].append(record)
        }
        func rememberInk(_ candidate: Candidate) {
            guard growth.rememberedInk[candidate.item.id] == nil, !candidate.inkFrame.isNull else { return }
            // lineProfile maps the measured Range offsets back onto the
            // current authored x/y, before CSS LayoutUnit resolution. The
            // retained footprint is that profile frame, not a physical BCR.
            let used=usedLayoutItem(candidate.item)
            let profileFrame=candidate.inkFrame.offsetBy(dx:candidate.item.x-used.x,dy:candidate.item.y-used.y)
            growth.rememberedInk[candidate.item.id] = RememberedInk(frame: profileFrame,
                font: candidate.item.fontSize, pad: max(3, min(6, candidate.item.fontSize * 0.3)))
        }
        func cohort(_ item: NativeTranslationLayoutItem, target: CGFloat,
                    others: [NativeTranslationLayoutItem]) -> NativeTranslationLayoutItem {
            let original = candidate(item)
            trace("cohort-original", original, target: target)
            let sizes = cohortFontCandidates(original: item.fontSize, target: target,
                                             minimum: BrowserOverlayLayoutPlanner.minimumRenderedFontSize)
            guard !sizes.isEmpty else { return item }
            rememberInk(original)
            var baseline = original
            if original.profile.hangulFragments > 0,
               let words = words(item, maxLines: original.profile.lines), contentFits(words),
               contained(words, baseline: original), koreanWrapImproves(words.profile, original.profile) { baseline = words }
            trace("cohort-flow-baseline", baseline, target: target)
            let allowance = sizes[0] > item.fontSize ? max(2, Int(ceil(CGFloat(original.profile.lines) * 0.35))) : 0
            for size in sizes {
                let proposed = resized(item, size: size)
                var fitted = candidate(proposed), wordAware = false
                if let words = words(proposed, maxLines: original.profile.lines + allowance), contentFits(words),
                   contained(words, baseline: original), words.profile.penalty < fitted.profile.penalty {
                    fitted = words; wordAware = true
                }
                trace("cohort-candidate", fitted, target: target, wordAware: wordAware,
                      contained: contained(fitted, baseline: original))
                let extra = item.wrappingScript == "korean" && item.fontSize < 8 && size > item.fontSize ? 2 : 0
                guard contentFits(fitted), contained(fitted, baseline: original),
                      fitted.profile.lines <= original.profile.lines + allowance,
                      fontFlowFits(fitted.profile, baseline.profile, extraWordBreaks: extra)
                else { continue }
                var accepted = fitted.item
                if wordAware { accepted.captionFixedBoxReflowDisabled = true }
                trace("cohort-accepted", fitted, target: target, wordAware: wordAware, accepted: true)
                return accepted
            }
            return item
        }
        func repaired(_ item: NativeTranslationLayoutItem, others: [NativeTranslationLayoutItem]) -> NativeTranslationLayoutItem {
            guard item.wrappingScript == "korean", item.captionFixedBoxReflowDisabled != true else { return item }
            let original = candidate(item)
            trace("wrap-original", original)
            rememberInk(original)
            guard original.profile.lines >= 2, original.profile.penalty > 0,
                  let words = words(item, maxLines: original.profile.lines), contentFits(words),
                  koreanWrapImproves(words.profile, original.profile), contained(words, baseline: original) else { return item }
            var accepted = words.item
            accepted.captionFixedBoxReflowDisabled = true
            trace("wrap-accepted", words, wordAware: true, accepted: true)
            return accepted
        }
        func scaled(_ item: NativeTranslationLayoutItem, size: CGFloat,
                    others: [NativeTranslationLayoutItem]) -> NativeTranslationLayoutItem? {
            let original = candidate(item), k = size / item.fontSize
            guard k.isFinite, k > 0, contentFits(original), !original.inkFrame.isNull else { return nil }
            var proposed = resized(item, size: size)
            proposed.typesettingText = original.shaped.lineRanges.compactMap { range in
                let text = original.shaped.shapedText as NSString
                guard NSMaxRange(range) <= text.length else { return nil }
                return text.substring(with: range).replacingOccurrences(of: "\n", with: "")
            }.joined(separator: "\n")
            if restored(item.id) {
                proposed.width *= k; proposed.height *= k
                proposed.paddingLeft *= k; proposed.paddingRight *= k; proposed.paddingTop *= k; proposed.paddingBottom *= k
            } else if k > 1 { return nil }
            let moved = candidate(proposed)
            guard !moved.inkFrame.isNull else { return nil }
            proposed.x += original.inkFrame.midX - moved.inkFrame.midX
            proposed.y += original.inkFrame.midY - moved.inkFrame.midY
            let final = candidate(proposed)
            guard contentFits(final), final.profile.lines == original.profile.lines, clear(final, others: others, prior: original) else { return nil }
            if k <= 1 {
                return original.inkFrame.insetBy(dx: -1, dy: -1).contains(final.inkFrame) ? proposed : nil
            }
            return holdsSurface(final, expands: true, usesBalloonBudget: true) ? proposed : nil
        }
        /// Search the same source-centred measures as the browser's native-crop
        /// pass. Every proposal is a fresh full layout; neither a clipped line
        /// nor a successful size at a different measure proves this proposal.
        func growthLayout(_ item: NativeTranslationLayoutItem, size: CGFloat, allowWide: Bool, liftWide: Bool,
                          lift: Bool, extended: Bool = false, display: Bool = false, condensed: Bool = false, extraBreaks: Int, original: Candidate,
                          search: GrowthSearch, others: [NativeTranslationLayoutItem]) -> Candidate? {
            guard let patch = patches[item.id], item.sourceBounds.count == 4 else { return nil }
            guard (!extended || growth.balloonExtendedRemaining > 0),
                  (!display || growth.balloonDisplayRemaining > 0),
                  (!condensed || growth.balloonCondensedRemaining > 0),
                  (!lift || (liftWide ? growth.balloonLiftWideRemaining : growth.balloonLiftRemaining) > 0) else { return nil }
            let savedType = growth.balloonTypeRemaining, savedSurface = growth.balloonSurfaceRemaining
            let savedExterior = reader.exteriorBudget, savedShift = growth.shiftBudget, savedMoves = search.movedAttempts
            defer {
                let spent = max(1, (savedType - growth.balloonTypeRemaining) * 64 +
                    savedSurface - growth.balloonSurfaceRemaining + savedExterior - reader.exteriorBudget)
                if extended { growth.balloonExtendedRemaining -= spent }
                if display { growth.balloonDisplayRemaining -= spent }
                if condensed { growth.balloonCondensedRemaining -= spent }
                if lift {
                    let charged = spent + max(0, savedShift - growth.shiftBudget)
                    if liftWide { growth.balloonLiftWideRemaining -= charged }
                    else { growth.balloonLiftRemaining -= charged }
                    growth.shiftBudget = savedShift; search.movedAttempts = savedMoves
                }
                if extended || display || lift || condensed {
                    growth.balloonTypeRemaining = savedType; growth.balloonSurfaceRemaining = savedSurface
                    reader.exteriorBudget = savedExterior
                }
            }
            let b = item.sourceBounds, frame = sourceFrame
            var region = patch.rect
            if (extended || lift), patch.surfaceQuality?["safe"] as? Bool == true,
               patch.surfaceQuality?["coefficients"] is [[Double]] {
                let glyph = sourceGlyph(item, frame: frame)
                let reach = lift && belowReadableSource(glyph) ? 9 / 0.9 : glyph
                let amount = min(64, reach * 1.5)
                region = region.insetBy(dx: -amount, dy: -amount).intersection(frame)
            }
            let sourceCX = frame.minX + (b[0] + b[2] / 2) * frame.width
            let sourceCY = frame.minY + (b[1] + b[3] / 2) * frame.height
            let sourceWidth = b[2] * frame.width, sourceHeight = b[3] * frame.height
            let aspect = max(0.5, min(3, sourceWidth / max(1, sourceHeight)))
            let ratio = max(1, item.lineHeight / item.fontSize)
            let fontStyle = style(resized(item, size: size))
            let advance = NativeTranslationTypography.measuredWidth(text: item.text, style: fontStyle)
                - CGFloat(max(0, item.text.unicodeScalars.count - 1)) * fontStyle.tracking
            let measuredCenters = [CGPoint(x: sourceCX, y: sourceCY), CGPoint(x: original.inkFrame.midX, y: original.inkFrame.midY)]
            var centers: [CGPoint] = []
            for center in measuredCenters where !centers.contains(where: { abs($0.x - center.x) < 0.5 && abs($0.y - center.y) < 0.5 }) {
                centers.append(center)
            }
            var anchors = centers.map { (point: $0, measure: CGFloat?.none) }, anchorIndex = 0
            var misplaced: (frame: CGRect, width: CGFloat, anchor: CGPoint)?
            while anchorIndex < anchors.count {
                let value = anchors[anchorIndex], anchor = value.point, moved = value.measure != nil
                anchorIndex += 1
                let height = 2 * min(anchor.y - region.minY - 2, region.maxY - anchor.y - 2)
                guard height >= size * ratio else { continue }
                func clampWidth(_ value: CGFloat) -> CGFloat {
                    quarterFloor(min(value, 2 * min(region.maxX - anchor.x, anchor.x - region.minX) - 2))
                }
                var widths: [CGFloat] = []
                let proposedWidths = [sqrt(advance * size * ratio * aspect) * 1.12, sourceWidth,
                                      original.inkFrame.width * size / item.fontSize,
                                      min(region.maxX - anchor.x, anchor.x - region.minX) * 2 * 0.9]
                    + (advance + 2 < size * 1.8 ? [advance + 2] : [])
                for width in proposedWidths.map(clampWidth) where !widths.contains(width) { widths.append(width) }
                if let measure = value.measure {
                    if let index = widths.firstIndex(of: measure) { widths.remove(at: index) }
                    widths.insert(measure, at: 0)
                }
                let longest = koreanWordWidth(text: item.text, style: fontStyle)
                var wordWidth = clampWidth(longest)
                var condense: CGFloat = condensed ? 0.9 : 1
                var fullWidths: [CGFloat] = []
                if condensed {
                    // Only compression may fit these painted widths. Every
                    // original full-width candidate must fail the same proof.
                    let narrow = ceil((longest * condense + 1) * 4) / 4
                    for width in widths + [wordWidth] where width >= longest && !fullWidths.contains(width) {
                        fullWidths.append(width)
                    }
                    widths = Array(widths.filter { $0 > narrow && $0 < longest }.prefix(1))
                        + (clampWidth(narrow) >= narrow ? [narrow] : [])
                    wordWidth = narrow
                    if widths.isEmpty { continue }
                }
                var lastWide = false
                func place(_ width: CGFloat, wideAllowed: Bool) -> Candidate? {
                    let logicalWidth = width / condense
                    guard logicalWidth >= min(size * 1.8, advance + 1), height > 0,
                          !moved || growth.shiftBudget > 0,
                          item.text.utf16.count <= growth.balloonTypeRemaining,
                          growth.balloonSurfaceRemaining > 0 else { return nil }
                    let savedType = growth.balloonTypeRemaining, savedSurface = growth.balloonSurfaceRemaining
                    let savedExterior = reader.exteriorBudget
                    defer {
                        if moved {
                            growth.shiftBudget -= max(1, (savedType - growth.balloonTypeRemaining) * 64 +
                                savedSurface - growth.balloonSurfaceRemaining + savedExterior - reader.exteriorBudget)
                            growth.balloonTypeRemaining = savedType; growth.balloonSurfaceRemaining = savedSurface
                            reader.exteriorBudget = savedExterior
                        }
                    }
                    growth.balloonTypeRemaining -= item.text.utf16.count
                    var proposed = resized(item, size: size)
                    proposed.x = anchor.x - width / 2; proposed.y = anchor.y - height / 2
                    proposed.width = width; proposed.height = height
                    // Items retain painted dimensions; the native shaper
                    // expands the available measure by horizontalScale once.
                    if condensed { proposed.typesettingWidthScale = condense < 1 ? condense : nil }
                    proposed.paddingTop = 0; proposed.paddingRight = 0; proposed.paddingBottom = 0; proposed.paddingLeft = 0
                    proposed.typesettingText = nil; proposed.typesettingQuoteMode = nil; proposed.typesettingPreformattedRows = nil
                    let maxLines = min(original.profile.lines + 4, Int(floor(height / (size * ratio))))
                    guard maxLines >= 1 else { return nil }
                    var result: Candidate
                    lastWide = false
                    if let narrow = words(proposed, maxLines: maxLines, strict: true) { result = narrow }
                    else if advance > logicalWidth {
                        guard wideAllowed, advance * condense > (widths.max() ?? 0) - 1,
                              let wide = words(proposed, maxLines: maxLines, wide: true) else { return nil }
                        if wide.profile.lines > original.profile.lines, size < item.fontSize * 1.25 { return nil }
                        result = wide; lastWide = true
                    } else { result = candidate(proposed) }
                    if growth.collectInitialDiagnostics { trace("growth-shaped-trial", result, target: size) }
                    guard !liftWide || lastWide, contentFits(result),
                          fontFlowFits(result.profile, original.profile, extraWordBreaks: moved ? 0 : extraBreaks), result.profile.lines <= maxLines,
                          growthKeepsLineLength(text: item.text, originalLines: original.profile.lines, lines: result.profile.lines),
                          !condensed || (result.profile.hangulIsolated <= original.profile.hangulIsolated &&
                            result.profile.lines <= original.profile.lines + 1) else { return nil }
                    func refusedPlacement() -> Candidate? {
                        if misplaced == nil && !moved { misplaced = (result.inkFrame, width, anchor) }
                        return nil
                    }
                    guard region.contains(result.inkFrame) else { return refusedPlacement() }
                    let gap = lift ? size * 0.35 : 0
                    let gx = lastWide ? max(size * 0.5, 1 + gap) : 1 + gap
                    let gy = lastWide ? max(size * 0.5, 0.75 + gap) : 0.75 + gap
                    let area = result.inkFrame.insetBy(dx: -gx, dy: -gy)
                    for other in others where other.id != item.id {
                        if placementObstacles(other).contains(where: { !$0.isNull && area.intersects($0) }) {
                            return refusedPlacement()
                        }
                    }
                    let margin = lift ? CGSize(width: max(2, size * 0.25), height: max(2, size * 0.25))
                        : extended || condensed ? CGSize(width: max(1, size * 0.1), height: max(0.75, size * 0.1)) : nil
                    guard clear(result, others: others), holdsSurface(result, expands: true, allowExterior: true,
                        margin: moved ? CGSize(width: max(1, size * 0.1), height: max(0.75, size * 0.1)) : margin,
                        lookupLimit: patch.surfaceQuality?["reason"] as? String == "ruled-grid" ? 262_144 : 65_536,
                        usesBalloonBudget: true)
                    else { return refusedPlacement() }
                    guard abs(result.inkFrame.midX - anchor.x) <= 1.5, abs(result.inkFrame.midY - anchor.y) <= 1.5 else { return nil }
                    return result
                }
                func rank(_ p: Profile) -> Int {
                    (p.hangulFragments + p.punctuationOnly + p.badStarts.count + p.badEnds.count) * 100 + p.breaks.count
                }
                if condensed, !fullWidths.isEmpty {
                    condense = 1
                    let fitsWithoutCompression = fullWidths.contains { place($0, wideAllowed: allowWide) != nil }
                    condense = 0.9
                    if fitsWithoutCompression { return nil }
                }
                for index in widths.indices {
                    if moved {
                        if search.movedAttempts >= 6 { break }; search.movedAttempts += 1
                    } else {
                        guard search.takeWidthAttempt() else { return nil }
                    }
                    guard var best = place(widths[index], wideAllowed: allowWide) else { continue }
                    var bestRank = rank(best.profile), bestWide = lastWide
                    if bestRank > 0 {
                        for other in Array(widths.dropFirst(index + 1)) + [wordWidth] where other != best.item.width {
                            if let repaired = place(other, wideAllowed: allowWide), rank(repaired.profile) < bestRank {
                                best = repaired; bestRank = rank(repaired.profile); bestWide = lastWide
                            }
                            if bestRank == 0 { break }
                        }
                    }
                    if bestWide {
                        var alternatives: [CGFloat] = []
                        for other in Array(widths.dropFirst(index + 1)) + [clampWidth(advance + 2)] where !alternatives.contains(other) {
                            alternatives.append(other)
                        }
                        for other in alternatives where other != best.item.width && other > 0 {
                            if let plain = place(other, wideAllowed: false), rank(plain.profile) <= bestRank { best = plain; break }
                        }
                    }
                    if growth.collectInitialDiagnostics { trace("growth-accepted", best, target: size, accepted: true) }
                    return best
                }
                if !condensed, !moved, anchorIndex == centers.count, anchors.count == centers.count, let refused = misplaced {
                    if !search.tableAttempted {
                        search.tableAttempted = true
                        if let safe = patch.layoutSafe, safe.count <= growth.shiftBudget {
                            growth.shiftBudget -= safe.count
                            let obstacles = others.filter { $0.id != item.id }.flatMap(placementObstacles)
                            search.table = NativeTypographyPlacementSearch.Table(safe: safe, width: patch.image.width,
                                height: patch.image.height, crop: patch.rect, obstacles: obstacles)
                            if growth.collectInitialDiagnostics,
                               growth.initialTypographyTrace[item.id, default: []].count < 60 {
                                growth.initialTypographyTrace[item.id, default: []].append([
                                    "stage": "growth-shift-table", "font": size,
                                    "obstacles": obstacles.filter { !$0.isNull && !$0.isInfinite }.map { [$0.minX, $0.minY, $0.width, $0.height] },
                                    "crop": [patch.rect.minX, patch.rect.minY, patch.rect.width, patch.rect.height],
                                    "raster": [patch.image.width, patch.image.height]])
                            }
                        }
                    }
                    let glyph = sourceGlyph(item, frame: frame), reach = lift && belowReadableSource(glyph) ? 9 / 0.9 : glyph
                    func recordShift(_ record: [String: Any]) {
                        if growth.initialTypographyTrace[item.id, default: []].count < 60 {
                            growth.initialTypographyTrace[item.id, default: []].append(record)
                        }
                    }
                    if let delta = search.table?.nearestShift(frame: refused.frame, size: size, region: region, reachGlyph: reach,
                        diagnostic: growth.collectInitialDiagnostics ? recordShift : nil) {
                        anchors.append((CGPoint(x: refused.anchor.x + delta.x, y: refused.anchor.y + delta.y), refused.width))
                    }
                }
            }
            return nil
        }
        func interiorGaps(_ item: NativeTranslationLayoutItem, value: CGFloat?, others: [NativeTranslationLayoutItem]) -> Int {
            guard item.sourceBounds.count == 4 else { return 0 }
            let f = sourceFrame, b = item.sourceBounds, glyph = item.sourceFontSize ?? 0
            let mine = item.sourceVertical ? b[2] * f.width : b[3] * f.height
            let a = CGRect(x: f.minX + b[0] * f.width, y: f.minY + b[1] * f.height,
                           width: b[2] * f.width, height: b[3] * f.height)
            var count = 0
            for other in others where other.id != item.id && !other.keptLettering {
                guard other.sourceVertical == item.sourceVertical, other.sourceBounds.count == 4, other.fontSize > 0 else { continue }
                let q = other.sourceBounds
                if let contour = item.balloonInterior, contour.contourVerified, contour.rect.count == 4 {
                    let r = contour.rect, cx = q[0] + q[2] / 2, cy = q[1] + q[3] / 2
                    if cx < r[0] || cx > r[0] + r[2] || cy < r[1] || cy > r[1] + r[3] { continue }
                }
                let ratio = value.map { max($0, other.fontSize) / min($0, other.fontSize) } ?? .infinity
                let theirs = other.sourceVertical ? q[2] * f.width : q[3] * f.height
                if value != nil, mine > 0, theirs > 0, max(mine, theirs) / min(mine, theirs) <= 1.15, ratio > 1.25 { count += 1 }
                let c = CGRect(x: f.minX + q[0] * f.width, y: f.minY + q[1] * f.height,
                               width: q[2] * f.width, height: q[3] * f.height)
                let cross = item.sourceVertical ? min(a.maxX, c.maxX) - max(a.minX, c.minX) : min(a.maxY, c.maxY) - max(a.minY, c.minY)
                let gap = item.sourceVertical ? max(a.minY, c.minY) - min(a.maxY, c.maxY) : max(a.minX, c.minX) - min(a.maxX, c.maxX)
                let axisA = item.sourceVertical ? a.width : a.height, axisB = item.sourceVertical ? c.width : c.height
                let peerGlyph = other.sourceFontSize ?? 0
                if cross > 0.6 * min(axisA, axisB), gap < 3 * max(axisA, axisB), glyph > 0, peerGlyph > 0,
                   max(glyph, peerGlyph) / min(glyph, peerGlyph) <= 1.2, ratio > 1.15 { count += 1 }
            }
            return count
        }
        func interiorGrowing(_ item: NativeTranslationLayoutItem, floor: CGFloat, repair: Int = 0, cap: CGFloat,
                             styleGlyph: CGFloat, original: Candidate, others: [NativeTranslationLayoutItem]) -> NativeTranslationLayoutItem? {
            guard floor > 0, item.text.utf16.count <= 80, growth.interiorBudget > 0,
                  let interior = item.balloonInterior, item.sourceBounds.count == 4,
                  let shape = balloonShape(rect: interior.rect, center: interior.center, spans: interior.spans, frame: sourceFrame),
                  growth.runs[item.id] == 1 || growth.interiorFirst.contains(item.id) else { return nil }
            let glyph = sourceGlyph(item, frame: sourceFrame), floored = belowReadableSource(glyph)
            let toFloor = floored && floor < 9
            let lowest = repair > 0 ? floor : toFloor ? min(floor * 1.06, floor + 0.25) : floor * 1.06
            let limit = quarterFloor(min(32, max(glyph * 0.9, styleGlyph * 0.9, floored ? 9 : 0), cap))
            let worth = repair > 0 ? floor : toFloor ? min(floor * 1.1, floor + 0.25) : floor * 1.1
            guard limit >= worth, let background = restoration.appearances[item.id]?.background,
                  let rgb = background.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components,
                  rgb.count >= 3 else { return nil }
            let paper = rgb.prefix(3).map { $0 * 255 }
            guard interior.contourVerified || (paper.min() ?? 0) >= 170 && (paper.max() ?? 0) - (paper.min() ?? 0) <= 48,
                  interiorGaps(item, value: nil, others: others) == 0 else { return nil }
            let b = item.sourceBounds, f = sourceFrame
            let own = CGRect(x: f.minX + b[0] * f.width, y: f.minY + b[1] * f.height,
                             width: b[2] * f.width, height: b[3] * f.height)
            guard !(shape.area > 8 * own.width * own.height && shape.rectangularity > 0.93) else { return nil }
            for other in layout.items where other.id != item.id && other.sourceBounds.count == 4 {
                let q = other.sourceBounds
                if shape.contains(CGPoint(x: f.minX + (q[0] + q[2] / 2) * f.width,
                                          y: f.minY + (q[1] + q[3] / 2) * f.height)) { return nil }
            }
            let anchor = CGPoint(x: own.midX, y: own.midY), ratio = max(1, item.lineHeight / item.fontSize)
            guard shape.contains(anchor), let centerSpan = shape.rowSpan(shape.center.y) else { return nil }
            let upperStyle = style(resized(item, size: limit))
            func untracked(_ text: String, _ style: NativeTranslationTypography.Style) -> CGFloat {
                NativeTranslationTypography.measuredWidth(text: text, style: style)
                    - CGFloat(max(0, text.unicodeScalars.count - 1)) * style.tracking
            }
            let longest = koreanWordWidth(text: item.text, style: upperStyle), advance = untracked(item.text, upperStyle)
            guard longest > 0, advance > 0 else { return nil }
            let byWord = limit * (centerSpan[1] - centerSpan[0] - 2 * max(2, limit * 0.2)) / longest
            let byArea = limit * sqrt(shape.area * 0.45 / (advance * limit * ratio))
            let allowedGaps = interiorGaps(item, value: floor, others: others)
            var sizes: [CGFloat] = [], size = quarterFloor(min(limit, byWord * 1.02, byArea))
            // The source loop stops after six accepted sizes, rather than six
            // rejected gap checks; the monotonic descent cannot loop at zero.
            while size >= lowest - 0.001, sizes.count < 6, size > 0 {
                if interiorGaps(item, value: size, others: others) <= allowedGaps { sizes.append(size) }
                let next = quarterFloor(size * 0.94)
                if next >= size { break }; size = next
            }
            if sizes.last != floor, sizes.count < 7 { sizes.append(floor) }
            guard !sizes.isEmpty else { return nil }
            let savedType = growth.balloonTypeRemaining, savedSurface = growth.balloonSurfaceRemaining
            let savedExterior = reader.exteriorBudget
            let surfaceAllowance = min(growth.interiorBudget, 262_144)
            growth.balloonSurfaceRemaining = surfaceAllowance
            defer {
                growth.interiorBudget -= max(1, (savedType - growth.balloonTypeRemaining) * 64 +
                    surfaceAllowance - growth.balloonSurfaceRemaining + savedExterior - reader.exteriorBudget)
                growth.balloonTypeRemaining = savedType; growth.balloonSurfaceRemaining = savedSurface
                reader.exteriorBudget = savedExterior
            }
            var attempts = 0
            for size in sizes {
                let pitch = size * ratio, clearance = max(2, size * 0.2), fontStyle = style(resized(item, size: size))
                guard let span = shape.rowSpan(anchor.y) else { continue }
                let room = 2 * min(span[1] - anchor.x, anchor.x - span[0]) - 2 * clearance
                let wordWidth = koreanWordWidth(text: item.text, style: fontStyle)
                let maxLines = min(original.profile.lines + 4, Int(Foundation.floor(shape.rect.height / pitch)))
                guard room >= wordWidth, maxLines >= 1 else { continue }
                var layouts: [(lines: [String], widths: [CGFloat])] = [], seen = Set<String>()
                for factor: CGFloat in [1, 0.86, 0.74, 0.63, 0.54, 0.46] {
                    let width = room * factor
                    if width < wordWidth { break }
                    guard let lines = NativeTranslationTypography.koreanLines(text: item.text,
                        available: CGSize(width: width, height: CGFloat(maxLines) * pitch), style: fontStyle, maxLines: maxLines),
                        lines.dropLast().allSatisfy({ $0.last?.isWhitespace == true }) else { continue }
                    let key = lines.joined(separator: "|")
                    guard seen.insert(key).inserted else { continue }
                    let widths = lines.map { NativeTranslationTypography.measuredWidth(text: $0.trimmingCharacters(in: .whitespacesAndNewlines), style: fontStyle) }
                    let top = anchor.y - CGFloat(lines.count) * pitch / 2
                    guard !widths.enumerated().contains(where: { index, width in
                        shape.outside(CGRect(x: anchor.x - width / 2, y: top + CGFloat(index) * pitch + (pitch - size) / 2,
                                             width: width, height: size).insetBy(dx: -clearance / 2, dy: -clearance / 2))
                    }) else { continue }
                    layouts.append((lines, widths))
                }
                layouts.sort { $0.lines.count != $1.lines.count ? $0.lines.count < $1.lines.count
                    : ($0.widths.max() ?? 0) < ($1.widths.max() ?? 0) }
                for value in layouts {
                    guard attempts < 10, item.text.utf16.count <= growth.balloonTypeRemaining,
                          growth.balloonSurfaceRemaining > 0 else { return nil }
                    attempts += 1; growth.balloonTypeRemaining -= item.text.utf16.count
                    var proposed = resized(item, size: size)
                    proposed.width = ceil(value.widths.max() ?? 0) + 2; proposed.height = CGFloat(value.lines.count) * pitch
                    proposed.x = anchor.x - proposed.width / 2; proposed.y = anchor.y - proposed.height / 2
                    proposed.paddingLeft = 0; proposed.paddingRight = 0; proposed.paddingTop = 0; proposed.paddingBottom = 0
                    proposed = NativeTypographyPostPolish.replacingWithBlockWords(proposed,
                        lines: value.lines, quoteMode: 0)
                    var result = candidate(proposed)
                    guard contentFits(result), result.profile.lines == value.lines.count,
                          fontFlowFits(result.profile, original.profile),
                          repair == 0 || result.profile.breaks.count < repair,
                          growthKeepsLineLength(text: item.text, originalLines: original.profile.lines, lines: result.profile.lines),
                          f.insetBy(dx: 1, dy: 1).contains(result.inkFrame),
                          !result.ink.contains(where: { shape.outside($0.insetBy(dx: -clearance, dy: -clearance)) }),
                          clear(result, others: others) else { continue }
                    let block = result.inkFrame.insetBy(dx: -clearance, dy: -clearance)
                    if others.contains(where: { other in
                        guard other.id != item.id else { return false }
                        return placementObstacles(other).contains { !$0.isNull && block.intersects($0) }
                    }) { continue }
                    let margin = CGSize(width: max(1, size * 0.1), height: max(0.75, size * 0.1))
                    var fits = holdsSurface(result, allowExterior: true, margin: margin, lookupLimit: 65_536,
                        usesBalloonBudget: true)
                    if !fits, interior.contourVerified,
                       let ink = fontStyle.foreground.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components,
                       ink.count >= 3, (ink.prefix(3).min() ?? 0) * 255 >= 230,
                       let range = inspectedSurface(result, allowExterior: true, margin: margin), range[1] <= 0.30,
                       (sourceLuminance(ink.prefix(3).map { Double($0) * 255 }) + 0.05) / (range[1] + 0.05) >= 3 {
                        proposed.typesettingOutlineRGB = [24, 18, 28]
                        proposed.typesettingOutlineWidth = max(0.5, size * 0.055)
                        result = candidate(proposed); fits = true
                    }
                    guard fits else { continue }
                    if growth.runs[item.id] == 1 { growth.interiorFirst.insert(item.id) }
                    growth.interior.insert(item.id)
                    growth.interiorBase[item.id] = floor
                    result.item.typesettingDisplayGrowth = nil
                    return result.item
                }
            }
            return nil
        }
        func growing(_ current: NativeTranslationLayoutItem, cap: CGFloat = .infinity, extraBreaks: Int = 1,
                     styleGlyph: CGFloat = 0, others: [NativeTranslationLayoutItem]) -> NativeTranslationLayoutItem? {
            var item = growth.original[current.id] ?? current
            // CSS/children restore from the baseline, while the live dataset
            // survives retries. A nil live marker is an accepted deletion.
            item.typesettingDisplayGrowth = current.typesettingDisplayGrowth
            guard eligible(item), !item.balancedColumn, item.rotation == 0, item.allowsAutomaticFontRecovery,
                  item.wrappingScript == "korean", !item.text.contains(where: \.isNewline),
                  restored(item.id) else { return nil }
            growth.original[item.id] = item
            growth.runs[item.id, default: 0] += 1
            growth.base.removeValue(forKey: item.id)
            growth.extended.remove(item.id)
            growth.interior.remove(item.id)
            growth.interiorBase.removeValue(forKey: item.id)
            growth.readablePeer.removeValue(forKey: item.id)
            let glyph = sourceGlyph(item, frame: sourceFrame), font = item.fontSize
            guard glyph.isFinite, glyph > 0 else { return nil }
            func returned(_ result: NativeTranslationLayoutItem?) -> NativeTranslationLayoutItem? {
                // Record existing state only; diagnostics must not shape or probe a candidate again.
                if growth.collectInitialDiagnostics,
                   growth.initialTypographyTrace[item.id, default: []].count < 64 {
                    var record: [String: Any] = ["stage": "growth-return", "returnedNil": result == nil,
                        "originalFont": font, "currentFont": current.fontSize,
                        "extended": growth.extended.contains(item.id), "interior": growth.interior.contains(item.id),
                        "runs": growth.runs[item.id, default: 0], "extraBreaks": extraBreaks,
                        "cap": cap.isFinite ? cap as Any : "Infinity"]
                    record["base"] = growth.base[item.id].map { $0 as Any } ?? NSNull()
                    record["interiorBase"] = growth.interiorBase[item.id].map { $0 as Any } ?? NSNull()
                    if let result {
                        record["font"] = result.fontSize
                        record["rect"] = [result.x, result.y, result.width, result.height]
                    }
                    growth.initialTypographyTrace[item.id, default: []].append(record)
                }
                return result
            }
            let target = quarterFloor(min(32, font * 1.8, max(glyph, styleGlyph) * 0.9, cap))
            let floored = glyph * 0.9 < 9
            if floored {
                growth.readablePeer[item.id] = max(growth.readablePeer[item.id] ?? 0, font,
                                                  quarterFloor(min(32, max(glyph, styleGlyph) * 0.9)))
            }
            var readable: [CGFloat] = []
            if floored {
                let top = quarterFloor(min(9, cap, font * 1.8))
                readable = [top, top - 0.25, top - 0.5].filter {
                    $0 > target + 0.01 && $0 >= font + 0.25 && $0 >= min(font * 1.08, 8.5)
                }
            }
            var display: [CGFloat] = []
            if glyph >= 40 {
                var size = quarterFloor(min(128, glyph * 0.85, cap))
                while size > max(target, font * 1.08), display.count < 8 {
                    display.append(size); size = quarterFloor(size * 0.9)
                }
            }
            guard target >= font * 1.08 || !readable.isEmpty || !display.isEmpty else {
                return returned(current == item ? nil : item)
            }
            let original = candidate(item), search = GrowthSearch()
            if growth.collectInitialDiagnostics { trace("growth-baseline", original) }
            var normal: [CGFloat] = []
            if target >= font * 1.08 {
                let low = font * 1.08
                normal = (0..<6).map { quarterFloor(target - (target - low) * CGFloat($0) / 5) }
            }
            let passes: [([CGFloat], Bool, Bool, Bool, Bool)] = [(readable, false, true, false, false), (readable, true, true, false, false),
                (display, true, false, false, true), (normal, true, false, false, false), (normal, true, false, true, false)]
            var kept: NativeTranslationLayoutItem?
            growthPasses: for (sizes, wide, lift, extended, isDisplay) in passes {
                search.beginWidthPass()
                for size in sizes {
                    if let kept, size < kept.fontSize * 1.06 { continue }
                    if let fitted = growthLayout(item, size: size, allowWide: wide, liftWide: lift && wide,
                                                 lift: lift, extended: extended, display: isDisplay, extraBreaks: kept == nil ? extraBreaks : 0,
                                                 original: original, search: search, others: others) {
                        var accepted = fitted.item
                        if isDisplay { accepted.typesettingDisplayGrowth = "balloon" }
                        if lift || extended || size >= max(normal.max() ?? 0, display.max() ?? 0) {
                            growth.base[item.id] = kept?.fontSize ?? size
                            if extended { growth.extended.insert(item.id) } else { growth.extended.remove(item.id) }
                            return returned(interiorGrowing(accepted, floor: size, repair: fitted.profile.breaks.count,
                                                   cap: cap, styleGlyph: styleGlyph, original: original, others: others) ?? accepted)
                        }
                        kept = accepted; break
                    }
                    if search.widthPassExhausted {
                        // The ordinary failed search stops later passes. The
                        // independently budgeted display/floor passes do not.
                        if !lift && !isDisplay && kept == nil { break growthPasses }
                        break
                    }
                }
            }
            if let kept {
                growth.base[item.id] = kept.fontSize; growth.extended.remove(item.id)
                return returned(interiorGrowing(kept, floor: kept.fontSize, cap: cap, styleGlyph: styleGlyph,
                                       original: original, others: others) ?? kept)
            }
            return returned(interiorGrowing(item, floor: font, cap: cap, styleGlyph: styleGlyph, original: original, others: others)
                ?? (current == item ? nil : item))
        }
        func condensed(_ item: NativeTranslationLayoutItem, cap: CGFloat,
                       others: [NativeTranslationLayoutItem]) -> NativeTranslationLayoutItem? {
            guard eligible(item), item.wrappingScript == "korean", item.fontScript == "korean", !item.vertical,
                  !item.balancedColumn, item.rotation == 0, item.allowsAutomaticFontRecovery,
                  item.typesettingWidthScale == nil, !growth.interior.contains(item.id), item.text.utf16.count <= 80,
                  growth.balloonCondensedRemaining > 0,
                  sourceGlyph(item, frame: sourceFrame) < 40,
                  restored(item.id) else { return nil }
            let font = item.fontSize, glyph = sourceGlyph(item, frame: sourceFrame)
            let initialFont = growth.original[item.id]?.fontSize ?? font
            let target = quarterFloor(min(32, initialFont * 1.8, glyph * 0.9, cap))
            guard target >= font * 1.08 else { return nil }
            let original = candidate(item), search = GrowthSearch()
            for size in condensedSizes(base: font, target: target) {
                guard growth.balloonCondensedRemaining > 0 else { break }
                if let result = growthLayout(item, size: size, allowWide: true, liftWide: false, lift: false,
                    condensed: true, extraBreaks: 0, original: original, search: search, others: others) {
                    return result.item
                }
            }
            return nil
        }
    }

    private static func sourceLuminance(_ rgb: [Double]) -> Double {
        let linear = rgb.prefix(3).map { value -> Double in
            let v = value / 255
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        guard linear.count == 3 else { return .nan }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }

    private static func sourceGlyph(_ item: NativeTranslationLayoutItem, frame: CGRect) -> CGFloat {
        if let glyph = item.sourceFontSize, glyph.isFinite, glyph > 0 { return glyph }
        guard item.sourceBounds.count == 4 else { return .nan }
        return min(item.sourceBounds[2] * frame.width, item.sourceBounds[3] * frame.height)
    }
    private static func spread(_ values: [CGFloat]) -> CGFloat {
        guard let low = values.min(), let high = values.max(), low > 0 else { return .infinity }
        return high / low
    }
    private static func sourceBox(_ item: NativeTranslationLayoutItem, frame: CGRect,
                                  appearance: NativeTranslationRestoration.Appearance?, labelOverride: String? = nil) -> SourceBox? {
        guard item.sourceBounds.count == 4 else { return nil }
        let bounds = item.sourceBounds
        let label: String
        if let labelOverride { label = labelOverride }
        else if let color = appearance?.background?.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
           let components = color.components, components.count >= 3,
           (components.prefix(3).max() ?? 0) - (components.prefix(3).min() ?? 0) > 40 / 255 {
            label = components.prefix(3).map { String(Int(floor($0 * 255 / 48 + 0.5))) }.joined(separator: ",")
        } else { label = "" }
        return SourceBox(x: frame.minX + bounds[0] * frame.width, y: frame.minY + bounds[1] * frame.height,
                         w: bounds[2] * frame.width, h: bounds[3] * frame.height, glyph: sourceGlyph(item, frame: frame),
                         script: item.fontScript, vertical: item.sourceVertical, style: label)
    }

    /// Dedicated final balloonSafeFit trial. The caller owns panel removal and
    /// commits its mutable restoration candidate only after this measured fit.
    struct RendererGrowthRecord {
        let id: String
        let original: NativeTranslationLayoutItem
        let font: CGFloat
        let sourceGlyph: CGFloat
        let runs: Int
        let beforeInteriorFont: CGFloat
        let readablePeerFont: CGFloat
        let interiorGrowth: Bool
        let base: CGFloat
        let extended: Bool
        let inPlace: Bool
        var script: String { original.wrappingScript }
        var vertical: Bool { original.vertical }
    }

    /// Retain one real shaping/surface context for the page's grower retries.
    /// Renderer creates this before refining and passes it through both phases;
    /// a cap trial therefore restores the original cohort-era card snapshot.
    enum RefinementPhase { case all, initial, growth, harmony }

    final class RendererGrowthSession {
        var context: Context
        init(_ context: Context) { self.context = context }
        var collectInitialDiagnostics: Bool {
            get { context.growth.collectInitialDiagnostics }
            set { context.growth.collectInitialDiagnostics = newValue }
        }
        func initialTypographyTrace(id: String) -> [[String: Any]] {
            context.growth.initialTypographyTrace[id] ?? []
        }

        /// Keep the page's budgets/history/cache while replacing accepted
        /// restoration patches and the current live caption geometry.
        func refresh(restoration: NativeTranslationRestoration.Result, layout: NativeTranslationLayout) {
            context = context.refreshed(restoration: restoration, layout: layout)
        }

        func records(items: [NativeTranslationLayoutItem]) -> [RendererGrowthRecord] {
            items.compactMap { item in
                guard let original = context.growth.original[item.id], item.fontSize >= original.fontSize * 1.08 else { return nil }
                return RendererGrowthRecord(id: item.id, original: original, font: item.fontSize,
                    sourceGlyph: NativeTypographyPostPolish.sourceGlyph(original, frame: context.sourceFrame),
                    runs: context.growth.runs[item.id] ?? 0,
                    beforeInteriorFont: context.growth.interiorBase[item.id] ?? item.fontSize,
                    readablePeerFont: context.growth.readablePeer[item.id] ?? item.fontSize,
                    interiorGrowth: context.growth.interior.contains(item.id),
                    base: context.growth.base[item.id] ?? original.fontSize,
                    extended: context.growth.extended.contains(item.id),
                    inPlace: context.restored(item.id))
            }
        }

        func grow(item: NativeTranslationLayoutItem, others: [NativeTranslationLayoutItem], cap: CGFloat,
                  strict: Bool, foreground: CGColor? = nil) -> NativeTranslationLayoutItem? {
            var candidate = item
            if let components = foreground?.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components,
               components.count >= 3 {
                candidate.typesettingForeground = components.prefix(3).map { Double($0) * 255 }
                if var original = context.growth.original[item.id] {
                    original.typesettingForeground = candidate.typesettingForeground
                    context.growth.original[item.id] = original
                }
            }
            return context.growing(candidate, cap: cap, extraBreaks: strict ? 0 : 1, others: others)
        }

        /// Collect restored growers after plate candidates and before their
        /// shared cap retries. The same page context keeps original snapshots.
        func growRestored(items: [NativeTranslationLayoutItem], lockedIDs: Set<String> = [],
                          foregrounds: [String: CGColor] = [:]) throws -> [NativeTranslationLayoutItem] {
            var result = items
            for index in result.indices where !lockedIDs.contains(result[index].id) {
                try Task.checkCancellation()
                if let grown = grow(item: result[index], others: result, cap: .infinity, strict: false,
                                    foreground: foregrounds[result[index].id]) { result[index] = grown }
            }
            return result
        }

        func rememberedInk(id: String) -> RememberedInk? { context.growth.rememberedInk[id] }
        func commitArtwork(item: NativeTranslationLayoutItem, originalFont: CGFloat, restoredInside: Bool) {
            context.growth.finalized.insert(item.id)
            if restoredInside { context.growth.restoredInside.insert(item.id) }
            else { context.growth.restoredInside.remove(item.id) }
            context.growth.artworkOriginalFonts[item.id] = originalFont
        }
        var artworkSurfaceRemaining: Int {
            get { context.growth.artworkSurfaceBudget }
            set { context.growth.artworkSurfaceBudget = max(0, newValue) }
        }
        var restoredExteriorRemaining: Int {
            get { context.reader.exteriorBudget }
            set { context.reader.exteriorBudget = max(0, newValue) }
        }
        var restoredLookupRemaining: Int {
            get { context.growth.restoredLookupRemaining }
            set { context.growth.restoredLookupRemaining = max(0, newValue) }
        }
        var wordRepairRemaining: Int {
            get { context.growth.wordRepairRemaining }
            set { context.growth.wordRepairRemaining = newValue }
        }
        var lateWordRepairRemaining: Int {
            get { context.growth.lateWordRepairRemaining }
            set { context.growth.lateWordRepairRemaining = newValue }
        }
        var balloonTypeRemaining: Int {
            get { context.growth.balloonTypeRemaining }
            set { context.growth.balloonTypeRemaining = max(0, newValue) }
        }
        var balloonSurfaceRemaining: Int {
            get { context.growth.balloonSurfaceRemaining }
            set { context.growth.balloonSurfaceRemaining = max(0, newValue) }
        }
        /// Registration is captured once by initial refinement and retained
        /// across refreshes. TextFit is the later committed surface probe;
        /// it is not inferred from the restoration's erasure certificate.
        func lateWordRepairEntry(id: String) -> Bool {
            context.growth.registered && context.growth.admitted.contains(id) &&
                context.growth.finalized.contains(id) && context.growth.restoredInside.contains(id)
        }
        func typographyEntryRegistered(id: String) -> Bool {
            context.growth.registered && context.growth.admitted.contains(id)
        }
        func sourcePanelTextFit(id: String) -> String? {
            guard context.growth.finalized.contains(id) else { return nil }
            return context.growth.restoredInside.contains(id) ? "inside" : "caption"
        }
        func typographySurfacePatch(id: String) -> NativeTranslationRestoration.Patch? {
            context.patches[id]
        }

        func inspectSurface(item: NativeTranslationLayoutItem, typography: NativeTranslationTypography.Layout,
                            rects: [CGRect]? = nil, allowExterior: Bool = true,
                            lookupBudget: inout Int) -> [Double]? {
            let candidate = Candidate(item: item, shaped: typography,
                profile: NativeTypographyPostPolish.profile(typography, originalText: item.text), surfaceInk: rects)
            return context.inspectedSurface(candidate, allowExterior: allowExterior,
                requiresCommittedRestoration: false, lookupBudget: &lookupBudget)
        }

        /// The caption palette can change contrast after the initial surface
        /// probe. Re-admit only an independently erased (or already admitted)
        /// canvas, using the actual current glyphs and its unchanged safe mask.
        func restoreReadableInk(item: NativeTranslationLayoutItem, typography: NativeTranslationTypography.Layout,
                                foreground: [Double]) -> [Double]? {
            guard context.settings.usesSourceInpainting, context.settings.renderedBackgroundOpacity == 1,
                  context.growth.registered, context.growth.admitted.contains(item.id),
                  context.growth.surfaceInspectable.contains(item.id),
                  foreground.count == 3, foreground.allSatisfy(\.isFinite),
                  let patch = context.patches[item.id], let candidate = patch.candidate,
                  candidate.erasureComplete,
                  candidate.sourceErasureVerified || context.restored(item.id) else { return nil }
            let current = Candidate(item: item, shaped: typography,
                profile: NativeTypographyPostPolish.profile(typography, originalText: item.text))
            guard let range = context.inspectedSurface(current, allowExterior: true,
                requiresCommittedRestoration: false), range.count == 2 else { return nil }
            let contrast: ([Double]) -> Double = { ink in
                NativeTranslationSourceStylePostPolish.luminanceContrast(
                    NativeSourceColorSampler.luminance(ink), range[0], range[1])
            }
            let adjusted = NativeTranslationSourceStylePostPolish.adjustInkForContrast(foreground, contrast: contrast)
            guard contrast(adjusted) >= 4.5 else { return nil }
            context.growth.finalized.insert(item.id)
            context.growth.restoredInside.insert(item.id)
            return adjusted
        }

        func peerFont(id: String, font: CGFloat, beforeInterior: Bool) -> CGFloat {
            let value = beforeInterior ? context.growth.interiorBase[id] ?? font : font
            return min(value, context.growth.readablePeer[id] ?? value)
        }

        func interiorGaps(id: String, font: CGFloat, items: [NativeTranslationLayoutItem]) -> Int {
            guard let item = items.first(where: { $0.id == id }) ?? context.growth.original[id] else { return 0 }
            return context.interiorGaps(item, value: font, others: items)
        }

        func holdsSurface(item: NativeTranslationLayoutItem, typography: NativeTranslationTypography.Layout,
                          foreground: CGColor? = nil) -> Bool {
            let candidate = Candidate(item: item, shaped: typography, profile: NativeTypographyPostPolish.profile(typography, originalText: item.text))
            return context.holdsSurface(candidate, expands: true, allowExterior: true,
                foreground: foreground, usesBalloonBudget: true)
        }
    }

    static func rendererGrowthSession(layout: NativeTranslationLayout, restoration: NativeTranslationRestoration.Result,
                                      settings: IPhoneOverlaySettings, sourceImage: CGImage?) -> RendererGrowthSession {
        var patches: [String: NativeTranslationRestoration.Patch] = [:]
        for patch in restoration.patches { if let id = patch.itemID { patches[id] = patch } }
        return RendererGrowthSession(Context(restoration: restoration, settings: settings, layout: layout,
                                              patches: patches, reader: SourceReader(sourceImage)))
    }

    static func holdsSurface(item: NativeTranslationLayoutItem, typography: NativeTranslationTypography.Layout,
                             restoration: NativeTranslationRestoration.Result, settings: IPhoneOverlaySettings,
                             layout: NativeTranslationLayout, foreground: CGColor? = nil) -> Bool {
        rendererGrowthSession(layout: layout, restoration: restoration, settings: settings, sourceImage: nil)
            .holdsSurface(item: item, typography: typography, foreground: foreground)
    }

    static func finalRestorationFit(itemID: String, currentLayout: NativeTranslationLayout,
                                    restoration: NativeTranslationRestoration.Result, settings: IPhoneOverlaySettings,
                                    sourceImage: CGImage?, plateRect: CGRect, obstacles: [CGRect] = [], foreground: CGColor? = nil,
                                    safeFitBudget: inout Int) -> NativeTranslationLayoutItem? {
        guard let item = currentLayout.items.first(where: { $0.id == itemID }), !item.balancedColumn,
              item.rotation == 0, item.wrappingScript == "korean", !item.text.contains(where: \.isNewline),
              item.text.utf16.count <= 180, let patch = restoration.patches.last(where: { $0.itemID == itemID }),
              let safe = patch.layoutSafe, safe.count <= 262_144, patch.surfaceLuminance != nil else { return nil }
        var patches: [String: NativeTranslationRestoration.Patch] = [:]
        for patch in restoration.patches { if let id = patch.itemID { patches[id] = patch } }
        let context = Context(restoration: restoration, settings: settings, layout: currentLayout,
                              patches: patches, reader: SourceReader(sourceImage))
        let original = context.candidate(item), glyph = sourceGlyph(item, frame: context.sourceFrame)
        guard !original.inkFrame.isNull, glyph > 0, item.sourceBounds.count == 4 else { return nil }
        let f = context.sourceFrame, bounds = [item.sourceBounds] + item.auxiliaryInkRects
        let sourceRects = bounds.compactMap { a -> CGRect? in
            guard a.count == 4, a.allSatisfy(\.isFinite) else { return nil }
            return CGRect(x: f.minX + a[0] * f.width, y: f.minY + a[1] * f.height,
                          width: a[2] * f.width, height: a[3] * f.height)
        }
        guard let primary = sourceRects.first else { return nil }
        let others = currentLayout.items.filter { $0.id != itemID }
        let otherInk = others.map { context.candidate($0).inkFrame }.filter { !$0.isNull && $0.width > 0 }
        var painted: [UInt8]?
        if let space = CGColorSpace(name: CGColorSpace.sRGB) {
            var pixels = [UInt8](repeating: 0, count: patch.image.width * patch.image.height * 4)
            let success = pixels.withUnsafeMutableBytes { bytes -> Bool in
                guard let bitmap = CGContext(data: bytes.baseAddress, width: patch.image.width, height: patch.image.height,
                    bitsPerComponent: 8, bytesPerRow: patch.image.width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
                bitmap.draw(patch.image, in: CGRect(x: 0, y: 0, width: patch.image.width, height: patch.image.height))
                return true
            }
            if success { painted = stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] } }
        }
        let shape = item.balloonInterior.flatMap { balloonShape(rect: $0.rect, center: $0.center, spans: $0.spans, frame: f) }
        // Tight interiors only bound plates in the source renderer.
        let useShape = shape.map { $0.area >= primary.width * primary.height * 1.8 } == true
        let allows: ((CGPoint) -> Bool)? = useShape ? { shape!.contains($0) } : nil
        guard let grid = NativeTypographyRestoredSurfaceFit.Grid(safe: safe, width: patch.image.width, height: patch.image.height,
            crop: patch.rect, page: f, sourceRects: sourceRects, sourceCenter: CGPoint(x: primary.midX, y: primary.midY),
            glyph: item.sourceFontSize ?? item.fontSize, obstacles: obstacles + otherInk, paintedAlpha: painted, interiorAllows: allows) else { return nil }
        let ratio = max(1, item.lineHeight / item.fontSize), room = plateRect.union(patch.rect)
        let proposals = NativeTypographyRestoredSurfaceFit.proposals(text: item.text, font: item.fontSize,
            lineHeightRatio: ratio, originalLines: original.profile.lines, sourceWidth: primary.width,
            baseWidth: original.inkFrame.width, glyph: glyph, grid: grid,
            style: { context.style(context.resized(item, size: $0)) }, budget: &safeFitBudget)
        return NativeTypographyRestoredSurfaceFit.verify(proposals, text: item.text,
            style: { context.style(context.resized(item, size: $0)) }, budget: &safeFitBudget) { proposal in
            let height = 2 * min(proposal.center.y - room.minY - 2, room.maxY - proposal.center.y - 2)
            guard height > 0 else { return nil }
            var proposed = context.resized(item, size: proposal.size)
            proposed.x = proposal.center.x - proposal.measure / 2; proposed.y = proposal.center.y - height / 2
            proposed.width = proposal.measure; proposed.height = height
            proposed.paddingLeft = 0; proposed.paddingRight = 0; proposed.paddingTop = 0; proposed.paddingBottom = 0
            proposed.typesettingText = nil; proposed.typesettingQuoteMode = nil; proposed.typesettingPreformattedRows = nil
            let maxLines = min(original.profile.lines + 8, Int(floor(height / (proposal.size * ratio))))
            guard maxLines >= 1 else { return nil }
            let fontStyle = context.style(proposed)
            let advance = NativeTranslationTypography.measuredWidth(text: item.text, style: fontStyle)
                - CGFloat(max(0, item.text.unicodeScalars.count - 1)) * fontStyle.tracking
            guard proposal.measure >= proposal.size * 1.8 || proposal.measure >= advance + 1 else { return nil }
            let result: Candidate
            if let words = context.words(proposed, maxLines: maxLines, strict: false, any: true) { result = words }
            else {
                guard advance <= proposal.measure else { return nil }
                result = context.candidate(proposed)
            }
            guard context.contentFits(result), fontFlowFits(result.profile, original.profile, extraWordBreaks: 1),
                  result.profile.lines <= maxLines, room.contains(result.inkFrame) else { return nil }
            let box = result.inkFrame.insetBy(dx: -1, dy: -0.75)
            guard !(obstacles + otherInk).contains(where: { !$0.isNull && box.intersects($0) }) else { return nil }
            guard context.holdsSurface(result, allowExterior: true, margin: CGSize(width: 1, height: 0.75),
                                       lookupLimit: 65_536, requiresCommittedRestoration: false, foreground: foreground) else { return nil }
            let live = NativeTranslationTypography.captionLineMetrics(layout: result.shaped).map {
                $0.rect.offsetBy(dx: result.item.contentRect.minX, dy: result.item.contentRect.minY)
            }.reduce(CGRect.null) { $0.union($1) }
            guard !live.isNull, abs(live.midX - proposal.center.x) <= 1.5, abs(live.midY - proposal.center.y) <= 1.5 else { return nil }
            let rank = (result.profile.hangulFragments + result.profile.punctuationOnly
                + result.profile.badStarts.count + result.profile.badEnds.count) * 100 + result.profile.breaks.count
            return NativeTypographyRestoredSurfaceFit.Validation(value: result.item, rank: rank)
        }
    }

    static func refining(layout: NativeTranslationLayout, restoration: NativeTranslationRestoration.Result,
                         settings: IPhoneOverlaySettings, sourceImage: CGImage?, growthSession: RendererGrowthSession? = nil, lockedIDs: Set<String> = [],
                         phase: RefinementPhase = .all, harmonyLabels: [String: String] = [:],
                         harmonyScale: ((NativeTranslationLayoutItem, CGFloat, [NativeTranslationLayoutItem]) -> NativeTranslationLayoutItem?)? = nil,
                         harmonyPlateGrowth: ((NativeTranslationLayoutItem, CGFloat, Bool, CGFloat?, [NativeTranslationLayoutItem]) -> NativeTranslationLayoutItem?)? = nil,
                         harmonyAxis: (([NativeTranslationLayoutItem], [SourceBox?], [AlignedGroup]) -> [NativeTranslationLayoutItem])? = nil,
                         harmonyCohort: (([NativeTranslationLayoutItem]) -> [NativeTranslationLayoutItem])? = nil,
                         harmonyStage: ((String, [NativeTranslationLayoutItem]) -> Void)? = nil) throws -> NativeTranslationLayout {
        guard settings.visible else { return layout }
        // Image data is owned by restoration. Page font work consumes its exact
        // masks instead of decoding a second image and inventing new protection.
        var patchByID: [String: NativeTranslationRestoration.Patch] = [:]
        for patch in restoration.patches { if let id = patch.itemID { patchByID[id] = patch } }
        let context = growthSession?.context ?? Context(restoration: restoration, settings: settings, layout: layout, patches: patchByID, reader: SourceReader(sourceImage))
        var items = layout.items
        if phase == .all || phase == .initial {
        if !context.growth.recoveryInitialized {
            let emergency = items.reduce(0) { total, item in
                total + ((item.smallTextReference?.fontSize ?? .infinity) < 8 && item.text.utf16.count <= 512 ? item.text.utf16.count : 0)
            }
            var refinement = 16384, readable = min(2048, max(0, 16384 - emergency))
            for item in items where !item.keptLettering && !item.text.isEmpty {
                guard let reference = item.smallTextReference, reference.fontSize.isFinite,
                      reference.padding.count == 4, reference.padding.allSatisfy(\.isFinite) else { continue }
                let length = item.text.utf16.count, emergency = reference.fontSize < 8
                if length <= 512, length <= refinement, emergency || length <= readable {
                    refinement -= length
                    if !emergency { readable -= length }
                }
            }
            context.growth.recoveryBudget.readable = layout.readableRecoveryRemaining ?? readable
            context.growth.recoveryInitialized = true
        }
        for i in items.indices where !items[i].keptLettering && !items[i].text.isEmpty && !lockedIDs.contains(items[i].id) {
            try Task.checkCancellation()
            if context.growth.collectInitialDiagnostics { context.trace("planner-entry", context.candidate(items[i])) }
            items[i] = context.captionRecovering(items[i])
            if context.growth.collectInitialDiagnostics { context.trace("caption-recovery", context.candidate(items[i])) }
        }
        var characterBudget = 8192
        context.growth.admitted.removeAll()
        // The slanted branch finishes before the frozen renderer registers
        // page typography. Locking its own size must not let that separate
        // lettering raise or lower the upright captions' cohort median.
        for item in items where item.rotation == 0 && item.sourceColorEligible && !item.sourceTextOnly &&
            !item.vertical && item.text.utf16.count <= 180 {
            let cost = item.text.utf16.count * 3
            if cost <= characterBudget { characterBudget -= cost; context.growth.admitted.insert(item.id) }
        }
        context.growth.registered = true
        let entries = items.filter { context.growth.admitted.contains($0.id) && ($0.nearUprightRotation ?? 0) == 0 }.compactMap { item -> FontEntry? in
            guard let source = item.sourceFontSize else { return nil }
            return FontEntry(id: item.id, source: source, font: item.fontSize, script: item.fontScript,
                             vertical: item.vertical, column: item.balancedColumn)
        }
        let kept = items.filter(\.keptLettering).compactMap { item -> FontEntry? in
            guard let source = item.sourceFontSize, source.isFinite, source > 0 else { return nil }
            return FontEntry(id: item.id, source: source, font: min(32, source * 0.9), script: item.fontScript,
                             vertical: item.vertical, column: false, kept: true)
        }
        let targets = fontClusterTargets(entries, kept: kept) { context.restored($0.id) && patchByID[$0.id]?.surfaceLuminance != nil }
        for i in items.indices {
            try Task.checkCancellation()
            if context.growth.admitted.contains(items[i].id), !lockedIDs.contains(items[i].id), let target = targets[items[i].id] { items[i] = context.cohort(items[i], target: target, others: items) }
        }
        for i in items.indices where context.growth.admitted.contains(items[i].id) && !lockedIDs.contains(items[i].id) { items[i] = context.repaired(items[i], others: items) }
        for item in items where context.growth.admitted.contains(item.id) && context.patches[item.id] != nil {
            context.growth.finalized.insert(item.id)
            if context.growth.surfaceInspectable.contains(item.id),
               context.holdsSurface(context.candidate(item), allowExterior: true, requiresCommittedRestoration: false) {
                context.growth.restoredInside.insert(item.id)
            } else { context.growth.restoredInside.remove(item.id) }
        }
        }
        if phase == .initial {
            return NativeTranslationLayout(imageSize: layout.imageSize, sourceRect: layout.sourceRect, viewport: layout.viewport, items: items,
                readableRecoveryRemaining: context.growth.recoveryInitialized ? context.growth.recoveryBudget.readable : layout.readableRecoveryRemaining, sourceObjectFit: layout.sourceObjectFit)
        }
        // Readability recovery is source-sized, capped, and checked against the
        // caption's own safe surface before row/page harmony sees its result.
        if phase == .all || phase == .growth {
        for i in items.indices {
            try Task.checkCancellation()
            if !lockedIDs.contains(items[i].id), let grown = context.growing(items[i], others: items) { items[i] = grown }
        }
        }
        if phase == .growth {
            return NativeTranslationLayout(imageSize: layout.imageSize, sourceRect: layout.sourceRect, viewport: layout.viewport, items: items,
                readableRecoveryRemaining: context.growth.recoveryInitialized ? context.growth.recoveryBudget.readable : layout.readableRecoveryRemaining, sourceObjectFit: layout.sourceObjectFit)
        }
        let boxes: [SourceBox?] = items.map { item in
            guard item.rotation == 0, (item.nearUprightRotation ?? 0) == 0, item.allowsAutomaticFontRecovery,
                  !item.keptLettering, !item.text.isEmpty else { return nil }
            return sourceBox(item, frame: context.sourceFrame, appearance: restoration.appearances[item.id],
                labelOverride: harmonyLabels[item.id])
        }
        let groups = alignedGroups(boxes)
        func captureStage(_ name: String) {
            if context.growth.collectInitialDiagnostics { harmonyStage?(name, items) }
        }
        captureStage("harmony-entry")
        func inconsistency(_ state: [NativeTranslationLayoutItem]) -> Int {
            var count = 0
            for i in state.indices {
                guard let a = boxes[i], a.valid else { continue }
                for j in state.indices where j > i {
                    guard let b = boxes[j], b.valid else { continue }
                    if spread([a.glyph, b.glyph]) > 1.15 && spread([a.w, b.w]) > 1.15 && spread([a.h, b.h]) > 1.15 { continue }
                    if spread([state[i].fontSize, state[j].fontSize]) > 1.25 { count += 1 }
                }
            }
            return count
        }
        func trying(_ item: NativeTranslationLayoutItem, _ size: CGFloat,
                    _ state: [NativeTranslationLayoutItem]) -> NativeTranslationLayoutItem? {
            if lockedIDs.contains(item.id) { return item }
            if abs(size - item.fontSize) < 0.01 { return item }
            if let scaled = (harmonyScale != nil ? harmonyScale!(item, size, state) : context.scaled(item, size: size, others: state)) { return scaled }
            if size >= item.fontSize, let plate = harmonyPlateGrowth?(item, size, false, nil, state),
               plate.fontSize >= size * 0.97, plate.fontSize <= size + 0.01 { return plate }
            guard size >= item.fontSize, let grown = context.growing(item, cap: size, others: state),
                  grown.fontSize >= size * 0.97, grown.fontSize <= size + 0.01 else { return nil }
            return grown
        }
        for group in groups {
            try Task.checkCancellation()
            let initial = spread(group.members.map { items[$0].fontSize })
            guard initial > 1.1 else { continue }
            let saved = items, before = inconsistency(items)
            let largest = group.members.map { items[$0].fontSize }.max() ?? 0
            var holds: [Int: CGFloat] = [:], floors: [Int: CGFloat] = [:]
            for i in group.members {
                let font = items[i].fontSize
                floors[i] = min(font, ceil(max(BrowserOverlayLayoutPlanner.minimumRenderedFontSize,
                                               min(font, 8.5), font * 0.75) * 4) / 4)
                var hold = font
                if font < largest - 0.01 {
                    for step: CGFloat in [1, 0.75, 0.5, 0.25] {
                        let size = quarterFloor(font + (largest - font) * step)
                        if size <= font { break }
                        if trying(items[i], size, items) != nil { hold = size; break }
                    }
                }
                holds[i] = hold
            }
            func textLength(_ i: Int) -> Int { items[i].text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count }
            for i in group.members {
                let font = items[i].fontSize
                let peers = group.members.filter { $0 != i && textLength($0) * 2 >= textLength(i) }
                let close = Set(group.links.filter {
                    ($0.a == i || $0.b == i) && $0.gap <= 1.5 * max(boxes[$0.a]?.glyph ?? 0, boxes[$0.b]?.glyph ?? 0)
                }.map { $0.a == i ? $0.b : $0.a })
                let near = peers.filter { close.contains($0) }.compactMap { holds[$0] }
                let far = peers.filter { !close.contains($0) }.compactMap { holds[$0] }
                let drag = min(font, near.min() ?? font, far.isEmpty ? font : max(font * 0.85, far.min() ?? font))
                floors[i] = max(floors[i] ?? font, ceil(drag * 4) / 4)
            }
            func sizeAt(_ i: Int, _ common: CGFloat) -> CGFloat { min(holds[i] ?? items[i].fontSize, max(floors[i] ?? items[i].fontSize, common)) }
            func choose() -> (CGFloat, CGFloat)? {
                var best: (common: CGFloat, score: CGFloat, total: CGFloat)?
                var seen = Set<CGFloat>()
                let candidates = group.members.compactMap { holds[$0] } + group.members.compactMap { floors[$0] }
                    + group.members.map { items[$0].fontSize }
                for common in candidates where seen.insert(common).inserted {
                    let sizes = group.members.map { sizeAt($0, common) }, score = spread(sizes), total = sizes.reduce(0, +)
                    if best == nil || score < best!.score - 0.01 || (score <= best!.score + 0.01 && total > best!.total) {
                        best = (common, score, total)
                    }
                }
                return best.map { ($0.common, $0.score) }
            }
            var best = choose()
            if let selected = best, selected.1 > 1.15 {
                for i in group.members { floors[i] = items[i].fontSize }
                best = choose()
            }
            guard let selected = best, selected.1 <= initial - 0.03 else { continue }
            for i in group.members {
                if let changed = trying(items[i], sizeAt(i, selected.0), items) { items[i] = changed }
            }
            if spread(group.members.map { items[$0].fontSize }) > initial - 0.03 || inconsistency(items) > before { items = saved }
        }
        captureStage("after-row-size")
        // Page styles use orientation, source fill/outline/ground and label class.
        let styleIndices = items.indices.filter { i in
            guard let box = boxes[i] else { return false }
            let count = items[i].text.unicodeScalars.filter { $0.properties.isAlphabetic || $0.properties.numericType != nil }.count
            return box.glyph < 40 && items[i].wrappingScript == "korean" && count >= 3
        }
        let styles = styleIndices.map { i -> StyleRecord in
            let appearance = restoration.appearances[items[i].id]
            let key = [boxes[i]?.vertical == true ? "v" : "h", styleColorClass(appearance?.foreground),
                       appearance?.stroke != nil && (appearance?.strokeWidth ?? 0) > 0 ? "outline" : "",
                       styleColorClass(appearance?.background), boxes[i]?.style.isEmpty == false ? "label" : ""].joined(separator: "|")
            return StyleRecord(key: key, glyph: boxes[i]?.glyph ?? 0, font: items[i].fontSize)
        }
        func clearance(_ i: Int, _ state: [NativeTranslationLayoutItem]) -> CGFloat {
            let own = context.candidate(state[i]).inkFrame
            return state.indices.filter { $0 != i && !state[$0].keptLettering }.map { index in
                let other = context.candidate(state[index]).inkFrame
                return max(other.minX - own.maxX, own.minX - other.maxX, other.minY - own.maxY, own.minY - other.maxY)
            }.min() ?? .infinity
        }
        for group in pageStyleGroups(styles, tolerance: 1.25) {
            let members = group.members.map { styleIndices[$0] }, target = group.font
            var pending = Set(members.filter { !lockedIDs.contains(items[$0].id) && context.peerFont(items[$0], beforeInterior: true) * 1.15 < target })
            let styleGlyph = members.filter { items[$0].fontSize >= target - 0.01 }.compactMap { boxes[$0]?.glyph }.max() ?? 0
            func pairs(_ state: [NativeTranslationLayoutItem]) -> Int {
                var count = 0
                for i in members {
                    for j in members where j > i {
                        if spread([state[i].fontSize, state[j].fontSize]) > 1.25 { count += 1 }
                    }
                }
                return count
            }
            let ordered = pending.sorted { a, b in
                items[a].fontSize != items[b].fontSize ? items[a].fontSize < items[b].fontSize
                    : (boxes[a]?.glyph ?? 0) < (boxes[b]?.glyph ?? 0)
            }
            for i in ordered {
                try Task.checkCancellation()
                pending.remove(i)
                let current = items[i].fontSize, font = context.peerFont(items[i], beforeInterior: true)
                guard let a = boxes[i] else { continue }
                let near = items.indices.filter { j in
                    guard j != i, !pending.contains(j), let b = boxes[j], max(a.glyph, b.glyph) / min(a.glyph, b.glyph) <= 1.35 else { return false }
                    return max(a.x - b.x - b.w, b.x - a.x - a.w, a.y - b.y - b.h, b.y - a.y - a.h) <= 3 * max(a.glyph, b.glyph)
                }.map { items[$0].fontSize }
                let cap = quarterFloor(min(target, near.min() ?? .infinity))
                guard cap >= font * 1.08 else { continue }
                let saved = items, priorPairs = pairs(items), priorInconsistency = inconsistency(items), priorClearance = clearance(i, items)
                let rowBaselines = groups.filter { $0.members.contains(i) }.map { ($0, spread($0.members.map { items[$0].fontSize })) }
                var changed: NativeTranslationLayoutItem?
                for step: CGFloat in [1, 0.75, 0.5, 0.25] {
                    let size = quarterFloor(font + (cap - font) * step)
                    if size < font * 1.08 || size <= current { break }
                    if let scaled = (harmonyScale != nil ? harmonyScale!(items[i], size, items) : context.scaled(items[i], size: size, others: items)) { changed = scaled; break }
                }
                if changed == nil { changed = harmonyPlateGrowth?(items[i], cap, true, styleGlyph, items) }
                if changed == nil { changed = context.growing(items[i], cap: cap, extraBreaks: 0, styleGlyph: styleGlyph, others: items) }
                guard let changed, changed.fontSize >= font * 1.08,
                      !(changed.fontSize <= current && current > font) else { continue }
                items[i] = changed
                if pairs(items) > priorPairs || inconsistency(items) > priorInconsistency ||
                    rowBaselines.contains(where: { spread($0.0.members.map { items[$0].fontSize }) > max($0.1, 1.15) }) ||
                    clearance(i, items) < min(priorClearance, max(2, items[i].fontSize * 0.2)) { items = saved }
            }
        }
        captureStage("after-page-style")
        // Interface rows retain their source scale before the late word-bound pass.
        let interface = interfaceRows(boxes, texts: items.map(\.text),
                                      frame: [context.sourceFrame.minX, context.sourceFrame.minY, context.sourceFrame.width, context.sourceFrame.height])
        var interfaceMembers = Set<Int>()
        for row in interface {
            let glyphs = row.compactMap { boxes[$0]?.glyph }.sorted()
            guard !glyphs.isEmpty else { continue }
            let glyph = glyphs[(glyphs.count - 1) / 2]
            for i in row where !lockedIDs.contains(items[i].id) {
                let cap = max(8.5, BrowserOverlayLayoutPlanner.minimumRenderedFontSize,
                              quarterFloor(max(glyph, boxes[i]?.glyph ?? 0) * 1.15))
                if items[i].fontSize > cap + 0.01, let scaled = context.scaled(items[i], size: cap, others: items) {
                    items[i] = scaled; interfaceMembers.insert(i)
                }
            }
            let readable = row.map { items[$0].fontSize }.filter { $0 >= 8.5 - 0.01 }.sorted()
            guard let target = readable.first else { continue }
            let saved = items, before = inconsistency(items)
            var grown: [Int] = []
            for i in row where items[i].fontSize < target * 0.97 {
                if let changed = trying(items[i], target, items) { items[i] = changed; grown.append(i) }
            }
            if !grown.isEmpty, inconsistency(items) > before { items = saved }
            else { interfaceMembers.formUnion(grown) }
        }
        captureStage("after-interface")
        if let harmonyAxis { items = harmonyAxis(items, boxes, groups) }
        captureStage("after-axis")
        // A longest eojeol may use the frozen 90% width transform once. Native
        // shaping measures the uncompressed line; the painter and glyph proof
        // both apply the same transform. No smaller horizontal scale is admitted.
        var typical: [Int: CGFloat] = [:]
        let currentStyles = styleIndices.enumerated().map { index, i in
            StyleRecord(key: styles[index].key, glyph: styles[index].glyph, font: items[i].fontSize)
        }
        for group in pageStyleGroups(currentStyles, tolerance: 1.25) {
            for index in group.members { typical[styleIndices[index]] = group.font }
        }
        for i in items.indices where !interfaceMembers.contains(i) && !lockedIDs.contains(items[i].id) {
            try Task.checkCancellation()
            guard let a = boxes[i] else { continue }
            let near = items.indices.filter { j in
                guard j != i, let b = boxes[j], max(a.glyph, b.glyph) / min(a.glyph, b.glyph) <= 1.35 else { return false }
                return max(a.x - b.x - b.w, b.x - a.x - a.w, a.y - b.y - b.h, b.y - a.y - a.h) <= 3 * max(a.glyph, b.glyph)
            }.map { context.peerFont(items[$0]) }
            let peers = Set(groups.filter { $0.members.contains(i) }.flatMap(\.members)).filter { $0 != i }.map { context.peerFont(items[$0]) }
            let cap = quarterFloor(min(typical[i] ?? .infinity, near.min() ?? .infinity, peers.min() ?? .infinity))
            guard cap >= items[i].fontSize * 1.06 else { continue }
            let saved = items, before = inconsistency(items), priorClearance = clearance(i, items)
            guard let changed = context.condensed(items[i], cap: cap, others: items) else { continue }
            items[i] = changed
            if inconsistency(items) > before || clearance(i, items) < min(priorClearance, max(2, items[i].fontSize * 0.2)) { items = saved }
        }
        captureStage("after-condensed")
        // Source columns sharing one row retain their original top/centre/bottom
        // edge. Only the cross-reading axis is adjusted, preserving reading order.
        for link in (harmonyAxis == nil ? columnRowLinks(boxes) : []) {
            try Task.checkCancellation()
            guard let edge = link.edge, !items[link.a].vertical, !items[link.b].vertical else { continue }
            let a = context.candidate(items[link.a]), b = context.candidate(items[link.b])
            let anchor = (a.inkFrame.minY + edge * a.inkFrame.height + b.inkFrame.minY + edge * b.inkFrame.height) / 2
            let saved = items
            var okay = true
            for i in [link.a, link.b] where !lockedIDs.contains(items[i].id) {
                let old = context.candidate(items[i])
                items[i].y += anchor - (old.inkFrame.minY + edge * old.inkFrame.height)
                let next = context.candidate(items[i])
                if !next.shaped.fits || !context.clear(next, others: items, prior: old) || !context.holdsSurface(next, expands: true) { okay = false; break }
            }
            if !okay { items = saved }
        }
        if let harmonyCohort { items = harmonyCohort(items) }
        captureStage("after-cohort")
        return NativeTranslationLayout(imageSize: layout.imageSize, sourceRect: layout.sourceRect, viewport: layout.viewport, items: items,
                readableRecoveryRemaining: context.growth.recoveryInitialized ? context.growth.recoveryBudget.readable : layout.readableRecoveryRemaining, sourceObjectFit: layout.sourceObjectFit)
    }
}
