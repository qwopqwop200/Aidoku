// Production final typography in WebKit. The detector's erasure plate must not
// rotate upright translated lettering, and cannot be enlarged to make it fit.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {webkit}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const source=fs.readFileSync(path.join(__dirname,'../../AidokuTests/Translation/LegacyBrowserOverlay/BrowserOverlayTypography.swift'),'utf8')
  .split('static let script = #"""')[1].split('"""#')[0];
(async()=>{
 const browser=await webkit.launch();
 try{
  const page=await browser.newPage({viewport:{width:430,height:607},deviceScaleFactor:3});
  await page.setContent('<style>body{margin:0}</style>');
  await page.evaluate(source+';window.upright=aidokuUprightCaptionText;');
  const result=await page.evaluate(()=>{
   const run=(flag,angle,small=false,clipped=false)=>{
    const root=document.createElement('div'),node=document.createElement('div'),plate=document.createElement('div');
    document.body.append(root);root.append(plate,node);
    node.dataset.aidokuImageOcrOverlay='item';node.dataset.aidokuRegion='0';
    plate.dataset.aidokuImageOcrOverlay='source-rotated-panel';plate.dataset.aidokuRegion='0';
    const css=`position:absolute;left:311.02929px;top:28.45787px;width:116.21347px;height:374.55975px;box-sizing:border-box;transform:rotate(${angle}rad);transform-origin:50% 50%`;
    plate.style.cssText=css+';background:rgb(250,247,253)';
    if(small)plate.style.width='6px';
    if(clipped)plate.style.clipPath='polygon(0px 0px, 5px 0px, 5px 5px, 0px 5px)';
    node.style.cssText=css+';display:flex;align-items:center;justify-content:center;font:700 51.5px/62px sans-serif;text-align:center';
    node.textContent='루나\n닉쿤';node.style.whiteSpace='pre-line';
    const geometry=()=>{const s=getComputedStyle(node);return ['transform','fontSize','lineHeight','width','height','left','top','clipPath','whiteSpace'].map(k=>s[k]);};
    const before=plate.style.cssText,beforeText=JSON.stringify(geometry());
    window.upright(root,[{id:'0',uprightQuadText:flag,vertical:false,rotation:angle,sourceFrame:[0,0,430,607]}]);
    const out={plateUnchanged:before===plate.style.cssText,textUnchanged:beforeText===JSON.stringify(geometry()),
      transform:node.style.transform,font:parseFloat(node.style.fontSize),proof:node.dataset.uprightQuadProof,text:node.textContent};
    root.remove();return out;
   };
   return [run(true,-.061420099665154194),run(false,-.061420099665154194),run(true,-.25),
     run(true,-.061420099665154194,true),run(true,-.061420099665154194,false,true)];
  });
  assert.equal(result[0].transform,'none');assert.equal(result[0].font,51.5);
  assert.equal(result[0].proof,'fixed-source-plate');
  for(const r of result){assert.equal(r.plateUnchanged,true);assert.equal(r.text,'루나\n닉쿤');}
  for(const r of result.slice(1))assert.equal(r.textUnchanged,true,'slanted / unproven / clipped controls unchanged');
  console.log('PASS upright title, fixed font and erasure plate; slanted, narrow and clipped controls');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
