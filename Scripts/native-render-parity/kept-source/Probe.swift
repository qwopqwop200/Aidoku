import Foundation
import CoreGraphics
@main struct KeptSourceProbe {
    static func main() throws {
        let args = CommandLine.arguments
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[1]))) as! [[String: Any]]
        var output: [[String: Any]] = []
        func rect(_ r: [Double]) -> CGRect { CGRect(x: r[0], y: r[1], width: r[2], height: r[3]) }
        func array(_ r: CGRect) -> [Double] { [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)] }
        for f in rows {
            let kept = (f["kept"] as! [[String: Any]]).map { value in
                NativeKeptSourceRestoration.Kept(id: value["id"] as! String,
                    rect: CGRect(x: value["x"] as! Double, y: value["y"] as! Double,
                        width: value["width"] as! Double, height: value["height"] as! Double),
                    sourceFontSize: value["sourceFontSize"] as? Double)
            }
            let zones = NativeKeptSourceRestoration.zones(kept: kept, painted: (f["painted"] as! [[Double]]).map(rect))
            let effects = (f["effects"] as! [[String: Any]]).map { value in
                NativeKeptSourceRestoration.Zone(id: value["id"] as! String, rect: rect(value["rect"] as! [Double]))
            }
            let result = NativeKeptSourceRestoration.select(kept: kept, keptZones: zones, effectZones: effects,
                glyphLines: (f["glyphs"] as! [[Double]]).map(rect), covers: (f["covers"] as! [[Double]]).map(rect),
                image: rect(f["image"] as! [Double]), blankMargins: (f["blank"] as! [[Double]]).map(rect))
            output.append(["zones": zones.map { ["id": $0.id, "rect": array($0.rect)] },
                "selection": ["pieces": result.pieces.map(array), "collisions": result.collisions.sorted(),
                    "overlaps": result.overlaps.sorted(), "restoredIDs": result.restoredIDs.sorted()]])
        }
        try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]).write(to: URL(fileURLWithPath: args[2]))
    }
}
