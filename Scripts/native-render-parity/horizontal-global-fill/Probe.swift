import CoreGraphics
import CoreText
import Foundation

@main struct HorizontalGlobalFillProbe {
    static func main() throws {
        func line(_ stroke: Bool) -> CTLine {
            let text = NSMutableAttributedString(string: "Core Text", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 20, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
            ])
            if stroke { text.addAttribute(NSAttributedString.Key(kCTStrokeWidthAttributeName as String), value: 8,
                range: NSRange(location: 5, length: 4)) }
            return CTLineCreateWithAttributedString(text)
        }
        func pixels(_ paint: (CGContext) -> Void) -> Data {
            let context = CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 1600,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
            context.translateBy(x: 0, y: 200); context.scaleBy(x: 2, y: -2); paint(context)
            return Data(bytes: context.data!, count: 320_000)
        }
        let text = line(false), point = CGPoint(x: 20, y: 60)
        let prepared = NativeCTFontHorizontalFillPainter.prepare(line: text)!
        let reference = pixels { context in
            context.translateBy(x: point.x, y: point.y); context.scaleBy(x: 1, y: -1)
            context.textMatrix = .identity; context.textPosition = .zero; CTLineDraw(text, context)
        }
        var state = false
        let actual = pixels { context in
            context.textMatrix = CGAffineTransform(rotationAngle: 0.2); context.textPosition = CGPoint(x: 4, y: 5)
            let matrix = context.textMatrix, position = context.textPosition, transform = context.ctm
            precondition(NativeCTFontHorizontalFillPainter.draw(prepared: prepared, context: context, anchor: point))
            state = context.textMatrix == matrix && context.textPosition == position && context.ctm == transform
        }
        let mixedRefused = NativeCTFontHorizontalFillPainter.prepare(line: line(true)) == nil
        let condensedRefused = NativeCTFontHorizontalFillPainter.prepare(line: text, horizontalScale: 0.9) == nil
        let report: [String: Any] = ["scope": "Hosted public CoreText transport, not the iOS WebKit image gate",
            "fullRGBAEqual": reference == actual, "stateRestored": state,
            "laterStrokeRunRefused": mixedRefused, "condensedLayerRefused": condensedRefused]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print(report)
        precondition(reference == actual && state && mixedRefused && condensedRefused)
    }
}
