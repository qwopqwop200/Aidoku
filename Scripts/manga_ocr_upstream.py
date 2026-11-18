#!/usr/bin/env python3
"""Source-pinned upstream Manga recipe comparison; no production settings change.

Uses the publisher's reviewed pure demo functions, removing only HTML/JPEG/UI
output. ONNX Runtime FP32 replaces OpenVINO FP16 and is explicitly reported.
The demo1120 variant changes the demo's 960 resize budget constants to 1120;
example960 follows the model repository's smaller standalone example.
"""
import argparse
import ast
import copy
import hashlib
import html
import json
from pathlib import Path
import resource
import statistics
import time
import unicodedata

import cv2
import numpy as np
import onnxruntime as ort
import pyclipper
from shapely.geometry import Polygon

import manga_ocr_search as shared

ort.disable_telemetry_events()

OUT = shared.OUT / "upstream"
REVISION = "8ee29e094b6aac77dd067c70805438782fa16ab0"
RECIPES = ["demo960", "demo1120", "example960"]
HASHES = {"det.onnx": "d132078c46e292b226fb5a2ca52a7612ad319262dfdf493e7d8e3be435295978",
          "rec.onnx": "de12c84c63e62c80339e882e675983d886670dcb6f0147e1ed041afd6fa81888",
          "dict.txt": "b5f2bfe2bdd9448429e3e82b51c789775d9b42f2403d082b00662eb77e401c5d"}


class Model:
    def __init__(self, path):
        options = ort.SessionOptions()
        options.intra_op_num_threads = 2
        options.inter_op_num_threads = 1
        options.enable_mem_pattern = False
        self.session = ort.InferenceSession(str(path), sess_options=options, providers=["CPUExecutionProvider"])
        self.shapes = []

    def __call__(self, tensor):
        self.shapes.append(list(tensor.shape))
        return self.session.run(None, {"x": tensor.astype(np.float32, copy=False)})


def demo_namespace(detector, recognizer, vocab, side):
    """Only named, inspected numeric/crop functions; never import the Gradio app."""
    code = (OUT / "source/demo-app.py").read_text()
    tree = ast.parse(code)
    allowed = {"rec_versions_for", "unclip_pp", "box_score_fast", "contains_kanji", "is_furigana_pair",
               "get_rotate_crop_image", "clean_manga_vertical_crop", "prepare_rec_input", "decode_ctc", "strip_punct",
               "_vert", "_thick", "_touch", "_order_lines", "sort_reading_order_v2", "run_ocr"}
    functions = [copy.deepcopy(n) for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in allowed]
    assert {n.name for n in functions} == allowed
    function = next(n for n in functions if n.name == "run_ocr")
    end = next(i for i, n in enumerate(function.body) if isinstance(n, ast.Assign)
               and any(isinstance(t, ast.Name) and t.id == "t_total" for t in n.targets))
    function.body = function.body[:end+1] + ast.parse(
        'return dict(raw=raw_boxes, lines=lines_data, detectorMs=t_det, recognitionMs=t_rec, '
        'totalMs=t_total, inputShape=[1,3,th,tw], orientationVertical=is_vertical)').body
    if side != 960:
        class Budget(ast.NodeTransformer):
            def visit_Constant(self, node):
                if isinstance(node.value, (int, float)) and node.value == 960:
                    return ast.copy_location(ast.Constant(value=float(side) if isinstance(node.value, float) else side), node)
                return node
        Budget().visit(function)
    numeric = ast.fix_missing_locations(ast.Module(body=functions, type_ignores=[]))
    namespace = {"cv2": cv2, "np": np, "pyclipper": pyclipper, "Polygon": Polygon, "time": time,
                 "unicodedata": unicodedata, "det_model": detector, "rec_models": {"v0.2": recognizer},
                 "vocab": vocab, "DEFAULT_REC_CHOICE": "v0.2"}
    exec(compile(numeric, "publisher-demo-reviewed-numeric-functions", "exec"), namespace)
    return namespace


