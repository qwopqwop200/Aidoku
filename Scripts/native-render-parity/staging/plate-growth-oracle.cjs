const fs=require('fs'),vm=require('vm');
const ref=process.argv[2],source=fs.readFileSync(ref+'/BrowserOverlayView.swift','utf8').replace(/\\\\/g,'\\');
const typo=fs.readFileSync(ref+'/BrowserOverlayTypography.swift','utf8').replace(/\\\\/g,'\\');
function block(s,name){const start=s.indexOf('const '+name+'=')>=0?s.indexOf('const '+name+'='):s.indexOf('const '+name+' =');if(start<0)throw new Error(name);const open=s.indexOf('{',start),semi=s.indexOf(';',start);if(semi<open)return s.slice(start,semi+1);let depth=0;for(let i=open;i<s.length;i++){if(s[i]==='{')depth++;else if(s[i]==='}'&&! --depth)return s.slice(start,i+2);}throw new Error(name);}
const grow=source.slice(source.indexOf('        const growPlate='),source.indexOf('        const growers=[];'));
const schedule=grow.slice(grow.indexOf('          const floored='),grow.indexOf('          // A clipped plate')).replace('if(!(Math.max(target,display)>=font*1.1)&&!liftSizes.length)return null;','');
const helpers=['aidokuGrowthKeepsLineLength','aidokuCondensedWordBound','aidokuCondensedSizes','aidokuBelowReadableSource'].map(n=>block(typo,n)).join('\n')+'\n'+source.slice(source.indexOf('const displaySizes=(from,to)=>'),source.indexOf('// Other captions',source.indexOf('const displaySizes=(from,to)=>')));
const bbox=a=>({left:a[0],top:a[1],right:a[0]+a[2],bottom:a[1]+a[3],width:a[2],height:a[3]});
const arr=r=>[r.left,r.top,r.width,r.height],meet=(a,b)=>a.left<b.right&&a.right>b.left&&a.top<b.bottom&&a.bottom>b.top;
function style(v){const o={scale:'',visibility:'visible',display:'block',fontWeight:'700',fontFamily:'Fixture',...v};Object.defineProperty(o,'cssText',{get(){return JSON.stringify(Object.fromEntries(Object.entries(o)))},set(s){for(const k of Object.keys(o))delete o[k];Object.assign(o,JSON.parse(s))},enumerable:false});return o;}
function run(f){
 const factor=f.factor??.5,font=f.font??12,text=f.text??'ABC',glyph=f.glyph??20,original=f.originalFont??font;
 const plate={dataset:{aidokuImageOcrOverlay:'source-readability-panel',aidokuRegion:'own'},style:style({left:f.plate[0]+'px',top:f.plate[1]+'px',width:f.plate[2]+'px',height:f.plate[3]+'px'}),getBoundingClientRect(){return box(this.style)}};
 if(f.coverage!==undefined)plate.dataset.panelCoverage=JSON.stringify(f.coverage);
 const root={dataset:{},querySelectorAll(){return [plate,...foreignPlates]}};plate.parentElement=root;
 const node={dataset:{aidokuRegion:'own'},style:style({left:f.plate[0]+'px',top:f.plate[1]+'px',width:f.plate[2]+'px',height:f.plate[3]+'px',fontSize:font+'px',lineHeight:font*(f.ratio??1.2)+'px',visibility:f.visible===false?'hidden':'visible',scale:f.committedAllowed===false?'1 1':''}),parentElement:root,textContent:text,childNodes:[],replaceChildren(){},getBoundingClientRect(){return box(this.style)}};
 const others=(f.others??[]).map(r=>({fixed:bbox(r),dataset:{},style:{visibility:'visible'},getBoundingClientRect(){return this.fixed}}));
 const foreignPlates=(f.foreignPlates??[]).map(r=>({dataset:{},style:{display:'block'},getBoundingClientRect(){return bbox(r)}}));
 function box(s){return bbox([parseFloat(s.left)||0,parseFloat(s.top)||0,parseFloat(s.width)||0,parseFloat(s.height)||0]);}
 function physical(){const s=node.style,size=parseFloat(s.fontSize),pitch=parseFloat(s.lineHeight),p=parseFloat(s.padding)||0,scale=parseFloat(s.scale)||1,box0=box(s),available=box0.width-2*p/(scale<1?scale:1);let widths=[],run=-1;
  for(const w of text.split(/\s+/u).filter(Boolean)){const next=w.length*size*factor;if(run>=0&&run+size*factor+next<=available)run+=size*factor+next;else{if(run>=0)widths.push(run);run=next;}}if(run>=0)widths.push(run);
  const h=widths.length*pitch,top=box0.top+box0.height/2-h/2,cx=box0.left+box0.width/2;
  const lines=widths.map((w,i)=>bbox([cx-w*scale/2,top+i*pitch,w*scale,pitch]));
  const left=Math.min(...lines.map(r=>r.left)),right=Math.max(...lines.map(r=>r.right));
  return {ink:{left,top,right,bottom:top+h,width:right-left,height:h},lines,scrollWidth:Math.max(box0.width,Math.max(...widths)+2*p/(scale<1?scale:1)),clientWidth:box0.width,scrollHeight:Math.max(box0.height,h+2*p),clientHeight:box0.height};
 }
 for(const key of ['scrollWidth','clientWidth','scrollHeight','clientHeight'])Object.defineProperty(node,key,{get(){return physical()[key]}});
 let selected;const document={createRange(){return {selectNodeContents(n){selected=n},getClientRects(){return physical().lines}}}};
 const item={rotation:f.rotated?1:0,vertical:f.vertical??false,wrappingScript:f.script??'korean',allowsAutomaticFontRecovery:f.recovery??true,text};
 const measure={font:'',measureText(t){const size=parseFloat(this.font.match(/([-\d.]+)px/)[1]);return {width:t.length*size*factor}}};
 const state={css:node.style.cssText,children:[],font:original,plateCss:plate.style.cssText,plateCoverage:plate.dataset.panelCoverage};
 const plateStates=new Map([[node,state]]);let roomReads=0;
 const room=f.room&&bbox(f.room);
 const ctx={root,node,plate,nodes:[node,...others],plateStates,itemFor:()=>item,sourceGlyph:()=>glyph,measure,
 inkOf:n=>n===node?(parseFloat(node.style.fontSize)===font&&!node.style.padding?bbox(f.ink):physical().ink):n.fixed,
 growRotatedPlate:()=>null,document,getComputedStyle:x=>x.style,displayMaximum:128,aidokuCondensedWidth:.9,aidokuReadableFontSize:9,
 flatPlateRoom:()=>{roomReads++;return room?{...room,free:(l,t,r,b)=>l>=room.left&&t>=room.top&&r<=room.right&&b<=room.bottom&&!(f.blocked??[]).some(a=>meet({left:l,top:t,right:r,bottom:b},bbox(a))) }:null},
 cleanupImageGeometry:f.frame?{frame:f.frame}:null,foreignCards:()=> (f.cards??[]).map(bbox),touching:(r,cards)=>cards.reduce((sum,c)=>sum+Math.max(0,Math.min(r.right,c.right)-Math.max(r.left,c.left))*Math.max(0,Math.min(r.bottom,c.bottom)-Math.max(r.top,c.top)),0),
 badLineStart:()=>f.badStart??false,loneSyllableLines:()=>f.lone??0,notePlateRoom:()=>{},performance:{now:()=>0},CSS:{supports:()=>true},cap:f.cap??Infinity,strict:f.strict??false,styleGlyph:f.styleGlyph??0,condensedOnly:f.condensed??false,plateRoomLayouts:f.roomLayouts??0,plateLiftLayouts:f.liftLayouts??0};
 if(f.plateVisible===false)plate.style.display='none';
 vm.createContext(ctx);vm.runInContext(helpers+'\n'+grow+'\nresult=growPlate(node,cap,strict,styleGlyph,condensedOnly);',ctx);
 const out={name:f.name,schedule:null,size:ctx.result,roomLayouts:ctx.plateRoomLayouts,liftLayouts:ctx.plateLiftLayouts,roomReads};
 const sc={...ctx,item,font,glyph,committed:f.condensed??false,state:{...state,font:original},foreignPlates};vm.createContext(sc);vm.runInContext(helpers+'\n'+schedule+'\nresult={target,display,earlier,lifts:liftSizes,sizes};',sc);out.schedule=sc.result;
 if(ctx.result){const pb=box(node.style);out.box=arr(pb);out.ink=arr(physical().ink);out.plate=arr(plate.getBoundingClientRect());out.coverage=plate.dataset.panelCoverage?JSON.parse(plate.dataset.panelCoverage):[];out.flatRoom=node.dataset.plateFlatRoom?JSON.parse(node.dataset.plateFlatRoom):[];out.scale=parseFloat(node.style.scale)||1;}
 return out;
}
const jobs=JSON.parse(fs.readFileSync(process.argv[3],'utf8'));fs.writeFileSync(process.argv[4],JSON.stringify(jobs.map(run)));
