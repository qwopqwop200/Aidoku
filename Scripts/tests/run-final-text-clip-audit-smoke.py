#!/usr/bin/env python3
"""Private native CG test of production audit and production text-only draw.

Extract the actual renderer's clipping/rotation and text-paint blocks verbatim.
Unrelated source/background composition is excluded because audit always passes
paintsBackground=false and paintsSourcePanels=false. Unsupported caption/part/
vertical helpers fail if entered. No shared renderer/app build or page replay.
"""
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
OVERLAY = ROOT / 'Aidoku/Core/Translation/NativeEngine/Overlay'


def section(text, begin, end):
    start = text.index(begin)
    return text[start:text.index(end, start)]


renderer = (OVERLAY / 'NativeTranslationRenderer.swift').read_text()
draw = section(renderer, '    static func draw(_ card:', '    static func columnSourceErasureRects(')
prefix = section(draw, '        let item = card.item', '        if paintsSourcePanels, pixelSnapScale == nil, let patch')
tail = draw[draw.index('        guard paintsText else { return }'):]
audit_source = (OVERLAY / 'NativeTranslationRenderer+SmallFontReadability.swift').read_text()
audit = section(audit_source, '    static func finalTextClipAudit(', '    private static func smallTextBoxInkAllocation(')
loss_observables = section(audit, '        func lossObservables(', '        var modes:')
slanted = (OVERLAY / 'NativeTranslationRenderer+SlantedTrials.swift').read_text()
slanted = slanted[slanted.index('    static func drawSlantedClip('):].rsplit('\n}', 1)[0]
typography = (OVERLAY / 'NativeTranslationTypography.swift').read_text()
typography = typography.replace(section(typography, '/// Scalar-only actual Card observer.',
                                       'extension NativeTranslationTypography {'), '')
final_loop = section((OVERLAY / 'NativeTranslationRenderer+TextBoxes.swift').read_text(),
                     '        var finalClipAudits:', '        phaseMilliseconds["finalClipAudit"]')
assert 'auditEveryFinalCard: true' in final_loop and 'forceMeasurement: true' in final_loop
assert 'continue' not in final_loop and '8_000_000' in final_loop

sources = ['NativeParentheticalNameWrap', 'NativeTextPaintGeometry', 'NativeCollapsedRowIntrinsicWidth',
    'NativePreLineTextFlow', 'NativeNormalTextFlow', 'NativeNormalBreakOpportunities', 'NativeRawTextBalance',
    'NativeKeepAllBreakOpportunities', 'NativeKeepAllAutoLines', 'NativeKeepAllTextBalance',
    'NativeCTFontStrokePainter', 'NativeCTFontHorizontalFillPainter', 'NativeCTFontVerticalPainter',
    'NativeVerticalGlyphOrigins', 'NativePreformattedTabs', 'NativeVerticalLetterSpacing',
    'NativeVisibleControlGlyphs', 'NativeTypographyFontCache']

