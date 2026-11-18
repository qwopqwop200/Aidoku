import CoreGraphics
import Foundation

/// Explicit NEW V2 decoder ABI. Call for EVERY V2 source, independent of identity/GT.
/// Matches NativeRFDETRSourceImage.decode opaque sRGB source canvas exactly.
/// No resize, orientation transform, model inference, image identity branches or V1 mutation.
enum NativeOCRV2SourcePixelDecoder {
    static let abi = "native-cgimage-opaque-srgb-white-rgba8-v2"
    struct Frame: Sendable {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let bytes: [UInt8]
    }
    static func decode(_ image: CGImage) -> Frame? {
        let width=image.width,height=image.height
        guard width>0,height>0,width<=16_384,height<=16_384,
              width<=16_777_216/height,
              let colorSpace=CGColorSpace(name:CGColorSpace.sRGB) else{return nil}
        // Decode into the final owner. A Data staging buffer used to require
        // a second full-page allocation and copy when constructing Frame.
        // The opaque white fill initializes every byte before source-over draw.
        let count = width * height * 4
        let rgba = [UInt8](unsafeUninitializedCapacity: count) { bytes, initializedCount in
            guard let context=CGContext(data:bytes.baseAddress,width:width,height:height,
                bitsPerComponent:8,bytesPerRow:width*4,space:colorSpace,
                bitmapInfo:CGBitmapInfo.byteOrder32Big.rawValue|CGImageAlphaInfo.premultipliedLast.rawValue) else{return}
            context.setFillColor(CGColor(gray:1,alpha:1))
            context.fill(CGRect(x:0,y:0,width:width,height:height))
            // Deliberately default source-over interpolation/blending, as RF source decode.
            // Preserve the original CGImage row order; no canvas flip or EXIF transform.
            context.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
            initializedCount = count
        }
        guard rgba.count == count else{return nil}
        return .init(width:width,height:height,bytesPerRow:width*4,bytes:rgba)
    }
}
