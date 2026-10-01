const fs=require('fs');
const file=fs.readFileSync('Scripts/native-render-parity/reference-source/BrowserSourcePanelRestoration.swift','utf8');
const functions=file.slice(file.indexOf('function aidokuFillFromDonorFront('),file.indexOf('function aidokuHarmonicFill('));
const helper=file.slice(file.indexOf('function aidokuRestorationDistance('),file.indexOf('function aidokuRestorationBlend('));
const api=new Function(helper+functions+';return {fill:aidokuFillFromDonorFront,contaminated:aidokuContaminatedFrontDonors};')();
const fixtures=[];let state=10903;const rand=()=>{state=(Math.imul(state,1664525)+1013904223)>>>0;return state/4294967296;};
for(let trial=0;trial<80;trial++){
 const w=16,h=15,n=w*h,p=new Uint8ClampedArray(n*4),mask=new Uint8Array(n),blocked=new Uint8Array(n),paint=new Uint8Array(n),queue=[];
 const coeff=[[140,18,12],[160,20,-10],[180,-4,8]];
 for(let y=0;y<h;y++)for(let x=0;x<w;x++)for(let c=0;c<4;c++)p[(y*w+x)*4+c]=c===3?255:coeff[c][0]+coeff[c][1]*x/w+coeff[c][2]*y/h;
 for(let y=4;y<10;y++)for(let x=5;x<11;x++){const i=y*w+x;mask[i]=1;paint[i]=1;queue.push(i);p.set([15,25,30,255],i*4);}
 for(let k=0;k<trial%7;k++){
  const x=trial%2?4:11,y=4+Math.floor(rand()*6),i=y*w+x,shade=50+Math.floor(rand()*90);
  p.set([shade,shade+10,shade+20,255],i*4);
  if(trial%11===0)blocked[i]=1;
 }
 if(trial%9===0){for(let y=3;y<=10;y++)for(let x=4;x<=11;x++){const i=y*w+x;if(!paint[i])blocked[i]=1;}}
 if(trial%13===0){for(let x=0;x<w;x++){const i=6*w+x;if(!paint[i])p.set([70,80,90,255],i*4);}}
 if(trial===79){mask[0]=1;paint[0]=1;queue.push(0);}
 const strokes=trial%5===0?[[70,80,90]]:[],inks=trial%3===0?[]:[[15,25,30]];
 const donors=api.contaminated(p,w,h,queue,queue.length,blocked,paint,coeff,strokes,inks);
 const original=Array.from(p),originalMask=Array.from(mask);
 api.fill(p,w,n,queue,queue.length,mask,blocked,paint);
 fixtures.push({w,h,p:original,mask:originalMask,blocked:Array.from(blocked),paint:Array.from(paint),queue,coeff,strokes,inks,expected:{p:Array.from(p),mask:Array.from(mask),indices:Array.from(donors),specks:donors.specks||[]}});
}
fs.writeFileSync(process.env.AIDOKU_POLICY_FIXTURES,JSON.stringify(fixtures));
