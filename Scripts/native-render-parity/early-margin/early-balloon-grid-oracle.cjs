const fs=require('fs'),vm=require('vm'),crypto=require('crypto');
const ref=process.argv[2],s=fs.readFileSync(ref+'/BrowserOverlayView.swift','utf8').replace(/\\\\/g,'\\');
const p=fs.readFileSync(ref+'/BrowserSourcePanelRestoration.swift','utf8');
const start=s.indexOf('                const c=panelGeometry,kx=c.iw/c.frame[2]*c.sx,ky=c.ih/c.frame[3]*c.sy;');
const finish=s.indexOf('                // Safe-area fit (late pass only)',start);
if(start<0||finish<0)throw Error('Frozen grid extraction seam missing');
const block=s.slice(start,finish),plane=p.slice(p.indexOf('        function aidokuSurfacePlaneRGB('),p.indexOf('        // Paint the fitted RGB plane',p.indexOf('        function aidokuSurfacePlaneRGB(')));
const fn=new vm.Script(`function runGrid(){${plane}\n${block}\nreturn {w,h,cx0,cy0,kx,ky,sl,sr,st,sb,scx,scy,blocked,reached,sat,clear};}runGrid();`);
function hash(a){return crypto.createHash('sha256').update(a).digest('hex');}
const jobs=JSON.parse(fs.readFileSync(process.argv[3],'utf8'));
const output=jobs.map(j=>{
 const [x,y,sx,sy,iw,ih]=j.at,reads=[],frame=j.frame;
 const c={w:j.w,h:j.h,x,y,sx,sy,iw,ih,frame,safe:Uint8Array.from(j.safe),surfaceQuality:{safe:j.surfaceSafe,coefficients:j.coeff}};
 if(j.painted)c.canvas={width:j.w,height:j.h,getContext(){return {getImageData(){return {data:Uint8Array.from(j.painted.flatMap(a=>[0,0,0,a]))}}}}};
 const source=j.sources[0]??[0,0,0,0],sourceCX=frame[0]+(source[0]+source[2]/2)*frame[2],sourceCY=frame[1]+(source[1]+source[3]/2)*frame[3];
 let interior=null;
 if(j.interior){const E=j.interior,k=4,w=Math.ceil(E[2]*k),h=Math.ceil(E[3]*k);interior={E:{left:E[0],top:E[1]},k,w,h,fill:new Uint8Array(w*h).fill(1)};}
 const reach=j.clearSearch&&!j.late&&j.surfaceSafe&&Array.isArray(j.coeff)?64:0;
 const reader={read(context,x,y,sw,sh,w,h){
  reads.push([x,y,sw,sh,w,h]);if(j.exterior==='absent')return null;
  const kx=iw/frame[2]*sx,ky=ih/frame[3]*sy,ex=Math.round(64*kx),ey=Math.round(64*ky),data=new Uint8Array(w*h*4);
  for(let yy=0;yy<h;yy++)for(let xx=0;xx<w;xx++){
   const coeff=j.coeff??[[240,0,0],[240,0,0],[240,0,0]],plane=coeff.map(a=>Math.max(0,Math.min(255,a[0]+a[1]*(xx-ex)/j.w+a[2]*(yy-ey)/j.h)));
   const bias=j.exterior==='wrong'?19:j.exterior==='tolerance'?18:j.exterior==='striped'&&xx%7===0?19:0,i=(yy*w+xx)*4;
   for(let c=0;c<3;c++)data[i+c]=Math.max(0,Math.min(255,Math.floor(plane[c]+bias+.5)));
   data[i+3]=j.exterior==='alpha253'?253:j.exterior==='alpha254'?254:255;
  }return data;
 }};
 const ctx={panelGeometry:c,reach,sourceImage:{complete:true},cleanupContext:{},sourcePixelReader:reader,balloonInteriorOf:()=>interior,
 item:{sourceBounds:source,auxiliaryInkRects:j.sources.slice(1),sourceFontSize:j.glyph},sourceCX,sourceCY,font:8,
 otherBackgrounds:j.obstacles.map(a=>({left:a[0],top:a[1],right:a[0]+a[2],bottom:a[1]+a[3]})),otherInks:[]};
 const g=fn.runInNewContext(ctx),r={name:j.name,reads,accepted:!!g};
 if(g){const queries=[[0,0,g.w,g.h],[0,0,1,1],[Math.floor(g.w/2),Math.floor(g.h/2),1,1],[Math.floor(g.w/3),Math.floor(g.h/3),2,2],[Math.max(0,g.w-2),Math.max(0,g.h-2),2,2]];
  Object.assign(r,{width:g.w,height:g.h,crop:[g.cx0,g.cy0,g.w/g.kx,g.h/g.ky],kx:g.kx,ky:g.ky,span:[g.sl,g.st,g.sr-g.sl,g.sb-g.st],sourceCentre:[sourceCX,sourceCY],gridCentre:[g.scx,g.scy],blocked:hash(g.blocked),reached:hash(g.reached),sat:hash(new Uint8Array(g.sat.buffer)),clear:queries.map(q=>g.clear(...q)),reachable:g.reached.reduce((a,b)=>a+b,0)});
 }return r;
});
fs.writeFileSync(process.argv[4],JSON.stringify(output));
