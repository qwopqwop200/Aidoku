const fs=require('fs'),vm=require('vm');const source=fs.readFileSync(process.argv[2]+'/BrowserOverlayView.swift','utf8').replace(/\\\\/g,'\\');
const start=source.indexOf('    if(opacity===1&&appearance?.preserveSourceTextColor&&appearance?.preserveSourceBackgroundColor&&items.length<=256)try {',source.indexOf('// Page style cohorts:'));
const end=source.indexOf('    // One plate colour per lettering unit.',start),block=source.slice(start,end);
function box(a){a??=[0,0,0,0];return {left:a[0],top:a[1],right:a[0]+a[2],bottom:a[1]+a[3],width:a[2],height:a[3]}}
const css=c=>c?'rgb('+c.join(',')+')':'';
function run(job){
 if(job.backing){const j=job.backing,ink=box(j.ink),panels=(j.panels??[]).map(p=>({style:{backgroundColor:css(p.color)},getBoundingClientRect(){return box(p.rect)}}));
  const node={dataset:{sourcePanelSurfaceLuminance:JSON.stringify(j.fallback)}};
  const item={};const c={frame:j.frame,x:j.origin[0],y:j.origin[1],sx:j.scale[0],sy:j.scale[1],iw:j.image[0],ih:j.image[1],w:j.width,h:j.height,canvas:{isConnected:j.connected!==false},luminance:j.fractional?j.luminance:new Uint8Array(j.luminance)};
  const context={panelsS:panels,panelStatesS:new Map(),restoredPanelGeometry:new Map([[item,c]]),backingBudgetS:j.budget??600000,Uint8Array,Int32Array,parseS:text=>text?text.match(/[0-9.]+/g).map(Number).slice(0,3):null,aidokuSourceColorLuminance:rgb=>rgb.reduce((s,v,i)=>s+(v/255<=.04045?v/255/12.92:((v/255+.055)/1.055)**2.4)*[.2126,.7152,.0722][i],0),item,node,ink};
  const begin=block.indexOf('      const restoredBackingS='),end=block.indexOf('      const members=[];',begin);
  vm.createContext(context);vm.runInContext(block.slice(begin,end)+'globalThis.answer=restoredBackingS(item,node,ink);',context);
  return {name:job.name,range:context.answer,budget:context.backingBudgetS};
 }

 const root={dataset:{},querySelectorAll(type){return type.includes('source-readability-backing')?[]:type.includes('source-readability-panel')?panels:nodes}};
 const panels=[],nodes=job.members.map(m=>({m,dataset:{aidokuRegion:m.id,sourceSampledTextRGB:css(m.sampled),sourceSampledStrokeRGB:css(m.sampledStroke),sourceSampledBackgroundRGB:css(m.sampledBack),sourceStrokeConfidence:String(m.strokeConfidence??1),sourceStrokeColor:m.strokeSource??'',sourceBackgroundColor:m.plate?(m.ownerIsNode?'rotated-panel':'readability-panel'):'inpainted',outlinedLettering:JSON.stringify({kind:m.ringKind,action:m.ringAction,core:m.ringCore,surface:m.ringSurface,...(m.ringPlateTo?{plateTo:[1,1,1]}:{})}),...(m.locked?{displayLettering:'true'}:{}),sourcePanelSurfaceLuminance:JSON.stringify(m.backing)},style:{visibility:'visible',fontSize:(m.font??10)+'px',color:css(m.fill),webkitTextStrokeWidth:m.stroke?'1px':'0px',webkitTextStrokeColor:css(m.stroke),backgroundColor:css(m.plate),textShadow:'none'},textContent:'test',getBoundingClientRect(){return box(m.ink)}}));
 for(const node of nodes){const m=node.m;node.parentElement=root;if(m.plate&&!m.ownerIsNode){const owner={dataset:{aidokuRegion:m.id,aidokuImageOcrOverlay:'source-readability-panel'},style:{backgroundColor:css(m.plate)},getBoundingClientRect(){return box(m.ownerRect??m.ink)},querySelectorAll(){return m.ownerAlone===false?[node,node]:[node]}};node.parentElement=owner;panels.push(owner)}}
 const items=nodes.map(n=>({id:n.m.id,sourceColorEligible:true,sourceFontSize:n.m.glyph}));
 const context={root,items,opacity:1,appearance:{preserveSourceTextColor:true,preserveSourceBackgroundColor:true},restoredPanelGeometry:new Map(),rotatedPlates:[],getComputedStyle:n=>n.style,document:{createRange(){let node;return {selectNodeContents(n){node=n},getBoundingClientRect(){return node.getBoundingClientRect()}}}},performance:{now(){return 0}},aidokuSourceColorLuminance:rgb=>rgb.reduce((sum,v,i)=>{const s=v/255;return sum+(s<=.04045?s/12.92:Math.pow((s+.055)/1.055,2.4))*[.2126,.7152,.0722][i]},0)};
 vm.createContext(context);vm.runInContext(block,context);if(root.dataset.styleCohortError)throw Error(root.dataset.styleCohortError);
 const decisions=nodes.filter(n=>n.dataset.styleCohort).map(n=>{const r=JSON.parse(n.dataset.styleCohort);return {id:n.m.id,fill:r.fill?.[1]??null,plate:r.plate?.[1]??null,dropStroke:!!r.stroke,minimumContrast:Number(n.dataset.sourceFinalMinimumContrast)}});
 return {name:job.name,decisions};
}
fs.writeFileSync(process.argv[4],JSON.stringify(JSON.parse(fs.readFileSync(process.argv[3],'utf8')).map(run)));
