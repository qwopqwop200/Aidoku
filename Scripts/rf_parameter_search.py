#!/usr/bin/env python3
"""RF648 fixed-resolution raw capture and label-backed offline parameter search.

Runtime capture requests contain only input identities. Labels are read only by
the evaluator. Uses existing source/split contracts; no new model or resolution.
"""
import argparse
import hashlib
import html
import itertools
import json
import math
from pathlib import Path
import resource
import statistics
import time

import manga_ocr_search as shared

OUT = shared.REPO / "build/rf648-parameter-search-current"
CONFIDENCES = [.01,.05,.1,.15,.2,.25,.3,.4,.5,.6,.7,.8,.9,.95]
MASK_PROBABILITIES = [.1,.3,.5,.7,.9]
OWNER_COVERAGES = [.5,.65,.8,.9,.95]
BALLOON_CONFIDENCES = [.01,.1,.2,.3,.4,.5,.6,.7,.8,.9]


def retained_mask_queries(selected, balloon_confidence, cap=32):
    """Replay the ranked shared balloon/frame mask budget."""
    retained = set()
    for query, cls, score in selected:
        threshold = balloon_confidence if cls == 2 else .5
        if cls in (2, 3) and score >= threshold and len(retained) < cap:
            retained.add(query)
    return retained


def prepare():
    request = shared.read(shared.OUT/"request.json")
    assert len(request["cases"])==836
    OUT.mkdir(parents=True,exist_ok=True)
    job = {"cases":request["cases"],"output":str(OUT/"raw"),"floor":.01}
    shared.save(OUT/"request.json",job)
    shared.save(OUT/"pilot-request.json",{**job,"limit":3})
    shared.save(OUT/"specification.json",{
        "side":648,"maskSide":162,"weightsPrecision":"FP16","computeUnits":"cpuAndGPU",
        "requestSHA256":shared.sha(OUT/"request.json"),"annotationsSHA256":shared.sha(shared.LABELS/"annotations.json"),
        "selectionSHA256":shared.sha(shared.ROUND/"selection.json"),"confidenceGrid":CONFIDENCES,
        "maskProbabilityGrid":MASK_PROBABILITIES,"balloonConfidenceGrid":BALLOON_CONFIDENCES,
        "ownerCoverageGrid":OWNER_COVERAGES,"development":"existing DEV100","validation":"historical40; previously exposed",
        "baselineThresholds":[.25,.20,.50,.50],"stockTopK":160,"queryCount":300,
        "resolutionSearch":False,"metricVersion":"rf648-source-envelope-and-horizontal-owner-pair-v1",
        "caveats":["Source region labels are silver envelopes, not exhaustive detection boxes or glyph masks.",
                   "Complete balloon/frame mask GT unavailable; do not call owner/group proxies segmentation IoU or accuracy.",
                   "Horizontal merge proposals are evaluated separately from sentence meaning and final rendered quality."],
        "unmeasured":["frame detection accuracy","complete segmentation IoU","OCR transcription accuracy","final rendering quality","iPhone latency/memory"],
        "rawMaskWorstCaseBytes":836*160*162*162*4,"mainParametersChanged":False})
    print(OUT/"request.json",flush=True)


