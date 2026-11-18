import CoreGraphics
import Foundation

/// Fixed glyph rectangles on the existing predicted contour. A soft margin is
/// optional; the original hard mask and every native glyph remain mandatory.
enum NativeContourTextClearance {
    struct Plan {
        let origin:CGPoint
        let margin:CGFloat
        let oldMargin:CGFloat
        let sourceCostBefore:CGFloat
        let sourceCostAfter:CGFloat
    }
    static func sourceCost(_ paint:CGRect,_ source:CGRect)->CGFloat {
        pow(paint.midX-source.midX,2)+pow(paint.midY-source.midY,2)
    }
    static func margin(_ paint:CGRect,policy:NativeTextExpansionPolicy,page:CGRect,limit:Int)->Int {
        guard limit>0 else{return 0}
        var result=0
        for value in 1...limit {
            let expanded=paint.insetBy(dx:-CGFloat(value),dy:-CGFloat(value))
            if !policy.allows(expanded,page:page) {break}
            result=value
        }
        return result
    }
    static func plans(paint:CGRect,source:CGRect,policy:NativeTextExpansionPolicy,
                      guide:NativeTextPlacementGuide,font:CGFloat,page:CGRect)->[Plan] {
        guard policy.valid,policy.insideBalloon,font.isFinite,font>0,font<=2048,
              !paint.isNull,!paint.isEmpty,paint.width.isFinite,paint.height.isFinite,
              !source.isNull,!source.isEmpty else{return []}
        let target=Int(ceil(font*0.2)),old=margin(paint,policy:policy,page:page,limit:target)
        guard target>old else{return []}
        let before=sourceCost(paint,source)
        guard before.isFinite else{return []}
        let towardSource=CGPoint(x:source.midX-paint.midX,y:source.midY-paint.midY)
        var result:[Plan]=[],seen=Set<String>()
        for value in stride(from:target,through:old+1,by:-1) {
            let expanded=paint.insetBy(dx:-CGFloat(value),dy:-CGFloat(value))
            for preferred in [CGPoint.zero,towardSource] {
                for delta in policy.projectedShifts(bounds:expanded,page:page,preferred:preferred,font:font) {
                    let proposed=paint.offsetBy(dx:delta.x,dy:delta.y)
                    let cost=sourceCost(proposed,source),key="\(proposed.minX),\(proposed.minY)"
                    guard cost<=before+1e-7,policy.sourceAnchorAllows(proposed,page:page,guide:guide),
                          policy.allows(proposed.insetBy(dx:-CGFloat(value),dy:-CGFloat(value)),page:page),
                          seen.insert(key).inserted else{continue}
                    result.append(.init(origin:proposed.origin,margin:CGFloat(value),oldMargin:CGFloat(old),
                        sourceCostBefore:before,sourceCostAfter:cost))
                }
            }
        }
        return result.sorted {a,b in
            if a.margin != b.margin {return a.margin>b.margin}
            let A=pow(a.origin.x-paint.minX,2)+pow(a.origin.y-paint.minY,2)
            let B=pow(b.origin.x-paint.minX,2)+pow(b.origin.y-paint.minY,2)
            if A != B {return A<B}
            if a.sourceCostAfter != b.sourceCostAfter {return a.sourceCostAfter<b.sourceCostAfter}
            return a.origin.y==b.origin.y ? a.origin.x<b.origin.x:a.origin.y<b.origin.y
        }
    }
}
