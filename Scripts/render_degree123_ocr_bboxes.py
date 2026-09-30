#!/usr/bin/env python3
"""Render full-page OCR geometry for the saved Zerodo/Degree123 corpus.

Red means OCR classified a region as horizontal, cyan means vertical, and
yellow means unknown. The complete source page is retained below the legend.
The matching JSON lists every label's source text without covering the art.
"""

import argparse
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


def points_for(region, width, height, top):
    polygon = region.get("polygon")
    if polygon and len(polygon) >= 3:
        return [(round(x * width), round(y * height) + top) for x, y in polygon]
    rect = region.get("rect")
    if isinstance(rect, list) and len(rect) == 2:
        (x, y), (w, h) = rect
    elif isinstance(rect, list) and len(rect) == 4:
        x, y, w, h = rect
    else:
        return []
    x, y, w, h = x * width, y * height + top, w * width, h * height
    return [(round(x), round(y)), (round(x + w), round(y)),
            (round(x + w), round(y + h)), (round(x), round(y + h))]


def color_for(orientation):
    orientation = str(orientation).lower()
    if "horizontal" in orientation:
        return (244, 41, 54, 255)
    if "vertical" in orientation:
        return (0, 224, 224, 255)
    return (255, 211, 36, 255)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--replay", type=Path,
                        help="Optional directory of *.replay.json with afterCoreMLOCR")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    font_path = "/System/Library/Fonts/Supplemental/Arial.ttf"
    font = ImageFont.truetype(font_path, 25)
    title_font = ImageFont.truetype(font_path, 31)
    entries = []
    for original in sorted((args.corpus / "original-png").glob("[0-9][0-9][0-9][0-9].png")):
        name = original.stem
        cached_path = args.corpus / "ocr-regions" / f"{name}.regions.json"
        if not cached_path.exists():
            raise SystemExit(f"Missing OCR regions for full page {name}: {cached_path}")
        if args.replay:
            replay_path = args.replay / f"{name}.replay.json"
            if not replay_path.exists():
                continue
            regions = json.loads(replay_path.read_text())["afterCoreMLOCR"]
            source_kind = "current CoreML replay"
        else:
            regions = json.loads(cached_path.read_text())
            source_kind = "preserved device OCR cache"
        with Image.open(original) as source:
            source = source.convert("RGB")
            width, height = source.size
            top = 78
            rendered = Image.new("RGB", (width, height + top), (19, 24, 32))
            rendered.paste(source, (0, top))
        draw = ImageDraw.Draw(rendered, "RGBA")
        draw.text((18, 17), f"{name} | {source_kind} | OCR {len(regions)}",
                  fill=(255, 255, 255, 255), font=title_font)
        legend = [("VERTICAL", color_for("vertical")),
                  ("HORIZONTAL", color_for("horizontal")),
                  ("UNKNOWN", color_for("unknown"))]
        legend_x = max(720, width - 760)
        for label, color in legend:
            draw.rectangle((legend_x, 24, legend_x + 21, 45), fill=color)
            draw.text((legend_x + 28, 19), label, fill=(255, 255, 255, 255), font=font)
            legend_x += 245 if label != "UNKNOWN" else 0
        rows = []
        for index, region in enumerate(regions):
            orientation = region.get("orientation", "unknown")
            color = color_for(orientation)
            polygon = points_for(region, width, height, top)
            if not polygon:
                raise SystemExit(f"Missing bbox for {name} region {index}")
            draw.polygon(polygon, fill=(*color[:3], 25))
            draw.line(polygon + [polygon[0]], fill=color, width=5, joint="curve")
            label = f"{index:02d} {region.get('confidence', 0):.2f}"
            x = min(max(0, min(p[0] for p in polygon)), width - 125)
            y = max(top, min(p[1] for p in polygon) - 30)
            label_box = draw.textbbox((x + 4, y), label, font=font)
            draw.rectangle((x, y, label_box[2] + 4, label_box[3] + 3),
                           fill=(12, 16, 20, 215))
            draw.text((x + 4, y), label, font=font, fill=color)
            rows.append({"index": index, "id": region.get("id", f"region-{index}"),
                         "orientation": orientation, "confidence": region.get("confidence"),
                         "source": region.get("source", ""), "polygon": region.get("polygon"),
                         "rect": region.get("rect")})
        image_path = args.out / f"{name}.png"
        rendered.save(image_path, optimize=True)
        (args.out / f"{name}.json").write_text(json.dumps({
            "page": int(name), "source": str(original), "ocrSource": source_kind,
            "fullOriginalSize": [width, height], "rendered": str(image_path),
            "horizontalCount": sum("horizontal" in str(r["orientation"]).lower() for r in rows),
            "verticalCount": sum("vertical" in str(r["orientation"]).lower() for r in rows),
            "regions": rows}, ensure_ascii=False, indent=2))
        entries.append({"page": int(name), "image": str(image_path),
                        "regions": len(rows), "horizontal": sum(
                            "horizontal" in str(r["orientation"]).lower() for r in rows)})
    (args.out / "manifest.json").write_text(json.dumps({
        "corpus": str(args.corpus), "pages": entries,
        "colorKey": {"vertical": "cyan", "horizontal": "red", "unknown": "yellow"}},
        ensure_ascii=False, indent=2))
    print(f"Rendered {len(entries)} full OCR bbox pages to {args.out}")


if __name__ == "__main__":
    main()
