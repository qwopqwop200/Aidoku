import Foundation

@main enum ForcedComponentMain {
    static func main() throws {
        let raw = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as! [String: Any]
        let w = raw["width"] as! Int, h = raw["height"] as! Int, values = raw["rgba"] as! [UInt8]
        let foreground = raw["foreground"] as! [Double], background = raw["background"] as! [Double]
        let stroke = raw["stroke"] as? [Double]
        let sample: [String: Any] = ["foreground": foreground, "background": background, "stroke": stroke as Any,
            "confidence": ["foreground": 0.9, "background": 0.9, "stroke": stroke == nil ? 0 : 0.9]]
        let palette = NativeRestorationPixels.Palette(foreground: NativeRestorationRGB(foreground), background: NativeRestorationRGB(background),
            stroke: stroke.map(NativeRestorationRGB.init), metadata: sample)
        var p = NativeRestorationPixels(width: w, height: h); p.rgba = values
        let box = raw["box"] as! [Double]
        let result = NativeResidualProof.forceComponent(p, box: CGRect(x: box[0], y: box[1], width: box[2], height: box[3]),
            auxiliary: [], excluded: [], palette: palette, vertical: false, glyphSize: raw["glyphSize"] as? Double ?? 0)
        let output: [String: Any] = result.map { ["rgba": $0.rgba, "layoutSafe": $0.layoutSafe ?? [], "sourceGlyphsVerified": $0.glyphsVerified,
                                                  "sourceErasureVerified": $0.erasureComplete] } ?? ["missing": true]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: output))
    }
}
