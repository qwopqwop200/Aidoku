import Foundation
import QuartzCore
import CryptoKit
@main struct CoreSmoke {
 static func threadIsMain()->Bool{Thread.isMainThread}
 static func root(_ rgb:[Double])->CALayer {
  let root=CALayer()
  CATransaction.begin();CATransaction.setDisableActions(true)
  root.frame=CGRect(x:0,y:0,width:320,height:160);root.contentsScale=3
  func color(_ c:[Double])->CGColor{CGColor(colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!,components:c.map{CGFloat(Float($0/255))}+[1])!}
  root.backgroundColor=color([41,65,87])
  let gradient=CAGradientLayer();gradient.frame=CGRect(x:20,y:20,width:96,height:96);gradient.contentsScale=3
  gradient.type = .axial;gradient.startPoint=CGPoint(x:0.5,y:0);gradient.endPoint=CGPoint(x:0.5,y:1);gradient.locations=[0,1];gradient.colors=[color(rgb),color(rgb)]
  root.addSublayer(gradient);CATransaction.commit()
  return root
 }
 static func main() async throws {
  let output=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true),reference=URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)
  try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
  var reports:[[String:Any]]=[]
  for (name,rgb) in [("red",[220.0,30,40]),("blue",[30.0,40,220])] {
   let packet:Data=try await Task.detached {
    let privateRoot=root(rgb)
    let captured=try NativeLayerTreeCapture.capture(size:CGSize(width:320,height:160),scale:3){privateRoot}
    let bytes=captured.image.dataProvider!.data! as Data
    let ref=try Data(contentsOf:reference.appendingPathComponent(name+"-flush.rgba"))
    try bytes.write(to:output.appendingPathComponent(name+"-core.rgba"))
    return try JSONSerialization.data(withJSONObject:["scene":name,"threadIsMain":threadIsMain(),"exactSameHostValidatedCapture":bytes==ref,"RGBAHash":SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined(),"pixelSize":[captured.image.width,captured.image.height],"rootRestored":privateRoot.superlayer==nil&&CATransform3DIsIdentity(privateRoot.transform),"scope":"Actual production candidate on a Swift detached Task, no UIKit/window/thread factory"],options:[.sortedKeys])
   }.value
   reports.append(try JSONSerialization.jsonObject(with:packet) as! [String:Any])
  }
  let signal=AsyncStream<Void>.makeStream()
  let release=DispatchSemaphore(value:0)
  let job=Task.detached {()->Bool in
   defer{signal.continuation.finish()}
   var owned:CALayer?,sawAttached=false
   do {
    _ = try NativeLayerTreeCapture.capture(size:CGSize(width:320,height:160),scale:3,checkCancellation:{
     if owned?.superlayer != nil{sawAttached=true}
     if sawAttached && owned?.superlayer==nil{signal.continuation.yield(());release.wait()}
     try Task.checkCancellation()
    },makeRoot:{let value=root([220,30,40]);owned=value;return value})
    return false
   }catch is CancellationError{return owned?.superlayer==nil && owned?.frame==CGRect(x:0,y:0,width:320,height:160) && owned.map{CATransform3DIsIdentity($0.transform)}==true}
   catch{return false}
  }
  var reached=false
  for await _ in signal.stream {reached=true;job.cancel();release.signal();break}
  let cancelled=await job.value
  let guardPacket:Data=await Task.detached {
   var invoked=false;var checks:[String:Bool]=[:]
   for (name,size) in [("nonfinite",CGSize(width:Double.nan,height:160)),("tooManyPixels",CGSize(width:4000,height:4000)),("fractionalRaster",CGSize(width:10.125,height:10))] {
    do{_ = try NativeLayerTreeCapture.capture(size:size,scale:1,makeRoot:{invoked=true;return root([220,30,40])});checks[name]=false}
    catch NativeLayerTreeCapture.Failure.invalidGeometry{checks[name] = !invoked}catch{checks[name]=false}
   }
   do{_ = try NativeLayerTreeCapture.capture(size:CGSize(width:320,height:160),scale:3,makeRoot:{let layer=root([220,30,40]);layer.bounds.origin.x=1;return layer});checks["invalidRoot"]=false}catch NativeLayerTreeCapture.Failure.invalidRoot{checks["invalidRoot"]=true}catch{checks["invalidRoot"]=false}
   return try! JSONSerialization.data(withJSONObject:checks,options:[.sortedKeys])
  }.value
  let admission=try JSONSerialization.jsonObject(with:guardPacket) as! [String:Bool]
  let passed=reports.allSatisfy{$0["exactSameHostValidatedCapture"]as?Bool==true&&$0["threadIsMain"]as?Bool==false&&$0["rootRestored"]as?Bool==true}&&reached&&cancelled&&admission.values.allSatisfy{$0}
  try JSONSerialization.data(withJSONObject:["passed":passed,"reports":reports,"swiftTaskCancelledAfterCleanup":cancelled,"finalCheckpointReached":reached,"admissionGuards":admission],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("report.json"))
  guard passed else{throw NSError(domain:"CoreSmoke",code:1)}
 }
}
