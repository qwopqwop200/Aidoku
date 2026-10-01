#!/usr/bin/env python3
"""Render and independently check native/Web final-image comparison reports.

Current final exports permit bounded low/sparse deltas or a certified common edge displacement.
Earlier sparse-rounding and exact reports retain their original declared policies.
Historical exact-decoded-RGBA reports keep their original zero-difference rule.
Incomplete runs, missing artifacts, changed dimensions and larger differences fail.
"""
from __future__ import annotations

import argparse
import html
import re
import json
from pathlib import Path


def common_displacement(reference, actual):
    """Bounded final-export certificate; no per-pixel free alignment or search."""
    import numpy as np
    if reference.shape != actual.shape or reference.ndim != 3 or reference.shape[2] != 4:
        return None
    height, width = reference.shape[:2]
    if not width or not height or not np.array_equal(reference[:, :, 3], actual[:, :, 3]):
        return None
    changed_mask = np.any(reference != actual, axis=2)
    changed = int(np.count_nonzero(changed_mask))
    if changed == 0 or changed > width * height // 1000:
        return None
    ys, xs = np.nonzero(changed_mask)
    min_x, min_y, max_x, max_y = int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())
    if min_x < 2 or min_y < 2 or max_x >= width - 2 or max_y >= height - 2:
        return None
    x0, y0, x1, y1 = min_x - 2, min_y - 2, max_x + 3, max_y + 3
    if (x1 - x0) * (y1 - y0) > 65_536:
        return None
    left = reference[y0:y1, x0:x1].astype(np.int64)
    right = actual[y0:y1, x0:x1].astype(np.int64)
    if np.any(left[:, :, 3] != 255):
        return None
    delta = right - left
    if np.any(delta.sum(axis=(0, 1)) != 0):
        return None
    border = np.ones(left.shape[:2], dtype=bool)
    border[2:-2, 2:-2] = False
    if np.any(left[border] != left[0, 0]) or np.any(right[border] != left[0, 0]):
        return None
    original = left[1:-1, 1:-1, :3].astype(np.float64)
    candidate = right[1:-1, 1:-1, :3].astype(np.float64)
    for axis in range(2):
        if np.any(delta.sum(axis=axis) != 0):
            continue
        for direction in (-1, 1):
            neighbor = (left[:-2, 1:-1, :3] if direction == 1 else left[2:, 1:-1, :3]) if axis == 0 else (
                left[1:-1, :-2, :3] if direction == 1 else left[1:-1, 2:, :3])
            step = neighbor.astype(np.float64) - original
            denominator = float(np.sum(step * step))
            if denominator == 0:
                continue
            coverage = float(np.sum((candidate - original) * step)) / denominator
            if not 0 < coverage <= 1:
                continue
            residual = float(np.max(np.abs(candidate - original - coverage * step)))
            if residual > 1:
                continue
            return {"axis": "y" if axis == 0 else "x", "direction": direction, "coverage": coverage,
                    "changedPixels": changed, "bounds": [x0, y0, x1, y1], "maximumFitResidual": residual,
                    "opaqueUnchangedBorder": True, "exactChannelMass": True, "exactProjectedMass": True}
    return None


