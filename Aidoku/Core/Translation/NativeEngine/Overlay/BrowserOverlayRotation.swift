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
        guard settings.mode == .translateOnly, settings.textPlacement == .replace,
              item.translatedText?.isEmpty == false, imageSize.width > 0, imageSize.height > 0 else { return nil }
        let polygon = item.sourcePolygon.map { CGPoint(x: sourceRect.minX + $0.x * sourceRect.width / imageSize.width,
                                                       y: sourceRect.minY + $0.y * sourceRect.height / imageSize.height) }
        guard let result = geometry(polygon: polygon,
                                   singleVerticalColumn: item.sourceOrientation == .vertical && item.sourceSingleVerticalColumn == true),
              sourceRect.insetBy(dx: -0.5, dy: -0.5).contains(result.footprint) else { return nil }
        return result
    }

    static func layout(geometry: Geometry, variant: BrowserOverlayDisplayVariant,
                       maximumFontSize: CGFloat, measurementCache: BrowserOverlayTextMeasurementCache?) -> BrowserOverlayCardLayout? {
        let padding: CGFloat = min(1.5, min(geometry.rect.width, geometry.rect.height) * 0.04)
        // measuredSize rounds its result upward. Measure against whole-point
        // limits too, otherwise a wrapped line of width 31.2 is reported as 32
        // and incorrectly rejects every font in a 31.6-point column.
        let available = CGSize(width: floor(geometry.rect.width - padding * 2),
                               height: floor(geometry.rect.height - padding * 2))
        let minimum = BrowserOverlayLayoutPlanner.minimumRenderedFontSize
        func fits(_ size: CGFloat) -> Bool {
            if variant.vertical {
                return BrowserOverlayVerticalTextRenderer.fits(text: variant.displayText, available: available,
                                                             fontSize: size, weight: .heavy)
            }
            let measured = variant.measuredSize(width: available.width, fontSize: size, measurementCache: measurementCache)
            return measured.width <= available.width + 0.01 && measured.height <= available.height + 0.01
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