def example_page(img_bgr, detector, recognizer, namespace, vocab):
    """Standalone example's resize/contour/unclip/axis-aligned crop/width rules."""
    h, w = img_bgr.shape[:2]
    ratio = min(1.0, (0.75*960.0*960.0/(h*w))**.5) if max(h,w)/min(h,w)>2 else 960.0/max(h,w)
    rh, rw = max(int(round(h*ratio/32)*32), 32), max(int(round(w*ratio/32)*32), 32)
    start = time.perf_counter()
    inp = cv2.resize(img_bgr, (rw,rh)).astype(np.float32)/255.0
    inp = (inp - np.array([.485,.456,.406])) / np.array([.229,.224,.225])
    tick = time.perf_counter()
    probability = detector(inp.transpose(2,0,1)[None])[0][0,0]
    detector_ms = (time.perf_counter()-tick)*1000
    contours, _ = cv2.findContours(((probability>.15)*255).astype(np.uint8), cv2.RETR_LIST, cv2.CHAIN_APPROX_SIMPLE)
    raw = []
    for contour in contours:
        points = contour.squeeze(1)
        if points.ndim != 2 or points.shape[0]<4:
            continue
        score = namespace["box_score_fast"](probability, points)
        if score < .25:
            continue
        x,y = points[:,0],points[:,1]
        area = .5*abs(np.dot(x,np.roll(y,-1))-np.dot(y,np.roll(x,-1)))
        perimeter = np.linalg.norm(np.roll(points,-1,axis=0)-points,axis=1).sum()
        if area<=0 or perimeter<=0:
            continue
        offset = pyclipper.PyclipperOffset()
        offset.AddPath(points.tolist(), pyclipper.JT_ROUND, pyclipper.ET_CLOSEDPOLYGON)
        paths = offset.Execute(area*1.4/perimeter)
        if len(paths)!=1:
            continue
        rect = cv2.minAreaRect(np.asarray(paths[0],dtype=np.float32))
        if min(rect[1])<3:
            continue
        box = cv2.boxPoints(rect).astype(np.float32)
        box[:,0] = np.clip(np.round(box[:,0]/rw*w),0,w)
        box[:,1] = np.clip(np.round(box[:,1]/rh*h),0,h)
        raw.append({"pts": box.tolist(), "score": float(score)})
    tick = time.perf_counter()
    lines = []
    for box in raw:
        points = np.asarray(box["pts"])
        x1,y1 = max(0,int(points[:,0].min())),max(0,int(points[:,1].min()))
        x2,y2 = min(w,int(points[:,0].max())),min(h,int(points[:,1].max()))
        crop = img_bgr[y1:y2,x1:x2]
        if crop.size==0:
            continue
        if crop.shape[0]>crop.shape[1]:
            crop = cv2.rotate(crop,cv2.ROTATE_90_COUNTERCLOCKWISE)
        natural = int(round(48.0*crop.shape[1]/max(1,crop.shape[0])))
        width = max(16,min(2400 if natural>2000 else 640,natural))
        inp = cv2.resize(crop,(width,48)).astype(np.float32)/255.0
        logits = recognizer(((inp-.5)/.5).transpose(2,0,1)[None])[0][0]
        indices = np.argmax(logits,axis=-1)
        text = ''.join(vocab[idx] for i,idx in enumerate(indices) if idx!=0 and (i==0 or idx!=indices[i-1]))
        lines.append({"pts": box["pts"], "text": text, "score": box["score"], "is_furigana": False})
    return {"raw":raw,"lines":lines,"detectorMs":detector_ms,"recognitionMs":(time.perf_counter()-tick)*1000,
            "totalMs":(time.perf_counter()-start)*1000,"inputShape":[1,3,rh,rw]}


