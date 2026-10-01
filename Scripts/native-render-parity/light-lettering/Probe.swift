import Foundation
import CoreGraphics
@main struct Probe {
    static func main() throws {
        let fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: Any]]
        func rect(_ a: [Double]) -> CGRect { CGRect(x: a[0], y: a[1], width: a[2], height: a[3]) }
        var output: [[String: Any]] = []
        for fixture in fixtures {
            let c = fixture["input"] as! [String: Any], expected = fixture["expected"] as! [String: Any]
            let font = c["font"] as! Double, plate = c["plate"] as! [Double], ink = c["ink"] as! [Double]
            let ring = c["ring"] as! [String: Any], mode = c["mode"] as! String
            var record: [String: Any] = [:], rejection: String?, styled = 0, remaining = 49_152
            var sampled: [String: Any]?
            if let style = NativeLightLettering.saturated(mode: mode, font: font, strokeWidth: c["strokeWidth"] as! Double, ring: ring, currentPlate: plate) {
                record = style.record; styled = 1
            } else if mode == "readability-panel", font >= 6 {
                if !NativeLightLettering.darkInkEligible(ink, plate: plate, font: font) { rejection = "ink" }
                else if !NativeLightLettering.hasLightEvidence(sampledFill: c["sampledFill"] as? [Double], sampledStroke: c["sampledStroke"] as? [Double], strokeConfidence: c["strokeConfidence"] as! Double, sampledBackground: c["sampledBackground"] as? [Double], ring: ring) { rejection = "gate" }
                else {
                    let image = c["image"] as! [Double]
                    let result = NativeLightLettering.crop(bounds: c["bounds"] as! [Double], frame: rect(c["frame"] as! [Double]), imageSize: CGSize(width: image[0], height: image[1]), sourceFont: c["sourceFont"] as? Double, plate: rect(c["plateRect"] as! [Double]), remainingPixels: &remaining)
                    rejection = result.rejection
                    if let crop = result.crop, let pixels = expected["sampled"] as? [String: Any] {
                        let rgba = pixels["rgba"] as! [UInt8]
                        sampled = ["source": [crop.source.minX, crop.source.minY, crop.source.width, crop.source.height], "w": crop.width, "h": crop.height, "rgba": rgba]
                        let a = NativeLightLettering.analyze(rgba: rgba, crop: crop, font: font, ink: ink, plate: plate, neighborOverlapsPlate: c["neighbor"] as! Bool)
                        record = a.record; rejection = a.rejection; styled = a.style == nil ? 0 : 1
                    }
                }
            }
            output.append(["record": record, "rejection": rejection as Any? ?? NSNull(), "styled": styled, "remaining": remaining, "sampled": sampled as Any? ?? NSNull()])
        }
        try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    }
}
