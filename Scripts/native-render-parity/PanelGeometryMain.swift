import CoreGraphics
import Foundation

@main enum PanelGeometryMain {
    static func main() throws {
        let jobs = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as! [[String: Any]]
        func rect(_ value: Any) -> CGRect { let r = value as! [Double]; return CGRect(x: r[0], y: r[1], width: r[2], height: r[3]) }
        func array(_ r: CGRect) -> [Double] { [r.origin.x, r.origin.y, r.size.width, r.size.height].map { Double($0) } }
        func layers(_ value: Any) -> [NativePanelGeometry.Layer] {
            (value as! [[String: Any]]).map { .init(rect: rect($0["rect"]!), color: $0["color"] as! [Double], coverage: ($0["coverage"] as! [[Double]]).map(rect)) }
        }
        let outputs: [Any] = jobs.map { j in
            let r = (j["rects"] as? [[Double]] ?? []).map(rect), ink = (j["ink"] as? [Double]).map(rect)
            switch j["op"] as! String {
            case "solid": return NativePanelGeometry.solidPanelCoverage(r).map(array)
            case "subtract": return NativePanelGeometry.subtractRects(r, cut: rect(j["cut"]!)).map(array)
            case "compact":
                guard let v = NativePanelGeometry.compactPanel(rect(j["panel"]!), ink: ink!, required: (j["required"] as! [[Double]]).map(rect), neighbors: r, pad: j["pad"] as! Double) else { return NSNull() }
                return ["frame": array(v.frame), "coverage": v.coverage.map(array)]
            case "visible": return NativePanelGeometry.visiblePanelColors(ink!, layers: layers(j["layers"]!), fallback: j["fallback"] as! [Double])
            case "backing": return NativePanelGeometry.textBackingRect(ink!, panel: rect(j["panel"]!), neighbors: r).map(array) as Any? ?? NSNull()
            case "needs": return NativePanelGeometry.needsTextBacking(ink, owner: j["owner"] as! Int, panels: layers(j["layers"]!))
            case "keeps": return NativePanelGeometry.textBackingKeepsContrast(ink, owner: j["owner"] as! Int, panels: layers(j["layers"]!), contrast: { $0[0] })
            case "anchor":
                guard let v = NativePanelGeometry.sourceAnchorShift(ink!, source: rect(j["source"]!), plate: rect(j["panel"]!), obstacles: r, leavesOverlap: j["leavesOverlap"] as! Bool) else { return NSNull() }
                return ["dx": Double(v.x), "dy": Double(v.y)]
            case "finalAnchor":
                guard let v = NativePanelGeometry.finalSourceAnchorShift(ink!, source: rect(j["source"]!), plate: rect(j["panel"]!),
                    obstacles: r, home: (j["home"] as? [Double]).map(rect), sourceFont: j["sourceFont"] as? Double,
                    nonSpaceCharacters: j["characters"] as! Int) else { return NSNull() }
                return ["dx": Double(v.x), "dy": Double(v.y)]
            case "packing": return NativePanelGeometry.packingRetainsSourceAnchor(originalInk: rect(j["original"]!),
                proposedInk: ink!, source: rect(j["source"]!), cell: rect(j["panel"]!), obstacles: r)
            default: fatalError("Unknown geometry operation")
            }
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: outputs))
    }
}
