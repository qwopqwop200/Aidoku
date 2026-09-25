// PLAYWRIGHT_MODULE=/path/to/playwright node Scripts/tests/compact-caption-browser-regression.cjs
// Exercise final caption geometry in WebKit: preserve old erasure footprints,
// expose empty artwork corners, and keep the selected readable font intact.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {webkit}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const source=fs.readFileSync(process.env.CAPTION_SOURCE||path.resolve(__dirname,'../../Aidoku/Core/Translation/NativeEngine/Overlay/BrowserOverlayView.swift'),'utf8');
const start=source.indexOf('    // Commit each opaque caption as one rectangle');
const block=source.slice(start,source.indexOf('    root.dataset.readabilityPanels=',start)).replace(/\\([\\"])/g,'$1');
assert.ok(start>0);
const typographySource=fs.readFileSync(path.resolve(__dirname,'../../Aidoku/Core/Translation/NativeEngine/Overlay/BrowserOverlayTypography.swift'),'utf8');
const typographyScript=typographySource.split('static let script = #\"\"\"')[1].split('\"\"\"#')[0];
let browser;
(async()=>{
 browser=await webkit.launch();const page=await browser.newPage({viewport:{width:400,height:400}});
 for(const [text,minimumFontSize] of [['짧은 대사',7],['매우 긴 대사로 채워진 말풍선에서는 기존에 선택한 글자 크기가 줄어들거나 번역이 숨겨지지 않도록 기존 사각형으로 돌아가야 한다.',7],['짧은 대사',17]]){
  await page.setContent('<style>body{margin:0}#root{position:absolute;inset:0}</style><div id="root"></div>');
  const boxes=[[40,40,120,100],[140,120,160,100]];
  await page.evaluate(({boxes,text,minimumFontSize})=>{
   window.root=document.querySelector('#root');window.items=[];window.cleanupImageGeometry=null;window.typographyInkFrames=new Map();
   window.minimumFontSize=minimumFontSize;window.appearance={preserveSourceTextColor:false};window.opacity=1;
   boxes.forEach(([x,y,w,h],id)=>{
    items.push({id,text});
    const p=document.createElement('div');p.dataset.aidokuImageOcrOverlay='source-readability-panel';p.dataset.aidokuRegion=id;
    p.style.cssText=`position:absolute;left:${x}px;top:${y}px;width:${w}px;height:${h}px;background:white;z-index:1`;root.append(p);
    const n=document.createElement('div');n.dataset.aidokuImageOcrOverlay='item';n.dataset.aidokuRegion=id;n.textContent=text;
    n.style.cssText=`position:absolute;left:${x+3}px;top:${y+3}px;width:${w-6}px;height:${h-6}px;font:16px/20px sans-serif;color:black;word-break:keep-all;overflow-wrap:anywhere;box-sizing:border-box;z-index:2`;root.append(n);
   });
  },{boxes,text,minimumFontSize});
  // Capture actual original footprint including translated ink, as production does.
  const original=await page.evaluate(()=>[...root.querySelectorAll('[data-aidoku-image-ocr-overlay="item"]')].map(n=>{
   const p=root.querySelector(`[data-aidoku-image-ocr-overlay="source-readability-panel"][data-aidoku-region="${n.dataset.aidokuRegion}"]`),b=p.getBoundingClientRect(),r=document.createRange();r.selectNodeContents(n);const i=r.getBoundingClientRect();
   return [Math.min(b.left,i.left-3),Math.min(b.top,i.top-3),Math.max(b.right,i.right+3),Math.max(b.bottom,i.bottom+3)];
  }));
  await page.evaluate(typographyScript+'\n'+block);
  const result=await page.evaluate(()=>[...root.querySelectorAll('[data-aidoku-image-ocr-overlay="item"]')].map(n=>{
   const p=n.parentElement.dataset.aidokuImageOcrOverlay==='source-readability-panel'?n.parentElement:
    root.querySelector(`[data-aidoku-image-ocr-overlay="source-readability-panel"][data-aidoku-region="${n.dataset.aidokuRegion}"]`);
   const b=p.getBoundingClientRect(),r=document.createRange();r.selectNodeContents(n);const i=r.getBoundingClientRect();
   return {box:[b.left,b.top,b.right,b.bottom],font:parseFloat(n.style.fontSize),text:n.textContent,compact:!!n.dataset.captionCompactOriginal,fitPolicy:n.dataset.unifiedCaptionFit,unified:n.dataset.unifiedCaption,
    fits:i.left>=b.left+2.5&&i.right<=b.right-2.5&&i.top>=b.top+2.5&&i.bottom<=b.bottom-2.5};
  }));
  assert.ok(result.every(r=>r.text===text&&r.fits),'all translated text remains visible');
  // Browser hit testing observes clip-path, including on descendants. The
  // isolated fixture deliberately leaves pointer events enabled on panels;
  // production's pointer-events:none would make painted erasure untestable.
  const rasterCoverage=await page.evaluate(({original})=>{
   const panelSelector='[data-aidoku-image-ocr-overlay="source-readability-panel"]';
   const itemSelector='[data-aidoku-image-ocr-overlay="item"]';
   const panels=[...root.querySelectorAll(panelSelector)];
   const rect=b=>[b.left,b.top,b.right,b.bottom];
   // Hit testing includes the path edge; ignore subpixel boundary rounding.
   const contains=([l,t,r,b],x,y)=>x>=l-.04&&x<=r+.04&&y>=t-.04&&y<=b+.04;
   const opaqueAt=(x,y)=>document.elementsFromPoint(x,y).some(n=>{
    if(!n.matches(panelSelector))return false;
    const s=getComputedStyle(n),rgba=s.backgroundColor.match(/[\d.]+/g)?.map(Number);
    return s.visibility==='visible'&&Number(s.opacity)===1&&rgba?.length>=3&&(rgba.length===3||rgba[3]===1);
   });
   const missedErasure=[],clippedGlyphs=[],filledCorners=[];
   let erasureSamples=0,glyphSamples=0,emptyCornerSamples=0,emptyCornerWitness=null;
   // Exhaustive CSS-pixel centers, rather than rectangle metadata: a tiny
   // omitted source strip or a real path hole must fail even if bounds match.
   for(const [l,t,r,b] of original)for(let y=t+.5;y<b;y++)for(let x=l+.5;x<r;x++){
    erasureSamples++;
    if(!opaqueAt(x,y)&&missedErasure.length<8)missedErasure.push([x,y]);
   }
   const inkBounds=[];
   for(const node of root.querySelectorAll(itemSelector)){
    const whole=document.createRange();whole.selectNodeContents(node);const b=whole.getBoundingClientRect();
    inkBounds.push([b.left-3,b.top-3,b.right+3,b.bottom+3]);
    const walker=document.createTreeWalker(node,NodeFilter.SHOW_TEXT),range=document.createRange();
    while(walker.nextNode()){
     const text=walker.currentNode;
     for(let offset=0;offset<text.length;){
      const char=String.fromCodePoint(text.data.codePointAt(offset)),next=offset+char.length;
      range.setStart(text,offset);range.setEnd(text,next);offset=next;if(/\s/u.test(char))continue;
      for(const r of range.getClientRects()){
       if(r.width<=0||r.height<=0)continue;
       // Center plus four near-corner probes check the entire glyph line box.
       for(const [fx,fy] of [[.5,.5],[.05,.05],[.95,.05],[.05,.95],[.95,.95]]){
        const x=r.left+r.width*fx,y=r.top+r.height*fy;glyphSamples++;
        if(document.elementFromPoint(x,y)?.closest(itemSelector)!==node&&clippedGlyphs.length<8)
         clippedGlyphs.push({id:node.dataset.aidokuRegion,char,x,y});
       }
      }
     }
    }
   }
   for(const panel of panels){
    if(panel.dataset.captionUnionClipped!=='true')continue;
    const [l,t,r,b]=rect(panel.getBoundingClientRect());
    for(let y=t+.5;y<b;y++)for(let x=l+.5;x<r;x++){
     if(original.some(box=>contains(box,x,y))||inkBounds.some(box=>contains(box,x,y)))continue;
     emptyCornerSamples++;
     if(!emptyCornerWitness)emptyCornerWitness={panel,x,y};
     if(opaqueAt(x,y)&&filledCorners.length<8)filledCorners.push([x,y]);
    }
   }
   let clipActuallyExposesCorner=false;
   if(emptyCornerWitness){
    const {panel,x,y}=emptyCornerWitness,saved=panel.style.clipPath;
    panel.style.clipPath='none';clipActuallyExposesCorner=opaqueAt(x,y);panel.style.clipPath=saved;
   }
   return {erasureSamples,glyphSamples,emptyCornerSamples,missedErasure,clippedGlyphs,filledCorners,clipActuallyExposesCorner,
    clippedPanels:panels.filter(p=>p.dataset.captionUnionClipped==='true'&&getComputedStyle(p).clipPath!=='none').length};
  },{original});
  assert.ok(rasterCoverage.erasureSamples>0&&rasterCoverage.glyphSamples>0,'hit-test validation must sample real geometry');
  assert.deepEqual(rasterCoverage.missedErasure,[],'every original erasure pixel is covered by a painted opaque panel');
  assert.deepEqual(rasterCoverage.clippedGlyphs,[],'final glyph boxes survive the actual ancestor clip and stacking');
  assert.deepEqual(rasterCoverage.filledCorners,[],'new empty corners expose the page through the actual clip');

  for(const [l,t,r,b] of original)for(let y=t+.5;y<b;y++)for(let x=l+.5;x<r;x++){
   assert.ok(result.some(({box:[ll,tt,rr,bb]})=>x>=ll-.01&&x<=rr+.01&&y>=tt-.01&&y<=bb+.01),'old source erasure remains covered');
  }
  if(text==='짧은 대사'&&minimumFontSize===7){
   assert.ok(result.some(r=>r.compact),'staggered caption must expose empty artwork');
   assert.ok(rasterCoverage.clippedPanels>0&&rasterCoverage.emptyCornerSamples>0&&rasterCoverage.clipActuallyExposesCorner,
    'staggered fixture must expose a formerly painted corner specifically through clip-path');
   assert.ok(result.every(r=>r.font===16),'compaction keeps the selected font');
   const covered=result.reduce((a,{box:[l,t,r,b]})=>a+(r-l)*(b-t),0);
   assert.ok(covered<260*180,'compaction reduces bounding rectangle coverage');
  }
  if(minimumFontSize===7)assert.ok(result.every(r=>r.font>=Math.max(7,6.5,16*.65)-.02),
   'the smaller shared cells retain the current soft readability floor');
  if(minimumFontSize===17)assert.ok(result.every(r=>r.font===16&&!r.unified&&r.fitPolicy==='floor-preserved'),
   'failed preflight preserves the complete original caption instead of shrinking or clipping');
  console.log(`PASS caption compact, ${text.length} characters, floor=${minimumFontSize}, `+
   `${rasterCoverage.erasureSamples} erasure / ${rasterCoverage.glyphSamples} glyph / ${rasterCoverage.emptyCornerSamples} corner probes`);
 }
 // Three offset balloons have valid, readable initial text. A cheaper font
 // floor must not turn them into a shared row or displace an anchored caption.
 for(const mode of ['source-anchor-group','prior-font-group']){
  await page.setContent('<style>body{margin:0}#root{position:absolute;inset:0}</style><div id="root"></div>');
  const before=await page.evaluate(({mode})=>{
   window.root=document.querySelector('#root');window.items=[];window.cleanupImageGeometry=null;window.typographyInkFrames=new Map();
   window.minimumFontSize=5;window.appearance={preserveSourceTextColor:false};window.opacity=1;
   const frames=[[40,40,80,140],[110,70,80,140],[180,100,80,140]],before=[];
   for(const [id,[x,y,w,h]] of frames.entries()){
    const panel=document.createElement('div');panel.dataset.aidokuImageOcrOverlay='source-readability-panel';panel.dataset.aidokuRegion=id;
    panel.style.cssText=`position:absolute;left:${x}px;top:${y}px;width:${w}px;height:${h}px;background:white;z-index:1`;root.append(panel);
    const node=document.createElement('div');node.dataset.aidokuImageOcrOverlay='item';node.dataset.aidokuRegion=id;
    if(mode==='prior-font-group')node.dataset.artworkOriginalFont='16';
    node.textContent='정말 오늘은 왜 이렇게 이상한 이야기를 하는 거야';
    node.style.cssText=`position:absolute;left:${x+3}px;top:${y+3}px;width:${w-6}px;height:${h-6}px;font:8px/10px sans-serif;color:black;word-break:keep-all;overflow-wrap:anywhere;box-sizing:border-box;z-index:2;display:flex;align-items:center;justify-content:center`;root.append(node);
    const range=document.createRange();range.selectNodeContents(node);const ink=range.getBoundingClientRect(),b=node.getBoundingClientRect();
    const item={id,text:node.textContent};
    // This fixture starts with measured source-aligned ink, unlike the separate
    // unified-caption fixture whose 18px-wide/20px font deliberately overflows.
    if(mode==='source-anchor-group')Object.assign(item,{sourceFrame:[0,0,400,400],
     sourceBounds:[ink.x/400,ink.y/400,ink.width/400,ink.height/400]});
    items.push(item);before.push({text:node.textContent,center:[ink.x+ink.width/2,ink.y+ink.height/2],
     fits:ink.left>=b.left-.02&&ink.right<=b.right+.02&&ink.top>=b.top-.02&&ink.bottom<=b.bottom+.02});
   }
   return before;
  },{mode});
  assert.ok(before.every(n=>n.fits),'multi-caption regression must start from valid readable geometry');
  await page.evaluate(typographyScript+'\n'+block);
  const after=await page.evaluate(()=>[...root.querySelectorAll('[data-aidoku-image-ocr-overlay="item"]')].map(n=>{
   const r=document.createRange();r.selectNodeContents(n);const b=r.getBoundingClientRect();
   return {text:n.textContent,font:parseFloat(n.style.fontSize),center:[b.x+b.width/2,b.y+b.height/2],
    unified:n.dataset.unifiedCaption,visibility:getComputedStyle(n).visibility};
  }));
  for(let i=0;i<before.length;i++){
   assert.equal(after[i].text,before[i].text);
   assert.equal(after[i].font,8,'packing never charges an already reduced caption a second font reduction');
   assert.notEqual(after[i].visibility,'hidden');
   if(mode==='source-anchor-group')assert.ok(Math.hypot(after[i].center[0]-before[i].center[0],after[i].center[1]-before[i].center[1])<1,
    'repartitioning must preserve the already source-aligned caption center');
   else assert.ok(!after[i].unified,'a reduced font cannot admit an opaque group that fails at its original readable floor');
  }
  console.log(`PASS caption compact, ${mode}`);
 }
 await browser.close();
})().catch(e=>{console.error(e);process.exitCode=1}).finally(async()=>{if(browser)await browser.close()});
