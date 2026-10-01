// Frozen historical Web renderer reference; production native rendering is tested by AidokuFull.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {webkit}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const script=fs.readFileSync(path.join(__dirname,'../../AidokuTests/Translation/LegacyBrowserOverlay/BrowserOverlayTypography.swift'),'utf8').split('static let script = #"""')[1].split('"""#')[0];
(async()=>{const browser=await webkit.launch();try{const page=await browser.newPage();
for(const mode of ['unverified-balloon','verified-balloon','unknown','paragraph']){
 await page.setContent('<div id="root"><div data-aidoku-image-ocr-overlay="item" data-aidoku-region="1" data-source-background-color="inpainted" style="position:absolute;left:30px;top:140px;width:100px;height:30px;font:16px Arial">test</div></div>');
 const result=await page.evaluate(({script,mode})=>{
  const item={id:1,sourceVertical:true,sourceFrame:[0,0,400,500],sourceBounds:[.1,.1,.1,.6],
   ...(mode.includes('balloon')?{balloonInterior:{contourVerified:mode==='verified-balloon'}}:{}),
   ...(mode==='paragraph'?{columnLayout:{balancedColumn:true}}:{})};
  const node=document.querySelector('[data-aidoku-region]'),before=node.style.top;
  new Function('root','items',script+';aidokuAnchorVerticalCaptionTops(root,items);')(document.querySelector('#root'),[item]);
  return {unchanged:node.style.top===before,anchored:node.dataset.sourceTopAnchored};
 },{script,mode});
 assert.equal(result.unchanged,mode!=='paragraph',mode);
 assert.equal(result.anchored==='true',mode==='paragraph',mode);
}
console.log('PASS: balloon/unknown dialogue keeps position; explicit paragraph retains top anchoring');
}finally{await browser.close();}})().catch(e=>{console.error(e);process.exitCode=1});
