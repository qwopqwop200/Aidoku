#!/usr/bin/env python3
"""Independent, conservative audit of the 141–193 device-cache replay.

This script never treats a missing render or an unverified source-erasure flag as
visual proof. It reports geometry and renderer decisions and creates paired
source/render crops for manual inspection of every suspicious text box.
"""

import argparse
import json
from collections import Counter
from pathlib import Path

from PIL import Image, ImageDraw


def load(path):
    with path.open() as f:
        return json.load(f)


def find_artifact(folder, number, suffix):
    if not folder:
        return None
    for name in (f"{number}.{suffix}", f"page-{number}.{suffix}", f"case-{number}.{suffix}"):
        path = folder / name
        if path.is_file():
            return path
    matches = list(folder.glob(f"*{number}*.{suffix}"))
    return matches[0] if len(matches) == 1 else None


def rect_intersection(a, b):
    left, top = max(a[0], b[0]), max(a[1], b[1])
    right, bottom = min(a[0] + a[2], b[0] + b[2]), min(a[1] + a[3], b[1] + b[3])
    return max(0, right - left) * max(0, bottom - top)


def rect_area(r):
    return max(0, r[2]) * max(0, r[3])


def source_rect(item, display_rect):
    source = item.get("sourceBounds")
    if not source or len(source) != 4:
        return None
    return [display_rect[0] + source[0] * display_rect[2],
            display_rect[1] + source[1] * display_rect[3],
            source[2] * display_rect[2], source[3] * display_rect[3]]


def balloon_rect(item, display_rect):
    interior = item.get("balloonInterior") or {}
    rect = interior.get("rect")
    if not interior.get("contourVerified") or not rect or len(rect) != 4:
        return None
    return [display_rect[0] + rect[0] * display_rect[2],
            display_rect[1] + rect[1] * display_rect[3],
            rect[2] * display_rect[2], rect[3] * display_rect[3]]


def crop_pair(src, dst, source, rendered, display_rect, output_path):
    try:
        sx, sy = src.width / display_rect[2], src.height / display_rect[3]
        dx, dy = dst.width / display_rect[2], dst.height / display_rect[3]

        def crop(image, box, kx, ky):
            pad = max(4, int(0.18 * max(box[2] * kx, box[3] * ky)))
            x = int((box[0] - display_rect[0]) * kx)
            y = int((box[1] - display_rect[1]) * ky)
            w, h = int(box[2] * kx), int(box[3] * ky)
            return image.crop((max(0, x - pad), max(0, y - pad),
                               min(image.width, x + w + pad), min(image.height, y + h + pad)))

        before = crop(src, source, sx, sy)
        after = crop(dst, rendered, dx, dy)
        max_height = 500
        for image in (before, after):
            image.thumbnail((500, max_height))
        out = Image.new("RGB", (before.width + after.width + 12,
                                max(before.height, after.height) + 26), "white")
        out.paste(before, (0, 26))
        out.paste(after, (before.width + 12, 26))
        draw = ImageDraw.Draw(out)
        draw.text((3, 3), "original bbox", fill="black")
        draw.text((before.width + 15, 3), "translated bbox", fill="black")
        output_path.parent.mkdir(parents=True, exist_ok=True)
        out.save(output_path)
        return True
    except (OSError, ValueError, ZeroDivisionError):
        return False


