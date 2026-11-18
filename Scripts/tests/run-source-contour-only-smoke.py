#!/usr/bin/env python3
"""Isolated production source-contour paint/admission regression; synthetic RGBA only."""
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
SOURCES = BASE['SOURCES'] + ['NativeMandatoryDisplayStroke+Composer', 'NativeSourceInkSelection',
                           'NativeRetainedStrokePainter']
HARNESS = r'''
import CoreGraphics
import Foundation
import Darwin

typealias Composer = NativeAOTTranslationPageComposer
typealias F = Composer.TranslatedFillPrimitive
typealias N = NativeFinalTextPaintAdmission
var checks = 0
func check(_ condition: Bool, _ reason: String) {
    if !condition {
        FileHandle.standardError.write(Data("FAIL after \(checks): \(reason)\n".utf8)); exit(1)
    }
    checks += 1
}
func rejects(_ reason: String, _ body: () throws -> Void) {
    do { try body() } catch { checks += 1; return }
    fatalError("unexpected admission: \(reason)")
}
func phase(_ name: String) {
    FileHandle.standardError.write(Data("PHASE \(checks): \(name)\n".utf8))
}
func rgba(_ image: CGImage) throws -> [UInt8] { try NativeMandatoryDisplayStroke.rgba(image) }
func image(_ bytes: [UInt8], _ w: Int, _ h: Int) throws -> CGImage {
    try NativeMandatoryDisplayStroke.image(bytes, width: w, height: h)
}
do {
let page = CGRect(x: 0, y: 0, width: 96, height: 96)
let background = try image([UInt8](repeating: 255, count: 96*96*4), 96, 96)
let style = NativeSourceStylePaint.Style(sourceFontPixels: 10,
    bands: [.init(rgb: [160,60,190], width: 1)], shadow: nil)
// Square ring with a 5x5 counter: source radius1 leaves 3x3 open;
// legacy mandatory radius2 + source width1 closes the center.
var ring = [UInt8](repeating: 0, count: 13*13*4)
for y in 2...10 { for x in 2...10 where !(4...8).contains(x) || !(4...8).contains(y) {
    let p = (y*13+x)*4
    ring[p+3] = 255 // black actual fill, same color as forced legacy guard
}}
let fillImage = try image(ring, 13, 13)
var raw = F(image: fillImage, frame: CGRect(x: 30, y: 30, width: 13, height: 13), fontOutputPixels: 10)
raw.ownerID = "ring"
raw.displayStrokeEndpoint = 0
raw.sourceStyle = style
raw.sourceContourOnly = true
func prepared(_ f: F) throws -> NativeMandatoryDisplayStroke.Prepared {
    try NativeMandatoryDisplayStroke.prepare(fill: f.image, restored: background,
        fontOutputPixels: f.fontOutputPixels, outwardEm: f.displayStrokeRatio ?? 0.20,
        fillFrame: f.frame, forcedEndpoint: f.displayStrokeEndpoint,
        recheckFinalEndpoint: f.recheckFinalEndpoint, sourceAppearance: f.sourceAppearance,
        sourceContourOnly: f.sourceContourOnly)
}
let contour = try prepared(raw)
phase("prepared ring")
check(contour.sourceContourOnly && contour.outwardPixels == 0 && contour.addedAlphaPixels == 0, "real zero guard")
check(contour.fill === fillImage && contour.frame == raw.frame, "original fill object/frame retained")
check(try rgba(contour.fill) == ring, "byte-exact original RGBA")
check(try rgba(contour.halo).allSatisfy { $0 == 0 }, "synthetic halo fully transparent")
check(contour.endpointDecision["guardPainted"] as? Bool == false &&
      contour.endpointDecision["paintMode"] as? String == "source-contour-only", "truthful mode")
check(contour.endpointDecision["finalEndpoint"] is NSNull, "unused endpoint not claimed painted")
let sourceFootprint = try N.retainedFootprint(raw)
let sourceActual = try N.footprint(layer: contour, style: style, fontPixels: 10)
check(sourceFootprint.runs.map { [$0.y,$0.left,$0.right] } == sourceActual.runs.map { [$0.y,$0.left,$0.right] },
    "proposal equals real source effect support")
let expected = try N.verify([raw], layers: [contour], page: page)
let sourcePaint = try Composer.mandatoryStrokeLayer(restored: background, fills: [raw], expectedItems: 1, textComplete: true)
phase("source ring painted")
let sourceBytes = try rgba(sourcePaint.image)
check(sourceBytes[(36*96+36)*4+3] == 0, "source-only leaves actual counter center open")
check(stride(from: 0, to: sourceBytes.count, by: 4).contains {
    Array(sourceBytes[$0..<$0+4]) == [160,60,190,255]
}, "actual measured colored band painted")
check(sourcePaint.audit["finalRetainedAlphaPixels"] as? Int == expected, "exact admitted alpha accounting")
try N.verifyRaster(sourcePaint.image, expectedPixels: expected)
checks += 1
let decisions = sourcePaint.audit["endpointDecisions"] as! [[String: Any]]
check(decisions[0]["finalDisplayStroke"] as? [Double] == [160,60,190], "actual source band RGB receipt")
let radii = (sourcePaint.audit["sourceStylePaint"] as! [[String: Any]])[0]["displayCumulativeRadiiPixels"] as! [Double]
check(radii == [1], "band radius starts at zero")
var withRows = sourcePaint.audit
withRows["rawNativeItems"] = [["id":"ring"]]
let staged = Composer.TextLayer(image: sourcePaint.image, expectedItems: 1, paintedItems: 1, complete: true, audit: withRows)
let admitted = try N.place([raw], page: page)
let repainted = try Composer.refineFinalReadability(layer: staged, fills: [raw], restored: background,
    admittedOverride: admitted, forceRepaint: true)
check(try rgba(repainted.image) == sourceBytes, "terminal repaint identical RGBA")
check((repainted.audit["rawNativeItems"] as! [[String:Any]])[0]["finalDisplayStroke"] as? [Double] == [160,60,190],
    "terminal row receipt reports colored stroke")
var legacy = raw; legacy.sourceContourOnly = false
let legacyLayer = try prepared(legacy)
check(!legacyLayer.sourceContourOnly && legacyLayer.outwardPixels == 2, "legacy floor retained")
let legacyPaint = try Composer.mandatoryStrokeLayer(restored: background, fills: [legacy], expectedItems: 1, textComplete: true)
phase("legacy ring painted")
let legacyBytes = try rgba(legacyPaint.image)
check(legacyBytes[(36*96+36)*4+3] > 0, "fixture actually exercises legacy closed counter")
let certified = try NativeRetainedStrokePainter.paint(restored:background, fills:[legacy], expectedItems:1, textComplete:true)
let certificate = (certified.audit["retainedStrokeItems"] as! [[String:Any]])[0]
check(certificate["visibleOutlineCertified"] as? Bool == true &&
      certificate["substantialCoreChangedPixels"] as? Int == 0, "unchanged legacy BW visibility/core certificate")
let omitted = try NativeMandatoryDisplayStroke.prepare(fill: fillImage, restored: background,
    fontOutputPixels: 10, fillFrame: raw.frame, forcedEndpoint: 0)
check(try rgba(omitted.fill) == rgba(legacyLayer.fill) && rgba(omitted.halo) == rgba(legacyLayer.halo),
    "default false and explicit false byte-identical")
rejects("prepared policy mismatch") { _ = try N.verify([raw], layers: [legacyLayer], page: page) }
// Keep actual pale/gradient/AA samples, including alpha1, without recoloring.
let alphas: [UInt8] = [1,63,64,127,128,254,255]
var aa = [UInt8](repeating: 0, count: 9*9*4)
for (x,a) in alphas.enumerated() {
    let p = (4*9+x+1)*4
    for c in 0..<3 { aa[p+c] = UInt8((Double([250,245,240][c])*Double(a)/255).rounded()) }
    aa[p+3] = a
}
var pale = raw
pale.image = try image(aa, 9, 9); pale.frame = CGRect(x: 50, y: 50, width: 9, height: 9)
pale.ownerID = "aa"; pale.recheckFinalEndpoint = true; pale.displayStrokeEndpoint = 255
let palePrepared = try prepared(pale)
check(try rgba(palePrepared.fill) == aa, "all premultiplied pale AA fill bytes exact")
check(palePrepared.endpointDecision["whiteFillOverride"] as? Bool == false, "no near-white recolor")
let mixed = try Composer.mandatoryStrokeLayer(restored: background, fills: [raw,pale], expectedItems: 2, textComplete: true)
phase("AA union painted")
check(mixed.audit["finalCompositeAlphaVerified"] as? Bool == true, "AA and owner union final raster gate")
// No threshold may drop faint source support from domain admission.
let paleSupport = try N.retainedFootprint(pale)
let palePixelCount = try N.verify([pale], layers: [palePrepared], page: page)
check(palePixelCount == paleSupport.pixels, "faint alpha remains counted")
var alphaOne: CGPoint?
let palePaint = try Composer.mandatoryStrokeLayer(restored: background, fills: [pale], expectedItems: 1, textComplete: true)
let paleBytes = try rgba(palePaint.image)
for y in 0..<96 { for x in 0..<96 where paleBytes[(y*96+x)*4+3] == 1 { alphaOne = CGPoint(x:x,y:y) }}
check(alphaOne != nil, "fixture contains actual alpha1 effect support")
let forbidden = CGRect(origin: alphaOne!, size: CGSize(width:1,height:1))
var denied = pale; denied.placementDomain = { !$0.intersects(forbidden) }
rejects("alpha1 domain spill") { _ = try N.verify([denied], layers: [palePrepared], page: page) }
// Direct preparation at a page edge cannot certify a cropped source contour.
// Its fill has no transparent inset, so the band truly crosses the page.
var edge = raw
edge.image = try image([0,0,0,255, 0,0,0,255, 0,0,0,255, 0,0,0,255], 2, 2)
edge.frame = CGRect(x:0,y:30,width:2,height:2)
let edgePrepared = try prepared(edge)
let edgeSupport = try N.retainedFootprint(edge)
check(edgeSupport.bounds.minX < 0, "unclipped source band actually extends off-page")
rejects("direct edge verify cannot lose band") { _ = try N.verify([edge], layers:[edgePrepared], page:page) }
rejects("fixed edge cannot lose band") { _ = try N.place([edge], page:page, fixedOrigins:["ring":edge.frame.origin]) }
let edgeAdmitted = try N.place([edge], page:page)
phase("edge admitted")
check(edgeAdmitted.fills[0].frame.minX > 0, "edge relocation protects complete source contour")
let safeEdge = try Composer.refineFinalReadability(layer:sourcePaint, fills:[edge], restored:background,
    admittedOverride:edgeAdmitted, forceRepaint:true)
let relocatedSupport = try N.retainedFootprint(edgeAdmitted.fills[0])
try N.verifyRaster(safeEdge.image, expectedPixels:relocatedSupport.pixels)
check(safeEdge.audit["finalRetainedAlphaPixels"] as? Int == edgeSupport.pixels, "edge repair loses no effect alpha")
// A tight raw-only domain cannot waive the surrounding source band.
var narrow = raw; narrow.placementDomain = { raw.frame.contains($0) }
// Ring's transparent inset holds this 1px band, so use the solid edge raster.
narrow.image = edge.image; narrow.frame = CGRect(x:30,y:30,width:2,height:2)
let narrowFrame = narrow.frame; narrow.placementDomain = { narrowFrame.contains($0) }
rejects("source band outside assigned domain") { _ = try N.verify([narrow],layers:[prepared(narrow)],page:page) }
var peer = raw; peer.ownerID = "peer"
rejects("source peer overlap") { _ = try N.verify([raw,peer],layers:[contour,contour],page:page) }
// Invalid opt-in style must fail, not paint unoutlined or double-styled text.
for invalidStyle: NativeSourceStylePaint.Style? in [nil,
    .init(sourceFontPixels:10,bands:[],shadow:nil),
    .init(sourceFontPixels:10,bands:style.bands+style.bands,shadow:nil),
    .init(sourceFontPixels:10,bands:style.bands,shadow:.init(rgb:[10,20,30],offset:[1,1])),
    .init(sourceFontPixels:10,bands:[.init(rgb:[160,60,190],width:Double.nan)],shadow:nil)] {
    var invalid = raw; invalid.sourceStyle = invalidStyle
    rejects("invalid source contour style") { _ = try N.retainedFootprint(invalid) }
    rejects("invalid source contour composer") {
        _ = try Composer.mandatoryStrokeLayer(restored:background,fills:[invalid],expectedItems:1,textComplete:true)
    }
}
var prepainted = raw; prepainted.hasFinalEffects = true
rejects("prepainted opt-in invalid") { _ = try N.retainedFootprint(prepainted) }
prepainted.sourceContourOnly = false
check(try N.retainedFootprint(prepainted).pixels == 56, "default-false prepainted support is exact incumbent raster")
var invalidGeometry = raw; invalidGeometry.frame.origin.x = 0.5
rejects("fractional raw geometry") { _ = try prepared(invalidGeometry) }
// Existing production regression programs remain intact; invoke all assertions.
phase("legacy source style suite")
try NativeSourceStylePaintSmoke.main()
phase("legacy stroke suite")
try StrokeSmoke.main()
print("PASS \(checks) source-contour-only core checks plus unchanged multiband/shadow, BW selection/white-fill and retained BW certificate")
} catch {
    FileHandle.standardError.write(Data("FAIL after \(checks): \(error)\n".utf8)); exit(1)
}
'''


