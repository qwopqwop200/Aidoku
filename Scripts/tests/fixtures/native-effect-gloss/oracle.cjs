// Runs the actual frozen final DOM pass with a deterministic native-fixture text
// measurement surface. No grouping, admission or placement policy is rewritten.
const fs=require('fs'),vm=require('vm'),base=process.argv[3];
const typography=fs.readFileSync(base+'/BrowserOverlayTypography.swift','utf8');
const helper=typography.slice(typography.indexOf('    const aidokuSubtractRects ='),typography.indexOf('    // Complete-link clusters'));
const color=fs.readFileSync(base+'/BrowserSourceTextColor.swift','utf8');
const colors=color.slice(color.indexOf('    const aidokuSourceColorLuminance ='),color.indexOf('    // Keep an already readable color.'));
const view=fs.readFileSync(base+'/BrowserOverlayView.swift','utf8');
const start=view.indexOf('    const effectZones=[];'),end=view.indexOf('    // Recovered lines (payload',start);
const policy=view.slice(start,end).replaceAll('\\\\n','\\n').replaceAll('\\\\1','\\1');
const rect=(x,y,w,h)=>({left:x,top:y,width:w,height:h,right:x+w,bottom:y+h});
const inputs=JSON.parse(fs.readFileSync(process.argv[2]));
const output=inputs.map(f=>{
 const children=[],nodes=[];
 const root={children,dataset:{},querySelectorAll(){return nodes},appendChild(n){if(n.parentElement)n.remove();children.push(n);n.parentElement=this},insertBefore(n,next){if(n.parentElement)n.remove();const at=children.indexOf(next);children.splice(at<0?children.length:at,0,n);n.parentElement=this}};
 function node(r,plate=null){
  const n={dataset:{aidokuRegion:r.id,aidokuImageOcrOverlay:plate?'source-readability-panel':'item'},style:{},parentElement:root,childNodes:[],nextSibling:null,contains(){return false},remove(){const at=children.indexOf(this);if(at>=0)children.splice(at,1);this.parentElement=null},replaceChildren(...values){this.textContent=values.join('')},getBoundingClientRect(){return plate?rect(...plate.rect):measure(this)}};
  Object.defineProperty(n,'textContent',{get(){return this.childNodes.join('')},set(v){this.childNodes=[v]}});
  Object.defineProperty(n.style,'cssText',{get(){return JSON.stringify({...this})},set(v){for(const k of Object.keys(this))delete this[k];Object.assign(this,JSON.parse(v))}});
  if(plate){n.style.backgroundColor=`rgb(${plate.colour.join(',')})`;if(plate.opaque===false)n.style.display='none';}
  else {Object.assign(n.style,{fontSize:r.fontSize+'px',left:r.ink[0]+'px',top:r.ink[1]+'px',width:r.ink[2]+'px',lineHeight:r.fontSize*1.2+'px',visibility:r.hidden?'hidden':'visible'});n.textContent=r.text;
   if(r.fill)n.dataset.sourceSampledTextRGB=r.fill.join(',');if(r.stroke)n.dataset.sourceSampledStrokeRGB=r.stroke.join(',');if(r.background)n.dataset.sourceSampledBackgroundRGB=r.background.join(',');if(r.preservedGloss)n.dataset.sourcePreservedGloss='true';}
  children.push(n);return n;
 }
 function measure(n){
  const size=parseFloat(n.style.fontSize),width=parseFloat(n.style.width),lh=parseFloat(n.style.lineHeight),natural=n.textContent.length*size*.53,lines=Math.max(1,Math.ceil(natural/width)),tw=Math.min(width,natural);
  let result=rect(parseFloat(n.style.left)+(width-tw)/2,parseFloat(n.style.top)+size*.08,tw,lines*lh*.82);
  if(n.style.transform&&n.style.transform!=='none'){
   const a=parseFloat(n.style.transform.slice(7)),o=n.style.transformOrigin.split(' ').map(parseFloat),cx=parseFloat(n.style.left)+o[0],cy=parseFloat(n.style.top)+o[1],pts=[];
   for(const [x,y] of [[result.left,result.top],[result.right,result.top],[result.right,result.bottom],[result.left,result.bottom]])pts.push([cx+(x-cx)*Math.cos(a)-(y-cy)*Math.sin(a),cy+(x-cx)*Math.sin(a)+(y-cy)*Math.cos(a)]);
   const xs=pts.map(p=>p[0]),ys=pts.map(p=>p[1]);result=rect(Math.min(...xs),Math.min(...ys),Math.max(...xs)-Math.min(...xs),Math.max(...ys)-Math.min(...ys));
  }return result;
 }
 const frame=f.frame,items=f.records.map(r=>{const s=r.source,n=node(r);nodes.push(n);for(const p of r.plates||[])node(r,p);
  return {id:r.id,sourceLettering:r.role,sourceBounds:[(s[0]-frame[0])/frame[2],(s[1]-frame[1])/frame[3],s[2]/frame[2],s[3]/frame[3]],sourceFontSize:r.glyph,sourceVertical:r.vertical||false,balloonInterior:r.balloon?{}:null,
   sourceQuad:r.quad?[(r.quad[0]-frame[0])/frame[2],(r.quad[1]-frame[1])/frame[3],r.quad[2]/frame[2],r.quad[3]/frame[2],r.quad[4]]:null,
   auxiliaryInkRects:(r.auxiliary||[]).map(s=>[(s[0]-frame[0])/frame[2],(s[1]-frame[1])/frame[3],s[2]/frame[2],s[3]/frame[3]])};});
 const geometry=new Map(items.filter((_,i)=>f.records[i].glyphReplacement).map(i=>[i,{method:'chromatic-balloon-glyphs',sourceGlyphsVerified:true}]));
 const document={createElement(){const canvas={width:0,height:0};canvas.getContext=()=>({drawImage(){},getImageData(){return {data:new Uint8ClampedArray(canvas.width*canvas.height*4).fill(255)}}});return canvas;},createRange(){return {selectNodeContents(n){this.node=n},getBoundingClientRect(){return measure(this.node)}}}};
 const c={root,items,keptItems:[],sourceImage:{complete:true,naturalWidth:1,naturalHeight:1},cleanupImageGeometry:{frame},opacity:1,inpaintingEnabled:f.inpainting||false,restoredPanelGeometry:geometry,slantedSourcePanels:new Map(),scrollX:0,scrollY:0,performance:{now:()=>0},document,getComputedStyle:n=>n.style};
 vm.createContext(c);vm.runInContext(helper+colors+policy+'\nglobalThis.zones=effectZones;',c);
 if(root.dataset.effectGlossError)throw Error(root.dataset.effectGlossError);
 const notes=nodes.filter(n=>n.dataset.effectGloss).map(n=>{const p=JSON.parse(n.dataset.effectGloss);return {id:n.dataset.aidokuRegion,text:n.textContent,size:p.size,width:parseFloat(n.style.width),lh:parseFloat(n.style.lineHeight),side:p.side,rank:p.rank,angle:n.style.transform&&n.style.transform!=='none'?parseFloat(n.style.transform.slice(7)):0,left:parseFloat(n.style.left),top:parseFloat(n.style.top),fill:n.dataset.sourceAppliedTextRGB.split(',').map(Number),outline:n.dataset.sourceAppliedStrokeRGB.split(',').map(Number),stroke:parseFloat(n.style.webkitTextStrokeWidth),members:p.members,unit:p.unit,anchor:p.anchor}});
 const rejected={};for(const n of nodes){if(n.dataset.effectGlossReject)rejected[n.dataset.aidokuRegion]=n.dataset.effectGlossReject;if(n.dataset.effectGlossRejected)rejected[n.dataset.aidokuRegion]='placement';}
 return {name:f.name,notes,hidden:nodes.filter(n=>n.dataset.effectGlossJoined).map(n=>n.dataset.aidokuRegion).sort(),removed:nodes.filter(n=>n.dataset.sourceErasurePreserved==='effect-gloss').map(n=>n.dataset.aidokuRegion).sort(),zones:c.zones.map(z=>({id:z.id,rect:[z.left,z.top,z.right-z.left,z.bottom-z.top]})),rejected,units:Number(root.dataset.effectGlosses||0)};
});fs.writeFileSync(process.argv[4],JSON.stringify(output));
