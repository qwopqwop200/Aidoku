// rasterdump.swift LIST OUTDIR: for each "pageID<TAB>path" line, the app's S4 gray raster (PipelineGrayRaster:
// CGImageSource decode, <= 768 px long side, DeviceGray, medium interpolation) as OUTDIR/pageID.raw (w*h bytes)
// plus OUTDIR/pageID.size ("w h"). Same drawing code as PipelineGrouping.swift.
import CoreGraphics
import Foundation
import ImageIO

let args = CommandLine.arguments
let list = try! String(contentsOfFile: args[1], encoding: .utf8)
let out = URL(fileURLWithPath: args[2])
for line in list.split(separator: "\n") {
    let parts = line.split(separator: "\t")
    guard parts.count == 2 else { continue }
    let id = String(parts[0]), path = String(parts[1])
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { print("fail", id); continue }
    let scale = min(1, 768 / CGFloat(max(image.width, image.height)))
    let width = max(1, Int(CGFloat(image.width) * scale))
    let height = max(1, Int(CGFloat(image.height) * scale))
    var pixels = [UInt8](repeating: 255, count: width * height)
    pixels.withUnsafeMutableBytes { bytes in
        let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    try! Data(pixels).write(to: out.appendingPathComponent("\(id).raw"))
    try! "\(width) \(height)".write(to: out.appendingPathComponent("\(id).size"), atomically: true, encoding: .utf8)
}
print("done")
