#!/usr/bin/env python3
"""Compare two PipelineEquivalenceHarness runs (pulled with pull.sh).

Usage: compare.py <baselineDir> <candidateDir> [--diff-dir DIR] [--box-tol 0] [--conf-tol 0]
                  [--pixel-tol 0] [--max-diff-pct 0.0] [--json OUT]

Reports:
  * OCR equivalence (final merged regions = production ReaderOCRService output, plus raw detector/recognizer
    lines): count, text exact equality, order, grouping, orientation, panel order, bbox/quad max deviation (px),
    confidence max abs diff.
  * Translation input/outputs (translated texts) and native layout payload equality.
  * Rendered PNG pixel diff: max channel diff, % pixels whose max channel diff > pixel-tol; writes heatmaps.
  * Per-stage timing table baseline vs candidate with speedup (baseline / candidate).
Exit status 1 when OCR/translation/layout/render equivalence fails the tolerances.
"""
import argparse
from fractions import Fraction
import json
import math
import os
import statistics
import sys

try:
    import numpy as np
    from PIL import Image
except ImportError:  # pragma: no cover
    np = None
    Image = None


def load(path):
    def reject_constant(value):
        raise ValueError(f"Non-finite JSON number: {value}")

    def validate(value):
        if isinstance(value, float) and not math.isfinite(value):
            raise ValueError("Non-finite JSON number")
        if isinstance(value, dict):
            for item in value.values():
                validate(item)
        elif isinstance(value, list):
            for item in value:
                validate(item)

    with open(path, encoding="utf-8") as f:
        value = json.load(f, parse_constant=reject_constant)
    validate(value)  # A valid exponent such as 1e999 can also overflow to infinity.
    return value


def numeric_difference(a, b):
    if any(isinstance(value, bool) or not isinstance(value, (int, float))
           or (isinstance(value, float) and not math.isfinite(value)) for value in (a, b)):
        return math.inf
    # Preserve 1 == 1.0 while avoiding Float rounding of adjacent large integers.
    difference = abs(Fraction(a) - Fraction(b))
    try:
        return float(difference)
    except OverflowError:
        return math.inf


def maybe(path):
    return load(path) if os.path.exists(path) else None


def max_point_dev(a, b):
    """Max abs coordinate deviation between two lists of [x, y] (or flat numbers)."""
    if a is None or b is None:
        return 0.0 if a == b else math.inf
    if len(a) != len(b):
        return math.inf
    dev = 0.0
    for p, q in zip(a, b):
        if isinstance(p, list):
            dev = max(dev, max_point_dev(p, q))
        else:
            dev = max(dev, numeric_difference(p, q))
    return dev


def compare_regions(base, cand, box_tol, conf_tol, key_text="source", key_conf="confidence",
                    rect_key="rectPx", poly_key="polygonPx", extra_keys=()):
    r = {"count": (len(base), len(cand)), "countEqual": len(base) == len(cand)}
    text_mismatch = []
    box_dev = 0.0
    conf_dev = 0.0
    extra_mismatch = {k: 0 for k in extra_keys}
    for i, (a, b) in enumerate(zip(base, cand)):
        if a.get(key_text) != b.get(key_text):
            text_mismatch.append((i, a.get(key_text), b.get(key_text)))
        if rect_key:
            box_dev = max(box_dev, max_point_dev(a.get(rect_key), b.get(rect_key)))
        if poly_key:
            box_dev = max(box_dev, max_point_dev(a.get(poly_key), b.get(poly_key)))
        conf_dev = max(conf_dev, numeric_difference(a.get(key_conf, 0), b.get(key_conf, 0)))
        for k in extra_keys:
            if k.endswith("Px"):
                if max_point_dev(a.get(k), b.get(k)) > box_tol:
                    extra_mismatch[k] += 1
            elif a.get(k) != b.get(k):
                extra_mismatch[k] += 1
    base_texts = [x.get(key_text) for x in base]
    cand_texts = [x.get(key_text) for x in cand]
    r["textExact"] = not text_mismatch and r["countEqual"]
    r["orderEqual"] = base_texts == cand_texts
    r["sameTextMultiset"] = sorted(map(str, base_texts)) == sorted(map(str, cand_texts))
    r["textMismatches"] = text_mismatch[:5]
    r["boxMaxDevPx"] = box_dev
    r["confMaxAbsDiff"] = conf_dev
    r["extraMismatches"] = {k: v for k, v in extra_mismatch.items() if v}
    r["ok"] = (r["countEqual"] and r["textExact"] and box_dev <= box_tol and conf_dev <= conf_tol
               and not r["extraMismatches"])
    return r


