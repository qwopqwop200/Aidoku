// Frozen real native crops exercise segmented recovery without claiming that a
// partial erasure permits transparent translated text. No output-folder inputs.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),z=require('node:zlib');
const directory=process.env.OVERLAY_SOURCE_DIR||path.resolve(__dirname,'../../Aidoku/Core/Translation/NativeEngine/Overlay');
const script=name=>fs.readFileSync(path.join(directory,name+'.swift'),'utf8').match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const restore=new Function(script('BrowserSourcePanelRestoration')+';return aidokuRestoreSourcePanel;')();
const unpack=s=>new Uint8ClampedArray(z.inflateSync(Buffer.from(s,'base64')));
const fixtures=JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/source-segmented-restoration.json')));
let passed=0;
for(const f of fixtures){
 const input=unpack(f.rgba),original=input.slice(),r=restore(input,f.w,f.h,f.b,f.palette,f.options);
 assert.equal(Boolean(r),f.expected,f.name+'/'+f.id);
 assert.deepEqual(input,original,'caller pixels unchanged');
 assert.equal(restore.classificationCache,null,'retry state released on success and rejection');
 if(r){
  assert.equal(r.sourceErasureVerified,f.verified,'partial erasure must never be promoted to complete ownership');
  assert.equal(r.surfaceQuality.safe,true);assert.ok(r.surfaceQuality.rmse<=3);assert.equal(r.surfaceQuality.outliers,0);
  let remainingSource=0,protectedPixels=0,protectedDark=0;
  const protectedMask=f.protected?unpack(f.protected):null;
  for(let i=0;i<f.w*f.h;i++){
   if(!r.layoutSafe[i])assert.equal(r.rgba[i*4+3],0,'unowned drawing/source pixels cannot receive paint');
   const x=i%f.w,y=Math.floor(i/f.w),a=r.rgba[i*4+3]/255;
   if(!f.verified&&f.palette.background&&x>=f.b[0]&&x<f.b[0]+f.b[2]&&y>=f.b[1]&&y<f.b[1]+f.b[3]&&a===0&&
       Math.max(...[0,1,2].map(c=>Math.abs(input[i*4+c]-f.palette.background[c])))>40)remainingSource++;
   if(protectedMask?.[i]){
    protectedPixels++;if(Math.max(...input.subarray(i*4,i*4+3))<110)protectedDark++;
    const delta=Math.max(...[0,1,2].map(c=>Math.abs(a*r.rgba[i*4+c]+(1-a)*input[i*4+c]-input[i*4+c])));
    assert.ok(delta<=3,'neighboring OCR-owned lettering must not be erased by target recovery');
   }
  }
  if(!f.verified)assert.ok(remainingSource>0,'partial recovery must retain original non-background pixels rather than flatten the entire source body');
  if(protectedMask)assert.ok(protectedPixels>500&&protectedDark>100,'neighbor oracle must contain actual neighboring glyphs');
 }
 console.log('PASS segmented actual crop '+f.name+'/'+f.id);passed++;
}
// This actual rectified crop previously erased neighboring 擦ろ～ while trying
// to replace 早く. Upright segmented recovery must not leak into slanted masks.
const slanted=JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/slanted-dense-recovery-guard.json')))
 .find(f=>f.name==='diverse-4367-g4');
assert.ok(slanted,'required neighboring-lettering negative exists');
const restoreSlanted=new Function(script('BrowserSourceTextColor')+script('BrowserSourcePanelRestoration')+
 script('BrowserSlantedSourceRestoration')+';return aidokuRestoreSlantedSource;')();
const input=unpack(slanted.rgba),before=input.slice();
assert.equal(restoreSlanted(input,slanted.w,slanted.h,slanted.box,slanted.angle,slanted.palette,slanted.vertical,slanted.options),null,
 'segmented recovery must preserve the unsafe neighboring-lettering slanted negative');
assert.deepEqual(input,before);passed++;console.log('PASS segmented exclusion of actual slanted neighbor crop');
console.log(`${passed}/${passed} segmented restoration regressions passed`);
