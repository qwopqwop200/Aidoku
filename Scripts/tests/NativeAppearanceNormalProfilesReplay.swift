import CoreGraphics
import Foundation

enum NativeRFDETRLayoutResource {
    static let highresSourceWeightsSHA256="03de2f77281974f5084cdd8652ace2b55dc15ac0378aed66654e62537cdda255"
}
@main enum NativeAppearanceNormalProfilesReplay {
    struct Request:Decodable {
        let width:Int;let height:Int;let rgb:[UInt8];let mask:[UInt8];let font:Double
        let colors:[[Double]];let polygons:[[[Double]]];let prediction:NativeFrozenSourceModel.Value
        let features:[[Float]];let pair:[[[Float]]];let roleRoot:String
    }
    static func main() throws {
        let request=try JSONDecoder().decode(Request.self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
        let w=request.width,h=request.height
        let polygons=request.polygons.map {$0.map {CGPoint(x:$0[0],y:$0[1])}}
        var input=SourceNativeInput(width:w,height:h,rgb:request.rgb,rf:[],coarseRF:[],affinityScores:[],
            rfModelWeightsSHA256:NativeRFDETRLayoutResource.highresSourceWeightsSHA256,memberPolygons:polygons,
            mergedPolygon:polygons.first ?? [],bbox:CGRect(x:0,y:0,width:w,height:h),fontPriorSourcePixels:request.font,
            crop:CGRect(x:0,y:0,width:w,height:h),pageSize:CGSize(width:w,height:h),sourceIdentity:"normal-profile-parity",
            sourceText:"source",confidence:0.9,role:"dialogue")
        input.ownMask=request.mask
        var prediction=request.prediction.foundationValue as! [String:Any]
        for key in ["fillIndex","outlineIndex","backgroundIndex"] {if let v=prediction[key] as? NSNumber {prediction[key]=v.intValue}}
        let packet=NativeAppearanceSourceFeatures209.Packet(colors:request.colors,features:request.features,pair:request.pair,
            fontPixels:request.font,maskFraction:Double(request.mask.filter {$0 != 0}.count)/Double(w*h))
        let ops=NativeOpenCVAppearanceImageOperations()
        let rings=try NativeAppearanceNormalProfiles.measure(input:input,packet:packet,prediction:prediction,ops:ops)
        let primary=try NativeAppearanceNormalProfiles.measure(input:input,packet:packet,prediction:prediction,ops:ops,discovery:true,primaryOnly:true)
        let discovery=try NativeAppearanceNormalProfiles.measure(input:input,packet:packet,prediction:prediction,ops:ops,discovery:true)
        let attached=try NativeAppearanceNormalProfiles.attachLayers(input:input,packet:packet,prediction:prediction,ops:ops)
        let heads=try NativeAppearanceModelHeads(directory:URL(fileURLWithPath:CommandLine.arguments[2]))
        let config:[String:Any]
        if request.roleRoot=="appearance/model" {config=try heads.configuration(request.roleRoot)}
        else {config=(try heads.configuration("appearance/pixel-role-model")["featureContext"] as! [String:Any])["roleModel"] as! [String:Any]}
        let corrected=try NativeAppearanceNormalProfiles.correctPrimary(input:input,packet:packet,prediction:prediction,heads:heads,
            ops:ops,roleRoot:request.roleRoot,roleConfiguration:config)
        let output:[String:Any]=["rings":rings,"primary":primary,"discovery":discovery,"attached":attached,"corrected":corrected]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]))
    }
}
