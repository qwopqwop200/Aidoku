#!/usr/bin/env python3
"""Focused source-owner candidate contract + saved actual probes; no OCR/API/render.

Fixture page IDs are test inputs only. Production candidate selection uses only
source-bound geometry and saved lexical provenance, never labels or page IDs.
"""
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT.parent
spec = importlib.util.spec_from_file_location('owner_controls', Path(__file__).with_name('run-source-owner-recovery-smoke.py'))
previous = importlib.util.module_from_spec(spec)
spec.loader.exec_module(previous)

# Reuse every existing synthetic metadata/strict-dedup control without modifying
# that test or any renderer. Only the new contract is appended below.
SWIFT = previous.SWIFT.split('let pages = try JSONSerialization')[0] + r'''
func recover(_ parts: [(item: [String: Any], row: [String: Any])],
             _ image: CGSize = size) -> NativeSourceOwnerRecovery.Result {
    NativeSourceOwnerRecovery.apply(parts.map(\.item), evidence: packet(parts.map(\.row)), imageSize: image,
        recoverDistinctFragments: true)
}
func unchanged(_ before: [[String: Any]], _ after: [[String: Any]]) {
    check(before.count == after.count, "all owners retained")
    for (a, b) in zip(before, after) {
        var stripped = b; stripped.removeValue(forKey: "sourceOwnerRecoveryCandidate")
        check(bytes([a]) == bytes([stripped]), "all lexical/geometry/style fields byte-for-byte retained")
    }
}
let distinct = plain("distinct", "が", "를", [0.14, 0.24, 0.02, 0.02])
let proposed = recover([body, distinct])
unchanged([body.item, distinct.item], proposed.items)
let contract = proposed.items[1]["sourceOwnerRecoveryCandidate"] as! [String: Any]
check(contract["kind"] as? String == "upstreamOCRLineageRepair", "actionable upstream repair")
check(contract["jointLayoutCertified"] as? Bool == false, "overlap is not paragraph proof")
check(contract["displayMutationAllowed"] as? Bool == false && contract["maskExpansionAllowed"] as? Bool == false,
    "no implied display/erasure permission")
check(contract["translationRefreshRequiredBeforeSourceReplacement"] as? Bool == true, "refresh before replacement")
check((contract["recognitionRequests"] as? [Any])?.count == 2, "bounded owned and paragraph-context recognition")
let snapshot = contract["fragment"] as! [String: Any]
check(snapshot["source"] as? String == "が" && snapshot["target"] as? String == "를", "distinct lexical provenance")
check(snapshot["sourceFontSize"] is NSNull, "font uncertainty not filled from body")
let relations = contract["relations"] as! [[String: Any]]
check(relations[0]["sourceExactOccurrences"] as? Int == 0 && relations[0]["targetExactOccurrences"] as? Int == 0,
    "missing source and target not treated as duplicate")
let replay = NativeSourceOwnerRecovery.apply(proposed.items, evidence: packet([body.row, distinct.row]), imageSize: size,
    recoverDistinctFragments: true)
check(bytes(replay.items) == bytes(proposed.items), "candidate replay deterministic and idempotent")
check(bytes(NativeSourceOwnerRecovery.apply([body.item, distinct.item], evidence: packet([body.row, distinct.row]),
    imageSize: size).items) == bytes([body.item, distinct.item]), "default no effect")
check(recover([body, distinct], CGSize(width: 999, height: 1000)).audit.isEmpty, "source dimensions bound")
var staleDistinct = distinct; staleDistinct.item["text"] = "stale"
check(recover([body, staleDistinct]).audit.isEmpty, "exact saved translation required")
var wrongQuad = distinct; wrongQuad.item["sourcePolygon"] = [[0.0, 0.0], [0.1, 0.0], [0.1, 0.1]]
check(recover([body, wrongQuad]).audit.isEmpty, "exact source polygon required")
var clippedDistinct = distinct
clippedDistinct.row["sourceGeometryObservation"] = ["rectClipped": true, "polygonClipped": false]
check(recover([body, clippedDistinct]).audit.isEmpty, "clipped observation not certified")
var protectedDistinct = distinct; protectedDistinct.item["keptLettering"] = true
check(recover([body, protectedDistinct]).audit.isEmpty, "protected fragment not reassigned")
var separated = distinct; separated.item["paragraphID"] = "second"
var first = body; first.item["paragraphID"] = "first"
let separateContract = recover([first, separated]).items[1]["sourceOwnerRecoveryCandidate"] as! [String: Any]
check((separateContract["relations"] as! [[String: Any]])[0]["explicitParagraphConflict"] as? Bool == true,
    "explicit separation retained in request")
let partial = plain("partial", "そ", "그", [0.14, 0.095, 0.02, 0.05])
let ambiguous = recover([body, extraParent, partial])
unchanged([body.item, extraParent.item, partial.item], ambiguous.items)
let multi = ambiguous.items[2]["sourceOwnerRecoveryCandidate"] as! [String: Any]
check((multi["overlappingOwners"] as? [Any])?.count == 2 && multi["jointLayoutCertified"] as? Bool == false,
    "partial and multiple ownership remain unassigned")
var keepOut = plain("protected-context", "別", "별도", [0.11, 0.2, 0.01, 0.01])
keepOut.item["keptLettering"] = true
let guarded = recover([body, distinct, keepOut])
unchanged([body.item, distinct.item, keepOut.item], guarded.items)
let guardedContract = guarded.items[1]["sourceOwnerRecoveryCandidate"] as! [String: Any]
check((guardedContract["contextKeepOuts"] as! [[String: Any]]).contains { $0["id"] as? String == "protected-context" },
    "recognition context retains protected neighbor footprint")
let apart = plain("apart", "字", "글", [0.6, 0.6, 0.01, 0.02])
check(recover([body, apart]).audit.isEmpty, "no proximity-only recovery")
var alternative = distinct
alternative.row["sourceOCRAlternatives"] = [["originalText": "が", "exactReading": "が字", "paddedReading": "が字"]]
let alt = recover([body, alternative]).items[1]["sourceOwnerRecoveryCandidate"] as! [String: Any]
check(alt["jointLayoutCertified"] as? Bool == false && alt["recoveredSource"] == nil,
    "unbound alternatives never synthesize repaired text")
let pages = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: Any]]
var reports: [[String: Any]] = []
for page in pages {
    let dimensions = page["size"] as! [Double], original = page["items"] as! [[String: Any]]
    let evidence = page["evidence"] as! [String: Any]
    let image = CGSize(width: dimensions[0], height: dimensions[1])
    check(bytes(NativeSourceOwnerRecovery.apply(original, evidence: evidence, imageSize: image).items) == bytes(original),
        "actual default no effect")
    let result = NativeSourceOwnerRecovery.apply(original, evidence: evidence, imageSize: image, recoverDistinctFragments: true)
    unchanged(original, result.items)
    let candidates = result.items.compactMap { item -> [String: Any]? in
        guard let candidate = item["sourceOwnerRecoveryCandidate"] as? [String: Any] else { return nil }
        check(candidate["jointLayoutCertified"] as? Bool == false && candidate["recoveredSource"] == nil,
            "missing lineage cannot certify repair")
        return ["id": item["id"]!, "candidate": candidate]
    }
    let strict = NativeSourceOwnerRecovery.apply(original, evidence: evidence, imageSize: image,
        consolidateShortOwners: true, recoverDistinctFragments: true)
    for event in strict.audit where event["action"] as? String == "consolidateRedundantNestedOwner" {
        check(!strict.items.contains { $0["id"] as? String == event["id"] as? String },
            "candidate path cannot resurrect a strict redundant owner")
    }
    reports.append(["id": page["id"]!, "candidates": candidates,
        "strictDedupAudit": strict.audit.filter { $0["action"] as? String == "consolidateRedundantNestedOwner" }])
}
print(String(data: bytes(["syntheticControlsPassed": true, "pages": reports]), encoding: .utf8)!)
'''


