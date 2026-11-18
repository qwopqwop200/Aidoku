import CoreGraphics
import Foundation

/// Source-relative preferred placement. Collision repair may move it; no text is clipped.
struct NativeTextPlacementGuide: Codable, Equatable, Sendable {
    enum Horizontal: String, Codable, Sendable { case left, center, right }
    enum Vertical: String, Codable, Sendable { case top, center, bottom }
    let rectNormalized: [Double]
    let horizontal: Horizontal
    let vertical: Vertical
    /// Source-observed screen-coordinate tilt; nil preserves existing rasters.
    var sourceRotationRadians: Double? = nil
    /// Derived point on the original oriented source, in original-page units.
    /// Nil retains the existing axis-aligned placement contract.
    var rotationAnchorNormalized: [Double]? = nil
    var valid: Bool {
        rectNormalized.count == 4 && rectNormalized.allSatisfy(\.isFinite) &&
        rectNormalized[2] > 0 && rectNormalized[3] > 0 &&
            CGRect(x: 0, y: 0, width: 1, height: 1).contains(rect(in: CGRect(x: 0, y: 0, width: 1, height: 1))) &&
            (sourceRotationRadians.map { $0.isFinite && abs($0) <= .pi/6 } ?? true) &&
            (rotationAnchorNormalized.map { $0.count == 2 && $0.allSatisfy { $0.isFinite && (-1...2).contains($0) } } ?? true)
    }
    func rect(in page: CGRect) -> CGRect {
        CGRect(x: rectNormalized[0] * page.width, y: rectNormalized[1] * page.height,
               width: rectNormalized[2] * page.width, height: rectNormalized[3] * page.height)
    }
    func preferredShift(bounds: CGRect, page: CGRect) -> CGPoint {
        let source = rect(in: page)
        if let anchor=rotationAnchorNormalized,anchor.count==2,
           let angle=sourceRotationRadians,abs(angle)>1e-6 {
            let c=abs(cos(angle)),s=abs(sin(angle)),denominator=c*c-s*s
            let width=(bounds.width*c-bounds.height*s)/denominator
            let height=(bounds.height*c-bounds.width*s)/denominator
            if width>0,height>0,width.isFinite,height.isFinite {
                let along:CGFloat=horizontal == .left ? -width/2:(horizontal == .right ? width/2:0)
                let normal:CGFloat=vertical == .top ? -height/2:(vertical == .bottom ? height/2:0)
                let cosine=CGFloat(cos(angle)),sine=CGFloat(sin(angle))
                let x=CGFloat(anchor[0])*page.width-(along*cosine-normal*sine)-bounds.width/2
                let y=CGFloat(anchor[1])*page.height-(along*sine+normal*cosine)-bounds.height/2
                return CGPoint(x:min(max(0,x.rounded()),max(0,floor(page.width-bounds.width)))-bounds.minX,
                    y:min(max(0,y.rounded()),max(0,floor(page.height-bounds.height)))-bounds.minY)
            }
        }
        let x: CGFloat
        switch horizontal {
        case .left: x = source.minX
        case .center: x = source.midX - bounds.width / 2
        case .right: x = source.maxX - bounds.width
        }
        let y: CGFloat
        switch vertical {
        case .top: y = source.minY
        case .center: y = source.midY - bounds.height / 2
        case .bottom: y = source.maxY - bounds.height
        }
        return CGPoint(x: min(max(0, x.rounded()), max(0, floor(page.width - bounds.width))) - bounds.minX,
                       y: min(max(0, y.rounded()), max(0, floor(page.height - bounds.height))) - bounds.minY)
    }
    enum RotationFailure: Error { case invalidGeometry, allocation }
    /// Rotate before final alpha admission, so effects, collisions and balloon
    /// boundaries are measured on the actual painted footprint, never a proxy.
    func rotatedRaster(_ image: CGImage, frame: CGRect) throws -> (CGImage, CGRect) {
        guard let angle=sourceRotationRadians,abs(angle)>1e-6 else { return (image,frame) }
        guard valid,frame.width>0,frame.height>0,
              frame.width.isFinite,frame.height.isFinite else { throw RotationFailure.invalidGeometry }
        let c=abs(cos(angle)),s=abs(sin(angle))
        let width=ceil(frame.width*c+frame.height*s)+2,height=ceil(frame.width*s+frame.height*c)+2
        guard width<=32768,height<=32768,height>0,width<=8_000_000/height,
            let context=CGContext(data:nil,width:Int(width),height:Int(height),
            bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,
            bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw RotationFailure.allocation }
        context.translateBy(x:width/2,y:height/2)
        context.rotate(by:-CGFloat(angle))
        context.interpolationQuality = .high
        context.draw(image,in:CGRect(x:-frame.width/2,y:-frame.height/2,width:frame.width,height:frame.height))
        guard let rotated=context.makeImage() else { throw RotationFailure.allocation }
        // Final alpha is counted on the output pixel grid. A half-pixel frame
        // would resample this already rotated raster again during composition.
        return (rotated,CGRect(x:(frame.midX-width/2).rounded(),y:(frame.midY-height/2).rounded(),width:width,height:height))
    }
    static func decode(_ value: Any?) throws -> Self? {
        guard let value, !(value is NSNull) else { return nil }
        let packet = try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: value))
        guard packet.valid else { throw NativeSourceClusterAlignment.Failure.invalidPacket }
        return packet
    }
}
