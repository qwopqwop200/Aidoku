// Production rectified erasure against independent clean-page and artwork oracles.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const source=n=>fs.readFileSync(path.resolve(__dirname,'../../Aidoku/Core/Translation/NativeEngine/Overlay/'+n+'.swift'),'utf8').match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const {restore,fits}=new Function(source('BrowserSourceTextColor')+source('BrowserSourcePanelRestoration')+source('BrowserSlantedSourceRestoration')+';return {restore:aidokuRestoreSlantedSource,fits:aidokuSlantedInkFits}')();
let passed=0;
function test(name,fn){fn();passed++;console.log('PASS',name);}
function scene(degrees,colors){
 const w=320,h=320,cx=160,cy=160,a=degrees*Math.PI/180,c=Math.cos(a),s=Math.sin(a),data=new Uint8ClampedArray(w*h*4),clean=data.slice(),ink=[],art=[];
 for(let y=0;y<h;y++)for(let x=0;x<w;x++){
  const dx=x+.5-cx,dy=y+.5-cy,u=dx*c+dy*s,v=-dx*s+dy*c;
  const border=Math.abs(v-27)<1.5&&Math.abs(u)<145;
  let letter=false;
  for(let k=0;k<5;k++){const gx=u-(-112+k*45);if(gx>=0&&gx<24&&v>=-20&&v<18&&(gx<5||gx>=19||Math.abs(v)<3))letter=true;}
  const bg=border?colors.fg:colors.bg,at=(y*w+x)*4;clean.set([...bg,255],at);data.set([...(letter?colors.fg:bg),255],at);
  if(letter)ink.push(y*w+x);if(border)art.push(y*w+x);
 }
 return {w,h,data,clean,ink,art,box:[30,130,260,60],a};
}
for(const degrees of [-80,-55,-20,20,55,80])for(const [name,bg,fg] of [['paper',[255,255,255],[12,12,12]],['colored sign',[244,176,65],[255,255,249]]]){
 test(`${name} ${degrees} degrees removes glyphs and preserves the crossing rule`,()=>{
  const s=scene(degrees,{bg,fg}),before=s.data.slice();const r=restore(s.data,s.w,s.h,s.box,s.a,{foreground:fg,background:bg,confidence:{foreground:1}},false);
  assert.ok(r,'valid source should be reconstructed');assert.deepEqual(s.data,before,'input must be immutable');
  let residual=0,error=0;
  for(const i of s.ink){if(!r.rgba[i*4+3])residual++;for(let k=0;k<3;k++)error+=Math.abs((r.rgba[i*4+3]?r.rgba[i*4+k]:s.data[i*4+k])-s.clean[i*4+k]);}
  assert.ok(residual/s.ink.length<.01,`source ink left ${residual}/${s.ink.length}`);
  assert.ok(error/(s.ink.length*3)<4,'reconstructed surface error');
  for(const i of s.art)assert.equal(r.rgba[i*4+3],0,'drawing pixels cannot be painted');
 });
}
test('invalid geometry and work above the existing pixel cap are rejected',()=>{
 assert.equal(restore(new Uint8ClampedArray(513*513*4),513,513,[10,10,100,50],.3,null),null);
 assert.equal(restore(new Uint8ClampedArray(100),5,5,[0,0,NaN,5],.3,null),null);
});
test('glyph footprint cannot cross surviving art even with a clear center',()=>{
 const r={lw:50,lh:50,box:[5,5,40,40],layoutSafe:new Uint8Array(2500).fill(1),luminance:new Uint8Array(2500).fill(255)};
 assert.equal(fits(r,[[5,5,20,20]],1,[10,10,10]),true);r.layoutSafe[12*50+11]=0;
 assert.equal(fits(r,[[5,5,20,20]],1,[10,10,10]),false);
 assert.equal(fits(r,[[22,22,30,30]],1,[250,250,250]),false,'contrast uses restored pixels');
});
console.log(`${passed}/${passed} slanted artwork regressions passed`);
const zlib=require('node:zlib');
const {harness}=require('./source-color-test-harness.cjs');
const fixtures=JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/slanted-artwork-pixels.json'),'utf8'));
const unpack=text=>new Uint8ClampedArray(zlib.inflateSync(Buffer.from(text,'base64')));
for(const f of fixtures.cases)test(`real lettering and protected illustration: ${f.id}`,()=>{
 const data=unpack(f.rgba),ink=unpack(f.ink),protectedPixels=unpack(f.protected);
 const {sampler}=harness();
 const c=Math.cos(f.angle),s=Math.sin(f.angle),cx=f.box[0]+f.box[2]/2,cy=f.box[1]+f.box[3]/2;
 const points=[[-1,-1],[1,-1],[1,1],[-1,1]].map(([x,y])=>[cx+x*f.box[2]/2*c-y*f.box[3]/2*s,cy+x*f.box[2]/2*s+y*f.box[3]/2*c]);
 const l=Math.max(0,Math.min(...points.map(p=>p[0]))),t=Math.max(0,Math.min(...points.map(p=>p[1])));
 const r=Math.min(f.width,Math.max(...points.map(p=>p[0]))),b=Math.min(f.height,Math.max(...points.map(p=>p[1])));
 const palette=sampler({complete:true,naturalWidth:f.width,naturalHeight:f.height,data},true).sample(f.bounds||[l/f.width,t/f.height,(r-l)/f.width,(b-t)/f.height]);
 const out=restore(data,f.width,f.height,f.box,f.angle,palette,f.vertical);
 assert.ok(out,'reviewed recoverable lettering must not be silently omitted');
 let inkCount=0,residual=0,protectedCount=0,damaged=0;
 for(let i=0;i<ink.length;i++){
  if(ink[i]){
   inkCount++;
   const change=Math.max(...[0,1,2].map(k=>Math.abs(out.rgba[i*4+k]-data[i*4+k])));
   // An opaque patch painted in the original ink color is not erasure.
   if(out.rgba[i*4+3]<250||change<5)residual++;
  }
  if(protectedPixels[i]){protectedCount++;if(out.rgba[i*4+3]){
    const error=Math.max(...[0,1,2].map(k=>Math.abs(out.rgba[i*4+k]-data[i*4+k])));
    if(error>3)damaged++;
  }}
 }
 assert.ok(inkCount>50&&protectedCount>1000,'nonempty independent masks');
 assert.ok(residual/inkCount<=.005,`${f.id}: remaining annotated ink ${residual}/${inkCount}`);
 assert.equal(damaged,0,`protected illustration changed in ${damaged} pixels`);
 console.log(`  ink=${inkCount}, remaining=${residual}, protected=${protectedCount}, changed=${damaged}`);
});
const rejections=JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/slanted-artwork-rejections.json'),'utf8'));
for(const f of rejections.cases)test(`partial source or unsupported backing is retained: ${f.id}`,()=>{
 const data=unpack(f.rgba),before=data.slice(),{sampler}=harness();
 const palette=sampler({complete:true,naturalWidth:f.width,naturalHeight:f.height,data},true).sample(f.bounds);
 assert.equal(restore(data,f.width,f.height,f.box,f.angle,palette,f.vertical),null,f.reason);
 assert.deepEqual(data,before,'retention must not damage the original');
});
console.log(`${passed}/${passed} total slanted artwork regressions passed`);
