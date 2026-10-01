const fs=require('node:fs'),path=require('node:path');const [root,input,output]=process.argv.slice(2);
const ref=path.join(root,'Scripts/native-render-parity/reference-source');
const s=fs.readFileSync(path.join(ref,'BrowserOverlayView.swift'),'utf8');
const a=s.indexOf('(()=>{',s.indexOf('// Recovered lines (payload')),b=s.indexOf('    // Short captions need',a);
const body=s.slice(a,b);
const t=fs.readFileSync(path.join(ref,'BrowserOverlayTypography.swift'),'utf8');
const helpers=t.slice(t.indexOf('    const aidokuSubtractRects ='),t.indexOf('    // Gloss placement at kept source lettering'));
function run(j){
 let crops=[],drawPixels=0;const keptItems=[],keptZones=[];
 const items=j.items.map(it=>({...it,recoveredLine:it.recovered,sourceBounds:it.bounds,sourceFontSize:it.font}));
 const rect=r=>({left:r[0],top:r[1],right:r[0]+r[2],bottom:r[1]+r[3],width:r[2],height:r[3]});
 const nodes=new Map(),children=[];
 for(const it of items){
  if(it.hasNode!==false)nodes.set(it.id,{style:{visibility:'visible',display:'block'},dataset:{aidokuRegion:it.id,sourceAppliedBackgroundRGB:(it.fallback||[]).join(',')},remove(){this.removed=true}});
  it.plates.forEach((p,index)=>children.push({dataset:{aidokuRegion:it.id,aidokuImageOcrOverlay:'source-readability-panel'},style:{visibility:p.visible===false?'hidden':'visible',display:'block',backgroundColor:p.color?`rgb(${p.color.join(',')})`:'transparent'},getBoundingClientRect:()=>rect(p.rect),remove(){this.removed=true},index}));
 }
 const root={children,dataset:{},querySelectorAll:()=>[...nodes.values()].filter(n=>!n.removed)};
 const coverSource={complete:j.complete!==false,naturalWidth:j.iw,naturalHeight:j.ih},cleanupImageGeometry={frame:j.frame},opacity=j.opacity;
 const getComputedStyle=n=>n.style,performance={now:()=>0};
 let crop;
 const context={drawImage(_src,x,y,sw,sh,_dx,_dy,w,h){crop=[x,y,sw,sh,w,h];crops.push(crop);drawPixels+=w*h},getImageData(){
  const [x0,y0,sw,sh,w,h]=crop,rgba=new Uint8ClampedArray(w*h*4);
  for(let y=0;y<h;y++)for(let x=0;x<w;x++){
   const sx=Math.floor(x0+(x+.5)*sw/w),sy=Math.floor(y0+(y+.5)*sh/h);
   const color=j.art.findLast(r=>sx>=r[0]&&sy>=r[1]&&sx<r[0]+r[2]&&sy<r[1]+r[3])?.slice(4)||j.background;
   rgba.set(color,(y*w+x)*4);
  }return{data:rgba};}};
 const document={createElement:()=>({getContext:()=>context})};
 new Function('items','root','coverSource','cleanupImageGeometry','opacity','document','getComputedStyle','performance','keptItems','keptZones',helpers+body)(items,root,coverSource,cleanupImageGeometry,opacity,document,getComputedStyle,performance,keptItems,keptZones);
 return{dropped:[...nodes.values()].filter(n=>n.removed).map(n=>n.dataset.aidokuRegion).sort(),shares:JSON.parse(root.dataset.recoveredLines||'{}'),
  kept:keptItems.map(k=>({id:k.id,rect:[k.x,k.y,k.width,k.height],font:k.sourceFontSize})),
  zones:keptZones.map(k=>({id:k.id,rect:[k.left,k.top,k.right-k.left,k.bottom-k.top]})),budget:262144-drawPixels,crops};
}
fs.writeFileSync(output,JSON.stringify(JSON.parse(fs.readFileSync(input,'utf8')).map(run)));
