import CoreGraphics
import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
func image(_ data: Data, width: Int, height: Int) -> CGImage {
    CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: [.byteOrder32Big, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)],
        provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}
func context(_ bgra: Bool, flipped: Bool, opaque: Bool) -> CGContext {
    let alpha = bgra ? CGImageAlphaInfo.premultipliedFirst : .premultipliedLast
    let order: CGBitmapInfo = bgra ? .byteOrder32Little : .byteOrder32Big
    let c = CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 48,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: alpha.rawValue | order.rawValue)!
    let p = c.data!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<6 { for x in 0..<8 {
        let red = UInt8(10 + x * 3), green = UInt8(20 + y * 5), blue = UInt8(x + y + 1)
        let at = p + y * c.bytesPerRow + x * 4
        at[0] = bgra ? blue : red; at[1] = green; at[2] = bgra ? red : blue; at[3] = opaque ? 255 : 80
    } }
    if flipped { c.translateBy(x: 0, y: 6); c.scaleBy(x: 1, y: -1) }
    c.scaleBy(x: 2, y: 2); c.translateBy(x: 3, y: 2)
    return c
}
func drawTopRowImage(_ tile: CGImage, context: CGContext, frame: CGRect, mode: CGBlendMode) {
    context.saveGState(); defer { context.restoreGState() }
    context.setBlendMode(mode); context.interpolationQuality = .none
    context.translateBy(x: frame.minX, y: frame.maxY); context.scaleBy(x: 1, y: -1)
    context.draw(tile, in: CGRect(origin: .zero, size: frame.size))
}
@main struct Probe {
    static func main() throws {
        var passed = 0
        let full = CGRect(x: -3, y: -2, width: 4, height: 3)
        for bgra in [false, true] { for flipped in [false, true] { for opaque in [false, true] {
            let c = context(bgra, flipped: flipped, opaque: opaque)
            let backing = NativeCanvasBacking.freshCanonicalBitmap(context: c, pixelExtent: CGSize(width: 8, height: 6))!
            require(backing.matchesFreshState(c), "fresh state")
            let original = backing.backgroundRGBA(context: c, userRect: full)!
            let b = [UInt8](original)
            for y in 0..<6 { for x in 0..<8 {
                let row = flipped ? y : 5-y, at = (y*8+x)*4
                require(b[at] == 10+x*3 && b[at+1] == 20+row*5 && b[at+2] == x+row+1 && b[at+3] == (opaque ? 255:80), "row/format")
            } }
            // The current bitmap has painted content, rather than the original
            // source page. Read a bounded integer cleanup rectangle after that.
            let tileFrame = CGRect(x: -2.5, y: -1.5, width: 2.5, height: 1.5)
            c.saveGState(); c.clip(to: tileFrame)
            let before = backing.backgroundRGBA(context: c, userRect: tileFrame)!
            let source = image(Data([25, 10, 5, 100, 0, 0, 0, 0, 0, 80, 10, 160, 60, 5, 5, 80]), width: 2, height: 2)
            let crop = CGRect(x: 1, y: 1, width: 5, height: 3)
            let tile = try NativeCanvasTextureResampler.compositeCanvasImage(image: source, destinationPixels: CGSize(width: 8, height: 6), cropPixels: crop, backgroundRGBA: before)
            let filtered = try NativeCanvasTextureResampler.canvasImage(image: source, destinationPixels: CGSize(width: 8, height: 6), cropPixels: crop)
            let tileRGBA = tile.dataProvider!.data! as Data
            drawTopRowImage(tile, context: c, frame: tileFrame, mode: .copy)
            let after = backing.backgroundRGBA(context: c, userRect: tileFrame)!
            require(after == tileRGBA, "copy must retain exact already-composited RGBA")
            // A second source-over is observably wrong for transparent backing.
            if !opaque {
                drawTopRowImage(tile, context: c, frame: tileFrame, mode: .normal)
                require(backing.backgroundRGBA(context: c, userRect: tileFrame)! != tileRGBA, "double-over control")
            }
            require(filtered.width == 5 && tile.height == 3, "full UV crop")
            c.restoreGState()
            require(backing.matchesFreshState(c), "restored CTM and clip")
            c.saveGState(); c.clip(to: CGRect(x:-2.875,y:-2,width:3,height:3))
            require(backing.backgroundRGBA(context:c,userRect:full)==nil, "fractional clip refusal")
            c.restoreGState()
            c.saveGState(); c.translateBy(x:1,y:0)
            require(!backing.matchesFreshState(c), "changed transform refusal")
            c.restoreGState()
            let other = context(bgra,flipped:flipped,opaque:opaque)
            require(!backing.matchesFreshState(other), "different context refusal")
            passed += 1
        } } }
        let p3 = CGContext(data:nil,width:8,height:6,bitsPerComponent:8,bytesPerRow:32,
            space:CGColorSpace(name:CGColorSpace.displayP3)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue)!
        require(NativeCanvasBacking.freshCanonicalBitmap(context:p3,pixelExtent:CGSize(width:8,height:6))==nil,"P3 refusal")
        let wrongExtent=context(false,flipped:true,opaque:false)
        require(NativeCanvasBacking.freshCanonicalBitmap(context:wrongExtent,pixelExtent:CGSize(width:7,height:6))==nil,"extent refusal")
        print("PASS \(passed) format/orientation/opaque controls, exact full RGBA copy, crop and refusal controls")
    }
}
