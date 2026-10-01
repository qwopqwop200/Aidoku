const fs=require('fs'),vm=require('vm');
const ref=process.argv[2],source=fs.readFileSync(ref+'/BrowserOverlayView.swift','utf8').replace(/\\\\/g,'\\');
const typo=fs.readFileSync(ref+'/BrowserOverlayTypography.swift','utf8').replace(/\\\\/g,'\\');
function block(s,name){const start=s.indexOf('const '+name+'=')>=0?s.indexOf('const '+name+'='):s.indexOf('const '+name+' =');if(start<0)throw new Error(name);const open=s.indexOf('{',start),semi=s.indexOf(';',start);if(semi<open)return s.slice(start,semi+1);let depth=0;for(let i=open;i<s.length;i++){if(s[i]==='{')depth++;else if(s[i]==='}'&&! --depth)return s.slice(start,i+2);}throw new Error(name);}
const grow=source.slice(source.indexOf('        const widenDisplayCard='),source.indexOf('        (()=>{for(const node of nodes){',source.indexOf('        const growPlateWide=')));
const helpers=block(typo,'aidokuGrowthKeepsLineLength')+'\n'+source.slice(source.indexOf('const displaySizes=(from,to)=>'),source.indexOf('// Other captions',source.indexOf('const displaySizes=(from,to)=>')));
const bbox=a=>({left:a[0],top:a[1],right:a[0]+a[2],bottom:a[1]+a[3],width:a[2],height:a[3]});
const arr=r=>[r.left,r.top,r.width,r.height],meet=(a,b)=>a.left<b.right&&a.right>b.left&&a.top<b.bottom&&a.bottom>b.top;
function style(v){const o={scale:'',visibility:'visible',display:'block',fontWeight:'700',fontFamily:'Fixture',...v};Object.defineProperty(o,'cssText',{get(){return JSON.stringify(Object.fromEntries(Object.entries(o)))},set(s){for(const k of Object.keys(o))delete o[k];Object.assign(o,JSON.parse(s))},enumerable:false});return o;}

function run(f){
 const factor=f.factor??.5,font=f.font??10,text=f.text??'GO NOW',glyph=f.glyph??70,ratio=f.ratio??1.2,reads=[];
 const plate={dataset:{aidokuImageOcrOverlay:'source-readability-panel',aidokuRegion:'own'},style:style({backgroundColor:'rgb('+(f.color??[255,255,255]).join(',')+')'}),getBoundingClientRect(){return bbox(f.plate)}};
 const root={dataset:{},querySelectorAll(){return [plate]}};plate.parentElement=root;
 const node={dataset:{aidokuRegion:'own',...(f.flatRoom?{plateFlatRoom:'true'}:{})},style:style({left:f.plate[0]+'px',top:f.plate[1]+'px',width:f.plate[2]+'px',height:f.plate[3]+'px',fontSize:font+'px',lineHeight:font*ratio+'px',visibility:f.visible===false?'hidden':'visible'}),parentElement:root,textContent:text,childNodes:[],replaceChildren(){},getBoundingClientRect(){return box(this.style)}};
 function box(s){return bbox([parseFloat(s.left)||0,parseFloat(s.top)||0,parseFloat(s.width)||0,parseFloat(s.height)||0])}
 function physical(){const s=node.style,size=parseFloat(s.fontSize),pitch=parseFloat(s.lineHeight),pad=parseFloat(s.padding)||0,q=box(s);let widths=[],run=-1;
  for(const word of text.split(/\s+/u).filter(Boolean)){const next=word.length*size*factor;if(run>=0&&run+size*factor+next<=q.width-2*pad)run+=size*factor+next;else{if(run>=0)widths.push(run);run=next}}
  if(run>=0)widths.push(run);const h=widths.length*pitch,w=Math.max(...widths),ink=bbox([q.left+q.width/2-w/2,q.top+q.height/2-h/2,w,h]);
  return {ink,scrollWidth:Math.max(q.width,w+2*pad),clientWidth:q.width,scrollHeight:Math.max(q.height,h+2*pad),clientHeight:q.height};
 }
 for(const key of ['scrollWidth','clientWidth','scrollHeight','clientHeight'])Object.defineProperty(node,key,{get(){return physical()[key]}});
 const state={css:node.style.cssText,children:[],font};
 const F=f.frame??[0,0,390,700],S=f.source??[f.plate[0],f.plate[1],f.plate[2],f.plate[3]],item={id:'own',text,rotation:f.rotated?1:0,vertical:f.vertical??false,sourceVertical:f.sourceVertical??true,allowsAutomaticFontRecovery:f.recovery??true,wrappingScript:f.script??'korean',sourceBounds:[(S[0]-F[0])/F[2],(S[1]-F[1])/F[3],S[2]/F[2],S[3]/F[3]]};
 if(f.visiblePlate)plate.dataset.panelCoverage=JSON.stringify([f.visiblePlate]);
 const fakeContext={drawImage(img,x,y,rw,rh,a,b,w,h){reads.push([x,y,rw,rh,w,h])},getImageData(x,y,w,h){let a=new Uint8ClampedArray(w*h*4);for(let i=0;i<w*h;i++){const c=f.texture&&i%97===0?0:255;a.set([c,c,c,255],i*4)}return {data:a}}};
 const canvas={getContext(){return fakeContext}},measure={font:'',measureText(t){const size=parseFloat(this.font.match(/([-\d.]+)px/)[1]);return {width:t.length*size*factor}}};
 const others=(f.others??[]).map(r=>({fixed:bbox(r),dataset:{},style:{visibility:'visible'}}));
 const sources=(f.sources??[]).map(r=>({id:'other',sourceBounds:[(r[0]-F[0])/F[2],(r[1]-F[1])/F[3],r[2]/F[2],r[3]/F[3]]}));
 const ctx={root,node,plate,items:[item,...sources],nodes:[node,...others],plateStates:new Map([[node,state]]),itemFor:()=>item,sourceGlyph:()=>glyph,measure,inkOf:n=>n===node?physical().ink:n.fixed,
 growPlate(){if(f.grown){node.style.fontSize=f.grown+'px';node.style.lineHeight=f.grown*ratio+'px'}return f.grown??null},getComputedStyle:x=>x.style,displayMaximum:128,pageGlyph:f.pageGlyph??20,
 sourceImage:{complete:true,naturalWidth:f.iw??390,naturalHeight:f.ih??700},cleanupImageGeometry:{frame:F},foreignCards:()=>(f.cards??[]).map(bbox),badLineStart:()=>f.badStart??false,
 document:{createElement(){return canvas}},widenCanvas:null,widenSamples:f.budget??393216,cap:f.cap??Infinity,strict:f.strict??false};
 vm.createContext(ctx);vm.runInContext(helpers+'\n'+grow+'\nresult=growPlateWide(node,cap,strict);',ctx);
 const out={name:f.name,size:node.dataset.displayCardGrowth?ctx.result:null,budget:ctx.widenSamples,reads};
 if(node.dataset.displayCardGrowth){out.box=arr(box(node.style));out.ink=arr(physical().ink)}return out;
}
const jobs=JSON.parse(fs.readFileSync(process.argv[3],'utf8'));fs.writeFileSync(process.argv[4],JSON.stringify(jobs.map(run)));
