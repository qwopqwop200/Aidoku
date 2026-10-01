import Foundation
import CoreGraphics
@main struct RecoveredLineProbe {
    static func main() throws {
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: Any]]
        func rect(_ r: [Double]) -> CGRect { CGRect(x: r[0], y: r[1], width: r[2], height: r[3]) }
        func array(_ r: CGRect) -> [Double] { [Double(r.origin.x), Double(r.origin.y), Double(r.size.width), Double(r.size.height)] }
        var results: [[String: Any]] = []
        for row in rows {
            let raw = row["items"] as! [[String: Any]], frame = rect(row["frame"] as! [Double])
            let items = raw.map { item -> NativeRecoveredLineProtection.Item in
                let fallback = item["fallback"] as? [Double]
                let plates = (item["plates"] as! [[String: Any]]).filter { $0["visible"] as? Bool != false }.map { plate in
                    NativeRecoveredLineProtection.Plate(rect: rect(plate["rect"] as! [Double]), color: plate["color"] as? [Double] ?? fallback)
                }
                return .init(id: item["id"] as! String, recoveredLine: item["recovered"] as! Bool,
                    sourceBounds: item["bounds"] as! [Double], sourceFontSize: item["font"] as? Double,
                    hasNode: item["hasNode"] as? Bool != false, plates: plates)
            }
            let iw = row["iw"] as! Int, ih = row["ih"] as! Int
            let background = row["background"] as! [UInt8], art = row["art"] as! [[Double]]
            var crops: [[Int]] = []
            let result = try NativeRecoveredLineProtection.evaluate(items: items, cleanupFrame: frame,
                imageSize: row["complete"] as? Bool == false ? .zero : CGSize(width: iw, height: ih), opacity: row["opacity"] as! Double) { crop in
                crops.append([crop.x,crop.y,crop.sourceWidth,crop.sourceHeight,crop.width,crop.height])
                var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
                for y in 0..<crop.height { for x in 0..<crop.width {
                    let sx = Int(floor(Double(crop.x) + (Double(x) + 0.5) * Double(crop.sourceWidth) / Double(crop.width)))
                    let sy = Int(floor(Double(crop.y) + (Double(y) + 0.5) * Double(crop.sourceHeight) / Double(crop.height)))
                    let color = art.last(where: { Double(sx) >= $0[0] && Double(sy) >= $0[1] && Double(sx) < $0[0]+$0[2] && Double(sy) < $0[1]+$0[3] })?.suffix(4).map { UInt8($0) } ?? background
                    let p = (y * crop.width + x) * 4; pixels.replaceSubrange(p..<p+4, with: color)
                } }
                return pixels
            }
            let kept = result.kept.map { NativeKeptSourceRestoration.Kept(id: $0.id, rect: $0.rect, sourceFontSize: $0.sourceFontSize) }
            let zones = NativeKeptSourceRestoration.zones(kept: kept, painted: result.painted)
            results.append(["dropped": result.droppedIDs.sorted(),
                "shares": Dictionary(result.shares.map { ($0.id, $0.value.map { $0 as Any } ?? NSNull()) }, uniquingKeysWith: { _, last in last }),
                "kept": result.kept.map { ["id": $0.id, "rect": array($0.rect), "font": $0.sourceFontSize.map { $0 as Any } ?? NSNull()] },
                "zones": zones.map { ["id": $0.id, "rect": array($0.rect)] },
                "budget": result.remainingBudget, "crops": crops])
        }
        try JSONSerialization.data(withJSONObject: results, options: .sortedKeys).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    }
}
