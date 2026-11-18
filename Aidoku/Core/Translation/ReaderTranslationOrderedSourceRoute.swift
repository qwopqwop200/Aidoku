import CoreGraphics
import Foundation

/// Live OCR -> provider route. Joins ORIGINAL accepted columns before request
/// planning/cache lookup, never translated strings or localized render items.
enum ReaderTranslationOrderedSourceRoute {
    static var enabled: Bool { ProcessInfo.processInfo.environment["AIDOKU_READER_ORDERED_SOURCE_PARAGRAPH"] == "1" }
    static var sourceIntervalsEnabled: Bool { ProcessInfo.processInfo.environment["AIDOKU_READER_ORDERED_SOURCE_INTERVALS"] == "1" }
    static var anyEnabled: Bool { enabled || sourceIntervalsEnabled }
    static let cacheVersion = "ordered-original-primary-paragraph-v1"
    static var activeCacheVersion: String {
        sourceIntervalsEnabled ? "ordered-original-primary-intervals-v1:paragraph=\(enabled)" : cacheVersion
    }
    struct Support {
        let queryID: Int
        let isText: Bool
        let confidence: Double
        let normalizedBounds: CGRect
    }
    struct Result {
        let regions: [ReaderTranslationRegion]
        let joinedGroups: Int
        let joinedOwners: Int
    }
    private struct Owner {
        let index: Int
        let box: CGRect
        let glyph: CGFloat
        let support: Int
        let ink: [Double]
    }

