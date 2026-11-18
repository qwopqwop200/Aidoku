#!/usr/bin/env python3
"""Full836 hash-bound silver-geometry YOLO1280 evaluation, numerical source inference only.

Run with build/koharu-mobile/yolo-env/bin/python -B. Shapely2.1.2 is installed
only under build/koharu-mobile/yolo/dataset836/dependencies. No source images,
composites, mask images, OCR/translation caches, renderer files or RF models
are generated/changed. Numeric page records are resumable and explicit.
"""

import argparse
import collections
import hashlib
import importlib.util
import itertools
import json
import math
import os
from pathlib import Path
import platform
import resource
import sys
import time
import traceback

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[2]
ROOT = REPO / "build/koharu-mobile/yolo/dataset836"
sys.path.insert(0, str(ROOT / "dependencies"))
import numpy as np
import cv2
from PIL import Image
import psutil
from shapely import affinity, make_valid
from shapely.geometry import Polygon, box, GeometryCollection
from shapely.ops import unary_union
from scipy.optimize import linear_sum_assignment


def read(path):
    return json.loads(path.read_text())


def write(path, value):
    path.write_text(json.dumps(value, indent=2, allow_nan=False)+"\n")


def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream,"sha256").hexdigest()


def geometry(parts):
    return unary_union([p for p in parts if not p.is_empty]) if parts else GeometryCollection()


def polygon(points):
    values = np.asarray(points,dtype=np.float64)
    if values.ndim != 2 or values.shape[1] != 2 or len(values) < 3 or not np.isfinite(values).all():
        raise ValueError("Invalid silver polygon")
    return make_valid(Polygon(values)).intersection(box(0,0,1,1))


def rect_xywh(values):
    x,y,w,h = map(float,values)
    if not all(math.isfinite(v) for v in (x,y,w,h)) or w <= 0 or h <= 0:
        raise ValueError("Invalid owner normalized rectangle")
    return box(x,y,x+w,y+h).intersection(box(0,0,1,1))


def ratio(intersection, denominator):
    return intersection.area/denominator.area if denominator.area > 0 else None


def resources(run):
    usage = resource.getrusage(resource.RUSAGE_SELF)
    return {"rss_bytes":psutil.Process().memory_info().rss,
            "process_max_rss_bytes":int(usage.ru_maxrss*(1 if platform.system()=="Darwin" else 1024)),
            "user_cpu_seconds":usage.ru_utime,"system_cpu_seconds":usage.ru_stime,
            "run_disk_bytes":sum(p.stat().st_size for p in run.rglob("*") if p.is_file()),
            "free_disk_bytes":psutil.disk_usage(str(run)).free}


def family_splits(manifest, bindings):
    parent = {pid:pid for pid in manifest}
    def find(pid):
        while parent[pid] != pid:
            parent[pid] = parent[parent[pid]]
            pid = parent[pid]
        return pid
    for binding in bindings:
        for other in binding["matching_current_ids"]:
            if other not in parent or binding["original_id"] not in parent:
                raise ValueError("Source-binding ID outside836")
            a,b = find(binding["original_id"]),find(other)
            parent[max(a,b)] = min(a,b)
    hashes = {}
    for pid,row in manifest.items():
        family = find(pid)
        hashes[family] = min(hashes.get(family,row["input_sha256"]),row["input_sha256"])
    return {pid:{"duplicate_family":find(pid),"family_source_hash":hashes[find(pid)],
                 "split":"heldout" if int(hashes[find(pid)][:8],16)%5==0 else "development"} for pid in manifest}


