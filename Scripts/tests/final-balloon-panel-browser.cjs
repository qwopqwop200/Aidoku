// Frozen historical Web renderer reference; production native rendering is tested by AidokuFull.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {webkit}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const script=fs.readFileSync(path.join(__dirname,'../../AidokuTests/Translation/LegacyBrowserOverlay/BrowserOverlayTypography.swift'),'utf8').split('static let script = #"""')[1].split('"""#')[0];
(async()=>{const browser=await webkit.launch();try{
 const page=await browser.newPage({viewport:{width:400,height:400}});
 for(const mode of ['fit','unverified','source-outside','foreign-outside']){
  await page.setContent('<style>body{margin:0}</style><div id="root"><div data-aidoku-image-ocr-overlay="source-readability-panel" data-aidoku-region="a" style="position:absolute;left:80px;top:80px;width:240px;height:240px;background:#ddd"></div><div data-aidoku-image-ocr-overlay="item" data-aidoku-region="a" style="position:absolute;left:150px;top:175px;font:12px sans-serif">test</div></div>');
  const result=await page.evaluate(script+`;(()=>{
    const item={id:'a',sourceFrame:[0,0,400,400],sourceBounds:[.35,.4,.15,.1],balloonInterior:{rect:[.25,.25,.5,.5],contourVerified:${mode!=='unverified'},spans:[.4,.6,.3,.7,.25,.75,.25,.75,.3,.7,.4,.6]}};
    const items=[item];
    if('${mode}'==='source-outside')item.sourceBounds=[.175,.4,.325,.1];
    if('${mode}'==='foreign-outside')items.push({id:'b',sourceFrame:item.sourceFrame,sourceBounds:[.7,.4,.075,.1]});
    const p=document.querySelector('[data-aidoku-image-ocr-overlay="source-readability-panel"]'),before=p.style.cssText;
    aidokuContainBalloonPanels(document.querySelector('#root'),items);
    return {same:p.style.cssText===before,coverage:JSON.parse(p.dataset.panelCoverage||'null'),fit:p.dataset.finalBalloonPanelFit};
  })()`);
  if(mode==='fit'){
   assert.equal(result.fit,'rectangular');assert.equal(result.coverage.length,1);
   const [x,y,w,h]=result.coverage[0];assert.ok(x<=140&&y<=160&&x+w>=200&&y+h>=200);
   assert.ok(x>=120&&x+w<=280&&y>=100&&y+h<=300);
  }else assert.ok(result.same,mode+' must preserve backing coverage');
 }
 console.log('PASS rectangular balloon backing: source and ink coverage retained; uncertain and foreign-source cases unchanged');
}finally{await browser.close();}})().catch(e=>{console.error(e);process.exitCode=1;});
