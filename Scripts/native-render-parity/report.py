#!/usr/bin/env python3
"""Render and check the exact native/WebKit parity report produced on iOS.

No OCR, API calls, thresholds or tolerance-based passes. Run after retrieving
Documents/NativeRenderParity from the tested simulator/device. A partially
completed suite is a failure even when all completed fixtures were exact.
"""
from __future__ import annotations

import argparse
import html
import json
from pathlib import Path


def build_report(directory: Path) -> bool:
    report = json.loads((directory / "report.json").read_text())
    rows = report.get("fixtures", [])
    from PIL import Image
    import numpy as np
    identifiers = [row.get("id") for row in rows]
    complete = (report.get("expectedFixtureCount", 0) > 0 and len(rows) == report["expectedFixtureCount"]
                and report.get("completedFixtureCount") == len(rows) and len(set(identifiers)) == len(identifiers))
    decoded_exact = True
    for row in rows:
        try:
            with Image.open(directory / row["id"] / "web.png") as source:
                web = np.asarray(source.convert("RGBA"))
            with Image.open(directory / row["id"] / "native.png") as source:
                native = np.asarray(source.convert("RGBA"))
            exact = web.shape == native.shape and np.array_equal(web, native)
            decoded_exact = decoded_exact and exact
            row["independentlyDecodedExact"] = bool(exact)
        except (OSError, KeyError, ValueError) as error:
            decoded_exact = False
            row["independentDecodeError"] = str(error)
    passed = complete and decoded_exact and report.get("passed") is True and report.get("gate") == "exact-decoded-RGBA" and all(
        row.get("status") == "exact" and row.get("differentPixels") == 0
        and row.get("maximumChannelDelta") == 0
        and isinstance(row.get("webRGBAHash"), str) and len(row["webRGBAHash"]) == 64
        and row.get("webRGBAHash") == row.get("nativeRGBAHash")
        and all((directory / row["id"] / name).is_file() for name in ("web.png", "native.png", "diff.png"))
        for row in rows
    )
    panels = []
    for row in rows:
        fixture_id = html.escape(row["id"])
        metrics = html.escape(json.dumps(row, indent=2))
        images = "".join(
            f'<figure><figcaption>{name}</figcaption><img src="{fixture_id}/{name}.png" '
            f'alt="{fixture_id} {name}" loading="lazy"></figure>' for name in ("web", "native", "diff")
        )
        panels.append(f'<article><h2>{fixture_id}: {html.escape(row["status"])}</h2>'
                      f'<div class="images">{images}</div><details><summary>Pixel metrics</summary>'
                      f'<pre>{metrics}</pre></details></article>')
    summary = f'Exact parity: {"PASS" if passed else "FAIL"}. {len(rows)}/{report.get("expectedFixtureCount", 0)} fixtures completed.'
    page = '''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Native translation pixel parity</title><style>
body{font:16px system-ui;margin:24px;background:#111827;color:#f3f4f6}h1{font-size:24px}
.images{display:flex;gap:12px;align-items:flex-start}figure{margin:0;flex:1;min-width:0}
img{width:100%;height:auto;background:repeating-conic-gradient(#ddd 0% 25%,#fff 0% 50%) 50%/12px 12px}
figcaption{padding:6px;background:#334155}article{border-top:1px solid #64748b;margin-top:28px;padding-top:12px}
pre{white-space:pre-wrap}details{margin:12px 0}</style><h1>''' + html.escape(summary) + '</h1>' + ''.join(panels) + '</html>'
    (directory / "index.html").write_text(page)
    print(summary)
    for row in rows:
        print(f'{row["id"]}: {row["status"]}, different pixels={row.get("differentPixels", "unavailable")}, '
              f'maximum channel delta={row.get("maximumChannelDelta", "unavailable")}')
    print(f'Report: {directory / "index.html"}')
    return passed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    return 0 if build_report(args.directory) else 1


if __name__ == "__main__":
    raise SystemExit(main())
