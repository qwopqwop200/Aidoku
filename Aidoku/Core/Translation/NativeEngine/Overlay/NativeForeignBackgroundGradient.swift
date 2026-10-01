import CoreGraphics
import Foundation

/// WebKit no-repeat, pixel-length background image geometry.
/// Callers preserve the CSS declaration at the producer, independently of the
/// owner's later DOM box. No fixture coordinates participate in this policy.
enum NativeForeignBackgroundGradient {
    struct Geometry { let destination: CGRect; let tile: CGRect; let usesPattern: Bool }
    static func used(_ v: CGFloat) -> CGFloat { CGFloat((Float(v) * 64).rounded(.towardZero)) / 64 }
    static func used(_ r: CGRect) -> CGRect { CGRect(x: used(r.minX), y: used(r.minY), width: used(r.width), height: used(r.height)) }
    static func geometry(owner: CGRect, position: CGPoint, size: CGSize, deviceScale: CGFloat) -> Geometry? {
        guard [owner.minX,owner.minY,owner.width,owner.height,position.x,position.y,size.width,size.height,deviceScale].allSatisfy(\.isFinite), owner.width>0,owner.height>0,size.width>0,size.height>0,deviceScale>0, Float(deviceScale).isFinite else { return nil }
        let border=used(owner), x=used(position.x), y=used(position.y)
        let intrinsic=CGSize(width:max(used(1/deviceScale),used(size.width)),height:max(used(1/deviceScale),used(size.height)))
        var destination=CGRect(x:border.minX+max(0,x),y:border.minY+max(0,y),width:intrinsic.width+min(0,x),height:intrinsic.height+min(0,y)).intersection(border)
        guard !destination.isNull, destination.width>0,destination.height>0 else { return nil }
        let snappedTile=NativeTranslationPDFCapture.snappedRect(CGRect(origin:destination.origin,size:intrinsic),deviceScale:deviceScale)
        let tileSize=CGSize(width:used(snappedTile.width),height:used(snappedTile.height))
        let snappedPhase=NativeTranslationPDFCapture.snappedRect(CGRect(origin:destination.origin,size:CGSize(width:max(0,-x),height:max(0,-y))),deviceScale:deviceScale)
        let phase=CGSize(width:used(snappedPhase.width),height:used(snappedPhase.height))
        destination=used(NativeTranslationPDFCapture.snappedRect(destination,deviceScale:deviceScale))
        let initialOrigin=destination.origin
        // BackgroundPainter clips the destination after preserving its origin.
        destination=destination.intersection(used(NativeTranslationPDFCapture.snappedRect(border,deviceScale:deviceScale)))
        guard !destination.isNull, destination.width>0,destination.height>0,tileSize.width>0,tileSize.height>0 else{return nil}
        let relativePhase=CGSize(width:phase.width+destination.minX-initialOrigin.x,height:phase.height+destination.minY-initialOrigin.y)
        // Image::drawTiled performs these operations in FloatRect precision.
        func firstTile(_ destination:CGFloat,_ phase:CGFloat,_ extent:CGFloat)->CGFloat {
            let d=Float(destination),p=Float(phase),s=Float(extent)
            return CGFloat(d + ((-p).truncatingRemainder(dividingBy:s)-s).truncatingRemainder(dividingBy:s))
        }
        let tile=CGRect(x:firstTile(destination.minX,relativePhase.width,tileSize.width),y:firstTile(destination.minY,relativePhase.height,tileSize.height),width:tileSize.width,height:tileSize.height)
        return Geometry(destination:destination,tile:tile,usesPattern:!tile.contains(destination))
    }
    @discardableResult static func draw(context:CGContext,owner:CGRect,position:CGPoint,size:CGSize,color:[CGFloat],deviceScale:CGFloat)->Bool {
        guard let g=geometry(owner:owner,position:position,size:size,deviceScale:deviceScale), !g.usesPattern, color.count==3,color.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 255 }),let space=CGColorSpace(name:CGColorSpace.sRGB),let c=CGColor(colorSpace:space,components:color.map{CGFloat(Float($0/255))}+[1]),let gradient=CGGradient(colorsSpace:space,colors:[c,c] as CFArray,locations:[0,1]) else{return false}
        context.saveGState();defer{context.restoreGState()}
        context.clip(to:g.destination)
        context.translateBy(x:g.tile.minX,y:g.tile.minY)
        context.drawLinearGradient(gradient,start:.zero,end:CGPoint(x:0,y:g.tile.height),options:[.drawsBeforeStartLocation,.drawsAfterEndLocation])
        return true
    }
}