def audit_page(number, source_path, payload_path, items_path, rendered_path, crop_dir, all_crops):
    result = {"sampleIndex": number, "source": str(source_path), "payload": str(payload_path) if payload_path else None,
              "items": str(items_path) if items_path else None, "render": str(rendered_path) if rendered_path else None,
              "issues": [], "boxes": []}
    if not payload_path or not items_path:
        result["issues"].append("missing-replay-artifact")
        return result
    if not rendered_path:
        result["issues"].append("missing-render-image")

    payload, rendered = load(payload_path), load(items_path)
    source_items = {str(i.get("id")): i for i in payload.get("items", [])}
    root = rendered.get("root", {})
    items = [i for i in rendered.get("items", []) if i.get("dataset", {}).get("aidokuImageOcrOverlay") == "item" and not i.get("hidden")]
    layers = rendered.get("layers", [])
    restorations = [i for i in layers if i.get("kind") == "source-panel-restoration"]
    panels = [i for i in layers if i.get("kind") == "source-readability-panel"]
    result.update(sourceCount=len(source_items), translatedCount=len(items), restorationCount=len(restorations),
                  visualPanelCount=len(panels), rendererPanelCount=int(root.get("finalReadabilityPanels", -1)),
                  sourceErasureAudit=[], forcedInpaintAudit=[])
    for field, target in (("panelRestorationAudit", "sourceErasureAudit"), ("forcedSourceInpaintAudit", "forcedInpaintAudit")):
        try:
            result[target] = json.loads(root.get(field, "[]"))
        except (TypeError, ValueError):
            result["issues"].append("invalid-" + field)
    if len(items) != len(source_items):
        result["issues"].append("translated-count-mismatch")
    if panels or result["rendererPanelCount"] > 0:
        result["issues"].append("opaque-panel")
    forced = {str(a.get("id")): a for a in result["forcedInpaintAudit"]}
    failures = [a for a in result["sourceErasureAudit"]
                if not a.get("sourceErasureVerified")
                and forced.get(str(a.get("id")), {}).get("reason") not in ("accepted", "already-certified")]
    result["outstandingSourceErasureIds"] = [str(a.get("id")) for a in failures]
    if failures:
        result["issues"].append("source-erasure-unverified")

    display = payload.get("displayRect", [0, 0, *payload.get("viewport", [0, 0])])
    source_image = render_image = None
    if rendered_path:
        try:
            source_image = Image.open(source_path).convert("RGB")
            render_image = Image.open(rendered_path).convert("RGB")
        except OSError:
            result["issues"].append("unreadable-render-image")
    for item in items:
        ident = str(item.get("region"))
        original = source_items.get(ident)
        box = item.get("box")
        if original is None or not box:
            result["boxes"].append({"id": ident, "issues": ["missing-source-match"]})
            continue
        sr = source_rect(original, display)
        br = balloon_rect(original, display)
        issues = []
        if br and rect_area(box) and rect_intersection(box, br) / rect_area(box) < 0.75:
            issues.append("outside-verified-balloon-rect")
        max_overlap, overlap_id = 0, None
        for other in items:
            if other is item or not other.get("box"):
                continue
            overlap = rect_intersection(box, other["box"]) / max(1, rect_area(box))
            if overlap > max_overlap:
                max_overlap, overlap_id = overlap, str(other.get("region"))
        if max_overlap > 0.30:
            issues.append("overlapping-translation-box")
        if item.get("background", "").startswith("rgb("):
            issues.append("opaque-translated-background")
        entry = {"id": ident, "renderBox": box, "sourceBox": sr, "balloonRect": br, "issues": issues}
        if max_overlap > 0:
            entry["maxTranslationOverlap"] = round(max_overlap, 3)
            entry["overlappingRegion"] = overlap_id
            peer_source = source_items.get(overlap_id)
            peer_box = source_rect(peer_source, display) if peer_source else None
            if sr and peer_box:
                source_overlap = rect_intersection(sr, peer_box) / max(1, rect_area(sr))
                entry["sourceOverlapWithRenderedPeer"] = round(source_overlap, 3)
                if max_overlap > 0.30:
                    entry["overlapOrigin"] = ("layout-created" if source_overlap < 0.10 else
                                              "source-already-overlapped" if source_overlap > 0.30 else
                                              "ambiguous")
        if br and br[2] > 0 and br[3] > 0:
            entry["balloonCenterOffset"] = [round((box[0] + box[2] / 2 - br[0] - br[2] / 2) / br[2], 3),
                                             round((box[1] + box[3] / 2 - br[1] - br[3] / 2) / br[3], 3)]
        if source_image and render_image and sr and (all_crops or issues or any(str(a.get("id")) == ident for a in failures)):
            crop_path = crop_dir / f"{number}-{ident}.png"
            if crop_pair(source_image, render_image, sr, box, display, crop_path):
                entry["pairCrop"] = str(crop_path)
        result["boxes"].append(entry)
    if any(b["issues"] for b in result["boxes"]):
        result["issues"].append("box-geometry-or-panel")
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--payload-dir", type=Path, required=True)
    parser.add_argument("--ocr-dir", type=Path,
                        help="Fresh OCR region JSONs; used to flag oversized, low-confidence boxes")
    parser.add_argument("--direct-report", type=Path,
                        help="Direct production inpaint audit JSON for the same pages")
    parser.add_argument("--render-dir", type=Path, required=True)
    parser.add_argument("--render-image-dir", type=Path,
                        help="Directory containing page PNGs if different from --render-dir")
    parser.add_argument("--source-text-diagnostic", action="store_true",
                        help="Payload reuses Japanese source instead of a Korean translation; image audit is inpaint/geometry only")
    parser.add_argument("--all-bbox-crops", action="store_true",
                        help="Create source/render paired crops for every matched text box, not only flagged boxes")
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    manifest = load(args.manifest)
    direct_by_page = {}
    if args.direct_report:
        for direct in load(args.direct_report).get("rows", []):
            direct_by_page.setdefault(int(direct["index"]), []).append(direct)
    rows = []
    for entry in manifest["files"]:
        number = entry["sampleIndex"]
        source = Path(entry["pngFile"])
        image_dir = args.render_image_dir or args.render_dir
        rendered_image = (find_artifact(image_dir, number, "png") or
                          find_artifact(image_dir, number, "jpg") or
                          find_artifact(image_dir, number, "jpeg"))
        row = audit_page(number, source,
                         find_artifact(args.payload_dir, number, "payload.json"),
                         find_artifact(args.render_dir, number, "items.json"),
                         rendered_image,
                         args.output_dir / "bbox-pairs", args.all_bbox_crops)
        if args.ocr_dir:
            ocr_path = find_artifact(args.ocr_dir, number, "regions.json")
            if ocr_path:
                regions = load(ocr_path)
                row["ocrCount"] = len(regions)
                row["oversizedOCR"] = []
                for region in regions:
                    rect = region.get("rect")
                    if not rect or len(rect) != 2 or len(rect[1]) != 2:
                        continue
                    area = rect[1][0] * rect[1][1]
                    if area >= 0.05:
                        row["oversizedOCR"].append({"id": region.get("id"), "areaFraction": round(area, 4),
                                                     "confidence": region.get("confidence"), "source": region.get("source")})
                if row["oversizedOCR"]:
                    row["issues"].append("oversized-ocr-bbox")
        if args.direct_report:
            direct = direct_by_page.get(number, [])
            row["directInpaint"] = {"tested": len(direct),
                                    "accepted": sum(bool(x.get("accepted")) for x in direct),
                                    "rectMasks": sum(x.get("forcedMaskMode") == "rect" for x in direct),
                                    "glyphMasks": sum(x.get("forcedMaskMode") == "glyph" for x in direct),
                                    "sourceCorePixels": sum(x.get("originalCore", 0) for x in direct),
                                    "uncoveredCorePixels": sum(x.get("remainingCore", 0) for x in direct)}
            if row.get("ocrCount") is not None and len(direct) != row["ocrCount"]:
                row["issues"].append("direct-inpaint-count-mismatch")
            if any(not x.get("accepted") or x.get("remainingCore", 0) for x in direct):
                row["issues"].append("direct-inpaint-unverified")
        rows.append(row)
    counts = Counter(issue for row in rows for issue in row["issues"])
    completed = sum("missing-replay-artifact" not in r["issues"] and "missing-render-image" not in r["issues"] for r in rows)
    result = {"sampleCount": len(rows), "sourceTextDiagnosticOnly": args.source_text_diagnostic,
              "translationQualityJudged": not args.source_text_diagnostic and completed == len(rows),
              "geometryReplays": sum("missing-replay-artifact" not in r["issues"] for r in rows),
              "completedReplays": completed,
              "issueCounts": dict(counts), "pages": rows}
    args.output_dir.mkdir(parents=True, exist_ok=True)
    (args.output_dir / "audit.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({k: result[k] for k in ("sampleCount", "geometryReplays", "completedReplays", "issueCounts")}, ensure_ascii=False))


if __name__ == "__main__":
    main()
