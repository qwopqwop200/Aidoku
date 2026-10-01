"""Independently verify immutable original-input CSSOM equality after iOS49."""
from pathlib import Path
import hashlib,json,re
ROOT=Path(__file__).resolve().parents[4]
BASE=ROOT/'build/native-render-parity/vertical-content-fit'
IOS=ROOT/'build/native-render-parity/verify-vertical-cssom-build49-snapshot'
OUT=BASE/'current47-audit/ios49-closure.json'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
canonical=lambda o:hashlib.sha256(json.dumps(o,ensure_ascii=False,sort_keys=True).encode()).hexdigest()
original=json.loads((BASE/'dom.json').read_text()); inputRows=json.loads((Path(__file__).parent/'ios-inputs.json').read_text())
mac=json.loads((BASE/'current45/shaping-report.json').read_text())
web=json.loads((IOS/'web-layout.json').read_text());native=json.loads((IOS/'native-layout.json').read_text());summary=json.loads((IOS/'report.json').read_text())
expectedIndices=[r['index'] for r in mac['adapterMetricFailures']]
assert len(web)==len(native)==len(inputRows)==10
assert [w['a']['originalIndex'] for w in web]==expectedIndices
script=(IOS/'input.js').read_text();jobs=json.loads(re.search(r'const jobs=(.*?);\n return JSON.stringify',script,re.S).group(1))
assert jobs==inputRows
assert [w['a'] for w in web]==inputRows and [n['a'] for n in native]==inputRows
baseStyle=(BASE/'capture.js').read_text();baseStyle=baseStyle[baseStyle.index('Object.assign(node.style'):baseStyle.index('if(item.balancedColumn)')]
actualStyle=script[script.index('Object.assign(node.style'):script.index('if(item.balancedColumn)')]
assert baseStyle==actualStyle
assert 'opticalNone' not in script and 'fontOpticalSizing' not in script
expectedHTML="<html><head><meta name='viewport' content='width=device-width,initial-scale=1'><style>html,body{margin:0;background:white}</style></head><body></body></html>"
assert (IOS/'input.html').read_text()==expectedHTML
reports=[]
for w,n,s in zip(web,native,summary['reports']):
 index=w['a']['originalIndex'];expected=dict(original[index]['a']);expected['originalIndex']=index
 assert w['a']==expected
 observed=w['client']+w['scroll'];actual=n['metrics']
 assert observed==actual==s['web']==s['native'] and s['index']==index and s['exact'] is True
 reports.append(dict(index=index,input=w['a'],clientScroll=actual,exact=True,
   macOriginalClientScroll=original[index]['client']+original[index]['scroll'],
   nativeColumns=n['lineCount'],nativeRanges=n['lineRanges'],nativeAdvances=n['lineAdvances']))
assert summary['passed'] is True and summary['expectedCount']==10
report=dict(closed=True,cases=10,exact=10,os=summary['os'],viewport=json.loads((IOS/'viewport.json').read_text()),
 scope='All ten original macOS CSSOM failure descriptors close on actual iOS production shaper/Post. Original input, frozen style, no optical override, strict integer tuple comparison.',
 boundaries=['Does not establish all448 cases iOS equality.','Does not imply arbitrary vertical font/run or PNG equality.','The separate actual Han pixel gate remains independently owned.'],
 inputSHA256=canonical(inputRows),frozenStyleSHA256=hashlib.sha256(actualStyle.encode()).hexdigest(),
 actualCaptureSHA256={str(p.relative_to(ROOT)):sha(p) for p in sorted(IOS.iterdir()) if p.is_file()},reports=reports)
OUT.write_text(json.dumps(report,ensure_ascii=False,indent=2))
print(json.dumps(dict(closed=report['closed'],cases=10,exact=10,inputSHA256=report['inputSHA256'],frozenStyleSHA256=report['frozenStyleSHA256'],report=str(OUT.relative_to(ROOT))),indent=2))
