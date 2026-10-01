import Foundation

// Each line is an independent bounded pixel crop. JSON communicates policy
// values only; image loading, Canvas resizing, and estimator differences are
// intentionally outside this direct observed-policy comparison.
while let line = readLine() {
    do {
        let input = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        let rgba = [UInt8](Data(base64Encoded: input["rgba"] as! String)!)
        let width = (input["width"] as! NSNumber).intValue
        let height = (input["height"] as! NSNumber).intValue
        let box = (input["box"] as! [NSNumber]).map(\.doubleValue)
        let result = input["result"] as? [String: Any]
        let hint = input["hint"] as? [String: Any]
        let glyphs = NativeObservedSourcePalette.observedGlyphPalette(rgba: rgba, width: width, height: height, box: box, hint: hint)
        let lettering = NativeObservedSourcePalette.observedLetteringInk(rgba: rgba, width: width, height: height, box: box)
        let display = NativeObservedSourcePalette.resolveDisplayGlyphs(result: result, glyphs: glyphs)
        let stroke = NativeObservedSourcePalette.observedStrokePalette(
            rgba: rgba, width: width, height: height, box: box, glyphs: glyphs, display: display, result: result
        )
        let output: [String: Any] = [
            "glyphs": glyphs as Any? ?? NSNull(), "lettering": lettering as Any? ?? NSNull(),
            "display": display as Any? ?? NSNull(), "stroke": stroke as Any? ?? NSNull(),
            "observedInk": NativeObservedSourcePalette.sourceObservedDisplayInk(sample: result) as Any? ?? NSNull(),
            "displayInk": NativeObservedSourcePalette.sourceDisplayInk(sample: result) as Any? ?? NSNull(),
        ]
        let encoded = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        print(String(decoding: encoded, as: UTF8.self))
    } catch {
        print("{\"error\":\"native policy harness failed\"}")
    }
}
