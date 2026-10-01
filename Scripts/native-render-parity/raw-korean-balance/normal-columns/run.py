#!/usr/bin/env python3
"""Bounded diagnostic; the actual WK ordinary-auto ranges remain supplied."""
import hashlib, json, pathlib, shutil, subprocess
HERE=pathlib.Path(__file__).resolve().parent
ROOT=HERE.parents[3]
OUT=ROOT/'build/native-render-parity/raw-korean-balance/normal-columns'
OUT.mkdir(parents=True,exist_ok=True)
subprocess.run(['xcrun','swiftc',str(HERE/'capture.swift'),'-o',str(OUT/'capture')],check=True)
subprocess.run([str(OUT/'capture'),str(OUT/'capture.json')],check=True)
primary=ROOT/'build/native-render-parity/raw-korean-balance/normal-primary/probe'
if not primary.exists():
 subprocess.run(['python3',str(HERE.parent/'opportunities/probe-normal.py')],check=True)
data=json.loads((OUT/'capture.json').read_text()); inputs=[str(len(data['WKWebView']))]
for fixture in data['CFStringTokenizer']:
 raw=fixture['text'].encode('utf-16-le'); units=[int.from_bytes(raw[i:i+2],'little') for i in range(0,len(raw),2)]
 inputs.append(' '.join(map(str,[len(units),*units,len(fixture['ends']),*fixture['ends']])))
lines=subprocess.check_output([str(primary)],input=('\n'.join(inputs)+'\n').encode()).decode().splitlines()
for fixture,line in zip(data['WKWebView'],lines):fixture['primaryOffsets']=[int(x) for x in line.split(',')]
(OUT/'input.json').write_text(json.dumps(data,ensure_ascii=False,indent=2))
shutil.copyfile(HERE/'Probe.swift',OUT/'main.swift')
production=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay'
sources=[production/'NativeRawTextBalance.swift',production/'NativeKeepAllBreakOpportunities.swift',production/'NativeNormalBreakOpportunities.swift',production/'NativeNormalTextFlow.swift',OUT/'main.swift']
subprocess.run(['xcrun','swiftc',*map(str,sources),'-o',str(OUT/'probe')],check=True)
result=json.loads(subprocess.check_output([str(OUT/'probe'),str(OUT/'input.json')]))
(OUT/'native.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
supported=[x for x in result if x['canvas']['greedy'] is not None and x['coretext']['greedy'] is not None]
unsupported=[x for x in result if x['id'].startswith('unsupported-') or '\t' in x['text']]
report=dict(cases=len(result),supportedCases=len(supported),supportedAutoMatches=sum(x['canvas']['greedy']==x['auto'] and x['coretext']['greedy']==x['auto'] for x in supported),nativePrimaryOffsetMatches=sum(x['nativePrimaryOffsets']==x['referencePrimaryOffsets'] for x in supported),supportedBalanceMatches=sum(x['canvas']['ranges']==x['web'] and x['coretext']['ranges']==x['web'] for x in supported),unsupportedCases=len(unsupported),unsupportedDeclines=sum(x['canvas']['greedy'] is None and x['coretext']['greedy'] is None for x in unsupported),canvasMatches=sum(x['canvas']['ranges']==x['web'] for x in result),coreTextMatches=sum(x['coretext']['ranges']==x['web'] for x in result),canvasAutoMatches=sum(x['canvas']['greedy']==x['auto'] for x in result),coreTextAutoMatches=sum(x['coretext']['greedy']==x['auto'] for x in result),sourceCommit='dd5fe1011df7e3438ac4889356abcab7681df46d',scope='Diagnostic only: native Swift opportunities +ordinary greedy+balance consumes primary fast paths around public CF neutral backend; primary C++ item boundaries are comparison-only, no WK row input. Two descriptors plus existing14 primary ASCII/CF controls at two widths and collapsed-space probe. Range capture groups nonempty physical fragments, allocating collapsed zero-rect ASCII whitespace to preceding visible row or first row; not caret ownership proof. Unsupported TAB/LF/bidi return nil for established caller fallback. No general CF/ICU equivalence or pixel parity.',checks=result,sourceSHA256={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [HERE/'capture.swift',*sources[:-1]]})
(OUT/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
print(json.dumps({k:report[k] for k in ['cases','supportedCases','nativePrimaryOffsetMatches','supportedAutoMatches','supportedBalanceMatches','unsupportedCases','unsupportedDeclines']}))
