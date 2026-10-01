// Captured native-resolution crops: thin dark ink with a measured white ring.
// Independent source-core masks were derived from connected dark components
// and their observed bright perimeter, not from the candidate restoration.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),zlib=require('node:zlib'),crypto=require('node:crypto');
const base=path.resolve(__dirname,'../../Aidoku/Core/Translation/NativeEngine/Overlay');
const source=n=>fs.readFileSync(path.join(base,n+'.swift'),'utf8').match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const api=new Function(source('BrowserSourceTextColor')+source('BrowserSourcePanelRestoration')+';return {restore:aidokuRestoreSourcePanel,outline:aidokuRestoreChromaticBalloonGlyphs};')();
for(const f of JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/thin-dark-caption-restoration.json'))).fixtures){
 const rgba=new Uint8ClampedArray(zlib.inflateSync(Buffer.from(f.rgba,'base64'))),before=rgba.slice();
 assert.equal(crypto.createHash('sha256').update(rgba).digest('hex'),f.sha256);
 const result=api.restore(rgba,f.w,f.h,f.b,f.palette,f.options);
 assert.ok(result?.sourceGlyphsVerified&&result.sourceErasureVerified,f.name+': complete glyph proof');
 assert.equal(result.method,'chromatic-balloon-glyphs');assert.deepEqual(rgba,before);
 const core=zlib.inflateSync(Buffer.from(f.sourceCoreMask,'base64'));let total=0,residual=0,unpainted=0;
 for(let i=0;i<core.length;i++)if(core[i]){
  total++;const p=result.rgba[i*4+3]?result.rgba:rgba,k=i*4;
  if(Math.max(p[k],p[k+1],p[k+2])<=90)residual++;
  if(!result.rgba[k+3])unpainted++;
 }
 assert.equal(total,f.minimumCorePixels);assert.ok(total>=1000);
 assert.ok(residual<=f.maximumResidualPixels&&residual/total<.001,f.name+': remove the observed source cores');
 assert.ok(unpainted<=f.maximumResidualPixels,f.name+': paint the source mask, not merely label it safe');
 for(let y=0;y<f.h;y++)for(let x=0;x<f.w;x++)if(x<2||y<2||x>=f.w-2||y>=f.h-2)
  assert.equal(result.rgba[(y*f.w+x)*4+3],0,'keep artwork at crop boundaries');
 // Palette-only guesses must not opt dark artwork into the new polarity path.
 for(const field of ['widthEvidence','confidence']){
  const palette=structuredClone(f.palette),evidence=palette.sourceInk||palette;
  if(field==='widthEvidence')delete evidence.widthEvidence;else evidence.confidence.stroke=0;
  assert.equal(api.outline(rgba,f.w,f.h,f.b,palette,f.options),null,'require independently measured ring evidence');
 }
 const noRing=rgba.slice();
 for(let i=0;i<noRing.length;i+=4)if(Math.min(noRing[i],noRing[i+1],noRing[i+2])>=200)
  noRing.set([130,130,130],i);
 assert.equal(api.outline(noRing,f.w,f.h,f.b,f.palette,f.options),null,'metadata cannot substitute for an observed white ring');
 const transparent=rgba.slice();for(let i=3;i<transparent.length;i+=4)transparent[i]=100;
 assert.equal(api.restore(transparent,f.w,f.h,f.b,f.palette,f.options),null);
 console.log('PASS',f.name,JSON.stringify({sourceCorePixels:total,residualPixels:residual,paintedPixels:result.erased}));
}
