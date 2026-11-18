#!/usr/bin/env python3
"""Real Composer final-paint anchor regression; synthetic pixels/private temp caches only."""
import json
import hashlib
import os
from pathlib import Path
import re
import runpy
import subprocess
import tempfile
import time

BASE = runpy.run_path(str(Path(__file__).with_name("run-balloon-readability-reflow-smoke.py")))
ENGINE = BASE["ENGINE"]
SOURCES = BASE["SOURCES"]
HARNESS = r'''
import CoreGraphics
import Foundation
import Darwin

typealias Composer = NativeAOTTranslationPageComposer
typealias Fill = Composer.TranslatedFillPrimitive
typealias Admission = (fills: [Fill], audit: [[String: Any]])
let page = CGRect(x: 0, y: 0, width: 400, height: 400)
func check(_ value: Bool, _ message: String) {
    if !value { fatalError(message) }
}
func raster(_ w: Int, _ h: Int, white: Bool = false) -> CGImage {
    let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.setFillColor(CGColor(gray: white ? 1 : 0, alpha: 1))
    c.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return c.makeImage()!
}
func normalized(_ r: CGRect) -> [Double] { [r.minX/400, r.minY/400, r.width/400, r.height/400].map(Double.init) }
func expectFailure(_ name: String, contains: String? = nil, _ body: () throws -> Void) throws {
    do { try body() } catch {
        if let contains { check(String(describing: error).contains(contains), "wrong failure for \(name): \(error)") }
        print("NEGATIVE \(name): \(error)")
        return
    }
    fatalError("unexpected success: \(name)")
}
let restored = raster(400, 400, white: true)
func test(_ axis: NativeSourceClusterAlignment.Axis) throws {
    let transpose = axis == .left
    func rect(_ r: CGRect) -> CGRect {
        transpose ? CGRect(x: r.minY, y: r.minX, width: r.height, height: r.width) : r
    }
    let n = normalized(page)
    let policy = NativeTextExpansionPolicy(allowedRectNormalized: n, candidates: [n], maskCoverage: [1],
        backgroundRisk: [0], sourceFontPixels: 20, kind: "inside-balloon-mask", maskRectNormalized: n,
        maskSpansNormalized: Array(repeating: [0.0, 1.0], count: 400).flatMap { $0 })
    let packet = NativeSourceClusterAlignment(groupID: "retained", axis: axis, anchorNormalized: 0.425,
        anchorPolicy: "source-near-final-alpha")
    func fill(_ owner: String, _ frame: CGRect, _ guide: CGRect) -> Fill {
        let frame = rect(frame)
        var f = Fill(image: raster(Int(frame.width), Int(frame.height)), frame: frame, fontOutputPixels: 20)
        f.ownerID = owner; f.displayStrokeEndpoint = 255
        f.textExpansionPolicy = policy; f.placementDomain = { policy.allows($0, page: page) }
        f.sourceClusterAlignment = packet
        f.textPlacementGuide = .init(rectNormalized: normalized(rect(guide)), horizontal: .center, vertical: .center)
        return f
    }
    let first = fill("owner", CGRect(x: 64, y: 174, width: 100, height: 60), CGRect(x: 74, y: 160, width: 80, height: 88))
    var peer = fill("peer", CGRect(x: 254, y: 174, width: 20, height: 20), CGRect(x: 249, y: 160, width: 30, height: 48))
    // An unchanged peer has no cross-axis capacity to follow a recomputed
    // target. Re-proposing the changed incumbent must genuinely fail here.
    let peerDomain = rect(CGRect(x: 250, y: 170, width: 28, height: 28))
    peer.placementDomain = { peerDomain.contains($0) }
    let originals = [first, peer]
    let supports = try originals.map { try NativeFinalTextPaintAdmission.retainedFootprint($0) }
    check(supports[0].bounds == rect(CGRect(x: 60, y: 170, width: 108, height: 68)), "real original halo support")
    let fixed = Dictionary(uniqueKeysWithValues: zip(["owner", "peer"], supports.map { $0.bounds.origin }))
    let before = try NativeFinalTextPaintAdmission.place(originals, page: page, fixedOrigins: fixed)
    let baseline = try Composer.mandatoryStrokeLayer(restored: restored, fills: originals, expectedItems: 2, textComplete: true)
    let text = "alpha beta gamma delta"
    let descriptor = NativeBalloonReadabilityReflow.Descriptor(text: text, ranges: [
        NSRange(location: 0, length: 2), NSRange(location: 2, length: 3), NSRange(location: 5, length: 5),
        NSRange(location: 10, length: 5), NSRange(location: 15, length: 7)])
    let after = try NativeBalloonReadabilityReflow.refineInteriorWords(before, descriptors: ["owner": descriptor],
        page: page, completePeerContext: true, restored: restored, outerWidths: { _ in 100 },
        extraOuterWidths: { _ in [] }, allowRowReduction: true) { _, _, _ in
        var candidate = before.fills[0]
        let shape = rect(CGRect(x: 64, y: 174, width: 100, height: 20))
        candidate.image = raster(Int(shape.width), Int(shape.height)); candidate.frame = shape
        return .init(fill: candidate, ranges: [NSRange(location: 0, length: 11), NSRange(location: 11, length: 11)])
    }
    check(after.selected.count == 1, "real reflow selects the retained-anchor candidate: \(after.diagnostics)")
    check(after.audit[0]["retainedSourceClusterAnchorApplied"] as? Bool == true, "selected marker")
    check(after.audit[1]["retainedSourceClusterAnchorApplied"] == nil, "peer needs no marker")
    check(NSDictionary(dictionary: after.audit[1]).isEqual(to: before.audit[1]), "peer audit unchanged")
    check(after.fills[1].image === before.fills[1].image && after.fills[1].frame == before.fills[1].frame, "peer raster/frame unchanged")
    func paint(_ value: Admission) throws -> Composer.TextLayer {
        try Composer.refineFinalReadability(layer: baseline, fills: after.fills, restored: restored,
            admittedOverride: value, forceRepaint: true)
    }
    let value: Admission = (after.fills, after.audit)
    let final = try paint(value)
    check(final.complete && final.expectedItems == 2 && final.paintedItems == 2, "complete real final paint")
    check(final.audit["finalCompositeAlphaVerified"] as? Bool == true, "production raster gate executed")
    check(final.audit["finalPaintBoundsChecked"] as? Bool == true, "production support gate executed")
    let bytes = try NativeMandatoryDisplayStroke.rgba(final.image)
    let pixels = stride(from: 3, to: bytes.count, by: 4).filter { bytes[$0] != 0 }.count
    check(pixels > 0 && pixels == final.audit["finalRetainedAlphaPixels"] as? Int, "independent composite alpha count")
    let originalBaselinePaint = try Composer.refineFinalReadability(layer: baseline, fills: before.fills,
        restored: restored, admittedOverride: value, forceRepaint: true)
    let repainted = try Composer.refineFinalReadability(layer: final, fills: after.fills,
        restored: restored, admittedOverride: value, forceRepaint: true)
    check(try NativeMandatoryDisplayStroke.rgba(originalBaselinePaint.image) == bytes, "changed baseline preserves exact original-path RGBA")
    let repaintBytes = try NativeMandatoryDisplayStroke.rgba(repainted.image)
    check(repaintBytes == bytes, "retained incumbent repaint has byte-identical RGBA")
    check(stride(from: 3, to: repaintBytes.count, by: 4).allSatisfy { repaintBytes[$0] == bytes[$0] }, "identical retained alpha plane")
    check(stride(from: 3, to: repaintBytes.count, by: 4).filter { repaintBytes[$0] != 0 }.count == pixels,
        "identical independent nonzero alpha count")
    check(repainted.complete && repainted.expectedItems == 2 && repainted.paintedItems == 2,
        "retained incumbent preserves complete item accounting")
    check(repainted.audit["finalCompositeAlphaVerified"] as? Bool == true &&
          repainted.audit["finalPaintBoundsChecked"] as? Bool == true &&
          repainted.audit["finalRetainedAlphaPixels"] as? Int == pixels, "repaint reaches actual support and raster gates")
    check(NSDictionary(dictionary: (repainted.audit["finalPaintAdmission"] as! [[String: Any]])[0])
        .isEqual(to: value.audit[0]), "retained admission receipt preserved")
    try expectFailure("legacy unconditional changed-incumbent place", contains: "noSafePlacement") {
        _ = try NativeFinalTextPaintAdmission.place(after.fills, page: page)
    }
    print("PASS retained-incumbent forced repaint \(axis.rawValue): identical RGBA/alpha/nonzero=\(pixels)")
    let actual = try after.fills.map { f in
        try NativeFinalTextPaintAdmission.footprint(layer: NativeMandatoryDisplayStroke.prepare(fill: f.image,
            restored: restored, fontOutputPixels: f.fontOutputPixels, fillFrame: f.frame, forcedEndpoint: f.displayStrokeEndpoint),
            style: f.sourceStyle, fontPixels: f.fontOutputPixels)
    }
    check(actual[0].bounds == rect(CGRect(x: 60, y: 170, width: 108, height: 28)), "final actual retained shape")
    check(!NativeFinalTextPaintAdmission.intersects(actual[0], actual[1]), "final support disjoint")
    let targets = try NativeSourceClusterAlignment.targets(after.fills.map(\.sourceClusterAlignment),
        bounds: actual.map(\.bounds), page: page, guides: after.fills.map(\.textPlacementGuide), capacities: after.fills.map(\.textExpansionPolicy))
    check(targets[0] == 180, "changed extent actually changes default target")
    try expectFailure("unflagged default target", contains: "source-cluster") {
        var noFlag = value; noFlag.audit[0].removeValue(forKey: "retainedSourceClusterAnchorApplied")
        _ = try paint(noFlag)
    }
    for name in ["stale bounds", "stale pixels", "owner", "axis", "peer receipt", "prior receipt", "boolean anchor", "nan anchor", "audit count", "duplicate owner"] {
        var bad = value
        switch name {
        case "stale bounds": bad.audit[0]["finalFootprintOutputPixels"] = [0, 0, 108, 28]
        case "stale pixels": bad.audit[0]["paintedPixels"] = 1
        case "owner": bad.audit[1]["owner"] = "other"
        case "axis": bad.audit[1]["sourceClusterAxis"] = transpose ? "top" : "left"
        case "peer receipt": bad.audit[1].removeValue(forKey: "sourceClusterAnchorOutputPixels")
        case "prior receipt": bad.audit[0].removeValue(forKey: "preInteriorWordReflowPlacement")
        case "boolean anchor": bad.audit[0]["sourceClusterAnchorOutputPixels"] = true
        case "nan anchor": bad.audit[0]["sourceClusterAnchorOutputPixels"] = Double.nan
        case "audit count": bad.audit.removeLast()
        default: bad.fills[1].ownerID = "owner"
        }
        try expectFailure(name) { _ = try paint(bad) }
    }
    var capacity = value
    let limited = NativeTextExpansionPolicy(allowedRectNormalized: normalized(rect(CGRect(x: 0, y: 200, width: 400, height: 200))),
        candidates: [n], maskCoverage: [1], backgroundRisk: [0], sourceFontPixels: 20, kind: "inside-balloon-mask",
        maskRectNormalized: n, maskSpansNormalized: Array(repeating: [0.0, 1.0], count: 400).flatMap { $0 })
    for i in capacity.fills.indices { capacity.fills[i].textExpansionPolicy = limited }
    try expectFailure("retained capacity", contains: "noPageCapacity") { _ = try paint(capacity) }
    var body = value
    for i in body.fills.indices {
        body.fills[i].balloonPlacement = NativeBalloonPlacement(crossAlignment: .center, bodyID: "body", rectNormalized: n,
            preserveSourceOffsets: true, biasNormalized: [0, 0], flow: transpose ? .column : .row,
            paddingEm: 0, gapEm: 0, maskSHA256: String(repeating: "0", count: 64), order: i)
    }
    try expectFailure("body residual remains mandatory", contains: "body-residual") { _ = try paint(body) }
    var domain = value; domain.fills[0].placementDomain = { _ in false }
    try expectFailure("actual domain", contains: "clippedEffects") { _ = try paint(domain) }
    var collision = value; collision.fills[1].frame = collision.fills[0].frame
    collision.fills[1].frame.size = CGSize(width: 20, height: 20)
    // Isolate collision rejection from the deliberately locked peer domain.
    collision.fills[1].placementDomain = { policy.allows($0, page: page) }
    try expectFailure("actual peer alpha", contains: "finalCollision") { _ = try paint(collision) }
    print("PASS actual Composer final paint + retained \(axis.rawValue) anchor; alpha=\(pixels)")
}
setenv("AIDOKU_INTERIOR_MEASURED_WIDTHS", "1", 1)
setenv("AIDOKU_INTERIOR_WORD_REFLOW", "1", 1)
try test(.top)
try test(.left)
print("PASS final-anchor-paint: real reflow, full production Composer, shared invariants and raster verification")
'''


