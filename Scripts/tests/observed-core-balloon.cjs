// Real cached crops whose similarly hued background prevented glyph-only erasure.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),zlib=require('node:zlib'),crypto=require('node:crypto');
const base=path.resolve(__dirname,'../../AidokuTests/Translation/LegacyBrowserOverlay');
const source=n=>fs.readFileSync(path.join(base,n+'.swift'),'utf8').match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const [restore,ordinary]=new Function(source('BrowserSourceTextColor')+source('BrowserSourcePanelRestoration')+';return [aidokuRestoreChromaticBalloonGlyphs,aidokuRestoreChromaticBalloonGlyphPass];')();
for(const f of JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/observed-core-balloon.json')))){
 const rgba=new Uint8ClampedArray(zlib.inflateSync(Buffer.from(f.rgba,'base64'))),before=rgba.slice();
 assert.equal(crypto.createHash('sha256').update(rgba).digest('hex'),f.sha256);
 assert.equal(ordinary(rgba,f.w,f.h,f.b,f.palette,f.options),null,'ordinary hue-only ownership was rejected');
 const result=restore(rgba,f.w,f.h,f.b,f.palette,f.options);
 assert.ok(result?.sourceErasureVerified);assert.equal(result.sourceRemainingInk,0);assert.deepEqual(rgba,before);
 let cores=0,missing=0,residual=0;const fg=f.palette.sourceInk.foreground;
 // Independent RGB core census, including every matching pixel inside the OCR box.
 for(let y=Math.ceil(f.b[1]);y<f.b[1]+f.b[3];y++)for(let x=Math.ceil(f.b[0]);x<f.b[0]+f.b[2];x++){
  const k=4*(y*f.w+x);if(Math.max(...fg.map((v,c)=>Math.abs(rgba[k+c]-v)))>25)continue;
  cores++;if(!result.rgba[k+3])missing++;
  const out=result.rgba[k+3]?result.rgba:rgba;
  if(Math.max(...fg.map((v,c)=>Math.abs(out[k+c]-v)))<=25)residual++;
 }
 assert.ok(cores>=700);assert.equal(missing,0);assert.equal(residual,0);
 assert.ok(result.erased<f.b[2]*f.b[3]*.55,'restore glyphs, not an opaque rectangular surface');
 if(f.case===11){
  // This cached balloon originally retained pale antialiased letter silhouettes
  // after every coloured core had gone. Compare the repaired interior to the
  // independent left/right background gradient on the same source scanline.
  let error=0,channels=0;
  for(let y=90;y<220;y++)for(let x=25;x<175;x++){
   const i=(y*f.w+x)*4;if(!result.rgba[i+3])continue;
   for(let c=0;c<3;c++){
    const expected=rgba[(y*f.w+8)*4+c]*(1-x/(f.w-1))+rgba[(y*f.w+f.w-9)*4+c]*x/(f.w-1);
    error+=Math.abs(result.rgba[i+c]-expected);channels++;
   }
  }
  assert.ok(channels>=30000 && error/channels<7,'white glyph fringe remains in restored background');
 }
 for(let y=0;y<f.h;y++)for(let x=0;x<f.w;x++)if(x<2||y<2||x>=f.w-2||y>=f.h-2)
  assert.equal(result.rgba[(y*f.w+x)*4+3],0,'retain crop borders');
 const noRing=rgba.slice();for(let k=0;k<noRing.length;k+=4)if(Math.min(...noRing.slice(k,k+3))>=200)noRing.set([130,130,130],k);
 assert.equal(restore(noRing,f.w,f.h,f.b,f.palette,f.options),null,'require independently visible white halo');
 const weak=structuredClone(f.palette);weak.sourceInk.confidence.foreground=.5;
 assert.equal(restore(rgba,f.w,f.h,f.b,weak,f.options),null,'uncertain palette cannot enable retry');
 console.log('PASS observed core',JSON.stringify({case:f.case,cores,missing,residual,erased:result.erased}));
}
