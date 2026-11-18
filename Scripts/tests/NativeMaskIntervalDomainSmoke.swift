import Foundation
import CoreGraphics

@main enum MaskIntervalDomainChecks {
    static func main() throws {
        let page=CGRect(x:0,y:0,width:1000,height:800)
        var policy=NativeTextExpansionPolicy(allowedRectNormalized:[0,0,1,1],candidates:[[0,0,1,1]],
            maskCoverage:[1],backgroundRisk:[0],sourceFontPixels:40,kind:"inside-balloon-mask",
            maskRectNormalized:[0,0.1,1,0.8],maskSpansNormalized:Array(repeating:[0.1,0.45],count:4).flatMap{$0})
        let left=CGRect(x:120,y:100,width:260,height:150),right=CGRect(x:700,y:100,width:180,height:150)
        precondition(policy.valid && policy.allows(left,page:page) && !policy.allows(right,page:page))
        policy.maskIntervalRowsNormalized=Array(repeating:[0.1,0.45,0.65,0.95],count:4)
        precondition(policy.valid && policy.allows(left,page:page) && policy.allows(right,page:page))
        precondition(!policy.allows(CGRect(x:400,y:100,width:320,height:150),page:page))
        let shifts=policy.projectedShifts(bounds:left,page:page,preferred:CGPoint(x:590,y:0),font:40)
        precondition(shifts.contains {policy.allows(left.offsetBy(dx:$0.x,dy:$0.y),page:page) && left.minX+$0.x>=650})
        precondition(shifts.contains {policy.allows(left.offsetBy(dx:$0.x,dy:$0.y),page:page) && left.maxX+$0.x<=450})
        precondition(shifts.allSatisfy {policy.allows(left.offsetBy(dx:$0.x,dy:$0.y),page:page)})
        let encoded=try JSONEncoder().encode(policy)
        let decoded=try JSONDecoder().decode(NativeTextExpansionPolicy.self,from:encoded)
        precondition(decoded==policy)
        policy.maskIntervalRowsNormalized?[1]=[0.1,0.7,0.65,0.95]
        precondition(!policy.valid)
        print("PASS: both source-safe lobes retained, gap rejected, fixed-size projections, typed roundtrip, malformed intervals rejected")
    }
}
