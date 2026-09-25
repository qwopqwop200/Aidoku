// Exercise the actual balloon-fit loop and its failed-fit DOM rollback in WebKit.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {webkit}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const base=path.resolve(__dirname,'../../Aidoku/Core/Translation/NativeEngine/Overlay');
const source=fs.readFileSync(process.env.CAPTION_SOURCE||path.join(base,'BrowserOverlayView.swift'),'utf8');
const start=source.indexOf('fitBalloon: ')+'fitBalloon: '.length;
const fitSource=source.slice(start,source.indexOf('            protectArtwork: () => {',start)).trim().replace(/,$/,'').replace(/\\([\\"])/g,'$1');
const typeSource=fs.readFileSync(path.join(base,'BrowserOverlayTypography.swift'),'utf8');
let helpers=typeSource.split('static let script = #"""')[1].split('"""#')[0];
if(process.env.EMERGENCY_HELPER&&!helpers.includes('const aidokuEmergencyBalloonFontSizes'))helpers+='\n'+fs.readFileSync(process.env.EMERGENCY_HELPER,'utf8');
let browser;
(async()=>{
 browser=await webkit.launch();const page=await browser.newPage({viewport:{width:400,height:400}});
 for(const minimum of [5,6]){
  await page.setContent('<style>body{margin:0}</style><div id="root"></div>');
  const result=await page.evaluate(({fitSource,helpers,minimum})=>{
   const root=document.querySelector('#root'),item={id:1,sourceBounds:[.5,.25,.2,.25],sourceFrame:[0,0,400,400]};
   const items=[item],cleanupImageGeometry=null,restoredPanelGeometry=new Map(),wrappingScript='korean',displayedText='짧은 대사',minimumFontSize=minimum;
   const panel=document.createElement('div');panel.dataset.aidokuImageOcrOverlay='source-readability-panel';panel.dataset.aidokuRegion='1';
   panel.style.cssText='position:absolute;left:50px;top:50px;width:250px;height:250px;background:white';root.append(panel);
   const node=document.createElement('div');node.dataset.aidokuImageOcrOverlay='item';node.dataset.aidokuRegion='1';node.dataset.sourceAppliedTextRGB='0,0,0';
   node.style.cssText='position:absolute;left:90px;top:90px;width:70px;height:40px;font:10px/12px sans-serif;color:black';node.innerHTML='<span>짧은 대사</span>';root.append(node);
   const measurementHost=document.createElement('div');root.append(measurementHost);const measurementNode=node.cloneNode(true);measurementNode.removeAttribute('data-aidoku-image-ocr-overlay');
   let x=90,y=90,width=70,height=40,readabilityPanels=1,balloonTypeBudget=8192,balloonSurfaceBudget=524288,restoredPanelLookupBudget=524288;
   const panelGeometry={frame:[0,0,400,400],x:0,y:0,w:400,h:400,iw:400,ih:400,sx:1,sy:1};
   const lineHeightRatio=1.2,observed=[];let probes=0;
   const applyMeasuredFontSize=size=>{observed.push(size);for(const n of [node,measurementNode]){n.style.fontSize=size+'px';n.style.lineHeight=size*lineHeightRatio+'px';}};
   const lineProfile=()=>{const range=document.createRange();range.selectNodeContents(measurementNode);const r=range.getBoundingClientRect();return {ink:[[r.left,r.top,r.width,r.height]],lines:1,breaks:[],hangulFragments:0,punctuationOnly:0,badStarts:[],badEnds:[],hangulIsolated:0};};
   const contentFits=()=>true;
   const wordLines=()=>{for(const n of [node,measurementNode])n.style.paddingTop=Math.max(0,(height-parseFloat(n.style.fontSize)*lineHeightRatio)/2)+'px';return true;};
   const koreanWrapMeasure={measureText:()=>({width:10})};
   const fitsRestoredSurface=()=>{probes++;return false;};
   const aidokuSourceColorLuminance=()=>0;
   const appearance=()=>{const style=getComputedStyle(node);return Object.fromEntries(['position','left','top','width','height','font-size','font-family','font-weight','line-height','color','padding','display','white-space','letter-spacing','transform'].map(k=>[k,style.getPropertyValue(k)]));};
   const before={appearance:appearance(),html:node.innerHTML};
   const accepted=eval(helpers+'\n('+fitSource+')()');
   return {accepted,probes,observed,min:Math.min(...observed),restored:JSON.stringify(appearance())===JSON.stringify(before.appearance)&&node.innerHTML===before.html,
    measurementDetached:!measurementNode.isConnected,panelKept:panel.isConnected,readabilityPanels,dimensions:[x,y,width,height],balloonTypeBudget};
  },{fitSource,helpers,minimum});
  assert.equal(result.accepted,false);
  assert.ok(result.restored&&result.measurementDetached&&result.panelKept,'failed emergency attempts restore full DOM and preserve backing');
  assert.equal(result.readabilityPanels,1);assert.deepEqual(result.dimensions,[90,90,70,40]);
  assert.equal(result.min,minimum,'last emergency candidate reaches configured minimum');
  assert.ok(result.probes>0&&result.probes<=120&&result.observed.length<=120,'preferred + emergency probes remain bounded');
  assert.ok(result.balloonTypeBudget>=0,'page budget is preserved');
  console.log(`PASS emergency rollback, minimum=${minimum}, probes=${result.probes}, measured=${result.observed.length}`);
 }
})().catch(e=>{console.error(e);process.exitCode=1}).finally(async()=>{if(browser)await browser.close()});
