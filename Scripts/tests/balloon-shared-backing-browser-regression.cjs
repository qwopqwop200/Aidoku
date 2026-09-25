// Verify the production shared-card admission gate against actual DOM geometry.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {webkit}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const source=fs.readFileSync(process.env.CAPTION_SOURCE||path.resolve(__dirname,'../../Aidoku/Core/Translation/NativeEngine/Overlay/BrowserOverlayView.swift'),'utf8');
const begin=source.indexOf('              let sharedRemoval=false;',source.indexOf('fitBalloon: '));
assert.ok(begin>0,'shared backing admission must exist');
const gate=source.slice(begin,source.indexOf('              measurementNode.style.cssText=',begin)).replace(/\\([\\"])/g,'$1');
let browser;
(async()=>{
 browser=await webkit.launch();const page=await browser.newPage({viewport:{width:300,height:300}});
 for(const mode of ['unverified-source','verified-source','incomplete-source','unbacked-text','restored-text','owned-text','partial-owned-text','clipped-owned-text','coverage-hole-owned-text','covered-owned-text','detached-source','many-verified-source','one-unverified-source','translucent-owned-text','transparent-owned-text','hidden-owned-text','opacity-owned-text']){
  await page.setContent('<style>body{margin:0}#root{position:absolute;inset:0}</style><div id="root"></div>');
  const admitted=await page.evaluate(({gate,mode})=>{
   const root=document.querySelector('#root'),item={id:0,sourceFrame:[0,0,300,300],sourceBounds:[0,0,.1,.1]},items=[item];
   const restoredPanelGeometry=new Map(),cleanupImageGeometry=null;
   const plate=document.createElement('div');plate.style.cssText='position:absolute;left:20px;top:20px;width:100px;height:100px';root.append(plate);
   const node=document.createElement('div');node.dataset.aidokuImageOcrOverlay='item';root.append(node);
   const p=plate.getBoundingClientRect(),intersects=r=>r[0]<p.right&&r[0]+r[2]>p.left&&r[1]<p.bottom&&r[1]+r[3]>p.top;
   if(mode.endsWith('source')){
    for(let index=0;index<(mode==='many-verified-source'||mode==='one-unverified-source'?8:1);index++){
    const other={id:index+1,sourceFrame:[0,0,300,300],sourceBounds:[.1+index*.015,.1,.1,.1]};items.push(other);
    const canvas=document.createElement('canvas');canvas.width=30;canvas.height=30;
    canvas.getContext('2d').fillRect(0,0,30,30);if(mode!=='detached-source')root.append(canvas);
    restoredPanelGeometry.set(other,{canvas,sourceErasureVerified:mode!=='unverified-source'&&!(mode==='one-unverified-source'&&index===6),erasureComplete:mode!=='incomplete-source'});
    }
   }else{
    const other=document.createElement('div');other.dataset.aidokuImageOcrOverlay='item';other.dataset.aidokuRegion='1';other.textContent='neighbor';
    other.style.cssText='position:absolute;left:40px;top:40px;font:12px/16px sans-serif';root.append(other);
    if(mode==='restored-text')other.dataset.sourceBackgroundColor='inpainted';
    if(mode.endsWith('owned-text')){
     const backing=document.createElement('div');backing.dataset.aidokuImageOcrOverlay='source-readability-panel';backing.dataset.aidokuRegion='1';
     backing.style.cssText=`position:absolute;left:35px;top:35px;width:${mode==='partial-owned-text'?10:85}px;height:30px;background:white`;root.append(backing);
     if(mode==='translucent-owned-text')backing.style.backgroundColor='rgba(255,255,255,.25)';
     if(mode==='transparent-owned-text')backing.style.backgroundColor='transparent';
     if(mode==='hidden-owned-text')backing.style.visibility='hidden';
     if(mode==='opacity-owned-text')backing.style.opacity='.25';
     if(mode==='clipped-owned-text')backing.style.clipPath='inset(0 80% 0 0)';
     if(mode==='coverage-hole-owned-text')backing.dataset.panelCoverage=JSON.stringify([[35,35,10,30],[100,35,20,30]]);
     if(mode==='covered-owned-text')backing.dataset.panelCoverage=JSON.stringify([[35,35,85,30]]);
    }
   }
   return eval(`(()=>{${gate};return sharedRemoval;})()`);
  },{gate,mode});
  assert.equal(admitted,['verified-source','restored-text','owned-text','covered-owned-text','many-verified-source'].includes(mode),mode);
  console.log('PASS shared balloon backing: '+mode);
 }
})().catch(e=>{console.error(e);process.exitCode=1}).finally(async()=>{if(browser)await browser.close()});