def flatten(obj, prefix=""):
    if isinstance(obj, dict):
        for k in sorted(obj):
            yield from flatten(obj[k], f"{prefix}.{k}")
    elif isinstance(obj, list):
        yield (prefix + ".#len", len(obj))
        for i, v in enumerate(obj):
            yield from flatten(v, f"{prefix}[{i}]")
    else:
        yield (prefix, obj)


def compare_layout(a, b, tol):
    if a is None and b is None:
        return {"ok": True, "present": False}
    if a is None or b is None:
        return {"ok": False, "present": "one side missing"}
    fa, fb = dict(flatten(a)), dict(flatten(b))
    keys = set(fa) | set(fb)
    num_dev = 0.0
    mism = []
    for k in sorted(keys):
        x, y = fa.get(k, "<missing>"), fb.get(k, "<missing>")
        if isinstance(x, bool) or isinstance(y, bool):
            if type(x) is not type(y) or x != y:
                mism.append((k, x, y))
        elif isinstance(x, (int, float)) and isinstance(y, (int, float)):
            d = numeric_difference(x, y)
            num_dev = max(num_dev, d)
            if d > tol:
                mism.append((k, x, y))
        elif x != y:
            mism.append((k, x, y))
    return {"ok": not mism, "numericMaxDev": num_dev, "mismatches": len(mism), "examples": mism[:5]}


def compare_png(pa, pb, diff_path, pixel_tol):
    if not (os.path.exists(pa) or os.path.exists(pb)):
        return {"present": False, "ok": False}
    if not (os.path.exists(pa) and os.path.exists(pb)):
        return {"present": "one side missing", "ok": False}
    if np is None:
        with open(pa, "rb") as f1, open(pb, "rb") as f2:
            same = f1.read() == f2.read()
        return {"bytesEqual": same, "ok": same, "note": "numpy/PIL unavailable"}
    a = np.asarray(Image.open(pa).convert("RGBA")).astype(np.int16)
    b = np.asarray(Image.open(pb).convert("RGBA")).astype(np.int16)
    if a.shape != b.shape:
        return {"sizeEqual": False, "sizes": [list(a.shape), list(b.shape)], "ok": False}
    diff = np.abs(a - b).max(axis=2)
    max_diff = int(diff.max())
    pct = float((diff > pixel_tol).mean() * 100)
    pct_any = float((diff > 0).mean() * 100)
    if diff_path and max_diff > 0:
        os.makedirs(os.path.dirname(diff_path), exist_ok=True)
        norm = np.clip(diff.astype(np.float32) * (255.0 / max(max_diff, 1)), 0, 255).astype(np.uint8)
        base_gray = (np.asarray(Image.open(pa).convert("L")).astype(np.float32) * 0.3).astype(np.uint8)
        heat = np.stack([np.maximum(base_gray, norm), base_gray, base_gray], axis=2)
        heat[diff > pixel_tol] = [255, 0, 255]
        Image.fromarray(heat, "RGB").save(diff_path)
    return {"sizeEqual": True, "size": [a.shape[1], a.shape[0]], "maxChannelDiff": max_diff,
            "pctPixelsDiffGtTol": pct, "pctPixelsAnyDiff": pct_any, "ok": None}


def med(values):
    values = [v for v in values if isinstance(v, (int, float))]
    return statistics.median(values) if values else None


