const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const root=path.resolve(__dirname,'../../..');
const frozen=fs.readFileSync(path.join(root,'AidokuTests/Translation/LegacyReaderTranslationRenderScript.swift'),'utf8');
const match=frozen.match(/static let BrowserOverlayTypography = #?"""\n([\s\S]*?)\n    """/);
if(!match)throw Error('frozen typography oracle unavailable');
const context=vm.createContext({});
vm.runInContext(match[1]+`\nglobalThis.policies={fontClusters:aidokuFontClusters,fontClusterTargets:(e,k)=>Object.fromEntries([...aidokuFontClusterTargets(e,k,x=>x.column)].map(([e,v])=>[e.id,v])),pageStyleGroups:aidokuPageStyleGroups,alignedGroups:aidokuAlignedGroups,columnRowLinks:aidokuColumnRowLinks,cohortFontCandidates:(a)=>aidokuCohortFontCandidates(...a),fontFlowFits:(a)=>aidokuFontFlowFits(...a),koreanWrapImproves:(a)=>aidokuKoreanWrapImproves(...a),condensedSizes:(a)=>aidokuCondensedSizes(...a),condensedWordBound:(a)=>aidokuCondensedWordBound(...a),growthKeepsLineLength:(a)=>aidokuGrowthKeepsLineLength(...a),badBreak:(a)=>aidokuBadBreak(...a),reduplicationBreak:(a)=>aidokuReduplicationBreak(...a),interfaceRows:aidokuInterfaceRows};`,context);
const shapeStart=frozen.indexOf('    const nativeBalloonShapes=new Map();');
const shapeEnd=frozen.indexOf('    // Size gaps a caption',shapeStart);
if(shapeStart<0||shapeEnd<0)throw Error('Frozen nativeBalloonShape unavailable');
vm.runInContext(frozen.slice(shapeStart,shapeEnd).replace(/\\\\/g,'\\')+`
policies.balloonShape=(rect,center,spans,frame,points,bounds)=>{
const s=nativeBalloonShape({balloonInterior:{rect,center,spans}},frame);if(!s)return null;
return{area:s.area,rectangularity:s.rectangularity,center:[s.cx,s.cy],contains:points.map(p=>s.contains(...p)),
rows:points.map(p=>s.rowSpan(p[1])),outside:bounds.map(b=>s.outside(b[0],b[1],b[0]+b[2],b[1]+b[3]))};};`,context);
vm.runInContext(`Object.assign(policies,{captionFontFloor:a=>aidokuCaptionFontFloor(...a),restoredFontFloor:a=>aidokuRestoredFontFloor(...a),artworkFontSizes:a=>aidokuArtworkFontSizes(...a),balloonFontSizes:a=>aidokuBalloonFontSizes(...a),emergencyBalloonFontSizes:a=>aidokuEmergencyBalloonFontSizes(...a)});`,context);
let seed=3010;const random=()=>{seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed/2**32;};
const cases=[];const add=(op,args)=>{let expected=context.policies[op](...args);if(op==='fontClusters')expected=expected.map(g=>({font:g.font,members:g.members.map(e=>({...e,kept:e.kept??false}))}));cases.push({id:op+'-'+cases.length,op,args,expected});};
for(let trial=0;trial<180;trial++){
 const n=2+Math.floor(random()*30),entries=Array.from({length:n},(_,i)=>({id:String(i),source:Math.floor(random()*10)+10,font:Math.floor(random()*48)/4+4,script:random()<.9?'korean':'latin',vertical:random()<.1,column:random()<.2,kept:false}));
 const kept=entries.slice(0,3).map((e,i)=>({...e,id:'kept'+i,font:e.source*.9,kept:true}));
 add('fontClusters',[entries]);add('fontClusterTargets',[entries,kept]);
 const records=entries.map(e=>({key:e.script+'|'+e.vertical,glyph:e.source,font:e.font}));
 add('pageStyleGroups',[records,trial%2?1.15:1.25]);
 const boxes=entries.map((e,i)=>({x:i%5*35+Math.floor(random()*10),y:Math.floor(i/5)*42+Math.floor(random()*10),w:25+Math.floor(random()*20),h:24+Math.floor(random()*20),glyph:e.source,script:e.script,vertical:e.vertical,style:trial%3?'':'paper'}));
 add('alignedGroups',[boxes]);add('columnRowLinks',[boxes]);
 const controls=boxes.map((b,i)=>({...b,y:trial%2?905:15,h:b.glyph*1.6,vertical:false,text:i%4?'시작 진행':'뒤로 앞으로 계속 끝'}));
 add('interfaceRows',[controls,[0,0,430,932]]);
 const profile=()=>({lines:1+Math.floor(random()*6),breaks:Array(Math.floor(random()*4)).fill(0),badStarts:Array(Math.floor(random()*3)).fill(0),badEnds:Array(Math.floor(random()*3)).fill(0),hangulFragments:Math.floor(random()*4),punctuationOnly:Math.floor(random()*2),hangulIsolated:0});
 const a=profile(),b=profile();add('fontFlowFits',[[a,b,trial%3]]);add('koreanWrapImproves',[[a,b]]);
}
for(const original of [4.5,5,7.75,8,9,12,20,32])for(const target of [4,5,7.5,8,10,16,35])add('cohortFontCandidates',[[original,target,5]]);
for(const base of [5,7,8.5,12,24,40])for(const target of [6,9,12,18,32,60])add('condensedSizes',[[base,target]]);
for(const longest of [0,30,90,100,120,240])for(const available of [30,80,90,100,110])add('condensedWordBound',[[longest,available]]);
for(const text of ['짧은 말','경찰관이라니','천수각에서의','당연하잖아','하는 것은 당연해요!','아아아아아악!!','두근두근','쿵쿵쿵','왜 이러는 거야'])for(let offset=0;offset<=text.length;offset++){add('badBreak',[[text,offset]]);add('reduplicationBreak',[[text,offset]]);}
for(const text of ['한글이다','긴 문장을 두 글자씩 나누지는 마십시오','한글'])for(const before of [1,2,6])for(const after of [1,2,3,5,10])add('growthKeepsLineLength',[[text,before,after]]);
for(let trial=0;trial<120;trial++){
 const frame=[-10+random()*20,random()*30,100+random()*400,300+random()*800];
 const rect=[.1,.2,.7,.55],center=[.45,.48],n=2+Math.floor(random()*30);
 const spans=Array.from({length:n},(_,i)=>{const d=Math.abs((i+.5)/n-.5)*.3;return trial%5===0&&i===0?[-1,-1]:[.1+d,.8-d];}).flat();
 const points=Array.from({length:30},()=>[frame[0]+random()*frame[2],frame[1]+random()*frame[3]]);
 const bounds=Array.from({length:30},()=>[frame[0]+random()*frame[2],frame[1]+random()*frame[3],random()*frame[2]/3,random()*frame[3]/3]);
 bounds.push([frame[0]+.2*frame[2],frame[1]+.2*frame[3],.1*frame[2],.55*frame[3]],
 [frame[0]+.2*frame[2],frame[1]+.3*frame[3],.1*frame[2],0]);
 add('balloonShape',[rect,center,spans,frame,points,bounds]);
}
for(const font of [-1,0,.1,4.5,5,6.5,7,7.99,8,8.5,9,12,16,31.5,64,128,512,1e10])for(const minimum of [-1,0,5,7,8.5,20]){
 for(const op of ['captionFontFloor','restoredFontFloor','artworkFontSizes','balloonFontSizes'])add(op,[[font,minimum]]);
 for(const preferred of [[],[font],[font,8],[font,7.5],[font,6]])add('emergencyBalloonFontSizes',[[font,minimum,preferred]]);
}
process.stdout.write(JSON.stringify(cases));
