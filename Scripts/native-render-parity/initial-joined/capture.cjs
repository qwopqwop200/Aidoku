const fs=require('fs'),path=require('path');
const root=process.argv[2],out=process.argv[3];
const src=fs.readFileSync(path.join(root,'Scripts/native-render-parity/reference-source/BrowserOverlayView.swift'),'utf8');
const start=src.indexOf('    // A joined balloon unit is planned in its members'),end=src.indexOf('    root.dataset.panelRestorationAudit',start);
if(start<0||end<start)throw Error('missing frozen initial joined-unit stage');
const run=new Function('data',`const all=JSON.parse(JSON.stringify(data)),items=all.filter(x=>!x.kept),keptItems=all.filter(x=>x.kept);
const unitMembersOf=item=>item.joined?[1,2]:null,unitResidueRisk=new Set(all.filter(x=>x.residue));
${src.slice(start,end)}
return all.map(x=>({rect:[x.x,x.y,x.width,x.height],planned:x.unitPlannedCard||null}));`);
const base={id:'unit',x:20,y:10,width:40,height:70,fontSize:12,sourceFrame:[0,0,100,100],sourceBounds:[.2,.1,.4,.7],
 balloonInterior:{rect:[0,0,1,1],spans:[.3,.7,.1,.9,.1,.9,.2,.8]},joined:true};
const fixtures=[];const add=(items,label)=>fixtures.push({label,input:items,expected:run(items)});
for(const rect of [[20,10,40,70],[25,27,45,45],[2,2,90,96],[20,35,40,20],[-5,15,40,70]])
for(const spans of [[.3,.7,.1,.9,.1,.9,.2,.8],[.1,.9,.1,.9,.1,.9,.1,.9],[-1,-1,.1,.9,.1,.9,-1,-1],[.2,.8,.4,.6,.1,.9,.2,.8],[.7,.7,.1,.9,.1,.9,.2,.8]])
for(const fontSize of [7,12,30])add([{...base,x:rect[0],y:rect[1],width:rect[2],height:rect[3],fontSize,balloonInterior:{...base.balloonInterior,spans}}],'geometry');
for(const sourceFrame of [[3.125,-5.25,177.7,223.1],[-50,20,500,100],[100,100,0,100]])
for(const rect of [[20,10,40,70],[110,120,35,50]])add([{...base,sourceFrame,x:rect[0],y:rect[1],width:rect[2],height:rect[3]}],'fractional-frame');
for(const flag of ['residue','vertical','kept','rotation','joined'])add([{...base,[flag]:flag==='joined'?false:true}],'admission-'+flag);
for(const rect of [[12,27,76,47],[15,29,1,1],[50,80,4,4],[88,27,5,5],[100,100,4,4]])
for(const kept of [false,true])for(const onlySource of [false,true])add([base,{id:'other',x:onlySource?200:rect[0],y:onlySource?200:rect[1],width:rect[2],height:rect[3],fontSize:10,kept,
 sourceFrame:[0,0,100,100],sourceBounds:onlySource?rect.map(x=>x/100):[2,2,.05,.05]}],'obstacles');
for(const reverse of [false,true]){
 const a={...base,id:'a'},b={...base,id:'b',x:5,y:3,width:25,height:15,sourceBounds:[0,0,.02,.02]};
 add(reverse?[b,a]:[a,b],'sequential-neighbors');
}
for(const spans of [[],[.1],[.1,.9,.2],[-1,-1,-1,-1]])add([{...base,balloonInterior:{...base.balloonInterior,spans}}],'invalid-bands');
fs.writeFileSync(out,JSON.stringify(fixtures));
console.log(JSON.stringify({cases:fixtures.length,accepted:fixtures.filter(x=>x.expected.some(e=>e.planned)).length}));
