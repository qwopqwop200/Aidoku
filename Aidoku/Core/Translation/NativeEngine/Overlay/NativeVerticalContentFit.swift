import CoreGraphics
import Foundation

/// CSSOM layout overflow for the frozen vertical-rl flex text node. Glyph ink,
/// strokes, and rotation do not contribute to its scroll/client dimensions.
enum NativeVerticalContentFit {
    struct Padding { var top: CGFloat; var right: CGFloat; var bottom: CGFloat; var left: CGFloat }
    struct Metrics: Codable, Equatable {
        let clientWidth: Int
        let clientHeight: Int
        let scrollWidth: Int
        let scrollHeight: Int
        var fits: Bool { scrollWidth <= clientWidth && scrollHeight <= clientHeight }
    }
    static func inlineExtent(advances: [CGFloat], ranges: [NSRange], text: String, contentHeight: CGFloat) -> CGFloat? {
        guard advances.count == ranges.count, advances.allSatisfy({ $0.isFinite && $0 >= 0 }),
              contentHeight.isFinite, contentHeight >= 0 else { return nil }
        let utf16 = Array(text.utf16)
        var softWrap = false
        for range in ranges.dropLast() {
            guard range.location >= 0, range.length >= 0, range.location <= utf16.count,
                  range.length <= utf16.count - range.location else { return nil }
            let end = range.location + range.length
            if end > 0 && utf16[end-1] != 10 && utf16[end-1] != 13 { softWrap = true }
        }
        // Flex's min-content extent cannot shrink below an indivisible inline
        // run. Max-content sizes ceil to a LayoutUnit, unlike assigned boxes.
        let intrinsic = ceil((advances.max() ?? 0) * 64) / 64
        return softWrap ? max(contentHeight,intrinsic) : intrinsic
    }
    static func metrics(box requestedBox: CGSize, padding: Padding, columnCount: Int,
        fontSize: CGFloat, lineHeight: CGFloat, inlineExtent: CGFloat,
        alignsToRight: Bool, clips: Bool) -> Metrics? {
        let values = [requestedBox.width,requestedBox.height,padding.top,padding.right,padding.bottom,padding.left,fontSize,lineHeight,inlineExtent]
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 16_777_216 }),
              columnCount >= 0, columnCount <= 16_384 else { return nil }
        let box = CGSize(width: max(requestedBox.width,padding.left+padding.right),
            height: max(requestedBox.height,padding.top+padding.bottom))
        let content = CGSize(width: box.width-padding.left-padding.right,height: box.height-padding.top-padding.bottom)
        // CSS numeric font/line-height values narrow to Float before their
        // integer line-box pitch is selected, including values just below one.
        let width = CGFloat(columnCount)*floor(max(CGFloat(Float(fontSize)),CGFloat(Float(lineHeight))))
        // Negative free space rounds down on the 1/64 layout grid. This also
        // keeps the original right-to-left column anchoring for odd raw units.
        let left = alignsToRight ? box.width-padding.right-width
            : padding.left+floor((content.width-width)*32)/64
        let top = padding.top+floor((content.height-inlineExtent)*32)/64
        var scrollWidth = box.width-left
        if clips && left < 0 { scrollWidth += padding.left }
        let scrollHeight = clips && inlineExtent > content.height
            ? inlineExtent+padding.top+padding.bottom : top+inlineExtent
        func integer(_ value: CGFloat) -> Int { Int(min(CGFloat(Int32.max),floor(max(0,value)+0.5))) }
        return .init(clientWidth: integer(box.width),clientHeight: integer(box.height),
            scrollWidth: integer(max(box.width,scrollWidth)),scrollHeight: integer(max(box.height,scrollHeight)))
    }
}
