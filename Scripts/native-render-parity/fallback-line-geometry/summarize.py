#!/usr/bin/env python3
import json,math,pathlib
root=pathlib.Path(__file__).resolve().parents[3];out=root/'build/native-render-parity/fallback-line-geometry'
d=json.loads((out/'captured.json').read_text());native={x['id']:x for x in d['native']};rows=[];scalars=0
for r in d['oracle']['rows']:
 f=r['input'];plain=r['plain'];marked=r['marked'];n=native[r['id']];a=r['canvas'][0]['ascent'];b=r['canvas'][0]['descent'];p=math.floor(f['pitch']);count=len(f['text'].split('\n'));top=(f['height']-count*p)/2;offset=math.floor((p-a-b)/2)
 baseline=[top+offset+a+i*p for i in range(count)]
 expected=[]
 for s in plain['ranges']:
  row=f['text'][:s['start']].count('\n');expected.append((top+offset+row*p,a+b))
 vertical=max(abs(s['box'][1]-v[0])+abs(s['box'][3]-v[1]) for s,v in zip(plain['ranges'],expected))
 marker=max(abs(s['box'][1]-m['box'][1])+abs(s['box'][3]-m['box'][3]) for s,m in zip(plain['ranges'],marked['ranges']))
 baseline_delta=max(abs(a-b) for a,b in zip(baseline,marked['baselines']))
 raw=n['primary'];desc=raw['descent'];desc=3 if desc<3 and raw['leading']>=3 and raw['face'].startswith('Hiragino') else desc
 metric=(math.floor(raw['ascent']+.5),math.floor(desc+.5))
 rows.append({'id':r['id'],'script':f['script'],'font':f['font'],'pitch':f['pitch'],'primaryCanvas':[a,b],'primaryRawCT':raw,'metricRuleMatches':metric==(a,b),'predictedBaseline':baseline,'webBaseline':marked['baselines'],'baselineDelta':baseline_delta,'rangeVerticalDelta':vertical,'baselineMarkerRangeDelta':marker,'CTNoNaturalLeadingBaseline':[x['topBaseline'] for x in n['noNaturalLeadingLines']]})
 scalars+=len(plain['ranges'])
web=json.loads((root/'build/native-render-parity/verify-image-build30-snapshot/original-plus-translation/web-final-layout.json').read_text())
card=next(x for x in web['layers'] if x.get('kind')=='item' and x.get('id')=='1')
ios=json.loads((out/'font-metrics-ios.json').read_text());ct=next(x for x in ios if x['face']=='HiraginoSans-W6' and x['size']==6)
report={'macOSCases':len(rows),'macOSScalars':scalars,'allPredictedBaselineAndRangeVerticalExact':all(x['baselineDelta']==0 and x['rangeVerticalDelta']==0 and x['baselineMarkerRangeDelta']==0 and x['metricRuleMatches'] for x in rows),'maximumDelta':max(max(x['baselineDelta'],x['rangeVerticalDelta'],x['baselineMarkerRangeDelta']) for x in rows),'actualIOSCorrelation':{'source':'BUILD30 same-pass original-plus-translation card1 and standalone CoreText executable in same iOS26.5 simulator','computedFamily':card['style']['fontFamily'],'fontWeight':card['style']['fontWeight'],'fontSize':card['style']['fontSize'],'lineHeight':card['style']['lineHeight'],'primaryCanvas':[card['textMetrics']['fontBoundingBoxAscent'],card['textMetrics']['fontBoundingBoxDescent']],'rawCT':ct,'ceilPrimary':[math.ceil(ct['ascent']),math.ceil(ct['descent'])],'allScalarRangeHeights':sorted(set(x['rect']['height'] for x in card['scalarRects']))},'scope':'Actual macOS WebKit64 independent captures with baseline marker transport checked against untouched scalar ranges. Formula proves vertical first-line offset/fixed pitch/primary-family Range heights, not horizontal glyph raster equality. iOS primary ceil rule is correlated to one actualmixed-script fixture and measured CoreText runtime; no universal platform implementation claim.','primarySources':['https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebCore/platform/graphics/coretext/FontCoreText.cpp#L140-L145','https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebCore/platform/graphics/FontMetrics.h#L51-L71'],'cases':rows}
(out/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2));print(json.dumps({k:v for k,v in report.items() if k!='cases'},ensure_ascii=False,indent=2))
assert report['allPredictedBaselineAndRangeVerticalExact']
