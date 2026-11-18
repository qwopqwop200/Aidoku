#!/usr/bin/env python3
"""Actual pure merger regression; optional saved-corpus image-boundary replay.
Optional args: RUN_DIRECTORY REPORT_JSON BASELINE_SWIFT
"""
from pathlib import Path
import subprocess,sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from swift_replay_cache import compile_replay,write_if_changed
ROOT=Path(__file__).resolve().parents[2]
OCR=ROOT/'Aidoku/Core/Translation/NativeEngine/OCR'
def span(text,start,end):return text[text.index(start):text.index(end,text.index(start))]
pipeline=(OCR/'NativeCoreMLOCRPipeline.swift').read_text()
balloon=(ROOT/'Aidoku/Core/Translation/ReaderTranslationBalloonMerger.swift').read_text()
support='import Foundation\nimport CoreGraphics\nimport ImageIO\n'+span(pipeline,'struct NativeCoreMLOCRLine:','@available(iOS 18.0, *)\nstruct NativeCoreMLOCRPipelineDiagnostics')
support+='enum NativeOCRScopeGeometry {\n'+span(pipeline,'    static func canonicalQuad(','    static func isLatinWord(')+'}\n'
support+='enum ReaderTranslationBalloonMerger {\n'+span(balloon,'    static func separatesVerticalUtterances(','    // Coloured CG captions')+'}\n'
enclosed=(ROOT/'Aidoku/Core/Translation/ReaderTranslationEnclosedBackground.swift').read_text()
support+=enclosed.replace(span(enclosed,'    static func attachingBalloonInteriors(','    private struct Component {'),'')
harness=r'''
func line(_ text:String,_ x:CGFloat)->NativeCoreMLOCRLine {
 .init(polygon:[CGPoint(x:x,y:20),CGPoint(x:x+100,y:20),CGPoint(x:x+100,y:50),CGPoint(x:x,y:50)],
 text:text,score:0.98,orientation:.horizontal)
}
let a=line("HELLO",20),b=line("WORLD",122)
let admitted=NativeOCRTextLineMerger.merge([a,b],imageWidth:300,imageHeight:100)
precondition(admitted.count==1,"control fragments must be joinable")
for rows in [[a,b],[b,a]] {
 var inspected=0
 let blocked=NativeOCRTextLineMerger.merge(rows,imageWidth:300,imageHeight:100,separationCheck:{_,_,direction in
  precondition(direction == .horizontal);inspected+=1;return true
 })
 precondition(blocked.count==2,"image separator must veto a non-overlapping fragment edge")
 precondition(inspected>0,"separator must actually inspect the join")
}
print("PASS: native horizontal fragments join without boundary; image ownership veto survives both input orders")
'''
harness += r'''
func merge(
        _ lines: [NativeCoreMLOCRLine],
        width: Int,
        height: Int,
        recognizedLatinWords: Set<String> = []
    ) -> [PaddleOCRLine] {
        NativeOCRTextLineMerger.merge(
            lines,
            imageWidth: width,
            imageHeight: height,
            recognizedLatinWords: recognizedLatinWords
        )
    }

func line(
        _ text: String,
        _ x: CGFloat,
        _ y: CGFloat,
        _ width: CGFloat,
        _ height: CGFloat,
        score: Double = 0.9,
        orientation: BrowserOCRSourceOrientation = .unknown,
        orientationIsEstimated: Bool = false,
        sourceTileBounds: CGRect? = nil
    ) -> NativeCoreMLOCRLine {
        NativeCoreMLOCRLine(
            polygon: [
                CGPoint(x: x, y: y),
                CGPoint(x: x + width, y: y),
                CGPoint(x: x + width, y: y + height),
                CGPoint(x: x, y: y + height),
            ],
            text: text,
            score: score,
            orientation: orientation,
            orientationIsEstimated: orientationIsEstimated,
            sourceTileBounds: sourceTileBounds
        )
    }
func sparseFourColumnCaptionPreservesOneUtterance(scale: CGFloat) {
        // fresh54/0028: one sparse caption, including a short interior count
        // phrase. Its detector boxes and rightmost slant are taken from input.
        let texts = ["全てが台無しになってしまう", "不純な何かが混ざるだけで", "ほんの一滴", "どんなに透明で綺麗な水も"]
        let boxes: [CGRect] = [CGRect(x: 397, y: 305, width: 31, height: 304),
                              CGRect(x: 459, y: 304, width: 28, height: 293),
                              CGRect(x: 519, y: 303, width: 29, height: 123),
                              CGRect(x: 578, y: 302, width: 31, height: 297)]
        func rows(_ words: [String] = texts, shifted: Int? = nil) -> [NativeCoreMLOCRLine] {
            boxes.enumerated().map { index, box in
                let dx: CGFloat = shifted == index ? 20 : 0
                let original = line(words[index], (box.minX + dx) * scale, box.minY * scale,
                                    box.width * scale, box.height * scale, orientation: .vertical)
                let polygon = index == 3 ? [CGPoint(x: 579 * scale, y: 302 * scale),
                    CGPoint(x: 609 * scale, y: 303 * scale), CGPoint(x: 608 * scale, y: 599 * scale),
                    CGPoint(x: 578 * scale, y: 599 * scale)] : original.polygon
                return .init(polygon: polygon, text: words[index], score: 0.98, orientation: .vertical,
                             erasurePolygons: [polygon])
            }
        }
        for input in [rows(), Array(rows().reversed())] {
            let result = merge(input, width: Int(992 * scale), height: Int(1403 * scale))
            precondition(result.count == 1)
            precondition(result.first?.text == texts.reversed().joined())
            precondition(result.first?.auxiliaryInkPolygons.count == 4)
        }
        let separated = NativeOCRTextLineMerger.merge(rows(), imageWidth: Int(992 * scale), imageHeight: Int(1403 * scale),
                                                     separationCheck: { _, _, _ in true })
        precondition(separated.count == 4)
        let differentInk = NativeOCRTextLineMerger.merge(rows(), imageWidth: Int(992 * scale), imageHeight: Int(1403 * scale),
                                                        inkContrast: { _, _ in true })
        precondition(differentInk.count == 4)
        var independent = texts
        independent[3] = "透明で綺麗な水だった。"
        precondition(merge(rows(independent), width: Int(992 * scale), height: Int(1403 * scale)).count == 4)
        independent = texts
        independent[3] = "「どんなに透明な水も」"
        precondition(merge(rows(independent), width: Int(992 * scale), height: Int(1403 * scale)).count == 4)
        precondition(merge(rows(shifted: 2), width: Int(992 * scale), height: Int(1403 * scale)).count > 1)
        precondition(merge(Array(rows().dropLast()), width: Int(992 * scale), height: Int(1403 * scale)).count == 3)
    }


for scale: CGFloat in [0.5, 1, 2] { sparseFourColumnCaptionPreservesOneUtterance(scale: scale) }
print("PASS: sparse caption actual quads, RTL ordering, polygons, scale/order, and independent-utterance vetoes")
'''
harness += r'''

struct NativeOCRSlantedDependentColumnsTests {
    private typealias Column = NativeOCRSlantedDependentColumns.Column

    private func fixture(_ text: String, right: Bool, scale: CGFloat = 1, id: Int? = nil) -> Column {
        // fresh54/0062 native OCR quads, in original 900x1200 pixel space.
        let coordinates: [(CGFloat, CGFloat)] = right
            ? [(521, 231), (571, 221), (619, 468), (569, 478)]
            : [(475, 278), (536, 260), (612, 522), (551, 540)]
        return Column(id: id ?? (right ? 0 : 1), text: text,
                      polygon: coordinates.map { CGPoint(x: $0.0 * scale, y: $0.1 * scale) }, isVertical: true)
    }

    private func accepts(_ a: Column, _ b: Column, nearby: [Column] = [],
                         separated: Bool = false, ink: Bool = false, polarity: Bool = false) -> Bool {
        NativeOCRSlantedDependentColumns.accepts(a, b, nearby: nearby,
            ownershipSeparated: separated, inkContrasted: ink, polarityContrasted: polarity)
    }

    func temporalRequestUsesQuadGeometryAndStableOrder(scale: CGFloat) {
        let a = fixture("逃げるときも…", right: true, scale: scale)
        let b = fixture("手…ひっぱってね…", right: false, scale: scale)
        precondition(accepts(a, b, nearby: [a, b]))
        precondition(accepts(b, a, nearby: [b, a]))
        // A grammatical family, not an exact corpus-text allowlist.
        precondition(accepts(fixture("帰る時は…", right: true, scale: scale),
                        fixture("声をかけてください…", right: false, scale: scale)))
    }

    func independentQuotesSentencesAndSpeakersRemainSeparate() {
        let head = fixture("逃げるときも…", right: true)
        let tail = fixture("手…ひっぱってね…", right: false)
        precondition(!accepts(fixture("「逃げるときも…」", right: true), tail))
        precondition(!accepts(head, fixture("「手…ひっぱってね…」", right: false)))
        precondition(!accepts(fixture("逃げるよ…", right: true), tail))
        precondition(!accepts(fixture("もう帰ります。", right: true), fixture("また来てね…", right: false)))
        precondition(!accepts(head, fixture("私は帰る…", right: false)))
        precondition(!accepts(head, fixture("花子：手をひっぱってね…", right: false)))
        precondition(!accepts(head, tail, separated: true))
        precondition(!accepts(head, tail, ink: true))
        precondition(!accepts(head, tail, polarity: true))
    }

    func ambiguousNeighboursAndRemoteColumnsDoNotBorrowOwnership() {
        let a = fixture("逃げるときも…", right: true)
        let b = fixture("手…ひっぱってね…", right: false)
        let neighbour = fixture("違う人の話", right: false, id: 2)
        precondition(!accepts(a, b, nearby: [a, b, neighbour]))
        let remote = Column(id: b.id, text: b.text,
                            polygon: b.polygon.map { CGPoint(x: $0.x - 300, y: $0.y) }, isVertical: true)
        precondition(!accepts(a, remote))
        let horizontal = Column(id: b.id, text: b.text, polygon: b.polygon, isVertical: false)
        precondition(!accepts(a, horizontal))
        precondition(!accepts(a, a))
    }

    func productionMergePreservesBothOwnedPolygonsAndWords(scale: CGFloat) {
        let columns = [fixture("逃げるときも…", right: true, scale: scale),
                       fixture("手…ひっぱってね…", right: false, scale: scale)]
        for ordered in [columns, Array(columns.reversed())] {
            let raw = ordered.map { NativeCoreMLOCRLine(polygon: $0.polygon, text: $0.text,
                score: 0.98, orientation: .vertical, erasurePolygons: [$0.polygon]) }
            let result = NativeOCRTextLineMerger.merge(raw, imageWidth: Int(900 * scale), imageHeight: Int(1200 * scale))
            precondition(result.count == 1)
            precondition(result.first?.text.replacingOccurrences(of: "\n", with: "") == "逃げるときも…手…ひっぱってね…")
            for column in columns {
                precondition(result.first?.auxiliaryInkPolygons.contains(column.polygon) == true)
            }
            let vetoed = NativeOCRTextLineMerger.merge(raw, imageWidth: Int(900 * scale), imageHeight: Int(1200 * scale),
                                                      separationCheck: { _, _, _ in true })
            precondition(vetoed.count == 2)
        }
    }
}
let slantedTests = NativeOCRSlantedDependentColumnsTests()
for scale: CGFloat in [0.5, 1, 2] { slantedTests.temporalRequestUsesQuadGeometryAndStableOrder(scale: scale); slantedTests.productionMergePreservesBothOwnedPolygonsAndWords(scale: scale) }
slantedTests.independentQuotesSentencesAndSpeakersRemainSeparate()
slantedTests.ambiguousNeighboursAndRemoteColumnsDoNotBorrowOwnership()
print("PASS: slanted dependent columns helper and production integration matrix")
'''
harness += r'''
func sourceRecord(_ owner:String,_ y:Int)->NativeOCRDetectorSeedEvidence {
    let runs=(y..<(y+4)).map { NativeOCRDetectorSeedEvidence.Run(y:$0,x:60,count:3) }
    return .init(ownerID:owner,parentBoxIndex:0,provenance:"db-complete-cc-candidates-v2",threshold:0.9,
        mapOriginX:0,mapOriginY:0,mapFullWidth:200,mapFullHeight:400,sourceWidth:200,sourceHeight:400,
        components:[.init(seed:y*200+60,pixelCount:12,meanProbability:0.99,runs:runs)],
        ownershipVersion:2,completeCCScan:true,ambiguousComponents:[],candidateComponents:[])
}
func observedLine(_ text:String,_ y:CGFloat,_ h:CGFloat,_ evidence:[NativeOCRDetectorSeedEvidence])->NativeCoreMLOCRLine {
    .init(polygon:[CGPoint(x:50,y:y),CGPoint(x:80,y:y),CGPoint(x:80,y:y+h),CGPoint(x:50,y:y+h)],
        text:text,score:0.95,orientation:.vertical,detectorSeedEvidence:evidence)
}
let upperRecord=sourceRecord("upper-source",70),lowerRecord=sourceRecord("lower-source",180)
let fullRead=observedLine("「上の声...下の声....」",50,200,[upperRecord,lowerRecord])
for alternate in ["下の声..」","下の声…」","下の声⋯」"] {
    let part=observedLine(alternate,160,80,[lowerRecord])
    let bound=NativeOCRAcceptedSource.bindingPrimary([fullRead,part],width:200,height:400)
    for input in [bound,Array(bound.reversed())] {
        let result=NativeOCRTextLineMerger.merge(input,imageWidth:200,imageHeight:400)
        precondition(result.count==1 && result[0].text==fullRead.text,"a shared physical read may differ only in dot-run count")
        precondition(result[0].acceptedSource.membership?.unknownDedup == [1],"retain the alternate's immutable provenance")
        precondition(result[0].acceptedSource.membership?.table === bound[0].acceptedSource.membership?.table)
    }
}
for fault in 0..<3 {
    let word=fault==0 ? "別の声..」":"下の声..」"
    let record=fault==1 ? sourceRecord("independent-source",180):lowerRecord
    let part=observedLine(word,160,80,[record])
    let bound=fault==2 ? NativeOCRAcceptedSource.bindingPrimary([fullRead],width:200,height:400)+NativeOCRAcceptedSource.bindingPrimary([part],width:200,height:400):NativeOCRAcceptedSource.bindingPrimary([fullRead,part],width:200,height:400)
    let result=NativeOCRTextLineMerger.merge(bound,imageWidth:200,imageHeight:400)
    precondition(result.map(\.text).joined().contains(word),"different letters, independent owners and different page operations cannot become aliases")
}
print("PASS: immutable same-owner dot-run aliases, literal text preservation, input order, and three independence negatives")
'''

