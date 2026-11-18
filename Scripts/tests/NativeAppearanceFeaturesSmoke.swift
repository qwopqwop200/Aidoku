import CoreGraphics
import Foundation

// Standalone source-feature executable; only resource identity constants are
// substituted. Production feature and real OpenCV implementation are compiled.
enum NativeRFDETRLayoutResource {
    static let highresSourceWeightsSHA256="03de2f77281974f5084cdd8652ace2b55dc15ac0378aed66654e62537cdda255"
}

@main enum NativeAppearanceFeaturesSmoke {
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
        let packet=try NativeAppearanceSourceFeatures209.extract(input,ops:ops)
        let positions=Array(stride(from:0,to:w*h,by:7))
        let first=packet.colors[0],last=packet.colors.last!
        let pixel=try NativeAppearancePixelFeatures71.extract(input,positions:positions,fill:first,outline:last,
            background:packet.colors[min(1,packet.colors.count-1)],outlinePresent:true,outlineProbability:0.7,ops:ops)
        let width=try NativeAppearanceOutlineWidthEvidence.measure(rgb:input.rgb,mask:input.ownMask,
            width:w,height:h,fill:first,outline:last)
        let adaptive=try NativeAppearanceAdaptiveWidth50.measure(input,fill:first,primary:last,present:true,ops:ops)
        let result:[String:Any]=["colors":packet.colors,"features":packet.features,"pair":packet.pair,
            "pixelFeatures":pixel,"widthVector":width.vector,"adaptiveWidthFeatures":adaptive.features]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]))
    }
}
