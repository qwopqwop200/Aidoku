#!/usr/bin/env python3
"""Run the production earlier balloon-group merge, including its contour veto."""
from pathlib import Path
import subprocess
import sys
import tempfile
import time
r=Path(__file__).resolve().parents[2];t=r/'Aidoku/Core/Translation'
s=(t/'ReaderTranslationBalloonMerger.swift').read_text();a=s.index('    static func joinBalloonUnits(');a=s.rfind('    ///',0,a);b=s.index('    /// Within one balloon',a);s=s[:a]+s[b:]
e=(t/'ReaderTranslationEnclosedBackground.swift').read_text();a=e.index('    static func attachingBalloonInteriors(');b=e.index('    private struct Component {',a);e=e[:a]+e[b:]
rot=(t/'NativeEngine/Overlay/BrowserOverlayRotation.swift').read_text();a=rot.index('    static func geometry(');i=rot.index('{',a);depth=1;j=i+1
while depth:
 if rot[j]=='{':depth+=1
 if rot[j]=='}':depth-=1
 j+=1
rot='enum BrowserOverlayRotation { struct Geometry { let radians:CGFloat; let rect:CGRect; let panelRect:CGRect }\n'+rot[a:j]+'\n}'
region=(t/'ReaderTranslationService.swift').read_text();a=region.index('struct ReaderTranslationRegion:');b=region.index('    /// If translation',a);region=region[a:b]+'}\n';region=region.replace('    var translationReuseIdentity: NativeTranslationReuseIdentity?\n','').replace('    var balloonInterior: ReaderTranslationBalloonInterior?\n','')
# This pre-translation grouping harness omits caller-bound translation/title state.
# The production merge functions do not reference these fields. Title admission has
# its own dependency-complete host suite; omitting it here does not stub a merge gate.
if 'ReaderTranslationSourceOCRAlternative' in region:
    alternatives = (t / 'NativeEngine/OCR/NativeOCRMixedScriptColumnRecovery.swift').read_text()
    region = alternatives[alternatives.index('struct ReaderTranslationSourceOCRAlternative:'):] + region
