// Native crops from device-cache pages. No translation strings or page IDs
// participate in production decisions; each fixture retains its original palette.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),zlib=require('node:zlib'),crypto=require('node:crypto');
const dir=path.resolve(__dirname,'../../Aidoku/Core/Translation/NativeEngine/Overlay');
const read=n=>fs.readFileSync(path.join(dir,n+'.swift'),'utf8').match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const api=new Function(read('BrowserSourceTextColor')+read('BrowserSourcePanelRestoration')+';return {restore:aidokuRestoreSourcePanel,discover:aidokuDiscoverOutlinedSource};')();
for(const f of JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/discovered-outline-restoration.json'))).fixtures){
 const rgba=new Uint8ClampedArray(zlib.inflateSync(Buffer.from(f.rgba,'base64'))),before=rgba.slice();
 assert.equal(crypto.createHash('sha256').update(rgba).digest('hex'),f.sha256);
 const result=api.restore(rgba,f.w,f.h,f.b,f.palette,f.options);
 assert.ok(result?.sourceGlyphsVerified&&result.sourceErasureVerified,f.name+': certified glyph erasure');
 assert.equal(result.preservedCore,0);assert.deepEqual(rgba,before);
 assert.ok(result.sourceCorePixels>=1000&&result.erased>result.sourceCorePixels,f.name+': erase cores and enclosing fill');
 assert.ok(result.sourceRemainingInk<=Math.max(3,result.sourceCorePixels*.002));
 const core=zlib.inflateSync(Buffer.from(f.sourceCoreMask,'base64'));let total=0,unpainted=0,unchanged=0;
 for(let i=0;i<core.length;i++)if(core[i]){total++;if(!result.rgba[i*4+3])unpainted++;
  const p=result.rgba[i*4+3]?result.rgba:rgba;
  if(Math.max(...[0,1,2].map(c=>Math.abs(p[i*4+c]-rgba[i*4+c])))<=24)unchanged++;}
 assert.ok(unchanged/total<.01,f.name+': replace original ink pixels, not only certify an alpha mask');
 assert.equal(total,f.sourceCoreMaskPixels);assert.ok(total>1000);
 assert.ok(unpainted/total<.005,f.name+': independently labeled original cores must actually be painted');
 for(let y=0;y<f.h;y++)for(let x=0;x<f.w;x++)if(x<2||y<2||x>=f.w-2||y>=f.h-2)
  assert.equal(result.rgba[(y*f.w+x)*4+3],0,f.name+': retain crop boundary');
 if(f.protectedArtwork){const [l,t,w,h]=f.protectedArtwork;for(let y=t;y<t+h;y++)for(let x=l;x<l+w;x++)
  assert.equal(result.rgba[(y*f.w+x)*4+3],0,f.name+': preserve crossing illustration');}
 const transparent=rgba.slice();for(let k=3;k<transparent.length;k+=4)transparent[k]=100;
 assert.equal(api.restore(transparent,f.w,f.h,f.b,f.palette,f.options),null);
 // A palette proposal alone cannot erase unoutlined chromatic artwork.
 const solid=rgba.slice();for(let k=0;k<solid.length;k+=4)solid.set([210,90,15,255],k);
 assert.equal(api.discover(solid,f.w,f.h,f.b,f.palette,f.options),null);
 assert.equal(api.discover(rgba,f.w,f.h,f.b,f.palette,{...f.options,readabilityGate:false}),null);
 console.log('PASS',f.name,JSON.stringify({cores:result.sourceCorePixels,remaining:result.sourceRemainingInk,erased:result.erased}));
}
