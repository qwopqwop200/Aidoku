#!/usr/bin/env python3
"""Bounded target/source ownership checks, without renderer, model or provider calls."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "owner_controls", Path(__file__).with_name("run-source-owner-recovery-smoke.py"))
previous = importlib.util.module_from_spec(spec)
spec.loader.exec_module(previous)

# Run all existing metadata and strict nested-owner controls unchanged as well.
SWIFT = previous.SWIFT.split("let pages = try JSONSerialization")[0] + r'''
func partition(_ parts: [(item: [String: Any], row: [String: Any])], enabled: Bool = true,
               _ image: CGSize = size) -> NativeSourceOwnerRecovery.TargetOwnershipResult {
    NativeSourceOwnerRecovery.partitionRedundantTargets(parts.map(\.item), evidence: packet(parts.map(\.row)),
        imageSize: image, enabled: enabled)
}
func intact(_ result: NativeSourceOwnerRecovery.TargetOwnershipResult, _ original: [[String: Any]]) {
    check(bytes(result.sourceItems) == bytes(original), "every original mask/palette owner retained exactly")
    for item in result.displayItems {
        let before = original.first { $0["id"] as? String == item["id"] as? String }!
        var stripped = item
        if let existing = before["sourceOwnerConsolidatedChildren"] {
            stripped["sourceOwnerConsolidatedChildren"] = existing
        } else { stripped.removeValue(forKey: "sourceOwnerConsolidatedChildren") }
        check(bytes([stripped]) == bytes([before]), "retained display text/style/geometry unchanged")
    }
}
let longBody = plain("long-body", "前の長い文章と最後の続きです…", "앞쪽 본문과 마지막 이어지는 문장...", [0.1, 0.1, 0.12, 0.3])
var longChild = plain("long-child", "最後の続きです…", "마지막 이어지는 문장...", [0.105, 0.098, 0.03, 0.33])
longChild.row["sourceSingleVerticalColumn"] = true
let longParts = [longBody, longChild], longItems = longParts.map(\.item)
let targetPartition = partition(longParts)
check(targetPartition.displayItems.count == 1 && targetPartition.sourceItems.count == 2, "long tail display partition")
intact(targetPartition, longItems)
let displayChildren = targetPartition.displayItems[0]["sourceOwnerConsolidatedChildren"] as! [[String: Any]]
check(displayChildren[0]["source"] as? String == longChild.row["source"] as? String &&
    displayChildren[0]["translation"] as? String == longChild.item["text"] as? String, "exact child strings retained")
check(partition(longParts, enabled: false).audit.isEmpty &&
    bytes(partition(longParts, enabled: false).displayItems) == bytes(longItems), "new policy disabled by default")
check(bytes(partition([longBody, longChild], CGSize(width: 999, height: 1000)).displayItems) == bytes(longItems),
    "dimension mismatch")
let replay = NativeSourceOwnerRecovery.partitionRedundantTargets(targetPartition.displayItems,
    evidence: packet(longParts.map(\.row)), imageSize: size, enabled: true)
check(bytes(replay.displayItems) == bytes(targetPartition.displayItems), "display replay idempotent")
let strictLong = NativeSourceOwnerRecovery.consolidateNestedOwners(longItems, evidence: packet(longParts.map(\.row)),
    imageSize: size, enabled: true)
check(strictLong.items.count == 2, "strict physical consolidation remains unchanged")
var prefixLong = plain("prefix-body", "最初の言葉です続く本文です", "처음 나오는 문장 뒤의 본문", [0.1, 0.1, 0.12, 0.3])
var prefixLongChild = plain("prefix-child", "最初の言葉です", "처음 나오는 문장", [0.185, 0.098, 0.03, 0.31])
prefixLongChild.row["sourceSingleVerticalColumn"] = true
check(partition([prefixLong, prefixLongChild]).displayItems.count == 1, "long prefix at rightmost source column")
for key in ["keptLettering", "sourceTextOnly", "vertical", "uprightQuadText", "drawsUprightQuadText"] {
    var held = longChild; held.item[key] = true
    check(partition([longBody, held]).displayItems.count == 2, "protected display: \(key)")
}
var weak = longChild; weak.row["confidence"] = 0.89
check(partition([longBody, weak]).displayItems.count == 2, "low-confidence child")
var changedTarget = longChild; changedTarget.item["text"] = "변경된 번역"
check(partition([longBody, changedTarget]).displayItems.count == 2, "stale target")
var missingSource = longChild; missingSource.row["source"] = "別の新しい言葉です…"
check(partition([longBody, missingSource]).displayItems.count == 2, "distinct missing source even with matching target")
var uniqueTarget = longChild; uniqueTarget.row["translation"] = "별도로 남길 번역"; uniqueTarget.item["text"] = "별도로 남길 번역"
check(partition([longBody, uniqueTarget]).displayItems.count == 2, "distinct target even with matching source")
var uniqueMark = longChild
uniqueMark.item["text"] = "마지막 이어지는 문장...!"; uniqueMark.row["translation"] = uniqueMark.item["text"]
check(partition([longBody, uniqueMark]).displayItems.count == 2, "unique target punctuation preserved")
var sourceMark = longChild; sourceMark.row["source"] = "最後の続きです…!"
check(partition([longBody, sourceMark]).displayItems.count == 2, "unique source punctuation preserved")
var repeatedSource = longBody; repeatedSource.row["source"] = "最後の続きです…前の長い文章と最後の続きです…"
check(partition([repeatedSource, longChild]).displayItems.count == 2, "repeated source")
var repeatedTranslation = longBody
repeatedTranslation.item["text"] = "마지막 이어지는 문장... 앞쪽 본문과 마지막 이어지는 문장..."
repeatedTranslation.row["translation"] = repeatedTranslation.item["text"]
check(partition([repeatedTranslation, longChild]).displayItems.count == 2, "repeated target")
var clippedLong = longChild
clippedLong.row["sourceGeometryObservation"] = ["rectClipped": true, "polygonClipped": false]
check(partition([longBody, clippedLong]).displayItems.count == 2, "clipped observation")
var alternateLong = longChild; alternateLong.row["sourceOCRAlternatives"] = [["exactReading": "別の字"]]
check(partition([longBody, alternateLong]).displayItems.count == 2, "alternative OCR requires upstream reconciliation")
var paragraphsLong = longChild; paragraphsLong.item["paragraphID"] = "other"
var parentParagraph = longBody; parentParagraph.item["paragraphID"] = "first"
check(partition([parentParagraph, paragraphsLong]).displayItems.count == 2, "explicit source paragraph conflict")
var unknownColumn = longChild; unknownColumn.row.removeValue(forKey: "sourceSingleVerticalColumn")
check(partition([longBody, unknownColumn]).displayItems.count == 2, "unobserved source column")
var duplicateLong = longChild; duplicateLong.item["id"] = "long-body"
check(partition([longBody, duplicateLong]).displayItems.count == 2, "duplicate owner identity")
let below = plain("long-child", "最後の続きです…", "마지막 이어지는 문장...", [0.105, 0.2, 0.03, 0.3])
var belowColumn = below; belowColumn.row["sourceSingleVerticalColumn"] = true
check(partition([longBody, belowColumn]).displayItems.count == 2, "insufficient vertical source overlap")
var wrongColumn = plain("long-child", "最後の続きです…", "마지막 이어지는 문장...", [0.185, 0.098, 0.03, 0.33])
wrongColumn.row["sourceSingleVerticalColumn"] = true
check(partition([longBody, wrongColumn]).displayItems.count == 2, "tail cannot move to right source column")
var rotatedQuad = longChild
rotatedQuad.item["sourcePolygon"] = [[0.105, 0.098], [0.135, 0.099], [0.134, 0.428], [0.105, 0.428]]
rotatedQuad.row["polygon"] = rotatedQuad.item["sourcePolygon"]
check(partition([longBody, rotatedQuad]).displayItems.count == 2, "slanted source not certified by bbox overlap")
var unboundQuad = longChild; unboundQuad.item["sourcePolygon"] = longBody.item["sourcePolygon"]
check(partition([longBody, unboundQuad]).displayItems.count == 2, "source polygon binding")
var secondChild = plain("competitor", "最後の続きです…", "마지막 이어지는 문장...", [0.106, 0.099, 0.029, 0.329])
secondChild.row["sourceSingleVerticalColumn"] = true
check(partition([longBody, longChild, secondChild]).displayItems.count == 3, "competing exact target span")
let secondBody = plain("second-body", "別の文章と最後の続きです…", "별도 본문과 마지막 이어지는 문장...", [0.099, 0.099, 0.122, 0.302])
check(partition([longBody, secondBody, longChild]).displayItems.count == 3, "ambiguous physical parent")
var normalizedBody = longBody
normalizedBody.item["text"] = "앞쪽 본문과\n\n마지막 이어지는 문장..."
normalizedBody.item["sourceOwnerCanonicalTranslation"] = longBody.item["text"]
check(partition([normalizedBody, longChild]).displayItems.count == 1, "authorized target whitespace normalization")
let pages = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: Any]]
var reports: [[String: Any]] = []
for page in pages {
    let dimensions = page["size"] as! [Double], original = page["items"] as! [[String: Any]]
    let evidence = page["evidence"] as! [String: Any], image = CGSize(width: dimensions[0], height: dimensions[1])
    let disabled = NativeSourceOwnerRecovery.partitionRedundantTargets(original, evidence: evidence, imageSize: image)
    check(bytes(disabled.displayItems) == bytes(original) && disabled.audit.isEmpty, "actual default preserves everything")
    let strict = NativeSourceOwnerRecovery.consolidateNestedOwners(original, evidence: evidence, imageSize: image, enabled: true)
    let result = NativeSourceOwnerRecovery.partitionRedundantTargets(strict.items, evidence: evidence, imageSize: image, enabled: true)
    intact(result, strict.items)
    let transfers = result.audit.filter { $0["action"] as? String == "partitionRedundantTargetOwner" }
    check(result.sourceItems.count - result.displayItems.count == transfers.count, "display/source owner accounting")
    reports.append(["id": page["id"]!, "audit": result.audit, "strictAudit": strict.audit,
        "sourceOwnerCount": result.sourceItems.count, "displayOwnerCount": result.displayItems.count,
        "displayItems": transfers.isEmpty ? [] : result.displayItems])
}
print(String(data: bytes(["existingAndNewSyntheticControlsPassed": true, "pages": reports]), encoding: .utf8)!)
'''


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_page(base, page_id):
    folder = base / "render-inputs/current836/pages" / page_id
    payload_path = folder / "001-render-payload.json"
    payload = json.loads(payload_path.read_text())["value"]
    ocr_path = folder / "original-ocr.json"
    descriptor = payload["nativeEnsembleEvidence"]["originalOCR"]
    assert digest(ocr_path) == descriptor["fileSHA256"], page_id
    assert digest(folder / "input.png") == descriptor["artifactSourceSHA256"], page_id
    assert descriptor["artifactSourceSHA256"] == payload["nativeEnsembleEvidence"]["sourceSHA256"], page_id
    ocr = json.loads(ocr_path.read_text())
    # Explicit scalar/geometry projection: probability bytes never leave this reader.
    keys = ("source", "translation", "confidence", "polygon", "sourceOrientation",
            "sourceSingleVerticalColumn", "sourceOCRAlternatives", "clippedUnitMemberIndices")
    rows = []
    for region in ocr["regions"]:
        row = {key: region[key] for key in keys if key in region}
        row["sourceBounds"] = [region["rect"][key] for key in ("x", "y", "width", "height")]
        xy = [(p["x"], p["y"]) if isinstance(p, dict) else p for p in region.get("polygon", [])]
        x, y, width, height = row["sourceBounds"]
        row["sourceGeometryObservation"] = dict(
            rectClipped=not (x >= 0 and y >= 0 and x + width <= 1 and y + height <= 1),
            polygonClipped=any(not (0 <= x <= 1 and 0 <= y <= 1) for x, y in xy))
        rows.append(row)
    items = payload["nativeLayout"]["items"]
    logs = []
    actual = base / "rendered-parallel836-triple-contained-main-v55/actual" / page_id
    for path in sorted(actual.glob("*.json")):
        document = json.loads(path.read_text())
        record = dict(path=str(path), sha256=digest(path), bytes=path.stat().st_size)
        if path.name == "main-ensemble-evaluation.json":
            record["baselineSourceOwnerRecovery"] = document["report"]["sourceOwnerRecovery"]
            record["baselineRetainedOwnerIDs"] = [item["id"] for item in document["renderItems"]]
        logs.append(record)
    assert any(Path(log["path"]).name == "main-ensemble-evaluation.json" for log in logs), page_id
    return dict(id=page_id, size=[ocr["width"], ocr["height"]], items=items,
                evidence={"originalOCR": dict(width=ocr["width"], height=ocr["height"], regions=rows)}), logs


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-root", type=Path, required=True)
    parser.add_argument("--relation-evaluator", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    ids = ["0580", "0827", "0602", "0708", "0528", "0093", "0244",
           "0064", "0169", "0287", "0807", "0731", "0743", "0467"]
    pages, logs = [], []
    for page_id in ids:
        page, page_logs = load_page(args.data_root, page_id)
        pages.append(page)
        logs.extend(page_logs)
    relations_path = args.data_root / "review-split-visual-v28/confirmed-relations-main-v55.json"
    relations = json.loads(relations_path.read_text())
    reviewed = [row for row in relations["rows"] if row["id"] in ids]
    cache = ROOT / "build/causal8-target-ownership-smoke"
    cache.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="causal8-owner-", dir=cache) as directory:
        tmp = Path(directory)
        (tmp / "main.swift").write_text(SWIFT)
        (tmp / "pages.json").write_text(json.dumps(pages, ensure_ascii=False))
        started = time.perf_counter()
        subprocess.run(["xcrun", "swiftc", "-Onone", "-module-cache-path", str(cache / "module-cache"),
                        str(previous.HELPER), str(tmp / "main.swift"), "-o", str(tmp / "controls")], check=True)
        compile_seconds = time.perf_counter() - started
        started = time.perf_counter()
        execution = subprocess.run([str(tmp / "controls"), str(tmp / "pages.json")], capture_output=True, text=True)
        if execution.returncode:
            raise RuntimeError(execution.stderr[:5000] + execution.stdout[:1000])
        helper_seconds = time.perf_counter() - started
        result = json.loads(execution.stdout)
    transfers = [(page["id"], row["id"], row["parentID"]) for page in result["pages"]
                 for row in page["audit"] if row["action"] == "partitionRedundantTargetOwner"]
    assert transfers == [("0528", "16", "10")], transfers
    strict = [(page["id"], row["id"], row["parentID"]) for page in result["pages"]
              for row in page["strictAudit"] if row["action"] == "consolidateRedundantNestedOwner"]
    assert strict == [("0244", "6", "5")], strict
    relation_checks = []
    if args.relation_evaluator:
        evaluator_spec = importlib.util.spec_from_file_location("reviewed_relations", args.relation_evaluator)
        evaluator = importlib.util.module_from_spec(evaluator_spec)
        evaluator_spec.loader.exec_module(evaluator)
        # Parent's read-only evaluator checks helper provenance, not a new render.
        changed = next(page for page in result["pages"] if page["id"] == "0528")
        historical = json.loads((args.data_root / "rendered-parallel836-all-confirmed-causes-main-v27/actual/0528"
                                 / "main-ensemble-evaluation.json").read_text())["report"]["renderItems"]
        for reviewed_row in reviewed:
            if reviewed_row["id"] != "0528":
                continue
            wanted = [mapping["historicalOwner"] for mapping in reviewed_row["mappings"]]
            evaluation = evaluator.evaluate(historical, changed["displayItems"], wanted, reviewed_row["expectation"])
            assert all(mapping["exactTargetAndSourceMatched"] for mapping in evaluation["mappings"]), evaluation
            assert evaluation["status"] == "multiple_current_owners_still_require_investigation", evaluation
            relation_checks.append(dict(id="0528", group=reviewed_row["group"], evaluation=evaluation))
        assert len(relation_checks) == 2
        assert next(row for row in relation_checks if row["group"] == "g13")["evaluation"]["currentOwners"] == ["10", "11", "13", "15"]
    report = dict(promptVersion="causal8-v56/technical-review-v1/main-v55", manifestDenominator=836,
                  focusedPages=len(ids), actualLogsRead=logs, reviewedRelations=reviewed,
                  reviewedRelationsSHA256=digest(relations_path), compileSeconds=compile_seconds,
                  helperSeconds=helper_seconds, result=result, targetTransfers=transfers,
                  helperOnlyReviewedRelationChecks=relation_checks,
                  newRenders=0, newVisualReviews=0, modelCalls=0, actualVisualGain="unmeasured",
                  integration="sourceItems for masks and originalItems evidence; displayItems for grouping/layout; default off")
    if args.output:
        args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(dict(focusedPages=len(ids), actualLogsRead=len(logs), targetTransfers=transfers,
                         strictConsolidations=strict, compileSeconds=compile_seconds, helperSeconds=helper_seconds,
                         syntheticControlsPassed=True, helperOnlyReviewedRelationChecks=len(relation_checks),
                         actualVisualGain="unmeasured")))


if __name__ == "__main__":
    main()
