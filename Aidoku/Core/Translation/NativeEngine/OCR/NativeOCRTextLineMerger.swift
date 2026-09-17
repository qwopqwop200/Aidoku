// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import CoreGraphics
import Foundation

/// Pure-Swift implementation of the conservative OCR fragment and translation-
/// region merger. Keeping this beside the Core ML pipeline makes the complete
/// capture -> OCR -> merge path native and removes the former JavaScriptCore
/// runtime from the application bundle.
@available(iOS 18.0, *)
enum NativeOCRTextLineMerger {
    private enum Orientation: Int {
        case vertical = 0
        case horizontal = 1

        init(_ source: BrowserOCRSourceOrientation, box: CGRect) {
            switch source {
            case .horizontal:
                self = .horizontal
            case .vertical:
                self = .vertical
            case .unknown:
                self = box.height >= box.width * 1.25
                    ? .vertical
                    : .horizontal
            }
        }

        var source: BrowserOCRSourceOrientation {
            switch self {
            case .horizontal: .horizontal
            case .vertical: .vertical
            }
        }
    }

    private struct Line {
        let index: Int
        var text: String
        let confidence: Double
        let box: CGRect
        let polygon: [CGPoint]
        let orientationHint: BrowserOCRSourceOrientation
        var orientation: Orientation
        var singleVerticalColumn: Bool
        var clippedByTile = false
        var sourceTileBounds: CGRect? = nil
    }

    private struct Geometry {
        let index: Int
        let line: Line
        let centerX: CGFloat
        let centerY: CGFloat
        let supportsHorizontal: Bool
        let supportsVertical: Bool
    }

    private struct Candidate {
        let left: Int
        let right: Int
        let normalizedGap: CGFloat
        let orientation: Orientation
    }

    private struct RegionGeometry {
        let index: Int
        let line: Line
        let centerX: CGFloat
        let centerY: CGFloat
        let fontSize: CGFloat

        var box: CGRect { line.box }
        var orientation: Orientation { line.orientation }
    }

    private struct IndexPair: Hashable {
        let lower: Int
        let upper: Int
        init(_ left: Int, _ right: Int) { lower = min(left, right); upper = max(left, right) }
    }

    private struct SpacingLink {
        let first: Int
        let second: Int
        let normalizedGap: CGFloat
    }

    private struct WeightedRegionEdge {
        let left: Int
        let right: Int
        let weight: CGFloat
    }

    private static let maximumLinesPerRegion = 64
    private static let fontSizeRatio: CGFloat = 1.6
    private static let regionGapInFontSizes: CGFloat = 0.4
    private static let regionAlignmentInFontSizes: CGFloat = 0.85
    private static let regionCrossAxisOverlapRatio: CGFloat = 0.45
    private static let regionComponentAlignmentInFontSizes: CGFloat = 1.25
    private static let regionComponentCrossAxisOverlapRatio: CGFloat = 0.3
    private static let regionComponentFillRatio: CGFloat = 0.5
    private static let maximumNewLinePrimaryOverlapRatio: CGFloat = 0.5
    private static let minimumDuplicateAreaRatio: CGFloat = 0.9
    private static let minimumDuplicateOverlapRatio: CGFloat = 0.95
    private static let mangaVerticalFontSizeRatio: CGFloat = 2.1
    private static let mangaVerticalSameColumnOverlapRatio: CGFloat = 0.45
    private static let mangaVerticalAdjacentColumnOverlapRatio: CGFloat = 0.75
    private static let mangaVerticalColumnGapInFontSizes: CGFloat = 0.6

    /// A small, geometry-filtered vocabulary for an optional external spell
    /// checker. No dictionary lookup or UI work happens inside the merger.
    static func latinWordCandidates(_ nativeLines: [NativeCoreMLOCRLine]) -> Set<String> {
        let lines = deduplicateLines(
            nativeLines.enumerated().compactMap { makeLine($0.element, index: $0.offset) }
                .filter { isLowercaseLatinFragment($0.text) && $0.orientation != .vertical }
        )
        let spatialIndex = NativeOCRSpatialIndex(boxes: lines.map(\.box))
        var words: Set<String> = []
        for left in lines {
            for index in spatialIndex.indices(intersecting: searchBounds(left)).sorted() {
                let right = lines[index]
                guard left.index != right.index else { continue }
                guard isTightlySplitLatinWord(left, right, orientation: .horizontal),
                      overlapRatio(left.box.minY, left.box.maxY, right.box.minY, right.box.maxY) >= 0.8
                else { continue }
                let proposed = words.union([left.text, right.text, left.text + right.text])
                guard proposed.count <= 256 else { return words }
                words = proposed
            }
        }
        return words
    }

    static func merge(
        _ nativeLines: [NativeCoreMLOCRLine],
        imageWidth: Int,
        imageHeight: Int,
        recognizedLatinWords: Set<String> = [],
        separationCheck: ((CGRect, CGRect, BrowserOCRSourceOrientation) -> Bool)? = nil
    ) -> [PaddleOCRLine] {
        guard imageWidth > 0, imageHeight > 0 else {
            return fallback(nativeLines)
        }
        var lines: [Line] = []
        var retained: [(index: Int, line: PaddleOCRLine)] = []
        for (index, native) in nativeLines.enumerated() {
            if var line = makeLine(native, index: index) {
                if let tile = native.sourceTileBounds {
                    // Only interior tile edges can produce a duplicate partial
                    // read. A page's actual edge provides no such evidence.
                    line.clippedByTile = (tile.minY > 0 && line.box.minY <= tile.minY + 1)
                        || (tile.maxY < CGFloat(imageHeight) && line.box.maxY >= tile.maxY - 1)
                        || (tile.minX > 0 && line.box.minX <= tile.minX + 1)
                        || (tile.maxX < CGFloat(imageWidth) && line.box.maxX >= tile.maxX - 1)
                }
                lines.append(line)
            } else {
                retained.append((index, fallback([native])[0]))
            }
        }
        let filtered = inheritHorizontalInlineGlyphs(suppressSeparateHorizontalRuby(suppressSeparateVerticalRuby(suppressSlantedVerticalRuby(lines))))
        let semanticRuby = semanticRubyAnnotations(in: lines, retained: filtered)
        let merged = mergeConservativeTextLines(
            filtered,
            imageWidth: CGFloat(imageWidth),
            imageHeight: CGFloat(imageHeight),
            recognizedLatinWords: recognizedLatinWords, separationCheck: separationCheck
        ).map { line in
            (index: line.index, line: PaddleOCRLine(
                poly: line.polygon.map {
                    PaddleOCRPoint(x: $0.x, y: $0.y)
                },
                text: applyingSemanticRuby(semanticRuby, to: line),
                score: line.confidence,
                orientationRaw: line.orientation.source.rawValue,
                singleVerticalColumn: line.singleVerticalColumn
            ))
        }
        return (merged + retained).sorted { $0.index < $1.index }.map(\.line)
    }

    private struct SemanticRuby {
        let parent: Line
        let annotatedText: String
    }

    /// Pronouns over unrelated Han text can supply the intended referent (e.g.
    /// 世界《わたし》). Preserve that evidence without making another OCR region.
    /// Ordinary readings of 私/俺/僕/君 and homophones such as 気味 remain suppressed.
    /// Geometry and grouping use the original body text; annotations are applied last.
    private static func semanticRubyAnnotations(in lines: [Line], retained: [Line]) -> [SemanticRuby] {
        let spellings: [String: [String]] = [
            "わたし": ["私"], "おれ": ["俺"], "ぼく": ["僕"],
            "あなた": ["貴方", "貴女", "彼方"], "きみ": ["君", "気味"]
        ]
        let kept = Set(retained.map(\.index))
        let readings = lines.filter { !kept.contains($0.index) && spellings[$0.text] != nil }
        guard !readings.isEmpty else { return [] }
        let spatial = NativeOCRSpatialIndex(boxes: lines.map(\.box))
        var result: [SemanticRuby] = []
        for reading in readings.prefix(8) {
            let candidates = spatial.indices(intersecting: reading.box.insetBy(
                dx: -reading.box.width, dy: -reading.box.height)).compactMap { index -> Line? in
                let parent = lines[index]
                guard parent.index != reading.index, kept.contains(parent.index) else { return nil }
                let pair = [parent, reading]
                let keptPair = suppressSeparateHorizontalRuby(suppressSeparateVerticalRuby(pair))
                return keptPair.contains(where: { $0.index == reading.index }) ? nil : parent
            }
            guard candidates.count == 1, let parent = candidates.first else { continue }
            let chars = Array(parent.text)
            let vertical = parent.orientation == .vertical
            let length = vertical ? parent.box.height : parent.box.width
            let position = ((vertical ? reading.box.midY : reading.box.midX) -
                (vertical ? parent.box.minY : parent.box.minX)) / length * CGFloat(chars.count)
            func isHan(_ char: Character) -> Bool {
                char.unicodeScalars.contains { (0x3400...0x4DBF).contains($0.value) ||
                    (0x4E00...0x9FFF).contains($0.value) || $0.value == 0x3005 }
            }
            guard !chars.isEmpty, position.isFinite else { continue }
            let center = min(chars.count - 1, max(0, Int(position)))
            guard isHan(chars[center]) else { continue }
            var start = center, end = center + 1
            while start > 0 && isHan(chars[start - 1]) { start -= 1 }
            while end < chars.count && isHan(chars[end]) { end += 1 }
            let body = String(chars[start..<end])
            guard !spellings[reading.text, default: []].contains(where: { body.contains($0) }),
                  !result.contains(where: { $0.parent.index == parent.index }) else { continue }
            result.append(SemanticRuby(parent: parent, annotatedText:
                String(chars[..<end]) + "《" + reading.text + "》" + String(chars[end...])))
        }
        return result
    }

    private static func applyingSemanticRuby(_ annotations: [SemanticRuby], to line: Line) -> String {
        var text = line.text
        for annotation in annotations where line.box.contains(annotation.parent.box) {
            guard let range = text.range(of: annotation.parent.text),
                  text.range(of: annotation.parent.text, range: range.upperBound..<text.endIndex) == nil else { continue }
            text.replaceSubrange(range, with: annotation.annotatedText)
        }
        return text
    }

    private static func fallback(
        _ lines: [NativeCoreMLOCRLine]
    ) -> [PaddleOCRLine] {
        lines.map { line in
            PaddleOCRLine(
                poly: line.polygon.map {
                    PaddleOCRPoint(x: $0.x, y: $0.y)
                },
                text: line.text,
                score: line.score.isFinite ? min(max(line.score, 0), 1) : 0,
                orientationRaw: line.orientation.rawValue,
                singleVerticalColumn: line.orientation == .vertical
            )
        }
    }

