import Foundation
import CoreGraphics

let input = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: Any]]
var output: [[String: Any]] = []
for f in input {
    let width = f["width"] as! Int, height = f["height"] as! Int
    let rgba = (f["rgba"] as! [NSNumber]).map { $0.uint8Value }
    let provider = CGDataProvider(data: Data(rgba) as CFData)!
    let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    let reader = NativeSourcePixelReader(image: image)
    let stage = NativeSpatialSourceCrop(image: image, reader: reader, eligibleCount: f["eligible"] as? Int ?? 1)
    stage.restorationBudget = f["budget"] as? Int ?? 1_572_864
    stage.slantedPageFallbackBudget = f["detachedBudget"] as? Int ?? 1_048_576
    stage.forcedBudget = f["forcedBudget"] as? Int ?? 6_000_000
    stage.markBudget = f["markBudget"] as? Int ?? 262_144
    let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: JSONSerialization.data(withJSONObject: f["item"]!))
    let sample = f["sample"] as? [String: Any]
    let excluded = (f["excluded"] as! [[Double]]).map { CGRect(x: $0[0] * Double(width), y: $0[1] * Double(height), width: $0[2] * Double(width), height: $0[3] * Double(height)) }
    let frame = (f["frame"] as? [Double]).map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
    let prepared = stage.prepare(item: item, palette: sample.flatMap(NativeRestorationPixels.palette), excluded: excluded, forced: f["forced"] as? Bool ?? false, detached: f["detached"] as? Bool ?? false, sample: sample, frame: frame)
    func rect(_ r: CGRect) -> [Double] { [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)] }
    var result: [String: Any] = ["name": f["name"]!, "budget": stage.restorationBudget, "rubyBudget": stage.rubyBudget, "detachedBudget": stage.slantedPageFallbackBudget,
        "markBudget": stage.markBudget, "adjacentDotBudget": stage.adjacentDotBudget, "remaining": stage.remaining, "remainingMarks": stage.remainingMarks]
    if let p = prepared {
        result["plan"] = ["crop": rect(p.crop), "width": p.pixels.width, "height": p.pixels.height, "box": rect(p.box),
            "auxiliary": p.auxiliary.map(rect), "marks": p.marks.map(rect), "excluded": p.excluded.map(rect), "leadingRule": p.leadingRule]
    } else { result["plan"] = NSNull() }
    if f["forced"] as? Bool == true {
        result["forcedBudget"] = stage.forcedBudget
        if let p = prepared, var plan = result["plan"] as? [String: Any] { plan["nominalScale"] = p.nominalScale; result["plan"] = plan }
    }
    reader.release()
    output.append(result)
}
try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
