const fs=require('fs');const [root,out,fp]=process.argv.slice(2);const s=fs.readFileSync(root+'/Scripts/native-render-parity/reference-source/BrowserOverlayView.swift','utf8');const start=s.indexOf('              const opaqueCard=layer=>',s.indexOf('            fitBalloon:')),end=s.indexOf('              measurementNode.style.cssText',start),body=s.slice(start,end);
const run=new Function('f',`
const box=a=>({left:a[0],top:a[1],width:a[2],height:a[3],right:a[0]+a[2],bottom:a[1]+a[3]});
const panels=f.panels.map(p=>({dataset:{aidokuRegion:p.id,sourceErasure:p.erasure?'true':undefined,panelCoverage:p.coverage?JSON.stringify(p.coverage):undefined},getBoundingClientRect:()=>box(p.rect),fixture:p}));
const nodes=f.captions.map(c=>({dataset:{aidokuRegion:c.id,sourceBackgroundColor:c.inpainted?'inpainted':undefined},getBoundingClientRect:()=>box(c.ink)}));
const items=f.captions.map(c=>({id:c.id,sourceFrame:[0,0,100,100],sourceBounds:c.sources[0]?.map(x=>x/100),auxiliaryInkRects:c.sources.slice(1).map(a=>a.map(x=>x/100))}));
const item=items[0],node=nodes[0],plate=panels[0],p=plate.getBoundingClientRect(),legible=f.legible,cleanupImageGeometry={frame:[0,0,100,100]};
const intersects=r=>r[0]<p.right&&r[0]+r[2]>p.left&&r[1]<p.bottom&&r[1]+r[3]>p.top;
const root={querySelectorAll:q=>q.includes('"item"')?nodes:panels,contains:c=>c.isConnected};
const getComputedStyle=layer=>{const f=layer.fixture;return {backgroundColor:f.opaque?'rgb(200,200,200)':'rgba(200,200,200,0.5)',clipPath:f.clipped?'polygon()':'none',display:f.visible?'block':'none',visibility:f.visible?'visible':'hidden',opacity:String(f.opacity)}};
const document={createRange:()=>{let selected;return {selectNodeContents:n=>selected=n,getBoundingClientRect:()=>selected.getBoundingClientRect()}}};
const restoredPanelGeometry=new Map(items.map((item,i)=>{const c=f.captions[i];return [item,{sourceErasureVerified:c.verified,erasureComplete:c.complete,provisional:c.provisional,partialErasureCertified:c.partial,canvas:{isConnected:c.connected,width:c.size[0],height:c.size[1]}}]}));
const decide=()=>{${body}return true;};const accepted=decide();return {id:f.id,accepted:accepted!==false};
`);fs.writeFileSync(out,JSON.stringify(JSON.parse(fs.readFileSync(fp)).map(run)));
