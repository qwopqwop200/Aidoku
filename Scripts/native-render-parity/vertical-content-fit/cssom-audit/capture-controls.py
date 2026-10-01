"""Bounded actual WK optical-sizing controls for ten existing CSSOM failures."""
from pathlib import Path
import json,re,subprocess
ROOT=Path(__file__).resolve().parents[4]
BASE=ROOT/'build/native-render-parity/vertical-content-fit'
OUT=BASE/'current47-audit';OUT.mkdir(parents=True,exist_ok=True)
original=(BASE/'capture.js').read_text()
reports=json.loads((OUT/'shaping-report.json').read_text())
web=json.loads((BASE/'dom.json').read_text());jobs=[]
for failure in reports['adapterMetricFailures']:
 for off in [False,True]:
  a=dict(web[failure['index']]['a']);a.update(originalIndex=failure['index'],opticalNone=off);jobs.append(a)
script=re.sub(r'const jobs=.*?;\n return JSON.stringify', 'const jobs='+json.dumps(jobs,ensure_ascii=False)+';\n return JSON.stringify',original,count=1,flags=re.S)
script=script.replace('node.textContent=a.text;', "if(a.opticalNone)node.style.fontOpticalSizing='none';node.textContent=a.text;")
script=script.replace('const result={a,itemBox', "const canvas=document.createElement('canvas'),ctx=canvas.getContext('2d');ctx.font=c.fontStyle+' '+c.fontWeight+' '+c.fontSize+' '+c.fontFamily;ctx.textBaseline='alphabetic';ctx.textAlign='left';const m=ctx.measureText(a.text[0]);const metrics={request:ctx.font,scope:'independent canvas font request; no optical-sizing setter',width:m.width,fontBoundingBoxAscent:m.fontBoundingBoxAscent,fontBoundingBoxDescent:m.fontBoundingBoxDescent,emHeightAscent:m.emHeightAscent,emHeightDescent:m.emHeightDescent};const result={metrics,a,itemBox")
(OUT/'capture-controls.js').write_text(script)
subprocess.run(['xcrun','swiftc',str(ROOT/'Scripts/native-render-parity/vertical-content-fit/capture.swift'),'-o',str(OUT/'capture')],check=True)
subprocess.run([str(OUT/'capture'),str(OUT/'capture-controls.js'),str(OUT/'dom-controls.json')],check=True)
rows=json.loads((OUT/'dom-controls.json').read_text());native=json.loads((OUT/'native.json').read_text());summary=[]
for i in range(0,len(rows),2):
 a,b=rows[i:i+2];index=a['a']['originalIndex'];n=native[index]
 summary.append(dict(index=index,input=a['a'],originalWeb=web[index]['client']+web[index]['scroll'],currentWK=a['client']+a['scroll'],opticalNoneWK=b['client']+b['scroll'],currentNative=n['metrics'],autoInline=a['itemBox'][3],noneInline=b['itemBox'][3],nativeInline=n['inline'],autoCanvas=a['metrics'],noneCanvas=b['metrics'],nativeAdvances=n['advances'],noneMatchesNative=b['client']+b['scroll']==n['metrics']))
report=dict(cases=len(summary),noneExact=sum(r['noneMatchesNative'] for r in summary),scope='Actual macOSWK diagnostic font-optical-sizing:none countercontrol. No app edits or iOS execution.',casesDetail=summary)
(OUT/'optical-controls-report.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))
