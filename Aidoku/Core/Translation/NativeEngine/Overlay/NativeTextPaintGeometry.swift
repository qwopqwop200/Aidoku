import CoreGraphics
import Foundation

/// CSS anonymous flex placement and the Float paint anchor used by WebKit.
/// Keep this separate from glyph shaping and explicit block/span layouts.
enum NativeTextPaintGeometry {
    struct FlexBox {
        let origin: CGFloat
        let width: CGFloat

        /// Float InlineLayoutUnit arithmetic after a source-proven item width.
        /// The subtraction must narrow before halving the remaining space.
        func inlineCenteredLineOrigin(lineWidth: CGFloat) -> CGFloat? {
            guard lineWidth.isFinite, lineWidth >= 0, origin.isFinite, width.isFinite else { return nil }
            let usedWidth = Float(lineWidth), availableWidth = Float(width), lineLeft = Float(origin)
            guard usedWidth.isFinite, availableWidth.isFinite, lineLeft.isFinite else { return nil }
            let remaining = availableWidth - usedWidth
            guard remaining.isFinite else { return nil }
            let result = lineLeft + max(0, remaining) / 2
            return result.isFinite ? CGFloat(result) : nil
        }

        /// `lineWidth` excludes whitespace hanging past a soft line break.
        func lineOrigin(lineWidth: CGFloat, alignment: CGFloat = 0.5) -> CGFloat? {
            guard lineWidth.isFinite, lineWidth >= 0, alignment.isFinite,
                  alignment >= 0, alignment <= 1 else { return nil }
            // FontCascade::width returns float before centered inline placement.
            // Narrowing only the final absolute FloatPoint can select the
            // adjacent float when the line width puts it on a rounding tie.
            let usedWidth = alignment == 0.5 ? CGFloat(Float(lineWidth)) : lineWidth
            guard usedWidth.isFinite else { return nil }
            return origin + max(0, width - usedWidth) * alignment
        }
    }

    // InlineFormattingContext::computedIntrinsicWidthConstraints ceilings the
    // unwrapped raw paragraphs. FlexFormattingUtils divides LayoutUnit space;
    // InlineFormattingUtils then aligns each line using floating-point width.
    static func anonymousFlexBox(contentWidth: CGFloat, maximumContentWidth: CGFloat,
                                 minimumContentWidth: CGFloat = 0, justification: CGFloat = 0.5) -> FlexBox? {
        guard contentWidth.isFinite, maximumContentWidth.isFinite, minimumContentWidth.isFinite,
              contentWidth > 0, maximumContentWidth >= 0, minimumContentWidth >= 0,
              justification.isFinite, justification >= 0, justification <= 1,
              max(contentWidth, maximumContentWidth, minimumContentWidth) < 16_777_216 else { return nil }
        let available = CGFloat((Float(contentWidth) * 64).rounded(.towardZero)) / 64
        let maximum = CGFloat((Float(maximumContentWidth) * 64).rounded(.up)) / 64
        let minimum = CGFloat((Float(minimumContentWidth) * 64).rounded(.up)) / 64
        let width = max(minimum, min(available, maximum))
        let origin = ((available - width) * justification * 64).rounded(.towardZero) / 64
        return FlexBox(origin: origin, width: width)
    }

    // TextBoxPainter converts the baseline to LayoutUnit before device snapping;
    // TextPainter passes an absolute FloatPoint to CGContextTranslateCTM.
    static func paintOrigin(_ point: CGPoint, deviceScale: CGFloat?) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite,
              abs(point.x) < 16_777_216, abs(point.y) < 16_777_216 else { return nil }
        var y = Double(Float(point.y))
        if let deviceScale {
            let scale = Double(Float(deviceScale))
            guard scale.isFinite, scale > 0 else { return nil }
            let raw = (y * 64).rounded(.towardZero)
            let unit = raw / 64
            // Match LayoutUnit's translated-origin treatment of negative ties.
            y = unit >= 0 ? (unit * scale).rounded() / scale
                : ((unit - raw) * scale).rounded() / scale + raw
        }
        return CGPoint(x: CGFloat(Float(point.x)), y: CGFloat(Float(y)))
    }
}
