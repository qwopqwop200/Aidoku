#!/usr/bin/env python3
"""Measure production Reader milestones from one single-page, single-chapter capture.

Pass reader-memory-events.previous.log and reader-memory-events.log from Documents
in one app container. Keep translation and its overlay enabled throughout the run.
Visit uncached pages, revisit warmed pages, and turn to adjacent pages repeatedly.
The output records application milestones, not physical display refresh or touch time.
"""
import argparse
import json
import math
from collections import Counter, defaultdict

from reader_pipeline_report import read_events


def distribution(values):
    values = sorted(values)
    def percentile(fraction):
        return round(values[math.ceil(len(values) * fraction) - 1], 3) if values else None
    return {"n": len(values), "p50_ms": percentile(.50), "p95_ms": percentile(.95),
            "within_1s": sum(v <= 1000 for v in values),
            "within_2s": sum(v <= 2000 for v in values),
            "within_3s": sum(v <= 3000 for v in values)}


def summarize(rows):
    groups = defaultdict(list)
    omissions = Counter()
    processes = defaultdict(list)
    for row in rows:
        if "reader_event" in row and "pid" in row:
            processes[row["pid"]].append(row)
    for events in processes.values():
        pending = {}
        page = None
        turn = None
        last_seq = None
        single = False
        for row in sorted(events, key=lambda event: int(event["seq"])):
            seq = int(row["seq"])
            if ((last_seq is not None and seq != last_seq + 1)
                    or int(row.get("dropped", 0)) or int(row.get("write_failures", 0))):
                omissions["interrupted_presentation"] += len(pending)
                omissions["interrupted_turn"] += int(turn is not None)
                pending.clear()
                turn, page, single = None, None, False
            last_seq = seq
            event = row["event"]
            token = row.get("page_token")
            key = (row.get("trace"), token)
            if token and token != "0" and key[0]:
                if event == "loaded_presentation_begin":
                    pending[key] = set()
                elif key in pending:
                    markers = pending[key]
                    if event in ("loaded_composite_memory_hit", "render_asset_replayed", "export_render_end"):
                        if int(row.get("outcome", 0)) == 0:
                            markers.add(event)
                    elif event == "loaded_presentation_end":
                        duration = float(row["elapsed_ms"])
                        if len(markers) == 1 and row.get("outcome") == "0" and math.isfinite(duration) and duration >= 0:
                            groups[next(iter(markers))].append(duration)
                        else:
                            omissions["failed_or_unclassified_presentation"] += 1
                        del pending[key]
            if event == "visible_window":
                omissions["turn_without_observed_frame"] += int(turn is not None)
                turn = None
                single = row.get("count") == "1"
                if not single:
                    page = None
            elif event == "visible_page" and single and token and token != "0":
                index = int(row["page"])
                if page is not None and index > 0 and abs(index - page) == 1:
                    turn = (token, float(row["uptime"]))
                page = index if index > 0 else None
            elif turn and token == turn[0] and event in ("visible_bitmap_attached", "visible_live_committed"):
                if event == "visible_bitmap_attached" and min(int(row["code"]), int(row["count"])) <= 0:
                    continue
                elapsed = (float(row["uptime"]) - turn[1]) * 1000
                if elapsed >= 0:
                    groups["turn"].append(elapsed)
                    turn = None
        omissions["turn_without_observed_frame"] += int(turn is not None)
        omissions["incomplete_presentation"] += len(pending)
    return {
        "boundary_presentation": "Coordinator prepareCachedImage entry to return, decoded source already supplied. Cold = fresh native render; hits = completed bitmap in memory or asset replay. Excludes initial page download and is not whole-chapter cold OCR/API latency.",
        "boundary_turn": "Adjacent visible_page to first subsequent matching bitmap attachment or live commit, including provisional. Previously attached pages without a new frame are censored. Captures must stay in one chapter with visible translation enabled.",
        "percentile": "nearest rank among observed completions",
        "render_cold": distribution(groups["export_render_end"]),
        "render_hit_bitmap": distribution(groups["loaded_composite_memory_hit"]),
        "render_hit_asset": distribution(groups["render_asset_replayed"]),
        "adjacent_turn_observed_frame": distribution(groups["turn"]),
        "omissions": dict(omissions),
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("logs", nargs="+")
    args = parser.parse_args()
    print(json.dumps(summarize(read_events(args.logs)), indent=2))
