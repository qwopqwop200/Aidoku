#!/usr/bin/env python3
"""Isolated terminal context regression using real admission and synthetic RGB/alpha."""
import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
ENGINE = ROOT / 'Aidoku/Core/Translation/NativeEngine/Ensemble'
BASE = runpy.run_path(str(Path(__file__).with_name('run-balloon-readability-reflow-smoke.py')))
admission_source_closure = runpy.run_path(
    str(Path(__file__).with_name("native_admission_sources.py"))
)["admission_source_closure"]
SOURCES = admission_source_closure(BASE['SOURCES'] + ['NativeMandatoryDisplayStroke+Composer', 'NativeSourcePixelInterior',
                           'NativeSourceClosedBarrierInterior', 'NativeSourcePhysicalInteriorContext'])
HARNESS = r'''
import CoreGraphics
import Foundation
import Darwin

typealias C = NativeSourcePhysicalInteriorContext
typealias F = C.Primitive
typealias N = NativeFinalTextPaintAdmission
var checks = 0
func check(_ value: Bool, _ reason: String) {
    if !value { FileHandle.standardError.write(Data("FAIL \(checks): \(reason)\n".utf8)); exit(1) }
    checks += 1
}
func phase(_ name: String) { FileHandle.standardError.write(Data("PHASE \(checks): \(name)\n".utf8)) }
let page = CGRect(x:0,y:0,width:96,height:80)
func normalized(_ r: CGRect) -> [Double] { [r.minX/96,r.minY/80,r.width/96,r.height/80].map(Double.init) }
func bytes(_ f: F) throws -> [UInt8] { try NativeMandatoryDisplayStroke.rgba(f.image) }
func samePixels(_ a: F, _ b: F) throws -> Bool { try a.frame == b.frame && bytes(a) == bytes(b) }
func policy() -> NativeTextExpansionPolicy {
    let r = normalized(CGRect(x:4,y:4,width:88,height:72))
    return .init(allowedRectNormalized:r,candidates:[r],maskCoverage:[1],backgroundRisk:[0],
        sourceFontPixels:6,kind:"inside-balloon-mask",maskRectNormalized:r,
        maskSpansNormalized:[4.0/96,92.0/96,4.0/96,92.0/96],
        maskIntervalRowsNormalized:[[4.0/96,92.0/96],[4.0/96,92.0/96]])
}
func original(room: CGRect = CGRect(x:20,y:16,width:56,height:48),
              originalGlyph: CGRect = CGRect(x:42,y:34,width:4,height:9)) -> ([UInt8],[UInt8]) {
    var rgb = [UInt8](repeating:0,count:96*80*3), erased = [UInt8](repeating:0,count:96*80)
    for y in 0..<80 { for x in 0..<96 {
        let inside = room.contains(CGRect(x:x,y:y,width:1,height:1))
        let glyph = originalGlyph.contains(CGRect(x:x,y:y,width:1,height:1))
        let p = y*96+x
        for c in 0..<3 { rgb[p*3+c] = glyph ? 0 : (inside ? 248 : [UInt8(30),60,80][c]) }
        if glyph { erased[p] = 255 }
    }}
    // Non-erased enclosed source hole: raw mask excludes it; envelope may close it.
    for y in 28..<31 { for x in 65..<68 { for c in 0..<3 { rgb[(y*96+x)*3+c] = 0 } }}
    return (rgb,erased)
}
func primitive(_ owner: String, x: Int, y: Int, w: Int = 6, h: Int = 5, font: CGFloat = 6) throws -> F {
    var rgba = [UInt8](repeating:0,count:w*h*4)
    for yy in 0..<h { for xx in 0..<w {
        let p = (yy*w+xx)*4
        let a: UInt8 = xx == 0 ? 1 : (xx == 1 ? 63 : 255)
        rgba[p] = a; rgba[p+3] = a
    }}
    var f = F(image:try NativeMandatoryDisplayStroke.image(rgba,width:w,height:h),
        frame:CGRect(x:x,y:y,width:w,height:h),fontOutputPixels:font)
    f.ownerID = owner; f.hasFinalEffects = true
    return f
}
func inside(_ f: F, guide: CGRect = CGRect(x:35,y:28,width:20,height:20)) -> F {
    var f = f; f.textExpansionPolicy = policy()
    f.textPlacementGuide = .init(rectNormalized:normalized(guide),horizontal:.center,vertical:.center)
    let p = policy(); f.placementDomain = { p.allows($0,page:page) }
    return f
}
func baseline(_ fills: [F]) throws -> C.Tuple {
    let supports = try fills.map { try N.retainedFootprint($0) }
    let fixed = Dictionary(uniqueKeysWithValues:fills.indices.map { (fills[$0].ownerID!,supports[$0].bounds.origin) })
    var a = try N.place(fills,page:page,fixedOrigins:fixed)
    for i in a.audit.indices { a.audit[i]["inheritedSentinel"] = "keep-\(i)" }
    return a
}
var translatedResultsChecked = 0
func refine(_ context: C, _ incumbent: C.Tuple, page: CGRect) -> C.Tuple {
    let result = context.refine(incumbent,page:page)
    check(result.fills.count == incumbent.fills.count,"all refinement calls retain owner count")
    for i in result.fills.indices {
        let a = incumbent.fills[i], b = result.fills[i]
        let dx = b.frame.minX-a.frame.minX, dy = b.frame.minY-a.frame.minY
        let diagnostic = result.audit[i]["sourcePhysicalInterior"] as? [String:Any]
        if dx != 0 || dy != 0 || diagnostic?["status"] as? String == "translated" {
            let cap = floor(a.fontOutputPixels * 0.5)
            check(dx*dx+dy*dy <= cap*cap,"EVERY translated result within independent floor(font*.5) circle")
            check(dx != 0 || dy != 0,"translated result has real nonzero motion")
            check(diagnostic?["status"] as? String == "translated" &&
                (diagnostic?["maxFixedRasterShiftEm"] as? NSNumber)?.doubleValue == 0.5,"actual cap/motion receipt")
            check(a.fontOutputPixels == b.fontOutputPixels && (try? bytes(a)) == (try? bytes(b)),
                "EVERY translated result preserves actual font/RGBA")
            translatedResultsChecked += 1
        }
    }
    return result
}
func info(_ t: C.Tuple, _ i: Int = 0) -> [String:Any] { t.audit[i]["sourcePhysicalInterior"] as! [String:Any] }
func assertUnchanged(_ old: C.Tuple, _ new: C.Tuple, _ reason: String) throws {
    check(old.fills.count == new.fills.count,reason+": no owner dropped")
    for i in old.fills.indices {
        check(try samePixels(old.fills[i],new.fills[i]),reason+": unchanged actual pixels/frame")
        check(new.audit[i]["inheritedSentinel"] as? String == old.audit[i]["inheritedSentinel"] as? String,reason+": inherited audit")
    }
}
func outside(_ support: N.Footprint, room: CGRect) -> Int {
    var result = 0
    for r in support.runs { for x in r.left..<r.right {
        if !room.contains(CGRect(x:x,y:r.y,width:1,height:1)) { result += 1 }
    }}
    return result
}
do {
check(C.maxFixedRasterShiftEm == 0.5,"production cap is the intended half glyph")
let (rgb,erased) = original()
let context = C(rgb:rgb,width:96,height:80,erased:erased,sourceIdentity:"synthetic-original-v1")!
check(C.current == nil,"TaskLocal initially absent")
C.$current.withValue(context) { check(C.current === context,"TaskLocal scope exact instance") }
check(C.current == nil,"TaskLocal scope restored")
check(C(rgb:[],width:96,height:80,erased:erased,sourceIdentity:"bad") == nil,"bad init bytes")
check(C(rgb:rgb,width:-1,height:80,erased:erased,sourceIdentity:"bad") == nil,"bad init dimension")
check(C(rgb:rgb,width:96,height:80,erased:erased,sourceIdentity:"") == nil,"empty identity rejected")
let target = inside(try primitive("target",x:18,y:38))
let peer = try primitive("peer",x:60,y:50,w:4,h:4)
let before = try baseline([target,peer])
phase("fixed prepainted full-alpha relocation")
let after = refine(context,before,page:page)
check(info(after)["status"] as? String == "translated","source evidence selects a real admitted translation: \(info(after))")
check(info(after)["evidenceAvailable"] as? Bool == true,"numeric source evidence available")
check(after.fills[0].frame == target.frame.offsetBy(dx:3,dy:0),"minimum-motion shift includes alpha1 fringe")
check(info(after)["beforeOutsidePixels"] as? Int == 10 && info(after)["afterOutsidePixels"] as? Int == 0,"all nonzero alpha outside accounting")
check(info(after)["blankMarginPixels"] as? Int == 1,"one full blank pixel preferred")
check(try bytes(after.fills[0]) == bytes(before.fills[0]),"exact prepainted RGBA retained")
check(try samePixels(before.fills[1],after.fills[1]),"unrelated actual raster/frame pinned")
check(after.fills[0].textExpansionPolicy == before.fills[0].textExpansionPolicy,"policy immutable")
check(after.audit[1]["inheritedSentinel"] as? String == "keep-1","fresh peer audit keeps inherited diagnostics")
let footprint = try N.retainedFootprint(after.fills[0])
check(footprint.pixels == 30 && outside(footprint,room:CGRect(x:20,y:16,width:56,height:48)) == 0,"actual final effect alpha in physical component")
check(after.fills[0].placementDomain?(CGRect(x:18,y:38,width:1,height:1)) == false,"new domain persists against later escape")
check(after.fills[0].placementDomain?(CGRect(x:65,y:28,width:1,height:1)) == false,"outer envelope never grants new hole paint")
check(info(after)["domainPolicy"] as? String == "outer-containment-raw-plus-static-incumbent-holes-v3" &&
    info(after)["envelopePermitsSourceOcclusion"] as? Bool == false,"envelope policy does not authorize source occlusion")
let escaped = after.fills
let fixedEscape = Dictionary(uniqueKeysWithValues:escaped.indices.map { (escaped[$0].ownerID!, $0 == 0 ? CGPoint(x:18,y:38) : (try! N.retainedFootprint(escaped[$0])).bounds.origin) })
check((try? N.place(escaped,page:page,fixedOrigins:fixedEscape)) == nil,"subsequent actual admission enforces retained pixel domain")
let repeated = refine(context,after,page:page)
check(info(repeated)["status"] as? String == "contained-no-move","cached evidence is idempotent")
try assertUnchanged(after,repeated,"repeat")
var alreadySafe = inside(try primitive("safe-no-prior-domain",x:30,y:38))
alreadySafe.placementDomain = nil
let safeBefore = try baseline([alreadySafe])
let safeAfter = refine(context,safeBefore,page:page)
check(info(safeAfter)["status"] as? String == "contained-no-move","contained owner needs no movement")
check(safeAfter.audit[0]["domainAvailable"] as? Bool == true && safeAfter.audit[0]["domainContained"] as? Bool == true,
    "new no-motion pixel domain has truthful audit")
try assertUnchanged(safeBefore,safeAfter,"contained domain-only update")
phase("raw mask preserved; complementary4 geometric envelope")
var predicted = [UInt8](repeating:0,count:96*80)
for y in 4..<76 { for x in 4..<92 { predicted[y*96+x] = 1 }}
let rawReport = NativeSourcePixelInterior.make(rgb:rgb,width:96,height:80,predicted:predicted,erased:erased,
    source:CGRect(x:35,y:28,width:20,height:20))
check(rawReport.available,"raw report evidence still available")
let rawMask = rawReport.mask!, rawBytes = rawReport.mask!.bytes
func maskPixel(_ mask: NativeSourcePixelInterior.Mask, _ x: Int, _ y: Int) -> UInt8 {
    let xx = x-Int(mask.rect.minX), yy = y-Int(mask.rect.minY)
    guard xx>=0,yy>=0,xx<Int(mask.rect.width),yy<Int(mask.rect.height) else { return 0 }
    return mask.bytes[yy*Int(mask.rect.width)+xx]
}
check(maskPixel(rawMask,65,28) == 0,"authoritative raw report still excludes non-erased hole")
let envelope = NativeSourcePixelInterior.outerEnvelope(rawMask)!
check(envelope.rect == rawMask.rect && maskPixel(envelope,65,28) == 1,"only envelope closes enclosed non-erased hole")
check(envelope.bytes.reduce(0) { $0+Int($1) }-rawBytes.reduce(0) { $0+Int($1) } == 9,"exact enclosed hole area added")
check(rawReport.mask!.bytes == rawBytes && rawReport.domainPixels == rawBytes.reduce(0) { $0+Int($1) },
    "helper leaves raw make/report semantics untouched")
var closed = [UInt8](repeating:0,count:81)
for y in 1...7 { for x in 1...7 { closed[y*9+x] = 1 }}
closed[4*9+4] = 0
let smallRect = CGRect(x:10,y:20,width:9,height:9)
let closedEnvelope = NativeSourcePixelInterior.outerEnvelope(.init(rect:smallRect,bytes:closed))!
check(closedEnvelope.bytes[4*9+4] == 1 && closedEnvelope.bytes[0] == 0,"enclosed hole filled; exterior rim never flooded")
var notch = closed
for y in 0...3 { notch[y*9+4] = 0 }
let openEnvelope = NativeSourcePixelInterior.outerEnvelope(.init(rect:smallRect,bytes:notch))!
check(openEnvelope.bytes == notch,"cardinal open notch and exterior remain byte-exact")
var diagonal = closed
for k in 1...3 { diagonal[k*9+k] = 0 }
let diagonalEnvelope = NativeSourcePixelInterior.outerEnvelope(.init(rect:smallRect,bytes:diagonal))!
check(diagonalEnvelope.bytes[4*9+4] == 1,"diagonal-only channel is enclosed under complementary4 topology")
check(NativeSourcePixelInterior.outerEnvelope(.init(rect:smallRect,bytes:[])) == nil,"envelope rejects malformed allocation")
phase("enclosed leftover must not create false motion")
let overHole = inside(try primitive("existing-over-leftover",x:64,y:27))
let overHoleBefore = try baseline([overHole])
let overHoleAfter = refine(context,overHoleBefore,page:page)
check(info(overHoleAfter)["status"] as? String == "contained-no-move" &&
    info(overHoleAfter)["beforeOutsidePixels"] as? Int == 0,"internal leftover no longer drives a rim motion")
try assertUnchanged(overHoleBefore,overHoleAfter,"internal-hole incumbent")
check(info(overHoleAfter)["envelopeDomainPixels"] as? Int == 2688 &&
      info(overHoleAfter)["rawDomainPixels"] as? Int == 2679,"raw and geometric evidence explicitly separated")
phase("static partial-hole grandfathering, no moving paint exemption")
let partial = inside(try primitive("partial-hole",x:64,y:27,w:2,h:5))
let partialBefore = try baseline([partial])
let partialAfter = refine(context,partialBefore,page:page)
try assertUnchanged(partialBefore,partialAfter,"old partial-hole alpha")
check(info(partialAfter)["status"] as? String == "contained-no-move" &&
    info(partialAfter)["incumbentHolePixelsAllowed"] as? Int == 3,"only actual incumbent alpha hole pixels grandfathered")
check(info(partialAfter)["outerBeforeOutsidePixels"] as? Int == 0 &&
    info(partialAfter)["rawBeforeOutsidePixels"] as? Int == 3 &&
    info(partialAfter)["occlusionBeforeOutsidePixels"] as? Int == 0,"outer vs raw vs occlusion diagnostics distinct")
check(partialAfter.fills[0].placementDomain?(CGRect(x:65,y:28,width:1,height:1)) == true &&
    partialAfter.fills[0].placementDomain?(CGRect(x:66,y:28,width:1,height:1)) == false,
    "hole allowance covers old alpha1/63 membership only, not whole hole")
let partialSupport = try N.retainedFootprint(partialAfter.fills[0])
let translatedAllowance = ["partial-hole":partialSupport.bounds.origin.applying(CGAffineTransform(translationX:1,y:0))]
check((try? N.place(partialAfter.fills,page:page,fixedOrigins:translatedAllowance)) == nil,
    "page-fixed grandfather pixels cannot move along with incumbent")
var protect = target
let protectedHole = CGRect(x:65,y:28,width:3,height:3), sourcePolicy = policy()
protect.placementDomain = { sourcePolicy.allows($0,page:page) && !$0.intersects(protectedHole) }
let protectedAfter = refine(context,try baseline([protect]),page:page)
check(info(protectedAfter)["status"] as? String == "translated" &&
    protectedAfter.fills[0].placementDomain?(CGRect(x:65,y:28,width:1,height:1)) == false,
    "envelope cannot widen original placementDomain")
phase("context open notch remains real outside")
var notchRGB = rgb
for y in 36..<44 { for x in 20..<30 { for c in 0..<3 { notchRGB[(y*96+x)*3+c] = [UInt8(30),60,80][c] }}}
let notchContext = C(rgb:notchRGB,width:96,height:80,erased:erased,sourceIdentity:"open-notch")!
let notchBefore = try baseline([inside(try primitive("notch-target",x:25,y:38))])
let notchAfter = refine(notchContext,notchBefore,page:page)
let notchRaw = NativeSourcePixelInterior.make(rgb:notchRGB,width:96,height:80,predicted:predicted,erased:erased,
    source:CGRect(x:35,y:28,width:20,height:20))
let notchOuter = NativeSourcePixelInterior.outerEnvelope(notchRaw.mask!)!
let notchSupport = try N.retainedFootprint(notchBefore.fills[0])
func minimumLegalShiftSquared(_ support: N.Footprint, mask: NativeSourcePixelInterior.Mask, radius: Int) -> Int? {
    var minimum: Int?
    for dy in -radius...radius { for dx in -radius...radius where dx*dx+dy*dy <= radius*radius {
        let legal = support.runs.allSatisfy { run in
            (run.left..<run.right).allSatisfy { maskPixel(mask,$0+dx,run.y+dy) != 0 }
        }
        if legal { minimum = min(minimum ?? Int.max,dx*dx+dy*dy) }
    }}
    return minimum
}
let notchCap = Int(floor(notchBefore.fills[0].fontOutputPixels*0.5))
check(notchRaw.available && info(notchAfter)["evidenceAvailable"] as? Bool == true,"large-notch source evidence valid")
check(minimumLegalShiftSquared(notchSupport,mask:notchOuter,radius:notchCap) == nil &&
    (minimumLegalShiftSquared(notchSupport,mask:notchOuter,radius:12) ?? 0) > notchCap*notchCap,
    "unchanged large notch mathematically requires motion beyond cap, despite a larger safe fit")
check(info(notchAfter)["status"] as? String == "no-safe-proposal-unresolved" &&
    (info(notchAfter)["beforeOutsidePixels"] as? Int ?? 0)>0,"large notch retained because no half-glyph fit")
check(maskPixel(notchOuter,25,38) == 0 &&
    notchAfter.fills[0].placementDomain?(CGRect(x:25,y:38,width:1,height:1)) == true,
    "open notch stays excluded from evidence; failed new domain never replaces incumbent")
try assertUnchanged(notchBefore,notchAfter,"large-notch beyond-cap incumbent")
phase("narrow open notch has a real half-glyph safe fit")
var narrowRGB = rgb
for y in 36..<44 { for x in 20..<24 { for c in 0..<3 { narrowRGB[(y*96+x)*3+c] = [UInt8(30),60,80][c] }}}
let narrowContext = C(rgb:narrowRGB,width:96,height:80,erased:erased,sourceIdentity:"narrow-notch")!
let narrowBefore = try baseline([inside(try primitive("narrow-notch-target",x:22,y:38)),peer])
let narrowAfter = refine(narrowContext,narrowBefore,page:page)
let narrowRaw = NativeSourcePixelInterior.make(rgb:narrowRGB,width:96,height:80,predicted:predicted,erased:erased,
    source:CGRect(x:35,y:28,width:20,height:20))
let narrowSupport = try N.retainedFootprint(narrowBefore.fills[0])
check(narrowRaw.available && minimumLegalShiftSquared(narrowSupport,mask:narrowRaw.mask!,radius:3) != nil,
    "separate open-notch fixture independently has safe alpha fit within half glyph")
check(info(narrowAfter)["status"] as? String == "translated" &&
    narrowAfter.fills[0].frame == narrowBefore.fills[0].frame.offsetBy(dx:3,dy:0),"real narrow-rim correction at cap")
check(info(narrowAfter)["beforeOutsidePixels"] as? Int == 10 &&
    info(narrowAfter)["occlusionAfterOutsidePixels"] as? Int == 0,"narrow notch full alpha1 support corrected")
check(try bytes(narrowBefore.fills[0]) == bytes(narrowAfter.fills[0]) &&
    samePixels(narrowBefore.fills[1],narrowAfter.fills[1]),"narrow repair preserves owner bytes and pinned peer pixels")
check(narrowAfter.fills[0].placementDomain?(CGRect(x:22,y:38,width:1,height:1)) == false,"admitted raw domain still excludes open notch")
phase("odd-size floor cap boundary and impossible one-pixel-over-cap repair")
let oddBefore = try baseline([inside(try primitive("odd-font",x:18,y:38,font:5))])
let oddAfter = refine(context,oddBefore,page:page)
check(info(oddAfter)["status"] as? String == "translated" &&
    oddAfter.fills[0].frame == oddBefore.fills[0].frame.offsetBy(dx:2,dy:0) &&
    info(oddAfter)["blankMarginPixels"] as? Int == 0,"floor(5*.5)=2 permits exact boundary, not rounded3")
let overCapBefore = try baseline([inside(try primitive("one-pixel-beyond-cap",x:17,y:38,font:5))])
let overCapAfter = refine(context,overCapBefore,page:page)
let overCapSupport = try N.retainedFootprint(overCapBefore.fills[0])
check(minimumLegalShiftSquared(overCapSupport,mask:rawMask,radius:2) == nil &&
    minimumLegalShiftSquared(overCapSupport,mask:rawMask,radius:3) == 9,
    "one pixel beyond floor cap independently needs3px")
check(info(overCapAfter)["status"] as? String == "no-safe-proposal-unresolved","larger needed shift never occurs")
try assertUnchanged(overCapBefore,overCapAfter,"one-pixel-over-cap")
phase("retained original ink risk veto inside envelope")
var inkRGB = rgb
let retainedInk = CGRect(x:71,y:38,width:1,height:5)
for y in 38..<43 { for x in 71..<72 { for c in 0..<3 { inkRGB[(y*96+x)*3+c] = 0 }}}
let inkContext = C(rgb:inkRGB,width:96,height:80,erased:erased,sourceIdentity:"retained-ink")!
let inkBefore = try baseline([inside(try primitive("ink-target",x:74,y:38,w:4))])
check(N.retainedSourceRiskGate == nil,"nil-risk protected-hole fixture actually has no risk gate")
let nilRiskInkAfter = refine(inkContext,inkBefore,page:page)
check(info(nilRiskInkAfter)["status"] as? String == "translated","legal raw-domain alternate admitted without risk gate")
let nilRiskSupport = try N.retainedFootprint(nilRiskInkAfter.fills[0])
check(!nilRiskSupport.runs.contains { retainedInk.intersects(CGRect(x:$0.left,y:$0.y,width:$0.right-$0.left,height:1)) },
    "nil risk gate cannot admit NEW styled alpha inside protected non-erased hole")
check(info(nilRiskInkAfter)["newEnclosedHoleAlphaPixels"] as? Int == 0 &&
    nilRiskInkAfter.fills[0].placementDomain?(retainedInk) == false,
    "admitted domain retains protected-hole exclusion for future moves")
check(try bytes(nilRiskInkAfter.fills[0]) == bytes(inkBefore.fills[0]),"nil-risk repair still fixed-raster exact")
var inkVetoes = 0
let inkGate = N.RetainedSourceRiskGate { _,next in
    let touches = next.runs.contains { run in
        retainedInk.intersects(CGRect(x:run.left,y:run.y,width:run.right-run.left,height:1))
    }
    if touches { inkVetoes += 1 }
    return !touches
}
let inkAfter = N.$retainedSourceRiskGate.withValue(inkGate) { refine(inkContext,inkBefore,page:page) }
check(inkVetoes == 0,"occlusion domain rejects new hole paint before optional risk gate")
if info(inkAfter)["status"] as? String == "translated" {
    let next = try N.retainedFootprint(inkAfter.fills[0])
    check(!next.runs.contains { retainedInk.intersects(CGRect(x:$0.left,y:$0.y,width:$0.right-$0.left,height:1)) },
        "positive risk-approved alternative avoids retained ink")
} else {
    try assertUnchanged(inkBefore,inkAfter,"retained-ink veto fallback")
}
phase("no safe original-domain intersection")
var fixedTarget = target
let onlyOld = target.frame
fixedTarget.placementDomain = { onlyOld.contains($0) }
let noSafeBefore = try baseline([fixedTarget,peer])
let noSafeAfter = refine(context,noSafeBefore,page:page)
try assertUnchanged(noSafeBefore,noSafeAfter,"no safe")
check(info(noSafeAfter)["status"] as? String == "no-safe-proposal-unresolved","explicit unresolved status")
check(noSafeAfter.fills[0].placementDomain?(CGRect(x:18,y:38,width:1,height:1)) == true,"failed new domain never poisons incumbent")
check(info(noSafeAfter)["retainedAlphaContained"] == nil,"no false physical pass")
phase("retained risk veto unknown and false")
for verdict: Bool? in [nil,false] {
    let veto = N.RetainedSourceRiskGate { old,new in
        check(old.pixels == 30 && new.pixels == 30,"risk gate sees full actual retained alpha")
        return verdict
    }
    let result = N.$retainedSourceRiskGate.withValue(veto) { refine(context,before,page:page) }
    try assertUnchanged(before,result,"risk veto")
    check(info(result)["status"] as? String == "no-safe-proposal-unresolved","unknown risk is not consent")
}
let consent = N.$retainedSourceRiskGate.withValue(.init { _,_ in true }) { refine(context,before,page:page) }
check(info(consent)["status"] as? String == "translated","positive source risk permits admitted candidate")
phase("unknown and kill switch")
let noErased = C(rgb:rgb,width:96,height:80,erased:[UInt8](repeating:0,count:96*80),sourceIdentity:"unknown")!
let unknown = refine(noErased,before,page:page)
try assertUnchanged(before,unknown,"unknown")
check(info(unknown)["evidenceAvailable"] as? Bool == false && info(unknown)["retainedAlphaContained"] == nil,"unknown never claims pass")
setenv("AIDOKU_SOURCE_PHYSICAL_INTERIOR","0",1)
let off = refine(context,before,page:page)
unsetenv("AIDOKU_SOURCE_PHYSICAL_INTERIOR")
check(NSDictionary(dictionary:off.audit[0]).isEqual(to:before.audit[0]),"kill switch exact audit")
try assertUnchanged(before,off,"off")
phase("raw source contour and legacy shadow actual footprints")
for useContour in [true,false] {
    var raw = try primitive("styled",x:19,y:38,w:2,h:2)
    raw.hasFinalEffects = false; raw.sourceContourOnly = useContour
    raw.sourceStyle = .init(sourceFontPixels:6,bands:[.init(rgb:[160,60,190],width:1)],
        shadow:useContour ? nil : .init(rgb:[20,80,100],offset:[-3,0]))
    raw = inside(raw)
    let styledBefore = try baseline([raw,peer])
    let old = try N.retainedFootprint(styledBefore.fills[0])
    let styledAfter = refine(context,styledBefore,page:page)
    check(info(styledAfter)["status"] as? String == (useContour ? "translated" : "no-safe-proposal-unresolved"),
    "actual bands/shadow honor fixed raster cap \(info(styledAfter))")
    let new = try N.retainedFootprint(styledAfter.fills[0])
    check(new.pixels == old.pixels && (useContour ? outside(new,room:CGRect(x:21,y:17,width:54,height:46)) == 0 :
    new.bounds == old.bounds && old.bounds.minX+floor(raw.fontOutputPixels*0.5)<20),
    "entire styled alpha admitted or retained when shadow cannot reach room within cap")
    if !useContour { try assertUnchanged(styledBefore,styledAfter,"over-cap legacy shadow") }
    check(try bytes(styledAfter.fills[0]) == bytes(styledBefore.fills[0]),"actual original fill unchanged")
    let painted = try NativeAOTTranslationPageComposer.mandatoryStrokeLayer(restored:
        NativeMandatoryDisplayStroke.image([UInt8](repeating:255,count:96*80*4),width:96,height:80),
        fills:styledAfter.fills,expectedItems:2,textComplete:true)
    check(painted.audit["finalCompositeAlphaVerified"] as? Bool == true,"real final Composer raster count")
}
phase("zero-margin fallback only for prior escape")
let (thinRGB,thinErased) = original(room:CGRect(x:20,y:36,width:12,height:5),originalGlyph:CGRect(x:25,y:38,width:1,height:1))
let thin = C(rgb:thinRGB,width:96,height:80,erased:thinErased,sourceIdentity:"thin")!
let thinTarget = inside(try primitive("thin",x:18,y:36),guide:CGRect(x:23,y:36,width:7,height:5))
let thinBefore = try baseline([thinTarget])
let thinAfter = refine(thin,thinBefore,page:page)
check(info(thinAfter)["status"] as? String == "translated" && info(thinAfter)["blankMarginPixels"] as? Int == 0,"zero-margin rescue when prior outside>0")
var flush = thinBefore
flush.fills[0].frame.origin.x = 20
let flushAfter = refine(thin,flush,page:page)
check(info(flushAfter)["status"] as? String == "contained-no-move" &&
    info(flushAfter)["outerBlankMarginPixels"] as? Int == 0,"outer-contained incumbent retained without margin-only polish")
try assertUnchanged(flush,flushAfter,"already contained flush")
phase("retained cohort anchor and actual audit consistency")
var ca = target, cb = try primitive("cohort-peer",x:60,y:38,w:4,h:4)
let packet = NativeSourceClusterAlignment(groupID:"source-cohort",axis:.top,anchorNormalized:38.0/80)
ca.sourceClusterAlignment = packet; cb.sourceClusterAlignment = packet
let cohort = try baseline([ca,cb])
let movedCohort = refine(context,cohort,page:page)
check(info(movedCohort)["status"] as? String == "translated","free-axis repair retains real cohort anchor")
check(movedCohort.fills.allSatisfy { $0.frame.minY == 38 },"cohort shared axis intact")
check(try samePixels(cohort.fills[1],movedCohort.fills[1]),"cohort peer fixed")
let supports = try movedCohort.fills.map { try N.retainedFootprint($0) }
try N.verifyRetainedPlacement(movedCohort.fills,footprints:supports,page:page)
checks += 1
phase("same-body relaxation must refresh unrelated audits")
var ba = inside(try primitive("body-target",x:72,y:38)), bb = try primitive("body-peer",x:84,y:50,w:4,h:4)
let body = NativeBalloonPlacement(bodyID:"synthetic-body",rectNormalized:normalized(CGRect(x:72,y:38,width:20,height:20)),
    preserveSourceOffsets:true,biasNormalized:[0,0],flow:.row,paddingEm:0,gapEm:0,
    maskSHA256:String(repeating:"a",count:64),order:0)
ba.balloonPlacement = body
var peerBody = body; peerBody.order = 1; bb.balloonPlacement = peerBody
bb.textPlacementGuide = .init(rectNormalized:normalized(CGRect(x:84,y:50,width:4,height:4)),horizontal:.center,vertical:.center)
bb.placementDomain = { page.contains($0) }
let bodyBefore = try baseline([ba,bb])
check(bodyBefore.fills.allSatisfy { !$0.balloonTargetRelaxed },"fixture starts with actual strict body targets")
let bodyAfter = refine(context,bodyBefore,page:page)
check(info(bodyAfter)["status"] as? String == "translated","body repair admitted: \(info(bodyAfter))")
check(bodyAfter.fills.allSatisfy { $0.balloonTargetRelaxed },"actual solver relaxes complete body")
check(bodyAfter.audit.allSatisfy { $0["balloonBodyPlaced"] as? Bool == false },"all fresh audits agree with relaxed body")
check(bodyBefore.audit[1]["balloonBodyPlaced"] as? Bool == true,"unrelated audit actually required refresh")
check(bodyAfter.audit[1]["inheritedSentinel"] as? String == "keep-1","fresh whole-body audit retains prior owner diagnostics")
check(try samePixels(bodyBefore.fills[1],bodyAfter.fills[1]),"relaxed unrelated owner still byte/position exact")
let bodySupports = try bodyAfter.fills.map { try N.retainedFootprint($0) }
try N.verifyRetainedPlacement(bodyAfter.fills,footprints:bodySupports,page:page)
checks += 1
check(translatedResultsChecked>0,"cap assertions exercised real translations")
print("PASS \(checks) source physical interior context checks; \(translatedResultsChecked) translated results cap-checked; actual native admission/footprints, no dataset RGB")
} catch {
    FileHandle.standardError.write(Data("FAIL after \(checks): \(error)\n".utf8)); exit(1)
}
'''


