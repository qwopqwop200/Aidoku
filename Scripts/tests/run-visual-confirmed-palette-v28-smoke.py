#!/usr/bin/env python3
"""Bounded original-pixel palette probe; no renderer, model, or network calls.

Extract exact production declarations and compile only the palette carrier and
source ink selector. Fixture page/owner IDs locate evidence, never enter a
production predicate. This probe does not itself certify actual composites.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import time

REPO = Path(__file__).resolve().parents[2]
BASE = REPO.parent
ENSEMBLE = REPO / "Aidoku/Core/Translation/NativeEngine/Ensemble"


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
func check(_ condition:Bool,_ message:String) {precondition(condition,message);checks+=1}
func consensus(_ value:P.Observation)->[String:Any] {value.rawPrediction!["memberPaletteConsensus"] as! [String:Any]}
func observation(_ audit:[String:Any])->P.Observation {
    let raw=audit["previousOriginalEvidence"] as? [String:Any]
    let t=raw?["sourceInkDominance"] as? [String:Any]
    let n=["fillPixels","strokePixels","fillShapePixels","strokeShapePixels","fillRepeatedTiles",
        "strokeRepeatedTiles","fillEnclosedPixels","strokeEnclosedPixels"].compactMap{(t?[$0] as? NSNumber)?.doubleValue}
    let e:NativeSourceInkSelection.Evidence? = n.count==8 ? .init(fillPixels:n[0],strokePixels:n[1],
        fillShapePixels:n[2],strokeShapePixels:n[3],fillRepeatedTiles:n[4],strokeRepeatedTiles:n[5],
        fillEnclosedPixels:n[6],strokeEnclosedPixels:n[7]):nil
    return .init(originalFill:audit["sourceFill"] as? [Double],originalStroke:audit["sourceStroke"] as? [Double],
        evidence:e,selected:.init(color:audit["selectedOriginalInk"] as? [Double],
        role:audit["selectedRole"] as? String ?? "unknown",neutralExteriorSuppressed:false),
        rawPrediction:raw,unknownReason:audit["uncertainty"] as? String)
}
func combined(_ owners:[P.Observation],_ members:[[String:Any]])->P.Observation {
    P.combineMembers(owners,members:members,inkOnly:true,recoverColumnShell:true,recoverNativePeers:true,recoverMeasuredEvidence:true)
}
let fixture=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [String:Any]
var output=[[String:Any]]()
for record in fixture["cases"] as! [[String:Any]] {
    let url=URL(fileURLWithPath:record["original"] as! String)
    let source=CGImageSourceCreateWithURL(url as CFURL,nil)!
    let image=CGImageSourceCreateImageAtIndex(source,0,nil)!
    let observer=P(original:image)
    let members=record["members"] as! [[String:Any]]
    let old=members.map{observation($0["audit"] as! [String:Any])}
    var fresh=[P.Observation](),details=[[String:Any]]()
    for (i,m) in members.enumerated() {
        let closed=observer.ownedGlyphObservation(sourceBounds:m["sourceBounds"] as! [Double],originalGeometry:m)
        var candidate=m
        candidate["sourceOpenRimGlyphPaletteRecovery"]=true
        let measured=observer.ownedGlyphObservation(sourceBounds:m["sourceBounds"] as! [Double],originalGeometry:candidate)
        fresh.append(measured ?? old[i])
        details.append(["id":m["id"]!,"baselineSelected":old[i].selected.color as Any? ?? NSNull(),
            "baselineRole":old[i].selected.role,"recovered":measured != nil,
            "closedRecovery":closed?.rawPrediction as Any? ?? NSNull(),
            "measurement":measured?.rawPrediction as Any? ?? NSNull(),
            "diagnostics":observer.ownedGlyphDiagnostics(sourceBounds:m["sourceBounds"] as! [Double],originalGeometry:m) as Any? ?? NSNull()])
    }
    let baseline=combined(old,members)
    let before=consensus(baseline)
    // Match the production rejected-consensus-only safeguard: accepted
    // observations are retained, not recoloured by candidate measurements.
    let after=consensus(before["accepted"] as? Bool == true ? baseline:combined(fresh,members))
    output.append(["fixture":record["name"]!,"members":details,"before":before,"after":after])
    // Preserve the full group's original 24-channel spread gate.
    check(after["maximumChannelSpread"] as? Int==24,"palette tolerance changed")
    if (record["name"] as! String).hasPrefix("0064/") || (record["name"] as! String).hasPrefix("0265/") {
        check(before["accepted"] as? Bool==false && after["accepted"] as? Bool==true,"actual residual did not change acceptance")
    }
}
// Pixel-only controls: repeated white-rimmed cores, absent ownership, alpha,
// an exterior-connected flat surface, and two competing repeated colours.
let w=96,h=96,n=w*h
var rgba=[UInt8](repeating:255,count:n*4),owned=[UInt8](repeating:1,count:n)
for yy in [12,42,72] {for xx in [12,42,72] {
    for y in yy..<(yy+8) {for x in xx..<(xx+8) {
        let p=(y*w+x)*4;rgba[p]=48;rgba[p+1]=65;rgba[p+2]=102
    }}
}}
let valid=P.enclosedGlyphMeasurement(rgba:rgba,width:w,height:h,ownership:owned)
check(valid?["foreground"] as? [Double]==[48,65,102],"own measured core not recovered")
check(valid?["components"] as? Int==9,"component quorum drift")
check(P.enclosedGlyphMeasurement(rgba:rgba,width:w,height:h,ownership:[UInt8](repeating:0,count:n))==nil,"unowned pixels voted")
var transparent=rgba
for p in 0..<n {transparent[p*4+3]=120}
check(P.enclosedGlyphMeasurement(rgba:transparent,width:w,height:h,ownership:owned)==nil,"transparent pixels voted")
var surface=[UInt8](repeating:255,count:n*4)
for p in 0..<n {surface[p*4]=48;surface[p*4+1]=65;surface[p*4+2]=102}
check(P.enclosedGlyphMeasurement(rgba:surface,width:w,height:h,ownership:owned)==nil,"bbox background mode voted")
var conflict=rgba
for yy in [12,42,72] {for xx in [56,86] {
    for y in yy..<(yy+8) {for x in xx..<min(w-1,xx+8) {
        let p=(y*w+x)*4;conflict[p]=185;conflict[p+1]=26;conflict[p+2]=138
    }}
}}
check(P.enclosedGlyphMeasurement(rgba:conflict,width:w,height:h,ownership:owned)==nil,"competing emphasis erased")
check(P.enclosedGlyphMeasurement(rgba:[],width:w,height:h,ownership:owned)==nil,"invalid buffer accepted")
// Open C-shaped strokes have opposing local boundaries but need no closed
// white ring. Different orientations and repeated owned spatial cells vote.
func glyphs(_ mixed:Bool=false)->[UInt8] {
    var pixels=[UInt8](repeating:255,count:n*4)
    for (row,yy) in [8,36,64].enumerated() {for (col,xx) in [4,26,48,70].enumerated() {
        let rgb:[UInt8]=mixed && (row+col)%2==0 ? [185,26,138]:[48,65,102]
        for y in yy..<(yy+14) {for x in xx..<(xx+14) {
            if x<xx+2 || y<yy+2 || y>=yy+12 {
                for c in 0..<3 {pixels[(y*w+x)*4+c]=rgb[c]}
            }
        }}
    }}
    return pixels
}
let openGlyphs=glyphs()
let open=P.openRimGlyphMeasurement(rgba:openGlyphs,width:w,height:h,ownership:owned)
check(open?["foreground"] as? [Double]==[48,65,102],"open local profiles missing own colour")
check(P.openRimGlyphMeasurement(rgba:glyphs(true),width:w,height:h,ownership:owned)==nil,"competing repeated ink erased")
check(P.openRimGlyphMeasurement(rgba:openGlyphs,width:w,height:h,ownership:[UInt8](repeating:0,count:n))==nil,"unowned profiles voted")
var ownCore=owned,openAlpha=openGlyphs
for p in 0..<n {
    if openGlyphs[p*4]>=225 {ownCore[p]=0}
    openAlpha[p*4+3]=120
}
check(P.openRimGlyphMeasurement(rgba:openGlyphs,width:w,height:h,ownership:ownCore)==nil,"unowned rims voted")
check(P.openRimGlyphMeasurement(rgba:openAlpha,width:w,height:h,ownership:owned)==nil,"alpha profiles voted")
check(P.openRimGlyphMeasurement(rgba:surface,width:w,height:h,ownership:owned)==nil,"flat chromatic surface voted")
check(P.openRimGlyphMeasurement(rgba:[],width:w,height:h,ownership:owned)==nil,"invalid profile buffer accepted")
var stripes=[UInt8](repeating:255,count:n*4)
for y in 0..<h {for x in 0..<w where x%30<3 {
    for c in 0..<3 {stripes[(y*w+x)*4+c]=[UInt8(48),65,102][c]}
}}
check(P.openRimGlyphMeasurement(rgba:stripes,width:w,height:h,ownership:owned)==nil,"one-orientation surface accepted")
let m:[[String:Any]]=[["id":"a","sourceBounds":[0.1,0.1,0.1,0.1]],["id":"b","sourceBounds":[0.3,0.1,0.1,0.1]]]
var g:[String:Any]=["sourceTextBlockMemberPalette":true,"agent02MemberItems":m]
let off=try P.memoDependencies(g)!
g["sourceOwnedGlyphPaletteRecovery"]=true
let on=try P.memoDependencies(g)!
check(off != on,"runtime policy missing from cache dependency")
let descriptor=try JSONSerialization.jsonObject(with:on) as! [String:Any]
check(descriptor["version"] as? Int==10 && descriptor["ownedGlyphVersion"] as? Int==3,"recovery version missing")
let nested=try P.memoDependencies(["sourceTextBlockMemberPalette":true,"agent02MemberItems":[g,["id":"c"]]])!
g["sourceOwnedGlyphPaletteRecovery"]=false
let nestedOff=try P.memoDependencies(["sourceTextBlockMemberPalette":true,"agent02MemberItems":[g,["id":"c"]]])!
check(nested != nestedOff,"nested recovery dependency missing")
g["sourceOpenRimGlyphPaletteRecovery"]=true
let openMemo=try P.memoDependencies(g)!
let openDescriptor=try JSONSerialization.jsonObject(with:openMemo) as! [String:Any]
check(openDescriptor["openRimGlyphVersion"] as? Int==1,"open policy version missing")
check(openMemo != off && openMemo != on,"open policy cache aliases existing policy")
check(!P.ownedGlyphRecoveryEnabled([:]) && !P.openRimGlyphRecoveryEnabled([:]),"default changed")
check(!P.openRimGlyphRecoveryEnabled(["sourceOpenRimGlyphPaletteRecovery":true,
    "sourceOwnedGlyphPaletteRecoverySuppressed":true]),"baseline suppression bypassed")
let report:[String:Any]=["cases":output,"checks":checks,"manifestDenominator":836,
    "activation":"sourceOpenRimGlyphPaletteRecovery=true (joined original geometry only)","defaultMainAcceptanceMeasuredHere":false,
    "limits":"Actual owned original pixel observations only; no final candidate images or grouping acceptance claim."]
let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
if CommandLine.arguments.count>2 {try data.write(to:URL(fileURLWithPath:CommandLine.arguments[2]))}
for row in output {
    let before=row["before"] as! [String:Any],after=row["after"] as! [String:Any]
    print(row["fixture"]!,"before",before["accepted"]!,"after",after["accepted"]!)
    for member in row["members"] as! [[String:Any]] {
        print("owner",member["id"]!,"recovered",member["recovered"]!,"measurement",member["measurement"]!)
    }
}
print("PASS",checks,"focused checks; default-main visual acceptance is tracked separately")
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    expected = {"0063": ["8", "6", "7"], "0064": ["5", "6", "7", "8", "9"],
                "0148": ["13", "12"], "0265": ["1", "2"]}
    cases = []
    for page, ids in expected.items():
        root = "rendered-parallel836-split-visual-integrated-main-v38" if page in ["0064", "0265"] else "rendered-parallel836-all-confirmed-causes-candidate-v26"
        path = BASE / f"{root}/actual/{page}/main-ensemble-evaluation.json"
        data = path.read_bytes()
        log = json.loads(data)
        items = {i["id"]: i for i in log["report"]["renderItems"]}
        sets = [["5", "6"], ["7", "8", "9"]] if page == "0064" else [ids]
        for group in sets:
            cases.append({"name": page + "/" + "+".join(group),
                          "original": str(BASE / f"render-inputs/current836/pages/{page}/input.png"),
                          "members": [{"id": item_id, "sourceBounds": items[item_id]["sourceBounds"],
                                       "sourcePolygon": items[item_id].get("sourcePolygon"),
                                       "audit": items[item_id]["ensemblePaletteAudit"]} for item_id in group]})
        print("Full actual log", page, len(data), hashlib.sha256(data).hexdigest(), flush=True)
    for page in ["0602", "0708"]:
        path = BASE / f"rendered-split-bounded-causes-v31/{page}/main-ensemble-evaluation.json"
        data = path.read_bytes()
        log = json.loads(data)
        items = {i["id"]: i for i in log["report"]["renderItems"]}
        cases.append({"name": page + "/9+12", "original": str(BASE / f"render-inputs/current836/pages/{page}/input.png"),
                      "members": [{"id": item_id, "sourceBounds": items[item_id]["sourceBounds"],
                                   "sourcePolygon": items[item_id].get("sourcePolygon"),
                                   "audit": items[item_id]["ensemblePaletteAudit"]} for item_id in ["9", "12"]]})
        print("Full actual v31 log", page, len(data), hashlib.sha256(data).hexdigest(), flush=True)
    source = (ENSEMBLE / "NativeOriginalSourcePalette.swift").read_text()
    carrier = "import CoreGraphics\nimport Foundation\nimport ImageIO\nfinal class PaletteCarrier {\n"
    carrier += "let original:CGImage\ninit(original:CGImage) {self.original=original}\n"
    carrier += source[source.index("    struct Observation {"):source.index("        func display(")] + "    }\n"
    for name in ["ownedGlyphRecoveryEnabled", "openRimGlyphRecoveryEnabled", "openRimGlyphMeasurement", "enclosedGlyphMeasurement", "memoDependencies",
                 "corroboratedStackedMembers", "corroboratedGroupCores", "corroboratedNativePeerMembers",
                 "recoveredMeasuredOriginal", "combineMembers"]:
        carrier += declaration(source, "    static func " + name + "(") + "\n"
    carrier += declaration(source, "    func ownedGlyphObservation(") + "\n}\n"
    # Instrument an exact copy of the production traversal. Diagnostic data
    # never participates in the production measurement or consensus decision.
    diagnostic = declaration(source, "    static func enclosedGlyphMeasurement(")
    diagnostic = diagnostic.replace("func enclosedGlyphMeasurement(", "func enclosedGlyphDiagnostics(")
    diagnostic = diagnostic.replace("let limit=max(32,min(4096,n/20))", "var rejected=[String:Int]();var cores=[[String:Any]]()\nlet limit=max(32,min(4096,n/20))")
    old_gate = '''            guard !external,(6...limit).contains(queue.count),edges.count>=8,
                  queue.allSatisfy({ownership[$0] != 0}) else{continue}'''
    new_gate = '''            let reason=external ? "connectedToExteriorOrAlpha" : queue.count<6 ? "smallComponent" : queue.count>limit ? "largeComponent" : edges.count<8 ? "fewWhiteRimEdges" : !queue.allSatisfy({ownership[$0] != 0}) ? "crossesOwnership" : "eligibleComponent"
            rejected[reason,default:0]+=1
            guard reason=="eligibleComponent" else{continue}'''
    assert old_gate in diagnostic
    diagnostic = diagnostic.replace(old_gate, new_gate)
    bin_gate = "            guard let key=bins.keys.sorted"
    assert bin_gate in diagnostic
    diagnostic = diagnostic.replace(bin_gate, '''            if let best=bins.keys.sorted(by:{bins[$0]!.count>bins[$1]!.count}).first {
                let ps=bins[best]!
                cores.append(["componentPixels":queue.count,"stableCorePixels":ps.count,
                    "stableCoreFraction":Double(ps.count)/Double(queue.count),
                    "rgb":(0..<3).map{c in (ps.reduce(0.0){$0+Double(rgba[$1*4+c])}/Double(ps.count)).rounded()}])
            } else {rejected["noStableChromaticCore",default:0]+=1}
''' + bin_gate)
    end = diagnostic.index("        let ranked=")
    diagnostic = diagnostic[:end] + '''        return ["componentRejections":rejected,"eligibleCores":cores,"witnessCount":witnesses.count,
            "witnessRGB":witnesses.map{$0.rgb},"witnessTiles":witnesses.map{$0.tile},"width":width,"height":height]
    }'''
    capture = declaration(source, "    func ownedGlyphObservation(")
    capture = capture.replace("func ownedGlyphObservation(", "func ownedGlyphDiagnostics(").replace("-> Observation?", "-> [String:Any]?")
    end = capture.index("        let open=Self.openRimGlyphRecoveryEnabled")
    capture = capture[:end] + "        return Self.enclosedGlyphDiagnostics(rgba:rgba,width:w,height:h,ownership:owned)\n    }"
    carrier = carrier[:-2] + diagnostic + "\n" + capture + "\n}\n"
    with tempfile.TemporaryDirectory(prefix="aidoku-v28-owned-palette-") as folder:
        temp = Path(folder)
        (temp / "main.swift").write_text(carrier + HARNESS)
        (temp / "fixtures.json").write_text(json.dumps({"cases": cases}))
        started = time.monotonic()
        subprocess.run(["xcrun", "swiftc", "-module-cache-path", str(temp / "module-cache"),
                        str(ENSEMBLE / "NativeSourceInkSelection.swift"), str(temp / "main.swift"),
                        "-o", str(temp / "check")], check=True)
        print("Focused carrier compile seconds", round(time.monotonic() - started, 3), flush=True)
        started = time.monotonic()
        command = [str(temp / "check"), str(temp / "fixtures.json")]
        if args.report:
            command.append(str(args.report.resolve()))
        subprocess.run(command, check=True, env={"PATH": "/usr/bin:/bin"})
        print("Bounded original observation seconds", round(time.monotonic() - started, 3), flush=True)


if __name__ == "__main__":
    main()
