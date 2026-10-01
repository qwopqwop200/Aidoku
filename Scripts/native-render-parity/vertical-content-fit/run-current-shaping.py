#!/usr/bin/env python3
"""Compile the actual vertical Post adapter and report remaining shaping gaps."""
from pathlib import Path
import hashlib,json,re,subprocess,os
ROOT=Path(__file__).resolve().parents[3]; HERE=Path(__file__).resolve().parent
BASE=ROOT/'build/native-render-parity/vertical-content-fit'
OUT=Path(os.environ.get('AIDOKU_VERTICAL_PROBE_OUT',str(BASE))); OUT.mkdir(parents=True,exist_ok=True)
O=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay'
layout=(O/'NativeTranslationLayout.swift').read_text()
(OUT/'Models.swift').write_text(layout.split('/// Actor confinement')[0].replace('import UIKit\n',''))
geometry=re.search(r'    static func validGeometry\([\s\S]*?\n    }',layout).group()
(OUT/'Shims.swift').write_text('import CoreGraphics\nstruct UIEdgeInsets {var top:CGFloat;var left:CGFloat;var bottom:CGFloat;var right:CGFloat}\nextension CGRect {func inset(by i:UIEdgeInsets)->CGRect {CGRect(x:minX+i.left,y:minY+i.top,width:width-i.left-i.right,height:height-i.top-i.bottom)}}\nenum NativeTranslationLayoutPlanner {\n'+geometry+'\n}\n')
post=(O/'NativeTypographyPostPolish.swift').read_text()
# Verbatim bounded policy section: excludes unrelated restoration/application
# adapters. The real layout descriptor is compiled, with UIKit insets transport.
(OUT/'PostAdapter.swift').write_text('import Foundation\nimport CoreGraphics\nenum NativeTypographyPostPolish {\n'+post[post.index('    struct ContentFitMetrics:'):post.index('    struct Candidate {')]+'\n}\n')
typography=Path(os.environ.get('AIDOKU_VERTICAL_TYPOGRAPHY',str(O/'NativeTranslationTypography.swift')))
sources=[typography,O/'NativeTextPaintGeometry.swift',O/'NativeVerticalContentFit.swift',OUT/'Models.swift',OUT/'Shims.swift',OUT/'PostAdapter.swift',HERE/'Probe.swift']
for name in ['NativePreLineTextFlow','NativeNormalTextFlow','NativeNormalBreakOpportunities','NativeKeepAllBreakOpportunities',
 'NativeKeepAllAutoLines','NativeKeepAllTextBalance','NativeRawTextBalance','NativePreformattedTabs','NativeVisibleControlGlyphs',
 'NativeCTFontStrokePainter','NativeVerticalLetterSpacing']:
 sources.append(O/(name+'.swift'))
snapshot=OUT/'source-snapshot';snapshot.mkdir(exist_ok=True)
captured=[]
for p in sources:
 q=snapshot/p.name;q.write_bytes(p.read_bytes());captured.append(q)
sources=captured
subprocess.run(['xcrun','swiftc','-O','-swift-version','6','-strict-concurrency=complete',*map(str,sources),'-o',str(OUT/'probe')],check=True,cwd=ROOT)
subprocess.run([str(OUT/'probe'),str(BASE/'dom.json'),str(OUT/'native.json')],check=True,cwd=ROOT)
web=json.loads((BASE/'dom.json').read_text());native=json.loads((OUT/'native.json').read_text())
failures=[];metric_failures=[]
for i,(w,n) in enumerate(zip(web,native)):
    columns=len(set(round(line[0]*100000) for line in w['lines']))
    if columns!=n['columns'] or w['itemBox'][3]!=n['inline']:
        failures.append(dict(index=i,fixture=w['a'],webColumns=columns,webInlineExtent=w['itemBox'][3],native=n))
    if w['client']+w['scroll']!=n['metrics']:
        metric_failures.append(dict(index=i,fixture=w['a'],web=w['client']+w['scroll'],native=n['metrics']))
report=dict(exact=not failures,cases=len(web),mismatches=len(failures),failures=failures,
    adapterMetricMismatches=len(metric_failures),adapterMetricFailures=metric_failures,
    scope='Actual Core Text verticalLineAdvances plus production Post contentFitMetrics branch compiled verbatim. Inputs compared with full DOM Range-visible column count and span-clone inline extent; these observations can diverge from anonymous flex layout. Only client/scroll mismatch counts directly compare actual original-node CSSOM. Policy-only 448 exact result does not imply complete anonymous-node shaping or final PNG equality.',
    observationLimit='Korean case320 original Range exposes two nonzero column positions, while cloned explicit span width72 implies three columns. Native has three; this observation alone does not establish a native font defect.',
    sourceSHA256={(str(p.relative_to(ROOT)) if p.is_relative_to(ROOT) else str(p)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources})
(OUT/'shaping-report.json').write_text(json.dumps(report,indent=2,ensure_ascii=False))
print(json.dumps({k:v for k,v in report.items() if k not in ('failures','adapterMetricFailures','sourceSHA256')},ensure_ascii=False))
# This is a diagnostic report, not an equality gate; remaining mismatches are
# explicit and must stay visible to the separate shaping owner.
