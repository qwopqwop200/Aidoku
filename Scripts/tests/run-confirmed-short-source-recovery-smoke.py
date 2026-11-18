#!/usr/bin/env python3
"""Execute the production short-source helper; no images, models or app build.

Reads the 23 checkpoint cases and 17 additional recorded upper-half failures.
The all836 denominator is retained; this is helper evidence, not render success.
Enable the candidate in actual renders with pipeline.recoverShortSourceFont=1
and pipeline.recoverShortSourceDirection=1 in AIDOKU_ENSEMBLE_PARAMETERS.
"""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT.parent
RENDERER = ROOT / 'Aidoku/Core/Translation/NativeEngine/Ensemble/NativeMainEnsembleRenderer.swift'
FLOW = ROOT / 'Aidoku/Core/Translation/NativeEngine/Overlay/BrowserOverlayView.swift'


def function(source, name):
    match = re.search(r'    (?:private )?static func ' + name + r'\(', source)
    assert match, name
    start = source.index('{', match.start())
    depth, end = 1, start + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[match.start():end]


source = RENDERER.read_text()
flow = FLOW.read_text()
harness = '''import Foundation
import CoreGraphics
import CoreText
enum BrowserOCRSourceOrientation: String { case vertical, horizontal, unknown }
enum BrowserOverlayTextFlow {
''' + '\n'.join(function(flow, name) for name in (
    'usesVerticalSourceLayout', 'textPrefersVerticalWriting', 'isVerticalCJK')) + '''
}
enum Renderer {
''' + '\n'.join(function(source, name) for name in ('recoverSourceDirections', 'recoverShortSources')) + r'''
}
func evidence(_ rows: [[String:Any]]) -> [String:Any] { ["originalOCR":["regions":rows]] }
let size = CGSize(width:1000,height:1000)
func row(_ text: String = "て", _ bounds: [Double] = [0.1,0.1,0.02,0.04],
         _ axis: String = "vertical") -> [String:Any] {
    ["source":text,"sourceBounds":bounds,"sourceOrientation":axis,"sourceSingleVerticalColumn":true,
     "confidence":0.99,"sourceGeometryObservation":["rectClipped":false,"polygonClipped":false]]
}
let owner: [String:Any] = ["id":"probe","text":"번역😀e\u{301}","sourceVertical":false,
    "sourceBounds":[0.1,0.1,0.02,0.04],"fontSize":30.0,"lineHeight":36.0]
func run(_ item: [String:Any] = owner, _ rows: [[String:Any]] = [row()],
         _ imageSize: CGSize = size) -> (items:[[String:Any]], audit:[[String:Any]]) {
    Renderer.recoverShortSources([item],evidence:evidence(rows),imageSize:imageSize,
        recoverFont:true,recoverDirection:true)
}
let accepted = run()
precondition(accepted.items[0]["sourceVertical"] as? Bool == true)
precondition((accepted.items[0]["sourceFontSize"] as? Double ?? 0) > 0, "\(accepted)")
precondition(accepted.items[0]["text"] as? String == owner["text"] as? String)
precondition(accepted.audit[0]["fontApplied"] as? Bool == true)
precondition(Renderer.recoverShortSources([owner],evidence:evidence([row()]),imageSize:size).audit.isEmpty)
precondition(run(owner,[row(),row()]).audit.isEmpty)
precondition(run(owner,[]).audit.isEmpty)
precondition(run(owner,[row()],CGSize(width:CGFloat.infinity,height:1000)).audit.isEmpty)
var invalid = owner; invalid["sourceBounds"] = [-0.1,0.1,0.02,0.04]
precondition(run(invalid).audit.isEmpty)
for key in ["keptLettering","sourceTextOnly"] {
    var kept = owner; kept[key] = true; precondition(run(kept).audit.isEmpty)
}
var clipped = row(); clipped["sourceGeometryObservation"] = ["rectClipped":true,"polygonClipped":false]
precondition(run(owner,[clipped]).audit.isEmpty)
var clippedMember = row(); clippedMember["clippedUnitMemberIndices"] = [0]
precondition(run(owner,[clippedMember]).audit.isEmpty)
var noObservation = row(); noObservation.removeValue(forKey:"sourceGeometryObservation")
precondition(run(owner,[noObservation]).audit.isEmpty)
var uncertain = row(); uncertain["confidence"] = 0.79
precondition(run(owner,[uncertain]).items[0]["sourceFontSize"] == nil)
var shifted = row(); shifted["sourceBounds"] = [0.10001,0.1,0.02,0.04]
precondition(run(owner,[shifted]).audit.isEmpty)
for text in ["A","1","…","😀","てて","か\u{3099}"] {
    precondition(run(owner,[row(text)]).items[0]["sourceFontSize"] == nil)
}
var existing = owner; existing["sourceFontSize"] = 17.25
precondition(run(existing).items[0]["sourceFontSize"] as? Double == 17.25)
for bad in [Double.nan,Double.infinity,0,-1] {
    var broken = owner; broken["sourceFontSize"] = bad
    precondition((run(broken).items[0]["sourceFontSize"] as? Double ?? 0) > 0)
}
let square = [0.1,0.1,0.03,0.03]
var squareOwner = owner; squareOwner["sourceBounds"] = square
precondition(run(squareOwner,[row("そ",square)]).items[0]["sourceVertical"] as? Bool == false)
precondition(run(owner,[row("て",[0.1,0.1,0.02,0.04],"horizontal")]).items[0]["sourceVertical"] as? Bool == false)
let prefix = row("てから",[0.1,0.1,0.04,0.12])
let duplicate = run(owner,[row(),prefix])
precondition(duplicate.items[0]["sourceFontSize"] == nil)
precondition(duplicate.items[0]["sourceVertical"] as? Bool == false)
let substring = run(owner,[row(),row("それにて",[0.1,0.1,0.04,0.12])])
precondition(substring.items[0]["sourceFontSize"] == nil)
let distinct = run(owner,[row(),row("別文",[0.1,0.1,0.04,0.12])])
precondition((distinct.items[0]["sourceFontSize"] as? Double ?? 0) > 0)
let disjoint = run(owner,[row(),row("てから",[0.4,0.1,0.04,0.12])])
precondition((disjoint.items[0]["sourceFontSize"] as? Double ?? 0) > 0)
let doubled = run(owner,[row()],CGSize(width:2000,height:2000))
precondition(abs((doubled.items[0]["sourceFontSize"] as! Double) /
    (accepted.items[0]["sourceFontSize"] as! Double) - 2) < 1e-9)
// Existing parent recovery remains independent and unchanged.
precondition(Renderer.recoverSourceDirections([owner],evidence:evidence([row()]),imageSize:size).audit.count == 1)
precondition(Renderer.recoverSourceDirections([owner],evidence:evidence([row(),row()]),imageSize:size).audit.isEmpty)
let pages = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
var reports: [[String:Any]] = []
for page in pages {
    let size = page["imageSize"] as! [Double], items = page["items"] as! [[String:Any]]
    let imageSize = CGSize(width:size[0],height:size[1]), saved = page["evidence"] as! [String:Any]
    let parent = Renderer.recoverSourceDirections(items,evidence:saved,imageSize:imageSize)
    let recovered = Renderer.recoverShortSources(parent.items,evidence:saved,imageSize:imageSize,
        recoverFont:true,recoverDirection:true)
    precondition(recovered.items.count == items.count)
    for (before,after) in zip(parent.items,recovered.items) {
        var b = before, a = after
        for key in ["sourceFontSize","sourceVertical"] { b.removeValue(forKey:key); a.removeValue(forKey:key) }
        precondition(NSDictionary(dictionary:b).isEqual(to:a),"owner/string/geometry changed")
    }
    reports.append(["page":page["id"]!,"parentDirectionRecovery":parent.audit,"candidate":recovered.audit])
}
let output: [String:Any] = ["syntheticControlsPassed":true,"pages":reports]
print(String(data:try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]),encoding:.utf8)!)
'''


