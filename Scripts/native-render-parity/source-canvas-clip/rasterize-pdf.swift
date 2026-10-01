import Foundation
import CoreGraphics
import ImageIO
@main struct Raster {
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let width = Int(CommandLine.arguments[2])!, height = Int(CommandLine.arguments[3])!
        let image = try NativeTranslationPDFCapture.rasterize(data: data, pixels: CGSize(width: width, height: height))
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let raw = Data(bytes: context.data!, count: width * height * 4)
        try raw.write(to: URL(fileURLWithPath: CommandLine.arguments[4]))
    }
}
