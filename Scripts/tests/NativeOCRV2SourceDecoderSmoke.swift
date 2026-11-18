import CoreGraphics
import Foundation

@main
enum NativeOCRV2SourceDecoderSmoke {
    // Frozen pre-allocation-change decoder. This intentionally owns Data so
    // parity covers the real allocation change, not a mirror of the new code.
    static func reference(_ image: CGImage) -> [UInt8] {
        let width = image.width, height = image.height
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return Array(data)
    }

    static func main() throws {
        var cases = 0
        for (width, height) in [(1, 1), (7, 13), (37, 53), (700, 1_000)] {
            for mode in 0..<4 {
                // Deliberately padded input rows, alpha gradients, independent
                // corners and both grayscale and RGB source color spaces.
                let gray = mode == 3
                let components = gray ? 2 : 4
                let rowStride = width * components + 16
                var bytes = [UInt8](repeating: 0xAD, count: rowStride * height)
                for y in 0..<height { for x in 0..<width {
                    let offset = y * rowStride + x * components
                    let alpha = mode == 0 ? 255 : (x * 43 + y * 71) % 256
                    for channel in 0..<(components - 1) {
                        bytes[offset + channel] = UInt8((x * 19 + y * 31 + channel * 67) % (alpha + 1))
                    }
                    bytes[offset + components - 1] = UInt8(alpha)
                } }
                let provider = CGDataProvider(data: Data(bytes) as CFData)!
                let colorSpace = CGColorSpace(name: gray ? CGColorSpace.genericGrayGamma2_2
                    : (mode == 2 ? CGColorSpace.displayP3 : CGColorSpace.sRGB))!
                let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                    bitsPerPixel: components * 8, bytesPerRow: rowStride, space: colorSpace,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
                let frame = NativeOCRV2SourcePixelDecoder.decode(image)!
                precondition(frame.width == width && frame.height == height && frame.bytesPerRow == width * 4)
                precondition(frame.bytes == reference(image), "Decoder pixel mismatch")
                precondition(stride(from: 3, to: frame.bytes.count, by: 4).allSatisfy { frame.bytes[$0] == 255 })
                cases += 1
            }
        }
        print("{\"passed\":true,\"cases\":\(cases),\"scope\":\"synthetic CPU source decode exact RGBA parity\"}")
    }
}
