const fs=require('fs'),path=require('path'),cp=require('child_process');
const root=path.resolve(__dirname,'../../..'),out=path.join(root,'build/native-render-parity/caption-css-provenance');
const reference=path.join(root,'Scripts/native-render-parity/reference-source/BrowserOverlayView.swift'),source=fs.readFileSync(reference,'utf8');
const records=fs.readFileSync(path.join(out,'tests.log'),'utf8').split('\n').filter(x=>x.startsWith('CSS_PROVENANCE ')).map(x=>JSON.parse(x.slice(15)));
const q=n=>Math.trunc(Math.fround(n)*64)/64,same=(a,b)=>Math.abs(a-b)<1e-10;
const failures=[];let exact=0;
const roomSource=source.match(/Object\.assign\(node\.style,\{left:`\$\{originLeft\+cx-width\/2-origin\.left\}px`,top:`\$\{originTop\+cy-H\/2-origin\.top\}px`,\s*width:`\$\{width\}px`,height:`\$\{H\}px`\}\);/)[0];
const plateSource=source.match(/Object\.assign\(node\.style,\{left:`\$\{originLeft\+P\.left-origin\.left-\(layoutWidth-P\.width\)\/2\}px`,top:`\$\{originTop\+P\.top-origin\.top\}px`,\s*width:`\$\{layoutWidth\}px`,height:`\$\{P\.height\}px`,boxSizing:'border-box'\}\);/)[0];
for(const r of records.filter(x=>x.kind==='plate')){
 const node={style:{}},[px,py]=r.parent,originLeft=r.saved[0]-px,originTop=r.saved[1]-py,origin={left:r.origin[0],top:r.origin[1]};
 const [x,y,width,H]=r.proposal,cx=x+width/2,cy=y+H/2,layoutWidth=width,P={left:x+(width-width*r.scale)/2,top:y,width:width*r.scale,height:H};
 eval(r.room?roomSource:plateSource);
 const left=parseFloat(node.style.left),top=parseFloat(node.style.top),w=parseFloat(node.style.width),h=parseFloat(node.style.height);
 const authored=[px+left,py+top],box=[px+q(left)+q(w)*(1-r.scale)/2,py+q(top),q(w)*r.scale,q(h)],padding=[q(r.padding/r.scale)*r.scale,q(r.padding)];
 const fields=[];for(const [key,value]of[['actualAuthored',authored],['actualBox',box],['actualPadding',padding]])if(!r[key].every((v,i)=>same(v,value[i])))fields.push(key);
 if(fields.length)failures.push({probe:r.probe,fields,expected:{authored,box,padding},actual:r});else exact++;
}
const reflow=records.filter(x=>x.kind==='reflow');
fs.writeFileSync(path.join(out,'raw-reflow-input.json'),JSON.stringify(reflow.map(x=>x.input)));
cp.execFileSync('node',[path.join(root,'Scripts/tests/fixtures/native-caption-fixed-box-reflow/oracle.cjs'),path.join(out,'raw-reflow-input.json'),path.dirname(reference),path.join(out,'raw-reflow-frozen.json')]);
const frozen=JSON.parse(fs.readFileSync(path.join(out,'raw-reflow-frozen.json')));
for(let i=0;i<reflow.length;i++){
 const fields=Object.keys(reflow[i].actual).filter(k=>!same(reflow[i].actual[k],frozen[i][k]));
 if(fields.length||!frozen[i].accepted)failures.push({kind:'reflow',fields,actual:reflow[i].actual,expected:frozen[i]});else exact++;
}
if(records.length!==9)failures.push({kind:'coverage',observed:records.length,expected:9});
const result={passed:!failures.length,exact,records:records.length,scope:'Actual native Card/CaptionReflowEntry/PlateGrowthTrial transport vs literal frozen room/plate CSS assignments and entire deferred captionTextReflow callback. Shared injected reflow profiles; platform glyph raster excluded.',failures};
fs.writeFileSync(path.join(out,'frozen-policy-report.json'),JSON.stringify(result,null,2));console.log(JSON.stringify(result));if(failures.length)process.exit(1);
