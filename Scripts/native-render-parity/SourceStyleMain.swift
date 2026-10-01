import Foundation

@main enum SourceStyleMain {
    static func main() throws {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let jobs = try JSONSerialization.jsonObject(with: input) as! [[String: Any]]
        var output: [Any] = []
        for job in jobs {
            func data(_ key: String) throws -> Data { try JSONSerialization.data(withJSONObject: job[key]!) }
            func decode<T: Decodable>(_ key: String, _ type: T.Type) throws -> T { try JSONDecoder().decode(type, from: data(key)) }
            func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
            switch job["operation"] as! String {
            case "robust":
                if let v = NativeTranslationSourceStylePostPolish.robustSurfaceInk(source: job["rgb"] as! [Double], histogram: job["histogram"] as! [Int]) {
                    output.append(["ink": v.ink, "contrast": v.contrast, "dim": v.dim, "total": v.total, "range": v.range] as [String: Any])
                } else { output.append(NSNull()) }
            case "releasedOutline":
                if let v = NativeTranslationSourceStylePostPolish.releasedCaptionOutline(sample: job["sample"] as! [String: Any], ring: job["ring"] as? [String: Any], font: job["font"] as! Double) {
                    output.append(["foreground": v.foreground, "stroke": v.stroke, "width": v.width] as [String: Any])
                } else { output.append(NSNull()) }
            case "releasedFill":
                if let v = NativeTranslationSourceStylePostPolish.releasedCaptionFill(sample: job["sample"] as! [String: Any]) {
                    output.append(["foreground": v.foreground, "stroke": NSNull(), "width": 0] as [String: Any])
                } else { output.append(NSNull()) }
            case "observed":
                if let value = NativeTranslationSourceStylePostPolish.observedCaptionStyle(sample: job["sample"] as! [String: Any], font: job["font"] as! Double) {
                    output.append(["fill": value.foreground, "stroke": value.stroke, "width": value.width] as [String: Any])
                } else { output.append(NSNull()) }
            case "dark":
                if let value = NativeTranslationSourceStylePostPolish.darkSurfaceSourceOutline(sample: job["sample"] as! [String: Any],
                    ring: job["ring"] as! [String: Any], font: job["font"] as! Double, certifiedSourcePosition: job["certified"] as! Bool) {
                    output.append(["foreground": value.foreground, "stroke": value.stroke, "width": value.width] as [String: Any])
                } else { output.append(NSNull()) }
            case "caption":
                let value = NativeTranslationSourceStylePostPolish.captionPalette(sample: job["sample"] as! [String: Any],
                    ink: job["rgb"] as? [Double], preserveText: job["preserve"] as! Bool, displayInk: job["display"] as? [Double])
                output.append(["background": value.background, "foreground": value.foreground, "observed": value.observed, "preserved": value.preserved] as [String: Any])
            case "ink": output.append(try object(NativeTranslationSourceStylePostPolish.inkClusters(decode("entries", [NativeTranslationSourceStylePostPolish.Ink].self))))
            case "stroke": output.append(try object(NativeTranslationSourceStylePostPolish.strokeWidths(decode("records", [NativeTranslationSourceStylePostPolish.Stroke].self))))
            case "class": output.append(NativeTranslationSourceStylePostPolish.colorClass(job["rgb"] as! [Double]))
            case "adjust":
                let range = job["range"] as! [Double]
                let color = NativeTranslationSourceStylePostPolish.adjustInkForContrast(job["rgb"] as! [Double], contrast: {
                    NativeTranslationSourceStylePostPolish.luminanceContrast(NativeTranslationSourceStylePostPolish.luminance($0), range[0], range[1])
                }, target: job["target"] as? Double ?? 4.5)
                output.append(color)
            default:
                let sample = job["sample"] as! [String: Any], range = job["range"] as! [Double], font = job["font"] as! Double
                let value = job["operation"] as! String == "readable" ?
                    NativeTranslationSourceStylePostPolish.readableSourceOutline(sample: sample, ink: job["rgb"] as! [Double], range: range, font: font) :
                    NativeTranslationSourceStylePostPolish.sourceStyleOutline(sample: sample, range: range, font: font)
                if let value {
                    var encoded = try object(value) as! [String: Any]
                    encoded["expansion"] = value.expansion
                    output.append(encoded)
                } else { output.append(NSNull()) }
            }
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]))
    }
}