    static func apply(_ input: [ReaderTranslationRegion], imageSize: CGSize, supports: [Support],
                      enabled: Bool = false,
                      separates: (CGRect, CGRect) -> Bool,
                      originalInk: (ReaderTranslationRegion) -> [Double]?) -> Result {
        let unchanged = Result(regions: input, joinedGroups: 0, joinedOwners: 0)
        guard enabled, (2...256).contains(input.count), supports.count <= 512,
              imageSize.width.isFinite, imageSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0, imageSize.width <= 16_384, imageSize.height <= 16_384,
              Set(input.map(\.id)).count == input.count else { return unchanged }
        func pixels(_ box: CGRect) -> CGRect {
            CGRect(x: box.minX * imageSize.width, y: box.minY * imageSize.height,
                   width: box.width * imageSize.width, height: box.height * imageSize.height)
        }
        func area(_ box: CGRect) -> CGFloat { box.isNull ? 0 : max(0, box.width) * max(0, box.height) }
        func coverage(_ box: CGRect, _ support: Support) -> CGFloat {
            area(box.intersection(support.normalizedBounds)) / max(1e-12, area(box))
        }
        let validSupports = supports.filter {
            $0.confidence.isFinite && $0.confidence >= 0.55 && area($0.normalizedBounds) > 0
        }
        var owners: [Owner] = [], sampledPixels = 0
        for (index, region) in input.enumerated() {
            guard region.translation == nil, region.sourceOrientation == .vertical, !region.isOccludedFinePrint,
                  let member = region.acceptedSource.membership, !member.hasUntrackedInputs,
                  member.unknownDedup.isEmpty, !member.body.isEmpty, member.body.count <= 16,
                  member.table.width == Int(imageSize.width), member.table.height == Int(imageSize.height),
                  member.body.allSatisfy(member.table.packets.indices.contains),
                  region.polygon.count >= 3, region.polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
                  [region.rect.minX, region.rect.minY, region.rect.maxX, region.rect.maxY].allSatisfy(\.isFinite),
                  region.rect.minX >= 0, region.rect.minY >= 0, region.rect.maxX <= 1.000000001,
                  region.rect.maxY <= 1.000000001, area(region.rect) > 0 else { continue }
            let packets = member.body.map { member.table.packets[$0] }
            guard packets.allSatisfy({ $0.orientation == .vertical && $0.score >= 0.55 &&
                $0.polygon.count >= 3 && $0.polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) }) else { continue }
            func bounds(_ points: [CGPoint]) -> CGRect {
                let xs = points.map(\.x), ys = points.map(\.y)
                return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            }
            let ordered = packets.sorted { bounds($0.polygon).midX > bounds($1.polygon).midX }
            // Revised or ambiguous composite reads require their existing source
            // recognition route; never invent a primary text concatenation.
            let originalBox = packets.reduce(CGRect.null) { $0.union(bounds($1.polygon)) }
            let regionBox = pixels(region.rect)
            guard zip([originalBox.minX, originalBox.minY, originalBox.maxX, originalBox.maxY],
                      [regionBox.minX, regionBox.minY, regionBox.maxX, regionBox.maxY])
                    .allSatisfy({ abs($0 - $1) < 1e-6 }),
                  ordered.map(\.text).joined() == region.source,
                  let glyph = packets.map({ bounds($0.polygon).width }).min(), glyph > 0 else { continue }
            let texts = validSupports.filter { $0.isText && coverage(region.rect, $0) >= 0.75 }
                .sorted { $0.confidence > $1.confidence }
            let sampleArea = Int(ceil(regionBox.width)) * Int(ceil(regionBox.height))
            guard let support = texts.first, sampleArea > 0, sampleArea <= 262_144,
                  sampledPixels <= 1_000_000 - sampleArea,
                  !validSupports.contains(where: { !$0.isText && $0.confidence >= support.confidence &&
                      coverage(region.rect, $0) >= 0.75 }) else { continue }
            sampledPixels += sampleArea
            guard let ink = originalInk(region), ink.count == 3, ink.allSatisfy(\.isFinite) else { continue }
            owners.append(Owner(index: index, box: pixels(region.rect), glyph: glyph, support: support.queryID, ink: ink))
        }
        func compatible(_ a: Owner, _ b: Owner) -> Bool {
            let glyph = (a.glyph + b.glyph) / 2
            let gap = a.box.minX - b.box.maxX
            return max(a.glyph, b.glyph) <= min(a.glyph, b.glyph) * 1.6 &&
                abs(a.box.minY - b.box.minY) <= glyph * 0.6 &&
                gap >= -glyph * 0.2 && gap <= glyph * 0.75 &&
                a.box.midX - b.box.midX >= glyph * 0.5 &&
                max(a.box.height, b.box.height) <= min(a.box.height, b.box.height) * 3 &&
                zip(a.ink, b.ink).allSatisfy({ abs($0 - $1) < 70 }) && !separates(a.box, b.box)
        }
        var groups: [[Owner]] = []
        for key in Set(owners.map(\.support)).sorted() {
            let sorted = owners.filter { $0.support == key }.sorted { $0.box.midX > $1.box.midX }
            var run: [Owner] = []
            for owner in sorted {
                if let prior = run.last, !compatible(prior, owner) { groups.append(run); run = [] }
                run.append(owner)
            }
            if !run.isEmpty { groups.append(run) }
        }
        var replacements: [Int: ReaderTranslationRegion] = [:], consumed = Set<Int>(), groupCount = 0
        for group in groups where (2...16).contains(group.count) {
            let indices = Set(group.map(\.index)), regions = group.map { input[$0.index] }
            let members = regions.compactMap { $0.acceptedSource.membership }
            guard let first = members.first, members.allSatisfy({ $0.table === first.table }),
                  members.reduce(0, { $0 + $1.body.count }) >= 3 else { continue }
            var body = Set<Int>(), disjoint = true
            for member in members {
                if !body.isDisjoint(with: member.body) { disjoint = false }
                body.formUnion(member.body)
            }
            let box = regions.reduce(CGRect.null) { $0.union($1.rect) }
            // A third unadmitted owner inside the proposed paragraph is not an
            // empty gap. Leave all owners independent rather than skip its text.
            guard disjoint, !input.indices.contains(where: { !indices.contains($0) && area(input[$0].rect.intersection(box)) > 0 }),
                  group.allSatisfy({ a in group.allSatisfy({ b in
                      a.index == b.index || abs(a.box.minY - b.box.minY) <= min(a.glyph, b.glyph) * 0.6 &&
                          zip(a.ink, b.ink).allSatisfy({ abs($0 - $1) < 70 }) && !separates(a.box, b.box)
                  }) }) else { continue }
            let anchor = indices.min()!
            var joined = ReaderTranslationRegion(id: input[anchor].id, rect: box,
                source: regions.map(\.source).joined(), confidence: regions.map(\.confidence).min()!,
                sourceImageAspectRatio: Double(imageSize.width / imageSize.height),
                sourceOrientation: .vertical, sourceSingleVerticalColumn: false)
            joined.polygon = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                              CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
            joined.unitMemberRects = regions.flatMap { $0.unitMemberRects.isEmpty ? [$0.rect] : $0.unitMemberRects }
            joined.auxiliaryInkRects = regions.flatMap(\.auxiliaryInkRects)
            joined.auxiliaryInkPolygons = regions.flatMap(\.auxiliaryInkPolygons)
            joined.detectorSeedEvidence = NativeOCRDetectorSeedEvidence.preservingUnion(regions.map(\.detectorSeedEvidence))
            joined.acceptedSource = .union(regions.map(\.acceptedSource))
            joined.sourceOCRAlternatives = regions.flatMap(\.sourceOCRAlternatives)
            joined.isRecoveredLine = regions.contains(where: \.isRecoveredLine)
            // No old target, translation cache identity, contour, display font or
            // reflow cache survives a new original source request.
            replacements[anchor] = joined
            consumed.formUnion(indices)
            groupCount += 1
        }
        return Result(regions: input.indices.compactMap { replacements[$0] ?? (consumed.contains($0) ? nil : input[$0]) },
                      joinedGroups: groupCount, joinedOwners: consumed.count)
    }

    /// Own original polygon's stable, repeated neutral dark glyph cores. Unlike
    /// a bbox two-mode histogram, white paper/halo cannot become the ink vote.
    /// Colored/unknown lettering abstains; this never assigns display colors.
    static func originalNeutralGlyphInk(_ region: ReaderTranslationRegion, image: CGImage) -> [Double]? {
        let rect = region.rect
        let scope = CGRect(x: rect.minX * CGFloat(image.width), y: rect.minY * CGFloat(image.height),
            width: rect.width * CGFloat(image.width), height: rect.height * CGFloat(image.height)).integral
        guard scope.width >= 8, scope.height >= 8, scope.width * scope.height <= 262_144,
              let crop = image.cropping(to: scope), region.polygon.count >= 3 else { return nil }
        let width = crop.width, height = crop.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        func contains(_ point: CGPoint) -> Bool {
            var hit = false
            let polygon = region.polygon
            var j = polygon.count - 1
            for i in polygon.indices {
                let a = polygon[i], b = polygon[j]
                if (a.y > point.y) != (b.y > point.y),
                   point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { hit.toggle() }
                j = i
            }
            return hit
        }
        var cores: [Int] = [], tiles = Set<Int>(), owned = 0
        for y in 1..<(height - 1) { for x in 1..<(width - 1) {
            guard contains(CGPoint(x: (scope.minX + CGFloat(x) + 0.5) / CGFloat(image.width),
                y: (scope.minY + CGFloat(y) + 0.5) / CGFloat(image.height))) else { continue }
            owned += 1
            let p = y * width + x
            let rgb = (0..<3).map { Int(rgba[p * 4 + $0]) }
            guard rgba[p * 4 + 3] >= 250, rgb.max()! <= 64, rgb.max()! - rgb.min()! <= 20,
                  [p - 1, p + 1, p - width, p + width].filter({ q in
                      (0..<3).allSatisfy { abs(Int(rgba[q * 4 + $0]) - rgb[$0]) <= 12 }
                  }).count >= 2 else { continue }
            cores.append(p); tiles.insert((y * 6 / height) * 3 + x * 3 / width)
        } }
        guard cores.count >= 64, tiles.count >= 6, cores.count * 100 < owned * 65 else { return nil }
        return (0..<3).map { channel in
            let values = cores.map { Int(rgba[$0 * 4 + channel]) }.sorted()
            return Double(values[values.count / 2])
        }
    }

    /// A nested owner is not a paragraph tail. Expand BOTH owners to the actual
    /// accepted-primary atoms, then order original column intervals, not owners.
    /// Composite/fused atoms and overlapping reads cannot be split by guessing
    /// a character offset: they remain independent for real source re-recognition.
    static func applySourceIntervals(_ input: [ReaderTranslationRegion], imageSize: CGSize, supports: [Support],
                                     enabled: Bool = false, separates: (CGRect, CGRect) -> Bool,
                                     originalInk: (ReaderTranslationRegion) -> [Double]?) -> Result {
        let unchanged = Result(regions: input, joinedGroups: 0, joinedOwners: 0)
        guard enabled, (2...256).contains(input.count), supports.count <= 512,
              imageSize.width.isFinite, imageSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0, imageSize.width <= 16_384, imageSize.height <= 16_384,
              Set(input.map(\.id)).count == input.count else { return unchanged }
        struct Atom {
            let ordinal: Int
            let packet: NativeOCRAcceptedSource.Packet
            let box: CGRect
        }
        struct Owner {
            let index: Int
            let member: NativeOCRAcceptedSource.Membership
            let atoms: [Atom]
            let box: CGRect
            let query: Int
        }
        func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : max(0, r.width) * max(0, r.height) }
        func pixels(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX * imageSize.width, y: r.minY * imageSize.height,
                   width: r.width * imageSize.width, height: r.height * imageSize.height)
        }
        func bounds(_ p: [CGPoint]) -> CGRect? {
            guard (3...16).contains(p.count), p.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
            let x = p.map(\.x), y = p.map(\.y)
            let r = CGRect(x: x.min()!, y: y.min()!, width: x.max()! - x.min()!, height: y.max()! - y.min()!)
            return area(r) > 0 ? r : nil
        }
        func coverage(_ r: CGRect, _ s: Support) -> CGFloat {
            area(r.intersection(s.normalizedBounds)) / max(1e-12, area(r))
        }
        // Complete disjoint original atoms -> column intervals -> exact source.
        func ordered(_ atoms: [Atom]) -> [Atom]? {
            guard (1...16).contains(atoms.count), Set(atoms.map(\.ordinal)).count == atoms.count else { return nil }
            var columns: [[Atom]] = []
            for atom in atoms.sorted(by: { $0.box.midX > $1.box.midX }) {
                let matches = columns.indices.filter { i in
                    columns[i].allSatisfy { other in
                        let overlap = min(atom.box.maxX, other.box.maxX) - max(atom.box.minX, other.box.minX)
                        return overlap >= min(atom.box.width, other.box.width) * 0.7 &&
                            abs(atom.box.midX - other.box.midX) <= min(atom.box.width, other.box.width) * 0.5
                    }
                }
                guard matches.count <= 1 else { return nil }
                if let index = matches.first { columns[index].append(atom) }
                else { columns.append([atom]) }
            }
            columns = columns.map { $0.sorted { $0.box.minY < $1.box.minY } }
                .sorted { $0[0].box.midX > $1[0].box.midX }
            for column in columns {
                for (a, b) in zip(column, column.dropFirst()) {
                    let glyph = min(a.box.width, b.box.width)
                    // Positive overlapping source spans need OCR alignment, not
                    // a guessed substring duplicate or target suppression.
                    guard b.box.minY >= a.box.maxY - glyph * 0.1,
                          b.box.minY - a.box.maxY <= glyph * 2 else { return nil }
                }
            }
            for (right, left) in zip(columns, columns.dropFirst()) {
                let a = right[0].box, b = left[0].box, glyph = min(a.width, b.width)
                let rightLeftEdge = right.map { $0.box.minX }.min()!
                let leftRightEdge = left.map { $0.box.maxX }.max()!
                guard max(a.width, b.width) <= glyph * 1.6,
                      rightLeftEdge - leftRightEdge >= -glyph * 0.2,
                      rightLeftEdge - leftRightEdge <= glyph * 0.75,
                      abs(a.minY - b.minY) <= glyph * 0.6 else { return nil }
            }
            return columns.flatMap { $0 }
        }
        let rf = supports.filter { $0.confidence.isFinite && $0.confidence >= 0.55 && area($0.normalizedBounds) > 0 }
        var owners: [Owner] = []
        for (index, region) in input.enumerated() {
            guard region.translation == nil, region.sourceOrientation == .vertical, !region.isOccludedFinePrint,
                  let member = region.acceptedSource.membership, !member.hasUntrackedInputs,
                  member.unknownDedup.isEmpty, (1...16).contains(member.body.count),
                  member.body.allSatisfy(member.table.packets.indices.contains),
                  member.table.width == Int(imageSize.width), member.table.height == Int(imageSize.height),
                  let polygonBox = bounds(region.polygon), area(region.rect) > 0,
                  [region.rect.minX, region.rect.minY, region.rect.maxX, region.rect.maxY].allSatisfy(\.isFinite),
                  region.rect.minX >= 0, region.rect.minY >= 0, region.rect.maxX <= 1.000000001,
                  region.rect.maxY <= 1.000000001 else { continue }
            let atoms = member.body.compactMap { ordinal -> Atom? in
                let packet = member.table.packets[ordinal]
                guard packet.orientation == .vertical, packet.score >= 0.55, !packet.text.isEmpty,
                      let box = bounds(packet.polygon) else { return nil }
                return Atom(ordinal: ordinal, packet: packet, box: box)
            }
            guard atoms.count == member.body.count, let ownOrder = ordered(atoms),
                  ownOrder.map({ $0.packet.text }).joined() == region.source else { continue }
            let originalBox = atoms.reduce(CGRect.null) { $0.union($1.box) }, box = pixels(region.rect)
            guard zip([originalBox.minX, originalBox.minY, originalBox.maxX, originalBox.maxY],
                      [box.minX, box.minY, box.maxX, box.maxY]).allSatisfy({ abs($0 - $1) < 1e-6 }),
                  polygonBox.intersection(region.rect).width > 0 else { continue }
            let text = rf.filter { $0.isText && coverage(region.rect, $0) >= 0.75 }.sorted { $0.confidence > $1.confidence }
            guard let support = text.first, !rf.contains(where: { !$0.isText &&
                $0.confidence >= support.confidence && coverage(region.rect, $0) >= 0.75 }) else { continue }
            owners.append(Owner(index: index, member: member, atoms: atoms, box: box, query: support.queryID))
        }
        var proposals: [(Int, Int, [Atom])] = []
        for parent in owners where parent.atoms.count >= 2 {
            for child in owners where parent.index != child.index && parent.query == child.query &&
                parent.member.table === child.member.table && parent.member.body.isDisjoint(with: child.member.body) {
                let intersection = parent.box.intersection(child.box)
                guard area(intersection) >= area(child.box) * 0.8,
                      area(parent.box) > area(child.box) * 1.5,
                      let sequence = ordered(parent.atoms + child.atoms) else { continue }
                let ownerOrder = [input[parent.index].source + input[child.index].source,
                                  input[child.index].source + input[parent.index].source]
                let source = sequence.map { $0.packet.text }.joined()
                // This route handles actual interval interleaving, not another
                // owner-prefix/tail concatenation path.
                guard !ownerOrder.contains(source) else { continue }
                proposals.append((parent.index, child.index, sequence))
            }
        }
        var used = Set<Int>(), replacements: [Int: ReaderTranslationRegion] = [:], sampledPixels = 0, joined = 0
        for (a, b, sequence) in proposals {
            guard !used.contains(a), !used.contains(b),
                  proposals.filter({ $0.0 == a || $0.1 == a || $0.0 == b || $0.1 == b }).count == 1 else { continue }
            let regions = [input[a], input[b]], box = regions[0].rect.union(regions[1].rect)
            guard !input.indices.contains(where: { $0 != a && $0 != b && area(input[$0].rect.intersection(box)) > 0 }),
                  !separates(pixels(regions[0].rect), pixels(regions[1].rect)) else { continue }
            let pixelCount = sequence.reduce(0) { $0 + Int(ceil($1.box.width)) * Int(ceil($1.box.height)) }
            guard pixelCount <= 1_000_000, sampledPixels <= 1_000_000 - pixelCount else { continue }
            sampledPixels += pixelCount
            // Parent envelopes contain the child's pixels. Measure EACH actual
            // primary polygon instead, so a peer's ink cannot become its truth.
            let palettes = sequence.compactMap { atom -> [Double]? in
                let r = atom.box
                let normalized = CGRect(x: r.minX / imageSize.width, y: r.minY / imageSize.height,
                    width: r.width / imageSize.width, height: r.height / imageSize.height)
                let own = ReaderTranslationRegion(id: input[a].id, rect: normalized, source: atom.packet.text,
                    polygon: atom.packet.polygon.map { CGPoint(x: $0.x / imageSize.width, y: $0.y / imageSize.height) },
                    confidence: atom.packet.score, sourceOrientation: .vertical)
                guard let value = originalInk(own), value.count == 3, value.allSatisfy(\.isFinite) else { return nil }
                return value
            }
            guard palettes.count == sequence.count, palettes.allSatisfy({ x in
                palettes.allSatisfy { y in zip(x, y).allSatisfy({ abs($0 - $1) < 70 }) }
            }) else { continue }
            let anchor = min(a, b)
            var revised = ReaderTranslationRegion(id: input[anchor].id, rect: box,
                source: sequence.map { $0.packet.text }.joined(), confidence: regions.map(\.confidence).min()!,
                sourceImageAspectRatio: Double(imageSize.width / imageSize.height), sourceOrientation: .vertical,
                sourceSingleVerticalColumn: false)
            revised.polygon = input[a].polygon
            revised.unitMemberRects = regions.flatMap { $0.unitMemberRects.isEmpty ? [$0.rect] : $0.unitMemberRects }
            revised.auxiliaryInkRects = regions.flatMap(\.auxiliaryInkRects)
            revised.auxiliaryInkPolygons = regions.flatMap(\.auxiliaryInkPolygons) + sequence.flatMap { atom in
                ([atom.packet.polygon] + atom.packet.erasurePolygons).map { polygon in
                    polygon.map { CGPoint(x: $0.x / imageSize.width, y: $0.y / imageSize.height) }
                }
            }
            revised.detectorSeedEvidence = NativeOCRDetectorSeedEvidence.preservingUnion(regions.map(\.detectorSeedEvidence))
            revised.acceptedSource = .union(regions.map(\.acceptedSource))
            revised.sourceOCRAlternatives = regions.flatMap(\.sourceOCRAlternatives)
            revised.isRecoveredLine = regions.contains(where: \.isRecoveredLine)
            replacements[anchor] = revised; used.formUnion([a, b]); joined += 1
        }
        return Result(regions: input.indices.compactMap { replacements[$0] ?? (used.contains($0) ? nil : input[$0]) },
                      joinedGroups: joined, joinedOwners: used.count)
    }
}
