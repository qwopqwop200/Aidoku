import Foundation
import CoreGraphics
@main struct LateGradientMain {
    typealias L=NativeAppearanceLateGradient
    static func main() throws {
        let base=URL(fileURLWithPath:CommandLine.arguments[1]),output=URL(fileURLWithPath:CommandLine.arguments[2])
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let heads=try NativeAppearanceModelHeads(directory:root.appendingPathComponent("Aidoku/Resources/Translation/SourceModels")),ops=NativeOpenCVAppearanceImageOperations()
        let cases=try JSONSerialization.jsonObject(with:Data(contentsOf:base.appendingPathComponent("INPUT.json"))) as! [[String:Any]]
        var results:[[String:Any]]=[]
        for source in cases {
            let w=source["width"] as! Int,h=source["height"] as! Int,n=w*h,name=source["name"] as! String
            func bytes(_ key:String)throws->Data {try Data(contentsOf:base.appendingPathComponent(source[key] as! String))}
            func floats(_ key:String)throws->[Float] {try bytes(key).withUnsafeBytes {raw in stride(from:0,to:raw.count,by:4).map {Float(bitPattern:raw.loadUnaligned(fromByteOffset:$0,as:UInt32.self))}}}
            let polygons=(source["polygons"] as! [[[Double]]]).map {$0.map {CGPoint(x:$0[0],y:$0[1])}}
            let points=polygons.flatMap {$0}
            let minX=points.map(\.x).min()!,maxX=points.map(\.x).max()!,minY=points.map(\.y).min()!,maxY=points.map(\.y).max()!
            let polygon=(source["mergedPolygon"] as! [[Double]]).map {CGPoint(x:$0[0],y:$0[1])}
            _ = minX; _ = maxX; _ = minY; _ = maxY
            var input=SourceNativeInput(width:w,height:h,rgb:Array(try bytes("rgb")),rf:try floats("rf"),coarseRF:Array(repeating:0,count:n*4),affinityScores:Array(repeating:0,count:5),
                rfModelWeightsSHA256:NativeRFDETRLayoutResource.highresSourceWeightsSHA256,memberPolygons:polygons,mergedPolygon:polygon,bbox:CGRect(x:0,y:0,width:w,height:h),
                fontPriorSourcePixels:source["font"] as! Double,crop:CGRect(x:0,y:0,width:w,height:h),pageSize:CGSize(width:w,height:h),sourceIdentity:name,sourceText:"HAXT",confidence:0.99,role:"dialogue")
            input.primary=try floats("primary");input.boundary=try floats("boundary");input.ownMask=Array(try bytes("mask"));input.contextMask=input.ownMask;input.ocr=try floats("ocr")
            let prediction=source["prediction"] as! [String:Any],packet=try NativeAppearanceSourceFeatures209.extract(input,ops:ops)
            let engine=try L.Engine(input,packet:packet,heads:heads,ops:ops)
            let options=try engine.nativeOptions(prediction)
            let config=try heads.configuration("appearance/native-primary-quality-model"),names=config["featureNames"] as! [String]
            let featureRows=try (0..<3).map {i -> [Any] in let row=try engine.primaryFeatures(prediction,options:options,index:i);return names.map {key in let value=row[key]!;return value.isFinite ? value:NSNull()}}
            let qualityModel=try heads.model("appearance/native-primary-quality-model/model")
            let qualityScores=try (0..<3).map {i -> Double in let row=try engine.primaryFeatures(prediction,options:options,index:i);return try qualityModel.predict(names.map {row[$0]!})[0]}
            let groups=try engine.gradientGroups(prediction),measure=try engine.contourMeasure(groups)
            let bright=try engine.brightProposals(prediction)
            var row:[String:Any]=["name":name,"options":options.map {option -> [String:Any] in ["nativeRGB":option.rgb as Any? ?? NSNull(),"evidence":option.evidence]},"features88":featureRows,"qualityScores":qualityScores,
                "gradientGroups":groups.map(\.count),"gradientMeasure":measure,"brightProposals":bright.map {p -> [String:Any] in ["rgb":p.color,"candidateRGB":p.candidate,"holes":p.holes.count,"samples":p.samples,"semantic":engine.brightSemantic(p)]}]
            let refined=try L.refine(input:input,packet:packet,prediction:prediction,heads:heads,ops:ops)
            row["refined"]=refined
            let warm=try L.refine(input:input,packet:packet,prediction:refined,heads:heads,ops:ops)
            row["warm"]=warm
            if let diagnostic=source["shellDiagnostic"] as? [String:Any] {
                row["shell"]=try engine.outerShell(prediction,diagnostic:diagnostic,threshold:0)
            }
            results.append(row)
            FileHandle.standardError.write(Data((name+" done\n").utf8))
        }
        try JSONSerialization.data(withJSONObject:results,options:[.sortedKeys]).write(to:output)
    }
}
