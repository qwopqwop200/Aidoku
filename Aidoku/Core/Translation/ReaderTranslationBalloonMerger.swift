import CoreGraphics
import Foundation

/// Joins nearby vertical columns using enclosed background or conservative
/// shared-ink and clear-gutter evidence for translucent speech balloons.
enum ReaderTranslationBalloonMerger { // swiftlint:disable:this type_body_length
    struct SourceLine {
        let polygon: [CGPoint]
        let text: String
        let orientation: BrowserOCRSourceOrientation
    }

    static func apply(_ regions: [ReaderTranslationRegion], image: CGImage, sourceLines: [SourceLine] = [],
                      enclosure: ReaderTranslationEnclosedBackground.ComponentMap? = nil) -> [ReaderTranslationRegion] {
        apply(regions, image: image, sourceLines: sourceLines, ink: OutlinedInkMemo(image: image),
              enclosure: enclosure ?? ReaderTranslationEnclosedBackground.ComponentMap(image: image))
    }

    /// `outlinedInk` is a pure function of the image and pixel rect. One merge
    /// pass asks for the same column rect repeatedly (pairwise checks and the
    /// restarting stacked-caption scan), so it is computed once per rect.
    private final class OutlinedInkMemo {
        private struct Key: Hashable {
            let x: UInt64, y: UInt64, width: UInt64, height: UInt64
            init(_ rect: CGRect) {
                x = Double(rect.origin.x).bitPattern; y = Double(rect.origin.y).bitPattern
                width = Double(rect.size.width).bitPattern; height = Double(rect.size.height).bitPattern
            }
        }
        private let image: CGImage
        private var values: [Key: (Double, Double, Double)?] = [:]
        init(image: CGImage) { self.image = image }

        func sample(_ rect: CGRect) -> (Double, Double, Double)? {
            let key = Key(rect)
            if let cached = values[key] { return cached }
            let value = ReaderTranslationBalloonMerger.outlinedInk(in: image, rect: rect)
            values[key] = .some(value)
            return value
        }

        func matching(_ first: CGRect, _ second: CGRect) -> Bool {
            guard let a = sample(first), let b = sample(second) else { return false }
            return ReaderTranslationBalloonMerger.matching(a, b)
        }

        func different(_ first: CGRect, _ second: CGRect) -> Bool {
            guard let a = sample(first), let b = sample(second) else { return false }
            return ReaderTranslationBalloonMerger.different(a, b)
        }
    }

    private static func apply(_ regions: [ReaderTranslationRegion], image: CGImage, sourceLines: [SourceLine], ink: OutlinedInkMemo,
                              enclosure: ReaderTranslationEnclosedBackground.ComponentMap) -> [ReaderTranslationRegion] {
        // The pixel bridge/lobe checks below use upright axes. Native OCR
        // already groups rotated columns using their source quads; applying
        // these upright rules again would replace that quad with an AABB.
        let rotated = regions.filter { region in
            BrowserOverlayRotation.geometry(polygon: region.polygon.map {
                CGPoint(x: $0.x * CGFloat(image.width), y: $0.y * CGFloat(image.height))
            }, singleVerticalColumn: region.sourceSingleVerticalColumn == true) != nil
        }
        if !rotated.isEmpty {
            let ids = Set(rotated.map(\.id))
            let order = Dictionary(regions.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: min)
            return (apply(regions.filter { !ids.contains($0.id) }, image: image, sourceLines: sourceLines, ink: ink,
                          enclosure: enclosure) + rotated)
                .sorted { order[$0.id, default: 0] < order[$1.id, default: 0] }
        }
        let regions = joinParagraphBlocks(joinShortStaggeredReactions(
            joinRepeatedKanaLeadIns(
                joinStackedCaptionFragments(regions, image: image, sourceLines: sourceLines, ink: ink),
                image: image, ink: ink), image: image, ink: ink), image: image, sourceLines: sourceLines, ink: ink, enclosure: enclosure)
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let candidates = regions.filter { $0.sourceOrientation == .vertical && $0.source.count >= 2 &&
            $0.rect.height * height >= $0.rect.width * width * 1.5 }
        guard candidates.count >= 2 else { return regions }
        var groups = ReaderTranslationEnclosedBackground.enclosedRegionGroups(in: image,
            candidateInputs: candidates.map { .init(id: $0.id, text: $0.source,
                rect: CGRect(x: $0.rect.minX * width, y: $0.rect.minY * height,
                             width: $0.rect.width * width, height: $0.rect.height * height)) },
            coordinateSize: CGSize(width: width, height: height))
        // Closed-component evidence is strongest. Translucent balloons can
        // expose artwork behind one column and break that white component.
        // A clear gutter can still connect aligned, similarly sized columns.
        let enclosedCandidates = Set(groups.flatMap { $0 })
        // A connected component may span multiple balloon lobes and fail the
        // geometry checks below. Do not reserve its columns before validation:
        // doing so prevents a valid neighbouring pair from using the bridge.
        let ordered = candidates.sorted { $0.rect.midX > $1.rect.midX }
        var bridgeClaimed = Set<String>()
        for (right, left) in zip(ordered, ordered.dropFirst()) {
            guard !bridgeClaimed.contains(right.id), !bridgeClaimed.contains(left.id),
                  min(right.source.count, left.source.count) >= 2 else { continue }
            let small = min(right.rect.width, left.rect.width), large = max(right.rect.width, left.rect.width)
            let gap = right.rect.minX - left.rect.maxX
            let overlap = min(right.rect.maxY, left.rect.maxY) - max(right.rect.minY, left.rect.minY)
            let box = right.rect.union(left.rect)
            let longEnough = min(right.source.count, left.source.count) >= 3
            let mixedBlock = longEnough && ((right.sourceSingleVerticalColumn == false && left.sourceSingleVerticalColumn == true) ||
                (right.sourceSingleVerticalColumn == true && left.sourceSingleVerticalColumn == false)) &&
                large >= small * 1.8 && large <= small * 3.5 && gap <= small * 0.65 &&
                overlap >= min(right.rect.height, left.rect.height) * 0.5
            let alignedColumns = longEnough && right.sourceSingleVerticalColumn != false && left.sourceSingleVerticalColumn != false &&
                (enclosedCandidates.contains(right.id) || enclosedCandidates.contains(left.id)) &&
                large <= small * 1.6 && gap <= small * 1.2 &&
                // Leading vertical ellipses can be omitted by recognition,
                // leaving the first lexical column one or two glyphs lower.
                abs(right.rect.minY - left.rect.minY) * height <= small * width * 1.75 &&
                overlap >= min(right.rect.height, left.rect.height) * 0.75
            func pixels(_ rect: CGRect) -> CGRect { CGRect(x: rect.minX * width, y: rect.minY * height, width: rect.width * width, height: rect.height * height) }
            guard gap >= -small * 0.2, mixedBlock || alignedColumns,
                  !regions.contains(where: { $0.id != right.id && $0.id != left.id && $0.rect.intersects(box) }) else { continue }
            if ReaderTranslationEnclosedBackground.hasClearVerticalBridge(
                in: image, left: pixels(left.rect), right: pixels(right.rect)) {
                groups.append([right.id, left.id]); bridgeClaimed.formUnion([right.id, left.id])
            }
        }
        var replacements: [String: ReaderTranslationRegion] = [:], removed = Set<String>()
        var consumed = Set<String>()
        for ids in groups where (2...4).contains(ids.count) {
            guard consumed.isDisjoint(with: ids) else { continue }
            let members = candidates.filter { ids.contains($0.id) }.sorted { $0.rect.midX > $1.rect.midX }
            guard let first = members.first, let smallest = members.map({ $0.rect.width }).min(), smallest > 0,
                  members.allSatisfy({ $0.rect.width <= smallest * ($0.sourceSingleVerticalColumn == false ? 3.5 : 1.6) }) else { continue }
            var valid = true
            for (right, left) in zip(members, members.dropFirst()) {
                func pixels(_ rect: CGRect) -> CGRect { CGRect(x: rect.minX * width, y: rect.minY * height, width: rect.width * width, height: rect.height * height) }
                if separatesVerticalUtterances(right.source, box: pixels(right.rect), left.source, box: pixels(left.rect)) ||
                    ink.different(pixels(right.rect), pixels(left.rect)) ||
                    enclosure.separates(pixels(right.rect), pixels(left.rect)) ||
                    staggeredUtterances(right, left, members: members, width: width, height: height) { valid = false; break }
                let gap = right.rect.minX - left.rect.maxX
                let overlap = min(right.rect.maxY, left.rect.maxY) - max(right.rect.minY, left.rect.minY)
                if gap < -smallest * 0.2 || gap > smallest * 1.8 || overlap < min(right.rect.height, left.rect.height) * 0.5 { valid = false; break }
                // A connected white component can contain several balloon lobes.
                // Across a wide column gutter, require a clear bridge over the
                // shared text height; a narrow neck is not one text block.
                if gap > smallest * 0.6 && !ReaderTranslationEnclosedBackground.hasClearVerticalBridge(
                    in: image, left: pixels(left.rect), right: pixels(right.rect)
                ) { valid = false; break }
            }
            guard valid else { continue }
            let box = members.dropFirst().reduce(first.rect) { $0.union($1.rect) }
            guard box.width <= smallest * 7 else { continue }
            // Never jump over a column that the connected-background evidence
            // did not include. Lettering or an overlapping balloon can split
            // the white component even though the outer rectangle looks close.
            guard !regions.contains(where: { !ids.contains($0.id) && $0.rect.intersects(box) }) else { continue }
            consumed.formUnion(ids)
            let anchor = regions.first { ids.contains($0.id) }!
            var joined = ReaderTranslationRegion(id: anchor.id, rect: box,
                source: members.map(\.source).joined(), confidence: members.map(\.confidence).min() ?? 1,
                sourceImageAspectRatio: Double(width / height), sourceOrientation: .vertical,
                sourceSingleVerticalColumn: false)
            joined.auxiliaryInkRects = members.flatMap(\.auxiliaryInkRects)
            joined.auxiliaryInkPolygons = members.flatMap(\.auxiliaryInkPolygons)
            joined.polygon = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                              CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
            replacements[anchor.id] = joined
            removed.formUnion(ids.filter { $0 != anchor.id })
        }
        return regions.compactMap { removed.contains($0.id) ? nil : replacements[$0.id] ?? $0 }
    }

