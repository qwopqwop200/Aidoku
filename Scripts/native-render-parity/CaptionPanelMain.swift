import Foundation
import CoreGraphics

@main enum CaptionPanelMain {
    static func main() throws {
        let jobs = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as! [[String: Any]]
        func rect(_ v: Any) -> CGRect { let q = v as! [Double]; return CGRect(x: q[0], y: q[1], width: q[2], height: q[3]) }
        func array(_ r: CGRect) -> [Double] { [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)] }
        var output: [Any] = []
        for job in jobs {
            let entries = (job["entries"] as! [[String: Any]]).map { v -> NativeTranslationCaptionPanelPolish.Entry in
                let panels = (v["panels"] as! [[String: Any]]).map { p -> NativeTranslationSourceStylePostPolish.Panel in
                    var value = NativeTranslationSourceStylePostPolish.Panel(rect: rect(p["rect"]!), background: p["background"] as! [Double],
                        coverage: (p["coverage"] as! [[Double]]).map(rect))
                    value.sourceErasure = p["sourceErasure"] as? Bool ?? false; value.clipped = p["clipped"] as? Bool ?? false
                    return value
                }
                return NativeTranslationCaptionPanelPolish.Entry(id: v["id"] as! String, sourceTextOnly: false, rotation: 0,
                    vertical: false, lettering: nil, wrappingScript: "korean", font: v["font"] as! Double,
                    frame: rect(v["frame"]!), sources: (v["sources"] as! [[Double]]).map(rect), balancedColumn: v["balanced"] as? Bool ?? false,
                    column: v["column"].map(rect), columnPaddingTop: 0, ink: rect(v["ink"]!), panels: panels)
            }
            let resolved = NativeTranslationCaptionPanelPolish.polish(entries, opacity: job["opacity"] as? Double ?? 1,
                kept: (job["kept"] as! [[Double]]).map(rect))
            output.append(resolved.map { e -> [String: Any] in
                ["id": e.id, "ink": array(e.ink), "panels": e.panels.map { p -> [String: Any] in
                    ["rect": array(p.rect), "coverage": p.coverage.map(array)] }]
            })
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: output))
    }
}
