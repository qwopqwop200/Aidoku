#!/usr/bin/env python3
import json,pathlib,subprocess,random
ROOT=pathlib.Path(__file__).resolve().parents[2];HERE=pathlib.Path(__file__).resolve().parent;OUT=ROOT/'build/native-render-parity/rotated-readability';SRC=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay'
NODE=r'''
const fs=require('fs'),vm=require('vm'),base=process.argv[1],fixtures=JSON.parse(fs.readFileSync(0,'utf8'));
const view=fs.readFileSync(base+'/BrowserOverlayView.swift','utf8'),s=view.indexOf("if(opacity===1&&items.length<=256",view.indexOf('Readability floor for rotated plates.')),end=view.indexOf("    // A rotated caption's opaque plate is final now.",s);
const body=view.slice(s,end).replaceAll('\\\\','\\').replace('layouts=0,pixels=786432','layouts=f.layouts??0,pixels=f.pixels??786432');
const script=fs.readFileSync(base+'/BrowserSlantedSourceRestoration.swift','utf8').split('static let script = """')[1].split('"""')[0];
const context=vm.createContext({performance:{now:()=>0}});vm.runInContext(script,context);
vm.runInContext(`globalThis.run=f=>{
 const q=f.rect||[100,100,60,35],text=f.text||'HELLO WORDS',font=f.font??6,scrollX=0,scrollY=0,opacity=f.opacity??1;
 const item={id:f.name,text,vertical:false,wrappingScript:f.korean===false?'latin':'korean'},items=Array.from({length:f.count||1},()=>item);
 const cleanupImageGeometry={frame:[0,0,500,500]},sourceImage={complete:true,naturalWidth:500,naturalHeight:500},Node={TEXT_NODE:3};
 function nodeFor(rect,own){const st={left:String(rect[0]),top:String(rect[1]),width:String(rect[2]),height:String(rect[3]),fontSize:String(own?font:6),lineHeight:String((own?font:6)*1.2),paddingTop:'2',paddingRight:'2',paddingBottom:'2',paddingLeft:'2',transform:own?'rotate('+(f.angle??.2)+'rad)'+((f.scale??1)<1?' scaleX('+f.scale+')':''):'none',visibility:'visible',fontWeight:'700',fontFamily:'Fixture',backgroundColor:'rgb(245,245,245)',backgroundImage:'none'};
 Object.defineProperty(st,'cssText',{get(){return JSON.stringify(Object.fromEntries(Object.entries(this).filter(([k])=>k!=='cssText')));},set(v){Object.assign(this,JSON.parse(v));}});
 const n={style:st,dataset:{aidokuRegion:own?f.name:'peer',rotatingPanel:own?'true':'false',sourceBackgroundColor:'rotated-panel'},childElementCount:0,textContent:own?(f.renderedText??text):'PEER',firstChild:{nodeType:3,data:own?text:'PEER'},getBoundingClientRect(){const l=parseFloat(st.left),t=parseFloat(st.top),w=parseFloat(st.width),h=parseFloat(st.height);return {left:l,top:t,right:l+w,bottom:t+h,width:w,height:h};}};return n;}
 const node=nodeFor(q,true),peer=f.peer?nodeFor(f.peer,false):null,root={dataset:{},querySelectorAll(sel){return sel.includes('source-readability')?[]:peer?[node,peer]:[node];}};node.parentElement=root;if(peer)peer.parentElement=root;
 if(f.upright)node.dataset.uprightQuad='true';if(f.bgImage)node.style.backgroundImage='url(source)';if(f.opaque===false)node.style.backgroundColor='rgba(245,245,245,.5)';
 function shape(n){const s=n.style,size=parseFloat(s.fontSize),pitch=parseFloat(s.lineHeight),W=parseFloat(s.width),H=parseFloat(s.height),padding=['paddingTop','paddingRight','paddingBottom','paddingLeft'].map(k=>parseFloat(s[k])),a=size*.5,cols=Math.max(1,Math.floor(Math.max(.01,W-padding[1]-padding[3])/a)),chars=Array.from(n.textContent),rows=Math.max(1,Math.ceil(chars.length/cols)),top=padding[0]+(H-padding[0]-padding[2]-rows*pitch)/2+(pitch-size)/2;
 const rect=(i,count=1)=>{const l=parseFloat(s.left)+padding[3]+i%cols*a,t=parseFloat(s.top)+top+Math.floor(i/cols)*pitch;return {left:l,top:t,right:l+count*a,bottom:t+size,width:count*a,height:size};};
 return {size,pitch,W,H,padding,a,cols,chars,rows,rect,lines:Array.from({length:rows},(_,r)=>rect(r*cols,Math.min(cols,chars.length-r*cols)))};}
 Object.defineProperties(node,{scrollWidth:{get(){const sh=shape(this);return sh.a>sh.W-sh.padding[1]-sh.padding[3]+.5?sh.W+1:sh.W;}},clientWidth:{get(){return parseFloat(this.style.width);}},scrollHeight:{get(){const sh=shape(this);return sh.rows*sh.pitch+sh.padding[0]+sh.padding[2]>sh.H+.5?sh.H+1:sh.H;}},clientHeight:{get(){return parseFloat(this.style.height);}}});
 const range={selectNodeContents(n){this.node=n;this.all=true;},setStart(t,i){this.node=node;this.start=i;this.all=false;},setEnd(t,i){this.end=i;},getClientRects(){const sh=shape(this.node);return this.all?sh.lines:[sh.rect(this.start)];},getBoundingClientRect(){const rs=this.getClientRects(),l=Math.min(...rs.map(r=>r.left)),t=Math.min(...rs.map(r=>r.top)),r=Math.max(...rs.map(r=>r.right)),b=Math.max(...rs.map(r=>r.bottom));return {left:l,top:t,right:r,bottom:b,width:r-l,height:b-t};}};
 let mfont=6,pixelsSpent=0;
 const measure={set font(v){mfont=parseFloat(v.split(' ')[1]);},measureText(t){return {width:Array.from(t).length*mfont*.5,fontBoundingBoxAscent:mfont*.8,fontBoundingBoxDescent:mfont*.2,actualBoundingBoxAscent:mfont*.8,actualBoundingBoxDescent:mfont*.2};}};
 const document={createRange:()=>range,createElement:()=>({getContext:()=>measure})},getComputedStyle=n=>n.style;
 const sourcePixelReader={read(ctx,x,y,w,h){pixelsSpent+=w*h;if(f.noRead)return null;return Uint8Array.from({length:w*h*4},(_,i)=>i%4===3?255:f.paper??245);}};
 const aidokuReadableMinimum=8.5,aidokuReadableFontSize=9,aidokuCondensedWidth=.9,aidokuCondensedWordBound=(longest,avail)=>longest>avail&&longest*.9<=avail;
 ${body}
 const accepted=!!node.dataset.readableLift,out={name:f.name,accepted,pixels:(f.pixels??786432)-pixelsSpent,layouts:Number(root.dataset.rotatedLiftLayouts||0),lifted:Number(root.dataset.rotatedLifts||0)};
 if(accepted){const s=node.style,k=/scaleX[(]([^)]*)/.exec(s.transform);out.candidate=['left','top','width','height','fontSize','lineHeight'].map(k=>parseFloat(s[k])).concat([k?Number(k[1]):1,Math.max(1,parseFloat(s.fontSize)*.1)]);out.metadata=Object.fromEntries(['readableLift','readablePeer','readableLiftBox','bodyCondensed'].filter(k=>node.dataset[k]!==undefined).map(k=>[k,node.dataset[k]]));out.clip=(s.clipPath.match(/[-0-9.e+]+px [-0-9.e+]+px/g)||[]).map(t=>t.match(/[-0-9.e+]+/g).map(Number));}
 return out;
};`,context);
process.stdout.write(JSON.stringify(fixtures.map(f=>context.run(f))));
'''
def fixtures():
 fs=[]
 def add(name,**kw):fs.append({'name':name,**kw})
 add('inside original opaque plate')
 add('source pixel budget exhausted',rect=[100,100,42,12],text='HELLO WORDS HELLO',pixels=0)
 add('600 counter is not admission cap',layouts=600)
 add('owned crop exact remaining budget',rect=[100,100,42,12],text='HELLO WORDS HELLO',pixels=2800)
 add('failed source read still spends admitted crop',rect=[100,100,42,12],text='HELLO WORDS HELLO',noRead=True)
 add('UTF16 maximum excludes surrogate pairs',text='🙂'*91)
 add('grow tall over white paper',rect=[100,100,42,12],text='HELLO WORDS HELLO')
 add('condensed word bound',rect=[100,100,48,60],text='LONGWORDLONG')
 add('grown art rejects',rect=[100,100,24,14],text='HELLO WORDS HELLO WORDS',paper=80)
 add('paper maximum rejects',rect=[100,100,24,14],text='HELLO WORDS HELLO WORDS',paper=220)
 add('paper mean rejects',rect=[100,100,24,14],text='HELLO WORDS HELLO WORDS',paper=236)
 add('existing overlapping peer refuses growth',rect=[100,100,42,12],text='HELLO WORDS HELLO',peer=[120,110,30,20])
 add('image edge refuses wide',rect=[0,0,24,14],text='HELLO WORDS HELLO WORDS')
 for k,v in [('font',8.5),('font',4),('korean',False),('upright',True),('opaque',False),('bgImage',True),('renderedText','CHANGED'),('opacity',.8),('count',257),('text','A'*181),('text','A\nB')]:add('gate '+k+str(v),**{k:v})
 rng=random.Random(11351)
 for i in range(100):add('matrix '+str(i),font=rng.choice([4.5,5,6,7,8,8.25]),rect=[100,100,rng.choice([18,25,40,60,100]),rng.choice([8,16,35,60])],text=rng.choice(['HELLO WORDS','LONGWORDLONG','HELLO WORDS HELLO WORDS','가나다라 마바사']),angle=rng.choice([.15,.45,.7]),scale=rng.choice([1,.9]),paper=rng.choice([245,245,240,230,80]))
 return fs

