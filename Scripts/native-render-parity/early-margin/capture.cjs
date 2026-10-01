const fs=require('fs'),text=fs.readFileSync(process.argv[2],'utf8');const helper=text.slice(text.indexOf('        const certifyOccludedExterior='),text.indexOf('        // Certify each card'));
const group=text.slice(text.indexOf('        const groupPixels=new Map();'),text.indexOf('        // Preserve all ordinary and already-shared certificates'));
const raw=JSON.parse(fs.readFileSync(process.argv[3],'utf8'));
const run=new Function('f',`const conv=x=>{const c={id:x.id,w:x.w,h:x.h,iw:x.imageSize[0],ih:x.imageSize[1],frame:x.frame,x:x.origin[0],y:x.origin[1],sx:x.scale[0],sy:x.scale[1],safe:new Uint8Array(x.safe),luminance:new Uint8Array(x.luminance),sourceErasureVerified:x.verified,erasureComplete:x.complete,provisional:x.provisional,surfaceRevision:x.revision};c.canvas={isConnected:x.connected,width:x.w,height:x.h,getContext:()=>({getImageData:()=>({data:new Uint8ClampedArray(x.rgba)})}),rootOwned:x.rootOwned};return c;};
const c=conv(f.canvas);let exteriorProofBudget=f.budget;
if(f.op==='exterior'){${helper}const result=certifyOccludedExterior(c,f.core,f.glyph);return {id:f.id,result:result?{safe:Array.from(result.safe),ignored:result.ignored,components:result.components}:null,budget:exteriorProofBudget};}
let certificationBudget=f.budget,artworkSurfaceBudget=0;const item={id:'A',sourceVertical:false},node={dataset:{}},id='A',coverage=[],regions=[],core=[],glyph=8;
const erasureRetries=[{item,c,id,node,coverage,regions,core,glyph}];if(f.repeat)erasureRetries.push(erasureRetries[0]);const restoredPanelGeometry=new Map(f.donors.map(d=>[{id:d.id},d.id===c.id?c:conv(d)])),root={contains:x=>x.rootOwned};const budgetStop=()=>true;
const aidokuHasAttachedLeadingInk=()=>false,aidokuHasResidualLettering=()=>true,aidokuRestoredErasureCovers=()=>false,certifiedErasure=new Set();
${group}
return {id:f.id,result:node.dataset.sourceErasureGroupPixels?{safe:Array.from(c.safe),luminance:Array.from(c.luminance),added:Number(node.dataset.sourceErasureGroupPixels),revision:c.surfaceRevision}:null,budget:certificationBudget,cache:Array.from(groupPixels.keys()).map(d=>d.id)};`);
fs.writeFileSync(process.argv[4],JSON.stringify(raw.map(run)));
