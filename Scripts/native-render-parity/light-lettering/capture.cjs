const fs=require('fs'),path=require('path');
const root=process.argv[2],out=process.argv[3];
const source=fs.readFileSync(path.join(root,'Scripts/native-render-parity/reference-source/BrowserOverlayView.swift'),'utf8');
const start=source.indexOf('    if(opacity===1&&appearance?.preserveSourceTextColor&&appearance?.preserveSourceBackgroundColor&&\n        coverSource?.complete&&coverSource.naturalWidth>0&&items.length<=256)try {');
const end=source.indexOf('    // Heavy source lettering:',start);
if(start<0||end<start)throw Error('frozen light pass absent');
const block=source.slice(start,end).replace('canvasL.width=0;canvasL.height=0;','root.dataset.remaining=lightPixels;canvasL.width=0;canvasL.height=0;');
const colors=fs.readFileSync(path.join(root,'Scripts/native-render-parity/reference-source/BrowserSourceTextColor.swift'),'utf8');
const lumStart=colors.indexOf('const aidokuSourceColorLuminance =');
const lumEnd=colors.indexOf(';',colors.indexOf('}, 0)',lumStart))+1;
if(lumStart<0||lumEnd<=lumStart)throw Error('frozen luminance absent');
const lum=colors.slice(lumStart,lumEnd);
const run=new Function('c',`
${lum}
const opacity=1,appearance={preserveSourceTextColor:true,preserveSourceBackgroundColor:true};
const coverSource={complete:true,naturalWidth:c.image[0],naturalHeight:c.image[1]};
const cleanupImageGeometry={frame:c.frame},performance={now:()=>0};
const rgbaCSS=a=>'rgb('+a.join(',')+')';
const owner={isConnected:true,dataset:{aidokuImageOcrOverlay:'source-readability-panel'},style:{backgroundColor:rgbaCSS(c.plate),backgroundImage:'none'},querySelectorAll:()=>[node],getBoundingClientRect:()=>({left:c.plateRect[0],top:c.plateRect[1],right:c.plateRect[0]+c.plateRect[2],bottom:c.plateRect[1]+c.plateRect[3]})};
const node={dataset:{aidokuRegion:'x',sourceBackgroundColor:c.mode,outlinedLettering:JSON.stringify(c.ring),sourceAppliedBackgroundRGB:c.plate.join(','),sourceSampledTextRGB:c.sampledFill?.join(',')||'',sourceSampledStrokeRGB:c.sampledStroke?.join(',')||'',sourceStrokeConfidence:c.strokeConfidence,sourceSampledBackgroundRGB:c.sampledBackground?.join(',')||''},style:{fontSize:c.font+'px',color:rgbaCSS(c.ink),webkitTextStrokeWidth:c.strokeWidth+'px'},parentElement:owner};
const neighbor={dataset:{},style:{},rect:[c.plateRect[0],c.plateRect[1],c.plateRect[0]+1,c.plateRect[1]+1]};
const root={dataset:{},querySelectorAll:s=>s.includes('source-readability-backing')?[]:s.includes('source-readability-panel')?[owner]:c.neighbor?[node,neighbor]:[node]};
const items=[{id:'x',sourceBounds:c.bounds,sourceFrame:c.frame,sourceFontSize:c.sourceFont,sourceColorEligible:true}];
let sampled=null;
const canvas={width:0,height:0,getContext:()=>({drawImage:(img,x,y,sw,sh,dx,dy,w,h)=>{const rgba=new Uint8ClampedArray(w*h*4);for(let j=0;j<h;j++)for(let i=0;i<w;i++){
 const sx=x+(i+.5)*sw/w,sy=y+(j+.5)*sh/h;let colour=c.surface;
 const bx=c.bounds[0]*c.image[0],by=c.bounds[1]*c.image[1],bw=c.bounds[2]*c.image[0],bh=c.bounds[3]*c.image[1];
 const ix=sx-bx,iy=sy-by;
 if(c.pattern==='flat')colour=c.surface;
 else if(c.pattern==='open'){if(ix>=0&&ix<bw&&i%12<5)colour=c.pale;}
 else {const stripe=((Math.floor(ix)-3)%12+12)%12;const inside=ix>=3&&ix<bw-3&&iy>=5&&iy<bh-5;
  if(inside&&stripe<c.thickness)colour=c.pale;
  if(c.pattern==='halo'&&inside&&stripe>=2&&stripe<c.thickness-2&&iy>=8&&iy<bh-8)colour=c.halo;
  if(c.pattern==='speck'&&((i*37+j*19)%23===0))colour=c.pale;
  if(c.pattern==='outside'&&(ix<0||iy<0||ix>=bw||iy>=bh))colour=c.pale;
  if(c.pattern==='split'&&i>w*.56&&colour===c.surface)colour=c.secondSurface;
 }
 const p=(j*w+i)*4;rgba[p]=colour[0];rgba[p+1]=colour[1];rgba[p+2]=colour[2];rgba[p+3]=255;
 }sampled={source:[x,y,sw,sh],w,h,rgba:Array.from(rgba)};},getImageData:()=>({data:new Uint8ClampedArray(sampled.rgba)})})};
const document={createElement:()=>canvas,createRange:()=>({selectNodeContents(n){this.n=n;},getBoundingClientRect(){const a=this.n.rect;return {left:a[0],top:a[1],right:a[2],bottom:a[3]};}})};
${block}
if(root.dataset.lightLetteringError)throw Error(root.dataset.lightLetteringError);
const record=node.dataset.lightLettering?JSON.parse(node.dataset.lightLettering):{};
return {record,rejection:node.dataset.lightLetteringReject||null,styled:Number(root.dataset.lightLettering),remaining:root.dataset.remaining,sampled};
`);
const base={image:[100,80],frame:[0,0,100,80],bounds:[.2,.2,.6,.6],plateRect:[20,16,60,48],sourceFont:24,font:18,mode:'readability-panel',strokeWidth:0,ink:[30,30,30],plate:[250,250,250],sampledFill:[245,245,245],sampledStroke:null,sampledBackground:[20,20,20],strokeConfidence:0,ring:{},surface:[20,20,20],pale:[245,245,245],secondSurface:[100,80,180],halo:[180,20,50],neighbor:false,pattern:'bars',thickness:5};
const fixtures=[];const add=c=>{const input={...structuredClone(base),...c};fixtures.push({input,expected:run(input)});};
for(const pattern of ['bars','flat','open','halo','speck','outside','split'])for(const thickness of [1,3,5,7,9])for(const font of [12,18])add({pattern,thickness,font});
for(const surface of [[0,0,0],[30,30,30],[50,40,95],[100,120,110],[170,170,170],[230,230,230]])for(const pale of [[245,245,245],[200,200,200],[250,220,170]])add({surface,pale});
for(const sourceFont of [0,7,8,12,24,40,80,160,1000])add({sourceFont});
for(const font of [5,6,12,18])add({font,neighbor:true});
for(const mode of ['readability-panel','rotated-panel','inpainted'])for(const font of [10,12,18,48])for(const width of [.09,.1])add({mode,font,ring:{kind:'outline',action:'none',core:[255,255,255],outline:[200,0,100],plate:[250,250,250],hug:.8,uniform:.8,width}});
for(const hug of [.69,.7])for(const uniform of [.59,.6])for(const strokeWidth of [0,.5])add({strokeWidth,ring:{kind:'outline',action:'none',core:[255,255,255],outline:[200,0,100],plate:[250,250,250],hug,uniform,width:.15}});
for(const bounds of [[-.1,.1,.6,.6],[.9,.1,.6,.6],[.2,.8,.6,.6],[.2,.2,.03,.03]])add({bounds});
fs.writeFileSync(out,JSON.stringify(fixtures));console.log(JSON.stringify({cases:fixtures.length,accepted:fixtures.filter(x=>x.expected.styled).length,lightPassSHA256:require('crypto').createHash('sha256').update(source.slice(start,end)).digest('hex')}));
