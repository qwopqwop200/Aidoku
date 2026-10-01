import Foundation
@main struct CaptionPolicyProbe {
    static func main() throws {
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: Any]]
        var results: [Any] = []
        for row in rows {
            let name = row["name"] as! String, arguments = row["args"] as! [Any]
            let rgba = (arguments[0] as! [NSNumber]).map { UInt8($0.intValue) }, width = arguments[1] as! Int, height = arguments[2] as! Int
            let box = arguments[3] as? [Double] ?? [0, 0, Double(width), Double(height)]
            let palette = arguments.count > 4 ? arguments[4] as? [String: Any] : nil
            let output: [String: Any]?
            switch name {
            case "recoverSourcePanel": output = NativeCaptionSourcePalette.recoverSourcePanel(rgba: rgba, width: width, height: height, box: box, result: palette)
            case "recoverOutlinedColor":
                output = NativeCaptionSourcePalette.recoverOutlinedColor(rgba: rgba, width: width, height: height, result: arguments[3] as? [String: Any],
                    allowDark: arguments.count > 4 ? arguments[4] as? Bool ?? false : false, opaque: arguments.count > 5 ? arguments[5] as? Bool ?? false : false)
            case "observedSourceSurface": output = NativeCaptionSourcePalette.observedSourceSurface(rgba: rgba, width: width, height: height, box: box, result: palette)
            case "observedCaptionPalette": output = NativeCaptionSourcePalette.observedCaptionPalette(rgba: rgba, width: width, height: height, box: box, result: palette)
            case "recoverHaloInk": output = NativeCaptionSourcePalette.recoverHaloInk(rgba: rgba, width: width, height: height, box: box)
            case "interiorCaptionSurface": output = NativeCaptionSourcePalette.interiorCaptionSurface(rgba: rgba, width: width, height: height, box: box, result: palette)
            case "observedCaptionBackground": output = NativeCaptionSourcePalette.observedCaptionBackground(rgba: rgba, width: width, height: height, box: box, result: palette,
                haloReach: arguments.count > 5 ? arguments[5] as? Int ?? 2 : 2)
            default: fatalError("Unknown policy fixture")
            }
            results.append(output as Any? ?? NSNull())
        }
        try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    }
}
