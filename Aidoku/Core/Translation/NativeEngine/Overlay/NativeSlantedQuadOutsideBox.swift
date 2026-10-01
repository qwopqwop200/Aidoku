import CoreGraphics
import Foundation

/// The source palette and the crop both use straight Canvas-compatible RGB.
/// Premultiplied image bytes are never compared with sampled straight colours.
enum NativeSlantedQuadOutsideBox {
    struct Result { let ink: Int; let area: Int }
    static func crop(quad: CGRect, angle: Double, imageSize: CGSize, frame: CGRect) -> CGRect? {
        guard [quad.minX,quad.minY,quad.width,quad.height,frame.minX,frame.minY,frame.width,frame.height,
               imageSize.width,imageSize.height,CGFloat(angle)].allSatisfy(\.isFinite), frame.width > 0, frame.height > 0 else { return nil }
        let corners = NativeSlantedGeometry.rotatedCard(cx: quad.midX, cy: quad.midY, width: quad.width, height: quad.height, angle: angle)
        let xs = corners.map { ($0[0] - Double(frame.minX)) * Double(imageSize.width / frame.width) }
        let ys = corners.map { ($0[1] - Double(frame.minY)) * Double(imageSize.height / frame.height) }
        let x = max(0, floor(xs.min()!)), y = max(0, floor(ys.min()!))
        let w = min(Double(imageSize.width), ceil(xs.max()!)) - x, h = min(Double(imageSize.height), ceil(ys.max()!)) - y
        guard w >= 2, h >= 2, w * h <= 262_144 else { return nil }
        return CGRect(x:x,y:y,width:w,height:h)
    }
    static func estimate(rgba: [UInt8], crop: CGRect, imageSize: CGSize, frame: CGRect, quad: CGRect,
                         angle: Double, card: CGRect, foreground: [Double], background: [Double]) -> Result? {
        guard foreground.count == 3, background.count == 3,
              abs(NativeTranslationSourceStylePostPolish.luminance(foreground) - NativeTranslationSourceStylePostPolish.luminance(background)) * 255 >= 24,
              crop.width >= 2, crop.height >= 2, crop.width * crop.height <= 262_144, frame.width > 0, frame.height > 0 else { return nil }
        let w = Int(crop.width), h = Int(crop.height)
        guard rgba.count == w * h * 4 else { return nil }
        let kx = Double(imageSize.width / frame.width), ky = Double(imageSize.height / frame.height)
        let c = cos(angle), s = sin(angle), cx = Double(quad.midX), cy = Double(quad.midY)
        let hw = Double(quad.width) / 2 - 1, hh = Double(quad.height) / 2 - 1
        let left = Double(card.minX) - 1, top = Double(card.minY) - 1, right = Double(card.maxX) + 1, bottom = Double(card.maxY) + 1
        var area = 0, ink = 0
        for y in 0..<h { for x in 0..<w {
            let px = Double(frame.minX) + (Double(crop.minX) + Double(x) + 0.5) / kx
            let py = Double(frame.minY) + (Double(crop.minY) + Double(y) + 0.5) / ky
            let dx = px - cx, dy = py - cy
            if abs(dx * c + dy * s) > hw || abs(-dx * s + dy * c) > hh ||
                px >= left && px <= right && py >= top && py <= bottom { continue }
            let i = (y * w + x) * 4; area += 1
            if abs(Double(rgba[i]) - background[0]) + abs(Double(rgba[i+1]) - background[1]) + abs(Double(rgba[i+2]) - background[2]) > 60 { ink += 1 }
        } }
        return .init(ink:ink,area:area)
    }
    static func read(item: NativeTranslationLayoutItem, image: CGImage, sample: [String: Any]?) throws -> Result? {
        try Task.checkCancellation()
        guard item.sourceFrame.count == 4, let foreground = NativeSourceColorSampler.rgb(sample?["foreground"]),
              let background = NativeSourceColorSampler.rgb(sample?["background"]) else { return nil }
        let f = item.sourceFrame, frame = CGRect(x:f[0],y:f[1],width:f[2],height:f[3]), size = CGSize(width:image.width,height:image.height)
        guard let crop = crop(quad:item.rect,angle:item.rotation,imageSize:size,frame:frame),
              let rgba = try? NativeSourcePixelReader.draw(image:image,x:crop.minX,y:crop.minY,sourceWidth:crop.width,sourceHeight:crop.height,
                                                         width:Int(crop.width),height:Int(crop.height)) else { return nil }
        let result = estimate(rgba:rgba,crop:crop,imageSize:size,frame:frame,quad:item.rect,angle:item.rotation,
                              card:item.rect,foreground:foreground,background:background)
        try Task.checkCancellation(); return result
    }
}
