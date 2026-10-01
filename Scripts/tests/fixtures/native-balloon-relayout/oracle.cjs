const fs=require('fs'),vm=require('vm'),base=process.argv[3];
const view=fs.readFileSync(base+'/BrowserOverlayView.swift','utf8'),typ=fs.readFileSync(base+'/BrowserOverlayTypography.swift','utf8');
const relayout=view.slice(view.indexOf('    const relayoutInBalloon='),view.indexOf('    const typographyByID=',view.indexOf('    const relayoutInBalloon='))).replaceAll('\\\\','\\');
const unitInterior=view.slice(view.indexOf("    const nativeUnitInterior=item=>"),view.indexOf("    // Joined units whose erasure left",view.indexOf("    const nativeUnitInterior=item=>")));
const growth=typ.slice(typ.indexOf('    const aidokuGrowthKeepsLineLength ='),typ.indexOf('    // Line-flow defects',typ.indexOf('    const aidokuGrowthKeepsLineLength =')));
const box=v=>({left:v[0],top:v[1],right:v[0]+v[2],bottom:v[1]+v[3],width:v[2],height:v[3]});
function shape(text,c){const advance=c.font*.55,limit=Math.max(1,Math.floor(c.rect[2]/advance)),rows=[[]];let split=false;
 const words=[...text.matchAll(/[^ ]+/g)];
 for(const word of words){let row=rows[rows.length-1];if(row.length&&row.length+1+word[0].length>limit){rows.push([]);row=rows[rows.length-1];}else if(row.length)row.push(-1);
  for(let j=0;j<word[0].length;j++){if(row.length>=limit){rows.push([]);row=rows[rows.length-1];split=true;}row.push(word.index+j);}}
 const height=(rows.length-1)*c.pitch+c.font,width=Math.max(...rows.map(r=>r.length))*advance,top=c.rect[1]+c.rect[3]/2-height/2,chars={};
 rows.forEach((r,y)=>r.forEach((index,x)=>{if(index>=0)chars[index]=box([c.rect[0]+c.rect[2]/2-r.length*advance/2+x*advance,top+y*c.pitch,advance,c.font]);}));
 return {ink:box([c.rect[0]+c.rect[2]/2-width/2,top,width,height]),chars,width};}
const output=JSON.parse(fs.readFileSync(process.argv[2])).map(f=>{
 const style={fontSize:f.font+'px',lineHeight:f.pitch+'px',left:f.box[0]+'px',top:f.box[1]+'px',width:f.box[2]+'px',height:f.box[3]+'px',visibility:f.visible===false?'hidden':'visible'};
 Object.defineProperty(style,'cssText',{get(){return JSON.stringify({...style});},set(v){Object.assign(style,JSON.parse(v));},enumerable:false});
 const node={style,dataset:{},textContent:f.rendered??f.text,get childNodes(){return [{data:this.textContent}];},replaceChildren(...cs){this.textContent=cs.map(x=>x.data).join('');},get clientWidth(){return parseFloat(style.width);},get scrollWidth(){return this._shape().width;},_shape(){return shape(this.textContent,{rect:[parseFloat(style.left),parseFloat(style.top),parseFloat(style.width),parseFloat(style.height)],font:parseFloat(style.fontSize),pitch:parseFloat(style.lineHeight)});}};
 const item={text:f.text,vertical:f.vertical||false,rotation:f.rotation||0,balancedColumn:f.balanced||false,wrappingScript:f.script||'korean'},foreign=(f.foreign||[]).map(r=>({style:{visibility:'visible'},_rect:box(r)}));
 let interior=f.interior===false?null:{tight:f.tight||false,outside:r=>{const c=box(f.contour),w=Math.max(0,Math.min(r.right,c.right)-Math.max(r.left,c.left)),h=Math.max(0,Math.min(r.bottom,c.bottom)-Math.max(r.top,c.top));return (r.right-r.left)*(r.bottom-r.top)-w*h;}};
 let probes=0;
 const c={items:[item],keptItems:[],root:{querySelectorAll:()=>[node,...foreign]},unitMembersOf:()=>f.unit?[{}]:null,unitResidueRisk:new Set(),balloonInteriorOf:()=>interior,sourceRectOf:()=>f.source?box(f.source):null,balloonRectsOf:()=>f.source?[box(f.source)]:[],cleanupImageGeometry:{frame:f.frame||null},cachedSourceSample:()=>({background:f.paper}),scrollX:0,scrollY:0,NodeFilter:{SHOW_TEXT:4},document:{createTreeWalker:n=>{let used=false;return {nextNode:()=>used?null:(used=true,{data:n.textContent})};},createRange:()=>({selectNodeContents(n){this.node=n;this.start=null;},setStart(n,s){this.start=s;},setEnd(n,e){this.end=e;},getBoundingClientRect(){if(this.start!==null&&this.start!==undefined)return node._shape().chars[this.start]||box([0,0,0,0]);if(this.node===node){probes++;return node._shape().ink;}return this.node._rect;}})}};
 vm.createContext(c);vm.runInContext(unitInterior+growth+relayout+'\nglobalThis.relayout=relayoutInBalloon;globalThis.nativeInterior=nativeUnitInterior;',c);
 let interiorValue=null;
 if(f.nativeRect){item.balloonInterior={rect:f.nativeRect,spans:f.spans};interior=c.nativeInterior(item);if(interior)interiorValue={width:interior.w,height:interior.h,scale:interior.k,fill:Array.from(interior.fill),paper:interior.surfaceRGB,outside:f.queries.map(q=>interior.outside(box(q)))};}

 const r=c.relayout(item,node,box(f.ink));let result=null;
 if(r)result={rect:[parseFloat(style.left),parseFloat(style.top),parseFloat(style.width),parseFloat(style.height)],font:parseFloat(style.fontSize),pitch:parseFloat(style.lineHeight),ink:[r.ink.left,r.ink.top,r.ink.width,r.ink.height],diagnostics:JSON.parse(node.dataset.balloonInteriorLayout)};
 return {name:f.name,result,probes,interior:interiorValue};
});fs.writeFileSync(process.argv[4],JSON.stringify(output));
