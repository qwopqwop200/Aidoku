"""A short retained word may recover only its rooted point train and closed cap."""
from pathlib import Path
import subprocess
import sys
import time

root = Path(__file__).resolve().parents[2]
base = root / 'Scripts/tests/run-endpoint-continuation-smoke.py'
ns = {'__file__': str(base)}
exec(base.read_text().split("checks=r'''", 1)[0], ns)
sys.path.insert(0, str(root / 'Scripts'))
from swift_replay_cache import compile_replay

checks = r'''
setenv("AIDOKU_OCR_ENDPOINT_INK_REFINEMENT","1",1)
var checks=0
func check(_ value:Bool,_ message:String){if !value {fputs("FAILED: \(message)\n",stderr);exit(1)};checks+=1}
check(!NativeOCRRFPrimaryEnsemble.preservesTerminalWord(candidate:"あ…♡",baseline:"あ"),"ordinary admission keeps its two-letter floor")
check(NativeOCRRFPrimaryEnsemble.preservesTerminalWord(candidate:"あ…♡",baseline:"あ",allowSingleGlyph:true),"a measured point-tail pair can retain a single glyph")
check(!NativeOCRRFPrimaryEnsemble.preservesTerminalWord(candidate:"いう…♡",baseline:"あ",allowSingleGlyph:true),"point evidence cannot substitute a different word")
check(!NativeOCRRFPrimaryEnsemble.preservesTerminalWord(candidate:"あいう…♡",baseline:"あ",allowSingleGlyph:true),"point evidence cannot append another word")
let side=400
for degree in stride(from:0.0,to:360,by:15) {
 let theta=CGFloat(degree)*CGFloat.pi/180,c=cos(theta),s=sin(theta)
 func world(_ p:CGPoint)->CGPoint {let x=p.x-160,y=p.y-200;return .init(x:200+x*c-y*s,y:200+x*s+y*c)}
 func local(_ x:Int,_ y:Int)->CGPoint {let xx=CGFloat(x)+0.5-200,yy=CGFloat(y)+0.5-200;return .init(x:160+xx*c+yy*s,y:200-xx*s+yy*c)}
 func quad(_ r:CGRect)->[CGPoint] {NativeOCRDirectionGeometry.corners(r).map(world)}
 let root=CGRect(x:150,y:100,width:20,height:20),bridge=CGRect(x:154,y:130,width:12,height:40)
 let points=[180,196,212,228,244].map {CGRect(x:157,y:$0,width:6,height:6)}
 let cap=CGRect(x:144,y:260,width:32,height:32)
 func picture(_ irregular:Bool)->NativeOCRRGBAFrame {
  var bytes=[UInt8](repeating:255,count:side*side*4)
  for y in 0..<side {for x in 0..<side {
   let p=local(x,y)
   let ink=root.contains(p) || bridge.contains(p) ||
    points.enumerated().contains {i,r in (irregular && i==2 ? r.offsetBy(dx:0,dy:7):r).contains(p)} ||
    (cap.contains(p) && !cap.insetBy(dx:4,dy:4).contains(p))
   if ink {for k in 0..<3 {bytes[(y*side+x)*4+k]=0}}
  }}
  return .init(width:side,height:side,bytes:bytes)!
 }
 func part(_ rect:CGRect)->NativeOCRDetectorSeedEvidence.Component {
  var runs:[NativeOCRDetectorSeedEvidence.Run]=[]
  for y in 0..<side {var begin:Int?,end=0
   for x in 0..<side {
    if rect.contains(local(x,y)){if begin==nil {begin=x};end=x+1}
    else if let start=begin {runs.append(.init(y:y,x:start,count:end-start));begin=nil}
   }
   if let start=begin {runs.append(.init(y:y,x:start,count:end-start))}
  }
  return .init(seed:runs[0].y*side+runs[0].x,pixelCount:runs.reduce(0){$0+$1.count},meanProbability:1,runs:runs)
 }
 func evidence(_ id:Int,_ components:[NativeOCRDetectorSeedEvidence.Component])->NativeOCRDetectorSeedEvidence {
  .init(ownerID:"point-cap-\(id)",parentBoxIndex:id,provenance:"db-complete-cc-candidates-v2",threshold:0.9,
   mapOriginX:0,mapOriginY:0,mapFullWidth:side,mapFullHeight:side,sourceWidth:side,sourceHeight:side,
   components:components,ownershipVersion:2,completeCCScan:true,ambiguousComponents:[],candidateComponents:[])
 }
 let observed=quad(.init(x:143,y:98,width:34,height:74))
 let boxes=[NativeCoreMLDetectionBox(polygon:quad(.init(x:143,y:98,width:34,height:28)),score:0.99,detectorSeedEvidence:evidence(0,[part(root)])),
  NativeCoreMLDetectionBox(polygon:quad(.init(x:143,y:178,width:34,height:116)),score:0.99,detectorSeedEvidence:evidence(1,points.map(part)+[part(cap)]))]
 let styles:[NativeOCRRFPrimaryEnsemble.EndpointInkStyle?]=[.init([0,0,0]),.init([0,0,0])]
 func proposals(_ frame:NativeOCRRGBAFrame,_ active:Bool)->[NativeOCRContextualColumnRecovery.Proposal] {
  NativeOCRContextualColumnRecovery.retainedPointTails(boxes:boxes,frame:frame,inkStyles:styles,retained:active ? [0,1]:[0],
   peerPolygons:active ? [0:observed,1:boxes[1].polygon]:[0:observed],excluding:[],terminalCapParents:[0])
 }
 let candidate=proposals(picture(false),false)
 check(candidate.count==1 && candidate[0].pointSources==[1],"rooted closed-cap alias missing at \(degree)")
 if let q=candidate.first?.polygon {check(NativeOCRDirectionGeometry.contains(q,world(.init(x:160,y:291))),"cap endpoint clipped at \(degree)")}
 check(proposals(picture(false),true).isEmpty,"active private peer absorbed at \(degree)")
 check(proposals(picture(true),false).isEmpty,"irregular points manufactured a tail at \(degree)")
}
print("PASS \(checks) short-point-cap checks /24angles")
'''
cache = root / 'build/short-point-cap-smoke'
started = time.monotonic()
binary = cache / 'checks'
compile_replay(cache, [], ns['stubs'] + ns['production'] + checks, binary)
print('Compile seconds', round(time.monotonic() - started, 2), flush=True)
subprocess.run([str(binary)], check=True)
