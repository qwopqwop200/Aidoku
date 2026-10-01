import Foundation
@main struct Probe {
    static func main() throws {
        let fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: Any]]
        var output: [[[String: Any]]] = []
        for fixture in fixtures {
            let entries = (fixture["input"] as! [[String: Any]]).map { c -> NativeInitialJoinedUnit.Entry in
                let b = c["balloonInterior"] as? [String: Any] ?? [:]
                return .init(rect: CGRect(x: c["x"] as! Double, y: c["y"] as! Double, width: c["width"] as! Double, height: c["height"] as! Double),
                    font: c["fontSize"] as! Double, frame: c["sourceFrame"] as! [Double], source: c["sourceBounds"] as! [Double],
                    interior: b["rect"] as? [Double] ?? [], spans: b["spans"] as? [Double] ?? [],
                    joined: c["joined"] as? Bool ?? false, residue: c["residue"] as? Bool ?? false,
                    rotated: (c["rotation"] as? NSNumber)?.doubleValue != nil && (c["rotation"] as! NSNumber).doubleValue != 0,
                    vertical: c["vertical"] as? Bool ?? false, kept: c["kept"] as? Bool ?? false)
            }
            func rect(_ r: CGRect) -> [Double] { [r.origin.x,r.origin.y,r.size.width,r.size.height] }
            output.append(NativeInitialJoinedUnit.fit(entries).map { ["rect": rect($0.rect), "planned": $0.planned.map(rect) as Any? ?? NSNull()] })
        }
        try JSONSerialization.data(withJSONObject: output).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    }
}
