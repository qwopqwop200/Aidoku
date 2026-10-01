const fs=require('fs'),path=require('path'),[root,out]=process.argv.slice(2);
const s=fs.readFileSync(path.join(root,'Scripts/native-render-parity/reference-source/BrowserOverlayView.swift'),'utf8');
const a=s.indexOf('        const layout=[source[0]-glyph*.15',s.indexOf('      const nodesD=')),end=s.indexOf('        if(!accepted){',a);
const body=s.slice(a,end);
const sl=fs.readFileSync(path.join(root,'Scripts/native-render-parity/reference-source/BrowserOverlayTypography.swift'),'utf8');
const all=fs.readdirSync(path.join(root,'Scripts/native-render-parity/reference-source')).map(p=>fs.readFileSync(path.join(root,'Scripts/native-render-parity/reference-source',p),'utf8')).join('\n');
const ga=all.indexOf('const aidokuGrowthKeepsLineLength =');
let gi=all.indexOf('{',ga),depth=1;for(gi++;depth;gi++){if(all[gi]==='{')depth++;else if(all[gi]==='}')depth--;}
const growth=all.slice(ga,gi)+';';
if(ga<0)throw Error('missinggrowth');
const rect=r=>({left:r[0],top:r[1],right:r[0]+r[2],bottom:r[1]+r[3],width:r[2],height:r[3]});
const policy=new Function('f','rect',growth+`const source=f.source,displayFrame=f.frame,glyph=f.glyph,current=f.current,ratio=f.ratio||1.2,priorInk=rect(f.priorInk),others=f.others.map(rect),item={text:f.text};const measurements=[];let final=null;
const node={style:{},set textContent(x){}};
function measurement(){const z=node.style,size=parseFloat(z.fontSize),inset=parseFloat(z.padding),l=parseFloat(z.left),t=parseFloat(z.top),width=parseFloat(z.width),height=parseFloat(z.height);const longest=f.wordFactor*size;const lines=f.lines;return {ink:[l+inset+f.shift,t+inset+1,Math.max(1,Math.min(longest,width-2*inset-2)),size*ratio*lines],longestWord:longest,contentFits:size<=f.fitsThrough};}
Object.defineProperties(node,{scrollWidth:{get(){return measurement().contentFits?100:104;}},clientWidth:{get(){return 100;}},scrollHeight:{get(){return 100;}},clientHeight:{get(){return 100;}}});
const getComputedStyle=()=>{const m=measurement();measurements.push({...m,probe:{rect:[parseFloat(node.style.left),parseFloat(node.style.top),parseFloat(node.style.width),parseFloat(node.style.height)],size:parseFloat(node.style.fontSize),strokeWidth:Math.min(8,Math.max(2,parseFloat(node.style.fontSize)*.16)),inset:parseFloat(node.style.padding),lineHeight:parseFloat(node.style.lineHeight)}});return {fontWeight:'700',fontFamily:'test'};};const inkRect=()=>rect(measurement().ink),root={appendChild(){}},scrollX=0,scrollY=0,document={createElement:()=>({getContext:()=>({measureText:()=>({width:measurement().longestWord})})})};`+body+`return {accepted:accepted?{...measurements.find(m=>m.probe.size===accepted.size).probe,ink:measurements.find(m=>m.probe.size===accepted.size).ink}:null,measurements};`);
const fixtures=[];
for(let seed=0;seed<100;seed++){
 const f={seed,text:seed%7===0?'긴문장검증글자각각열두자':'TEST',source:[20,30,80,65],frame:seed%4===0?[25,25,65,90]:null,glyph:seed%9===0?60:36,current:seed%11===0?12:16,ratio:seed%13===0?0:1.2,priorInk:[25,35,35,20],others:seed%5===0?[[40,45,20,25]]:[],wordFactor:seed%6===0?6:1.6,shift:seed%8===0?-2:1,lines:seed%10===0?4:1,fitsThrough:seed%3===0?24:100};
 const r=policy(f,rect);f.measurements=r.measurements;f.expected=r.accepted;fixtures.push(f);
}
fs.writeFileSync(out,JSON.stringify(fixtures));console.log(JSON.stringify({cases:fixtures.length,positive:fixtures.filter(f=>f.expected).length}));
