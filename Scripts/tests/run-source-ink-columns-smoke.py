"""Exercise the actual local-axis source ink column proposal kernel."""
from pathlib import Path
import subprocess,sys,time
root=Path(__file__).resolve().parents[2];base=root/'Scripts/tests/run-endpoint-continuation-smoke.py';ns={'__file__':str(base)};exec(base.read_text().split("checks=r'''",1)[0],ns);sys.path.insert(0,str(root/'Scripts'));from swift_replay_cache import compile_replay
source=(root/'Aidoku/Core/Translation/NativeEngine/OCR/NativeOCRRFGapRecovery.swift').read_text()
ns['stubs']=ns['stubs'].replace('enum NativeRFDETRLayoutClass { case text, soundEffect }',
    'enum NativeRFDETRLayoutClass { case text, soundEffect, balloon, frame }')
def block(token):
 start=source.index(token);brace=source.index('{',source.index('throws -> [NativeCoreMLDetectionBox]',start)) if 'func sourceInkColumns' in token else source.index('{',start);depth=1;i=brace+1
 while depth:
  if source[i]=='{':depth+=1
  if source[i]=='}':depth-=1
  i+=1
 return source[start:i]
extra='\nextension NativeOCRRFPrimaryEnsemble {\n'+block('    static var sourceInkAnnotationBandsEnabled:')+'\n'+block('    static var sourceInkPartitionsEnabled:')+'\n'+block('    static var sourceInkColumnsEnabled:')+'\n'+block('    static func sourceInkSideAnnotation(')+'\n'+block('    static func sourceInkColumnCaps(')+'\n'+block('    static func sourceInkColumns(')+'\n}\n'
checks=r'''
unsetenv("AIDOKU_OCR_SOURCE_INK_PARTITIONS")
unsetenv("AIDOKU_OCR_INK_ANNOTATION_BANDS")
var checks=0
func check(_ x:Bool,_ name:String){if !x {fputs("FAILED: \(name)\n",stderr);exit(1)};checks+=1}
unsetenv("AIDOKU_OCR_SOURCE_INK_COLUMNS")
check(!NativeOCRRFPrimaryEnsemble.sourceInkColumnsEnabled,"non-manga default changed")
check(!NativeOCRRFPrimaryEnsemble.sourceInkAnnotationBandsEnabled,"non-manga annotation default changed")
check(NativeOCRRFPrimaryEnsemble.$mainMangaEndpointPolicy.withValue(true){NativeOCRRFPrimaryEnsemble.sourceInkAnnotationBandsEnabled},"full manga annotation policy missing")
setenv("AIDOKU_OCR_INK_ANNOTATION_BANDS","0",1)
check(!NativeOCRRFPrimaryEnsemble.$mainMangaEndpointPolicy.withValue(true){NativeOCRRFPrimaryEnsemble.sourceInkAnnotationBandsEnabled},"annotation ablation ignored")
unsetenv("AIDOKU_OCR_INK_ANNOTATION_BANDS")
check(!NativeOCRRFPrimaryEnsemble.sourceInkPartitionsEnabled,"non-manga partition policy changed")
check(NativeOCRRFPrimaryEnsemble.$mainMangaEndpointPolicy.withValue(true){NativeOCRRFPrimaryEnsemble.sourceInkPartitionsEnabled},"full manga partition policy missing")
setenv("AIDOKU_OCR_SOURCE_INK_PARTITIONS","0",1)
check(!NativeOCRRFPrimaryEnsemble.$mainMangaEndpointPolicy.withValue(true){NativeOCRRFPrimaryEnsemble.sourceInkPartitionsEnabled},"partition ablation ignored")
unsetenv("AIDOKU_OCR_SOURCE_INK_PARTITIONS")
check(NativeOCRRFPrimaryEnsemble.$mainMangaEndpointPolicy.withValue(true){NativeOCRRFPrimaryEnsemble.sourceInkColumnsEnabled},"full manga default missing")
setenv("AIDOKU_OCR_SOURCE_INK_COLUMNS","0",1)
check(!NativeOCRRFPrimaryEnsemble.$mainMangaEndpointPolicy.withValue(true){NativeOCRRFPrimaryEnsemble.sourceInkColumnsEnabled},"explicit source-column ablation ignored")
setenv("AIDOKU_OCR_SOURCE_INK_COLUMNS","1",1)
let side=500
for degree in stride(from:0.0,to:360.0,by:15) {
 let t=CGFloat(degree)*CGFloat.pi/180,c=cos(t),s=sin(t)
 func world(_ p:CGPoint)->CGPoint{let x=p.x-250,y=p.y-250;return .init(x:250+x*c-y*s,y:250+x*s+y*c)}
 func local(_ p:CGPoint)->CGPoint{let x=p.x-250,y=p.y-250;return .init(x:250+x*c+y*s,y:250-x*s+y*c)}
 func quad(_ r:CGRect)->[CGPoint]{NativeOCRDirectionGeometry.corners(r).map(world)}
 let rectangle=CGRect(x:190,y:130,width:120,height:240),polygon=quad(rectangle)
 // A slanted word's detached terminal dot can sit off its centreline while
 // remaining inside the actual measured column. A neighbouring dot cannot.
 var terminalBytes=[UInt8](repeating:255,count:side*side*4)
 for y in 0..<side {for x in 0..<side {
  let p=local(.init(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5))
  let hollow=CGRect(x:234,y:300,width:8,height:8).contains(p) && !CGRect(x:235,y:301,width:6,height:6).contains(p)
  if hollow || CGRect(x:202,y:279,width:8,height:8).contains(p) || CGRect(x:248,y:279,width:8,height:8).contains(p) {
   let k=(y*side+x)*4;terminalBytes[k]=0;terminalBytes[k+1]=0;terminalBytes[k+2]=0
  }
 }}
 let terminalFrame=NativeOCRRGBAFrame(width:side,height:side,bytes:terminalBytes)!
 let terminalCap=NativeOCRRFPrimaryEnsemble.sourceInkColumnCaps(quad(CGRect(x:200,y:150,width:40,height:120)),
  colour:SIMD3<Int>(repeating:0),frame:terminalFrame)
 let terminalBound=NativeOCRDirectionGeometry.bounds(terminalCap.map(local))
 check(terminalBound.maxY>=286,"off-centre terminal dot was omitted at \(degree)")
 check(terminalBound.maxX<245,"neighbour-column dot was borrowed at \(degree)")
 check(terminalBound.maxY<300,"off-centre hollow accent was treated as a filled dot at \(degree)")
 var compactBytes=[UInt8](repeating:255,count:side*side*4),compactValues=[Float](repeating:0.1,count:side*side)
 for y in 0..<side {for x in 0..<side {
  let point=local(.init(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5))
  var glyph=false
  for n in 0..<3 {if CGRect(x:201,y:145+CGFloat(n*53),width:32,height:34).contains(point) {glyph=true}}
  if glyph {let p=(y*side+x)*4;compactBytes[p]=60;compactBytes[p+1]=70;compactBytes[p+2]=140;compactValues[y*side+x]=0.95}
 }}
 let compactFrame=NativeOCRRGBAFrame(width:side,height:side,bytes:compactBytes)!
 let compactMap=NativeMainEnsembleOCRProbability.Sample(sourceWidth:side,sourceHeight:side,resizedWidth:side,resizedHeight:side,
  region:CGRect(x:0,y:0,width:side,height:side),width:side,height:side,values:compactValues)
 var compactRF=NativeRFDETRLayoutPrimitive(queryID:3000,semanticClass:.text,confidence:0.95,
  sourceBounds:NativeOCRDirectionGeometry.bounds(quad(CGRect(x:190,y:138,width:60,height:155))))
 compactRF.supportPolygon=quad(CGRect(x:190,y:138,width:60,height:155))
 var compactBalloon=NativeRFDETRLayoutPrimitive(queryID:3002,semanticClass:.balloon,confidence:0.95,
  sourceBounds:NativeOCRDirectionGeometry.bounds(quad(CGRect(x:175,y:120,width:140,height:230))))
 compactBalloon.supportPolygon=quad(CGRect(x:175,y:120,width:140,height:230))
 let compactLayout=NativeRFDETRLayoutResult(sourceWidth:side,sourceHeight:side,primitives:[compactRF,compactBalloon])
 let fusedParent=NativeCoreMLDetectionBox(polygon:quad(CGRect(x:180,y:130,width:120,height:200)),score:0.8)
 let compactRecovered=try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:[fusedParent],existing:[fusedParent.polygon],layout:compactLayout,
  frame:compactFrame,probability:compactMap,partitionsEnabled:true)
 check(compactRecovered.contains { box in
  let b=NativeOCRDirectionGeometry.bounds(box.polygon.map(local));return b.minY<148 && b.maxY>282 && b.width<50
 },"strong RF/map witness did not split a compact column from a broad DB parent at \(degree)")
 let withoutParent=try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:[],existing:[],layout:compactLayout,frame:compactFrame,probability:compactMap,partitionsEnabled:true)
 check(withoutParent.contains { box in
  let b=NativeOCRDirectionGeometry.bounds(box.polygon.map(local));return b.minY<148 && b.maxY>282 && b.width<50
 },"map-derived local axis did not recover an RF column without a DB box at \(degree)")
 var uncertainCompact=NativeRFDETRLayoutPrimitive(queryID:3001,semanticClass:.text,confidence:0.8,sourceBounds:compactRF.sourceBounds)
 uncertainCompact.supportPolygon=compactRF.supportPolygon
 let uncertainCompactLayout=NativeRFDETRLayoutResult(sourceWidth:side,sourceHeight:side,primitives:[uncertainCompact,compactBalloon])
 check(try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:[fusedParent],existing:[fusedParent.polygon],layout:uncertainCompactLayout,
  frame:compactFrame,probability:compactMap,partitionsEnabled:true).isEmpty,"RF witness admitted an insufficiently confident scope at \(degree)")
 let emptyCompactMap=NativeMainEnsembleOCRProbability.Sample(sourceWidth:side,sourceHeight:side,resizedWidth:side,resizedHeight:side,
  region:CGRect(x:0,y:0,width:side,height:side),width:side,height:side,values:[Float](repeating:0.1,count:side*side))
 check(try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:[fusedParent],existing:[fusedParent.polygon],layout:compactLayout,
  frame:compactFrame,probability:emptyCompactMap,partitionsEnabled:true).isEmpty,"RF scope invented a crop without model-map support at \(degree)")
 let noBalloon=NativeRFDETRLayoutResult(sourceWidth:side,sourceHeight:side,primitives:[compactRF])
 for uniform in [false,true] {
  var connectedBytes=[UInt8](repeating:255,count:side*side*4),connectedValues=[Float](repeating:0.1,count:side*side)
  for y in 0..<side {for x in 0..<side {
   let p=local(.init(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5))
   var glyph=CGRect(x:215,y:145,width:2,height:140).contains(p)
   if uniform {glyph=CGRect(x:201,y:145,width:32,height:140).contains(p)}
   else {for n in 0..<3 {if CGRect(x:201,y:145+CGFloat(n*53),width:32,height:34).contains(p) {glyph=true}}}
   if glyph {let k=(y*side+x)*4;connectedBytes[k]=60;connectedBytes[k+1]=70;connectedBytes[k+2]=140;connectedValues[y*side+x]=0.95}
  }}
  let connectedMap=NativeMainEnsembleOCRProbability.Sample(sourceWidth:side,sourceHeight:side,resizedWidth:side,resizedHeight:side,
   region:CGRect(x:0,y:0,width:side,height:side),width:side,height:side,values:connectedValues)
  let connected=try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:[fusedParent],existing:[fusedParent.polygon],layout:compactLayout,
   frame:NativeOCRRGBAFrame(width:side,height:side,bytes:connectedBytes)!,probability:connectedMap,partitionsEnabled:true)
  if uniform {check(connected.isEmpty,"uniform rule masqueraded as repeated glyph bodies at \(degree)")}
  else {check(connected.contains { box in
   let b=NativeOCRDirectionGeometry.bounds(box.polygon.map(local));return b.minY<148 && b.maxY>282 && b.width<50
  },"connected glyph contours lost their complete column at \(degree)")}
 }
 var twinBytes=[UInt8](repeating:255,count:side*side*4),twinValues=[Float](repeating:0.1,count:side*side)
 for y in 0..<side {for x in 0..<side {
  let p=local(.init(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5))
  var glyph=false
  for n in 0..<3 {for column in 0..<2 {
   if CGRect(x:201+CGFloat(column*23),y:145+CGFloat(n*53),width:20,height:34).contains(p) {glyph=true}
  }}
  if glyph {let k=(y*side+x)*4;twinBytes[k]=60;twinBytes[k+1]=70;twinBytes[k+2]=140;twinValues[y*side+x]=0.95}
 }}
 let twinMap=NativeMainEnsembleOCRProbability.Sample(sourceWidth:side,sourceHeight:side,resizedWidth:side,resizedHeight:side,
  region:CGRect(x:0,y:0,width:side,height:side),width:side,height:side,values:twinValues)
 let twinRecovered=try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:[fusedParent],existing:[fusedParent.polygon],layout:compactLayout,
  frame:NativeOCRRGBAFrame(width:side,height:side,bytes:twinBytes)!,probability:twinMap,partitionsEnabled:true)
 check(twinRecovered.count>=2,"sample-quantized gutter rejected neighbouring complete columns at \(degree)")
 check(try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:[fusedParent],existing:[fusedParent.polygon],layout:noBalloon,
  frame:compactFrame,probability:compactMap,partitionsEnabled:true).isEmpty,"unanchored RF text borrowed an unverified background scope at \(degree)")
 let shortBody=NativeCoreMLDetectionBox(polygon:quad(CGRect(x:190,y:140,width:100,height:140)),score:0.7)
 check(NativeOCRRFPrimaryEnsemble.sourceInkSideAnnotation(quad(CGRect(x:260,y:160,width:24,height:100)),boxes:[shortBody],
  useOwnFontWidth:true,rfWitness:true),"short fused parent did not suppress its small side reading at \(degree)")
 check(!NativeOCRRFPrimaryEnsemble.sourceInkSideAnnotation(quad(CGRect(x:238,y:150,width:32,height:120)),boxes:[shortBody],
  useOwnFontWidth:true,rfWitness:true),"same-scale central text was marked as a side reading at \(degree)")
 var roleEffect=NativeRFDETRLayoutPrimitive(queryID:2000,semanticClass:.soundEffect,confidence:0.85,
  sourceBounds:NativeOCRDirectionGeometry.bounds(polygon));roleEffect.supportPolygon=polygon
 let effectLayout=NativeRFDETRLayoutResult(sourceWidth:side,sourceHeight:side,primitives:[roleEffect])
 check(NativeOCRRFPrimaryEnsemble.primaryRoleRejection(polygon,layout:effectLayout,width:side,height:side)==nil,
  "non-manga role admission changed at \(degree)")
 check(NativeOCRRFPrimaryEnsemble.$mainMangaEndpointPolicy.withValue(true) {
  NativeOCRRFPrimaryEnsemble.primaryRoleRejection(polygon,layout:effectLayout,width:side,height:side)?.queryID==2000
 },"strong unopposed RF effect reached primary recognition at \(degree)")
 var roleText=NativeRFDETRLayoutPrimitive(queryID:2001,semanticClass:.text,confidence:0.6,
  sourceBounds:NativeOCRDirectionGeometry.bounds(quad(CGRect(x:190,y:130,width:120,height:60))))
 roleText.supportPolygon=quad(CGRect(x:190,y:130,width:120,height:60))
 let conflictedLayout=NativeRFDETRLayoutResult(sourceWidth:side,sourceHeight:side,primitives:[roleEffect,roleText])
 check(NativeOCRRFPrimaryEnsemble.$mainMangaEndpointPolicy.withValue(true) {
  NativeOCRRFPrimaryEnsemble.primaryRoleRejection(polygon,layout:conflictedLayout,width:side,height:side)==nil
 },"text-supported crop was pruned by an RF role conflict at \(degree)")
 var uncertainEffect=NativeRFDETRLayoutPrimitive(queryID:2002,semanticClass:.soundEffect,confidence:0.59,
  sourceBounds:roleEffect.sourceBounds);uncertainEffect.supportPolygon=polygon
 let uncertainLayout=NativeRFDETRLayoutResult(sourceWidth:side,sourceHeight:side,primitives:[uncertainEffect])
 check(NativeOCRRFPrimaryEnsemble.$mainMangaEndpointPolicy.withValue(true) {
  NativeOCRRFPrimaryEnsemble.primaryRoleRejection(polygon,layout:uncertainLayout,width:side,height:side)==nil
 },"uncertain RF effect pruned a primary crop at \(degree)")
 var mediumEffect=NativeRFDETRLayoutPrimitive(queryID:2004,semanticClass:.soundEffect,confidence:0.6,
  sourceBounds:roleEffect.sourceBounds);mediumEffect.supportPolygon=polygon
 let mediumLayout=NativeRFDETRLayoutResult(sourceWidth:side,sourceHeight:side,primitives:[mediumEffect])
 check(NativeOCRRFPrimaryEnsemble.$mainMangaEndpointPolicy.withValue(true) {
  NativeOCRRFPrimaryEnsemble.primaryRoleRejection(polygon,layout:mediumLayout,width:side,height:side)?.queryID==2004
 },"unopposed medium RF effect reached recognition at \(degree)")
 let mediumConflict=NativeRFDETRLayoutResult(sourceWidth:side,sourceHeight:side,primitives:[mediumEffect,roleText])
 check(NativeOCRRFPrimaryEnsemble.$mainMangaEndpointPolicy.withValue(true) {
  NativeOCRRFPrimaryEnsemble.primaryRoleRejection(polygon,layout:mediumConflict,width:side,height:side)==nil
 },"medium role gate pruned independently text-supported ink at \(degree)")
 var partialEffect=NativeRFDETRLayoutPrimitive(queryID:2003,semanticClass:.soundEffect,confidence:0.95,
  sourceBounds:NativeOCRDirectionGeometry.bounds(quad(CGRect(x:190,y:130,width:120,height:120))))
 partialEffect.supportPolygon=quad(CGRect(x:190,y:130,width:120,height:120))
 let partialLayout=NativeRFDETRLayoutResult(sourceWidth:side,sourceHeight:side,primitives:[partialEffect])
 check(NativeOCRRFPrimaryEnsemble.$mainMangaEndpointPolicy.withValue(true) {
  NativeOCRRFPrimaryEnsemble.primaryRoleRejection(polygon,layout:partialLayout,width:side,height:side)==nil
 },"partial RF effect overlap pruned a complete crop at \(degree)")
 check(NativeOCRRFPrimaryEnsemble.$mainMangaEndpointPolicy.withValue(true) {
  NativeOCRRFPrimaryEnsemble.primaryRoleRejection(polygon,layout:effectLayout,width:side+1,height:side)==nil
 },"mismatched RF dimensions entered role admission at \(degree)")
 // Sparse ambiguous components are not independent detector witnesses.
 // Positive text/private/candidate/source-pixel evidence always protects a read.
 do {
  let center=world(CGPoint(x:250,y:220)),px=Int(floor(center.x)),py=Int(floor(center.y))
  let one=NativeOCRDetectorSeedEvidence.Component(seed:py*side+px,pixelCount:1,meanProbability:0.95,
   runs:[.init(y:py,x:px,count:1)])
  let manyRuns=(0..<3).map{NativeOCRDetectorSeedEvidence.Run(y:py+$0,x:px,count:3)}
  let many=NativeOCRDetectorSeedEvidence.Component(seed:py*side+px,pixelCount:9,meanProbability:0.95,runs:manyRuns)
  let pair=NativeOCRDetectorSeedEvidence.Component(seed:py*side+px,pixelCount:2,meanProbability:0.95,runs:[.init(y:py,x:px,count:2)])
  func sparseEvidence(_ mode:Int)->NativeOCRDetectorSeedEvidence {
   .init(ownerID:"sparse-owner",parentBoxIndex:0,provenance:"db-complete-cc-candidates-v2",threshold:0.9,
    mapOriginX:0,mapOriginY:0,mapFullWidth:side,mapFullHeight:side,sourceWidth:side,sourceHeight:side,
    components:mode==1 ? [one]:[],ownershipVersion:2,completeCCScan:true,
    ambiguousComponents:mode==1 || mode==3 ? []:[mode==2 ? many:one],
    candidateComponents:mode==3 ? [.init(component:pair,competingOwnerIDs:["other-owner"],outsideCompetingCells:[1])]:[])
  }
  let emptyRF=NativeRFDETRLayoutResult(sourceWidth:side,sourceHeight:side,primitives:[])
  for mode in 0..<4 {
   let result=NativeOCRRFPrimaryEnsemble.$mainMangaEndpointPolicy.withValue(true) {
    NativeOCRRFPrimaryEnsemble.sparseSharedPrimaryRejection(polygon,evidence:sparseEvidence(mode),layout:emptyRF,width:side,height:side)
   }
   if mode==0 {check(result==1,"single ambiguous source cell entered primary read at \(degree)")}
   else {check(result==nil,"independent/supported source was pruned at \(degree),mode \(mode)")}
  }
  check(NativeOCRRFPrimaryEnsemble.sparseSharedPrimaryRejection(polygon,evidence:sparseEvidence(0),layout:emptyRF,width:side,height:side)==nil,
   "non-manga sparse gate changed at \(degree)")
  check(NativeOCRRFPrimaryEnsemble.$mainMangaEndpointPolicy.withValue(true) {
   NativeOCRRFPrimaryEnsemble.sparseSharedPrimaryRejection(polygon,evidence:sparseEvidence(0),layout:emptyRF,width:side,height:side,hasSourceInkProof:true)==nil
  },"original-pixel proof discarded by sparse gate at \(degree)")
  check(NativeOCRRFPrimaryEnsemble.$mainMangaEndpointPolicy.withValue(true) {
   NativeOCRRFPrimaryEnsemble.sparseSharedPrimaryRejection(polygon,evidence:sparseEvidence(0),layout:nil,width:side,height:side)==nil
  },"unknown RF state pruned a source at \(degree)")
  var positive=NativeRFDETRLayoutPrimitive(queryID:2900,semanticClass:.text,confidence:0.3,sourceBounds:NativeOCRDirectionGeometry.bounds(polygon))
  positive.supportPolygon=polygon
  let positiveRF=NativeRFDETRLayoutResult(sourceWidth:side,sourceHeight:side,primitives:[positive])
  check(NativeOCRRFPrimaryEnsemble.$mainMangaEndpointPolicy.withValue(true) {
   NativeOCRRFPrimaryEnsemble.sparseSharedPrimaryRejection(polygon,evidence:sparseEvidence(0),layout:positiveRF,width:side,height:side)==nil
  },"positive RF text support was ignored at \(degree)")
  check(NativeOCRRFPrimaryEnsemble.$mainMangaEndpointPolicy.withValue(true) {
   NativeOCRRFPrimaryEnsemble.sparseSharedPrimaryRejection(polygon,evidence:sparseEvidence(0),layout:emptyRF,width:side+1,height:side)==nil
  },"mismatched source dimensions entered sparse gate at \(degree)")
 }
 var bytes=[UInt8](repeating:255,count:side*side*4),values=[Float](repeating:0,count:side*side)
 for y in 0..<side {for x in 0..<side {
  let p=local(.init(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5)),offset=(y*side+x)*4
  if rectangle.contains(p){values[y*side+x]=0.1}
  for column in 0..<2 {for row in 0..<4 {
   if CGRect(x:201+column*57,y:145+row*53,width:32,height:34).contains(p) {
    bytes[offset]=60;bytes[offset+1]=70;bytes[offset+2]=140;values[y*side+x]=0.95
   }
  }}
 }}
 let frame=NativeOCRRGBAFrame(width:side,height:side,bytes:bytes)!
 let map=NativeMainEnsembleOCRProbability.Sample(sourceWidth:side,sourceHeight:side,resizedWidth:side,resizedHeight:side,
  region:CGRect(x:0,y:0,width:side,height:side),width:side,height:side,values:values)
 var text=NativeRFDETRLayoutPrimitive(queryID:1,semanticClass:.text,confidence:0.95,sourceBounds:NativeOCRDirectionGeometry.bounds(polygon));text.supportPolygon=polygon
 let layout=NativeRFDETRLayoutResult(sourceWidth:side,sourceHeight:side,primitives:[text])
 let box=NativeCoreMLDetectionBox(polygon:polygon,score:0.95)
 let proposals=try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:[box],existing:[polygon],layout:layout,frame:frame,probability:map)
 check(proposals.count==2,"two full columns missing at \(degree): \(proposals.count)")
 for p in proposals {
  check(p.score>=0.9,"measured DB support lost")
  let local=p.polygon.map{local($0)},b=NativeOCRDirectionGeometry.bounds(local)
  check(b.width>32 && b.width<45 && b.height>190 && b.height<220,"glyph envelope cut or overgrown at \(degree)")
 }
 let anchor=NativeCoreMLDetectionBox(polygon:quad(CGRect(x:201,y:145,width:32,height:193)),score:0.95)
 let context=try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:[anchor],existing:[anchor.polygon],layout:layout,frame:frame,probability:map)
 check(context.count==1,"RF context must recover the other column at \(degree): \(context.count)")
 let body=NativeCoreMLDetectionBox(polygon:quad(CGRect(x:200,y:130,width:40,height:240)),score:0.95)
 check(NativeOCRRFPrimaryEnsemble.sourceInkSideAnnotation(quad(CGRect(x:245,y:150,width:14,height:180)),boxes:[body]),"annotation-sized side column missed at \(degree)")
 check(!NativeOCRRFPrimaryEnsemble.sourceInkSideAnnotation(quad(CGRect(x:300,y:150,width:14,height:180)),boxes:[body]),"remote narrow word suppressed at \(degree)")
 check(!NativeOCRRFPrimaryEnsemble.sourceInkSideAnnotation(quad(CGRect(x:245,y:150,width:32,height:180)),boxes:[body]),"normal-sized neighboring word suppressed at \(degree)")
 var capBytes=bytes,openBytes=bytes
 for y in 0..<side {for x in 0..<side {
  let p=local(.init(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5)),offset=(y*side+x)*4
  if CGRect(x:212,y:352,width:6,height:6).contains(p) || CGRect(x:242,y:145,width:5,height:8).contains(p) {capBytes[offset]=60;capBytes[offset+1]=70;capBytes[offset+2]=140}
  if CGRect(x:212,y:344,width:6,height:140).contains(p) {openBytes[offset]=60;openBytes[offset+1]=70;openBytes[offset+2]=140}
 }}
 let short=quad(CGRect(x:197,y:139,width:40,height:205))
 let capped=NativeOCRRFPrimaryEnsemble.sourceInkColumnCaps(short,colour:SIMD3(60,70,140),frame:NativeOCRRGBAFrame(width:side,height:side,bytes:capBytes)!)
 let capBounds=NativeOCRDirectionGeometry.bounds(capped.map{local($0)})
 check(capBounds.maxY>=358 && capBounds.maxY<=365,"DB-missed closed terminal dot clipped at \(degree): \(capBounds)")
 check(capBounds.maxX>=247 && capBounds.maxX<=253,"detached kana accent clipped at \(degree): \(capBounds)")
 let limited=NativeOCRRFPrimaryEnsemble.sourceInkColumnCaps(short,colour:SIMD3(60,70,140),frame:NativeOCRRGBAFrame(width:side,height:side,bytes:capBytes)!,normalLimits:quad(CGRect(x:197,y:139,width:43,height:205)))
 check(NativeOCRDirectionGeometry.bounds(limited.map{local($0)}).maxX<=240.1,"neighbor midpoint ignored at \(degree)")
 let open=NativeOCRRFPrimaryEnsemble.sourceInkColumnCaps(short,colour:SIMD3(60,70,140),frame:NativeOCRRGBAFrame(width:side,height:side,bytes:openBytes)!)
 check(NativeOCRDirectionGeometry.bounds(open.map{local($0)}).maxY<=345,"open rule borrowed as a cap at \(degree)")
 let duplicate=try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:[box],existing:proposals.map(\.polygon),layout:layout,frame:frame,probability:map)
 check(duplicate.isEmpty,"already owned columns duplicated at \(degree)")
 let missingMap=try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:[box],existing:[],layout:layout,frame:frame,probability:nil)
 check(missingMap.isEmpty,"missing probability invented ink")
 var effect=NativeRFDETRLayoutPrimitive(queryID:2,semanticClass:.soundEffect,confidence:0.8,sourceBounds:text.sourceBounds);effect.supportPolygon=polygon
 let blocked=NativeRFDETRLayoutResult(sourceWidth:side,sourceHeight:side,primitives:[text,effect])
 check(try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:[box],existing:[],layout:blocked,frame:frame,probability:map).isEmpty,"SFX borrowed at \(degree)")
 setenv("AIDOKU_OCR_SOURCE_INK_PARTITIONS","1",1)
 let conserved=try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:[box],existing:[polygon],layout:layout,frame:frame,probability:map)
 check(conserved.map(\.polygon)==proposals.map(\.polygon),"existing validated columns changed under flexible partition at \(degree)")
 var shortBytes=[UInt8](repeating:255,count:side*side*4),shortValues=[Float](repeating:0,count:side*side)
 let loose=CGRect(x:150,y:90,width:200,height:280),supportRect=CGRect(x:185,y:125,width:130,height:202)
 for y in 0..<side {for x in 0..<side {
  let p=local(.init(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5)),offset=(y*side+x)*4
  if supportRect.contains(p){shortValues[y*side+x]=0.1}
  var active=false
  for row in 0..<4 {if CGRect(x:190,y:130+row*52,width:40,height:36).contains(p){active=true}}
  for row in 0..<2 {
   if CGRect(x:270,y:130+row*52,width:9,height:36).contains(p) || CGRect(x:285,y:130+row*52,width:25,height:36).contains(p){active=true}
  }
  if active {shortBytes[offset]=60;shortBytes[offset+1]=70;shortBytes[offset+2]=140;shortValues[y*side+x]=0.95}
 }}
 let shortFrame=NativeOCRRGBAFrame(width:side,height:side,bytes:shortBytes)!
 let shortMap=NativeMainEnsembleOCRProbability.Sample(sourceWidth:side,sourceHeight:side,resizedWidth:side,resizedHeight:side,
  region:CGRect(x:0,y:0,width:side,height:side),width:side,height:side,values:shortValues)
 var narrowScope=NativeRFDETRLayoutPrimitive(queryID:3,semanticClass:.text,confidence:0.95,sourceBounds:NativeOCRDirectionGeometry.bounds(quad(supportRect)));narrowScope.supportPolygon=quad(supportRect)
 let shortLayout=NativeRFDETRLayoutResult(sourceWidth:side,sourceHeight:side,primitives:[narrowScope])
 let looseBox=NativeCoreMLDetectionBox(polygon:quad(loose),score:0.95)
 let shortColumns=try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:[looseBox],existing:[looseBox.polygon],layout:shortLayout,frame:shortFrame,probability:shortMap)
 check(shortColumns.count==2,"loose DB margin / short final column / internal counter at \(degree): \(shortColumns.count)")
 let bounds=shortColumns.map{NativeOCRDirectionGeometry.bounds($0.polygon.map{local($0)})}.sorted{$0.minX<$1.minX}
 if bounds.count==2 {check(bounds[1].width>=40 && bounds[1].width<65 && bounds[1].height>=85 && bounds[1].height<120,"glyph counter split or short column inflated at \(degree)")}
 var weakScope=NativeRFDETRLayoutPrimitive(queryID:4,semanticClass:.text,confidence:0.6,sourceBounds:narrowScope.sourceBounds);weakScope.supportPolygon=narrowScope.supportPolygon
 let weak=NativeRFDETRLayoutResult(sourceWidth:side,sourceHeight:side,primitives:[weakScope])
 check(try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:[looseBox],existing:[looseBox.polygon],layout:weak,frame:shortFrame,probability:shortMap).isEmpty,"weak RF inside loose detector borrowed at \(degree)")
 func fragment(_ rect:CGRect,_ index:Int,_ pixels:[UInt8]?=nil,_ probability:[Float]?=nil)->NativeCoreMLDetectionBox {
  let ownedPixels=pixels ?? bytes
  var runs:[NativeOCRDetectorSeedEvidence.Run]=[]
  for y in 0..<side {var start:Int?
   for x in 0...side {
    let owned=x<side && rect.contains(local(.init(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5))) && ownedPixels[(y*side+x)*4]==60 &&
     (probability == nil || probability![y*side+x]>=0.9)
    if owned {if start==nil {start=x}}
    else if let begin=start {runs.append(.init(y:y,x:begin,count:x-begin));start=nil}
   }
  }
  var groups:[[NativeOCRDetectorSeedEvidence.Run]]=[]
  for r in runs {if let last=groups.last?.last,r.y<=last.y+1 {groups[groups.count-1].append(r)} else {groups.append([r])}}
  let components=groups.map { runs in NativeOCRDetectorSeedEvidence.Component(seed:runs[0].y*side+runs[0].x,pixelCount:runs.reduce(0){$0+$1.count},meanProbability:0.95,runs:runs) }
  let evidence=NativeOCRDetectorSeedEvidence(ownerID:"fragment-\(index)",parentBoxIndex:index,provenance:"db-complete-cc-candidates-v2",threshold:0.9,mapOriginX:0,mapOriginY:0,mapFullWidth:side,mapFullHeight:side,sourceWidth:side,sourceHeight:side,components:components,ownershipVersion:2,completeCCScan:true,ambiguousComponents:[],candidateComponents:[])
  return .init(polygon:quad(rect),score:0.7,detectorSeedEvidence:evidence)
 }
 let fragments=[fragment(CGRect(x:197,y:140,width:40,height:96),0),fragment(CGRect(x:197,y:246,width:40,height:96),1)]
 // A narrow DB normal extent must recover its closed connected collar,
 // while disconnected side readings, foreign paint and open paper cannot grow it.
 do {
  for variant in 0..<9 {
   var contourPixels=[UInt8](repeating:255,count:side*side*4)
   for y in 0..<side {for x in 0..<side {
    let p=local(.init(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5)),k=(y*side+x)*4
    var colour=[115,110,135]
    for n in 0..<5 {
     let top=CGFloat(110+n*45)
     if CGRect(x:202,y:top,width:38,height:38).contains(p) {colour=[250,253,250]}
     if variant==2,CGRect(x:180,y:top,width:90,height:38).contains(p) {colour=[250,253,250]}
     let fullBody=variant != 5 && !(variant==8 && n>0 && n<4)
     if CGRect(x:fullBody ? 203:208,y:top+4,width:fullBody ? 36:26,height:30).contains(p) {colour=[60,70,140]}
     if CGRect(x:246,y:top+6,width:5,height:10).contains(p) {colour=[60,70,140]}
     if variant==1,CGRect(x:230,y:top+12,width:21,height:5).contains(p) {colour=[60,70,140]}
    }
    for c in 0..<3 {contourPixels[k+c]=UInt8(colour[c])}
   }}
   let owner=fragment(CGRect(x:208,y:105,width:26,height:230),501,contourPixels)
   let ruby=fragment(CGRect(x:241,y:105,width:13,height:230),502,contourPixels)
   var scope=NativeRFDETRLayoutPrimitive(queryID:1100,semanticClass:.text,confidence:0.44,
    sourceBounds:NativeOCRDirectionGeometry.bounds(quad(CGRect(x:198,y:102,width:43,height:238))))
   scope.supportPolygon=quad(CGRect(x:variant==7 ? 160:198,y:102,width:variant==7 ? 120:43,height:238))
   let layout=NativeRFDETRLayoutResult(sourceWidth:side,sourceHeight:side,primitives:[scope])
   let noOwner=NativeCoreMLDetectionBox(polygon:owner.polygon,score:0.7)
   let completed=NativeOCRDirectionGeometry.$mainMangaPolicy.withValue(true) {
    NativeOCRRFPrimaryEnsemble.$mainMangaEndpointPolicy.withValue(true) {
     NativeOCRRFPrimaryEnsemble.completingPrivateNormalInk(index:0,boxes:[variant==4 ? noOwner:owner,ruby],
      polygon:owner.polygon,layout:variant==3 ? nil:layout,frame:NativeOCRRGBAFrame(width:side,height:side,bytes:contourPixels)!,
      inkStyle:variant==6 ? .init([250,253,250]):nil)
    }
   }
   let b=NativeOCRDirectionGeometry.bounds(completed.map(local))
   if variant==0 {
    check(b.minX<=203 && b.maxX>=239,"closed source collar clipped at \(degree): \(b)")
    check(b.maxX<246,"side annotation acquired by normal contour at \(degree)")
   } else if variant==2 {
    check(b.minX<=204 && b.maxX>=238 && b.width<45,"open backing supplied extra normal growth at \(degree): \(b)")
   } else {check(b.width<28,"foreign/unwitnessed contour acquired at \(degree), variant \(variant): \(b)")}
   check(abs(b.minY-105)<0.01 && abs(b.maxY-335)<0.01,"normal completion moved reading endpoints at \(degree)")
  }
 }
 // Lateral detector padding is separate from the measured reading span.
 // A low box score does not erase its strong private paint observations.
 for collar in [false,true] {
  var widthBytes=[UInt8](repeating:255,count:side*side*4)
  for y in 0..<side {for x in 0..<side {
   let p=local(.init(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5)),k=(y*side+x)*4
   var colour=collar ? [115,110,135]:[255,255,255]
   for n in 0..<5 {
    if collar,CGRect(x:207,y:107+CGFloat(n*50),width:38,height:42).contains(p) {colour=[250,253,250]}
    if CGRect(x:211,y:111+CGFloat(n*50),width:30,height:34).contains(p) {colour=[60,70,140]}
   }
   // An independently detected small side reading is not part of the word.
   for n in 0..<15 {if CGRect(x:254,y:115+CGFloat(n*15),width:5,height:8).contains(p) {colour=[60,70,140]}}
   for c in 0..<3 {widthBytes[k+c]=UInt8(colour[c])}
  }}
  let widthOwner=fragment(CGRect(x:205,y:100,width:42,height:300),401,widthBytes)
  let broadBox=NativeCoreMLDetectionBox(polygon:quad(CGRect(x:185,y:100,width:80,height:300)),
   score:0.69,detectorSeedEvidence:widthOwner.detectorSeedEvidence)
  let rubyBox=fragment(CGRect(x:251,y:110,width:12,height:240),402,widthBytes)
  var widthScope=NativeRFDETRLayoutPrimitive(queryID:1012,semanticClass:.text,confidence:0.44,
   sourceBounds:NativeOCRDirectionGeometry.bounds(quad(CGRect(x:204,y:105,width:45,height:250))))
  widthScope.supportPolygon=quad(CGRect(x:204,y:105,width:45,height:250))
  let widthLayout=NativeRFDETRLayoutResult(sourceWidth:side,sourceHeight:side,primitives:[widthScope])
  let widthFrame=NativeOCRRGBAFrame(width:side,height:side,bytes:widthBytes)!
  let fitted=NativeOCRDirectionGeometry.$mainMangaPolicy.withValue(true) {
   NativeOCRRFPrimaryEnsemble.$mainMangaEndpointPolicy.withValue(true) {
    NativeOCRRFPrimaryEnsemble.fittingPrivateInkWidth(index:0,boxes:[broadBox,rubyBox],polygon:broadBox.polygon,
     layout:widthLayout,frame:widthFrame)
   }
  }
  let b=NativeOCRDirectionGeometry.bounds(fitted.map(local))
  check(b.width<60,"private normal ink did not remove broad lateral padding at \(degree): \(b)")
  check(b.minX<=211 && b.maxX>=241,"normal fit clipped an owned glyph at \(degree): \(b)")
  if collar {check(b.minX<=207 && b.maxX>=245,"normal fit clipped a real white collar at \(degree): \(b)")}
  // The peer's private glyph starts at254; its detector margin begins at251.
  // Blank sampling margin is not a borrowed furigana stroke.
  check(b.maxX<254,"normal fit included the independent side reading at \(degree): \(b)")
  check(abs(b.minY-100)<0.01 && abs(b.maxY-400)<0.01,"width fitting moved the reading endpoints at \(degree)")
  let noScope=NativeOCRRFPrimaryEnsemble.$mainMangaEndpointPolicy.withValue(true) {
   NativeOCRRFPrimaryEnsemble.fittingPrivateInkWidth(index:0,boxes:[broadBox],polygon:broadBox.polygon,
    layout:nil,frame:widthFrame)
  }
  check(noScope==broadBox.polygon,"width fitting invented RF support at \(degree)")
 }
 // Preserve the font-sized reading cell for narrow glyphs and dot rails.
 // These are not coarse region boxes merely because their paint is narrow.
 for dots in [false,true] {
  var cellBytes=[UInt8](repeating:255,count:side*side*4)
  for y in 0..<side {for x in 0..<side {
   let p=local(.init(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5)),k=(y*side+x)*4
   for n in 0..<(dots ? 12:5) {
    let glyph=CGRect(x:dots ? 216:210,y:110+CGFloat(n*(dots ? 14:35)),width:dots ? 8:20,height:dots ? 8:28)
    if glyph.contains(p) {cellBytes[k]=60;cellBytes[k+1]=70;cellBytes[k+2]=140}
   }
  }}
  let cellRect=CGRect(x:200,y:100,width:40,height:200),owned=fragment(cellRect,410,cellBytes)
  var cellScope=NativeRFDETRLayoutPrimitive(queryID:1013,semanticClass:.text,confidence:0.8,
   sourceBounds:NativeOCRDirectionGeometry.bounds(quad(cellRect)))
  cellScope.supportPolygon=quad(cellRect)
  let fitted=NativeOCRRFPrimaryEnsemble.$mainMangaEndpointPolicy.withValue(true) {
   NativeOCRRFPrimaryEnsemble.fittingPrivateInkWidth(index:0,boxes:[owned],polygon:owned.polygon,
    layout:.init(sourceWidth:side,sourceHeight:side,primitives:[cellScope]),
    frame:NativeOCRRGBAFrame(width:side,height:side,bytes:cellBytes)!)
  }
  check(fitted==owned.polygon,"narrow glyphs/dots lost their normal font cell at \(degree)")
 }
 // A white outline joins the word and three dots into one component. Its
 // private coloured interiors still measure the real punctuation scale.
 for headTrain in [false,true] {for tailKind in 0..<3 {
  let resolvedTail=tailKind == 1
  var dotBytes=[UInt8](repeating:255,count:side*side*4)
  for y in 0..<side {for x in 0..<side {
   let sample=local(.init(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5)),k=(y*side+x)*4
   let p=CGPoint(x:sample.x,y:headTrain ? CGFloat(side)-sample.y:sample.y)
   var colour=[105,105,115]
   var halo=CGRect(x:203,y:105,width:34,height:55).contains(p) || CGRect(x:216,y:150,width:4,height:78).contains(p)
   var fill=CGRect(x:207,y:109,width:26,height:47).contains(p)
   for n in 0..<3 {
    if CGRect(x:209,y:167+CGFloat(n*22),width:18,height:18).contains(p) {halo=true}
    if CGRect(x:213,y:171+CGFloat(n*22),width:10,height:10).contains(p) {fill=true}
   }
   if halo {colour=[250,253,250]}
   if fill {colour=[60,70,140]}
   for n in 0..<3 where tailKind < 2 {
    if CGRect(x:214,y:254+CGFloat(n*22),width:resolvedTail ? 10:3,height:resolvedTail ? 10:3).contains(p) {
     colour=resolvedTail ? [60,70,140]:[250,253,250]
    }
   }
   for c in 0..<3 {dotBytes[k+c]=UInt8(colour[c])}
  }}
  let dotRect=CGRect(x:200,y:headTrain ? 265:100,width:40,height:135),sample=fragment(dotRect,301,dotBytes)
  let dotBox=NativeCoreMLDetectionBox(polygon:sample.polygon,score:0.95,detectorSeedEvidence:sample.detectorSeedEvidence)
  var dotScope=NativeRFDETRLayoutPrimitive(queryID:1011,semanticClass:.text,confidence:0.9,
   sourceBounds:NativeOCRDirectionGeometry.bounds(quad(CGRect(x:198,y:headTrain ? 162:98,width:44,height:240))))
  dotScope.supportPolygon=quad(CGRect(x:198,y:headTrain ? 162:98,width:44,height:240))
  var measuredDiameter:CGFloat=0
  let dotCompletion=NativeOCRDirectionGeometry.$mainMangaPolicy.withValue(true) {
   NativeOCRRFPrimaryEnsemble.$mainMangaEndpointPolicy.withValue(true) {
    NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index:0,boxes:[dotBox],
     layout:.init(sourceWidth:side,sourceHeight:side,primitives:[dotScope]),
     frame:NativeOCRRGBAFrame(width:side,height:side,bytes:dotBytes)!,refineInk:true,audit:{ row in
      if let diameter=row["sourcePointDiameter"] as? CGFloat {measuredDiameter=diameter}
     })
   }
  }
  check(measuredDiameter>=8,"fused outline hid the private dot scale at \(degree)")
  let dotBound=NativeOCRDirectionGeometry.bounds((dotCompletion ?? dotBox.polygon).map(local))
  let end=headTrain ? CGFloat(side)-dotBound.minY:dotBound.maxY
  if resolvedTail {check(end>=300,"resolved source-size punctuation was rejected at \(degree): \(dotBound)")}
  else {check(end<250,"tiny unowned texture prolonged a fused outlined word at \(degree): \(dotBound)")}
  let opposite=headTrain ? CGFloat(side)-dotBound.maxY:dotBound.minY
  check(opposite>95,"a private point train moved the opposite endpoint at \(degree): \(dotBound)")
 }}
 // Outside gutters share the terminal ink colours, while the actual paper
 // inside the detector is white. A black-only palette must not trim the
 // private red/blue glyphs; genuinely blank trailing paper may still shrink.
 let colourRect=CGRect(x:200,y:100,width:40,height:330)
 var colourBytes=[UInt8](repeating:255,count:side*side*4)
 var colourRuns:[NativeOCRDetectorSeedEvidence.Run]=[]
 for y in 0..<side {
  var runStart:Int?
  for x in 0...side {
   let p=local(.init(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5)),owned=x<side && colourRect.contains(p)
   if owned {if runStart==nil {runStart=x}}
   else if let first=runStart {colourRuns.append(.init(y:y,x:first,count:x-first));runStart=nil}
   if x==side {continue}
   let k=(y*side+x)*4
   var ink:[Int]?
   if (p.x>=185 && p.x<200) || (p.x>=240 && p.x<255) {
    if p.y>=100,p.y<170 {ink=[180,20,40]}
    if p.y>=345,p.y<430 {ink=[8,138,220]}
   }
   for n in 0..<9 {
    if CGRect(x:205,y:105+CGFloat(n*35),width:30,height:24).contains(p) {
     ink=n<2 ? [180,20,40]:(n>=7 ? [8,138,220]:[2,1,1])
    }
   }
   if let ink {for channel in 0..<3 {colourBytes[k+channel]=UInt8(ink[channel])}}
  }
 }
 let colourComponent=NativeOCRDetectorSeedEvidence.Component(seed:colourRuns[0].y*side+colourRuns[0].x,
  pixelCount:colourRuns.reduce(0){$0+$1.count},meanProbability:0.95,runs:colourRuns)
 let colourEvidence=NativeOCRDetectorSeedEvidence(ownerID:"colour-word",parentBoxIndex:0,provenance:"db-complete-cc-candidates-v2",
  threshold:0.9,mapOriginX:0,mapOriginY:0,mapFullWidth:side,mapFullHeight:side,sourceWidth:side,sourceHeight:side,
  components:[colourComponent],ownershipVersion:2,completeCCScan:true,ambiguousComponents:[],candidateComponents:[])
 let colourBox=NativeCoreMLDetectionBox(polygon:quad(colourRect),score:0.95,detectorSeedEvidence:colourEvidence)
 let colourFrame=NativeOCRRGBAFrame(width:side,height:side,bytes:colourBytes)!
 var colourScope=NativeRFDETRLayoutPrimitive(queryID:1010,semanticClass:.text,confidence:0.9,
  sourceBounds:NativeOCRDirectionGeometry.bounds(quad(CGRect(x:198,y:98,width:44,height:335))))
 colourScope.supportPolygon=quad(CGRect(x:198,y:98,width:44,height:335))
 let colourLayout=NativeRFDETRLayoutResult(sourceWidth:side,sourceHeight:side,primitives:[colourScope])
 let colourTrim=NativeOCRDirectionGeometry.$mainMangaPolicy.withValue(true) {
  NativeOCRRFPrimaryEnsemble.$mainMangaEndpointPolicy.withValue(true) {
   NativeOCRRFPrimaryEnsemble.trimmingEndpointPadding(index:0,boxes:[colourBox],polygon:colourBox.polygon,
    layout:colourLayout,frame:colourFrame,inkStyles:[.init([2,1,1])])
  }
 }
 let colourBound=NativeOCRDirectionGeometry.bounds(colourTrim.map(local))
 check(colourBound.minY<=106 && colourBound.maxY>=408,"private multicolour terminal glyphs were trimmed at \(degree)")
 check(colourBound.maxY<colourRect.maxY-1,"coarse private paper prevented proven padding trim at \(degree): \(colourBound)")
 for brightPrint in [false,true] {
  var shadeBytes=[UInt8](repeating:255,count:side*side*4)
  for y in 0..<side {for x in 0..<side {
   let p=local(.init(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5)),k=(y*side+x)*4
   var colour=[110,60,120]
   for n in 0..<4 {if CGRect(x:205,y:110+CGFloat(n*40),width:30,height:24).contains(p) {colour=[255,255,255]}}
   if CGRect(x:214,y:292,width:12,height:18).contains(p) {colour=brightPrint ? [250,230,20]:[18,18,50]}
   for channel in 0..<3 {shadeBytes[k+channel]=UInt8(colour[channel])}
  }}
  let shadeTrim=NativeOCRDirectionGeometry.$mainMangaPolicy.withValue(true) {
   NativeOCRRFPrimaryEnsemble.$mainMangaEndpointPolicy.withValue(true) {
    NativeOCRRFPrimaryEnsemble.trimmingEndpointPadding(index:0,boxes:[colourBox],polygon:colourBox.polygon,
     layout:colourLayout,frame:NativeOCRRGBAFrame(width:side,height:side,bytes:shadeBytes)!,inkStyles:[.init([255,255,255])])
   }
  }
  let b=NativeOCRDirectionGeometry.bounds(shadeTrim.map(local))
  check(b.minY<=115 && b.maxY>=253,"base white glyphs lost during colour validation at \(degree)")
  if brightPrint {check(b.maxY>=309,"independent bright print was rejected as shadow at \(degree)")}
  else {check(b.maxY<285,"opposite-polarity backing prolonged the white word at \(degree)")}
 }
 var contourBytes=[UInt8](repeating:255,count:side*side*4),contourValues=[Float](repeating:0.1,count:side*side)
 for y in 0..<side {for x in 0..<side {
  let p=local(.init(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5)),k=(y*side+x)*4
  if CGRect(x:203,y:260,width:34,height:44).contains(p) && !CGRect(x:206,y:263,width:28,height:38).contains(p) {
   contourBytes[k]=60;contourBytes[k+1]=70;contourBytes[k+2]=140;contourValues[y*side+x]=0.95
  }
 }}
 let contourFrame=NativeOCRRGBAFrame(width:side,height:side,bytes:contourBytes)!
 let contourMap=NativeMainEnsembleOCRProbability.Sample(sourceWidth:side,sourceHeight:side,resizedWidth:side,resizedHeight:side,
  region:CGRect(x:0,y:0,width:side,height:side),width:side,height:side,values:contourValues)
 let contourBase=quad(CGRect(x:200,y:150,width:40,height:120))
 let completedContour=NativeOCRRFPrimaryEnsemble.sourceInkColumnCaps(contourBase,colour:SIMD3(60,70,140),frame:contourFrame,probability:contourMap)
 check(NativeOCRDirectionGeometry.bounds(completedContour.map(local)).maxY>=303,"strongly rooted partial contour was clipped at \(degree)")
 let unsupportedContour=NativeOCRRFPrimaryEnsemble.sourceInkColumnCaps(contourBase,colour:SIMD3(60,70,140),frame:contourFrame)
 check(NativeOCRDirectionGeometry.bounds(unsupportedContour.map(local)).maxY<=271,"unrooted contour borrowed a terminal glyph at \(degree)")
 // A low-map point train can end in a closed narrow stroke and one
 // final dot. Its spacing, source root and final point must all be real.
 do {
  for direction in [CGFloat(-1),CGFloat(1)] {
   for variant in 0..<8 {
    var capPixels=[UInt8](repeating:255,count:side*side*4)
    func terminalRect(_ y:CGFloat,_ h:CGFloat,_ w:CGFloat=6)->CGRect {
     let yy=direction>0 ? y:540-y-h
     return CGRect(x:220-w/2,y:yy,width:w,height:h)
    }
    let sourceEnd:CGFloat=variant==6 ? 240:(variant==7 ? 215:270)
    let sourceRect=direction>0 ? CGRect(x:200,y:sourceEnd-120,width:40,height:120):CGRect(x:200,y:540-sourceEnd,width:40,height:120)
    var shapes=[CGRect]()
    if variant != 1 {
     for n in 0..<(variant>=6 ? 4:3) {shapes.append(terminalRect(CGFloat((variant>=6 ? 225:239)+n*14+(variant==2 && n==1 ? 6:0)),6))}
    }
    if variant != 3 {shapes.append(terminalRect(308,6))}
    shapes.append(terminalRect(285,18,variant==4 ? 26:6))
    if variant==5 {shapes.append(terminalRect(285,110,6))}
    for y in 0..<side {for x in 0..<side {
     let p=local(.init(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5))
     if shapes.contains(where:{$0.contains(p)}) {
      let k=(y*side+x)*4;capPixels[k]=60;capPixels[k+1]=70;capPixels[k+2]=140
     }
    }}
    let capFrame=NativeOCRRGBAFrame(width:side,height:side,bytes:capPixels)!
    let completed=NativeOCRRFPrimaryEnsemble.sourceInkColumnCaps(quad(sourceRect),colour:SIMD3(60,70,140),frame:capFrame)
    let bound=NativeOCRDirectionGeometry.bounds(completed.map(local))
    let end=direction>0 ? bound.maxY:540-bound.minY
    if variant==0 || variant==6 {check(end>=313,"periodic closed terminal omitted at \(degree), direction \(direction): \(bound)")}
    else {check(end<300,"uncertified terminal borrowed at \(degree), direction \(direction), variant \(variant): \(bound)")}
   }
  }
 }
 var fragmentScope=NativeRFDETRLayoutPrimitive(queryID:5,semanticClass:.text,confidence:0.35,sourceBounds:NativeOCRDirectionGeometry.bounds(quad(CGRect(x:200,y:138,width:34,height:208))))
 fragmentScope.supportPolygon=quad(CGRect(x:200,y:138,width:34,height:208))
 let fragmentLayout=NativeRFDETRLayoutResult(sourceWidth:side,sourceHeight:side,primitives:[fragmentScope])
 let complete=try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:fragments,existing:fragments.map(\.polygon),layout:fragmentLayout,frame:frame,probability:map)
 check(complete.count==1,"aligned private fragments under weak RF were not recovered at \(degree): \(complete.count)")
 let weakPrivate=NativeCoreMLDetectionBox(polygon:fragments[0].polygon,score:0.55,detectorSeedEvidence:fragments[0].detectorSeedEvidence)
 let strongPrivate=NativeCoreMLDetectionBox(polygon:fragments[1].polygon,score:0.8,detectorSeedEvidence:fragments[1].detectorSeedEvidence)
 let measuredBoxes=[weakPrivate,strongPrivate]
 let measured=try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:measuredBoxes,existing:measuredBoxes.map(\.polygon),layout:fragmentLayout,frame:frame,probability:map)
 check(measured.count==1,"independent private roots lost a weak scalar-score fragment at \(degree)")
 if let p=measured.first {let b=NativeOCRDirectionGeometry.bounds(p.polygon.map(local));check(b.minY<147 && b.maxY>335,"measured weak-score chain truncated at \(degree)")}
 let bothWeak=[weakPrivate,NativeCoreMLDetectionBox(polygon:strongPrivate.polygon,score:0.55,detectorSeedEvidence:strongPrivate.detectorSeedEvidence)]
 check(try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:bothWeak,existing:bothWeak.map(\.polygon),layout:fragmentLayout,frame:frame,probability:map).isEmpty,
  "weak scores without a strong peer certified a new chain at \(degree)")
 var broadMeasuredScope=NativeRFDETRLayoutPrimitive(queryID:1000,semanticClass:.text,confidence:0.35,
  sourceBounds:NativeOCRDirectionGeometry.bounds(quad(CGRect(x:60,y:138,width:320,height:208))))
 broadMeasuredScope.supportPolygon=quad(CGRect(x:60,y:138,width:320,height:208))
 let broadMeasuredLayout=NativeRFDETRLayoutResult(sourceWidth:side,sourceHeight:side,primitives:[broadMeasuredScope])
 check(try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:measuredBoxes,existing:measuredBoxes.map(\.polygon),layout:broadMeasuredLayout,frame:frame,probability:map).count==1,
  "broad RF discarded a complete privately measured narrow chain at \(degree)")
 if let p=complete.first {let b=NativeOCRDirectionGeometry.bounds(p.polygon.map{local($0)});check(b.minY<147 && b.maxY>335 && b.width<50,"weak RF overexpanded or truncated lane at \(degree)")}
 let oversizedOwner=quad(CGRect(x:182,y:110,width:70,height:270))
 let refined=try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:fragments,existing:[oversizedOwner],layout:fragmentLayout,frame:frame,probability:map)
 check(refined.count==1,"oversized existing owner blocked an independently rooted precise crop at \(degree)")
 if let p=refined.first {let b=NativeOCRDirectionGeometry.bounds(p.polygon.map(local));check(b.width<50 && b.height>180 && b.height<230,
  "root-certified refinement lost the full column at \(degree)")}
 let weakRefineBody=NativeCoreMLDetectionBox(polygon:fragments[0].polygon,score:0.85,detectorSeedEvidence:fragments[0].detectorSeedEvidence)
 let weakRefineTail=NativeCoreMLDetectionBox(polygon:fragments[1].polygon,score:0.48,detectorSeedEvidence:fragments[1].detectorSeedEvidence)
 let fullAnchor=NativeCoreMLDetectionBox(polygon:quad(CGRect(x:197,y:140,width:40,height:202)),score:0.85)
 let weakRefineBoxes=[weakRefineBody,weakRefineTail,fullAnchor]
 var preciseScope=NativeRFDETRLayoutPrimitive(queryID:1003,semanticClass:.text,confidence:0.95,
  sourceBounds:NativeOCRDirectionGeometry.bounds(quad(CGRect(x:190,y:138,width:60,height:208))))
 preciseScope.supportPolygon=quad(CGRect(x:190,y:138,width:60,height:208))
 let preciseLayout=NativeRFDETRLayoutResult(sourceWidth:side,sourceHeight:side,primitives:[preciseScope])
 let weakRefinement=try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:weakRefineBoxes,existing:[oversizedOwner],layout:preciseLayout,frame:frame,probability:map)
 check(weakRefinement.count==1,"strong RF and independent weak-root tail did not refine the oversized owner at \(degree)")
 if let p=weakRefinement.first {let b=NativeOCRDirectionGeometry.bounds(p.polygon.map(local));check(b.minY<147 && b.maxY>335,
  "strong-RF weak-root refinement dropped a terminal at \(degree)")}
 var weakerScope=NativeRFDETRLayoutPrimitive(queryID:1004,semanticClass:.text,confidence:0.8,sourceBounds:preciseScope.sourceBounds)
 weakerScope.supportPolygon=preciseScope.supportPolygon
 let weakerLayout=NativeRFDETRLayoutResult(sourceWidth:side,sourceHeight:side,primitives:[weakerScope])
 check(try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:weakRefineBoxes,existing:[oversizedOwner],layout:weakerLayout,frame:frame,probability:map).isEmpty,
  "weak-root refinement ignored the required strong RF support at \(degree)")
 check(try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:[fragments[0]],existing:[fragments[0].polygon],layout:fragmentLayout,frame:frame,probability:map).isEmpty,"one fragment certified weak RF at \(degree)")
 var outlinedBytes=[UInt8](repeating:255,count:side*side*4)
 for y in 0..<side {for x in 0..<side {
  let offset=(y*side+x)*4;outlinedBytes[offset]=110;outlinedBytes[offset+1]=90;outlinedBytes[offset+2]=80
  let point=local(.init(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5))
  for n in 0..<4 {
   let glyph=CGRect(x:201,y:148+CGFloat(n*52),width:32,height:34)
   guard glyph.contains(point) else {continue}
   if glyph.insetBy(dx:3,dy:3).contains(point) {
    outlinedBytes[offset]=60;outlinedBytes[offset+1]=n<2 ? 70:150;outlinedBytes[offset+2]=n<2 ? 140:70
   } else {outlinedBytes[offset]=235;outlinedBytes[offset+1]=235;outlinedBytes[offset+2]=235}
  }
 }}
 let outlinedFragments=[fragment(CGRect(x:197,y:140,width:40,height:96),500,outlinedBytes),
  fragment(CGRect(x:197,y:246,width:40,height:96),501,outlinedBytes)]
 let outlinedFrame=NativeOCRRGBAFrame(width:side,height:side,bytes:outlinedBytes)!
 let outlinedColumns=try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:outlinedFragments,existing:outlinedFragments.map(\.polygon),layout:fragmentLayout,
  frame:outlinedFrame,probability:map)
 check(outlinedColumns.contains { box in
  let b=NativeOCRDirectionGeometry.bounds(box.polygon.map(local));return b.minY<147 && b.maxY>335 && b.width<50
 },"stable pale stroke lost a model-supported column with changing inner colour at \(degree)")
 let unownedOutline=NativeCoreMLDetectionBox(polygon:outlinedFragments[1].polygon,score:0.7)
 check(try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:[outlinedFragments[0],unownedOutline],existing:outlinedFragments.map(\.polygon),layout:fragmentLayout,
  frame:outlinedFrame,probability:map).isEmpty,"pale stroke borrowed an unowned colour-changing fragment at \(degree)")
 let shortFragment=fragment(CGRect(x:197,y:246,width:40,height:70),2)
 check(try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:[fragments[0],shortFragment],existing:[fragments[0].polygon,shortFragment.polygon],layout:fragmentLayout,frame:frame,probability:map).isEmpty,"short detached word certified broad search at \(degree)")
 let terminal=fragment(CGRect(x:197,y:246,width:40,height:50),3)
 var terminalScope=NativeRFDETRLayoutPrimitive(queryID:8,semanticClass:.text,confidence:0.9,sourceBounds:NativeOCRDirectionGeometry.bounds(quad(CGRect(x:200,y:138,width:34,height:160))))
 terminalScope.supportPolygon=quad(CGRect(x:200,y:138,width:34,height:160))
 let terminalLayout=NativeRFDETRLayoutResult(sourceWidth:side,sourceHeight:side,primitives:[terminalScope])
 let terminalColumns=try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:[fragments[0],terminal],existing:[fragments[0].polygon,terminal.polygon],layout:terminalLayout,frame:frame,probability:map)
 check(terminalColumns.count==1,"strong RF lost adjacent short terminal at \(degree): \(terminalColumns.count)")
 func shared(_ box:NativeCoreMLDetectionBox,_ index:Int)->NativeCoreMLDetectionBox {
  let e=box.detectorSeedEvidence!
  let evidence=NativeOCRDetectorSeedEvidence(ownerID:"shared-\(index)",parentBoxIndex:index,provenance:e.provenance,threshold:e.threshold,mapOriginX:e.mapOriginX,mapOriginY:e.mapOriginY,mapFullWidth:e.mapFullWidth,mapFullHeight:e.mapFullHeight,sourceWidth:e.sourceWidth,sourceHeight:e.sourceHeight,components:[],ownershipVersion:2,completeCCScan:true,ambiguousComponents:e.components,candidateComponents:[])
  return .init(polygon:box.polygon,score:box.score,detectorSeedEvidence:evidence)
 }
 let sharedTerminal=shared(terminal,10)
 let sharedColumns=try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:[fragments[0],sharedTerminal],existing:[fragments[0].polygon,sharedTerminal.polygon],layout:terminalLayout,frame:frame,probability:map)
 check(sharedColumns.count==1,"shared terminal ink lost despite independent body and strong RF at \(degree)")
 let sharedBody=shared(fragments[0],11)
 check(try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:[sharedBody,sharedTerminal],existing:[sharedBody.polygon,sharedTerminal.polygon],layout:terminalLayout,frame:frame,probability:map).isEmpty,"shared evidence alone certified compact chain at \(degree)")
 var outlineValues=values
 for y in 0..<side {for x in 0..<side where bytes[(y*side+x)*4]==60 {
  let p=local(.init(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5));outlineValues[y*side+x]=p.x<205 ? 0.95:0.35
 }}
 let outlineBody=fragment(CGRect(x:197,y:140,width:40,height:96),30,bytes,outlineValues)
 let outlineTerminal=fragment(CGRect(x:197,y:246,width:40,height:50),31,bytes,outlineValues)
 let outlineMap=NativeMainEnsembleOCRProbability.Sample(sourceWidth:side,sourceHeight:side,resizedWidth:side,resizedHeight:side,
  region:CGRect(x:0,y:0,width:side,height:side),width:side,height:side,values:outlineValues)
 let outlineColumns=try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:[outlineBody,outlineTerminal],existing:[outlineBody.polygon,outlineTerminal.polygon],layout:terminalLayout,frame:frame,probability:outlineMap)
 check(outlineColumns.count==1,"low-map source stroke vetoed independent private roots at \(degree)")
 if let p=outlineColumns.first {check(p.score>=0.6,"private stroke confidence was not retained at \(degree)")}
 let sharedOutline=shared(outlineTerminal,32)
 check(try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:[outlineBody,sharedOutline],existing:[outlineBody.polygon,sharedOutline.polygon],layout:terminalLayout,frame:frame,probability:outlineMap).isEmpty,"one private owner certified low-map stroke at \(degree)")
 func exclusivePair(_ box:NativeCoreMLDetectionBox,_ peerRect:CGRect,_ index:Int)->(candidate:NativeCoreMLDetectionBox,peer:NativeCoreMLDetectionBox) {
  let e=box.detectorSeedEvidence!,peerID="competitor-\(index)"
  let candidates=e.components.map { component -> NativeOCRDetectorSeedEvidence.Candidate in
   var touched=0
   for run in component.runs {for x in run.x..<(run.x+run.count) {
    if peerRect.contains(local(.init(x:CGFloat(x)+0.5,y:CGFloat(run.y)+0.5))) {touched+=1}
   }}
   return .init(component:component,competingOwnerIDs:[peerID],outsideCompetingCells:[component.pixelCount-touched])
  }
  let evidence=NativeOCRDetectorSeedEvidence(ownerID:"exclusive-\(index)",parentBoxIndex:index,provenance:e.provenance,threshold:e.threshold,mapOriginX:e.mapOriginX,mapOriginY:e.mapOriginY,mapFullWidth:e.mapFullWidth,mapFullHeight:e.mapFullHeight,sourceWidth:e.sourceWidth,sourceHeight:e.sourceHeight,components:[],ownershipVersion:2,completeCCScan:true,ambiguousComponents:[],candidateComponents:candidates)
  let peerEvidence=NativeOCRDetectorSeedEvidence(ownerID:peerID,parentBoxIndex:index+1,provenance:e.provenance,threshold:e.threshold,mapOriginX:e.mapOriginX,mapOriginY:e.mapOriginY,mapFullWidth:e.mapFullWidth,mapFullHeight:e.mapFullHeight,sourceWidth:e.sourceWidth,sourceHeight:e.sourceHeight,components:[],ownershipVersion:2,completeCCScan:true,ambiguousComponents:e.components,candidateComponents:[])
  return (.init(polygon:box.polygon,score:box.score,detectorSeedEvidence:evidence),.init(polygon:quad(peerRect),score:0.5,detectorSeedEvidence:peerEvidence))
 }
 let exclusive=exclusivePair(fragments[1],CGRect(x:229,y:246,width:16,height:96),100)
 let exclusiveBoxes=[fragments[0],exclusive.candidate,exclusive.peer]
 let exclusiveColumns=try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:exclusiveBoxes,existing:exclusiveBoxes.map(\.polygon),layout:fragmentLayout,frame:frame,probability:map)
 check(exclusiveColumns.count==1,"measured exclusive cells did not support weak RF lane at \(degree)")
 // Paragraph height is not this column's required height. A complete short
 // column can use private plus independently exclusive original cells, while
 // stronger effects and absent competitor geometry still veto it.
 var paragraphScope=NativeRFDETRLayoutPrimitive(queryID:1014,semanticClass:.text,confidence:0.7,
  sourceBounds:NativeOCRDirectionGeometry.bounds(quad(CGRect(x:185,y:100,width:80,height:350))))
 paragraphScope.supportPolygon=quad(CGRect(x:185,y:100,width:80,height:350))
 let strongBridgeBody=NativeCoreMLDetectionBox(polygon:fragments[0].polygon,score:0.85,
  detectorSeedEvidence:fragments[0].detectorSeedEvidence)
 let shortColumnBoxes=[strongBridgeBody,exclusive.candidate,exclusive.peer]
 let paragraphLayout=NativeRFDETRLayoutResult(sourceWidth:side,sourceHeight:side,primitives:[paragraphScope])
 let shortColumn=try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:shortColumnBoxes,
  existing:shortColumnBoxes.map(\.polygon),layout:paragraphLayout,frame:frame,probability:map)
 check(shortColumn.contains { b in
  let r=NativeOCRDirectionGeometry.bounds(b.polygon.map(local));return r.minY<150 && r.maxY>333 && r.width<55
 },"short private column was tied to the whole paragraph height at \(degree)")
 check(try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:[strongBridgeBody,exclusive.candidate],
  existing:[strongBridgeBody.polygon,exclusive.candidate.polygon],layout:paragraphLayout,frame:frame,probability:map).isEmpty,
  "unknown competitor geometry granted a paragraph bridge at \(degree)")
 let unrootedBridge=[shared(strongBridgeBody,420),exclusive.candidate,exclusive.peer]
 check(try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:unrootedBridge,existing:unrootedBridge.map(\.polygon),
  layout:paragraphLayout,frame:frame,probability:map).isEmpty,"an exclusive candidate alone acquired a new complete column at \(degree)")
 for effectScore:Float in [0.6,0.85] {
  var effect=NativeRFDETRLayoutPrimitive(queryID:1015,semanticClass:.soundEffect,confidence:effectScore,
   sourceBounds:NativeOCRDirectionGeometry.bounds(quad(CGRect(x:190,y:130,width:60,height:220))))
  effect.supportPolygon=quad(CGRect(x:190,y:130,width:60,height:220))
  let proposed=try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:shortColumnBoxes,
   existing:shortColumnBoxes.map(\.polygon),layout:.init(sourceWidth:side,sourceHeight:side,primitives:[paragraphScope,effect]),
   frame:frame,probability:map)
  if effectScore>0.7 {check(proposed.isEmpty,"a dominant RF effect was overridden by a column bridge at \(degree)")}
  else {check(!proposed.isEmpty,"a weaker overlapping effect erased stronger text with private column roots at \(degree)")}
 }
 // A shared paragraph and matching colour cannot bridge a genuinely blank
 // word-sized interval. Both original fragments remain valid observations.
 do {
 var gapBytes=[UInt8](repeating:255,count:side*side*4),gapValues=[Float](repeating:0.1,count:side*side)
 for y in 0..<side {for x in 0..<side {
  let p=local(.init(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5)),k=(y*side+x)*4
  for n in 0..<3 {
   if CGRect(x:201,y:148+CGFloat(n*32),width:32,height:22).contains(p) ||
      CGRect(x:201,y:355+CGFloat(n*32),width:32,height:22).contains(p) {
    gapBytes[k]=60;gapBytes[k+1]=70;gapBytes[k+2]=140;gapValues[y*side+x]=0.95
   }
  }
 }}
 let gapFirst=fragment(CGRect(x:197,y:140,width:40,height:96),430,gapBytes)
 let gapStrong=NativeCoreMLDetectionBox(polygon:gapFirst.polygon,score:0.85,detectorSeedEvidence:gapFirst.detectorSeedEvidence)
 let gapTail=fragment(CGRect(x:197,y:345,width:40,height:100),431,gapBytes)
 let gapExclusive=exclusivePair(gapTail,CGRect(x:229,y:345,width:16,height:100),432)
 let gapBoxes=[gapStrong,gapExclusive.candidate,gapExclusive.peer]
 let gapMap=NativeMainEnsembleOCRProbability.Sample(sourceWidth:side,sourceHeight:side,resizedWidth:side,resizedHeight:side,
  region:CGRect(x:0,y:0,width:side,height:side),width:side,height:side,values:gapValues)
 check(try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:gapBoxes,existing:gapBoxes.map(\.polygon),
  layout:paragraphLayout,frame:NativeOCRRGBAFrame(width:side,height:side,bytes:gapBytes)!,probability:gapMap).isEmpty,
  "same-colour words merged across blank source paper at \(degree)")
 }
 var neighbourBytes=bytes,neighbourValues=values
 for y in 0..<side {for x in 0..<side {
  let point=local(.init(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5))
  var inGlyphRow=false
  for n in 0..<4 {let top=CGFloat(148+n*52);if point.y>=top && point.y<top+34 {inGlyphRow=true}}
  if point.x>=174 && point.x<191 && inGlyphRow {
   let offset=(y*side+x)*4;neighbourBytes[offset]=60;neighbourBytes[offset+1]=70;neighbourBytes[offset+2]=140;neighbourValues[y*side+x]=0.95
  }
 }}
 let paddedBody=NativeCoreMLDetectionBox(polygon:quad(CGRect(x:189,y:130,width:56,height:116)),score:0.7,detectorSeedEvidence:fragments[0].detectorSeedEvidence)
 let paddedTail=NativeCoreMLDetectionBox(polygon:quad(CGRect(x:189,y:246,width:56,height:116)),score:0.7,detectorSeedEvidence:fragments[1].detectorSeedEvidence)
 let paddedExclusive=exclusivePair(paddedTail,CGRect(x:229,y:246,width:16,height:116),300)
 let neighbourBoxes=[paddedBody,paddedExclusive.candidate,paddedExclusive.peer]
 var neighbourScope=NativeRFDETRLayoutPrimitive(queryID:1002,semanticClass:.text,confidence:0.35,
  sourceBounds:NativeOCRDirectionGeometry.bounds(quad(CGRect(x:185,y:130,width:65,height:232))))
 neighbourScope.supportPolygon=quad(CGRect(x:185,y:130,width:65,height:232))
 let neighbourLayout=NativeRFDETRLayoutResult(sourceWidth:side,sourceHeight:side,primitives:[neighbourScope])
 let neighbourMap=NativeMainEnsembleOCRProbability.Sample(sourceWidth:side,sourceHeight:side,resizedWidth:side,resizedHeight:side,
  region:CGRect(x:0,y:0,width:side,height:side),width:side,height:side,values:neighbourValues)
 let neighbourColumns=try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:neighbourBoxes,existing:neighbourBoxes.map(\.polygon),layout:neighbourLayout,
  frame:NativeOCRRGBAFrame(width:side,height:side,bytes:neighbourBytes)!,probability:neighbourMap)
 check(neighbourColumns.contains { box in
  let b=NativeOCRDirectionGeometry.bounds(box.polygon.map(local));return b.minX>195 && b.width<50 && b.height>180
 },"open adjacent same-colour band suppressed the independently rooted body at \(degree)")
 check(neighbourColumns.allSatisfy { box in NativeOCRDirectionGeometry.bounds(box.polygon.map(local)).minX>195 },
  "neighbouring edge ink leaked into the rooted body at \(degree)")
 var continuedBytes=bytes,continuedValues=values
 for y in 0..<side {for x in 0..<side {
  if CGRect(x:201,y:357,width:32,height:34).contains(local(.init(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5))) {
   let offset=(y*side+x)*4;continuedBytes[offset]=60;continuedBytes[offset+1]=70;continuedBytes[offset+2]=140;continuedValues[y*side+x]=0.95
  }
 }}
 let tail=fragment(CGRect(x:197,y:350,width:40,height:50),200,continuedBytes)
 let strongTail=NativeCoreMLDetectionBox(polygon:tail.polygon,score:0.9,detectorSeedEvidence:tail.detectorSeedEvidence)
 let continuedBoxes=exclusiveBoxes+[strongTail]
 let continuedMap=NativeMainEnsembleOCRProbability.Sample(sourceWidth:side,sourceHeight:side,resizedWidth:side,resizedHeight:side,
  region:CGRect(x:0,y:0,width:side,height:side),width:side,height:side,values:continuedValues)
 let ambiguousContinuation=shared(strongTail,900)
 check(try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:fragments+[ambiguousContinuation],
  existing:[quad(CGRect(x:182,y:110,width:70,height:300))],layout:fragmentLayout,
  frame:NativeOCRRGBAFrame(width:side,height:side,bytes:continuedBytes)!,probability:continuedMap).isEmpty,
  "uncertain detector-owned continuation was cut by a narrowing crop at \(degree)")
 var gapBytes=continuedBytes,gapValues=continuedValues
 for y in 0..<side {for x in 0..<side {
  if CGRect(x:195,y:240,width:45,height:60).contains(local(.init(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5))) {
   let p=(y*side+x)*4;gapBytes[p]=250;gapBytes[p+1]=250;gapBytes[p+2]=250;gapValues[y*side+x]=0.1
  }
 }}
 let gapBody=fragment(CGRect(x:197,y:130,width:40,height:110),201,gapBytes)
 let gapTail=fragment(CGRect(x:197,y:300,width:40,height:100),202,gapBytes)
 let gapBoxes=[NativeCoreMLDetectionBox(polygon:gapBody.polygon,score:0.55,detectorSeedEvidence:gapBody.detectorSeedEvidence),
  NativeCoreMLDetectionBox(polygon:gapTail.polygon,score:0.8,detectorSeedEvidence:gapTail.detectorSeedEvidence)]
 var gapScope=NativeRFDETRLayoutPrimitive(queryID:1001,semanticClass:.text,confidence:0.35,
  sourceBounds:NativeOCRDirectionGeometry.bounds(quad(CGRect(x:190,y:125,width:60,height:280))))
 gapScope.supportPolygon=quad(CGRect(x:190,y:125,width:60,height:280))
 let gapLayout=NativeRFDETRLayoutResult(sourceWidth:side,sourceHeight:side,primitives:[gapScope])
 let gapMap=NativeMainEnsembleOCRProbability.Sample(sourceWidth:side,sourceHeight:side,resizedWidth:side,resizedHeight:side,
  region:CGRect(x:0,y:0,width:side,height:side),width:side,height:side,values:gapValues)
 check(try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:gapBoxes,existing:gapBoxes.map(\.polygon),layout:gapLayout,
  frame:NativeOCRRGBAFrame(width:side,height:side,bytes:gapBytes)!,probability:gapMap).isEmpty,
  "measured private chain crossed a wide source-pixel gap at \(degree)")
 let continued=try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:continuedBoxes,existing:continuedBoxes.map(\.polygon),layout:fragmentLayout,
  frame:NativeOCRRGBAFrame(width:side,height:side,bytes:continuedBytes)!,probability:continuedMap)
 check(continued.contains { box in
  let r=NativeOCRDirectionGeometry.bounds(box.polygon.map(local))
  return r.minY<150 && r.maxY>=390
 },"partial RF scope did not recover the complete detected continuation at \(degree)")
 var balloon=NativeRFDETRLayoutPrimitive(queryID:999,semanticClass:.balloon,confidence:0.95,
  sourceBounds:NativeOCRDirectionGeometry.bounds(quad(CGRect(x:170,y:120,width:90,height:225))))
 balloon.supportPolygon=quad(CGRect(x:170,y:120,width:90,height:225))
 let boundedLayout=NativeRFDETRLayoutResult(sourceWidth:side,sourceHeight:side,primitives:fragmentLayout.primitives+[balloon])
 check(try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:continuedBoxes,existing:continuedBoxes.map(\.polygon),layout:boundedLayout,
  frame:NativeOCRRGBAFrame(width:side,height:side,bytes:continuedBytes)!,probability:continuedMap).isEmpty,
  "continuation crossed the containing balloon at \(degree)")
 let error=CGFloat(5.5)*CGFloat.pi/180
 let skewed=NativeOCRDirectionGeometry.corners(CGRect(x:196,y:130,width:42,height:116)).map { p -> CGPoint in
  let x=p.x-217,y=p.y-188
  return world(.init(x:217+x*cos(error)-y*sin(error),y:188+x*sin(error)+y*cos(error)))
 }
 let skewedBody=NativeCoreMLDetectionBox(polygon:skewed,score:fragments[0].score,detectorSeedEvidence:fragments[0].detectorSeedEvidence)
 var skewScope=NativeRFDETRLayoutPrimitive(queryID:11,semanticClass:.text,confidence:0.35,sourceBounds:NativeOCRDirectionGeometry.bounds(quad(CGRect(x:185,y:125,width:64,height:221))))
 skewScope.supportPolygon=quad(CGRect(x:185,y:125,width:64,height:221))
 let skewBoxes=[skewedBody,exclusive.candidate,exclusive.peer]
 let aligned=try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:skewBoxes,existing:skewBoxes.map(\.polygon),layout:.init(sourceWidth:side,sourceHeight:side,primitives:[skewScope]),frame:frame,probability:map)
 check(aligned.count==1,"exclusive two-fragment axis recovery missing at \(degree)")
 if let p=aligned.first {let b=NativeOCRDirectionGeometry.bounds(p.polygon.map{local($0)});check(b.width<50 && b.height>180,"word-edge skew distorted whole-column crop at \(degree)")}
 check(try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:[fragments[0],exclusive.candidate],existing:[fragments[0].polygon,exclusive.candidate.polygon],layout:fragmentLayout,frame:frame,probability:map).isEmpty,"missing competitor geometry supplied exclusive roots at \(degree)")
 let coveringPeer=NativeCoreMLDetectionBox(polygon:fragments[1].polygon,score:exclusive.peer.score,detectorSeedEvidence:exclusive.peer.detectorSeedEvidence)
 check(try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:[fragments[0],exclusive.candidate,coveringPeer],existing:[fragments[0].polygon,exclusive.candidate.polygon,coveringPeer.polygon],layout:fragmentLayout,frame:frame,probability:map).isEmpty,"metadata counter overrode fully covered measured cells at \(degree)")
 let outlineTail=fragment(CGRect(x:197,y:246,width:40,height:96),102,bytes,outlineValues)
 let exclusiveOutline=exclusivePair(outlineTail,CGRect(x:203,y:246,width:5,height:96),104)
 let exclusiveOutlineBoxes=[outlineBody,exclusiveOutline.candidate,exclusiveOutline.peer]
 let exclusiveOutlineColumns=try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:exclusiveOutlineBoxes,existing:exclusiveOutlineBoxes.map(\.polygon),layout:fragmentLayout,frame:frame,probability:outlineMap)
 check(exclusiveOutlineColumns.count==1,"measured exclusive roots lost low-map source stroke at \(degree)")
 if let p=exclusiveOutlineColumns.first {check(p.score>=0.6,"exclusive root score was not retained at \(degree)")}
 let compactPieces=[fragment(CGRect(x:197,y:140,width:40,height:50),4),fragment(CGRect(x:197,y:193,width:40,height:50),5),fragments[1]]
 var chainScope=NativeRFDETRLayoutPrimitive(queryID:9,semanticClass:.text,confidence:0.9,sourceBounds:fragmentScope.sourceBounds)
 chainScope.supportPolygon=fragmentScope.supportPolygon
 let chain=try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:compactPieces,existing:compactPieces.map(\.polygon),layout:.init(sourceWidth:side,sourceHeight:side,primitives:[chainScope]),frame:frame,probability:map)
 check(chain.count==1,"strong RF lost compact three-owner chain at \(degree): \(chain.count)")
 let varyingRects=[CGRect(x:243,y:100,width:14,height:60),CGRect(x:235,y:210,width:30,height:100),CGRect(x:222,y:340,width:56,height:120)]
 var varyingBytes=[UInt8](repeating:255,count:side*side*4),varyingValues=[Float](repeating:0,count:side*side)
 let varyingScopeRect=CGRect(x:218,y:95,width:64,height:370)
 for y in 0..<side {for x in 0..<side {
  let p=local(.init(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5)),offset=(y*side+x)*4
  if varyingScopeRect.contains(p){varyingValues[y*side+x]=0.1}
  for r in varyingRects {for j in 0..<3 {
   let pitch=(r.height-10)/3
   if CGRect(x:r.minX+2,y:r.minY+5+CGFloat(j)*pitch,width:r.width-4,height:pitch*0.7).contains(p) {
    varyingBytes[offset]=60;varyingBytes[offset+1]=70;varyingBytes[offset+2]=140;varyingValues[y*side+x]=0.95
   }
  }}
 }}
 let varyingBoxes=varyingRects.enumerated().map{fragment($0.element,20+$0.offset,varyingBytes)}
 let varyingMap=NativeMainEnsembleOCRProbability.Sample(sourceWidth:side,sourceHeight:side,resizedWidth:side,resizedHeight:side,
  region:CGRect(x:0,y:0,width:side,height:side),width:side,height:side,values:varyingValues)
 var varyingScope=NativeRFDETRLayoutPrimitive(queryID:10,semanticClass:.text,confidence:0.35,sourceBounds:NativeOCRDirectionGeometry.bounds(quad(varyingScopeRect)))
 varyingScope.supportPolygon=quad(varyingScopeRect)
 let varyingColumns=try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:varyingBoxes,existing:varyingBoxes.map(\.polygon),layout:.init(sourceWidth:side,sourceHeight:side,primitives:[varyingScope]),frame:NativeOCRRGBAFrame(width:side,height:side,bytes:varyingBytes)!,probability:varyingMap)
 check(varyingColumns.count==1,"private varying-size lane was not recovered at \(degree): \(varyingColumns.count)")
 if let p=varyingColumns.first {let b=NativeOCRDirectionGeometry.bounds(p.polygon.map{local($0)});check(b.width>=48 && b.width<72 && b.height>330,"varying-size lane lost support at \(degree)")}
 // Distant centres in another lane must not rotate a complete private chain.
 let consensusRects=[CGRect(x:230,y:100,width:40,height:100),CGRect(x:241,y:205,width:18,height:30),
  CGRect(x:230,y:300,width:40,height:120),CGRect(x:190,y:95,width:30,height:80),CGRect(x:190,y:340,width:30,height:80)]
 var consensusBytes=[UInt8](repeating:255,count:side*side*4),consensusValues=[Float](repeating:0.1,count:side*side)
 for y in 0..<side {for x in 0..<side {
  let p=local(.init(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5)),k=(y*side+x)*4
  for r in consensusRects {for j in 0..<3 {
   let pitch=(r.height-10)/3
   if CGRect(x:r.minX+2,y:r.minY+5+CGFloat(j)*pitch,width:r.width-4,height:pitch*0.7).contains(p) {
    consensusBytes[k]=60;consensusBytes[k+1]=70;consensusBytes[k+2]=140;consensusValues[y*side+x]=0.95
   }
  }}
 }}
 let consensusBoxes=consensusRects.enumerated().map { entry -> NativeCoreMLDetectionBox in
  let b=fragment(entry.element,150+entry.offset,consensusBytes)
  return .init(polygon:b.polygon,score:0.85,detectorSeedEvidence:b.detectorSeedEvidence)
 }
 let consensusMap=NativeMainEnsembleOCRProbability.Sample(sourceWidth:side,sourceHeight:side,resizedWidth:side,resizedHeight:side,
  region:CGRect(x:0,y:0,width:side,height:side),width:side,height:side,values:consensusValues)
 var consensusScope=NativeRFDETRLayoutPrimitive(queryID:12,semanticClass:.text,confidence:0.65,
  sourceBounds:NativeOCRDirectionGeometry.bounds(quad(CGRect(x:160,y:90,width:200,height:340))))
 consensusScope.supportPolygon=quad(CGRect(x:160,y:90,width:200,height:340))
 let consensusLayout=NativeRFDETRLayoutResult(sourceWidth:side,sourceHeight:side,primitives:[consensusScope])
 let consensus=try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:consensusBoxes,existing:consensusBoxes.map(\.polygon),layout:consensusLayout,
  frame:NativeOCRRGBAFrame(width:side,height:side,bytes:consensusBytes)!,probability:consensusMap)
 check(consensus.contains { p in
  let b=NativeOCRDirectionGeometry.bounds(p.polygon.map(local))
  // The final painted body ends at404; the detector's box extends to420.
  return abs(b.midX-250)<8 && b.width<60 && b.minY<110 && b.maxY>403
 },"neighbouring-lane centres rotated a complete private chain at \(degree)")
 check(consensus.allSatisfy{NativeOCRDirectionGeometry.bounds($0.polygon.map(local)).width<75},
  "consensus borrowed an adjacent lane at \(degree)")
 for p in consensus {
  let q=p.polygon.map(local),b=NativeOCRDirectionGeometry.bounds(q)
  if abs(b.midX-250)<8,b.height>300 {
   check(q[3].y>q[0].y,"PCA reversed the trusted recognition order at \(degree)")
  }
 }
 let weakConsensus=consensusBoxes.map{NativeCoreMLDetectionBox(polygon:$0.polygon,score:0.7,detectorSeedEvidence:$0.detectorSeedEvidence)}
 check(try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:weakConsensus,existing:weakConsensus.map(\.polygon),layout:consensusLayout,
  frame:NativeOCRRGBAFrame(width:side,height:side,bytes:consensusBytes)!,probability:consensusMap).isEmpty,
  "broad scale chain ignored private detector confidence at \(degree)")
 var splitPalette=bytes
 for y in 0..<side {for x in 0..<side {
  let offset=(y*side+x)*4,p=local(.init(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5))
  if p.y>=246,splitPalette[offset]==60 {splitPalette[offset]=150;splitPalette[offset+1]=20;splitPalette[offset+2]=30}
 }}
 check(try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:fragments,existing:fragments.map(\.polygon),layout:fragmentLayout,
  frame:NativeOCRRGBAFrame(width:side,height:side,bytes:splitPalette)!,probability:map).isEmpty,"one palette fragment masqueraded as the full lane at \(degree)")
 var partial=NativeRFDETRLayoutPrimitive(queryID:7,semanticClass:.text,confidence:0.9,sourceBounds:NativeOCRDirectionGeometry.bounds(quad(CGRect(x:208,y:138,width:20,height:208))))
 partial.supportPolygon=quad(CGRect(x:208,y:138,width:20,height:208))
 check(try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:fragments,existing:fragments.map(\.polygon),layout:.init(sourceWidth:side,sourceHeight:side,primitives:[partial]),frame:frame,probability:map).isEmpty,"insufficient actual fragment coverage borrowed at \(degree)")
 var unreliable=NativeRFDETRLayoutPrimitive(queryID:6,semanticClass:.text,confidence:0.2,sourceBounds:fragmentScope.sourceBounds)
 unreliable.supportPolygon=fragmentScope.supportPolygon
 check(try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:fragments,existing:fragments.map(\.polygon),layout:.init(sourceWidth:side,sourceHeight:side,primitives:[unreliable]),frame:frame,probability:map).isEmpty,"unreliable RF certified fragment lane at \(degree)")
 setenv("AIDOKU_OCR_SOURCE_INK_PARTITIONS","0",1)

 setenv("AIDOKU_OCR_INK_ANNOTATION_BANDS","1",1)
 var annotatedBytes=bytes,accentBytes=bytes
 for y in 0..<side {for x in 0..<side {
  let p=local(.init(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5)),offset=(y*side+x)*4
  var ruby=false
  for row in 0..<16 {if CGRect(x:239,y:148+row*12,width:5,height:8).contains(p){ruby=true}}
  if ruby {annotatedBytes[offset]=60;annotatedBytes[offset+1]=70;annotatedBytes[offset+2]=140}
  if CGRect(x:239,y:148,width:5,height:8).contains(p){accentBytes[offset]=60;accentBytes[offset+1]=70;accentBytes[offset+2]=140}
 }}
 let annotated=try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:[box],existing:[polygon],layout:layout,
  frame:NativeOCRRGBAFrame(width:side,height:side,bytes:annotatedBytes)!,probability:map)
 check(annotated.count==2,"side reading created an extra column at \(degree)")
 let annotatedBounds=annotated.map{NativeOCRDirectionGeometry.bounds($0.polygon.map{local($0)})}.sorted{$0.minX<$1.minX}
 if annotatedBounds.count==2 {check(annotatedBounds[0].maxX<239 && annotatedBounds[1].minX>244,"small side reading entered body crop at \(degree): \(annotatedBounds)")}
 let accents=try NativeOCRRFPrimaryEnsemble.sourceInkColumns(boxes:[box],existing:[polygon],layout:layout,
  frame:NativeOCRRGBAFrame(width:side,height:side,bytes:accentBytes)!,probability:map)
 let accentBounds=accents.map{NativeOCRDirectionGeometry.bounds($0.polygon.map{local($0)})}.sorted{$0.minX<$1.minX}
 check(accentBounds.count==2 && accentBounds[0].maxX>=243.5,"detached full-size glyph accent mistaken for side reading at \(degree)")
 setenv("AIDOKU_OCR_INK_ANNOTATION_BANDS","0",1)
}
print("PASS \(checks) source-ink column checks /24angles")
'''
cache=root/'build/source-ink-columns-smoke';binary=cache/'checks';started=time.monotonic();compile_replay(cache,[],ns['stubs']+ns['production']+extra+checks,binary);print('Compile seconds',round(time.monotonic()-started,2),flush=True);subprocess.run([str(binary)],check=True)
