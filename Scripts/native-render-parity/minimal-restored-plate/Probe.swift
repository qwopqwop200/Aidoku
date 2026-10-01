import Foundation
import CoreGraphics
@main struct MinimalPlateProbe {
    static func main() throws {
        let args = CommandLine.arguments
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[1]))) as! [[String: Any]]
        func rect(_ r: [Double]) -> CGRect { CGRect(x: r[0], y: r[1], width: r[2], height: r[3]) }
        func array(_ r: CGRect) -> [Double] { [Double(r.minX),Double(r.minY),Double(r.width),Double(r.height)] }
        var outputs: [Any] = []
        for f in rows {
            let frame = f["frame"] as! [Double], size = f["imageSize"] as! [Double], scale = f["scale"] as! [Double], origin = f["origin"] as! [Double]
            let surface = NativeMinimalRestoredPlate.Surface(width: f["w"] as! Int, height: f["h"] as! Int,
                safe: (f["safe"] as! [Int]).map(UInt8.init), rgba: (f["rgba"] as! [Int]).map(UInt8.init),
                frame: rect(frame), imageSize: CGSize(width: size[0], height: size[1]),
                origin: CGPoint(x: origin[0], y: origin[1]), scale: CGSize(width: scale[0], height: scale[1]))
            var input = NativeMinimalRestoredPlate.Input(panel: rect(f["panel"] as! [Double]), ink: rect(f["ink"] as! [Double]), font: f["font"] as! Double)
            input.clipped = f["clipped"] as! Bool; input.coverage = (f["coverage"] as? [[Double]])?.map(rect)
            input.otherInk = (f["otherInk"] as! [[Double]]).map(rect)
            input.sources = (f["sources"] as! [[String: Any]]).map { value in
                .init(frame: rect(value["frame"] as! [Double]), bounds: value["bounds"] as! [[Double]],
                    vertical: value["vertical"] as! Bool, sourceFont: value["sourceFont"] as? Double, font: value["font"] as? Double)
            }
            if let p = NativeMinimalRestoredPlate.shrink(surface, input: input) {
                outputs.append(["rect": array(p.rect), "coverage": p.coverage.map(array), "clipped": p.clipped,
                    "beforeArea": p.beforeArea, "afterArea": p.afterArea])
            } else { outputs.append(NSNull()) }
        }
        try JSONSerialization.data(withJSONObject: outputs, options: [.sortedKeys]).write(to: URL(fileURLWithPath: args[2]))
    }
}
