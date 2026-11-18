#!/usr/bin/env python3
"""Focused production CJK gap regression; synthetic ordinary captions, no network.

Uses actual production merger and existing native support adapter. Does not
substitute a candidate merger, render, alter the shared host cache, or run OCR.
"""
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
OCR = ROOT / 'Aidoku/Core/Translation/NativeEngine/OCR'
carrier = ROOT / 'Scripts/tests/run-ocr-merger-evidence-smoke.py'
namespace = {'__file__': str(carrier)}
exec(carrier.read_text().split("harness=r'''")[0], namespace)
harness = r'''
func row(_ text: String, _ rect: CGRect, _ orientation: BrowserOCRSourceOrientation = .horizontal,
         seeds: [NativeOCRDetectorSeedEvidence]? = nil) -> NativeCoreMLOCRLine {
 let p = [CGPoint(x:rect.minX,y:rect.minY),CGPoint(x:rect.maxX,y:rect.minY),
          CGPoint(x:rect.maxX,y:rect.maxY),CGPoint(x:rect.minX,y:rect.maxY)]
 return .init(polygon:p,text:text,score:0.98,orientation:orientation,erasurePolygons:[p],detectorSeedEvidence:seeds)
}
func grouped(_ rows: [NativeCoreMLOCRLine], veto: Bool = false) -> [PaddleOCRLine] {
 NativeOCRTextLineMerger.merge(rows,imageWidth:3000,imageHeight:3000,
   separationCheck: veto ? {_,_,_ in true} : nil)
}
var cases = 0
for scale: CGFloat in [0.5, 1, 2] {
 func box(_ x:CGFloat,_ y:CGFloat,_ w:CGFloat,_ h:CGFloat) -> CGRect {
  .init(x:x*scale,y:y*scale,width:w*scale,height:h*scale)
 }
 // Actual ordinary 0695 caption geometry; no page-specific production logic.
 let top = row("龍門渕家",box(149,888,133,33))
 let bottom = row("調理室",box(172,933,78,25))
 for rows in [[top,bottom],[bottom,top]] {
  unsetenv("AIDOKU_CJK_GAP05")
  let baseline = grouped(rows)
  precondition(baseline.count == 2,"default must remain conservative")
  setenv("AIDOKU_CJK_GAP05","0",1)
  precondition(grouped(rows) == baseline,"explicit off equals absent gate")
  setenv("AIDOKU_CJK_GAP05","1",1)
  let result = grouped(rows)
  precondition(result.count == 1 && result[0].text == "龍門渕家調理室")
  precondition(result[0].auxiliaryInkPolygons.count == 2,"both physical polygons retained")
  precondition(grouped(rows,veto:true).count == 2,"actual ownership callback remains authoritative")
  cases += 4
 }
 // False-pair counterexamples: no blanket widening, no shifted peer joins.
 let negatives: [[NativeCoreMLOCRLine]] = [
  [top,row("調理室",box(172,935,78,25))], // gap exceeds frozen half-glyph bound
  [top,row("調理室",box(320,933,78,25))], // different aligned surface
  [row("食堂",box(149,888,133,33)),bottom], // fewer than three CJK scalars
  [row("KITCHEN",box(149,888,133,33)),bottom], // Latin is not CJK eligibility
  [top,row("調理室",box(172,933,78,16))], // incompatible type size
 ]
 for input in negatives {
  for rows in [input,Array(input.reversed())] {
   setenv("AIDOKU_CJK_GAP05","0",1); let baseline = grouped(rows)
   setenv("AIDOKU_CJK_GAP05","1",1); let candidate = grouped(rows)
   precondition(candidate == baseline,"false-pair counterexample must be unchanged")
   precondition(candidate.count == 2,"independent units must remain separate")
   cases += 1
  }
 }
 let vertical = [row("学校です",box(100,100,30,120),.vertical),
                 row("図書館です",box(145,100,30,150),.vertical)]
 setenv("AIDOKU_CJK_GAP05","0",1); let prior = grouped(vertical)
 setenv("AIDOKU_CJK_GAP05","1",1)
 precondition(grouped(vertical) == prior,"vertical policy must remain unchanged")
 cases += 1
}
print("PASS CJKGap05: \(cases) scale/order/default-off/false-pair/veto/polygon checks")
func seed(_ id:String,_ x:Int) -> NativeOCRDetectorSeedEvidence {
 .init(ownerID:id,parentBoxIndex:x,provenance:"db-4connected-original-cells-v1",threshold:0.9,
       mapOriginX:0,mapOriginY:0,mapFullWidth:3000,mapFullHeight:3000,sourceWidth:3000,sourceHeight:3000,
       components:[.init(seed:20*3000+x,pixelCount:2,meanProbability:0.95,runs:[.init(y:20,x:x,count:2)])])
}
let firstSeed=seed("title-head",100),secondSeed=seed("title-tail",124)
func sortedSeeds(_ evidence:[NativeOCRDetectorSeedEvidence]) -> [NativeOCRDetectorSeedEvidence] {
 evidence.sorted{$0.ownerID < $1.ownerID}
}
let witnessed=[row("龍門渕家",CGRect(x:149,y:888,width:133,height:33),seeds:[firstSeed]),
               row("調理室",CGRect(x:172,y:933,width:78,height:25),seeds:[secondSeed])]
for rows in [witnessed,Array(witnessed.reversed())] {
 let merged=grouped(rows)
 precondition(merged.count==1 && sortedSeeds(merged[0].detectorSeedEvidence ?? []) == [firstSeed,secondSeed])
 let blocked=grouped(rows,veto:true)
 precondition(sortedSeeds(blocked.flatMap{$0.detectorSeedEvidence ?? []}) == [firstSeed,secondSeed])
}
print("PASS CJKGap05: exact detector-owner evidence retained through admission and veto, both input orders")
'''
owned = (ROOT / 'AidokuTests/Translation/NativeEngine/NativeOCRTextLineMergerTests.swift').read_text()
start = owned.index('    @Test func missingClosingQuote')
body = owned[start:owned.index('    @Test', start + len('    @Test'))]
body = body.replace('@Test ', '').replace('#expect', 'precondition')
helper = owned[owned.index('    private func line('):owned.index('\n}\n\nprivate final')].replace('private func', 'func')
balloon = namespace['balloon']
support = namespace['support'] + 'enum PixelWitness {\n' + balloon[balloon.index('    static func darkFraction('):balloon.index('    private static func matching(')] + '}\n'
harness += body + helper + '\nmissingClosingQuoteKeepsDifferentlyColouredResponseSeparate()\nprint("PASS existing independent quoted/owned-colour counterexamples: 3 scales, 2 orders, 5 negative variants")\n'
names = ['BrowserOCRSourceOrientation','PaddleOCRTypes','NativeOCRSpatialIndex',
         'NativeOCRAuxiliaryOwnership','NativeOCRTextLineMerger','NativeOCRSlantedDependentColumns',
         'NativeOCRDetectorSeedEvidence','NativeOCRSourceROIProbabilityEvidence','NativeOCRRegionSeparator']
with tempfile.TemporaryDirectory(prefix='aidoku-cjk-gap05-regression-') as directory:
    path = Path(directory)
    (path / 'main.swift').write_text(support + harness)
    start = time.monotonic()
    subprocess.run(['xcrun','swiftc','-O',*[str(OCR / (name + '.swift')) for name in names],
                    str(path / 'main.swift'),'-o',str(path / 'regression')], check=True)
    print(f'build_seconds={time.monotonic()-start:.3f}', flush=True)
    start = time.monotonic()
    subprocess.run([str(path / 'regression')],check=True)
    print(f'test_seconds={time.monotonic()-start:.3f}', flush=True)
