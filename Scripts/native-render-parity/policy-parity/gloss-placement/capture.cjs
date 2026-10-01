const fs=require('fs'),path=require('path'),vm=require('vm');
const root=path.resolve(__dirname,'../../../..');
const source=fs.readFileSync(path.join(root,'Scripts/native-render-parity/reference-source/BrowserOverlayTypography.swift'),'utf8');
const start=source.indexOf('    const aidokuGlossPlacer =');
const end=source.indexOf('    // Turns a placed gloss node',start);
const factory=source.slice(start,end)+'\n globalThis.glossFactory=aidokuGlossPlacer;';
let fixtures=[];
const rect=(x,y,w,h)=>({left:x,top:y,right:x+w,bottom:y+h,width:w,height:h});
const serial=p=>p?{cost:p.cost,size:p.size,width:p.width,lineHeight:p.lh,moves:p.moves.map(m=>[m.dx,m.dy]),edge:p.edge,rank:p.rank,side:p.side,gap:p.gap,texture:p.texture,ink:p.ink?[p.ink.left,p.ink.top,p.ink.right-p.ink.left,p.ink.bottom-p.ink.top]:null,angle:p.angle??null,center:p.center??null,block:p.block??null}:null;
for(let i=0;i<120;i++){
 const frame=[i%3*5,i%2*3,320+i%4*40,520+i%5*20],band=[frame[0]+60+i%3*20,frame[1]+180+i%7*12,90+i%4*20,38+i%6*12];
 const fill=i%2?[235,215,195]:[20,20,20],ground=i%2?[25,25,25]:[240,240,240];
 const reach=26*1.2*3+40,top=Math.max(frame[1],band[1]-reach),bottom=Math.min(frame[1]+frame[3],band[1]+band[3]+reach);
 const k=Math.max(2,frame[2]/200,(bottom-top)/400),gw=Math.max(2,Math.round(frame[2]/k)),gh=Math.max(2,Math.round((bottom-top)/k));
 let rgba=[];
 for(let y=0;y<gh;y++)for(let x=0;x<gw;x++){
  let c=ground.slice(),px=frame[0]+x*k,py=top+y*k;
  if(i%10===1 && y%2===0)c=[120,120,120];
  if(i%10===2 && py>band[1]+band[3]+10 && py<band[1]+band[3]+14)c=[0,0,0];
  if(i%10===3 && px>band[0]+band[2]+8 && px<band[0]+band[2]+12)c=[0,0,0];
  if(i%10===4 && x%3===0 && y%3===0)c=[100,100,100];
  if(i%10===5 && px>band[0]+5 && px<band[0]+band[2]-5 && py>band[1]+6 && py<band[1]+band[3]-6)c=fill.slice();
  if(i%10===6 && px>band[0]-12 && px<band[0]+band[2]+12 && py>band[1]-25 && py<band[1]+band[3]+28)c=fill.slice();
  if(i%10===7 && (x+y)%2===0)c=[128,128,128];
  if(i%10===8)c=c.map(v=>Math.max(0,Math.min(255,v+(x%15)-7)));
  if(i%10===9 && py>band[1]+band[3]+5 && py<band[1]+band[3]+50)c=[90,90,90];
  rgba.push(...c,255);
 }
 const nodeSpecs=Array.from({length:i%4===0?2:1},(_,n)=>({length:4+i%13+n*3,left:band[0]+n*7,top:band[1]+n*6}));
 const nodes=nodeSpecs.map(spec=>({style:{},spec}));
 const measure=n=>{
  const size=parseFloat(n.style.fontSize),width=parseFloat(n.style.width),lh=parseFloat(n.style.lineHeight);
  const natural=n.spec.length*size*.53,lines=Math.max(1,Math.ceil(natural/width));
  const tw=Math.min(width,natural),height=lines*lh*.82;
  return rect(n.spec.left+(width-tw)/2,n.spec.top+size*.08,tw,height);
 };
 const sandbox={Math,Float32Array,Int32Array,Map,Set,document:{createElement:()=>({getContext:()=>({drawImage(){},getImageData:()=>({data:rgba})})}),createRange:()=>({selectNodeContents(n){this.node=n},getBoundingClientRect(){return measure(this.node)}})}};
 vm.createContext(sandbox);vm.runInContext(factory,sandbox);
 const reasons={frame:0,source:0,blocked:0,edge:0,inside:0,reads:0};
 const f=frame,s=rect(...band),blocked=i%5===0?[rect(band[0]-10,band[1]+band[3]+2,band[2]+20,70)]:i%5===1?[rect(band[0]+band[2]+3,band[1]-40,70,band[3]+80)]:[];
 const options={start:11+i%5*3,minimum:9,lines:i%3+1,texture:i%2===0};
 const q={cx:band[0]+band[2]/2,cy:band[1]+band[3]/2,angle:(i%7-3)*Math.PI/18,hw:band[2]/2,hh:band[3]/2};
 const placer=sandbox.glossFactory({frame:f,band:s,fill,ground:i%12===0?null:ground,image:{complete:true,naturalWidth:1000,naturalHeight:1500},reasons});
 const test=rect(band[0]-30,band[1]+band[3]+4,band[2]+60,30);
 const evidence=placer.underneath(test,3),divided=placer.divided(rect(frame[0],band[1],frame[2],band[3]+60),true),ink=placer.inkOf(s);
 const axis=serial(placer.search(s,blocked,nodes,i%4===0,options));
 const tilted=serial(placer.searchTilted(q,blocked,nodes,i%4===0,options));
 fixtures.push({frame,band,fill,ground:i%12===0?null:ground,rgba,gw,gh,nodeSpecs,blocked:blocked.map(r=>[r.left,r.top,r.width,r.height]),options,before:i%4===0,tiltedFrame:q,test:[test.left,test.top,test.width,test.height],expected:{evidence,divided,ink:[ink.left,ink.top,ink.right-ink.left,ink.bottom-ink.top],axis,tilted,reasons}});
}
fs.writeFileSync(process.env.AIDOKU_POLICY_FIXTURES,JSON.stringify(fixtures));
console.log('Captured '+fixtures.length+' frozen axis/tilted gloss fixtures.');
