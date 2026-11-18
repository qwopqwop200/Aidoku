#!/usr/bin/env python3
"""Manga-only production detector sweep, with offline silver-envelope scoring.

prepare -> swift Scripts/image-translation.swift --manga-detector-search REQUEST
        -> evaluate
No labels enter the Swift request. Pure stdlib; no API calls or image copies.
"""
import argparse
import hashlib
import html
import json
import math
from pathlib import Path
import statistics
import time

REPO = Path(__file__).resolve().parents[1]
ROUND = REPO / "build/rf-ensemble100-r117"
OUT = REPO / "build/manga-ocr-search-current"
LABELS = REPO.parent / "labels/final-ensemble-recovered-20261013"
BOX_THRESHOLDS = [.01, .05, .1, .15, .2, .25, .3, .4, .5, .6, .75, .9]
REC_THRESHOLDS = [.01, .1, .2, .3, .4, .5, .6, .7, .75, .8, .85, .9, .95]
SIZE = 128


def read(path):
    return json.loads(path.read_text())


def save(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    temporary.replace(path)


def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def prepare():
    manifest = read(ROUND / "current-input-manifest.json")
    fallback = {row["id"]: row for row in read(LABELS / "manifest.json")}
    rows = manifest["cases"]
    assert len(rows) == 836 and len({row["id"] for row in rows}) == 836
    cases = []
    for row in rows:
        source = Path(row["source"])
        if not source.is_file():
            source = Path(fallback[row["id"]]["input_path"])
        assert source.is_file(), (row["id"], "source missing")
        assert sha(source) == row["sourceSHA256"], (row["id"], "source hash mismatch")
        cases.append({"id": row["id"], "source": str(source),
                      "sourceSHA256": row["sourceSHA256"], "dimensions": row["dimensions"]})
    # Interleave the frozen DEV100 with the remainder so early progress is diverse.
    dev_order = [r["id"] for r in read(ROUND / "selection.json")["dev"]]
    by_id = {r["id"]: r for r in cases}
    cases = [by_id[i] for i in dev_order] + [r for r in cases if r["id"] not in set(dev_order)]
    OUT.mkdir(parents=True, exist_ok=True)
    request = {"cases": cases, "output": str(OUT / "predictions"), "sides": [512, 768, 960, 1184],
               "pixelThresholds": [.01, .05, .1, .15, .2, .3], "unclipRatios": [1.0, 1.4, 1.8]}
    save(OUT / "request.json", request)
    save(OUT / "specification.json", {
        "model": "PP-OCRv6-Manga-DetShapes", "recognition": "not run in detector screening",
        "requestSHA256": sha(OUT / "request.json"), "manifestSHA256": sha(ROUND / "current-input-manifest.json"),
        "annotationsSHA256": sha(LABELS / "annotations.json"), "boxThresholds": BOX_THRESHOLDS,
        "selectionSHA256": sha(ROUND / "selection.json"), "pages": len(cases), "modelCalls": len(cases) * 4,
        "parameterCombinations": 4 * 6 * 3 * len(BOX_THRESHOLDS),
        "metric": "silver-envelope pixel precision/recall/F1 proxy at 128x128; NOT OCR transcription or standard word-box F1",
        "precisionCaveat": "outside target envelopes is unlabelled or protected; not independently verified false text",
        "recallCaveat": "paragraph envelopes include whitespace; not glyph recall",
        "selection": "rank on existing DEV100, freeze winner, report existing validation40 and all836 separately",
        "validationExposure": "reused historical partition; not newly unseen validation",
        "cost": "Mac host sequential detector; process peak RSS cumulative, not per-resolution mobile peak",
        "estimatedRawMapUpperBoundBytes": 836 * sum(s*s*4 for s in request["sides"]),
        "diskPolicy": "retain raw maps and numeric candidates; no copied page rasters or final renders",
        "implementationSHA256": {str(p.relative_to(REPO)): sha(p) for p in [
            REPO / "Scripts/manga_ocr_search.py", REPO / "Scripts/image-translation/HostMangaDetectorSearch.swift",
            REPO / "Aidoku/Core/Translation/NativeEngine/OCR/NativeCoreMLDetector.swift",
            REPO / "Aidoku/Core/Translation/NativeEngine/OCR/NativeCoreMLDBPostprocessor.swift"]},
    })
    print(OUT / "request.json", flush=True)


def polygon_bits(points):
    """Even-odd scan conversion at pixel centers; normalized top-left coordinates."""
    if len(points) < 3:
        return 0
    if not all(len(p) == 2 and all(math.isfinite(v) for v in p) for p in points):
        raise ValueError("Invalid polygon")
    points = [(x * SIZE, y * SIZE) for x, y in points]
    lo = max(0, math.ceil(min(y for x, y in points) - .5))
    hi = min(SIZE, math.ceil(max(y for x, y in points) - .5))
    result = 0
    edges = list(zip(points, points[1:] + points[:1]))
    for row in range(lo, hi):
        y = row + .5
        xs = sorted(x1 + (y-y1) * (x2-x1) / (y2-y1)
                    for (x1, y1), (x2, y2) in edges if (y1 <= y < y2) or (y2 <= y < y1))
        for x1, x2 in zip(xs[::2], xs[1::2]):
            start = max(0, math.ceil(x1-.5))
            end = min(SIZE, math.ceil(x2-.5))
            if end > start:
                result |= ((1 << (end-start))-1) << (row*SIZE + start)
    return result


def union_bits(polygons):
    result = 0
    for polygon in polygons:
        result |= polygon_bits(polygon)
    return result


def text_regions(annotation, all_text=False):
    if all_text:
        return [r for r in annotation["regions"] if r["kind"] in ("must_cover", "protected")
                and r.get("role") in ("dialogue", "caption", "sfx", "background")]
    return [r for r in annotation["regions"] if r["kind"] == "must_cover"]


def prepare_recognition(all_text=False):
    prefix = "alltext-" if all_text else ""
    report = read(OUT / (prefix + "evaluation.json"))
    assert report["status"] == "complete" and report["ranking"]
    detector = read(OUT / "request.json")
    winner = report["ranking"][0]
    old_request = OUT / "recognition-request.json"
    if all_text and old_request.exists():
        old = read(old_request)
        if all(old[k] == winner[k] for k in ("side", "pixelThreshold", "unclipRatio")):
            save(OUT / (prefix + "recognition-request.json"), old)
            print("Reusing identical completed recognition geometry and source-bound request", flush=True)
            return
    save(OUT / (prefix + "recognition-request.json"), {
        "cases": detector["cases"], "output": str(OUT / (prefix + "recognition")), "predictionRoot": detector["output"],
        "detectorRequestSHA256": sha(OUT / "request.json"), "side": winner["side"],
        "pixelThreshold": winner["pixelThreshold"], "unclipRatio": winner["unclipRatio"]})
    print(OUT / (prefix + "recognition-request.json"), flush=True)


def evaluate_recognition(all_text=False):
    prefix = "alltext-" if all_text else ""
    request = read(OUT / (prefix + "recognition-request.json"))
    digest = sha(OUT / (prefix + "recognition-request.json"))
    labels = {r["id"]: r for r in read(LABELS / "annotations.json")}
    split = read(ROUND / "selection.json")
    dev = {r["id"] for r in split["dev"]}
    validation = {r["id"] for r in split["validation"]}
    totals, costs, failures = {}, [], []
    for case in request["cases"]:
        ident = case["id"]
        path = Path(request["output"]) / (ident + ".json")
        result = read(path) if path.exists() else {}
        if result.get("status") != "complete" or result.get("requestSHA256") != digest:
            failures.append({"id": ident, "status": result.get("status", "not-run"), "error": result.get("error")})
            continue
        assert result["sourceSHA256"] == case["sourceSHA256"]
        annotation = labels[ident]
        target = text_regions(annotation, all_text)
        ground = union_bits([r["polygon"] for r in target])
        protected = union_bits([r["polygon"] for r in annotation["regions"] if r["kind"] == "protected"
                                and (not all_text or r.get("role") == "art")])
        group_polygons = {}
        for r in target:
            group_polygons.setdefault(r["group_id"], []).append(r["polygon"])
        groups = [union_bits(p) for p in group_polygons.values()]
        groups = [g for g in groups if g]
        rows = [(r["score"], r["recognitionConfidence"], polygon_bits(r["polygon"])) for r in result["boxes"]
                if r.get("recognitionConfidence") is not None and r.get("text", "").strip()]
        for box_threshold in BOX_THRESHOLDS:
            ranked = sorted((r for r in rows if r[0] >= box_threshold), key=lambda r: r[1], reverse=True)
            predicted, cursor = 0, 0
            for rec_threshold in reversed(REC_THRESHOLDS):
                while cursor < len(ranked) and ranked[cursor][1] >= rec_threshold:
                    predicted |= ranked[cursor][2]
                    cursor += 1
                values = [(predicted & ground).bit_count(), predicted.bit_count(), ground.bit_count(),
                          (predicted & protected).bit_count(),
                          sum((predicted & g).bit_count() >= .5*g.bit_count() for g in groups), len(groups), 1, 0]
                for bucket in ["all836"] + (["dev100"] if ident in dev else []) + (["historicalValidation40"] if ident in validation else []):
                    total = totals.setdefault((box_threshold, rec_threshold, bucket), [0]*8)
                    for i, value in enumerate(values):
                        total[i] += value
        costs.append({k: result[k] for k in ["recognitionWallMs", "modelWasAlreadyLoaded", "modelLoadMs", "functionLoadMs",
            "processPeakRSSBytes", "requestedRegions", "skippedInvalidRegions"]})
    ranking = []
    for box_threshold in BOX_THRESHOLDS:
        for rec_threshold in REC_THRESHOLDS:
            row = {"boxThreshold": box_threshold, "recognitionThreshold": rec_threshold, "metrics": {}}
            for bucket in ["dev100", "historicalValidation40", "all836"]:
                if (box_threshold, rec_threshold, bucket) in totals:
                    row["metrics"][bucket] = metrics(totals[(box_threshold, rec_threshold, bucket)])
            if row["metrics"]:
                ranking.append(row)
    ranking.sort(key=lambda r: r["metrics"].get("dev100", {}).get("envelopeF1Proxy") or -1, reverse=True)
    warm = [r for r in costs if r["modelWasAlreadyLoaded"]]
    cost = {"warmRecognitionMedianMs": statistics.median(r["recognitionWallMs"] for r in warm) if warm else None,
            "processPeakRSSBytes": max((r["processPeakRSSBytes"] for r in costs), default=None),
            "pages": len(costs), "requestedRegions": sum(r["requestedRegions"] for r in costs),
            "skippedInvalidRegions": sum(r["skippedInvalidRegions"] for r in costs),
            "scope": "Mac recognizer at confidence floor .01 on cached low-score detector boxes; not final filtered runtime cost"}
    report = {"status": "complete" if len(costs) == 836 else "partial", "measuredPages": len(costs),
              "manifestPages": 836, "geometry": {k: request[k] for k in ["side", "pixelThreshold", "unclipRatio"]},
              "ranking": ranking, "costs": cost, "failuresOrPending": failures,
              "metric": "silver-envelope F1 proxy after recognition confidence filtering; no transcription ground truth",
              "labelScope": "all labelled source text including preserved SFX/background" if all_text else "translation targets only",
              "CER": None, "WER": None, "productionRecoveryAndGrouping": "not run; raw Manga detector/recognizer screening",
              "mainParametersChanged": False}
    save(OUT / (prefix + "recognition-evaluation.json"), report)
    if ranking:
        save(OUT / (prefix + "selected-ocr-candidate.json"), {"geometry": report["geometry"], "candidate": ranking[0],
            "selection": "DEV100 envelope proxy only; not certified end-to-end quality", "recognizerWidth": 1184})
    index = OUT / "index.html"
    if index.exists():
        page = index.read_text().split('<section id="recognition">')[0]
        page += '<section id="recognition"><h2>Manga 글자 인식 후 임계값 탐색</h2>'
        page += f'<p>{len(costs)}/836장 · 박스/인식 임계값 156조합 · CER/WER 미측정(전사 정답 없음)</p>'
        page += '<pre>' + html.escape(json.dumps({"geometry": report["geometry"], "best": ranking[:1], "costs": cost}, indent=2, ensure_ascii=False)) + '</pre>'
        page += f'<a href="{prefix}recognition-evaluation.json">인식 후 전체 평가</a></section>'
        index.write_text(page)
    print(json.dumps({"measuredPages": len(costs), "best": ranking[:1], "costs": cost}, ensure_ascii=False), flush=True)


def summarize(all_text=False):
    """Reformat saved measurements and expose the F1/owner-recall tradeoff."""
    path = OUT / ("alltext-evaluation.json" if all_text else "evaluation.json")
    report = read(path)
    report["metricVersion"] = "all-source-text-envelope-v2" if all_text else "translation-target-envelope-v1"
    baseline = report["referenceManga960"]
    floor = baseline["metrics"]["dev100"]["targetGroupRecallAtHalfEnvelope"]
    guarded = next((r for r in report["ranking"]
                    if r["metrics"]["dev100"]["targetGroupRecallAtHalfEnvelope"] >= floor), None)
    report.pop("inferenceBuildFingerprint", None)
    report.pop("inferenceHelperSnapshotSHA256", None)
    report["inferenceImplementationSHA256"] = read(OUT / "specification.json")["implementationSHA256"]
    report["devRecallPreservingCandidate"] = guarded
    report["selectionAudit"] = {
        "status": "no automatic production adoption",
        "reason": "development envelope score alone does not certify transcription or end-to-end visual quality",
        "constraint": "DEV group recall >= reference baseline; supplementary post-hoc DEV analysis",
        "validationExposure": "historical validation/all-corpus aggregates already inspected; not new unseen validation"}
    save(path, report)
    body = '<section id="selection-summary"><h2>해상도별 DEV 선택 설정</h2><table><tr><th>긴 변</th><th>픽셀</th><th>박스</th><th>확장</th><th>전체 영역 F1 proxy</th><th>전체 그룹 회수율</th><th>Mac 검출 중앙값</th></tr>'
    for side, row in report["perSideDevBest"].items():
        m = row["metrics"]["all836"]
        latency = report["costs"][side]["warmDetectorMedianMs"]
        body += '<tr>' + ''.join(f'<td>{v}</td>' for v in [side, row["pixelThreshold"], row["boxThreshold"], row["unclipRatio"],
            f'{m["envelopeF1Proxy"]:.4f}', f'{100*m["targetGroupRecallAtHalfEnvelope"]:.2f}%', f'{latency:.1f} ms']) + '</tr>'
    body += '</table><p>시간은 확률맵 확보용 고정 설정(pixel .15 / box .01 / unclip 1.4)의 검출 시간이며 선택 설정의 전체 OCR 시간이 아님.</p>'
    body += '<h2>F1과 누락의 상충</h2><table><tr><th>후보</th><th>side / pixel / box / unclip</th><th>전체 F1 proxy</th><th>전체 그룹 회수율</th><th>보호영역 겹침 픽셀</th></tr>'
    for title, row in [("960 기본 검출", baseline), ("DEV F1 최대", report["ranking"][0]), ("DEV 그룹 회수율 유지", guarded)]:
        if row:
            m = row["metrics"]["all836"]
            body += '<tr>' + ''.join(f'<td>{v}</td>' for v in [title,
                f'{row["side"]} / {row["pixelThreshold"]} / {row["boxThreshold"]} / {row["unclipRatio"]}',
                f'{m["envelopeF1Proxy"]:.4f}', f'{100*m["targetGroupRecallAtHalfEnvelope"]:.2f}%', m["protectedOverlapPixels"]]) + '</tr>'
    body += '</table><p>모든 값은 silver 문단 영역 기반 자동 대리지표. 누락 위험과 시각 확인 없이 F1 1위를 메인에 적용하지 않음.</p></section>'
    index = OUT / "index.html"
    page = index.read_text()
    if '<section id="selection-summary">' in page:
        begin = page.index('<section id="selection-summary">')
        end = page.index('</section>', begin) + len('</section>')
        page = page[:begin] + body + page[end:]
    else:
        marker = '<table>'
        page = page.replace(marker, body + marker, 1)
    index.write_text(page)
    print(json.dumps({"baseline": baseline, "devRecallPreserving": guarded}, ensure_ascii=False))


def metrics(counts):
    intersection, predicted, target, protected, hit, groups, pages, capped = counts
    p = intersection / predicted if predicted else (1.0 if target == 0 else 0.0)
    r = intersection / target if target else None
    return {"envelopePrecisionProxy": p, "envelopeRecallProxy": r,
            "envelopeF1Proxy": 2*p*r/(p+r) if r is not None and p+r else (0.0 if r is not None else None),
            "targetGroupRecallAtHalfEnvelope": hit/groups if groups else None,
            "protectedOverlapPixels": protected, "predictedPixels": predicted, "targetPixels": target,
            "measuredPages": pages, "targetGroups": groups, "candidateLimitPages": capped}


def evaluate(all_text=False):
    started = time.monotonic()
    prefix = "alltext-" if all_text else ""
    request = read(OUT / "request.json")
    specification = read(OUT / "specification.json")
    assert sha(OUT / "request.json") == specification["requestSHA256"]
    assert sha(LABELS / "annotations.json") == specification["annotationsSHA256"]
    assert sha(ROUND / "selection.json") == specification["selectionSHA256"]
    labels = {r["id"]: r for r in read(LABELS / "annotations.json")}
    split = read(ROUND / "selection.json")
    dev = {r["id"] for r in split["dev"]}
    val = {r["id"] for r in split["validation"]}
    # Counts are accumulated on the same complete page set at every resolution.
    availability, failures, ready = {}, [], []
    for case in request["cases"]:
        ident = case["id"]
        paths = [Path(request["output"]) / str(side) / ident / "result.json" for side in request["sides"]]
        statuses = []
        for path in paths:
            value = read(path) if path.exists() else {}
            valid = value.get("status") == "complete" and value.get("requestSHA256") == specification["requestSHA256"]
            statuses.append(valid)
            if not valid:
                failures.append({"id": ident, "side": int(path.parent.parent.name),
                                 "status": value.get("status", "not-run"), "error": value.get("error")})
        availability[ident] = statuses
        if all(statuses):
            ready.append(case)
    totals = {}
    page_rows = []
    costs = {side: [] for side in request["sides"]}
    for page_index, case in enumerate(ready):
        ident = case["id"]
        annotation = labels[ident]
        targets = text_regions(annotation, all_text)
        ground = union_bits([r["polygon"] for r in targets])
        protected = union_bits([r["polygon"] for r in annotation["regions"] if r["kind"] == "protected"
                                and (not all_text or r.get("role") == "art")])
        group_polygons = {}
        for r in targets:
            group_polygons.setdefault(r["group_id"], []).append(r["polygon"])
        groups = [union_bits(p) for p in group_polygons.values()]
        groups = [g for g in groups if g]
        for side in request["sides"]:
            result = read(Path(request["output"]) / str(side) / ident / "result.json")
            assert result["sourceSHA256"] == case["sourceSHA256"]
            costs[side].append({k: result[k] for k in ["id", "detectorWallMs", "modelLoadMs", "modelWasAlreadyLoaded",
                "predictionMs", "preprocessMs", "searchMs", "processPeakRSSBytes"]})
            for variant in result["variants"]:
                ranked = sorted(variant["boxes"], key=lambda b: b["score"], reverse=True)
                predicted, cursor = 0, 0
                for confidence in reversed(BOX_THRESHOLDS):
                    while cursor < len(ranked) and ranked[cursor]["score"] >= confidence:
                        predicted |= polygon_bits(ranked[cursor]["polygon"])
                        cursor += 1
                    values = [(predicted & ground).bit_count(), predicted.bit_count(), ground.bit_count(),
                              (predicted & protected).bit_count(),
                              sum((predicted & g).bit_count() >= .5*g.bit_count() for g in groups), len(groups), 1,
                              int(variant["candidateLimitReached"])]
                    key = (side, variant["pixelThreshold"], variant["unclipRatio"], confidence)
                    buckets = ["all836"] + (["dev100"] if ident in dev else []) + (["historicalValidation40"] if ident in val else [])
                    for bucket in buckets:
                        total = totals.setdefault((key, bucket), [0]*8)
                        for i, value in enumerate(values):
                            total[i] += value
                    page_rows.append([ident, *key, *values])
        if (page_index+1) % 100 == 0:
            print(f"Scored {page_index+1}/{len(ready)} common pages", flush=True)
    ranked = []
    for key in sorted({key for key, bucket in totals}):
        row = {"side": key[0], "pixelThreshold": key[1], "unclipRatio": key[2], "boxThreshold": key[3]}
        row["metrics"] = {bucket: metrics(totals[(key, bucket)]) for bucket in
                          ["dev100", "historicalValidation40", "all836"] if (key, bucket) in totals}
        ranked.append(row)
    ranked.sort(key=lambda r: r["metrics"].get("dev100", {}).get("envelopeF1Proxy") or -1, reverse=True)
    cost_summary = {}
    for side, rows in costs.items():
        warm = [r for r in rows if r["modelWasAlreadyLoaded"]]
        cost_summary[side] = {"pages": len(rows), "warmPages": len(warm),
            "warmDetectorMedianMs": statistics.median(r["detectorWallMs"] for r in warm) if warm else None,
            "warmPredictionMedianMs": statistics.median(r["predictionMs"] for r in warm) if warm else None,
            "maxCumulativeProcessPeakRSSBytes": max((r["processPeakRSSBytes"] for r in rows), default=None),
            "scope": "Mac detector capture at pixel=.15/box=.01/unclip=1.4; model load and search excluded from warm detector time; model-loaded does not guarantee every shape is warm; RSS cumulative across sides"}
    per_side_best = {str(side): next((r for r in ranked if r["side"] == side), None) for side in request["sides"]}
    baseline = next((r for r in ranked if r["side"] == 960 and r["pixelThreshold"] == .15
                     and r["boxThreshold"] == .25 and r["unclipRatio"] == 1.4), None)
    report = {"status": "complete" if len(ready) == 836 else "partial", "manifestPages": 836,
        "commonMeasuredPages": len(ready), "unmeasuredPages": 836-len(ready),
        "metric": specification["metric"], "caveats": [specification["precisionCaveat"], specification["recallCaveat"]],
        "metricVersion": "all-source-text-envelope-v2" if all_text else "translation-target-envelope-v1",
        "labelScope": "all labelled source text including preserved SFX/background; protected-overlap counts art only" if all_text else "translation targets only; preserved text is outside target envelopes",
        "selection": specification["selection"], "ranking": ranked, "costs": cost_summary,
        "perSideDevBest": per_side_best, "referenceManga960": baseline,
        "failuresOrPending": failures, "evaluationSeconds": time.monotonic()-started,
        "recognitionAccuracy": None, "visualReview": "not performed", "mainParametersChanged": False,
        "inferenceImplementationSHA256": specification["implementationSHA256"]}
    save(OUT / (prefix + "evaluation.json"), report)
    save(OUT / (prefix + "page-metrics.json"), {"columns": ["id", "side", "pixel", "unclip", "box", "intersection", "predicted", "target",
        "protected", "hitGroups", "groups", "pages", "capped"], "rows": page_rows})
    if ranked:
        save(OUT / (prefix + "selected-dev-candidate.json"), {"selectionScope": "existing DEV100, detector envelope proxy only",
            "candidate": ranked[0], "requestSHA256": specification["requestSHA256"],
            "notFinalOCRSelection": "recognition and actual image review remain required"})
    body = []
    for row in ranked[:40]:
        m = row["metrics"]
        def number(bucket, field):
            value = m.get(bucket, {}).get(field)
            return f"{value:.4f}" if value is not None else "—"
        body.append("<tr>" + "".join(f"<td>{v}</td>" for v in [row["side"], row["pixelThreshold"], row["boxThreshold"],
            row["unclipRatio"], number("dev100", "envelopeF1Proxy"), number("all836", "envelopePrecisionProxy"),
            number("all836", "envelopeRecallProxy"), number("all836", "envelopeF1Proxy"),
            number("all836", "targetGroupRecallAtHalfEnvelope")]) + "</tr>")
    page = '<!doctype html><meta charset="utf-8"><title>Manga PP-OCR search</title><style>body{font:16px system-ui;margin:32px;background:#17191e;color:#eee}td,th{padding:9px;border:1px solid #555}table{border-collapse:collapse}a{color:#adceff}</style>'
    page += f"<h1>Manga PP-OCR 검출 파라미터 탐색</h1><p>동일 페이지 비교: {len(ready)}/836장 · 해상도 4개 · 조합 864개</p>"
    page += "<p>DEV100 영역 F1 대리지표 순위. 문단 여백을 포함한 silver 영역 평가이며 글자 인식 정확도·시각 검수·실기기 성능이 아님.</p>"
    if all_text:
        page += '<p>OCR 전체 문자: 대사·캡션·보존 효과음·배경 문자 모두 정답 영역에 포함. <a href="target-only-index.html">이전 번역대상 전용 지표</a>도 보존.</p>'
    page += '<table><tr><th>긴 변</th><th>픽셀</th><th>박스</th><th>확장</th><th>DEV F1 proxy</th><th>전체 P proxy</th><th>전체 R proxy</th><th>전체 F1 proxy</th><th>그룹 회수율</th></tr>' + ''.join(body) + '</table>'
    page += "<h2>호스트 비용</h2><pre>" + html.escape(json.dumps(cost_summary, indent=2, ensure_ascii=False)) + "</pre>"
    page += f'<p><a href="{prefix}evaluation.json">전체 평가와 미실행 목록</a> · <a href="specification.json">고정 실험 설정</a> · <a href="overlays.html">원본·검출 비교</a></p>'
    if all_text and (OUT / "index.html").exists() and not (OUT / "target-only-index.html").exists():
        (OUT / "target-only-index.html").write_text((OUT / "index.html").read_text())
    (OUT / "index.html").write_text(page)
    if ranked:
        overlays(request, ranked[0], baseline, page_rows, labels)
    print(json.dumps({"commonMeasuredPages": len(ready), "best": ranked[:1], "costs": cost_summary,
                      "report": str(OUT / "index.html")}, ensure_ascii=False), flush=True)


def overlays(request, winner, baseline, page_rows, labels):
    """Evidence browser, not a claim that images have been visually reviewed."""
    def key(candidate):
        return (candidate["side"], candidate["pixelThreshold"], candidate["unclipRatio"], candidate["boxThreshold"])
    selected = {row[0]: metrics(row[5:]) for row in page_rows if tuple(row[1:5]) == key(winner)}
    before = {row[0]: metrics(row[5:]) for row in page_rows if baseline and tuple(row[1:5]) == key(baseline)}
    valid = [ident for ident in selected if ident in before]
    delta = lambda ident: (selected[ident]["envelopeF1Proxy"] or 0) - (before[ident]["envelopeF1Proxy"] or 0)
    # Fixed seed for normal controls, plus objectively worst and most regressed.
    import random
    sample = random.Random(20261017).sample(valid, min(8, len(valid)))
    picks = list(dict.fromkeys(sorted(valid, key=delta)[:4] + sorted(valid, key=delta, reverse=True)[:4]
                              + sorted(valid, key=lambda i: selected[i]["envelopeF1Proxy"] or 0)[:4] + sample))
    sources = {r["id"]: r for r in request["cases"]}
    cards = []
    for ident in picks:
        source = sources[ident]
        width, height = source["dimensions"]
        blocks = []
        for title, candidate in [("원본", None), ("Manga 960 기본 검출", baseline), ("DEV 선택 후보", winner)]:
            polygons = []
            if candidate:
                data = read(Path(request["output"]) / str(candidate["side"]) / ident / "result.json")
                variant = next(v for v in data["variants"] if v["pixelThreshold"] == candidate["pixelThreshold"]
                               and v["unclipRatio"] == candidate["unclipRatio"])
                polygons = [b["polygon"] for b in variant["boxes"] if b["score"] >= candidate["boxThreshold"]]
            drawing = f'<svg viewBox="0 0 {width} {height}"><image width="{width}" height="{height}" href="{html.escape(Path(source["source"]).as_uri(), quote=True)}"/>'
            for points in polygons:
                coordinates = " ".join(f"{x*width:.2f},{y*height:.2f}" for x, y in points)
                drawing += f'<polygon points="{coordinates}" fill="#00e5ff" fill-opacity=".13" stroke="#00e5ff" stroke-width="{max(width,height)/700}"/>'
            drawing += '</svg>'
            blocks.append(f'<div><h3>{title}</h3>{drawing}</div>')
        cards.append(f'<section><h2>{ident} · 영역 F1 proxy 변화 {delta(ident):+.4f}</h2><div class="grid">' + ''.join(blocks) + '</div></section>')
    document = '<!doctype html><meta charset="utf-8"><title>Manga detector overlays</title><style>body{background:#17191e;color:#eee;font:16px system-ui;margin:20px}.grid{display:grid;grid-template-columns:repeat(3,1fr);gap:12px}svg{width:100%}section{border-top:1px solid #666;margin-top:30px}</style>'
    document += '<h1>원본 · 기본 검출 · 선택 후보</h1><p>동일 배율 전체 페이지. 자동 선정한 개선·회귀·최악·고정 난수 사례이며, 이 페이지 생성 자체는 시각 검수 완료가 아님.</p>' + ''.join(cards)
    (OUT / "overlays.html").write_text(document)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=["prepare", "evaluate", "evaluate-text", "prepare-recognition", "evaluate-recognition",
                                        "prepare-text-recognition", "evaluate-text-recognition", "summarize", "summarize-text"])
    args = parser.parse_args()
    {"prepare": prepare, "evaluate": evaluate, "prepare-recognition": prepare_recognition,
     "evaluate-recognition": evaluate_recognition, "summarize": summarize, "evaluate-text": lambda: evaluate(True),
     "prepare-text-recognition": lambda: prepare_recognition(True),
     "evaluate-text-recognition": lambda: evaluate_recognition(True), "summarize-text": lambda: summarize(True)}[args.phase]()
