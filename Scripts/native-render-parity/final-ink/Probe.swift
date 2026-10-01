import Foundation
@main struct Probe {
    static func main() throws {
        let fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: Any]]
        var output: [[[String: Any]]] = []
        for fixture in fixtures {
            let input = fixture["input"] as! [[String: Any]]
            let records = input.map { c -> NativeTranslationSourceStylePostPolish.Display in
                NativeTranslationSourceStylePostPolish.Display(id: c["id"] as! String, eligible: c["eligible"] as! Bool,
                    sourceTextOnly: c["sourceTextOnly"] as! Bool, rotation: c["rotation"] as! Double, script: "korean", vertical: false,
                    fontName: "system", fontWeight: "700", glyph: 12, font: c["font"] as! Double, sample: c["sample"] as! [String: Any],
                    foreground: c["foreground"] as! [Double], stroke: c["stroke"] as? [Double], strokeWidth: c["strokeWidth"] as! Double,
                    textPreserved: true, strokePreserved: c["strokePreserved"] as! Bool, darkMeasured: false, captionBackground: nil,
                    ownerBackground: c["ownerBackground"] as? [Double], restored: c["restored"] as! Bool, surfaceRange: c["surfaceRange"] as? [Double],
                    overlappingSurfaceLuminances: (c["overlapColors"] as! [[Double]]).map(NativeTranslationSourceStylePostPolish.luminance),
                    cluster: c["cluster"] as? [Double], partialSourcePositionProof: c["partialSourcePositionProof"] as! Bool,
                    inkBeforeSurface: c["inkBeforeSurface"] as? [Double], surfaceHistogram: c["surfaceHistogram"] as? [Int])
            }
            let result = NativeTranslationSourceStylePostPolish.resolve(records, preserveText: true, opacity: 1, clusterStrokes: false, stage: .finalContrast)
            output.append(result.map { ["foreground": $0.foreground, "stroke": $0.stroke as Any? ?? NSNull(),
                "strokeWidth": $0.strokeWidth, "strokePreserved": $0.strokePreserved, "cluster": $0.cluster as Any? ?? NSNull()] })
        }
        try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    }
}
