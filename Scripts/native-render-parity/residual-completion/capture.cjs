const fs=require('node:fs'),path=require('node:path');
const [root,out]=process.argv.slice(2);
const source=fs.readFileSync(path.join(root,'Scripts/native-render-parity/reference-source/BrowserOverlayView.swift'),'utf8');
const start=source.indexOf('            completeResidualErasure: () => {'),end=source.indexOf('\n            finalize: () => {',start);
const body=source.slice(start,end).replace(/^\s*completeResidualErasure: \(\) => \{/,'').replace(/\n\s*},\s*$/,'');
const fixtures=[];
for(let seed=0;seed<90;seed++){
 const w=40,h=32,original=new Uint8ClampedArray(w*h*4),rgba=new Uint8ClampedArray(w*h*4),safe=new Uint8Array(w*h).fill(1),luminance=new Uint8Array(w*h).fill(100);
 for(let i=0;i<w*h;i++){original.set([250,249,248,255],i*4);rgba.set([250,249,248,255],i*4);}
 const l=seed>=84?12:seed>=72?0:seed%4===0?1:12+(seed%5),t=seed>=84?12:seed>=72?10:seed%6===0?1:11+(seed%4),rw=seed>=84?14:seed>=72?3:seed%9===0?15:2+(seed%3),rh=seed>=72?2:seed%10===0?13:2+(seed%2);
 for(let y=t;y<Math.min(h,t+rh);y++)for(let x=l;x<Math.min(w,l+rw);x++){
  const i=y*w+x;safe[i]=0;rgba[i*4+3]=0;original.set(seed%7===0?[40,120,190,255]:[20,20,20,255],i*4);
 }
 if(seed%11===0)for(let y=3;y<29;y++)for(let x=3;x<37;x++){if(safe[y*w+x]){const v=(x+y)%2?20:200;rgba.set([v,v,v,255],(y*w+x)*4);}}
 const foreground=seed<72&&seed%7===0?[40,120,190]:null,background=foreground?[250,249,248]:null;
 const iw=seed>=72?100:w,ih=seed>=72?96:h,ox=seed>=72?20:0,oy=seed>=72?20:0;
 const box=[(10+ox)/iw,(8+oy)/ih,20/iw,16/ih],plate=seed>=72?[ox,oy,w,h]:seed%8===0?[28,24,6,6]:[10,8,20,16];
 const sourceRGBA=new Uint8ClampedArray(iw*ih*4);for(let i=0;i<iw*ih;i++)sourceRGBA.set([250,249,248,255],i*4);
 for(let y=0;y<h;y++)for(let x=0;x<w;x++)sourceRGBA.set(original.subarray((y*w+x)*4,(y*w+x)*4+4),((y+oy)*iw+x+ox)*4);
 if(seed>=72&&seed%2===0)for(let x=0;x<ox;x++)sourceRGBA.set([20,20,20,255],((oy+t)*iw+x)*4);
 const other=seed%13===0?[[.25,.25,.4,.4]]:[];
 const c={erasureComplete:true,residualLettering:true,partialErasureCertified:false,safe:safe.slice(),luminance:luminance.slice(),w,h,iw,ih,frame:[0,0,iw,ih],x:ox,y:oy,sx:1,sy:1,surfaceRevision:4};
 const image={data:rgba.slice()},paint={getImageData:()=>image,putImageData:im=>{image.data=im.data;}};
 c.canvas={isConnected:true,width:w,height:h,getContext:()=>paint};
 const sourceFont=seed>=84?0:8;
 const item={id:'candidate',sourceBounds:box,sourceFontSize:sourceFont,auxiliaryInkRects:[],rotation:0,balancedColumn:false};
 const node={style:{fontSize:'10px'},dataset:{sourceSampledTextRGB:foreground?.join(',')||'',sourceSampledBackgroundRGB:background?.join(',')||''}};
 const panel={dataset:{aidokuRegion:'candidate',sourceErasure:'false'},getBoundingClientRect:()=>({left:plate[0],top:plate[1],width:plate[2],height:plate[3]})};
 const rootDOM={querySelectorAll:()=>[panel]},items=[item,...other.map((r,i)=>({id:'other'+i,sourceBounds:r}))],keptItems=[];
 const sourcePixelReader={read:(ctx,x,y,sw,sh,ww,hh)=>{const p=new Uint8ClampedArray(ww*hh*4);for(let yy=0;yy<hh;yy++)for(let xx=0;xx<ww;xx++){const sx=x+xx,sy=y+yy;if(sx>=0&&sx<iw&&sy>=0&&sy<ih)p.set(sourceRGBA.subarray((sy*iw+sx)*4,(sy*iw+sx)*4+4),(yy*ww+xx)*4);}return p;}};
 const fn=new Function('panelGeometry','item','node','root','items','keptItems','sourceImage','cleanupContext','cleanupCanvas','sourcePixelReader','budgetStop',body);
 const undo=fn(c,item,node,rootDOM,items,keptItems,{complete:true},{},{},sourcePixelReader,()=>true);
 const normalized=()=>({rgba:Array.from(image.data),safe:Array.from(c.safe),luminance:Array.from(c.luminance),residual:c.residualLettering,revision:c.surfaceRevision,filled:node.dataset.sourceResidualFilled==null?null:Number(node.dataset.sourceResidualFilled)});
 const expected={accepted:!!undo,after:normalized()};if(undo){undo();expected.undo=normalized();}
 fixtures.push({seed,sourceFont,w,h,iw,ih,ox,oy,sourceRGBA:Array.from(sourceRGBA),original:Array.from(original),rgba:Array.from(rgba),safe:Array.from(safe),luminance:Array.from(luminance),box,plate,other,foreground,background,expected});
}
fs.writeFileSync(out,JSON.stringify(fixtures));console.log(JSON.stringify({cases:fixtures.length,accepted:fixtures.filter(f=>f.expected.accepted).length,filled:fixtures.filter(f=>f.expected.after.filled>0).length}));
