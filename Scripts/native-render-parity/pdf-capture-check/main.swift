import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let out = URL(fileURLWithPath: "build/native-render-parity/pdf-capture-check")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ components: [CGFloat]) -> CGColor { CGColor(colorSpace: srgb, components: components)! }
let frame = CGRect(x: 39, y: 135.5, width: 253.5, height: 85.796875)
let actual = NativeTranslationPDFCapture.snappedRect(frame, deviceScale: 3)
let isPattern = NativeTranslationPDFCapture.gradientGeometry(frame: frame, deviceScale: 3).usesPattern
let fill = rgb([17.0/255, 18.0/255, 23.0/255, 1])
let style = NativeTranslationTypography.Style(fontScript: "korean", fontSize: 31, foreground: fill,
    lineHeight: 36.994140625, optimizesKoreanWrapping: false, balancesHorizontalLines: true)
let layout = NativeTranslationTypography.layout(text: "안녕, 세상! 함께 출발하자.", in: CGSize(width: 241.5, height: 73.8), style: style)
let capture = try NativeTranslationPDFCapture.capture(bounds: CGRect(x: 0, y: 81.875, width: 390, height: 536.25),
    pixels: CGSize(width: 640, height: 880), paint: { context in
        context.saveGState()
        context.addPath(NativeTranslationPDFCapture.roundedPath(frame, radius: 6, deviceScale: 3))
        context.clip(using: .evenOdd)
        context.setFillColor(rgb([1, 254.0/255, 249.0/255, 1])); context.fill(actual)
        NativeTranslationPDFCapture.drawFallbackGradient(context: context, frame: frame, lightSurface: true, deviceScale: 3)
        context.restoreGState()
        NativeTranslationTypography.draw(layout: layout, in: context, at: CGPoint(x: 45, y: 141.5), pixelSnapScale: 3)
    })
try capture.data.write(to: out.appendingPathComponent("native.pdf"))
let web = try Data(contentsOf: URL(fileURLWithPath: "build/native-render-parity/export-gradient-alpha/horizontal-korean.pdf"))
func composite(_ data: Data, name: String) throws -> [UInt8] {
    let pdf = CGPDFDocument(CGDataProvider(data: data as CFData)!)!, page = pdf.page(at: 1)!
    var bytes = [UInt8](repeating: 0, count: 640 * 880 * 4)
    bytes.withUnsafeMutableBytes { buffer in
        let c = CGContext(data: buffer.baseAddress, width: 640, height: 880, bitsPerComponent: 8, bytesPerRow: 640 * 4,
            space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(rgb([0.72, 0.83, 0.91, 1])); c.fill(CGRect(x: 0, y: 0, width: 640, height: 880))
        c.scaleBy(x: 640.0/390, y: 880.0/536); c.drawPDFPage(page)
        let dest = CGImageDestinationCreateWithURL(out.appendingPathComponent(name + ".png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, c.makeImage()!, nil); precondition(CGImageDestinationFinalize(dest))
    }
    return bytes
}
let a = try composite(web, name: "web"), b = try composite(capture.data, name: "native")
var changed = 0, channelChanged = [0, 0, 0, 0], maxDelta = 0
for i in stride(from: 0, to: a.count, by: 4) {
    if (0..<4).contains(where: { a[i + $0] != b[i + $0] }) { changed += 1 }
    for c in 0..<4 { if a[i+c] != b[i+c] { channelChanged[c] += 1 }; maxDelta = max(maxDelta, abs(Int(a[i+c])-Int(b[i+c]))) }
}
let report: [String: Any] = ["allRGBAExact": changed == 0, "differentPixels": changed, "perChannelDifferentPixels": channelChanged,
    "maximumChannelDelta": maxDelta, "predicatePattern": isPattern, "stageOnly": true,
    "scope": "Frozen final geometry/fonts supplied; native CG vector capture versus frozen WK PDF, full page RGBA on colored background"]
try JSONSerialization.data(withJSONObject: report, options: .prettyPrinted).write(to: out.appendingPathComponent("report.json"))
print(report)
