const fs=require('fs'),path=require('path');
const fixtures=JSON.parse(fs.readFileSync(process.argv[2]));
const raw=fs.readFileSync(path.join(process.argv[3],'BrowserOverlayView.swift'),'utf8');
const start=raw.indexOf('    if(opacity===1&&items.length<=256)try {',raw.indexOf('// A joined unit'));
const end=raw.indexOf('    // The readable floor',start);
const body=raw.slice(start,end).replaceAll('\\\\','\\');
const box=r=>({left:r[0],top:r[1],width:r[2],height:r[3],right:r[0]+r[2],bottom:r[1]+r[3]});
const array=r=>[r.left,r.top,r.width,r.height];
const union=rs=>{const l=Math.min(...rs.map(r=>r.left)),t=Math.min(...rs.map(r=>r.top)),r=Math.max(...rs.map(r=>r.right)),b=Math.max(...rs.map(r=>r.bottom));return box([l,t,r-l,b-t]);};
function run(f){
 let root={dataset:{},style:{},getBoundingClientRect:()=>box([0,0,500,500])};
 function element(){
  const n={dataset:{},style:{},childNodes:[],parentElement:null,_text:'',remove(){this.parentElement.childNodes=this.parentElement.childNodes.filter(c=>c!==this);},appendChild(c){c.parentElement=this;this.childNodes.push(c);},replaceChildren(...c){this.childNodes=c;c.forEach(v=>v.parentElement=this);this._text='';},getBoundingClientRect(){let l=parseFloat(this.style.left)||0,t=parseFloat(this.style.top)||0,w=parseFloat(this.style.width)||0,h=parseFloat(this.style.height)||0;const p=this.parentElement;if(p&&p!==root){const q=p.getBoundingClientRect();l+=q.left;t+=q.top;}return box([l,t,w,h]);}};
  Object.defineProperty(n,'textContent',{get(){return this.childNodes.length?this.childNodes.map(c=>c.textContent).join(''):this._text},set(v){this._text=v;this.childNodes=[];}});
  return n;
 }
 const panel=element();panel.dataset.aidokuImageOcrOverlay='source-readability-panel';const pb=f.panel||[0,0,500,500];Object.assign(panel.style,{left:pb[0]+'px',top:pb[1]+'px',width:pb[2]+'px',height:pb[3]+'px'});panel.parentElement=root;if(f.coverage)panel.dataset.panelCoverage=JSON.stringify(f.coverage);
 const node=element();node.dataset.aidokuRegion='a';node.textContent=f.text;node.parentElement=f.root?root:panel;
 Object.assign(node.style,{left:'0px',top:'0px',width:'500px',height:'500px',fontSize:f.font+'px',lineHeight:f.font*1.2+'px',transform:'none'});
 const item={id:'a',text:f.text,unitMemberRects:f.members.map(r=>r.map(v=>v/500)),rotation:0,vertical:false};
 const foreign=(f.others||[]).map((r,i)=>{const n=element();n.dataset.aidokuRegion='other'+i;n.parentElement=root;n.fixed=box(r);return n;});
 root.querySelectorAll=()=>[node,...foreign];
 function lines(n){if(n.fixed)return [n.fixed];if(n===node)return n.childNodes.flatMap(lines);const r=n.getBoundingClientRect(),font=parseFloat(n.style.fontSize),pitch=parseFloat(n.style.lineHeight),adv=font*.5,words=n.textContent.trim().split(/ +/),rows=[];let row='';for(const word of words){const next=row?row+' '+word:word;if(row&&next.length*adv>r.width){rows.push(row);row=word;}else row=next;}if(row)rows.push(row);return rows.map((s,i)=>box([r.left+r.width/2-s.length*adv/2,r.top+r.height/2-rows.length*pitch/2+i*pitch+(pitch-font)/2,s.length*adv,font]));}
 const document={createElement:()=>{const n=element();Object.defineProperties(n,{clientWidth:{get(){return this.getBoundingClientRect().width}},scrollWidth:{get(){const font=parseFloat(this.style.fontSize),longest=Math.max(...this.textContent.trim().split(/ +/).map(w=>w.length*font*.5));return Math.max(this.clientWidth,longest)}}});return n;},createRange(){let n;return {selectNodeContents(v){n=v},getClientRects(){return lines(n)},getBoundingClientRect(){return union(lines(n))},setStart(t,i){n=t.owner;this.at=i},setEnd(){}};},createTreeWalker(n){let used=false;return {nextNode(){if(used)return null;used=true;return {data:n.textContent,owner:n}}};}};
 const inside=box(f.interior),balloonInteriorOf=()=>({w:f.span||400,k:1,outside(r){const w=Math.max(0,Math.min(r.right,inside.right)-Math.max(r.left,inside.left)),h=Math.max(0,Math.min(r.bottom,inside.bottom)-Math.max(r.top,inside.top));return (r.right-r.left)*(r.bottom-r.top)-w*h;}});
 const unitMembersOf=i=>i.unitMemberRects,balloonRectsOf=()=>[],unitResidueRisk=new Set(),items=[item],keptItems=[],opacity=1,cleanupImageGeometry={frame:[0,0,500,500]},NodeFilter={SHOW_TEXT:1},performance={now:()=>0},aidokuRebaseCoverageClip=()=>{};
 eval(body);
 const accepted=!!node.dataset.unitParts,v={name:f.name,accepted};
 if(accepted){const mark=JSON.parse(node.dataset.unitParts);Object.assign(v,{font:mark[1],from:mark[0],first:mark[2],parts:node.childNodes.map(n=>({text:n.textContent,frame:array(n.getBoundingClientRect()),ink:array(union(lines(n)))})),panel:f.root?[]:array(panel.getBoundingClientRect()),coverage:f.root?(f.coverage||[]):JSON.parse(panel.dataset.panelCoverage)});}
 return v;
}
fs.writeFileSync(process.argv[4],JSON.stringify(fixtures.map(run)));
