import CoreGraphics
import Foundation

enum NativeRFDETRLayoutResource {
    static let highresSourceWeightsSHA256="03de2f77281974f5084cdd8652ace2b55dc15ac0378aed66654e62537cdda255"
}
@main enum NativeAppearanceGlowSmoke {
    static func main() throws {
        let data=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
        let request=try JSONSerialization.jsonObject(with:data) as! [String:Any]
        let w=request["width"] as! Int,h=request["height"] as! Int
        let rect=[CGPoint(x:0,y:0),CGPoint(x:w-1,y:0),CGPoint(x:w-1,y:h-1),CGPoint(x:0,y:h-1)]
        var input=SourceNativeInput(width:w,height:h,rgb:request["rgb"] as! [UInt8],rf:[],coarseRF:[],affinityScores:[],
            rfModelWeightsSHA256:NativeRFDETRLayoutResource.highresSourceWeightsSHA256,memberPolygons:[rect],mergedPolygon:rect,
            bbox:CGRect(x:0,y:0,width:w,height:h),fontPriorSourcePixels:request["font"] as! Double,
            crop:CGRect(x:0,y:0,width:w,height:h),pageSize:CGSize(width:w,height:h),sourceIdentity:"source-glow-smoke",sourceText:"source",confidence:nil,role:nil)
        input.ownMask=request["mask"] as! [UInt8]
        let result=try NativeAppearanceDiffuseGlow.observe(input:input,prediction:request["prediction"] as! [String:Any],
            ops:NativeOpenCVAppearanceImageOperations())
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:result ?? [:],options:[.sortedKeys]))
    }
}
