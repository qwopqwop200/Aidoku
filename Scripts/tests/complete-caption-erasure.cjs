// Captured native-prepared crops. Independent source-ink labels cover the
// previously rejected glyphs, including punctuation cut by the OCR boundary.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),zlib=require('node:zlib'),crypto=require('node:crypto');
const dir=path.join(__dirname,'../../Aidoku/Core/Translation/NativeEngine/Overlay');
const script=n=>fs.readFileSync(path.join(dir,n+'.swift'),'utf8').match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const restore=new Function(script('BrowserSourceTextColor')+script('BrowserSourcePanelRestoration')+';return aidokuRestoreSourcePanel;')();
for(const f of JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/complete-caption-erasure.json'))).fixtures){
  const rgba=new Uint8ClampedArray(zlib.inflateSync(Buffer.from(f.rgba,'base64'))),before=rgba.slice();
  assert.equal(crypto.createHash('sha256').update(rgba).digest('hex'),f.sha256);
  const r=restore(rgba,f.w,f.h,f.b,f.palette,f.options);
  assert.ok(r?.sourceErasureVerified,f.name+': complete source erasure');
  assert.ok(r.sourceRemainingInk>=0,f.name+': protected artwork must not be double-subtracted');
  assert.deepEqual(rgba,before);
  const labels=zlib.inflateSync(Buffer.from(f.sourceCoreMask,'base64'));let source=0,replaced=0;
  for(let i=0;i<labels.length;i++)if(labels[i]){
    source++;
    if(r.rgba[i*4+3]===255&&Math.max(...[0,1,2].map(c=>Math.abs(r.rgba[i*4+c]-rgba[i*4+c])))>24)replaced++;
  }
  assert.equal(source,f.sourceCorePixels);assert.ok(source>100);
  assert.ok(replaced/source>=.99,f.name+': replace the labeled source pixels, including the final bracket');
  if(f.protectedArt){const [x,y,w,h]=f.protectedArt;
    for(let yy=y;yy<y+h;yy++)for(let xx=x;xx<x+w;xx++)
      assert.equal(r.rgba[(yy*f.w+xx)*4+3],0,f.name+': retain the original diagonal seam');
  }
  const transparent=rgba.slice();for(let k=3;k<transparent.length;k+=4)transparent[k]=120;
  assert.equal(restore(transparent,f.w,f.h,f.b,f.palette,f.options),null);
  console.log('PASS',f.name,JSON.stringify({source,replaced,remaining:r.sourceRemainingInk}));
}
