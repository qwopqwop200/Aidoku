const fs=require('fs'),path=require('path');
const root=process.argv[2],output=process.argv[3],reference=path.join(root,'Scripts/native-render-parity/reference-source');
function extract(file,name){const text=fs.readFileSync(path.join(reference,file+'.swift'),'utf8');const start=text.indexOf('const '+name+' =');if(start<0)throw Error(name);const begin=text.indexOf('{',start);let depth=0,end=begin;for(;end<text.length;end++){if(text[end]==='{')depth++;if(text[end]==='}'&&--depth===0)break;}return text.slice(start,end+2);}
const names=['aidokuHasResidualLettering','aidokuHasAttachedLeadingInk','aidokuRestoredErasureCovers'];
const defs=names.map(n=>extract('BrowserOverlayTypography',n)).concat(['aidokuMainbodyCellsClear','aidokuFillEnclosedSpecks','aidokuHiddenForeignRepaint'].map(n=>extract('BrowserOverlayView',n))).join('\n');
const api=new Function(defs+';return {residual:aidokuHasResidualLettering,attached:aidokuHasAttachedLeadingInk,covers:aidokuRestoredErasureCovers,cells:aidokuMainbodyCellsClear,specks:aidokuFillEnclosedSpecks,foreign:aidokuHiddenForeignRepaint};')();
const rows=[];
function gate(name,w,h,safe,regions,glyph=8,core=regions){for(const op of ['residual','attached','covers','cells'])rows.push({name:name+'-'+op,op,w,h,safe,regions,glyph,core});}
const w=40,h=32,n=w*h,all=()=>Array(n).fill(1),region=[[10,8,16,12]];
gate('all-clear',w,h,all(),region);
let m=all();m[12*w+16]=0;gate('singleton-speck',w,h,m,region);
m=all();m[12*w+16]=0;m[13*w+17]=0;gate('diagonal-letter',w,h,m,region);
m=all();for(let x=0;x<w;x++)m[2*w+x]=0;gate('continuous-rule',w,h,m,region);
m=all();m[1*w+1]=0;m[2*w+2]=0;gate('distant-letter',w,h,m,[[26,20,5,5]],3);
gate('truthy-two-strict-cell',w,h,Array(n).fill(2),region);
gate('fractional-core',w,h,all(),[[8.2,7.7,10.1,12.2]],8);
gate('outside-regions',w,h,all(),[[-1,5,12,10]],8);
gate('budget-duplicates',w,h,all(),Array.from({length:3},()=>[0,0,w,h]),8);
gate('empty-regions',w,h,all(),[],8);
gate('invalid-dimension',0,h,[],region);
gate('invalid-buffer',w,h,[1],region);
gate('zero-glyph',w,h,all(),region,0);
gate('invalid-rect',w,h,all(),[[10,12,3]],8);
let seed=971031;function rng(){seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed/4294967296;}
for(let f=0;f<16;f++){m=all();for(let q=0;q<30;q++){let x=2+Math.floor(rng()*36),y=2+Math.floor(rng()*28);m[y*w+x]=0;if(f%3===0)m[y*w+x+1]=0;}gate('random-'+f,w,h,m,[[5+f%7,6,18,16]],4+f%8);}
let aw=96,ah=80,am=Array(aw*ah).fill(1);for(let y=0;y<ah;y++)am[y*aw+89]=0;
for(let y of [...Array.from({length:5},(_,i)=>20+i),...Array.from({length:5},(_,i)=>35+i)])for(let x=65;x<90;x++)am[y*aw+x]=0;
rows.push({name:'attached-repeated-protrusions',op:'attached',w:aw,h:ah,safe:am,core:[[35,5,25,65]],regions:[],glyph:20});
function speck(name,holes,mutate=()=>{},extra={}){const ww=18,hh=16,nn=ww*hh,safe=Array(nn).fill(1),rgba=Array.from({length:nn},()=>[200,211,222,255]).flat(),lum=Array(nn).fill(100);for(const [x,y] of holes){safe[y*ww+x]=0;rgba.splice((y*ww+x)*4,4,10,30,50,70);}let f={name,op:'specks',w:ww,h:hh,safe,rgba,luminance:lum,revision:7,coreClear:true,innerCoreClear:false,residualLettering:true,...extra};mutate(f);rows.push(f);}
speck('one-enclosed',[[7,6]]);speck('four-connected',[[7,6],[8,6],[7,7],[8,7]]);speck('two-components',[[4,4],[12,11]]);speck('five-tail-rejected',[[5,6],[6,6],[7,6],[8,6],[9,6]]);speck('edge-open-rejected',[[0,6],[1,6]]);speck('alpha-ring-rejected',[[7,6]],f=>f.rgba[(5*18+6)*4+3]=200);speck('nonflat-ring-rejected',[[7,6]],f=>f.rgba[(5*18+6)*4]=20);speck('half-up-mean',[[7,6]],f=>{let k=0;for(let y=5;y<=7;y++)for(let x=6;x<=8;x++)if(x!==7||y!==6)f.rgba[(y*18+x)*4]=200+(k++%2);});speck('truthy-safe-two',[[7,6]],f=>f.safe=f.safe.map(v=>v?2:0));speck('diagonal-edge-connection',[[0,0],[1,1],[2,2],[3,3]]);speck('no-holes',[]);speck('short-luminance-buffer',[[7,6]],f=>f.luminance=[100]);speck('empty-luminance-buffer',[[7,6]],f=>f.luminance=[]);
function foreign(name,{bounds=[.3,.3,.2,.2],aux=[],font=8,detached=false,alpha=255,plate=[10,8,25,22],frame=[0,0,40,32],crop=[0,0],scale=[1,1]}={}){rows.push({name,op:'foreign',w,h,rgba:Array.from({length:n},(_,i)=>[10,20,30,i%7===0?0:alpha]).flat(),imageSize:[40,32],frame,crop,scale,sourceFontSize:font,sourceBounds:bounds,auxiliaryInkRects:aux,plate,detached});}
foreign('foreign-card-positive');foreign('foreign-detached-positive',{detached:true});foreign('foreign-owned-all',{bounds:[0,0,1,1],detached:true});foreign('foreign-zero-alpha',{alpha:0,detached:true});foreign('foreign-auxiliary',{aux:[[0,0,.3,1],[.5,0,.5,1]],detached:true});foreign('foreign-fractional-scaled',{frame:[3.2,4.7,80,64],crop:[2.5,3.1],scale:[.8,.9],plate:[10.1,8.3,25.6,22.4],font:11.5});foreign('foreign-zero-font-fallback',{font:0});foreign('foreign-negative-font',{font:-8});foreign('foreign-small-below-threshold',{plate:[0,0,1,1]});foreign('foreign-outside-card',{plate:[-30,-40,8,8]});foreign('foreign-malformed-bounds',{bounds:[1,2,3],aux:[[.1,.2,.3,.4],[1,2]]});
const opaqueForeign=structuredClone(rows.find(f=>f.name==='foreign-detached-positive'));opaqueForeign.name='foreign-detached-all-opaque';for(let i=3;i<opaqueForeign.rgba.length;i+=4)opaqueForeign.rgba[i]=255;rows.push(opaqueForeign);
function snapshot(c,image){return {rgba:Array.from(image.data),safe:Array.from(c.safe),luminance:Array.from(c.luminance),revision:c.surfaceRevision??0,enclosedSpecks:c.enclosedSpecks??null,coreClear:c.coreClear??null,innerCoreClear:c.innerCoreClear??null,residualLettering:c.residualLettering??null};}
for(const f of rows){if(f.op==='specks'){let puts=0,image={data:new Uint8ClampedArray(f.rgba)},c={w:f.w,h:f.h,safe:new Uint8Array(f.safe),luminance:new Uint8Array(f.luminance),surfaceRevision:f.revision,coreClear:f.coreClear,innerCoreClear:f.innerCoreClear,residualLettering:f.residualLettering,canvas:{width:f.w,height:f.h,getContext:()=>({putImageData:()=>puts++})}};const undo=api.specks(c,image),filled=snapshot(c,image);if(undo)undo();f.expected={accepted:!!undo,filled,undone:snapshot(c,image),puts};}else if(f.op==='foreign'){f.expected=api.foreign({w:f.w,h:f.h,iw:f.imageSize[0],ih:f.imageSize[1],frame:f.frame,x:f.crop[0],y:f.crop[1],sx:f.scale[0],sy:f.scale[1]},{sourceBounds:f.sourceBounds,auxiliaryInkRects:f.auxiliaryInkRects,sourceFontSize:f.sourceFontSize},{getBoundingClientRect:()=>({left:f.plate[0],top:f.plate[1],width:f.plate[2],height:f.plate[3]})},f.detached,new Uint8ClampedArray(f.rgba));}else{f.expected=f.op==='attached'?api.attached(f.safe,f.w,f.h,f.core,f.glyph):f.op==='covers'?api.covers(f.safe,f.w,f.h,f.regions,f.glyph,f.core):f.op==='cells'?api.cells(f.safe,f.w,f.h,f.regions):api.residual(f.safe,f.w,f.h,f.regions,f.glyph);}}
fs.writeFileSync(output,JSON.stringify(rows));console.log(rows.length+' frozen fixtures');
