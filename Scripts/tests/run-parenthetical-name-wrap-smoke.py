#!/usr/bin/env python3
"""Production CoreText checks for protected Latin names and authored text flow."""
from pathlib import Path
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[2]
OVERLAY = ROOT / 'Aidoku/Core/Translation/NativeEngine/Overlay'
SOURCES = [
    'NativeTranslationTypography', 'NativeParentheticalNameWrap',
    'NativeTextPaintGeometry', 'NativeCollapsedRowIntrinsicWidth', 'NativePreLineTextFlow',
    'NativeNormalTextFlow', 'NativeNormalBreakOpportunities', 'NativeRawTextBalance',
    'NativeKeepAllBreakOpportunities', 'NativeKeepAllAutoLines', 'NativeKeepAllTextBalance',
    'NativeCTFontStrokePainter', 'NativeCTFontHorizontalFillPainter', 'NativeCTFontVerticalPainter',
    'NativeVerticalGlyphOrigins', 'NativePreformattedTabs', 'NativeVerticalLetterSpacing',
    'NativeVisibleControlGlyphs',
]
FIXTURE = r'''
import Foundation
import CoreText
@main struct Check {
 static func rows(_ layout: NativeTranslationTypography.Layout) -> [String] {
  layout.lineRanges.map { (layout.shapedText as NSString).substring(with: $0) }
 }
 static func compact(_ text: String) -> String {
  String(text.filter { !$0.isWhitespace })
 }
 static func main() {
  let positives = ["두 번째는 민수(Chloe)다", "뭐야 이 민수(Asure)는", "학생(Alice)은 웃었다", "친구(Bob)", "학생(Alice)", "학생(alice)에게", "두  번째는 민수(Chloe)다"]
  for text in positives {
   let units = NativeParentheticalNameWrap.units(text)!
   precondition(units.contains { $0.text.hasPrefix("(") }, text)
   precondition(!NativeParentheticalNameWrap.protectedUTF16Cuts(text).isEmpty)
  }
  for text in ["여기서는 괜찮을까", "(3.14)는", "(Alice)다음", "(two words)는", "(Alice\n)는", "((Alice))는", "(Alice-Ann)는", "(Alice)는지", "(Alice))는", "학생(Alice)\n웃었다"] {
   precondition(NativeParentheticalNameWrap.units(text) == nil, text)
  }
  var measured = 0
  for (text,font,narrow,wide,outline) in [("두 번째는 민수(Chloe)다",11.25,37.25,48.0,1.575), ("뭐야 이 민수(Asure)는",9.0,29.328125,39.0,1.8)] {
   let style = NativeTranslationTypography.Style(fontScript: "korean", fontSize: font, outline: CGColor(gray:1,alpha:1), outlineWidth: outline, tracking:-font*0.012, lineHeight:font*1.1777, optimizesKoreanWrapping:true)
   let small = NativeTranslationTypography.layout(text: text, in: CGSize(width:narrow,height:100), style:style)
   precondition(!small.fits || small.size.width > narrow + 0.01, "Protected token must never be reported as a possible narrow fit")
   let large = NativeTranslationTypography.layout(text: text, in: CGSize(width:wide,height:100), style:style)
   let output = rows(large)
   precondition(large.fits && large.size.width <= wide + 0.01)
   precondition(compact(output.joined()) == compact(text))
   let protectedName = text.contains("Chloe") ? "(Chloe)다" : "(Asure)는"
   precondition(output.contains { $0.contains(protectedName) }, "Name and particle split across rows")
   precondition(NativeTranslationTypography.koreanLines(text:text,available:CGSize(width:narrow,height:100),style:style) == nil)
   let generated = NativeTranslationTypography.koreanLines(text:text,available:CGSize(width:wide,height:100),style:style)!
   precondition(generated.contains { $0.contains(protectedName) })
   precondition(compact(generated.joined()) == compact(text))
   measured += 1
  }
  // Latin-dominant mixed text takes the panel's generic .normal/.preWrap path.
  let genericText = "이(Alexander)는"
  let genericStyle = NativeTranslationTypography.Style(fontSize:18)
  let genericWidth = NativeTranslationTypography.canvasTextMetrics(text:"(Alexander)는",style:genericStyle)!.advance + 3
  let generic = NativeTranslationTypography.layout(text:genericText,in:CGSize(width:genericWidth,height:160),style:genericStyle)
  precondition(generic.fits && compact(rows(generic).joined()) == compact(genericText))
  precondition(rows(generic).contains { $0.contains("(Alexander)는") })
  print("PASS: protected names/particles, whitespace, authored-newline and token negatives; \(measured) actual CoreText impossible/possible width pairs and generated-row checks; generic panel style")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='aidoku-parenthetical-name-') as temporary:
    folder = Path(temporary)
    fixture = folder / 'Check.swift'
    fixture.write_text(FIXTURE)
    binary = folder / 'check'
    subprocess.run(['xcrun','swiftc','-parse-as-library',*[str(OVERLAY/(n+'.swift')) for n in SOURCES],str(fixture),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
