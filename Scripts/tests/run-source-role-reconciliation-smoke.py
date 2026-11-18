#!/usr/bin/env python3
"""Private production-stage leaf: unchanged 133 controls, ordered-role reconciliation and actual owned ROIs."""
import argparse
import hashlib
import os
from pathlib import Path
import runpy
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
OVERLAY = ROOT / 'Aidoku/Core/Translation/NativeEngine/Overlay'
BASE = runpy.run_path(str(Path(__file__).with_name('run-source-role-evidence-smoke.py')))
HARNESS = r'''
func reconcile(_ f: Fixture, original: Payload, proposed: Payload?, budget initial: Int,
               expected: [Double]?, replaced: Bool, label: String) {
    var budget = initial
    let raw = original["sourceInk"] as? Payload
    let frozen = try! JSONSerialization.data(withJSONObject: original, options: [.sortedKeys])
    let decision = NativeSourceColorSamplingStage.corroborateObservedStrokeRoles(rgba: f.rgba, width: width,
        height: height, ownership: f.ownership, original: original, sourceInk: raw,
        proposed: proposed, observationBudget: &budget)
    let selected = decision["selectedStrokeEvidence"] as? Payload
    var errors: [String] = []
    if Sampler.rgb(selected?["foreground"]) != expected { errors.append("wrong reconciled source FG") }
    if decision["foregroundReplaced"] as? Bool != replaced { errors.append("wrong replacement provenance") }
    if initial - budget != Int(Sampler.number(decision["observerPixelsSpent"])) || budget < 0 {
        errors.append("unaccounted or negative observer budget")
    }
    if initial < pixels && budget != initial { errors.append("underfunded pass consumed partial pixel quota") }
    if replaced && decision["foregroundProvenance"] == nil { errors.append("replacement reused stale FG authority") }
    if replaced && decision["foregroundModelConfidence"] == nil { errors.append("replacement confidence missing") }
    if frozen != (try! JSONSerialization.data(withJSONObject: original, options: [.sortedKeys])) { errors.append("raw/source BG mutated") }
    report("reconciliation-" + label, errors, decision)
}
let good = forecastInput(orderedBlue)
let bad: Payload = ["foreground": photoBG, "stroke": white, "backgroundExits": 0, "exits": 100,
                    "foregroundModelConfidence": 0.99]
reconcile(orderedBlue, original: good, proposed: bad, budget: pixels, expected: orderedBlue.fill,
          replaced: false, label: "protect-actual-ordered-pair")
var alternate = forecastInput(orderedOrange)
alternate["foreground"] = [15.0,30,50]
alternate["sourceInk"] = ["foreground": [15.0,30,50], "stroke": white, "confidence": ["foreground": 1.0,"stroke": 1.0]]
reconcile(orderedOrange, original: alternate,
          proposed: ["foreground": orderedOrange.fill,"stroke": orange,"backgroundExits": 90,"exits": 100],
          budget: pixels * 2, expected: orderedOrange.fill, replaced: true, label: "legitimate-alternate-fill")
// No confidence-alone/raw blanket preference: wrong raw pair must not survive
// when a different actual ordered pair is supported, even with zero old observer exits.
reconcile(orderedOrange, original: alternate,
          proposed: ["foreground": orderedOrange.fill,"stroke": orange,"backgroundExits": 0,"exits": 100],
          budget: pixels * 2, expected: orderedOrange.fill, replaced: true, label: "alternate-needs-own-proof-not-old-exits")
reconcile(orderedBlue, original: good, proposed: bad, budget: 0, expected: nil, replaced: false, label: "budget-zero")
reconcile(orderedBlue, original: good, proposed: bad, budget: pixels - 1, expected: nil, replaced: false, label: "budget-short")
reconcile(orderedOrange, original: alternate,
          proposed: ["foreground": white,"stroke": orange], budget: pixels,
          expected: nil, replaced: false, label: "alternate-budget-spent-on-rejected-raw")
var stageUnowned = orderedBlue
stageUnowned.ownership = [UInt8](repeating: 0, count: pixels)
reconcile(stageUnowned, original: good, proposed: bad, budget: pixels * 2,
          expected: nil, replaced: false, label: "unowned-endpoints-no-raw-protection")
reconcile(orderedBlue, original: good,
          proposed: ["foreground": orderedBlue.fill,"stroke": orderedBlue.stroke], budget: 0,
          expected: orderedBlue.fill, replaced: false, label: "unchanged-pair-no-observation")
let stagePhoto = fixture("role-photo", fill: white, stroke: photoEdge, background: photoBG, shape: "blob")
var photoOriginal = forecastInput(stagePhoto)
photoOriginal["foreground"] = photoEdge
photoOriginal["sourceInk"] = ["foreground": photoEdge,"stroke": white,"confidence": ["foreground":1.0,"stroke":1.0]]
reconcile(stagePhoto, original: photoOriginal, proposed: ["foreground": white,"stroke": photoEdge,"backgroundExits":0],
          budget: pixels * 2, expected: nil, replaced: false, label: "photo-no-ordered-support")
let paper = fixture("black-paper", fill: [0,0,0], stroke: white, background: white)
reconcile(paper, original: forecastInput(paper), proposed: ["foreground": white,"stroke": [0,0,0],"backgroundExits":0],
          budget: pixels * 2, expected: nil, replaced: false, label: "white-paper-not-stroke")
var missing = alternate
missing["foreground"] = NSNull()
missing["sourceInk"] = NSNull()
reconcile(orderedOrange, original: missing, proposed: ["foreground": white,"stroke": orange], budget: pixels,
          expected: white, replaced: true, label: "missing-prior-legitimate-fill")
var refine = good
reconcile(orderedBlue, original: refine,
          proposed: ["foreground": [52.0,66,101],"stroke": white,"foregroundModelConfidence":0.45,
                     "foregroundProvenance":"fresh bounded observer score"], budget: 0,
          expected: [52,66,101], replaced: true, label: "endpoint-refinement-own-score")
let stageGate = AsyncStream<Void>.makeStream()
let stageCancelled = Task.detached {
    for await _ in stageGate.stream { break }
    var budget = pixels
    let decision = NativeSourceColorSamplingStage.corroborateObservedStrokeRoles(
        rgba: orderedBlue.rgba, width: width, height: height, ownership: orderedBlue.ownership,
        original: good, sourceInk: good["sourceInk"] as? Payload, proposed: bad,
        observationBudget: &budget)
    return Task.isCancelled && decision["selectedStrokeEvidence"] is NSNull && budget == pixels &&
        decision["orderedRoleEvidence"] == nil
}
stageCancelled.cancel(); stageGate.continuation.finish()
let stageGroup = DispatchGroup(); stageGroup.enter()
Task.detached {
    let ok = await stageCancelled.value
    report("reconciliation-cancelled", ok ? [] : ["cancelled stage protected raw or spent budget"], [:])
    stageGroup.leave()
}
stageGroup.wait()
for prefix in CommandLine.arguments.dropFirst() {
    let record = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: prefix + ".json"))) as! Payload
    let before = record["stageResult"] as! Payload, raw = before["sourceInk"] as! Payload
    let size = record["sampleSize"] as! [Int], w=size[0], h=size[1]
    let bytes = Array(try Data(contentsOf: URL(fileURLWithPath: prefix + ".rgba")))
    let owned = Array(try Data(contentsOf: URL(fileURLWithPath: prefix + ".ownership")))
    var original = before
    for key in ["foreground","stroke","confidence","widthEvidence"] { original[key] = raw[key] }
    var budget = w*h
    let proposed: Payload = ["foreground": before["foreground"]!, "stroke": before["stroke"]!, "backgroundExits":0]
    let decision = NativeSourceColorSamplingStage.corroborateObservedStrokeRoles(rgba: bytes, width:w,height:h,
        ownership:owned,original:original,sourceInk:raw,proposed:proposed,observationBudget:&budget)
    let selected=decision["selectedStrokeEvidence"] as? Payload
    var errors: [String] = []
    if Sampler.rgb(selected?["foreground"]) != Sampler.rgb(raw["foreground"]) { errors.append("actual raw FG overwritten") }
    if Sampler.rgb(selected?["stroke"]) != Sampler.rgb(raw["stroke"]) { errors.append("actual raw stroke lost or changed") }
    if (decision["orderedRoleEvidence"] as? Payload)?["accepted"] as? Bool != true { errors.append("actual raw pair not corroborated") }
    if budget != 0 { errors.append("actual raw pair protection was not charged exactly once") }
    report("actual-stage-reconciliation-" + URL(fileURLWithPath:prefix).lastPathComponent, errors, decision)
}
print("RECONCILIATION_SUMMARY PASS=\(passed) FAIL=\(failed)")
if failed != 0 { exit(1) }
'''

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pixel-case',action='append',default=[])
    args=parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='aidoku-source-role-stage-') as directory:
        t=Path(directory); cache=t/'module-cache'; cache.mkdir()
        env=os.environ.copy(); env.update(CLANG_MODULE_CACHE_PATH=str(cache),SWIFT_MODULECACHE_PATH=str(cache))
        parts=[]
        for name in ['NativeSourceColorSampler.swift','NativeTranslationPixelKernels.swift','NativeSourceROIFeatures.swift',
                     'NativeCaptionSourcePalette.swift','NativeObservedSourcePalette.swift','NativeSourceLetteringScale.swift',
                     'NativeSourceColorSamplingStage.swift']:
            data=(OVERLAY/name).read_bytes(); parts.append(data)
            print('SOURCE',name,hashlib.sha256(data).hexdigest(),flush=True)
        (t/'main.swift').write_bytes(b'\n'.join(parts)+BASE['HARNESS'].encode()+HARNESS.encode())
        lib=t/'kernels.a'
        subprocess.run(['rustc','--crate-type','staticlib','--crate-name','aidoku_overlay_kernels',
            '-C','opt-level=3','-C','panic=abort',str(ROOT/'Scripts/overlay-kernels/kernels.rs'),'-o',str(lib)],env=env,check=True)
        started=time.monotonic()
        subprocess.run(['xcrun','swiftc','-O','-D','AIDOKU_SOURCE_ROLE_LOCAL_CANDIDATE','-module-cache-path',str(cache),
            str(t/'main.swift'),'-I',str(ROOT/'Scripts/overlay-kernels/native'),str(lib),'-o',str(t/'smoke')],env=env,check=True)
        print('Private compileSeconds',round(time.monotonic()-started,2),flush=True)
        subprocess.run([str(t/'smoke'),*args.pixel_case],env=env,check=True)

if __name__=='__main__': main()
