import Foundation
let fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: Any]]
var output: [[String: Any]] = []
for f in fixtures {
    let r = f["ring"] as! [String: Any], s = f["state"] as! [String: Any]
    func n(_ d: [String: Any], _ k: String, _ fallback: Double = 0) -> Double { (d[k] as? NSNumber)?.doubleValue ?? fallback }
    func rgb(_ d: [String: Any], _ k: String) -> [Double]? { (d[k] as? [NSNumber])?.map(\.doubleValue) }
    let st = r["structure"] as! [String: Any]
    let structure = NativeSourceOutlineEvidence.Structure(band: n(st,"band"), deep: n(st,"deep"), fillN: Int(n(st,"fillN")), ringN: Int(n(st,"ringN")))
    let surface = (r["surface"] as? [String: Any]).map { NativeSourceOutlineEvidence.Surface(rgb: rgb($0,"rgb")!, flat: $0["flat"] as? Bool ?? false, close: n($0,"close"), luminances: rgb($0,"luminances")!) }
    let ring = NativeSourceOutlineEvidence.Ring(core: rgb(r,"core")!, outline: rgb(r,"outline")!, uniform: n(r,"uniform"), hug: n(r,"hug"), width: n(r,"width"), structure: structure, boxRing: (r["boxRing"] as? NSNumber)?.doubleValue, reached: n(r,"reached"), exterior: (r["exterior"] as? NSNumber)?.doubleValue, kind: r["kind"] as! String, surface: surface)
    let state = NativePrimaryOutlinedLettering.State(sample: s["sample"] as? [String: Any] ?? [:], font: n(s,"font",10), foreground: rgb(s,"foreground"), stroke: rgb(s,"stroke"), strokeWidth: n(s,"strokeWidth"), plate: rgb(s,"plate"), restored: s["restored"] as? Bool ?? false, slanted: s["slanted"] as? Bool ?? false, missingColumnRing: s["missingColumnRing"] as? Bool ?? false, plateIsAlone: s["plateIsAlone"] as? Bool ?? true, overlappingInks: (s["overlappingInks"] as? [Any] ?? []).map { ($0 as? [NSNumber])?.map(\.doubleValue) }, sourceContrastBefore: (s["sourceContrastBefore"] as? NSNumber)?.doubleValue, slantedSurfaceLuminance: rgb(s,"slantedSurfaceLuminance"))
    let d = NativePrimaryOutlinedLettering.decide(ring: ring, state: state)
    output.append(["name": f["name"]!, "fill": d.fill as Any? ?? NSNull(), "stroke": d.stroke as Any? ?? NSNull(), "strokeWidth": d.strokeWidth as Any? ?? NSNull(), "background": d.background as Any? ?? NSNull(), "clearsStroke": d.clearsStroke, "record": d.record, "rejection": d.rejection as Any? ?? NSNull()])
}
try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
