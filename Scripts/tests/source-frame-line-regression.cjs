// Production frame restoration must distinguish a crossing rule from an art contour.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {webkit} = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const source = fs.readFileSync(path.join(__dirname,'../../Aidoku/Core/Translation/NativeEngine/Overlay/BrowserOverlayView.swift'),'utf8');
const start = source.indexOf('    const frameSource=');
const end = source.indexOf('    // Readability floor for rotated plates.',start);
assert.ok(start > 0 && end > start);
const script = source.slice(start,end);
(async()=>{
 const browser=await webkit.launch();
 try {
  const page=await browser.newPage({viewport:{width:220,height:200}});
  await page.setContent('<body style="margin:0"></body>');
  const result=await page.evaluate(async script=>{
   const results=[];
   for(const spec of [
    {name:'crossing',from:20,to:170,left:60},
    {name:'entersRight',from:90,to:170,left:60},
    {name:'entersLeft',from:20,to:90,left:60},
    {name:'pageEdge',from:20,to:110,left:0}
   ]){
    const image=document.createElement('canvas');image.width=220;image.height=200;
    const ctx=image.getContext('2d');ctx.fillStyle='white';ctx.fillRect(0,0,220,200);
    ctx.fillStyle='#303030';ctx.fillRect(spec.from,70,spec.to-spec.from,2);
    const sourceImage=new Image();sourceImage.src=image.toDataURL();await sourceImage.decode();
    const root=document.createElement('div'),panel=document.createElement('div');document.body.append(root);root.append(panel);
    panel.dataset.aidokuImageOcrOverlay='source-readability-panel';panel.dataset.aidokuRegion='caption';
    panel.style.cssText=`position:absolute;left:${spec.left}px;top:40px;width:70px;height:100px;background:rgb(160,190,210)`;
    const items=[{id:'caption',sourceBounds:[(spec.left+5)/220,45/200,50/220,90/200]}];
    new Function('sourceImage','root','items','opacity','cleanupImageGeometry',script)(sourceImage,root,items,1,{frame:[0,0,220,200]});
    results.push({name:spec.name,restored:Number(panel.dataset.sourceFrameLines||0),background:panel.style.backgroundImage});root.remove();
   }
   return results;
  },script);
  assert.ok(result[0].restored>0,'a rule continuing beyond both sides must remain visible');
  for(const value of result.slice(1)){
   assert.equal(value.restored,0,value.name+' must not cut a notch into a rectangular caption');
   assert.ok(!value.background||value.background==='none',value.name+' must retain a flat plate');
  }
  console.log('PASS source frame restoration: crossing rule retained; three one-sided contours rejected');
 } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});
