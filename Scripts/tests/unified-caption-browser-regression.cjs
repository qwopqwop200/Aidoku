// PLAYWRIGHT_MODULE=/path/to/playwright node Scripts/tests/unified-caption-browser-regression.cjs
// Runs the production final commit in real WebKit, including layout and stacking.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {webkit}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const source=fs.readFileSync(path.resolve(__dirname,'../../Aidoku/Core/Translation/NativeEngine/Overlay/BrowserOverlayView.swift'),'utf8');
const start=source.indexOf('    // Commit each opaque caption as one rectangle');
const block=source.slice(start,source.indexOf('    root.dataset.readabilityPanels=',start)).replace(/\\([\\"])/g,'$1');
assert.ok(start>0);
(async()=>{
 const browser=await webkit.launch();const page=await browser.newPage({viewport:{width:513,height:593}});
 for(const scroll of [0,120])for(const mode of ['caption','manual','crossing','contained','restored']){
  await page.setContent('<style>body{margin:0;height:1300px}#root{position:absolute;inset:0}</style><div id="root"></div>');
  await page.evaluate(({scroll,mode})=>{
   const root=document.querySelector('#root');window.root=root;window.items=[];
   const fixtures=[
    {id:'left',box:[172,155,124,397],ink:[172,165,112,375],text:'「나에게도 너와 비슷한 나이의 딸이 있는데 말이야, 한창 말썽을 피울 때라 골치 아프다니까……」',bg:'rgb(179, 158, 137)',fg:'rgb(0, 0, 0)'},
    {id:'incident',box:[275,155,67,335],ink:[293,176,18,295],text:'그렇게…… 보지 말아주세요',bg:'rgb(102, 89, 78)',fg:'rgb(255, 200, 158)'}];
   if(mode==='crossing')fixtures[1].box=[140,280,220,100];
   if(mode==='contained')fixtures[1].box=[180,170,70,150];
   for(const f of fixtures){
    items.push({id:f.id,text:f.text});
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
  await page.evaluate(block);
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
 await browser.close();
})().catch(e=>{console.error(e);process.exitCode=1});