def projected(region):
    bounds = [region['rect'][key] for key in ('x', 'y', 'width', 'height')]
    polygon = region.get('polygon', [])
    vertices = [list(point.values()) if isinstance(point, dict) else point for point in polygon]
    return dict(sourceBounds=bounds, source=region.get('source', ''), confidence=region.get('confidence'),
                sourceOrientation=region.get('sourceOrientation', 'unknown'),
                sourceSingleVerticalColumn=region.get('sourceSingleVerticalColumn', False),
                sourceGeometryObservation=dict(rectClipped=(any(x < 0 for x in bounds) or
                    bounds[0]+bounds[2] > 1 or bounds[1]+bounds[3] > 1),
                    polygonClipped=any(not 0 <= x <= 1 for point in vertices for x in point)))


checkpoint = json.loads((BASE / 'review-confirmed-inset-candidate-v23/decision.json').read_text())
upper = json.loads((BASE / 'review-current836-label-groups-v1/agent-upper-visual.json').read_text())
additional = {'0455','0460','0477','0490','0494','0496','0528','0570','0580','0586','0604','0676',
              '0696','0703','0708','0807','0827'}
confirmed = {p['id'] for p in upper['pages'] if p['id'] in upper['directVisualReviewPages'] and
             p['status'] == 'full_original_and_final_viewed'}
