import AidokuNativeCV
import Foundation
import CoreGraphics

// The harness supplies already-authenticated, bounded source context records.
// Extraction and final orchestration are production code; this boundary shell
// avoids running unrelated page/appearance/font producers in an isolated test.
final class NativeAppearanceModelHeads {
    let directory: URL
    private let registry: NativeFrozenSourceModel.Registry
    init(directory: URL) throws { self.directory=directory; registry=try .init(directory:directory) }
    func model(_ identity:String) throws -> NativeFrozenSourceModel {try registry.model(identity)}
}
enum NativeSourceWeightMeasurements {
    struct Result {
        let raw866:[[Double]],fill71:[[Double]],paired48:[[Double]],bands112:[[Double]],angles131:[Double]
        let residualReused:[Bool],sourceEMs:[Double],mixed:[Bool]
        let physicalReferenceAvailable = [true,true,true]
    }
}
final class NativeAcceptedSourceFontInference {
    enum SourceGeometry {case bboxOnly}
    struct Word {let text:String;let bbox:CGRect}
    struct Packet {let width:Int,height:Int;let wordEvidence:[Word];let values:[String:Any]}
    struct SourceFontContext {let packets:[Packet];let finalSourceEMs:[Double];let geometryMode:SourceGeometry = .bboxOnly;let angles131:[Double]}
    func weightMeasurements(_ context:SourceFontContext,styles:[[String:Any]]) throws -> NativeSourceWeightMeasurements.Result {
        var raw=[[Double]](),fills=[[Double]](),paired=[[Double]](),bands=[[Double]](),angles=[Double](),mixed=[Bool]()
        for (i,p) in context.packets.enumerated(){var v=p.values;v["style"]=styles[i];v["sourceEm"]=context.finalSourceEMs[i]
            v["weightMemberPolygons"]=(v["wordMembers"] as! [[String:Any]]).map {$0["polygon"]!}
            var error:NSError?;guard let m=AIDExtractSourceWeightSignals(v,&error) else {throw error!}
            raw.append((m["raw597"] as! [Double])+(m["direct7"] as! [Double])+(m["weightStyle187"] as! [Double]))
            fills.append(m["fill71"] as! [Double]);paired.append(m["paired48"] as! [Double]);bands.append(m["bands112"] as! [Double]);angles.append(m["weightAngle131"] as! Double);mixed.append(m["qualifiedMixed"] as! Bool)
        }
        return .init(raw866:raw,fill71:fills,paired48:paired,bands112:bands,angles131:angles,residualReused:Array(repeating:false,count:raw.count),sourceEMs:context.finalSourceEMs,mixed:mixed)
    }
    func weightImageEvidence(_ context:SourceFontContext,index:Int,style:[String:Any],sourceEM:Double,kind:String,references:[[String:Any]],ordered:Bool=false,policy:[String:Any]?=nil,sourceAngle:Double?=nil) throws -> [String:Any]{
        var v=context.packets[index].values;v["style"]=style;v["sourceEm"]=sourceEM;v["kind"]=kind;v["referenceInkPairs"]=references;v["includeOrdered"]=ordered;v["policy"]=policy;v["sourceAngle"]=sourceAngle ?? context.angles131[index]
        var error:NSError?;guard let m=AIDMeasureSourceWeightImageEvidence(v,&error) else {throw error!};return m
    }
}
@main struct SourceWeightReplay {
 static func main() throws {
  let args=CommandLine.arguments,heads=try NativeAppearanceModelHeads(directory:URL(fileURLWithPath:args[1])),font=NativeAcceptedSourceFontInference()
  let weight=try NativeAcceptedSourceWeightInference(heads:heads,font:font,fontResources:URL(fileURLWithPath:args[2]))
  let batches=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:args[3]))) as! [[String:Any]]
  var outputs=[[String:Any]]()
  for batch in batches {var packets=[NativeAcceptedSourceFontInference.Packet](),styles=[[String:Any]](),ems=[Double]()
   for var row in batch["packets"] as! [[String:Any]] {
    for key in ["rgb","ownership","valid","primary","boundary","rf","nativeMask"] {row[key]=Data(base64Encoded:row[key] as! String)!}
    let words=(row["wordMembers"] as! [[String:Any]]).map { word -> NativeAcceptedSourceFontInference.Word in let b=word["bbox"] as! [Double];return .init(text:word["text"] as! String,bbox:CGRect(x:b[0],y:b[1],width:b[2],height:b[3]))}
    packets.append(.init(width:row["width"] as! Int,height:row["height"] as! Int,wordEvidence:words,values:row));styles.append(row["style"] as! [String:Any]);ems.append(row["sourceEm"] as! Double)
   }
   let context=NativeAcceptedSourceFontInference.SourceFontContext(packets:packets,finalSourceEMs:ems,angles131:Array(repeating:0,count:packets.count))
   let rows=try weight.estimate(context,styles:styles);outputs.append(["page":batch["page"]!,"rows":rows])
  }
  try JSONSerialization.data(withJSONObject:outputs,options:[.sortedKeys]).write(to:URL(fileURLWithPath:args[4]))
 }
}
