import CoreGraphics
import Foundation

// The fixture model contains only the native raster's stored bytes. The production
// policy and its distance/clamping helpers below are compiled without replacement.
struct NativeRestorationPixels {
    let width: Int
    let height: Int
    var rgba: [UInt8]
    var layoutSafe: [UInt8]?
    var count: Int { width * height }
}
let inputs = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: Any]]
func rect(_ a: [Double]) -> CGRect { CGRect(x: a[0], y: a[1], width: a[2], height: a[3]) }
let outputs: [[String: Any]] = inputs.map { f in
    let w = f["width"] as! Int, h = f["height"] as! Int
    let source = NativeRestorationPixels(width: w, height: h, rgba: (f["rgba"] as! [Int]).map(UInt8.init), layoutSafe: nil)
    var restored = NativeRestorationPixels(width: w, height: h, rgba: (f["restored"] as! [Int]).map(UInt8.init), layoutSafe: (f["safe"] as! [Int]).map(UInt8.init))
    let painted = NativeConnectedLettering.complete(original: source, box: rect(f["box"] as! [Double]), restored: &restored,
        exclusions: (f["excluded"] as! [[Double]]).map(rect), vertical: f["vertical"] as? Bool)
    return ["name": f["name"]!, "painted": painted, "rgba": restored.rgba, "safe": restored.layoutSafe!]
}
try JSONSerialization.data(withJSONObject: outputs, options: [.sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
