#!/usr/bin/env python3
"""Execute only NativeSourceOwnerRecovery, never the renderer or inference.

All actual JSON logs for the scoped fixtures are parsed in full, with source/OCR
artifact digests checked. Fixture selection is evaluation-only. Runtime receives
no page IDs, labels, paths, or expected outcomes. Run with --metadata-only for the
first independent metadata handoff; default also exercises nested-owner controls.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT.parent
HELPER = ROOT / 'Aidoku/Core/Translation/NativeEngine/Ensemble/NativeSourceOwnerRecovery.swift'

SWIFT = r'''
import Foundation
import CoreGraphics

func check(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message)
}
func bytes(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
let size = CGSize(width: 1000, height: 1000)
let bounds = [0.1, 0.1, 0.05, 0.3]
let quad = [[0.1, 0.1], [0.12, 0.1], [0.15, 0.4], [0.13, 0.4]]
let angle = -atan2(0.03, 0.3)
func row(_ source: String = "これは文章です", _ translation: String = "본문\n\n끝😀e\u{301}") -> [String: Any] {
    ["source": source, "translation": translation, "sourceBounds": bounds, "polygon": quad,
     "sourceOrientation": "vertical", "sourceSingleVerticalColumn": true, "confidence": 0.95,
     "sourceGeometryObservation": ["rectClipped": false, "polygonClipped": false]]
}
func packet(_ rows: [[String: Any]]) -> [String: Any] {
    ["originalOCR": ["width": 1000, "height": 1000, "regions": rows]]
}
let item: [String: Any] = ["id": "owner", "text": "본문\n\n끝😀e\u{301}", "sourceBounds": bounds,
    "sourcePolygon": quad, "sourceFrame": [0.0, 0.0, 1000.0, 1000.0],
    "sourceVertical": true, "vertical": false, "rotation": angle, "rotationPlannedFontSize": 8.0,
    "fontSize": 24.0, "sourceFontSize": 31.0, "lineHeight": 28.0,
    "x": 1.0, "y": 2.0, "width": 3.0, "height": 4.0]
func run(_ items: [[String: Any]] = [item], _ rows: [[String: Any]] = [row()],
         _ image: CGSize = size) -> NativeSourceOwnerRecovery.Result {
    NativeSourceOwnerRecovery.apply(items, evidence: packet(rows), imageSize: image,
        normalizeParagraphs: true, normalizeSkew: true)
}
check(bytes(NativeSourceOwnerRecovery.apply([item], evidence: packet([row()]), imageSize: size).items) == bytes([item]), "disabled")
let changed = run()
check(changed.audit.count == 2, "both independent repairs")
check(changed.items[0]["text"] as? String == "본문 끝😀e\u{301}", "only blank paragraph whitespace")
check(changed.items[0]["sourceOwnerCanonicalTranslation"] as? String == item["text"] as? String, "provider text retained")
check(changed.items[0]["rotation"] as? Double == 0, "upright horizontal seed")
check(abs((changed.items[0]["x"] as? Double ?? 0) - 100) < 1e-8 &&
    abs((changed.items[0]["width"] as? Double ?? 0) - 50) < 1e-8, "source bbox seed")
for key in ["fontSize", "sourceFontSize", "lineHeight", "sourceBounds", "sourcePolygon"] {
    check(bytes([changed.items[0][key]!]) == bytes([item[key]!]), "no peer font/source mutation: \(key)")
}
check(bytes(run(changed.items).items) == bytes(changed.items), "idempotent")
check(run([item], [row(), row()]).audit.isEmpty, "ambiguous exact OCR")
check(run([item], []).audit.isEmpty, "missing evidence")
check(run([item], [row()], CGSize(width: 999, height: 1000)).audit.isEmpty, "dimension binding")
check(run([item], [row()], CGSize(width: CGFloat.infinity, height: 1000)).audit.isEmpty, "nonfinite dimensions")
for key in ["keptLettering", "sourceTextOnly"] {
    var held = item; held[key] = true
    check(run([held]).audit.isEmpty, "protected owner: \(key)")
}
var clipped = row(); clipped["sourceGeometryObservation"] = ["rectClipped": true, "polygonClipped": false]
check(run([item], [clipped]).audit.isEmpty, "clipped evidence")
var absent = row(); absent.removeValue(forKey: "sourceGeometryObservation")
check(run([item], [absent]).audit.isEmpty, "unknown clipping")
var shifted = row(); shifted["sourceBounds"] = [0.100001, 0.1, 0.05, 0.3]
check(run([item], [shifted]).audit.isEmpty, "not exact OCR")
var stale = row(); stale["translation"] = "다른 번역"
check(run([item], [stale]).audit.isEmpty, "stale translation")
for source in ["source\n\nparagraph", "source\nline"] {
    let result = NativeSourceOwnerRecovery.normalizeArtificialParagraphs([item], evidence: packet([row(source)]), imageSize: size, enabled: true)
    check(result.audit.isEmpty, "source breaks preserved")
}
var multiple = row(); multiple["sourceSingleVerticalColumn"] = false
check(NativeSourceOwnerRecovery.normalizeArtificialParagraphs([item], evidence: packet([multiple]), imageSize: size, enabled: true).audit.isEmpty, "multiple source columns")
var wrap = item; wrap["text"] = "첫째\n둘째"
check(NativeSourceOwnerRecovery.normalizeArtificialParagraphs([wrap], evidence: packet([row("本文", "첫째\n둘째")]), imageSize: size, enabled: true).audit.isEmpty, "single target wrap preserved")
for key in ["vertical", "uprightQuadText", "drawsUprightQuadText"] {
    var vertical = item; vertical[key] = true
    check(NativeSourceOwnerRecovery.normalizeSourceBBoxSkew([vertical], evidence: packet([row()]), imageSize: size, enabled: true).audit.isEmpty, "intentional quad/vertical: \(key)")
}
var conflict = item; conflict["rotation"] = angle + 0.1
check(NativeSourceOwnerRecovery.normalizeSourceBBoxSkew([conflict], evidence: packet([row()]), imageSize: size, enabled: true).audit.isEmpty, "angle conflict")
var mismatch = item; mismatch["sourcePolygon"] = [[0.1, 0.1], [0.15, 0.1], [0.15, 0.4], [0.1, 0.4]]
check(NativeSourceOwnerRecovery.normalizeSourceBBoxSkew([mismatch], evidence: packet([row()]), imageSize: size, enabled: true).audit.isEmpty, "quad conflict")

func plain(_ id: String, _ source: String, _ target: String, _ box: [Double]) -> (item: [String: Any], row: [String: Any]) {
    let polygon = [[box[0], box[1]], [box[0] + box[2], box[1]],
        [box[0] + box[2], box[1] + box[3]], [box[0], box[1] + box[3]]]
    let value: [String: Any] = ["id": id, "text": target, "sourceBounds": box, "sourcePolygon": polygon,
        "vertical": false, "sourceVertical": true, "rotation": 0.0, "fontSize": 17.0]
    let observation: [String: Any] = ["source": source, "translation": target, "sourceBounds": box,
        "polygon": polygon, "sourceOrientation": "vertical", "confidence": 0.98,
        "sourceGeometryObservation": ["rectClipped": false, "polygonClipped": false]]
    return (value, observation)
}
let body = plain("body", "例えばこれは長い文です", "마지막 문장이다", [0.1, 0.1, 0.1, 0.3])
let child = plain("short", "す", "다", [0.14, 0.34, 0.02, 0.02])
func nested(_ parts: [(item: [String: Any], row: [String: Any])] = [body, child]) -> NativeSourceOwnerRecovery.Result {
    NativeSourceOwnerRecovery.apply(parts.map(\.item), evidence: packet(parts.map(\.row)), imageSize: size,
        consolidateShortOwners: true)
}
let consolidated = nested()
check(consolidated.items.count == 1 && consolidated.items[0]["id"] as? String == "body", "strict nested tail")
var retained = consolidated.items[0]; retained.removeValue(forKey: "sourceOwnerConsolidatedChildren")
check(bytes([retained]) == bytes([body.item]), "parent text/geometry/style/identity unchanged")
let provenance = consolidated.items[0]["sourceOwnerConsolidatedChildren"] as! [[String: Any]]
check(provenance[0]["text"] as? String == "다" && provenance[0]["source"] as? String == "す", "retired owner strings retained")
check(nested([body]).audit.isEmpty, "idempotent nested repair")
check(bytes(NativeSourceOwnerRecovery.apply([body.item, child.item], evidence: packet([body.row, child.row]), imageSize: size).items) == bytes([body.item, child.item]), "owner consolidation disabled by default")
let noSource = plain("short", "泳", "다", [0.14, 0.34, 0.02, 0.02])
check(nested([body, noSource]).items.count == 2, "overlap and redundant target alone insufficient")
let noTarget = plain("short", "す", "빠진 번역", [0.14, 0.34, 0.02, 0.02])
check(nested([body, noTarget]).items.count == 2, "source substring alone insufficient")
let uniqueSymbol = plain("short", "す", "다♡", [0.14, 0.34, 0.02, 0.02])
check(nested([body, uniqueSymbol]).items.count == 2, "unique child punctuation not discarded")
let wrongPosition = plain("short", "す", "다", [0.14, 0.11, 0.02, 0.02])
check(nested([body, wrongPosition]).items.count == 2, "tail cannot be mapped to source top")
let prefixBody = plain("body", "それから長い文章です", "그런 문장의 나머지", [0.1, 0.1, 0.1, 0.3])
let prefixChild = plain("short", "そ", "그", [0.14, 0.11, 0.02, 0.02])
check(nested([prefixBody, prefixChild]).items.count == 1, "strict nested prefix")
let outside = plain("short", "そ", "그", [0.14, 0.095, 0.02, 0.05])
check(nested([prefixBody, outside]).items.count == 2, "partial containment keeps source footprint")
let distinctBody = plain("body", "すべてすべて長い文です", "마지막 문장이다", [0.1, 0.1, 0.1, 0.3])
check(nested([distinctBody, child]).items.count == 2, "nonunique source glyph retained")
let repeatedTarget = plain("body", "例えばこれは長い文です", "다른 문장이다", [0.1, 0.1, 0.1, 0.3])
check(nested([repeatedTarget, child]).items.count == 2, "nonunique target syllable retained")
var protectedChild = child; protectedChild.item["keptLettering"] = true
check(nested([body, protectedChild]).items.count == 2, "protected nested owner")
var paragraphChild = child; paragraphChild.item["paragraphID"] = "second"
var paragraphBody = body; paragraphBody.item["paragraphID"] = "first"
check(nested([paragraphBody, paragraphChild]).items.count == 2, "explicit paragraph separation")
var corruptChild = child; corruptChild.item["text"] = "바뀐 번역"
check(nested([body, corruptChild]).items.count == 2, "translation binding conflict")
var weakChild = child; weakChild.row["confidence"] = 0.5
check(nested([body, weakChild]).items.count == 2, "weak OCR")
var clippedChild = child; clippedChild.row["sourceGeometryObservation"] = ["rectClipped": true, "polygonClipped": false]
check(nested([body, clippedChild]).items.count == 2, "clipped OCR")
let extraParent = plain("other-body", "例えばこれは長い文章です", "마지막 문장이다", [0.09, 0.09, 0.13, 0.34])
check(nested([body, child, extraParent]).items.count == 3, "ambiguous parent")
var duplicateID = child; duplicateID.item["id"] = "body"
check(nested([body, duplicateID]).items.count == 2, "duplicate item identity")
var competing = child; competing.item["id"] = "competitor"
check(nested([body, child, competing]).items.count == 3, "competing target span")
// A source scalar is not a whole composed glyph. The combining mark is never dropped.
let combiningBody = plain("body", "例えばこれは長いか\u{3099}です", "마지막 문장이다", [0.1, 0.1, 0.1, 0.3])
let combiningChild = plain("short", "か", "다", [0.14, 0.34, 0.02, 0.02])
check(nested([combiningBody, combiningChild]).items.count == 2, "exact composed Unicode matching")

let pages = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: Any]]
var reports: [[String: Any]] = []
for page in pages {
    let dimensions = page["size"] as! [Double]
    let original = page["items"] as! [[String: Any]]
    let evidence = page["evidence"] as! [String: Any]
    let image = CGSize(width: dimensions[0], height: dimensions[1])
    let result = NativeSourceOwnerRecovery.apply(original, evidence: evidence, imageSize: image,
        normalizeParagraphs: true, normalizeSkew: true)
    check(result.items.count == original.count, "metadata changed owner count")
    for (before, after) in zip(original, result.items) {
        let a = (before["text"] as? String ?? "").filter { !$0.isWhitespace }
        let b = (after["text"] as? String ?? "").filter { !$0.isWhitespace }
        check(Array(a.utf16) == Array(b.utf16), "lexical translation changed")
        for key in ["sourceBounds", "sourcePolygon", "fontSize", "sourceFontSize", "lineHeight"] {
            check(bytes([before[key] ?? NSNull()]) == bytes([after[key] ?? NSNull()]), "source/font mutation")
        }
    }
    let owners = CommandLine.arguments[2] == "metadata" ? (items: original, audit: [[String: Any]]()) :
        NativeSourceOwnerRecovery.consolidateNestedOwners(original, evidence: evidence, imageSize: image, enabled: true)
    for owner in owners.items {
        let before = original.first { $0["id"] as? String == owner["id"] as? String }!
        var withoutProvenance = owner
        withoutProvenance.removeValue(forKey: "sourceOwnerConsolidatedChildren")
        check(bytes([before]) == bytes([withoutProvenance]), "nested repair changed retained body")
    }
    let retired = owners.audit.filter { $0["action"] as? String == "consolidateRedundantNestedOwner" }
    check(owners.items.count == original.count - retired.count, "owner accounting")
    reports.append(["id": page["id"]!, "audit": result.audit, "nestedAudit": owners.audit,
        "inputItems": original.count, "outputItems": owners.items.count])
}
print(String(data: bytes(["syntheticControlsPassed": true, "pages": reports]), encoding: .utf8)!)
'''


def load_page(page_id):
    folder = BASE / f'render-inputs/current836/pages/{page_id}'
    payload = json.loads((folder / '001-render-payload.json').read_text())['value']
    descriptor = payload['nativeEnsembleEvidence']['originalOCR']
    raw = Path(descriptor['path']).read_bytes()
    assert hashlib.sha256(raw).hexdigest() == descriptor['fileSHA256'], page_id
    assert descriptor['artifactSourceSHA256'] == payload['nativeEnsembleEvidence']['sourceSHA256'], page_id
    assert hashlib.sha256((folder / 'input.png').read_bytes()).hexdigest() == descriptor['artifactSourceSHA256'], page_id
    ocr = json.loads(raw)
    rows = []
    for region in ocr['regions']:
        row = dict(region)
        row['sourceBounds'] = [region['rect'][k] for k in ('x', 'y', 'width', 'height')]
        polygon = region.get('polygon', [])
        xy = [(p['x'], p['y']) if isinstance(p, dict) else p for p in polygon]
        row['sourceGeometryObservation'] = dict(
            rectClipped=not (row['sourceBounds'][0] >= 0 and row['sourceBounds'][1] >= 0
                            and row['sourceBounds'][0] + row['sourceBounds'][2] <= 1
                            and row['sourceBounds'][1] + row['sourceBounds'][3] <= 1),
            polygonClipped=any(not (0 <= x <= 1 and 0 <= y <= 1) for x, y in xy))
        rows.append(row)
    items = []
    for raw in payload['nativeLayout']['items']:
        item = dict(raw)
        frame = item['sourceFrame']
        sx, sy = ocr['width'] / frame[2], ocr['height'] / frame[3]
        for key in ('width', 'paddingLeft', 'paddingRight', 'fontSize', 'lineHeight', 'sourceFontSize'):
            if item.get(key) is not None:
                item[key] *= sx
        for key in ('height', 'paddingTop', 'paddingBottom', 'inspectionHeight'):
            if item.get(key) is not None:
                item[key] *= sy
        item['x'], item['y'] = (item['x'] - frame[0]) * sx, (item['y'] - frame[1]) * sy
        item['sourceFrame'] = [0, 0, ocr['width'], ocr['height']]
        items.append(item)
    logs = []
    actual = BASE / f'rendered-parallel836-all-confirmed-causes-main-v27/actual/{page_id}'
    for name in ('main-ensemble-evaluation.json', '001-native-render-diagnostics.json', 'native-layout.json'):
        path = actual / name
        raw = path.read_bytes()
        parsed = json.loads(raw)  # Parse complete actual artifacts; no historical summary substituted.
        record = dict(path=str(path), sha256=hashlib.sha256(raw).hexdigest(), bytes=len(raw))
        if name == 'main-ensemble-evaluation.json':
            report = parsed['report']
            grouping = [c['evidence']['fusion']['sourceTextBlockGrouping'] for c in report['candidates']
                        if 'sourceTextBlockGrouping' in c.get('evidence', {}).get('fusion', {})]
            record.update(sourceFragmentJoins=report.get('sourceFragmentJoins', []),
                          sourceDirectionRecovery=report.get('sourceDirectionRecovery', []),
                          shortSourceRecovery=report.get('shortSourceRecovery', []),
                          eligibility=[g.get('sourceEligibilityFailures', []) for g in grouping],
                          pairDiagnosticsAvailable=any('pairDiagnostics' in g for g in grouping))
        logs.append(record)
    return dict(id=page_id, size=[ocr['width'], ocr['height']], items=items,
                evidence=dict(originalOCR=dict(width=ocr['width'], height=ocr['height'], regions=rows))), logs


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--metadata-only', action='store_true')
    args = parser.parse_args()
    ids = ['0160', '0313', '0730']
    if not args.metadata_only:
        ids += ['0093', '0169', '0244', '0287', '0528', '0807']
    pages, logs = [], []
    for page_id in ids:
        page, actual = load_page(page_id)
        pages.append(page)
        logs.extend(actual)
    cache = ROOT / 'build/source-owner-recovery-smoke'
    cache.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='aidoku-owner-controls-') as directory:
        tmp = Path(directory)
        (tmp / 'main.swift').write_text(SWIFT)
        (tmp / 'pages.json').write_text(json.dumps(pages, ensure_ascii=False))
        started = time.perf_counter()
        subprocess.run(['xcrun', 'swiftc', '-Onone', '-module-cache-path', str(cache / 'module-cache'),
                        str(ROOT / 'Aidoku/Core/Translation/NativeEngine/OCR/NativeOCRLocalCoordinates.swift'), str(HELPER), str(tmp / 'main.swift'), '-o', str(tmp / 'controls')], check=True)
        compile_seconds = time.perf_counter() - started
        started = time.perf_counter()
        execution = subprocess.run([str(tmp / 'controls'), str(tmp / 'pages.json'),
                                    'metadata' if args.metadata_only else 'nested'],
                                   capture_output=True, text=True)
        if execution.returncode:
            raise RuntimeError(execution.stderr[:5000] + execution.stdout[:1000])
        runtime_seconds = time.perf_counter() - started
        result = json.loads(execution.stdout)
    affected = {(p['id'], str(a['id']), a['action']) for p in result['pages'] for a in p['audit']}
    expected = {('0160', '9', 'normalizeTargetBlankParagraphs'), ('0313', '5', 'normalizeInheritedSourceSkew'),
                ('0730', '0', 'normalizeInheritedSourceSkew'), ('0730', '1', 'normalizeInheritedSourceSkew')}
    assert affected == expected, affected
    owners = {(p['id'], str(a['id']), str(a['parentID'])) for p in result['pages'] for a in p['nestedAudit']
              if a['action'] == 'consolidateRedundantNestedOwner'}
    assert owners == (set() if args.metadata_only else {('0244', '6', '5')}), owners
    manifest = json.loads((BASE / 'render-inputs/current836/manifest.json').read_text())
    assert len(manifest['cases']) == 836
    print(json.dumps(dict(manifestDenominator=836, metadataResult=result,
                         actualLogsRead=logs, compileSeconds=compile_seconds, helperSeconds=runtime_seconds,
                         newRenders=0, modelCalls=0, visualAcceptance=False), ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
