import Foundation
import CoreGraphics

@main enum BalloonPanelMain {
    static func main() throws {
        func rect(_ v: Any) -> CGRect { let r = v as! [Double]; return CGRect(x: r[0], y: r[1], width: r[2], height: r[3]) }
        func array(_ r: CGRect) -> [Double] { [r.origin.x, r.origin.y, r.size.width, r.size.height].map { Double($0) } }
        let jobs = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as! [[String: Any]]
        var outputs: [Any] = []
        for job in jobs {
            let entries = job["entries"] as! [[String: Any]]
            let records = entries.map { e -> NativePanelGeometry.Record in
                let source = rect(e["source"]!), panel = rect(e["panel"]!), font = e["font"] as! Double
                var r = NativePanelGeometry.Record(id: e["id"] as! String, ink: rect(e["ink"]!), source: source, sources: [source],
                    sourceColorEligible: true, sourceTextOnly: false, balancedColumn: false, vertical: false, rotation: 0,
                    font: font, sourceFont: font, sourceVertical: false, inkPadding: 0, foreground: [0, 0, 0], fallbackBackground: [255, 255, 255],
                    panels: [.init(rect: panel, background: [255, 255, 255], coverage: [panel])])
                r.glyphs = [r.ink]; r.strokeWidth = e["stroke"] as! Double
                if let spans = e["spans"] as? [Double] {
                    r.balloon = .init(frame: rect(e["frame"]!), rect: rect(e["balloonRect"]!), spans: spans, contourVerified: true)
                }
                return r
            }
            let resolved = NativePanelGeometry.containBalloonPanels(records, measure: { id, candidate, font in
                let entry = entries.first { $0["id"] as! String == id }!
                let count = entry["characters"] as! Int, width = candidate.width - 2
                let lineCount = max(1, Int(floor(width / (font * 0.5))))
                var glyphs: [CGRect] = [], remaining = count, line = 0
                while remaining > 0 {
                    let chars = min(remaining, lineCount)
                    glyphs.append(CGRect(x: candidate.minX + 1, y: candidate.minY + 1 + CGFloat(line) * font,
                        width: CGFloat(chars) * font * 0.5, height: font))
                    remaining -= chars; line += 1
                }
                return .init(glyphs: glyphs, scrollFits: font * Double(line) + 2 <= candidate.height + 1)
            })
            outputs.append(resolved.map { r -> [String: Any] in
                var out: [String: Any] = ["id": r.id, "panel": array(r.panels[0].rect), "coverage": r.panels[0].coverage.map(array)]
                if let result = r.balloonResult { out["result"] = result }
                if let font = r.reflowFont { out["font"] = font }
                return out
            })
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: outputs))
    }
}
