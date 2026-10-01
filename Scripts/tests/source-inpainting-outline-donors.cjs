// Real native Canvas captures: outlined ink joining a similarly hued backing.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),zlib=require('node:zlib'),crypto=require('node:crypto');
const dir=path.join(__dirname,'../../Aidoku/Core/Translation/NativeEngine/Overlay');
const script=name=>fs.readFileSync(path.join(dir,name+'.swift'),'utf8').match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const fixtures=JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/source-inpainting-outline-donors.json'))).fixtures;
for(const wasm of [false,true]){
 const {restore,available}=new Function((wasm?script('BrowserSourceTextColor'):'')+script('BrowserSourcePanelRestoration')+
  ';return {restore:aidokuRestoreSourcePanel,available:typeof aidokuPixelKernels!=="undefined"&&!!aidokuPixelKernels(1024)};')();
 assert.equal(available,wasm);
 for(const f of fixtures){
  const rgba=new Uint8ClampedArray(zlib.inflateSync(Buffer.from(f.rgba,'base64'))),original=rgba.slice();
  assert.equal(crypto.createHash('sha256').update(rgba).digest('hex'),f.sha256);
  const result=restore(rgba,f.w,f.h,f.b,f.palette,f.options);assert.ok(result?.sourceErasureVerified);
  if(f.name==='warm-outlined-caption')assert.deepEqual(result.discoveredOutline,f.palette.stroke,
    'erasure ownership must retain the physical outline for the final display palette');
  let ink=0,missing=0,seam=0,edges=0;
  for(let y=0;y<f.h;y++)for(let x=0;x<f.w;x++){
   const i=y*f.w+x,k=i*4;
   if(!x||!y||x===f.w-1||y===f.h-1){assert.equal(result.rgba[k+3],0,'crop border stays untouched');continue;}
   if(x>=f.b[0]&&x<=f.b[0]+f.b[2]&&y>=f.b[1]&&y<=f.b[1]+f.b[3]&&
      Math.max(...f.palette.stroke.map((v,c)=>Math.abs(v-rgba[k+c])))<=48){ink++;if(!result.rgba[k+3])missing++;}
   if(result.rgba[k+3])for(const j of [i-1,i+1,i-f.w,i+f.w])if(!result.rgba[j*4+3]){
    edges++;seam+=Math.max(...[0,1,2].map(c=>Math.abs(result.rgba[k+c]-rgba[j*4+c])));
   }
  }
  assert.ok(ink>3000);assert.equal(missing,0,'no measured source outline may survive a complete-erasure claim');
  assert.ok(seam/edges<1,`no donor-starved boundary patches: ${seam/edges}`);
  assert.deepEqual(rgba,original,'source pixels remain immutable');
  console.log(`PASS ${f.name}, ${wasm?'WASM':'JavaScript'}: ${ink} ink pixels erased, boundary MAE ${(seam/edges).toFixed(3)}`);
 }
}
