import CoreGraphics
import Foundation

/// A declaration made only at the renderer's fresh bitmap entry. The owner
/// guarantees alpha one, normal blend mode and the initial rectangular clip;
/// every painter on the way to a source patch must restore these outer states.
/// A CGContext cannot expose alpha, blend mode or the shape of its clip.
final class NativeCanvasBacking {
    private enum Format { case rgba, bgra }
    private let context: CGContext
    private let pointer: UnsafeMutableRawPointer
    private let transform: CGAffineTransform
    private let clip: CGRect
    private let width: Int
    private let height: Int
    private let stride: Int
    private let format: Format

    static func freshCanonicalBitmap(context: CGContext, pixelExtent: CGSize) -> NativeCanvasBacking? {
        guard pixelExtent.width.isFinite, pixelExtent.height.isFinite,
              pixelExtent.width > 0, pixelExtent.height > 0,
              pixelExtent.width.rounded(.towardZero) == pixelExtent.width,
              pixelExtent.height.rounded(.towardZero) == pixelExtent.height,
              pixelExtent.width <= CGFloat(NativeCanvasTextureResampler.maximumDimension),
              pixelExtent.height <= CGFloat(NativeCanvasTextureResampler.maximumDimension),
              context.width == Int(pixelExtent.width), context.height == Int(pixelExtent.height),
              context.width <= NativeCanvasTextureResampler.maximumPixels / context.height,
              let pointer = context.data, let format = format(of: context),
              context.bytesPerRow >= context.width * 4 else { return nil }
        let transform = context.ctm
        guard transform.a.isFinite, transform.a > 0, transform.b == 0, transform.c == 0,
              transform.d.isFinite, abs(transform.d) == transform.a,
              transform.tx.isFinite, transform.ty.isFinite else { return nil }
        let clip = context.boundingBoxOfClipPath
        let deviceClip = context.convertToDeviceSpace(clip)
        guard deviceClip == CGRect(origin: .zero, size: pixelExtent) else { return nil }
        return .init(context: context, pointer: pointer, transform: transform, clip: clip, format: format)
    }

    private init(context: CGContext, pointer: UnsafeMutableRawPointer, transform: CGAffineTransform, clip: CGRect, format: Format) {
        self.context = context; self.pointer = pointer; self.transform = transform; self.clip = clip
        width = context.width; height = context.height; stride = context.bytesPerRow; self.format = format
    }

    /// Call before adding the patch's independently known rectangular cleanup
    /// clip. Bounding-box equality is a refusal check, not a clip-shape proof.
    func matchesFreshState(_ candidate: CGContext) -> Bool {
        candidate === context && candidate.data == pointer && candidate.ctm == transform &&
        candidate.boundingBoxOfClipPath == clip && candidate.width == width && candidate.height == height &&
        candidate.bytesPerRow == stride && Self.format(of: candidate) == format
    }

    /// Read the already painted destination in the texture primitive's top-row
    /// order. convertToDeviceSpace includes the bitmap base transform and reports
    /// top-row coordinates. A positive user Y transform reverses those rows.
    func backgroundRGBA(context candidate: CGContext, userRect: CGRect) -> Data? {
        guard candidate === context, candidate.data == pointer, candidate.ctm == transform,
              candidate.width == width, candidate.height == height, candidate.bytesPerRow == stride,
              Self.format(of: candidate) == format else { return nil }
        let device = candidate.convertToDeviceSpace(userRect)
        let deviceClip = candidate.convertToDeviceSpace(candidate.boundingBoxOfClipPath)
        guard Self.integral(device), Self.integral(deviceClip),
              device.size.width > 0, device.size.height > 0,
              CGRect(x: 0, y: 0, width: width, height: height).contains(device), deviceClip.contains(device) else { return nil }
        let x = Int(device.minX), y = Int(device.minY), w = Int(device.size.width), h = Int(device.size.height)
        var output = Data(count: w * h * 4)
        output.withUnsafeMutableBytes { raw in
            let destination = raw.bindMemory(to: UInt8.self).baseAddress!
            let source = pointer.assumingMemoryBound(to: UInt8.self)
            for row in 0..<h {
                let memoryY = transform.d < 0 ? y + row : y + h - 1 - row
                let input = source + memoryY * stride + x * 4
                let target = destination + row * w * 4
                for column in 0..<w {
                    let s = input + column * 4, d = target + column * 4
                    switch format {
                    case .rgba: d[0] = s[0]; d[1] = s[1]; d[2] = s[2]; d[3] = s[3]
                    case .bgra: d[0] = s[2]; d[1] = s[1]; d[2] = s[0]; d[3] = s[3]
                    }
                }
            }
        }
        return output
    }

    private static func integral(_ rect: CGRect) -> Bool {
        [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height].allSatisfy {
            $0.isFinite && $0.rounded(.towardZero) == $0
        }
    }
    private static func format(of context: CGContext) -> Format? {
        guard context.bitsPerComponent == 8, context.bitsPerPixel == 32,
              context.colorSpace?.model == .rgb, context.colorSpace?.name == CGColorSpace.sRGB,
              !context.bitmapInfo.contains(.floatComponents) else { return nil }
        let order = context.bitmapInfo.intersection(.byteOrderMask)
        if context.alphaInfo == .premultipliedLast, order == .byteOrder32Big { return .rgba }
        if context.alphaInfo == .premultipliedFirst, order == .byteOrder32Little { return .bgra }
        return nil
    }
}
