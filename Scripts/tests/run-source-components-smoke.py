"""Shared native RGB components: all-angle ownership, paper and corner semantics."""
from pathlib import Path
import subprocess,sys,time
root=Path(__file__).resolve().parents[2];sys.path.insert(0,str(root/'Scripts'));from swift_replay_cache import compile_replay
ocr=root/'Aidoku/Core/Translation/NativeEngine/OCR'
stubs=r'''
import CoreGraphics
import Foundation
struct NativeCoreMLDetectionBox {let polygon:[CGPoint];let score:Double;var detectorSeedEvidence:NativeOCRDetectorSeedEvidence?=nil}
struct NativeOCRRGBAFrame {
 let width:Int;let height:Int;let bytesPerRow:Int;let bytes:[UInt8]
 init?(width:Int,height:Int,bytes:[UInt8]) {self.width=width;self.height=height;self.bytesPerRow=width*4;self.bytes=bytes}
}
'''
source=''.join((ocr/name).read_text() for name in ['NativeOCRSourceROIProbabilityEvidence.swift','NativeOCRDetectorSeedEvidence.swift','NativeOCRSourceComponentMeasurements.swift','NativeOCRSourceComponentBounds.swift'])
bank=(ocr/'NativeOCRResidualCandidateBank.swift').read_text();start=bank.index('    static func enclosing(');opening=bank.index('{',start);depth=1;end=opening+1
while depth:
 if bank[end]=='{':depth+=1
 elif bank[end]=='}':depth-=1
 end+=1