corpus=r'''
let run=URL(fileURLWithPath:CommandLine.arguments[1]),output=URL(fileURLWithPath:CommandLine.arguments[2])
let dirs=try FileManager.default.contentsOfDirectory(at:run,includingPropertiesForKeys:nil).sorted{$0.path<$1.path}
var rows:[[String:Any]]=[]
for dir in dirs where Int(dir.lastPathComponent) != nil {
 let files=try FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil)
 guard let file=files.first(where:{$0.lastPathComponent.hasSuffix("-native-ocr.json")}),
  let object=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any],
  let value=object["value"] as? [String:Any],let lines=value["lines"] as? [[String:Any]],
  let source=CGImageSourceCreateWithURL(dir.appendingPathComponent("input.png") as CFURL,nil),
  let image=CGImageSourceCreateImageAtIndex(source,0,nil) else {continue}
 let native=lines.compactMap { line -> NativeCoreMLOCRLine? in
  guard let points=line["polygon"] as? [[String:Double]],let text=line["text"] as? String else{return nil}
  return .init(polygon:points.map{CGPoint(x:$0["x"]!,y:$0["y"]!)},text:text,score:line["score"] as? Double ?? 1,
   orientation:BrowserOCRSourceOrientation(tolerantRawValue:line["orientation"] as? String),
   orientationIsEstimated:line["orientationIsEstimated"] as? Bool ?? false)
 }
 let map=ReaderTranslationEnclosedBackground.ComponentMap(image:image),separator=NativeOCRRegionSeparator(image:image)
 let check:(CGRect,CGRect,BrowserOCRSourceOrientation)->Bool={a,b,o in
  separator?.separates(a,b,orientation:o)==true || map.separates(a,b)
 }
 let before=BaselineNativeOCRTextLineMerger.merge(native,imageWidth:image.width,imageHeight:image.height,separationCheck:check)
 let after=NativeOCRTextLineMerger.merge(native,imageWidth:image.width,imageHeight:image.height,separationCheck:check)
 rows.append(["page":dir.lastPathComponent,"nativeLines":native.count,"beforeGroups":before.count,"afterGroups":after.count,
  "changed":before != after])
}
try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:output)
print("Corpus merge replay: \(rows.count) pages; \(rows.filter{$0["changed"] as? Bool == true}.count) changed by image separation")
'''
p=ROOT/'build/ocr-merger-evidence-smoke'
p.mkdir(parents=True,exist_ok=True)
sources=[OCR/(n+'.swift') for n in ['BrowserOCRSourceOrientation','NativeOCRLocalCoordinates','PaddleOCRTypes','NativeOCRSpatialIndex','NativeOCRAuxiliaryOwnership','NativeOCRAcceptedSource','NativeOCRTextLineMerger','NativeOCRSlantedDependentColumns','NativeOCRDetectorSeedEvidence','NativeOCRSourceROIProbabilityEvidence','NativeOCRRegionSeparator']]
if len(sys.argv)>1:
 baseline=Path(sys.argv[3]) if len(sys.argv)>3 else ROOT/'build/output-hard-evidence-baseline/NativeOCRTextLineMerger.swift'
 write_if_changed(p/'baseline.swift',baseline.read_text().replace('enum NativeOCRTextLineMerger {','enum BaselineNativeOCRTextLineMerger {').encode())
 sources.append(p/'baseline.swift')
checker=r'''
func checked(_ value: @autoclosure () -> Bool, _ message: String = "", line: UInt = #line) {
 if !value() { fputs("FAILED line \(line): \(message)\n",stderr); exit(1) }
}
'''
compile_replay(p,sources,support+checker+harness.replace('precondition(', 'checked(')+(corpus if len(sys.argv)>1 else ''),p/'replay')
subprocess.run([str(p/'replay'),*sys.argv[1:3]],check=True)