def infer(limit=None):
    request = shared.read(shared.OUT / "request.json")
    for name, digest in HASHES.items():
        assert shared.sha(OUT / "models" / name) == digest, name
    specification = {"modelRevision": REVISION,"weightSHA256":HASHES,
        "demoSourceSHA256":shared.sha(OUT/"source/demo-app.py"),
        "exampleSourceSHA256":shared.sha(OUT/"source/onnx_openvino.py"),
        "runnerSHA256":shared.sha(Path(__file__)),"requestSHA256":shared.sha(shared.OUT/"request.json"),
        "recipes":RECIPES,"backend":"ONNX Runtime CPU FP32, 2 intra-op threads; publisher uses OpenVINO FP16",
        "packages":{"numpy":np.__version__,"opencv":cv2.__version__,"onnxruntime":ort.__version__},
        "settings":{"pixel":.15,"box":.25,"unclip":1.4,"recognitionHeight":48,"recognitionWidthRule":"640 or 2400 for natural width >2000"},
        "differences":{"demo960":"publisher pure numeric functions unchanged; UI tail omitted; backend FP32 ORT",
                       "demo1120":"same demo with resize budget 960 constants changed to1120; backend FP32 ORT",
                       "example960":"publisher standalone example logic, including axis-aligned crops; backend FP32 ORT"},
        "filterFurigana":"false as current demo default; true evaluated separately from saved flags",
        "scope":"all836; no labels during inference; no translation, RF or rendering"}
    fingerprint = hashlib.sha256(json.dumps(specification,sort_keys=True).encode()).hexdigest()
    shared.save(OUT/"specification.json",specification)
    started = time.perf_counter()
    detector, recognizer = Model(OUT/"models/det.onnx"),Model(OUT/"models/rec.onnx")
    load_ms = (time.perf_counter()-started)*1000
    vocab = ["blank"] + (OUT/"models/dict.txt").read_text().splitlines() + [" "]
    assert len(vocab)==18710
    namespaces = {side:demo_namespace(detector,recognizer,vocab,side) for side in [960,1120]}
    completed = failed = 0
    started = time.perf_counter()
    for recipe in RECIPES:
        directory = OUT/"predictions"/recipe
        directory.mkdir(parents=True,exist_ok=True)
        for case in request["cases"][:limit]:
            path = directory/(case["id"]+".json")
            if path.exists():
                old = shared.read(path)
                if old.get("fingerprint")==fingerprint and old.get("status")=="complete":
                    completed += 1
                    continue
            try:
                assert shared.sha(Path(case["source"]))==case["sourceSHA256"]
                img = cv2.imread(case["source"],cv2.IMREAD_COLOR)
                assert img is not None and list(img.shape[1::-1])==case["dimensions"]
                recognizer.shapes.clear()
                if recipe.startswith("demo"):
                    data = namespaces[int(recipe[4:])]["run_ocr"](cv2.cvtColor(img,cv2.COLOR_BGR2RGB))
                else:
                    data = example_page(img,detector,recognizer,namespaces[960],vocab)
                widths = [shape[-1] for shape in recognizer.shapes]
                shared.save(path,{"id":case["id"],"status":"complete","fingerprint":fingerprint,
                    "sourceSHA256":case["sourceSHA256"],"dimensions":case["dimensions"],"recipe":recipe,
                    "processPeakRSSBytes":resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
                    "recognitionWidths":widths,**data})
                completed += 1
            except Exception as error:
                failed += 1
                shared.save(path,{"id":case["id"],"status":"failed","fingerprint":fingerprint,"error":repr(error)})
                print(f"FAIL {recipe}/{case['id']}: {error}",flush=True)
            if (completed+failed)%20==0:
                progress = {"complete":completed,"failed":failed,"expected":len(request["cases"])*len(RECIPES),
                            "elapsedSeconds":time.perf_counter()-started,"modelLoadMs":load_ms,
                            "processPeakRSSBytes":resource.getrusage(resource.RUSAGE_SELF).ru_maxrss}
                shared.save(OUT/"progress.json",progress)
                print(f"Upstream {completed} complete, {failed} failed / {progress['expected']}",flush=True)
    shared.save(OUT/"progress.json",{"complete":completed,"failed":failed,"expected":len(request["cases"])*len(RECIPES),
        "elapsedSeconds":time.perf_counter()-started,"modelLoadMs":load_ms,
        "processPeakRSSBytes":resource.getrusage(resource.RUSAGE_SELF).ru_maxrss})


