"""Check whether verified native speech-balloon centers lie inside their own contour bands.

Usage: python3 balloon-native-center-corpus-audit.py REGIONS_DIR OUTPUT_JSON IDS_JSON
This uses OCR geometry only; it does not assert that translated glyphs fit.
"""

import json
import pathlib
import sys


def run(directory: pathlib.Path, ids: list[str]):
    missing = []
    verified = 0
    outside = []
    for page in ids:
        source = directory / f"{page}.regions.json"
        if not source.is_file() and page.isdecimal():
            source = directory / f"{int(page):04}.regions.json"
        if not source.is_file():
            missing.append(page)
            continue
        for region in json.loads(source.read_text()):
            contour = region.get("balloonInterior") or {}
            if not contour.get("contourVerified"):
                continue
            verified += 1
            rect, center, spans = contour["rect"], contour["center"], contour["spans"]
            top, height = rect[0][1], rect[1][1]
            bands = len(spans) // 2
            row = max(0, min(bands - 1, int((center[1] - top) / height * bands)))
            left, right = spans[row * 2:row * 2 + 2]
            if left < 0 or not left <= center[0] <= right:
                outside.append({"page": page, "region": region["id"], "band": row,
                                "centerX": center[0], "bandX": [left, right]})
    return {"pagesExpected": len(ids), "missing": missing, "verifiedContours": verified,
            "centersOutsideContour": outside}


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit("Pass REGIONS_DIR OUTPUT_JSON IDS_JSON")
    entries = json.loads(pathlib.Path(sys.argv[3]).read_text())
    if isinstance(entries, dict):
        entries = entries.get("cachedPages", entries.get("originals", []))
    ids = [str(entry.get("id", entry.get("page", entry.get("sampleIndex")))
               if isinstance(entry, dict) else entry) for entry in entries]
    if not ids or len(ids) != len(set(ids)) or "None" in ids:
        raise SystemExit("Invalid page ID list")
    result = run(pathlib.Path(sys.argv[1]), ids)
    pathlib.Path(sys.argv[2]).write_text(json.dumps(result, ensure_ascii=False, indent=2))
    print(json.dumps({"missing": len(result["missing"]), "verifiedContours": result["verifiedContours"],
                      "centersOutsideContour": len(result["centersOutsideContour"])}))
    if result["missing"] or result["verifiedContours"] == 0:
        raise SystemExit(1)
