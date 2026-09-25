// PLAYWRIGHT_MODULE=/path/to/playwright node Scripts/tests/source-bridge-browser-regression.cjs
// Bounded real WebKit checks for rejected-caption artwork coverage and explicit
// oversized source preservation. Both blocks are extracted from production.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {webkit}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const source=fs.readFileSync(path.resolve(__dirname,'../../Aidoku/Core/Translation/NativeEngine/Overlay/BrowserOverlayView.swift'),'utf8');
function extract(from,to){const a=source.indexOf(from),b=source.indexOf(to,a);assert.ok(a>=0&&b>a);return source.slice(a,b).replace(/\\([\\"])/g,'$1');}
const oversized=extract('    // Oversized failed source restoration','    // Commit each opaque caption');
const bridge='(()=>{'+extract('      const sourceRect=item=>{','      const finalInks=')+extract('      // A rejected partition retains','    // Geometry is now committed.').replace(/\s*}\s*$/,'')+'})();';
let browser;
(async()=>{
 browser=await webkit.launch();const page=await browser.newPage({viewport:{width:400,height:400}});
 for(const mode of ['large','collision','restored','small']){
  await page.setContent('<style>body{margin:0}#root{position:absolute;inset:0}</style><div id="root"></div>');
  await page.evaluate(mode=>{
   window.root=document.querySelector('#root');window.cleanupImageGeometry=null;window.restoredPanelGeometry=new Map();
   window.items=[{id:'owner',sourceFrame:[0,0,400,400],sourceBounds:mode==='small'?[.05,.05,.1,.1]:[.05,.05,.9,.85]}];
   if(mode==='restored')restoredPanelGeometry.set(items[0],{});
   const panel=document.createElement('div');panel.dataset.aidokuImageOcrOverlay='source-readability-panel';panel.dataset.aidokuRegion='owner';panel.style.cssText='position:absolute;left:20px;top:20px;width:360px;height:350px;background:white';root.append(panel);
   const n=document.createElement('div');n.dataset.aidokuImageOcrOverlay='item';n.dataset.aidokuRegion='owner';n.textContent='읽을 수 있는 번역';n.style.cssText='position:absolute;left:110px;top:180px;width:180px;height:24px;font:16px/24px sans-serif;color:black';root.append(n);
   if(mode==='collision'){const other=n.cloneNode(true);other.dataset.aidokuRegion='neighbor';root.append(other);}
  },mode);
  await page.evaluate(oversized);
  const result=await page.evaluate(()=>{
   const n=root.querySelector('[data-aidoku-region="owner"][data-aidoku-image-ocr-overlay="item"]'),p=root.querySelector('[data-aidoku-image-ocr-overlay="source-readability-panel"]');
   const r=document.createRange();r.selectNodeContents(n);const ink=r.getBoundingClientRect(),b=p.getBoundingClientRect();
   return {preserved:n.dataset.sourceErasurePreserved,background:n.dataset.sourceBackgroundColor,shift:Number(n.dataset.sourcePreservedCaptionShift||0),text:n.textContent,font:parseFloat(n.style.fontSize),area:b.width*b.height,
    fits:ink.left>=b.left&&ink.top>=b.top&&ink.right<=b.right&&ink.bottom<=b.bottom};
  });
  assert.equal(result.text,'읽을 수 있는 번역');assert.equal(result.font,16);
  if(mode==='large'||mode==='collision'){assert.equal(result.preserved,'oversized-unrestored');assert.equal(result.background,'source-preserved-caption');assert.ok(result.fits&&result.area<10000);}
  else {assert.equal(result.preserved,undefined);assert.equal(result.area,126000);}
  if(mode==='collision')assert.ok(result.shift>0&&result.shift<=72);
 }
 await page.setContent('<style>body{margin:0}#root{position:absolute;inset:0}</style><div id="root"></div>');
 await page.evaluate(()=>{
  window.root=document.querySelector('#root');window.cleanupImageGeometry=null;window.typographyInkFrames=new Map();window.backings=[];
  window.items=[
   {id:'owner',sourceFrame:[0,0,400,400],sourceBounds:[.05,.825,.1,.075],sourceVertical:true,sourceFontSize:10,auxiliaryInkRects:[[.2,.8,.025,.025]]},
   {id:'neighbor',sourceFrame:[0,0,400,400],sourceBounds:[.25,.375,.0625,.0625],sourceFontSize:8},
   {id:'preserved',sourceFrame:[0,0,400,400],sourceBounds:[0,0,1,1]}
  ];
  for(const item of items){const n=document.createElement('div');n.dataset.aidokuImageOcrOverlay='item';n.dataset.aidokuRegion=item.id;n.style.cssText='position:absolute;left:180px;top:25px;font:10px/12px sans-serif';n.textContent=item.id==='owner'?'번역':'';if(item.id==='preserved')n.dataset.sourceErasurePreserved='oversized-unrestored';root.append(n);}
  const p=document.createElement('div');p.dataset.aidokuImageOcrOverlay='source-readability-panel';p.dataset.aidokuRegion='owner';p.style.cssText='position:absolute;left:20px;top:20px;width:240px;height:350px;background:white';root.prepend(p);
  window.skippedCaptions=new Set([{node:root.querySelector('[data-aidoku-region="owner"][data-aidoku-image-ocr-overlay="item"]'),panel:p,owned:[p]}]);
  window.finalInks=new Map([['owner',[180,25,35,12]],['neighbor',[160,240,30,12]]]);
  // Source, auxiliary, neighboring original and final translated footprints.
  window.required=[[10,327,60,36],[70,317,30,16],[97,142,31,41],[177,22,41,18],[157,237,36,18]];
 });
 const prior=await page.evaluate(()=>{
  const panel=root.querySelector('[data-aidoku-image-ocr-overlay="source-readability-panel"]');const samples=[];
  for(const [l,t,w,h] of required)for(let y=t+.5;y<t+h;y+=2)for(let x=l+.5;x<l+w;x+=2)if(document.elementsFromPoint(x,y).includes(panel))samples.push([x,y]);return samples;
 });
 await page.evaluate(bridge);
 const proof=await page.evaluate(prior=>{
  const p=root.querySelector('[data-aidoku-image-ocr-overlay="source-readability-panel"]');
  return {lost:prior.filter(([x,y])=>!document.elementsFromPoint(x,y).includes(p)),released:!document.elementsFromPoint(70,200).includes(p),clipped:p.dataset.sourceBridgeClipped,rect:[p.offsetLeft,p.offsetTop,p.offsetWidth,p.offsetHeight]};
 },prior);
 assert.ok(prior.length>500);assert.deepEqual(proof.lost,[],'retain actual painted original, auxiliary and neighbor glyph coverage');assert.ok(proof.released,'release a real empty bridge pixel');assert.equal(proof.clipped,'true');assert.deepEqual(proof.rect,[20,20,240,350]);
 await page.evaluate(()=>{delete items[0].sourceBounds;const p=root.querySelector('[data-aidoku-image-ocr-overlay="source-readability-panel"]');p.style.clipPath='';delete p.dataset.sourceBridgeClipped;delete p.dataset.captionUnionClipped;});
 await page.evaluate(bridge);
 assert.equal(await page.evaluate(()=>root.querySelector('[data-aidoku-image-ocr-overlay="source-readability-panel"]').dataset.sourceBridgeClipped),undefined,'unknown source coverage must retain the original panel');
 console.log(`source bridge regression: 6 cases passed; ${prior.length} required coverage samples retained`);
 await browser.close();
})().catch(async error=>{console.error(error);await browser?.close();process.exitCode=1;});
