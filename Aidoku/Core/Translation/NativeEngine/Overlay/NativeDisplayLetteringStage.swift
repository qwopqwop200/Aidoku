import CoreGraphics
import Foundation

enum NativeDisplayLetteringStage {
    final class Budget { var colour = 393216; var blackWhite = 262144 }
    struct Other { var bounds: [Double]; var mode: String?; var plates: [CGRect] }
    struct Crop { var x: Int; var y: Int; var sw: Int; var sh: Int; var width: Int; var height: Int; var scale: Double; var box: CGRect; var glyph: Double; var rect: CGRect; var borders: [Bool] }
    static func crowded(bounds b: [Double],others: [Other])->Bool {
        guard b.count == 4 else { return true }
        return others.contains { other in let o = other.bounds; guard o.count == 4 else { return false }
            let ix = min(o[0]+o[2],b[0]+b[2])-max(o[0],b[0]), iy = min(o[1]+o[3],b[1]+b[3])-max(o[1],b[1])
            return ix > 0 && iy > 0 && ix*iy > o[2]*o[3]*0.1
        }
    }
    static func hidesOther(plate: CGRect,frame f: CGRect,others: [Other])->Bool {
        others.contains { other in let o = other.bounds; guard o.count == 4 else { return false }
            let l = Double(f.minX)+o[0]*Double(f.width), t = Double(f.minY)+o[1]*Double(f.height), w = o[2]*Double(f.width), h = o[3]*Double(f.height)
            let ix = min(l+w,Double(plate.maxX))-max(l,Double(plate.minX)), iy = min(t+h,Double(plate.maxY))-max(t,Double(plate.minY))
            if ix <= 0 || iy <= 0 || ix*iy < w*h*0.1 { return false }
            if ["inpainted","slanted-glyph-restored","rotated-panel","display-restored"].contains(other.mode ?? "") { return false }
            return !other.plates.contains { Double($0.minX) <= l+1 && Double($0.minY) <= t+1 && Double($0.maxX) >= l+w-1 && Double($0.maxY) >= t+h-1 }
        }
    }
    static func crop(bounds b: [Double],frame f: CGRect,imageSize: CGSize,glyph: Double,budget: Budget)->Crop? {
        guard b.count == 4, b.allSatisfy(\.isFinite), b[2] > 0, b[3] > 0,
              [f.minX,f.minY,f.width,f.height,imageSize.width,imageSize.height].allSatisfy(\.isFinite),
              f.width > 0, f.height > 0, imageSize.width > 0, imageSize.height > 0,
              imageSize.width <= 16384, imageSize.height <= 16384, glyph.isFinite, glyph >= 24 else { return nil }
        let iw = Double(imageSize.width), ih = Double(imageSize.height), cssToImage = iw/Double(f.width), pad = max(8,glyph*cssToImage*0.5)
        let x0 = max(0,floor(b[0]*iw-pad)), y0 = max(0,floor(b[1]*ih-pad))
        let x1 = min(iw,ceil((b[0]+b[2])*iw+pad)), y1 = min(ih,ceil((b[1]+b[3])*ih+pad))
        let sw = x1-x0, sh = y1-y0
        guard sw > 0, sh > 0, [x0,y0,x1,y1,sw,sh].allSatisfy(\.isFinite), x0 <= iw, y0 <= ih else { return nil }
        let scale = min(1,sqrt(163840/(sw*sh))), w = max(1,Int(floor(sw*scale))), h = max(1,Int(floor(sh*scale)))
        guard w >= 16, h >= 16, w*h <= budget.colour else { return nil }; budget.colour -= w*h
        let rect = CGRect(x:Double(f.minX)+x0/iw*Double(f.width),y:Double(f.minY)+y0/ih*Double(f.height),width:sw/iw*Double(f.width),height:sh/ih*Double(f.height))
        return .init(x:Int(x0),y:Int(y0),sw:Int(sw),sh:Int(sh),width:w,height:h,scale:scale,
            box:CGRect(x:(b[0]*iw-x0)*scale,y:(b[1]*ih-y0)*scale,width:b[2]*iw*scale,height:b[3]*ih*scale),
            glyph:glyph*cssToImage*scale,rect:rect,borders:[x0 == 0,y0 == 0,x1 == iw,y1 == ih])
    }
}
