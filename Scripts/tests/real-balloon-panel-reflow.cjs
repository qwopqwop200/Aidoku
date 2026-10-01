const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {webkit}=require(process.env.PLAYWRIGHT_MODULE||'playwright'),root=process.argv[2];
const load=s=>JSON.parse(fs.readFileSync(path.join(root,s)));
const payload=load('native-after/incident-10.payload.json'),dump=load('before-panel-reflow/incident-10.items.json');
const item=payload.items.find(x=>String(x.id)==='8'),caption=dump.items.find(x=>x.region==='8');
const layer=dump.layers.find(x=>x.region==='8'&&x.kind==='source-readability-panel');assert.ok(item&&caption&&layer);
const script=fs.readFileSync(path.join(__dirname,'../../Aidoku/Core/Translation/NativeEngine/Overlay/BrowserOverlayTypography.swift'),'utf8').split('static let script = #"""')[1].split('"""#')[0];
(async()=>{const browser=await webkit.launch();try{const page=await browser.newPage({viewport:{width:430,height:574}});
 for(const mode of ['fit','no-room']){
  await page.setContent('<style>body{margin:0}</style><div id="root"></div>');
  await page.evaluate(({item,caption,layer,mode})=>{
   const root=document.querySelector('#root'),node=document.createElement('div'),panel=document.createElement('div');
   node.innerHTML=caption.html;node.style.cssText=caption.css;Object.assign(node.dataset,caption.dataset);
   node.dataset.aidokuImageOcrOverlay='item';node.dataset.aidokuRegion=String(item.id);
   Object.assign(panel.dataset,layer.dataset);panel.dataset.aidokuImageOcrOverlay='source-readability-panel';
   const [x,y,w,h]=layer.box;panel.style.cssText=`position:absolute;left:${x}px;top:${y}px;width:${w}px;height:${h}px;background:${layer.background}`;
   if(mode==='no-room')item.text='너무 긴 문장 '.repeat(200);
   root.append(panel,node);window.item=item;window.before={css:node.style.cssText,html:node.innerHTML,panel:panel.style.cssText};
  },{item,caption,layer,mode});
  const r=await page.evaluate(script+`;(()=>{
   aidokuContainBalloonPanels(document.querySelector('#root'),[window.item]);
   const node=document.querySelector('[data-aidoku-image-ocr-overlay="item"]'),panel=document.querySelector('[data-aidoku-image-ocr-overlay="source-readability-panel"]');
   const range=document.createRange();range.selectNodeContents(node);
   return {fit:panel.dataset.finalBalloonPanelFit,coverage:JSON.parse(panel.dataset.panelCoverage||'null'),text:node.textContent,
    lines:[...range.getClientRects()].map(r=>[r.left,r.top,r.width,r.height]),font:parseFloat(node.style.fontSize),
    unchanged:node.style.cssText===before.css&&node.innerHTML===before.html&&panel.style.cssText===before.panel};
  })()`);
  if(mode==='no-room'){assert.ok(r.unchanged,'failed reflow rolls back text, children, and backing');continue;}
  assert.equal(r.fit,'reflowed-rectangle');assert.equal(r.coverage.length,1);assert.equal(r.text,item.text);
  assert.ok(r.font>=caption.fontSize*.85);
  const [x,y,w,h]=r.coverage[0],f=item.sourceFrame,b=item.balloonInterior,top=f[1]+b.rect[1]*f[3],height=b.rect[3]*f[3],bands=b.spans.length/2;
  for(let k=Math.floor((y-top)/height*bands);k<Math.ceil((y+h-top)/height*bands);k++){
   assert.ok(k>=0&&k<bands&&b.spans[2*k]>=0);assert.ok(x>=f[0]+b.spans[2*k]*f[2]-.05&&x+w<=f[0]+b.spans[2*k+1]*f[2]+.05);
  }
  const s=item.sourceBounds;assert.ok(x<=f[0]+s[0]*f[2]&&x+w>=f[0]+(s[0]+s[2])*f[2]);
  assert.ok(y<=f[1]+s[1]*f[3]&&y+h>=f[1]+(s[1]+s[3])*f[3]);
  assert.ok(r.lines.every(l=>l[0]>=x&&l[1]>=y&&l[0]+l[2]<=x+w&&l[1]+l[3]<=y+h));
 }
 console.log('PASS captured balloon: rectangular backing contains source and all translated lines, failed reflow fully rolls back');
}finally{await browser.close();}})().catch(e=>{console.error(e);process.exitCode=1;});
