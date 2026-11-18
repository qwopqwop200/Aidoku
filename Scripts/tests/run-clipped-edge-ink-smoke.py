"""A cut source-ink component may finish its cap; detached/foreign ink cannot."""
from pathlib import Path
import subprocess,sys,time
root=Path(__file__).resolve().parents[2];base=root/'Scripts/tests/run-endpoint-continuation-smoke.py';ns={'__file__':str(base)};exec(base.read_text().split("checks=r'''",1)[0],ns)
sys.path.insert(0,str(root/'Scripts'));from swift_replay_cache import compile_replay
checks=r'''
var checks=0
func check(_ x:Bool,_ message:String){if !x {fputs("FAILED: \(message)\n",stderr);exit(1)};checks+=1}
let side=400
for degree in stride(from:0.0,to:360,by:15) {
 let theta=CGFloat(degree)*CGFloat.pi/180,c=cos(theta),s=sin(theta)
 func world(_ p:CGPoint)->CGPoint {let x=p.x-150,y=p.y-160;return .init(x:200+x*c-y*s,y:200+x*s+y*c)}
 func local(_ x:Int,_ y:Int)->CGPoint {let xx=CGFloat(x)+0.5-200,yy=CGFloat(y)+0.5-200;return .init(x:150+xx*c+yy*s,y:160-xx*s+yy*c)}
 func quad(_ r:CGRect)->[CGPoint]{NativeOCRDirectionGeometry.corners(r).map(world)}
 let crop=quad(.init(x:130,y:100,width:40,height:120))
 func evidence(_ id:Int,_ r:CGRect)->NativeOCRDetectorSeedEvidence {
  var runs:[NativeOCRDetectorSeedEvidence.Run]=[]
  for y in 0..<side {var begin:Int?,end=0
   for x in 0..<side {
    if r.contains(local(x,y)){if begin==nil {begin=x};end=x+1}
    else if let start=begin {runs.append(.init(y:y,x:start,count:end-start));begin=nil}
   }
   if let start=begin {runs.append(.init(y:y,x:start,count:end-start))}
  }
  let part=NativeOCRDetectorSeedEvidence.Component(seed:runs[0].y*side+runs[0].x,pixelCount:runs.reduce(0){$0+$1.count},meanProbability:1,runs:runs)
  return .init(ownerID:"edge-\(id)",parentBoxIndex:id,provenance:"db-complete-cc-candidates-v2",threshold:0.9,
   mapOriginX:0,mapOriginY:0,mapFullWidth:side,mapFullHeight:side,sourceWidth:side,sourceHeight:side,
   components:[part],ownershipVersion:2,completeCCScan:true,ambiguousComponents:[],candidateComponents:[])
 }
 let own=NativeCoreMLDetectionBox(polygon:crop,score:0.99,detectorSeedEvidence:evidence(0,.init(x:140,y:110,width:20,height:100)))
 func picture(_ kind:Int)->NativeOCRRGBAFrame {
  var bytes=[UInt8](repeating:255,count:side*side*4)
  for y in 0..<side {for x in 0..<side {
   let p=local(x,y)
   let ink:Bool
   if kind==0 {ink=CGRect(x:140,y:110,width:20,height:118).contains(p)}
   else if kind==1 {ink=CGRect(x:140,y:110,width:20,height:108).contains(p) || CGRect(x:140,y:224,width:20,height:4).contains(p)}
   else if kind==2 {ink=true}
   else if kind==3 {ink=CGRect(x:140,y:94,width:20,height:116).contains(p)}
   else {ink=CGRect(x:140,y:110,width:20,height:100).contains(p) || CGRect(x:132,y:205,width:5,height:23).contains(p)}
   if ink {for k in 0..<3 {bytes[(y*side+x)*4+k]=0}}
  }}
  return .init(width:side,height:side,bytes:bytes)!
 }
 func complete(_ kind:Int,_ boxes:[NativeCoreMLDetectionBox])->[CGPoint]? {
  NativeOCRRFPrimaryEnsemble.completingClippedEndpointInk(index:0,boxes:boxes,polygon:crop,frame:picture(kind),inkStyle:.init([0,0,0]))
 }
 let tail=complete(0,[own]);check(tail != nil,"continuous tail omitted at \(degree)")
 if let tail {check(NativeOCRDirectionGeometry.contains(tail,world(.init(x:150,y:227.5))),"visible terminal pixels clipped at \(degree)")}
 check(complete(1,[own])==nil,"detached next glyph acquired at \(degree)")
 check(complete(2,[own])==nil,"paper/artwork colour admitted at \(degree)")
 check(complete(4,[own])==nil,"unowned same-colour edge component admitted at \(degree)")
 let head=complete(3,[own]);check(head != nil,"continuous head omitted at \(degree)")
 if let head {check(NativeOCRDirectionGeometry.contains(head,world(.init(x:150,y:94.5))),"head pixels clipped at \(degree)")}
 let peer=NativeCoreMLDetectionBox(polygon:quad(.init(x:138,y:221,width:24,height:9)),score:0.99,detectorSeedEvidence:evidence(1,.init(x:140,y:223,width:20,height:5)))
 check(complete(0,[own,peer])==nil,"peer private ink borrowed at \(degree)")
}
print("PASS \(checks) clipped-edge source-ink checks /24angles")
'''
cache=root/'build/clipped-edge-ink-smoke';binary=cache/'checks';started=time.monotonic();compile_replay(cache,[],ns['stubs']+ns['production']+checks,binary);print('Compile seconds',round(time.monotonic()-started,2),flush=True);subprocess.run([str(binary)],check=True)