def main():
    with tempfile.TemporaryDirectory(prefix='aidoku-physical-interior-context-') as directory:
        cache = Path(directory)
        composer = (ENGINE/'NativeAOTTranslationPageComposer.swift').read_text()
        text_layer = composer[composer.index('    struct TextLayer {'):composer.index('    struct Result {')]
        failure = re.search(r'    enum Failure: Error \{.*?\n    \}',composer,re.S).group()
        (cache/'ComposerTypes.swift').write_text('import CoreGraphics\nimport Foundation\nfinal class NativeAOTTranslationPageComposer {\n'+text_layer+failure+'\n}\n')
        hashes = {}
        for name in SOURCES:
            data = (ENGINE/(name+'.swift')).read_bytes()
            (cache/(name+'.swift')).write_bytes(data)
            hashes[name+'.swift'] = hashlib.sha256(data).hexdigest()
        (cache/'main.swift').write_text(HARNESS)
        env = {k:v for k,v in os.environ.items() if not k.startswith('AIDOKU_')}
        env['CLANG_MODULE_CACHE_PATH'] = str(cache/'clang-modules')
        binary = cache/'check'
        start = time.monotonic()
        subprocess.run(['xcrun','swiftc','-O','-module-cache-path',str(cache/'swift-modules'),
            *[str(cache/(name+'.swift')) for name in SOURCES],str(cache/'ComposerTypes.swift'),
            str(cache/'main.swift'),'-o',str(binary)],check=True,env=env)
        compiled = time.monotonic()
        print(f'Isolated compile seconds: {compiled-start:.3f}',flush=True)
        subprocess.run([str(binary)],check=True,env=env)
        print(json.dumps(dict(compileSeconds=round(compiled-start,3),testSeconds=round(time.monotonic()-compiled,3),
            cache=str(cache),sourceSHA256=hashes,scriptSHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            datasetImages=0,sharedBuilds=0)))


if __name__=='__main__':main()
