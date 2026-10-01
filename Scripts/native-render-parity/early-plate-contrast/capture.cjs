const fs=require('node:fs'),path=require('node:path');const [root,out]=process.argv.slice(2);
const view=fs.readFileSync(path.join(root,'Scripts/native-render-parity/reference-source/BrowserOverlayView.swift'),'utf8');
const color=fs.readFileSync(path.join(root,'Scripts/native-render-parity/reference-source/BrowserSourceTextColor.swift'),'utf8');
const geo=fs.readFileSync(path.join(root,'Scripts/native-render-parity/reference-source/BrowserOverlayTypography.swift'),'utf8');
const colors=color.slice(color.indexOf('    const aidokuSourceColorLuminance'),color.indexOf('    // A verified source outline'));
const geometry=geo.slice(geo.indexOf('    const aidokuVisiblePanelColors'),geo.indexOf('    const aidokuNeedsTextBacking'));
const start=view.indexOf('      (()=>{for(const item of items){',view.indexOf('      const layers=Array.from(root.querySelectorAll'));
const body=view.slice(start,view.indexOf('      }})();',start)+'      }})();'.length);
const run=new Function('f',colors+geometry+`
const items=f.records.map(r=>({id:r.id,sourceColorEligible:r.eligible,sourceTextOnly:r.textOnly}));
const nodes=new Map(f.records.map(r=>[r.id,{style:{fontSize:String(r.font)},dataset:{sourceAppliedTextRGB:r.inkRGB.join(',')}}]));
const plates=new Map(f.records.filter(r=>r.panels.some(p=>!p.sourceErasure)).map(r=>[r.id,{style:{backgroundColor:'rgb('+r.panels.filter(p=>!p.sourceErasure).at(-1).color.join(',')+')'},getBoundingClientRect:()=>bounds(r.panels.filter(p=>!p.sourceErasure).at(-1).rect),cloneNode(){return {style:{...this.style},setAttribute(){},removeAttribute(){}}}}]));
const bounds=r=>({left:r[0],top:r[1],width:r[2],height:r[3]});const rect=r=>[r.left,r.top,r.width,r.height];
const inks=new Map(f.records.map(r=>[r.id,r.ink]));
const layers=f.records.flatMap(r=>r.panels.map(p=>({color:p.color,coverage:p.coverage.length?p.coverage:[p.rect]}))).concat(f.records.flatMap(r=>r.backings.map(p=>({color:p.color,coverage:p.coverage}))));
const root={appendChild(){}};const cachedSourceSample=item=>({captionBackground:f.records.find(r=>r.id===item.id).fallback});
const aidokuCaptionPalette=(sample,ink,preserve)=>({background:sample.captionBackground});
if(f.opacity===1&&f.itemCount<=256){`+body+`}
return f.records.map(r=>{const d=nodes.get(r.id).dataset;return {id:r.id,foreground:d.sourceAppliedTextRGB.split(',').map(Number),backing:d.sourceTextBacking?JSON.parse(d.sourceTextBacking):null,decision:d.sourceContrastOriginalInk?{before:d.sourceContrastOriginalInk.split(',').map(Number),after:d.sourceAppliedTextRGB.split(',').map(Number),surfaces:JSON.parse(d.sourceContrastSurfaces),minimumBefore:Number(d.sourceContrastBefore),minimumAfter:Number(d.sourceContrastAfter)}:null}});
`);
const fixtures=[];
for(let seed=0;seed<128;seed++){
 const record=(id,ink,inkRGB,panel,color)=>({id,eligible:true,textOnly:false,font:seed%6===0?18:9,ink,inkRGB,panels:[{rect:panel,color,coverage:seed%7===0?[[panel[0],panel[1],panel[2],panel[3]/2]]:[panel],sourceErasure:false}],backings:[],fallback:color});
 const colors=[[55,65,91],[151,140,164],[49,32,20],[240,240,240],[90,90,90]],inkRGB=[[70,70,135],[2,3,2],[240,100,110],[250,251,253]][seed%4];
 const records=[record('a',[10,10,12,10],inkRGB,[5,5,35,30],colors[seed%5])];
 if(seed%3===0)records.push(record('b',[25,10,10,12],[30,40,50],[16,5,25,30],colors[(seed+2)%5]));
 if(seed%8===0)records[0].eligible=false;
 if(seed%9===0)records[0].textOnly=true;
 if(seed%11===0)records[0].panels[0].sourceErasure=true;
 if(seed%13===0)records[0].backings.push({frame:[5,5,35,30],coverage:[[10,10,8,10]],color:[200,190,180]});
 const f={seed,records,opacity:seed%17===0?.5:1,itemCount:seed%19===0?257:records.length};f.expected=run(f);fixtures.push(f);
}
const snapshot=path.join(root,'build/native-render-parity/verify-image-build30-snapshot');
for(const [name,id] of [['real-comic-0007','14'],['real-comic-0025','4']]){
 const native=JSON.parse(fs.readFileSync(path.join(snapshot,name,'native-final-layout.json'),'utf8'));
 const web=JSON.parse(fs.readFileSync(path.join(snapshot,name,'web-final-layout.json'),'utf8'));
 const c=native.cards.find(v=>String(v.id)===id),n=web.layers.find(v=>v.kind==='item'&&String(v.id)===id),d=n.dataset;
 const background=JSON.parse(d.sourceContrastSurfaces)[0];
 const webPanel=web.layers.find(v=>v.kind==='source-readability-panel'&&String(v.id)===id);
 const panels=c.panels.length?c.panels.map(p=>({rect:p.rect,color:background,coverage:p.coverage,sourceErasure:false})):[{rect:[webPanel.rect.x,webPanel.rect.y,webPanel.rect.width,webPanel.rect.height],color:background,coverage:[[webPanel.rect.x,webPanel.rect.y,webPanel.rect.width,webPanel.rect.height]],sourceErasure:false}];
 const r={id,eligible:true,textOnly:false,font:c.fontSize,ink:c.ink,inkRGB:d.sourceContrastOriginalInk.split(',').map(Number),panels,backings:[],fallback:background};
 const f={seed:name+':'+id,records:[r],opacity:1,itemCount:1};f.expected=run(f);fixtures.push(f);
}
fs.writeFileSync(out,JSON.stringify(fixtures));
