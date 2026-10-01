import Foundation
import CoreGraphics
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for light in [true, false] {
    let capture = try NativeTranslationPDFCapture.capture(bounds: CGRect(x: 0, y: 81.875, width: 390, height: 536.25),
        pixels: CGSize(width: 390, height: 536)) { context in
        NativeTranslationPDFCapture.drawFallbackGradient(context: context,
            frame: CGRect(x: 39, y: 135.5, width: 253.5, height: 85.796875), lightSurface: light, deviceScale: 3)
    }
    try capture.data.write(to: output.appendingPathComponent(light ? "light.pdf" : "dark.pdf"))
}
