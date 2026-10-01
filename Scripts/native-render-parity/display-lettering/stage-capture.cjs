const fs=require('fs'),path=require('path'),[root,out]=process.argv.slice(2);
const s=fs.readFileSync(path.join(root,'Scripts/native-render-parity/reference-source/BrowserOverlayView.swift'),'utf8');
const rect=r=>({left:r[0],top:r[1],right:r[0]+r[2],bottom:r[1]+r[3],width:r[2],height:r[3]});
const a=s.indexOf('        const crowded=',s.indexOf('      const nodesD=')),b=s.indexOf('        if(crowded||hidesOther)',a);
const ownership=new Function('v','rect',`const b=v.bounds,f=v.frame,item={id:'own',sourceBounds:b},items=[item,...v.others.map((o,i)=>({id:String(i),sourceBounds:o.bounds}))],plate={getBoundingClientRect:()=>rect(v.plate)};const nodesD=v.others.map((o,i)=>({dataset:{aidokuRegion:String(i),sourceBackgroundColor:o.mode}}));const root={querySelectorAll:()=>v.others.flatMap((o,i)=>o.plates.map(p=>({dataset:{aidokuRegion:String(i)},getBoundingClientRect:()=>rect(p)})))};`+s.slice(a,b)+`return {crowded,hidesOther};`);
const c=s.indexOf('        const iw=sourceImage.naturalWidth',a),d=s.indexOf('        let result=null;',c);
const crop=new Function('v',`const sourceImage={naturalWidth:v.imageSize[0],naturalHeight:v.imageSize[1]},f=v.frame,b=v.bounds,glyph=v.glyph;let displayPixels=v.budget;`+s.slice(c,d).replace('continue;','return {crop:null,remaining:displayPixels};')+`return {crop:{x:x0,y:y0,sw,sh,width:w,height:h,scale,box:[(b[0]*iw-x0)*scale,(b[1]*ih-y0)*scale,b[2]*iw*scale,b[3]*ih*scale],glyph:glyph*cssToImage*scale,rect:[f[0]+x0/iw*f[2],f[1]+y0/ih*f[3],sw/iw*f[2],sh/ih*f[3]],borders:[x0===0,y0===0,x1===iw,y1===ih]},remaining:displayPixels};`);
const fixtures=[];
for(let seed=0;seed<80;seed++){
 const frame=seed%7===0?[100,200,400,600]:[0,0,400,600],bounds=[.12,.21,.44,.26],plate=[frame[0]+35,frame[1]+115,255,220];
 const o=seed%4===0?[.33,.3,.1,.08]:seed%4===1?[.57,.3,.1,.08]:seed%4===2?[.59,.3,.1,.08]:[.01,.01,.05,.05];
 const r=[frame[0]+o[0]*frame[2],frame[1]+o[1]*frame[3],o[2]*frame[2],o[3]*frame[3]];
 const mode=['readability-panel','inpainted','slanted-glyph-restored','rotated-panel','display-restored',null][seed%6];
 const f={seed,frame,bounds,plate,others:[{bounds:o,mode,plates:seed%5===0?[r]:[]}],imageSize:seed%3===0?[1200,1800]:[400,600],glyph:24+seed*.23,budget:seed%11===0?200:393216};
 f.expected={...ownership(f,rect),...crop(f)};fixtures.push(f);
}
fs.writeFileSync(out,JSON.stringify(fixtures));console.log(JSON.stringify({cases:fixtures.length,crops:fixtures.filter(f=>f.expected.crop).length,crowded:fixtures.filter(f=>f.expected.crowded).length,hides:fixtures.filter(f=>f.expected.hidesOther).length}));