    /// Paragraphs of one vertical text block (a narration box, a note) are set with a
    /// blank column or two between them. Each paragraph is already one region; the block is
    /// one lettering unit in reading order. Join right-to-left neighbours whose
    /// columns share the top line and the column size, separated by a clear gutter of
    /// about one column, on the same surface and in the same ink.
    private static func joinParagraphBlocks(_ regions: [ReaderTranslationRegion], image: CGImage, sourceLines: [SourceLine],
                                            ink: OutlinedInkMemo,
                                            enclosure: ReaderTranslationEnclosedBackground.ComponentMap) -> [ReaderTranslationRegion] {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        func pixels(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX * width, y: rect.minY * height, width: rect.width * width, height: rect.height * height)
        }
        let lines = sourceLines.filter { $0.orientation == .vertical }.compactMap { line -> CGRect? in
            guard let xs = line.polygon.map(\.x).min(), let xe = line.polygon.map(\.x).max(),
                  let ys = line.polygon.map(\.y).min(), let ye = line.polygon.map(\.y).max() else { return nil }
            return CGRect(x: xs, y: ys, width: xe - xs, height: ye - ys)
        }
        // Column size: the median width of the region's own vertical lines.
        func column(_ region: ReaderTranslationRegion) -> CGFloat? {
            let box = pixels(region.rect)
            let widths = lines.filter { box.insetBy(dx: -2, dy: -2).contains($0) }.map(\.width).sorted()
            return widths.count >= 2 ? widths[widths.count / 2] : nil
        }
        let blocks = regions.filter { $0.sourceOrientation == .vertical && $0.sourceSingleVerticalColumn == false && $0.source.count >= 8 }
            .sorted { $0.rect.midX > $1.rect.midX }
        guard blocks.count >= 2 else { return regions }
        var chains: [[ReaderTranslationRegion]] = []
        for block in blocks {
            if let last = chains.last?.last, let a = column(last), let b = column(block), paragraphsContinue(
                last, block, columns: (a, b), image: image, regions: regions, ink: ink, enclosure: enclosure) {
                chains[chains.count - 1].append(block)
            } else {
                chains.append([block])
            }
        }
        var replacements: [String: ReaderTranslationRegion] = [:], removed = Set<String>()
        for members in chains where (2...6).contains(members.count) {
            let box = members.dropFirst().reduce(members[0].rect) { $0.union($1.rect) }
            guard !regions.contains(where: { region in !members.contains { $0.id == region.id } && region.rect.intersects(box) }),
                  clearBlockMargin(in: image, box: pixels(box), members: members.map { pixels($0.rect) }) else { continue }
            let anchor = regions.first { region in members.contains { $0.id == region.id } }!
            var joined = ReaderTranslationRegion(id: anchor.id, rect: box, source: members.map(\.source).joined(),
                                                 confidence: members.map(\.confidence).min() ?? 1, sourceImageAspectRatio: Double(width / height),
                                                 sourceOrientation: .vertical, sourceSingleVerticalColumn: false)
            joined.auxiliaryInkRects = members.flatMap(\.auxiliaryInkRects)
            joined.auxiliaryInkPolygons = members.flatMap(\.auxiliaryInkPolygons)
            joined.polygon = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                              CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
            replacements[anchor.id] = joined
            removed.formUnion(members.map(\.id).filter { $0 != anchor.id })
        }
        return regions.compactMap { removed.contains($0.id) ? nil : replacements[$0.id] ?? $0 }
    }

    // swiftlint:disable:next function_parameter_count
    private static func paragraphsContinue(_ right: ReaderTranslationRegion, _ left: ReaderTranslationRegion,
                                           columns: (CGFloat, CGFloat), image: CGImage, regions: [ReaderTranslationRegion],
                                           ink: OutlinedInkMemo, enclosure: ReaderTranslationEnclosedBackground.ComponentMap) -> Bool {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        func pixels(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX * width, y: rect.minY * height, width: rect.width * width, height: rect.height * height)
        }
        let a = pixels(right.rect), b = pixels(left.rect), font = min(columns.0, columns.1)
        let gap = a.minX - b.maxX, overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        guard font > 0, max(columns.0, columns.1) <= font * 1.2, gap >= font * 0.4, gap <= font * 2.1,
              abs(a.minY - b.minY) <= font * 0.6, overlap >= min(a.height, b.height) * 0.6,
              a.width >= font * 1.5, b.width >= font * 1.5 else { return false }
        let union = right.rect.union(left.rect)
        guard !regions.contains(where: { $0.id != right.id && $0.id != left.id && $0.rect.intersects(union) }),
              !separatesVerticalUtterances(right.source, box: a, left.source, box: b),
              !ink.different(a, b), !enclosure.separates(a, b) else { return false }
        return clearGutter(in: image, left: b, right: a, font: font)
    }

    /// The joined block is erased and set as one rectangle. Its area outside the paragraphs
    /// (the gutters and the corners beside a shorter paragraph) must be clear surface: a
    /// balloon border or drawing there would be covered, so such paragraphs stay apart.
    private static func clearBlockMargin(in image: CGImage, box: CGRect, members: [CGRect]) -> Bool {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let crop = image.cropping(to: box.integral.intersection(bounds)) else { return false }
        let columns = 48, rows = 48
        var gray = [UInt8](repeating: 0, count: columns * rows)
        let drawn = gray.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: columns, height: rows, bitsPerComponent: 8,
                                          bytesPerRow: columns, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: columns, height: rows))
            return true
        }
        guard drawn else { return false }
        let pad = min(box.width, box.height) * 0.03
        var margin: [Int] = []
        for row in 0..<rows {
            for column in 0..<columns {
                // The first buffer row holds the top of the drawn image.
                let point = CGPoint(x: box.minX + (CGFloat(column) + 0.5) * box.width / CGFloat(columns),
                                    y: box.minY + (CGFloat(row) + 0.5) * box.height / CGFloat(rows))
                if members.contains(where: { $0.insetBy(dx: -pad, dy: -pad).contains(point) }) { continue }
                margin.append(Int(gray[row * columns + column]))
            }
        }
        guard margin.count >= 8 else { return true }
        let median = margin.sorted()[margin.count / 2]
        return margin.filter { abs($0 - median) > 80 }.count <= margin.count / 50
    }

    /// The strip between two paragraphs holds no lettering or strong drawing: every
    /// sampled row stays near the strip's median grey (faint background sketching passes).
    private static func clearGutter(in image: CGImage, left: CGRect, right: CGRect, font: CGFloat) -> Bool {
        let top = max(left.minY, right.minY) + font * 0.2, bottom = min(left.maxY, right.maxY) - font * 0.2
        let sample = CGRect(x: left.maxX + font * 0.15, y: top, width: right.minX - left.maxX - font * 0.3, height: bottom - top).integral
        guard sample.width >= 2, sample.height >= font, sample.minX >= 0, sample.minY >= 0, sample.maxX <= CGFloat(image.width),
              sample.maxY <= CGFloat(image.height), let crop = image.cropping(to: sample) else { return false }
        let columns = 6, rows = 48
        var gray = [UInt8](repeating: 0, count: columns * rows)
        let drawn = gray.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: columns, height: rows, bitsPerComponent: 8,
                                          bytesPerRow: columns, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: columns, height: rows))
            return true
        }
        guard drawn else { return false }
        let median = Int(gray.sorted()[gray.count / 2])
        let clear = (0..<rows).filter { row in (0..<columns).allSatisfy { abs(Int(gray[row * columns + $0]) - median) <= 80 } }.count
        return clear >= rows - 3
    }

    /// One balloon lobe is one lettering unit: blocks, tails and fragments that OCR left as separate
    /// regions inside the same balloon paper are joined before translation, in reading order. Ruby-sized
    /// kana hugging a larger block is kept as erase-only ink (it repeats the block's reading).
    /// Two units join when they follow each other in reading flow within about one glyph (next row or
    /// column, a line's continuation, or an offset block of the same lobe), with only this balloon's
    /// paper between them. Tilted lettering is compared in its own baseline frame and keeps a rotated
    /// quad. Separate balloons, joined lobes (a neck), other ink, numbers and asides of another
    /// lettering size stay apart.
    ///
    /// Overlapping Latin rows are one text block on any background: tilted or handwritten
    /// asides and tight stacks whose rows the line merger interleaved ("No, I'm / just / worried." as rows
    /// 1+3 and row 2). Their quads cover the same lettering, so each would erase and plate over the other.
    /// Such a stack also takes a touching row of the same lettering, and its text is re-read from the
    /// source rows in position order.
    static func joinBalloonUnits(_ input: [ReaderTranslationRegion], image: CGImage, // swiftlint:disable:this function_body_length
                                 enclosure: ReaderTranslationEnclosedBackground.ComponentMap,
                                 sourceLines: [SourceLine] = [],
                                 separates: (CGRect, CGRect, BrowserOCRSourceOrientation) -> Bool) -> [ReaderTranslationRegion] {
        guard input.count >= 2 else { return input }
        let ink = OutlinedInkMemo(image: image)
        let width = CGFloat(image.width), height = CGFloat(image.height)
        func pixels(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX * width, y: rect.minY * height, width: rect.width * width, height: rect.height * height)
        }
        struct Unit {
            var region: ReaderTranslationRegion
            var box: CGRect
            var balloon: Int?
            var enclosed: Bool
            var letters: Int
            /// Baseline angle of tilted lettering (0 upright) and its quad in image pixels.
            var angle: CGFloat
            var points: [CGPoint]
            /// Latin-only horizontal lettering, its quad slope, and whether it is a joined overlapping stack.
            var latin: Bool
            var slope: CGFloat
            var stack = 0
            /// Full blocks (3 or more letters) joined into this unit; fragments, tails and ruby are not counted.
            var blocks: Int
        }
        func latinOnly(_ text: String) -> Bool {
            let scalars = text.unicodeScalars
            let latin = scalars.contains { (0x41...0x5A).contains($0.value) || (0x61...0x7A).contains($0.value) }
            let asian = scalars.contains { value in
                [0x3040...0x30FF, 0x3400...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF].contains { $0.contains(value.value) }
            }
            return latin && !asian
        }
        func slope(_ p: [CGPoint]) -> CGFloat {
            (atan2(p[1].y - p[0].y, p[1].x - p[0].x) + atan2(p[2].y - p[3].y, p[2].x - p[3].x)) / 2
        }
        func letterCount(_ text: String) -> Int { text.filter { !$0.isWhitespace }.count }
        func glyph(_ box: CGRect, letters: Int) -> CGFloat {
            min(min(box.width, box.height), sqrt(box.width * box.height / CGFloat(max(1, letters))))
        }
        func glyph(_ unit: Unit) -> CGFloat {
            glyph(unit.angle == 0 ? unit.box : deskewed(unit.points, by: unit.angle, around: .zero), letters: unit.letters)
        }
        /// Two Latin rows whose quads cover the same lettering: they overlap by 30 % of the smaller box and,
        /// on their mean slope, their ink bands meet and one lies over the other (80 % of the narrower).
        func interleaved(_ a: Unit, _ b: Unit) -> Bool {
            guard a.latin, b.latin, abs(a.slope - b.slope) <= 0.15 else { return false }
            let shared = a.box.intersection(b.box)
            guard !shared.isNull, shared.width * shared.height >= min(a.box.width * a.box.height, b.box.width * b.box.height) * 0.3
            else { return false }
            let theta = (a.slope + b.slope) / 2
            let f = deskewed(a.points, by: theta, around: .zero), g = deskewed(b.points, by: theta, around: .zero)
            let rows = min(f.height, g.height), narrow = min(f.width, g.width)
            return rows > 0 && narrow > 0 && max(f.minY, g.minY) - min(f.maxY, g.maxY) <= rows * 0.05 &&
                min(f.maxX, g.maxX) - max(f.minX, g.minX) >= narrow * 0.8
        }
        /// Axis-aligned bounds of a quad after removing a baseline rotation around `origin`.
        func deskewed(_ points: [CGPoint], by angle: CGFloat, around origin: CGPoint) -> CGRect {
            let c = cos(angle), s = sin(angle)
            let local = points.map { p in
                CGPoint(x: (p.x - origin.x) * c + (p.y - origin.y) * s, y: -(p.x - origin.x) * s + (p.y - origin.y) * c)
            }
            let xs = local.map(\.x), ys = local.map(\.y)
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
        /// Both members in one reading frame: page axes for upright lettering, the shared baseline for
        /// tilted lettering (angles within 0.1 rad). Nil when the baselines disagree.
        func frame(_ a: Unit, _ b: Unit) -> (a: CGRect, b: CGRect, angle: CGFloat, origin: CGPoint)? { // swiftlint:disable:this large_tuple
            if a.stack > 0 || b.stack > 0 || interleaved(a, b) {
                // An overlapping stack is measured on its quads' mean slope (rows within 0.15 rad).
                let angle = abs(a.slope - b.slope) <= 0.15 ? (a.slope + b.slope) / 2 : 0
                let origin = CGPoint(x: a.box.union(b.box).midX, y: a.box.union(b.box).midY)
                return (deskewed(a.points, by: angle, around: origin), deskewed(b.points, by: angle, around: origin), angle, origin)
            }
            guard a.angle != 0 || b.angle != 0 else { return (a.box, b.box, 0, .zero) }
            guard abs(a.angle - b.angle) <= 0.1 else { return nil }
            let angle = (a.angle * CGFloat(a.letters) + b.angle * CGFloat(b.letters)) / CGFloat(max(1, a.letters + b.letters))
            let origin = CGPoint(x: a.box.union(b.box).midX, y: a.box.union(b.box).midY)
            return (deskewed(a.points, by: angle, around: origin), deskewed(b.points, by: angle, around: origin), angle, origin)
        }
        func numeric(_ text: String) -> Bool {
            let letters = text.filter { !$0.isWhitespace }
            return !letters.isEmpty && letters.filter(\.isNumber).count * 2 >= letters.count
        }
        // Short katakana-only lettering (ガビーン, バオ) is a sound effect, not balloon speech.
        func soundEffect(_ text: String) -> Bool {
            let letters = text.filter { !$0.isWhitespace && !"!?！？…‥".contains($0) }
            return !letters.isEmpty && letters.count <= 6 && letters.unicodeScalars.allSatisfy { (0x30A1...0x30FC).contains($0.value) }
        }
        func kanaOnly(_ text: String) -> Bool {
            let letters = text.filter { !$0.isWhitespace && !"、。・…‥".contains($0) }
            return !letters.isEmpty && letters.unicodeScalars.allSatisfy { (0x3041...0x30FF).contains($0.value) }
        }
        // Punctuation OCR left without balloon evidence (!!, …) inside a joined unit is part of its lettering.
        func absorbable(_ region: ReaderTranslationRegion, into union: CGRect) -> Bool {
            let shared = region.rect.intersection(union)
            return !region.source.contains(where: { $0.isLetter || $0.isNumber }) && !shared.isNull &&
                shared.width * shared.height >= region.rect.width * region.rect.height * 0.8
        }
        var units: [Unit] = input.compactMap { region in
            let box = pixels(region.rect)
            let letters = letterCount(region.source)
            let points = region.polygon.count == 4 ? region.polygon.map { CGPoint(x: $0.x * width, y: $0.y * height) }
                : [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                   CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
            let rotation = BrowserOverlayRotation.geometry(polygon: points, singleVerticalColumn: region.sourceSingleVerticalColumn == true)
            // Tilted lettering joins only along its own baseline: horizontal rows of a slanted stack.
            let latin = region.sourceOrientation == .horizontal && latinOnly(region.source)
            guard letters > 0, !numeric(region.source), rotation == nil || region.sourceOrientation == .horizontal else { return nil }
            let balloon = enclosure.balloon(of: box)
            guard balloon != nil || latin else { return nil }
            return Unit(region: region, box: box, balloon: balloon, enclosed: enclosure.component(of: box) != nil, letters: letters,
                        angle: rotation?.radians ?? 0, points: points, latin: latin, slope: slope(points), blocks: letters >= 3 ? 1 : 0)
        }
        guard units.count >= 2 else { return input }
        let order = Dictionary(input.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: min)
        var removed = Set<String>(), replacements: [String: ReaderTranslationRegion] = [:]
        var verdicts: [String: Bool] = [:]
        // Reading order of two members under the host's orientation: vertical columns right to left,
        // then top down. Horizontal: stacked blocks top down; pieces of one line left to right; two
        // blocks side by side in one balloon right to left, as the page reads (a staggered English
        // pair "THIS IS THE ONLY..." / "SO IT MAKES SENSE..." overlaps in height but is not one line).
        func precedes(_ first: Unit, _ second: Unit, vertical: Bool) -> Bool {
            let boxes = frame(first, second)
            let a = boxes?.a ?? first.box, b = boxes?.b ?? second.box
            if vertical {
                let overlap = min(a.maxX, b.maxX) - max(a.minX, b.minX)
                return overlap >= min(a.width, b.width) * 0.5 ? a.minY < b.minY : a.midX > b.midX
            }
            let gapX = max(a.minX, b.minX) - min(a.maxX, b.maxX), gapY = max(a.minY, b.minY) - min(a.maxY, b.maxY)
            guard gapX > gapY else { return a.minY < b.minY }
            let sameLine = abs(a.midY - b.midY) <= min(glyph(first), glyph(second)) * 0.5 &&
                max(a.height, b.height) <= min(a.height, b.height) * 1.5
            return sameLine ? a.minX < b.minX : a.midX > b.midX
        }
        func sourceSize(_ unit: Unit) -> CGFloat? { BrowserOverlayTypography.sourceSize(text: unit.region.source, rect: unit.box) }
        /// Overlapping Latin rows, or a touching row absorbed by such a stack, on any background.
        func stacked(_ a: Unit, _ b: Unit) -> Bool {
            guard a.latin, b.latin, a.stack + b.stack < 6, abs(a.slope - b.slope) <= 0.15 else { return false }
            if !interleaved(a, b) {
                // A row of the aside that touches the stack without overlapping one member enough
                // ("Why is" above "he wearing / on the"): at most 0.6 of the stack and inside it by a tenth.
                guard a.stack > 0 || b.stack > 0 else { return false }
                let block = a.stack >= b.stack ? a : b, row = a.stack >= b.stack ? b : a
                let shared = row.box.intersection(block.box)
                guard !shared.isNull, shared.width * shared.height > row.box.width * row.box.height * 0.1,
                      row.box.width * row.box.height <= block.box.width * block.box.height * 0.6 else { return false }
            }
            guard let sa = sourceSize(a), let sb = sourceSize(b), max(sa, sb) <= min(sa, sb) * 2,
                  !enclosure.separates(a.box, b.box), !ink.different(a.box, b.box) else { return false }
            // Display lettering on art (a logo in two rows, comic-4064) keeps its rows: one joined box
            // would plate the art between them.
            if a.balloon == nil && b.balloon == nil && max(glyph(a), glyph(b)) > max(width, height) * 0.04 { return false }
            // The block must not reach over another caption (a neighbouring column, a label, a document).
            let union = a.region.rect.union(b.region.rect)
            return !input.contains { other in
                guard other.id != a.region.id, other.id != b.region.id, !removed.contains(other.id) else { return false }
                let shared = other.rect.intersection(union)
                return !shared.isNull && shared.width * shared.height > other.rect.width * other.rect.height * 0.1
            }
        }
        func joinable(_ a: Unit, _ b: Unit) -> (score: CGFloat, ruby: Bool)? {
            if stacked(a, b) { return (-1, false) }
            // A balloon unit is a block with its tail, fragments and ruby, or two blocks. Three or more full
            // blocks are a narration panel or paragraph box, where one joined caption loses its layout (diverse-3486).
            guard let balloon = a.balloon, balloon == b.balloon, a.enclosed || b.enclosed, a.blocks + b.blocks <= 2,
                  !(soundEffect(a.region.source) && soundEffect(b.region.source)),
                  let boxes = frame(a, b) else { return nil }
            // Reading-flow geometry in the members' own frame (`fa`, `fb`); pixel evidence on page boxes.
            let fa = boxes.a, fb = boxes.b
            let ga = glyph(fa, letters: a.letters), gb = glyph(fb, letters: b.letters), large = max(ga, gb), small = min(ga, gb)
            guard small > 0 else { return nil }
            let gapX = max(fa.minX, fb.minX) - min(fa.maxX, fb.maxX)
            let gapY = max(fa.minY, fb.minY) - min(fa.maxY, fb.maxY)
            let gap = max(gapX, gapY)
            guard gap <= large * 1.6 else { return nil }
            // Next row / column or a line's continuation: the members face each other over a third of the
            // shorter one. An offset block of the same lobe is joined only as a short aside of a paragraph
            // ("HM?" above and right of the reply), within about one glyph on both axes: two full offset
            // blocks would leave one layout box with empty corners.
            var offset = false
            // Evidence weaker than a facing block (half overlap, upright, no block inside the joined box, no
            // staircase) must also show that the balloon does not narrow into another lobe between them.
            var relaxed = boxes.angle != 0
            if gap > 0 {
                let overlap = gapX >= gapY ? min(fa.maxY, fb.maxY) - max(fa.minY, fb.minY)
                    : min(fa.maxX, fb.maxX) - max(fa.minX, fb.minX)
                if overlap < (gapX >= gapY ? min(fa.height, fb.height) : min(fa.width, fb.width)) * 0.5 { relaxed = true }
                if overlap < (gapX >= gapY ? min(fa.height, fb.height) : min(fa.width, fb.width)) * 0.3 {
                    let areas = [fa.width * fa.height, fb.width * fb.height]
                    guard gapX <= large * 1.2, gapY <= large * 1.2, areas.min()! <= areas.max()! * 0.3 else { return nil }
                    offset = true
                }
            }
            let union = a.box.union(b.box)
            // A balloon, not a panel or a page-wide paper area around distant text.
            guard let bounds = enclosure.bounds(of: balloon),
                  bounds.width * bounds.height <= union.width * union.height * 8 else { return nil }
            let normalizedUnion = a.region.rect.union(b.region.rect)
            // A third box nested in one member (ruby, a fragment) is joined on its own turn.
            func nested(_ unit: Unit) -> Bool {
                [a.box, b.box].contains { member in
                    let shared = member.intersection(unit.box)
                    return !shared.isNull && shared.width * shared.height >= unit.box.width * unit.box.height * 0.8
                }
            }
            // So is another block of the same balloon lying inside the joined box: it joins that box next.
            func enclosedBlock(_ unit: Unit) -> Bool {
                let shared = unit.region.rect.intersection(normalizedUnion)
                return unit.balloon == balloon && unit.blocks == 0 && !shared.isNull &&
                    shared.width * shared.height >= unit.region.rect.width * unit.region.rect.height * 0.8
            }
            if units.contains(where: { $0.region.id != a.region.id && $0.region.id != b.region.id &&
                $0.region.rect.intersects(normalizedUnion) && !nested($0) }) { relaxed = true }
            guard !units.contains(where: { $0.region.id != a.region.id && $0.region.id != b.region.id &&
                    $0.region.rect.intersects(normalizedUnion) && !nested($0) && !enclosedBlock($0) }),
                  !input.contains(where: { region in region.id != a.region.id && region.id != b.region.id && !removed.contains(region.id) &&
                    !units.contains(where: { $0.region.id == region.id }) && region.rect.intersects(normalizedUnion) &&
                    !absorbable(region, into: normalizedUnion) }) else { return nil }
            let smaller = ga <= gb ? a : b, larger = ga <= gb ? b : a
            let smallBox = ga <= gb ? fa : fb, largeBox = ga <= gb ? fb : fa
            // Ruby: small kana alongside a block of at least 1.5x its glyph, no longer than that block.
            // A one- or two-glyph fragment at ruby size and position is a (mis)read reading aid too.
            let rubySized = kanaOnly(smaller.region.source) ? large >= small * 1.5 : smaller.letters <= 2 && large >= small * 1.8
            let ruby = !offset && rubySized && gap <= large * 0.5 &&
                (larger.region.sourceOrientation == .vertical
                    ? smallBox.height <= largeBox.height * 1.1 && smallBox.midX > largeBox.minX + largeBox.width * 0.5
                    : smallBox.width <= largeBox.width * 1.1 && smallBox.midY < largeBox.minY + largeBox.height * 0.5)
            // Two full blocks of clearly different lettering size are a text and an aside.
            if !ruby, min(a.letters, b.letters) >= 4, large > small * 1.6 { return nil }
            let vertical = larger.region.sourceOrientation == .vertical
            if vertical, a.region.sourceOrientation == .vertical, b.region.sourceOrientation == .vertical, gapX > gapY {
                let right = a.box.midX > b.box.midX ? a : b, left = a.box.midX > b.box.midX ? b : a
                if separatesVerticalUtterances(right.region.source, box: right.box, left.region.source, box: left.box) { return nil }
                // A staircase across a wide gutter is a second utterance; neighbouring columns of one lobe
                // may start lower (a pause, a centred short column).
                if min(a.letters, b.letters) >= 4,
                   staggeredUtterances(right.region, left.region, members: [right.region, left.region], width: width, height: height) {
                    guard gapX <= small * 1.2 else { return nil }
                    relaxed = true
                }
            }
            // One lettering size (punctuation-only fragments and ruby aside): the pair may become one caption
            // of its balloon even where the union rectangle leaves the paper (diverse-2962 即死 + するんだぞ stays apart).
            let lettered = { (unit: Unit) in unit.region.source.contains { $0.isLetter || $0.isNumber } }
            let oneLettering = ruby || !lettered(smaller) || large <= small * 1.6
            // Pixel evidence is evaluated once per pair of boxes, not once per join iteration.
            let key = [a.box, b.box].map { "\($0.minX),\($0.minY),\($0.width),\($0.height)" }.joined(separator: "|") + "\(relaxed)"
            let evidence = verdicts[key] ?? {
                let value = !separates(a.box, b.box, larger.region.sourceOrientation) &&
                    !differentTextInk(in: image, first: a.box, second: b.box) &&
                    enclosure.sharesBalloonInterior(a.box, b.box, component: balloon, lobe: relaxed, oneLettering: oneLettering)
                verdicts[key] = value
                return value
            }()
            return evidence ? (max(0, gap) / large, ruby) : nil
        }
        /// The stack's source rows re-read in position order when they form one stacked column and
        /// account for exactly the members' words; otherwise the members top to bottom (`fallback`).
        func stackText(_ a: Unit, _ b: Unit, angle theta: CGFloat, fallback: [String]) -> String {
            func words(_ text: String) -> [String] {
                text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).sorted()
            }
            struct Row { let text: String; let left: CGFloat; let right: CGFloat; let y: CGFloat; let height: CGFloat }
            func sameLine(_ a: Row, _ b: Row) -> Bool { abs(a.y - b.y) <= min(a.height, b.height) * 0.5 }
            var rows: [Row] = []
            for line in sourceLines where line.polygon.count >= 3 && latinOnly(line.text) {
                let count = CGFloat(line.polygon.count)
                let center = CGPoint(x: line.polygon.reduce(CGFloat.zero) { $0 + $1.x } / count,
                                     y: line.polygon.reduce(CGFloat.zero) { $0 + $1.y } / count)
                guard a.box.contains(center) || b.box.contains(center) else { continue }
                let e = deskewed(line.polygon, by: theta, around: .zero)
                rows.append(Row(text: line.text.trimmingCharacters(in: .whitespacesAndNewlines), left: e.minX, right: e.maxX,
                                y: e.midY, height: e.height))
            }
            // Group rows into lines top to bottom (a row joins the line it shares with the line's first row),
            // then order each line left to right; a pairwise same-line comparator would not be transitive.
            var grouped: [[Row]] = []
            for row in rows.sorted(by: { $0.y < $1.y }) {
                if let first = grouped.last?.first, sameLine(row, first) {
                    grouped[grouped.count - 1].append(row)
                } else {
                    grouped.append([row])
                }
            }
            rows = grouped.flatMap { $0.sorted { $0.left < $1.left } }
            var spans: [Row] = []
            for row in rows {
                if let last = spans.last, sameLine(row, last) {
                    spans[spans.count - 1] = Row(text: "", left: min(last.left, row.left), right: max(last.right, row.right),
                                                 y: last.y, height: last.height)
                } else {
                    spans.append(row)
                }
            }
            let column = zip(spans, spans.dropFirst()).allSatisfy { a, b in
                min(a.right, b.right) - max(a.left, b.left) >= min(a.right - a.left, b.right - b.left) * 0.5
            }
            let texts = rows.map(\.text)
            if !rows.isEmpty, column, words(texts.joined(separator: " ")) == words((fallback).joined(separator: " ")) {
                return texts.filter { !$0.isEmpty }.joined(separator: " ")
            }
            return fallback.filter { !$0.isEmpty }.joined(separator: " ")
        }
        for _ in 0..<32 {
            // swiftlint:disable:next large_tuple
            var best: (i: Int, j: Int, score: CGFloat, ruby: Bool)?
            for i in units.indices {
                for j in units.indices where j > i {
                    guard let value = joinable(units[i], units[j]) else { continue }
                    if best == nil || value.score < best!.score { best = (i, j, value.score, value.ruby) }
                }
            }
            guard let best else { break }
            let a = units[best.i], b = units[best.j]
            let host = glyph(a) >= glyph(b) ? a : b, guest = host.region.id == a.region.id ? b : a
            let anchorID = order[a.region.id, default: 0] <= order[b.region.id, default: 0] ? a.region.id : b.region.id
            var rect = a.region.rect.union(b.region.rect)
            var polygon = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                           CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
            // A tilted stack keeps its baseline: the joined quad is the union in that frame, rotated back.
            let tilt = best.ruby ? host.angle : (frame(a, b)?.angle ?? 0)
            if !best.ruby, tilt != 0, let boxes = frame(a, b) {
                let local = boxes.a.union(boxes.b), c = cos(boxes.angle), s = sin(boxes.angle)
                let quad = [CGPoint(x: local.minX, y: local.minY), CGPoint(x: local.maxX, y: local.minY),
                            CGPoint(x: local.maxX, y: local.maxY), CGPoint(x: local.minX, y: local.maxY)].map {
                    CGPoint(x: boxes.origin.x + $0.x * c - $0.y * s, y: boxes.origin.y + $0.x * s + $0.y * c)
                }
                let xs = quad.map(\.x), ys = quad.map(\.y)
                let bounds = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
                    .intersection(CGRect(x: 0, y: 0, width: width, height: height))
                if !bounds.isNull, !bounds.isEmpty {
                    polygon = quad.map { CGPoint(x: $0.x / width, y: $0.y / height) }
                    rect = CGRect(x: bounds.minX / width, y: bounds.minY / height, width: bounds.width / width, height: bounds.height / height)
                }
            }
            let vertical = host.region.sourceOrientation == .vertical
            var joined: ReaderTranslationRegion
            if best.ruby {
                joined = ReaderTranslationRegion(id: anchorID, rect: host.region.rect, source: host.region.source,
                                                 polygon: host.region.polygon, confidence: host.region.confidence,
                                                 sourceImageAspectRatio: Double(width / height), sourceOrientation: host.region.sourceOrientation,
                                                 sourceSingleVerticalColumn: host.region.sourceSingleVerticalColumn)
                joined.auxiliaryInkRects = host.region.auxiliaryInkRects + [guest.region.rect] + guest.region.auxiliaryInkRects
                joined.auxiliaryInkPolygons = host.region.auxiliaryInkPolygons + [guest.region.polygon] + guest.region.auxiliaryInkPolygons
                joined.unitMemberRects = host.region.unitMemberRects
            } else {
                let first = precedes(a, b, vertical: vertical) ? a.region : b.region
                let second = first.id == a.region.id ? b.region : a.region
                let head = first.source.trimmingCharacters(in: .whitespacesAndNewlines)
                let tail = second.source.trimmingCharacters(in: .whitespacesAndNewlines)
                let latin = { (character: Character?) in character.map { $0.isASCII && !$0.isWhitespace } == true }
                let separator = latin(head.last) && latin(tail.first) && !head.hasSuffix("-") ? " " : ""
                let sameColumn = vertical && a.region.sourceSingleVerticalColumn == true && b.region.sourceSingleVerticalColumn == true &&
                    min(a.box.maxX, b.box.maxX) - max(a.box.minX, b.box.minX) >= min(a.box.width, b.box.width) * 0.8
                joined = ReaderTranslationRegion(
                    id: anchorID, rect: rect,
                    source: best.score < 0 ? stackText(a, b, angle: tilt, fallback: [head, tail]) : head + separator + tail,
                    confidence: min(a.region.confidence, b.region.confidence), sourceImageAspectRatio: Double(width / height),
                    sourceOrientation: host.region.sourceOrientation,
                    sourceSingleVerticalColumn: vertical ? sameColumn : host.region.sourceSingleVerticalColumn)
                joined.auxiliaryInkRects = first.auxiliaryInkRects + second.auxiliaryInkRects
                joined.auxiliaryInkPolygons = first.auxiliaryInkPolygons + second.auxiliaryInkPolygons
                // The members, not their union rectangle, bound the unit's erasure and plate: on an irregular
                // balloon the union's corners lie on its outline or the art beyond it.
                joined.unitMemberRects = (first.unitMemberRects.isEmpty ? [first.rect] : first.unitMemberRects) +
                    (second.unitMemberRects.isEmpty ? [second.rect] : second.unitMemberRects)
                joined.polygon = polygon
            }
            // Absorbed punctuation stays erase-only ink of the joined unit.
            let absorbed = input.filter { region in
                !removed.contains(region.id) && region.id != a.region.id && region.id != b.region.id &&
                    !units.contains(where: { $0.region.id == region.id }) && absorbable(region, into: joined.rect)
            }
            joined.auxiliaryInkRects += absorbed.map(\.rect)
            joined.auxiliaryInkPolygons += absorbed.map(\.polygon)
            removed.formUnion(absorbed.map(\.id))
            let points = best.ruby ? host.points : joined.polygon.map { CGPoint(x: $0.x * width, y: $0.y * height) }
            var merged = Unit(region: joined, box: best.ruby ? host.box : pixels(joined.rect), balloon: a.balloon ?? b.balloon,
                              enclosed: a.enclosed || b.enclosed, letters: letterCount(joined.source), angle: tilt,
                              points: points, latin: a.latin && b.latin, slope: best.ruby ? host.slope : slope(points),
                              blocks: best.ruby ? host.blocks : best.score < 0 ? max(1, a.blocks, b.blocks) : a.blocks + b.blocks)
            merged.stack = best.score < 0 ? a.stack + b.stack + 1 : 0
            let lost = anchorID == a.region.id ? b.region.id : a.region.id
            removed.insert(lost); replacements.removeValue(forKey: lost)
            replacements[anchorID] = joined
            units.remove(at: best.j); units.remove(at: best.i)
            units.append(merged)
        }
        guard !removed.isEmpty else { return input }
        return input.compactMap { removed.contains($0.id) ? nil : replacements[$0.id] ?? $0 }
    }

    /// Within one balloon a text block's columns start together (top-aligned) or are centred.
    /// A block that starts several glyphs lower and is neither centred nor bottom-aligned with
    /// its neighbour is a second utterance in a double-lobed balloon (staircase layout).
    private static func staggeredUtterances(_ right: ReaderTranslationRegion, _ left: ReaderTranslationRegion,
                                            members: [ReaderTranslationRegion], width: CGFloat, height: CGFloat) -> Bool {
        let columns = members.filter { $0.sourceSingleVerticalColumn == true }.map { $0.rect.width * width }
        // Multi-column blocks carry no glyph width; assume at least two columns each.
        let glyph = columns.min() ?? ((members.map { $0.rect.width * width }.min() ?? 0) / 2)
        // A comma at the end of the earlier block continues the same sentence.
        let previous = right.source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard glyph > 0, !previous.hasSuffix("、"), !previous.hasSuffix("，"), !previous.hasSuffix(",") else { return false }
        let a = CGRect(x: right.rect.minX * width, y: right.rect.minY * height,
                       width: right.rect.width * width, height: right.rect.height * height)
        let b = CGRect(x: left.rect.minX * width, y: left.rect.minY * height,
                       width: left.rect.width * width, height: left.rect.height * height)
        return abs(a.minY - b.minY) > glyph * 1.75 && abs(a.midY - b.midY) > glyph && abs(a.maxY - b.maxY) > glyph
    }

    /// A single repeated kana (し / しかたない, う / うん) is usually
    /// classified horizontal. Keep ruby and unrelated one-character captions
    /// separate: require the exact repeated prefix, full-sized lettering, tight
    /// top alignment and image evidence across the adjacent columns.
    private static func joinRepeatedKanaLeadIns(_ input: [ReaderTranslationRegion], image: CGImage, ink: OutlinedInkMemo) -> [ReaderTranslationRegion] {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        func pixels(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX * width, y: rect.minY * height, width: rect.width * width, height: rect.height * height)
        }
        let leads = input.filter {
            $0.source.count == 1 && $0.source.unicodeScalars.allSatisfy {
                (0x3041...0x3096).contains($0.value) || (0x30A1...0x30FA).contains($0.value)
            }
        }
        guard !leads.isEmpty else { return input }
        var replacements: [String: ReaderTranslationRegion] = [:], consumed = Set<String>()
        for column in input where column.sourceOrientation == .vertical && column.sourceSingleVerticalColumn == true &&
            column.source.count >= 2 && !consumed.contains(column.id) {
            let left = pixels(column.rect)
            for lead in leads where !consumed.contains(lead.id) && column.source.hasPrefix(lead.source) {
                let right = pixels(lead.rect), font = min(left.width, right.width)
                let box = column.rect.union(lead.rect)
                guard font > 0, right.midX > left.midX,
                      max(left.width, right.width) <= font * 1.6,
                      right.height >= font * 0.8, right.height <= font * 1.6,
                      left.height >= right.height * 1.5,
                      abs(right.minY - left.minY) <= font * 0.35,
                      right.minX - left.maxX >= -font * 0.2,
                      right.minX - left.maxX <= font * 0.35,
                      !input.contains(where: { $0.id != column.id && $0.id != lead.id && $0.rect.intersects(box) }),
                      !ink.different(left, right) else { continue }
                let bridge = ReaderTranslationEnclosedBackground.hasClearVerticalBridge(
                    in: image, left: left, right: right, minimumOverlapInFontSizes: 0.6)
                // Touching OCR padding can cover the gutter with letter ink.
                // Check the whole text block in a bounded crop so small balloons
                // retain their outline instead of disappearing at page scale.
                if !bridge {
                    // With a genuine gap, dark pixels may be a separating rule.
                    // Enclosure alone can reconnect around the ends of that rule.
                    guard right.minX <= left.maxX else { continue }
                    let union = left.union(right)
                    let cropRect = union.insetBy(dx: -max(left.width, right.width) * 6,
                        dy: -max(left.width, right.width) * 6)
                        .intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
                    guard let crop = image.cropping(to: cropRect),
                          !ReaderTranslationEnclosedBackground.enclosedRegionGroups(in: crop,
                            candidateInputs: [.init(id: column.id, text: lead.source + column.source,
                                rect: union.offsetBy(dx: -cropRect.minX, dy: -cropRect.minY))],
                            coordinateSize: CGSize(width: crop.width, height: crop.height),
                            checkingAlternateSeeds: true).isEmpty else { continue }
                }
                let anchor = input.first { $0.id == column.id || $0.id == lead.id }!
                var joined = ReaderTranslationRegion(id: anchor.id, rect: box, source: lead.source + column.source,
                    confidence: min(lead.confidence, column.confidence), sourceImageAspectRatio: Double(width / height),
                    sourceOrientation: .vertical, sourceSingleVerticalColumn: false)
                joined.auxiliaryInkRects = lead.auxiliaryInkRects + column.auxiliaryInkRects
                joined.auxiliaryInkPolygons = lead.auxiliaryInkPolygons + column.auxiliaryInkPolygons
                joined.polygon = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                                  CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
                replacements[anchor.id] = joined
                consumed.formUnion([column.id, lead.id])
                break
            }
        }
        return input.compactMap { replacements[$0.id] ?? (consumed.contains($0.id) ? nil : $0) }
    }

    /// A short vertical reaction can contain a horizontal punctuation row (!?).
    /// Its merged OCR region is then labelled horizontal. Recover only with a
    /// longer vertical neighbour, matching ink and an unobstructed bright gutter;
    /// never change the orientation of a region that remains separate.
    private static func joinShortStaggeredReactions(_ input: [ReaderTranslationRegion], image: CGImage, ink: OutlinedInkMemo) -> [ReaderTranslationRegion] {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        func pixels(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX * width, y: rect.minY * height, width: rect.width * width, height: rect.height * height)
        }
        let columns = input.filter { $0.sourceOrientation == .vertical && $0.sourceSingleVerticalColumn == true && $0.source.count >= 2 }
        let reactions = input.filter { (2...4).contains($0.source.count) && $0.source.contains(where: { "!?！？…‥".contains($0) }) }
        var replacements: [String: ReaderTranslationRegion] = [:], consumed = Set<String>()
        for column in columns where !consumed.contains(column.id) {
            for reaction in reactions where reaction.id != column.id && !consumed.contains(reaction.id) {
                let members = [column, reaction].sorted { $0.rect.midX > $1.rect.midX }
                let right = members[0], left = members[1]
                let rightBox = pixels(right.rect), leftBox = pixels(left.rect)
                let box = right.rect.union(left.rect)
                guard isShortStaggeredReaction(right, left, rightBox: rightBox, leftBox: leftBox),
                      rightBox.minX - leftBox.maxX >= -min(rightBox.width, leftBox.width) * 0.2,
                      !separatesVerticalUtterances(right.source, box: rightBox, left.source, box: leftBox),
                      !input.contains(where: { $0.id != column.id && $0.id != reaction.id && $0.rect.intersects(box) }),
                      ink.matching(rightBox, leftBox),
                      ReaderTranslationEnclosedBackground.hasClearVerticalBridge(in: image, left: leftBox, right: rightBox,
                          minimumOverlapInFontSizes: 1.25) else { continue }
                let anchor = input.first { $0.id == column.id || $0.id == reaction.id }!
                var joined = ReaderTranslationRegion(id: anchor.id, rect: box,
                    source: members.map(\.source).joined(), confidence: members.map(\.confidence).min() ?? 1,
                    sourceImageAspectRatio: Double(width / height), sourceOrientation: .vertical,
                    sourceSingleVerticalColumn: false)
                joined.auxiliaryInkRects = members.flatMap(\.auxiliaryInkRects)
                joined.auxiliaryInkPolygons = members.flatMap(\.auxiliaryInkPolygons)
                joined.polygon = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                                  CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
                replacements[anchor.id] = joined
                consumed.formUnion([column.id, reaction.id])
                break
            }
        }
        return input.compactMap { replacements[$0.id] ?? (consumed.contains($0.id) ? nil : $0) }
    }

    /// Recover a short reaction beside a longer column when OCR omitted its
    /// leading ellipsis. Requiring punctuation, Japanese text, equal glyph widths,
    /// bottom alignment, matching coloured ink and a bright gutter avoids treating
    /// arbitrary short captions or separate balloon lobes as one utterance.
    private static func isShortStaggeredReaction(
        _ right: ReaderTranslationRegion, _ left: ReaderTranslationRegion,
        rightBox: CGRect, leftBox: CGRect
    ) -> Bool {
        let rightIsShort = rightBox.height < leftBox.height
        let short = rightIsShort ? right : left
        let long = rightIsShort ? left : right
        let shortBox = rightIsShort ? rightBox : leftBox
        let longBox = rightIsShort ? leftBox : rightBox
        let font = min(rightBox.width, leftBox.width)
        let text = short.source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard long.sourceOrientation == .vertical, long.sourceSingleVerticalColumn == true,
              (short.sourceOrientation == .vertical && short.sourceSingleVerticalColumn == true) ||
                (short.sourceOrientation == .horizontal && shortBox.height >= shortBox.width * 1.5),
              font > 0, shortBox.height >= shortBox.width * 1.5, longBox.height >= longBox.width * 1.5,
              (2...4).contains(text.count),
              text.contains(where: { "!?！？…‥".contains($0) }),
              text.unicodeScalars.contains(where: { (0x3041...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value) }),
              !right.source.contains(where: { "「」『』“”".contains($0) }),
              !left.source.contains(where: { "「」『』“”".contains($0) }),
              max(rightBox.width, leftBox.width) <= font * 1.6,
              rightBox.minX - leftBox.maxX <= font * 0.6,
              shortBox.height <= font * 3, longBox.height >= shortBox.height * 1.4,
              abs(rightBox.maxY - leftBox.maxY) <= font * 0.6 else { return false }
        let overlap = min(rightBox.maxY, leftBox.maxY) - max(rightBox.minY, leftBox.minY)
        return overlap >= shortBox.height * 0.85 && overlap > font * 1.25
    }

    /// A wrapped caption can end with a centered/edge-aligned single column
    /// below its multi-column head. This is not an adjacent-column merge.
    private static func joinStackedCaptionFragments(_ input: [ReaderTranslationRegion], image: CGImage, sourceLines: [SourceLine], ink: OutlinedInkMemo) -> [ReaderTranslationRegion] {
        var result = input
        let width = CGFloat(image.width), height = CGFloat(image.height)
        func pixels(_ r: CGRect) -> CGRect { CGRect(x: r.minX * width, y: r.minY * height, width: r.width * width, height: r.height * height) }
        for head in input where head.sourceOrientation == .vertical && head.sourceSingleVerticalColumn == false {
            guard let index = result.firstIndex(where: { $0.id == head.id }) else { continue }
            let tails = result.filter { $0.id != head.id && $0.sourceOrientation == .vertical && $0.sourceSingleVerticalColumn == true }
                .sorted { $0.rect.minY < $1.rect.minY }
            for tail in tails {
                let top = pixels(result[index].rect), bottom = pixels(tail.rect), font = bottom.width
                let gap = bottom.minY - top.maxY
                let next = tail.source.trimmingCharacters(in: .whitespacesAndNewlines)
                guard font > 0, next.count >= 2, !next.hasPrefix("「"), !next.hasPrefix("『"),
                      top.width >= font * 1.4, top.width <= font * 3.5,
                      bottom.minY > top.minY, bottom.maxY > top.maxY,
                      (gap >= -font * 0.5 || continuesLastSourceColumn(head: result[index], tail: tail,
                          top: top, bottom: bottom, sourceLines: sourceLines)), gap <= font * 1.1,
                      bottom.minX >= top.minX - font * 0.2, bottom.maxX <= top.maxX + font * 0.2,
                      ink.matching(top, bottom) else { continue }
                let union = result[index].rect.union(tail.rect)
                guard !result.contains(where: { $0.id != head.id && $0.id != tail.id && $0.rect.intersects(union) }) else { continue }
                var joined = ReaderTranslationRegion(id: head.id, rect: union, source: result[index].source + tail.source,
                    confidence: min(result[index].confidence, tail.confidence), sourceImageAspectRatio: Double(width / height),
                    sourceOrientation: .vertical, sourceSingleVerticalColumn: false)
                joined.auxiliaryInkRects = result[index].auxiliaryInkRects + tail.auxiliaryInkRects
                joined.auxiliaryInkPolygons = result[index].auxiliaryInkPolygons + tail.auxiliaryInkPolygons
                joined.polygon = [CGPoint(x: union.minX, y: union.minY), CGPoint(x: union.maxX, y: union.minY),
                                  CGPoint(x: union.maxX, y: union.maxY), CGPoint(x: union.minX, y: union.maxY)]
                result[index] = joined
                // Rebuild indices after removal by id; a head may follow its tail in detector order.
                return joinStackedCaptionFragments(result.filter { $0.id != tail.id }, image: image, sourceLines: sourceLines, ink: ink)
            }
        }
        return result
    }

    // A short final column can end above the other columns in the same block.
    // Its continuation then overlaps the block's bounding box. Use the original
    // last text line, not that enclosing rectangle, to establish adjacency/order.
    private static func continuesLastSourceColumn(
        head: ReaderTranslationRegion, tail: ReaderTranslationRegion,
        top: CGRect, bottom: CGRect, sourceLines: [SourceLine]
    ) -> Bool {
        let font = bottom.width
        guard font > 0, abs(bottom.minX - top.minX) <= font * 0.2,
              bottom.maxY > top.maxY, !head.source.hasSuffix("」"), !head.source.hasSuffix("』") else { return false }
        let matches = sourceLines.filter { line in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.orientation == .vertical, text.count >= 2, head.source.hasSuffix(text),
                  !text.hasSuffix("」"), !text.hasSuffix("』"), !line.polygon.isEmpty else { return false }
            let xs = line.polygon.map(\.x), ys = line.polygon.map(\.y)
            let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            let small = min(font, box.width)
            guard small > 0, max(font, box.width) <= small * 1.6,
                  abs(box.midX - bottom.midX) <= small * 0.25,
                  min(box.maxX, bottom.maxX) - max(box.minX, bottom.minX) >= small * 0.8,
                  box.minY >= top.minY - small * 0.2,
                  box.maxY <= bottom.minY + small * 0.15,
                  bottom.minY - box.maxY <= small * 1.1 else { return false }
            return true
        }
        return matches.count == 1
    }

    /// A fresh opening quote across a visible column gutter marks a new
    /// utterance, even when OCR missed the previous utterance's closing quote.
    /// Tight/nested quotations and an ordinary wrapped continuation are unaffected.
    static func separatesVerticalUtterances(_ a: String, box aBox: CGRect, _ b: String, box bBox: CGRect) -> Bool {
        let rightFirst = aBox.midX > bBox.midX
        let right = rightFirst ? aBox : bBox, left = rightFirst ? bBox : aBox
        let previous = (rightFirst ? a : b).trimmingCharacters(in: .whitespacesAndNewlines)
        let next = (rightFirst ? b : a).trimmingCharacters(in: .whitespacesAndNewlines)
        let quoteBoundary = next.first.map { "「『“".contains($0) } == true ||
            previous.last.map { "」』”".contains($0) } == true
        let font = min(right.width, left.width)
        guard font > 0, next.count >= 3, quoteBoundary,
              right.minX - left.maxX >= font * 0.35,
              abs(right.minY - left.minY) <= font * 0.75,
              min(right.maxY, left.maxY) - max(right.minY, left.minY) >= font * 2 else { return false }
        return true
    }

    // Coloured CG captions may sit directly on artwork. Sample saturated strokes
    // next to near-white outline/fill pixels, not the dominant background colour.
    static func matchingOutlinedInk(in image: CGImage, first: CGRect, second: CGRect) -> Bool {
        guard let a = outlinedInk(in: image, rect: first), let b = outlinedInk(in: image, rect: second) else { return false }
        return matching(a, b)
    }

    static func differentOutlinedInk(in image: CGImage, first: CGRect, second: CGRect) -> Bool {
        guard let a = outlinedInk(in: image, rect: first), let b = outlinedInk(in: image, rect: second) else { return false }
        return different(a, b)
    }

    /// Whether two text lines are printed in clearly different ink (a coloured VN
    /// name tag above white or black dialogue). Inconclusive samples answer false.
    static func differentTextInk(in image: CGImage, first: CGRect, second: CGRect) -> Bool {
        guard let a = textInk(in: image, rect: first), let b = textInk(in: image, rect: second) else { return false }
        return max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2)) >= 100
    }

    static func darkFraction(in image: CGImage, rect: CGRect) -> Double? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let crop = image.cropping(to: rect.integral.intersection(bounds)) else { return nil }
        let scale = min(1, 128 / CGFloat(crop.width), 64 / CGFloat(crop.height))
        let w = Int((CGFloat(crop.width) * scale).rounded()), h = Int((CGFloat(crop.height) * scale).rounded())
        guard w >= 4, h >= 4 else { return nil }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var dark = 0
        for i in stride(from: 0, to: rgba.count, by: 4)
        where (Int(rgba[i]) * 54 + Int(rgba[i + 1]) * 183 + Int(rgba[i + 2]) * 19) >> 8 < 80 { dark += 1 }
        return Double(dark) / Double(w * h)
    }

    /// Mean colour of the most common ink bin: pixels far (>= 80 in a channel)
    /// from the line's dominant background bin. Only the leading ten glyph
    /// heights are sampled; one line keeps one ink.
    static func textInk(in image: CGImage, rect: CGRect) -> (Double, Double, Double)? { // swiftlint:disable:this large_tuple
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let leading = CGRect(x: rect.minX, y: rect.minY, width: min(rect.width, rect.height * 10), height: rect.height)
        guard let crop = image.cropping(to: leading.integral.intersection(bounds)) else { return nil }
        let scale = min(1, 512 / CGFloat(crop.width), 128 / CGFloat(crop.height))
        let w = Int((CGFloat(crop.width) * scale).rounded()), h = Int((CGFloat(crop.height) * scale).rounded())
        guard w >= 8, h >= 8 else { return nil }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        // swiftlint:disable:next large_tuple
        func dominant(_ include: (Int, Int, Int) -> Bool) -> (count: Int, color: (Double, Double, Double)) {
            var counts = [Int](repeating: 0, count: 512), sums = [Int](repeating: 0, count: 512 * 3)
            for i in stride(from: 0, to: rgba.count, by: 4) {
                let r = Int(rgba[i]), g = Int(rgba[i + 1]), b = Int(rgba[i + 2])
                guard include(r, g, b) else { continue }
                let key = (r >> 5) << 6 | (g >> 5) << 3 | b >> 5
                counts[key] += 1; sums[key * 3] += r; sums[key * 3 + 1] += g; sums[key * 3 + 2] += b
            }
            var best = 0
            for key in 1..<512 where counts[key] > counts[best] { best = key }
            let count = max(1, counts[best])
            return (counts[best], (Double(sums[best * 3]) / Double(count), Double(sums[best * 3 + 1]) / Double(count),
                                   Double(sums[best * 3 + 2]) / Double(count)))
        }
        let background = dominant { _, _, _ in true }.color
        let ink = dominant { r, g, b in
            max(abs(Double(r) - background.0), abs(Double(g) - background.1), abs(Double(b) - background.2)) >= 80
        }
        return ink.count >= 20 ? ink.color : nil
    }

    private static func matching(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Bool {
        abs(a.0 - b.0) <= 35 && abs(a.1 - b.1) <= 35 && abs(a.2 - b.2) <= 35
    }

    private static func different(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Bool {
        max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2)) >= 70
    }

    static func outlinedInk(in image: CGImage, rect: CGRect) -> (Double, Double, Double)? {
            guard let crop = image.cropping(to: rect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))) else { return nil }
            let w = min(96, crop.width), h = min(384, crop.height)
            guard w >= 4, h >= 16 else { return nil }
            var rgba = [UInt8](repeating: 0, count: w * h * 4)
            let drawn = rgba.withUnsafeMutableBytes { bytes -> Bool in
                guard let context = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8,
                    bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard drawn else { return nil }
            // 64 fixed colour bins (r/64, g/64, b/64) with summed channels and a
            // 12-bit bitmask of the vertical bands (y * 12 / h) that contain the
            // bin. This is the former Dictionary/Set accumulation without
            // per-pixel copy-on-write allocation.
            var counts = [Int](repeating: 0, count: 64)
            var sumR = [Int](repeating: 0, count: 64)
            var sumG = [Int](repeating: 0, count: 64)
            var sumB = [Int](repeating: 0, count: 64)
            var rows = [UInt16](repeating: 0, count: 64)
            let rowStride = w * 4
            rgba.withUnsafeBufferPointer { pixels in
                for y in 1..<(h - 1) {
                    let band = UInt16(1) << UInt16(y * 12 / h)
                    for x in 1..<(w - 1) {
                        let i = (y * w + x) * 4
                        let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                        let high = max(r, g, b)
                        guard high >= 110, high - min(r, g, b) >= 65 else { continue }
                        @inline(__always) func white(_ n: Int) -> Bool {
                            pixels[n] >= 200 && pixels[n + 1] >= 200 && pixels[n + 2] >= 200
                        }
                        guard white(i - 4) || white(i + 4) || white(i - rowStride) || white(i + rowStride) else { continue }
                        let key = (r / 64) * 16 + (g / 64) * 4 + b / 64
                        counts[key] += 1; sumR[key] += r; sumG[key] += g; sumB[key] += b
                        rows[key] |= band
                    }
                }
            }
            // The former `bins.values.max(by:)` kept the first maximal bin in
            // Dictionary iteration order, which depends on the per-process hash
            // seed when two bins tie. Ties now resolve to the lowest bin key;
            // every non-tied page selects exactly the same bin as before.
            var bestKey = -1
            for key in 0..<64 where counts[key] > 0 && (bestKey < 0 || counts[key] > counts[bestKey]) {
                bestKey = key
            }
            guard bestKey >= 0, counts[bestKey] >= 24, rows[bestKey].nonzeroBitCount >= 6 else { return nil }
            let best = (count: counts[bestKey], r: sumR[bestKey], g: sumG[bestKey], b: sumB[bestKey])
            // White outline antialiasing changes brightness/saturation, not the caption hue.
            let r = Double(best.r) / Double(best.count), g = Double(best.g) / Double(best.count), b = Double(best.b) / Double(best.count)
            let low = min(r, g, b), chroma = max(r, g, b) - low
            guard chroma >= 65 else { return nil }
            return ((r - low) * 255 / chroma, (g - low) * 255 / chroma, (b - low) * 255 / chroma)
    }

}