harness = r'''
import Foundation
import CoreGraphics
import CoreText
typealias T = NativeTranslationTypography
enum NativeTranslationPDFCapture {
    static func roundedPath(_ r: CGRect, radius: CGFloat, deviceScale: CGFloat) -> CGPath { fatalError("untested vertical helper") }
    static func snappedRect(_ r: CGRect, deviceScale: CGFloat) -> CGRect { fatalError("untested vertical helper") }
}
enum NativeTranslationRenderer {
    struct Item {
        var text: String
        var typesettingText: String? = nil
        var rect: CGRect
        var vertical = false
        var rotation: CGFloat = 0
        var clipsText = false
    }
    struct Domain { let rect: CGRect; let polygon: [CGPoint] }
    struct Part { let text: String; let frame: CGRect; let style: T.Style }
    struct Owner {
        var clipped = false; var coverageClip: [CGPoint]? = nil; var coverage: [CGPoint] = []
        var rect = CGRect.zero; var overflowClip = false; var radius: CGFloat = 0
    }
    struct Card {
        var item: Item
        var typography: T.Layout
        var style: T.Style
        var textOrigin: CGPoint
        var sourcePlateRect: CGRect
        var textBoxClip: [CGPoint] = []
        var textPaintDomain: Domain? = nil
        var textRotation: CGFloat? = nil
        var effectiveTextRotation: CGFloat { textRotation ?? item.rotation }
        var sourceBackgroundKind: String? = "solid-text-box"
        var unitTextParts: [Part] = []
        var heavyStrokeWidth: CGFloat = 0
        var captionParentPlate = false
        var glyphPlateReleased = false
        var slantedClip: [[Double]]? = nil
    }
    static func readabilityOwnerPanel(_ c: Card) -> Owner? { fatalError("untested caption owner") }
    static func applyCoverageClip(_ clip: [CGPoint]?, coverage: [CGPoint], owner: CGRect,
                                  context: CGContext, pixelSnapScale: CGFloat?) { fatalError("untested caption clip") }
    static func textPartFrame(_ part: Part, card: Card) -> CGRect { fatalError("unit parts are explicitly unknown") }
''' + slanted + '\n' + audit + r'''
    static func lossProbe(raw: [UInt8], clipped: [UInt8], width: Int, diagnostic: Bool = true) -> [String:Any] {
        let auditEveryFinalCard = diagnostic
''' + loss_observables + r'''
        return lossObservables(raw:raw,clipped:clipped,width:width)
    }
    static func draw(_ card: Card, context: CGContext, opacity: CGFloat,
                     paintsBackground: Bool, paintsText: Bool, paintsSourcePanels: Bool,
                     pixelSnapScale: CGFloat?) {
        precondition(!paintsBackground && !paintsSourcePanels)
''' + prefix + tail + r'''
}
typealias R = NativeTranslationRenderer
var checks = 0
func check(_ condition: Bool, _ reason: String) {
    checks += 1
    if !condition { FileHandle.standardError.write(Data("FAIL: \(reason)\n".utf8)); exit(1) }
}
func polygon(_ r: CGRect) -> [CGPoint] {
    [.init(x:r.minX,y:r.minY),.init(x:r.maxX,y:r.minY),.init(x:r.maxX,y:r.maxY),.init(x:r.minX,y:r.maxY)]
}
// Exact production alpha reducer, authored arrays: strict delta=1 retained,
// threshold/core counters remain additive and are not perceptual/GOLD labels.
var reference = [UInt8](repeating:0,count:25), clipped = reference
for (index, raw, retained) in [(6,1,0),(7,255,254),(8,128,120),(11,20,12),
                              (12,255,0),(13,200,190),(16,127,119),(17,0,1)] {
    reference[index] = UInt8(raw); clipped[index] = UInt8(retained)
}
let loss = R.lossProbe(raw:reference,clipped:clipped,width:5)
check(loss["clipLossPixels"] as? Int == 7 && loss["clipLossAlpha"] as? Int == 291,
      "strict counts preserve every positive alpha delta including 1")
check(loss["aboveNoiseClipLossPixels"] as? Int == 5 && loss["aboveNoiseClipLossAlpha"] as? Int == 289,
      "delta >=8 measured separately")
check(loss["belowNoiseThresholdClipLossPixels"] as? Int == 2, "below threshold is retained strict loss")
check(loss["referenceCorePixels"] as? Int == 4 && loss["coreClipLossPixels"] as? Int == 3
      && loss["coreClipLossAlpha"] as? Int == 273, "core reference >=128 AND delta>=8")
check(loss["coreToNonCoreClipLossPixels"] as? Int == 2 && loss["fullyLostCoreClipLossPixels"] as? Int == 1,
      "core threshold crossing versus fully lost core alpha")
check(loss["aboveNoiseClipLossBounds"] as? [Int] == [1,1,3,3], "observed integer bitmap loss bounds")
check(loss["referenceAllocationBoundaryOccupiedPixels"] as? Int == 0, "known reference within allocation")
let strictOnly = R.lossProbe(raw:reference,clipped:clipped,width:5,diagnostic:false)
check(strictOnly.count == 3 && strictOnly["clipLossPixels"] as? Int == 7
      && strictOnly["clipLossAlpha"] as? Int == 291, "legacy reducer definition/schema unchanged")
let one = R.lossProbe(raw:[0,0,0,0,1,0,0,0,0],clipped:[UInt8](repeating:0,count:9),width:3)
check(one["clipLossPixels"] as? Int == 1 && one["clipLossAlpha"] as? Int == 1,
      "single-alpha loss never erased from strict counts")
check(one["aboveNoiseClipLossPixels"] as? Int == 0 && one["coreClipLossPixels"] as? Int == 0,
      "single-alpha loss does not imply complete core/glyph clipping")
check(one["aboveNoiseClipLossBounds"] is NSNull, "no fabricated above-threshold location")
CTFontManagerRegisterFontsForURL(URL(fileURLWithPath:CommandLine.arguments[1]) as CFURL, .process, nil)
check(T.isBundledSerifAvailable, "production Korean face registered")
let text = "실제 글리프"
let style = T.Style(fontName:"AidokuSerifKR-Bold",fontScript:"korean",fontSize:16,
                    outline:CGColor(gray:1,alpha:1),outlineWidth:2,lineHeight:22)
let layout = T.layout(text:text,in:CGSize(width:160,height:60),style:style)
let origin = CGPoint(x:40.3,y:50.4)
let ink = layout.glyphBounds.reduce(CGRect.null) { $0.union($1) }.offsetBy(dx:origin.x,dy:origin.y)
let safeRect = ink.insetBy(dx:-12,dy:-12)
let safe = R.Card(item:.init(text:text,rect:safeRect),typography:layout,style:style,
                  textOrigin:origin,sourcePlateRect:safeRect)
func audit(_ c: R.Card, budget: inout Int) -> [String:Any] {
    R.finalTextClipAudit(c,pixelScale:CGSize(width:1,height:1),pdfDeviceScale:2,
                        remainingPixels:&budget,forceMeasurement:true,auditEveryFinalCard:true)!
}
var budget = 8_000_000
let beforeFits = safe.typography.fits
let measured = audit(safe,budget:&budget)
check(measured["status"] as? String == "measured-within-allocation", "unscreened empty polygon measured")
check(measured["clipGeometry"] as? String == "rectangle-only", "rectangle remains actual clip")
check(measured["serializedPDFMeasured"] as? Bool == false && measured["finalCompositeMeasured"] as? Bool == false,
      "bitmap never promoted to serialized PDF/composite")
check(measured["finalCardMissingGlyphSemantics"] is NSNull, "no semantic missing-glyph certificate from alpha")
let policy = measured["alphaLossPolicy"] as! [String:Any]
check(policy["visibilityDeltaMinimum"] as? Int == 8 && policy["referenceCoreAlphaMinimum"] as? Int == 128,
      "thresholds explicitly serialized")
let modes = measured["modes"] as! [[String:Any]]
check(modes.count == 2, "both bitmap and PDF-snapped bitmap anchors")
for m in modes {
    check((m["rawOccupiedPixels"] as! Int)>0 && (m["clipLossPixels"] as! Int)==0, "actual safe paint no clip loss")
    check(m["referenceWithinAllocationObserved"] as? Bool == true, "bounded reference does not hit boundary")
}
check(safe.typography.fits == beforeFits, "audit never changes fits")
check((measured["originalToShapedOwnership"] as! [String:Any])["whole"] as? Bool == true,
      "original-to-shaped ownership separate and whole")
check(8_000_000-budget == measured["budgetPixelsCharged"] as? Int, "four raster-pass budget accounted")
var legacyBudget = 8_000_000
check(R.finalTextClipAudit(safe,pixelScale:.init(width:1,height:1),pdfDeviceScale:2,
      remainingPixels:&legacyBudget,forceMeasurement:true) == nil, "historical rectangle repair eligibility unchanged")
var cut = safe
cut.sourcePlateRect = CGRect(x:ink.midX,y:ink.minY-5,width:ink.width,height:ink.height+10)
let cutAudit = audit(cut,budget:&budget)
for m in cutAudit["modes"] as! [[String:Any]] {
    check((m["clipLossPixels"] as! Int)>0 && (m["clipLossAlpha"] as! Int)>0,
          "production rectangle clip loses reference ink under both anchors")
}
var tilted = safe; tilted.item.rotation = 0.13; tilted.textRotation = 0
check(audit(tilted,budget:&budget)["status"] as? String == "measured-within-allocation",
      "effective upright text measured despite detector angle")
tilted.textRotation = 0.13
check(audit(tilted,budget:&budget)["unmeasuredReason"] as? String == "effective-text-rotation", "actual rotated paint unknown")
var domain = safe; domain.textPaintDomain = .init(rect:cut.sourcePlateRect,polygon:polygon(cut.sourcePlateRect))
check(audit(domain,budget:&budget)["status"] as? String == "measured-within-allocation", "independent domain actual draw measured")
var poly = safe; poly.textBoxClip = polygon(cut.sourcePlateRect)
for m in audit(poly,budget:&budget)["modes"] as! [[String:Any]] {
    check((m["clipLossPixels"] as! Int)>0, "production polygon clipping observed")
}
var noBudget = 0
let unknown = audit(safe,budget:&noBudget)
check(unknown["status"] as? String == "pixel-budget" && unknown["ordinaryClipMeasured"] as? Bool == false,
      "budget exhaustion unknown rather than zero loss")
check(unknown["modes"] == nil, "no invented alpha observations after budget exhaustion")
check(unknown["alphaVisibilityLossMeasured"] as? Bool == false && unknown["finalCardMissingGlyphSemantics"] is NSNull,
      "unmeasured damage stays unknown even with threshold policy")
var unused = safe; unused.item.rect = CGRect(x:0,y:0,width:5000,height:5000)
let unusedAudit = audit(unused,budget:&budget)
check(unusedAudit["status"] as? String == "measured-within-allocation", "huge unused capacity no longer allocated")
check((unusedAudit["allocationPixels"] as! Int)<100_000, "bounded actual ink allocation")
check(unusedAudit["referenceEnvelopeCompletenessCertified"] as? Bool == false,
      "empty allocation boundary never certifies full glyph completeness")
var giantStyle = style; giantStyle.fontSize = 2200; giantStyle.lineHeight = 3000
var giant = safe; giant.typography = T.layout(text:text,in:.init(width:20000,height:10000),style:giantStyle)
giant.style = giantStyle
check(audit(giant,budget:&budget)["status"] as? String == "allocation-unsupported", "actual oversized ink remains unknown")

// Compare compact and original repair-frame measurement on the same world
// lattice with actual positive loss. Only the diagnostic allocation shrinks.
var tall = cut
tall.item.rect = CGRect(x:0.3,y:0.4,width:200,height:3000)
tall.textBoxClip = polygon(cut.sourcePlateRect)
var compactBudget = 8_000_000, capacityBudget = 8_000_000
let compact = audit(tall,budget:&compactBudget)
let capacity = R.finalTextClipAudit(tall,pixelScale:.init(width:1,height:1),pdfDeviceScale:2,
    remainingPixels:&capacityBudget,forceMeasurement:true)!
check(compact["status"] as? String == "measured-within-allocation", "tall capacity compact measurement")
check((compact["allocationPixels"] as! Int)<(capacity["allocationPixels"] as! Int)/10,
      "more than tenfold fewer pixels for unused tall capacity")
let compactModes = compact["modes"] as! [[String:Any]], capacityModes = capacity["modes"] as! [[String:Any]]
for i in compactModes.indices {
    for key in ["rawOccupiedPixels","clipLossPixels","clipLossAlpha"] {
        check(compactModes[i][key] as? Int == capacityModes[i][key] as? Int,
              "same strict \(key) under compact/legacy frame and both anchors")
    }
}
// Native coverage witness only, not the parent's saved nine-page benchmark.
var smallQuota = 300_000, oldQuota = smallQuota
var compactCount = 0, legacyCount = 0
for _ in 0..<9 {
    if audit(tall,budget:&smallQuota)["status"] as? String == "measured-within-allocation" { compactCount += 1 }
    if R.finalTextClipAudit(tall,pixelScale:.init(width:1,height:1),pdfDeviceScale:2,
        remainingPixels:&oldQuota,forceMeasurement:true)?["status"] as? String == "measured-within-allocation" { legacyCount += 1 }
}
check(compactCount>legacyCount, "more actual ink audits within unchanged quota")
print("authored quota witness compact \(compactCount)/9 versus capacity \(legacyCount)/9; pixels \(compact["allocationPixels"]!)/\(capacity["allocationPixels"]!)")

for witness in ["😀 👩‍👩‍👧‍👦", "A\u{0301} g\u{0308} e\u{0301}", "漢字 日本語 한글", "첫 행\n중간 행\n마지막 행"] {
    var s = style; s.outlineWidth = 3; s.lineHeight = 23.37
    let shaped = T.layout(text:witness,in:.init(width:220,height:100),style:s)
    check(!shaped.glyphBounds.isEmpty, "native emoji/diacritic/CJK/multiline ink observed")
    let o = CGPoint(x:30.37,y:40.61)
    let envelope = shaped.glyphBounds.reduce(shaped.inkBounds) { $0.union($1) }.offsetBy(dx:o.x,dy:o.y)
    let clip = envelope.insetBy(dx:-20,dy:-20)
    let c = R.Card(item:.init(text:witness,rect:clip),typography:shaped,style:s,textOrigin:o,sourcePlateRect:clip)
    var q = 8_000_000
    let a = audit(c,budget:&q)
    check(a["status"] as? String == "measured-within-allocation", "native full envelope measured")
    for m in a["modes"] as! [[String:Any]] {
        check(m["referenceAllocationBoundaryOccupiedPixels"] as? Int == 0, "first/last glyph and row snap inside allocation")
        check(m["coreClipLossPixels"] as? Int == 0 && m["clipLossPixels"] as? Int == 0,
              "safe allocation preserves strict/core counts for actual production paint")
    }
}
var glowStyle = style; glowStyle.outlineGlow = 3
let glowingLayout = T.layout(text:text,in:.init(width:160,height:60),style:glowStyle)
var glowing = safe; glowing.typography = glowingLayout; glowing.style = glowStyle
var glowBudget = 8_000_000
let glowingAudit = audit(glowing,budget:&glowBudget)
check(glowingAudit["outlineGlowMargin"] as? Double == 12, "glow support explicitly padded and reported")
check(glowingAudit["status"] as? String == "measured-within-allocation", "native glowing reference stays allocated")
// Actual native shadow extends beyond deliberately stale reported support.
// Occupied allocation edge must veto measurement rather than narrow-crop it.
var hiddenGlow = style; hiddenGlow.outlineGlow = 20
var underestimated = safe
underestimated.typography = T.layout(text:text,in:.init(width:160,height:60),style:hiddenGlow)
underestimated.style = style
var underestimatedBudget = 8_000_000
let underestimatedAudit = audit(underestimated,budget:&underestimatedBudget)
check(underestimatedAudit["status"] as? String == "unmeasured"
      && underestimatedAudit["unmeasuredReason"] as? String == "reference-reaches-allocation-boundary",
      "underestimated paint support yields explicit unknown")
check(underestimatedAudit["ordinaryClipMeasured"] as? Bool == false
      && underestimatedAudit["finalCardMissingGlyphSemantics"] is NSNull,
      "occupied reference boundary cannot certify complete or undamaged glyphs")
check(((underestimatedAudit["modes"] as! [[String:Any]])[0]["referenceAllocationBoundaryOccupiedPixels"] as! Int)>0,
      "real CG boundary occupancy retained as observed evidence")
var parts = safe; parts.unitTextParts = [.init(text:text,frame:safeRect,style:style)]
let partsAudit = audit(parts,budget:&budget)
check(partsAudit["unmeasuredReason"] as? String == "unit-text-parts", "unit part paint unsupported")
check((partsAudit["originalToShapedOwnership"] as! [String:Any])["whole"] is NSNull, "unit ownership not invented")
// Explicit producer ledger omits the first input code unit. The retained
// glyph paint is still safe, so a zero-loss alpha audit cannot hide omission.
var partialLayout = layout
partialLayout.sourceUTF16Ownership = (0..<text.utf16.count).map { NSRange(location:$0+1,length:1) }
var partial = safe; partial.item.text = "누" + text; partial.typography = partialLayout
let partialAudit = audit(partial,budget:&budget)
let ownership = partialAudit["originalToShapedOwnership"] as! [String:Any]
check(ownership["whole"] as? Bool == false, "omitted original prefix recorded separately from retained alpha")
check(ownership["committedParagraphRawComplete"] as? Bool == false, "incomplete source is not certified by zero retained clipping")
for m in partialAudit["modes"] as! [[String:Any]] {
    check(m["clipLossPixels"] as? Int == 0, "zero retained-paint loss can coexist with original omission")
}
var empty = safe; empty.item.text = ""; empty.typography = T.layout(text:"",in:.init(width:10,height:10),style:style)
check(audit(empty,budget:&budget)["unmeasuredReason"] as? String == "no-retained-glyph-bounds", "no glyph paint explicit unknown")
print("PASS \(checks) native final-audit CG/production-text-draw checks; bitmap scope only")
'''

with tempfile.TemporaryDirectory(prefix='aidoku-final-audit-private-') as directory:
    work = Path(directory)
    (work / 'Typography.swift').write_text(typography)
    (work / 'main.swift').write_text(harness)
    started = time.monotonic()
    subprocess.run(['xcrun', 'swiftc', '-O', '-module-cache-path', str(work / 'modules'),
        str(work / 'Typography.swift'), *[str(OVERLAY / (s + '.swift')) for s in sources],
        str(work / 'main.swift'), '-o', str(work / 'probe')], check=True)
    print('private test compile seconds', round(time.monotonic()-started,3), flush=True)
    started = time.monotonic()
    subprocess.run([str(work / 'probe'), str(ROOT / 'Aidoku/Resources/Translation/AidokuSerifKR-Bold.woff2')], check=True)
    print('native test seconds', round(time.monotonic()-started,3), flush=True)
