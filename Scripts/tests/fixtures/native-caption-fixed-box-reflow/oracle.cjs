const fs=require('fs'),path=require('path');const raw=fs.readFileSync(path.join(process.argv[3],'BrowserOverlayView.swift'),'utf8');
const start=raw.indexOf('        captionTextReflows.set(item, (box, pad) => {'),end=raw.indexOf('        if (item.sourceColorEligible',start);const source=raw.slice(start,end).replaceAll('\\\\','\\');
const rect=a=>({left:a[0],top:a[1],width:a[2],height:a[3],right:a[0]+a[2],bottom:a[1]+a[3]});
function run(f){const displayedText=f.text??'가나다 라마바',preserveOriginalBackground=f.preserve??true,opacity=f.opacity??1,vertical=f.vertical??false,wrappingScript=f.script??'korean';let captionReflowCharacterBudget=f.budget??8192,x=f.x??110,width=f.width??50;
 const item={allowsAutomaticFontRecovery:f.automatic??true},node={style:{padding:'5px',paddingLeft:(f.left??5)+'px',paddingRight:(f.right??5)+'px'},dataset:{}},measurementNode={style:{},remove(){}};
 const others=(f.others||[]).map(a=>({getBoundingClientRect:()=>rect(a)}));const root={appendChild(){},querySelectorAll:()=>[node,...others]},getComputedStyle=n=>n.style,captionTextReflows=new Map(),scrollX=0;
 let at=-1,calls=[];const p=d=>d?{lines:d.lines,breaks:d.breaks||[],badStarts:d.starts||[],badEnds:d.ends||[],hangulIsolated:d.isolated||0,punctuationOnly:d.punctuation||0,ink:d.ink||[]}:null;
 const lineProfile=()=>{if(at++===-1)return p(f.baseline);calls.push([x,width]);return p(f.probes[Math.min(at-1,f.probes.length-1)].profile);};const contentFits=()=>f.probes[Math.min(at-1,f.probes.length-1)].fits!==false;
 eval(source);captionTextReflows.get(item)(rect(f.panel||[100,100,120,100]),f.pad??5);
 const accepted=!!node.dataset.captionReflow,v={name:f.name,accepted,budget:captionReflowCharacterBudget,calls};if(accepted)Object.assign(v,{x,width,originalWidth:Number(node.dataset.captionOriginalWidth),originalLines:Number(node.dataset.captionOriginalLines),finalLines:Number(node.dataset.captionFinalLines)});return v;}
fs.writeFileSync(process.argv[4],JSON.stringify(JSON.parse(fs.readFileSync(process.argv[2])).map(run)));