def evaluate():
    request = shared.read(shared.OUT/"request.json")
    labels = {r["id"]:r for r in shared.read(shared.LABELS/"annotations.json")}
    split = shared.read(shared.ROUND/"selection.json")
    dev = {r["id"] for r in split["dev"]}
    val = {r["id"] for r in split["validation"]}
    totals,costs,missing = {},{r:[] for r in RECIPES},[]
    fingerprint = hashlib.sha256(json.dumps(shared.read(OUT/"specification.json"),sort_keys=True).encode()).hexdigest()
    for case in request["cases"]:
        ident = case["id"]
        annotation = labels[ident]
        target = shared.text_regions(annotation,True)
        ground = shared.union_bits([r["polygon"] for r in target])
        protected = shared.union_bits([r["polygon"] for r in annotation["regions"] if r["kind"]=="protected" and r.get("role")=="art"])
        gp = {}
        for region in target:
            gp.setdefault(region["group_id"],[]).append(region["polygon"])
        groups = [shared.union_bits(p) for p in gp.values()]
        groups = [g for g in groups if g]
        for recipe in RECIPES:
            path = OUT/"predictions"/recipe/(ident+".json")
            row = shared.read(path) if path.exists() else {}
            if row.get("status")!="complete" or row.get("fingerprint")!=fingerprint:
                missing.append({"id":ident,"recipe":recipe,"error":row.get("error","not-run")})
                continue
            assert row["sourceSHA256"]==case["sourceSHA256"]
            cost = {k:row[k] for k in ["detectorMs","recognitionMs","totalMs","processPeakRSSBytes","recognitionWidths"]}
            bounds = []
            for b in row["raw"]:
                points = np.asarray(b["pts"])
                bounds.append([points[:,0].min(),points[:,1].min(),points[:,0].max(),points[:,1].max()])
            duplicates = 0
            for i,a in enumerate(bounds):
                for b in bounds[i+1:]:
                    intersection = max(0,min(a[2],b[2])-max(a[0],b[0]))*max(0,min(a[3],b[3])-max(a[1],b[1]))
                    union = (a[2]-a[0])*(a[3]-a[1])+(b[2]-b[0])*(b[3]-b[1])-intersection
                    duplicates += int(union>0 and intersection/union>=.8)
            cost.update(detectorBoxes=len(row["raw"]),nonemptyReadLines=sum(bool(l.get("text","").strip()) for l in row["lines"]),
                        furiganaFlaggedLines=sum(bool(l.get("is_furigana")) for l in row["lines"]),nearDuplicateBBoxPairs=duplicates)
            costs[recipe].append(cost)
            stages = ["detector","recognized"] + (["recognized-drop-furigana"] if recipe.startswith("demo") else [])
            for stage in stages:
                boxes = row["raw"] if stage=="detector" else [l for l in row["lines"] if l.get("text","").strip()
                    and (stage!="recognized-drop-furigana" or not l.get("is_furigana"))]
                w,h = case["dimensions"]
                predicted = shared.union_bits([[[x/w,y/h] for x,y in b["pts"]] for b in boxes])
                counts = [(predicted&ground).bit_count(),predicted.bit_count(),ground.bit_count(),
                    (predicted&protected).bit_count(),sum((predicted&g).bit_count()>=.5*g.bit_count() for g in groups),len(groups),1,0]
                shape_bucket = "longStrip5" if max(case["dimensions"])/min(case["dimensions"])>2 else "regular831"
                for bucket in ["all836",shape_bucket]+(["dev100"] if ident in dev else [])+(["historicalValidation40"] if ident in val else []):
                    total = totals.setdefault((recipe,stage,bucket),[0]*8)
                    for i,value in enumerate(counts): total[i] += value
    rows = []
    for recipe in RECIPES:
        row = {"recipe":recipe,"stages":{}}
        for stage in ["detector","recognized","recognized-drop-furigana"]:
            row["stages"][stage] = {b:shared.metrics(totals[(recipe,stage,b)]) for b in ["dev100","historicalValidation40","all836","longStrip5","regular831"]
                                    if (recipe,stage,b) in totals}
        values = costs[recipe]
        row["costs"] = {"pages":len(values),"medianDetectorModelMs":statistics.median(v["detectorMs"] for v in values) if values else None,
            "medianRecognitionMs":statistics.median(v["recognitionMs"] for v in values) if values else None,
            "medianWholeOCRMs":statistics.median(v["totalMs"] for v in values) if values else None,
            "maxCumulativeProcessPeakRSSBytes":max((v["processPeakRSSBytes"] for v in values),default=None),
            "linesWiderThan1184":sum(w>1184 for v in values for w in v["recognitionWidths"]),
            "detectorBoxes":sum(v["detectorBoxes"] for v in values),
            "nonemptyReadLines":sum(v["nonemptyReadLines"] for v in values),
            "furiganaFlaggedLines":sum(v["furiganaFlaggedLines"] for v in values) if recipe.startswith("demo") else None,
            "furiganaFilterSupported":recipe.startswith("demo"),
            "nearDuplicateBBoxPairs":sum(v["nearDuplicateBBoxPairs"] for v in values)}
        rows.append(row)
    native = shared.read(shared.OUT/"alltext-evaluation.json")
    report = {"status":"complete" if not missing else "partial","manifestPages":836,"recipes":rows,"missing":missing,
        "metric":"same all-source-text silver envelope proxy v2 at128px; no transcription GT, CER/WER null",
        "nativeReference":native["referenceManga960"],"nativeDevWinner":native["ranking"][0],
        "backendCaveat":"Reference FP32 ONNX Runtime CPU vs native FP16 CoreML. Timings cannot isolate algorithmic cost differences.",
        "mainParametersChanged":False,"CER":None,"WER":None}
    shared.save(OUT/"evaluation.json",report)
    body = '<!doctype html><meta charset="utf-8"><title>원본 Manga 설정 비교</title><style>body{font:16px system-ui;background:#17191e;color:#eee;margin:32px}table{border-collapse:collapse}td,th{padding:12px;border:1px solid #666}a{color:#adceff}</style><h1>원본 Manga 설정 · 현재 경로 비교</h1>'
    body += '<p>동일836장 · 원본0.15/0.25/1.4 · demo1120은 원본 데모의960 리사이즈 상수를1120으로 변경. 전체 문자 silver 영역 F1 대리지표이며 전사 정확도가 아님.</p>'
    body += '<table><tr><th>경로</th><th>단계</th><th>페이지</th><th>F1 proxy</th><th>P proxy</th><th>R proxy</th><th>그룹 회수율</th></tr>'
    display = []
    for title,row in [("현재 native960 권장 숫자",native["referenceManga960"]),("현재 native1184 DEV선택",native["ranking"][0])]:
        display.append((title,"detector",row["metrics"]["all836"]))
    for row in rows:
        for stage in ["detector","recognized","recognized-drop-furigana"]:
            if "all836" in row["stages"][stage]: display.append((row["recipe"],stage,row["stages"][stage]["all836"]))
    for title,stage,m in display:
        body += '<tr>'+''.join(f'<td>{v}</td>' for v in [title,stage,m["measuredPages"],f'{m["envelopeF1Proxy"]:.4f}',
            f'{m["envelopePrecisionProxy"]:.4f}',f'{m["envelopeRecallProxy"]:.4f}',f'{100*m["targetGroupRecallAtHalfEnvelope"]:.2f}%'])+'</tr>'
    body += '</table><p>원본 예제와 실제 데모는 서로 다른 경로. 데모는16px 흰 여백·회전 crop·후리가나/테두리 trim·읽기 순서를 사용. 후리가나 삭제는 기본off, 저장된 flags로on도 별도 평가.</p><p>영역 union 점수는 중복 박스를 벌점 처리하지 못하므로 박스 수와 bbox IoU≥0.8 중복 의심 쌍도 별도 기록.</p><p>ONNX Runtime CPU FP32와 Core ML FP16의 비용은 직접 같은 조건의 속도 비교가 아님.</p><h2>호스트 비용</h2><pre>'
    body += html.escape(json.dumps({r["recipe"]:r["costs"] for r in rows},ensure_ascii=False,indent=2))+'</pre><a href="evaluation.json">전체 평가</a> · <a href="specification.json">원본·설정 버전</a>'
    (OUT/"index.html").write_text(body)
    index = shared.OUT/"index.html"
    page = index.read_text()
    marker = '<section id="upstream-reference">'
    if marker in page: page = page[:page.index(marker)]
    page += marker+'<h2>원본 설정 비교</h2><a href="upstream/index.html">원본 예제960·실제 데모960/1120 비교표</a></section>'
    index.write_text(page)
    print(json.dumps({"status":report["status"],"recipes":[{"recipe":r["recipe"],"costs":r["costs"],"stages":r["stages"]} for r in rows]},ensure_ascii=False),flush=True)


