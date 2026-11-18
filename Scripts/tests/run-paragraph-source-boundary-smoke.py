"""Production paragraph scope/contested-inline boundaries in every writing direction."""
from pathlib import Path
import subprocess,sys,time
root=Path(__file__).resolve().parents[2];base=root/'Scripts/tests/run-paragraph-fragment-pipeline-smoke.py';ns={'__file__':str(base)};exec(compile(base.read_text().split('tests =',1)[0],str(base),'exec'),ns)
sys.path.insert(0,str(root/'Scripts'));from swift_replay_cache import compile_replay,write_if_changed
translation=root/'Aidoku/Core/Translation';ocr=translation/'NativeEngine/OCR'
wrapper=r'''
extension NativeParagraphFragmentGrouping {
 static func sourceBoundaryChecks()->Int {
  var checks=0
  func require(_ ok:Bool,_ message:String){if !ok {fputs("FAILED: \(message)\n",stderr);exit(1)};checks+=1}
  for scale:CGFloat in [0.5,1,2] {for degree in stride(from:0.0,to:360,by:15) {
   let size=4096,angle=CGFloat(degree)*CGFloat.pi/180
   let t=CGAffineTransform(scaleX:scale,y:scale).rotated(by:angle).concatenating(.init(translationX:2000,y:2000))
   func quad(_ r:CGRect)->[CGPoint] {
    [CGPoint(x:r.minX,y:r.minY),CGPoint(x:r.maxX,y:r.minY),CGPoint(x:r.maxX,y:r.maxY),CGPoint(x:r.minX,y:r.maxY)].map {$0.applying(t)}
   }
   func component(_ r:CGRect,_ hole:CGRect?=nil)->NativeOCRDetectorSeedEvidence.Component {
    let b=pointBounds(quad(r));var runs:[NativeOCRDetectorSeedEvidence.Run]=[]
    for y in Int(floor(b.minY))..<Int(ceil(b.maxY)) {
     var start:Int?,end=0
     for x in Int(floor(b.minX))..<Int(ceil(b.maxX)) {
      let local=CGPoint(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5).applying(t.inverted())
      if r.contains(local) && !(hole?.contains(local) ?? false) {if start==nil {start=x};end=x+1}
      else if let initial=start {runs.append(.init(y:y,x:initial,count:end-initial));start=nil}
     }
     if let start {runs.append(.init(y:y,x:start,count:end-start))}
    }
    return .init(seed:runs[0].y*size+runs[0].x,pixelCount:runs.reduce(0){$0+$1.count},meanProbability:0.99,runs:runs)
   }
   func evidence(_ id:Int,_ parts:[NativeOCRDetectorSeedEvidence.Component],_ candidates:[NativeOCRDetectorSeedEvidence.Candidate]=[])->NativeOCRDetectorSeedEvidence {
    .init(ownerID:"boundary-owner-\(id)",parentBoxIndex:id,provenance:"db-complete-cc-candidates-v2",threshold:0.9,
     mapOriginX:0,mapOriginY:0,mapFullWidth:size,mapFullHeight:size,sourceWidth:size,sourceHeight:size,
     components:parts,ownershipVersion:2,completeCCScan:true,ambiguousComponents:[],candidateComponents:candidates)
   }
   func line(_ r:CGRect,_ word:String,_ id:Int)->NativeCoreMLOCRLine {
    .init(polygon:quad(r),text:word,score:0.99,orientation:.vertical,detectorSeedEvidence:[evidence(id,[component(r)])])
   }
   func scope(_ id:Int,_ r:CGRect,_ confidence:Double)->TextScope {
    let b=pointBounds(quad(r)).applying(.init(scaleX:1/CGFloat(size),y:1/CGFloat(size)))
    return .init(owner:id,box:b,confidence:confidence)
   }
   func region(_ lines:[NativeCoreMLOCRLine],_ ids:Set<Int>,_ name:String)->ReaderTranslationRegion {
    let table=lines[0].acceptedSource.membership!.table
    let b=pointBounds(ids.flatMap {table.packets[$0].polygon}).applying(.init(scaleX:1/CGFloat(size),y:1/CGFloat(size)))
    var r=ReaderTranslationRegion(id:name,rect:b,source:ids.sorted().map {table.packets[$0].text}.joined())
    r.confidence=0.99;r.polygon=[CGPoint(x:b.minX,y:b.minY),CGPoint(x:b.maxX,y:b.minY),CGPoint(x:b.maxX,y:b.maxY),CGPoint(x:b.minX,y:b.maxY)]
    r.acceptedSource = .init(.init(table:table,body:ids,readings:[],unknownDedup:[],hasUntrackedInputs:false))
    r.detectorSeedEvidence=NativeOCRDetectorSeedEvidence.preservingUnion(ids.sorted().map {table.packets[$0].detectorSeedEvidence});return r
   }
   let columns=[line(.init(x:100,y:100,width:28,height:170),"甲甲甲甲甲甲",0),
    line(.init(x:100,y:330,width:28,height:70),"乙乙乙",1),
    line(.init(x:145,y:100,width:28,height:320),"丙丙丙丙丙丙丙丙丙丙丙",2),
    line(.init(x:55,y:160,width:28,height:120),"丁丁丁丁",3),
    line(.init(x:190,y:250,width:28,height:170),"戊戊戊戊戊戊",4),
    line(.init(x:190,y:130,width:28,height:60),"己己",5)]
   let bound=NativeOCRAcceptedSource.bindingPrimary(columns,width:size,height:size)
   let source=[region(bound,[0,3],"upper"),region(bound,[1,2,4],"body"),region(bound,[5],"head")]
   let nested=[scope(1,.init(x:40,y:85,width:190,height:210),0.7),scope(2,.init(x:30,y:75,width:210,height:370),0.6)]
   let edges=supportedParagraphNeighbors(source.map {observingSource($0)},scopes:nested)
   require(edges.contains {Set([$0.first,$0.second])==Set([0,1])},"nested RF winner split at \(degree),scale\(scale)")
   let separated=[scope(1,.init(x:40,y:85,width:92,height:210),0.7),scope(2,.init(x:138,y:75,width:102,height:370),0.6)]
   let independent=supportedParagraphNeighbors(source.map {observingSource($0)},scopes:separated)
   require(!independent.contains {Set([$0.first,$0.second])==Set([0,1])},"non-nested queries substituted for shared context at \(degree),scale\(scale)")
   let table=bound[0].acceptedSource.membership!.table
   let head=projectedPacketInventory([5],table:table)!,body=projectedPacketInventory([1,2,4],table:table)!
   let frame=sourceAlignmentFrame(head+body,table:table)!
   require(corroboratedInterruptedColumn(head,host:body,table:table,frame:frame,glyph:28*scale/CGFloat(size)),"parallel column did not witness interrupted edge at \(degree),scale\(scale)")
   let noBridge=projectedPacketInventory([1,4],table:table)!
   require(!corroboratedInterruptedColumn(head,host:noBridge,table:table,frame:frame,glyph:28*scale/CGFloat(size)),"missing parallel column fabricated a witness at \(degree),scale\(scale)")
   let nestedLines=NativeOCRAcceptedSource.bindingPrimary([
    line(.init(x:145,y:100,width:28,height:150),"甲甲甲甲甲",0),
    line(.init(x:145,y:270,width:28,height:150),"乙乙乙乙乙",1),
    line(.init(x:190,y:250,width:28,height:70),"丙丙丙",2),
    line(.init(x:190,y:340,width:28,height:80),"丁丁丁",3)],width:size,height:size)
   let nt=nestedLines[0].acceptedSource.membership!.table
   let child=projectedPacketInventory([2,3],table:nt)!,carrier=projectedPacketInventory([0,1],table:nt)!
   let nf=sourceAlignmentFrame(child+carrier,table:nt)!
   let enclosing=[scope(30,.init(x:135,y:90,width:95,height:345),0.7)]
   require(corroboratedNestedColumn(child,host:carrier,table:nt,frame:nf,scopes:enclosing),"nested fragmented column lost its carrier at \(degree),scale\(scale)")
   let separateOwners=[scope(30,.init(x:135,y:90,width:40,height:345),0.7),scope(31,.init(x:185,y:240,width:40,height:190),0.7)]
   require(!corroboratedNestedColumn(child,host:carrier,table:nt,frame:nf,scopes:separateOwners),"different RF owners certified nested continuation at \(degree),scale\(scale)")
   require(!corroboratedNestedColumn(carrier,host:child,table:nt,frame:nf,scopes:enclosing),"incomplete carrier certified a larger column at \(degree),scale\(scale)")
   let rects:[CGRect]=[.init(x:400,y:100,width:28,height:180),.init(x:445,y:100,width:28,height:180),.init(x:200,y:300,width:28,height:180),.init(x:245,y:300,width:28,height:180),.init(x:400,y:600,width:28,height:180),.init(x:445,y:600,width:28,height:180)]
   let words=["甲甲甲甲甲甲","乙乙乙乙乙乙","丙丙丙丙丙丙","丁丁丁丁丁丁","戊戊戊戊戊戊","己己己己己己"]
   let baseLines=zip(rects,words).enumerated().map {line($0.element.0,$0.element.1,$0.offset)}
   let cell=component(.init(x:405,y:120,width:14,height:24))
   var anchorEvidence=evidence(0,[component(rects[0],.init(x:405,y:120,width:14,height:24))]);anchorEvidence.ambiguousComponents=[cell]
   let host=NativeCoreMLOCRLine(polygon:quad(rects[0]),text:words[0],score:0.99,orientation:.vertical,detectorSeedEvidence:[anchorEvidence])
   var withHost=baseLines;withHost[0]=host
   let inlineRect=CGRect(x:405,y:120,width:14,height:24)
   let shared=NativeOCRDetectorSeedEvidence.Candidate(component:cell,competingOwnerIDs:["boundary-owner-0"],outsideCompetingCells:[1])
   let fragment=NativeCoreMLOCRLine(polygon:quad(inlineRect),text:"庚",score:0.99,orientation:.vertical,detectorSeedEvidence:[evidence(6,[],[shared])])
   let inputs=NativeOCRAcceptedSource.bindingPrimary(withHost+[fragment],width:size,height:size)
   let aggregate=region(inputs,Set(0..<7),"aggregate")
   let scopes=[scope(10,.init(x:390,y:90,width:95,height:200),0.9),scope(11,.init(x:190,y:290,width:95,height:200),0.9),scope(12,.init(x:390,y:590,width:95,height:200),0.9)]
   let observed=observingSource(aggregate)
   let split=separatedSupportedParagraphs(observed,scopes:scopes)
   let partition=Set(split.map {$0.region.acceptedSource.membership!.body})
   require(partition==Set([Set([0,1,6]),Set([2,3]),Set([4,5])]),"shared-cell inline fragment vetoed independent cohorts at \(degree),scale\(scale): \(partition)")
   let unsupported=NativeCoreMLOCRLine(polygon:quad(inlineRect),text:"庚",score:0.99,orientation:.vertical,detectorSeedEvidence:[evidence(6,[])])
   let noAnchor=NativeOCRAcceptedSource.bindingPrimary(withHost+[unsupported],width:size,height:size)
   require(separatedSupportedParagraphs(observingSource(region(noAnchor,Set(0..<7),"unanchored")),scopes:scopes).count==1,"unowned fragment invented an anchor at \(degree),scale\(scale)")
  }}
  return checks
 }
}
'''
cache=root/'build/paragraph-source-boundary-smoke';snapshot=cache/'production-snapshot';snapshot.mkdir(parents=True,exist_ok=True);sources=[]
for path in [ocr/(n+'.swift') for n in ['BrowserOCRSourceOrientation','NativeOCRDetectorSeedEvidence','NativeOCRSourceROIProbabilityEvidence','NativeOCRAcceptedSource']]+[translation/'NativeParagraphFragmentGrouping.swift',translation/'NativeParagraphFragmentGrouping+Pipeline.swift']:
 target=snapshot/path.name;write_if_changed(target,(path.read_text()+(wrapper if '+Pipeline' in path.name else '')).encode());sources.append(target)
main=ns['support']+'\nprint("PASS \\(NativeParagraphFragmentGrouping.sourceBoundaryChecks()) source-boundary checks / 24angles /3scales")\n';started=time.monotonic();binary=cache/'checks';compile_replay(cache,sources,main,binary);print('Compile seconds',round(time.monotonic()-started,2),flush=True);subprocess.run([str(binary)],check=True)