source+=(ocr/'NativeOCRResidualCandidate.swift').read_text()+'\n@available(iOS 18.0, *) enum CandidateEnclosingChecks { typealias Measurement=NativeOCRSourceComponentMeasurements.Measurement\n'+bank[start:end]+'\n}\n'
checks=r'''
var checks=0
func check(_ x:Bool,_ message:String) {if !x {fputs("FAILED: \(message)\n",stderr);exit(1)};checks+=1}
func corners(_ r:CGRect)->[CGPoint] {[.init(x:r.minX,y:r.minY),.init(x:r.maxX,y:r.minY),.init(x:r.maxX,y:r.maxY),.init(x:r.minX,y:r.maxY)]}
func evidence(_ components:[NativeOCRDetectorSeedEvidence.Component],_ owner:String,_ index:Int,_ width:Int,_ height:Int)->NativeOCRDetectorSeedEvidence {
 .init(ownerID:owner,parentBoxIndex:index,provenance:"db-4connected-original-cells-v1",threshold:0.9,mapOriginX:0,mapOriginY:0,mapFullWidth:width,mapFullHeight:height,sourceWidth:width,sourceHeight:height,components:components)
}
for degree in stride(from:0.0,to:360,by:15) {
 let angle=CGFloat(degree)*CGFloat.pi/180,c=cos(angle),s=sin(angle),side=512
 func world(_ p:CGPoint)->CGPoint {let x=p.x-256,y=p.y-256;return .init(x:256+x*c-y*s,y:256+x*s+y*c)}
 func local(_ p:CGPoint)->CGPoint {let x=p.x-256,y=p.y-256;return .init(x:256+x*c+y*s,y:256-x*s+y*c)}
 func sourceInk(_ p:CGPoint)->Bool {
  [80,140,200].contains { y in
   let r=CGRect(x:198.5,y:CGFloat(y)-1.5,width:27,height:27)
   return r.contains(p) && !r.insetBy(dx:3,dy:3).contains(p)
  }
 }
 func foreignInk(_ p:CGPoint)->Bool {CGRect(x:238,y:100,width:7,height:21).contains(p)}
 func component(_ test:(CGPoint)->Bool)->NativeOCRDetectorSeedEvidence.Component {
  var runs:[NativeOCRDetectorSeedEvidence.Run]=[]
  for y in 0..<side {var begin:Int?
   for x in 0...side {
    let ink=x<side && test(local(.init(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5)))
    if ink {if begin==nil {begin=x}} else if let start=begin {runs.append(.init(y:y,x:start,count:x-start));begin=nil}
   }
  }
  return .init(seed:runs[0].y*side+runs[0].x,pixelCount:runs.reduce(0){$0+$1.count},meanProbability:0.99,runs:runs)
 }
 let own=component(sourceInk),other=component(foreignInk)
 let e=evidence([own],"source",0,side,side),f=evidence([other],"foreign",1,side,side)
 check(e.isValid && f.isValid,"source fixture invalid")
 let q=corners(.init(x:190,y:75,width:60,height:155)).map(world)
 let boxes=[NativeCoreMLDetectionBox(polygon:q,score:0.9,detectorSeedEvidence:e),NativeCoreMLDetectionBox(polygon:corners(.init(x:235,y:97,width:14,height:28)).map(world),score:0.9,detectorSeedEvidence:f)]
 var pixels=[UInt8](repeating:255,count:side*side*4)
 for y in 0..<side {for x in 0..<side {
  let p=local(.init(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5))
  if sourceInk(p) || foreignInk(p) {let o=(y*side+x)*4;pixels[o]=0;pixels[o+1]=0;pixels[o+2]=0}
 }}
 let frame=NativeOCRRGBAFrame(width:side,height:side,bytes:pixels)!
 let context=NativeOCRSourceComponentMeasurements.Context(originals:boxes,prepared:boxes,groups:[:],scopes:[],frameProvider:{frame})
 let measured=context.measure(index:0,polygon:q)!
 check(measured.status=="measured","source contrast missing at \(degree)")
 check(measured.rejections["foreign-owner",default:0]>0,"foreign word acquired source permission at \(degree)")
 check(measured.components.allSatisfy{$0.foreignPixels==0},"foreign ownership leaked")
 guard let proposal=NativeOCRSourceComponentBounds.proposal(measured,gap:0,axis:0,padding:2) else {fatalError("No source proposal")}
 for r in own.runs {for x in r.x..<(r.x+r.count) {
  check(NativeOCRSourceComponentMeasurements.contains(proposal.0,.init(x:CGFloat(x)+0.5,y:CGFloat(r.y)+0.5),tolerance:0.01),"private stroke clipped at \(degree)")
 }}
 check(!NativeOCRSourceComponentMeasurements.contains(proposal.0,world(.init(x:241,y:110))),"neighbor column swallowed at \(degree)")
 let visible=NativeOCRSourceComponentBounds.visibleForeground(measured)
 check(!visible.isEmpty,"visible foreground protection missing")
 check(visible.allSatisfy{NativeOCRSourceComponentMeasurements.contains(q,$0,tolerance:0.01)},"foreground protection escaped incoming bbox")
 let clipped=NativeOCRSourceComponentBounds.clip(q,to:q)
 check(clipped.count==4,"convex clipping changed intact source")
 let caps=NativeOCRSourceComponentBounds.protectedCaps(measured,baseline:corners(.init(x:190,y:90,width:60,height:120)).map(world),terminal:q,point:nil)
 check(caps.count==2,"measured terminal caps missing")
 check(caps.allSatisfy{NativeOCRSourceComponentMeasurements.contains(q,$0,tolerance:0.01)},"terminal protection escaped incoming bbox")
 let independent=context.measure(index:boxes.count,polygon:q)!
 check(independent.kind=="independent" && independent.status=="measured","independent source association missing")
 check(independent.associatedOwners==["source"],"neighbor owner associated with independent column")
 check(independent.components.allSatisfy{$0.foreignPixels==0},"independent association swallowed foreign cells")
 let sourceMetadata=context.metadata(index:boxes.count,polygon:q)!
 let associated=context.associatedEvidence(sourceMetadata)
 check(associated.allSatisfy{$0.isValid},"association changed original evidence validity")
 check(associated.first?.ownerID==e.ownerID && associated.first?.components==e.components,"association rewrote detector ownership")
 let foreignView=NativeOCRSourceComponentMeasurements.Context(originals:boxes,prepared:boxes,groups:[:],scopes:[],frameProvider:{frame},supportViews:[0:[f]]).measure(index:0,polygon:q)!
 check(foreignView.status != "measured","provisional sampling acquired external private owner")
 let referenceView=NativeOCRSourceComponentMeasurements.Context(originals:boxes,prepared:boxes,groups:[:],scopes:[],frameProvider:{frame},supportViews:[boxes.count:[e]]).measure(index:boxes.count,polygon:q)!
 check(referenceView.status=="measured" && referenceView.provisionalOwners==[e.ownerID],"independent original-owner sampling reference lost")
 check(referenceView.components.allSatisfy{$0.foreignPixels==0},"provisional reference swallowed foreign source")
 let fixedContext=NativeOCRSourceComponentMeasurements.Context(originals:boxes,prepared:boxes,groups:[:],scopes:[],frameProvider:{frame},associationViews:[boxes.count:associated])
 let wider=fixedContext.measure(index:boxes.count,polygon:corners(.init(x:160,y:75,width:120,height:155)).map(world))!
 check(wider.associatedOwners==[e.ownerID],"wider source probe acquired a neighboring owner")
 check(wider.components.allSatisfy{$0.foreignPixels==0},"wider source probe reclassified neighboring ink")
 let enclosing=CandidateEnclosingChecks.enclosing([.init(key:"normal-fit",polygon:proposal.0)],measurement:measured)
 check(enclosing.count==3,"enclosing correction strengths missing")
 for option in enclosing {for run in own.runs {for x in run.x..<(run.x+run.count) {
  check(NativeOCRSourceComponentMeasurements.contains(option.polygon,.init(x:CGFloat(x)+0.5,y:CGFloat(run.y)+0.5),tolerance:0.01),"strength interpolation clipped an original glyph")
 }}}
 let outward=corners(.init(x:185,y:75,width:70,height:155)).map(world)
 check(CandidateEnclosingChecks.enclosing([.init(key:"normal-grow",polygon:outward)],measurement:measured).isEmpty,"partial outer-stroke recovery admitted")
 check(CandidateEnclosingChecks.enclosing([.init(key:"terminal-tail-proof",polygon:proposal.0)],measurement:measured).isEmpty,"partial terminal admitted")
 check(CandidateEnclosingChecks.enclosing([.init(key:"member-proof",polygon:proposal.0,consumedIndices:[1])],measurement:measured).isEmpty,"partial consumed peer admitted")
 let shifted=Array(proposal.0.dropFirst())+[proposal.0[0]]
 check(NativeOCRSourceComponentBounds.interpolate(q,proposal:shifted,fraction:0)==q,"incoming corner semantics changed")
 let normal=NativeOCRSourceComponentBounds.operate(q,proposal:shifted,action:1,frame:measured).map(measured.project)
 check(zip(normal,q.map(measured.project)).allSatisfy{abs($0.y-$1.y)<1e-8},"normal resize changed along positions")
 let empty=NativeOCRRGBAFrame(width:side,height:side,bytes:[UInt8](repeating:255,count:side*side*4))!
 let blank=NativeOCRSourceComponentMeasurements.Context(originals:boxes,prepared:boxes,groups:[:],scopes:[],frameProvider:{empty}).measure(index:0,polygon:q)!
 check(blank.status=="no-source-contrast","flat paper supplied glyph evidence")
}
// A one-column source ROI still uses a valid reflected derivative border.
do {
 let w=128,h=12000,q=corners(.init(x:60,y:100,width:5,height:10000))
 var runs:[NativeOCRDetectorSeedEvidence.Run]=[]
 for start in [1000,4000,8000] {for y in start..<(start+200) {runs.append(.init(y:y,x:61,count:3))}}
 let component=NativeOCRDetectorSeedEvidence.Component(seed:runs[0].y*w+61,pixelCount:runs.count*3,meanProbability:0.99,runs:runs)
 let e=evidence([component],"narrow",0,w,h);check(e.isValid,"narrow fixture invalid")
 let box=NativeCoreMLDetectionBox(polygon:q,score:0.9,detectorSeedEvidence:e)
 let frame=NativeOCRRGBAFrame(width:w,height:h,bytes:[UInt8](repeating:255,count:w*h*4))!
 let result=NativeOCRSourceComponentMeasurements.Context(originals:[box],prepared:[box],groups:[:],scopes:[],frameProvider:{frame}).measure(index:0,polygon:q)!
 check(result.columns==1,"narrow derivative path not exercised");check(result.status=="no-source-contrast","narrow flat source invented a glyph")
}
print("PASS \(checks) source component checks /24angles")
'''
cache=root/'build/source-components-smoke';binary=cache/'checks';started=time.monotonic();compile_replay(cache,[],stubs+source+checks,binary)
print('Compile seconds',round(time.monotonic()-started,2),flush=True);subprocess.run([str(binary)],check=True)
