import CoreGraphics
import Foundation
@main struct EarlyTrialProbe {
 static func main() throws {
 let fs=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
 var results:[[String:Any]]=[]
 for f in fs {
  func ds(_ v:Any?)->[Double] { (v as? [NSNumber])?.map(\.doubleValue) ?? [] }
  func bool(_ k:String)->Bool { f[k] as? Bool ?? false }
  let w=f["w"] as! Int,h=f["h"] as! Int,frame=CGRect(x:0,y:0,width:w,height:h),bounds=ds(f["bounds"]),p=ds(f["plate"])
  let canvas=NativeEarlyMarginPixels.Canvas(id:"A",width:w,height:h,rgba:(f["rgba"] as! [NSNumber]).map(\.uint8Value),safe:(f["safe"] as! [NSNumber]).map(\.uint8Value),luminance:(f["luminance"] as! [NSNumber]).map(\.uint8Value),geometry:.init(frame:frame,imageSize:frame.size,origin:.zero,scale:.init(width:1,height:1)),erasureComplete:true,erasureVerified:bool("verified"))
  let geometry=NativeFinalRestorationTrial.Geometry(imageSize:frame.size,frame:frame,cropOrigin:.zero,scale:.init(width:1,height:1),sourceBounds:bounds,sourceFontSize:(f["font"] as! NSNumber).doubleValue)
  let coverage=NativeFinalRestorationTrial.marginCoverage(geometry:geometry,sourceFrame:frame,oldPlate:.init(x:p[0],y:p[1],width:p[2],height:p[3]),padding:.init(width:3,height:8),displayedFontSize:10)!
  let state=NativeEarlyMarginTrial.State(canvas:canvas,revision:7,partialCertified:bool("partial"))
  let e=NativeEarlyMarginTrial.Entry(state:state,coverage:coverage,sourceCorePixels:(f["corePixels"] as! NSNumber).doubleValue)
  e.sourceSingleColumn=true;e.sourceGlyphsVerified=bool("glyphsVerified");e.sourceRemainingInk=(f["remaining"] as! NSNumber).doubleValue
  e.sourceBodyCoverage=[CGRect(x:bounds[0]*Double(w),y:bounds[1]*Double(h),width:bounds[2]*Double(w),height:bounds[3]*Double(h))]
  let fits=f["fits"] as! [String:Bool],budget=NativeEarlyMarginTrial.Budget(artworkRemaining:f["artworkBudget"] as! Int,paperRemaining:0);var trace:[String]=[]
  let callbacks=NativeEarlyMarginTrial.Callbacks(publish:{_ in},refresh:{_ in},fit:{ _,mode in trace.append("fit:"+mode.rawValue);return fits[mode.rawValue]! },largerPaper:{_,_ in nil},replaceCandidate:{_,_,_ in},sourcePosition:{_ in false},eligible:{ e in trace.append("eligible");return bool("eligible") || e.state.canvas.safe.allSatisfy { $0==1 } },completeResidual:{ e in
   trace.append("residual");if !bool("residual") { return nil }
   let safe=e.state.canvas.safe,luma=e.state.canvas.luminance
   e.state.canvas.safe=[UInt8](repeating:1,count:w*h);e.state.canvas.luminance=[UInt8](repeating:255,count:w*h);e.state.revision+=1
   return { trace.append("undo-residual");e.state.canvas.safe=safe;e.state.canvas.luminance=luma;e.state.revision+=1 }
  },residualKey:{_ in "refused-key"},commitResidual:{_ in trace.append("commit-residual") })
  NativeEarlyMarginTrial.run([e],budget:budget,callbacks:callbacks)
  var metadata=e.state.metadata;metadata["aidokuRegion"]="A";if let policy=e.state.policy { metadata["sourceErasurePolicy"]=policy }
  results.append(["id":f["id"]!,"trace":trace,"safe":e.state.canvas.safe,"luminance":e.state.canvas.luminance,"revision":e.state.revision,"partial":e.state.partialCertified,"policy":e.state.policy as Any? ?? NSNull(),"residualRefused":e.state.residualRefused as Any? ?? NSNull(),"artworkBudget":budget.pixels.exterior,"metadata":metadata])
 }
 try JSONSerialization.data(withJSONObject:results).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
 }
}
