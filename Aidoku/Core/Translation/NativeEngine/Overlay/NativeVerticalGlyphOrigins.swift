import CoreGraphics
import Foundation

/// Literal FontCascadeCoreText::fillVectorWithVerticalGlyphPositions algebra.
/// Inputs use WebKit's rotated user coordinate system, NOT final page axes.
/// Does not alter CSS Range geometry or invent a constant glyph correction.
enum NativeVerticalGlyphOrigins {
    struct Metrics {
        let ascent: Float
        let descent: Float
        var ideographicAscent: Float { (ascent + descent) / 2 }
        var ascentDelta: Float { ideographicAscent - ascent }
    }


    struct IOSMetrics {
        let primary: Metrics
        let leading: Float
        let lineSpacing: Float
    }

    /// FontCoreText.cpp at dd5fe101, PLATFORM(IOS_FAMILY), lines174–180.
    /// Raw inputs are the selected primary font AFTER any OpenType MATH
    /// override. Family-specific 15% adjustment precedes float ceilings.
    /// This policy does not change glyph paths, run fonts, or CSS Range.
    static func iosMetrics(ascent: Double, descent: Double, leading: Double,
                           familyName: String) -> IOSMetrics? {
        guard [ascent,descent,leading].allSatisfy(\.isFinite),
              abs(ascent) <= 65_536, abs(descent) <= 65_536,
              abs(leading) <= 65_536 else { return nil }
        let adjustedFamily = ["times", "helvetica", ".helvetica neueui"]
            .contains(familyName.lowercased())
        // kLineHeightAdjustment is float, while CGFloat inputs are doubles.
        let adjustment = adjustedFamily ? ceil((ascent + descent) * Double(Float(0.15))) : 0
        let gap = ceilf(Float(leading))
        let spacing = Float(ceil(ascent) + adjustment + ceil(descent) + Double(gap))
        return IOSMetrics(primary: Metrics(ascent: ceilf(Float(ascent + adjustment)),
                                           descent: ceilf(Float(descent))),
                          leading: gap, lineSpacing: spacing)
    }

    /// Fixed-pitch vertical-rl root cell: int ideographic ascent plus half
    /// leading is floored by InlineLevelBox::AscentAndDescent::round. The
    /// alphabetic paint origin is then converted by FontCascade's float delta.
    /// cellRight is the used line cell edge, independent of Range/glyph bounds.
    static func ideographicCellBaseline(cellRight: Float, pitch: Float,
                                         metrics: Metrics) -> Float? {
        guard [cellRight,pitch,metrics.ascent,metrics.descent].allSatisfy(\.isFinite),
              pitch >= 0, pitch <= 65_536, abs(metrics.ascent) <= 65_536,
              abs(metrics.descent) <= 65_536 else { return nil }
        let alphabeticA = max(Int(lroundf(metrics.ascent)),0)
        let alphabeticD = Int(lroundf(metrics.descent))
        let height = alphabeticA + alphabeticD
        let ideographicA = height - height / 2
        let halfLeading = (floorf(pitch) - Float(height)) / 2
        let layoutA = floorf(Float(ideographicA) + halfLeading)
        let textBoxRight = cellRight - layoutA + Float(ideographicA)
        return ideographicCrossBaseline(textBoxRight: textBoxRight,
                                         integerAlphabeticAscent: alphabeticA,
                                         metrics: metrics)
    }

    /// Vertical-rl source paint baseline before glyph-specific translation.
    /// TextBoxPainter adds int alphabetic ascent in its rotated coordinates;
    /// FontCascade converts to the floating ideographic baseline. The source
    /// text box right is a placement input, not an enclosing glyph-path bound.
    static func ideographicCrossBaseline(textBoxRight: Float,
                                         integerAlphabeticAscent: Int,
                                         metrics: Metrics) -> Float? {
        guard textBoxRight.isFinite, metrics.ascent.isFinite,
              metrics.descent.isFinite, integerAlphabeticAscent >= 0,
              integerAlphabeticAscent <= 65_536 else { return nil }
        return (textBoxRight - Float(integerAlphabeticAscent)) - metrics.ascentDelta
    }

    /// InlineFormattingUtils::horizontalAlignmentOffset, centered LTR scope.
    /// cssContentRight includes terminal letter spacing; do not replace it
    /// with the last glyph origin or Core Text's internal alignment extent.
    static func centeredInlineShift(flexOrigin: Float, lineLogicalWidth: Float,
                                    cssContentRight: Float, hangingTrailingWidth: Float,
                                    conditionalHanging: Bool,
                                    nativeLineOrigin: Float) -> Float? {
        guard [flexOrigin,lineLogicalWidth,cssContentRight,hangingTrailingWidth,nativeLineOrigin]
            .allSatisfy(\.isFinite), lineLogicalWidth >= 0, hangingTrailingWidth >= 0 else { return nil }
        var right = cssContentRight
        if hangingTrailingWidth != 0 {
            right = conditionalHanging ? min(right,lineLogicalWidth) : right-hangingTrailingWidth
        }
        let room = lineLogicalWidth-right
        let desired = flexOrigin + (room > 0 ? room/2 : 0)
        return desired-nativeLineOrigin
    }

    static func positions(userPoint: CGPoint, metrics: Metrics,
                          textMatrix: CGAffineTransform,
                          translations: [CGSize], advances: [CGSize]) -> [CGPoint]? {
        let scalars = [textMatrix.a,textMatrix.b,textMatrix.c,textMatrix.d,
                       textMatrix.tx,textMatrix.ty,userPoint.x,userPoint.y]
        guard scalars.allSatisfy(\.isFinite), metrics.ascent.isFinite,
              metrics.descent.isFinite, translations.count == advances.count,
              translations.count <= 65_536,
              textMatrix.a * textMatrix.d - textMatrix.b * textMatrix.c != 0,
              translations.allSatisfy({ $0.width.isFinite && $0.height.isFinite }),
              advances.allSatisfy({ $0.width.isFinite && $0.height.isFinite }) else { return nil }
        // FontCascade's public input is FloatPoint and ascentDelta is float.
        var pen = CGPoint(x: CGFloat(Float(userPoint.x)),
                          y: CGFloat(Float(userPoint.y) + metrics.ascentDelta))
        let inverse = textMatrix.inverted()
        // Y-flip followed by left rotation, with synthetic oblique omitted.
        let translationMatrix = CGAffineTransform(a: 0,b: -1,c: -1,d: 0,tx: 0,ty: 0)
        var result: [CGPoint] = []
        for (translation, advance) in zip(translations, advances) {
            let local = translation.applying(translationMatrix)
            let inUser = CGPoint(x: pen.x + local.width, y: pen.y + local.height)
            result.append(inUser.applying(inverse))
            pen.x += advance.width
            pen.y += advance.height
        }
        return result
    }
}