def ablate_postprocessing():
    """Same saved native probability tensors; change ONLY the DB decoder."""
    tree = ast.parse((OUT/"source/onnx_openvino.py").read_text())
    functions = [n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name in ("box_score_fast","unclip")]
    loop = next(n for n in tree.body if isinstance(n,ast.For) and isinstance(n.target,ast.Name) and n.target.id=="cnt")
    namespace = {"np":np,"cv2":cv2,"pyclipper":pyclipper}
    exec(compile(ast.fix_missing_locations(ast.Module(body=functions,type_ignores=[])),"publisher-example-db-functions","exec"),namespace)
    decode = compile(ast.fix_missing_locations(ast.Module(body=[loop],type_ignores=[])),"publisher-example-db-loop","exec")
    native = shared.read(shared.OUT/"alltext-evaluation.json")
    candidates = {"native960-map-originalDB":native["referenceManga960"],"native1184-map-originalDB":native["ranking"][0]}
    labels = {r["id"]:r for r in shared.read(shared.LABELS/"annotations.json")}
    cases = shared.read(shared.OUT/"request.json")["cases"]
    split = shared.read(shared.ROUND/"selection.json")
    dev = {r["id"] for r in split["dev"]}
    validation = {r["id"] for r in split["validation"]}
    totals,rows = {},[]
    directory = OUT/"same-map-ablation"
    directory.mkdir(exist_ok=True)
    for case in cases:
        ident = case["id"]
        gt = shared.text_regions(labels[ident],True)
        ground = shared.union_bits([r["polygon"] for r in gt])
        protected = shared.union_bits([r["polygon"] for r in labels[ident]["regions"] if r["kind"]=="protected" and r.get("role")=="art"])
        gp = {}
        for r in gt: gp.setdefault(r["group_id"],[]).append(r["polygon"])
        groups = [shared.union_bits(p) for p in gp.values()]
        groups = [g for g in groups if g]
        w,h = case["dimensions"]
        for title,candidate in candidates.items():
            folder = shared.OUT/"predictions"/str(candidate["side"])/ident
            source = shared.read(folder/"result.json")
            assert source["sourceSHA256"]==case["sourceSHA256"]
            meta = source["map"]
            assert meta["originX"]==meta["originY"]==0
            assert meta["width"]==meta["fullWidth"] and meta["height"]==meta["fullHeight"]
            probability = np.fromfile(folder/"probability.f32",dtype="<f4").reshape(meta["height"],meta["width"])
            contours,_ = cv2.findContours(((probability>candidate["pixelThreshold"])*255).astype(np.uint8),cv2.RETR_LIST,cv2.CHAIN_APPROX_SIMPLE)
            values = dict(namespace,pred_map=probability,contours=contours,boxes=[],W=w,H=h,rw=meta["width"],rh=meta["height"],
                          thresh=candidate["pixelThreshold"],box_thresh=candidate["boxThreshold"],unclip_ratio=candidate["unclipRatio"])
            exec(decode,values)
            polygons = [[[float(x)/w,float(y)/h] for x,y in b] for b in values["boxes"]]
            predicted = shared.union_bits(polygons)
            counts = [(predicted&ground).bit_count(),predicted.bit_count(),ground.bit_count(),(predicted&protected).bit_count(),
                      sum((predicted&g).bit_count()>=.5*g.bit_count() for g in groups),len(groups),1,0]
            rows.append({"id":ident,"variant":title,"polygons":polygons,"counts":counts,
                         "sourceMapSHA256":hashlib.sha256(memoryview(probability).cast("B")).hexdigest()})
            for bucket in ["all836"]+(["dev100"] if ident in dev else [])+(["historicalValidation40"] if ident in validation else []):
                total = totals.setdefault((title,bucket),[0]*8)
                for i,v in enumerate(counts): total[i] += v
    report = {"scope":"same source and exact cached probability map; only DB postprocessor changed; no new inference",
              "metricVersion":"all-source-text-envelope-v2","pages":len(cases),"variants":[],"mainParametersChanged":False}
    for title,candidate in candidates.items():
        report["variants"].append({"variant":title,"settings":{k:candidate[k] for k in ("side","pixelThreshold","boxThreshold","unclipRatio")},
            "native":candidate["metrics"],"originalDB":{b:shared.metrics(totals[(title,b)]) for b in ["dev100","historicalValidation40","all836"]}})
    shared.save(directory/"evaluation.json",report)
    shared.save(directory/"page-results.json",rows)
    index = OUT/"index.html"
    page = index.read_text()
    page += '<h2>같은 확률맵에서 후처리만 바꾼 대조</h2><p>추론·입력·파라미터 고정, DB decoder만 원본 예제로 변경.</p><table><tr><th>맵</th><th>native F1 proxy</th><th>원본DB F1 proxy</th><th>native 그룹 회수율</th><th>원본DB 그룹 회수율</th></tr>'
    for row in report["variants"]:
        before,after = row["native"]["all836"],row["originalDB"]["all836"]
        page += '<tr>'+''.join(f'<td>{v}</td>' for v in [row["variant"],f'{before["envelopeF1Proxy"]:.4f}',f'{after["envelopeF1Proxy"]:.4f}',
            f'{100*before["targetGroupRecallAtHalfEnvelope"]:.2f}%',f'{100*after["targetGroupRecallAtHalfEnvelope"]:.2f}%'])+'</tr>'
    page += '</table><a href="same-map-ablation/evaluation.json">동일 맵 후처리 대조 상세</a>'
    index.write_text(page)
    print(json.dumps(report,ensure_ascii=False),flush=True)


if __name__=="__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase",choices=["infer","evaluate","ablate-postprocessing"])
    parser.add_argument("--limit",type=int)
    args = parser.parse_args()
    if args.phase=="infer": infer(args.limit)
    elif args.phase=="evaluate": evaluate()
    else: ablate_postprocessing()