def load_authority(args, run):
    dataset = args.dataset.resolve()
    contract = read(dataset/"dataset.json")
    integrity = read(dataset/"integrity.json")
    verified = {}
    for name,expected in integrity["files"].items():
        path = dataset/name
        actual = sha(path)
        if actual != expected:
            raise ValueError(f"Permanent silver dataset integrity drift: {name}")
        verified[name] = actual
    annotations = read(dataset/"annotations.json")
    manifest_rows = read(dataset/"manifest.json")
    validation = read(dataset/"validation.json")
    labels = {r["id"]:r for r in annotations}
    manifest = {r["id"]:r for r in manifest_rows}
    expected_ids = {f"{i:04d}" for i in range(1,837)}
    if len(annotations)!=836 or len(manifest_rows)!=836 or set(labels)!=expected_ids or set(manifest)!=expected_ids:
        raise ValueError("Full source denominator must be exactly IDs0001..0836")
    bindings = {r["original_id"]:r for r in validation["source_bindings"]}
    splits = family_splits(manifest,validation["source_bindings"])
    baseline_path = REPO.parent/"output_dedup_manga_v6/optimization-current/label-evaluation/baseline-836.pages.json"
    baseline = {r["id"]:r for r in read(baseline_path)}
    split_disagreements = [pid for pid in labels if baseline[pid]["split"] != splits[pid]["split"]]
    if split_disagreements:
        raise ValueError(f"Preserved source-family split disagrees with baseline: {split_disagreements[:10]}")
    inventory = []
    role_counts = collections.Counter()
    for pid in sorted(labels):
        entry,label,binding = manifest[pid],labels[pid],bindings[pid]
        path = Path(entry["input_path"])
        region_counts = collections.Counter((r["kind"],r.get("role")) for r in label["regions"])
        role_counts.update(region_counts)
        layout_path = args.owners_run.resolve()/pid/"native-layout.json"
        inventory.append({"id":pid,**splits[pid],"source_path":str(path),"expected_source_sha256":entry["input_sha256"],
                          "source_exists":path.is_file(),"source_bytes":path.stat().st_size if path.is_file() else None,
                          "source_size_wh":entry["image_size"],"label_size_wh":label["image_size"],
                          "source_identity_verification":entry["source_identity_verification"],
                          "source_geometry_eligible":entry["source_geometry_eligible"] and binding["source_geometry_eligible"],
                          "binding_current_path_agrees":str(path)==binding["current_source_path"],
                          "matching_source_ids":binding["matching_current_ids"],"source_hash_status":"pending_runtime_byte_validation",
                          "label_tier":label.get("label_tier"),"human_verified":label.get("human_verified"),
                          "silver_regions":len(label["regions"]),"silver_groups":len(label["groups"]),
                          "region_kind_role_counts":{f"{k[0]}:{k[1]}":v for k,v in region_counts.items()},
                          "saved_owner_layout_path":str(layout_path),"saved_owner_layout_exists":layout_path.is_file(),
                          "status":"planned"})
    authority = {"dataset":str(dataset),"contract":contract,"verified_dataset_file_hashes":verified,
                 "script_sha256":sha(Path(__file__)),"owners_run":str(args.owners_run.resolve()),
                 "baseline_split_ledger":str(baseline_path),"baseline_split_ledger_sha256":sha(baseline_path),
                 "split_method":"Preserved RGB duplicate-binding families, minimum family manifest SHA prefix modulo5; matches existing baseline. Diagnostic heldout, not guaranteed historically unseen.",
                 "split_counts":dict(collections.Counter(v["split"] for v in splits.values())),
                 "duplicate_families":len(set(v["duplicate_family"] for v in splits.values())),
                 "source_bytes_total":sum(r["source_bytes"] or 0 for r in inventory),
                 "region_kind_role_counts":{f"{k[0]}:{k[1]}":v for k,v in role_counts.items()},
                 "known_missing_primitive_gt":["frame primitives","complete balloon contours","complete class-exhaustive detection labels","pixel segmentation masks","current render defects"],
                 "label_ownership_vs_primitive_correspondence":"must_cover/allowed/protected groups are label ownership; YOLO frame/text/balloon/SFX are primitives. Safe interiors are not balloon outlines. Old layout_item_ids never reused as current identity.",
                 "model":{"package":str(args.model.resolve()),"package_sha256_files":{str(p.relative_to(args.model)):sha(p) for p in args.model.rglob("*") if p.is_file()},
                          "size":1280,"fp16_compute":True,"fp32_io":True,"compute_units":"CPU_AND_NE","placement":"Allowed units, not per-operation ANE proof",
                          "one2one":True,"conf":0.25,"max_det":300,"nms":False},
                 "policy_frozen_before_run":{"primitive_box_iou_thresholds":[0.5,0.75],"owner_mapping_target_fraction":0.20,"owner_mapping_owner_fraction":0.40,
                                             "owner_balloon_mask_coverage":0.80,"balloon_safe_inset_input_pixels":2,"local_owner_probe_padding_input_pixels":2,
                                             "source_coverage_thresholds":[0.5,0.8,0.985]},
                 "archived_RF":{"836_source_bound_statistics_available":False,"status":"not provided/found in scoped RF artifact index; no RF model rerun",
                                "public_phone_reference_only":str(REPO/"build/koharu-mobile/rf-parity-gpu-1839-evaluation.json"),"user_latency_candidate_excluded":True},
                 "outputs":"Numeric JSON only. No source pixels, images, composites, OCR text, translation or model mask rasters saved."}
    write(run/"authority.json",authority)
    write(run/"source-inventory.json",inventory)
    return labels,manifest,inventory,authority


def preprocess(rgb):
    height,width = rgb.shape[:2]
    gain = min(1280/height,1280/width)
    nw,nh = round(width*gain),round(height*gain)
    left,right = round((1280-nw)/2-0.1),round((1280-nw)/2+0.1)
    top,bottom = round((1280-nh)/2-0.1),round((1280-nh)/2+0.1)
    resized = cv2.resize(rgb,(nw,nh),interpolation=cv2.INTER_LINEAR) if (nw,nh)!=(width,height) else rgb
    padded = cv2.copyMakeBorder(resized,top,bottom,left,right,cv2.BORDER_CONSTANT,value=(114,114,114))
    return np.ascontiguousarray(padded.transpose(2,0,1)[None],dtype=np.float32)/255.,(gain,left,top,width,height)


