#!/usr/bin/env python3
"""Test production contour placement and invocation memo, not pixel parity."""
from pathlib import Path
import argparse
import fcntl
import json
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--geometry-audit", type=Path, help="Saved native layouts; numerical split stage only, not renderer/GT replay")
parser.add_argument("--emit-swift", action="store_true", help="Print the fixture program without building or touching any cache")
parser.add_argument("--isolated-cache", action="store_true", help="Build in a temporary private cache, leaving shared caches untouched")
parser.add_argument("--debug", action="store_true", help="Use unoptimized debug symbols to locate fixture traps")
args = parser.parse_args()

root = Path(__file__).resolve().parents[2]
overlay = root / "Aidoku/Core/Translation/NativeEngine/Overlay"
layout = (overlay / "NativeTranslationLayout.swift").read_text()
interior = layout[layout.index("struct NativeTranslationBalloonInterior:"):
                  layout.index("struct NativeTranslationBalloonUnit:")]
program = "import CoreGraphics\nimport Foundation\n" + interior
program += (overlay / "NativeTextBoxContainment.swift").read_text()
program += (overlay / "NativeSourceCoverageWitness.swift").read_text()
program += (overlay / "NativeTextBoxSurfaceMemo.swift").read_text()
capacity = (root / 'Aidoku/Core/Translation/NativeEngine/Ensemble/NativeRawBalloonCapacity.swift').read_text()
capacity = capacity[capacity.index('    struct Contour {'):capacity.index('    static func attributes(')]
program += "enum NativeRawBalloonCapacity {\n" + capacity + "\n}\n"
painter = (root / 'Aidoku/Core/Translation/NativeEngine/Ensemble/NativeAOTRawTextPainter.swift').read_text()
policy = painter[painter.index('    static func renderMaskSurface('):painter.index('    private static func renderImpl(')]
program += "enum NativeAOTMaskPolicy {\n" + policy + "\n}\n"
program += r'''
// Background truth is supplied only to the synthetic fixture, never the predictor.
let faceRect = CGRect(x: 0, y: 0, width: 96, height: 96)
let faceOwner = CGRect(x: 32, y: 24, width: 32, height: 48)
let faceSurface = NativeTextBoxContainment.Surface(rect: faceRect,
    spans: Array(repeating: (CGFloat(4), CGFloat(92)), count: 96), color: nil)
for color in [[158, 157, 194], [125, 148, 153], [225, 174, 207], [20, 22, 24], [248, 249, 246]] {
    var pixels = [UInt8](repeating: 255, count: 96 * 96 * 4)
    for y in 0..<96 { for x in 0..<96 {
        let text = faceOwner.contains(CGPoint(x: x, y: y))
        for c in 0..<3 { pixels[(y * 96 + x) * 4 + c] = UInt8(text ? [245, 0, 130][c] : color[c]) }
    } }
    let prediction = try NativeTextBoxContainment.faceColor(rgba: pixels, width: 96, height: 96,
        roi: faceRect, surface: faceSurface, owner: faceOwner, excluding: [])
    precondition(prediction == color.map(Double.init), "Interior face must not inherit glyph/outline colors")
    let unavailable = try NativeTextBoxContainment.faceColor(rgba: pixels, width: 96, height: 96,
        roi: faceRect, surface: faceSurface, owner: faceRect, excluding: [])
    precondition(unavailable == nil,
        "No independent face evidence must remain unknown")
}
let rounded = NativeTextBoxContainment.Surface(rect: faceRect,
    spans: (0..<96).map { y in
        let t = (CGFloat(y) + 0.5 - 48) / 48
        let half = 46 * sqrt(max(0, 1 - t * t))
        return (48 - half, 48 + half)
    }, color: nil)
let panel = rounded.rectangularPanel(covering: faceOwner, near: faceRect, within: faceRect)!
precondition(rounded.contains(panel) && !rounded.contains(faceRect))
// The actual default AOT boundary, including normalized contour transport.
let maskRecord: [String: Any] = ["rect": [0.1,0.1,0.8,0.8], "center": [0.5,0.5],
    "spans": [0.1,0.9,0.1,0.9], "contourVerified": true, "modelEstimated": true,
    "nativeMaskSHA256": String(repeating:"a",count:64)]
let decodedMask = try JSONDecoder().decode(NativeTranslationBalloonInterior.self,
    from:JSONSerialization.data(withJSONObject:maskRecord))
precondition(decodedMask.nativeMaskSHA256 == String(repeating:"a",count:64))
let sourceMask = NativeAOTMaskPolicy.renderMaskSurface(raw:["balloonInterior":maskRecord,"sourceBounds":[0.2,0.2,0.2,0.2],"text":"translation"],
    viewport:CGSize(width:200,height:100),scale:2)!
precondition(sourceMask.contains(CGRect(x:50,y:30,width:200,height:100)))
precondition(!sourceMask.contains(CGRect(x:39,y:30,width:200,height:100)))
var estimatedOnly = maskRecord;estimatedOnly.removeValue(forKey:"nativeMaskSHA256")
precondition(NativeAOTMaskPolicy.renderMaskSurface(raw:["balloonInterior":estimatedOnly,"sourceBounds":[0.2,0.2,0.2,0.2],"text":"translation"],
    viewport:CGSize(width:200,height:100),scale:2) == nil)
let targetContour = NativeRawBalloonCapacity.contour(raw:["balloonInterior":maskRecord],viewport:CGSize(width:100,height:100))!
precondition(NativeRawBalloonCapacity.isConnected(targetContour,raw:["text":"translation","sourceBounds":[0.2,0.2,0.2,0.2]],viewport:CGSize(width:100,height:100)))
for inactive in [["text":"translation","sourceBounds":[0.89,0.89,0.1,0.1]],
                 ["text":"translation","sourceBounds":[0.2,0.2,0.2,0.2],"sourceTextOnly":true],
                 ["text":"translation","sourceBounds":[0.2,0.2,0.2,0.2],"keptLettering":true],
                 ["text":"   ","sourceBounds":[0.2,0.2,0.2,0.2]],
                 ["text":"translation"]] as [[String:Any]] {
    precondition(!NativeRawBalloonCapacity.isConnected(targetContour,raw:inactive,viewport:CGSize(width:100,height:100)))
    precondition(NativeAOTMaskPolicy.renderMaskSurface(raw:inactive.merging(["balloonInterior":maskRecord]) {_,new in new},viewport:CGSize(width:100,height:100),scale:1) == nil)
}
// Seventy percent is based on the original text area, never balloon area.
precondition(NativeRawBalloonCapacity.isConnected(targetContour,raw:["text":"translation","sourceBounds":[0.83,0.3,0.1,0.2]],viewport:CGSize(width:100,height:100)))
precondition(!NativeRawBalloonCapacity.isConnected(targetContour,raw:["text":"translation","sourceBounds":[0.84,0.3,0.1,0.2]],viewport:CGSize(width:100,height:100)))
// Outside rendered boxes are translated back inside without cutting any glyphs.
let escaped = CGRect(x:87.25,y:30.5,width:20,height:30)
let refitted = rounded.containedRenderBox(escaped,within:faceRect,margin:3)!
precondition(refitted.size == escaped.size && rounded.contains(refitted.insetBy(dx:-3,dy:-3)))
precondition(abs((refitted.minX-escaped.minX).rounded()-(refitted.minX-escaped.minX))<1e-8)
let protectedPeer = CGRect(x:60,y:15,width:20,height:65)
let peerRefit = rounded.containedRenderBox(escaped,within:faceRect,margin:3,protectedRects:[protectedPeer])!
precondition(!peerRefit.insetBy(dx:-3,dy:-3).intersects(protectedPeer))
precondition(rounded.containedRenderBox(faceRect,within:faceRect,margin:3) == nil)
precondition(rounded.containedRenderBox(escaped,within:faceRect,margin:.nan) == nil)
// The AOT painter requests fixed-size grown frames with a full boundary halo.
let renderSeed = CGRect(x: 38, y: 35, width: 20, height: 20)
let renderWanted = CGRect(x: 20, y: 25, width: 55, height: 45)
let expanded = rounded.inscribed(near: renderWanted, within: faceRect,
    required: renderWanted.size, boundaryInset: 3)!
precondition(expanded.width*expanded.height > renderSeed.width*renderSeed.height)
precondition(rounded.contains(expanded.insetBy(dx: -3, dy: -3)))
let renderPeer = CGRect(x: 60, y: 20, width: 20, height: 60)
let peerLimited = rounded.inscribed(near: renderSeed, within: faceRect,
    required: CGSize(width: 30, height: 40), accepts: { frame in
        !frame.insetBy(dx: -1, dy: -1).intersects(renderPeer)
    }, xPlacements: { low, high, _ in [max(low,min(high,renderPeer.minX-1-30))] }, boundaryInset: 1)!
precondition(peerLimited.maxX+1 <= renderPeer.minX+1e-8)
precondition(rounded.inscribed(near: faceRect, within: faceRect,
    required: faceRect.size, boundaryInset: 3) == nil)
let neck = NativeTextBoxContainment.Surface(rect: CGRect(x: 0, y: 0, width: 100, height: 100),
    spans: (0..<100).map { row in row < 50 ? (CGFloat(10), CGFloat(90)) : (CGFloat(40), CGFloat(60)) }, color: nil)
precondition(!neck.contains(CGRect(x: 20, y: 20, width: 60, height: 60)),
    "Bounding-box containment must not bridge a narrowed balloon neck")
precondition(neck.contains(CGRect(x: 42, y: 20, width: 16, height: 60)))
precondition(!neck.contains(.null) && !neck.contains(.zero))
let narrow = NativeTextBoxContainment.Surface(rect: CGRect(x: 0, y: 0, width: 12, height: 80),
    spans: Array(repeating: (CGFloat(0), CGFloat(12)), count: 80), color: nil)
let narrowOwner = CGRect(x: 0.25, y: 10, width: 11.5, height: 40)
precondition(narrow.rectangularPanel(covering: narrowOwner, near: narrow.rect, within: narrow.rect) == nil)
let exactCover = narrow.rectangularPanel(covering: narrowOwner, near: narrowOwner, within: narrow.rect,
    allowsExactCover: true, boundaryInset: 0.125)!
precondition(exactCover.contains(narrowOwner) && narrow.contains(exactCover))
precondition(narrow.inscribed(near: narrowOwner, within: narrow.rect, required: narrowOwner.size,
    boundaryInset: -1) == nil)
// Source and translated ink guards are independent obligations, in output pixels.
var coverageFailures = 0
func coverageCheck(_ condition: Bool, _ details: @autoclosure () -> String) {
    if !condition {
        coverageFailures += 1
        FileHandle.standardError.write(Data(("COVERAGE FAILURE: " + details() + "\n").utf8))
    }
}
for scale in [CGFloat(0.25), 1, 3.125] {
    let pixel = 1 / scale
    let sourceGuard = faceOwner.insetBy(dx: -pixel, dy: -pixel)
    let guardedPanel = rounded.rectangularPanel(covering: sourceGuard, near: faceRect,
        within: faceRect, allowsExactCover: true, boundaryInset: pixel)!
    coverageCheck(guardedPanel.contains(sourceGuard)
        && rounded.contains(guardedPanel.insetBy(dx: -pixel, dy: -pixel)),
        "Output scale \(scale): panel \(guardedPanel), expanded \(guardedPanel.insetBy(dx: -pixel, dy: -pixel)) loses source guard or output-pixel boundary clearance")
    let fillBounds = CGRect(x: guardedPanel.minX + pixel, y: guardedPanel.minY + pixel,
        width: 6, height: 6)
    let outline = pixel * 4
    // Typography.layout already adds outlineWidth / 2 to glyphBounds. The
    // renderer must add only glow/AA here, rather than counting the stroke twice.
    let glyphBounds = fillBounds.insetBy(dx: -outline / 2, dy: -outline / 2)
    coverageCheck(guardedPanel.contains(fillBounds.insetBy(dx: -pixel, dy: -pixel))
        && !guardedPanel.contains(glyphBounds.insetBy(dx: -pixel, dy: -pixel)),
        "Already outlined glyphBounds plus AA must reject fill-only edge clearance")
    let edgeOwner = CGRect(x: pixel / 2, y: 20, width: 8, height: 20)
    coverageCheck(narrow.rectangularPanel(covering: edgeOwner, near: narrow.rect,
        within: narrow.rect, allowsExactCover: true, boundaryInset: pixel) == nil,
        "Exact-cover fallback must abstain when boundary clearance is infeasible")
}
var witnessPixels = [UInt8](repeating: 240, count: 96 * 96 * 4)
for i in 0..<(96 * 96) { witnessPixels[i * 4 + 3] = 255 }
for origin in [30, 66] {
    for y in 22..<42 { for x in origin..<(origin + 10) {
        let ink = x >= origin + 2 && x < origin + 8 && y >= 24 && y < 40
        let rgb = ink ? [0, 0, 0] : [255, 0, 0]
        for c in 0..<3 { witnessPixels[(y * 96 + x) * 4 + c] = UInt8(rgb[c]) }
    } }
}
let witness = try NativeSourceCoverageWitness.bounds(rgba: witnessPixels, width: 96, height: 96,
    roi: faceRect, surface: faceSurface, foreground: [0, 0, 0], stroke: [255, 0, 0],
    background: [240, 240, 240], peers: [], maximumGlyphSpan: 20 * 2)
coverageCheck(witness?.contains(CGRect(x: 32, y: 24, width: 6, height: 16)) == true
    && witness?.contains(CGRect(x: 68, y: 24, width: 6, height: 16)) == true,
    "Unassigned original lettering outside the OCR owner must remain in the covering witness")
let ownedWitness = try NativeSourceCoverageWitness.bounds(rgba: witnessPixels, width: 96, height: 96,
    roi: faceRect, surface: faceSurface, foreground: [0, 0, 0], stroke: [255, 0, 0],
    background: [240, 240, 240], peers: [CGRect(x: 60, y: 20, width: 20, height: 25)], maximumGlyphSpan: 20 * 2)
coverageCheck(ownedWitness.map { $0.maxX < 60 } == true,
    "Other paragraph ownership must not enter the witness; retained outlined owner must remain observable")
// Authored colored source roles; the owner omits a complete second glyph.
// Check stroke coverage, coordinate projection, and actual backing admission.
for colors in [([0, 0, 0], [255, 0, 0], [240, 240, 240]),
               ([20, 40, 60], [240, 245, 250], [125, 148, 153]),
               ([245, 215, 180], [15, 25, 35], [158, 157, 194])] {
    var pixels = [UInt8](repeating: 255, count: 96 * 96 * 4)
    for y in 0..<96 { for x in 0..<96 {
        var rgb = colors.2
        for origin in [30, 66] where x >= origin && x < origin + 10 && y >= 22 && y < 42 {
            rgb = x >= origin + 2 && x < origin + 8 && y >= 24 && y < 40 ? colors.0 : colors.1
        }
        for c in 0..<3 { pixels[(y * 96 + x) * 4 + c] = UInt8(rgb[c]) }
    } }
    for scale in [CGFloat(0.5), 1, 2] {
        func projected(_ r: CGRect) -> CGRect {
            CGRect(x: 7.25 + r.minX * scale, y: -11.5 + r.minY * scale,
                width: r.width * scale, height: r.height * scale)
        }
        let roi = projected(faceRect)
        let surface = NativeTextBoxContainment.Surface(rect: roi,
            spans: Array(repeating: (roi.minX + 4 * scale, roi.maxX - 4 * scale), count: 96), color: nil)
        guard let evidence = try NativeSourceCoverageWitness.evidence(rgba: pixels, width: 96, height: 96,
            roi: roi, surface: surface, foreground: colors.0.map(Double.init),
            stroke: colors.1.map(Double.init), background: colors.2.map(Double.init), peers: [],
            maximumGlyphSpan: 20 * 2 * scale) else {
            coverageCheck(false, "True outlined source letters lost: foreground \(colors.0), ROI scale \(scale)")
            continue
        }
        let firstGlyph = projected(CGRect(x: 30, y: 22, width: 10, height: 20))
        let unownedGlyph = projected(CGRect(x: 66, y: 22, width: 10, height: 20))
        coverageCheck(evidence.bounds.contains(firstGlyph) && evidence.bounds.contains(unownedGlyph)
            && evidence.backgroundSupport > 0.6,
            "Original colored fill AND outer stroke must witness unassigned source text at every ROI scale")
        let required = projected(CGRect(x: 32, y: 24, width: 6, height: 16)).union(evidence.bounds)
            .insetBy(dx: -scale, dy: -scale)
        let backing = surface.rectangularPanel(covering: required, near: roi, within: roi,
            allowsExactCover: true, boundaryInset: scale)!
        coverageCheck(backing.contains(firstGlyph) && backing.contains(unownedGlyph),
            "Rectangular shrink must not expose original text outside the OCR owner")
        let excluded = try NativeSourceCoverageWitness.bounds(rgba: pixels, width: 96, height: 96,
            roi: roi, surface: surface, foreground: colors.0.map(Double.init),
            stroke: colors.1.map(Double.init), background: colors.2.map(Double.init),
            peers: [unownedGlyph.insetBy(dx: -scale, dy: -scale)], maximumGlyphSpan: 20 * 2 * scale)!
        coverageCheck(excluded.contains(firstGlyph) && excluded.maxX < unownedGlyph.minX,
            "Only explicitly peer-owned source may be excluded from coverage")
    }
    for i in 0..<(96 * 96) { pixels[i * 4 + 3] = 0 }
    let transparentWitness = try NativeSourceCoverageWitness.bounds(rgba: pixels, width: 96, height: 96,
        roi: faceRect, surface: faceSurface, foreground: colors.0.map(Double.init),
        stroke: colors.1.map(Double.init), background: colors.2.map(Double.init), peers: [])
    coverageCheck(transparentWitness == nil,
        "Transparent samples cannot authorize a smaller source envelope")
}
// Same-color solid artwork with just one white edge must never witness text.
// Rotate both the artwork and true outlined letter to exercise both axes and
// both directions; disconnected nearby white strokes must not grow the witness.
// Enclosing pairs on either axis retain real glyphs; known source font size
// limits connected palette spans so a long thin rim cannot inherit ownership.
let falsePositiveFailuresBefore = coverageFailures
var unknownFontControls = 0
for rotation in 0..<4 {
    func rotate(_ x: Int, _ y: Int) -> (Int, Int) {
        switch rotation {
        case 1: return (95 - y, x)
        case 2: return (95 - x, 95 - y)
        case 3: return (y, 95 - x)
        default: return (x, y)
        }
    }
    func rotatedRect(_ r: CGRect) -> CGRect {
        switch rotation {
        case 1: return CGRect(x: 96 - r.maxY, y: r.minX, width: r.height, height: r.width)
        case 2: return CGRect(x: 96 - r.maxX, y: 96 - r.maxY, width: r.width, height: r.height)
        case 3: return CGRect(x: r.minY, y: 96 - r.maxX, width: r.height, height: r.width)
        default: return r
        }
    }
    let solid = CGRect(x: 60, y: 52, width: 18, height: 24)
    let letter = CGRect(x: 30, y: 22, width: 10, height: 20)
    for (name, includeLetter, includeSolid, includeRim) in [
        ("one-white-edge artwork", false, true, false),
        ("outlined letter and artwork", true, true, false),
        ("long thin rim", false, false, true),
        ("outlined letter and long thin rim", true, false, true)
    ] {
        var pixels = [UInt8](repeating: 255, count: 96 * 96 * 4)
        for y in 0..<96 { for x in 0..<96 {
            var rgb = [125, 148, 153]
            if includeSolid && solid.contains(CGPoint(x: x, y: y)) { rgb = [20, 40, 60] }
            if includeSolid && x >= 58 && x < 60 && y >= 52 && y < 76 { rgb = [250, 250, 250] }
            if includeRim && x >= 20 && x < 80 {
                if y >= 56 && y < 60 { rgb = [20, 40, 60] }
                if y >= 54 && y < 56 || y >= 60 && y < 62 { rgb = [250, 250, 250] }
            }
            if includeLetter && letter.contains(CGPoint(x: x, y: y)) {
                rgb = x >= 32 && x < 38 && y >= 24 && y < 40 ? [20, 40, 60] : [250, 250, 250]
            }
            // Within the 8-sample search radius but separated from the real
            // outline by four background pixels: never an extension of stroke.
            if x >= 44 && x < 46 && y >= 22 && y < 42 { rgb = [250, 250, 250] }
            let (rx, ry) = rotate(x, y)
            for c in 0..<3 { pixels[(ry * 96 + rx) * 4 + c] = UInt8(rgb[c]) }
        } }
        for scale in [CGFloat(0.5), 1, 2] {
            func projected(_ r: CGRect) -> CGRect {
                CGRect(x: 7.25 + r.minX * scale, y: -11.5 + r.minY * scale,
                    width: r.width * scale, height: r.height * scale)
            }
            let roi = projected(faceRect)
            let whiteSurface = NativeTextBoxContainment.Surface(rect: roi,
                spans: Array(repeating: (roi.minX + 4 * scale, roi.maxX - 4 * scale), count: 96), color: nil)
            let sourceFontSize = CGFloat(20) * scale
            let result = try NativeSourceCoverageWitness.bounds(rgba: pixels, width: 96, height: 96,
                roi: roi, surface: whiteSurface, foreground: [20, 40, 60], stroke: [250, 250, 250],
                background: [125, 148, 153], peers: [], maximumGlyphSpan: sourceFontSize * 2)
            let evidence = try NativeSourceCoverageWitness.evidence(rgba: pixels, width: 96, height: 96,
                roi: roi, surface: whiteSurface, foreground: [20, 40, 60], stroke: [250, 250, 250],
                background: [125, 148, 153], peers: [], maximumGlyphSpan: sourceFontSize * 2)
            coverageCheck(evidence?.bounds == result,
                "Style-aware bounds/evidence APIs disagree: rotation \(rotation), scale \(scale), \(name)")
            if includeLetter {
                coverageCheck(result == projected(rotatedRect(letter)),
                    "Rotation \(rotation), scale \(scale), \(name): true outlined letter must survive with exact contiguous-stroke bounds; got \(String(describing: result))")
            } else {
                coverageCheck(result == nil,
                    "Rotation \(rotation), scale \(scale), \(name): artwork or 60-sample rim exceeds known glyph evidence")
            }
            if includeRim {
                // No known font size means no hard glyph-span proof. Observe
                // the legacy bound without counting it as safe rim rejection.
                let unknown = try NativeSourceCoverageWitness.bounds(rgba: pixels, width: 96, height: 96,
                    roi: roi, surface: whiteSurface, foreground: [20, 40, 60], stroke: [250, 250, 250],
                    background: [125, 148, 153], peers: [], maximumGlyphSpan: nil)
                let omitted = try NativeSourceCoverageWitness.bounds(rgba: pixels, width: 96, height: 96,
                    roi: roi, surface: whiteSurface, foreground: [20, 40, 60], stroke: [250, 250, 250],
                    background: [125, 148, 153], peers: [])
                coverageCheck(unknown == omitted,
                    "Unknown-font explicit nil must preserve the omitted-span default")
                coverageCheck(unknown?.contains(projected(rotatedRect(CGRect(x: 20, y: 54, width: 60, height: 8)))) == true,
                    "Unknown-font control must expose unfiltered rim evidence, not claim hard glyph-span proof")
                unknownFontControls += 1
            }
        }
    }
}
if coverageFailures == falsePositiveFailuresBefore {
    print("PASS: 48 style-aware rotated/scaled artwork/rim/outlined-letter cases; disconnected white strokes excluded")
}
print("UNKNOWN: \(unknownFontControls) nil-span controls have no hard source-font proof; not counted as safe rim rejection")
// A thin unassigned outlined fragment touches the surface edge. Its foreground
// is inside the surface: no surrounding sample-space dilation may discard it.
var edgePixels = witnessPixels
let edgeGlyph = CGRect(x: 4, y: 50, width: 3, height: 16)
for y in 50..<66 { for x in 4..<7 {
    let rgb = x == 5 && y >= 52 && y < 64 ? [0, 0, 0] : [255, 0, 0]
    for c in 0..<3 { edgePixels[(y * 96 + x) * 4 + c] = UInt8(rgb[c]) }
} }
let edgeWitness = try NativeSourceCoverageWitness.bounds(rgba: edgePixels, width: 96, height: 96,
    roi: faceRect, surface: faceSurface, foreground: [0, 0, 0], stroke: [255, 0, 0],
    background: [240, 240, 240], peers: [], maximumGlyphSpan: 20 * 2)
coverageCheck(edgeWitness?.contains(edgeGlyph) == true,
    "True outlined edge lettering must remain in the source coverage witness")
guard coverageFailures == 0 else {
    FileHandle.standardError.write(Data(("FAIL: \(coverageFailures) focused coverage obligations failed\n").utf8))
    exit(1)
}
print("PASS: output-scale boundary/source guards, full outlined-ink obligation and nine colored unowned-source coverage cases")
precondition(panel.contains(faceOwner) && panel.width < faceRect.width && panel.height < faceRect.height)
let first = max(0, Int(floor(panel.minY))), last = min(95, Int(ceil(panel.maxY)) - 1)
precondition((first...last).allSatisfy { panel.minX >= rounded.spans[$0].0 && panel.maxX <= rounded.spans[$0].1 },
    "Complete rectangle must stay inside every intersected balloon row")
print("PASS: five synthetic interior face palettes, glyph exclusion, unavailable evidence and rectangular balloon containment")
let largePanel = CGRect(x: 0, y: 0, width: 100, height: 120)
let sourceCoverage = CGRect(x: 40, y: 20, width: 20, height: 80)
let paintedCoverage = CGRect(x: 35, y: 50, width: 30, height: 20)
let tight = NativeTextBoxContainment.tightPanel(owner: sourceCoverage, paintedInk: paintedCoverage,
    within: largePanel, padding: 1)!
precondition(tight == CGRect(x: 34, y: 19, width: 32, height: 82))
precondition(tight.contains(sourceCoverage) && tight.contains(paintedCoverage) && largePanel.contains(tight))
let guarded = NativeTextBoxContainment.tightPanel(owner: sourceCoverage, paintedInk: paintedCoverage,
    within: largePanel, padding: 1, sourcePadding: 1.5)!
precondition(guarded.minY == 17.5 && guarded.maxY == 102.5 && guarded.contains(tight),
    "Source outline erasure needs its own small margin, not only translated-ink AA padding")
precondition(NativeTextBoxContainment.tightPanel(owner: sourceCoverage,
    paintedInk: paintedCoverage.offsetBy(dx: 100, dy: 0), within: largePanel, padding: 1) == nil)
print("PASS: backing shrinks independently from the paragraph frame without uncovering source or painted ink")
let owner = CGRect(x: 3, y: 4, width: 20, height: 30)
let otherOwner = CGRect(x: 40, y: 4, width: 20, height: 30)
let ownerKey = NativeTextBoxSurfaceMemo.OwnerKey(owner)
precondition(NativeTextBoxSurfaceMemo.repeatedOwners(
    [owner, otherOwner], eligible: [true, true]).isEmpty)
precondition(NativeTextBoxSurfaceMemo.repeatedOwners(
    [owner, otherOwner, owner], eligible: [true, true, true]) == [ownerKey])
precondition(NativeTextBoxSurfaceMemo.repeatedOwners(
    [owner, owner], eligible: [true, false]).isEmpty,
    "Kept, empty or supplied-contour items must not admit a cache by themselves")
var adjacentOwner = owner
adjacentOwner.origin.x = owner.origin.x.nextUp
precondition(NativeTextBoxSurfaceMemo.repeatedOwners(
    [owner, adjacentOwner], eligible: [true, true]).isEmpty,
    "Admission must not merge nearby but different source domains")
for invalid in [CGRect.null, CGRect.infinite, CGRect.zero,
                CGRect(x: 0, y: 0, width: 0, height: 4)] {
    precondition(NativeTextBoxSurfaceMemo.repeatedOwners(
        [invalid, invalid], eligible: [true, true]).isEmpty)
}
precondition(NativeTextBoxSurfaceMemo.repeatedOwners([owner], eligible: []).isEmpty)
precondition(NativeTextBoxSurfaceMemo.repeatedOwners(
    Array(repeating: owner, count: 4097),
    eligible: Array(repeating: true, count: 4097)).isEmpty)
precondition(NativeTextBoxSurfaceMemo.repeatedOwners(
    Array(repeating: owner, count: 4096),
    eligible: Array(repeating: true, count: 4096)) == [ownerKey])

func key(_ index: Int = 0, rects: [CGRect]? = nil, width: Int = 32,
         height: Int = 32) -> NativeTextBoxSurfaceMemo.Key {
    let defaults = [CGRect(x: index, y: 0, width: 32, height: 32),
                    CGRect(x: 3, y: 3, width: 10, height: 10),
                    CGRect(x: 0, y: 0, width: 32, height: 32),
                    CGRect(x: 0, y: 0, width: 430, height: 932)]
    let r = rects ?? defaults
    return .init(frame: r[0], owner: r[1], roi: r[2], projection: r[3],
                 width: width, height: height)
}
func surface(_ rows: Int, color: Double = 0.8) -> NativeTextBoxContainment.Surface {
    .init(rect: CGRect(x: 0, y: 0, width: 32, height: 32),
          spans: Array(repeating: (CGFloat(0), CGFloat(32)), count: rows),
          color: [color, color, color])
}
let memo = NativeTextBoxSurfaceMemo()
precondition(!memo.lookup(key()).found)
memo.insert(nil, for: key())
precondition(memo.lookup(key()).found && memo.lookup(key()).surface == nil,
             "Measured absence must differ from a cache miss")
memo.insert(surface(4), for: key())
precondition(memo.lookup(key()).surface == nil, "Memo entries must be immutable")
precondition(!NativeTextBoxSurfaceMemo().lookup(key()).found,
             "A different source invocation must not reuse old surfaces")

let base = [CGRect(x: 0, y: 0, width: 32, height: 32),
            CGRect(x: 3, y: 3, width: 10, height: 10),
            CGRect(x: 0, y: 0, width: 32, height: 32),
            CGRect(x: 0, y: 0, width: 430, height: 932)]
for rectangle in 0..<4 {
    for coordinate in 0..<4 {
        var r = base
        switch coordinate {
        case 0: r[rectangle].origin.x += 0.125
        case 1: r[rectangle].origin.y += 0.125
        case 2: r[rectangle].size.width += 0.125
        default: r[rectangle].size.height += 0.125
        }
        precondition(!memo.lookup(key(rects: r)).found,
                     "Every frame/owner/ROI/projection coordinate belongs in the key")
    }
}
precondition(!memo.lookup(key(width: 33)).found && !memo.lookup(key(height: 33)).found)
var adjacent = base
adjacent[2].origin.x = base[2].origin.x.nextUp
precondition(key(rects: adjacent) != key(rects: base),
             "The compact key must preserve every coordinate's exact bits")
var negativeZero = base
negativeZero[0].origin.x = -0.0
precondition(key(rects: negativeZero) != key(rects: base),
             "Signed zero identity must match the original bit-pattern key")

let fifo = NativeTextBoxSurfaceMemo()
for index in 0..<32 { fifo.insert(surface(4, color: Double(index)), for: key(index)) }
_ = fifo.lookup(key(0)) // Reads must not silently change FIFO order.
fifo.insert(surface(4), for: key(32))
precondition(!fifo.lookup(key(0)).found && fifo.lookup(key(1)).found)
precondition(fifo.lookup(key(32)).surface?.spans.count == 4)
precondition(fifo.lookup(key(1)).surface?.color == [1, 1, 1])

let bounded = NativeTextBoxSurfaceMemo()
for index in 0..<8 { bounded.insert(surface(1024), for: key(index)) }
bounded.insert(surface(2), for: key(8))
precondition(!bounded.lookup(key(0)).found && bounded.lookup(key(1)).found,
             "The aggregate span cap must evict, not retain unbounded geometry")
bounded.insert(surface(8193), for: key(9))
precondition(!bounded.lookup(key(9)).found && bounded.lookup(key(1)).found,
             "An oversized entry must not purge already useful entries")
for index in 10..<50 { bounded.insert(nil, for: key(index)) }
precondition(!bounded.lookup(key(17)).found && bounded.lookup(key(18)).found,
             "Measured-nil entries also count toward the entry cap")

// The current measured query consumes logical admission even on a hit. Test the
// memo at that seam; full painter/reader equivalence is a separate integration test.
var remaining = 2 * 32 * 32
var admissions = 0, computations = 0
let page = NativeTextBoxSurfaceMemo()
for _ in 0..<3 {
    let pixels = 32 * 32
    guard pixels <= remaining else { continue }
    remaining -= pixels
    admissions += 1
    if !page.lookup(key()).found {
        computations += 1
        page.insert(surface(4), for: key())
    }
}
precondition(admissions == 2 && computations == 1 && remaining == 0)

// Independent exhaustive contact oracle, deliberately O(rows²), against the
// production linear sweep. These are authored geometry, not corpus annotations.
func exhaustive(_ surface: NativeTextBoxContainment.Surface, wanted: CGRect,
                limit: CGRect, required: CGSize) -> CGRect? {
    guard surface.certifiedSpans else { return nil }
    // Enumerate the complete clearance rectangle independently of the linear
    // production sweep, then return its paint rectangle. Adjacent row bands
    // above and below the paint participate in the exhaustive envelope too.
    let padding: CGFloat = 0.7
    let clearanceWanted = wanted.insetBy(dx: -padding, dy: -padding)
    let clearanceSize = CGSize(width: required.width + padding * 2, height: required.height + padding * 2)
    let available = surface.rect.intersection(limit)
    guard clearanceSize.width <= available.width, clearanceSize.height <= available.height else { return nil }
    let step = surface.rect.height / CGFloat(surface.spans.count)
    let low = available.minY, high = available.maxY - clearanceSize.height
    var events = [low, high, min(max(clearanceWanted.midY - clearanceSize.height / 2, low), high)]
    for row in 0...surface.spans.count {
        let edge = row == surface.spans.count ? surface.rect.maxY : surface.rect.minY + CGFloat(row) * step
        events += [edge, edge - clearanceSize.height]
    }
    var best: CGRect?, bestDistance = CGFloat.infinity
    for y in Set(events).sorted() where y >= low && y <= high {
        var left = available.minX, right = available.maxX
        for (row, span) in surface.spans.enumerated() {
            let top = surface.rect.minY + CGFloat(row) * step
            let bottom = row + 1 == surface.spans.count ? surface.rect.maxY : surface.rect.minY + CGFloat(row + 1) * step
            if top < y + clearanceSize.height && bottom > y {
                left = max(left, span.0); right = min(right, span.1)
            }
        }
        guard right - left >= clearanceSize.width else { continue }
        let x = min(max(clearanceWanted.midX - clearanceSize.width / 2, left), right - clearanceSize.width)
        let candidate = CGRect(x: x, y: y, width: clearanceSize.width, height: clearanceSize.height)
        let dx = candidate.midX - clearanceWanted.midX, dy = candidate.midY - clearanceWanted.midY
        let distance = dx * dx + dy * dy
        if distance < bestDistance { best = candidate.insetBy(dx: padding, dy: padding); bestDistance = distance }
    }
    return best
}
let lobe = NativeTextBoxContainment.Surface(rect: CGRect(x: 0, y: 0, width: 200, height: 100),
    spans: Array(repeating: (CGFloat(0), CGFloat(40)), count: 6)
         + Array(repeating: (CGFloat(0), CGFloat(200)), count: 4), color: nil)
let desired = CGRect(x: 80, y: 32.7, width: 100, height: 20)
splitCheck(lobe.inscribed(near: desired, within: lobe.rect) == CGRect(x: 80, y: 60.7, width: 100, height: 20),
             "The live entrypoint must use a side lobe before shrinking capacity")
let blockedLobe = CGRect(x: 100, y: 60, width: 60, height: 30)
let guardedLobe = lobe.inscribed(near: desired, within: lobe.rect, protectedRects: [blockedLobe])!
splitCheck(!guardedLobe.intersects(blockedLobe), "guarded candidate intrudes: \(guardedLobe)")
splitCheck(abs(guardedLobe.width - 38.6) < 1e-9 && guardedLobe.height == 20,
           "infeasible capacity must retain legacy frame: \(guardedLobe)")
let lateBlock = CGRect(x: 80, y: 60, width: 100, height: 10)
let alternate = lobe.inscribed(near: desired, within: lobe.rect, protectedRects: [lateBlock])!
splitCheck(alternate.size == desired.size && alternate.minY == 70.7,
           "later safe full-capacity contact missing: \(alternate)")
splitCheck(!alternate.intersects(lateBlock), "alternate intrudes: \(alternate)")
let rightPeer = CGRect(x: 150, y: 60, width: 30, height: 40)
let leftPeer = CGRect(x: 0, y: 60, width: 50, height: 40)
for peers in [[rightPeer], [rightPeer, leftPeer], [leftPeer, rightPeer]] {
    let safe = lobe.inscribed(near: desired, within: lobe.rect, protectedRects: peers)!
    splitCheck(safe == CGRect(x: 50, y: 60.7, width: 100, height: 20),
               "Safe full-capacity X contact missing: \(safe)")
    splitCheck(peers.allSatisfy { !safe.intersects($0) }, "Exact peer contact intrudes")
}
for peers in [[rightPeer, CGRect(x: 0, y: 60, width: 51, height: 40)],
              [CGRect(x: 0, y: 60, width: 200, height: 40)]] {
    let safe = lobe.inscribed(near: desired, within: lobe.rect, protectedRects: peers)!
    splitCheck(abs(safe.width - 38.6) < 1e-9, "Infeasible X must retain legacy capacity")
}
let edgeSurface = NativeTextBoxContainment.Surface(rect: CGRect(x: 0, y: 0, width: 100, height: 100),
    spans: [(0, 100), (0, 100), (0, 20), (0, 20)], color: nil)
let exactEdge = CGRect(x: 30, y: 25, width: 40, height: 25)
let clearEdge = edgeSurface.inscribed(near: exactEdge, within: edgeSurface.rect, required: exactEdge.size)!
splitCheck(abs(clearEdge.minY - 24.3) < 1e-9 && abs(clearEdge.height - exactEdge.height) < 1e-9
    && edgeSurface.contains(clearEdge.insetBy(dx: -0.7, dy: -0.7)),
    "Paint touching a narrow row needs vertical boundary clearance: \(clearEdge)")
let crossesEdge = CGRect(x: 30, y: 25, width: 40, height: 25.125)
precondition(edgeSurface.inscribed(near: crossesEdge, within: edgeSurface.rect, required: crossesEdge.size)!.minY < 25)
var oracleCases = 0
for rows in [2, 4, 7, 16, 63, 1024] {
    let rect = CGRect(x: 7.3, y: -11.2, width: 200, height: 103.7)
    let bands = (0..<rows).map { row -> (CGFloat, CGFloat) in
        let left = rect.minX + CGFloat((row * 7) % 13)
        let right = rect.maxX - CGFloat((row * 11) % 91)
        return (left, right)
    }
    let surface = NativeTextBoxContainment.Surface(rect: rect, spans: bands, color: nil)
    for width in [CGFloat(30), 100, 170, 198.6] {
        for height in [CGFloat(3), 13.9, 40, 90] {
            for inset in [CGFloat(0), 5.125] {
                let wanted = CGRect(x: 40.3, y: 22.7, width: width, height: height)
                let limit = rect.insetBy(dx: inset, dy: inset)
                let fast = surface.inscribed(near: wanted, within: limit, required: wanted.size)
                let slow = exhaustive(surface, wanted: wanted, limit: limit, required: wanted.size)
                splitCheck(fast == slow,
                    "Clearance oracle mismatch: rows \(rows), size \(wanted.size), inset \(inset), fast \(String(describing: fast)), exhaustive \(String(describing: slow))")
                oracleCases += 1
            }
        }
    }
}
let disconnected = NativeTextBoxContainment.Surface(rect: CGRect(x: 0, y: 0, width: 100, height: 100),
    spans: [(0, 40), (60, 100)], color: nil)
let fractionalWaistRect = CGRect(x: 0, y: 0, width: 100, height: 16.0 / 3)
let fractionalWaist = NativeTextBoxContainment.Surface(rect: fractionalWaistRect,
    spans: (0..<16).map { $0 == 3 || $0 == 12 ? (CGFloat(49), CGFloat(51)) : (CGFloat(40), CGFloat(60)) }, color: nil)
let fractionalCandidates = fractionalWaist.reducedHeightFrontier(
    near: CGRect(x: 45, y: 0, width: 10, height: 5), within: fractionalWaistRect)
precondition(!fractionalCandidates.isEmpty)
for candidate in fractionalCandidates {
    for row in fractionalWaist.spans.indices {
        let top = fractionalWaistRect.minY + CGFloat(row) * fractionalWaistRect.height / 16
        let bottom = row == 15 ? fractionalWaistRect.maxY : fractionalWaistRect.minY + CGFloat(row + 1) * fractionalWaistRect.height / 16
        if top < candidate.maxY && bottom > candidate.minY {
            let span = fractionalWaist.spans[row]
            precondition(candidate.minX >= span.0 + 0.7 && candidate.maxX <= span.1 - 0.7,
                         "Fractional frontier crosses a narrow row at a rounded boundary")
        }
    }
}
let collapsedWaist = NativeTextBoxContainment.Surface(rect: CGRect(x: 0, y: 1e16, width: 100, height: 102.4),
    spans: Array(repeating: (CGFloat.zero, CGFloat(100)), count: 1024), color: nil)
precondition(collapsedWaist.reducedHeightFrontier(
    near: CGRect(x: 10, y: 1e16, width: 80, height: 80), within: collapsedWaist.rect).isEmpty)
print("PASS: native fractional frontier half-open containment and sub-ULP row abstention")
precondition(disconnected.inscribed(near: exactEdge, within: disconnected.rect, required: exactEdge.size) == nil)
precondition(lobe.inscribed(near: desired, within: lobe.rect, required: CGSize(width: CGFloat.nan, height: 20)) == nil)
let splitOwners = [CGRect(x: 10, y: 80, width: 10, height: 10),
                   CGRect(x: 10, y: 60, width: 10, height: 10),
                   CGRect(x: 70, y: 20, width: 10, height: 10)]
let splitPanels = [CGRect(x: 0, y: 50, width: 50, height: 70),
                   CGRect(x: 0, y: 30, width: 50, height: 70),
                   CGRect(x: 40, y: 0, width: 70, height: 60)]
let permutations = [[0,1,2], [0,2,1], [1,0,2], [1,2,0], [2,0,1], [2,1,0]]
var permutationChecks = 0
func splitCheck(_ condition: Bool, _ details: @autoclosure () -> String) {
    if !condition {
        FileHandle.standardError.write(Data(("SPLIT FAILURE: " + details() + "\n").utf8))
        exit(1)
    }
}
for scale in [CGFloat(0.25), 1, 3.125] {
    for kept in [[false, false, false], [false, true, false], [true, false, true]] {
        func projected(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX * scale + 7.3, y: r.minY * scale - 11.2,
                   width: r.width * scale, height: r.height * scale)
        }
        let panels = splitPanels.map(projected), owners = splitOwners.map(projected)
        let baseline = NativeTextBoxContainment.separated(panels: panels, owners: owners, kept: kept, gap: 1.5 * scale)
        for order in permutations {
            let result = NativeTextBoxContainment.separated(panels: order.map { panels[$0] },
                owners: order.map { owners[$0] }, kept: order.map { kept[$0] }, gap: 1.5 * scale)
            for i in 0..<3 {
                splitCheck(result[i] == baseline[order[i]], "permutation \(order), scale \(scale), kept \(kept), item \(i): \(result[i]) vs \(baseline[order[i]])")
                splitCheck(result[i].contains(panels[order[i]].intersection(owners[order[i]])), "source lost \(order), scale \(scale), item \(i)")
                if kept[order[i]] { splitCheck(result[i] == panels[order[i]], "kept changed") }
            }
            permutationChecks += 1
        }
    }
}
let overlappingOwners = [CGRect(x: 10, y: 10, width: 50, height: 20),
                         CGRect(x: 40, y: 10, width: 50, height: 20)]
let overlappingPanels = [CGRect(x: 0, y: 0, width: 80, height: 40),
                         CGRect(x: 20, y: 0, width: 80, height: 40)]
let unresolved = NativeTextBoxContainment.separated(panels: overlappingPanels,
    owners: overlappingOwners, kept: [false, false])
precondition(unresolved == overlappingPanels,
             "Overlapping SOURCE cannot be made uncovered to hide a panel conflict")
let historicalCut = [CGRect(x: 0, y: 0, width: 49.25, height: 40),
                     CGRect(x: 50.75, y: 0, width: 49.25, height: 40)]
var oldLost: CGFloat = 0, newLost: CGFloat = 0
for i in 0..<2 {
    let oldHit = historicalCut[i].intersection(overlappingOwners[i])
    let newHit = unresolved[i].intersection(overlappingOwners[i])
    let area = overlappingOwners[i].width * overlappingOwners[i].height
    oldLost += area - oldHit.width * oldHit.height
    newLost += area - newHit.width * newHit.height
}
precondition(oldLost == 430 && newLost == 0)
let keptPanels = [CGRect(x: 30, y: 40, width: 110, height: 110), CGRect(x: 120, y: 60, width: 25, height: 60)]
let keptOwners = [CGRect(x: 40, y: 50, width: 70, height: 90), keptPanels[1]]
let keptSplit = NativeTextBoxContainment.separated(panels: keptPanels, owners: keptOwners, kept: [false, true])
precondition(keptSplit[1] == keptPanels[1] && keptSplit[0].contains(keptOwners[0]))
precondition(keptSplit[0].maxX + 1.5 <= keptSplit[1].minX)
precondition(NativeTextBoxContainment.separated(panels: keptPanels, owners: [], kept: []) == keptPanels)
precondition(NativeTextBoxContainment.separated(panels: keptPanels, owners: keptOwners,
    kept: [false, true], gap: CGFloat.nan) == keptPanels)
for sourceGap in [CGFloat(0), 0.125, 0.75, 1.5] {
    let owners = [CGRect(x: 10, y: 10, width: 40, height: 20),
                  CGRect(x: 50 + sourceGap, y: 10, width: 40, height: 20)]
    let panels = [CGRect(x: 0, y: 0, width: 80, height: 40),
                  CGRect(x: 20, y: 0, width: 80, height: 40)]
    let result = NativeTextBoxContainment.separated(panels: panels, owners: owners, kept: [false, false])
    precondition(result[0].contains(owners[0]) && result[1].contains(owners[1]))
    precondition(result[0].maxX <= result[1].minX,
                 "A feasible sub-gutter source gap must separate without exposing SOURCE")
}
print("PASS: \(permutationChecks) native split permutation/scale/kept comparisons; overlapping-owner lost coverage 430 -> 0 square points (conflict deliberately remains); kept spacing and invalid-input controls")
print("PASS: live side-lobe capacity, half-open row contacts, invalid/disconnected abstention; \(oracleCases) exhaustive numeric geometry comparisons; not native font/pixel or whole-corpus quality")
print("PASS: exact bounded owner admission, production memo key isolation, absence, immutable entries, FIFO, span/entry caps, invocation scope and logical admission seam; not pixel parity")

// Frozen pre-fix split formula, for a stage-local numerical comparison only.
func legacySplit(_ panels: [CGRect], _ owners: [CGRect], _ kept: [Bool]) -> [CGRect] {
    var result = panels
    let gap: CGFloat = 1.5
    for a in result.indices {
        for b in result.indices where b > a && (!kept[a] || !kept[b]) {
            let hit = result[a].intersection(result[b])
            guard !hit.isNull, hit.width > 0, hit.height > 0 else { continue }
            let first = owners[a], second = owners[b]
            if (kept[a] || kept[b]), first.intersects(second) { continue }
            let horizontal = first.maxX <= second.minX || second.maxX <= first.minX
                || (!(first.maxY <= second.minY || second.maxY <= first.minY)
                    && abs(first.midX - second.midX) / max(1, first.width + second.width)
                    >= abs(first.midY - second.midY) / max(1, first.height + second.height))
            let low = horizontal ? (first.midX < second.midX ? a : b) : (first.midY < second.midY ? a : b)
            let high = low == a ? b : a
            let end = horizontal ? owners[low].maxX : owners[low].maxY
            let start = horizontal ? owners[high].minX : owners[high].minY
            let cut = end <= start ? (end + start) / 2 : (horizontal
                ? (first.midX + second.midX) / 2 : (first.midY + second.midY) / 2)
            let lowEnd = kept[high] ? (horizontal ? result[high].minX : result[high].minY) - gap : cut - gap / 2
            let highStart = kept[low] ? (horizontal ? result[low].maxX : result[low].maxY) + gap : cut + gap / 2
            if !kept[low] {
                if horizontal { result[low].size.width = max(0, min(result[low].maxX, lowEnd) - result[low].minX) }
                else { result[low].size.height = max(0, min(result[low].maxY, lowEnd) - result[low].minY) }
            }
            if !kept[high] {
                let old = result[high]
                if horizontal { result[high].origin.x = max(old.minX, highStart); result[high].size.width = max(0, old.maxX - result[high].minX) }
                else { result[high].origin.y = max(old.minY, highStart); result[high].size.height = max(0, old.maxY - result[high].minY) }
            }
        }
    }
    return result
}
// Frozen pre-peer-edge capacity wrapper. The row sweep itself is unchanged;
// this baseline deliberately passes only its nearest X to the admission gate.
func prePeerEdge(_ surface: NativeTextBoxContainment.Surface, wanted: CGRect,
                 limit: CGRect, peers: [CGRect]) -> CGRect? {
    guard surface.certifiedSpans else { return nil }
    let available = surface.rect.intersection(limit).insetBy(dx: 0.7, dy: 0.7)
    guard available.width > 2, available.height > 2 else { return nil }
    var best: CGRect?
    for trial in 0..<12 {
        let height = min(wanted.height, available.height) * (1 - CGFloat(trial) * 0.055)
        let top = min(max(wanted.midY - height / 2, available.minY), available.maxY - height)
        let first = max(0, Int(floor((top - surface.rect.minY) / surface.rect.height * CGFloat(surface.spans.count))))
        let last = min(surface.spans.count - 1,
            Int(ceil((top + height - surface.rect.minY) / surface.rect.height * CGFloat(surface.spans.count))) - 1)
        guard first <= last else { continue }
        let left = max(available.minX, surface.spans[first...last].map(\.0).max()! + 0.7)
        let right = min(available.maxX, surface.spans[first...last].map(\.1).min()! - 0.7)
        let width = min(wanted.width, right - left)
        guard width > 2 else { continue }
        let x = min(max(wanted.midX - width / 2, left), right - width)
        let candidate = CGRect(x: x, y: top, width: width, height: height)
        if best == nil || width * height > best!.width * best!.height { best = candidate }
    }
    func area(_ r: CGRect) -> CGFloat {
        r.isNull || r.isInfinite || r.width <= 0 || r.height <= 0 ? 0 : r.width * r.height
    }
    let validPeers = peers.filter {
        !$0.isNull && !$0.isInfinite && $0.size.width > 0 && $0.size.height > 0
            && [$0.minX, $0.minY, $0.maxX, $0.maxY].allSatisfy(\.isFinite)
    }
    let hits = validPeers.map { area((best ?? wanted).intersection($0)) }
    let accepts: (CGRect) -> Bool = { candidate in
        zip(validPeers, hits).allSatisfy {
            area(candidate.intersection($0.0)) <= $0.1 + max(1, $0.1) * 1e-12
        }
    }
    let required = CGSize(width: min(wanted.width, available.width), height: min(wanted.height, available.height))
    return surface.inscribed(near: wanted, within: limit, required: required,
                             accepts: validPeers.isEmpty ? nil : accepts) ?? best
}
if CommandLine.arguments.contains("--geometry-audit") {
    let pages = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as! [[String: Any]]
    func rectangle(_ a: [Double]) -> CGRect { CGRect(x: a[0], y: a[1], width: a[2], height: a[3]) }
    func area(_ r: CGRect) -> Double { r.isNull || r.width <= 0 || r.height <= 0 ? 0 : Double(r.width * r.height) }
    func used(_ x: Double) -> CGFloat { CGFloat((Float(x) * 64).rounded(.towardZero)) / 64 }
    var count = 0, sourceImproved = 0, sourceRegressed = 0, overlapImproved = 0, overlapRegressed = 0
    var oldLost = 0.0, newLost = 0.0, oldOverlap = 0.0, newOverlap = 0.0
    var changedPanels = 0, keptChanges = 0, requiredPairOverlap = 0.0
    var contourEligible = 0, contourEvaluated = 0, capacityImproved = 0, capacityRegressed = 0
    var edgeChanged = 0, edgePeerRegressed = 0, edgeImprovedPages = 0
    var capacityGain = 0.0
    var frontierItems = 0, frontierFrames = 0, frontierPeerAdmittedItems = 0, frontierPages = 0
    for page in pages {
        let frame = rectangle(page["frame"] as! [Double])
        let items = page["items"] as! [[String: Any]]
        var owners: [CGRect] = [], panels: [CGRect] = [], kept: [Bool] = [], texts: [CGRect] = []
        for item in items {
            let r = item["rect"] as! [Double]
            let text = CGRect(x: used(r[0]), y: used(r[1]), width: used(r[2]), height: used(r[3]))
            var owner = CGRect.null
            for b in item["source"] as! [[Double]] where b.count == 4 && b[2] > 0 && b[3] > 0 && b.allSatisfy(\.isFinite) {
                owner = owner.union(CGRect(x: frame.minX + CGFloat(b[0]) * frame.width,
                    y: frame.minY + CGFloat(b[1]) * frame.height, width: CGFloat(b[2]) * frame.width,
                    height: CGFloat(b[3]) * frame.height))
            }
            owner = (owner.isNull ? text : owner).intersection(frame)
            let isKept = item["kept"] as! Bool
            let angle = item["rotation"] as! Double
            var rotated = text
            if angle != 0 {
                let c = cos(angle), s = sin(angle)
                let corners = [CGPoint(x: text.minX, y: text.minY), CGPoint(x: text.maxX, y: text.minY),
                    CGPoint(x: text.maxX, y: text.maxY), CGPoint(x: text.minX, y: text.maxY)].map { p in
                    CGPoint(x: text.midX + (p.x - text.midX) * c - (p.y - text.midY) * s,
                            y: text.midY + (p.x - text.midX) * s + (p.y - text.midY) * c)
                }
                let xs = corners.map(\.x), ys = corners.map(\.y)
                rotated = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            }
            owners.append(owner); kept.append(isKept); texts.append(text)
            panels.append(isKept ? owner : rotated.union(owner).insetBy(dx: -2, dy: -2).intersection(frame))
        }
        let old = legacySplit(panels, owners, kept)
        let new = NativeTextBoxContainment.separated(panels: panels, owners: owners, kept: kept)
        var pageImproved = false
        var pageFrontier = false
        for i in items.indices where !kept[i] && (items[i]["rotation"] as! Double) == 0 {
            guard let geometry = items[i]["interior"] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: geometry),
                  let interior = try? JSONDecoder().decode(NativeTranslationBalloonInterior.self, from: data),
                  let surface = NativeTextBoxContainment.known(interior, frame: frame) else { continue }
            contourEligible += 1
            let box = new[i].intersection(surface.rect)
            let wanted = texts[i].intersection(box)
            guard !box.isNull, !wanted.isNull, wanted.width > 0, wanted.height > 0 else { continue }
            let peers = items.indices.filter { $0 != i }.flatMap { [owners[$0], texts[$0]] }
            let baseline = prePeerEdge(surface, wanted: wanted, limit: box, peers: peers) ?? wanted
            let candidate = surface.inscribed(near: wanted, within: box, protectedRects: peers) ?? wanted
            if candidate.width < wanted.width {
                let frontier = surface.reducedHeightFrontier(near: wanted, within: box)
                if !frontier.isEmpty {
                    frontierItems += 1; frontierFrames += frontier.count; pageFrontier = true
                    let hits = peers.map { area(candidate.intersection($0)) }
                    if frontier.contains(where: { proposal in
                        zip(peers, hits).allSatisfy {
                            area(proposal.intersection($0.0)) <= $0.1 + max(1, $0.1) * 1e-12
                        }
                    }) { frontierPeerAdmittedItems += 1 }
                }
            }
            contourEvaluated += 1
            let gain = area(candidate) - area(baseline)
            if gain > 1e-8 { capacityImproved += 1; pageImproved = true; capacityGain += gain }
            if gain < -1e-8 { capacityRegressed += 1 }
            if candidate != baseline { edgeChanged += 1 }
            if peers.contains(where: {
                area(candidate.intersection($0)) > area(baseline.intersection($0)) + 1e-8
            }) { edgePeerRegressed += 1 }
        }
        if pageImproved { edgeImprovedPages += 1 }
        if pageFrontier { frontierPages += 1 }
        var oldPageLost = 0.0, newPageLost = 0.0, oldPageOverlap = 0.0, newPageOverlap = 0.0
        for i in panels.indices {
            let required = panels[i].intersection(owners[i])
            oldPageLost += area(required) - area(old[i].intersection(required))
            newPageLost += area(required) - area(new[i].intersection(required))
            if old[i] != new[i] { changedPanels += 1 }
            if kept[i], new[i] != panels[i] { keptChanges += 1 }
            for j in panels.indices where j > i && (!kept[i] || !kept[j]) {
                oldPageOverlap += area(old[i].intersection(old[j]))
                newPageOverlap += area(new[i].intersection(new[j]))
                requiredPairOverlap += area(required.intersection(panels[j].intersection(owners[j])))
            }
        }
        if newPageLost < oldPageLost - 1e-8 { sourceImproved += 1 }
        if newPageLost > oldPageLost + 1e-8 { sourceRegressed += 1 }
        if newPageOverlap < oldPageOverlap - 1e-8 { overlapImproved += 1 }
        if newPageOverlap > oldPageOverlap + 1e-8 { overlapRegressed += 1 }
        oldLost += oldPageLost; newLost += newPageLost
        oldOverlap += oldPageOverlap; newOverlap += newPageOverlap; count += items.count
    }
    let report: [String: Any] = ["scope": "numeric production split stage on saved layouts, not complete renderer/GT/pixel replay",
        "pages": pages.count, "items": count, "sourceImprovedPages": sourceImproved, "sourceRegressedPages": sourceRegressed,
        "overlapImprovedPages": overlapImproved, "overlapRegressedPages": overlapRegressed,
        "oldLostCoveredOwnerArea": oldLost, "newLostCoveredOwnerArea": newLost,
        "oldPairOverlapArea": oldOverlap, "newPairOverlapArea": newOverlap,
        "changedPanels": changedPanels, "keptChanges": keptChanges,
        "requiredOwnerPairOverlapArea": requiredPairOverlap]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    print("AUDIT:" + String(data: data, encoding: .utf8)!)
    let edgeReport: [String: Any] = [
        "scope": "Numeric initial inscribing stage on supplied contours; excludes shaping, measured surfaces, centered placement and final paint",
        "pages": pages.count, "items": count, "eligibleSuppliedContours": contourEligible,
        "evaluatedItems": contourEvaluated, "changedItems": edgeChanged,
        "capacityImprovedItems": capacityImproved, "capacityRegressedItems": capacityRegressed,
        "capacityImprovedPages": edgeImprovedPages, "peerOverlapRegressedItems": edgePeerRegressed,
        "capacityAreaGain": capacityGain
    ]
    let edgeData = try JSONSerialization.data(withJSONObject: edgeReport, options: [.sortedKeys])
    print("PEER_EDGE_AUDIT:" + String(data: edgeData, encoding: .utf8)!)
    let frontierReport: [String: Any] = [
        "scope": "Native reduced-height frontier on all saved numerical layouts, supplied contours only; potential frames, not fitted font or pixel/GT improvements",
        "pages": pages.count, "items": count, "evaluatedSuppliedContours": contourEvaluated,
        "frontierItems": frontierItems, "frontierFrames": frontierFrames,
        "frontierPages": frontierPages, "peerAdmittedFrontierItems": frontierPeerAdmittedItems
    ]
    let frontierData = try JSONSerialization.data(withJSONObject: frontierReport, options: [.sortedKeys])
    print("WAIST_FRONTIER_AUDIT:" + String(data: frontierData, encoding: .utf8)!)
}
'''

