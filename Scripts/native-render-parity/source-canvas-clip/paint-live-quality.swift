import Foundation
import CoreGraphics
import ImageIO
@main struct Paint {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let width = Int(CommandLine.arguments[2])!, height = Int(CommandLine.arguments[3])!
        let scale = CGFloat(width) / 640
        let output = URL(fileURLWithPath: CommandLine.arguments[4])
        let mode = CommandLine.arguments[5]
        let quality = CommandLine.arguments[6]
        let interpolationOverride = CommandLine.arguments.count > 7 ? CommandLine.arguments[7] : "original"
        let raw = try Data(contentsOf: directory.appendingPathComponent("web-dom-and-saved-masks.json"))
        let document = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        let records = document["records"] as! [[String: Any]]
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: 1000)
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 1000))
        context.interpolationQuality = quality == "none" ? .none : quality == "low" ? .low : quality == "medium" ? .medium : quality == "high" ? .high : .default
        for record in records {
            let id = record["id"] as! String
            let source = CGImageSourceCreateWithURL(directory.appendingPathComponent("source-\(id).png") as CFURL, nil)!
            let original = CGImageSourceCreateImageAtIndex(source, 0, nil)!
            let image: CGImage
            if interpolationOverride == "original" { image = original }
            else {
                image = CGImage(width: original.width, height: original.height,
                    bitsPerComponent: original.bitsPerComponent, bitsPerPixel: original.bitsPerPixel,
                    bytesPerRow: original.bytesPerRow, space: original.colorSpace!, bitmapInfo: original.bitmapInfo,
                    provider: original.dataProvider!, decode: original.decode,
                    shouldInterpolate: interpolationOverride == "true", intent: original.renderingIntent)!
            }
            let used = record["used"] as! [Double]
            var frame = CGRect(x: used[0], y: used[1], width: used[2], height: used[3])
            if mode == "snapped" {
                guard let snapped = NativeSourceCanvasImageFrame.liveFrame(domRect: frame) else { continue }
                frame = snapped
            }
            context.saveGState()
            context.translateBy(x: frame.minX, y: frame.maxY)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = quality == "none" ? .none : quality == "low" ? .low : quality == "medium" ? .medium : quality == "high" ? .high : .default
            print("quality-state", id, quality, context.interpolationQuality.rawValue, "image-interpolation", image.shouldInterpolate)
            context.draw(image, in: CGRect(origin: .zero, size: frame.size))
            context.restoreGState()
        }
        let image = context.makeImage()!
        let reader = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
        reader.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        try Data(bytes: reader.data!, count: width * height * 4).write(to: output)
    }
}