h = r'''
func assertSourceFragmentsOnce(_ input:[ReaderTranslationRegion],_ output:[ReaderTranslationRegion]) {
 // Compare with the inventory before production merging, not two downstream copies of a reduced payload.
 for region in input {
  precondition(!region.source.isEmpty)
  let count=output.reduce(0){$0+$1.source.components(separatedBy:region.source).count-1}
  precondition(count == 1,"each independent source phrase must survive exactly once")
 }
}
func image(_ neck: Bool, _ scale: Int)->CGImage {
 let size=400*scale, s=CGFloat(scale)
 let c=CGContext(data:nil,width:size,height:size,bitsPerComponent:8,bytesPerRow:size,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:0)!
 c.scaleBy(x:s,y:s)
 c.setFillColor(gray:0.2,alpha:1);c.fill(CGRect(x:0,y:0,width:400,height:400));c.setFillColor(gray:1,alpha:1)
 c.fill(CGRect(x:140,y:80,width:120,height:240))
 if neck {c.setFillColor(gray:0.2,alpha:1);c.fill(CGRect(x:194,y:80,width:12,height:55));c.fill(CGRect(x:194,y:265,width:12,height:55))}
 return c.makeImage()!
}
let rows=[ReaderTranslationRegion(id:"r",rect:CGRect(x:0.525,y:0.35,width:0.05,height:0.3),source:"明日の",sourceOrientation:.vertical,sourceSingleVerticalColumn:true),ReaderTranslationRegion(id:"l",rect:CGRect(x:0.425,y:0.35,width:0.05,height:0.3),source:"予定は",sourceOrientation:.vertical,sourceSingleVerticalColumn:true)]
let blocks=[ReaderTranslationRegion(id:"r",rect:CGRect(x:0.525,y:0.35,width:0.1,height:0.3),source:"明日の予定を聞く",sourceOrientation:.vertical,sourceSingleVerticalColumn:false),ReaderTranslationRegion(id:"l",rect:CGRect(x:0.375,y:0.35,width:0.1,height:0.3),source:"時間はどうしよう",sourceOrientation:.vertical,sourceSingleVerticalColumn:false)]
var cases=0
for scale in [1,2,4] {for neck in [false,true] { for reverse in [false,true] { for paragraphs in [false,true] {
 let im=image(neck,scale),members=paragraphs ? blocks : rows,input=reverse ? Array(members.reversed()) : members
 let lines=[150.0,170.0,210.0,230.0].map{x -> ReaderTranslationBalloonMerger.SourceLine in
 let p=CGFloat(scale);return .init(polygon:[CGPoint(x:x*p,y:140*p),CGPoint(x:(x+20)*p,y:140*p),CGPoint(x:(x+20)*p,y:260*p),CGPoint(x:x*p,y:260*p)],text:"長い文章",orientation:.vertical)}
 let output=ReaderTranslationBalloonMerger.apply(input,image:im,sourceLines:paragraphs ? lines : [])
 assertSourceFragmentsOnce(input,output)
 precondition(output.count == (neck ? 2 : 1),"clear lettering gutter must not override the wider balloon's neck")
 if neck {precondition(output==input,"separate source ownership and ordering must survive")}
 cases += 1
}}}}
// Synthetic nonsexual paragraphs exercise both real merge admission and its neck veto.
let phrases=["午前は図書館へ","午後は公園へ"]
let phraseRegions=rows.enumerated().map { index,row in
 ReaderTranslationRegion(id:row.id,rect:row.rect,source:phrases[index],
  sourceOrientation:row.sourceOrientation,sourceSingleVerticalColumn:row.sourceSingleVerticalColumn)
}
for scale in [1,2,4] {for neck in [false,true] {for reverse in [false,true] {
 let input=reverse ? Array(phraseRegions.reversed()) : phraseRegions
 let output=ReaderTranslationBalloonMerger.apply(input,image:image(neck,scale))
 assertSourceFragmentsOnce(input,output)
 precondition(output.count == (neck ? 2 : 1),"synthetic paragraphs retain the measured neck boundary")
 if neck {precondition(output==input,"both lobe owners must retain their original source")}
 else {precondition(output[0].source == phrases.joined(),"merged phrases retain source reading order")}
 cases += 1
}}}
for scale in [1,2,4] {for reverse in [false,true] {
 let size=400*scale,p=CGFloat(scale)
 let context=CGContext(data:nil,width:size,height:size,bitsPerComponent:8,bytesPerRow:size,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:0)!
 context.setFillColor(gray:1,alpha:1);context.fill(CGRect(x:0,y:0,width:size,height:size))
 let lines=[150.0,170.0,210.0,230.0].map{x -> ReaderTranslationBalloonMerger.SourceLine in
 .init(polygon:[CGPoint(x:x*p,y:140*p),CGPoint(x:(x+20)*p,y:140*p),CGPoint(x:(x+20)*p,y:260*p),CGPoint(x:x*p,y:260*p)],text:"長い文章",orientation:.vertical)}
 let input=reverse ? Array(blocks.reversed()) : blocks
 let output=ReaderTranslationBalloonMerger.apply(input,image:context.makeImage()!,sourceLines:lines)
 assertSourceFragmentsOnce(input,output)
 precondition(output==input,"open-page paragraphs must retain authored separation")
 cases += 1
}}
// Same outlined style cannot erase an independently closed utterance. Exercise
// production apply, with an open continuation as the positive control.
let colourContext=CGContext(data:nil,width:300,height:400,bitsPerComponent:8,bytesPerRow:1200,
 space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
colourContext.setFillColor(red:0.3,green:0.3,blue:0.3,alpha:1)
colourContext.fill(CGRect(x:0,y:0,width:300,height:400))
for x in [105,135,165] {for y in stride(from:25,to:340,by:12) {
 colourContext.setFillColor(red:1,green:1,blue:1,alpha:1)
 colourContext.fill(CGRect(x:x,y:400-y-10,width:10,height:10))
 colourContext.setFillColor(red:1,green:0,blue:1,alpha:1)
 colourContext.fill(CGRect(x:x+1,y:400-y-9,width:8,height:8))
}}
let colourImage=colourContext.makeImage()!
func captionHead(_ text:String)->ReaderTranslationRegion {
 .init(id:"head",rect:CGRect(x:100.0/300,y:20.0/400,width:90.0/300,height:170.0/400),
 source:text,sourceOrientation:.vertical,sourceSingleVerticalColumn:false)
}
let captionTail=ReaderTranslationRegion(id:"tail",rect:CGRect(x:100.0/300,y:210.0/400,width:30.0/300,height:130.0/400),
 source:"続きの文",sourceOrientation:.vertical,sourceSingleVerticalColumn:true)
for reverse in [false,true] {
 let open=[captionHead("本文最後の列"),captionTail]
 let openInput=reverse ? Array(open.reversed()) : open
 precondition(ReaderTranslationBalloonMerger.apply(openInput,image:colourImage).map(\.source)==["本文最後の列続きの文"],
  "matching outlined continuation must still join")
 cases += 1
 for quote in ["」","』","”"] {
  let closed=[captionHead("終わった発話"+quote+" \n"),captionTail]
  let input=reverse ? Array(closed.reversed()) : closed
  precondition(ReaderTranslationBalloonMerger.apply(input,image:colourImage)==input,
   "same outlined style must not join a closed utterance when the next opening quote is missing")
  cases += 1
 }
}
// Production staggered quote helper: neutral positive and independent-utterance negatives.
func staggeredQuoteImage(closing: Bool = true, freshOpening: Bool = false, wrongCorner: Bool = false) -> CGImage {
 let c=CGContext(data:nil,width:420,height:420,bitsPerComponent:8,bytesPerRow:1680,
  space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
 func fill(_ r:CGRect,_ white:Bool) {
  if white {c.setFillColor(red:1,green:1,blue:1,alpha:1)}
  else {c.setFillColor(red:0.65,green:0.25,blue:0.55,alpha:1)}
  c.fill(CGRect(x:r.minX,y:420-r.maxY,width:r.width,height:r.height))
 }
 c.setFillColor(gray:0.12,alpha:1);c.fill(CGRect(x:0,y:0,width:420,height:420))
 func corner(_ x:CGFloat,_ y:CGFloat,_ opening:Bool) {
  let rail=CGRect(x:x,y:opening ? y:y+8,width:28,height:4)
  let leg=CGRect(x:opening ? x+24:x,y:y,width:4,height:12)
  fill(rail.insetBy(dx:-2,dy:-2),true);fill(leg.insetBy(dx:-2,dy:-2),true)
  fill(rail,false);fill(leg,false)
 }
 for x in [CGFloat(194),260] {
  let start=x == 194 ? 154:74
  for y in stride(from:start,through:264,by:22) {
   let glyph=CGRect(x:x,y:CGFloat(y),width:28,height:10)
   fill(glyph.insetBy(dx:-2,dy:-2),true);fill(glyph,false)
  }
 }
 corner(260,48,true)
 if closing {corner(194,306,wrongCorner)}
 if freshOpening {corner(194,130,true)}
 return c.makeImage()!
}
func staggeredQuoteRows(_ first:String="「今日は",_ last:String="良い天気") -> [ReaderTranslationRegion] {
 [.init(id:"right",rect:CGRect(x:250.0/420,y:40.0/420,width:50.0/420,height:250.0/420),source:first,
  sourceOrientation:.vertical,sourceSingleVerticalColumn:true),
  .init(id:"left",rect:CGRect(x:184.0/420,y:125.0/420,width:50.0/420,height:185.0/420),source:last,
  sourceOrientation:.vertical,sourceSingleVerticalColumn:true)]
}
let staggeredImage=staggeredQuoteImage()
for input in [staggeredQuoteRows(),Array(staggeredQuoteRows().reversed())] {
 let output=ReaderTranslationStaggeredQuoteMerger.apply(input,image:staggeredImage,
  enclosure:ReaderTranslationEnclosedBackground.ComponentMap(image:staggeredImage))
 precondition(output.count == 1,"staggered quote measured corner positive")
 precondition(output[0].source == "「今日は良い天気」")
 precondition(output[0].id == input[0].id && output[0].unitMemberRects == staggeredQuoteRows().map(\.rect))
 assertSourceFragmentsOnce(input,output)
 cases += 1
}
for im in [staggeredQuoteImage(closing:false),staggeredQuoteImage(freshOpening:true),staggeredQuoteImage(wrongCorner:true)] {
 let input=staggeredQuoteRows()
 let output=ReaderTranslationStaggeredQuoteMerger.apply(input,image:im,enclosure:ReaderTranslationEnclosedBackground.ComponentMap(image:im))
 precondition(output==input,"missing/wrong corner or fresh opening must remain separate");cases += 1
}
for input in [staggeredQuoteRows("「今日は」"),staggeredQuoteRows("「今日は","「良い天気"),staggeredQuoteRows("今日は")] {
 let output=ReaderTranslationStaggeredQuoteMerger.apply(input,image:staggeredImage,
  enclosure:ReaderTranslationEnclosedBackground.ComponentMap(image:staggeredImage))
 precondition(output==input,"independent quote boundary must survive");cases += 1
}
print("STAGGERED_QUOTE_NEUTRAL_PASS cases=8")

if CommandLine.arguments.count > 1 {
 let fixtureURL=URL(fileURLWithPath:CommandLine.arguments[1])
 let fixture=try JSONSerialization.jsonObject(with:Data(contentsOf:fixtureURL)) as! [String:Any]
 let imageURL=URL(fileURLWithPath:fixture["image"] as! String)
 let source=CGImageSourceCreateWithURL(imageURL as CFURL,nil)!
 let original=CGImageSourceCreateImageAtIndex(source,0,nil)!
 let members=(fixture["regions"] as! [[String:Any]]).map { row -> ReaderTranslationRegion in
  let box=row["rect"] as! [String:Double]
  var region=ReaderTranslationRegion(id:row["id"] as! String,rect:CGRect(x:box["x"]!,y:box["y"]!,width:box["width"]!,height:box["height"]!),
   source:row["source"] as! String,sourceOrientation:.vertical,sourceSingleVerticalColumn:row["sourceSingleVerticalColumn"] as? Bool)
  if let evidence=row["detectorSeedEvidence"] as? [[String:Any]] {
   region.detectorSeedEvidence=try! JSONDecoder().decode([NativeOCRDetectorSeedEvidence].self,
    from:JSONSerialization.data(withJSONObject:evidence))
  }
  return region
 }
 for reverse in [false,true] {
  let input=reverse ? Array(members.reversed()) : members
  let output=ReaderTranslationBalloonMerger.apply(input,image:original)
  let expected=members.first{$0.id=="region-0"}!.source+members.first{$0.id=="region-2"}!.source
  guard output.count == 2,output.contains(where:{$0.source==expected}),
    output.contains(where:{$0.id=="region-1" && $0.source==members.first{$0.id=="region-1"}!.source}) else {
   print("QUOTED_COLUMNS_FAIL page=0031 actualGroups=\(output.count) expectedGroups=2 whiteSpeakerMustRemainSeparate=true")
   exit(1)
  }
  let right=members.first{$0.id=="region-0"}!,left=members.first{$0.id=="region-2"}!
  let joined=output.first{$0.source==expected}!
  precondition(joined.id == input.first{$0.id != "region-1"}!.id,"input anchor identity must survive")
  precondition(joined.unitMemberRects == [right.rect,left.rect],"retain reading-order member geometry and unequal emphasis widths")
  let evidence=NativeOCRDetectorSeedEvidence.preservingUnion([right.detectorSeedEvidence,left.detectorSeedEvidence])
  precondition(evidence != nil && joined.detectorSeedEvidence == evidence,"retain original measured ownership")
  for (first,last) in [(right.source+"」","「"+left.source),(right.source,"「"+left.source),(right.source,String(left.source.dropLast())+"』")] {
   let altered=members.map { item -> ReaderTranslationRegion in
    var region=ReaderTranslationRegion(id:item.id,rect:item.rect,
     source:item.id==right.id ? first : item.id==left.id ? last : item.source,
     sourceOrientation:item.sourceOrientation,sourceSingleVerticalColumn:item.sourceSingleVerticalColumn)
    region.detectorSeedEvidence=item.detectorSeedEvidence
    return region
   }
   let rows=reverse ? Array(altered.reversed()) : altered
   precondition(ReaderTranslationBalloonMerger.apply(rows,image:original)==rows,"complete, freshly opened or mismatched quotes must stay separate")
   cases += 1
  }
  let blocker=ReaderTranslationRegion(id:"blocker",rect:CGRect(x:(right.rect.minX+left.rect.maxX)/2,y:right.rect.minY+0.05,
   width:0.001,height:0.04),source:"別",sourceOrientation:.horizontal)
  precondition(ReaderTranslationBalloonMerger.apply(input+[blocker],image:original)==input+[blocker],"never cross a third source owner")
  cases += 2
 }
}
print("BALLOON_MERGE_SEPARATION_PASS cases=\(cases) scales=1,2,4 orders=forward,reverse columns=single,multiple broad-paper-control=joined narrow-lobes=separate open-page-paragraphs=separate closed-quotes=separate outlined-continuation=joined source-fragments=exactly-once synthetic-phrase-cases=12")
'''
with tempfile.TemporaryDirectory(prefix='aidoku-merge-separation-') as directory:
    directory = Path(directory)
    main = directory / 'main.swift'
    main.write_text('import CoreGraphics\nimport Foundation\nimport ImageIO\nimport Darwin\n'+(t/'NativeEngine/OCR/BrowserOCRSourceOrientation.swift').read_text()+region+rot+'\n'+e+s+h)
    start=time.perf_counter()
    evidence_sources = [t / 'NativeEngine/OCR' / (name + '.swift') for name in [
        'NativeOCRDetectorSeedEvidence','NativeOCRSourceROIProbabilityEvidence']]
    evidence_sources.append(t / 'ReaderTranslationStaggeredQuoteMerger.swift')
    subprocess.run(['xcrun','swiftc','-O',*[str(path) for path in evidence_sources],str(main),'-o',str(directory/'replay')],check=True)
    print(f'Build seconds: {time.perf_counter()-start:.3f}',flush=True)
    start=time.perf_counter()
    subprocess.run([str(directory/'replay'),*sys.argv[1:]],check=True)
    print(f'Test seconds: {time.perf_counter()-start:.3f}',flush=True)