def top300(actual):
    boxes,scores,coefficients = (actual[k][0] for k in ("boxes","scores","mask_coefficients"))
    anchors = np.argsort(-scores.max(axis=1),kind="stable")[:300]
    pairs = np.argsort(-scores[anchors].reshape(-1),kind="stable")[:300]
    indices,classes = anchors[pairs//4],pairs%4
    confidence = scores[indices,classes]
    kept = confidence>0.25
    return boxes[indices[kept]],confidence[kept],classes[kept],coefficients[indices[kept]],indices[kept]


def mask_polygons(mask):
    contours,hierarchy = cv2.findContours(mask.astype(np.uint8),cv2.RETR_CCOMP,cv2.CHAIN_APPROX_SIMPLE)
    if hierarchy is None:
        return GeometryCollection()
    parts = []
    for i,contour in enumerate(contours):
        if hierarchy[0,i,3] != -1 or len(contour)<3:
            continue
        holes = []
        child = hierarchy[0,i,2]
        while child != -1:
            if len(contours[child])>=3:
                holes.append(contours[child][:,0,:].tolist())
            child = hierarchy[0,child,0]
        parts.append(make_valid(Polygon(contour[:,0,:],holes)))
    return geometry(parts)


def normalized_shape(shape, mapping):
    gain,left,top,width,height = mapping
    return affinity.scale(affinity.translate(shape,xoff=-left,yoff=-top),xfact=1/(gain*width),yfact=1/(gain*height),origin=(0,0)).intersection(box(0,0,1,1))


def decode(actual, mapping):
    import torch
    from torch.nn import functional as F
    boxes,scores,classes,coefficients,anchors = top300(actual)
    prototypes = np.ascontiguousarray(actual["mask_prototypes"][0],dtype=np.float32).reshape(32,-1)
    predictions = []
    for start in range(0,len(boxes),4):
        stop = min(start+4,len(boxes))
        logits = (coefficients[start:stop]@prototypes).reshape(-1,320,320)
        crop_boxes = np.maximum(0,np.rint(boxes[start:stop]/4)).astype(int)
        # Pinned CPU stock crop switches at50 detections. Preserve both paths.
        if len(boxes)<50:
            for j,(x1,y1,x2,y2) in enumerate(crop_boxes):
                logits[j,:y1]=0; logits[j,y2:]=0
                logits[j,:,:x1]=0; logits[j,:,x2:]=0
        else:
            xx = np.arange(320)[None,None,:]
            yy = np.arange(320)[None,:,None]
            b = boxes[start:stop]/4
            logits *= ((xx>=b[:,0,None,None])&(xx<b[:,2,None,None])&(yy>=b[:,1,None,None])&(yy<b[:,3,None,None]))
        with torch.inference_mode():
            full = F.interpolate(torch.from_numpy(logits)[None],size=(1280,1280),mode="bilinear",align_corners=False)[0].numpy()>0
        for j,mask in enumerate(full):
            i = start+j
            if not mask.any():
                continue
            native_box = box(*boxes[i])
            item = {"id":len(predictions),"anchor":int(anchors[i]),"class":int(classes[i]),"score":float(scores[i]),
                    "box":normalized_shape(native_box,mapping)}
            if int(classes[i]) == 2:
                contour = mask_polygons(mask)
                item["mask_geometry"] = normalized_shape(contour,mapping)
                item["safe_geometry"] = normalized_shape(contour.buffer(-2),mapping)
            predictions.append(item)
    return predictions


def selected_known_regions(label):
    result = []
    for row in label["regions"]:
        cls = 1 if row["kind"]=="must_cover" and row.get("role") in ("dialogue","caption") else 3 if row.get("role")=="sfx" and row["kind"] in ("must_cover","protected") else None
        if cls is not None:
            result.append({"region_id":row["id"],"group_id":row["group_id"],"class":cls,"kind":row["kind"],"role":row["role"],
                           "confidence":row.get("confidence"),"geometry":polygon(row["polygon"])})
    return result


def correspondence(regions,predictions,threshold):
    rows = []
    for cls in (1,3):
        target = [r for r in regions if r["class"]==cls]
        candidates = [p for p in predictions if p["class"]==cls]
        matches = []
        matched_targets,matched_predictions = set(),set()
        if target and candidates:
            ious = np.asarray([[r["geometry"].envelope.intersection(p["box"]).area/max(r["geometry"].envelope.union(p["box"]).area,1e-12) for p in candidates] for r in target])
            reward = (ious>=threshold)*1000.+ious
            for i,j in zip(*linear_sum_assignment(-reward)):
                if ious[i,j]>=threshold:
                    matched_targets.add(i);matched_predictions.add(j)
                    matches.append({"region_id":target[i]["region_id"],"group_id":target[i]["group_id"],"prediction_id":candidates[j]["id"],
                                    "silver_bbox_iou":float(ious[i,j]),"confidence":target[i]["confidence"]})
        rows.append({"class":cls,"known_silver_region_count":len(target),"prediction_count":len(candidates),"matched":len(matches),
                     "unmatched_silver_region_ids":[r["region_id"] for i,r in enumerate(target) if i not in matched_targets],
                     "unmatched_prediction_ids":[p["id"] for j,p in enumerate(candidates) if j not in matched_predictions],
                     "unmatched_predictions_authority":"not false positives; selected silver regions are not exhaustive primitive GT",
                     "matches":matches})
    return rows


def owner_mapping(label,owners):
    by_group = collections.defaultdict(lambda:collections.defaultdict(list))
    for region in label["regions"]:
        by_group[region["group_id"]][region["kind"]].append(polygon(region["polygon"]))
    groups = []
    for group in label["groups"]:
        if not group["target"]:
            continue
        source = geometry(by_group[group["id"]]["must_cover"])
        allowed = geometry(by_group[group["id"]]["allowed"])
        matching = []
        if source.area > 0:
            for oid,owner in owners.items():
                overlap = source.intersection(owner).area
                if overlap>0 and (overlap/source.area>=0.20 or overlap/owner.area>=0.40):
                    matching.append(oid)
        groups.append({"id":group["id"],"kind":group["kind"],"source":source,"allowed":allowed,"owner_ids":matching,
                       "state":"label_geometry_missing" if source.is_empty else "current_owners_matched" if matching else "current_owner_unmatched"})
    return groups


def page_metrics(label,predictions,layout,mapping):
    regions = selected_known_regions(label)
    owners = {str(i["id"]):rect_xywh(i["sourceBounds"]) for i in layout["items"] if not i.get("keptLettering",False) and isinstance(i.get("sourceBounds"),list) and len(i["sourceBounds"])==4}
    kept_count = sum(bool(i.get("keptLettering")) for i in layout["items"])
    balloons = [p for p in predictions if p["class"]==2 and not p["mask_geometry"].is_empty]
    gain,left,top,width,height = mapping
    selectors,local_domains,baseline_domains = {},{},{}
    pad_x,pad_y = 2/(gain*width),2/(gain*height)
    for oid,owner in owners.items():
        possible = [(p["mask_geometry"].area,p) for p in balloons if ratio(owner.intersection(p["mask_geometry"]),owner)>=0.80]
        selected = min(possible,key=lambda item:(item[0],item[1]["id"]))[1] if possible else None
        selectors[oid] = selected["id"] if selected is not None else None
        x1,y1,x2,y2 = owner.bounds
        baseline = box(x1-pad_x,y1-pad_y,x2+pad_x,y2+pad_y).intersection(box(0,0,1,1))
        baseline_domains[oid] = baseline
        local_domains[oid] = baseline.intersection(selected["safe_geometry"]) if selected is not None else GeometryCollection()
    protected = geometry([polygon(r["polygon"]) for r in label["regions"] if r["kind"]=="protected"])
    group_rows = []
    for group in owner_mapping(label,owners):
        source,allowed,ids = group["source"],group["allowed"],group["owner_ids"]
        label_source = source if source.area>0 else None
        predicted_ids = [p["id"] for p in predictions if p["class"]==1 and label_source is not None and source.intersection(p["box"]).area>0 and
                         (source.intersection(p["box"]).area/source.area>=.20 or source.intersection(p["box"]).area/max(p["box"].area,1e-12)>=.40)]
        predicted_source = geometry([p["box"] for p in predictions if p["id"] in predicted_ids])
        candidate = geometry([local_domains[oid] for oid in ids])
        baseline = geometry([baseline_domains[oid] for oid in ids])
        container_ids = [selectors[oid] for oid in ids if selectors[oid] is not None]
        pairs = list(itertools.combinations(ids,2))
        colocated = sum(selectors[a] is not None and selectors[a]==selectors[b] for a,b in pairs)
        group_rows.append({"group_id":group["id"],"kind":group["kind"],"owner_state":group["state"],"owner_ids":ids,
                           "owner_count":len(ids),"model_text_primitive_ids":predicted_ids,
                           "model_text_bbox_source_coverage":ratio(source.intersection(predicted_source),source) if source.area>0 else None,
                           "selected_balloon_ids":sorted(set(container_ids)),"owner_balloon_assignments":{oid:selectors[oid] for oid in ids},
                           "same_silver_group_owner_pairs":len(pairs),"same_group_pairs_sharing_predicted_balloon":colocated,
                           "allowed_geometry_present":allowed.area>0,"source_safe_silver_infeasible":not allowed.covers(source) if allowed.area>0 and source.area>0 else None,
                           "candidate_state":"selected_owner_local_balloon_domain" if container_ids else "no_predicted_balloon_owner_match" if ids else "current_owner_unmatched",
                           "baseline_source_coverage":ratio(source.intersection(baseline),source) if source.area>0 and ids else None,
                           "candidate_source_coverage":ratio(source.intersection(candidate),source) if source.area>0 and container_ids else None,
                           "candidate_area_source_pixels2":candidate.area*width*height if container_ids else None,
                           "candidate_outside_selected_safe_fraction":ratio(candidate.difference(allowed),candidate) if allowed.area>0 and candidate.area>0 else None,
                           "candidate_outside_selected_safe_pixels2":candidate.difference(allowed).area*width*height if allowed.area>0 and container_ids else None,
                           "baseline_outside_selected_safe_pixels2":baseline.difference(allowed).area*width*height if allowed.area>0 and ids else None,
                           "candidate_selected_safe_coverage":ratio(candidate.intersection(allowed),allowed) if allowed.area>0 and container_ids else None,
                           "candidate_protected_intersection_pixels2":candidate.intersection(protected).area*width*height if container_ids else None,
                           "baseline_protected_intersection_pixels2":baseline.intersection(protected).area*width*height if ids else None})
    shared = collections.defaultdict(set)
    for group in group_rows:
        for bid in group["selected_balloon_ids"]:
            shared[bid].add(group["group_id"])
    return {"primitive_correspondence":{str(t):correspondence(regions,predictions,t) for t in (.5,.75)},
            "groups":group_rows,"saved_current_owner_count":len(owners),"kept_lettering_owner_count_excluded":kept_count,
            "shared_container_across_distinct_silver_groups":[{"balloon_prediction_id":bid,"silver_group_ids":sorted(ids)} for bid,ids in shared.items() if len(ids)>1],
            "shared_container_authority":"association ambiguity, not proof different paragraphs must be merged or a grouping error",
            "mask_metric_authority":"Silver bbox/polygon containment of a numeric owner-local inset-mask diagnostic domain, not pixel-gold IoU or a render panel proposal"}


def summarize(run,inventory):
    records = [read(run/"pages"/f"{r['id']}.json") for r in inventory if (run/"pages"/f"{r['id']}.json").exists()]
    authority = read(run/"authority.json")
    labels = {r["id"]:r for r in read(Path(authority["dataset"])/"annotations.json")}
    subsets = {}
    for subset in ("all","development","heldout"):
        eligible = [r for r in records if subset=="all" or r["split"]==subset]
        successful = [r for r in eligible if r["status"]=="complete"]
        value = {"pages_recorded":len(eligible),"pages_complete":len(successful),"status_counts":dict(collections.Counter(r["status"] for r in eligible)),
                 "primitive_class_counts":dict(collections.Counter(str(p["class"]) for r in successful for p in r["predictions"])),"primitive_correspondence":{}}
        for threshold in (.5,.75):
            by_class = {}
            for cls in (1,3):
                data = [c for r in successful for c in r["metrics"]["primitive_correspondence"][str(threshold)] if c["class"]==cls]
                total = sum(c["known_silver_region_count"] for c in data)
                matched = sum(c["matched"] for c in data)
                by_class[str(cls)] = {"known_silver_regions":total,"matched":matched,"unmatched":total-matched,
                                       "known_region_correspondence_recall":matched/total if total else None,
                                       "unmatched_prediction_count_unknown_gt":sum(len(c["unmatched_prediction_ids"]) for c in data),
                                       "bbox_iou_mean_matched":float(np.mean([m["silver_bbox_iou"] for c in data for m in c["matches"]])) if matched else None}
            value["primitive_correspondence"][str(threshold)] = by_class
        groups = [g for r in successful for g in r["metrics"]["groups"]]
        coverage = [g["model_text_bbox_source_coverage"] for g in groups if g["model_text_bbox_source_coverage"] is not None]
        measured_safe = [g for g in groups if g["candidate_outside_selected_safe_pixels2"] is not None]
        value["label_ownership"] = {"target_groups":len(groups),"owner_state_counts":dict(collections.Counter(g["owner_state"] for g in groups)),
                                     "candidate_state_counts":dict(collections.Counter(g["candidate_state"] for g in groups)),
                                     "source_geometry_groups":len(coverage),"model_text_source_coverage_mean":float(np.mean(coverage)) if coverage else None,
                                     "model_text_source_coverage_counts":{str(t):sum(c>=t for c in coverage) for t in (.5,.8,.985)},
                                     "group_owner_pairs":sum(g["same_silver_group_owner_pairs"] for g in groups),
                                     "pairs_sharing_predicted_balloon":sum(g["same_group_pairs_sharing_predicted_balloon"] for g in groups),
                                     "groups_with_selected_safe_label":sum(g["allowed_geometry_present"] for g in groups),
                                     "source_safe_silver_infeasible":sum(g["source_safe_silver_infeasible"] is True for g in groups),
                                     "selected_safe_candidate_measured_groups":len(measured_safe),
                                     "candidate_outside_silver_safe_over16_source_px2_groups":sum(g["candidate_outside_selected_safe_pixels2"]>16 for g in measured_safe),
                                     "baseline_outside_silver_safe_over16_source_px2_groups_same_cohort":sum(g["baseline_outside_selected_safe_pixels2"]>16 for g in measured_safe),
                                     "candidate_protected_intersection_pixels2":sum(g["candidate_protected_intersection_pixels2"] or 0 for g in groups),
                                     "baseline_protected_intersection_pixels2_same_selected_cohort":sum((g["baseline_protected_intersection_pixels2"] or 0) for g in groups if g["candidate_protected_intersection_pixels2"] is not None),
                                     "source_coverage_loss_from_baseline_gt_0_02_groups":sum(g["baseline_source_coverage"]-g["candidate_source_coverage"]>.02 for g in groups if g["candidate_source_coverage"] is not None and g["baseline_source_coverage"] is not None)}
        value["silver_group_kind_cohorts"] = {}
        for kind in ("balloon","free_text","caption"):
            selected = [g for g in groups if g["kind"]==kind]
            safe = [g for g in selected if g["candidate_outside_selected_safe_pixels2"] is not None]
            source_values = [g["model_text_bbox_source_coverage"] for g in selected if g["model_text_bbox_source_coverage"] is not None]
            value["silver_group_kind_cohorts"][kind] = {
                "target_groups":len(selected),"owner_states":dict(collections.Counter(g["owner_state"] for g in selected)),
                "candidate_states":dict(collections.Counter(g["candidate_state"] for g in selected)),
                "model_text_source_coverage_mean":float(np.mean(source_values)) if source_values else None,
                "model_text_source_coverage_ge0_8_groups":sum(v>=.8 for v in source_values),
                "same_group_owner_pairs":sum(g["same_silver_group_owner_pairs"] for g in selected),
                "pairs_sharing_predicted_balloon":sum(g["same_group_pairs_sharing_predicted_balloon"] for g in selected),
                "selected_safe_label_groups":sum(g["allowed_geometry_present"] for g in selected),
                "measured_safe_candidate_groups":len(safe),
                "safe_candidate_outside_over16_source_px2_groups":sum(g["candidate_outside_selected_safe_pixels2"]>16 for g in safe),
                "safe_baseline_outside_over16_source_px2_groups_same_cohort":sum(g["baseline_outside_selected_safe_pixels2"]>16 for g in safe),
                "source_safe_silver_infeasible_groups":sum(g["source_safe_silver_infeasible"] is True for g in selected),
                "source_coverage_loss_from_baseline_over0_02_groups":sum(g["baseline_source_coverage"]-g["candidate_source_coverage"]>.02 for g in selected if g["candidate_source_coverage"] is not None and g["baseline_source_coverage"] is not None)}
        value["known_region_role_confidence_cohorts"] = {}
        value["selected_safe_feasibility_cohorts"] = {}
        for feasibility in (False,True):
            eligible_safe = [g for g in groups if g["source_safe_silver_infeasible"] is feasibility]
            safe = [g for g in eligible_safe if g["candidate_outside_selected_safe_pixels2"] is not None]
            value["selected_safe_feasibility_cohorts"]["silver_source_fits_allowed" if not feasibility else "silver_source_exceeds_allowed"] = {
                "labeled_groups":len(eligible_safe),"candidate_measured_groups":len(safe),
                "candidate_missing_or_unmatched_groups":len(eligible_safe)-len(safe),
                "candidate_outside_over16_source_px2_groups":sum(g["candidate_outside_selected_safe_pixels2"]>16 for g in safe),
                "baseline_outside_over16_source_px2_groups_same_cohort":sum(g["baseline_outside_selected_safe_pixels2"]>16 for g in safe),
                "source_coverage_loss_from_baseline_over0_02_groups":sum(g["baseline_source_coverage"]-g["candidate_source_coverage"]>.02 for g in safe if g["candidate_source_coverage"] is not None and g["baseline_source_coverage"] is not None)}
        for threshold in (.5,.75):
            counters = collections.defaultdict(lambda:{"known_regions":0,"matched":0,"ious":[]})
            for record in successful:
                region_index = {r["id"]:r for r in labels[record["id"]]["regions"]}
                matched_ids = {m["region_id"]:m for cls in record["metrics"]["primitive_correspondence"][str(threshold)] for m in cls["matches"]}
                for region in region_index.values():
                    cls = 1 if region["kind"]=="must_cover" and region.get("role") in ("dialogue","caption") else 3 if region.get("role")=="sfx" and region["kind"] in ("must_cover","protected") else None
                    if cls is None:
                        continue
                    key = f"class{cls}:{region['kind']}:{region['role']}:{region.get('confidence')}"
                    counter = counters[key]
                    counter["known_regions"] += 1
                    if region["id"] in matched_ids:
                        counter["matched"] += 1
                        counter["ious"].append(matched_ids[region["id"]]["silver_bbox_iou"])
            value["known_region_role_confidence_cohorts"][str(threshold)] = {
                key:{"known_regions":v["known_regions"],"matched":v["matched"],"unmatched":v["known_regions"]-v["matched"],
                     "known_positive_correspondence_recall":v["matched"]/v["known_regions"],
                     "bbox_iou_mean_on_matches":float(np.mean(v["ious"])) if v["ious"] else None}
                for key,v in sorted(counters.items())}
        value["host_runtime"] = {key:{"total_seconds":sum(r["timing_seconds"][key] for r in successful),
                                            "median_seconds":float(np.median([r["timing_seconds"][key] for r in successful])) if successful else None}
                                 for key in ("image_numeric_preprocess","coreml_predict","mask_decode","silver_geometry_evaluation","page_total")}
        subsets[subset] = value
    result = {"source_denominator":836,"pages_recorded":len(records),"pages_pending":836-len(records),"subsets":subsets,"resources":resources(run),
              "authority":"Agent silver source bbox/polygon geometry only. Known-positive class cohorts not exhaustive detector precision/AP. Safe domains not balloon contours. No historical render defects used. Missing/unmatched explicitly counted.",
              "raw_source_pixels_or_composites_saved":False,"RF836_comparison":"Unavailable without existing source-bound RF836 stats; RF model not run",
              "host_proxy_only":True}
    handle = read(run/"run.json")
    result["inference_run"] = {"id":handle["id"],"pid":handle["pid"],"status":handle["status"],
                               "elapsed_wall_seconds":handle.get("finished_unix",time.time())-handle["started_unix"],
                               "resources":handle.get("resources"),"host_model_load_seconds":handle.get("host_model_load_seconds")}
    result["summary_reducer_script_sha256"] = sha(Path(__file__))
    result["source_hash_verification_status"] = dict(collections.Counter(r["source_hash_status"] for r in inventory))
    result["historical_source_identity_counts"] = dict(collections.Counter(r["source_identity_verification"] for r in inventory))
    result["missing_is_not_zero"] = "Missing source, owner, safe label and model association have explicit states/nullable metrics. Actual inferred-empty primitive union has measured zero support and explicit unmatched IDs; never zero error."
    archive_index = []
    source_hashes = {r["expected_source_sha256"] for r in inventory}
    def archive_hashes(value):
        found = set()
        if isinstance(value,dict):
            for key,item in value.items():
                if "sha" in key.lower() and isinstance(item,str) and len(item)==64:
                    found.add(item.lower())
                found.update(archive_hashes(item))
        elif isinstance(value,list):
            for item in value:
                found.update(archive_hashes(item))
        return found
    for path in sorted((REPO/"build/koharu-mobile/rfdetr").glob("*.json")):
        metadata = read(path)
        matches = source_hashes.intersection(archive_hashes(metadata))
        archive_index.append({"path":str(path),"metadata_sha256":sha(path),"836_exact_source_byte_hash_matches":sorted(matches)})
    write(run/"RF-archived-metadata-index.json",archive_index)
    result["RF_archive_coverage"] = {"metadata_files_indexed":len(archive_index),
                                     "exact_836_source_byte_hashes_matched":len(set(h for r in archive_index for h in r["836_exact_source_byte_hash_matches"])),
                                     "RF836_model_executed":False,
                                     "scope":"Scoped existing RF metadata only; unmatched byte hashes do not prove RGB aliases absent. No source-bound RF836 predictions provided, hence numerical cross-model836 accuracy remains unmeasured."}
    write(run/"summary.json",result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset",type=Path,default=REPO.parent/"labels/final-ensemble-recovered-20261013")
    parser.add_argument("--owners-run",type=Path,default=REPO.parent/"output_dedup_manga_v6/optimization-current/main/current-improved-full836-v2-20261013")
    parser.add_argument("--model",type=Path,default=REPO/"build/koharu-mobile/yolo/1280/KoharuYOLO26sSeg1280FP16.mlpackage")
    parser.add_argument("--run-id",default="native1280-silver836-20261014")
    parser.add_argument("--inventory-only",action="store_true")
    parser.add_argument("--resume",action="store_true")
    parser.add_argument("--summarize-only",action="store_true",help="Reduce existing numeric records only; no source pixels, model execution or renderer access")
    args = parser.parse_args()
    if not args.run_id or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_" for c in args.run_id):
        raise ValueError("Invalid scoped run ID")
    run = ROOT/args.run_id
    if args.summarize_only:
        summarize(run,read(run/"source-inventory.json"))
        print(f"Existing full836 records summarized: {run/'summary.json'}",flush=True)
        return
    if run.exists() and (run/"run.json").exists() and not args.resume:
        raise ValueError("Existing run: use --resume; do not overwrite a completed ledger")
    run.mkdir(parents=True,exist_ok=True)
    (run/"pages").mkdir(exist_ok=True)
    run_handle = {"id":args.run_id,"pid":os.getpid(),"status":"preparing","started_unix":time.time(),"output":str(run),
                  "source_scope":836,"model":"native1280 CPU_AND_NE","production_integration":False,"resource_policy":"one sequential page, mask batches4, Torch2 threads; numeric JSON only"}
    write(run/"run.json",run_handle)
    print("RUN HANDLE "+json.dumps(run_handle),flush=True)
    labels,manifest,inventory,authority = load_authority(args,run)
    if args.inventory_only:
        run_handle.update({"status":"inventory_only_complete","resources":resources(run)})
        write(run/"run.json",run_handle)
        return
    import coremltools as ct
    import torch
    torch.set_num_threads(2)
    start = time.perf_counter()
    engine = ct.models.MLModel(str(args.model.resolve()),compute_units=ct.ComputeUnit.CPU_AND_NE)
    run_handle.update({"status":"running","host_model_load_seconds":time.perf_counter()-start,"resources":resources(run)})
    write(run/"run.json",run_handle)
    for entry in inventory:
        pid = entry["id"]
        page_path = run/"pages"/f"{pid}.json"
        if args.resume and page_path.exists():
            prior = read(page_path)
            if prior["source_expected_sha256"]==entry["expected_source_sha256"] and prior.get("annotation_sha256")==authority["verified_dataset_file_hashes"]["annotations.json"]:
                entry["status"] = prior["status"]
                continue
            raise ValueError("Resume provenance changed")
        began = time.perf_counter()
        record = {"id":pid,"split":entry["split"],"duplicate_family":entry["duplicate_family"],"status":"pending",
                  "source_expected_sha256":entry["expected_source_sha256"],"annotation_sha256":authority["verified_dataset_file_hashes"]["annotations.json"],
                  "source_identity_verification":entry["source_identity_verification"]}
        try:
            if not entry["source_exists"]:
                record["status"] = "source_missing"
            elif not entry["source_geometry_eligible"] or not entry["binding_current_path_agrees"]:
                record["status"] = "source_binding_ineligible"
            elif entry["source_size_wh"] != entry["label_size_wh"]:
                record["status"] = "source_label_coordinate_mismatch"
            elif not entry["saved_owner_layout_exists"]:
                record["status"] = "saved_owner_geometry_missing"
            else:
                actual_hash = sha(Path(entry["source_path"]))
                record["source_actual_sha256"] = actual_hash
                if actual_hash != entry["expected_source_sha256"]:
                    record["status"] = "source_hash_mismatch"
                else:
                    start = time.perf_counter()
                    with Image.open(entry["source_path"]) as image:
                        rgb = np.asarray(image.convert("RGB"))
                    if [rgb.shape[1],rgb.shape[0]] != entry["source_size_wh"]:
                        raise ValueError("Runtime source dimensions mismatch")
                    tensor,mapping = preprocess(rgb)
                    del rgb
                    record["input_tensor_sha256"] = hashlib.sha256(tensor.tobytes()).hexdigest()
                    t_pre = time.perf_counter()-start
                    start = time.perf_counter()
                    actual = engine.predict({"image":tensor})
                    del tensor
                    expected = {"boxes":(1,33600,4),"scores":(1,33600,4),"mask_coefficients":(1,33600,32),"mask_prototypes":(1,32,320,320)}
                    if set(actual)!=set(expected) or any(actual[k].shape!=shape or not np.isfinite(actual[k]).all() for k,shape in expected.items()):
                        raise ValueError("Invalid model output layout/numerics")
                    t_pred = time.perf_counter()-start
                    start = time.perf_counter()
                    predictions = decode(actual,mapping)
                    del actual
                    t_decode = time.perf_counter()-start
                    start = time.perf_counter()
                    layout_path = Path(entry["saved_owner_layout_path"])
                    layout = read(layout_path)
                    record["saved_owner_layout_sha256"] = sha(layout_path)
                    record["metrics"] = page_metrics(labels[pid],predictions,layout,mapping)
                    record["predictions"] = [{"id":p["id"],"anchor":p["anchor"],"class":p["class"],"score":p["score"],
                                              "box_normalized_xyxy":list(p["box"].bounds),
                                              "balloon_mask_geometry_area":p["mask_geometry"].area if p["class"]==2 else None} for p in predictions]
                    t_geometry = time.perf_counter()-start
                    del predictions,layout
                    record["timing_seconds"] = {"image_numeric_preprocess":t_pre,"coreml_predict":t_pred,"mask_decode":t_decode,
                                                "silver_geometry_evaluation":t_geometry,"page_total":time.perf_counter()-began}
                    record["status"] = "complete"
        except (OSError,ValueError,RuntimeError,KeyError,TypeError) as error:
            record.update({"status":"page_error","error_type":type(error).__name__,"error":str(error),"traceback":traceback.format_exc()})
        entry["status"] = record["status"]
        entry["source_hash_status"] = "verified_exact_current_manifest_bytes" if record.get("source_actual_sha256")==entry["expected_source_sha256"] else "mismatch" if record.get("source_actual_sha256") else "not_verified"
        write(page_path,record)
        if int(pid)%10==0 or pid=="0001" or pid=="0836":
            write(run/"source-inventory.json",inventory)
            result = summarize(run,inventory)
            run_handle.update({"last_id":pid,"pages_recorded":result["pages_recorded"],"pages_complete":result["subsets"]["all"]["pages_complete"],"resources":result["resources"]})
            write(run/"run.json",run_handle)
            print(f"PROGRESS {pid}/0836 complete={run_handle['pages_complete']} RSS={run_handle['resources']['rss_bytes']} disk={run_handle['resources']['run_disk_bytes']}",flush=True)
    write(run/"source-inventory.json",inventory)
    result = summarize(run,inventory)
    run_handle.update({"status":"complete" if result["subsets"]["all"]["pages_complete"]==836 else "completed_with_explicit_page_failures",
                       "finished_unix":time.time(),"pages_recorded":result["pages_recorded"],"pages_complete":result["subsets"]["all"]["pages_complete"],"resources":result["resources"]})
    write(run/"run.json",run_handle)
    print("FINISHED "+json.dumps(run_handle),flush=True)


if __name__=="__main__":
    main()
