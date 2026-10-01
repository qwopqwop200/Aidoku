import CoreGraphics
import Foundation

func painted(scaleX: CGFloat, vertical: Bool) -> (NativeTranslationTypography.Layout, [UInt8], [Int]) {
    let size = CGSize(width: 160, height: 120), scale: CGFloat = 3
    let style = NativeTranslationTypography.Style(fontScript: "korean", fontSize: 20, vertical: vertical,
        lineHeight: 24, optimizesKoreanWrapping: false, horizontalScale: scaleX)
    let typography = NativeTranslationTypography.layout(text: "가나다라마바사\n미래 번역\n그대로 유지", in: size, style: style)
    let width = Int(size.width * scale), height = Int(size.height * scale)
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    bytes.withUnsafeMutableBytes { storage in
        let context = CGContext(data: storage.baseAddress, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        NativeTranslationTypography.draw(layout: typography, in: context)
    }
    var x0 = width, y0 = height, x1 = -1, y1 = -1
    for y in 0..<height {
        for x in 0..<width where bytes[(y * width + x) * 4] < 240 {
            x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y)
        }
    }
    precondition(x1 >= x0 && y1 >= y0, "The renderer did not paint glyphs")
    let pixelBounds = CGRect(x: CGFloat(x0) / scale, y: CGFloat(y0) / scale,
                            width: CGFloat(x1 - x0 + 1) / scale, height: CGFloat(y1 - y0 + 1) / scale)
    precondition(typography.inkBounds.insetBy(dx: -1, dy: -1).contains(pixelBounds), "Paint exceeds measured glyph bounds")
    return (typography, bytes, [x0, y0, x1, y1])
}
let full = painted(scaleX: 1, vertical: false), condensed = painted(scaleX: 0.9, vertical: false)
precondition(full.0.lineRanges == condensed.0.lineRanges, "Condensing changed controlled line breaks")
precondition(full.0.lineCount == 3 && condensed.0.lineCount == 3)
for (a, b) in zip(full.0.glyphBounds, condensed.0.glyphBounds) {
    precondition(abs(b.width - a.width * 0.9) < 0.001)
    precondition(abs(b.midX - (80 + (a.midX - 80) * 0.9)) < 0.001)
    precondition(abs(b.minY - a.minY) < 0.001)
}
precondition(full.1 != condensed.1, "A 90% width transform must change final pixels")
let vertical = painted(scaleX: 1, vertical: true), verticalScale = painted(scaleX: 0.9, vertical: true)
precondition(vertical.1 == verticalScale.1, "Horizontal width policy must preserve vertical glyphs")
let report: [String: Any] = ["passed": true, "horizontalLines": full.0.lineCount,
    "fullWidthPixelBounds": full.2, "condensedPixelBounds": condensed.2,
    "verticalIgnoresHorizontalScale": true,
    "scope": "Actual native Core Text 3x raster pixels agree with reported glyph bounds and the 90% transform; this is not browser pixel parity."]
let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
print(String(data: data, encoding: .utf8)!)
