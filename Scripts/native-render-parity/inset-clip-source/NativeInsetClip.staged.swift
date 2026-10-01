import CoreGraphics

/// Bounded external equation proof. The caller supplies WebKit's already
/// device-snapped Float reference box and the original unit declaration.
enum NativeInsetClipProof {
    enum Unit { case pixels(Double), percent(Double) }

    static func rect(referenceBox: CGRect, top: Unit, right: Unit, bottom: Unit, left: Unit) -> CGRect? {
        let box = [referenceBox.minX,referenceBox.minY,referenceBox.width,referenceBox.height].map(Float.init)
        guard box.allSatisfy(\.isFinite),box[2]>=0,box[3]>=0 else { return nil }
        func evaluate(_ unit: Unit, _ reference: Float) -> Float? {
            let result: Float
            switch unit {
            case .pixels(let value): result=Float(value)
            case .percent(let value): result=Float(Double(Float(value))/100.0*Double(reference))
            }
            return result.isFinite ? result : nil
        }
        guard let l=evaluate(left,box[2]),let r=evaluate(right,box[2]),let t=evaluate(top,box[3]),let b=evaluate(bottom,box[3]) else {return nil}
        let x=l+box[0],y=t+box[1],width=max((box[2]-l)-r,0),height=max((box[3]-t)-b,0)
        guard [x,y,width,height].allSatisfy(\.isFinite) else{return nil}
        return CGRect(x:CGFloat(x),y:CGFloat(y),width:CGFloat(width),height:CGFloat(height))
    }

    /// Exact zero-radius PreferBezier command shape; nonzero round radii are
    /// intentionally unsupported by this bounded proof helper.
    static func zeroRadiusPath(rect: CGRect) -> CGPath? {
        let x=Float(rect.minX),y=Float(rect.minY),w=Float(rect.width),h=Float(rect.height)
        guard [x,y,w,h].allSatisfy(\.isFinite),w>0,h>0 else{return nil}
        let right=x+w,bottom=y+h
        let path=CGMutablePath()
        path.move(to:CGPoint(x:CGFloat(x),y:CGFloat(y)))
        path.addLine(to:CGPoint(x:CGFloat(right),y:CGFloat(y)))
        path.addLine(to:CGPoint(x:CGFloat(right),y:CGFloat(bottom)))
        path.addLine(to:CGPoint(x:CGFloat(x),y:CGFloat(bottom)))
        path.addLine(to:CGPoint(x:CGFloat(x),y:CGFloat(y)))
        path.closeSubpath()
        return path
    }
}