def evaluate():
    import cv2
    import numpy as np
    start = time.perf_counter()
    spec = shared.read(OUT/"specification.json")
    request = shared.read(OUT/"request.json")
    assert shared.sha(shared.LABELS/"annotations.json")==spec["annotationsSHA256"]
    assert shared.sha(shared.ROUND/"selection.json")==spec["selectionSHA256"]
    labels = {r["id"]:r for r in shared.read(shared.LABELS/"annotations.json")}
    manifest = {r["id"]:r for r in shared.read(shared.ROUND/"current-input-manifest.json")["cases"]}
    split = shared.read(shared.ROUND/"selection.json")
    dev = {r["id"] for r in split["dev"]}
    validation = {r["id"] for r in split["validation"]}
    assert not dev.intersection(validation)
    assert not {r["family"] for r in split["dev"]}.intersection(r["family"] for r in split["validation"])
    pages,missing,costs = [],[],[]
    confidence_totals = {}
    # All class cutoffs reuse the exact stock160 selection before class gating.
    for case in request["cases"]:
        ident = case["id"]
        folder = OUT/"raw"/ident
        record = shared.read(folder/"result.json") if (folder/"result.json").exists() else {}
        if record.get("status")!="complete":
            missing.append({"id":ident,"status":record.get("status","not-run"),"error":record.get("error")})
            continue
        assert record["side"]==648 and record["sourceSHA256"]==case["sourceSHA256"]
        assert shared.sha(folder/"masks.f32")==record["masksSHA256"]
        costs.append({k:record[k] for k in ["predictionMs","preprocessMs","captureWallMs","processPeakRSSBytes","masksBytes"]})
        boxes = np.asarray(record["boxesCXCYWH"],dtype=np.float64)
        xyxy = np.column_stack([boxes[:,0]-boxes[:,2]/2,boxes[:,1]-boxes[:,3]/2,boxes[:,0]+boxes[:,2]/2,boxes[:,1]+boxes[:,3]/2])
        selected = [(x["flat"]//5,x["flat"]%5,x["score"]) for x in record["top160"] if x["flat"]%5<4 and x["score"]>=.01]
        annotation = labels[ident]
        buckets = ["all836"]+(["dev100"] if ident in dev else [])+(["historicalValidation40"] if ident in validation else [])
        for cls in [0,1]:
            gt = [r for r in shared.text_regions(annotation,True) if (r.get("role")=="sfx")==bool(cls)]
            ground = shared.union_bits([r["polygon"] for r in gt])
            predictions = sorted([x for x in selected if x[1]==cls],key=lambda x:-x[2])
            predicted,cursor = 0,0
            for confidence in reversed(CONFIDENCES):
                while cursor<len(predictions) and predictions[cursor][2]>=confidence:
                    q = predictions[cursor][0]
                    x1,y1,x2,y2 = xyxy[q]
                    predicted |= shared.polygon_bits([[x1,y1],[x2,y1],[x2,y2],[x1,y2]])
                    cursor += 1
                counts = [(ground&predicted).bit_count(),predicted.bit_count(),ground.bit_count(),0,0,0,1,0]
                for bucket in buckets:
                    total = confidence_totals.setdefault((cls,confidence,bucket),[0]*8)
                    for i,v in enumerate(counts):total[i] += v
        # Freeze owner boxes from the existing main payload; do not regenerate OCR.
        payload = shared.read(Path(manifest[ident]["payload"]))["value"]["nativeLayout"]
        items = [i for i in payload["items"] if len(i.get("sourceBounds",[]))==4 and i["sourceBounds"][2]>0 and i["sourceBounds"][3]>0]
        bounds = np.asarray([i["sourceBounds"] for i in items],dtype=np.float64).reshape(-1,4)
        group_polygons = {}
        for r in annotation["regions"]:
            if r["kind"]=="must_cover":group_polygons.setdefault(r["group_id"],[]).append(r["polygon"])
        gnames = sorted(group_polygons)
        gbits = [shared.union_bits(group_polygons[g]) for g in gnames]
        owned = []
        for b in bounds:
            x,y,w,h=b
            mask=shared.polygon_bits([[x,y],[x+w,y],[x+w,y+h],[x,y+h]])
            area=mask.bit_count()
            ranking=sorted([((mask&g).bit_count()/max(1,area),j) for j,g in enumerate(gbits)],reverse=True)
            owned.append(ranking[0][1] if ranking and ranking[0][0]>=.5 and (len(ranking)==1 or ranking[1][0]<ranking[0][0]*.75) else -1)
        owned=np.asarray(owned,dtype=np.int32)
        ai,bi=np.triu_indices(len(bounds),1)
        if len(ai):
            a,b=bounds[ai],bounds[bi]
            vertical=np.maximum(0,np.minimum(a[:,1]+a[:,3],b[:,1]+b[:,3])-np.maximum(a[:,1],b[:,1]))/np.maximum(1e-9,np.minimum(a[:,3],b[:,3]))
            horizontal_gap=np.maximum(0,np.maximum(a[:,0],b[:,0])-np.minimum(a[:,0]+a[:,2],b[:,0]+b[:,2]))/np.maximum(1e-9,np.minimum(a[:,3],b[:,3]))
            center=np.abs((a[:,1]+a[:,3]/2)-(b[:,1]+b[:,3]/2))/np.maximum(1e-9,np.minimum(a[:,3],b[:,3]))
            known=(owned[ai]>=0)&(owned[bi]>=0)&(vertical>=.2)
            truth=owned[ai]==owned[bi]
        else:
            vertical=horizontal_gap=center=np.array([],dtype=float);known=truth=np.array([],dtype=bool)
        query_ids=record["maskQueryIDs"]
        raw=np.fromfile(folder/"masks.f32",dtype="<f4").reshape(len(query_ids),162,162)
        qindex={q:j for j,q in enumerate(query_ids)}
        balloons=[];seen=set()
        for q,c,score in selected:
            if c==2 and q not in seen:
                seen.add(q);balloons.append((q,score))
        balloon_queries=np.array([q for q,s in balloons],dtype=np.int32)
        balloon_scores=np.array([s for q,s in balloons],dtype=float)
        masks=np.array([cv2.resize(raw[qindex[q]],(128,128),interpolation=cv2.INTER_LINEAR) for q in balloon_queries],dtype=np.float32).reshape(-1,128,128)
        rects=np.clip(np.round(np.column_stack([bounds[:,0],bounds[:,1],bounds[:,0]+bounds[:,2],bounds[:,1]+bounds[:,3]])*128),0,128).astype(int) if len(bounds) else np.zeros((0,4),dtype=int)
        # Store compact coverage matrices, not full-page masks per parameter.
        coverage=[];areas=[]
        for probability in MASK_PROBABILITIES:
            threshold=math.log(probability/(1-probability))
            binary=masks>threshold
            areas.append(binary.sum(axis=(1,2)))
            integral=np.pad(binary.astype(np.int32),((0,0),(1,0),(1,0))).cumsum(1).cumsum(2)
            x1,y1,x2,y2=rects.T
            surface=np.maximum(1,(x2-x1)*(y2-y1))
            fractions=(integral[:,y2,x2]-integral[:,y1,x2]-integral[:,y2,x1]+integral[:,y1,x1])/surface[None,:]
            coverage.append(fractions)
        availability={}
        for confidence in BALLOON_CONFIDENCES:
            retained=retained_mask_queries(selected,confidence)
            availability[confidence]=np.array([q in retained for q in balloon_queries],dtype=bool)
        pages.append({"id":ident,"buckets":buckets,"bounds":bounds,"ownerGroups":owned,"ai":ai,"bi":bi,"known":known,"truth":truth,
            "vertical":vertical,"gap":horizontal_gap,"center":center,"queries":balloon_queries,"scores":balloon_scores,"coverage":coverage,"areas":areas,
            "maskAvailability":availability,
            "unknownOwnerCount":int((owned<0).sum())})
        if len(pages)%100==0:print(f"RF648 prepared {len(pages)}/836",flush=True)
    if not pages:raise ValueError("No source-bound RF648 pages available")
    class_rankings={}
    for cls in [0,1]:
        rank=[]
        for confidence in CONFIDENCES:
            rank.append({"confidence":confidence,"metrics":{b:shared.metrics(confidence_totals[(cls,confidence,b)]) for b in ["dev100","historicalValidation40","all836"] if (cls,confidence,b) in confidence_totals}})
        rank.sort(key=lambda r:r["metrics"].get("dev100",{}).get("envelopeF1Proxy") or -1,reverse=True)
        class_rankings[str(cls)]=rank
    owner_grid=list(itertools.product(BALLOON_CONFIDENCES,range(len(MASK_PROBABILITIES)),OWNER_COVERAGES))
    geometry_grid=list(itertools.product([.3,.5,.7],[.5,1.0,1.5,2.0],[.35,.65,1.0]))
    # Stage1 compares ownership settings with one frozen horizontal geometry.
    def assignments(page,config):
        confidence,mask_i,minimum=config
        score=page["scores"]
        allowed=(score>=confidence)&page["maskAvailability"][confidence]
        fractions=page["coverage"][mask_i]
        eligible=allowed[:,None]&(fractions>=minimum)
        areas=np.where(eligible,page["areas"][mask_i][:,None],np.inf)
        result=np.full(len(page["bounds"]),-1,dtype=np.int32)
        if len(score):
            best=areas.argmin(axis=0)
            valid=np.isfinite(areas[best,np.arange(len(result))])
            result[valid]=page["queries"][best[valid]]
        return result
    def pair_counts(page,assignment,geometry):
        y,gap,center=geometry
        a,b=page["ai"],page["bi"]
        predicted=(assignment[a]>=0)&(assignment[a]==assignment[b])&(page["vertical"]>=y)&(page["gap"]<=gap)&(page["center"]<=center)
        known,truth=page["known"],page["truth"]
        return [int((predicted&known&truth).sum()),int((predicted&known&~truth).sum()),int((~predicted&known&truth).sum()),
                int((predicted&~known).sum()),int((~known).sum()),int((assignment>=0).sum()),len(assignment),int(known.any())]
    def pair_metrics(counts):
        tp,fp,fn,unknown,unmeasured,assigned,owners,count=counts
        return {"correctMerges":tp,"wrongMerges":fp,"missedHorizontalPairs":fn,"pairPrecision":tp/(tp+fp) if tp+fp else None,
            "pairRecall":tp/(tp+fn) if tp+fn else None,"pairF1":2*tp/(2*tp+fp+fn) if 2*tp+fp+fn else None,
            "proposedUnlabelledPairs":unknown,"unmeasuredPairs":unmeasured,"assignedOwners":assigned,"owners":owners,"measuredPages":count}
    def grid_eval(config,geometry):
        totals={b:[0]*8 for b in ["dev100","historicalValidation40","all836"]}
        for page in pages:
            counts=pair_counts(page,assignments(page,config),geometry)
            for bucket in page["buckets"]:
                total=totals[bucket]
                for i,v in enumerate(counts):total[i]+=v
        return {b:pair_metrics(v) for b,v in totals.items()}
    seed_geometry=(.5,1.5,.65)
    owner_rows=[]
    for config in owner_grid:
        # First stage development only; do not use validation for selection.
        total=[0]*8
        for page in pages:
            if page["id"] not in dev:continue
            counts=pair_counts(page,assignments(page,config),seed_geometry)
            for i,v in enumerate(counts):total[i]+=v
        owner_rows.append({"config":config,"dev":pair_metrics(total)})
    owner_rows.sort(key=lambda r:(r["dev"]["pairF1"] or -1,-r["dev"]["wrongMerges"]),reverse=True)
    finalists=[]
    for row in owner_rows:
        if row["config"] not in finalists:finalists.append(row["config"])
        if len(finalists)==5:break
    baseline_config=(.5,2,.8)
    if baseline_config not in finalists:finalists.append(baseline_config)
    joint=[]
    for config,geometry in itertools.product(finalists,geometry_grid):
        total=[0]*8
        for page in pages:
            if page["id"] not in dev:continue
            counts=pair_counts(page,assignments(page,config),geometry)
            for i,v in enumerate(counts):total[i]+=v
        joint.append({"config":config,"geometry":geometry,"dev":pair_metrics(total)})
    joint.sort(key=lambda r:(r["dev"]["pairF1"] or -1,-r["dev"]["wrongMerges"]),reverse=True)
    winner=joint[0]
    # Freeze before validation/all-corpus metrics are inspected.
    frozen={"side":648,"textConfidence":class_rankings["0"][0]["confidence"],"sfxConfidence":class_rankings["1"][0]["confidence"],
        "balloonConfidence":winner["config"][0],"maskProbability":MASK_PROBABILITIES[winner["config"][1]],"ownerCoverage":winner["config"][2],
        "minimumVerticalOverlap":winner["geometry"][0],"maximumHorizontalGapHeightRatio":winner["geometry"][1],
        "maximumCenterHeightRatio":winner["geometry"][2],"frameConfidence":.5,"stockTopK":160,
        "maximumMaskQueries":32,"frameMaskCompetition":True,
        "selectionScope":"existing DEV100 pair-label/proxy screening only; no runtime label/ID access",
        "implementationSHA256":{name:shared.sha(shared.REPO/name) for name in [
            "Scripts/rf_parameter_search.py","Scripts/image-translation/HostRFParameterSearch.swift"]},
        "requestSHA256":shared.sha(OUT/"request.json"),"annotationsSHA256":spec["annotationsSHA256"],
        "selectionSHA256":spec["selectionSHA256"]}
    shared.save(OUT/"frozen-parameters.json",frozen)
    final_metrics=grid_eval(winner["config"],winner["geometry"])
    baseline_metrics=grid_eval(baseline_config,seed_geometry)
    page_comparisons=[]
    for page in pages:
        before=pair_metrics(pair_counts(page,assignments(page,baseline_config),seed_geometry))
        after=pair_metrics(pair_counts(page,assignments(page,winner["config"]),winner["geometry"]))
        before_errors=before["wrongMerges"]+before["missedHorizontalPairs"]
        after_errors=after["wrongMerges"]+after["missedHorizontalPairs"]
        outcome=("unmeasured" if not page["known"].any() else
                 "improved" if after_errors<before_errors else "regressed" if after_errors>before_errors else "same")
        page_comparisons.append({"id":page["id"],"outcome":outcome,"baseline":before,"selected":after,
                                 "visualInspection":"not-performed","unknownOwnerCount":page["unknownOwnerCount"]})
    capture_progress=shared.read(OUT/"raw/progress.json")
    label_coverage={}
    for bucket in ["dev100","historicalValidation40","all836"]:
        cohort=[p for p in pages if bucket in p["buckets"]]
        total_pairs=sum(len(p["known"]) for p in cohort)
        measured_pairs=sum(int(p["known"].sum()) for p in cohort)
        total_owners=sum(len(p["bounds"]) for p in cohort)
        measured_owners=total_owners-sum(p["unknownOwnerCount"] for p in cohort)
        label_coverage[bucket]={"mappedOwners":measured_owners,"totalOwners":total_owners,
            "ownerMappingFraction":measured_owners/total_owners if total_owners else None,
            "evaluatedHorizontalPairs":measured_pairs,"allOwnerPairs":total_pairs,
            "horizontalPairEvaluationFraction":measured_pairs/total_pairs if total_pairs else None,
            "caveat":"Pair cohort requires unambiguous label mapping and vertical overlap >=0.2; other pairs not scored."}
    report={"status":"complete" if len(pages)==836 else "partial","resolution":648,"resolutionChanged":False,
        "manifestPages":836,"measuredPages":len(pages),"unmeasuredPages":836-len(pages),"failuresOrPending":missing,
        "classRankings":class_rankings,"ownershipSearch":owner_rows,"jointSearch":joint,"selected":frozen,
        "horizontalPairBaseline":baseline_metrics,"horizontalPairSelected":final_metrics,
        "pairBaselineAuthority":"fixed proxy comparator, not actual current-main merger output",
        "labelCoverage":label_coverage,
        "pageComparisons":page_comparisons,
        "pageOutcomeCounts":{outcome:sum(p["outcome"]==outcome for p in page_comparisons)
                             for outcome in ["improved","regressed","same","unmeasured"]},
        "costs":{"warmModelMedianMs":statistics.median(c["predictionMs"] for c in costs[1:]) if len(costs)>1 else None,
            "preprocessMedianMs":statistics.median(c["preprocessMs"] for c in costs),
            "captureWallMedianMs":statistics.median(c["captureWallMs"] for c in costs),
            "modelLoadMs":capture_progress["modelLoadMs"],
            "processPeakRSSBytes":max(c["processPeakRSSBytes"] for c in costs),"rawMaskBytes":sum(c["masksBytes"] for c in costs),
            "captureElapsedSeconds":capture_progress["elapsedSeconds"],"searchElapsedSeconds":time.perf_counter()-start,
            "searchPeakRSSBytes":resource.getrusage(resource.RUSAGE_SELF).ru_maxrss},
        "maskIoU":None,"frameAccuracy":None,"finalPixelQuality":None,"mainParametersChanged":False,
        "caveats":spec["caveats"],"validationExposure":spec["validation"]}
    shared.save(OUT/"evaluation.json",report)
    body='<!doctype html><meta charset="utf-8"><title>RF648 parameter search</title><style>body{background:#17191e;color:#eee;font:16px system-ui;margin:30px}table{border-collapse:collapse}td,th{padding:10px;border:1px solid #666}a{color:#adceff}</style><h1>RF-DETR648 고정 해상도 파라미터 탐색</h1>'
    body+=f'<p>{len(pages)}/836장 · 해상도 변경 없음 · 원시 score floor .01 · 메인 미적용</p><h2>선택 설정</h2><pre>'+html.escape(json.dumps(frozen,ensure_ascii=False,indent=2))+'</pre>'
    body+='<h2>클래스별 영역 F1 대리지표</h2><table><tr><th>클래스</th><th>기본 임계값</th><th>선택</th><th>기본 전체 F1 proxy</th><th>선택 전체 F1 proxy</th></tr>'
    for cls,title,baseline in [(0,"text",.25),(1,"SFX",.20)]:
        ranking=class_rankings[str(cls)];before=next(r for r in ranking if r["confidence"]==baseline);after=ranking[0]
        body+='<tr>'+''.join(f'<td>{v}</td>' for v in [title,baseline,after["confidence"],f'{before["metrics"]["all836"]["envelopeF1Proxy"]:.4f}',f'{after["metrics"]["all836"]["envelopeF1Proxy"]:.4f}'])+'</tr>'
    body+='</table><h2>같은 높이 병합 제안: 라벨 대응 가능한 쌍</h2><p>실제 메인 병합 결과가 아닌 고정 proxy 비교. 같은 말풍선만으로 문장을 합치지 않음.</p><pre>'+html.escape(json.dumps({"baseline":baseline_metrics,"candidate":final_metrics},ensure_ascii=False,indent=2))+'</pre>'
    body+='<h2>페이지별 병합 제안 변화</h2><p>오병합+미병합 쌍 수 기준이며 최종 픽셀 시각 판정이 아님.</p><pre>'+html.escape(json.dumps(report["pageOutcomeCounts"],ensure_ascii=False,indent=2))+'</pre>'
    body+='<table><tr><th>페이지</th><th>변화</th><th>기본 오병합/미병합</th><th>후보 오병합/미병합</th></tr>'
    for row in sorted(page_comparisons,key=lambda r:(r["selected"]["wrongMerges"]-r["baseline"]["wrongMerges"],r["selected"]["missedHorizontalPairs"]-r["baseline"]["missedHorizontalPairs"]),reverse=True):
        before,after=row["baseline"],row["selected"]
        source=Path(manifest[row["id"]]["source"]).as_uri()
        body+=f'<tr><td><a href="{html.escape(source,quote=True)}">{row["id"]}</a></td><td>{row["outcome"]}</td><td>{before["wrongMerges"]}/{before["missedHorizontalPairs"]}</td><td>{after["wrongMerges"]}/{after["missedHorizontalPairs"]}</td></tr>'
    body+='</table>'
    body+='<h2>라벨 측정 범위</h2><pre>'+html.escape(json.dumps(label_coverage,ensure_ascii=False,indent=2))+'</pre>'
    body+='<h2>시간·메모리</h2><pre>'+html.escape(json.dumps(report["costs"],indent=2))+'</pre><p>Mac host; iPhone 미측정. 완전한 말풍선/프레임 마스크 GT가 없어 segmentation IoU는 미측정. 최종 렌더링·시각 품질 통과가 아님.</p><a href="evaluation.json">전체 평가</a> · <a href="frozen-parameters.json">고정 후보 설정</a>'
    (OUT/"index.html").write_text(body)
    print(json.dumps({"pages":len(pages),"selected":frozen,"baseline":baseline_metrics,"candidate":final_metrics,"costs":report["costs"]},ensure_ascii=False),flush=True)


if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase",choices=["prepare","evaluate"])
    args=parser.parse_args()
    prepare() if args.phase=="prepare" else evaluate()
