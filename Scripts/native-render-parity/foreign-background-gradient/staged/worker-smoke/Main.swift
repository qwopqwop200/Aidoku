import Foundation
import QuartzCore
import CryptoKit
@main struct WorkerSmoke {
 static func main() throws {
  let output=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
  let reference=URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)
  try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
  let done=DispatchSemaphore(value:0)
  let thread=Thread {
   defer{done.signal()}
   var reports:[[String:Any]]=[]
   do {
    for (name,rgb) in [("red",[220.0,30,40]),("blue",[30.0,40,220])] {
     let value=try NativeDetachedGradientWorkerScene.capture(rgb:rgb)
     let ref=try Data(contentsOf:reference.appendingPathComponent(name+"-flush.rgba"))
     try value.canonicalRGBA.write(to:output.appendingPathComponent(name+"-worker.rgba"))
     let equal=value.canonicalRGBA==ref
     reports.append(["scene":name,"actualThreadIsMain":Thread.isMainThread,"exactToSameHostMainFlush":equal,"RGBAHash":SHA256.hash(data:value.canonicalRGBA).map{String(format:"%02x",$0)}.joined(),"metadata":value.metadata])
     guard equal && !Thread.isMainThread else{throw NSError(domain:"WorkerSmoke",code:1)}
    }
    try JSONSerialization.data(withJSONObject:["passed":true,"reports":reports],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("report.json"))
   }catch{try? JSONSerialization.data(withJSONObject:["passed":false,"reports":reports,"error":String(describing:error)],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("report.json"))}
  }
  thread.name="Detached gradient private-tree smoke";thread.start();done.wait()
  // Separate dedicated threads exercise cooperative admission and post-GPU checkpoints.
  for mode in ["pre","post","final"] {
   let finished=DispatchSemaphore(value:0)
   let worker=Thread {
    defer{finished.signal()}
    let root=CALayer();root.frame=CGRect(x:0,y:0,width:320,height:160);root.backgroundColor=CGColor(gray:1,alpha:1)
    let oldAnchor=root.anchorPoint,oldPosition=root.position
    var successfulCheckpointCount=0
    if mode=="final"{_ = try? NativeDetachedWorkerMetalCapture.capture(root:root,size:CGSize(width:320,height:160),scale:3){successfulCheckpointCount+=1}}
    var checkpoints=0,cancelled=false
    do {
     _=try NativeDetachedWorkerMetalCapture.capture(root:root,size:CGSize(width:320,height:160),scale:3) {
      checkpoints+=1
      if (mode=="pre" && checkpoints==1)||(mode=="post" && checkpoints==4)||(mode=="final" && checkpoints==successfulCheckpointCount){Thread.current.cancel()}
      if Thread.current.isCancelled{throw CancellationError()}
     }
    }catch is CancellationError{cancelled=true}catch{}
    let restored=root.superlayer==nil&&root.anchorPoint==oldAnchor&&root.position==oldPosition&&CATransform3DIsIdentity(root.transform)
    try? JSONSerialization.data(withJSONObject:["mode":mode,"actualThreadIsMain":Thread.isMainThread,"actualThreadCancelled":Thread.current.isCancelled,"cancellationError":cancelled,"checkpoints":checkpoints,"modelRestored":restored,"successfulCheckpointCount":successfulCheckpointCount,"finalCheckpointReached":mode=="final" && checkpoints==successfulCheckpointCount,"scope":"Cooperative checkpoint test; post checkpoint after GPU completion, no GPU preemption claim"],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent(mode+"-cancellation.json"))
   }
   worker.start();finished.wait()
  }
 }
}
