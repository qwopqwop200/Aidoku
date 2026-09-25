// Real captured narrow balloons and textured negatives, executing production.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),z=require('node:zlib');
const source=fs.readFileSync(path.join(__dirname,'../../Aidoku/Core/Translation/NativeEngine/Overlay/BrowserSourcePanelRestoration.swift'),'utf8');
const script=source.match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const api=new Function(script+';return {restore:aidokuRestoreSourcePanel,attempts:aidokuRestoreSourcePanelAttempts};')();
for(const fixture of JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/source-inpainting-dense-donors.json')))){
 const rgba=new Uint8ClampedArray(z.inflateSync(Buffer.from(fixture.rgba,'base64'))),original=rgba.slice();
 const args=[rgba,fixture.w,fixture.h,fixture.b,fixture.palette,fixture.options];
 api.restore.classificationCache=[];
 const sparse=api.attempts(...args);api.restore.classificationCache=null;
 assert.equal(sparse,null,fixture.name+'/'+fixture.id+': sparse donor lattice fails this captured case');
 const restored=api.restore(...args);
 assert.equal(Boolean(restored),fixture.expectedRestored,fixture.name+'/'+fixture.id);
 assert.deepEqual(rgba,original,'input image is immutable');
 assert.equal(api.restore.classificationCache,null,'retry cache is released after call');
 if(restored){
  assert.equal(restored.sourceErasureVerified,true,'clean balloon owns every source glyph');
  assert.equal(restored.preservedCore,0);
  assert.equal(restored.preservedPixels,0);
  assert.ok(restored.surfaceQuality.samples>=24);
  assert.ok(restored.surfaceQuality.safe);
  assert.ok(restored.erased>0);
  for(let i=0;i<fixture.w*fixture.h;i++)if(!restored.layoutSafe[i])
   assert.equal(restored.rgba[i*4+3],0,'protected artwork must not be painted');
 }
 console.log('PASS dense donor '+fixture.name+'/'+fixture.id+' '+Boolean(restored));
}