def main():
    with tempfile.TemporaryDirectory(prefix='aidoku-source-contour-only-') as directory:
        cache = Path(directory)
        composer = (ENGINE / 'NativeAOTTranslationPageComposer.swift').read_text()
        text_layer = composer[composer.index('    struct TextLayer {'):composer.index('    struct Result {')]
        failure = re.search(r'    enum Failure: Error \{.*?\n    \}', composer, re.S).group()
        (cache / 'ComposerTypes.swift').write_text('import CoreGraphics\nimport Foundation\n'
            'final class NativeAOTTranslationPageComposer {\n' + text_layer + failure + '\n}\n')
        hashes = {}
        for name in SOURCES:
            data = (ENGINE / (name + '.swift')).read_bytes()
            (cache / (name + '.swift')).write_bytes(data)
            hashes[name + '.swift'] = hashlib.sha256(data).hexdigest()
        smoke_files = []
        for name in ['NativeSourceStylePaintSmoke', 'NativeRenderedStrokeSelectionSmoke']:
            data = Path(__file__).with_name(name + '.swift').read_text()
            if name == 'NativeSourceStylePaintSmoke':
                data = 'import CoreGraphics\nimport Foundation\n' + data[data.index('@main enum'):]
            data = data.replace('@main ', '')
            snapshot = cache / (name + '.swift')
            snapshot.write_text(data)
            smoke_files.append(str(snapshot))
        (cache / 'main.swift').write_text(HARNESS)
        env = {k:v for k,v in os.environ.items() if not k.startswith('AIDOKU_')}
        env['CLANG_MODULE_CACHE_PATH'] = str(cache / 'clang-modules')
        executable = cache / 'check'
        start = time.monotonic()
        subprocess.run(['xcrun','swiftc','-O','-module-cache-path',str(cache / 'swift-modules'),
            *[str(cache / (name + '.swift')) for name in SOURCES],str(cache / 'ComposerTypes.swift'),
            *smoke_files,str(cache / 'main.swift'),'-o',str(executable)],check=True,env=env)
        compiled = time.monotonic()
        print(f'Isolated compile seconds: {compiled-start:.3f}', flush=True)
        subprocess.run([str(executable)],check=True,env=env)
        print(json.dumps({'compileSeconds':round(compiled-start,3),
            'testSeconds':round(time.monotonic()-compiled,3),'cache':str(cache),
            'sourceSHA256':hashes,'datasetImages':0,'sharedBuilds':0}))


if __name__ == '__main__':
    main()
