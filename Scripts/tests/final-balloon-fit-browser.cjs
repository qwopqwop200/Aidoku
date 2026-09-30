// Real captured caption geometry; exercise safe fit, refusal and rollback.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {webkit}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const root=process.argv[2];assert.ok(root,'Pass panel-rectangles replay directory');
const read=p=>JSON.parse(fs.readFileSync(path.join(root,p)));
const payload=read('native-after/incident-10.payload.json');
const dump=read('merged-after/incident-10.items.json');
const item=payload.items.find(x=>String(x.id)==='15'),caption=dump.items.find(x=>x.region==='15');
const layer=dump.layers.find(x=>x.region==='15'&&x.kind==='source-readability-panel');
assert.ok(item&&caption&&layer);
const script=fs.readFileSync(path.join(__dirname,'../../Aidoku/Core/Translation/NativeEngine/Overlay/BrowserOverlayTypography.swift'),'utf8').split('static let script = #"""')[1].split('"""#')[0];
(async()=>{
 const browser=await webkit.launch();try{
 const page=await browser.newPage({viewport:{width:430,height:574}});
 for(const mode of ['fit','unverified','no-room']){
  await page.setContent('<style>body{margin:0}</style><div id="root"></div>');
  await page.evaluate(({item,caption,layer,mode})=>{
   const root=document.querySelector('#root'),node=document.createElement('div'),panel=document.createElement('div');
   node.innerHTML=caption.html;node.style.cssText=caption.css;
   Object.assign(node.dataset,caption.dataset);node.dataset.aidokuRegion=String(item.id);
   Object.assign(panel.dataset,layer.dataset);panel.dataset.aidokuImageOcrOverlay='source-readability-panel';
   const [x,y,w,h]=layer.box;panel.style.cssText=`position:absolute;left:${x}px;top:${y}px;width:${w}px;height:${h}px;background:${layer.background}`;
   root.append(panel,node);window.input=item;window.before=node.style.cssText;
   if(mode==='unverified')item.balloonInterior.contourVerified=false;
   if(mode==='no-room')item.balloonInterior.spans=item.balloonInterior.spans.map((v,k,a)=>k%2?a[k-1]+.0001:v);
  },{item,caption,layer,mode});
  const result=await page.evaluate(script+`;aidokuContainBalloonText(document.querySelector('#root'),[window.input]);
   const node=document.querySelector('[data-aidoku-image-ocr-overlay="item"]');
   ({same:node.style.cssText===window.before,fit:node.dataset.finalBalloonFit,rejected:node.dataset.finalBalloonFitRejected});`);
  if(mode==='fit')assert.ok(result.fit&&!result.rejected);
  else assert.equal(result.same,true,'uncertain contours must preserve the full original style');
  if(mode==='no-room')assert.equal(result.rejected,'no-safe-slot');
 }
 console.log('PASS final balloon fit: captured caption fitted, unverified contour unchanged, impossible fit fully rolled back');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