    private static func makeLine(
        _ native: NativeCoreMLOCRLine,
        index: Int
    ) -> Line? {
        guard native.polygon.count >= 2,
              native.polygon.count <= 16,
              native.text.count <= 16_384,
              native.score.isFinite,
              native.score >= 0,
              native.score <= 1,
              native.polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite })
        else {
            return nil
        }
        let box = boundingBox(native.polygon)
        guard !box.isNull, box.width > 0, box.height > 0,
              box.width.isFinite, box.height.isFinite, boxArea(box).isFinite
        else { return nil }
        let orientation = Orientation(native.orientation, box: box)
        return Line(
            index: index,
            text: native.text,
            confidence: min(max(native.score, 0), 1),
            box: box,
            polygon: native.polygon,
            orientationHint: native.orientationIsEstimated ? .unknown : native.orientation,
            orientation: orientation,
            singleVerticalColumn: orientation == .vertical,
            sourceTileBounds: native.sourceTileBounds
        )
    }

    /// Compare tilted readings in the parent's own coordinate frame. Rotating
    /// only the geometry avoids inflated bounding boxes masquerading as large
    /// type. Full-size kana, different slopes, and semantic katakana readings
    /// retain the existing conservative behavior.
    private static func suppressSlantedVerticalRuby(_ lines: [Line]) -> [Line] {
        func angle(_ line: Line) -> CGFloat? {
            guard line.orientation == .vertical, line.polygon.count == 4 else { return nil }
            let p = line.polygon
            let dx = (p[2].x + p[3].x - p[0].x - p[1].x) / 2
            let dy = (p[2].y + p[3].y - p[0].y - p[1].y) / 2
            guard dy > 0 else { return nil }
            return atan2(dx, dy)
        }
        let parents = lines.filter { line in
            guard let tilt = angle(line), abs(tilt) >= 0.04, abs(tilt) <= 0.35 else { return false }
            return line.text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        }
        guard !parents.isEmpty else { return lines }
        let spatial = NativeOCRSpatialIndex(boxes: lines.map(\.box))
        var removed = Set<Int>()
        for parent in parents {
            let tilt = angle(parent)!
            func aligned(_ line: Line) -> Line {
                let copy = line
                let points = line.polygon.map { p in
                    CGPoint(x: p.x * cos(tilt) - p.y * sin(tilt),
                            y: p.x * sin(tilt) + p.y * cos(tilt))
                }
                // Line geometry is immutable; all text/identity stays original.
                return Line(index: copy.index, text: copy.text, confidence: copy.confidence,
                    box: boundingBox(points), polygon: points, orientationHint: copy.orientationHint,
                    orientation: copy.orientation, singleVerticalColumn: copy.singleVerticalColumn)
            }
            let body = aligned(parent)
            for index in spatial.indices(intersecting: parent.box.insetBy(dx: -body.box.width, dy: 0)) {
                let reading = lines[index]
                guard reading.index != parent.index, let slope = angle(reading),
                      abs(slope - tilt) <= 0.08, (2...12).contains(reading.text.count),
                      reading.text.unicodeScalars.allSatisfy({ (0x3041...0x3096).contains($0.value) || $0.value == 0x30FC })
                else { continue }
                if !suppressSeparateVerticalRuby([body, aligned(reading)]).contains(where: { $0.index == reading.index }) {
                    removed.insert(reading.index)
                }
            }
        }
        return lines.filter { !removed.contains($0.index) }
    }

    // Separate ruby can interrupt adjacency before columns are assembled. Require
    // both a kana reading and a smaller, vertically contained box touching the
    // right edge of a Han-bearing column; small dialogue alone is not evidence.
    private static func suppressSeparateVerticalRuby(_ lines: [Line]) -> [Line] {
        func hasUprightColumnBounds(_ line: Line) -> Bool {
            guard line.polygon.count == 4 else { return false }
            let topWidth = abs(line.polygon[1].x - line.polygon[0].x)
            let bottomWidth = abs(line.polygon[2].x - line.polygon[3].x)
            // Slanted columns have inflated axis-aligned widths. They cannot
            // establish that an adjacent kana column uses a smaller font.
            return min(topWidth, bottomWidth) >= line.box.width * 0.8
        }
        let parentIndices = lines.indices.filter { index in
            hasUprightColumnBounds(lines[index]) && lines[index].orientation == .vertical && lines[index].orientationHint != .horizontal
                && lines[index].text.unicodeScalars.contains {
                (0x3400...0x4DBF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value)
            }
        }
        guard !parentIndices.isEmpty else { return lines }
        let spatial = NativeOCRSpatialIndex(boxes: parentIndices.map { lines[$0].box })
        return lines.filter { reading in
            let characters = reading.text.unicodeScalars
            let singleton = characters.count == 1 && reading.orientationHint == .unknown
            guard (reading.orientation == .vertical || singleton), reading.orientationHint != .horizontal,
                  (1...12).contains(characters.count),
                  characters.allSatisfy({ (0x3041...0x3096).contains($0.value) || $0.value == 0x30FC })
            else { return true }
            let ruby = reading.box
            // Accepted boxes touch the parent edge. A small expansion only
            // accommodates detector rounding without searching unrelated rows.
            let nearby = spatial.indices(intersecting: ruby.insetBy(dx: -ruby.width, dy: 0))
            return !nearby.contains { candidate in
                let parent = lines[parentIndices[candidate]]
                let body = parent.box
                let bodyAdvance = body.height / CGFloat(max(parent.text.count, 1))
                let font = min(body.width, bodyAdvance)
                let advance = ruby.height / CGFloat(characters.count)
                // A slightly tilted reading has an inflated axis-aligned width.
                // The polygon's two cross edges measure its actual thickness.
                let thickness = rubyCrossThickness(reading, vertical: true)
                let smallReading = advance <= font * 0.85
                    // Recognition can omit a kana (e.g. ひびの -> ひび).
                    // Accept that shorter transcript only with independent
                    // evidence that its strokes occupy a narrower column.
                    || (thickness <= font * 0.7 && advance <= font)
                if characters.count == 1 {
                    guard singleton, thickness <= font * 0.65, advance <= font * 0.9,
                          rubyAlignsWithHan(reading, parent: parent, vertical: true)
                    else { return false }
                }
                let overlap = min(ruby.maxY, body.maxY) - max(ruby.minY, body.minY)
                return thickness <= body.width * 0.75
                    && ruby.height <= body.height * 1.05
                    // A detector may include attached ruby in the parent's
                    // width. Its text advance independently protects adjacent
                    // full-size dialogue from that inflated width.
                    && smallReading
                    && overlap >= ruby.height * 0.85
                    && ruby.minY >= body.minY - body.width * 0.25
                    && ruby.maxY <= body.maxY + body.width * 0.25
                    && ruby.midX >= body.minX + body.width * 0.7
                    && ruby.midX <= body.maxX + body.width * 0.35
                    && ruby.minX <= body.maxX + body.width * 0.1
                    && ruby.maxX >= body.maxX - body.width * 0.2
            }
        }
    }

    /// Horizontal furigana sits just above a Han-bearing baseline. Require
    /// smaller glyphs on both axes; a short independent caption is not ruby.
    private static func suppressSeparateHorizontalRuby(_ lines: [Line]) -> [Line] {
        let parents = lines.indices.filter { index in
            let line = lines[index]
            guard line.orientation == .horizontal, line.orientationHint != .vertical,
                  line.polygon.count == 4 else { return false }
            let leftHeight = abs(line.polygon[3].y - line.polygon[0].y)
            let rightHeight = abs(line.polygon[2].y - line.polygon[1].y)
            return min(leftHeight, rightHeight) >= line.box.height * 0.8
                && line.text.unicodeScalars.contains {
                    (0x3400...0x4DBF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value)
                }
        }
        guard !parents.isEmpty else { return lines }
        let spatial = NativeOCRSpatialIndex(boxes: parents.map { lines[$0].box })
        let allSpatial = NativeOCRSpatialIndex(boxes: lines.map(\.box))
        return lines.filter { reading in
            let characters = reading.text.unicodeScalars
            let singleton = characters.count == 1 && reading.orientationHint == .unknown
            guard (reading.orientation == .horizontal || singleton), reading.orientationHint != .vertical,
                  (1...24).contains(characters.count),
                  characters.allSatisfy({ (0x3041...0x3096).contains($0.value) || $0.value == 0x30FC })
            else { return true }
            let ruby = reading.box
            // A suffix underneath the preceding line (e.g. a sign's "20から")
            // can also sit above Han text. Preserve it when that attachment is
            // geometrically plausible rather than deciding by kana alone.
            let preceding = CGRect(x: ruby.minX, y: ruby.minY - ruby.height,
                                   width: ruby.width, height: ruby.height)
            let attachesAbove = allSpatial.indices(intersecting: preceding).contains { index in
                let other = lines[index]
                guard other.index != reading.index, other.orientation == .horizontal else { return false }
                let box = other.box
                let overlap = min(ruby.maxX, box.maxX) - max(ruby.minX, box.minX)
                let gap = ruby.minY - box.maxY
                return box.height >= ruby.height * 1.25 && overlap >= ruby.width * 0.8
                    && abs(box.maxX - ruby.maxX) <= ruby.height * 0.5
                    && gap >= -ruby.height * 0.1 && gap <= ruby.height * 0.35
            }
            guard !attachesAbove else { return true }
            return !spatial.indices(intersecting: ruby.insetBy(dx: 0, dy: -ruby.height)).contains { candidate in
                let parent = lines[parents[candidate]]
                let body = parent.box
                let advance = ruby.width / CGFloat(characters.count)
                let bodyAdvance = body.width / CGFloat(max(parent.text.count, 1))
                if characters.count == 1 {
                    guard singleton, rubyAlignsWithHan(reading, parent: parent, vertical: false)
                    else { return false }
                }
                let overlap = min(ruby.maxX, body.maxX) - max(ruby.minX, body.minX)
                return ruby.height <= body.height * 0.6
                    && advance <= body.height * 0.65 && advance <= bodyAdvance * 0.65
                    && ruby.width <= body.width * 1.05 && overlap >= ruby.width * 0.9
                    && ruby.minX >= body.minX - body.height * 0.2
                    && ruby.maxX <= body.maxX + body.height * 0.2
                    && ruby.midY <= body.minY + body.height * 0.2
                    && ruby.midY >= body.minY - body.height * 0.35
                    && ruby.maxY >= body.minY - body.height * 0.1
                    && ruby.minY <= body.minY + body.height * 0.1
            }
        }
    }

    private static func rubyCrossThickness(_ line: Line, vertical: Bool) -> CGFloat {
        let fallback = vertical ? line.box.width : line.box.height
        guard line.polygon.count == 4 else { return fallback }
        let p = line.polygon
        let first = vertical ? abs(p[1].x - p[0].x) : abs(p[3].y - p[0].y)
        let second = vertical ? abs(p[2].x - p[3].x) : abs(p[2].y - p[1].y)
        // Degenerate or tapered polygons cannot establish a smaller font.
        guard min(first, second) > 0, min(first, second) >= max(first, second) * 0.8 else { return fallback }
        return max(first, second)
    }

    /// Single kana are also ordinary reactions. Require a small detector-
    /// estimated glyph beside a Han cell, rather than merely anywhere beside
    /// a column containing at least one Han character.
    private static func rubyAlignsWithHan(_ reading: Line, parent: Line, vertical: Bool) -> Bool {
        let characters = Array(parent.text)
        let start = vertical ? parent.box.minY : parent.box.minX
        let length = vertical ? parent.box.height : parent.box.width
        let center = vertical ? reading.box.midY : reading.box.midX
        let position = (center - start) / length * CGFloat(characters.count)
        return characters.enumerated().contains { index, character in
            character.unicodeScalars.contains {
                (0x3400...0x4DBF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value)
            } && position >= CGFloat(index) - 0.15 && position <= CGFloat(index + 1) + 0.15
        }
    }

    private static func mergeConservativeTextLines(
        _ lines: [Line],
        imageWidth: CGFloat,
        imageHeight: CGFloat,
        recognizedLatinWords: Set<String>,
        deskew: Bool = true,
        separationCheck: ((CGRect, CGRect, BrowserOCRSourceOrientation) -> Bool)? = nil
    ) -> [Line] {
        if deskew, let result = mergeSlantedHorizontalLines(
            lines, imageWidth: imageWidth, imageHeight: imageHeight,
            recognizedLatinWords: recognizedLatinWords, separationCheck: separationCheck
        ) { return result }
        guard lines.count >= 2 else {
            return lines.map(resolvedSingleLine)
        }
        guard imageWidth.isFinite, imageHeight.isFinite,
              imageWidth > 0, imageHeight > 0
        else {
            return lines.map(resolvedSingleLine)
        }

        let horizontalResolved = inheritHorizontalWrappedTailOrientations(
            deduplicateLines(
                mergeLineFragments(
                    deduplicateLines(lines),
                    imageWidth: imageWidth,
                    imageHeight: imageHeight,
                    recognizedLatinWords: recognizedLatinWords, separationCheck: separationCheck
                )
            )
        )
        let visualLines = inheritVerticalSingletonOrientations(horizontalResolved)
        guard visualLines.count > 1 else { return visualLines }

        let geometries = visualLines.enumerated().map(makeRegionGeometry)
        let spatialIndex = NativeOCRSpatialIndex(boxes: visualLines.map(\.box))
        let connected = DisjointSet(geometries.count)
        let regularPairs = regularSpacingPairs(visualLines, orientation: .horizontal, fragments: false)
            .union(regularSpacingPairs(visualLines, orientation: .vertical, fragments: false))
        let captionGutters = contrastingVerticalGutters(visualLines)
        var admittedPairs: Set<IndexPair> = []
        for left in geometries.indices {
            for right in spatialIndex.indices(intersecting: searchBounds(visualLines[left])) where right > left {
                guard !captionGutters.contains(IndexPair(left, right)),
                      !areIndependentQuotedLanguages(geometries[left], geometries[right]) else { continue }
                if geometries[left].orientation == .vertical, geometries[right].orientation == .vertical,
                   ReaderTranslationBalloonMerger.separatesVerticalUtterances(geometries[left].line.text, box: geometries[left].box,
                       geometries[right].line.text, box: geometries[right].box) { continue }
                if canFormTranslationRegion(
                    geometries[left],
                    geometries[right]
                ) || regularPairs.contains(IndexPair(left, right)) {
                    if separationCheck?(geometries[left].box, geometries[right].box, geometries[left].orientation.source) == true { continue }
                    admittedPairs.insert(IndexPair(left, right))
                    connected.union(left, right)
                }
            }
        }
        let candidates = componentsOf(
            Array(geometries.indices),
            set: connected
        )
        return candidates
            .flatMap { splitSuspiciousRegion($0, geometries: geometries, admittedPairs: admittedPairs) }
            .map {
                mergeTranslationRegion(
                    $0,
                    geometries: geometries,
                    imageWidth: imageWidth,
                    imageHeight: imageHeight
                )
            }
            .sorted { $0.index < $1.index }
    }

    /// A slanted line's axis-aligned height includes its horizontal advance.
    /// Treating that as glyph height can join nonadjacent rows and reorder a
    /// poster. Run the same conservative rules in each local baseline frame;
    /// model pixels, recognition text, and the final page coordinates stay intact.
    private static func mergeSlantedHorizontalLines(
        _ input: [Line], imageWidth: CGFloat, imageHeight: CGFloat,
        recognizedLatinWords: Set<String>,
        separationCheck: ((CGRect, CGRect, BrowserOCRSourceOrientation) -> Bool)?
    ) -> [Line]? {
        func angle(_ line: Line) -> CGFloat? {
            guard line.orientation == .horizontal, line.polygon.count == 4 else { return nil }
            let points = line.polygon
            let top = CGPoint(x: points[1].x - points[0].x, y: points[1].y - points[0].y)
            let bottom = CGPoint(x: points[2].x - points[3].x, y: points[2].y - points[3].y)
            let side = hypot(points[3].x - points[0].x, points[3].y - points[0].y)
            guard top.x > 0, bottom.x > 0, hypot(top.x, top.y) >= side * 1.8 else { return nil }
            let value = atan2(top.y, top.x)
            guard abs(value) >= 0.10, abs(value) <= 0.55,
                  abs(value - atan2(bottom.y, bottom.x)) <= 0.04 else { return nil }
            return value
        }
        guard input.contains(where: { angle($0) != nil }) else { return nil }
        // Duplicate tiles can straddle the angle threshold by a fraction of a
        // pixel. Select their representative before partitioning by baseline.
        let lines = deduplicateLines(input)
        let angles = lines.map(angle)
        let spatialIndex = NativeOCRSpatialIndex(boxes: lines.map(\.box))
        var remaining = Set(lines.indices.filter { angles[$0] != nil })
        var result = mergeConservativeTextLines(
            lines.indices.filter { angles[$0] == nil }.map { lines[$0] },
            imageWidth: imageWidth, imageHeight: imageHeight,
            recognizedLatinWords: recognizedLatinWords, deskew: false, separationCheck: separationCheck
        )
        // Model/tile enumeration is not reading order. A geometric seed keeps
        // grouping stable even when neighbouring lines have slightly different slopes.
        let seeds = remaining.sorted {
            if lines[$0].box.minY != lines[$1].box.minY { return lines[$0].box.minY < lines[$1].box.minY }
            if lines[$0].box.minX != lines[$1].box.minX { return lines[$0].box.minX < lines[$1].box.minX }
            if angles[$0] != angles[$1] { return angles[$0]! < angles[$1]! }
            return $0 < $1
        }
        for seed in seeds where remaining.contains(seed) {
            let baseline = angles[seed]!
            remaining.remove(seed)
            var members = [seed]
            var cursor = 0
            while cursor < members.count {
                let current = members[cursor]
                for index in spatialIndex.indices(intersecting: searchBounds(lines[current])).sorted()
                where remaining.contains(index) && abs(angles[index]! - baseline) <= 0.07 {
                    remaining.remove(index)
                    members.append(index)
                }
                cursor += 1
            }
            let origin = lines[seed].box.origin
            func rotated(_ line: Line, inverse: Bool) -> Line {
                let theta = inverse ? baseline : -baseline
                let cosine = cos(theta), sine = sin(theta)
                let polygon = line.polygon.map { point -> CGPoint in
                    let x = inverse ? point.x : point.x - origin.x
                    let y = inverse ? point.y : point.y - origin.y
                    return CGPoint(x: x * cosine - y * sine + (inverse ? origin.x : 0),
                                   y: x * sine + y * cosine + (inverse ? origin.y : 0))
                }
                return Line(index: line.index, text: line.text, confidence: line.confidence,
                            box: boundingBox(polygon), polygon: polygon,
                            orientationHint: line.orientationHint, orientation: line.orientation,
                            singleVerticalColumn: line.singleVerticalColumn, clippedByTile: line.clippedByTile)
            }
            if members.count == 1 {
                result.append(lines[seed])
            } else {
                result += mergeConservativeTextLines(
                    members.map { rotated(lines[$0], inverse: false) },
                    imageWidth: imageWidth, imageHeight: imageHeight,
                    recognizedLatinWords: recognizedLatinWords, deskew: false
                ).map { rotated($0, inverse: true) }
            }
        }
        return result.sorted { $0.index < $1.index }
    }

    private static func mergeLineFragments(
        _ lines: [Line],
        imageWidth: CGFloat,
        imageHeight: CGFloat,
        recognizedLatinWords: Set<String>,
        separationCheck: ((CGRect, CGRect, BrowserOCRSourceOrientation) -> Bool)? = nil
    ) -> [Line] {
        let geometries = lines.enumerated().map(makeGeometry)
        let spatialIndex = NativeOCRSpatialIndex(boxes: lines.map(\.box))
        var parent = Array(geometries.indices)
        var componentMembers = geometries.map { [$0.index] }
        var componentOrientation = geometries.map(fixedOrientation)
        var candidates: [Candidate] = []
        let regularHorizontal = regularSpacingPairs(lines, orientation: .horizontal, fragments: true)
        let regularVertical = regularSpacingPairs(lines, orientation: .vertical, fragments: true)
        for left in geometries.indices {
            for right in spatialIndex.indices(intersecting: searchBounds(lines[left])) where right > left {
                let leftGeometry = geometries[left]
                let rightGeometry = geometries[right]
                if leftGeometry.supportsVertical,
                   rightGeometry.supportsVertical,
                   let candidate = mergeCandidate(
                       leftGeometry,
                       rightGeometry,
                       orientation: .vertical,
                       maximumGap: verticalFragmentGap(leftGeometry, rightGeometry, regular: regularVertical.contains(IndexPair(left, right)))
                   ), separationCheck?(leftGeometry.line.box, rightGeometry.line.box, .vertical) != true {
                    candidates.append(candidate)
                }
                if leftGeometry.supportsHorizontal,
                   rightGeometry.supportsHorizontal,
                   !spatialIndex.indices(intersecting: leftGeometry.line.box.union(rightGeometry.line.box)).contains(where: { middle in
                       guard middle != left, middle != right else { return false }
                       let item = geometries[middle]
                       return item.centerX > min(leftGeometry.centerX, rightGeometry.centerX) &&
                           item.centerX < max(leftGeometry.centerX, rightGeometry.centerX) &&
                           abs(item.centerY - (leftGeometry.centerY + rightGeometry.centerY) / 2) <
                               min(leftGeometry.line.box.height, rightGeometry.line.box.height) * 0.35
                   }),
                   let candidate = mergeCandidate(
                       leftGeometry,
                       rightGeometry,
                       orientation: .horizontal,
                       maximumGap: regularHorizontal.contains(IndexPair(left, right)) ? 0.85 : 0.4
                   ) {
                    let ordered = [leftGeometry.line, rightGeometry.line].sorted { $0.box.minX < $1.box.minX }
                    let font = min(ordered[0].box.height, ordered[1].box.height)
                    let isNewOverlapEdge = ordered[0].box.maxX - ordered[1].box.minX > font * 0.15
                        && horizontalLatinOverlap(ordered[0], ordered[1]) != nil
                        && overlappingCharacterCount(ordered[0], ordered[1], orientation: .horizontal) == nil
                    if isNewOverlapEdge {
                        let nearby = spatialIndex.indices(intersecting: ordered[0].box.union(ordered[1].box)
                            .insetBy(dx: -font * 3, dy: -font * 2)).map { geometries[$0].line }
                        if conflictsWithIndependentHorizontalOwners(ordered[0], ordered[1], nearby: nearby)
                            || separationCheck?(ordered[0].box, ordered[1].box, .horizontal) == true { continue }
                    }
                    candidates.append(candidate)
                }
            }
        }
        candidates.sort {
            if $0.normalizedGap != $1.normalizedGap {
                return $0.normalizedGap < $1.normalizedGap
            }
            if $0.orientation.rawValue != $1.orientation.rawValue {
                return $0.orientation.rawValue < $1.orientation.rawValue
            }
            if $0.left != $1.left { return $0.left < $1.left }
            return $0.right < $1.right
        }

        for candidate in candidates {
            let leftRoot = find(&parent, candidate.left)
            let rightRoot = find(&parent, candidate.right)
            guard leftRoot != rightRoot else { continue }
            if let orientation = componentOrientation[leftRoot],
               orientation != candidate.orientation {
                continue
            }
            if let orientation = componentOrientation[rightRoot],
               orientation != candidate.orientation {
                continue
            }
            let memberIndices = componentMembers[leftRoot] + componentMembers[rightRoot]
            let members = memberIndices.map { geometries[$0] }
            guard componentRemainsLineLike(
                members,
                orientation: candidate.orientation,
                regularPairs: candidate.orientation == .vertical ? regularVertical : regularHorizontal
            ) else { continue }
            parent[rightRoot] = leftRoot
            componentMembers[leftRoot] = memberIndices
            componentMembers[rightRoot] = []
            componentOrientation[leftRoot] = candidate.orientation
        }

        var components: [Int: [Geometry]] = [:]
        for geometry in geometries {
            let root = find(&parent, geometry.index)
            components[root, default: []].append(geometry)
        }
        return components.map { root, component in
            let currentRoot = find(&parent, root)
            return mergeComponent(
                component,
                imageWidth: imageWidth,
                imageHeight: imageHeight,
                orientation: componentOrientation[currentRoot]
                    ?? defaultOrientation(component[0]),
                recognizedLatinWords: recognizedLatinWords
            )
        }.sorted { $0.index < $1.index }
    }

    private static func makeGeometry(
        _ pair: (offset: Int, element: Line)
    ) -> Geometry {
        let (index, line) = pair
        let width = max(1, line.box.width)
        let height = max(1, line.box.height)
        let clearlyVertical = height >= width * 1.25
        let compactSingleCJKGlyph = isSingleCJKGlyph(line.text)
            && height >= width * 0.65
            && height <= width * 1.6
        return Geometry(
            index: index,
            line: line,
            centerX: line.box.midX,
            centerY: line.box.midY,
            supportsHorizontal: line.orientationHint == .horizontal
                || (line.orientationHint == .unknown && !clearlyVertical),
            supportsVertical: line.orientationHint == .vertical
                || (line.orientationHint == .unknown
                    && (clearlyVertical || compactSingleCJKGlyph))
        )
    }

    /// Every accepted pair is overlapping or separated by at most 0.9 of the
    /// smaller font size. Include both possible directions for ambiguous glyphs
    /// and a revised direction when looking for a wrapped horizontal tail.
    private static func searchBounds(_ line: Line) -> CGRect {
        let geometry = makeGeometry((0, line))
        let font = max(
            1,
            line.orientation == .vertical ? line.box.width : line.box.height,
            geometry.supportsHorizontal ? line.box.height : 0,
            geometry.supportsVertical ? line.box.width : 0
        )
        return line.box.insetBy(dx: -font, dy: -font * (line.orientation == .vertical ? 1.2 : 1))
    }

    /// Expand the conservative gap only when a local three-item run
    /// proves regular spacing. Use nearest neighbours so a blank paragraph gap
    /// cannot borrow evidence from a farther row or from another text column.
    private static func regularSpacingPairs(
        _ lines: [Line], orientation: Orientation, fragments: Bool
    ) -> Set<IndexPair> {
        guard lines.count >= 3 else { return [] }
        let eligible = lines.enumerated().compactMap { index, line -> Int? in
            if !fragments { return line.orientation == orientation ? index : nil }
            let letters = line.text.unicodeScalars.filter(isLetter)
            guard !letters.isEmpty, letters.allSatisfy(isCJK) else { return nil }
            let geometry = makeGeometry((index, line))
            return (orientation == .vertical ? geometry.supportsVertical : geometry.supportsHorizontal) ? index : nil
        }
        guard eligible.count >= 3 else { return [] }
        let spatial = NativeOCRSpatialIndex(boxes: eligible.map { lines[$0].box })
        let alongY = fragments ? orientation == .vertical : orientation == .horizontal
        // Wide spacing alone must not combine a CJK caption and its Latin
        // counterpart into one region before source-language filtering.
        let containsCJK = lines.map { $0.text.unicodeScalars.contains(where: isCJK) }
        var preceding: [Int: SpacingLink] = [:]
        var following: [Int: SpacingLink] = [:]
        for left in eligible {
            for localRight in spatial.indices(intersecting: searchBounds(lines[left])) {
                let right = eligible[localRight]
                guard right > left, containsCJK[left] == containsCJK[right] else { continue }
                let leftBox = lines[left].box
                let rightBox = lines[right].box
                let leftFont = orientation == .vertical ? leftBox.width : leftBox.height
                let rightFont = orientation == .vertical ? rightBox.width : rightBox.height
                let font = min(leftFont, rightFont)
                guard font > 0, max(leftFont, rightFont) / font <= 1.25 else { continue }
                let first = (alongY ? leftBox.minY < rightBox.minY : leftBox.minX < rightBox.minX) ? left : right
                let second = first == left ? right : left
                let firstBox = lines[first].box
                let secondBox = lines[second].box
                let gap = alongY ? secondBox.minY - firstBox.maxY : secondBox.minX - firstBox.maxX
                guard gap >= 0, gap < font * 0.85 else { continue }
                let crossOverlap = alongY
                    ? overlapRatio(leftBox.minX, leftBox.maxX, rightBox.minX, rightBox.maxX)
                    : overlapRatio(leftBox.minY, leftBox.maxY, rightBox.minY, rightBox.maxY)
                let centerDelta = alongY ? abs(leftBox.midX - rightBox.midX) : abs(leftBox.midY - rightBox.midY)
                let edgeDelta = alongY
                    ? min(abs(leftBox.minX - rightBox.minX), abs(leftBox.maxX - rightBox.maxX))
                    : min(abs(leftBox.minY - rightBox.minY), abs(leftBox.maxY - rightBox.maxY))
                guard crossOverlap >= 0.8, (fragments ? centerDelta : min(centerDelta, edgeDelta)) <= font * 0.2 else { continue }
                let link = SpacingLink(first: first, second: second, normalizedGap: gap / font)
                if following[first] == nil || link.normalizedGap < following[first]!.normalizedGap { following[first] = link }
                if preceding[second] == nil || link.normalizedGap < preceding[second]!.normalizedGap { preceding[second] = link }
            }
        }
        var result: Set<IndexPair> = []
        for middle in eligible {
            guard let before = preceding[middle], let after = following[middle],
                  following[before.first]?.second == middle, preceding[after.second]?.first == middle,
                  abs(before.normalizedGap - after.normalizedGap) <= 0.15 else { continue }
            result.insert(IndexPair(before.first, middle))
            result.insert(IndexPair(middle, after.second))
        }
        return result
    }

    // Resolve interrupted columns before joining adjacent columns into a box.
    // Otherwise that box can enclose a still-unclaimed fragment, losing its
    // column position and preventing a later ordered merge.
    private static func verticalFragmentGap(_ a: Geometry, _ b: Geometry, regular: Bool) -> CGFloat {
        let upper = a.line.box.minY <= b.line.box.minY ? a : b
        let lower = a.line.box.minY <= b.line.box.minY ? b : a
        let x = upper.line.box, y = lower.line.box
        let font = min(x.width, y.width)
        let next = lower.line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if font > 0, upper.line.text.count >= 2, next.count >= 2,
           !next.hasPrefix("「"), !next.hasPrefix("『"), !next.hasPrefix("“"),
           max(x.width, y.width) <= font * 1.6,
           overlapRatio(x.minX, x.maxX, y.minX, y.maxX) >= 0.8,
           abs(x.midX - y.midX) <= font * 0.25,
           x.maxY <= y.minY, y.minY - x.maxY <= font * 1.1 {
            return 1.11
        }
        return regular ? 0.85 : 0.4
    }

    private static func mergeCandidate(
        _ left: Geometry,
        _ right: Geometry,
        orientation: Orientation,
        maximumGap: CGFloat = 0.4
    ) -> Candidate? {
        let leftFont = fontSize(left, orientation: orientation)
        let rightFont = fontSize(right, orientation: orientation)
        let smallerFont = min(leftFont, rightFont)
        let largerFont = max(leftFont, rightFont)
        guard largerFont / smallerFont <= 1.6 else { return nil }

        let primaryGap = orientation == .vertical
            ? intervalGap(
                left.line.box.minY, left.line.box.maxY,
                right.line.box.minY, right.line.box.maxY
            )
            : intervalGap(
                left.line.box.minX, left.line.box.maxX,
                right.line.box.minX, right.line.box.maxX
            )
        guard primaryGap < smallerFont * maximumGap else { return nil }

        let perpendicularOverlap = orientation == .vertical
            ? overlapRatio(
                left.line.box.minX, left.line.box.maxX,
                right.line.box.minX, right.line.box.maxX
            )
            : overlapRatio(
                left.line.box.minY, left.line.box.maxY,
                right.line.box.minY, right.line.box.maxY
            )
        let alignmentDelta = orientation == .vertical
            ? abs(left.centerX - right.centerX)
            : abs(left.centerY - right.centerY)
        guard perpendicularOverlap >= 0.58,
              alignmentDelta <= smallerFont * 0.45
        else { return nil }
        if primaryGap < -smallerFont * 0.15 {
            let ordered = [left.line, right.line].sorted {
                primaryInterval($0.box, orientation: orientation).0
                    < primaryInterval($1.box, orientation: orientation).0
            }
            guard overlappingJoin(
                ordered[0], ordered[1], orientation: orientation
            ) != nil || (orientation == .horizontal && paddedCJKNeighbours(ordered[0], ordered[1]))
                || (orientation == .horizontal && horizontalLatinOverlap(ordered[0], ordered[1]) != nil)
                || (orientation == .vertical && paddedVerticalNeighbours(ordered[0], ordered[1])) else { return nil }
        }
        return Candidate(
            left: left.index,
            right: right.index,
            normalizedGap: max(0, primaryGap) / smallerFont,
            orientation: orientation
        )
    }

    /// Detector expansion may overlap adjacent glyph boxes without either
    /// recognition containing the other's text. Keep every glyph in that case.
    // Full-page DBNet boxes can overlap by less than half a glyph at a pause.
    // These are successive pieces of one column, not duplicate text crops.
    private static func paddedVerticalNeighbours(_ upper: Line, _ lower: Line) -> Bool {
        let a = upper.box, b = lower.box, font = min(upper.box.width, lower.box.width)
        let overlap = a.maxY - b.minY
        let next = lower.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard font > 0, !upper.clippedByTile, !lower.clippedByTile,
              upper.text.count >= 2, next.count >= 2,
              !next.hasPrefix("「"), !next.hasPrefix("『"), !next.hasPrefix("“"),
              a.minY < b.minY, a.maxY < b.maxY,
              overlap > 0, overlap <= font * 0.5,
              overlap <= min(a.height, b.height) * 0.15,
              abs(a.midX - b.midX) <= font * 0.25,
              overlapRatio(a.minX, a.maxX, b.minX, b.maxX) >= 0.8 else { return false }
        return true
    }

    // Consult ownership evidence only for newly admitted overlap edges.
    private static func conflictsWithIndependentHorizontalOwners(
        _ left: Line, _ right: Line, nearby: [Line]
    ) -> Bool {
        let a = left.box, b = right.box, font = min(a.height, b.height)
        func horizontalLatin(_ line: Line) -> Bool {
            let letters = line.text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
            return line.orientation == .horizontal && !letters.isEmpty && letters.allSatisfy(isLatin)
        }
        let others = nearby.filter { $0.index != left.index && $0.index != right.index && horizontalLatin($0) }
        let center = (a.midY + b.midY) / 2
        // Three independently detected neighbouring labels in one row are
        // ambiguous without ownership evidence; abstain instead of inventing a phrase.
        if others.contains(where: { line in
            let c = line.box
            return max(c.height, font) <= min(c.height, font) * 2
                && abs(c.midY - center) <= font * 0.4
                && (c.midX < a.minX || c.midX > b.maxX)
                && min(abs(c.maxX - a.minX), abs(c.minX - b.maxX)) <= font * 3
        }) { return true }
        // Two adjacent independently wrapped columns must not be bridged just
        // because one pair of rows happens to share a baseline.
        func hasExclusiveContinuation(_ own: CGRect, other: CGRect) -> Bool {
            others.contains { line in
                let c = line.box
                let dy = abs(c.midY - own.midY)
                let ownOverlap = max(0, min(c.maxX, own.maxX) - max(c.minX, own.minX))
                let otherOverlap = max(0, min(c.maxX, other.maxX) - max(c.minX, other.minX))
                return max(c.height, own.height) <= min(c.height, own.height) * 1.5
                    && dy >= min(c.height, own.height) * 0.7 && dy <= max(c.height, own.height) * 2
                    && ownOverlap >= min(c.width, own.width) * 0.65
                    && otherOverlap <= c.width * 0.2
            }
        }
        return hasExclusiveContinuation(a, other: b) && hasExclusiveContinuation(b, other: a)
    }

    // Distinguish detector padding from one shared source glyph.
    private static func horizontalLatinOverlap(_ left: Line, _ right: Line) -> Int? {
        guard left.orientation == .horizontal, right.orientation == .horizontal,
              !left.clippedByTile, !right.clippedByTile else { return nil }
        let a = left.box, b = right.box, font = min(a.height, b.height)
        let x = left.text, y = right.text
        let letters = (x + y).unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty, letters.allSatisfy(isLatin), x.count >= 2, y.count >= 2,
              max(a.height, b.height) <= font * 1.25,
              abs(a.midY - b.midY) <= font * 0.2,
              overlapRatio(a.minY, a.maxY, b.minY, b.maxY) >= 0.8,
              a.minX < b.minX, a.maxX < b.maxX, a.maxX > b.minX else { return nil }
        let overlap = a.maxX - b.minX
        let ax = a.width / CGFloat(x.count), bx = b.width / CGFloat(y.count)
        guard min(ax, bx) > 0, max(ax, bx) <= min(ax, bx) * 1.6 else { return nil }
        // Less than half a source glyph cannot justify deleting any character.
        if overlap <= min(ax, bx) * 0.35 { return 0 }
        // A trailing word and an isolated re-read suffix must share one glyph area.
        let words = x.split(whereSeparator: { $0.isWhitespace })
        let next = Array(y)
        guard let word = words.last, word.count >= 3,
              word.allSatisfy({ $0.isLetter }), next.count >= 3,
              next[0] == word.last, next[1].isWhitespace,
              next.dropFirst(2).contains(where: { $0.isLetter }),
              abs(overlap - (ax + bx) / 2) <= (ax + bx) / 2 * 0.25 else { return nil }
        return 1
    }

    private static func paddedCJKNeighbours(_ left: Line, _ right: Line) -> Bool {
        let a = left.text.unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) }
        let b = right.text.unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) }
        guard left.text.count == 1 || right.text.count == 1,
              !a.isEmpty, !b.isEmpty, a.allSatisfy(isCJK), b.allSatisfy(isCJK),
              left.box.minX < right.box.minX, left.box.maxX < right.box.maxX else { return false }
        let overlap = left.box.maxX - right.box.minX
        return overlap > 0 && overlap <= min(left.box.height, right.box.height) * 0.55 &&
            overlap <= min(left.box.width, right.box.width) * 0.55
    }

    private static func inheritHorizontalInlineGlyphs(_ lines: [Line]) -> [Line] {
        let index = NativeOCRSpatialIndex(boxes: lines.map(\.box))
        return lines.map { line in
            guard line.orientation == .vertical, isSingleCJKGlyph(line.text),
                  line.box.height >= line.box.width * 0.65,
                  line.box.height <= line.box.width * 1.6 else { return line }
            let neighbours = index.indices(intersecting: line.box.insetBy(dx: -line.box.height * 0.6, dy: 0)).map { lines[$0] }.filter {
                $0.index != line.index && $0.orientation == .horizontal &&
                    $0.box.height / line.box.height >= 0.75 && $0.box.height / line.box.height <= 1.4 &&
                    abs($0.box.midY - line.box.midY) <= line.box.height * 0.2
            }
            guard neighbours.contains(where: { $0.box.midX < line.box.midX && $0.box.maxX < line.box.maxX }),
                  neighbours.contains(where: { $0.box.midX > line.box.midX && $0.box.minX > line.box.minX }) else { return line }
            return Line(index: line.index, text: line.text, confidence: line.confidence,
                box: line.box, polygon: line.polygon, orientationHint: .horizontal,
                orientation: .horizontal, singleVerticalColumn: false, sourceTileBounds: line.sourceTileBounds)
        }
    }

    private static func componentRemainsLineLike(
        _ component: [Geometry],
        orientation: Orientation,
        regularPairs: Set<IndexPair>
    ) -> Bool {
        guard !component.isEmpty else { return false }
        guard component.allSatisfy({ item in
            orientation == .vertical
                ? item.supportsVertical
                : item.supportsHorizontal
        }) else { return false }
        let fonts = component.map { fontSize($0, orientation: orientation) }
        guard (fonts.max() ?? 1) / (fonts.min() ?? 1) <= 1.6 else {
            return false
        }
        let centers = component.map {
            orientation == .vertical ? $0.centerX : $0.centerY
        }
        let meanFont = fonts.reduce(0, +) / CGFloat(fonts.count)
        guard (centers.max() ?? 0) - (centers.min() ?? 0) <= meanFont * 0.85 else {
            return false
        }
        // A shared neighbour must not join two conflicting OCR alternatives.
        let ordered = component.sorted {
            primaryInterval($0.line.box, orientation: orientation).0
                < primaryInterval($1.line.box, orientation: orientation).0
        }
        for (left, right) in zip(ordered, ordered.dropFirst()) {
            let regular = regularPairs.contains(IndexPair(left.index, right.index))
            let limit: CGFloat = orientation == .vertical ? verticalFragmentGap(left, right, regular: regular) : (regular ? 0.85 : 0.4)
            guard mergeCandidate(left, right, orientation: orientation, maximumGap: limit) != nil else {
                return false
            }
        }
        return true
    }

    private static func mergeComponent(
        _ component: [Geometry],
        imageWidth: CGFloat,
        imageHeight: CGFloat,
        orientation: Orientation,
        recognizedLatinWords: Set<String>
    ) -> Line {
        precondition(!component.isEmpty)
        if component.count == 1 {
            var line = component[0].line
            line.orientation = orientation
            line.singleVerticalColumn = orientation == .vertical
            return line
        }
        let ordered = component.sorted { left, right in
            if orientation == .vertical {
                if left.line.box.minY != right.line.box.minY {
                    return left.line.box.minY < right.line.box.minY
                }
                return left.line.box.minX > right.line.box.minX
            }
            if left.line.box.minX != right.line.box.minX {
                return left.line.box.minX < right.line.box.minX
            }
            return left.line.box.minY < right.line.box.minY
        }
        let box = unionBoxes(ordered.map { $0.line.box })
        let polygon = rectanglePolygon(box)
        let weightedCharacters = ordered.reduce(0) {
            $0 + max(1, $1.line.text.count)
        }
        let confidence = ordered.reduce(0.0) {
            $0 + $1.line.confidence * Double(max(1, $1.line.text.count))
        } / Double(weightedCharacters)
        let text = joinOrderedLines(
            ordered.map(\.line), orientation: orientation, fragments: true,
            recognizedLatinWords: recognizedLatinWords
        )
        return Line(
            index: ordered.map(\.line.index).min() ?? 0,
            text: text,
            confidence: confidence,
            box: box,
            polygon: polygon,
            orientationHint: orientation.source,
            orientation: orientation,
            singleVerticalColumn: orientation == .vertical
        )
    }

    private static func isSingleCJKGlyph(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count == 1 && trimmed.unicodeScalars.allSatisfy(isCJK)
    }

    private static func fontSize(
        _ geometry: Geometry,
        orientation: Orientation
    ) -> CGFloat {
        orientation == .vertical
            ? max(1, geometry.line.box.width)
            : max(1, geometry.line.box.height)
    }

    private static func fixedOrientation(
        _ geometry: Geometry
    ) -> Orientation? {
        if geometry.supportsVertical && !geometry.supportsHorizontal {
            return .vertical
        }
        if geometry.supportsHorizontal && !geometry.supportsVertical {
            return .horizontal
        }
        return nil
    }

    private static func defaultOrientation(
        _ geometry: Geometry
    ) -> Orientation {
        geometry.line.orientation
    }

    private static func joinFragments(_ left: String, _ right: String) -> String {
        guard !left.isEmpty else { return right }
        guard !right.isEmpty else { return left }
        guard let leftScalar = left.unicodeScalars.last,
              let rightScalar = right.unicodeScalars.first
        else { return left + right }
        let needsSpace = isLetterOrNumber(leftScalar)
            && isLetterOrNumber(rightScalar)
            && (isLatin(leftScalar) || isNumber(leftScalar))
            && (isLatin(rightScalar) || isNumber(rightScalar))
        return left + (needsSpace ? " " : "") + right
    }

    private static func primaryInterval(
        _ box: CGRect, orientation: Orientation
    ) -> (CGFloat, CGFloat) {
        orientation == .vertical ? (box.minY, box.maxY) : (box.minX, box.maxX)
    }

    /// Reconcile only a suffix/prefix that occupies the same part of one line.
    /// Text similarity alone is insufficient: repeated dialogue, adjacent
    /// columns, contained detections and punctuation must retain their text.
    private static func overlappingCharacterCount(
        _ left: Line, _ right: Line, orientation: Orientation
    ) -> Int? {
        let leftAxis = primaryInterval(left.box, orientation: orientation)
        let rightAxis = primaryInterval(right.box, orientation: orientation)
        guard leftAxis.0 < rightAxis.0, leftAxis.1 < rightAxis.1 else { return nil }
        let overlap = leftAxis.1 - rightAxis.0
        guard overlap > 0 else { return nil }
        let leftCross = primaryInterval(left.box, orientation: orientation == .vertical ? .horizontal : .vertical)
        let rightCross = primaryInterval(right.box, orientation: orientation == .vertical ? .horizontal : .vertical)
        let smallerFont = min(leftCross.1 - leftCross.0, rightCross.1 - rightCross.0)
        guard overlapRatio(leftCross.0, leftCross.1, rightCross.0, rightCross.1) >= 0.8,
              abs((leftCross.0 + leftCross.1) - (rightCross.0 + rightCross.1)) / 2
                <= smallerFont * 0.3
        else { return nil }

        let leftText = overlapComparisonGlyphs(left.text)
        let rightText = overlapComparisonGlyphs(right.text)
        let tileContinuation = (left.clippedByTile || right.clippedByTile)
            && originateInDifferentOverlappingTiles(left, right)
        // A second tile may contain only the final glyphs of a clipped line.
        // Detector padding can extend that complete suffix slightly beyond the
        // first tile. Require the same physical ink and the actual ending edge;
        // ordinary contained/repeated text must not take this path.
        let endsAtTileBoundary = left.sourceTileBounds.map {
            abs(leftAxis.1 - primaryInterval($0, orientation: orientation).1) <= 1
        } ?? false
        let wholeRightSuffix = tileContinuation && left.clippedByTile && endsAtTileBoundary
            && rightText.count < leftText.count
            && overlap >= (rightAxis.1 - rightAxis.0) * 0.75
            && rightAxis.1 - leftAxis.1 <= smallerFont * 0.5
        let maximumOverlap = min(256, min(leftText.count - 1, rightText.count - (wholeRightSuffix ? 0 : 1)))
        let minimumOverlap = tileContinuation ? 2 : 3
        guard maximumOverlap >= minimumOverlap else { return nil }
        let leftAdvance = (leftAxis.1 - leftAxis.0) / CGFloat(leftText.count)
        let rightAdvance = (rightAxis.1 - rightAxis.0) / CGFloat(rightText.count)
        guard max(leftAdvance, rightAdvance) / min(leftAdvance, rightAdvance) <= 1.6 else {
            return nil
        }
        for count in stride(from: maximumOverlap, through: minimumOverlap, by: -1) {
            let suffix = leftText.suffix(count)
            guard suffix.elementsEqual(rightText.prefix(count)) else { continue }
            let letters = suffix.filter { $0.unicodeScalars.contains(where: isLetterOrNumber) }
            guard letters.count >= minimumOverlap, Set(letters).count >= 2 else { continue }
            let expectedOverlap = CGFloat(count) * (leftAdvance + rightAdvance) / 2
            guard abs(overlap - expectedOverlap) <= max(smallerFont * (tileContinuation ? 1 : 0.5), expectedOverlap * 0.35) else {
                continue
            }
            return count
        }
        return nil
    }

    private struct OverlappingJoin {
        let prefixCount: Int
        var trailingLeftCount = 0
    }

    private static func overlappingJoin(
        _ left: Line, _ right: Line, orientation: Orientation
    ) -> OverlappingJoin? {
        if let count = overlappingCharacterCount(left, right, orientation: orientation) {
            return OverlappingJoin(prefixCount: count)
        }
        if orientation == .horizontal, horizontalLatinOverlap(left, right) == 1 {
            return OverlappingJoin(prefixCount: 1)
        }
        // A clipped crop may read the beginning of an ellipsis as a middle dot.
        // Only the crop ending at the tile edge can surrender that punctuation;
        // the overlapping crop must independently re-read at least three letters.
        guard left.clippedByTile, originateInDifferentOverlappingTiles(left, right),
              let tile = left.sourceTileBounds,
              primaryInterval(left.box, orientation: orientation).1
                >= primaryInterval(tile, orientation: orientation).1 - 1,
              let last = left.text.last, "・.…。".contains(last) else { return nil }
        var clipped = left
        clipped.text = String(left.text.dropLast())
        guard let count = overlappingCharacterCount(clipped, right, orientation: orientation),
              count >= 3 else { return nil }
        return OverlappingJoin(prefixCount: count, trailingLeftCount: 1)
    }

    /// One comparison key per original grapheme keeps suffix lengths mapped to
    /// the original string. Width folding also handles voiced halfwidth kana,
    /// but deliberately does not equate circled digits or other compatibility
    /// characters whose visual distinction can carry meaning.
    private static func overlapComparisonGlyphs(_ text: String) -> [String] {
        text.trimmingCharacters(in: .whitespacesAndNewlines).map {
            String($0).folding(options: .widthInsensitive, locale: Locale(identifier: "en_US_POSIX"))
                .precomposedStringWithCanonicalMapping
        }
    }

    private static func joinOrderedLines(
        _ lines: [Line], orientation: Orientation, fragments: Bool,
        recognizedLatinWords: Set<String> = []
    ) -> String {
        var text = ""
        var previous: Line?
        for line in lines {
            let next = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !next.isEmpty else { continue }
            if let previous,
               let match = overlappingJoin(previous, line, orientation: orientation) {
                if match.trailingLeftCount > 0 { text = String(text.dropLast(match.trailingLeftCount)) }
                text += next.dropFirst(match.prefixCount)
            } else if fragments, let previous,
                      isTightlySplitLatinWord(previous, line, orientation: orientation),
                      recognizedLatinWords.contains(previous.text + line.text),
                      !(recognizedLatinWords.contains(previous.text) && recognizedLatinWords.contains(line.text)) {
                text += next
            } else {
                text = fragments ? joinFragments(text, next) : joinRegionText(text, next)
            }
            previous = line
        }
        return text
    }

    private static func isTightlySplitLatinWord(
        _ left: Line, _ right: Line, orientation: Orientation
    ) -> Bool {
        guard orientation == .horizontal else { return false }
        // Explicit whitespace, numbers, initials and capitalised words keep
        // their boundaries. Only very tight lowercase fragments are eligible.
        guard isLowercaseLatinFragment(left.text), isLowercaseLatinFragment(right.text) else { return false }
        let advance = min(left.box.width / CGFloat(left.text.count), right.box.width / CGFloat(right.text.count))
        let font = min(left.box.height, right.box.height)
        let gap = right.box.minX - left.box.maxX
        return gap >= 0 && gap <= min(advance * 0.25, font * 0.12)
    }

    private static func isLowercaseLatinFragment(_ text: String) -> Bool {
        (3...64).contains(text.count)
            && text.unicodeScalars.allSatisfy { (97...122).contains($0.value) }
    }

    private static func intervalGap(
        _ leftStart: CGFloat,
        _ leftEnd: CGFloat,
        _ rightStart: CGFloat,
        _ rightEnd: CGFloat
    ) -> CGFloat {
        max(leftStart, rightStart) - min(leftEnd, rightEnd)
    }

    private static func overlapRatio(
        _ leftStart: CGFloat,
        _ leftEnd: CGFloat,
        _ rightStart: CGFloat,
        _ rightEnd: CGFloat
    ) -> CGFloat {
        let overlap = max(
            0,
            min(leftEnd, rightEnd) - max(leftStart, rightStart)
        )
        return overlap / max(1, min(leftEnd - leftStart, rightEnd - rightStart))
    }

    private static func resolvedSingleLine(_ source: Line) -> Line {
        var line = source
        line.orientation = Orientation(source.orientationHint, box: source.box)
        line.singleVerticalColumn = line.orientation == .vertical
        return Line(
            index: source.index,
            text: line.text,
            confidence: line.confidence,
            box: line.box,
            polygon: line.polygon,
            orientationHint: line.orientationHint,
            orientation: line.orientation,
            singleVerticalColumn: line.singleVerticalColumn
        )
    }

    private static func inheritHorizontalWrappedTailOrientations(
        _ lines: [Line]
    ) -> [Line] {
        let geometries = lines.enumerated().map(makeRegionGeometry)
        let spatialIndex = NativeOCRSpatialIndex(boxes: lines.map(\.box))
        return lines.enumerated().map { index, line in
            let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.orientation == .vertical,
                  line.orientationHint == .unknown,
                  trimmed.count <= 2,
                  !trimmed.isEmpty,
                  trimmed.unicodeScalars.allSatisfy(isCJK)
            else { return line }

            var horizontalLine = line
            horizontalLine.orientation = .horizontal
            horizontalLine.singleVerticalColumn = false
            let candidate = makeRegionGeometry((index, horizontalLine))
            let matches = spatialIndex.indices(intersecting: searchBounds(horizontalLine)).map { geometries[$0] }.filter {
                $0.index != index
                    && $0.orientation == .horizontal
                    && compactText($0.line.text).count >= 4
                    && canFormTranslationRegion(candidate, $0)
            }
            return matches.count == 1 ? horizontalLine : line
        }
    }

    /// One full-size CJK glyph at the top of a neighbouring vertical column
    /// has no intrinsic writing direction. Resolve only an estimated direction
    /// with one compatible column; tiny ruby and explicit horizontal text stay.
    private static func inheritVerticalSingletonOrientations(_ lines: [Line]) -> [Line] {
        guard lines.contains(where: {
            $0.orientation == .horizontal && $0.orientationHint == .unknown && isSingleCJKGlyph($0.text)
        }) else { return lines }
        let geometries = lines.enumerated().map(makeRegionGeometry)
        let spatialIndex = NativeOCRSpatialIndex(boxes: lines.map(\.box))
        return lines.enumerated().map { index, line in
            guard line.orientation == .horizontal, line.orientationHint == .unknown,
                  isSingleCJKGlyph(line.text), line.box.height >= line.box.width * 0.65,
                  line.box.height <= line.box.width * 1.6 else { return line }
            var vertical = line
            vertical.orientation = .vertical
            vertical.singleVerticalColumn = true
            let candidate = makeRegionGeometry((index, vertical))
            let matches = spatialIndex.indices(intersecting: searchBounds(line)).filter {
                let other = geometries[$0]
                return $0 != index && other.orientation == .vertical && compactText(other.line.text).count >= 2
                    && line.box.width >= other.fontSize * 0.75
                    && abs(line.box.minY - other.box.minY) <= min(line.box.width, other.fontSize) * 0.45
                    && isMangaVerticalContinuation(candidate, other)
            }
            return matches.count == 1 ? vertical : line
        }
    }

    private static func deduplicateLines(_ lines: [Line]) -> [Line] {
        guard lines.count > 1 else { return lines }
        let ordered = lines.sorted(by: duplicateRepresentativePrecedes)
        let spatialIndex = NativeOCRSpatialIndex(boxes: ordered.map(\.box))
        var suppressed: Set<Int> = []
        var retained: [Line] = []
        // Suppression is directional and always anchored to a retained line.
        // A short shared substring must never bridge two distinct full lines.
        for left in ordered.indices where !suppressed.contains(left) {
            retained.append(ordered[left])
            for right in spatialIndex.indices(intersecting: ordered[left].box)
                where right > left && !suppressed.contains(right) {
                if canSuppressDuplicate(ordered[right], keeping: ordered[left]) {
                    suppressed.insert(right)
                }
            }
        }
        return retained.sorted { $0.index < $1.index }
    }

    private static func canSuppressDuplicate(_ right: Line, keeping left: Line) -> Bool {
        if containsTileReadingEdgeFragment(right, in: left) { return true }
        if containsPartialDetection(right, in: left) { return true }
        if duplicatesTilePaddedLine(left, right) { return true }
        guard left.orientation == right.orientation else { return false }
        let leftText = duplicateComparisonText(left.text)
        let rightText = duplicateComparisonText(right.text)
        guard !leftText.isEmpty, !rightText.isEmpty else { return false }
        // Overlapping crops may disagree only about a word space ("On Azarday"
        // vs "OnAzarday"). Require the same physical baseline/endpoints and a
        // substantial identical glyph sequence; distinct repetitions stay intact.
        if leftText != rightText, compactText(leftText).count >= 6,
           compactText(leftText) == compactText(rightText), occupiesSameTextLine(left, right) {
            return true
        }
        if containsMultilineEdgeFragment(right, in: left, fragmentText: rightText, fullText: leftText) { return true }
        let exactText = leftText == rightText
        let containedText = textContainsMeaningfulFragment(leftText, rightText)
        guard exactText || (containedText
            && CGFloat(min(leftText.count, rightText.count))
                / CGFloat(max(leftText.count, rightText.count)) >= 0.4)
        else { return false }
        let leftArea = boxArea(left.box)
        let rightArea = boxArea(right.box)
        guard leftArea > 0, rightArea > 0 else { return false }
        let areaRatio = min(leftArea, rightArea) / max(leftArea, rightArea)
        let containedArea = intersectionArea(left.box, right.box)
            / min(leftArea, rightArea)
        if exactText {
            return (areaRatio >= minimumDuplicateAreaRatio
                && containedArea >= minimumDuplicateOverlapRatio)
                || occupiesSameTextLine(left, right)
        }
        return areaRatio >= 0.18 && containedArea >= 0.9
    }

    /// A crop can cut a word/column while the full read also touches a tile's
    /// orthogonal edge. Match the actual reading-axis boundary rather than
    /// treating every touched edge as an incomplete full read.
    private static func containsTileReadingEdgeFragment(_ fragment: Line, in full: Line) -> Bool {
        guard fragment.orientation == full.orientation,
              originateInDifferentOverlappingTiles(fragment, full),
              let tile = fragment.sourceTileBounds else { return false }
        let part = overlapComparisonGlyphs(fragment.text), text = overlapComparisonGlyphs(full.text)
        guard part.count >= 2, part.count < text.count else { return false }
        let along = full.orientation
        let across: Orientation = along == .vertical ? .horizontal : .vertical
        let a = primaryInterval(full.box, orientation: along), b = primaryInterval(fragment.box, orientation: along)
        let ac = primaryInterval(full.box, orientation: across), bc = primaryInterval(fragment.box, orientation: across)
        let edge = primaryInterval(tile, orientation: along)
        let font = min(ac.1 - ac.0, bc.1 - bc.0)
        guard font > 0, max(ac.1 - ac.0, bc.1 - bc.0) <= font * 1.6,
              abs((ac.0 + ac.1) - (bc.0 + bc.1)) / 2 <= font * 0.3,
              intersectionArea(full.box, fragment.box) / boxArea(fragment.box) >= 0.9,
              a.1 - a.0 >= (b.1 - b.0) * 1.2 else { return false }
        let expected = (a.1 - a.0) * CGFloat(part.count) / CGFloat(text.count)
        guard b.1 - b.0 >= expected * 0.6, b.1 - b.0 <= expected * 1.5 else { return false }
        let prefix = Array(text.prefix(part.count)) == part
        let suffix = Array(text.suffix(part.count)) == part
        return (prefix && abs(b.1 - edge.1) <= 2 && a.1 > edge.1 + font * 0.25 && abs(a.0 - b.0) <= font * 0.4)
            || (suffix && abs(b.0 - edge.0) <= 2 && a.0 < edge.0 - font * 0.25 && abs(a.1 - b.1) <= font * 0.4)
    }

    /// The same line may have extra detector padding at one endpoint in a
    /// neighbouring tile. Require identical substantial text, a common baseline
    /// and one matching endpoint; never use text alone to remove repetitions.
    private static func duplicatesTilePaddedLine(_ left: Line, _ right: Line) -> Bool {
        guard left.orientation == right.orientation,
              originateInDifferentOverlappingTiles(left, right),
              duplicateComparisonText(left.text) == duplicateComparisonText(right.text),
              compactText(left.text).count >= 6 else { return false }
        let orientation = left.orientation
        let across: Orientation = orientation == .vertical ? .horizontal : .vertical
        let a = primaryInterval(left.box, orientation: orientation)
        let b = primaryInterval(right.box, orientation: orientation)
        let ac = primaryInterval(left.box, orientation: across)
        let bc = primaryInterval(right.box, orientation: across)
        let font = min(ac.1 - ac.0, bc.1 - bc.0)
        let span = min(a.1 - a.0, b.1 - b.0)
        guard max(ac.1 - ac.0, bc.1 - bc.0) <= font * 1.5,
              overlapRatio(ac.0, ac.1, bc.0, bc.1) >= 0.8,
              abs((ac.0 + ac.1) - (bc.0 + bc.1)) / 2 <= font * 0.35,
              overlapRatio(a.0, a.1, b.0, b.1) >= 0.95,
              max(a.1 - a.0, b.1 - b.0) <= span * 1.35 else { return false }
        return min(abs(a.0 - b.0), abs(a.1 - b.1)) <= min(font * 0.5, span * 0.1)
    }

    private static func originateInDifferentOverlappingTiles(_ left: Line, _ right: Line) -> Bool {
        guard let a = left.sourceTileBounds, let b = right.sourceTileBounds,
              a != b, a.intersects(b) else { return false }
        return a.intersects(right.box) && b.intersects(left.box)
    }

    /// Vision may return a whole balloon in one tile and separate rows in
    /// another. Keep a matching first/last row only once, with physical edge
    /// alignment and near-complete containment rather than substring alone.
    private static func containsMultilineEdgeFragment(
        _ fragment: Line, in full: Line, fragmentText: String, fullText: String
    ) -> Bool {
        guard full.orientation == .horizontal, fragment.orientation == .horizontal,
              fragmentText.split(whereSeparator: \.isWhitespace).count >= 2,
              fragmentText.unicodeScalars.filter(isLetter).count >= 6,
              fullText.count > fragmentText.count,
              full.box.height >= fragment.box.height * 1.6,
              full.box.height <= fragment.box.height * 4,
              fragment.box.width <= full.box.width * 1.1,
              intersectionArea(fragment.box, full.box) / boxArea(fragment.box) >= 0.9,
              abs(fragment.box.midX - full.box.midX) <= fragment.box.height * 0.35 else { return false }
        let tolerance = fragment.box.height * 0.35
        return (fullText.hasPrefix(fragmentText + " ") && abs(fragment.box.minY - full.box.minY) <= tolerance)
            || (fullText.hasSuffix(" " + fragmentText) && abs(fragment.box.maxY - full.box.maxY) <= tolerance)
    }

    /// Optional Arabic vowel marks vary between tile recognitions. Ignore
    /// them only when comparing duplicate detections; retain original output
    /// and meaningful letters/hamza/madda as well as accents in other scripts.
    private static func duplicateComparisonText(_ text: String) -> String {
        let normalized = canonicalText(text)
        return String(String.UnicodeScalarView(normalized.unicodeScalars.filter {
            !(0x064B...0x0652).contains($0.value) && $0.value != 0x0670 && $0.value != 0x0640
        }))
    }

    /// A tile can end midway through a column, returning a square glyph with
    /// the wrong orientation (or even the wrong character). Match its physical
    /// character position against a complete line before fragment grouping can
    /// attach that stale glyph to an unrelated neighbour.
    private static func containsPartialDetection(_ fragment: Line, in full: Line) -> Bool {
        guard fragment.orientationHint == .unknown || fragment.orientation == full.orientation,
              full.orientation != .vertical || full.singleVerticalColumn,
              !full.clippedByTile else { return false }
        let content = overlapComparisonGlyphs(full.text)
        let part = overlapComparisonGlyphs(fragment.text)
        guard !part.isEmpty, part.count < content.count, part.count <= 256, content.count <= 4_096 else { return false }
        let along = full.orientation
        let across: Orientation = along == .horizontal ? .vertical : .horizontal
        let a = primaryInterval(full.box, orientation: along)
        let b = primaryInterval(fragment.box, orientation: along)
        let ac = primaryInterval(full.box, orientation: across)
        let bc = primaryInterval(fragment.box, orientation: across)
        let font = min(ac.1 - ac.0, bc.1 - bc.0)
        guard max(ac.1 - ac.0, bc.1 - bc.0) <= font * 1.6,
              abs((ac.0 + ac.1) - (bc.0 + bc.1)) / 2 <= font * 0.35,
              intersectionArea(full.box, fragment.box) / boxArea(fragment.box) >= 0.75,
              a.1 - a.0 >= (b.1 - b.0) * 1.15 else { return false }

        // Mismatching tiny glyphs are discarded only with explicit evidence
        // that this detection was cut by an interior tile boundary.
        if fragment.clippedByTile, part.count <= 2,
           b.1 - b.0 <= font * 1.8,
           a.1 - a.0 >= (b.1 - b.0) * 1.8 {
            return true
        }
        guard textContainsMeaningfulFragment(full.text, fragment.text) else { return false }
        let advance = (a.1 - a.0) / CGFloat(content.count)
        let expectedSpan = advance * CGFloat(part.count)
        guard b.1 - b.0 <= expectedSpan + font,
              b.1 - b.0 >= expectedSpan * 0.5 else { return false }
        for offset in 0...(content.count - part.count)
            where content[offset..<(offset + part.count)].elementsEqual(part) {
            let expectedCenter = a.0 + advance * (CGFloat(offset) + CGFloat(part.count) / 2)
            if abs((b.0 + b.1) / 2 - expectedCenter) <= max(font * 0.75, advance * 0.65) {
                return true
            }
        }
        return false
    }

    /// Overlapping tiles resize the same ink differently. DBNet padding can
    /// change a line's thickness enough to fail area-ratio deduplication, even
    /// though its baseline and both text endpoints still agree.
    private static func occupiesSameTextLine(_ left: Line, _ right: Line) -> Bool {
        let along = left.orientation
        let across: Orientation = along == .horizontal ? .vertical : .horizontal
        let a = primaryInterval(left.box, orientation: along)
        let b = primaryInterval(right.box, orientation: along)
        let ac = primaryInterval(left.box, orientation: across)
        let bc = primaryInterval(right.box, orientation: across)
        let font = min(ac.1 - ac.0, bc.1 - bc.0)
        let span = min(a.1 - a.0, b.1 - b.0)
        guard max(ac.1 - ac.0, bc.1 - bc.0) <= font * 1.5,
              abs((ac.0 + ac.1) - (bc.0 + bc.1)) / 2 <= font * 0.2,
              overlapRatio(ac.0, ac.1, bc.0, bc.1) >= 0.8 else { return false }
        let endpointTolerance = min(font * 0.5, span * 0.1)
        return abs(a.0 - b.0) <= endpointTolerance && abs(a.1 - b.1) <= endpointTolerance
    }

    private static func compactText(_ text: String) -> String {
        canonicalText(text).filter { !$0.isWhitespace }
    }

    private static func canonicalText(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func textContainsMeaningfulFragment(
        _ containerText: String,
        _ fragmentText: String
    ) -> Bool {
        let container = canonicalText(containerText)
        let fragment = canonicalText(fragmentText)
        guard !fragment.isEmpty, container != fragment else { return false }
        let compactFragment = fragment.filter { !$0.isWhitespace }
        let isLatinOrNumberOnly = compactFragment.unicodeScalars.allSatisfy {
            isLatin($0) || isNumber($0)
        }
        guard isLatinOrNumberOnly else { return container.contains(fragment) }

        var searchStart = container.startIndex
        while searchStart < container.endIndex,
              let range = container.range(
                  of: fragment,
                  range: searchStart..<container.endIndex
              ) {
            let before = range.lowerBound > container.startIndex
                ? container.unicodeScalars[
                    container.unicodeScalars.index(before: range.lowerBound)
                ]
                : nil
            let after = range.upperBound < container.endIndex
                ? container.unicodeScalars[range.upperBound]
                : nil
            if before.map({ !isLatin($0) && !isNumber($0) }) ?? true,
               after.map({ !isLatin($0) && !isNumber($0) }) ?? true {
                return true
            }
            searchStart = container.index(after: range.lowerBound)
        }
        return false
    }

    private static func duplicateRepresentativePrecedes(
        _ left: Line,
        _ right: Line
    ) -> Bool {
        let leftCoverage = compactText(left.text).count
        let rightCoverage = compactText(right.text).count
        if leftCoverage != rightCoverage { return leftCoverage > rightCoverage }
        if left.confidence != right.confidence {
            return left.confidence > right.confidence
        }
        if boxArea(left.box) != boxArea(right.box) {
            return boxArea(left.box) > boxArea(right.box)
        }
        return left.index < right.index
    }

    private static func makeRegionGeometry(
        _ pair: (offset: Int, element: Line)
    ) -> RegionGeometry {
        let (index, line) = pair
        return RegionGeometry(
            index: index,
            line: line,
            centerX: line.box.midX,
            centerY: line.box.midY,
            fontSize: line.orientation == .vertical
                ? max(1, line.box.width)
                : max(1, line.box.height)
        )
    }

    // Whole, independently quoted subtitle rows must remain available to source-language filtering.
    // Do not split inline Latin names/units or an ordinary quotation wrapping across rows.
    private static func areIndependentQuotedLanguages(_ a: RegionGeometry, _ b: RegionGeometry) -> Bool {
        guard a.orientation == .horizontal, b.orientation == .horizontal else { return false }
        let font = min(a.fontSize, b.fontSize)
        guard font > 0, abs(a.centerY - b.centerY) >= font * 0.6,
              abs(a.box.minX - b.box.minX) <= font,
              max(a.box.minY, b.box.minY) - min(a.box.maxY, b.box.maxY) >= -font * 0.25
        else { return false }
        func language(_ text: String) -> Int {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let first = text.first, let last = text.last,
                  text.count >= 4,
                  (first == "「" && last == "」") || (first == "『" && last == "』")
                    || (first == "\"" && last == "\"") || (first == "“" && last == "”")
            else { return 0 }
            var kana = 0, han = 0, latin = 0
            for scalar in text.unicodeScalars {
                switch scalar.value {
                case 0x3041...0x3096, 0x30A1...0x30FA: kana += 1
                case 0x3400...0x9FFF: han += 1
                case 0x41...0x5A, 0x61...0x7A: latin += 1
                default: break
                }
            }
            if kana >= 2 && kana + han > latin { return 1 }
            if kana == 0 && han == 0 && latin >= 3 { return 2 }
            return 0
        }
        let left = language(a.line.text), right = language(b.line.text)
        return left != 0 && right != 0 && left != right
    }

    /// Preserve a local gutter beside tightly packed columns. A fixed maximum
    /// gap alone makes a short independent caption join a nearby paragraph.
    private static func contrastingVerticalGutters(_ lines: [Line]) -> Set<IndexPair> {
        let ordered = lines.indices.filter { lines[$0].orientation == .vertical && lines[$0].singleVerticalColumn }
            .sorted { lines[$0].box.midX < lines[$1].box.midX }
        guard ordered.count >= 3 else { return [] }
        func gap(_ a: Int, _ b: Int) -> CGFloat? {
            let left = lines[a].box, right = lines[b].box
            let font = min(left.width, right.width)
            guard font > 0, max(left.width, right.width) <= font * 1.8,
                  abs(left.minY - right.minY) <= font * 0.75,
                  overlapRatio(left.minY, left.maxY, right.minY, right.maxY) >= 0.7 else { return nil }
            return (right.minX - left.maxX) / font
        }
        var result: Set<IndexPair> = []
        for position in 0..<(ordered.count - 1) {
            let a = ordered[position], b = ordered[position + 1]
            guard let wide = gap(a, b), wide >= 0.3 else { continue }
            let before = position > 0 ? gap(ordered[position - 1], a) : nil
            let after = position + 2 < ordered.count ? gap(b, ordered[position + 2]) : nil
            if [before, after].compactMap({ $0 }).contains(where: { $0 <= wide * 0.35 }) {
                result.insert(IndexPair(a, b))
            }
        }
        return result
    }

    private static func canFormTranslationRegion(
        _ left: RegionGeometry,
        _ right: RegionGeometry
    ) -> Bool {
        guard left.orientation == right.orientation else { return false }
        if isTallWrappedLatinContinuation(left, right) || isOrdinaryWrappedLatinContinuation(left, right) { return true }
        if isCenteredCasedContinuation(left, right) { return true }
        if isMangaVerticalContinuation(left, right) { return true }
        let smallerFont = min(left.fontSize, right.fontSize)
        let largerFont = max(left.fontSize, right.fontSize)
        guard largerFont / smallerFont <= fontSizeRatio,
              boxDistance(left.box, right.box)
                < smallerFont * regionGapInFontSizes
        else { return false }

        let primaryCenterDelta = left.orientation == .horizontal
            ? abs(left.centerY - right.centerY)
            : abs(left.centerX - right.centerX)
        guard primaryCenterDelta >= smallerFont * 0.45 else { return false }
        let normalOverlap = left.orientation == .horizontal
            ? overlapRatio(
                left.box.minY, left.box.maxY,
                right.box.minY, right.box.maxY
            )
            : overlapRatio(
                left.box.minX, left.box.maxX,
                right.box.minX, right.box.maxX
            )
        guard normalOverlap < maximumNewLinePrimaryOverlapRatio else {
            return false
        }
        let crossAxisOverlap = left.orientation == .horizontal
            ? overlapRatio(
                left.box.minX, left.box.maxX,
                right.box.minX, right.box.maxX
            )
            : overlapRatio(
                left.box.minY, left.box.maxY,
                right.box.minY, right.box.maxY
            )
        guard crossAxisOverlap >= regionCrossAxisOverlapRatio else {
            return false
        }
        let primaryGap = left.orientation == .horizontal
            ? separatedIntervalGap(
                left.box.minY, left.box.maxY,
                right.box.minY, right.box.maxY
            )
            : separatedIntervalGap(
                left.box.minX, left.box.maxX,
                right.box.minX, right.box.maxX
            )
        return primaryGap < smallerFont * regionGapInFontSizes
            && minimumRegionAlignmentDelta(left, right)
                <= smallerFont * regionAlignmentInFontSizes
    }

    /// Manga detectors often return one vertical sentence as either overlapping
    /// chunks in the same column or columns whose detected widths differ greatly.
    /// Accept those strong vertical layouts without relaxing horizontal cards.
    private static func isMangaVerticalContinuation(
        _ left: RegionGeometry,
        _ right: RegionGeometry
    ) -> Bool {
        guard left.orientation == .vertical,
              right.orientation == .vertical
        else { return false }
        let smallerFont = min(left.fontSize, right.fontSize)
        let largerFont = max(left.fontSize, right.fontSize)
        guard largerFont / smallerFont <= mangaVerticalFontSizeRatio else {
            return false
        }

        let verticalOverlap = overlapRatio(
            left.box.minY, left.box.maxY,
            right.box.minY, right.box.maxY
        )
        // Slanted vertical quads include sideways drift in their bounding box.
        // Compare each column at its midline so adjacent rows with ruby/skew
        // are not mistaken for the same column merely because the boxes overlap.
        func columnSpan(_ line: Line) -> (CGFloat, CGFloat) {
            guard line.polygon.count == 4 else { return (line.box.minX, line.box.maxX) }
            let points = line.polygon
            let start = (points[0].x + points[3].x) / 2
            let end = (points[1].x + points[2].x) / 2
            guard end > start else { return (line.box.minX, line.box.maxX) }
            return (start, end)
        }
        let leftSpan = columnSpan(left.line), rightSpan = columnSpan(right.line)
        let horizontalOverlap = overlapRatio(leftSpan.0, leftSpan.1, rightSpan.0, rightSpan.1)
        let centerDelta = abs(left.centerX - right.centerX)
        let sameColumn = horizontalOverlap >= 0.6
            && centerDelta <= largerFont * 0.5
        if sameColumn {
            if verticalOverlap < mangaVerticalSameColumnOverlapRatio {
                // A detector can split a single column at a pause (or leave only
                // a small overlap). Compare physical glyph widths, not sentence
                // heights; requiring 45% height overlap rejected these fragments.
                let upper = left.box.minY <= right.box.minY ? left : right
                let lower = left.box.minY <= right.box.minY ? right : left
                let smallWidth = min(upper.box.width, lower.box.width)
                let largeWidth = max(upper.box.width, lower.box.width)
                let next = lower.line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return upper.line.singleVerticalColumn && lower.line.singleVerticalColumn
                    && upper.line.text.count >= 2 && next.count >= 2
                    && !next.hasPrefix("「") && !next.hasPrefix("『") && !next.hasPrefix("“")
                    && largeWidth <= smallWidth * 1.6
                    && horizontalOverlap >= 0.8
                    && centerDelta <= smallWidth * 0.25
                    && lower.box.minY - upper.box.maxY <= smallWidth * 1.1
                    && upper.box.maxY < lower.box.maxY
            }
            let leftExtends = left.box.minY < right.box.minY
                || left.box.maxY > right.box.maxY
            let rightExtends = right.box.minY < left.box.minY
                || right.box.maxY > left.box.maxY
            return leftExtends && rightExtends
        }

        let columnGap = separatedIntervalGap(
            left.box.minX, left.box.maxX,
            right.box.minX, right.box.maxX
        )
        return verticalOverlap >= mangaVerticalAdjacentColumnOverlapRatio
            && horizontalOverlap < maximumNewLinePrimaryOverlapRatio
            && columnGap < smallerFont * mangaVerticalColumnGapInFontSizes
            && minimumRegionAlignmentDelta(left, right) <= smallerFont * 1.25
    }

    private static func isTallWrappedLatinContinuation(
        _ left: RegionGeometry,
        _ right: RegionGeometry
    ) -> Bool {
        guard left.orientation == .horizontal,
              right.orientation == .horizontal
        else { return false }
        let upper = left.box.minY <= right.box.minY ? left : right
        let lower = left.box.minY <= right.box.minY ? right : left
        let upperText = upper.line.text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let lowerText = lower.line.text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard isLatinWrappedText(upperText),
              isLatinWrappedText(lowerText),
              upperText.split(whereSeparator: \.isWhitespace).count >= 2,
              !hasSentenceTerminator(upperText),
              startsWithLowercaseLetter(lowerText),
              compactText(lowerText).count < compactText(upperText).count
        else { return false }

        let upperHeight = max(1, upper.box.height)
        let lowerHeight = max(1, lower.box.height)
        guard upperHeight / lowerHeight > fontSizeRatio else { return false }
        let gap = lower.box.minY - upper.box.maxY
        guard gap >= 0, gap <= lowerHeight * 0.9,
              abs(upper.box.minX - lower.box.minX) <= lowerHeight * 0.75,
              lower.box.width <= upper.box.width * 1.05
        else { return false }
        return overlapRatio(
            upper.box.minX, upper.box.maxX,
            lower.box.minX, lower.box.maxX
        ) >= 0.8
    }

    /// A lower-case continuation after an unfinished Latin sentence also gives
    /// two normal-height rows enough evidence; large/tall OCR boxes keep the
    /// existing conservative rule above.
    private static func isOrdinaryWrappedLatinContinuation(_ left: RegionGeometry, _ right: RegionGeometry) -> Bool {
        guard left.orientation == .horizontal, right.orientation == .horizontal else { return false }
        let upper = left.box.minY < right.box.minY ? left : right
        let lower = upper.index == left.index ? right : left
        let font = min(upper.fontSize, lower.fontSize)
        guard max(upper.fontSize, lower.fontSize) / font <= 1.25,
              isLatinWrappedText(upper.line.text), isLatinWrappedText(lower.line.text),
              upper.line.text.split(whereSeparator: \.isWhitespace).count >= 3,
              !hasSentenceTerminator(upper.line.text), startsWithLowercaseLetter(lower.line.text),
              abs(upper.box.minX - lower.box.minX) <= font * 0.2,
              lower.box.width <= upper.box.width * 1.05 else { return false }
        let gap = lower.box.minY - upper.box.maxY
        return gap >= 0 && gap < font * 0.75 &&
            overlapRatio(upper.box.minX, upper.box.maxX, lower.box.minX, lower.box.maxX) >= 0.8
    }

    /// Centered speech balloons have ragged left edges, and OCR glyph boxes
    /// vary with ascenders/descenders. Require matching cased scripts plus an
    /// unfinished sentence and a lowercase continuation before bridging rows.
    private static func isCenteredCasedContinuation(_ left: RegionGeometry, _ right: RegionGeometry) -> Bool {
        guard left.orientation == .horizontal, right.orientation == .horizontal else { return false }
        let upper = left.box.minY < right.box.minY ? left : right
        let lower = upper.index == left.index ? right : left
        let font = min(upper.fontSize, lower.fontSize)
        guard let script = casedWrappedScript(upper.line.text),
              script == casedWrappedScript(lower.line.text),
              max(upper.fontSize, lower.fontSize) / font <= 1.8,
              upper.line.text.split(whereSeparator: \.isWhitespace).count >= 2,
              !hasSentenceTerminator(upper.line.text), startsWithLowercaseLetter(lower.line.text),
              abs(upper.centerX - lower.centerX) <= font * 0.35,
              overlapRatio(upper.box.minX, upper.box.maxX, lower.box.minX, lower.box.maxX) >= 0.85 else { return false }
        let gap = lower.box.minY - upper.box.maxY
        return gap >= 0 && gap < font * 0.75
    }

    private static func casedWrappedScript(_ text: String) -> Int? {
        var script: Int?
        for scalar in text.unicodeScalars where isLetter(scalar) {
            let current: Int
            if isLatin(scalar) { current = 0 }
            else if (0x0370...0x03FF).contains(scalar.value) || (0x1F00...0x1FFF).contains(scalar.value) { current = 1 }
            else if (0x0400...0x052F).contains(scalar.value) { current = 2 }
            else { return nil }
            if let script, script != current { return nil }
            script = current
        }
        return script
    }

    private static func startsWithLowercaseLetter(_ text: String) -> Bool {
        guard let scalar = text.unicodeScalars.first(where: isLetter) else {
            return false
        }
        let value = String(scalar)
        return value == value.lowercased() && value != value.uppercased()
    }

    private static func minimumRegionAlignmentDelta(
        _ left: RegionGeometry,
        _ right: RegionGeometry
    ) -> CGFloat {
        if left.orientation == .horizontal {
            return min(
                abs(left.box.minX - right.box.minX),
                abs(left.box.maxX - right.box.maxX),
                abs(left.centerX - right.centerX)
            )
        }
        return min(
            abs(left.box.minY - right.box.minY),
            abs(left.box.maxY - right.box.maxY),
            abs(left.centerY - right.centerY)
        )
    }

    private static func splitSuspiciousRegion(
        _ indices: [Int],
        geometries: [RegionGeometry],
        admittedPairs: Set<IndexPair>
    ) -> [[Int]] {
        if indices.count > maximumLinesPerRegion {
            return indices.map { [$0] }
        }
        guard indices.count > 1 else { return indices.map { [$0] } }
        if indices.count == 2 {
            return admittedPairs.contains(IndexPair(indices[0], indices[1])) ? [indices] : indices.map { [$0] }
        }
        if regionIsCohesive(indices, geometries: geometries, admittedPairs: admittedPairs) {
            return [indices]
        }

        var allEdges: [WeightedRegionEdge] = []
        for leftPosition in indices.indices {
            for rightPosition in indices.indices where rightPosition > leftPosition {
                let left = indices[leftPosition]
                let right = indices[rightPosition]
                guard admittedPairs.contains(IndexPair(left, right)) else { continue }
                allEdges.append(WeightedRegionEdge(
                    left: left,
                    right: right,
                    weight: regionAnchorDistance(
                        geometries[left], geometries[right]
                    )
                ))
            }
        }
        allEdges.sort(by: regionEdgePrecedes)
        let positions = Dictionary(
            uniqueKeysWithValues: indices.enumerated().map { ($1, $0) }
        )
        let treeSet = DisjointSet(indices.count)
        var treeEdges: [WeightedRegionEdge] = []
        for edge in allEdges {
            guard let left = positions[edge.left],
                  let right = positions[edge.right],
                  treeSet.find(left) != treeSet.find(right)
            else { continue }
            treeSet.union(left, right)
            treeEdges.append(edge)
            if treeEdges.count + 1 == indices.count { break }
        }
        guard !treeEdges.isEmpty else { return indices.map { [$0] } }
        treeEdges.sort { regionEdgePrecedes($1, $0) }
        let splitSet = DisjointSet(indices.count)
        for edge in treeEdges.dropFirst() {
            if let left = positions[edge.left], let right = positions[edge.right] {
                splitSet.union(left, right)
            }
        }
        return componentsOf(indices, set: splitSet).flatMap {
            splitSuspiciousRegion($0, geometries: geometries, admittedPairs: admittedPairs)
        }
    }

    private static func regionIsCohesive(
        _ indices: [Int],
        geometries: [RegionGeometry],
        admittedPairs: Set<IndexPair>
    ) -> Bool {
        let members = indices.map { geometries[$0] }
        guard let orientation = members.first?.orientation,
              members.allSatisfy({ $0.orientation == orientation })
        else { return false }
        let fonts = members.map(\.fontSize)
        let ordered = members.sorted(by: regionReadingOrderPrecedes)
        let centeredContinuation = orientation == .horizontal && (1..<ordered.count).allSatisfy {
            isCenteredCasedContinuation(ordered[$0 - 1], ordered[$0])
        }
        let allowedFontSizeRatio = orientation == .vertical
            ? mangaVerticalFontSizeRatio
            // Ascenders/descenders can double ink height across a paragraph,
            // even when every adjacent pair meets the stricter continuation rule.
            : (centeredContinuation ? 2 : fontSizeRatio)
        guard (fonts.max() ?? 1) / (fonts.min() ?? 1)
            <= allowedFontSizeRatio else {
            return false
        }
        for index in 1..<ordered.count {
            guard admittedPairs.contains(IndexPair(ordered[index - 1].index, ordered[index].index)) else { return false }
        }
        let meanFont = fonts.reduce(0, +) / CGFloat(fonts.count)
        let anchor = members.sorted {
            let left = crossAxisSpan($0)
            let right = crossAxisSpan($1)
            return left != right ? left > right : $0.index < $1.index
        }[0]
        guard members.allSatisfy({
            minimumRegionAlignmentDelta(anchor, $0)
                <= meanFont * regionComponentAlignmentInFontSizes
        }) else { return false }

        let crossStarts = members.map { crossAxisInterval($0).0 }
        let crossEnds = members.map { crossAxisInterval($0).1 }
        let shortestCrossAxis = members.map(crossAxisSpan).min() ?? 1
        let commonCrossAxis = max(
            0,
            (crossEnds.min() ?? 0) - (crossStarts.max() ?? 0)
        )
        guard commonCrossAxis / max(1, shortestCrossAxis)
            >= regionComponentCrossAxisOverlapRatio
        else { return false }

        let bounds = unionBoxes(members.map(\.box))
        let coveredArea = members.reduce(0) { $0 + boxArea($1.box) }
        return coveredArea / max(1, boxArea(bounds))
            >= regionComponentFillRatio
    }

    private static func regionReadingOrderPrecedes(
        _ left: RegionGeometry,
        _ right: RegionGeometry
    ) -> Bool {
        if left.orientation == .horizontal {
            if left.box.minY != right.box.minY {
                return left.box.minY < right.box.minY
            }
            if left.box.minX != right.box.minX {
                return left.box.minX < right.box.minX
            }
            return left.index < right.index
        }
        if left.box.maxX != right.box.maxX {
            return left.box.maxX > right.box.maxX
        }
        if left.box.minY != right.box.minY {
            return left.box.minY < right.box.minY
        }
        return left.index < right.index
    }

    private static func mergeTranslationRegion(
        _ indices: [Int],
        geometries: [RegionGeometry],
        imageWidth: CGFloat,
        imageHeight: CGFloat
    ) -> Line {
        let members = indices.map { geometries[$0] }
        guard members.count > 1 else { return members[0].line }
        let orientation = members[0].orientation
        let oneVerticalColumn = isOneVerticalColumn(members)
        let ordered = members.sorted { left, right in
            if orientation == .horizontal {
                if left.box.minY != right.box.minY {
                    return left.box.minY < right.box.minY
                }
                if left.box.minX != right.box.minX {
                    return left.box.minX < right.box.minX
                }
                return left.index < right.index
            }
            if oneVerticalColumn {
                if left.box.minY != right.box.minY {
                    return left.box.minY < right.box.minY
                }
                if left.box.minX != right.box.minX {
                    return left.box.minX > right.box.minX
                }
                return left.index < right.index
            }
            return regionReadingOrderPrecedes(left, right)
        }
        let box = unionBoxes(ordered.map(\.box))
        let text = joinOrderedLines(
            ordered.map(\.line), orientation: orientation, fragments: false
        )
        return Line(
            index: ordered.map(\.line.index).min() ?? 0,
            text: text,
            confidence: geometricAreaWeightedConfidence(ordered),
            box: box,
            polygon: rectanglePolygon(box),
            orientationHint: orientation.source,
            orientation: orientation,
            singleVerticalColumn: orientation == .vertical && oneVerticalColumn
        )
    }

    private static func geometricAreaWeightedConfidence(
        _ members: [RegionGeometry]
    ) -> Double {
        guard members.allSatisfy({ $0.line.confidence > 0 }) else { return 0 }
        let totalArea = members.reduce(CGFloat.zero) {
            $0 + boxArea($1.box)
        }
        guard totalArea > 0 else { return 0 }
        let weightedLog = members.reduce(0.0) {
            $0 + log($1.line.confidence) * Double(boxArea($1.box))
        }
        return min(1, max(0, exp(weightedLog / Double(totalArea))))
    }

    private static func joinRegionText(_ left: String, _ right: String) -> String {
        guard !left.isEmpty else { return right }
        guard !right.isEmpty else { return left }
        let leftScalar = left.unicodeScalars.last
        let rightScalar = right.unicodeScalars.first
        let needsSpace = !(leftScalar.map(isCJKBoundary) ?? false)
            && !(rightScalar.map(isCJKBoundary) ?? false)
        return left + (needsSpace ? " " : "") + right
    }

    private static func isOneVerticalColumn(
        _ members: [RegionGeometry]
    ) -> Bool {
        let centers = members.map(\.centerX)
        let meanFont = members.map(\.fontSize).reduce(0, +)
            / CGFloat(members.count)
        return (centers.max() ?? 0) - (centers.min() ?? 0) <= meanFont * 0.5
    }

    private static func crossAxisInterval(
        _ member: RegionGeometry
    ) -> (CGFloat, CGFloat) {
        member.orientation == .horizontal
            ? (member.box.minX, member.box.maxX)
            : (member.box.minY, member.box.maxY)
    }

    private static func crossAxisSpan(_ member: RegionGeometry) -> CGFloat {
        let interval = crossAxisInterval(member)
        return interval.1 - interval.0
    }

    private static func regionAnchorDistance(
        _ left: RegionGeometry,
        _ right: RegionGeometry
    ) -> CGFloat {
        if left.orientation == .horizontal {
            return min(
                pointDistance(left.box.minX, left.box.minY,
                              right.box.minX, right.box.minY),
                pointDistance(left.box.maxX, left.box.minY,
                              right.box.maxX, right.box.minY),
                pointDistance(left.centerX, left.box.minY,
                              right.centerX, right.box.minY)
            )
        }
        return min(
            pointDistance(left.box.minX, left.box.minY,
                          right.box.minX, right.box.minY),
            pointDistance(left.box.minX, left.box.maxY,
                          right.box.minX, right.box.maxY),
            pointDistance(left.box.minX, left.centerY,
                          right.box.minX, right.centerY)
        )
    }

    private static func regionEdgePrecedes(
        _ left: WeightedRegionEdge,
        _ right: WeightedRegionEdge
    ) -> Bool {
        if left.weight != right.weight { return left.weight < right.weight }
        if left.left != right.left { return left.left < right.left }
        return left.right < right.right
    }

    private static func boxDistance(_ left: CGRect, _ right: CGRect) -> CGFloat {
        hypot(
            separatedIntervalGap(
                left.minX, left.maxX, right.minX, right.maxX
            ),
            separatedIntervalGap(
                left.minY, left.maxY, right.minY, right.maxY
            )
        )
    }

    private static func separatedIntervalGap(
        _ leftStart: CGFloat,
        _ leftEnd: CGFloat,
        _ rightStart: CGFloat,
        _ rightEnd: CGFloat
    ) -> CGFloat {
        max(0, intervalGap(leftStart, leftEnd, rightStart, rightEnd))
    }

    private static func boundingBox(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var minimumX = first.x
        var minimumY = first.y
        var maximumX = first.x
        var maximumY = first.y
        for point in points.dropFirst() {
            minimumX = min(minimumX, point.x)
            minimumY = min(minimumY, point.y)
            maximumX = max(maximumX, point.x)
            maximumY = max(maximumY, point.y)
        }
        return CGRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX,
            height: maximumY - minimumY
        )
    }

    private static func unionBoxes(_ boxes: [CGRect]) -> CGRect {
        boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }
    }

    private static func rectanglePolygon(_ box: CGRect) -> [CGPoint] {
        [
            CGPoint(x: box.minX, y: box.minY),
            CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.maxX, y: box.maxY),
            CGPoint(x: box.minX, y: box.maxY),
        ]
    }

    private static func boxArea(_ box: CGRect) -> CGFloat {
        max(0, box.width) * max(0, box.height)
    }

    private static func intersectionArea(_ left: CGRect, _ right: CGRect) -> CGFloat {
        let intersection = left.intersection(right)
        return intersection.isNull ? 0 : boxArea(intersection)
    }

    private static func pointDistance(
        _ leftX: CGFloat,
        _ leftY: CGFloat,
        _ rightX: CGFloat,
        _ rightY: CGFloat
    ) -> CGFloat {
        hypot(leftX - rightX, leftY - rightY)
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x9FFF, 0xF900...0xFAFF,
             0x20000...0x2FA1F, 0xAC00...0xD7AF:
            true
        default:
            false
        }
    }

    private static func isCJKBoundary(_ scalar: Unicode.Scalar) -> Bool {
        (0x3000...0x9FFF).contains(scalar.value)
    }

    private static func isLatin(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0041...0x005A, 0x0061...0x007A,
             0x00C0...0x024F, 0x1E00...0x1EFF:
            true
        default:
            false
        }
    }

    private static func isNumber(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .decimalNumber, .letterNumber, .otherNumber:
            true
        default:
            false
        }
    }

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter,
             .modifierLetter, .otherLetter:
            true
        default:
            false
        }
    }

    private static func isLetterOrNumber(_ scalar: Unicode.Scalar) -> Bool {
        isLetter(scalar) || isNumber(scalar)
    }

    private static func isLatinWrappedText(_ text: String) -> Bool {
        var containsLatin = false
        for scalar in text.unicodeScalars {
            if isLatin(scalar) { containsLatin = true; continue }
            if isNumber(scalar) { continue }
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark,
                 .connectorPunctuation, .dashPunctuation,
                 .openPunctuation, .closePunctuation,
                 .initialPunctuation, .finalPunctuation,
                 .otherPunctuation, .spaceSeparator, .lineSeparator,
                 .paragraphSeparator, .mathSymbol, .currencySymbol,
                 .modifierSymbol, .otherSymbol:
                continue
            default:
                return false
            }
        }
        return containsLatin
    }

    private static func hasSentenceTerminator(_ text: String) -> Bool {
        let trailing = CharacterSet(charactersIn: "\"'’”])}")
        let scalars = text.unicodeScalars
        var index = scalars.endIndex
        while index > scalars.startIndex {
            let previous = scalars.index(before: index)
            let scalar = scalars[previous]
            if trailing.contains(scalar) {
                index = previous
                continue
            }
            return scalar == "." || scalar == "!" || scalar == "?"
                || scalar.value == 0x2026
        }
        return false
    }

    private static func componentsOf(
        _ indices: [Int],
        set: DisjointSet
    ) -> [[Int]] {
        var components: [Int: [Int]] = [:]
        var rootOrder: [Int] = []
        for (position, index) in indices.enumerated() {
            let root = set.find(position)
            if components[root] == nil { rootOrder.append(root) }
            components[root, default: []].append(index)
        }
        return rootOrder.compactMap { components[$0] }
    }

    private final class DisjointSet {
        private var parent: [Int]

        init(_ length: Int) {
            parent = Array(0..<length)
        }

        func find(_ index: Int) -> Int {
            var root = index
            while parent[root] != root { root = parent[root] }
            var current = index
            while parent[current] != current {
                let next = parent[current]
                parent[current] = root
                current = next
            }
            return root
        }

        func union(_ left: Int, _ right: Int) {
            let leftRoot = find(left)
            let rightRoot = find(right)
            if leftRoot != rightRoot { parent[rightRoot] = leftRoot }
        }
    }

    private static func find(_ parent: inout [Int], _ index: Int) -> Int {
        var root = index
        while parent[root] != root { root = parent[root] }
        var current = index
        while parent[current] != current {
            let next = parent[current]
            parent[current] = root
            current = next
        }
        return root
    }
}
