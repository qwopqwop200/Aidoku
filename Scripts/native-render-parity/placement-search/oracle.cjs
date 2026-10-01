const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const root=path.resolve(__dirname,'../../..');
const frozen=fs.readFileSync(path.join(root,'AidokuTests/Translation/LegacyReaderTranslationRenderScript.swift'),'utf8');
const start=frozen.indexOf('                let clearTable=null,shiftAttempts=0;');
const end=frozen.indexOf('                // A caption that grew only part',start);
if(start<0||end<0)throw Error('Frozen clearShift unavailable');
const source=frozen.slice(start,end).replace(/\\\\/g,'\\');
const context=vm.createContext({});
vm.runInContext(`globalThis.oracle=v=>{
const [cx,cy,cw,ch]=v.crop,w=v.width,h=v.height;
const c={w,h,iw:w,ih:h,sx:cw/ch*h/w,sy:1,x:0,y:0,safe:Uint8Array.from(v.safe)};
const frame=[cx,cy,cw,ch];c.sx=1;
const otherBackgrounds=v.obstacles.map(r=>({left:r[0],top:r[1],right:r[0]+r[2],bottom:r[1]+r[3]})),otherInks=[];
const glyph=v.glyph,reachGlyph=glyph,lifted=()=>false,budgetStop=()=>false,item={id:'fixture'};
let balloonShiftBudget=1048576;
${source}
const b=v.frame,r=v.region;
return clearShift({left:b[0],top:b[1],right:b[0]+b[2],bottom:b[1]+b[3]},v.size,[r[0],r[1],r[0]+r[2],r[1]+r[3]]);
};`,context);
let seed=16452;const rand=()=>{seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed/2**32;};
const cases=[];
for(let i=0;i<240;i++){
 const width=24+Math.floor(rand()*80),height=24+Math.floor(rand()*80),crop=[rand()*20,rand()*30,width*(.4+rand()*1.8),height*(.4+rand()*1.8)];
 const safe=Array(width*height).fill(1);
 for(let k=0;k<10;k++){
  const x=Math.floor(rand()*width),y=Math.floor(rand()*height),rw=1+Math.floor(rand()*5),rh=1+Math.floor(rand()*10);
  for(let yy=y;yy<Math.min(height,y+rh);yy++)for(let xx=x;xx<Math.min(width,x+rw);xx++)safe[yy*width+xx]=0;
 }
 const frame=[crop[0]+rand()*crop[2],crop[1]+rand()*crop[3],crop[2]*(.1+rand()*.4),crop[3]*(.1+rand()*.3)];
 const obstacles=Array.from({length:i%3},()=>[crop[0]+rand()*crop[2],crop[1]+rand()*crop[3],rand()*crop[2]*.1,rand()*crop[3]*.2]);
 const value={id:'clearShift-'+i,width,height,crop,safe,frame,obstacles,size:3+rand()*12,glyph:10+rand()*40,
 region:i%4?crop:[crop[0]+crop[2]*.1,crop[1]+crop[3]*.1,crop[2]*.8,crop[3]*.8]};
 value.expected=context.oracle(value);cases.push(value);
}
process.stdout.write(JSON.stringify(cases));
