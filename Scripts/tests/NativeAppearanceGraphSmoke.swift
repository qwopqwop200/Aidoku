import CoreGraphics
import Foundation

// Standalone source-feature executable; only resource identity constants are
// substituted. Production feature and real OpenCV implementation are compiled.
enum NativeRFDETRLayoutResource {
    static let highresSourceWeightsSHA256="03de2f77281974f5084cdd8652ace2b55dc15ac0378aed66654e62537cdda255"
}

@main enum NativeAppearanceGraphSmoke {
    struct Request:Decodable {
        let width:Int;let height:Int;let rgb:[UInt8];let mask:[UInt8]
        let rf:[Float];let primary:[Float];let boundary:[Float];let ocr:[Float]
        let polygons:[[[Double]]];let mergedPolygon:[[Double]];let font:Double
    }
    static func main() throws {
        let request=try JSONDecoder().decode(Request.self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
        let w=request.width,h=request.height
        var input=SourceNativeInput(width:w,height:h,rgb:request.rgb,rf:request.rf,
            coarseRF:[Float](repeating:0,count:w*h*4),affinityScores:[Float](repeating:0,count:5),
            rfModelWeightsSHA256:NativeRFDETRLayoutResource.highresSourceWeightsSHA256,
            memberPolygons:request.polygons.map {$0.map {CGPoint(x:$0[0],y:$0[1])}},
            mergedPolygon:request.mergedPolygon.map {CGPoint(x:$0[0],y:$0[1])},
            bbox:CGRect(x:0,y:0,width:w,height:h),fontPriorSourcePixels:request.font,
            crop:CGRect(x:0,y:0,width:w,height:h),pageSize:CGSize(width:w,height:h),sourceIdentity:"synthetic-parity",
            sourceText:"source",confidence:0.9,role:"dialogue")
        input.primary=request.primary;input.boundary=request.boundary
        input.ownMask=request.mask;input.contextMask=request.mask;input.ocr=request.ocr
        let ops=NativeOpenCVAppearanceImageOperations()
        NativeAppearanceInferenceGraph.installBuiltInPolicies()
        let heads=try NativeAppearanceModelHeads(directory:URL(fileURLWithPath:CommandLine.arguments[2]))
        let graph=try NativeAppearanceInferenceGraph(heads:heads,ops:ops)
        let result=try graph.predict(input)
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]))
    }
}
