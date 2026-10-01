const fs=require('fs'),path=require('path'),crypto=require('crypto');
const root=process.argv[2],out=process.argv[3];
const source=fs.readFileSync(path.join(root,'Scripts/native-render-parity/reference-source/BrowserOverlayView.swift'),'utf8');
const start=source.indexOf('    const frameSource=typeof sourceImage'),end=source.indexOf('    // Readability floor for rotated plates.',start);
if(start<0||end<start)throw Error('frozen frame pass missing');
const frozen=source.slice(start,end),block=frozen.replace('budget-=w*h;','budget-=w*h;root.dataset.remaining=budget;');
const run=new Function('c',`
const opacity=c.opacity??1,items=c.panels.map((p,i)=>({id:String(i),sourceBounds:p.bounds})),cleanupImageGeometry={frame:c.frame};
const sourceImage={complete:true,naturalWidth:c.image[0],naturalHeight:c.image[1]};
const box=a=>({left:a[0],top:a[1],width:a[2],height:a[3],right:a[0]+a[2],bottom:a[1]+a[3]});
const panels=c.panels.map((p,i)=>({dataset:{aidokuRegion:String(i)},style:{transform:p.rotated?'rotate(.1rad)':'none',backgroundImage:'none',visibility:p.hidden?'hidden':'visible'},getBoundingClientRect:()=>box(p.rect)}));
const nodes=c.text.map(a=>({style:{},rect:box(a)}));
const root={dataset:{remaining:3000000},querySelectorAll:s=>s.includes('source-readability-panel')?panels:nodes};
const getComputedStyle=n=>n.style;let samples=[],painted=[],number=0;
const document={createRange:()=>({selectNodeContents(n){this.n=n;},getClientRects(){return [this.n.rect];}}),createElement:()=>{
 const index=number++,canvas={width:0,height:0};let bytes=null;
 canvas.toDataURL=()=>{painted.push({width:canvas.width,height:canvas.height,rgba:Array.from(bytes)});return 'fixture';};
 canvas.getContext=()=>({drawImage:(image,x,y,sw,sh,dx,dy,w,h)=>{
  bytes=new Uint8ClampedArray(w*h*4);
  for(let yy=0;yy<h;yy++)for(let xx=0;xx<w;xx++){
   const px=x+(xx+.5)*sw/w,py=y+(yy+.5)*sh/h;let rgb=c.surface;
   for(const r of c.rules){if(px>=r[0]&&py>=r[1]&&px<r[0]+r[2]&&py<r[1]+r[3])rgb=r.slice(4,7);}
   const at=(yy*w+xx)*4;bytes[at]=rgb[0];bytes[at+1]=rgb[1];bytes[at+2]=rgb[2];bytes[at+3]=c.alpha??255;
  }
  samples.push({source:[x,y,sw,sh],width:w,height:h,rgba:Array.from(bytes)});
 },getImageData:()=>({data:bytes}),createImageData:(w,h)=>({data:new Uint8ClampedArray(w*h*4)}),putImageData:v=>{bytes=v.data;}});
 return canvas;
}};
${block}
return {remaining:root.dataset.remaining,restored:Number(root.dataset.frameLinePlates||0),counts:panels.map(p=>Number(p.dataset.sourceFrameLines||0)),samples,painted};
`);
const base={image:[100,80],frame:[0,0,100,80],panels:[{rect:[25,20,40,35],bounds:[.3,.3,.3,.3]}],text:[],surface:[245,245,245],rules:[[0,31,100,1,20,20,20]]};
const fixtures=[];function add(p={}){const input={...structuredClone(base),...p};fixtures.push({input,expected:run(input)});}
for(const thick of [1,2,4,5,8,10])for(const vertical of [false,true])for(const color of [20,109,110,170])add({rules:[vertical?[44,0,thick,80,color,color,color]:[0,31,100,thick,color,color,color]]});
for(const text of [[[35,29,12,6]],[[0,0,100,80]],[[200,200,10,10]],[[-100,-100,1,1]],[[30,20,3,3],[30,40,4,10]]])add({text});
for(const image of [[200,160],[250,200],[300,240],[350,280],[75,60]])add({image,rules:[[0,image[1]*.4,image[0],2,20,40,15]]});
for(const rules of [[[28,31,60,1,10,10,10]],[[0,31,40,1,10,10,10]],[[0,31,100,1,180,180,180],[0,32,100,1,20,20,20]],[[0,31,100,2,20,20,20],[44,0,2,80,30,30,30]]])add({rules});
for(const surface of [[150,150,150],[151,151,151],[0,0,0]])add({surface});
for(const alpha of [0,128,255])add({alpha});
for(const rect of [[25.3,20.8,40.2,35.6],[0,20,40,35],[25,20,3.9,35],[25,20,40,3.9],[90,70,40,35]])add({panels:[{rect,bounds:[.3,.3,.3,.3]}]});
for(const flag of ['hidden','rotated'])add({panels:[{...base.panels[0],[flag]:true}]});
add({opacity:.5});add({panels:[...base.panels,...base.panels]});
fs.writeFileSync(out,JSON.stringify(fixtures));console.log(JSON.stringify({cases:fixtures.length,positive:fixtures.filter(f=>f.expected.restored>0).length,frozenSHA256:crypto.createHash('sha256').update(frozen).digest('hex')}));
