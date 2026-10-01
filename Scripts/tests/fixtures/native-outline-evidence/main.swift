import Foundation
import CoreGraphics
let fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: Any]]
let outputs: [[String: Any]] = fixtures.map { f in
    let p = (f["rgba"] as! [Int]).map(UInt8.init), w = f["width"] as! Int, h = f["height"] as! Int, box = f["box"] as! [Int], glyph = f["glyph"] as! Double
    let result = NativeSourceOutlineEvidence.ringPair(rgba: p, width: w, height: h, box: box, glyph: glyph, candidates: (f["candidates"] as! [[Double]]).map { $0 })
    var ring: Any = NSNull()
    if let r = result.ring {
        var d: [String: Any] = ["core": r.core, "outline": r.outline, "uniform": r.uniform, "hug": r.hug, "width": r.width,
            "boxRing": r.boxRing as Any? ?? NSNull(), "reached": r.reached, "exterior": r.exterior as Any? ?? NSNull(), "kind": r.kind,
            "structure": ["band": r.structure.band, "deep": r.structure.deep, "fillN": r.structure.fillN, "ringN": r.structure.ringN]]
        if let s = r.surface {
            d["surface"] = ["rgb": s.rgb, "flat": s.flat, "close": s.close, "reads": [[0.0,0,0],[255.0,255,255],[120.0,80,180]].map { s.reads($0, ratio: 4.5) }]
        } else { d["surface"] = NSNull() }
        ring = d
    }
    let enclosed = NativeSourceOutlineEvidence.enclosedCaptionOutline(rgba: p, width: w, height: h, box: box.map(Double.init), glyph: glyph, ink: f["ink"] as! [Double], allowNeutral: f["neutral"] as? Bool ?? false)
    return ["name": f["name"]!, "ring": ring, "reject": result.rejection as Any? ?? NSNull(), "enclosed": enclosed as Any? ?? NSNull()]
}
try JSONSerialization.data(withJSONObject: outputs, options: [.sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