def main():
    ids = ['0064', '0093', '0169', '0244', '0287', '0528', '0807']
    pages, logs = [], []
    actual_root = BASE / 'rendered-parallel836-split-visual-integrated-main-v38/actual'
    for page_id in ids:
        page, _ = previous.load_page(page_id)
        for path in sorted((actual_root / page_id).glob('*.json')):
            raw = path.read_bytes()
            data = json.loads(raw)  # Parse complete saved artifacts, not old summary rows.
            record = dict(path=str(path), sha256=hashlib.sha256(raw).hexdigest(), bytes=len(raw))
            if path.name == 'main-ensemble-evaluation.json':
                handoff = data['report']['ocrEvidenceHandoff']
                record['stageAvailability'] = handoff['stageAvailability']
            logs.append(record)
        assert any(Path(log['path']).parent == actual_root / page_id for log in logs), page_id
        pages.append(page)
    cache = ROOT / 'build/distinct-source-owner-recovery-smoke'
    cache.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='aidoku-distinct-owner-') as directory:
        tmp = Path(directory)
        (tmp / 'main.swift').write_text(SWIFT)
        (tmp / 'pages.json').write_text(json.dumps(pages, ensure_ascii=False))
        started = time.perf_counter()
        subprocess.run(['xcrun', 'swiftc', '-Onone', '-module-cache-path', str(cache / 'module-cache'),
                        str(previous.HELPER), str(tmp / 'main.swift'), '-o', str(tmp / 'controls')], check=True)
        compile_seconds = time.perf_counter() - started
        started = time.perf_counter()
        execution = subprocess.run([str(tmp / 'controls'), str(tmp / 'pages.json')], capture_output=True, text=True)
        if execution.returncode:
            raise RuntimeError(execution.stderr[:5000] + execution.stdout[:1000])
        runtime_seconds = time.perf_counter() - started
        result = json.loads(execution.stdout)
    by_page = {p['id']: {str(c['id']): c['candidate'] for c in p['candidates']} for p in result['pages']}
    required = {'0064': ['11', '14', '15'], '0093': ['12'], '0169': ['3', '8', '10'],
                '0287': ['12'], '0528': ['3', '13', '15'], '0807': ['13']}
    for page_id, owner_ids in required.items():
        for owner_id in owner_ids:
            assert owner_id in by_page[page_id], (page_id, owner_id, list(by_page[page_id]))
    dedup = {(p['id'], str(a['id']), str(a['parentID'])) for p in result['pages'] for a in p['strictDedupAudit']}
    assert dedup == {('0244', '6', '5')}, dedup
    manifest = json.loads((BASE / 'render-inputs/current836/manifest.json').read_text())
    assert len(manifest['cases']) == 836
    print(json.dumps(dict(manifestDenominator=836, result=result, actualLogsRead=logs,
                         compileSeconds=compile_seconds, helperSeconds=runtime_seconds,
                         newRenders=0, modelCalls=0, visualAcceptance=False), ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
