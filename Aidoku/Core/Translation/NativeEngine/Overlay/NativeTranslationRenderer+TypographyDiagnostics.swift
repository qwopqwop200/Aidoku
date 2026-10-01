import CoreGraphics
import Foundation

extension NativeTranslationRenderer {
    /// Called only by the opt-in renderer diagnostics. These are the final
    /// shaped rows/runs, including the separately shaped absolute child nodes.
    static func finalTypographyDiagnostics(_ card: Card) -> [String: Any] {
        func number(_ value: CGFloat) -> Any { value.isFinite ? Double(value) as Any : NSNull() }
        func point(_ value: CGPoint) -> [Any] { [number(value.x), number(value.y)] }
        func box(_ value: CGRect) -> [Any] {
            [number(value.minX), number(value.minY), number(value.width), number(value.height)]
        }
        func flow(_ layout: NativeTranslationTypography.Layout) -> [String: Any] {
            let source = layout.shapedText as NSString
            let rows: [[String: Any]] = layout.lineRanges.compactMap { range in
                guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
                      range.location <= source.length, range.length <= source.length - range.location else { return nil }
                return ["range": [range.location, range.length], "text": source.substring(with: range)]
            }
            let ownership = layout.sourceUTF16Ownership?.map { range -> [Int] in
                [range.location, range.length]
            } ?? []
            return ["shapedText": layout.shapedText, "rows": rows,
                    "sourceUTF16Ownership": ownership,
                    "coreTextRows": NativeTranslationTypography.diagnosticRuns(layout: layout)]
        }
        var result = flow(card.typography)
        result["parentTextDrawn"] = card.unitTextParts.isEmpty
        result["textOrigin"] = point(card.textOrigin)
        result["rotation"] = number(card.effectiveTextRotation)
        result["parts"] = card.unitTextParts.map { part -> [String: Any] in
            var record = flow(part.typography)
            record["text"] = part.text
            record["frame"] = box(textPartFrame(part, card: card))
            record["horizontalScale"] = number(part.style.horizontalScale)
            return record
        }
        return result
    }
}
