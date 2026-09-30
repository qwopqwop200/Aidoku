import CoreGraphics
import Foundation

/// Clean paper of the closed balloon (or caption box) that holds one caption, measured natively
/// once per page. Normalized image coordinates. `spans` holds, for each of the equal bands of
/// `rect` (top to bottom), the [left, right] run of paper through the caption's centre column, or
/// [-1, -1] where other ink or the outline cuts it. A balloon shared by several captions carries
/// `members` (their count); every member holds the same interior, measured around their union.
struct ReaderTranslationBalloonInterior: Codable, Equatable, Sendable {
    let rect: CGRect
    let center: CGPoint
    let spans: [Double]
    var members: Int?
    var contourVerified: Bool?

    /// The same interior in a crop's normalized coordinates, if the crop holds all of it.
    func cropped(to crop: CGRect) -> Self? {
        guard crop.width > 0, crop.height > 0, crop.insetBy(dx: -0.000_01, dy: -0.000_01).contains(rect) else { return nil }
        return Self(rect: CGRect(x: (rect.minX - crop.minX) / crop.width, y: (rect.minY - crop.minY) / crop.height,
                                 width: rect.width / crop.width, height: rect.height / crop.height),
                    center: CGPoint(x: (center.x - crop.minX) / crop.width, y: (center.y - crop.minY) / crop.height),
                    spans: spans.map { $0 < 0 ? $0 : ($0 - Double(crop.minX)) / Double(crop.width) }, members: members, contourVerified: contourVerified)
    }

    var payload: [String: Any] {
        ["rect": [rect.minX, rect.minY, rect.width, rect.height], "center": [center.x, center.y], "spans": spans, "contourVerified": contourVerified == true]
    }
}

/// Bounded light-background components used only for conservative column merging.
enum ReaderTranslationEnclosedBackground { // swiftlint:disable:this type_body_length
    /// Adds each caption's balloon interior (see `ComponentMap.balloonInteriors`), reusing the
    /// page's component map when OCR grouping already built one.
    static func attachingBalloonInteriors(_ regions: [ReaderTranslationRegion], image: CGImage,
                                          map: ComponentMap? = nil) -> [ReaderTranslationRegion] {
        guard !regions.isEmpty, image.width > 0, image.height > 0 else { return regions }
        let map = map ?? ComponentMap(image: image)
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let rects = regions.map {
            CGRect(x: $0.rect.minX * width, y: $0.rect.minY * height, width: $0.rect.width * width, height: $0.rect.height * height)
        }
        // Vertical or narrow sources: their OCR column, not their balloon, bounds the translation.
        let interiors = map.balloonInteriors(of: rects, candidates: zip(regions, rects).map { region, rect in
            region.unitMemberRects.isEmpty && (region.sourceOrientation == .vertical || rect.width <= rect.height * 1.2)
        })
        return zip(regions, interiors).map { region, interior in
            var result = region
            // A joined unit's balloon bounds its erasure, plate and lettering (not the union rectangle). A unit
            // whose balloon is not balloon-shaped keeps the interior it shares with the balloon's other captions.
            result.balloonInterior = region.unitMemberRects.isEmpty ? interior : map.unitInterior(members: region.unitMemberRects.map {
                CGRect(x: $0.minX * width, y: $0.minY * height, width: $0.width * width, height: $0.height * height)
            }) ?? interior
            return result
        }
    }

