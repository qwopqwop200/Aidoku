#!/usr/bin/env python3
"""Hash-bound RF-DETR FP16 fixed-resolution full836 sweep and parent handoff.

Uses the frozen YOLO evaluator's silver/owner mapping helpers read-only.
No phone, app build, production edits, HTML or source/mask raster outputs.
Run with build/koharu-mobile/rfdetr-env/bin/python -B; --resume preserves pages.
"""
from __future__ import annotations

import argparse
from collections import Counter
import gc
import gzip
import hashlib
import json
import os
from pathlib import Path
import resource
import subprocess
import sys
import time
import traceback

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUT = ROOT / "build/koharu-mobile/rf-resolution"
THRESHOLDS = [0.25, 0.20, 0.50, 0.50]
SWEEP_THRESHOLDS = [0.25] * 4
SIZES = [648, 768, 864, 960, 1152]


def read(path):
    return json.loads(Path(path).read_text())


def write(path, value):
    path = Path(path)
    temporary = path.with_name(f"{path.name}.{os.getpid()}.partial")
    temporary.write_text(json.dumps(value, indent=2, allow_nan=False) + "\n")
    temporary.replace(path)


def sha(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def select(values, thresholds=THRESHOLDS, strict=False):
    """Stock top160 over all logits, including background, before thresholds."""
    import numpy as np
    import torch
    logits = torch.from_numpy(values["logits"][0])
    scores = logits.sigmoid()
    confidence, indices = torch.topk(scores.flatten(), 160)
    queries = torch.div(indices, logits.shape[-1], rounding_mode="floor")
    classes = indices % logits.shape[-1]
    limits = torch.tensor(thresholds + [float("inf")])[classes]
    keep = (classes < 4) & (confidence > limits if strict else confidence >= limits)
    queries, classes, confidence = queries[keep].numpy(), classes[keep].numpy(), confidence[keep].numpy()
    cxcywh = values["boxes"][0, queries]
    boxes = np.concatenate((cxcywh[:, :2] - cxcywh[:, 2:] / 2,
                            cxcywh[:, :2] + cxcywh[:, 2:] / 2), axis=-1)
    return {"queries": queries, "classes": classes, "scores": confidence, "boxes": boxes}


def mask(values, query, width, height):
    import torch
    with torch.inference_mode():
        logits = torch.from_numpy(values["instance_masks"][0, query].copy())[None, None]
        return (torch.nn.functional.interpolate(logits, size=(height, width),
                mode="bilinear", align_corners=False)[0, 0] > 0).numpy()


def selected_parity(reference, actual, width, height, bbox_min=.99, mask_min=.99, score_max=.005):
    """Class/box assignment, source-size mask IoU, explicit unmatched counts."""
    import numpy as np
    from scipy.optimize import linear_sum_assignment
    a, b = select(reference), select(actual)
    matches, counts = [], []
    for cls in range(4):
        ai, bi = np.flatnonzero(a["classes"] == cls), np.flatnonzero(b["classes"] == cls)
        matched = 0
        if len(ai) and len(bi):
            aa, bb = a["boxes"][ai], b["boxes"][bi]
            overlap = np.prod(np.maximum(np.minimum(aa[:, None, 2:], bb[None, :, 2:]) -
                                        np.maximum(aa[:, None, :2], bb[None, :, :2]), 0), axis=-1)
            areas_a = np.prod(np.maximum(aa[:, 2:] - aa[:, :2], 0), axis=-1)
            areas_b = np.prod(np.maximum(bb[:, 2:] - bb[:, :2], 0), axis=-1)
            ious = overlap / np.maximum(areas_a[:, None] + areas_b[None, :] - overlap, 1e-12)
            for i, j in zip(*linear_sum_assignment(-((ious >= 0.5) * 1000 + ious))):
                if ious[i, j] < 0.5:
                    continue
                ia, ib = int(ai[i]), int(bi[j])
                ma = mask(reference, int(a["queries"][ia]), width, height)
                mb = mask(actual, int(b["queries"][ib]), width, height)
                union = np.count_nonzero(ma | mb)
                matches.append({"class": cls, "stock_query": int(a["queries"][ia]),
                    "actual_query": int(b["queries"][ib]), "bbox_iou": float(ious[i, j]),
                    "mask_iou": float(np.count_nonzero(ma & mb) / union) if union else 1.0,
                    "score_abs_delta": float(abs(a["scores"][ia] - b["scores"][ib]))})
                matched += 1
        counts.append({"class": cls, "stock": len(ai), "actual": len(bi), "matched": matched,
                       "missed_stock": len(ai) - matched, "unmatched_actual": len(bi) - matched})
    n = len(a["queries"])
    passed = bool(n > 0 and all(c["missed_stock"] == c["unmatched_actual"] == 0 for c in counts)
                  and all(m["bbox_iou"] >= bbox_min and m["mask_iou"] >= mask_min
                          and m["score_abs_delta"] <= score_max for m in matches))
    return {"pass": passed, "counts": counts, "stock_count": n, "actual_count": len(b["queries"]),
            "match_coverage": len(matches) / n if n else None, "matches": matches,
            "bbox_iou_mean_matched": float(np.mean([m["bbox_iou"] for m in matches])) if matches else None,
            "mask_iou_mean_matched": float(np.mean([m["mask_iou"] for m in matches])) if matches else None,
            "gate": {"bbox_iou_min": bbox_min, "mask_iou_min": mask_min, "score_delta_max": score_max,
                     "missed_stock_max": 0, "unmatched_actual_max": 0}}


def helpers():
    # Import existing evaluator, without editing it or writing its output tree.
    import evaluate_koharu_yolo_836 as silver
    return silver


def polygonal_area(shape):
    """Keep every polygon/area, remove only zero-area members for area overlay."""
    from shapely import make_valid
    from shapely.geometry import GeometryCollection
    from shapely.ops import unary_union
    valid = make_valid(shape)
    def parts(value):
        if value.geom_type == "Polygon":
            return [value]
        return [part for child in getattr(value, "geoms", []) for part in parts(child)]
    polygons = parts(valid)
    result = unary_union(polygons) if polygons else GeometryCollection()
    if abs(result.area - valid.area) > max(1e-10, abs(valid.area) * 1e-12):
        raise ValueError("Polygon area changed during dimension normalization")
    return result, {"original_type": shape.geom_type, "valid_type": valid.geom_type,
                    "area_only_type": result.geom_type, "original_area": valid.area,
                    "result_area": result.area, "area_preserved": True,
                    "policy": "polygon extraction only; no precision grid, envelope, simplification or empty fallback"}


def decode(values, width, height, silver):
    """One source-size mask at a time; contours never saved as rasters."""
    from shapely import affinity
    from shapely.geometry import box
    selected = select(values, SWEEP_THRESHOLDS, strict=True)
    predictions = []
    # Public RF classes -> frozen evaluator primitive classes.
    class_mapping = {0: 1, 1: 3, 2: 2, 3: 0}
    for i, query in enumerate(selected["queries"]):
        cls = int(selected["classes"][i])
        contour, type_repair = polygonal_area(silver.mask_polygons(mask(values, int(query), width, height)))
        normalized = affinity.scale(contour, xfact=1 / width, yfact=1 / height, origin=(0, 0)).intersection(box(0, 0, 1, 1))
        prediction = {"id": i, "query": int(query), "rf_class": cls, "class": class_mapping[cls],
                      "score": float(selected["scores"][i]),
                      "box": box(*selected["boxes"][i]).intersection(box(0, 0, 1, 1)),
                      "mask_geometry": normalized, "area_dimension_normalization": type_repair}
        if cls == 2:
            prediction["safe_geometry"] = affinity.scale(contour.buffer(-2), xfact=1 / width,
                yfact=1 / height, origin=(0, 0)).intersection(box(0, 0, 1, 1))
        predictions.append(prediction)
    return predictions


def label_mask_metrics(label, predictions, silver):
    """Selected-positive polygon IoU, not exhaustive pixel segmentation GT."""
    import numpy as np
    from scipy.optimize import linear_sum_assignment
    result = {}
    targets = silver.selected_known_regions(label)
    for cls in (1, 3):
        known = [{**r, "geometry": polygonal_area(r["geometry"])[0]} for r in targets if r["class"] == cls]
        candidates = [p for p in predictions if p["class"] == cls]
        ious = np.asarray([[r["geometry"].intersection(p["mask_geometry"]).area /
                           max(r["geometry"].union(p["mask_geometry"]).area, 1e-12)
                           for p in candidates] for r in known])
        result[str(cls)] = {}
        for threshold in (0.5, 0.75):
            matches = []
            if known and candidates:
                for i, j in zip(*linear_sum_assignment(-((ious >= threshold) * 1000 + ious))):
                    if ious[i, j] >= threshold:
                        matches.append({"region_id": known[i]["region_id"], "group_id": known[i]["group_id"],
                            "prediction_id": candidates[j]["id"], "silver_polygon_mask_iou": float(ious[i, j])})
            matched_ids = {m["region_id"] for m in matches}
            result[str(cls)][str(threshold)] = {"known_silver_regions": len(known), "predictions": len(candidates),
                "matched": len(matches), "missed": len(known) - len(matches),
                "match_coverage": len(matches) / len(known) if known else None,
                "missed_region_ids": [r["region_id"] for r in known if r["region_id"] not in matched_ids],
                "matches": matches}
    return result


def page_union_proxy(label, predictions, silver):
    """No assignment: source-space union overlaps, expressly not gold masks."""
    result = {}
    regions = silver.selected_known_regions(label)
    for cls in (1, 3):
        target, target_type = polygonal_area(silver.geometry([r["geometry"] for r in regions if r["class"] == cls]))
        candidates = [p for p in predictions if p["class"] == cls]
        result[str(cls)] = {"known_positive_regions": sum(r["class"] == cls for r in regions)}
        for field in ("box", "mask_geometry"):
            predicted, predicted_type = polygonal_area(silver.geometry([p[field] for p in candidates]))
            overlap = target.intersection(predicted).area
            union = target.union(predicted).area
            result[str(cls)]["bbox" if field == "box" else "mask"] = {
                "union_overlap_iou_proxy": overlap / union if union else None,
                "known_label_area_coverage": overlap / target.area if target.area else None,
                "prediction_area_overlapping_known_label": overlap / predicted.area if predicted.area else None,
                "known_label_area": target.area, "predicted_union_area": predicted.area,
                "area_dimension_normalization": {"target": target_type, "prediction": predicted_type}}
    return {"classes": result, "authority": "Page union overlap with selected silver polygons only; not pixel-gold accuracy, precision, AP or complete primitive annotation"}


def handoff(output):
    """Supplement immutable conversion records with explicit failed gates."""
    variants = []
    import numpy as np
    for side in SIZES:
        run = output / str(side)
        if not (run / "conversion.json").exists():
            continue
        report = read(run / "conversion.json")
        failures = []
        for name, values in report.get("raw_stock_coreml", {}).items():
            limits = {"mean_abs": .002 if name == "boxes" else .05,
                      "max_abs": .02 if name == "boxes" else 1.0}
            for metric, limit in limits.items():
                if values[metric] > limit:
                    failures.append({"gate": "raw_query_row_numeric", "output": name,
                                     "metric": metric, "actual": values[metric], "limit": limit})
            if not values["finite"]:
                failures.append({"gate": "raw_finite", "output": name})
        selected = report.get("selected_stock_coreml", {})
        for count in selected.get("counts", []):
            if count["missed_stock"] or count["unmatched_actual"]:
                failures.append({"gate": "selected_count_correspondence", **count})
        for match in selected.get("matches", []):
            for metric, limit, direction in (("bbox_iou", .99, "min"), ("mask_iou", .99, "min"), ("score_abs_delta", .005, "max")):
                if (match[metric] < limit if direction == "min" else match[metric] > limit):
                    failures.append({"gate": "selected_operational_parity", "class": match["class"],
                        "stock_query": match["stock_query"], "actual_query": match["actual_query"],
                        "metric": metric, "actual": match[metric], "limit": limit, "direction": direction})
        diagnostic = {"side": side, "approved_for_quality_claim": False,
            "benchmark_use": "diagnostic only; no quality claim" if failures else "parity passed on one fixture; full836 and phone gates separate",
            "stock_fixed_shape_export_max_abs": {n: v["max_abs"] for n, v in report.get("stock_export_raw", {}).items()},
            "raw_parity_pass": report.get("raw_parity_pass"), "selected_parity_pass": selected.get("pass"),
            "selected_match_coverage": selected.get("match_coverage"), "failed_gates": failures,
            "raw_metric_limit": "Query-row order can change at encoder topk; raw max errors alone are not semantic geometry. Selected class/box/mask matching is recorded separately.",
            "semantic_mask_authority": "Predicted stock mask vs converted predicted mask is conversion parity, not GT segmentation accuracy"}
        write(run / "parity-failures.json", diagnostic)
        contract = read(run / "contract.json")
        width, height = contract["source_size_wh"]
        values = dict(np.load(run / "public-stock.npz"))
        selected = select(values)
        stock_selected = run / "public-stock-selected.npz"
        if not stock_selected.exists():
            masks = np.stack([mask(values, int(q), width, height) for q in selected["queries"]]) if len(selected["queries"]) else np.zeros((0, height, width), bool)
            np.savez_compressed(stock_selected, **selected, masks=masks)
        request_path = output / f"request-rf{side}-parity-gpu.json"
        if not request_path.exists():
            write(request_path, {"modelPath": f"KoharuRFDETRSeg2XLarge{side}FP16.mlmodelc",
                "computeUnits": "cpuAndGPU", "warmup": 0, "iterations": 1,
                "reportName": f"rf{side}-parity-gpu.json",
                "inputFiles": {"image": f"rf-resolution-{side}-public-input.f32"}, "dumpOutputs": True})
        variants.append({**diagnostic, "parent_handoff": str(run / "parent-handoff.json"),
                         "phone_parity_request": str(request_path),
                         "stock_selected_reference": str(stock_selected),
                         "stock_selected_reference_sha256": sha(stock_selected),
                         "phone_model_only_measurements": phone_measurements(output, side),
                         "host_benchmark": str(run / "host-model-only.json"),
                         "device_parity_command": f"build/koharu-mobile/rfdetr-env/bin/python -B Scripts/models/evaluate_koharu_rfdetr_resolution.py --device-side {side} --device-report {output}/rf{side}-parity-gpu.json"})
    previous = ROOT / "build/koharu-mobile/rf-parity-gpu-1839-evaluation.json"
    write(output / "parent-handoff-summary.json", {"variants": variants, "phone_owner": "parent exclusively",
        "integration_approved": False, "native1152_existing_device_control": {
            "path": str(previous), "sha256": sha(previous) if previous.exists() else None,
            "selected_parity_pass": read(previous).get("passed") if previous.exists() else None,
            "precision": "FP32DiagnosticChunked; distinct from current FP16 sweep", "reused_as_FP16_pass": False}})


def phone_measurements(output, side):
    """Parent-owned captures, read-only and input-bound, never imply quality."""
    rows = []
    contract_path = output / str(side) / "contract.json"
    if not contract_path.exists():
        return rows
    contract = read(contract_path)
    for path in sorted(output.glob(f"rf{side}-gpu20-*-device.json")):
        capture = read(path)
        input_rows = capture.get("input", [])
        verified = (capture.get("model") == f"KoharuRFDETRSeg2XLarge{side}FP16.mlmodelc"
            and len(input_rows) == 1 and input_rows[0].get("inputSHA256") == contract["input_sha256"]
            and input_rows[0].get("shape") == contract["input"]["shape"])
        rows.append({"report": str(path), "sha256": sha(path), "input_and_model_verified": verified,
            "status": capture.get("status"), "samples": capture.get("completedMeasuredIterations"),
            "median_model_ms": capture.get("medianMilliseconds"), "p95_model_ms": capture.get("p95Milliseconds"),
            "peak_process_footprint_bytes": max(capture.get("peakObservedPhysFootprintBytes", 0), capture.get("sampledPeakPhysFootprintBytes", 0)),
            "point_observed_peak_footprint_bytes": capture.get("peakObservedPhysFootprintBytes"),
            "sampled_peak_footprint_bytes": capture.get("sampledPeakPhysFootprintBytes"),
            "model_only_latency_gate": capture.get("steadyLatencyWithinBudget") if verified else None,
            "thermal_at_start": capture.get("thermalAtStart"),
            "thermal_states": capture.get("thermalStates"),
            "low_power_mode": capture.get("lowPowerMode"),
            "full_preprocess_decode_gate": None, "quality_approved": False,
            "scope": "Parent phone model-only GPU20; excludes source preprocess/decode; parity and full836 separate"})
    return rows


def evaluate_device(args):
    """Validate a parent capture's hashes/ABI then use stock selected matching."""
    import numpy as np
    from convert_koharu_rfdetr import metrics
    side = args.device_side
    run = args.output / str(side)
    report_path = args.device_report.resolve()
    capture = read(report_path)
    contract = read(run / "contract.json")
    if capture.get("status") != "completed" or capture.get("model") != f"KoharuRFDETRSeg2XLarge{side}FP16.mlmodelc":
        raise ValueError("Device capture status/model mismatch")
    inputs = capture.get("input", [])
    if len(inputs) != 1 or inputs[0].get("inputSHA256") != contract["input_sha256"] or inputs[0].get("shape") != contract["input"]["shape"]:
        raise ValueError("Device input checksum/shape mismatch")
    if inputs[0].get("dtype") != 65568 or inputs[0].get("fileDtype") != "float32":
        raise ValueError("Device input dtype mismatch")
    actual = {}
    for row in capture.get("dumpedOutputs", []):
        path = (report_path.parent / row["file"]).resolve()
        if not path.is_relative_to(report_path.parent) or sha(path) != row["SHA256"]:
            raise ValueError("Output path or checksum mismatch")
        name = row["name"]
        if row.get("dtype") != "float32":
            raise ValueError("Device dump dtype mismatch")
        if name in actual or name not in contract["outputs"] or row["shape"] != contract["outputs"][name]:
            raise ValueError("Device output ABI mismatch")
        values = np.fromfile(path, dtype="<f4")
        if len(values) != int(np.prod(row["shape"])):
            raise ValueError("Device output byte count mismatch")
        actual[name] = values.reshape(row["shape"])
        if not np.isfinite(actual[name]).all():
            raise ValueError("Nonfinite device outputs")
    if set(actual) != set(contract["outputs"]):
        raise ValueError("Incomplete device output dump")
    stock = dict(np.load(run / "public-stock.npz"))
    width, height = contract["source_size_wh"]
    result = {"side": side, "report": str(report_path), "report_sha256": sha(report_path),
        "source": "parent capture only; no device launched", "input_verified": True,
        "scope": "Device conversion parity to same-resolution stock predictions; not label segmentation accuracy",
        "selected_stock_device": selected_parity(stock, actual, width, height, .995, .995, .01),
        "raw_stock_device": {n: metrics(stock[n], actual[n]) for n in stock},
        "host_parity_is_separate": True, "integration_approved": False}
    directory = run / "device-parity"
    directory.mkdir(exist_ok=True)
    target = directory / f"{report_path.stem}-evaluation.json"
    if target.exists():
        raise ValueError("Existing device parity result preserved; use a unique capture name")
    write(target, result)
    print(json.dumps({"output": str(target), "selected_parity_pass": result["selected_stock_device"]["pass"]}), flush=True)


def benchmark_model_only(args):
    """Fresh CoreML process, without a Torch model or source/mask decoding."""
    import numpy as np
    import psutil
    import coremltools as ct
    run = args.output / str(args.benchmark_side)
    side = args.benchmark_side
    baseline = psutil.Process().memory_info().rss
    package = run / f"KoharuRFDETRSeg2XLarge{side}FP16.mlpackage"
    x = np.fromfile(run / "public-input.f32", dtype="<f4").reshape(1, 3, side, side)
    start = time.perf_counter()
    engine = ct.models.MLModel(str(package), compute_units=getattr(ct.ComputeUnit, args.compute_units))
    loading = time.perf_counter() - start
    times = []
    for _ in range(4):
        start = time.perf_counter()
        result = engine.predict({"image": x})
        times.append(time.perf_counter() - start)
        if not all(np.isfinite(value).all() for value in result.values()):
            raise ValueError("Nonfinite model benchmark outputs")
        del result
    peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    write(run / "host-model-only.json", {"side": side, "compute_units": args.compute_units,
        "scope": "macOS CoreML inference process; pre-normalized tensor, no source preprocessing, mask decode or Torch model construction; bridge import overhead included",
        "load_compile_seconds": loading, "first_model_seconds": times[0], "warm_model_seconds": times[1:],
        "warm_model_median_seconds": float(np.median(times[1:])), "baseline_process_rss_bytes": baseline,
        "process_peak_rss_bytes": peak, "host_proxy_model_gate": {
            "memory_under2GiB": peak <= 2 * 1024**3, "warm_median_under1sec": float(np.median(times[1:])) <= 1.0},
        "phone_gate_measured": False, "full_preprocess_decode_gate_measured_here": False})
    print(f"RF {side} isolated model benchmark complete", flush=True)


def finalize_comparison(args):
    """Audit complete RF records and adapt read-only YOLO r3 reference rows."""
    from PIL import Image
    silver = helpers()
    expected_ids = {f"{i:04d}" for i in range(1, 837)}
    integrity = read(args.dataset / "integrity.json")["files"]
    for name, expected in integrity.items():
        if sha(args.dataset / name) != expected:
            raise ValueError(f"Dataset integrity drift: {name}")
    manifest = {r["id"]: r for r in read(args.dataset / "manifest.json")}
    labels = {r["id"]: r for r in read(args.dataset / "annotations.json")}
    if set(manifest) != expected_ids or set(labels) != expected_ids:
        raise ValueError("Incomplete source/label ID denominator")
    bindings = {r["original_id"]: r for r in read(args.dataset / "validation.json")["source_bindings"]}
    sources = []
    for pid in sorted(expected_ids):
        row, label, binding = manifest[pid], labels[pid], bindings[pid]
        actual = sha(row["input_path"])
        with Image.open(row["input_path"]) as image:
            dimensions = list(image.size)
        if actual != row["input_sha256"] or dimensions != row["image_size"] or dimensions != label["image_size"]:
            raise ValueError(f"Source/coordinates drift: {pid}")
        if not row["source_geometry_eligible"] or not binding["source_geometry_eligible"] or row["input_path"] != binding["current_source_path"]:
            raise ValueError(f"Source binding ineligible: {pid}")
        sources.append({"id": pid, "source_sha256": actual, "size_wh": dimensions,
                        "source_identity_verification": row["source_identity_verification"]})
    counts = Counter(r["class"] for label in labels.values() for r in silver.selected_known_regions(label))
    snapshots, boundary, legacy = {}, [], {}
    for side in SIZES:
        run = args.output / str(side)
        paths = sorted((run / "pages").glob("*.json"))
        if {p.stem for p in paths} != expected_ids or read(run / "run.json")["status"] != "complete":
            raise ValueError(f"RF{side} not complete on all836")
        authority_sha = sha(run / "authority.json")
        records = [read(p) for p in paths]
        for record in records:
            if record["status"] != "complete" or record["source_expected_sha256"] != manifest[record["id"]]["input_sha256"] or record["authority_sha256"] != authority_sha:
                raise ValueError(f"RF{side} record provenance/status mismatch: {record['id']}")
            for prediction in record["predictions"]:
                if prediction["score"] == .25:
                    boundary.append({"side": side, "id": record["id"], "prediction": prediction["id"]})
            source_sha = record.get("evaluation_script_sha256")
            if source_sha:
                snapshot = Path(record["evaluation_source_snapshot"])
                if sha(snapshot) != source_sha:
                    raise ValueError("Recorded evaluator snapshot mismatch")
                snapshots[source_sha] = str(snapshot)
        legacy[str(side)] = sum("evaluation_script_sha256" not in r for r in records)
    if boundary:
        raise ValueError(f"Confidence boundary requires affected-page reanalysis: {boundary}")
    write(args.output / "source-binding-final-audit.json", {
        "status": "complete", "pages": 836, "RF_records": 4180,
        "source_hash_coordinate_binding_pass": True, "dataset_file_hashes": integrity,
        "known_positive_denominators": {"text": counts[1], "sfx": counts[3]},
        "source_coordinate_system": "normalized original source top-left x,y; source W,H verified",
        "confidence_exact_0_25_predictions": boundary, "legacy_ge_vs_strict_gt_effect": "none on all4180 actual records",
        "source_snapshots_verified": snapshots, "legacy_pages_without_own_evaluator_sha": legacy,
        "legacy_limit": "Initial RF648 code bytes were not captured before early edits. Records retain source/annotation/model authority; own-code SHA was not retroactively invented.",
        "label_authority": "agent visual/manual silver confirmed, not pixel gold", "sources": sources})
    rf_summary = summary(args.output)
    rows = []
    for variant in rf_summary["variants"]:
        side = variant["side"]
        data = variant["subsets"]["all"]
        classes = {}
        for name, cls in (("text_silver_region", "1"), ("sfx_silver_region", "3")):
            classes[name] = {"known_labels_full_denominator": counts[int(cls)], "thresholds": {}}
            for threshold in ("0.5", "0.75"):
                value = data["correspondence"][threshold][cls]
                classes[name]["thresholds"][threshold] = {
                    "bbox_matched": value["bbox_matched"], "bbox_missed": value["bbox_missed_evaluated"],
                    "bbox_correspondence_rate": value["bbox_match_coverage"],
                    "bbox_iou_matched_mean": value["bbox_iou_mean_matched"],
                    "bbox_iou_all_known_misses_zero": value["bbox_iou_sum_over_all_known_with_missed_zero"],
                    "mask_proxy_matched": value["mask_proxy_matched"], "mask_proxy_missed": value["mask_proxy_missed_evaluated"],
                    "mask_proxy_correspondence_rate": value["mask_match_coverage"],
                    "mask_proxy_iou_matched_mean": value["mask_polygon_iou_mean_matched"],
                    "mask_proxy_iou_all_known_misses_zero": value["mask_iou_sum_over_all_known_with_missed_zero"],
                    "mask_proxy_authority": "source-space mask contour/polygon area overlap; NOT pixel gold",
                    "primitive_gold_mask_iou": None, "primitive_gold_mask_iou_status": "missing_gold"}
        device_results = [read(p) for p in (args.output / str(side) / "device-parity").glob("*-evaluation.json")]
        rows.append({"family": "RF-DETR", "size": side, "pages_complete": 836, "page_errors": 0,
            "source_summary": str(args.output / "summary.json"), "compute_units": "CPU_ONLY",
            "confidence": .25, "matching": "classwise threshold-valid-count-first one-to-one Hungarian .5/.75",
            "classes": classes, "page_union_proxy_notgold": data["page_union_overlap_proxy_notgold"],
            "balloon_safe_interior_containment_coverage": data["balloon_safeinterior_containment_coverage"],
            "host_timings_seconds": data["timing_seconds"], "host_model_only_isolated": variant["isolated_host_model_benchmark"],
            "host_runtime_context": rf_summary["host_runtime_context"],
            "phone_GPU20_model_only": variant["phone_model_only_measurements"],
            "phone_selected_stock_parity": [{"report": r["report"], **r["selected_stock_device"]} for r in device_results],
            "full_phone_preprocess_decode_gate": None, "quality_approved": False})
    yolo_root = ROOT / "build/koharu-mobile/yolo/dataset836/resolution836-20261014-r3"
    reference = {"root": str(yolo_root), "read_only": True, "sizes": [512, 640, 960, 1280]}
    if (yolo_root / "authority.json").exists():
        yolo_authority = read(yolo_root / "authority.json")
        if yolo_authority["source_geometry_authority"] != integrity:
            raise ValueError("YOLO r3 and RF dataset authorities differ")
        reference.update(authority_sha256=sha(yolo_root / "authority.json"), matching=yolo_authority["matching"], raster=yolo_authority["raster"])
        for size in reference["sizes"]:
            path = yolo_root / f"{size}-cpu_ane/summary.json"
            if not path.exists():
                continue
            value = read(path)
            data = value["subsets"]["all"]
            classes = {}
            for name, cohort in data["classes"].items():
                classes[name] = {"known_labels_full_denominator": cohort["known_labels_full_split_denominator"], "thresholds": {}}
                for threshold, metric in cohort["thresholds"].items():
                    classes[name]["thresholds"][threshold] = {
                        "bbox_matched": metric["bbox_matched"], "bbox_missed": metric["bbox_unmatched_known_labels"],
                        "bbox_correspondence_rate": metric["bbox_correspondence_rate"],
                        "bbox_iou_matched_mean": metric["bbox_iou_matched"]["mean"],
                        "bbox_iou_all_known_misses_zero": metric["bbox_iou_mean_measured_known_with_misses_zero"],
                        "mask_proxy_matched": metric["mask_polygon_matched"], "mask_proxy_missed": metric["mask_polygon_unmatched_known_labels"],
                        "mask_proxy_correspondence_rate": metric["mask_polygon_correspondence_rate"],
                        "mask_proxy_iou_matched_mean": metric["mask_polygon_iou_matched"]["mean"],
                        "mask_proxy_iou_all_known_misses_zero": metric["mask_polygon_iou_mean_measured_known_with_misses_zero"],
                        "mask_proxy_authority": yolo_authority["raster"] + "; NOT pixel gold",
                        "primitive_gold_mask_iou": None, "primitive_gold_mask_iou_status": "missing_gold"}
            rows.append({"family": "YOLO", "size": size, "pages_complete": data["pages_complete"],
                "source_summary": str(path), "source_summary_sha256": sha(path), "compute_units": "CPU_AND_NE",
                "confidence": .25, "matching": yolo_authority["matching"], "classes": classes,
                "host_proxy_timing_ms": data["host_proxy_timing_ms"], "source_reference_only": True,
                "YOLO_quality_approval": "owned by Aquinas/parent, not assigned here"})
    write(args.output / "comparison-rows.json", {
        "status": "complete", "RF_pages_per_size": 836, "RF_records": 4180,
        "rows": rows, "YOLO_r3_reference": reference,
        "primitive_matching_comparison": "Text bbox cohorts share all3910 source-positive labels, confidence .25, classwise one-to-one .5/.75 and misses-zero averages. RF has an additional SFX cohort2679; YOLO r3 does not report it.",
        "mask_proxy_protocol_difference": "RF source-space continuous contour/polygon proxy differs from YOLO r3 rounded common1280 raster proxy; neither is pixel gold. Do not rank segmentation accuracy from these numbers.",
        "balloon_scope_difference": "RF owner-local safe-domain containment/coverage differs from YOLO r3 one-to-one selected safe-interior overlap; do not equate either to full balloon contour GT.",
        "host_vs_phone_units": "RF full836 CPU_ONLY; YOLO r3 CPU_AND_NE; RF parent phone CPU_AND_GPU20. Host contention/preprocessing/decoding and phone model-only timing remain separate.",
        "phone_gate_policy": "Use max(point-observed, sampled) footprint; >=20 model-only samples median/p95 <=1000ms are partial performance evidence. Full phone preprocessing/decode remains unmeasured; all5 RF FP16 strict selected parity failed.",
        "labels": "agent visual/manual silver confirmed, not pixel gold", "production_integration": False,
        "source_audit": str(args.output / "source-binding-final-audit.json"),
        "phone_parity_summary": str(args.output / "phone-parity-operational-summary.json")})
    print(f"RF all4180 records audited; comparison ready: {args.output / 'comparison-rows.json'}", flush=True)


def summary(output):
    import numpy as np
    variants = []
    ledger = output / "648" / "authority.json"
    labels = read(Path(read(ledger)["dataset"]) / "annotations.json") if ledger.exists() else []
    known_denominator = Counter()
    if labels:
        silver = helpers()
        for label in labels:
            known_denominator.update(r["class"] for r in silver.selected_known_regions(label))
    for side in SIZES:
        run = output / str(side)
        conversion = read(run / "conversion.json") if (run / "conversion.json").exists() else None
        records = [read(p) for p in sorted((run / "pages").glob("*.json"))]
        complete = [r for r in records if r["status"] == "complete"]
        subsets = {}
        for subset in ("all", "development", "heldout"):
            pages = [r for r in complete if subset == "all" or r["split"] == subset]
            cohort = {"pages_complete": len(pages), "correspondence": {}}
            for threshold in (0.5, 0.75):
                cohort["correspondence"][str(threshold)] = {}
                for cls in (1, 3):
                    rows = [c for p in pages for c in p["metrics"]["primitive_correspondence"][str(threshold)] if c["class"] == cls]
                    mask_rows = [p["mask_overlap_correspondence_proxy"][str(cls)][str(threshold)] for p in pages]
                    count = sum(r["known_silver_region_count"] for r in rows)
                    matched = sum(r["matched"] for r in rows)
                    mask_matched = sum(r["matched"] for r in mask_rows)
                    bbox_ious = [m["silver_bbox_iou"] for r in rows for m in r["matches"]]
                    mask_ious = [m["silver_polygon_mask_iou"] for r in mask_rows for m in r["matches"]]
                    cohort["correspondence"][str(threshold)][str(cls)] = {
                        "known_positive_regions_evaluated": count,
                        "full836_known_positive_denominator": known_denominator[cls] if subset == "all" else None,
                        "unevaluated_known_positive_regions": known_denominator[cls] - count if subset == "all" else None,
                        "bbox_matched": matched, "bbox_missed_evaluated": count - matched,
                        "bbox_match_coverage": matched / count if count else None,
                        "bbox_iou_mean_matched": float(np.mean(bbox_ious)) if bbox_ious else None,
                        "bbox_iou_sum_over_all_known_with_missed_zero": sum(bbox_ious) / count if count else None,
                        "mask_proxy_matched": mask_matched, "mask_proxy_missed_evaluated": count - mask_matched,
                        "mask_match_coverage": mask_matched / count if count else None,
                        "mask_polygon_iou_mean_matched": float(np.mean(mask_ious)) if mask_ious else None,
                        "mask_iou_sum_over_all_known_with_missed_zero": sum(mask_ious) / count if count else None,
                        "unmatched_predictions_unknown_gt": sum(len(r["unmatched_prediction_ids"]) for r in rows)}
            groups = [g for p in pages for g in p["metrics"]["groups"]]
            coverage = [g["model_text_bbox_source_coverage"] for g in groups if g["model_text_bbox_source_coverage"] is not None]
            cohort["ownership"] = {"target_groups": len(groups), "source_geometry_groups": len(coverage),
                "owner_states": dict(Counter(g["owner_state"] for g in groups)),
                "candidate_states": dict(Counter(g["candidate_state"] for g in groups)),
                "text_source_coverage_mean": float(np.mean(coverage)) if coverage else None,
                "text_source_coverage_counts": {str(t): sum(v >= t for v in coverage) for t in (0.5, 0.8, 0.985)},
                "source_coverage_loss_over_0_02": sum(g["baseline_source_coverage"] - g["candidate_source_coverage"] > .02
                    for g in groups if g["baseline_source_coverage"] is not None and g["candidate_source_coverage"] is not None),
                "groups_missing_balloon_match": sum(not g["selected_balloon_ids"] for g in groups),
                "group_owner_pairs": sum(g["same_silver_group_owner_pairs"] for g in groups),
                "pairs_sharing_balloon": sum(g["same_group_pairs_sharing_predicted_balloon"] for g in groups)}
            safe = [g for g in groups if g["candidate_outside_selected_safe_pixels2"] is not None]
            cohort["balloon_safeinterior_containment_coverage"] = {
                "authority": "Owner-local predicted safe domain vs labeled selected safe interior; not complete balloon contours or balloon segmentation accuracy",
                "groups_with_safe_label": sum(g["allowed_geometry_present"] for g in groups),
                "groups_measured": len(safe),
                "groups_missing_safe_correspondence": sum(g["allowed_geometry_present"] for g in groups) - len(safe),
                "outside_silver_safe_over16_source_px2_groups": sum(g["candidate_outside_selected_safe_pixels2"] > 16 for g in safe),
                "selected_safe_coverage_mean": float(np.mean([g["candidate_selected_safe_coverage"] for g in safe])) if safe else None,
                "source_coverage_mean": float(np.mean([g["candidate_source_coverage"] for g in safe if g["candidate_source_coverage"] is not None]))
                    if any(g["candidate_source_coverage"] is not None for g in safe) else None}
            cohort["page_union_overlap_proxy_notgold"] = {}
            for cls in (1, 3):
                cohort["page_union_overlap_proxy_notgold"][str(cls)] = {}
                for kind in ("bbox", "mask"):
                    rows = [p["page_union_overlap_proxy_notgold"]["classes"][str(cls)][kind] for p in pages]
                    eligible = [r for r in rows if r["known_label_area"] > 0]
                    cohort["page_union_overlap_proxy_notgold"][str(cls)][kind] = {
                        "pages_with_known_label_geometry": len(eligible),
                        "union_overlap_iou_proxy_mean": float(np.mean([r["union_overlap_iou_proxy"] for r in eligible])) if eligible else None,
                        "known_label_area_coverage_mean": float(np.mean([r["known_label_area_coverage"] for r in eligible])) if eligible else None}
            cohort["timing_seconds"] = {}
            for key in ("source_hash", "image_preprocess", "model_only", "mask_decode", "geometry_evaluation", "preprocess_model_decode", "page_total"):
                values = [p["timing_seconds"][key] for p in pages]
                cohort["timing_seconds"][key] = {"median": float(np.median(values)) if values else None,
                    "p95": float(np.percentile(values, 95)) if values else None, "total": sum(values)}
            subsets[subset] = cohort
        handle = read(run / "run.json") if (run / "run.json").exists() else {}
        variants.append({"side": side, "conversion_status": conversion.get("status") if conversion else "pending",
            "raw_parity_pass": conversion.get("raw_parity_pass") if conversion else None,
            "selected_parity_pass": conversion.get("selected_stock_coreml", {}).get("pass") if conversion else None,
            "pages_recorded": len(records), "pages_complete": len(complete), "pages_pending": 836 - len(records),
            "page_status_counts": dict(Counter(r["status"] for r in records)), "run": handle, "subsets": subsets,
            "page_code_provenance_counts": dict(Counter(r.get("evaluation_script_sha256", "legacy_not_captured") for r in records)),
            "repair_run": read(run / "repair-run.json") if (run / "repair-run.json").exists() else None,
            "isolated_host_model_benchmark": read(run / "host-model-only.json") if (run / "host-model-only.json").exists() else None,
            "phone_model_only_measurements": phone_measurements(output, side),
            "host_memory_scope": "CoreML full836 evaluator process; includes source decode and geometry; excludes conversion process",
            "phone_gate": {"measured": False, "max_bytes": 2 * 1024**3, "max_full_pipeline_seconds": 1.0,
                           "pass": None, "owner": "parent"}})
    complete = all(v["pages_complete"] == 836 for v in variants)
    result = {"status": "complete" if complete else "in_progress", "source_denominator": 836,
        "sizes": SIZES, "shape_policy": {"patch_size": 12, "windows": 2, "multiple": 24,
            "requested640": "unsupported; nearest648 used explicitly", "648_is_640": False},
        "variants": variants, "production_integration": False, "host_proxy_only": True,
        "authority": "Confirmed agent visual/manual silver bbox/polygon positives and owner groups; not human gold, exhaustive primitive GT, balloon outlines or pixel masks. Unmatched predictions are unknown GT, not false positives; no AP/precision claim.",
        "frozen_mapping": "RF0->YOLO1 text, RF1->YOLO3 SFX, RF2->YOLO2 bubble, RF3->YOLO0 panel; stock top160; sweep all-class confidence>.25 like YOLO; matching .5/.75. Earlier >=.25 pages had no exactly-.25 predictions (full-corpus boundary audit). Public stock parity separately uses recommended [.25,.20,.50,.50]. Frozen source-space 2px safe inset/owner probe padding.",
        "comparison_limit": "Use same RF836 mapping across sizes. YOLO letterbox and input-space 2px inset differ from RF stretch/source-space 2px; raw latency and safe-domain outcomes are not interchangeable.",
        "parity_limit": "Stock/CoreML conversion parity on pinned real public fixture at each size; full836 evaluates actual CoreML outputs even if parity fails. Export success never implies approved quality.",
        "original_MIT_pixelGT": {"used": False, "source_hash_verified_pixel_GT_found": False,
                                 "reason": "No original source-bound pixelGT has been established; silver polygons never substituted for it"},
        "phone_owner": "parent exclusively", "html_opened": False,
        "host_runtime_context": read(output / "host-runtime-context.json") if (output / "host-runtime-context.json").exists() else {"mode": "sequential"},
        "phone_operational_parity_summary": str(output / "phone-parity-operational-summary.json"),
        "resolution_quality_limit": "Full836 compares actual FP16 CoreML candidate outputs. Failed stock parity confounds resolution effects with conversion/precision effects; no pure-resolution accuracy or approved production-quality claim."}
    write(output / "summary.json", result)
    return result


def evaluate_side(args):
    import numpy as np
    import torch
    import torchvision.transforms.functional as TF
    import coremltools as ct
    import psutil
    from PIL import Image
    from convert_koharu_rfdetr import MEAN, STD
    silver = helpers()
    torch.set_num_threads(args.threads)
    side = args.side
    run = args.output / str(side)
    package = run / f"KoharuRFDETRSeg2XLarge{side}FP16.mlpackage"
    conversion = read(run / "conversion.json")
    script_sha = args.script_sha256
    snapshot = args.output / "source-snapshots" / f"evaluator-{script_sha}.py"
    snapshot.parent.mkdir(exist_ok=True)
    if not snapshot.exists():
        temporary_snapshot = snapshot.with_name(f"{snapshot.name}.{os.getpid()}.partial")
        temporary_snapshot.write_bytes(Path(__file__).read_bytes())
        temporary_snapshot.replace(snapshot)
    if sha(snapshot) != script_sha:
        raise ValueError("Evaluator source snapshot drift")
    history_path = run / "code-provenance-history.json"
    history = read(history_path) if history_path.exists() else []
    history.append({"started_unix": time.time(), "pid": os.getpid(), "script_sha256": script_sha,
        "source_snapshot": str(snapshot), "helper_sha256": sha(ROOT / "Scripts/models/evaluate_koharu_yolo_836.py"),
        "legacy_note": "Early RF648 process did not capture its own script bytes; preserved pages are explicitly legacy_not_captured, never assigned the current script SHA"})
    write(history_path, history)
    if conversion["status"] != "complete":
        raise ValueError("Conversion not complete")
    for relative, expected in conversion["package_sha256_files"].items():
        if sha(package / relative) != expected:
            raise ValueError("Package drift")
    if (run / "run.json").exists() and not args.resume:
        raise ValueError("Existing evaluation: use --resume")
    (run / "pages").mkdir(exist_ok=True)
    handle_path = run / ("repair-run.json" if args.repair_only else "run.json")
    handle = {"pid": os.getpid(), "side": side, "status": "preparing", "started_unix": time.time(),
              "compute_units": args.compute_units, "phone_measured": False}
    write(handle_path, handle)
    # Reuse exact dataset hashes, byte bindings, duplicate families and owner inventory.
    authority_args = argparse.Namespace(dataset=args.dataset, owners_run=args.owners_run,
                                        model=run / "planned-model-placeholder")
    if args.repair_only:
        authority = read(run / "authority.json")
        labels = {r["id"]: r for r in read(args.dataset / "annotations.json")}
        if sha(args.dataset / "annotations.json") != authority["verified_dataset_file_hashes"]["annotations.json"]:
            raise ValueError("Repair annotation drift")
        inventory = [r for r in read(run / "source-inventory.json")
                     if (run / "pages" / f"{r['id']}.json").exists()
                     and read(run / "pages" / f"{r['id']}.json")["status"] != "complete"]
        handle["repair_ids"] = [r["id"] for r in inventory]
    else:
        labels, manifest, inventory, authority = silver.load_authority(authority_args, run)
        authority["model"] = {"family": "RF-DETR", "side": side, "package": str(package), "conversion": str(run / "conversion.json"),
                          "compute_units": args.compute_units, "fp16_compute": True, "fp32_io": True,
                          "num_select": 160, "thresholds": SWEEP_THRESHOLDS, "confidence_comparison": "same0.25 as YOLO"}
        authority.pop("archived_RF", None)
        authority["policy_frozen_before_run"].update({"safe_inset": "2 source pixels for every RF size",
        "owner_probe_padding": "2 source pixels for every RF size", "mask_iou": "source-size predicted contour vs silver polygon; not pixel gold"})
        authority["RF_class_to_shared_evaluator_class"] = {"0": 1, "1": 3, "2": 2, "3": 0}
        write(run / "authority.json", authority)
    start = time.perf_counter()
    engine = ct.models.MLModel(str(package), compute_units=getattr(ct.ComputeUnit, args.compute_units))
    handle.update(status="running", load_compile_seconds=time.perf_counter() - start)
    write(handle_path, handle)
    signature = sha(run / "authority.json")
    try:
        for index, entry in enumerate(inventory):
            pid = entry["id"]
            page_path = run / "pages" / f"{pid}.json"
            if sha(Path(__file__)) != script_sha:
                raise RuntimeError("Evaluator source changed during execution; stop and resume from retained page records")
            previous = None
            if args.resume and page_path.exists():
                previous = read(page_path)
                if previous.get("authority_sha256") != signature:
                    raise ValueError("Resume authority drift")
                if previous["status"] == "complete":
                    continue
                # Retain failures before any authorized resumed retry.
                archive = run / "failures"
                archive.mkdir(exist_ok=True)
                write(archive / f"{pid}-{time.time_ns()}.json", previous)
            began = time.perf_counter()
            record = {"id": pid, "split": entry["split"], "duplicate_family": entry["duplicate_family"],
                "authority_sha256": signature, "source_expected_sha256": entry["expected_source_sha256"],
                "status": "pending", "evaluation_script_sha256": script_sha,
                "evaluation_source_snapshot": str(snapshot)}
            try:
                if not entry["source_exists"]:
                    record["status"] = "source_missing"
                elif not entry["source_geometry_eligible"] or not entry["binding_current_path_agrees"]:
                    record["status"] = "source_binding_ineligible"
                elif entry["source_size_wh"] != entry["label_size_wh"]:
                    record["status"] = "coordinate_mismatch"
                elif not entry["saved_owner_layout_exists"]:
                    record["status"] = "owner_geometry_missing"
                else:
                    start = time.perf_counter()
                    actual_hash = sha(entry["source_path"])
                    hash_seconds = time.perf_counter() - start
                    if actual_hash != entry["expected_source_sha256"]:
                        record["status"] = "source_hash_mismatch"
                    else:
                        saved_path = run / "prediction-geometry" / f"{pid}.json.gz"
                        saved = None
                        if saved_path.exists():
                            if previous and previous.get("prediction_geometry_sha256") and previous["prediction_geometry_sha256"] != sha(saved_path):
                                raise ValueError("Saved prediction checksum drift")
                            saved = json.loads(gzip.decompress(saved_path.read_bytes()))
                            if saved["source_sha256"] != actual_hash or saved["side"] != side or saved["confidence"] != SWEEP_THRESHOLDS or saved["authority_sha256"] != signature:
                                raise ValueError("Saved prediction provenance mismatch")
                        start = time.perf_counter()
                        if saved:
                            from shapely import from_wkb
                            width, height = saved["source_size_wh"]
                            predictions = []
                            for p in saved["predictions"]:
                                prediction = {k: v for k, v in p.items() if k not in ("box_wkb", "mask_wkb", "safe_wkb")}
                                shape, repair = polygonal_area(from_wkb(bytes.fromhex(p["mask_wkb"])))
                                prediction.update(box=from_wkb(bytes.fromhex(p["box_wkb"])), mask_geometry=shape,
                                                  area_dimension_normalization=repair)
                                if "safe_wkb" in p:
                                    prediction["safe_geometry"] = from_wkb(bytes.fromhex(p["safe_wkb"]))
                                predictions.append(prediction)
                            preprocess, inference, decoding = (saved["original_timing_seconds"][k] for k in ("image_preprocess", "model_only", "mask_decode"))
                            record["inference_reused_from_saved_geometry"] = True
                            record["orphan_geometry_recovered_after_native_exit"] = previous is None
                            record["geometry_reload_seconds"] = time.perf_counter() - start
                        else:
                            with Image.open(entry["source_path"]) as image:
                                rgb = image.convert("RGB")
                                width, height = rgb.size
                                if [width, height] != entry["source_size_wh"]:
                                    raise ValueError("Runtime source dimensions drift")
                                tensor = TF.normalize(TF.resize(TF.to_tensor(rgb), [side, side], antialias=True), MEAN, STD)[None]
                            x = np.ascontiguousarray(tensor.numpy(), dtype=np.float32)
                            preprocess = time.perf_counter() - start
                            start = time.perf_counter()
                            actual = engine.predict({"image": x})
                            inference = time.perf_counter() - start
                            if not all(np.isfinite(v).all() for v in actual.values()):
                                raise ValueError("Nonfinite CoreML outputs")
                            start = time.perf_counter()
                            predictions = decode(actual, width, height, silver)
                            decoding = time.perf_counter() - start
                            saved = {"side": side, "confidence": SWEEP_THRESHOLDS, "source_sha256": actual_hash,
                                "source_size_wh": [width, height], "coordinate_system": "normalized top-left source x,y",
                                "authority_sha256": signature, "evaluation_script_sha256": script_sha,
                                "original_timing_seconds": {"image_preprocess": preprocess, "model_only": inference, "mask_decode": decoding},
                                "predictions": [{**{k: v for k, v in p.items() if k not in ("box", "mask_geometry", "safe_geometry")},
                                    "box_wkb": p["box"].wkb_hex, "mask_wkb": p["mask_geometry"].wkb_hex,
                                    **({"safe_wkb": p["safe_geometry"].wkb_hex} if "safe_geometry" in p else {})} for p in predictions]}
                            saved_path.parent.mkdir(exist_ok=True)
                            temporary = saved_path.with_suffix(".partial")
                            temporary.write_bytes(gzip.compress(json.dumps(saved, allow_nan=False).encode(), mtime=0))
                            temporary.replace(saved_path)
                            del actual, tensor, x, rgb
                            record["inference_reused_from_saved_geometry"] = False
                        record["prediction_geometry_path"] = str(saved_path)
                        record["prediction_geometry_sha256"] = sha(saved_path)
                        record["prediction_geometry_source_script_sha256"] = saved["evaluation_script_sha256"]
                        start = time.perf_counter()
                        record["metrics"] = silver.page_metrics(labels[pid], predictions,
                            read(entry["saved_owner_layout_path"]), (1, 0, 0, width, height))
                        record["mask_overlap_correspondence_proxy"] = label_mask_metrics(labels[pid], predictions, silver)
                        record["page_union_overlap_proxy_notgold"] = page_union_proxy(labels[pid], predictions, silver)
                        evaluation = time.perf_counter() - start
                        record["predictions"] = [{"id": p["id"], "query": p["query"], "rf_class": p["rf_class"],
                            "class": p["class"], "score": p["score"], "bbox_xyxy_normalized": list(p["box"].bounds),
                            "mask_area_normalized": p["mask_geometry"].area,
                            "area_dimension_normalization": p.get("area_dimension_normalization")} for p in predictions]
                        record["timing_seconds"] = {"source_hash": hash_seconds, "image_preprocess": preprocess,
                            "model_only": inference, "mask_decode": decoding, "geometry_evaluation": evaluation,
                            "preprocess_model_decode": preprocess + inference + decoding,
                            "page_total": time.perf_counter() - began}
                        record["status"] = "complete"
                        del predictions
                        gc.collect()
            except Exception as error:
                record.update(status="failed", error=str(error), traceback=traceback.format_exc())
            record["host_rss_bytes"] = psutil.Process().memory_info().rss
            record["host_process_peak_rss_bytes"] = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
            write(page_path, record)
            entry["status"] = record["status"]
            handle.update(last_page=pid, pages_processed=index + 1,
                          host_process_peak_rss_bytes=record["host_process_peak_rss_bytes"], updated_unix=time.time())
            write(handle_path, handle)
            if index % 20 == 0 or index == 835:
                summary(args.output)
                print(f"RF {side} page {pid}/0836 {record['status']}", flush=True)
        handle.update(status="complete", finished_unix=time.time())
    except Exception:
        handle.update(status="failed", error=traceback.format_exc(), finished_unix=time.time())
        raise
    finally:
        write(handle_path, handle)
        if not args.repair_only:
            write(run / "source-inventory.json", inventory)
        summary(args.output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--dataset", type=Path, default=ROOT.parent / "labels/final-ensemble-recovered-20261013")
    parser.add_argument("--owners-run", type=Path, default=ROOT.parent / "output_dedup_manga_v6/optimization-current/main/current-improved-full836-v2-20261013")
    parser.add_argument("--compute-units", choices=("CPU_ONLY", "CPU_AND_GPU", "CPU_AND_NE", "ALL"), default="CPU_ONLY")
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument("--side", type=int, choices=SIZES)
    parser.add_argument("--resume", action="store_true")
    parser.add_argument("--repair-only", action="store_true", help="Snapshot and retry recorded failures, retaining previous error records and the active full-sweep handle")
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--summarize-only", action="store_true")
    parser.add_argument("--handoff-only", action="store_true")
    parser.add_argument("--benchmark-side", type=int, choices=SIZES)
    parser.add_argument("--device-side", type=int, choices=SIZES)
    parser.add_argument("--device-report", type=Path)
    parser.add_argument("--finalize-comparison", action="store_true")
    args = parser.parse_args()
    args.script_sha256 = sha(Path(__file__))
    args.output = args.output.resolve()
    if args.repair_only:
        if not args.side:
            parser.error("--repair-only requires --side")
        args.resume = True
    if not args.output.is_relative_to(DEFAULT_OUT):
        parser.error("Outputs must remain under build/koharu-mobile/rf-resolution")
    args.output.mkdir(parents=True, exist_ok=True)
    if args.finalize_comparison:
        finalize_comparison(args)
        return
    if args.device_report:
        if not args.device_side:
            parser.error("--device-report requires --device-side")
        evaluate_device(args)
        return
    if args.handoff_only:
        handoff(args.output)
        return
    if args.benchmark_side:
        benchmark_model_only(args)
        return
    if args.summarize_only:
        summary(args.output)
        return
    if args.side:
        evaluate_side(args)
        return
    # Separate converter and evaluator processes: export RSS is not inference RSS.
    write(args.output / "sweep.json", {"pid": os.getpid(), "status": "preparing", "started_unix": time.time(),
        "sizes": SIZES, "pages_per_side": 836, "compute_units": args.compute_units, "phone_owner": "parent"})
    try:
        for side in SIZES:
            report = args.output / str(side) / "conversion.json"
            if args.resume and report.exists() and read(report)["status"] == "complete":
                continue
            command = [sys.executable, "-B", str(ROOT / "Scripts/models/convert_koharu_rfdetr.py"),
                "--stage", "resolution", "--resolution", str(side), "--resolution-output", str(args.output),
                "--compute-units", args.compute_units, "--threads", str(args.threads)]
            directory = args.output / str(side)
            directory.mkdir(exist_ok=True)
            with (directory / "conversion.log").open("a") as log:
                subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
            summary(args.output)
            print(f"RF {side} model and parent handoff ready", flush=True)
        if not args.prepare_only:
            handle = read(args.output / "sweep.json")
            handle.update(status="evaluating", prepared_sizes=SIZES)
            write(args.output / "sweep.json", handle)
            for side in SIZES:
                command = [sys.executable, "-B", str(Path(__file__).resolve()), "--side", str(side),
                    "--output", str(args.output), "--dataset", str(args.dataset), "--owners-run", str(args.owners_run),
                    "--compute-units", args.compute_units, "--threads", str(args.threads)]
                if args.resume:
                    command.append("--resume")
                with (args.output / str(side) / "evaluation.log").open("a") as log:
                    subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
        handle = read(args.output / "sweep.json")
        handle.update(status="prepared" if args.prepare_only else "complete", finished_unix=time.time())
        write(args.output / "sweep.json", handle)
        summary(args.output)
    except Exception:
        handle = read(args.output / "sweep.json")
        handle.update(status="failed", error=traceback.format_exc(), finished_unix=time.time())
        write(args.output / "sweep.json", handle)
        raise


if __name__ == "__main__":
    main()
