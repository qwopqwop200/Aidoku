import Foundation
import CoreGraphics
let text = "아주긴단어를절대로중간분할하지않는것"
let style = NativeTranslationTypography.Style(fontScript: "korean", fontSize: 20,
    lineHeight: 24, optimizesKoreanWrapping: false, alignsToTop: true, keepsWholeWords: true)
let overflow = NativeTranslationTypography.layout(text: text, in: CGSize(width: 35, height: 200), style: style)
precondition(overflow.lineCount == 1 && overflow.shapedText == text && !overflow.fits)
precondition(overflow.inkBounds.minX < 0 && overflow.inkBounds.maxX > 35)
let normal = NativeTranslationTypography.layout(text: "  너희\t먼저 \n먹어.  ", in: CGSize(width: 85, height: 200), style: style)
precondition(normal.shapedText == "너희 먼저\n먹어.")
precondition(normal.lineCount == 2)
let words = ["너희", "먼저", "먹어."]
for word in words { precondition(normal.shapedText.contains(word)) }
print(String(data: try JSONSerialization.data(withJSONObject: ["passed":true,"longWordOverflowPreserved":true,
    "normalWhitespaceCollapsed":true,"wrappedLines":normal.lineCount,"rangeCount":normal.rangeBounds.count], options: .sortedKeys), encoding: .utf8)!)
