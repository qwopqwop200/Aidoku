#!/usr/bin/env python3
import json,pathlib,subprocess
HERE=pathlib.Path(__file__).resolve().parent;ROOT=HERE.parents[3]
OUT=ROOT/'build/native-render-parity/raw-korean-balance/keep-all-caller';OUT.mkdir(exist_ok=True,parents=True)
(OUT/'main.swift').write_text((HERE/'Probe.swift').read_text())
OVERLAY=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay'
subprocess.run(['xcrun','swiftc','-O',*[str(OVERLAY/(x+'.swift')) for x in ['NativeRawTextBalance','NativeKeepAllBreakOpportunities','NativeKeepAllTextBalance']],str(OUT/'main.swift'),'-o',str(OUT/'native')],check=True)
records=json.loads(subprocess.check_output([str(OUT/'native'),str(OUT/'capture.json')]))
def rows(text,ranges):
 u=text.encode('utf-16-le')
 return [u[start*2:(start+length)*2].decode('utf-16-le').strip(' \t') for start,length in ranges]
for record in records:
 for mode in ['canvas','coretext']:
  a=record[mode];a['exactRanges']=a['ranges']==record['web'];a['exactRowText']=rows(record['text'],a['ranges'])==rows(record['text'],record['web'])
report=dict(cases=len(records),modes={mode:dict(exactRanges=sum(r[mode]['exactRanges'] for r in records),exactRowText=sum(r[mode]['exactRowText'] for r in records),accepted=sum(r[mode]['accepted'] for r in records)) for mode in ['canvas','coretext']},moreThanSixRows=sum(len(r['auto'])>6 for r in records),records=records,scope='Actual host WK ordinary auto and balance rows; pure keep-all caller fed captured Canvas item advances and separately genuine CoreText advances at same font. Visible row-text identity trims only U0020/TAB; NBSP untouched. Not complete font/Unicode or raster parity.')
(OUT/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2));print(json.dumps({k:v for k,v in report.items() if k!='records'}))
