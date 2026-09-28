import UIKit

/// A detector quad describes the lettering's axes, independently of whether
/// that lettering is read horizontally or vertically. All math uses pixels;
/// normalized coordinates would give the wrong angle on non-square pages.
enum BrowserOverlayRotation {
    struct Geometry: Equatable {
        let radians: CGFloat
        let rect: CGRect // Unrotated local box, centered on the source quad.
        let panelRect: CGRect // Encloses the entire quad, including quantized edges.

        var footprint: CGRect {
            let c = abs(cos(radians)), s = abs(sin(radians))
            let width = rect.width * c + rect.height * s
            let height = rect.width * s + rect.height * c
            return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2,
                          width: width, height: height)
        }
    }

    static func geometry(polygon: [CGPoint], singleVerticalColumn: Bool = false) -> Geometry? {
        guard polygon.count == 4, polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        var p = polygon
        func vector(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: b.x - a.x, y: b.y - a.y) }
        func length(_ v: CGPoint) -> CGFloat { hypot(v.x, v.y) }
        // Detector corner ordering can put a vertical column's long edge first.
        // Its reading direction is separate from the rotation of its glyphs.
        // Only a confirmed single column supplies enough evidence to swap axes.
        if singleVerticalColumn, length(vector(p[0], p[1])) > length(vector(p[0], p[3])) * 1.5 {
            p = [p[3], p[0], p[1], p[2]]
            if p[1].x < p[0].x { p = [p[2], p[3], p[0], p[1]] }
        }
        let top = vector(p[0], p[1]), bottom = vector(p[3], p[2])
        let left = vector(p[0], p[3]), right = vector(p[1], p[2])
        let widths = [length(top), length(bottom)], heights = [length(left), length(right)]
        guard widths.min()! >= 3, heights.min()! >= 3,
              widths.min()! / widths.max()! >= 0.75,
              heights.min()! / heights.max()! >= 0.75 else { return nil }
        let u = CGPoint(x: top.x / widths[0] + bottom.x / widths[1],
                        y: top.y / widths[0] + bottom.y / widths[1])
        let v = CGPoint(x: left.x / heights[0] + right.x / heights[1],
                        y: left.y / heights[0] + right.y / heights[1])
        guard length(u) > 1.98, length(v) > 1.98,
              u.x * v.y - u.y * v.x > 0,
              abs(u.x * v.x + u.y * v.y) / (length(u) * length(v)) < 0.12 else { return nil }
        // Quantization on a short cross-edge must not outweigh the accurately
        // detected long sides. Estimate both orthogonal axes, weighted by
        // squared edge length, before fitting the local rectangle.
        let axisX = top.x * widths[0] + bottom.x * widths[1] + left.y * heights[0] + right.y * heights[1]
        let axisY = top.y * widths[0] + bottom.y * widths[1] - left.x * heights[0] - right.x * heights[1]
        let angle = atan2(axisY, axisX)
        // Ignore detector jitter. Strong perspective/skew needs a homography,
        // not a confident-looking rotation of an unrelated rectangular box.
        // Near a quarter turn, reading-axis ambiguity dominates. Allow steep
        // but usable slopes up to 80 degrees, not sideways/upside-down guesses.
        guard abs(angle) >= .pi / 60, abs(angle) <= .pi * 4 / 9 + 1e-9 else { return nil }
        let center = CGPoint(x: p.map(\.x).reduce(0, +) / 4, y: p.map(\.y).reduce(0, +) / 4)
        let c = cos(angle), s = sin(angle)
        let local = p.map { q in
            let x = q.x - center.x, y = q.y - center.y
            return CGPoint(x: x * c + y * s, y: -x * s + y * c)
        }
        // Inscribe the box so quantized/nonparallel edges cannot put translated
        // ink outside the source quad. Keep its center at the original anchor.
        var halfWidth = min(-local[0].x, -local[3].x, local[1].x, local[2].x)
        var halfHeight = min(-local[0].y, -local[1].y, local[2].y, local[3].y)
        guard halfWidth > 1, halfHeight > 1 else { return nil }
        let panelHalfWidth = local.map { abs($0.x) }.max()!
        let panelHalfHeight = local.map { abs($0.y) }.max()!
        var area: CGFloat = 0, insetScale: CGFloat = 1
        for i in local.indices {
            let a = local[i], b = local[(i + 1) % 4], next = local[(i + 2) % 4]
            let edge = vector(a, b), following = vector(b, next)
            guard edge.x * following.y - edge.y * following.x > 0 else { return nil }
            area += a.x * b.y - a.y * b.x
            let distance = edge.y * a.x - edge.x * a.y
            let extent = abs(edge.y) * halfWidth + abs(edge.x) * halfHeight
            guard distance > 0, extent > 0 else { return nil }
            insetScale = min(insetScale, distance / extent)
        }
        // A thin skewed quad can have nearly parallel edges yet require a much
        // larger opaque rectangle. Reject that spill onto neighboring artwork.
        guard panelHalfWidth * panelHalfHeight * 4 <= area / 2 * 1.10 else { return nil }
        halfWidth *= insetScale; halfHeight *= insetScale
        guard halfWidth > 1, halfHeight > 1 else { return nil }
        return Geometry(radians: angle,
            rect: CGRect(x: center.x - halfWidth, y: center.y - halfHeight, width: halfWidth * 2, height: halfHeight * 2),
            panelRect: CGRect(x: center.x - panelHalfWidth, y: center.y - panelHalfHeight,
                              width: panelHalfWidth * 2, height: panelHalfHeight * 2))
    }

    static func mapped(item: BrowserOverlayItem, imageSize: CGSize, sourceRect: CGRect,
                       settings: IPhoneOverlaySettings) -> Geometry? {
        guard let result = quadGeometry(item: item, imageSize: imageSize, sourceRect: sourceRect, settings: settings),
              !isEffectivelyUpright(result, vertical: item.sourceOrientation == .vertical, text: item.sourceText) else { return nil }
        return result
    }

    /// The baseline of italic or skewed lettering whose quad `geometry` rejects (its sides are not
    /// perpendicular): the two edges along the reading direction (the column axis for vertical text),
    /// parallel within 8.2 degrees, tilted by 4-80 degrees. The box is the quad projected on those axes.
    /// Only keep-source glosses use it: they turn with the lettering's baseline.
    static func baselineAxis(item: BrowserOverlayItem, imageSize: CGSize, sourceRect: CGRect) -> Geometry? {
        guard imageSize.width > 0, imageSize.height > 0, item.sourcePolygon.count == 4 else { return nil }
        let p = item.sourcePolygon.map { CGPoint(x: sourceRect.minX + $0.x * sourceRect.width / imageSize.width,
                                                 y: sourceRect.minY + $0.y * sourceRect.height / imageSize.height) }
        guard p.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        func direction(_ a: CGPoint, _ b: CGPoint) -> CGPoint? {
            let length = hypot(b.x - a.x, b.y - a.y)
            return length >= 3 ? CGPoint(x: (b.x - a.x) / length, y: (b.y - a.y) / length) : nil
        }
        let vertical = item.sourceOrientation == .vertical
        guard let first = vertical ? direction(p[0], p[3]) : direction(p[0], p[1]),
              let second = vertical ? direction(p[1], p[2]) : direction(p[3], p[2]),
              first.x * second.x + first.y * second.y >= cos(.pi / 22) else { return nil }
        let angle = atan2(first.y + second.y, first.x + second.x) - (vertical ? .pi / 2 : 0)
        guard abs(angle) >= .pi / 45, abs(angle) <= .pi * 4 / 9 else { return nil }
        let c = cos(angle), s = sin(angle)
        let center = CGPoint(x: p.map(\.x).reduce(0, +) / 4, y: p.map(\.y).reduce(0, +) / 4)
        let us = p.map { ($0.x - center.x) * c + ($0.y - center.y) * s }
        let vs = p.map { -($0.x - center.x) * s + ($0.y - center.y) * c }
        let midU = (us.min()! + us.max()!) / 2, midV = (vs.min()! + vs.max()!) / 2
        let panel = CGRect(x: center.x + midU * c - midV * s - (us.max()! - us.min()!) / 2,
                           y: center.y + midU * s + midV * c - (vs.max()! - vs.min()!) / 2,
                           width: us.max()! - us.min()!, height: vs.max()! - vs.min()!)
        return Geometry(radians: angle, rect: panel, panelRect: panel)
    }

    /// The source quad when it only tilts by detector noise and the caption
    /// is therefore set upright (see `isEffectivelyUpright`).
    static func nearUpright(item: BrowserOverlayItem, imageSize: CGSize, sourceRect: CGRect,
                            settings: IPhoneOverlaySettings) -> Geometry? {
        guard let result = quadGeometry(item: item, imageSize: imageSize, sourceRect: sourceRect, settings: settings),
              isEffectivelyUpright(result, vertical: item.sourceOrientation == .vertical, text: item.sourceText) else { return nil }
        return result
    }

    private static func quadGeometry(item: BrowserOverlayItem, imageSize: CGSize, sourceRect: CGRect,
                                     settings: IPhoneOverlaySettings) -> Geometry? {
        guard settings.mode == .translateOnly, settings.textPlacement == .replace,
              item.translatedText?.isEmpty == false, imageSize.width > 0, imageSize.height > 0 else { return nil }
        let polygon = item.sourcePolygon.map { CGPoint(x: sourceRect.minX + $0.x * sourceRect.width / imageSize.width,
                                                       y: sourceRect.minY + $0.y * sourceRect.height / imageSize.height) }
        guard let result = geometry(polygon: polygon,
                                   singleVerticalColumn: item.sourceOrientation == .vertical && item.sourceSingleVerticalColumn == true),
              sourceRect.insetBy(dx: -0.5, dy: -0.5).contains(result.footprint) else { return nil }
        return result
    }

    /// A detector quad around upright lettering still tilts by a few degrees:
    /// the minimum-area box of a short word or label is not level. Measured
    /// against the source lettering, horizontal body text below 4 degrees
    /// whose baseline rises by at most a fifth of a glyph over its length
    /// reads as upright (the tilt is imperceptible there), and takes the
    /// upright path (grouping, erasure, growth, plates). Vertical columns and
    /// large lettering (24 pt glyphs, about twice body text) keep their quad:
    /// the rotated path bounds their plates and growth inside it, while an
    /// upright caption would spill over the balloon edge and artwork. A label
    /// set upright this way stays out of the page's size cohorts, which it
    /// never joined as a rotated caption: it may not pull other captions down.
    static func isEffectivelyUpright(_ geometry: Geometry, vertical: Bool, text: String) -> Bool {
        let angle = abs(geometry.radians)
        guard !vertical, angle < .pi / 45 else { return false }
        let rect = geometry.rect
        let glyph = BrowserOverlayTypography.sourceSize(text: text, rect: rect) ?? min(rect.width, rect.height)
        guard glyph < 24 else { return false }
        return rect.width * tan(angle) <= glyph * 0.2
    }

    /// A vertical column's quad tilts by a few degrees of detector noise even
    /// when its lettering stands upright: measured against the source, columns
    /// below 4.2 degrees are nearly all upright (25 of 27), steeper ones only
    /// about half. Horizontal Korean over such a column keeps the quad's
    /// layout (sized from its glyph) and erasure but is set upright in the same
    /// box; a plate is clipped to the quad grown by `uprightQuadMargin`. The
    /// web overlay confirms the premise on the source ink before using it.
    static func setsUprightInQuad(_ geometry: Geometry, sourceVertical: Bool, translatedVertical: Bool) -> Bool {
        sourceVertical && !translatedVertical && abs(geometry.radians) < .pi / 43
    }

    /// Plate slack past the quad, in page points.
    static let uprightQuadMargin: CGFloat = 2

    /// A convex polygon clipped to the quad's panel grown by `margin`
    /// (Sutherland-Hodgman against its four sides, in page points).
    static func clipped(_ polygon: [CGPoint], toQuad geometry: Geometry, margin: CGFloat = uprightQuadMargin) -> [CGPoint] {
        let c = cos(geometry.radians), s = sin(geometry.radians)
        let center = CGPoint(x: geometry.panelRect.midX, y: geometry.panelRect.midY)
        let halfWidth = geometry.panelRect.width / 2 + margin, halfHeight = geometry.panelRect.height / 2 + margin
        // Signed distance inside each side, measured along the quad's axes.
        let sides: [(CGPoint) -> CGFloat] = [
            { halfWidth - (($0.x - center.x) * c + ($0.y - center.y) * s) },
            { halfWidth + (($0.x - center.x) * c + ($0.y - center.y) * s) },
            { halfHeight - (-($0.x - center.x) * s + ($0.y - center.y) * c) },
            { halfHeight + (-($0.x - center.x) * s + ($0.y - center.y) * c) }
        ]
        var result = polygon
        for side in sides where !result.isEmpty {
            let input = result
            result = []
            for index in input.indices {
                let p = input[index], q = input[(index + 1) % input.count], dp = side(p), dq = side(q)
                if dp >= 0 { result.append(p) }
                if (dp >= 0) != (dq >= 0) {
                    let t = dp / (dp - dq)
                    result.append(CGPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t))
                }
            }
        }
        return result
    }

    /// Source glyphs from this size up are display lettering (titles, shouts,
    /// sound effects); the overlay's growth pass uses the same threshold.
    static let displayGlyphSize: CGFloat = 40
    static let maximumDisplayFontSize: CGFloat = 128

    /// The planner sizes a caption from the axis-aligned OCR box, which
    /// under-reads rotated lettering. The quad's own axes give the source
    /// glyph size; a rotated caption may grow toward it inside its quad.
    /// With `display`, display lettering is sized from its source lettering
    /// (up to 0.8x of the glyph) instead of the body-text ceiling; the quad
    /// and the layout's word, line and obstacle rules still bound it.
    static func maximumFontSize(geometry: Geometry, sourceText: String, planned: CGFloat, display: Bool = false) -> CGFloat {
        let size = geometry.rect.size
        guard sourceText.contains(where: { !$0.isWhitespace }) else { return planned }
        let glyph = BrowserOverlayTypography.sourceSize(text: sourceText, rect: geometry.rect) ?? min(size.width, size.height)
        if display, glyph >= displayGlyphSize {
            return max(planned, min(maximumDisplayFontSize, floor(glyph * 0.8 * 4) / 4))
        }
        return max(planned, min(BrowserOverlayLayoutPlanner.maximumAutoFontSize, floor(glyph * 0.9 * 4) / 4))
    }

    /// A slanted vertical column is often only one or two Hangul syllables
    /// wide, so horizontal Korean set inside its quad breaks every word into a
    /// pseudo-vertical stack. The ordinary source-anchored card was planned
    /// against every other caption's source and card; when it keeps each word
    /// whole at a comparable size, it is offered as an upright alternative.
    /// The overlay still erases the slanted quad and falls back to the rotated
    /// layout unless every upright glyph lands on clean, readable surface.
    static func prefersUprightLayout(rotated: BrowserOverlayCardLayout, radians: CGFloat, upright: BrowserOverlayCardLayout,
                                     variant: BrowserOverlayDisplayVariant, sourceVertical: Bool,
                                     measurementCache: BrowserOverlayTextMeasurementCache?) -> Bool {
        // Upright text reads naturally only over a near-vertical column.
        guard sourceVertical, !variant.vertical, !upright.rect.isNull, abs(radians) <= .pi / 12,
              BrowserOverlayTextFlow.wrappingScript(for: variant.displayText) == .korean else { return false }
        // One short word stacked in its slanted column still reads like the
        // vertical source (an exclamation or sound effect); keep its quad.
        let text = variant.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains(where: \.isWhitespace), text.filter(\.isLetter).count <= 4 { return false }
        func reads(_ layout: BrowserOverlayCardLayout) -> Bool {
            let width = layout.rect.width - layout.contentInsets.left - layout.contentInsets.right
            let font = layout.maximumFontSize
            guard width > 0, variant.minimumUnbrokenWidth(fontSize: font, measurementCache: measurementCache) <= width + 0.5
            else { return false }
            let count = CGFloat(variant.displayText.filter { !$0.isWhitespace }.count)
            let height = variant.measuredSize(width: width, fontSize: font, measurementCache: measurementCache).height
            let lines = max(1, (height / BrowserOverlayFont.system(ofSize: font, weight: .bold).lineHeight).rounded())
            return lines < 3 || count < 5 || count / lines >= 2.5
        }
        return !reads(rotated) && reads(upright) && upright.maximumFontSize >= rotated.maximumFontSize * 0.85
    }

    static func layout(geometry: Geometry, variant: BrowserOverlayDisplayVariant,
                       maximumFontSize: CGFloat, plannedFontSize: CGFloat? = nil, obstacles: [CGRect] = [],
                       displayMargins: Bool = false,
                       measurementCache: BrowserOverlayTextMeasurementCache?) -> BrowserOverlayCardLayout? {
        let padding: CGFloat = min(1.5, min(geometry.rect.width, geometry.rect.height) * 0.04)
        // measuredSize rounds its result upward. Measure against whole-point
        // limits too, otherwise a wrapped line of width 31.2 is reported as 32
        // and incorrectly rejects every font in a 31.6-point column.
        let available = CGSize(width: floor(geometry.rect.width - padding * 2),
                               height: floor(geometry.rect.height - padding * 2))
        let minimum = BrowserOverlayLayoutPlanner.minimumRenderedFontSize
        // A detector quad can enclose or touch other captions. Growth above the
        // planned size may not reach further into their source boxes than the
        // planned text block did (centered text block, page-axis footprint).
        let c = abs(cos(geometry.radians)), s = abs(sin(geometry.radians))
        func obstruction(_ block: CGSize) -> CGFloat {
            let width = block.width * c + block.height * s, height = block.width * s + block.height * c
            let footprint = CGRect(x: geometry.rect.midX - width / 2, y: geometry.rect.midY - height / 2,
                                   width: width, height: height)
            return obstacles.reduce(0) { sum, obstacle in
                let overlap = footprint.intersection(obstacle)
                return overlap.isNull ? sum : sum + overlap.width * overlap.height
            }
        }
        var plannedObstruction: CGFloat?
        func fits(_ size: CGFloat) -> Bool {
            if variant.vertical {
                guard BrowserOverlayVerticalTextRenderer.fits(text: variant.displayText, available: available,
                                                             fontSize: size, weight: .heavy) else { return false }
                guard let plannedFontSize, size > plannedFontSize else { return true }
                return obstruction(available) == 0
            }
            // Display lettering above the planned size keeps a margin inside its
            // card that grows with the type (as the overlay's plate growth does).
            let inset = displayMargins && size > (plannedFontSize ?? .infinity)
                ? max(0, min(8, max(3, size * 0.1)) - padding) : 0
            let room = CGSize(width: available.width - inset * 2, height: available.height - inset * 2)
            guard room.width > 0, room.height > 0 else { return false }
            let measured = variant.measuredSize(width: room.width, fontSize: size, measurementCache: measurementCache)
            guard measured.width <= room.width + 0.01, measured.height <= room.height + 0.01 else { return false }
            // Growth above the planned size must not split a word that the
            // planned size kept whole, or stack a sentence into one- or
            // two-syllable lines.
            guard let plannedFontSize, size > plannedFontSize else { return true }
            // The planned size is judged in the card it was planned for.
            let unbroken = { (font: CGFloat, width: CGFloat) in
                variant.minimumUnbrokenWidth(fontSize: font, measurementCache: measurementCache) <= width + 0.01
            }
            guard unbroken(size, room.width) || !unbroken(plannedFontSize, available.width) else { return false }
            let count = CGFloat(variant.displayText.filter { !$0.isWhitespace }.count)
            func lineCount(_ height: CGFloat, _ font: CGFloat) -> CGFloat {
                max(1, (height / BrowserOverlayFont.system(ofSize: font, weight: .bold).lineHeight).rounded())
            }
            let lines = lineCount(measured.height, size)
            // Hangul may wrap between syllables; a new line needs a new word.
            let words = CGFloat(variant.displayText.split(whereSeparator: { $0.isWhitespace }).count)
            let plannedLines = lineCount(variant.measuredSize(width: available.width, fontSize: plannedFontSize,
                                                              measurementCache: measurementCache).height, plannedFontSize)
            guard lines <= max(plannedLines, words) else { return false }
            guard lines < 3 || count < 8 || count / lines >= 2.5 else { return false }
            guard !obstacles.isEmpty else { return true }
            if plannedObstruction == nil {
                plannedObstruction = obstruction(variant.measuredSize(width: available.width, fontSize: plannedFontSize,
                                                                      measurementCache: measurementCache))
            }
            return obstruction(measured) <= (plannedObstruction ?? 0) + 0.5
        }
        guard available.width > 0, available.height > 0, fits(minimum) else { return nil }
        var lower = minimum, upper = max(minimum, maximumFontSize)
        for _ in 0..<10 {
            let candidate = (lower + upper) / 2
            if fits(candidate) { lower = candidate } else { upper = candidate }
        }
        let horizontalPadding = padding + (geometry.panelRect.width - geometry.rect.width) / 2
        let verticalPadding = padding + (geometry.panelRect.height - geometry.rect.height) / 2
        return BrowserOverlayCardLayout(rect: geometry.panelRect, maximumFontSize: floor(lower * 4) / 4,
            contentInsets: UIEdgeInsets(top: verticalPadding, left: horizontalPadding,
                                       bottom: verticalPadding, right: horizontalPadding))
    }
}
