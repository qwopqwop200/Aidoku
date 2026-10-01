import Foundation
import CoreGraphics

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let black = CGColor(colorSpace: srgb, components: [0, 0, 0, 1])!
let white = CGColor(colorSpace: srgb, components: [1, 1, 1, 1])!
func raster(vertical: Bool, outlined: Bool, snapped: Bool) -> (NativeTranslationTypography.Layout, [UInt8]) {
    let size = CGSize(width: 180, height: 180), scale: CGFloat = 3
    let style = NativeTranslationTypography.Style(fontScript: "korean", fontSize: 31.75, vertical: vertical,
        foreground: black, outline: outlined ? white : nil, outlineWidth: outlined ? 2 : 0,
        lineHeight: 38, optimizesKoreanWrapping: false)
    let layout = NativeTranslationTypography.layout(text: "동그란 공", in: size, style: style)
    var bytes = [UInt8](repeating: 255, count: 540 * 540 * 4)
    bytes.withUnsafeMutableBytes { data in
        let context = CGContext(data: data.baseAddress, width: 540, height: 540, bitsPerComponent: 8,
            bytesPerRow: 540 * 4, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: 0, y: 540)
        context.scaleBy(x: scale, y: -scale)
        NativeTranslationTypography.draw(layout: layout, in: context, pixelSnapScale: snapped ? scale : nil)
    }
    return (layout, bytes)
}
var results: [[String: Any]] = []
for vertical in [false, true] {
    for snapped in [false, true] {
        let fill = raster(vertical: vertical, outlined: false, snapped: snapped), outlined = raster(vertical: vertical, outlined: true, snapped: snapped)
        let reference = raster(vertical: vertical, outlined: false, snapped: snapped)
        let changed = zip(reference.1, outlined.1).filter { $0 != $1 }.count
        precondition(changed == 0, "White stroke behind black fill on white paper must preserve every fill pixel")
        precondition(fill.0.lineRanges == outlined.0.lineRanges, "Stroke paint order changed line shaping")
        results.append(["vertical": vertical, "snapped": snapped, "changedRGBABytes": changed])
    }
}
print(String(data: try JSONSerialization.data(withJSONObject: ["passed": true, "cases": results], options: .sortedKeys), encoding: .utf8)!)
