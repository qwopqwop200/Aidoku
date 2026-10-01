import Foundation
import CoreGraphics
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
func raster(_ layout: NativeTranslationTypography.Layout) -> [UInt8] {
    var bytes = [UInt8](repeating: 255, count: 540 * 360 * 4)
    bytes.withUnsafeMutableBytes { data in
        let context = CGContext(data: data.baseAddress, width: 540, height: 360,
            bitsPerComponent: 8, bytesPerRow: 540 * 4, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: 0, y: 360); context.scaleBy(x: 3, y: -3)
        NativeTranslationTypography.draw(layout: layout, in: context)
    }
    return bytes
}
let style = NativeTranslationTypography.Style(fontScript: "korean", fontSize: 20, lineHeight: 24, optimizesKoreanWrapping: false)
let base = NativeTranslationTypography.layout(text: "가나다\n라마바", in: CGSize(width: 180, height: 120), style: style)
let offsets = [CGPoint(x: 5, y: 0), CGPoint(x: -7, y: 0)]
let moved = NativeTranslationTypography.applyingLineOffsets(layout: base, offsets: offsets)
let lines = NativeTranslationTypography.captionLineMetrics(layout: base)
for (i, pair) in zip(lines, NativeTranslationTypography.captionLineMetrics(layout: moved)).enumerated() {
    precondition(abs(pair.1.rect.minX - pair.0.rect.minX - offsets[i].x) < 0.00001)
}
let original = raster(base), actual = raster(moved)
var expected = [UInt8](repeating: 255, count: original.count)
for y in 0..<360 {
    let row = lines.indices.min { abs(lines[$0].rect.midY * 3 - CGFloat(y)) < abs(lines[$1].rect.midY * 3 - CGFloat(y)) }!
    let shift = Int(offsets[row].x * 3)
    for x in 0..<540 {
        let dx = x + shift
        if dx >= 0 && dx < 540 { for c in 0..<4 { expected[(y*540+dx)*4+c] = original[(y*540+x)*4+c] } }
    }
}
precondition(actual == expected, "Committed line painting disagrees with exact integer pixel translations")
let leftStyle = NativeTranslationTypography.Style(fontScript: "korean", fontSize: 20, lineHeight: 24,
    optimizesKoreanWrapping: false, horizontalAlignment: .left)
let left = NativeTranslationTypography.layout(text: "가나다\n라마바", in: CGSize(width: 180, height: 120), style: leftStyle)
precondition(NativeTranslationTypography.captionLineMetrics(layout: left).allSatisfy { abs($0.rect.minX) < 0.0001 })
let red = CGColor(colorSpace: srgb, components: [1,0,0,1])!
let glowStyle = NativeTranslationTypography.Style(fontScript: "korean", fontSize: 20, foreground: CGColor(gray:0,alpha:1),
    outline: red, outlineWidth: 1, lineHeight: 24, optimizesKoreanWrapping: false, outlineGlow: 2)
let glow = NativeTranslationTypography.layout(text: "가나다\n라마바", in: CGSize(width:180,height:120), style: glowStyle)
var noGlowStyle = glowStyle; noGlowStyle.outlineGlow = 0
let noGlow = NativeTranslationTypography.layout(text: "가나다\n라마바", in: CGSize(width:180,height:120), style:noGlowStyle)
precondition(glow.lineRanges == noGlow.lineRanges && glow.rangeBounds == noGlow.rangeBounds && glow.glyphBounds == noGlow.glyphBounds)
precondition(raster(glow) != raster(noGlow), "Explicit glow did not paint")
print("{\"passed\":true,\"lineOffsetsExactRaster\":true,\"leftAlignment\":true,\"explicitGlowPaints\":true,\"glowRasterMatchesCSS\":null}")
