#!/usr/bin/env python3
"""Replay actual original palette evidence through current production functions.

No image review, inference, renderer, model build, or corpus acceptance claim.
Fixture IDs locate recorded evidence only; production predicates never see them.
"""
import argparse
import ast
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import time


REPO = Path(__file__).resolve().parents[2]
ENSEMBLE = REPO / "Aidoku/Core/Translation/NativeEngine/Ensemble"
UPPER = "0455 0460 0477 0490 0494 0496 0528 0570 0580 0586 0604 0676 0696 0703 0708 0807 0827".split()


def declaration(source, marker):
    start = source.index(marker)
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        if source[end] == "{":
            depth += 1
        elif source[end] == "}":
            depth -= 1
        end += 1
    return source[start:end]


HARNESS = r'''
typealias P = PaletteCarrier
var checks=0
func check(_ condition:Bool,_ message:String) {
    precondition(condition,message);checks += 1
}
func observation(_ audit:[String:Any]) -> P.Observation {
    let raw=audit["previousOriginalEvidence"] as? [String:Any]
    let topology=raw?["sourceInkDominance"] as? [String:Any]
    let keys=["fillPixels","strokePixels","fillShapePixels","strokeShapePixels",
        "fillRepeatedTiles","strokeRepeatedTiles","fillEnclosedPixels","strokeEnclosedPixels"]
    let n=keys.compactMap{(topology?[$0] as? NSNumber)?.doubleValue}
    let evidence:NativeSourceInkSelection.Evidence? = n.count==8
        ? .init(fillPixels:n[0],strokePixels:n[1],fillShapePixels:n[2],strokeShapePixels:n[3],
            fillRepeatedTiles:n[4],strokeRepeatedTiles:n[5],fillEnclosedPixels:n[6],strokeEnclosedPixels:n[7]) : nil
    return .init(originalFill:audit["sourceFill"] as? [Double],originalStroke:audit["sourceStroke"] as? [Double],
        evidence:evidence,selected:.init(color:audit["selectedOriginalInk"] as? [Double],
        role:audit["selectedRole"] as? String ?? "unknown",neutralExteriorSuppressed:false),
        rawPrediction:raw,unknownReason:audit["uncertainty"] as? String)
}
func consensus(_ value:P.Observation) -> [String:Any] {value.rawPrediction!["memberPaletteConsensus"] as! [String:Any]}
func accepted(_ value:P.Observation) -> Bool {consensus(value)["accepted"] as? Bool==true}
func combine(_ observations:[P.Observation],enabled:Bool=true,inkOnly:Bool=true) -> P.Observation {
    P.combineMembers(observations,members:observations.indices.map{["id":"owner-\($0)"]},inkOnly:inkOnly,
        recoverColumnShell:true,recoverNativePeers:true,recoverMeasuredEvidence:enabled)
}
func frozen(_ value:Any) -> Data {try! JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])}
let fixture=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [String:Any]
let cases=fixture["cases"] as! [[String:Any]]
var observationsByCase=[String:[P.Observation]]()
for record in cases {
    let name=record["name"] as! String
    let observations=(record["audits"] as! [[String:Any]]).map(observation)
    observationsByCase[name]=observations
    let before=frozen(observations.map{$0.rawPrediction ?? [:]})
    let off=combine(observations,enabled:false),on=combine(observations)
    check(!accepted(off),name+" baseline must reproduce recorded veto")
    let expected=record["expectedAccepted"] as! Bool
    check(accepted(on)==expected,name+" candidate result")
    check(before==frozen(observations.map{$0.rawPrediction ?? [:]}),name+" input mutated")
    check(accepted(combine(Array(observations.reversed())))==expected,name+" order dependence")
    if expected {
        let audit=consensus(on)
        let members=audit["members"] as! [[String:Any]]
        for (index,member) in members.enumerated() where member["measuredEvidenceRecovered"] as? Bool==true {
            let own=P.recoveredMeasuredOriginal(observations[index])!
            check(member["selected"] as? [Double]==own.selected.color,name+" copied peer instead of own endpoint")
            check(member["fill"] as? [Double]==own.originalFill,name+" native original fill lost")
            check(member["stroke"] as? [Double]==own.originalStroke,name+" native original stroke lost")
            check(member["measuredEvidenceRecovery"] is [String:Any],name+" witness provenance lost")
        }
        check(!accepted(combine(observations,inkOnly:false)),name+" strict endpoint policy weakened")
    } else {
        check(consensus(on)["measuredEvidenceRecoveredMembers"] as? [String]==[],name+" unsupported recovery")
    }
    print("ACTUAL",name,"baselineRejected=true candidateAccepted=\(accepted(on))",
        "recovered=\(consensus(on)["measuredEvidenceRecoveredMembers"]!)")
}
let dark=observationsByCase["0248"]![1]
let pale=observationsByCase["0359"]![0]
check(P.recoveredMeasuredOriginal(dark)!.selected.color==[1,2,1],"stale zero confidence lost independent dark witness")
check(P.recoveredMeasuredOriginal(pale)!.selected.color==[239,249,248],"native topology did not correct coarse role")
check(P.recoveredMeasuredOriginal(observationsByCase["0359"]![1])!.selected.color==[240,249,248],
    "unknown owner must establish its own shell")
check(P.recoveredMeasuredOriginal(observationsByCase["0265"]![0])==nil,"three coarse components are not native proof")
func changing(_ observation:P.Observation,_ edit:(inout [String:Any])->Void) -> P.Observation {
    var raw=observation.rawPrediction!
    var scales=raw["multiscale"] as! [String:Any],native=scales["native"] as! [String:Any]
    edit(&native);scales["native"]=native;raw["multiscale"]=scales
    return .init(originalFill:observation.originalFill,originalStroke:observation.originalStroke,
        evidence:observation.evidence,selected:observation.selected,rawPrediction:raw,unknownReason:observation.unknownReason)
}
func rejected(_ observation:P.Observation,_ label:String,_ edit:(inout [String:Any])->Void) {
    check(P.recoveredMeasuredOriginal(changing(observation,edit))==nil,label)
}
for key in ["fillPixels","strokePixels","fillShapePixels","strokeShapePixels",
            "fillRepeatedTiles","strokeRepeatedTiles","fillEnclosedPixels","strokeEnclosedPixels"] {
    rejected(dark,"missing topology "+key) { native in
        var t=native["sourceInkDominance"] as! [String:Any];t.removeValue(forKey:key);native["sourceInkDominance"]=t
    }
    for bad in [-1.0,Double.nan,Double.infinity] {
        rejected(dark,"invalid topology "+key) {native in
            var t=native["sourceInkDominance"] as! [String:Any];t[key]=bad;native["sourceInkDominance"]=t
        }
    }
}
for (key,value) in [("fillShapePixels",11.0),("strokeShapePixels",11.0),("fillRepeatedTiles",3.0),
                    ("strokeRepeatedTiles",3.0),("fillRepeatedTiles",37.0),("fillPixels",1.0),
                    ("strokePixels",1.0),("fillEnclosedPixels",100000.0)] {
    rejected(dark,"weak/inconsistent topology "+key) {native in
        var t=native["sourceInkDominance"] as! [String:Any];t[key]=value;native["sourceInkDominance"]=t
    }
}
for key in ["foreground","stroke","background"] {
    for bad:[Double] in [[Double.nan,2,1],[256,2,1],[-1,2,1],[1,2]] {
        rejected(dark,"invalid RGB "+key){$0[key]=bad}
    }
    rejected(dark,"missing RGB "+key){$0.removeValue(forKey:key)}
}
for value in [0.5,3,Double.nan] {
    rejected(dark,"invalid native sample scale") {native in
        var s=native["sourceSamplingPolicy"] as! [String:Any];s["sampleScale"]=value;native["sourceSamplingPolicy"]=s
    }
}
rejected(dark,"no independent component witness"){$0.removeValue(forKey:"endpointRecovery")}
rejected(dark,"weak component quorum"){$0["endpointRecovery"]=["components":5]}
rejected(dark,"native background cannot vote as ink"){$0["background"]=$0["foreground"]}
rejected(pale,"no ordered shell proof"){$0.removeValue(forKey:"gradientShellRecovery")}
for (key,value) in [("rays",23),("spatialSupport",3),("spatialSupport",37)] {
    rejected(pale,"weak ray proof "+key){native in
        var s=native["gradientShellRecovery"] as! [String:Any];s[key]=value;native["gradientShellRecovery"]=s
    }
}
rejected(pale,"shell RGB mismatch"){native in
    var s=native["gradientShellRecovery"] as! [String:Any];s["rgb"]=[80,90,100];native["gradientShellRecovery"]=s
}
for value in [0.39,1.1,Double.nan] {
    rejected(pale,"insufficient own core confidence") {native in
        var c=native["confidence"] as! [String:Any];c["foreground"]=value;native["confidence"]=c
    }
}
rejected(pale,"native fill must corroborate own original core"){$0["foreground"]=[200.0,201,202]}
let unknown=P.Observation(originalFill:nil,originalStroke:nil,evidence:nil,
    selected:.init(color:nil,role:"unknown",neutralExteriorSuppressed:false),rawPrediction:nil,unknownReason:"missing")
check(!accepted(combine([dark,unknown])),"unknown bypass")
check(!accepted(combine([unknown,unknown])),"mutual unknown bypass")
// Independent recoveries must still agree over the whole group, within 24.
check(!accepted(combine([dark,pale])),"conflicting independent ink admitted")
check(!accepted(combine([dark,observationsByCase["0248"]![0],pale])),"third owner conflict ignored")
let same=[dark,dark]
let sameOff=combine(same,enabled:false),sameOn=combine(same)
check(accepted(sameOff) && accepted(sameOn),"agreeing baseline rejected")
check(sameOn.selected.color==sameOff.selected.color,"established consensus recolored")
check(consensus(sameOn)["measuredEvidenceRecoveryAttempted"] as? Bool==false,"agreeing group reprocessed")
check(!accepted(combine([dark])),"singleton group admitted")
check(!accepted(combine(Array(repeating:dark,count:7))),"oversize group admitted")
var geometry:[String:Any]=["sourceTextBlockMemberPalette":true,"agent02MemberItems":[["id":"a"],["id":"b"]]]
let keyOff=try P.memoDependencies(geometry)
let offDescriptor=try JSONSerialization.jsonObject(with:keyOff!) as! [String:Any]
check(offDescriptor["version"] as? Int==7,"memo descriptor version must invalidate v6")
check(offDescriptor["measuredEvidenceRecovery"] as? Bool==false,"missing flag must be explicit false")
geometry["sourceTextBlockMeasuredEvidenceRecovery"]=true
let keyOn=try P.memoDependencies(geometry)
check(keyOff != keyOn,"candidate memo collision")
let onDescriptor=try JSONSerialization.jsonObject(with:keyOn!) as! [String:Any]
check(onDescriptor["version"] as? Int==7 && onDescriptor["measuredEvidenceRecovery"] as? Bool==true,
    "enabled candidate missing from memo descriptor")
var priorVersion=onDescriptor;priorVersion["version"]=6
check(keyOn != frozen(priorVersion),"v6 consensus key reused after descriptor bump")
var nested:[String:Any]=["sourceTextBlockMemberPalette":true,"agent02MemberItems":[geometry,["id":"c"]]]
let nestedOn=try P.memoDependencies(nested)
geometry["sourceTextBlockMeasuredEvidenceRecovery"]=false;nested["agent02MemberItems"]=[geometry,["id":"c"]]
check(nestedOn != (try P.memoDependencies(nested)),"nested candidate memo collision")
check(keyOff == (try P.memoDependencies(geometry)),"explicit false differs from default off")
geometry["sourceTextBlockMeasuredEvidenceRecovery"]=true
check(keyOn == (try P.memoDependencies(geometry)),"on/off/on memo identity unstable")
print("PASS production function checks=\(checks); manifest denominator=836; visual acceptance not measured")
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--logs", type=Path, default=REPO.parent / "rendered-confirmed-logs-v24")
    parser.add_argument("--upper-logs", type=Path,
                        default=REPO.parent / "rendered-parallel836-confirmed-inset-main-v24/actual")
    args = parser.parse_args()
    causes_path = REPO.parent / "review-confirmed-inset-main836-v24/all-actual-log-causes.json"
    causes = json.loads(causes_path.read_bytes())
    assert causes["manifestDenominator"] == causes["actualReportsRead"] == len(causes["rows"]) == 836
    palette_pages = {row["id"] for row in causes["rows"]
                     if row["actualGrouping"].get("rejected", {}).get("sourcePaletteConflictOrUnknown", 0)}
    assert palette_pages == {"0248", "0265", "0359", "0455"}, "new actual palette veto needs its own diagnosis"
    confirmed_rows = [row for row in causes["rows"] if row["priorConfirmedCase"]]
    assert len(confirmed_rows) == causes["previouslyConfirmedCaseCount"] == 47
    current_cases = []
    for row in confirmed_rows:
        path = Path(row["report"])
        data = path.read_bytes()
        assert hashlib.sha256(data).hexdigest() == row["reportSHA256"], "actual log changed since cause audit"
        record = json.loads(data)
        grouping = next(c for c in record["report"]["candidates"] if c["candidate"] == "02")["evidence"]["fusion"]["sourceTextBlockGrouping"]
        assert grouping == row["actualGrouping"], "actual grouping differs from full836 cause audit"
        if row["id"] in palette_pages - {"0455"}:
            ids = ["2", "1"] if row["id"] == "0265" else ["3", "2"]
            items = {i["id"]: i for i in record["report"]["renderItems"]}
            current_cases.append({"name": "actual-" + row["id"],
                                  "audits": [items[i]["ensemblePaletteAudit"] for i in ids],
                                  "expectedAccepted": row["id"] != "0265"})
    print("COVERAGE denominator=836 aggregateRows=836 confirmedActualLogsRead=47 paletteVetoPages=4", flush=True)
    review_path = REPO.parent / "review-current836-label-groups-v1/agent-upper-visual.json"
    review = json.loads(review_path.read_bytes())
    reviewed = {p["id"] for p in review["pages"]
                if p["id"] in review["directVisualReviewPages"] and p["status"] == "full_original_and_final_viewed"}
    assert set(UPPER) <= reviewed, "upper fixtures must have actual direct visual records"
    cases = current_cases
    for name in ["0248", "0265", "0359", *UPPER]:
        path = (args.logs if name in {"0248", "0265", "0359"} else args.upper_logs) / name / "main-ensemble-evaluation.json"
        data = path.read_bytes()
        record = json.loads(data)  # Parse the entire actual log; missing logs fail, never skip.
        grouping = next(c for c in record["report"]["candidates"] if c["candidate"] == "02")["evidence"]["fusion"]["sourceTextBlockGrouping"]
        print("LOG", name, "bytes", len(data), "sha256", hashlib.sha256(data).hexdigest(),
              "paletteRejects", grouping.get("rejected", {}).get("sourcePaletteConflictOrUnknown", 0),
              "memberAuditAvailable", "paletteAdmissionDecisions" in grouping, flush=True)
        # Upper actual logs lack pair auditing. The recorded 0455 visual group
        # identifies 3/2; replay its measured owner observations without claiming
        # to reconstruct missing admission records for the other upper pages.
        ids = {"0248": ["3", "2"], "0265": ["2", "1"], "0359": ["3", "2"], "0455": ["3", "2"]}.get(name)
        if ids:
            items = {i["id"]: i for i in record["report"]["renderItems"]}
            audits = [items[i]["ensemblePaletteAudit"] for i in ids]
            if "paletteAdmissionDecisions" in grouping:
                rejected = [d for d in grouping["paletteAdmissionDecisions"] if d["members"] == ids]
                assert len(rejected) == 1 and rejected[0]["accepted"] is False
                assert any(d["members"] == ids and d["stage"] == "palette" for d in grouping["groupDecisions"])
                for member, audit in zip(rejected[0]["consensus"]["members"], audits):
                    assert member["selected"] == audit["selectedOriginalInk"]
                    assert member["role"] == audit["selectedRole"]
            else:
                assert grouping["rejected"]["sourcePaletteConflictOrUnknown"] == 1
            cases.append({"name": name, "audits": audits, "expectedAccepted": name != "0265"})
    source = (ENSEMBLE / "NativeOriginalSourcePalette.swift").read_text()
    # Execute exact current production declarations. Only the carrier's image /
    # display/cache adapters are omitted; no replacement palette implementation.
    carrier = "import Foundation\nenum PaletteCarrier {\n"
    observation = source[source.index("    struct Observation {"):source.index("        func display(")]
    carrier += observation + "    }\n"
    for name in ["memoDependencies", "corroboratedStackedMembers", "corroboratedGroupCores",
                 "corroboratedNativePeerMembers", "recoveredMeasuredOriginal", "combineMembers"]:
        carrier += declaration(source, "    static func " + name + "(") + "\n"
    carrier += "}\n"
    # Preserve the complete prior stacked/column/native-peer regression matrix
    # without editing its separately owned extraction runner. Include today's
    # production dependency declarations in both executables.
    legacy_tree = ast.parse((REPO / "Scripts/tests/run-stacked-palette-smoke.py").read_text())
    legacy = next(node.value.value for node in ast.walk(legacy_tree)
                  if isinstance(node, ast.AugAssign) and isinstance(node.target, ast.Name)
                  and node.target.id == "carrier" and isinstance(node.value, ast.Constant)
                  and isinstance(node.value.value, str) and "func observation(" in node.value.value)
    legacy = legacy.split("}", 1)[1]
    # Adapt only the prior harness's descriptor-version expectation. Its
    # original file stays untouched and every behavior assertion is retained.
    prior_assertion = 'descriptor["version"] as? Int==6 && descriptor["nativePeerRecovery"]'
    assert legacy.count(prior_assertion) == 1, "prior memo assertion changed; inspect before adapting"
    legacy = legacy.replace(prior_assertion, 'descriptor["version"] as? Int==7 && descriptor["nativePeerRecovery"]')
    legacy = legacy.replace("memo v6", "memo v7")
    print("SOURCE sha256", hashlib.sha256(source.encode()).hexdigest(), flush=True)
    with tempfile.TemporaryDirectory(prefix="aidoku-confirmed-palette-") as directory:
        temp = Path(directory)
        (temp / "evidence.json").write_text(json.dumps({"cases": cases}))
        for label, harness in [("confirmed", HARNESS), ("prior-regressions", legacy)]:
            (temp / "main.swift").write_text(carrier + harness)
            started = time.monotonic()
            subprocess.run(["xcrun", "swiftc", "-module-cache-path", str(temp / "module-cache"),
                            str(ENSEMBLE / "NativeSourceInkSelection.swift"), str(temp / "main.swift"),
                            "-o", str(temp / "check")], check=True)
            print(f"{label} focused Swift compile seconds: {time.monotonic() - started:.3f}", flush=True)
            started = time.monotonic()
            subprocess.run(["/usr/bin/time", "-l", str(temp / "check"), str(temp / "evidence.json")], check=True)
            print(f"{label} fixture process wall seconds: {time.monotonic() - started:.3f}", flush=True)
    print("Read 47 current confirmed logs plus 3 detailed logs; all836 denominator; no new visual reviews/build/inference.")


if __name__ == "__main__":
    main()