def main():
    with tempfile.TemporaryDirectory(prefix="aidoku-final-anchor-paint-") as directory:
        cache = Path(directory)
        # Copy production value types verbatim; no model/restoration dependency or painter stubs.
        composer = (ENGINE / "NativeAOTTranslationPageComposer.swift").read_text()
        text_layer = composer[composer.index("    struct TextLayer {"):composer.index("    struct Result {")]
        failure = re.search(r"    enum Failure: Error \{.*?\n    \}", composer, re.S).group()
        (cache / "ComposerTypes.swift").write_text(
            "import CoreGraphics\nimport Foundation\nfinal class NativeAOTTranslationPageComposer {\n" + text_layer + failure + "\n}\n")
        names = SOURCES + ["NativeMandatoryDisplayStroke+Composer"]
        source_hashes = {}
        for name in names:
            data = (ENGINE / (name + ".swift")).read_bytes()
            (cache / (name + ".swift")).write_bytes(data)
            source_hashes[name + ".swift"] = hashlib.sha256(data).hexdigest()
        (cache / "main.swift").write_text(HARNESS)
        env = {k: v for k, v in os.environ.items() if not k.startswith("AIDOKU_")}
        env["CLANG_MODULE_CACHE_PATH"] = str(cache / "clang-modules")
        binary = cache / "check"
        start = time.monotonic()
        subprocess.run(["xcrun", "swiftc", "-O", "-module-cache-path", str(cache / "swift-modules"),
                        *[str(cache / (name + ".swift")) for name in names], str(cache / "ComposerTypes.swift"),
                        str(cache / "main.swift"), "-o", str(binary)], check=True, env=env)
        compiled = time.monotonic()
        subprocess.run([str(binary)], check=True, env=env)
        print(json.dumps({"compileSeconds": round(compiled - start, 3),
                          "testSeconds": round(time.monotonic() - compiled, 3), "cache": "isolated temporary",
                          "corpusInputs": 0, "sharedCacheBuilds": 0, "sourceSHA256": source_hashes,
                          "scriptSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}))


if __name__ == "__main__":
    main()
