"""RF scopes and observed source pieces bind one lane, preserving direction and ownership."""
from pathlib import Path
import subprocess,sys,time
root=Path(__file__).resolve().parents[2];base=root/'Scripts/tests/run-endpoint-continuation-smoke.py';ns={'__file__':str(base)};exec(base.read_text().split("checks=r'''",1)[0],ns);sys.path.insert(0,str(root/'Scripts'));from swift_replay_cache import compile_replay
source=(root/'Aidoku/Core/Translation/NativeEngine/OCR/NativeOCRRFGapRecovery.swift').read_text()
def block(token):
 start=source.index(token);brace=source.index('{',start);depth=1;i=brace+1
 while depth:
  if source[i]=='{':depth+=1
  if source[i]=='}':depth-=1
  i+=1
 return source[start:i]
extra='\nextension NativeOCRRFPrimaryEnsemble {\n'+block('    struct RefinedCrop:')+'\n'+block('    struct Plan:')+'\n'+block('    static func includingSourceAlignedColumns(')+'\n'+block('    static func sourceConsistentGroupAxis(')+'\n'+block('    static func sourceColumnDominatesGroup(')+'\n}\n'
checks=r'''
setenv("AIDOKU_OCR_ENDPOINT_INK_REFINEMENT","1",1)
setenv("AIDOKU_OCR_RF_LANE_GAP","1",1)
var checks=0
func check(_ x:Bool,_ message:String){if !x {fputs("FAILED: \(message)\n",stderr);exit(1)};checks+=1}
unsetenv("AIDOKU_OCR_RF_LANE_GAP")
check(!NativeOCRRFPrimaryEnsemble.sourceAlignedColumnsEnabled,"non-manga/scoped policy changed")
check(NativeOCRRFPrimaryEnsemble.$mainMangaEndpointPolicy.withValue(true) { NativeOCRRFPrimaryEnsemble.sourceAlignedColumnsEnabled },"full manga policy missing by default")
setenv("AIDOKU_OCR_RF_LANE_GAP","0",1)
check(!NativeOCRRFPrimaryEnsemble.$mainMangaEndpointPolicy.withValue(true) { NativeOCRRFPrimaryEnsemble.sourceAlignedColumnsEnabled },"explicit ablation ignored")
setenv("AIDOKU_OCR_RF_LANE_GAP","1",1)
let side=500
for degree in stride(from:0.0,to:360,by:15) {
 let theta=CGFloat(degree)*CGFloat.pi/180,c=cos(theta),s=sin(theta)
 func world(_ p:CGPoint)->CGPoint{let x=p.x-250,y=p.y-210;return .init(x:250+x*c-y*s,y:250+x*s+y*c)}
 func local(_ x:Int,_ y:Int)->CGPoint{let xx=CGFloat(x)+0.5-250,yy=CGFloat(y)+0.5-250;return .init(x:250+xx*c+yy*s,y:210-xx*s+yy*c)}
 func quad(_ r:CGRect)->[CGPoint]{NativeOCRDirectionGeometry.corners(r).map(world)}
 func rect(_ i:Int,_ shifted:Bool,_ compact:Bool=false)->CGRect{.init(x:235+(shifted && i==1 ? 20:0),y:80+i*(compact ? 90:100),width:30,height:60)}
 func ink(_ p:CGPoint,_ i:Int,_ shifted:Bool,_ compact:Bool=false)->Bool{let r=rect(i,shifted,compact);return CGRect(x:r.minX+5,y:r.minY+5,width:20,height:20).contains(p) || CGRect(x:r.minX+5,y:r.minY+35,width:20,height:20).contains(p)}
 func box(_ i:Int,_ shifted:Bool,_ compact:Bool=false,_ shared:Bool=false)->NativeCoreMLDetectionBox{
  var runs:[NativeOCRDetectorSeedEvidence.Run]=[]
  for y in 0..<side {var begin:Int?,end=0
   for x in 0..<side {let p=local(x,y);let painted=shared ? (0..<3).contains{ink(p,$0,shifted,compact)}:ink(p,i,shifted,compact)
    if painted{if begin==nil{begin=x};end=x+1}else if let start=begin{runs.append(.init(y:y,x:start,count:end-start));begin=nil}}
   if let start=begin{runs.append(.init(y:y,x:start,count:end-start))}
  }
  let component=NativeOCRDetectorSeedEvidence.Component(seed:runs[0].y*side+runs[0].x,pixelCount:runs.reduce(0){$0+$1.count},meanProbability:0.99,runs:runs)
  let owners=(0..<3).filter{$0 != i}.map{"aligned-\($0)"}
  let outside=(0..<3).filter{$0 != i}.map{peer in runs.reduce(0){count,run in
   count+(run.x..<(run.x+run.count)).filter{!rect(peer,shifted,compact).contains(local($0,run.y))}.count}}
  let candidate=NativeOCRDetectorSeedEvidence.Candidate(component:component,competingOwnerIDs:owners,
   outsideCompetingCells:outside)
  let evidence=NativeOCRDetectorSeedEvidence(ownerID:"aligned-\(i)",parentBoxIndex:i,provenance:"db-complete-cc-candidates-v2",threshold:0.9,mapOriginX:0,mapOriginY:0,mapFullWidth:side,mapFullHeight:side,sourceWidth:side,sourceHeight:side,components:shared ? []:[component],ownershipVersion:2,completeCCScan:true,ambiguousComponents:[],candidateComponents:shared ? [candidate]:[])
  return .init(polygon:quad(rect(i,shifted,compact)),score:0.95,detectorSeedEvidence:evidence)
 }
 func picture(_ foreign:Bool,_ shifted:Bool,_ compact:Bool=false)->NativeOCRRGBAFrame{
  var bytes=[UInt8](repeating:255,count:side*side*4)
  for y in 0..<side {for x in 0..<side {let p=local(x,y);for i in 0..<3 where ink(p,i,shifted,compact){let offset=(y*side+x)*4;bytes[offset]=foreign && i==2 ? 220:0;bytes[offset+1]=0;bytes[offset+2]=0}}}
  return .init(width:side,height:side,bytes:bytes)!
 }
 func scopes(_ broad:Bool,_ effect:Bool,_ compact:Bool=false,_ confidence:Float=0.32)->NativeRFDETRLayoutResult{
  let r=CGRect(x:broad ? 160:233,y:78,width:broad ? 180:34,height:compact ? 244:264)
  var text=NativeRFDETRLayoutPrimitive(queryID:7,semanticClass:.text,confidence:confidence,sourceBounds:NativeOCRDirectionGeometry.bounds(quad(r)));text.supportPolygon=quad(r)
  var values=[text]
  if effect{var fx=NativeRFDETRLayoutPrimitive(queryID:8,semanticClass:.soundEffect,confidence:0.8,sourceBounds:text.sourceBounds);fx.supportPolygon=text.supportPolygon;values.append(fx)}
  return .init(sourceWidth:side,sourceHeight:side,primitives:values)
 }
 func group(_ foreign:Bool=false,_ shifted:Bool=false,_ broad:Bool=false,_ effect:Bool=false,
  _ compact:Bool=false,_ confidence:Float=0.32,_ shared:Bool=false)->NativeOCRRFPrimaryEnsemble.Plan{
  let boxes=(0..<3).map{box($0,shifted,compact,shared)};let plan=NativeOCRRFPrimaryEnsemble.Plan(boxes:boxes,supported:[],stronglySupported:[],groups:[],refinedCrops:[])
  let result=NativeOCRRFPrimaryEnsemble.includingSourceAlignedColumns(plan,layout:scopes(broad,effect,compact,confidence),frame:picture(foreign,shifted,compact))
  for i in 0..<3{check(result.boxes[i].polygon==boxes[i].polygon,"original source mutated at \(degree)")}
  return result
 }
 let positive=group();check(positive.groups.count==1,"aligned lane not grouped at \(degree)")
 if let g=positive.groups.first{check(g.members==[0,1,2] && g.evidence.count==3,"source ownership lost at \(degree)")}
 check(group(false,false,true).groups.isEmpty,"paragraph width became a lane at \(degree)")
 check(group(false,true).groups.isEmpty,"shifted neighboring column borrowed at \(degree)")
 check(group(true).groups.isEmpty,"different measured ink borrowed at \(degree)")
 check(group(false,false,false,true).groups.isEmpty,"SFX scope borrowed at \(degree)")
 let paragraph=group(false,false,true,false,true,0.9)
 check(paragraph.groups.count==1,"source-resolved lane inside strong paragraph not grouped at \(degree)")
 check(group(false,false,true,false,true).groups.isEmpty,"weak paragraph resolved no independent lane at \(degree)")
 check(group(false,false,true,false,false,0.9).groups.isEmpty,"paragraph borrowed distant pieces at \(degree)")
 check(group(false,true,true,false,true,0.9).groups.isEmpty,"paragraph borrowed shifted lane at \(degree)")
 check(group(true,false,true,false,true,0.9).groups.isEmpty,"paragraph borrowed different ink at \(degree)")
 check(group(false,false,true,true,true,0.9).groups.isEmpty,"paragraph bypassed SFX veto at \(degree)")
 let shared=group(false,false,true,false,true,0.9,true)
 check(shared.groups.count==1,"observed candidate cells inside each source could not bind a lane at \(degree)")
 if let g=shared.groups.first {check(g.evidence.allSatisfy{$0.components.isEmpty},"group reassigned shared detector ownership at \(degree)")}
 // A short edge's two-pixel skew must not rotate the complete printed lane
 // when independently measured ink and the member centers agree otherwise.
 let skew=[CGPoint(x:235,y:80),CGPoint(x:265,y:78),CGPoint(x:269,y:178),CGPoint(x:239,y:180)].map(world)
 let upright=quad(CGRect(x:235,y:210,width:30,height:130))
 let axis=NativeOCRRFPrimaryEnsemble.EndpointFrame(skew)!
 let extent=axis.bounds(skew).union(axis.bounds(upright))
 let synthetic=NativeOCRDirectionGeometry.corners(extent).map(axis.restore)
 let measured=quad(CGRect(x:233,y:78,width:38,height:264))
 let corrected=NativeOCRRFPrimaryEnsemble.sourceConsistentGroupAxis(synthetic,members:[skew,upright],
  columns:[measured],uncertainty:2)
 check(corrected==measured,"independent source axis did not resolve borrowed short-edge skew at \(degree)")
 let reversed=[measured[2],measured[3],measured[0],measured[1]]
 check(NativeOCRRFPrimaryEnsemble.sourceConsistentGroupAxis(synthetic,members:[skew,upright],
  columns:[reversed],uncertainty:2)==measured,"source axis reversed trusted reading order at \(degree)")
 check(NativeOCRRFPrimaryEnsemble.sourceConsistentGroupAxis(synthetic,members:[skew,upright],
  columns:[quad(CGRect(x:233,y:78,width:38,height:100))],uncertainty:2)==nil,
  "partial source candidate replaced a complete group at \(degree)")
 check(NativeOCRRFPrimaryEnsemble.sourceConsistentGroupAxis(synthetic,members:[skew,upright],
  columns:[measured],uncertainty:100)==nil,"unresolved source-grid jitter rotated the group at \(degree)")
 let reliable=quad(CGRect(x:235,y:80,width:30,height:260))
 check(NativeOCRRFPrimaryEnsemble.sourceConsistentGroupAxis(reliable,
  members:[quad(CGRect(x:235,y:80,width:30,height:60)),upright],columns:[synthetic],uncertainty:2)==nil,
  "independent but worse axis displaced a stable original lane at \(degree)")
 // Two source components remain separated even though DB unclip padding
 // overlaps. The reciprocal complete-component provenance supplies contact
 // permission; unrelated private reads and larger overlaps must abstain.
 func contactRect(_ i:Int,_ large:Bool)->CGRect {
  i==0 ? CGRect(x:230,y:80,width:40,height:120):
   CGRect(x:230,y:large ? 180:190,width:40,height:large ? 150:140)
 }
 func contactInk(_ p:CGPoint,_ i:Int)->Bool {
  let first:CGFloat=i==0 ? 85:196,last:CGFloat=i==0 ? 194:325
  if CGRect(x:248,y:first,width:4,height:last-first).contains(p) {return true}
  let starts:[CGFloat]=i==0 ? [85,130,180]:[196,240,295]
  return starts.contains { y in CGRect(x:235,y:y,width:30,height:min(30,last-y)).contains(p) }
 }
 func contactGroup(_ independent:Bool=false,_ large:Bool=false,_ tall:Bool=false,
  _ columns:[[CGPoint]]?=nil)->NativeOCRRFPrimaryEnsemble.Plan {
  let components=(0..<2).map { i -> NativeOCRDetectorSeedEvidence.Component in
   var runs:[NativeOCRDetectorSeedEvidence.Run]=[]
   for y in 0..<side {var first:Int?
    for x in 0...side {
     let painted=x<side && contactInk(local(x,y),i)
     if painted {if first==nil {first=x}}
     else if let start=first {runs.append(.init(y:y,x:start,count:x-start));first=nil}
    }
   }
   return .init(seed:runs[0].y*side+runs[0].x,pixelCount:runs.reduce(0){$0+$1.count},meanProbability:0.99,runs:runs)
  }
  let boxes=(0..<2).map { i -> NativeCoreMLDetectionBox in
   let component=components[i],peer=1-i
   let outside=component.runs.reduce(0) { count,run in
    count+(run.x..<(run.x+run.count)).filter{!contactRect(peer,large).contains(local($0,run.y))}.count
   }
   let candidate=NativeOCRDetectorSeedEvidence.Candidate(component:component,
    competingOwnerIDs:["contact-\(peer)"],outsideCompetingCells:[outside])
   let e=NativeOCRDetectorSeedEvidence(ownerID:"contact-\(i)",parentBoxIndex:i,provenance:"db-complete-cc-candidates-v2",
    threshold:0.9,mapOriginX:0,mapOriginY:0,mapFullWidth:side,mapFullHeight:side,sourceWidth:side,sourceHeight:side,
    components:independent ? [component]:[],ownershipVersion:2,completeCCScan:true,ambiguousComponents:[],
    candidateComponents:independent ? []:[candidate])
   check(e.isValid,"invalid reciprocal source fixture at \(degree)")
   return .init(polygon:quad(contactRect(i,large)),score:0.95,detectorSeedEvidence:e)
  }
  var bytes=[UInt8](repeating:255,count:side*side*4)
  for y in 0..<side {for x in 0..<side {
   if (0..<2).contains(where:{contactInk(local(x,y),$0)}) {
    let k=(y*side+x)*4;bytes[k]=0;bytes[k+1]=0;bytes[k+2]=0
   }
  }}
  var scope=NativeRFDETRLayoutPrimitive(queryID:70,semanticClass:.text,confidence:0.75,
   sourceBounds:NativeOCRDirectionGeometry.bounds(quad(CGRect(x:180,y:tall ? 70:78,width:140,height:tall ? 360:254))))
  scope.supportPolygon=quad(CGRect(x:180,y:tall ? 70:78,width:140,height:tall ? 360:254))
  let plan=NativeOCRRFPrimaryEnsemble.Plan(boxes:boxes,supported:[],stronglySupported:[],groups:[],refinedCrops:[])
  let provider:(()->[[CGPoint]])?=columns.map { value in {value} }
  return NativeOCRRFPrimaryEnsemble.includingSourceAlignedColumns(plan,
   layout:.init(sourceWidth:side,sourceHeight:side,primitives:[scope]),frame:.init(width:side,height:side,bytes:bytes)!,
   independentColumns:provider)
 }
 let joinedContact=contactGroup()
 check(joinedContact.groups.count==1,"reciprocal source contact remained split by bbox padding at \(degree)")
 check(joinedContact.groups.first?.sourcePixelLane==true,"contact group bypassed pixel-axis validation at \(degree)")
 check(contactGroup(false,false,true).groups.count==1,"neighboring paragraph height vetoed a complete source column at \(degree)")
 check(contactGroup(true).groups.isEmpty,"unrelated private reads acquired contact permission at \(degree)")
 check(contactGroup(false,true).groups.isEmpty,"unresolved large overlap acquired contact permission at \(degree)")
 check(contactGroup(false,false,true,[quad(CGRect(x:229,y:78,width:42,height:330))]).groups.isEmpty,
  "redundant prefix group hid the independent complete column at \(degree)")
 check(contactGroup(false,false,true,[quad(CGRect(x:229,y:78,width:42,height:254))]).groups.count==1,
  "matching complete source column vetoed a valid relation at \(degree)")
 check(contactGroup(false,false,true,[quad(CGRect(x:300,y:78,width:42,height:330))]).groups.count==1,
  "neighboring source column vetoed this lane at \(degree)")
 check(contactGroup(false,false,true,[quad(CGRect(x:200,y:78,width:100,height:330))]).groups.count==1,
  "wide paragraph envelope masqueraded as a source column at \(degree)")
 unsetenv("AIDOKU_OCR_RF_LANE_GAP");check(group().groups.isEmpty,"experimental path enabled by default");setenv("AIDOKU_OCR_RF_LANE_GAP","1",1)
}
print("PASS \(checks) source-aligned column checks /24angles")
'''
cache=root/'build/source-aligned-columns-smoke';binary=cache/'checks';started=time.monotonic();compile_replay(cache,[],ns['stubs']+ns['production']+extra+checks,binary);print('Compile seconds',round(time.monotonic()-started,2),flush=True);subprocess.run([str(binary)],check=True)
