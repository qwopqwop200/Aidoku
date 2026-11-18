#!/usr/bin/env python3
"""Compare production call-local measurement memoization to uncached Core Text."""
from pathlib import Path
import subprocess, tempfile, time, argparse, statistics, json
root=Path(__file__).resolve().parents[2]
overlay=root/'Aidoku/Core/Translation/NativeEngine/Overlay'
sources=['NativeTranslationTypography','NativeParentheticalNameWrap','NativeTextPaintGeometry','NativeCollapsedRowIntrinsicWidth','NativePreLineTextFlow','NativeNormalTextFlow','NativeNormalBreakOpportunities','NativeRawTextBalance','NativeKeepAllBreakOpportunities','NativeKeepAllAutoLines','NativeKeepAllTextBalance','NativeCTFontStrokePainter','NativeCTFontHorizontalFillPainter','NativeCTFontVerticalPainter','NativeVerticalGlyphOrigins','NativePreformattedTabs','NativeVerticalLetterSpacing','NativeVisibleControlGlyphs']
old='''        func measure(_ range: NSRange) -> CGFloat {
            CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(
                attributedString(text: source.substring(with: range), style: paintedStyle)), nil, nil, nil))
        }'''
new='''        var measuredWidths: [NSRange: CGFloat] = [:]
        func measure(_ range: NSRange) -> CGFloat {
            if let cached = measuredWidths[range] { return cached }
            let width = CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(
                attributedString(text: source.substring(with: range), style: paintedStyle)), nil, nil, nil))
            if measuredWidths.count < 512 { measuredWidths[range] = width }
            return width
        }'''
fixture=r'''
import Foundation
import CoreGraphics
import CryptoKit
@main struct Check {
 static func main() throws {
  var texts=["원문 위치와 말풍선 안의 글자 배치를 함께 확인합니다.", "This is a longer balanced caption with repeated words and natural whitespace.", "폭이좁아서긴단어가다음줄로넘어갈때도글자는같아야한다", "hello  world  repeated  whitespace", "한국어와 English 1234 mixed text", "가나다라마바사\n두번째 문단입니다", "👩🏽‍💻 가족 👨‍👩‍👧‍👦 and combining e\u{301}"]
  if CommandLine.arguments.count > 3 {
   texts = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))) as! [String]
  }
  var records:[[String:Any]]=[]
  let iterations=Int(CommandLine.arguments[2]) ?? 1
  let start=Date()
  for repeatIndex in 0..<iterations { for text in texts { for mode in 0..<3 { for width in [40.0,90,150,250] {
   let style=NativeTranslationTypography.Style(fontSize: 18, outline: CGColor(gray:1,alpha:1), outlineWidth:0.8, balancesHorizontalLines:true, horizontalWrapping: mode == 0 ? .normal : mode == 1 ? .keepAll : .keepAllWithEmergency, horizontalWhitespace: mode == 0 ? .normal : .preWrap, balancesExplicitParagraphs:true)
   let layout=NativeTranslationTypography.layout(text:text,in:CGSize(width:width,height:500),style:style)
   if repeatIndex == 0 {
    let context=CGContext(data:nil,width:320,height:540,bitsPerComponent:8,bytesPerRow:1280,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x:0,y:540);context.scaleBy(x:1,y:-1)
    NativeTranslationTypography.draw(layout:layout,in:context,at:CGPoint(x:20,y:20))
    let data=Data(bytes:context.data!,count:1280*540)
    records.append(["text":text,"mode":mode,"width":width,"pixel":SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined(),"size":[layout.size.width,layout.size.height],"ink":[layout.inkBounds.minX,layout.inkBounds.minY,layout.inkBounds.width,layout.inkBounds.height],"fit":layout.fits,"lines":layout.lineRanges.map{[$0.location,$0.length]}])
   }
  } } } }
  let elapsed=Date().timeIntervalSince(start)
  try JSONSerialization.data(withJSONObject:records,options:[.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
  print(elapsed)
 }
}
'''
temporary=tempfile.TemporaryDirectory(prefix='aidoku-native-text-measure-')
dir=Path(temporary.name)
original=(overlay/'NativeTranslationTypography.swift').read_text()
original=original.replace('        // Intrinsic sizing, greedy flow and balance revisit the same ranges.\n        // Cache only this immutable shaping context, with bounded call lifetime.\n','')
assert original.count(new)==1 and original.count(old)==1
parser=argparse.ArgumentParser(description='Exact Core Text geometry and pixel regression; optional scoped performance experiment')
parser.add_argument('--benchmark',action='store_true')
parser.add_argument('--corpus-run', type=Path, help='Use actual translated text from saved native-layout.json; no OCR or API')
args=parser.parse_args()
corpus=[]
if args.corpus_run:
 for path in sorted(args.corpus_run.glob('*/native-layout.json')):
  for item in json.loads(path.read_text())['items']:
   text=item.get('text')
   if isinstance(text,str) and text not in corpus: corpus.append(text)
 if not corpus: parser.error('No saved translated cards found')
 corpus_path=dir/'texts.json'
 corpus_path.write_text(json.dumps(corpus,ensure_ascii=False))
timings={}
for mode in ['before','after']:
 path=dir/(mode+'.swift');path.write_text(original.replace(new,old) if mode=='before' else original)
 fixturepath=dir/'Check.swift';fixturepath.write_text(fixture)
 start=time.monotonic();subprocess.run(['xcrun','swiftc','-O','-parse-as-library',str(path),*[str(overlay/(x+'.swift')) for x in sources[1:]],str(fixturepath),'-o',str(dir/mode)],check=True)
 print(mode,'build',time.monotonic()-start,flush=True)
 timings[mode]=[]
 for i in range(3 if args.benchmark else 1):
  result=subprocess.check_output([str(dir/mode),str(dir/(mode+'.json')),str(40 if args.benchmark else 1),*([str(corpus_path)] if corpus else [])],text=True)
  timings[mode].append(float(result.strip()))
  print(mode,'runtime',result.strip(),flush=True)
assert (dir/'before.json').read_bytes()==(dir/'after.json').read_bytes()
print('PASS exact geometry and RGBA pixel SHA256 for %d cases' % (12 * len(corpus) if corpus else 84))

if args.benchmark:
 print('Median runtime change %.2f%%' % ((statistics.median(timings['after'])/statistics.median(timings['before'])-1)*100))