def main():
 OUT.mkdir(parents=True,exist_ok=True);fs=fixtures();(OUT/'fixtures.json').write_text(json.dumps(fs))
 trial=(SRC/'NativeSlantedTypographyTrial.swift').read_text();needed='import Foundation\nenum NativeSlantedTypographyTrial {static func whitespace(_ c:Unicode.Scalar)->Bool {CharacterSet.whitespacesAndNewlines.contains(c)}\nstatic func condensedWordBound(_ l:Double,_ a:Double)->Bool {l>a && l*0.9<=a}\n}\n';(OUT/'TrialQueries.swift').write_text(needed)
 subprocess.run(['swiftc','-swift-version','6','-O',str(SRC/'NativeRotatedReadability.swift'),str(SRC/'NativeSlantedGeometry.swift'),str(OUT/'TrialQueries.swift'),str(HERE/'RotatedReadabilityParityMain.swift'),'-o',str(OUT/'native')],check=True)
 subprocess.run([str(OUT/'native'),str(OUT/'fixtures.json'),str(OUT/'native.json')],check=True)
 js=subprocess.run(['node','-e',NODE,str(HERE/'reference-source')],input=json.dumps(fs),text=True,capture_output=True)
 if js.returncode:print(js.stderr);raise SystemExit(js.returncode)
 (OUT/'web.json').write_text(js.stdout)
 native=json.loads((OUT/'native.json').read_text());web=json.loads(js.stdout)
 def eq(a,b):
  if isinstance(a,(int,float)) and isinstance(b,(int,float)):return abs(a-b)<1e-7
  if isinstance(a,list) and isinstance(b,list):return len(a)==len(b) and all(eq(x,y) for x,y in zip(a,b))
  if isinstance(a,dict) and isinstance(b,dict):return a.keys()==b.keys() and all(eq(a[k],b[k]) for k in a)
  return a==b
 failures=[]
 for a,b in zip(native,web):
  a.pop('ink',None)
  if not eq(a,b):failures.append({'name':a['name'],'native':a,'web':b})
 report={'cases':len(fs),'passed':len(fs)-len(failures),'active':sum(x['accepted'] for x in native),'failures':failures,'scope':'Actual entire frozen final opaque rotated readability pass with shared deterministic Range/Canvas measure and straight source-pixel queries. Excludes real font adapter.'}
 (OUT/'report.json').write_text(json.dumps(report,indent=2));print(f"{report['passed']}/{len(fs)} exact, {report['active']} lifted")
 if failures:print(json.dumps(failures[:2],indent=2));raise SystemExit(1)
if __name__=='__main__':main()