def timing_rows(row):
    """Flatten one fixture row into named timing metrics (ms)."""
    t = {}
    svc = row.get("ocrService") or []
    if svc:
        t["ocr.cold.wall"] = svc[0].get("wallMS")
        warm = svc[1:]
        t["ocr.warm.wall(med)"] = med([p.get("wallMS") for p in warm])
        for ph in ("native", "wordBoundary", "mergeAndSeparator", "balloonMerge"):
            t[f"ocr.cold.{ph}"] = (svc[0].get("phases") or {}).get(ph)
            t[f"ocr.warm.{ph}(med)"] = med([(p.get("phases") or {}).get(ph) for p in warm])
    st = row.get("ocrStages") or []
    if st:
        c = st[0]
        t["stage.cold.detect"] = c.get("detectionMS")
        t["stage.cold.recognize"] = c.get("recognitionMS")
        t["stage.cold.frameConv"] = c.get("frameConversionMS")
        t["stage.cold.detModelLoad"] = (c.get("detector") or {}).get("modelLoadMilliseconds")
        t["stage.cold.recModelLoad"] = (c.get("recognizer") or {}).get("modelLoadMilliseconds")
        t["stage.cold.recFnLoad"] = (c.get("recognizer") or {}).get("modelFunctionLoadMilliseconds")
        w = st[1:]
        t["stage.warm.detect(med)"] = med([p.get("detectionMS") for p in w])
        t["stage.warm.recognize(med)"] = med([p.get("recognitionMS") for p in w])
        for k in ("preprocessingMilliseconds", "predictionMilliseconds", "dbPostprocessingMilliseconds",
                  "postprocessingMilliseconds"):
            t[f"stage.warm.det.{k.replace('Milliseconds', '')}(med)"] = med([(p.get("detector") or {}).get(k) for p in w])
        for k in ("preprocessingMilliseconds", "predictionMilliseconds", "decodingMilliseconds"):
            t[f"stage.warm.rec.{k.replace('Milliseconds', '')}(med)"] = med([(p.get("recognizer") or {}).get(k) for p in w])
    t["prep(panelOrder+filter)"] = row.get("preparationMS")
    t["translate.total"] = row.get("translationMS")
    t["translate.providerSum"] = row.get("providerWallMS")
    t["translate.firstBatch"] = row.get("firstTranslatedBatchMS")
    t["layoutPayload"] = row.get("layoutPayloadMS")
    rr = row.get("renderTotalMS") or []
    if rr:
        t["render.cold"] = rr[0]
        t["render.warm(med)"] = med(rr[1:])
    js = row.get("jsMetrics") or {}
    for k in ("cleanupMilliseconds", "sourceColorMilliseconds", "koreanWrapMilliseconds",
              "smallTextRefinementMilliseconds", "readableParagraphMilliseconds"):
        if k in js:
            t[f"js.{k.replace('Milliseconds', '')}"] = js[k]
    t["domCommit"] = row.get("domCommitMS")
    t["peakFootprintMiB"] = row.get("peakFootprintMiB")
    return t


