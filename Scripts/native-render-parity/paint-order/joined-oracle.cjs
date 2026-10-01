const fs=require('fs'),vm=require('vm'),rows=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const source=fs.readFileSync(process.argv[3],'utf8');
const start=source.indexOf('      let contained=0,failed=0;const started=performance.now();',source.indexOf('// Lettering is final. A joined balloon unit'));
const end=source.indexOf('\n    } catch(_) {}',start);
let code=source.slice(start,end).replace(/\\\\/g,'\\');
code=code.replace('const before=outside(', 'const before=globalThis.before=outside(').replace('const partial=container===root', 'const partial=globalThis.partial=container===root').replace('const settled=final.length?', 'const settled=globalThis.after=final.length?');
function run(row) {
 const root={dataset:{}},parent=row.parent?{dataset:{aidokuImageOcrOverlay:'source-readability-panel'},style:{},getBoundingClientRect:()=>({left:row.parent[0],top:row.parent[1],right:row.parent[0]+row.parent[2],bottom:row.parent[1]+row.parent[3],width:row.parent[2],height:row.parent[3]})}:root;
 const values={left:(row.initial[0]-(row.parent?.[0]||0))+'px',top:(row.initial[1]-(row.parent?.[1]||0))+'px',width:row.initial[2]+'px',height:row.initial[3]+'px',fontSize:row.font+'px',lineHeight:row.font*1.2+'px',transform:'none',visibility:'visible'};
 const style=new Proxy(values,{get:(o,k)=>k==='cssText'?JSON.stringify(o):o[k],set:(o,k,v)=>{if(k==='cssText'){for(let p of Object.keys(o))delete o[p];Object.assign(o,JSON.parse(v))}else o[k]=v;return true}});
 const node={style,parentElement:parent,dataset:{aidokuRegion:'one'},textContent:row.text,childNodes:[row.text],replaceChildren:()=>{node.textContent=row.text}};
 function shape(){let f=parseFloat(style.fontSize),p=parseFloat(style.lineHeight),w=parseFloat(style.width),h=parseFloat(style.height),x=parseFloat(style.left)+(row.parent?.[0]||0),y=parseFloat(style.top)+(row.parent?.[1]||0),widths=[],v=0;for(let word of node.textContent.split(' ')){let ww=word.length*f*.55;if(v>0&&v+f*.4+ww>w){widths.push(v);v=ww}else v=v===0?ww:v+f*.4+ww}if(v>0)widths.push(v);let top=y+h/2-widths.length*p/2;return{widths,lines:widths.map((ww,i)=>({left:x+w/2-ww/2,top:top+i*p,right:x+w/2+ww/2,bottom:top+i*p+f,width:ww,height:f}))};}
 Object.defineProperty(node,'scrollWidth',{get:()=>Math.max(parseFloat(style.width),...shape().widths)});Object.defineProperty(node,'clientWidth',{get:()=>parseFloat(style.width)});
 root.querySelectorAll=()=>[node];
 const document={createRange:()=>{let selected=false;return {selectNodeContents:()=>selected=true,getClientRects:()=>shape().lines,setStart:()=>{},setEnd:()=>{},getBoundingClientRect:()=>shape().lines[0]}},createTreeWalker:()=>{let done=false;return{nextNode:()=>done?null:(done=true,{data:node.textContent})}}};
 const outside=r=>{let count=0;for(let y=Math.floor(r.top);y<Math.ceil(r.bottom);y++)for(let x=Math.floor(r.left);x<Math.ceil(r.right);x++)if(x<row.safe[0]||x>=row.safe[0]+row.safe[2]||y<row.safe[1]||y>=row.safe[1]+row.safe[3])count++;return count;};
 const item={id:'one',text:row.text,sourceFontSize:row.sourceFont,balloonInterior:{center:[row.centres[0][0]/100,row.centres[0][1]/100]}};
 const items=[item,...row.obstacles.map(r=>({r}))];
 const ctx={root,items,keptItems:[],opacity:1,scrollX:0,scrollY:0,performance:{now:()=>0},document,NodeFilter:{SHOW_TEXT:4},unitMembersOf:()=>[{}],unitResidueRisk:new Set(),balloonInteriorOf:()=>({native:true,w:row.span,k:1,outside}),cleanupImageGeometry:{frame:[0,0,100,100]},restoredPanelGeometry:new Map([[item,{erasureComplete:row.grow,sourceGlyphsVerified:row.grow}]]),sourceRectOf:()=>{let c=row.centres[1]||row.centres[0];return{left:c[0]-5,right:c[0]+5,top:c[1]-5,bottom:c[1]+5}},balloonRectsOf:o=>o.r?[{left:o.r[0],top:o.r[1],right:o.r[0]+o.r[2],bottom:o.r[1]+o.r[3]}]:[],aidokuRebaseCoverageClip:()=>{}};
 vm.runInNewContext(code,ctx);
 const data=node.dataset.unitContainment?JSON.parse(node.dataset.unitContainment):null,accepted=data&&data[0]!=='kept';
 return {candidate:accepted?{rect:[parseFloat(style.left)+(row.parent?.[0]||0),parseFloat(style.top)+(row.parent?.[1]||0),parseFloat(style.width),parseFloat(style.height)],font:parseFloat(style.fontSize),pitch:parseFloat(style.lineHeight)}:null,before:ctx.before,after:ctx.after??null,partial:ctx.partial??false,searched:!!data};
}
process.stdout.write(JSON.stringify(rows.map(run)));
