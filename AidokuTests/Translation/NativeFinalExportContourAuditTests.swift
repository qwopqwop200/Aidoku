import Testing

struct NativeFinalExportContourAuditTests {
    @Test func semanticStyleAndScalarGeometryAreMandatory() {
        let (card, layer) = metadata()
        #expect(matches(card, layer))
        for key in ["id", "text", "fontSize", "foreground", "outlinePaintOrder", "typographyFinal", "pageRangeBounds"] {
            var malformed = card; malformed.removeValue(forKey: key)
            #expect(!matches(malformed, layer))
        }
        for (key, value) in [("id", "other"), ("text", "나"), ("outlinePaintOrder", "strokeThenFill"), ("fontName", "serif")] {
            var changed = card; changed[key] = value
            #expect(!matches(changed, layer))
        }
        for key in ["fontWeight", "fontStyle", "opacity", "visibility", "fontFamily", "fontSize", "color", "transform"] {
            var missing = layer, style = layer["style"] as? [String: Any] ?? [:]
            style.removeValue(forKey: key); missing["style"] = style
            #expect(!matches(card, missing))
        }
        var changed = layer
        changed["scalarRects"] = [["scalar": "나", "rect": ["x": 10, "y": 10, "width": 20, "height": 14]]]
        #expect(!matches(card, changed))
    }

    @Test func malformedAndUnboundedGeometryFailsBeforeIntegerConversion() {
        let (card, layer) = metadata()
        for key in ["fontSize", "lineHeight", "outlineWidth", "horizontalScale", "rotation"] {
            for value in [Double.infinity, -Double.infinity, Double.nan, 1e308, -1e308] {
                var malformed = card; malformed[key] = value
                #expect(!matches(malformed, layer))
            }
        }
        for component in 0..<4 {
            for value in [Double.infinity, Double.nan, 1e308, -1e308, -1] {
                var malformed = card, rect = [10.0, 10.0, 20.0, 14.0]
                rect[component] = value; malformed["pageRangeBounds"] = [rect]
                #expect(!matches(malformed, layer))
            }
        }
        for key in ["x", "y", "width", "height"] {
            var malformed = layer, rect: [String: Any] = ["x": 10, "y": 10, "width": 20, "height": 14]
            rect[key] = 1e308; malformed["scalarRects"] = [["scalar": "가", "rect": rect]]
            #expect(!matches(card, malformed))
        }
        var booleanFont = card; booleanFont["fontSize"] = true
        #expect(!matches(booleanFont, layer))
        let invalidScale = NativeFinalExportContourAudit.glyphDescriptor(card: card, layers: [layer],
            scale: .infinity, width: 300, height: 300) == nil
        #expect(invalidScale)
    }

    @Test func balancedStrokeRedistributionAndErasureCannotBorrowCoverage() {
        let width = 64, height = 64
        var reference = [UInt8](repeating: 255, count: width * height * 4)
        func paint(_ bytes: inout [UInt8], x: ClosedRange<Int>, y: ClosedRange<Int>, color: UInt8) {
            for row in y { for column in x { for channel in 0..<3 { bytes[(row * width + column) * 4 + channel] = color } } }
        }
        // Two stems joined at the bottom form one component. Grow the left stem
        // while shrinking the right equally: total/component mass cancels exactly.
        paint(&reference, x: 15...18, y: 15...40, color: 3)
        paint(&reference, x: 35...38, y: 15...40, color: 3)
        paint(&reference, x: 15...38, y: 37...40, color: 3)
        var balanced = reference
        paint(&balanced, x: 19...19, y: 15...36, color: 3)
        paint(&balanced, x: 38...38, y: 15...36, color: 255)
        for actual in [balanced, [UInt8](repeating: 255, count: reference.count)] {
            let rejected = NativeFinalExportGlyphContourAcceptance.evaluate(reference: reference, actual: actual,
                width: width, height: height, foreground: [3, 3, 3], outline: [255, 255, 255]) == nil
            #expect(rejected)
        }
    }

    private func matches(_ card: [String: Any], _ layer: [String: Any]) -> Bool {
        NativeFinalExportContourAudit.glyphDescriptor(card: card, layers: [layer], scale: 3, width: 300, height: 300) != nil
    }

    private func metadata() -> ([String: Any], [String: Any]) {
        let card: [String: Any] = ["id": "text", "text": "가", "removed": false, "hidden": false,
            "fontName": "system", "fontSize": 10, "lineHeight": 12, "foreground": [3, 3, 3], "outline": [255, 255, 255],
            "outlineWidth": 1, "outlinePaintOrder": "fillThenStroke", "rotation": 0, "horizontalScale": 1,
            "pageRangeBounds": [[10, 10, 20, 14]], "typographyFinal": ["shapedText": "가", "coreTextRows": [
                ["text": "가", "runs": [["fontName": "AppleSDGothicNeo-Bold", "fontSize": 10]]]]]]
        let style: [String: Any] = ["fontSize": "10px", "lineHeight": "12px", "fontWeight": "700", "fontStyle": "normal",
            "opacity": "1", "visibility": "visible", "fontFamily": "Apple SD Gothic Neo", "color": "rgb(3, 3, 3)",
            "webkitTextStrokeWidth": "1px", "webkitTextStrokeColor": "rgb(255, 255, 255)", "paintOrder": "normal", "transform": "none"]
        let layer: [String: Any] = ["id": "text", "kind": "item", "text": "가", "style": style,
            "scalarRects": [["scalar": "가", "rect": ["x": 10, "y": 10, "width": 20, "height": 14]]]]
        return (card, layer)
    }
}
