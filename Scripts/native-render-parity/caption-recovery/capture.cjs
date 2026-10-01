const fs=require('node:fs'),path=require('node:path');const [root,out]=process.argv.slice(2);
const s=fs.readFileSync(path.join(root,'Scripts/native-render-parity/reference-source/BrowserOverlayView.swift'),'utf8');
const a=s.indexOf('        const preRecoveryPadding=node.style.padding;'),b=s.indexOf('        const panelGeometry=restoredPanelGeometry.get(item);',a),c=s.indexOf("        if(node.dataset.captionFontRecovery==='accepted'&&preRecoveryProfile)",b),d=s.indexOf('        if(panelGeometry){',c);
const original=s.slice(a,b)+'inspectInitial();\n'+s.slice(c,d)+'inspectFinal();';
const execute=new Function('f',`const events=[];const node={style:{fontSize:String(f.font),padding:f.padding},dataset:{}};const measurementNode={style:{padding:f.padding}};const preserveOriginalBackground=f.preserveBackground,vertical=f.vertical,item={allowsAutomaticFontRecovery:f.automatic};const displayedText='x'.repeat(f.length),wrappingScript=f.korean?'korean':'latin';let readableRefinementBudget=f.readable,captionRecoveryCharacterBudget=f.characters;
const sample=()=>f.samples.find(v=>v.font===parseFloat(node.style.fontSize)&&v.padding===node.style.padding)||{fits:false,profile:null};
const applyMeasuredFontSize=n=>{node.style.fontSize=String(n)};
const contentFits=()=>{events.push(['fit',parseFloat(node.style.fontSize),node.style.padding]);return sample().fits};
const lineProfile=()=>{events.push(['profile',parseFloat(node.style.fontSize),node.style.padding]);const p=sample().profile;return p?{breaks:p.breaks,badStarts:Array(p.badStarts).fill(0),badEnds:Array(p.badEnds).fill(0),punctuationOnly:p.punctuationOnly,hangulIsolated:p.hangulIsolated}:null};
const inspectInitial=()=>{events.push(['initial',parseFloat(node.style.fontSize),node.style.padding]);if(f.surfacePadding){node.style.padding=f.surfacePadding;measurementNode.style.padding=f.surfacePadding;}};
const inspectFinal=()=>events.push(['final',parseFloat(node.style.fontSize),node.style.padding]);
`+original+`return {font:parseFloat(node.style.fontSize),padding:node.style.padding,reason:node.dataset.captionFontRecovery||null,readable:readableRefinementBudget,characters:captionRecoveryCharacterBudget,events};`);
const fixtures=[];for(let seed=0;seed<192;seed++){
 const font=[8.5,9,9.5,9.75,10,10.25,10.5,11][seed%8],padding='1,2,3,4';
 const f={seed,font,padding,preserveBackground:seed%13!==0,automatic:seed%17!==0,vertical:seed%19===0,korean:seed%5!==0,length:[0,20,80,180,181][seed%5],readable:[0,30,80,2048][seed%4],characters:[0,20,80,16384][Math.floor(seed/4)%4],surfacePadding:seed%7===0?'4,3,2,1':null,samples:[]};
 for(let q=32;q<=44;q++)for(const pad of [padding,'4,3,2,1']){
  const size=q/4,v=(seed*13+q*7+(pad===padding?0:3))%11;
  const profile=v===0?null:{breaks:v===1?[4,9]:v===2?[5]:[4],badStarts:v===3?1:0,badEnds:v===4?1:0,punctuationOnly:v===5?1:0,hangulIsolated:v===6?1:0};
  f.samples.push({font:size,padding:pad,fits:v!==7&&v!==8,profile});
 }
 f.expected=execute(f);fixtures.push(f);
}
for(let index=0;index<72;index++){
 const f={seed:192+index,font:9.5,padding:'1,2,3,4',preserveBackground:true,automatic:true,vertical:false,korean:true,length:index%9===0?0:20,readable:index%11===0?19:2048,characters:[0,19,20,40,60,80,16384][index%7],surfacePadding:index%2===0?'4,3,2,1':null,samples:[]};
 for(let q=38;q<=42;q++)for(const padding of ['1,2,3,4','4,3,2,1']){
  let profile={breaks:[4],badStarts:0,badEnds:0,punctuationOnly:0,hangulIsolated:0},fits=true;
  if(q===42)profile.breaks=[4,8];
  if(q===41){if(padding==='1,2,3,4')profile.breaks=[5];else profile.badEnds=1;}
  if(q===40&&index%3===0&&padding==='4,3,2,1')fits=false;
  if(q===40&&index%3===1)profile.badStarts=1;
  if(q===40&&index%3===2)profile=null;
  if(q===39&&index%5===0)profile.punctuationOnly=1;
  f.samples.push({font:q/4,padding,fits,profile});
 }
 f.expected=execute(f);fixtures.push(f);
}
fs.writeFileSync(out,JSON.stringify(fixtures));