    private struct Component {
        let count: Int
        let minimumPoint: Int
        let minX: Int, maxX: Int, minY: Int, maxY: Int
    }
    struct Input { let id: String; let text: String; let rect: CGRect }
    static func enclosedRegionGroups(in image: CGImage,
                                    candidateInputs candidates: [Input],
                                    coordinateSize: CGSize, checkingAlternateSeeds: Bool = false,
                                    reusingCompletedComponents: Bool = true) -> [[String]] {
        guard coordinateSize.width > 0, coordinateSize.height > 0,
              coordinateSize.width.isFinite, coordinateSize.height.isFinite else { return [] }
        guard !candidates.isEmpty else { return [] }
        let scale = min(1, 512 / CGFloat(max(image.width, image.height)))
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        var pixels = [UInt8](repeating: 255, count: width * height)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return [] }
        var labels = [Int](repeating: -1, count: reusingCompletedComponents ? pixels.count : 0)
        var components: [Component] = []
        var groups: [Int: [String]] = [:]
        // One visit-stamp buffer shared by every flood of this call: a pixel is
        // "seen" by the current flood iff its stamp equals that flood's
        // generation. Equivalent to a fresh [Bool] per seed, without the
        // per-seed full-image allocation.
        var visits = FloodVisits()
        for input in candidates.prefix(64) {
            guard !Task.isCancelled else { return [] }
            let rect = CGRect(x: input.rect.minX / coordinateSize.width * CGFloat(width),
                              y: input.rect.minY / coordinateSize.height * CGFloat(height),
                              width: input.rect.width / coordinateSize.width * CGFloat(width),
                              height: input.rect.height / coordinateSize.height * CGFloat(height))
            if let component = enclosed(rect, pixels: pixels, width: width, height: height, checkingAlternateSeeds: checkingAlternateSeeds, labels: &labels, components: &components, visits: &visits) { groups[component, default: []].append(input.id) }
        }
        return groups.keys.sorted().map { groups[$0]! }
    }

    /// Page-level light components (speech balloons, caption boxes), rasterized and labelled
    /// lazily, at most once per pixel. A text box belongs to the bounded light component that holds
    /// most of the paper between its glyph strokes and clearly exceeds the box (not an outline halo).
    /// `separates` is a veto for OCR grouping; artwork, tone and open outlines abstain.
    final class ComponentMap { // swiftlint:disable:this type_body_length
        private struct Stats {
            var count = 0
            var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
            var touchesEdge = false
        }
        private struct Key: Hashable {
            let x: Double, y: Double, width: Double, height: Double
        }
        private var image: CGImage?
        private let imageWidth: CGFloat, imageHeight: CGFloat
        private var width = 0, height = 0
        private var pixels: [UInt8] = []
        private var labels: [Int32] = []
        private var stats: [Stats] = []
        private struct Surface {
            let enclosing: Int?
            /// The enclosing paper also rings the text box (not only fills its gaps).
            let surrounded: Bool
            let dominant: Int?
            let dominantCount: Int
            let lightCount: Int
            let area: Int
            let tally: [Int: Int]
            /// The dominant paper is balloon-shaped (see `resolve`), even when open at the image edge
            /// or too small against a wide text box to count as `enclosing`; with the ring share around the box.
            var balloon: Int?
            var ring: Double = 0
            /// `enclosing`, or for dense lettering that leaves under 30 % paper inside its box, the bounded
            /// component that still dominates the paper between its strokes (balloon units, `balloon(of:)`).
            var letteringBalloon: Int?
        }
        private var cache: [Key: Surface] = [:]

        init(image: CGImage) {
            self.image = image
            imageWidth = CGFloat(image.width)
            imageHeight = CGFloat(image.height)
        }

        /// Different enclosing components, or text ringed by a balloon joined with text printed on
        /// another single light surface outside that balloon (a caption or page margin beside it).
        func separates(_ first: CGRect, _ second: CGRect) -> Bool {
            guard let a = surface(of: first), let b = surface(of: second) else { return false }
            if let x = a.enclosing, let y = b.enclosing { return x != y }
            func outside(_ text: Surface, _ balloon: Surface) -> Bool {
                guard balloon.surrounded, let id = balloon.enclosing, let other = text.dominant, other != id else { return false }
                return text.lightCount * 20 >= text.area * 3 && text.tally[id, default: 0] * 3 < text.lightCount &&
                    text.dominantCount * 10 >= text.lightCount * 6
            }
            if a.enclosing != nil, outside(b, a) { return true }
            if b.enclosing != nil, outside(a, b) { return true }
            return differentBalloons(a, b)
        }

        /// Text on two different balloon-shaped papers, each box mostly on its own paper and ringed by it
        /// (one clearly): a small balloon drawn over or inside a larger one, whose outline separates them
        /// even where one paper runs off the image edge (diverse2-3055).
        private func differentBalloons(_ a: Surface, _ b: Surface) -> Bool {
            guard let x = a.balloon, let y = b.balloon, x != y,
                  min(a.ring, b.ring) >= 0.4, max(a.ring, b.ring) >= 0.7 else { return false }
            return a.tally[y, default: 0] * 3 < a.lightCount && b.tally[x, default: 0] * 3 < b.lightCount
        }

        func component(of rect: CGRect) -> Int? {
            surface(of: rect)?.enclosing
        }

        /// The text box is printed on open light paper: at least 30 % of the box is light, most of that
        /// on one component at least twice the box's area, and that paper rings the box (a thin ring 0.15
        /// glyph outside it lies on the same component for `ring` of its length). Lettering over artwork,
        /// tone or a coloured surface has no such paper, and its erase would need a plate over the art.
        func onOpenPaper(_ rect: CGRect, ring: Double = 0.6) -> Bool {
            guard let value = surface(of: rect), let id = value.dominant, stats.indices.contains(id),
                  value.lightCount * 10 >= value.area * 3, value.dominantCount * 10 >= value.lightCount * 6,
                  stats[id].count >= value.area * 2, width > 0, height > 0 else { return false }
            let sx = CGFloat(width) / imageWidth, sy = CGFloat(height) / imageHeight
            let x0 = Int((rect.minX * sx).rounded()), y0 = Int((rect.minY * sy).rounded())
            let x1 = Int((rect.maxX * sx).rounded()) - 1, y1 = Int((rect.maxY * sy).rounded()) - 1
            return ringShare(id, x0: x0, y0: y0, x1: x1, y1: y1) >= ring
        }

        /// Enclosing balloon of a text box, including dense lettering whose box shows little paper.
        func balloon(of rect: CGRect) -> Int? {
            surface(of: rect)?.letteringBalloon
        }

        /// Bounds of a resolved component in image coordinates.
        func bounds(of id: Int) -> CGRect? {
            guard stats.indices.contains(id), width > 0, height > 0 else { return nil }
            let value = stats[id], sx = imageWidth / CGFloat(width), sy = imageHeight / CGFloat(height)
            return CGRect(x: CGFloat(value.minX) * sx, y: CGFloat(value.minY) * sy,
                          width: CGFloat(value.maxX - value.minX + 1) * sx, height: CGFloat(value.maxY - value.minY + 1) * sy)
        }

        /// Two text boxes inside balloon `id` face each other across its paper: the band between them is
        /// almost only that paper (no outline or artwork crosses it) and the balloon does not narrow
        /// there, which separates two lobes of a joined balloon from one lobe holding two blocks.
        /// `lobe` (joins on weaker reading-flow evidence) also rejects a neck narrower than 0.8 of the
        /// larger lobe: a notch between two lobes of one outline, or a bubble chain. `oneLettering`: the two boxes
        /// share one lettering size, so the balloon may hold them as one caption even where their union rectangle
        /// leaves its paper (see `unitFitsBalloon`).
        func sharesBalloonInterior(_ first: CGRect, _ second: CGRect, component id: Int, lobe: Bool = false,
                                   oneLettering: Bool = false) -> Bool {
            guard stats.indices.contains(id), width > 0, height > 0 else { return false }
            let sx = CGFloat(width) / imageWidth, sy = CGFloat(height) / imageHeight
            let a = CGRect(x: first.minX * sx, y: first.minY * sy, width: first.width * sx, height: first.height * sy)
            let b = CGRect(x: second.minX * sx, y: second.minY * sy, width: second.width * sx, height: second.height * sy)
            let gapX = max(a.minX, b.minX) - min(a.maxX, b.maxX), gapY = max(a.minY, b.minY) - min(a.maxY, b.maxY)
            // The joined rectangle is a layout and cleanup box: it must stay on this balloon's paper or
            // the members' own lettering, not reach over artwork around two touching boxes.
            let union = a.union(b)
            let ux0 = max(0, Int(union.minX.rounded())), ux1 = min(width, Int(union.maxX.rounded()))
            let uy0 = max(0, Int(union.minY.rounded())), uy1 = min(height, Int(union.maxY.rounded()))
            guard ux1 > ux0, uy1 > uy0 else { return false }
            // Translucent artwork can split a balloon's light paper. Track bounded
            // secondary patches already occupied by this lettering, without treating
            // dark contours or unrelated light areas as the balloon's outer edge.
            var memberPaper: [Int32: Int] = [:], borderComponents: [Int32: Int] = [:]
            var covered = 0, border = 0, borderPaper = 0
            for y in uy0..<uy1 {
                for x in ux0..<ux1 {
                    let point = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                    let label = labels[y * width + x]
                    let paper = label == Int32(id), member = a.contains(point) || b.contains(point)
                    if oneLettering, member, label >= 0, !paper { memberPaper[label, default: 0] += 1 }
                    if paper || member { covered += 1 }
                    // The joined rectangle's own edge beyond the members: where it runs on the balloon paper, the
                    // rectangle cannot cut a corner of an irregular balloon (its outline) or reach over art beside
                    // open lettering (comic-2347, comic-0538, comic-2691).
                    if !member, x == ux0 || x == ux1 - 1 || y == uy0 || y == uy1 - 1 {
                        border += 1
                        if paper { borderPaper += 1 }
                        else if oneLettering, label >= 0 { borderComponents[label, default: 0] += 1 }
                    }
                }
            }
            for (label, count) in memberPaper {
                let patch = stats[Int(label)], host = stats[id]
                guard !patch.touchesEdge, count * 5 >= patch.count,
                      patch.minX >= host.minX, patch.maxX <= host.maxX,
                      patch.minY >= host.minY, patch.maxY <= host.maxY else { continue }
                borderPaper += borderComponents[label, default: 0]
            }
            // A rectangle that leaves the paper is safe when the balloon itself can hold the unit: the overlay then
            // erases, plates and letters the unit inside the balloon's interior (`unitInterior`), not the rectangle.
            guard covered * 100 >= (ux1 - ux0) * (uy1 - uy0) * 85,
                  borderPaper * 100 >= border * 95 || oneLettering && unitFitsBalloon([first, second], component: id) else { return false }
            guard gapX > 1 || gapY > 1 else { return true }
            let sideBySide = gapX > gapY
            let band = sideBySide
                ? CGRect(x: min(a.maxX, b.maxX), y: max(a.minY, b.minY), width: gapX, height: min(a.maxY, b.maxY) - max(a.minY, b.minY))
                : CGRect(x: max(a.minX, b.minX), y: min(a.maxY, b.maxY), width: min(a.maxX, b.maxX) - max(a.minX, b.minX), height: gapY)
            let x0 = max(0, Int(band.minX.rounded())), x1 = min(width, Int(band.maxX.rounded()))
            let y0 = max(0, Int(band.minY.rounded())), y1 = min(height, Int(band.maxY.rounded()))
            if x1 > x0, y1 > y0 {
                var inside = 0
                for y in y0..<y1 { for x in x0..<x1 where labels[y * width + x] == Int32(id) { inside += 1 } }
                guard inside * 100 >= (x1 - x0) * (y1 - y0) * 97 else { return false }
            } else {
                // Offset blocks face no band: the straight path between their centres must stay on this paper.
                let steps = max(1, Int(max(abs(a.midX - b.midX), abs(a.midY - b.midY))))
                var outside = 0, onPaper = 0
                for step in 0...steps {
                    let t = CGFloat(step) / CGFloat(steps)
                    let point = CGPoint(x: a.midX + (b.midX - a.midX) * t, y: a.midY + (b.midY - a.midY) * t)
                    guard !a.contains(point), !b.contains(point) else { continue }
                    let x = min(width - 1, max(0, Int(point.x))), y = min(height - 1, max(0, Int(point.y)))
                    outside += 1
                    if labels[y * width + x] == Int32(id) { onPaper += 1 }
                }
                guard onPaper * 100 >= outside * 97 else { return false }
            }
            // Extent of the balloon across the reading gap versus through each text box.
            let value = stats[id]
            func extent(at position: CGFloat) -> Int {
                var low = Int.max, high = Int.min
                if sideBySide {
                    let x = min(width - 1, max(0, Int(position)))
                    for y in value.minY...value.maxY where labels[y * width + x] == Int32(id) { low = min(low, y); high = max(high, y) }
                } else {
                    let y = min(height - 1, max(0, Int(position)))
                    for x in value.minX...value.maxX where labels[y * width + x] == Int32(id) { low = min(low, x); high = max(high, x) }
                }
                return high >= low ? high - low + 1 : 0
            }
            let neck = extent(at: sideBySide ? (band.minX + band.maxX) / 2 : (band.minY + band.maxY) / 2)
            let first = extent(at: sideBySide ? a.midX : a.midY), second = extent(at: sideBySide ? b.midX : b.midY)
            return neck * 10 >= min(first, second) * 7 && (!lobe || neck * 10 >= max(first, second) * 8)
        }

        private func surface(of rect: CGRect) -> Surface? {
            let key = Key(x: Double(rect.minX), y: Double(rect.minY), width: Double(rect.width), height: Double(rect.height))
            if let cached = cache[key] { return cached }
            guard let value = resolve(rect) else { return nil }
            cache[key] = value
            return value
        }

        private func rasterize() {
            guard let image else { return }
            self.image = nil
            // About two megapixels keeps 1-2 px balloon outlines as barriers on ordinary pages.
            let scale = min(1, sqrt(2_000_000 / max(1, imageWidth * imageHeight)))
            width = max(1, Int(imageWidth * scale)); height = max(1, Int(imageHeight * scale))
            var data = [UInt8](repeating: 255, count: width * height)
            let rendered = data.withUnsafeMutableBytes { bytes -> Bool in
                guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: width,
                                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
                context.setFillColor(gray: 1, alpha: 1)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.interpolationQuality = .medium
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard rendered else { return }
            pixels = data
            labels = [Int32](repeating: -1, count: data.count)
        }

        private func label(at seed: Int) -> Int {
            if labels[seed] >= 0 { return Int(labels[seed]) }
            let id = Int32(stats.count)
            var value = Stats()
            var queue = [seed]
            // Queue horizontal runs instead of every pixel of the same light surface.
            // Pending seeds are -2; completed runs retain the original component ID.
            labels[seed] = -2
            var cursor = 0
            while cursor < queue.count {
                let point = queue[cursor]; cursor += 1
                if labels[point] >= 0 { continue }
                let y = point / width, row = y * width
                var left = point, right = point
                while left > row, labels[left - 1] < 0, pixels[left - 1] >= Self.light { left -= 1 }
                while right < row + width - 1, labels[right + 1] < 0, pixels[right + 1] >= Self.light { right += 1 }
                for index in left...right { labels[index] = id }
                value.count += right - left + 1
                value.minX = min(value.minX, left - row); value.maxX = max(value.maxX, right - row)
                value.minY = min(value.minY, y); value.maxY = max(value.maxY, y)
                if left == row || right == row + width - 1 || y == 0 || y == height - 1 { value.touchesEdge = true }
                for offset in [-width, width] where y + offset / width >= 0 && y + offset / width < height {
                    var next = left + offset
                    let end = right + offset
                    while next <= end {
                        if labels[next] < 0 && pixels[next] >= Self.light {
                            if labels[next] == -1 { labels[next] = -2; queue.append(next) }
                            repeat { next += 1 } while next <= end && labels[next] < 0 && pixels[next] >= Self.light
                        } else { next += 1 }
                    }
                }
            }
            stats.append(value)
            return Int(id)
        }

        private static let light: UInt8 = 225

        private func resolve(_ rect: CGRect) -> Surface? {
            guard !Task.isCancelled, rect.width > 0, rect.height > 0, imageWidth > 0, imageHeight > 0,
                  [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy(\.isFinite) else { return nil }
            rasterize()
            guard !pixels.isEmpty else { return nil }
            let sx = CGFloat(width) / imageWidth, sy = CGFloat(height) / imageHeight
            let box = CGRect(x: rect.minX * sx, y: rect.minY * sy, width: rect.width * sx, height: rect.height * sy)
            let x0 = Int(box.minX.rounded()), y0 = Int(box.minY.rounded())
            let x1 = Int(box.maxX.rounded()) - 1, y1 = Int(box.maxY.rounded()) - 1
            guard x0 > 0, y0 > 0, x1 < width - 1, y1 < height - 1, x1 - x0 >= 3, y1 - y0 >= 3 else { return nil }
            // The paper between and inside glyph strokes is the surface the text is printed on.
            // Closed counters are tiny separate components; the dominant one is the balloon.
            var tally: [Int: Int] = [:]
            var lightCount = 0
            for y in y0...y1 {
                for x in x0...x1 where pixels[y * width + x] >= Self.light {
                    lightCount += 1
                    tally[label(at: y * width + x), default: 0] += 1
                }
            }
            let area = (x1 - x0 + 1) * (y1 - y0 + 1)
            let top = tally.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key })
            var unresolved = Surface(enclosing: nil, surrounded: false, dominant: top?.key, dominantCount: top?.value ?? 0,
                                     lightCount: lightCount, area: area, tally: tally)
            guard let (id, count) = top, count * 10 >= lightCount * 6 else { return unresolved }
            let component = stats[id]
            let center = (x: (x0 + x1) / 2, y: (y0 + y1) / 2)
            let centered = component.minX < center.x && component.maxX > center.x
                && component.minY < center.y && component.maxY > center.y
            let bounded = (component.maxX - component.minX) * 4 < width * 3 && (component.maxY - component.minY) * 4 < height * 3
            // A lettering outline forms a thin light halo; a balloon or box leaves margins.
            let encloses = !component.touchesEdge && centered && bounded && component.count >= area * 3 / 2
            guard lightCount * 10 >= area * 3 else {
                // Dense lettering leaves little paper in its box; a bounded dominant paper is still its balloon.
                if lightCount * 100 >= area * 15, encloses { unresolved.letteringBalloon = id }
                return unresolved
            }
            // A balloon-shaped paper: larger than the box and compact (fills half its bounds); thin wedges
            // between speed lines and the page background do not qualify.
            let bounds = (component.maxX - component.minX + 1) * (component.maxY - component.minY + 1)
            if centered, bounded, component.count >= area, component.count * 2 >= bounds {
                unresolved.balloon = id
                unresolved.ring = ringShare(id, x0: x0, y0: y0, x1: x1, y1: y1)
            }
            guard encloses else { return unresolved }
            var resolved = Surface(enclosing: id, surrounded: surrounds(id, x0: x0, y0: y0, x1: x1, y1: y1), dominant: id,
                                   dominantCount: count, lightCount: lightCount, area: area, tally: tally)
            resolved.balloon = unresolved.balloon
            resolved.ring = unresolved.ring
            resolved.letteringBalloon = id
            return resolved
        }

        /// The clean paper of the balloon (or caption box) around each text box, for sizing its
        /// translation against the balloon instead of the OCR column. `rects` are in image pixels;
        /// `candidates` marks the boxes that want one. A box whose balloon holds no other box's paper
        /// gets an interior; the box itself counts as paper (its lettering is erased), other ink and
        /// the outline end the paper. Unlike `separates`, a balloon may fit its column tightly (a
        /// vertical column has room across it) or be tall: the paper must ring the box and continue
        /// beyond it by half the box area.
        func balloonInteriors(of rects: [CGRect], candidates: [Bool]) -> [ReaderTranslationBalloonInterior?] {
            guard rects.count >= 2 || candidates.contains(true) else { return rects.map { _ in nil } }
            let surfaces = rects.map { surface(of: $0) }
            guard !pixels.isEmpty else { return rects.map { _ in nil } }
            var members: [Int: Int] = [:]
            for value in surfaces { if let id = value?.dominant { members[id, default: 0] += 1 } }
            let sx = CGFloat(width) / imageWidth, sy = CGFloat(height) / imageHeight
            let lone: [ReaderTranslationBalloonInterior?] = rects.indices.map { index in
                guard candidates[index], !Task.isCancelled, let value = surfaces[index], let id = value.dominant, members[id] == 1,
                      value.lightCount * 10 >= value.area * 3, value.dominantCount * 10 >= value.lightCount * 6 else { return nil }
                let component = stats[id], rect = rects[index]
                let x0 = Int((rect.minX * sx).rounded()), y0 = Int((rect.minY * sy).rounded())
                let x1 = Int((rect.maxX * sx).rounded()) - 1, y1 = Int((rect.maxY * sy).rounded()) - 1
                let center = (x: (x0 + x1) / 2, y: (y0 + y1) / 2)
                guard !component.touchesEdge,
                      component.minX < center.x, component.maxX > center.x, component.minY < center.y, component.maxY > center.y,
                      (component.maxX - component.minX) * 10 < width * 9, (component.maxY - component.minY) * 10 < height * 9,
                      (component.count - value.dominantCount) * 2 >= value.area,
                      surrounds(id, x0: x0, y0: y0, x1: x1, y1: y1) else { return nil }
                return interior(id, boxes: [rect])
            }
            return sharedInteriors(surfaces: surfaces, rects: rects, members: members, into: lone)
        }

        /// A balloon holding several captions (dialogue split by OCR, or a reply in the same
        /// balloon): one interior around the union of its captions, attached to each of them, so
        /// layout can set them as one unit. Accepted like a lone interior, with the paper ringing
        /// the union and continuing beyond the captions; a light panel or page area around a few
        /// captions (bounds over 8x their union) is not a balloon.
        private func sharedInteriors(surfaces: [Surface?], rects: [CGRect], members: [Int: Int],
                                     into lone: [ReaderTranslationBalloonInterior?]) -> [ReaderTranslationBalloonInterior?] {
            var result = lone
            let sx = CGFloat(width) / imageWidth, sy = CGFloat(height) / imageHeight
            var groups: [Int: [Int]] = [:]
            for (index, value) in surfaces.enumerated() {
                if let id = value?.dominant, let count = members[id], count >= 2, count <= 6 { groups[id, default: []].append(index) }
            }
            for (id, candidates) in groups.sorted(by: { $0.key < $1.key }) {
                guard !Task.isCancelled else { break }
                // Lettering printed mostly on something else (dense ink, art) stays a separate caption.
                let indices = candidates.filter { index in
                    guard result[index] == nil, let value = surfaces[index] else { return false }
                    return value.lightCount * 10 >= value.area * 3 && value.dominantCount * 10 >= value.lightCount * 6
                }
                guard indices.count >= 2 else { continue }
                let union = indices.dropFirst().reduce(rects[indices[0]]) { $0.union(rects[$1]) }
                let component = stats[id]
                let x0 = Int((union.minX * sx).rounded()), y0 = Int((union.minY * sy).rounded())
                let x1 = Int((union.maxX * sx).rounded()) - 1, y1 = Int((union.maxY * sy).rounded()) - 1
                let center = (x: (x0 + x1) / 2, y: (y0 + y1) / 2)
                let area = indices.reduce(0) { $0 + (surfaces[$1]?.area ?? 0) }
                let covered = indices.reduce(0) { $0 + (surfaces[$1]?.dominantCount ?? 0) }
                let bounds = (component.maxX - component.minX + 1) * (component.maxY - component.minY + 1)
                guard x1 > x0, y1 > y0, !component.touchesEdge,
                      component.minX < center.x, component.maxX > center.x, component.minY < center.y, component.maxY > center.y,
                      (component.maxX - component.minX) * 10 < width * 9, (component.maxY - component.minY) * 10 < height * 9,
                      (component.count - covered) * 4 >= area, bounds <= (x1 - x0 + 1) * (y1 - y0 + 1) * 8 else { continue }
                // Each caption is ringed by this paper (the ring may cross a neighbour's box: erased too).
                let boxes = indices.map { index in
                    let rect = rects[index]
                    return (x0: Int((rect.minX * sx).rounded()), y0: Int((rect.minY * sy).rounded()),
                            x1: Int((rect.maxX * sx).rounded()) - 1, y1: Int((rect.maxY * sy).rounded()) - 1)
                }
                guard boxes.indices.allSatisfy({ member in
                          let box = boxes[member]
                          return ringShare(id, x0: box.x0, y0: box.y0, x1: box.x1, y1: box.y1,
                                           excluding: boxes.indices.filter { $0 != member }.map { boxes[$0] }) >= 0.5
                      }),
                      var shared = interior(id, boxes: indices.map { rects[$0] }) else { continue }
                shared.members = indices.count
                for index in indices { result[index] = shared }
            }
            return result
        }

        /// The paper of balloon `id` with the lettering it encloses: holes (glyphs, counters, specks) lying mostly
        /// within the members' boxes (+ 0.3 glyph), and small marks within their union, are filled; art enclosed by
        /// the paper elsewhere is not. Map pixels.
        private struct FilledBalloon {
            var mask: [UInt8]
            let x0: Int, y0: Int, w: Int, h: Int
            var area = 0, artHoles = 0
        }

        private func filledBalloon(_ id: Int, members rects: [CGRect]) -> FilledBalloon? {
            guard stats.indices.contains(id), !rects.isEmpty, width > 0, height > 0 else { return nil }
            let component = stats[id], sx = CGFloat(width) / imageWidth, sy = CGFloat(height) / imageHeight
            let boxes = rects.map { CGRect(x: $0.minX * sx, y: $0.minY * sy, width: $0.width * sx, height: $0.height * sy) }
            let glyph = boxes.map { min($0.width, $0.height) }.min() ?? 0
            let x0 = max(0, min(component.minX, boxes.map { Int($0.minX) }.min()!) - 1)
            let y0 = max(0, min(component.minY, boxes.map { Int($0.minY) }.min()!) - 1)
            let x1 = min(width - 1, max(component.maxX, boxes.map { Int($0.maxX.rounded(.up)) }.max()!) + 1)
            let y1 = min(height - 1, max(component.maxY, boxes.map { Int($0.maxY.rounded(.up)) }.max()!) + 1)
            let w = x1 - x0 + 1, h = y1 - y0 + 1
            // A panel-sized light area is not a balloon; it also bounds the work below.
            guard w > 2, h > 2, w * h * 5 <= width * height * 2 else { return nil }
            let label = Int32(id)
            var result = FilledBalloon(mask: [UInt8](repeating: 0, count: w * h), x0: x0, y0: y0, w: w, h: h)
            for y in 0..<h {
                let source = (y + y0) * width + x0
                for x in 0..<w where labels[source + x] == label { result.mask[y * w + x] = 1 }
            }
            // 0 unvisited, 1 paper, 2 outside, 3 hole being measured, 4 lettering hole, 5 art hole.
            var state = result.mask
            var queue: [Int] = []
            queue.reserveCapacity(w * 2 + h * 2)
            for i in 0..<(w * h) where state[i] == 0 && (i % w == 0 || i % w == w - 1 || i < w || i >= w * (h - 1)) {
                state[i] = 2; queue.append(i)
            }
            var cursor = 0
            while cursor < queue.count {
                let i = queue[cursor]; cursor += 1
                let x = i % w
                if x > 0, state[i - 1] == 0 { state[i - 1] = 2; queue.append(i - 1) }
                if x < w - 1, state[i + 1] == 0 { state[i + 1] = 2; queue.append(i + 1) }
                if i >= w, state[i - w] == 0 { state[i - w] = 2; queue.append(i - w) }
                if i < w * (h - 1), state[i + w] == 0 { state[i + w] = 2; queue.append(i + w) }
            }
            // Small marks OCR did not read between the members (dots, a tail) lie in their union: they are erased
            // and plated with the unit (diverse2-3156). A longer stroke there is a partial outline (comic-4622).
            let margin = glyph * 0.3
            let near = boxes.map { $0.insetBy(dx: -margin, dy: -margin) }
            let union = boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }, mark = min(union.width, union.height) * 0.2
            for seed in 0..<(w * h) where state[seed] == 0 {
                queue.removeAll(keepingCapacity: true); queue.append(seed); state[seed] = 3
                var inside = 0, inUnion = 0, low = (Int.max, Int.max), high = (Int.min, Int.min); cursor = 0
                while cursor < queue.count {
                    let i = queue[cursor]; cursor += 1
                    let x = i % w, point = CGPoint(x: CGFloat(x + x0) + 0.5, y: CGFloat(i / w + y0) + 0.5)
                    if near.contains(where: { $0.contains(point) }) { inside += 1 }
                    if union.contains(point) { inUnion += 1 }
                    low = (min(low.0, x), min(low.1, i / w)); high = (max(high.0, x), max(high.1, i / w))
                    if x > 0, state[i - 1] == 0 { state[i - 1] = 3; queue.append(i - 1) }
                    if x < w - 1, state[i + 1] == 0 { state[i + 1] = 3; queue.append(i + 1) }
                    if i >= w, state[i - w] == 0 { state[i - w] = 3; queue.append(i - w) }
                    if i < w * (h - 1), state[i + w] == 0 { state[i + w] = 3; queue.append(i + w) }
                }
                let small = CGFloat(high.0 - low.0 + 1) <= mark && CGFloat(high.1 - low.1 + 1) <= mark
                let lettering = inside * 2 >= queue.count || queue.count <= 4 || small && inUnion * 2 >= queue.count
                for i in queue {
                    state[i] = lettering ? 4 : 5
                    if lettering { result.mask[i] = 1 }
                }
                if !lettering { result.artHoles += queue.count }
            }
            result.area = result.mask.reduce(0) { $0 + Int($1) }
            return result
        }

        /// The balloon of a joined unit (see `ReaderTranslationBalloonMerger.joinBalloonUnits`): its paper with the
        /// members' lettering (see `filledBalloon`); each band keeps the narrowest of its rows' widest paper runs.
        /// The members' union rectangle may cross the outline, so it never counts as paper. Only a balloon-shaped
        /// paper (see `unitFitsBalloon`) qualifies: paper leaking through a broken outline into the page between
        /// speed lines is not an interior (diverse2-2925); such a unit keeps the overlay's own estimate.
        func unitInterior(members rects: [CGRect]) -> ReaderTranslationBalloonInterior? {
            guard rects.count >= 2, let largest = rects.max(by: { $0.width * $0.height < $1.width * $1.height }),
                  let id = balloon(of: largest), !pixels.isEmpty, stats.indices.contains(id), !stats[id].touchesEdge,
                  let filled = filledBalloon(id, members: rects), balloonShaped(filled, members: rects) else { return nil }
            return interior(id, boxes: [rects.dropFirst().reduce(rects[0]) { $0.union($1) }], filled: filled)
        }

        /// A joined unit's balloon can hold its lettering as one caption: every member at least 97 % inside it, a
        /// compact shape (solidity >= 0.85, so not two lobes or a stair of panels), no artwork enclosed by its paper
        /// beyond the lettering (<= 4 %), and an upright rectangle inside it of at least 1.05x the members' area,
        /// where one card fits at their size.
        private func balloonShaped(_ filled: FilledBalloon, members rects: [CGRect]) -> Bool {
            guard filled.area > 0, filled.artHoles * 25 <= filled.area else { return false }
            let w = filled.w, h = filled.h
            // Each member lies in the balloon: lettering written across its outline or onto the art beside it
            // (a handwritten gloss over a box edge, diverse-3570) would keep a plate over the outline.
            let scaleX = CGFloat(width) / imageWidth, scaleY = CGFloat(height) / imageHeight
            for rect in rects {
                let x0 = max(filled.x0, Int((rect.minX * scaleX).rounded())), x1 = min(filled.x0 + w, Int((rect.maxX * scaleX).rounded()))
                let y0 = max(filled.y0, Int((rect.minY * scaleY).rounded())), y1 = min(filled.y0 + h, Int((rect.maxY * scaleY).rounded()))
                let total = max(1, Int((rect.width * scaleX).rounded()) * Int((rect.height * scaleY).rounded()))
                var inside = 0
                if x1 > x0, y1 > y0 {
                    for y in y0..<y1 { for x in x0..<x1 where filled.mask[(y - filled.y0) * w + x - filled.x0] != 0 { inside += 1 } }
                }
                guard inside * 100 >= total * 97 else { return false }
            }
            // Convex hull of the row extents (monotone chain).
            var points: [(Int, Int)] = []
            for y in 0..<h {
                var low = -1, high = -1
                for x in 0..<w where filled.mask[y * w + x] != 0 { if low < 0 { low = x }; high = x }
                if low >= 0 { points += [(low, y), (low, y + 1), (high + 1, y), (high + 1, y + 1)] }
            }
            points.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
            func cross(_ o: (Int, Int), _ a: (Int, Int), _ b: (Int, Int)) -> Int { (a.0 - o.0) * (b.1 - o.1) - (a.1 - o.1) * (b.0 - o.0) }
            var lower: [(Int, Int)] = [], upper: [(Int, Int)] = []
            for p in points {
                while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
                lower.append(p)
            }
            for p in points.reversed() {
                while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
                upper.append(p)
            }
            let hull = Array(lower.dropLast()) + Array(upper.dropLast())
            var twice = 0
            for i in hull.indices { let a = hull[i], b = hull[(i + 1) % hull.count]; twice += a.0 * b.1 - b.0 * a.1 }
            return filled.area * 20 >= abs(twice) * 17 / 2
        }

        /// `balloonShaped`, and one card fits the balloon at the members' size (see above).
        func unitFitsBalloon(_ rects: [CGRect], component id: Int) -> Bool {
            guard let filled = filledBalloon(id, members: rects), balloonShaped(filled, members: rects) else { return false }
            let w = filled.w, h = filled.h
            // Largest upright rectangle of balloon paper (histogram method).
            var heights = [Int](repeating: 0, count: w + 1), best = 0, stack: [Int] = []
            for y in 0..<h {
                for x in 0..<w { heights[x] = filled.mask[y * w + x] != 0 ? heights[x] + 1 : 0 }
                stack.removeAll(keepingCapacity: true)
                for x in 0...w {
                    while let top = stack.last, heights[top] >= (x < w ? heights[x] : 0) {
                        stack.removeLast()
                        best = max(best, heights[top] * (x - (stack.last.map { $0 + 1 } ?? 0)))
                    }
                    stack.append(x)
                }
            }
            let sx = CGFloat(width) / imageWidth, sy = CGFloat(height) / imageHeight
            let members = rects.reduce(CGFloat(0)) { $0 + $1.width * sx * $1.height * sy }
            return CGFloat(best) * 100 >= members * 105
        }

        /// `boxes` are the captions' boxes (image pixels): their lettering is erased, so they count as
        /// paper; the runs pass through the centre column of their union.
        private func interior( // swiftlint:disable:this cyclomatic_complexity
            _ id: Int, boxes: [CGRect], filled: FilledBalloon? = nil
        ) -> ReaderTranslationBalloonInterior? {
            let component = stats[id]
            let sx = CGFloat(width) / imageWidth, sy = CGFloat(height) / imageHeight
            let pixelBoxes = boxes.map { rect in
                (x0: max(0, Int((rect.minX * sx).rounded(.down))), y0: max(0, Int((rect.minY * sy).rounded(.down))),
                 x1: min(width - 1, Int((rect.maxX * sx).rounded(.up)) - 1), y1: min(height - 1, Int((rect.maxY * sy).rounded(.up)) - 1))
            }
            guard !pixelBoxes.isEmpty, pixelBoxes.allSatisfy({ $0.x1 > $0.x0 && $0.y1 > $0.y0 }) else { return nil }
            let bx0 = pixelBoxes.map(\.x0).min()!, by0 = pixelBoxes.map(\.y0).min()!
            let bx1 = pixelBoxes.map(\.x1).max()!, by1 = pixelBoxes.map(\.y1).max()!
            let x0 = filled?.x0 ?? min(component.minX, bx0), x1 = filled.map { $0.x0 + $0.w - 1 } ?? max(component.maxX, bx1)
            let y0 = filled?.y0 ?? min(component.minY, by0), y1 = filled.map { $0.y0 + $0.h - 1 } ?? max(component.maxY, by1)
            let w = x1 - x0 + 1, h = y1 - y0 + 1
            // A panel-sized light area is not a balloon; it also bounds the work below.
            guard w * h * 5 <= width * height * 2 else { return nil }
            let label = Int32(id)
            var clean = filled?.mask ?? [UInt8](repeating: 0, count: w * h)
            if filled == nil {
                for y in y0...y1 {
                    let row = (y - y0) * w - x0, source = y * width
                    for x in x0...x1 where labels[source + x] == label { clean[row + x] = 1 }
                }
                for box in pixelBoxes {
                    for y in box.y0...box.y1 {
                        let row = (y - y0) * w - x0
                        for x in box.x0...box.x1 { clean[row + x] = 1 }
                    }
                }
            }
            var lefts = [Int](repeating: -1, count: h), rights = [Int](repeating: -1, count: h)
            if filled != nil {
                // The widest paper run of each row.
                for y in 0..<h {
                    var x = 0
                    while x < w {
                        guard clean[y * w + x] != 0 else { x += 1; continue }
                        var end = x
                        while end + 1 < w, clean[y * w + end + 1] != 0 { end += 1 }
                        if lefts[y] < 0 || end - x > rights[y] - lefts[y] { lefts[y] = x; rights[y] = end }
                        x = end + 1
                    }
                }
            } else {
                // Horizontal run of paper through the caption's centre column, per pixel row.
                let anchor = (bx0 + bx1) / 2 - x0
                for y in 0..<h where clean[y * w + anchor] != 0 {
                    var left = anchor, right = anchor
                    while left > 0, clean[y * w + left - 1] != 0 { left -= 1 }
                    while right < w - 1, clean[y * w + right + 1] != 0 { right += 1 }
                    lefts[y] = left; rights[y] = right
                }
            }
            // Chamfer (3-4) distance to non-paper; the deep part's centroid is the visual centre,
            // so a tail does not pull the text off centre.
            var distance = [UInt16](repeating: 0, count: w * h)
            for y in 0..<h {
                for x in 0..<w where clean[y * w + x] != 0 {
                    let i = y * w + x
                    var d = min(x > 0 ? Int(distance[i - 1]) + 3 : 3, y > 0 ? Int(distance[i - w]) + 3 : 3)
                    d = min(d, x > 0 && y > 0 ? Int(distance[i - w - 1]) + 4 : 4, x < w - 1 && y > 0 ? Int(distance[i - w + 1]) + 4 : 4)
                    distance[i] = UInt16(min(d, Int(UInt16.max)))
                }
            }
            var deepest = 0
            for y in stride(from: h - 1, through: 0, by: -1) {
                for x in stride(from: w - 1, through: 0, by: -1) where clean[y * w + x] != 0 {
                    let i = y * w + x
                    var d = min(Int(distance[i]), x < w - 1 ? Int(distance[i + 1]) + 3 : 3, y < h - 1 ? Int(distance[i + w]) + 3 : 3)
                    d = min(d, x < w - 1 && y < h - 1 ? Int(distance[i + w + 1]) + 4 : 4, x > 0 && y < h - 1 ? Int(distance[i + w - 1]) + 4 : 4)
                    distance[i] = UInt16(min(d, Int(UInt16.max)))
                    deepest = max(deepest, d)
                }
            }
            guard deepest > 0 else { return nil }
            // Captions of one balloon share one lobe: the paper stays deep along the line between
            // their boxes. Joined balloons (two lobes and a neck) keep their captions separate.
            if pixelBoxes.count > 1 {
                func depth(_ x: Int, _ y: Int) -> Int {
                    let u = min(w - 1, max(0, x - x0)), v = min(h - 1, max(0, y - y0))
                    return Int(distance[v * w + u])
                }
                let centres = pixelBoxes.map { ((($0.x0 + $0.x1) / 2), (($0.y0 + $0.y1) / 2)) }
                for first in centres.indices {
                    for second in centres.indices where second > first {
                        let a = centres[first], b = centres[second]
                        let ends = min(depth(a.0, a.1), depth(b.0, b.1))
                        var neck = ends
                        for step in 0...20 {
                            let t = Double(step) / 20
                            neck = min(neck, depth(a.0 + Int((Double(b.0 - a.0) * t).rounded()),
                                                   a.1 + Int((Double(b.1 - a.1) * t).rounded())))
                        }
                        if ends <= 0 || neck * 10 < ends * 6 { return nil }
                    }
                }
            }
            var sumX: Double = 0, sumY: Double = 0, count: Double = 0
            for y in 0..<h {
                for x in 0..<w where Int(distance[y * w + x]) * 10 >= deepest * 6 {
                    sumX += Double(x) + 0.5; sumY += Double(y) + 0.5; count += 1
                }
            }
            // At most 48 bands (96 for a unit, whose erasure follows them); each keeps the narrowest run of its rows (no run in a row: none).
            let bands = min(filled != nil ? 96 : 48, h)
            var spans: [Double] = []
            spans.reserveCapacity(bands * 2)
            for band in 0..<bands {
                var left = 0, right = w - 1, open = true
                for y in (band * h / bands)..<max(band * h / bands + 1, (band + 1) * h / bands) {
                    guard lefts[y] >= 0 else { open = false; break }
                    left = max(left, lefts[y]); right = min(right, rights[y])
                }
                if open, right >= left {
                    spans.append(Self.quantized(Double(x0 + left) / Double(width)))
                    spans.append(Self.quantized(Double(x0 + right + 1) / Double(width)))
                } else {
                    spans.append(-1); spans.append(-1)
                }
            }
            return ReaderTranslationBalloonInterior(
                rect: CGRect(x: Self.quantized(Double(x0) / Double(width)), y: Self.quantized(Double(y0) / Double(height)),
                             width: Self.quantized(Double(w) / Double(width)), height: Self.quantized(Double(h) / Double(height))),
                center: CGPoint(x: Self.quantized((Double(x0) + sumX / count) / Double(width)),
                                y: Self.quantized((Double(y0) + sumY / count) / Double(height))),
                spans: spans)
        }

        private static func quantized(_ value: Double) -> Double { (value * 100_000).rounded() / 100_000 }

        /// Balloon paper continues beyond the text box (margins, gutters). A lettering outline halo
        /// hugs the strokes, so most of a ring just outside the box lies on the artwork.
        private func surrounds(_ id: Int, x0: Int, y0: Int, x1: Int, y1: Int) -> Bool {
            ringShare(id, x0: x0, y0: y0, x1: x1, y1: y1) >= 0.5
        }

        /// Share of a ring 0.15 glyph outside the box that lies on component `id`. Ring points inside
        /// `excluding` boxes (other captions of the same balloon, whose lettering is erased) are skipped.
        private func ringShare(_ id: Int, x0: Int, y0: Int, x1: Int, y1: Int,
                               // swiftlint:disable:next large_tuple
                               excluding: [(x0: Int, y0: Int, x1: Int, y1: Int)] = []) -> Double {
            let distance = max(2, Int((CGFloat(min(x1 - x0, y1 - y0) + 1) * 0.15).rounded()))
            let left = x0 - distance, right = x1 + distance, top = y0 - distance, bottom = y1 + distance
            var inside = 0, total = 0
            func sample(_ x: Int, _ y: Int) {
                if excluding.contains(where: { x >= $0.x0 && x <= $0.x1 && y >= $0.y0 && y <= $0.y1 }) { return }
                total += 1
                guard x >= 0, y >= 0, x < width, y < height, pixels[y * width + x] >= Self.light else { return }
                if label(at: y * width + x) == id { inside += 1 }
            }
            for x in left...right { sample(x, top); sample(x, bottom) }
            for y in (top + 1)..<bottom { sample(left, y); sample(right, y) }
            return total > 0 ? Double(inside) / Double(total) : 0
        }
    }

    /// A tight gap between a multi-column block and its remaining column can
    /// stay inside a balloon whose outline is open or crossed by lettering.
    /// Require an almost entirely white bridge, rather than absence of a rule.
    static func hasClearVerticalBridge(in image: CGImage, left: CGRect, right: CGRect,
                                       minimumOverlapInFontSizes: CGFloat = 2) -> Bool {
        let top = max(left.minY, right.minY), bottom = min(left.maxY, right.maxY)
        let font = min(left.width, right.width)
        guard bottom - top > font * minimumOverlapInFontSizes else { return false }
        let middle = (left.maxX + right.minX) / 2
        let sample = CGRect(x: middle - max(1, font * 0.06), y: top + font * 0.2,
            width: max(2, font * 0.12), height: bottom - top - font * 0.4).integral
        guard sample.minX >= 0, sample.minY >= 0, sample.maxX <= CGFloat(image.width),
              sample.maxY <= CGFloat(image.height), let crop = image.cropping(to: sample) else { return false }
        let width = 5, height = 48
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return false }
        let clearRows = (0..<height).filter { row in (0..<width).allSatisfy { pixels[row * width + $0] >= 225 } }.count
        return clearRows >= 47
    }

    private struct FloodVisits {
        var stamps: [UInt32] = []
        private(set) var generation: UInt32 = 0

        /// Starts a new flood whose seen set is empty.
        mutating func begin(pixelCount: Int) {
            if stamps.count != pixelCount {
                stamps = [UInt32](repeating: 0, count: pixelCount)
                generation = 0
            }
            if generation == .max {
                for index in stamps.indices { stamps[index] = 0 }
                generation = 0
            }
            generation += 1
        }
    }

    private static func enclosed(_ rect: CGRect, pixels: [UInt8], width: Int, height: Int, checkingAlternateSeeds: Bool, labels: inout [Int], components: inout [Component], visits: inout FloodVisits) -> Int? {
        guard rect.minX.isFinite, rect.minY.isFinite, rect.maxX.isFinite, rect.maxY.isFinite,
              rect.width > 0, rect.height > 0, rect.minX >= 0, rect.minY >= 0,
              rect.maxX < CGFloat(width), rect.maxY < CGFloat(height) else { return nil }
        let x0 = Int(floor(rect.minX)) - 2, y0 = Int(floor(rect.minY)) - 2
        let x1 = Int(ceil(rect.maxX)) + 2, y1 = Int(ceil(rect.maxY)) + 2
        guard x0 > 0, y0 > 0, x1 < width - 1, y1 < height - 1,
              x1 - x0 >= 6, y1 - y0 >= 6 else { return nil }
        var perimeter: [Int] = []
        for x in x0...x1 { perimeter.append(y0 * width + x); perimeter.append(y1 * width + x) }
        for y in (y0 + 1)..<y1 { perimeter.append(y * width + x0); perimeter.append(y * width + x1) }
        // Require background all around the lettering, not a small white hole
        // inside one glyph. An open/missing balloon boundary always abstains.
        guard let seed = perimeter.first(where: { pixels[$0] >= 235 }) else { return nil }
        let middleX = (x0 + x1) / 2, middleY = (y0 + y1) / 2
        let seeds = checkingAlternateSeeds
            ? [seed, middleY * width + x0, middleY * width + x1,
               y0 * width + middleX, y1 * width + middleX] : [seed]
        // All attempts share the original flood budget. A bad corner seed must
        // not multiply page work or count as evidence against enclosed speech.
        var remaining = min(pixels.count / 3, max(256, (x1 - x0) * (y1 - y0) * 12))
        var attempted = Set<Int>()
        for seed in seeds where pixels[seed] >= 235 && !attempted.contains(seed) {
            guard remaining > 0, !Task.isCancelled else { return nil }
            // Only completed, edge-free floods are reusable. Charge the same
            // node budget and recheck this region's perimeter and geometry.
            if !labels.isEmpty, labels[seed] >= 0 {
                let label = labels[seed], component = components[label]
                guard remaining >= component.count else { return nil }
                remaining -= component.count
                for candidate in seeds where labels[candidate] == label { attempted.insert(candidate) }
                guard perimeter.filter({ labels[$0] == label }).count * 5 >= perimeter.count * 4,
                      component.minX < x0, component.maxX > x1, component.minY < y0, component.maxY > y1,
                      component.maxX - component.minX < width * 3 / 4,
                      component.maxY - component.minY < height * 3 / 4 else { continue }
                return component.minimumPoint
            }
            visits.begin(pixelCount: pixels.count)
            let generation = visits.generation
            var queue = [seed]
            visits.stamps[seed] = generation; remaining -= 1
            var cursor = 0, minX = width, maxX = 0, minY = height, maxY = 0
            var touchesEdge = false
            while cursor < queue.count {
                guard !Task.isCancelled else { return nil }
                let point = queue[cursor]; cursor += 1
                let x = point % width, y = point / width
                if x == 0 || y == 0 || x == width - 1 || y == height - 1 { touchesEdge = true; break }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                // Unrolled in the former neighbour order: left, right, up, down.
                // `visit` returns false only when the flood budget is exhausted.
                func visit(_ next: Int) -> Bool {
                    guard visits.stamps[next] != generation, pixels[next] >= 235 else { return true }
                    guard remaining > 0 else { return false }
                    remaining -= 1; visits.stamps[next] = generation; queue.append(next)
                    return true
                }
                guard visit(point - 1), visit(point + 1), visit(point - width), visit(point + width) else { return nil }
            }
            if !touchesEdge, !labels.isEmpty {
                let label = components.count
                components.append(Component(count: queue.count, minimumPoint: queue.min()!,
                    minX: minX, maxX: maxX, minY: minY, maxY: maxY))
                for point in queue { labels[point] = label }
            }
            for candidate in seeds where visits.stamps[candidate] == generation { attempted.insert(candidate) }
            guard !touchesEdge,
                  perimeter.filter({ visits.stamps[$0] == generation }).count * 5 >= perimeter.count * 4,
                  minX < x0, maxX > x1, minY < y0, maxY > y1,
                  maxX - minX < width * 3 / 4, maxY - minY < height * 3 / 4 else { continue }
            return queue.min()
        }
        return nil
    }
}
