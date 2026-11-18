import Foundation
import CoreGraphics

// Cache-only regression: no model inference, source dataset or GT.
enum HostDump { static func capture(_ name:String,_ value:[String:Any]) {} }
@main enum RFCacheSmoke {
 static func main() throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]);let temp=FileManager.default.temporaryDirectory.appendingPathComponent("rf-semantic-cache-"+UUID().uuidString);try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:temp)}
  let old=ProcessInfo.processInfo.environment[NativeRFDETRSemanticGrid.environmentKey];setenv(NativeRFDETRSemanticGrid.environmentKey,"synthetic-cache-test",1);defer{if let old{setenv(NativeRFDETRSemanticGrid.environmentKey,old,1)}else{unsetenv(NativeRFDETRSemanticGrid.environmentKey)}}
  let source=try NativeRFDETRSourceImage(width:32,height:32,rgb:Data(repeating:0,count:32*32*3));let bounds=CGRect(x:0,y:0,width:32,height:32);let normalized=CGRect(x:0,y:0,width:1,height:1)
  let mask=NativeRFDETRLayoutMask(queryID:0,sourceWidth:32,sourceHeight:32,logits:[Float](repeating:1,count:162*162));let primitive=NativeRFDETRLayoutPrimitive(queryID:0,semanticClass:.text,confidence:0.9,normalizedBounds:normalized,sourceBounds:bounds,mask:mask)
  let raw=(0..<300).map{q in NativeRFDETRClassEvidence(queryID:q,logits:[Float](repeating:-12,count:5),probabilities:[Float](repeating:1/(1+exp(12)),count:5),normalizedBounds:normalized,sourceBounds:bounds,mask:q==0 ? mask:nil)}
  let grid=NativeRFDETRSemanticGrid(width:32,height:32,side:162,probabilities:[Float](repeating:0.2,count:4*162*162),modelWeightsSHA256:"synthetic",imageIdentity:source.identity)
  let result=NativeRFDETRLayoutResult(imageIdentity:source.identity,sourceWidth:32,sourceHeight:32,primitives:[primitive],maskQueriesOmittedByBudget:0,preprocessingMilliseconds:0,modelMilliseconds:1,decodeMilliseconds:0,computeUnits:"synthetic",fromCache:false,classEvidence:raw,semanticGrid:grid)
  var rgba=[UInt8](repeating:0,count:32*32*4);for i in 0..<(32*32){rgba[i*4+3]=255};let provider=CGDataProvider(data:Data(rgba)as CFData)!;let image=CGImage(width:32,height:32,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:128,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
  let context=try HostRFLayoutReplay.Context(root:root,cache:temp,sourceSHA256:String(repeating:"a",count:64),width:32,height:32)
  try HostRFLayoutReplay.$context.withValue(context) {
   let first=try HostRFLayoutReplay.store(result,maximumMasks:160);precondition(first.classEvidence.count==300 && first.semanticGrid?.probabilities==grid.probabilities)
   let hit=try HostRFLayoutReplay.read(image:image,maximumMasks:160);precondition(hit?.fromCache==true && hit?.classEvidence.count==300 && hit?.semanticGrid?.probabilities==grid.probabilities)
   precondition(hit?.evidenceStorageBytes==(1+4)*162*162*4)
   let enumerator=FileManager.default.enumerator(at:temp,includingPropertiesForKeys:nil)!;let field=enumerator.allObjects.compactMap{$0 as? URL}.first{$0.lastPathComponent.hasPrefix("semantic-")}!;try Data(repeating:0,count:4*162*162*4).write(to:field)
   var rejected=false;do{_ = try HostRFLayoutReplay.read(image:image,maximumMasks:160)}catch{rejected=true};precondition(rejected)
  }
  print("PASS: fresh/cache preserve all300 class queries and semantic fields, memory accounting and corrupt payload rejection")
 }
}