def fmt(v):
    if v is None:
        return "-"
    return f"{v:.1f}" if isinstance(v, float) else str(v)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("baseline")
    ap.add_argument("candidate")
    ap.add_argument("--diff-dir", default=None, help="heatmap output dir (default <candidate>/diff-vs-<baseline>)")
    ap.add_argument("--box-tol", type=float, default=0.0)
    ap.add_argument("--conf-tol", type=float, default=0.0)
    ap.add_argument("--pixel-tol", type=int, default=0)
    ap.add_argument("--max-diff-pct", type=float, default=0.0,
                    help="render fails if %% pixels with diff > pixel-tol exceeds this")
    ap.add_argument("--json", default=None, help="write machine-readable report")
    ap.add_argument("--no-timing", action="store_true")
    ap.add_argument("--layout-tol", type=float, default=0.0)
    args = ap.parse_args()
    if any(not math.isfinite(value) or value < 0 for value in
           (args.box_tol, args.conf_tol, args.pixel_tol, args.max_diff_pct, args.layout_tol)):
        ap.error("tolerances must be finite and nonnegative")

    B, C = args.baseline, args.candidate
    rb, rc = load(os.path.join(B, "results.json")), load(os.path.join(C, "results.json"))
    diff_dir = args.diff_dir or os.path.join(C, "diff-vs-" + os.path.basename(os.path.normpath(B)))
    rows_b = {r["fixture"]: r for r in rb["rows"]}
    rows_c = {r["fixture"]: r for r in rc["rows"]}
    mb, mc = rb["metadata"], rc["metadata"]
    print(f"baseline : {B}  [{mb.get('label')} {mb.get('translationMode')} thermal {mb.get('thermalStart')}->{mb.get('thermalEnd')}]")
    print(f"candidate: {C}  [{mc.get('label')} {mc.get('translationMode')} thermal {mc.get('thermalStart')}->{mc.get('thermalEnd')}]")
    fixtures = sorted(set(rows_b) | set(rows_c))
    report = {"fixtures": {}}
    all_ok = bool(fixtures) and len(rows_b) == len(rb["rows"]) and len(rows_c) == len(rc["rows"])
    if not all_ok:
        print("FAIL: empty fixture set or duplicate fixture identifiers")

    print("\n== Equivalence ==")
    for name in fixtures:
        entry = {}
        if name not in rows_b or name not in rows_c:
            print(f"{name}: missing in {'baseline' if name not in rows_b else 'candidate'}")
            all_ok = False
            report["fixtures"][name] = {"ok": False, "reason": "fixture missing"}
            continue
        missing = [str(os.path.join(directory, f"{name}.{suffix}"))
                   for directory in (B, C)
                   for suffix in ("ocr.json", "lines.json", "translated.json", "layout.json", "render.png")
                   if not os.path.isfile(os.path.join(directory, f"{name}.{suffix}"))]
        if missing:
            all_ok = False
            report["fixtures"][name] = {"ok": False, "missingArtifacts": missing}
            print(f"{name}: FAIL missing artifacts {missing}")
            continue
        ob, oc = load(os.path.join(B, f"{name}.ocr.json")), load(os.path.join(C, f"{name}.ocr.json"))
        ocr = compare_regions(ob["regions"], oc["regions"], args.box_tol, args.conf_tol,
                              extra_keys=("orientation", "singleVerticalColumn", "auxiliaryInkRectsPx"))
        prep = compare_regions(ob["prepared"], oc["prepared"], args.box_tol, args.conf_tol,
                               extra_keys=("translationOrder",))
        eligible_eq = ob.get("eligibleIDs") == oc.get("eligibleIDs")
        lb, lc = maybe(os.path.join(B, f"{name}.lines.json")), maybe(os.path.join(C, f"{name}.lines.json"))
        lines = compare_regions(lb or [], lc or [], args.box_tol, args.conf_tol, key_text="text", key_conf="score",
                                rect_key=None, poly_key="polygon", extra_keys=("orientation",))
        tb, tc = maybe(os.path.join(B, f"{name}.translated.json")), maybe(os.path.join(C, f"{name}.translated.json"))
        trans_eq = [(x["id"], x["source"], x.get("translation")) for x in (tb or [])] == \
                   [(x["id"], x["source"], x.get("translation")) for x in (tc or [])]
        layout = compare_layout(maybe(os.path.join(B, f"{name}.layout.json")),
                                maybe(os.path.join(C, f"{name}.layout.json")), args.layout_tol)
        png = compare_png(os.path.join(B, f"{name}.render.png"), os.path.join(C, f"{name}.render.png"),
                          os.path.join(diff_dir, f"{name}.diff.png"), args.pixel_tol)
        if png.get("ok") is None:
            png["ok"] = png["pctPixelsDiffGtTol"] <= args.max_diff_pct
        misses = rows_c[name].get("replayMisses", 0)
        unstable = [k for k in ("ocrUnstableAcrossPasses", "rawLinesUnstableAcrossPasses", "renderUnstableAcrossPasses")
                    if rows_b[name].get(k) or rows_c[name].get(k)]
        ok = ocr["ok"] and prep["ok"] and eligible_eq and lines["ok"] and trans_eq and layout["ok"] and png["ok"] and misses == 0
        all_ok &= ok
        entry.update(ocr=ocr, prepared=prep, eligibleEqual=eligible_eq, rawLines=lines, translationsEqual=trans_eq,
                     layout=layout, render=png, replayMisses=misses, unstable=unstable, ok=ok)
        report["fixtures"][name] = entry
        print(f"{name}: {'PASS' if ok else 'FAIL'}")
        print(f"  OCR regions  count {ocr['count'][0]}/{ocr['count'][1]} text={'==' if ocr['textExact'] else '!='} "
              f"order={'==' if ocr['orderEqual'] else '!='} boxDev={ocr['boxMaxDevPx']:.3g}px "
              f"confDiff={ocr['confMaxAbsDiff']:.3g} {ocr['extraMismatches'] or ''}")
        if ocr["textMismatches"]:
            print(f"    text mismatches: {ocr['textMismatches']}")
        print(f"  panel order  {'==' if prep['ok'] else '!= ' + str(prep['extraMismatches'])}  eligible={'==' if eligible_eq else '!='}")
        print(f"  raw lines    count {lines['count'][0]}/{lines['count'][1]} text={'==' if lines['textExact'] else '!='} "
              f"quadDev={lines['boxMaxDevPx']:.3g}px scoreDiff={lines['confMaxAbsDiff']:.3g}")
        print(f"  translations {'==' if trans_eq else '!='}  replayMisses={misses}")
        print(f"  layout       {'==' if layout['ok'] else '!='} " +
              (f"(numDev {layout.get('numericMaxDev', 0):.3g}, {layout.get('mismatches', 0)} diffs {layout.get('examples', '')[:2]})"
               if layout.get('present', True) else "(none)"))
        if "maxChannelDiff" in png:
            print(f"  render PNG   {png['size']} maxChannelDiff={png['maxChannelDiff']} "
                  f">{args.pixel_tol}: {png['pctPixelsDiffGtTol']:.4f}%  any: {png['pctPixelsAnyDiff']:.4f}%")
        else:
            print(f"  render PNG   {png}")
        if unstable:
            print(f"  WARNING intra-run instability: {unstable}")

    if not args.no_timing:
        print("\n== Timing (ms; speedup = baseline/candidate) ==")
        totals_b, totals_c = {}, {}
        modes_differ = mb.get("translationMode") != mc.get("translationMode")
        if modes_differ:
            print("  (translate.* not comparable: live vs replay)")
        print("  thermal (0 nominal,1 fair,2 serious,3 critical) per fixture start: baseline " +
              str([rows_b[n].get("thermalStart") for n in fixtures if n in rows_b]) + " candidate " +
              str([rows_c[n].get("thermalStart") for n in fixtures if n in rows_c]))
        for name in fixtures:
            if name not in rows_b or name not in rows_c:
                continue
            tb_, tc_ = timing_rows(rows_b[name]), timing_rows(rows_c[name])
            print(f"\n{name}")
            print(f"  {'metric':42s} {'baseline':>10s} {'candidate':>10s} {'speedup':>8s}")
            for k in tb_:
                vb, vc = tb_.get(k), tc_.get(k)
                if vb is None and vc is None:
                    continue
                sp = f"{vb / vc:.2f}x" if isinstance(vb, (int, float)) and isinstance(vc, (int, float)) and vc > 0 \
                    and k != "peakFootprintMiB" and not (k.startswith("translate.") and modes_differ) else ""
                print(f"  {k:42s} {fmt(vb):>10s} {fmt(vc):>10s} {sp:>8s}")
                if isinstance(vb, (int, float)) and isinstance(vc, (int, float)):
                    totals_b[k] = totals_b.get(k, 0) + vb
                    totals_c[k] = totals_c.get(k, 0) + vc
        print("\nTOTAL over fixtures")
        print(f"  {'metric':42s} {'baseline':>10s} {'candidate':>10s} {'speedup':>8s}")
        for k in totals_b:
            vb, vc = totals_b[k], totals_c[k]
            if k == "peakFootprintMiB":
                continue
            sp = f"{vb / vc:.2f}x" if vc > 0 and not (k.startswith("translate.") and modes_differ) else ""
            print(f"  {k:42s} {fmt(vb):>10s} {fmt(vc):>10s} {sp:>8s}")
        print(f"\n  peak footprint (sampled, MiB): {fmt(mb.get('peakFootprintMiBSampled'))} -> {fmt(mc.get('peakFootprintMiBSampled'))}; "
              f"lifetime ledger peak: {fmt(mb.get('lifetimePeakFootprintMiB'))} -> {fmt(mc.get('lifetimePeakFootprintMiB'))}")
        report["timingTotals"] = {"baseline": totals_b, "candidate": totals_c}

    print(f"\nOVERALL: {'PASS' if all_ok else 'FAIL'}  (heatmaps: {diff_dir})")
    report["ok"] = all_ok
    if args.json:
        with open(args.json, "w", encoding="utf-8") as f:
            json.dump(report, f, indent=2, ensure_ascii=False, default=str)
    sys.exit(0 if all_ok else 1)


if __name__ == "__main__":
    main()
