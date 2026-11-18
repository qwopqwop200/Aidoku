"""Compare actual native replay outputs; no quality labels inferred from scores."""
import hashlib
import html
import json
from pathlib import Path
import statistics
import sys

candidate, baseline = map(Path, sys.argv[1:3])
work = candidate.parent
read = lambda p: json.loads(p.read_text())
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
rows = []
for folder in sorted(candidate.iterdir()):
    report_file = folder / 'main-ensemble-evaluation.json'
    if not report_file.exists():
        continue
    new = read(report_file)['report']
    old = read(baseline / folder.name / report_file.name)['report']
    ni, oi = new['renderItems'], old['renderItems']
    decisions = new['text']['endpointDecisions']
    old_decisions = old['text']['endpointDecisions']
    assert len(decisions) == len(old_decisions)
    changed = [i for i, d in enumerate(decisions)
               if d['finalEndpoint'] != old_decisions[i]['finalEndpoint']]
    # Remove only stroke-selection metadata; all geometry, ink, text and
    # upstream predictions must match, not merely item counts.
    def invariant(items):
        return [{k: v for k, v in item.items() if not k.startswith('ensembleFinalStroke')}
                for item in items]
    assert invariant(ni) == invariant(oi), folder.name
    assert new['complete'] and new['paintedTranslationItems'] == new['expectedTranslationItems']
    assert new['text']['outwardRadiiOutputPixels'] == old['text']['outwardRadiiOutputPixels']
    for filename in ['restored.png', 'removal-mask.png']:
        assert sha(folder / filename) == sha(baseline / folder.name / filename), (folder.name, filename)
    rows.append(dict(id=folder.name, items=len(decisions), changedEndpoints=len(changed),
        selectionSeconds=sum(d['selectionSeconds'] for d in decisions),
        reviewItems=sum(d['needsReview'] for d in decisions),
        unchangedInputInkGeometryMaskRestorationAndWidth=True,
        observedQualityImprovement=None, observedQualityRegression=None,
        candidate=sha(folder/'final.png'), baseline=sha(baseline/folder.name/'final.png')))
summary = dict(pages=len(rows), items=sum(r['items'] for r in rows),
    changedEndpoints=sum(r['changedEndpoints'] for r in rows),
    medianSelectionSecondsPerPage=statistics.median(r['selectionSeconds'] for r in rows),
    maxSelectionSecondsPerPage=max(r['selectionSeconds'] for r in rows),
    peakRSSBytes=None, deviceMeasured=False, full836Validated=False,
    note='Scores are visibility proxies, not gold. Generation/invariant checks do not establish visual review. No full836 quality claim.',
    candidateDirectory=str(candidate), baselineDirectory=str(baseline),
    adaptations=['existing halo-then-fill composite, not D-A', 'bilinear render-then-resize',
                 'visible-weighted linear-luminance variance', 'bounded integer normal pairs'], rows=rows)
(candidate/'stroke-comparison.json').write_text(json.dumps(summary,indent=2)+'\n')
parts=['<!doctype html><meta charset="utf-8"><title>Stroke comparison</title>',
       '<style>body{background:#222;color:#eee;font:16px system-ui}section{margin-bottom:32px}.grid{display:grid;grid-template-columns:repeat(3,1fr);gap:8px}img{width:100%}a{color:#9cf}</style>',
       '<h1>검정·흰색 stroke 선택</h1><p>원본 / 이전 결과 / 수정 결과. 글자색·배치·두께·복원 동일성 자동 검사. 점수는 가독성 정답이 아님.</p>',
       '<a href="stroke-comparison.json">측정 결과</a>']
for row in rows:
    ident=row['id']
    source=work/'render-inputs/current836/pages'/ident/'input.png'
    paths=[source,baseline/ident/'final.png',candidate/ident/'final.png']
    parts.append(f'<section><h2>{ident} — {row["changedEndpoints"]}/{row["items"]} 색 변경, 선택 {row["selectionSeconds"]*1000:.1f} ms</h2><div class="grid">')
    for label,path in zip(['원본','이전 결과','수정 결과'],paths):
        url=html.escape(str(path),quote=True)
        parts.append(f'<div>{label}<a href="{url}"><img loading="lazy" src="{url}"></a></div>')
    parts.append('</div></section>')
(candidate/'index.html').write_text('\n'.join(parts))
print(json.dumps({k:v for k,v in summary.items() if k!='rows'},ensure_ascii=False,indent=2))