def build_report(directory: Path) -> bool:
    report = json.loads((directory / "report.json").read_text())
    rows = report.get("fixtures", [])
    from PIL import Image
    import numpy as np
    identifiers = [row.get("id") for row in rows]
    complete = (report.get("expectedFixtureCount", 0) > 0 and len(rows) == report["expectedFixtureCount"]
                and report.get("completedFixtureCount") == len(rows) and len(set(identifiers)) == len(identifiers))
    gate = report.get("gate")
    rounding_gate = gate == "final-export-raster-acceptance"
    policy = report.get("acceptancePolicy")
    bounded_policy = "same dimensions; RGBA channel delta <= 4, or <= 16 on at most 0.1% changed pixels"
    previous_displacement_policy = bounded_policy + "; or bounded common axis displacement <= 1 physical pixel"
    current_policy = ("same dimensions; RGBA channel delta <= 4 anywhere; delta <= 16 on at most 0.1% pixels over delta 4; "
                      "or bounded common axis displacement <= 1 physical pixel")
    low_only_policy = "same dimensions; maximum RGBA channel delta 4"
    sparse_policy = "same dimensions; at most 0.01% changed pixels; maximum channel delta 1"
    legacy_sparse = policy == sparse_policy
    composed_color = policy == current_policy
    displacement_policy = policy in (current_policy, previous_displacement_policy)
    bounded_sparse = policy in (current_policy, previous_displacement_policy, bounded_policy)
    maximum_allowed = 1 if legacy_sparse else 255 if displacement_policy else 16 if bounded_sparse else 4
    accepted_counter = "acceptedRoundingFixtureCount" if legacy_sparse else "acceptedLowDeltaFixtureCount"
    valid_gate = gate == "exact-decoded-RGBA" or (rounding_gate and policy in (current_policy, previous_displacement_policy, bounded_policy, low_only_policy, sparse_policy))
    row_checks = []
    exact_count = rounding_count = sparse_count = displacement_count = mismatch_count = 0
    for row in rows:
        try:
            with Image.open(directory / row["id"] / "web.png") as source:
                web = np.asarray(source.convert("RGBA"))
            with Image.open(directory / row["id"] / "native.png") as source:
                native = np.asarray(source.convert("RGBA"))
            same_size = web.shape == native.shape and web.shape[0] > 0 and web.shape[1] > 0
            changed = maximum = stronger = None
            if same_size:
                delta = np.abs(web.astype(np.int16) - native.astype(np.int16))
                changed = int(np.count_nonzero(np.any(delta != 0, axis=2)))
                maximum = int(delta.max())
                stronger = int(np.count_nonzero(np.max(delta, axis=2) > 4))
            exact = same_size and changed == 0
            pixels = web.shape[0] * web.shape[1]
            sparse_counted_pixels = stronger if composed_color else changed
            sparse_acceptance = (same_size and bounded_sparse and 4 < maximum <= 16 and sparse_counted_pixels <= pixels // 1000)
            accepted = (same_size and (maximum <= (1 if legacy_sparse else 4) or sparse_acceptance)
                        and (not legacy_sparse or changed <= pixels // 10_000))
            displacement = common_displacement(web, native) if same_size and displacement_policy and not accepted else None
            accepted = accepted or displacement is not None
            accepted_status = ("accepted-common-displacement" if displacement is not None else
                               "accepted-rounding" if legacy_sparse else
                               "accepted-sparse-delta" if sparse_acceptance else "accepted-low-delta")
            row["independentlyDecodedExact"] = bool(exact)
            row["independentlyAcceptedFinalExportPixels"] = bool(accepted if rounding_gate else exact)
            row["independentDifferentPixels"] = changed
            row["independentMaximumChannelDelta"] = maximum
            row["independentPixelsOverLowDeltaLimit"] = stronger
            if displacement is not None:
                row["independentCommonDisplacement"] = displacement
            if exact:
                exact_count += 1
            elif rounding_gate and accepted:
                if displacement is not None:
                    displacement_count += 1
                elif sparse_acceptance:
                    sparse_count += 1
                else:
                    rounding_count += 1
            else:
                mismatch_count += 1
            reported_changed = row.get("differentPixels")
            reported_maximum = row.get("maximumChannelDelta")
            valid_metrics = (same_size and type(reported_changed) is int and type(reported_maximum) is int
                             and row.get("width") == web.shape[1] and row.get("height") == web.shape[0]
                             and reported_changed == changed and reported_maximum == maximum
                             and (not composed_color or (type(row.get("pixelsOverLowDeltaLimit")) is int
                                  and row["pixelsOverLowDeltaLimit"] == stronger)))
            hashes = [row.get("webRGBAHash"), row.get("nativeRGBAHash")]
            valid_hashes = all(isinstance(value, str) and re.fullmatch(r"[0-9a-fA-F]{64}", value) for value in hashes)
            artifacts = all((directory / row["id"] / name).is_file() for name in ("web.png", "native.png", "diff.png"))
            if rounding_gate:
                expected_status = "exact" if exact else accepted_status if accepted else "mismatch"
                row_passed = (accepted and valid_metrics and valid_hashes and artifacts
                              and row.get("status") == expected_status
                              and row.get("equalDecodedPixels") is bool(exact)
                              and row.get("acceptedFinalExportPixels") is True
                              and row.get("acceptancePolicy") == policy
                              and (displacement is None or row.get("commonDisplacement") == displacement)
                              and (not exact or (reported_changed == 0 and reported_maximum == 0 and hashes[0] == hashes[1]))
                              and (exact or (reported_changed > 0 and 1 <= reported_maximum <= maximum_allowed and hashes[0] != hashes[1])))
            else:
                row_passed = (exact and valid_metrics and valid_hashes and artifacts and row.get("status") == "exact"
                              and reported_changed == 0 and reported_maximum == 0 and hashes[0] == hashes[1])
            row_checks.append(bool(row_passed))
        except (OSError, KeyError, ValueError) as error:
            row_checks.append(False)
            mismatch_count += 1
            row["independentDecodeError"] = str(error)
    counters_match = (not rounding_gate or (report.get("exactFixtureCount") == exact_count
                      and report.get(accepted_counter) == rounding_count
                      and (not bounded_sparse or report.get("acceptedSparseDeltaFixtureCount") == sparse_count)
                      and (not displacement_policy or report.get("acceptedCommonDisplacementFixtureCount") == displacement_count)))
    passed = complete and valid_gate and counters_match and report.get("passed") is True and all(row_checks)
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
    label = "Final-export acceptance" if rounding_gate else "Exact parity"
    accepted_label = 'accepted rounding' if legacy_sparse else 'accepted low-delta'
    summary = (f'{label}: {"PASS" if passed else "FAIL"}. {len(rows)}/{report.get("expectedFixtureCount", 0)} fixtures completed. '
               f'{exact_count} exact, {rounding_count} {accepted_label}, {sparse_count} accepted sparse-delta, '
               f'{displacement_count} accepted common-displacement, {mismatch_count} mismatches/errors.')
    policy_text = policy if rounding_gate else "every decoded RGBA pixel must match"
    page = '''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Native translation pixel parity</title><style>
body{font:16px system-ui;margin:24px;background:#111827;color:#f3f4f6}h1{font-size:24px}
.images{display:flex;gap:12px;align-items:flex-start}figure{margin:0;flex:1;min-width:0}
img{width:100%;height:auto;background:repeating-conic-gradient(#ddd 0% 25%,#fff 0% 50%) 50%/12px 12px}
figcaption{padding:6px;background:#334155}article{border-top:1px solid #64748b;margin-top:28px;padding-top:12px}
pre{white-space:pre-wrap}details{margin:12px 0}</style><h1>''' + html.escape(summary) + '</h1><p>' + html.escape(policy_text) + '</p>' + ''.join(panels) + '</html>'
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
