#!/usr/bin/env python3
import json,pathlib,subprocess
ROOT=pathlib.Path(__file__).resolve().parents[3];HERE=pathlib.Path(__file__).resolve().parent;OUT=ROOT/'build/native-render-parity/vertical-content-fit';OUT.mkdir(parents=True,exist_ok=True)
s=(HERE.parent/'reference-source/BrowserOverlayView.swift').read_text()
a=s.index('        Object.assign(node.style, {\n          position:',s.index('const fontFamily ='))
b=s.index('\n        if (item.balancedColumn)',a)
style=s[a:b]
script=r'''(()=>{
 const jobs=JOBS;
 return JSON.stringify(jobs.map(a=>{
 const node=document.createElement('div'),item={clipsText:a.clips,balancedColumn:a.balanced};
 const x=0,y=0,scrollX=0,scrollY=0,width=a.width,height=a.height,fontSize=a.font,lineHeight=a.pitch;
 const paddingTop=a.pads[0],paddingRight=a.pads[1],paddingBottom=a.pads[2],paddingLeft=a.pads[3];
 const vertical=true,wrappingScript=a.script==='korean'?'korean':'cjk',displayedText=a.text;
 const fontFamily=a.script==='japanese'?"'Hiragino Sans','YuGothic','Noto Sans CJK JP',-apple-system,BlinkMacSystemFont,sans-serif":a.script==='han'?"'PingFang SC','PingFang TC','Noto Sans CJK SC',-apple-system,BlinkMacSystemFont,sans-serif":"'Apple SD Gothic Neo','Noto Sans CJK KR','Noto Sans KR',-apple-system,BlinkMacSystemFont,sans-serif";
 const surfaceGradient=null,surface='255,255,255',opacity=1,sampledBackground=null,veil='255,255,255',veilAlpha=.42,foreground='0,0,0';
 STYLE
 if(item.balancedColumn)node.style.alignItems='flex-start';
 node.textContent=a.text;document.body.append(node);
 const c=getComputedStyle(node),r=node.getBoundingClientRect(),range=document.createRange();range.selectNodeContents(node);
 const lines=Array.from(range.getClientRects(),r=>[r.x,r.y,r.width,r.height]);
 const chars=[];for(let i=0;i<a.text.length;i++){range.setStart(node.firstChild,i);range.setEnd(node.firstChild,i+1);let rr=range.getBoundingClientRect();chars.push([a.text[i],rr.x,rr.y,rr.width,rr.height]);}
 const clone=node.cloneNode(false),child=document.createElement('span');child.textContent=a.text;clone.append(child);document.body.append(clone);const childBox=child.getBoundingClientRect();const itemBox=[childBox.x,childBox.y,childBox.width,childBox.height];clone.remove();
 const result={a,itemBox,client:[node.clientWidth,node.clientHeight],scroll:[node.scrollWidth,node.scrollHeight],box:[r.x,r.y,r.width,r.height],padding:[c.paddingTop,c.paddingRight,c.paddingBottom,c.paddingLeft].map(parseFloat),font:c.font,pitch:parseFloat(c.lineHeight),lines,chars};node.remove();return result;
 }));})()
'''
texts=[('japanese','日本語の縦書き'),('japanese','天地\n玄黄\n宇宙'),('japanese','ABCDEFGHIJKLMN'),('japanese','日A本B語!の縦書き、です。'),('japanese','「縦書き」\n！？'),('korean','가나다라마바사아자차카타파하'),('han','天地玄黄宇宙洪荒')]
jobs=[]
for script_name,text in texts:
 for font,pitch in [(20,24),(20.5,24.6),(12,12),(23.9999999,23.9999999)]:
  for width,height,pads in [(100,160,[3,3,3,3]),(20,50,[3,3,3,3]),(30.49,30.51,[2.99,4.125,3.49,1.5]),(8.5,15,[1,2,1,2])]:
   for clips in [False,True]:
    for balanced in [False,True]:jobs.append(dict(script=script_name,text=text,font=font,pitch=pitch,width=width,height=height,pads=pads,clips=clips,balanced=balanced))
script=script.replace('JOBS',json.dumps(jobs,ensure_ascii=False)).replace(' STYLE',style)
(OUT/'capture.js').write_text(script)
subprocess.run(['swiftc',str(HERE/'capture.swift'),'-o',str(OUT/'capture')],check=True)
subprocess.run([str(OUT/'capture'),str(OUT/'capture.js'),str(OUT/'dom.json')],check=True)
rows=json.loads((OUT/'dom.json').read_text());print('captured actual frozenCSS vertical nodes',len(rows))
for r in rows[:16]:print({k:r[k] for k in ['a','client','scroll','itemBox']})
