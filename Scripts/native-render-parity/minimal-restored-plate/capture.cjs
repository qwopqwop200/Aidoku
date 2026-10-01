const fs=require('node:fs'),path=require('node:path');const [root,out]=process.argv.slice(2);
const s=fs.readFileSync(path.join(root,'Scripts/native-render-parity/reference-source/BrowserOverlayView.swift'),'utf8');
let body=s.slice(s.indexOf('        const covered=(x,y)=>coverage.some'),s.indexOf('        const saved={panel:panel.style.cssText',s.indexOf('        const covered=(x,y)=>coverage.some')));
body=body.replace('catch(_){continue;}','catch(_){return null;}').replace('if(c.canvas.width!==c.w||c.canvas.height!==c.h||painted.length!==c.w*c.h*4)continue;','if(c.canvas.width!==c.w||c.canvas.height!==c.h||painted.length!==c.w*c.h*4)return null;').replace('if(!next.length)continue;','if(!next.length)return null;').replace('if(after>=before*.95&&area(next)>=area(coverage)*.95)continue;','if(after>=before*.95&&area(next)>=area(coverage)*.95)return null;');
const rect=r=>({left:r[0],top:r[1],width:r[2],height:r[3],right:r[0]+r[2],bottom:r[1]+r[3]});
const policy=new Function('f','rect',`const p=rect(f.panel),ink=rect(f.ink),node={style:{fontSize:String(f.font)},ink};const clipped=f.clipped;let coverage=(clipped?f.coverage:[f.panel]).map(rect);const item={id:'own'},items=[item,...f.sources.map((v,i)=>({id:'src'+i,sourceFrame:v.frame,sourceBounds:v.bounds[0],auxiliaryInkRects:v.bounds.slice(1),sourceVertical:v.vertical,sourceFontSize:v.sourceFont}))];const captionNodes=[node,...f.otherInk.map((r,i)=>({dataset:{aidokuRegion:"ink"+i},style:{fontSize:"10"},ink:rect(r)})),...f.sources.map((v,i)=>({dataset:{aidokuRegion:'src'+i},style:{fontSize:String(v.font||'')},ink:rect([0,0,0,0])}))];node.dataset={aidokuRegion:'own'};const inkOf=n=>n.ink;const cleanupImageGeometry=null;const c={w:f.w,h:f.h,iw:f.imageSize[0],ih:f.imageSize[1],sx:f.scale[0],sy:f.scale[1],x:f.origin[0],y:f.origin[1],frame:f.frame,safe:f.safe};c.canvas={width:c.w,height:c.h,getContext:()=>({getImageData:()=>({data:f.rgba})})};`+body+`return {rect:[B.left,B.top,B.right-B.left,B.bottom-B.top],coverage:next.map(r=>[r.left,r.top,r.right-r.left,r.bottom-r.top]),clipped:next.length>1||clipped,beforeArea:Math.round(area(coverage)),afterArea:Math.round(area(next))};`);
const fixtures=[];
for(let seed=0;seed<120;seed++){
 const w=40,h=40,safe=Array(w*h).fill(1),rgba=Array(w*h*4).fill(0);
 for(let i=0;i<w*h;i++)rgba.splice(i*4,3,240,240,240);
 if(seed%6===0)for(let y=10;y<15;y++)for(let x=27;x<31;x++)safe[y*w+x]=0;
 if(seed%6===1)for(let y=4;y<8;y++)for(let x=4;x<8;x++)rgba[(y*w+x)*4+3]=255;
 if(seed%6===2)for(let y=2;y<38;y++)for(let x=2;x<38;x++)rgba[(y*w+x)*4+3]=255;
 if(seed%6===3)for(let y=14;y<18;y++)for(let x=9;x<13;x++)rgba[(y*w+x)*4+3]=128;
 const frame=seed%7===0?[100,200,80,80]:[0,0,80,80];
 const panel=[frame[0]+4,frame[1]+4,72,72],ink=[frame[0]+30,frame[1]+30,12,10],clipped=seed%4===0;
 const coverage=clipped?[[panel[0],panel[1],panel[2],28],[panel[0]+8,panel[1]+24,56,48]]:null;
 const sources=seed%5===0?[{frame,bounds:[[.6,.2,.15,.3]],vertical:seed%10===0,sourceFont:13,font:11}]:[];
 const otherInk=seed%9===0?[[frame[0]+12,frame[1]+50,10,8]]:[];
 const f={seed,w,h,safe,rgba,frame,imageSize:[40,40],scale:[1,1],origin:[0,0],panel,ink,clipped,coverage,sources,otherInk,font:seed%11===0?0:10};
 f.expected=policy(f,rect);fixtures.push(f);
}
fs.writeFileSync(out,JSON.stringify(fixtures));console.log(JSON.stringify({cases:fixtures.length,positive:fixtures.filter(f=>f.expected).length,paintedRetained:fixtures.filter(f=>f.expected&&f.rgba.some((v,i)=>i%4===3&&v)).length}));
