import CoreText
import CoreGraphics
import Foundation

extension NativeWholeWordWrap {
    struct Proposal {
        let width: CGFloat
        let result: Result
        let singleLetterRows: Int
        let overflowRows: Int
    }

    /// Finite fill-body alternatives for parent's free-space allocator. Caller
    /// owns admissible width, paragraph ownership and collision admission.
    /// No stroke radius enters shaping or font selection.
    static func proposals(text: String, font: CTFont, size: CGFloat,
                          width: CGFloat, maximumWidth: CGFloat,
                          tracking: CGFloat = 0, color: CGColor = CGColor(gray: 0, alpha: 1)) throws -> [Proposal] {
        guard maximumWidth.isFinite, maximumWidth >= width else { throw Failure.invalidInput }
        let initial = try layout(text: text, font: font, size: size, width: width, tracking: tracking, color: color)
        let widths = Set([width, min(maximumWidth, max(width, initial.requiredWidth)),
                          min(maximumWidth,width*1.15), min(maximumWidth,width*1.35), maximumWidth]).sorted()
        return try widths.map { w in
            let result = w == width ? initial : try layout(text: text, font: font, size: size,
                                                         width: w, tracking: tracking, color: color)
            let ns = text as NSString
            let singles = result.rows.filter { row in
                ns.substring(with: row.paintedRange).filter { $0.isLetter }.count == 1
            }.count
            return Proposal(width: w, result: result, singleLetterRows: singles,
                            overflowRows: result.rows.filter { $0.overflow > 0.01 }.count)
        }
    }
}
