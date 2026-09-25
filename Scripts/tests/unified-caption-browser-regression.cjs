// PLAYWRIGHT_MODULE=/path/to/playwright node Scripts/tests/unified-caption-browser-regression.cjs
// Runs the production final commit in real WebKit, including layout and stacking.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {webkit}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const source=fs.readFileSync(process.env.CAPTION_SOURCE_PATH||path.resolve(__dirname,'../../Aidoku/Core/Translation/NativeEngine/Overlay/BrowserOverlayView.swift'),'utf8');
const start=source.indexOf('    // Commit each opaque caption as one rectangle');
const block=source.slice(start,source.indexOf('    root.dataset.readabilityPanels=',start)).replace(/\\([\\"])/g,'$1');
assert.ok(start>0);
const typographySource=fs.readFileSync(path.resolve(__dirname,'../../Aidoku/Core/Translation/NativeEngine/Overlay/BrowserOverlayTypography.swift'),'utf8');
const typographyScript=typographySource.split('static let script = #\"\"\"')[1].split('\"\"\"#')[0];
let browser;
(async()=>{
 browser=await webkit.launch();const page=await browser.newPage({viewport:{width:513,height:593}});
 for(const scroll of [0,120])for(const mode of ['caption','manual','crossing','contained','restored']){
  if(process.env.CAPTION_CASE_FILTER&&!new RegExp(process.env.CAPTION_CASE_FILTER).test(mode))continue;
  await page.setContent('<style>body{margin:0;height:1300px}#root{position:absolute;inset:0}</style><div id="root"></div>');
  await page.evaluate(({scroll,mode})=>{
   const root=document.querySelector('#root');window.root=root;window.items=[];window.cleanupImageGeometry=null;window.typographyInkFrames=new Map();window.minimumFontSize=7;window.appearance={minimumFontSize:7};
   const fixtures=[
    {id:'left',box:[172,155,124,397],ink:[172,165,112,375],text:'「나에게도 너와 비슷한 나이의 딸이 있는데 말이야, 한창 말썽을 피울 때라 골치 아프다니까……」',bg:'rgb(179, 158, 137)',fg:'rgb(0, 0, 0)'},
    {id:'incident',box:[275,155,67,335],ink:[293,176,18,295],text:'그렇게…… 보지 말아주세요',bg:'rgb(102, 89, 78)',fg:'rgb(255, 200, 158)'}];
   if(mode==='crossing')fixtures[1].box=[140,280,220,100];
   if(mode==='contained')fixtures[1].box=[180,170,70,150];
   for(const f of fixtures){
    items.push({id:f.id,text:f.text,sourceFrame:[0,0,513,593],sourceBounds:[f.ink[0]/513,f.ink[1]/593,f.ink[2]/513,f.ink[3]/593]});
    if(mode!=='restored'){
     const p=document.createElement('div');p.dataset.aidokuImageOcrOverlay='source-readability-panel';p.dataset.aidokuRegion=f.id;
     p.style.cssText=`position:absolute;left:${f.box[0]}px;top:${f.box[1]+scroll}px;width:${f.box[2]}px;height:${f.box[3]}px;background:${f.bg};z-index:1`;
     if(mode==='manual')p.dataset.sourceErasure='true';root.append(p);
     const backing=p.cloneNode();backing.dataset.aidokuImageOcrOverlay='source-readability-backing';backing.style.clipPath='inset(5% 20% 10% 20%)';root.append(backing);
    }
    const n=document.createElement('div');n.dataset.aidokuImageOcrOverlay='item';n.dataset.aidokuRegion=f.id;n.textContent=f.text;
    n.style.cssText=`position:absolute;left:${f.ink[0]}px;top:${f.ink[1]+scroll}px;width:${f.ink[2]}px;height:${f.ink[3]}px;font:700 20px/24px sans-serif;color:${f.fg};background:transparent;word-break:keep-all;overflow-wrap:anywhere;box-sizing:border-box;z-index:2`;
    root.append(n);
   }
  },{scroll,mode});
  await page.evaluate(async scroll=>{window.scrollTo(0,scroll);await new Promise(requestAnimationFrame)},scroll);
  assert.equal(await page.evaluate(()=>window.scrollY),scroll);
  const colors=await page.locator('[data-aidoku-image-ocr-overlay="item"]').evaluateAll(ns=>ns.map(n=>n.style.color));
  if(process.env.CAPTION_SCREENSHOT&&scroll===0&&mode==='caption')await page.screenshot({path:process.env.CAPTION_SCREENSHOT+'-before.png'});
  await page.evaluate(typographyScript+'\n'+block);
  if(process.env.CAPTION_SCREENSHOT&&scroll===0&&mode==='caption')await page.screenshot({path:process.env.CAPTION_SCREENSHOT+'-after.png'});
  const result=await page.evaluate(()=>[...root.querySelectorAll('[data-aidoku-image-ocr-overlay="item"]')].map(n=>{
   const r=document.createRange();r.selectNodeContents(n);const ink=r.getBoundingClientRect(),p=n.parentElement,b=p.getBoundingClientRect();
   return {color:n.style.color,unified:n.dataset.unifiedCaption,parent:p.dataset.aidokuRegion,
    contains:ink.left>=b.left+2.5&&ink.right<=b.right-2.5&&ink.top>=b.top+2.5&&ink.bottom<=b.bottom-2.5,
    width:n.getBoundingClientRect().width,ownerWidth:b.width,inkRight:ink.right,text:n.textContent};
  }));
  assert.deepEqual(result.map(n=>n.color),colors,'geometry commit must never recolor ink');
  if(mode==='restored')assert.ok(result.every(n=>!n.unified),'transparent restoration stays untouched');
  else{
   assert.ok(result.every(n=>n.unified==='true'&&n.parent&&n.contains&&n.width===n.ownerWidth),JSON.stringify(result));
   const boxes=await page.locator('[data-aidoku-image-ocr-overlay="source-readability-panel"]').evaluateAll(ns=>ns.map(n=>{
    const r=n.getBoundingClientRect();return {left:r.left,top:r.top,right:r.right,bottom:r.bottom};
   }));
   for(let i=0;i<boxes.length;i++)for(let j=i+1;j<boxes.length;j++){
    const a=boxes[i],b=boxes[j];
    assert.ok(Math.min(a.right,b.right)-Math.max(a.left,b.left)<=.5||Math.min(a.bottom,b.bottom)-Math.max(a.top,b.top)<=.5,
      'whole caption rectangles must never cover each other');
   }
   assert.equal(await page.locator('[data-aidoku-image-ocr-overlay="source-readability-backing"]').count(),0);
   assert.equal(await page.locator('#root > [data-aidoku-image-ocr-overlay="item"]').count(),0);
   const before=await page.locator('[data-aidoku-region="incident"][data-aidoku-image-ocr-overlay="item"]').boundingBox();
   await page.locator('[data-aidoku-region="incident"][data-aidoku-image-ocr-overlay="source-readability-panel"]').evaluate(p=>p.style.left=`${parseFloat(p.style.left)+12}px`);
   const after=await page.locator('[data-aidoku-region="incident"][data-aidoku-image-ocr-overlay="item"]').boundingBox();
   assert.equal(after.x-before.x,12,'moving the rectangle moves its text');
  }
  console.log(`PASS ${mode}, scroll=${scroll}`);
 }

 // Final caption geometry must preserve prior source anchoring, accepted Korean
 // line breaks, and the readability floor. These cases intentionally avoid
 // collisions so geometry has no reason to sacrifice an accepted placement.
 for(const scroll of [0,120])for(const mode of ['source-anchor','word-aware','small-font-floor','bounded-font-floor']){
  if(process.env.CAPTION_CASE_FILTER&&!new RegExp(process.env.CAPTION_CASE_FILTER).test(mode))continue;
  await page.setContent('<style>body{margin:0;height:1300px}#root{position:absolute;inset:0}</style><div id="root"></div>');
  const before=await page.evaluate(({scroll,mode})=>{
   window.scrollTo(0,0);window.root=document.querySelector('#root');window.cleanupImageGeometry=null;window.typographyInkFrames=new Map();window.minimumFontSize=5;
   window.appearance={minimumFontSize:5};
   const small=mode==='small-font-floor',bounded=mode==='bounded-font-floor';
   const size=small?6.5:20,text=mode==='word-aware'?'원문 위치를 지키는 번역':'원문 위치';
   const box=[30,40,260,180],ink=[55,60,150,60];
   window.items=[{id:'preserved',text,vertical:false,sourceFrame:[0,0,513,593],
     sourceBounds:[55/513,60/593,150/513,60/593]}];
   const p=document.createElement('div');p.dataset.aidokuImageOcrOverlay='source-readability-panel';p.dataset.aidokuRegion='preserved';
   p.style.cssText=`position:absolute;left:${box[0]}px;top:${box[1]+scroll}px;width:${box[2]}px;height:${box[3]}px;background:white;z-index:1`;
   root.append(p);
   const n=document.createElement('div');n.dataset.aidokuImageOcrOverlay='item';n.dataset.aidokuRegion='preserved';
   n.style.cssText=`position:absolute;left:${ink[0]}px;top:${ink[1]+scroll}px;width:${ink[2]}px;height:${ink[3]}px;font:700 ${size}px/${size*1.2}px sans-serif;color:rgb(20,20,20);background:transparent;word-break:keep-all;overflow-wrap:anywhere;box-sizing:border-box;z-index:2`;
   if(mode==='word-aware'){
    n.dataset.koreanLineLayout='word-aware';
    for(const text of ['원문 위치를 ','지키는 번역']){
     const line=document.createElement('span');line.style.display='block';line.textContent=text;n.append(line);
    }
   }else n.textContent=text;
   if(bounded){n.style.letterSpacing='1px';n.textContent=items[0].text='읽을 수 있는 글자 크기는 지켜야 하는 것이랍니다';}
   root.append(n);
   const range=document.createRange();range.selectNodeContents(n);const r=range.getBoundingClientRect();
   const source=[55,60+scroll,150,60];
   return {html:n.innerHTML,text:n.textContent,font:size,center:[r.left+r.width/2,r.top+r.height/2],source,breaks:n.querySelectorAll('span').length};
  },{scroll,mode});
  await page.evaluate(async scroll=>{window.scrollTo(0,scroll);await new Promise(requestAnimationFrame)},scroll);
  await page.evaluate(typographyScript+'\n'+block);
  const after=await page.evaluate(()=>{
   const n=root.querySelector('[data-aidoku-image-ocr-overlay="item"]'),p=n.parentElement;
   const range=document.createRange();range.selectNodeContents(n);const r=range.getBoundingClientRect(),b=p.getBoundingClientRect();
   return {text:n.textContent,font:parseFloat(n.style.fontSize),breaks:n.querySelectorAll('span').length,
    center:[r.left+r.width/2,r.top+r.height/2],box:[b.left,b.top,b.width,b.height],
    visible:getComputedStyle(n).visibility!=='hidden'&&getComputedStyle(n).display!=='none',
    fits:r.left>=b.left+2.5&&r.right<=b.right-2.5&&r.top>=b.top+2.5&&r.bottom<=b.bottom-2.5};
  });
  assert.equal(after.text,before.text,`${mode}: final commit preserves all translated content`);
  assert.ok(after.visible&&after.fits,`${mode}: text remains visible and fits its final card: ${JSON.stringify(after)}`);
  const floor=await page.evaluate(typographyScript+`;aidokuCaptionFontFloor(${before.font},5)`);
  assert.ok(after.font+.01>=floor,`${mode}: final font ${after.font} below readable floor ${floor}`);
  if(mode==='small-font-floor')assert.equal(after.font,before.font,'already-small text must not shrink');
  if(mode==='word-aware')assert.equal(after.breaks,before.breaks,'accepted Korean line break elements survive final commit');
  if(mode==='source-anchor'){
   const sourceCenter=[before.source[0]+before.source[2]/2,before.source[1]+before.source[3]/2-scroll];
   const oldDistance=Math.hypot(before.center[0]-sourceCenter[0],before.center[1]-scroll-sourceCenter[1]);
   const newDistance=Math.hypot(after.center[0]-sourceCenter[0],after.center[1]-sourceCenter[1]);
   assert.ok(newDistance<=oldDistance+.5,`final caption must not move accepted text farther from its source: ${oldDistance} -> ${newDistance}`);
  }
  console.log(`PASS ${mode}, scroll=${scroll}`);
 }
 // Neither axis can fit these overlapping multiline captions at the font
 // floor. The transaction must preserve their prior DOM, not silently shrink
 // to 5px, hide text, or commit a clipped partition.
 if(!process.env.CAPTION_CASE_FILTER||new RegExp(process.env.CAPTION_CASE_FILTER).test('floor-rollback')){
  await page.setContent('<style>body{margin:0}#root{position:absolute;inset:0}</style><div id="root"></div>');
  const before=await page.evaluate(()=>{
   window.root=document.querySelector('#root');window.items=[];window.cleanupImageGeometry=null;window.typographyInkFrames=new Map();
   window.minimumFontSize=7;window.appearance={minimumFontSize:7};window.scrollTo(0,0);
   for(const id of ['a','b']){
    items.push({id,text:'WWWWWWWW WWWWWWWW WWWWWWWW',sourceFrame:[0,0,513,593],sourceBounds:[30/513,30/593,180/513,84/593]});
    const p=document.createElement('div');p.dataset.aidokuImageOcrOverlay='source-readability-panel';p.dataset.aidokuRegion=id;
    p.style.cssText='position:absolute;left:30px;top:30px;width:180px;height:84px;background:white';root.append(p);
    const n=document.createElement('div');n.dataset.aidokuImageOcrOverlay='item';n.dataset.aidokuRegion=id;n.dataset.koreanLineLayout='word-aware';
    n.style.cssText='position:absolute;left:33px;top:33px;width:174px;height:78px;font:700 20px/24px sans-serif;box-sizing:border-box;color:black';
    for(let i=0;i<3;i++){const line=document.createElement('span');line.style.cssText='display:block;white-space:nowrap';line.textContent='WWWWWWWW';n.append(line);}
    root.append(n);
   }
   return [...root.children].map(n=>({html:n.innerHTML,css:['left','top','width','height','font-size','line-height','background-color','display','visibility','overflow'].map(k=>getComputedStyle(n).getPropertyValue(k)),text:n.textContent}));
  });
  await page.evaluate(typographyScript+'\n'+block);
  const after=await page.evaluate(()=>({children:[...root.children].map(n=>({html:n.innerHTML,css:['left','top','width','height','font-size','line-height','background-color','display','visibility','overflow'].map(k=>getComputedStyle(n).getPropertyValue(k)),text:n.textContent})),
   fallbacks:root.dataset.captionPreflightFallbacks,
   nodes:[...root.querySelectorAll('[data-aidoku-image-ocr-overlay="item"]')].map(n=>({unified:n.dataset.unifiedCaption,fit:n.dataset.unifiedCaptionFit,font:parseFloat(n.style.fontSize),visible:getComputedStyle(n).visibility!=='hidden'&&getComputedStyle(n).display!=='none'}))}));
  assert.deepEqual(after.children,before,'failed partition restores the original children, styles and panel surfaces');
  assert.equal(after.fallbacks,'1');
  assert.ok(after.nodes.every(n=>!n.unified&&n.fit==='floor-preserved'&&n.font===20&&n.visible));
  console.log('PASS floor-rollback');
 }
 await browser.close();
})().catch(async e=>{console.error(e);await browser?.close();process.exitCode=1});