if args.emit_swift:
    sys.stdout.write(program)
    raise SystemExit(0)

isolated_cache = tempfile.TemporaryDirectory(prefix="aidoku-surface-memo-") if args.isolated_cache else None
cache = Path(isolated_cache.name) if isolated_cache else root / "build/native-surface-memo-smoke"
cache.mkdir(parents=True, exist_ok=True)
with (cache / "build.lock").open("a") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    source, binary = cache / "main.swift", cache / "check"
    if not source.exists() or source.read_text() != program:
        source.write_text(program)
    output_map = cache / "outputs.json"
    outputs = {
        "": {"swift-dependencies": str(cache / "master.swiftdeps")},
        str(source): {"object": str(cache / "main.o"),
                      "swift-dependencies": str(cache / "main.swiftdeps")},
    }
    encoded = json.dumps(outputs, indent=2) + "\n"
    if not output_map.exists() or output_map.read_text() != encoded:
        output_map.write_text(encoded)
    subprocess.run(["swiftc", *(["-Onone", "-g"] if args.debug else ["-O"]), "-incremental", "-j", "1",
                    "-output-file-map", str(output_map),
                    "-module-cache-path", str(cache / "modules"),
                    str(source), "-o", str(binary)], check=True)
    if args.geometry_audit:
        pages = []
        for path in sorted(args.geometry_audit.glob("*/native-layout.json")):
            data = json.loads(path.read_text())
            origin, size = data["sourceRect"]
            pages.append({"frame": [*origin, *size], "items": [
                {"rect": [item[k] for k in ("x", "y", "width", "height")],
                 "source": [item.get("sourceBounds", [])] + item.get("auxiliaryInkRects", []),
                 "kept": item.get("keptLettering", False), "rotation": item.get("rotation", 0),
                 "interior": {key: interior[key] for key in ("rect", "center", "spans", "contourVerified") if key in interior}}
                for item in data["items"]
                for interior in [item["balloonInterior"] if item.get("balloonInterior") is not None
                                 else (item.get("balloonUnit") or {}).get("interior") or {}]
                ]})
        if not pages:
            raise SystemExit("No saved native layouts found; audit incomplete")
        subprocess.run([str(binary), "--geometry-audit"], input=json.dumps(pages, allow_nan=False), text=True, check=True)
    else:
        subprocess.run([str(binary)], check=True)