assert additional <= confirmed
ids = sorted(set(checkpoint['priorConfirmedResidualPages']) | additional)
pages, log_summary = [], []
for page in ids:
    detailed = BASE / f'rendered-confirmed-logs-v24/{page}/main-ensemble-evaluation.json'
    if not detailed.exists():
        detailed = BASE / f'rendered-parallel836-confirmed-inset-main-v24/actual/{page}/main-ensemble-evaluation.json'
    log = json.loads(detailed.read_text())  # Read the complete actual log, not the summary ledger.
    grouping = next(c['evidence']['fusion']['sourceTextBlockGrouping'] for c in log['report']['candidates']
                    if 'sourceTextBlockGrouping' in c.get('evidence', {}).get('fusion', {}))
    log_summary.append(dict(page=page, path=str(detailed),
        eligibility=[x for x in grouping.get('sourceEligibilityFailures', []) if x['reason'] != 'keptLettering'],
        pairDiagnostics=len(grouping['pairDiagnostics']) if 'pairDiagnostics' in grouping else None,
        groupDecisions=[dict(members=x.get('members'), reason=x['reason']) for x in grouping['groupDecisions']]
                       if 'groupDecisions' in grouping else None,
        paletteDecisions=len(grouping['paletteAdmissionDecisions']) if 'paletteAdmissionDecisions' in grouping else None))
    value = json.loads((BASE / f'render-inputs/current836/pages/{page}/001-render-payload.json').read_text())['value']
    descriptor = value['nativeEnsembleEvidence']['originalOCR']
    data = Path(descriptor['path']).read_bytes()
    assert hashlib.sha256(data).hexdigest() == descriptor['fileSHA256'], page
    assert descriptor['artifactSourceSHA256'] == value['nativeEnsembleEvidence']['sourceSHA256'], page
    ocr = json.loads(data)
    layout = value['nativeLayout']
    items = []
    for original in layout['items']:
        # Same source-local font transform as page(); source rectangles stay normalized.
        item = dict(original)
        frame = item['sourceFrame']
        if item.get('sourceFontSize') is not None:
            item['sourceFontSize'] *= ocr['width'] / frame[2]
        items.append(item)
    pages.append(dict(id=page, imageSize=[ocr['width'], ocr['height']], items=items,
                      evidence=dict(originalOCR=dict(regions=[projected(r) for r in ocr['regions']]))))

with tempfile.TemporaryDirectory(prefix='aidoku-confirmed-short-') as folder:
    tmp = Path(folder)
    (tmp / 'main.swift').write_text(harness)
    (tmp / 'pages.json').write_text(json.dumps(pages, ensure_ascii=False))
    started = time.perf_counter()
    subprocess.run(['xcrun', 'swiftc', '-Onone', '-module-cache-path', str(tmp / 'module-cache'),
                    str(tmp / 'main.swift'), '-o', str(tmp / 'probe')], check=True)
    compile_seconds = time.perf_counter() - started
    started = time.perf_counter()
    result = subprocess.run(['/usr/bin/time', '-l', str(tmp / 'probe'), str(tmp / 'pages.json')],
                            text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr[:6000])
    helper_seconds = time.perf_counter() - started
    report = json.loads(result.stdout)
    changed = []
    for page in report['pages']:
        for row in page['candidate']:
            if row['fontApplied'] or row['directionApplied'] or row.get('fontStatus') != 'existing-source-font-retained':
                changed.append(dict(page=page['page'], **row))
    # IDs are fixture assertions only; production never sees page IDs or labels.
    actual_fonts = {(r['page'], r['id']) for r in changed if r['fontApplied']}
    assert actual_fonts == {('0093','12'), ('0148','4'), ('0160','4'), ('0169','8'),
                            ('0287','12'), ('0528','3')}, actual_fonts
    assert not any(r['directionApplied'] for r in changed)
    prefix = next(r for r in changed if (r['page'], r['id']) == ('0807','13'))
    assert not prefix['fontApplied'] and prefix['directionUnresolved']
    assert any(r['relation'] == 'overlappingDuplicatePrefixCandidate' for r in prefix['sourceRelations'])
    manifest = json.loads((BASE / 'render-inputs/current836/manifest.json').read_text())
    denominator = len(manifest['cases'])
    assert denominator == 836
    rss = re.search(r'(\d+)\s+maximum resident set size', result.stderr)
    print(json.dumps(dict(manifestDenominator=denominator, actualLogsRead=len(log_summary),
        helperPagesExecuted=len(pages), actualCandidateRenders=0, full836CandidateRenders=0,
        newVisualReviews=0, renderQualityAccepted=False, syntheticControlsPassed=report['syntheticControlsPassed'],
        projectionLimitation='Normalized on-canvas final OCR projection; source-image pixels are not decoded or revalidated here. Production uses the image-bound Packet.',
        compileSeconds=round(compile_seconds, 4), helperExecutionSeconds=round(helper_seconds, 4),
        helperProcessPeakRSSBytes=int(rss.group(1)) if rss else None,
        phoneRuntimeMeasured=False, aggregateRenderMemoryMeasured=False,
        parentDirectionRepairs=[dict(page=p['page'], repairs=p['parentDirectionRecovery'])
                                for p in report['pages'] if p['parentDirectionRecovery']],
        candidates=changed, actualLogs=log_summary), ensure_ascii=False, indent=2))
