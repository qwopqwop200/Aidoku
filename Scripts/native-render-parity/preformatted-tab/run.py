#!/usr/bin/env python3
"""Exact preserved span/tab geometry against actual frozen WK CSS."""
from pathlib import Path
import hashlib,json,os,subprocess
ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).resolve().parent
OUT=ROOT/'build/native-render-parity/preformatted-tab';OUT.mkdir(parents=True,exist_ok=True)
O=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay'
typography=Path(os.environ.get('AIDOKU_TAB_TYPOGRAPHY',str(O/'NativeTranslationTypography.swift')))
tabs=Path(os.environ.get('AIDOKU_TAB_POLICY',str(O/'NativePreformattedTabs.swift')))
subprocess.run(['python3',str(HERE/'capture.py')],check=True,cwd=ROOT,stdout=subprocess.DEVNULL)
sources=[typography,O/'NativeTextPaintGeometry.swift',tabs,*[O/(name+'.swift') for name in ('NativeKeepAllAutoLines','NativeKeepAllTextBalance','NativeKeepAllBreakOpportunities','NativeRawTextBalance')],HERE/'Probe.swift']
subprocess.run(['xcrun','swiftc','-O','-swift-version','6','-strict-concurrency=complete',*map(str,sources),'-o',str(OUT/'shape-probe')],check=True,cwd=ROOT)
web=json.loads((OUT/'dom.json').read_text())
response=subprocess.run([str(OUT/'shape-probe')],input='\n'.join(json.dumps(w['a'],ensure_ascii=False) for w in web),text=True,capture_output=True,check=True)
native=[json.loads(line) for line in response.stdout.splitlines()];assert len(native)==len(web)
(OUT/'native.json').write_text(json.dumps(native,ensure_ascii=False,indent=2))
full=[];inline=[];text=[];pitch=[]
for i,(w,n) in enumerate(zip(web,native)):
    failure=dict(index=i,input=w['a'],web=w['whole'],native=n['whole'])
    if w['whole']!=n['whole']:full.append(failure)
    if [w['whole'][0],w['whole'][2]]!=[n['whole'][0],n['whole'][2]]:inline.append(failure)
    if w['a']['text']!=n['text']:text.append(failure)
    if len(w['children'])!=len(n['lines']) or [c['box'][1]-w['children'][0]['box'][1] for c in w['children']]!=[c[1]-n['lines'][0][1] for c in n['lines']]:pitch.append(failure)
report=dict(cases=len(web),original48WholeExact=not any(f['index']<48 for f in full),inlineAxisExact=not inline,rawTextExact=not text,
    linePitchExact=not pitch,pitchFailures=pitch,fullGeometryExact=not full,fullGeometryFailures=full,inlineFailures=inline,rawTextFailures=text,
    scope='Actual complete CoreText Typography source plus literal preformatted tab policy vs real WK block-span CSS. Original48 full Range gate; extra54 tab inline/raw UTF16/pitch gates, including positive-leading Hiragino6/12. Separate whole geometry differences remain visible; final RGBA equality not inferred.',
    sourceSHA256={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
    primarySource='https://raw.githubusercontent.com/WebKit/WebKit/c479f0fb22bf0e4c7b15074191592c3d5bf1b75d/Source/WebCore/platform/graphics/FontCascadeInlines.h',
    policyVersion='Reference uses half-space minimum gap; main changed to half-zero2026-09-08 (681c0a0ad8ad1cdcc78ee7d0ceded7bcc624ea86).')
(OUT/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
print(json.dumps({k:v for k,v in report.items() if k not in ('fullGeometryFailures','inlineFailures','rawTextFailures','pitchFailures','sourceSHA256')},ensure_ascii=False))
raise SystemExit(not(report['original48WholeExact'] and report['inlineAxisExact'] and report['rawTextExact'] and report['linePitchExact']))
