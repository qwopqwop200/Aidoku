#!/usr/bin/env python3
"""Exercise shared final admission; optionally survey saved final-effect owners.

No shaping, corpus renderer build, source RGB, or production cache is used.
The harness extracts the production fill carrier from the shared composer.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import runpy
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
ENGINE = ROOT / "Aidoku/Core/Translation/NativeEngine/Ensemble"
admission_source_closure = runpy.run_path(
    str(Path(__file__).with_name("native_admission_sources.py"))
)["admission_source_closure"]
SOURCES = admission_source_closure([
    "NativeTextExpansionPolicy", "NativeTextPlacementGuide", "NativeBalloonPlacement",
    "NativeSourceClusterAlignment", "NativeSourceCohortPacking", "NativeInkContourClearance",
    "NativeContourTextClearance", "NativeAdaptiveTextGutter", "NativeReadablePeerGutter", "NativeExplicitDisplayStrokePolicy", "NativeMandatoryDisplayStroke",
    "NativeRenderedStrokeSelection", "NativeSourceStylePaint", "NativeFinalTextPaintAdmission",
])

HARNESS = r'''
import CoreGraphics
import Foundation
import ImageIO

enum NativeAOTTranslationPageComposer {}
typealias Fill = NativeAOTTranslationPageComposer.TranslatedFillPrimitive
typealias Admission = (fills:[Fill], audit:[[String:Any]])
let page = CGRect(x:0,y:0,width:256,height:256)

func require(_ value:Bool,_ message:String) {
    if !value { fputs("FAIL: \(message)\n",stderr); exit(1) }
}
func rect(_ v:Any?) -> CGRect {
    let a=v as! [NSNumber]
    return CGRect(x:a[0].doubleValue,y:a[1].doubleValue,width:a[2].doubleValue,height:a[3].doubleValue)
}
func normalized(_ r:CGRect) -> [Double] {
    [Double(r.minX/256),Double(r.minY/256),Double(r.width/256),Double(r.height/256)]
}
func bounds(_ a:Admission,_ i:Int) -> CGRect {rect(a.audit[i]["finalFootprintOutputPixels"])}
func number(_ row:[String:Any],_ key:String) -> Double {(row[key] as! NSNumber).doubleValue}
func raster() -> CGImage {
    let c=CGContext(data:nil,width:12,height:12,bitsPerComponent:8,bytesPerRow:48,
        space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.setFillColor(CGColor(gray:1,alpha:1)); c.fill(CGRect(x:0,y:0,width:12,height:12))
    c.setFillColor(CGColor(gray:0,alpha:1)); c.fill(CGRect(x:1,y:1,width:10,height:10))
    return c.makeImage()!
}
func fixture(row:Bool,relaxed:Bool,cohort:Bool=true) throws -> Admission {
    let mask=row ? CGRect(x:50,y:30,width:150,height:100):CGRect(x:30,y:50,width:100,height:150)
    let raw=normalized(mask)
    let policy=NativeTextExpansionPolicy(allowedRectNormalized:raw,candidates:[raw],maskCoverage:[1],
        backgroundRisk:[0],sourceFontPixels:40,kind:"inside-balloon-mask",maskRectNormalized:raw,
        maskSpansNormalized:Array(repeating:[Double(mask.minX/256),Double(mask.maxX/256)],count:128).flatMap{$0})
    require(policy.valid,"synthetic policy")
    var fills:[Fill]=[]
    for i in 0..<3 {
        let origin=i==2 ? CGPoint(x:210,y:210):(row ? CGPoint(x:50+i*70,y:50):CGPoint(x:50,y:50+i*70))
        let frame=CGRect(origin:origin,size:CGSize(width:12,height:12))
        var f=Fill(image:raster(),frame:frame,fontOutputPixels:i==2 ? 32:40)
        f.ownerID="owner-\(i)";f.hasFinalEffects=true
        if i<2 {
            f.textExpansionPolicy=policy
            f.textPlacementGuide = .init(rectNormalized:normalized(frame),horizontal:.center,vertical:.center)
            f.balloonPlacement = .init(crossAlignment:.start,bodyID:"synthetic-body",rectNormalized:raw,
                preserveSourceOffsets:true,biasNormalized:[0,0],flow:row ? .row:.column,paddingEm:0,
                gapEm:0,maskSHA256:String(repeating:"0",count:64),order:i)
            f.balloonTargetRelaxed=relaxed
            if cohort {
                f.sourceClusterAlignment = .init(groupID:"synthetic-cohort",axis:row ? .top:.left,
                    anchorNormalized:50.0/256)
            }
            f.placementDomain={policy.allows($0,page:page)}
        }
        fills.append(f)
    }
    let initial=try NativeFinalTextPaintAdmission.place(fills,page:page,
        fixedOrigins:Dictionary(uniqueKeysWithValues:fills.map{($0.ownerID!,$0.frame.origin)}))
    require(initial.fills.count==3,"all synthetic owners admitted")
    for i in 0..<3 { require(bounds(initial,i)==fills[i].frame,"fixture retained origin") }
    for i in 0..<2 {
        require(initial.fills[i].balloonTargetRelaxed==relaxed,"real relaxed state")
        require((initial.audit[i]["balloonBodyPlaced"] as! Bool) == !relaxed,"real body target state")
    }
    return initial
}
func stablePaint(_ before:Admission,_ after:Admission) throws {
    require(before.fills.count==after.fills.count,"owner count")
    for i in before.fills.indices {
        let a=before.fills[i],b=after.fills[i]
        require(a.ownerID==b.ownerID && a.fontOutputPixels==b.fontOutputPixels,"owner/font retained")
        require(a.hasFinalEffects && b.hasFinalEffects,"baked final effects retained")
        require(a.image.width==b.image.width && a.image.height==b.image.height,"raster dimensions")
        require(try NativeMandatoryDisplayStroke.rgba(a.image)==NativeMandatoryDisplayStroke.rgba(b.image),"exact RGBA retained")
        require(bounds(before,i).size==bounds(after,i).size,"footprint size")
        require(number(before.audit[i],"paintedPixels")==number(after.audit[i],"paintedPixels"),"alpha count")
        require(a.balloonTargetRelaxed==b.balloonTargetRelaxed,"body relaxation retained")
        require(a.sourceClusterAlignment==b.sourceClusterAlignment,"cohort packet retained")
        require(a.textExpansionPolicy==b.textExpansionPolicy && a.textPlacementGuide==b.textPlacementGuide,"source packets retained")
        require((before.audit[i]["balloonBodyPlaced"] as? Bool)==(after.audit[i]["balloonBodyPlaced"] as? Bool),"body target retained")
    }
}
func smoke() throws {
    var controls=0
    for row in [true,false] {
        for cohort in [true,false] {
            let before=try fixture(row:row,relaxed:true,cohort:cohort)
            let after=NativeFinalTextPaintAdmission.refineContourClearance(before,page:page,inkAware:true)
            try stablePaint(before,after)
            let a=bounds(before,0),b=bounds(after,0),audit=after.audit[0]
            require(a != b,"relaxed multiowner improves along free axis")
            require(row ? a.minY==b.minY:a.minX==b.minX,"shared top/left unchanged")
            require(row ? b.minX>a.minX:b.minY>a.minY,"moves inward on free axis")
            require(hypot(b.minX-a.minX,b.minY-a.minY)<=10,"movement <= .25em")
            require(number(audit,"inkContourClearanceAfterPixels")>number(audit,"inkContourClearanceBeforePixels"),"strict margin gain")
            let policy=before.fills[0].textExpansionPolicy!
            let oldMargin=NativeInkContourClearance.margin(rows:try envelope(before.fills[0]),bounds:a,policy:policy,page:page,limit:8)
            let newMargin=NativeInkContourClearance.margin(rows:try envelope(after.fills[0]),bounds:b,policy:policy,page:page,limit:8)
            require(newMargin>oldMargin,"margin gain measured from retained RGBA")
            require(sqrt(number(audit,"inkContourSourceCostAfter"))<=sqrt(number(audit,"inkContourSourceCostBefore"))+4+1e-7,"source drift <= .1em")
            require(audit["inkContourCoupledFreeAxisRefined"] as? Bool == true,"coupled branch reached")
            require(audit[row ? "inkContourSharedYPreserved":"inkContourSharedXPreserved"] as? Bool == true,"locked axis audited")
            for j in 1..<3 {require(bounds(before,j)==bounds(after,j),"body peer and unrelated peer stationary")}
            require(row ? b.midX<bounds(after,1).midX:b.midY<bounds(after,1).midY,"body order")
            if cohort {
                for j in 0..<2 {
                    require(number(before.audit[j],"sourceClusterAnchorOutputPixels")==number(after.audit[j],"sourceClusterAnchorOutputPixels"),"shared cohort anchor unchanged")
                }
            }
            // The actual retained image still has an opaque white border and black core.
            let pixels=try NativeMandatoryDisplayStroke.rgba(after.fills[0].image)
            for y in 0..<12 {for x in 0..<12 {
                let k=(y*12+x)*4,white=x==0 || x==11 || y==0 || y==11
                require(Array(pixels[k..<k+4])==(white ? [255,255,255,255]:[0,0,0,255]),"visible BW outline retained")
            }}
            let rectangleOnly=NativeFinalTextPaintAdmission.refineContourClearance(before,page:page)
            for j in 0..<3 {require(bounds(before,j)==bounds(rectangleOnly,j),"rectangle stage leaves coupled owners unchanged")}
            controls+=1
            print("PASS relaxed",row ? "row/top":"column/left",cohort ? "cohort":"body-axis",a.origin,"->",b.origin)
        }
        let active=try fixture(row:row,relaxed:false)
        let unchanged=NativeFinalTextPaintAdmission.refineContourClearance(active,page:page,inkAware:true)
        try stablePaint(active,unchanged)
        for j in 0..<3 {
            require(bounds(active,j)==bounds(unchanged,j),"active body never independently moved")
            require(unchanged.audit[j]["inkContourCoupledFreeAxisRefined"]==nil,"active body gate")
        }
        controls+=1
    }
    print("COUPLED_CONTOUR_CLEARANCE \(controls) synthetic controls passed")
}

func decode<T:Decodable>(_ value:Any?,as type:T.Type) throws -> T? {
    guard let value,!(value is NSNull) else{return nil}
    return try JSONDecoder().decode(type,from:JSONSerialization.data(withJSONObject:value))
}
func object(_ path:String) throws -> [String:Any] {
    try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:path))) as! [String:Any]
}
func envelope(_ f:Fill) throws -> [NativeInkContourClearance.Row] {
    let pixels=try NativeMandatoryDisplayStroke.rgba(f.image)
    var rows:[NativeInkContourClearance.Row]=[]
    for y in 0..<f.image.height {
        let xs=(0..<f.image.width).filter{pixels[(y*f.image.width+$0)*4+3]>0}
        if let first=xs.first,let last=xs.last {
            rows.append(.init(y:Int(f.frame.minY)+y,left:Int(f.frame.minX)+first,right:Int(f.frame.minX)+last+1))
        }
    }
    return rows
}
func replay(_ manifest:String,_ output:String) throws {
    var report=try object(manifest)
    let pages=report.removeValue(forKey:"pages") as! [[String:Any]]
    var moves:[[String:Any]]=[]
    for p in pages {
        let id=p["page"] as! String
        let size=p["size"] as! [Int]
        let canvas=CGRect(x:0,y:0,width:size[0],height:size[1])
        let items=p["items"] as! [[String:Any]]
        var fills:[Fill]=[],audit:[[String:Any]]=[]
        for item in items {
            let path=item["raster"] as! String
            let src=CGImageSourceCreateWithURL(URL(fileURLWithPath:path) as CFURL,nil)!
            let image=CGImageSourceCreateImageAtIndex(src,0,nil)!
            let frame=rect(item["frame"])
            require(CGFloat(image.width)==frame.width && CGFloat(image.height)==frame.height,"\(id): receipt dimensions")
            var f=Fill(image:image,frame:frame,fontOutputPixels:(item["font"] as! NSNumber).doubleValue)
            f.ownerID=item["id"] as? String;f.hasFinalEffects=true
            f.textPlacementGuide=try decode(item["guide"],as:NativeTextPlacementGuide.self)
            f.textExpansionPolicy=try decode(item["policy"],as:NativeTextExpansionPolicy.self)
            f.balloonPlacement=try decode(item["body"],as:NativeBalloonPlacement.self)
            f.sourceClusterAlignment=try decode(item["cohort"],as:NativeSourceClusterAlignment.self)
            f.balloonTargetRelaxed=item["relaxed"] as! Bool
            if let policy=f.textExpansionPolicy {f.placementDomain={policy.allows($0,page:canvas)}}
            fills.append(f);audit.append(item["audit"] as! [String:Any])
        }
        let before:Admission=(fills,audit)
        // Exactly one native ink stage, using saved final admission as its input.
        let after=NativeFinalTextPaintAdmission.refineContourClearance(before,page:canvas,inkAware:true)
        try stablePaint(before,after)
        let eligible=Set(p["eligibleOwners"] as! [String])
        for i in fills.indices where bounds(before,i) != bounds(after,i) {
            let a=bounds(before,i),b=bounds(after,i),f=fills[i],r=after.audit[i]
            let policy=f.textExpansionPolicy!,limit=Int(ceil(f.fontOutputPixels*0.2))
            let old=NativeInkContourClearance.margin(rows:try envelope(f),bounds:a,policy:policy,page:canvas,limit:limit)
            let new=NativeInkContourClearance.margin(rows:try envelope(after.fills[i]),bounds:b,policy:policy,page:canvas,limit:limit)
            require(new>old,"\(id)/\(f.ownerID!): independently measured contour gain")
            if r["inkContourCoupledFreeAxisRefined"] as? Bool == true {
                require(eligible.contains(f.ownerID!),"moved coupled owner was geometrically eligible")
                require(hypot(b.minX-a.minX,b.minY-a.minY)<=f.fontOutputPixels*0.25+1e-7,"survey move budget")
                let source=f.textPlacementGuide!.rect(in:canvas)
                require(sqrt(NativeContourTextClearance.sourceCost(b,source))<=sqrt(NativeContourTextClearance.sourceCost(a,source))+f.fontOutputPixels*0.1+1e-7,"survey drift budget")
                if r["inkContourSharedXPreserved"] as? Bool == true {require(a.minX==b.minX,"survey shared X")}
                if r["inkContourSharedYPreserved"] as? Bool == true {require(a.minY==b.minY,"survey shared Y")}
            }
            moves.append(["page":id,"owner":f.ownerID!,"before":[a.minX,a.minY,a.width,a.height],
                "after":[b.minX,b.minY,b.width,b.height],"clearanceBefore":old,"clearanceAfter":new,
                "newCoupledBranch":r["inkContourCoupledFreeAxisRefined"] as? Bool ?? false])
        }
        print("SURVEY",id,"owners",fills.count,"moves",moves.filter{$0["page"] as? String==id}.count)
    }
    report["replayedPages"]=pages.count;report["moves"]=moves
    report["movedPageIDs"]=Set(moves.map{$0["page"] as! String}).sorted()
    report["acceptedMoves"]=moves.count
    report["acceptedCoupledMoves"]=moves.filter{$0["newCoupledBranch"] as! Bool}.count
    report["complete"]=true
    let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
    try data.write(to:URL(fileURLWithPath:output),options:.atomic)
    print("SURVEY_COMPLETE pages",pages.count,"accepted moves",moves.count)
}

if CommandLine.arguments.count==4 && CommandLine.arguments[1]=="replay" {
    try replay(CommandLine.arguments[2],CommandLine.arguments[3])
} else {try smoke()}
'''


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def geometric_owners(items, audit, width, height):
    """Mirror the new coupled gate only; native code decides feasibility/admission."""
    bodies, cohorts = {}, {}
    for item in items:
        if item.get("balloonPlacement"):
            bodies.setdefault(item["balloonPlacement"]["bodyID"], []).append(item)
        if item.get("sourceClusterAlignment"):
            cohorts.setdefault(item["sourceClusterAlignment"]["groupID"], []).append(item)
    eligible = []
    for item in items:
        policy, guide = item.get("textExpansionPolicy"), item.get("textPlacementGuide")
        if not policy or policy.get("kind") != "inside-balloon-mask" or not guide:
            continue
        body, cohort = item.get("balloonPlacement"), item.get("sourceClusterAlignment")
        shared_body = body and len(bodies[body["bodyID"]]) > 1
        shared_cohort = cohort and len(cohorts[cohort["groupID"]]) > 1
        if not (shared_body or shared_cohort):
            continue
        lock_x = lock_y = False
        if shared_body:
            members = bodies[body["bodyID"]]
            if not all(audit[m["id"]]["finalPlacement"]["balloonCapacityFallback"] for m in members):
                continue
            row = body["flow"] == "row"
            fraction = {"start": 0, "center": .5, "end": 1}[body.get("crossAlignment") or "start"]
            cross = []
            for m in members:
                if not m.get("textPlacementGuide"):
                    break
                r = m["textPlacementGuide"]["rectNormalized"]
                cross.append((r[1] + r[3] * fraction) * height if row else (r[0] + r[2] * fraction) * width)
            if len(cross) != len(members):
                continue
            if max(cross) - min(cross) <= min(audit[m["id"]]["fontPixels"] for m in members) * .5:
                lock_y, lock_x = row, not row
        if shared_cohort:
            lock_y |= cohort["axis"] == "top"
            lock_x |= cohort["axis"] == "left"
        if not (lock_x and lock_y):
            eligible.append(item["id"])
    return eligible


def survey_manifest(render_root):
    root = render_root.resolve()
    request_path = root / "REQUEST.json"
    request = json.loads(request_path.read_text())
    integrity = json.loads((root / "RENDER-INTEGRITY.json").read_text())
    if not integrity.get("passed") or not integrity.get("complete") or integrity["requestSHA256"] != sha256(request_path):
        raise ValueError("A complete matching render-integrity receipt is required")
    pages, eligible_all, skipped = [], [], []
    owner_count = 0
    for page in request["pages"]:
        page_id = page["page"]
        audit_path = root / "audits" / (page_id + ".json")
        audit = json.loads(audit_path.read_text())
        rows = {r["id"]: r for r in audit["items"]}
        items = page["items"]
        if set(rows) != {i["id"] for i in items}:
            raise ValueError(f"{page_id}: request/audit owner mismatch")
        owner_count += len(items)
        eligible = geometric_owners(items, rows, page["width"], page["height"])
        eligible_all.extend({"page": page_id, "owner": owner} for owner in eligible)
        if not any((i.get("textExpansionPolicy") or {}).get("kind") == "inside-balloon-mask" for i in items):
            skipped.append(page_id)
            continue
        receipt_path = root / "owner-rasters" / page_id.encode().hex() / "RECEIPT.json"
        receipt = json.loads(receipt_path.read_text())
        if receipt["stage"] != "actual-final-primitives-after-refinement" or receipt["auditSHA256"] != sha256(audit_path):
            raise ValueError(f"{page_id}: final raster/audit binding mismatch")
        if (receipt["width"], receipt["height"]) != (page["width"], page["height"]):
            raise ValueError(f"{page_id}: receipt page dimensions mismatch")
        rasters = {r["id"]: r for r in receipt["owners"]}
        if set(rasters) != set(rows):
            raise ValueError(f"{page_id}: raster owner mismatch")
        replay_items = []
        for item in items:
            owner = item["id"]
            raster, row = rasters[owner], rows[owner]
            if sha256(raster["path"]) != raster["sha256"]:
                raise ValueError(f"{page_id}/{owner}: raster digest mismatch")
            final = row["finalPlacement"]
            replay_items.append({
                "id": owner, "raster": raster["path"], "frame": raster["frame"], "font": row["fontPixels"],
                "guide": item.get("textPlacementGuide"), "policy": item.get("textExpansionPolicy"),
                "body": item.get("balloonPlacement"), "cohort": item.get("sourceClusterAlignment"),
                "relaxed": final["balloonCapacityFallback"], "audit": final,
            })
        pages.append({"page": page_id, "size": [page["width"], page["height"]],
                      "eligibleOwners": eligible, "items": replay_items})
    if len(request["pages"]) != integrity["checkedPages"] or owner_count != integrity["checkedOwners"]:
        raise ValueError("Geometric survey does not cover the integrity receipt denominator")
    return {
        "kind": "offline-final-stage-candidate-survey", "renderRoot": str(root),
        "requestSHA256": sha256(request_path), "geometricallyCheckedPages": len(request["pages"]),
        "geometricallyCheckedOwners": owner_count, "eligibleCoupledOwners": eligible_all,
        "eligibleCoupledOwnerCount": len(eligible_all), "candidatePageIDs": [p["page"] for p in pages],
        "skippedNoInsidePolicyPageIDs": skipped,
        "sourceRGBRead": False, "nativeFullRendering": False, "qualityAcceptance": False,
        "preFinalBodyInkSeparationReplayed": False,
        "limitation": "Saved final-raster candidate survey only; does not authenticate skipping actual rerender of changed pre-final BodyInkSeparation.",
        "pages": pages,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--render-root", type=Path, help="Saved final render directory with REQUEST.json and owner-rasters")
    parser.add_argument("--survey-output", type=Path, help="Write candidate/moved owner survey JSON outside the source tree")
    args = parser.parse_args()
    if bool(args.render_root) != bool(args.survey_output):
        parser.error("--render-root and --survey-output must be supplied together")
    with tempfile.TemporaryDirectory(prefix="aidoku-coupled-contour-") as directory:
        cache = Path(directory)
        carrier = (ENGINE / "NativeMandatoryDisplayStroke+Composer.swift").read_text()
        carrier = carrier.split("    /// Concrete minimal adapter")[0] + "}\n"
        (cache / "Primitive.swift").write_text(carrier)
        (cache / "main.swift").write_text(HARNESS)
        # Freeze actual shared source bytes while the parent may continue editing.
        source_bytes = [(ENGINE / (name + ".swift")).read_bytes() for name in SOURCES]
        for name, data in zip(SOURCES, source_bytes):
            (cache / (name + ".swift")).write_bytes(data)
        source_digest = hashlib.sha256(b"".join(source_bytes) + carrier.encode()).hexdigest()
        binary = cache / "check"
        env = os.environ.copy()
        for key in list(env):
            if key.startswith("AIDOKU_"):
                del env[key]
        env["AIDOKU_INK_CONTOUR_SOURCE_DRIFT_EM"] = "0.1"
        env["CLANG_MODULE_CACHE_PATH"] = str(cache / "clang-modules")
        start = time.monotonic()
        subprocess.run([
            "xcrun", "swiftc", "-O", "-module-cache-path", str(cache / "swift-modules"),
            *[str(cache / (name + ".swift")) for name in SOURCES],
            str(cache / "Primitive.swift"), str(cache / "main.swift"), "-o", str(binary),
        ], check=True, env=env)
        print(f"Isolated helper build: {time.monotonic() - start:.2f}s", flush=True)
        start = time.monotonic()
        subprocess.run([str(binary)], check=True, env=env)
        print(f"Synthetic execution: {time.monotonic() - start:.2f}s", flush=True)
        if args.render_root:
            start = time.monotonic()
            manifest = survey_manifest(args.render_root)
            manifest["nativeSourceSHA256"] = source_digest
            manifest_path = cache / "survey-input.json"
            manifest_path.write_text(json.dumps(manifest))
            args.survey_output.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run([str(binary), "replay", str(manifest_path), str(args.survey_output.resolve())], check=True, env=env)
            print(f"Offline survey execution: {time.monotonic() - start:.2f}s; {args.survey_output.resolve()}", flush=True)


if __name__ == "__main__":
    main()
