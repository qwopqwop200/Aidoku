const fs=require('fs'),path=require('path');
const root=process.argv[2],out=process.argv[3],source=fs.readFileSync(path.join(root,'Scripts/native-render-parity/reference-source/BrowserOverlayView.swift'),'utf8');
const a=source.indexOf('    // Lettering at a page edge'),b=source.indexOf('    // Paragraphs, lists, profiles',a);if(a<0||b<a)throw Error('frozen edge missing');
const body=source.slice(a,b);
const run=new Function('c',`
const box=a=>({left:a[0],top:a[1],width:a[2],height:a[3],right:a[0]+a[2],bottom:a[1]+a[3]});
const node={dataset:{aidokuRegion:'x'},style:{fontSize:c.font+'px',lineHeight:c.pitch+'px',left:'0px',top:'0px'},parentElement:{dataset:{aidokuImageOcrOverlay:c.plated?'source-readability-panel':'root'}}};
const root={dataset:{},querySelectorAll:()=>[node]},items=[{id:'x',allowsAutomaticFontRecovery:c.resize}],cleanupImageGeometry={frame:c.frame};
const trace=[];
const document={createRange:()=>({selectNodeContents(){},getBoundingClientRect(){const font=parseFloat(node.style.fontSize),factor=font/c.font,pitch=parseFloat(node.style.lineHeight),w=c.ink[2]*factor,h=c.ink[3]*factor;const r=font===c.font?c.ink:[c.ink[0]+(c.center?(c.ink[2]-w)/2:0),c.ink[1]+(c.center?(c.ink[3]-h)/2:0),w,h];if(font!==c.font)trace.push({font,pitch,ink:r});return box(r);}})};
${body}
return {result:node.dataset.edgeFit?{font:parseFloat(node.style.fontSize),pitch:parseFloat(node.style.lineHeight),shift:[parseFloat(node.style.left),parseFloat(node.style.top)],outcome:node.dataset.edgeFit.split(':')[0]}:null,trace};
`);
const f=[];
for(const font of [6,7,8,9,12,20])for(const plated of [false,true])for(const resize of [false,true])for(const center of [false,true])for(const ink of [[-.74,30,40,20],[-5,30,40,20],[-30,30,60,20],[70,30,60,20],[0,-35,40,60],[0,90,40,30],[0,0,150,150],[20,30,40,20]]){
 const input={font,pitch:font*1.2,plated,resize,center,ink,frame:[0,0,100,100]};f.push({input,expected:run(input)});
}
fs.writeFileSync(out,JSON.stringify(f));console.log(JSON.stringify({cases:f.length,outcomes:f.reduce((o,x)=>{const k=x.expected.result?.outcome||'none';o[k]=(o[k]||0)+1;return o;},{})}));
