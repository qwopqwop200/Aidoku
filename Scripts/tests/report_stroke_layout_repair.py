"""Saved main replay invariants and before/after gallery; never infer visual success."""
import hashlib
import html
import json
from pathlib import Path
import statistics
import sys

output, baseline = map(Path, sys.argv[1:3])
allow_source_recovery = '--allow-source-recovery' in sys.argv[3:]
allow_ink_reselection = '--allow-ink-reselection' in sys.argv[3:] or allow_source_recovery
read = lambda p: json.loads(p.read_text())
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
rows = []
before = output/'before'
before.mkdir(exist_ok=True)
for folder in sorted(output.iterdir()):
    path = folder/'main-ensemble-evaluation.json'
    if not path.exists():
        continue
    ident = folder.name
    new = read(path)['report']
    old = read(baseline/ident/path.name)['report']
    assert new['complete'] and new['paintedTranslationItems'] == new['expectedTranslationItems']
    assert new['paintedTranslationItems'] == old['paintedTranslationItems']
    for name in ['restored.png','removal-mask.png']:
        assert sha(folder/name) == sha(baseline/ident/name), (ident,name)
    ni = {str(x['id']):x for x in new['renderItems']}
    oi = {str(x['id']):x for x in old['renderItems']}
    assert ni.keys() == oi.keys()
    source_prediction_changes = []
    source_evidence_changes = []
    for key in ni:
        for field in ['sourceBounds','sourceFontSize'] + ([] if allow_ink_reselection else ['ensembleDisplayFill','ensemblePaletteAudit']):
            assert ni[key].get(field) == oi[key].get(field), (ident,key,field)
        if allow_ink_reselection:
            for field in ['sourceFill','sourceStroke','previousOriginalEvidence']:
                same = ni[key].get('ensemblePaletteAudit',{}).get(field) == oi[key].get('ensemblePaletteAudit',{}).get(field)
                if not same and field != 'previousOriginalEvidence' and key not in source_prediction_changes:
                    source_prediction_changes.append(key)
                if not same and field == 'previousOriginalEvidence': source_evidence_changes.append(key)
                assert same or allow_source_recovery, (ident,key,field)
        assert ''.join(ni[key].get('text','').split()) == ''.join(oi[key].get('text','').split())
    nn = {str(x['id']):x for x in new['text']['rawNativeItems']}
    oo = {str(x['id']):x for x in old['text']['rawNativeItems']}
    assert nn.keys() == oo.keys()
    endpoint_changes = [key for key in nn if nn[key]['finalDisplayStroke'] != oo[key]['finalDisplayStroke']]
    fill_changes = [key for key in nn if nn[key].get('finalDisplayFill',
        nn[key]['finalStrokeDecision'].get('displayFillRGB')) != oo[key].get('finalDisplayFill',
        oo[key]['finalStrokeDecision'].get('displayFillRGB', nn[key]['finalStrokeDecision'].get('selectedFillRGB')))]
    geometry_changes = [key for key in nn if any(nn[key].get(k) != oo[key].get(k)
        for k in ['fontSize','frameOutputTopLeft','actualCoreTextLineStrings'])]
    raster_bounds_changes = [key for key in nn if nn[key].get('retainedFillBoundsOutput') != oo[key].get('retainedFillBoundsOutput')]
    for x in nn.values():
        assert x['visibleUTF16'] == x['sourceUTF16']
        assert x['finalDisplayStroke'] in ([0,0,0],[255,255,255])
    target = before/(ident+'.png')
    if not target.exists():
        target.hardlink_to(baseline/ident/'final.png')
    rows.append(dict(id=ident,painted=len(nn),changedStrokeIDs=endpoint_changes,
        changedDisplayFillIDs=fill_changes,
        changedRasterBoundsIDs=raster_bounds_changes,
        changedSourcePredictionIDs=source_prediction_changes,
        changedSourceEvidenceIDs=source_evidence_changes,
        changedGeometryIDs=geometry_changes,sourcePredictionsPreserved=not source_prediction_changes,
        textMaskRestorationPreserved=True,
        selectionSeconds=sum(x['finalStrokeDecision']['selectionSeconds'] for x in nn.values()),
        aotInferenceCalls=new['restoration'].get('inferenceCalls',0)))
summary=dict(pages=len(rows),painted=sum(r['painted'] for r in rows),
    changedStrokeItems=sum(len(r['changedStrokeIDs']) for r in rows),
    changedDisplayFillItems=sum(len(r['changedDisplayFillIDs']) for r in rows),
    changedGeometryItems=sum(len(r['changedGeometryIDs']) for r in rows),
    changedSourcePredictionItems=sum(len(r['changedSourcePredictionIDs']) for r in rows),
    aotInferenceCalls=sum(r['aotInferenceCalls'] for r in rows),
    medianStrokeSelectionSeconds=statistics.median(r['selectionSeconds'] for r in rows),
    full836Validated=False,peakMemoryBytes=None,deviceMeasured=False,inkReselectionAllowed=allow_ink_reselection,rows=rows)
(output/'verification.json').write_text(json.dumps(summary,indent=2)+'\n')
parts=['<!doctype html><meta charset="utf-8"><title>色・高さ・フォント修正</title>',
    '<style>body{background:#202127;color:#eee;font:16px system-ui;margin:24px}.grid{display:grid;grid-template-columns:repeat(3,1fr);gap:8px}img{width:100%}section{margin-bottom:32px}a{color:#9cf}</style>',
    f'<h1>표시 색상·stroke·배치 비교</h1><p>개발 {len(rows)}장 비교. 원문·마스크·복원 유지. 색 추정 변경은 검사 기록 참조. 전체 836장 검증은 아직.</p>',
    '<a href="verification.json">검사 기록</a>']
for row in rows:
    ident=row['id']
    source=output.parent/'render-inputs/current836/pages'/ident/'input.png'
    parts.append(f'<section><h2>{ident} — stroke {len(row["changedStrokeIDs"])}항목 / 배치 {len(row["changedGeometryIDs"])}항목 변경</h2><div class="grid">')
    for label,path in [('원본',source),('수정 전',before/(ident+'.png')),('수정 후',output/ident/'final.png')]:
        url=html.escape(str(path),quote=True)
        parts.append(f'<div>{label}<a href="{url}"><img loading="lazy" src="{url}"></a></div>')
    parts.append('</div></section>')
(output/'index.html').write_text('\n'.join(parts))
print(json.dumps({k:v for k,v in summary.items() if k!='rows'},indent=2))
