"""All-angle source-cell preservation and intrinsic-frame calibration checks."""
from pathlib import Path
import subprocess,sys,time
root=Path(__file__).resolve().parents[2]
base=root/'Scripts/tests/run-endpoint-continuation-smoke.py'
ns={'__file__':str(base)};exec(base.read_text().split("checks=r'''",1)[0],ns)
sys.path.insert(0,str(root/'Scripts'));from swift_replay_cache import compile_replay
source=(root/'Aidoku/Core/Translation/NativeEngine/OCR/NativeOCRRFGapRecovery.swift').read_text()
calibration=source[source.index('/// Shared offline calibration;'):]
checks=r'''
var checks=0
func check(_ value:Bool,_ message:String) {if !value {fputs("FAILED: \(message)\n",stderr);exit(1)};checks+=1}
let center=CGPoint(x:350,y:350)
var references:[[CGPoint]]=[]
for degree in stride(from:0.0,to:360,by:15) {
 let angle=CGFloat(degree)*CGFloat.pi/180,c=cos(angle),s=sin(angle)
 func world(_ p:CGPoint)->CGPoint {let x=p.x-center.x,y=p.y-center.y;return CGPoint(x:center.x+x*c-y*s,y:center.y+x*s+y*c)}
 func local(_ p:CGPoint)->CGPoint {let x=p.x-center.x,y=p.y-center.y;return CGPoint(x:center.x+x*c+y*s,y:center.y-x*s+y*c)}
 func quad(_ r:CGRect)->[CGPoint] {NativeOCRDirectionGeometry.corners(r).map(world)}
 let base=quad(CGRect(x:325,y:200,width:50,height:300))
 var runs:[NativeOCRDetectorSeedEvidence.Run]=[]
 for y in 100..<600 {
  var begin:Int?
  for x in 100...600 {
   let inside=x<600 && CGRect(x:340,y:220,width:20,height:260).contains(local(CGPoint(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5)))
   if inside {if begin==nil {begin=x}} else if let start=begin {runs.append(.init(y:y,x:start,count:x-start));begin=nil}
  }
 }
 let component=NativeOCRDetectorSeedEvidence.Component(seed:runs[0].y*700+runs[0].x,pixelCount:runs.reduce(0){$0+$1.count},meanProbability:0.99,runs:runs)
 let evidence=NativeOCRDetectorSeedEvidence(ownerID:"fixture-source",parentBoxIndex:0,provenance:"db-4connected-original-cells-v1",threshold:0.9,mapOriginX:0,mapOriginY:0,mapFullWidth:700,mapFullHeight:700,sourceWidth:700,sourceHeight:700,components:[component])
 check(evidence.isValid,"fixture ownership invalid at \(degree)")
 for (ordinal,score) in [0.65,0.85,0.95].enumerated() {
  let box=NativeCoreMLDetectionBox(polygon:base,score:score,detectorSeedEvidence:evidence)
  let crop=quad(CGRect(x:325,y:190,width:50,height:330))
  let input=NativeOCRCommonBoundaryCalibration.Input(index:0,polygon:crop,baseline:base,hasInk:true)
  let result=NativeOCRCommonBoundaryCalibration.calibrate([input],originals:[box],prepared:[box],groups:[:])[0]
  check(result.count==4 && result.allSatisfy{$0.x.isFinite && $0.y.isFinite},"invalid calibrated quad")
  let restored=result.map(local)
  if degree==0 {references.append(restored)} else {
   check(zip(restored,references[ordinal]).allSatisfy{hypot($0.x-$1.x,$0.y-$1.y)<0.01},"source-angle-specific calibration at \(degree), score \(score)")
  }
  for run in runs {for x in run.x..<(run.x+run.count) {
   let point=local(CGPoint(x:CGFloat(x)+0.5,y:CGFloat(run.y)+0.5))
   let bounds=NativeOCRDirectionGeometry.bounds(restored).insetBy(dx:-0.75,dy:-0.75)
   check(bounds.contains(point),"private glyph cell clipped at \(degree)")
  }}
  check(box.polygon==base && box.detectorSeedEvidence==evidence,"source evidence mutated")
 }
}

// A detached private terminal lies outside the incoming basis, but inside
// the fixed source-only witness. Empty margin may shrink; this owned mark may not.
for degree in stride(from:0.0,to:360,by:15) {
 let angle=CGFloat(degree)*CGFloat.pi/180,c=cos(angle),s=sin(angle)
 func world(_ p:CGPoint)->CGPoint {let x=p.x-350,y=p.y-350;return CGPoint(x:350+x*c-y*s,y:350+x*s+y*c)}
 func local(_ p:CGPoint)->CGPoint {let x=p.x-350,y=p.y-350;return CGPoint(x:350+x*c+y*s,y:350-x*s+y*c)}
 let q=NativeOCRDirectionGeometry.corners(CGRect(x:325,y:300,width:50,height:100)).map(world)
 func component(_ rect:CGRect)->NativeOCRDetectorSeedEvidence.Component {
  var runs:[NativeOCRDetectorSeedEvidence.Run]=[]
  for y in 250..<450 {var begin:Int?
   for x in 250...450 {
    let inside=x<450 && rect.contains(local(CGPoint(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5)))
    if inside {if begin==nil {begin=x}} else if let start=begin {runs.append(.init(y:y,x:start,count:x-start));begin=nil}
   }
  }
  return .init(seed:runs[0].y*700+runs[0].x,pixelCount:runs.reduce(0){$0+$1.count},meanProbability:0.99,runs:runs)
 }
 let core=component(CGRect(x:340,y:315,width:20,height:50)),terminal=component(CGRect(x:346,y:402,width:8,height:3))
 for withTerminal in [false,true] {
  let evidence=NativeOCRDetectorSeedEvidence(ownerID:"terminal-owner",parentBoxIndex:0,provenance:"db-4connected-original-cells-v1",threshold:0.9,mapOriginX:0,mapOriginY:0,mapFullWidth:700,mapFullHeight:700,sourceWidth:700,sourceHeight:700,components:withTerminal ? [core,terminal]:[core])
  check(evidence.isValid,"terminal ownership fixture invalid")
  let box=NativeCoreMLDetectionBox(polygon:q,score:0.65,detectorSeedEvidence:evidence)
  let result=NativeOCRCommonBoundaryCalibration.calibrate([.init(index:0,polygon:q,baseline:q)],originals:[box],prepared:[box],groups:[:])[0].map(local)
  let bounds=NativeOCRDirectionGeometry.bounds(result)
  if withTerminal {
   check(bounds.maxY>=405,"accepted owned terminal discarded at \(degree)")
  } else {
   check(abs(bounds.maxY-400)<0.01,"empty terminal padding retained without a source witness at \(degree)")
  }
 }
}
print("PASS \(checks) common-boundary calibration checks /24angles")
'''
cache=root/'build/common-boundary-calibration-smoke';binary=cache/'checks'
started=time.monotonic();compile_replay(cache,[],ns['stubs']+ns['production']+calibration+checks,binary)
print('Compile seconds',round(time.monotonic()-started,2),flush=True);subprocess.run([str(binary)],check=True)
