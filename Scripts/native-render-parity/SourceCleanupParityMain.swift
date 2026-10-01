import Foundation
import CoreGraphics
let fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: Any]]
var output: [[String: Any]] = []
for f in fixtures {
    let width = f["width"] as! Int, height = f["height"] as! Int
    let bytes = (f["rgba"] as! [NSNumber]).map { $0.uint8Value }
    let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
        provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let reader = NativeSourcePixelReader(image: image)
    let cleanup = NativeSourceInkCleanup(image: image, reader: reader)
    cleanup.cleanupBudget = f["budget"] as? Int ?? 2_000_000
    cleanup.coloredBudget = f["coloredBudget"] as? Int ?? 262_144
    var queries: [[String: Any]] = []
    for descriptor in f["items"] as! [[String: Any]] {
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: JSONSerialization.data(withJSONObject: descriptor))
        let result = cleanup.prepare(item: item, sample: f["sample"] as? [String: Any], opacity: CGFloat((f["opacity"] as? Double) ?? 1))
        let audit = cleanup.coloredAudit.map { id, pixels, a -> [String: Any] in ["id": id, "pixels": pixels, "reason": a.reason, "erased": a.erased, "haloAdded": a.haloAdded] }
        var query: [String: Any] = ["budget": cleanup.cleanupBudget, "coloredBudget": cleanup.coloredBudget,
            "cleanedPixels": cleanup.cleanedPixels, "cleanupCount": cleanup.cleanupCount, "denseItems": cleanup.denseItems.sorted(), "audit": audit]
        if let result {
            query["output"] = ["rect": [result.rect.minX, result.rect.minY, result.rect.width, result.rect.height],
                "width": result.width, "height": result.height, "rgba": result.pixels.rgba!, "count": result.pixels.count, "dense": result.pixels.dense]
        } else { query["output"] = NSNull() }
        queries.append(query)
    }
    reader.release()
    output.append(["name": f["name"]!, "queries": queries])
}
try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
