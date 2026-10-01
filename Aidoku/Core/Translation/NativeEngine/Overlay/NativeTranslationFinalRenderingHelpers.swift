import CoreGraphics
import Foundation

/// Last-stage transformed plate ownership and local gloss transforms.
enum NativeTranslationFinalRenderingHelpers {
    static func plateMeets(bounds: CGRect, width: Double, height: Double, matrix: [Double]?, ink: [Double]) -> Bool {
        guard ink.count == 4 else { return false }
        if !(ink[0] < bounds.maxX && bounds.minX < ink[2] && ink[1] < bounds.maxY && bounds.minY < ink[3]) { return false }
        guard let v=matrix,v.count == 6,v.allSatisfy(\.isFinite),width > 0,height > 0 else { return true }
        let a=v[0],b=v[1],c=v[2],d=v[3],det=a*d-b*c
        if abs(det) < 1e-6 || abs(abs(a)*width+abs(c)*height-Double(bounds.width)) > 2 ||
            abs(abs(b)*width+abs(d)*height-Double(bounds.height)) > 2 { return true }
        let cx=Double(bounds.midX),cy=Double(bounds.midY)
        var u0=Double.infinity,u1 = -Double.infinity,v0=Double.infinity,v1 = -Double.infinity
        for p in [[ink[0],ink[1]],[ink[2],ink[1]],[ink[0],ink[3]],[ink[2],ink[3]]] {
            let dx=p[0]-cx,dy=p[1]-cy,u=(d*dx-c*dy)/det,t=(a*dy-b*dx)/det
            u0=min(u0,u);u1=max(u1,u);v0=min(v0,t);v1=max(v1,t)
        }
        return u0 < width/2 && -width/2 < u1 && v0 < height/2 && -height/2 < v1
    }
    struct Turn { let angle: Double; let origin: CGPoint }
    static func turnGloss(nodeOrigin: CGPoint, angle: Double?, center: CGPoint) -> Turn? {
        guard let angle, angle != 0, !angle.isNaN else { return nil }
        return Turn(angle: angle, origin: CGPoint(x:center.x-nodeOrigin.x,y:center.y-nodeOrigin.y))
    }
}
