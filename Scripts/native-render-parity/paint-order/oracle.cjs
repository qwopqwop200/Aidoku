const fs=require('fs'),vm=require('vm');
const rows=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const source=fs.readFileSync(process.argv[3],'utf8');
const start=source.indexOf('      const paintOrderStarted=performance.now();');
const end=source.indexOf('    root.dataset.readabilityPanels=',start);
const block=source.slice(start,end).replace(/\n    }\s*$/,'');
function run(row) {
 const root={dataset:{},children:[]};
 const map=new Map(row.layers.map(l=>[l.id,{...l,parentElement:root,style:{zIndex:String(l.z)},dataset:{aidokuImageOcrOverlay:l.kind,aidokuRegion:l.owner||l.id},offsetParent:null,offsetLeft:l.quad[0][0],offsetTop:l.quad[0][1],offsetWidth:l.quad[1][0]-l.quad[0][0],offsetHeight:l.quad[3][1]-l.quad[0][1]}]));
 root.children=[...map.values()].sort((a,b)=>a.order-b.order);
 root.insertBefore=(a,b)=>{root.children.splice(root.children.indexOf(a),1);let i=b?root.children.indexOf(b):-1;root.children.splice(i<0?root.children.length:i,0,a)};
 for (const l of map.values()) {
  if(l.coverage.length)l.dataset.panelCoverage=JSON.stringify(l.coverage);
  l.getBoundingClientRect=()=>{let q=l.quad;return {left:q[0][0],top:q[0][1],width:q[1][0]-q[0][0],height:q[3][1]-q[0][1]}};
  l.compareDocumentPosition=b=>root.children.indexOf(b)>root.children.indexOf(l)?4:2;
  Object.defineProperty(l,'nextSibling',{get:()=>root.children[root.children.indexOf(l)+1]||null});
 }
 const nodes=row.nodes.map(n=>{let o=map.get(n.layerID);Object.assign(o,{node:n,text:{data:'X'.repeat(n.glyphs.length),owner:o}});o.dataset.rotatingPanel=n.rotatingPanel?'true':'false';if(!n.isRoot)o.parentElement={parentElement:root};return o;});
 root.querySelectorAll=q=>q==='[data-aidoku-image-ocr-overlay="item"]'?nodes:[...map.values()].filter(l=>l.kind==='source-readability-panel'||l.kind==='source-readability-backing');
 const getComputedStyle=l=>({zIndex:l.style.zIndex,display:l.shown?'block':'none',visibility:'visible',opacity:1,backgroundImage:l.opaque&&!l.background?'linear-gradient(red,blue)':'none',backgroundColor:l.opaque?`rgb(${(l.background||[240,240,240]).join(',')})`:'rgba(0,0,0,0)',color:l.node?.foreground?`rgb(${l.node.foreground.join(',')})`:'rgba(0,0,0,0)',transform:'none',transformOrigin:'0 0',clipPath:l.coverage.length?'path()':'none'});
 const document={createTreeWalker:n=>{let sent=false;return {nextNode:()=>sent?null:(sent=true,n.text)}},createRange:()=>{let t,index;return {setStart:(text,i)=>{t=text;index=i},setEnd:()=>{},getBoundingClientRect:()=>{let r=t.owner.node.glyphs[index];return{left:r[0],top:r[1],width:r[2],height:r[3]}}}}};
 const ctx={root,items:Array(row.count).fill({}),performance:{now:()=>0},getComputedStyle,document,Node:{DOCUMENT_POSITION_FOLLOWING:4},NodeFilter:{SHOW_TEXT:4},rotatedPlates:[...map.values()].filter(l=>l.kind==='source-rotated-panel'),DOMMatrix:class {transformPoint(p){return p}},DOMPoint:class{constructor(x,y){this.x=x;this.y=y}},aidokuSourceColorLuminance:rgb=>rgb.map((v,i)=>{let x=v/255;return(x<=.04045?x/12.92:Math.pow((x+.055)/1.055,2.4))*[.2126,.7152,.0722][i]}).reduce((a,b)=>a+b,0)};
 if(row.count<=256)vm.runInNewContext(block,ctx);
 return {nodes:nodes.map(n=>({id:n.node.id,lift:n.dataset.paintOrderLift||null})),layers:row.layers.map(l=>({id:l.id,z:Number(map.get(l.id).style.zIndex)})),order:root.children.map(l=>l.id),lifted:Number(root.dataset.paintOrderLifts||0)};
}
process.stdout.write(JSON.stringify(rows.map(run)));
