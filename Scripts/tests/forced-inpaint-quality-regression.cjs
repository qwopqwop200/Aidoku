const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');

const source=fs.readFileSync(path.join(__dirname,
  '../../AidokuTests/Translation/LegacyBrowserOverlay/BrowserForcedInpaintQuality.swift'),'utf8');
const script=source.match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const fill=new Function(script+';return aidokuForcedDonorFill;')();
const w=120,h=90,n=w*h,clean=new Uint8ClampedArray(n*4),ink=new Uint8ClampedArray(n*4),mask=new Uint8Array(n);
for(let y=0;y<h;y++)for(let x=0;x<w;x++){
  const k=(y*w+x)*4,art=x<45;
  clean.set(art?[35+y*.14,42+y*.18,56+y*.2,255]:[96+x*.12,163+y*.17,191+x*.08,255],k);
}
ink.set(clean);
for(const x0 of [27,55,79])for(let y=12;y<76;y++)for(let x=x0;x<x0+6;x++){
  const i=y*w+x,k=i*4;mask[i]=1;
  ink.set(x===x0||x===x0+5?[249,249,248,255]:[25,38,74,255],k);
}
const result=fill(ink,w,h,mask);
assert.ok(result?.quality?.safe,'narrow glyph masks have coherent donors');
let error=0,erased=0,leaked=0;
for(let i=0;i<n;i++)for(let c=0;c<3;c++){
  if(mask[i]){error+=Math.abs(clean[i*4+c]-result.rgba[i*4+c]);erased++;}
  else leaked+=Math.abs(ink[i*4+c]-result.rgba[i*4+c]);
}
assert.equal(leaked,0,'unowned artwork pixels stay exact');
assert.ok(error/erased<1,`restored glyphs follow both sides of artwork edge: ${error/erased}`);
const huge=new Uint8Array(n);
for(let y=10;y<80;y++)for(let x=10;x<110;x++)huge[y*w+x]=1;
assert.equal(fill(ink,w,h,huge),null,'wide source mask cannot be certified by local donors');
const none=new Uint8Array(n);none.fill(1);
assert.equal(fill(ink,w,h,none),null,'missing donors cannot certify erasure');
console.log(JSON.stringify({narrowGlyphMAE:error/erased,leaked,erasedPixels:result.quality.erased,
  largeMaskRejected:true,noDonorRejected:true}));
// A distant, matching pair used to win against a nearby illustration edge and
// stamp its unrelated blue color through the source lettering.
const ew=160,eh=140,en=ew*eh,edge=new Uint8ClampedArray(en*4),em=new Uint8Array(en);
for(let y=0;y<eh;y++)for(let x=0;x<ew;x++)edge.set(y<15||y>124?[100,160,210,255]:x<83?[32,42,52,255]:[200,110,90,255],(y*ew+x)*4);
for(let y=15;y<=124;y++)for(let x=78;x<=82;x++){em[y*ew+x]=1;edge.set([180,0,180,255],(y*ew+x)*4);}
const edgeResult=fill(edge,ew,eh,em);
assert.ok(edgeResult?.quality.safe,'nearby clean side can restore a narrow edge crossing');
assert.deepEqual(Array.from(edgeResult.rgba.slice((70*ew+79)*4,(70*ew+79)*4+3)),[32,42,52],
 'remote matching donors must not wash blue across a local dark edge');
console.log('PASS nearby illustration edge wins over unrelated remote matching pair');
