const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {webkit}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const script=fs.readFileSync(path.join(__dirname,'../../Aidoku/Core/Translation/NativeEngine/Overlay/BrowserOverlayTypography.swift'),'utf8').split('static let script = #"""')[1].split('"""#')[0];
(async()=>{const browser=await webkit.launch();try{const page=await browser.newPage();
for(const mode of ['outline-overlap','clear','kept-obstacle','panel','same-column']){
 await page.setContent(`<div id="root" style="position:absolute;left:0;top:0"><div data-aidoku-image-ocr-overlay="item" data-aidoku-region="1" data-source-background-color="${mode==='panel'?'rgb(0,0,0)':'inpainted'}" style="position:absolute;left:30px;top:50px;width:45px;height:100px;font:20px/25px Arial;-webkit-text-stroke:4px black;white-space:nowrap">AB<br>CD</div><div data-aidoku-image-ocr-overlay="item" data-aidoku-region="2" data-source-background-color="inpainted" style="position:absolute;left:${mode==='clear'?90:58}px;top:50px;width:45px;height:100px;font:20px/25px Arial;-webkit-text-stroke:4px orange;white-space:nowrap">EF<br>GH</div></div>`);
 const result=await page.evaluate(({script,mode})=>{
  const items=[1,2].map(id=>({id,sourceVertical:true,sourceFrame:[0,0,200,300],sourceBounds:[id===1||mode==='same-column'?.15:.3,.15,.12,.5]}));
  if(mode==='kept-obstacle')items.push({id:'kept',keptLettering:true,sourceFrame:[0,0,200,300],sourceBounds:[.1,.15,.5,.3]});
  const nodes=[...document.querySelectorAll('[data-aidoku-region]')],before=nodes.map(n=>n.style.cssText);
  const rects=n=>{const r=document.createRange();r.selectNodeContents(n);return [...r.getClientRects()].filter(r=>r.width&&r.height);};
  const top=nodes.map(n=>rects(n)[0].top);
  new Function('root','items',script+';aidokuSeparateCaptionColumns(root,items);')(document.querySelector('#root'),items);
  const a=rects(nodes[0]),b=rects(nodes[1]);
  const collision=a.some(r=>b.some(o=>r.left-2.5<o.right+2.5&&r.right+2.5>o.left-2.5&&r.top-2.5<o.bottom+2.5&&r.bottom+2.5>o.top-2.5));
  return {collision,unchanged:nodes.every((n,i)=>n.style.cssText===before[i]),topPreserved:nodes.every((n,i)=>rects(n)[0].top===top[i]),text:nodes.map(n=>n.textContent)};
 },{script,mode});
 assert.equal(result.unchanged,mode!=='outline-overlap',mode);
 assert.equal(result.collision,mode!=='outline-overlap'&&mode!=='clear',mode);
 assert(result.topPreserved,mode);assert.deepEqual(result.text,['ABCD','EFGH']);
}
console.log('PASS: final outlined columns separate; source tops, panels, retained ink and already-clear text remain unchanged');
}finally{await browser.close();}})().catch(e=>{console.error(e);process.exitCode=1});
