from pathlib import Path
import json,re,subprocess
ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).resolve().parent
OUT=ROOT/'build/native-render-parity/preformatted-tab';OUT.mkdir(parents=True,exist_ok=True)
source=(HERE/'ReferenceCapture.swift').read_text()
script=re.search(r'let script = #"""([\s\S]*?)"""#',source).group(1).strip()
body=script[script.index('.map(a=>{')+len('.map(a=>{'):script.rindex('}))')]
body=body.replace("fontFamily:'Apple SD Gothic Neo'","fontFamily:a.script==='japanese'?'Hiragino Sans':'Apple SD Gothic Neo'")
body=body.replace("fontSize:'8.75px',lineHeight:'10.5px'", "fontSize:a.font+'px',lineHeight:(a.font*1.2)+'px'")
body=body.replace('const children=[...parent.children].map(s=>{', 'const children=[...parent.children].map(s=>{')
body=body.replace('return {text:s.textContent,box:', "const chars=[];for(let i=0;i<s.textContent.length;i++){r.setStart(s.firstChild,i);r.setEnd(s.firstChild,i+1);const rr=r.getBoundingClientRect();chars.push([rr.x,rr.y,rr.width,rr.height]);}return {text:s.textContent,chars,box:")
body=body.replace('return {a,whole:', "const c=getComputedStyle(d),ctx=document.createElement('canvas').getContext('2d');ctx.font=c.font;const metrics={space:ctx.measureText(' ').width,zero:ctx.measureText('0').width};return {a,metrics,whole:")
texts=['가','드디어 \n선생\n님이 \n왔다','안녕하세요, \n반갑습니다!','  가\t 나  \n다\u00a0라 ']
jobs=[dict(mode='pre',text=t,width=w,align=a,font=8.75) for t in texts for w in [5.484375,23.1328125,51.5,85] for a in ['left','center','right']]
extra=['    가\t나','\t\t가','        \t가','가\t\t나','\t가\t나\t','  AB\t CD  ','😀\t가\n다\t😀']
jobs += [dict(mode='pre',text=t,width=85,align=a,font=f) for t in extra for f in [8.75,12,20.5] for a in ['left','center']]
jobs += [dict(mode='pre',text=t,width=85,align=a,font=f,script='japanese') for t in ['あ\tい\nう\tえ','あい\nうえ','\t\tあ'] for f in [6,12] for a in ['left','center']]
script='JSON.stringify('+json.dumps(jobs,ensure_ascii=False)+'.map(a=>{'+body+'}))'
(OUT/'capture.js').write_text(script)
subprocess.run(['xcrun','swiftc',str(HERE/'Capture.swift'),'-o',str(OUT/'capture')],check=True)
subprocess.run([str(OUT/'capture'),str(OUT/'capture.js'),str(OUT/'dom.json')],check=True)
rows=json.loads((OUT/'dom.json').read_text());print('Captured',len(rows),'actual WK preformatted span cases')
for r in rows[48:54]:print(r['a'],r['whole'],r['metrics'])
