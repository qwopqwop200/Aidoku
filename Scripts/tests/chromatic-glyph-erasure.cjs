const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),zlib=require('node:zlib'),crypto=require('node:crypto');
const base=path.resolve(__dirname,'../../Aidoku/Core/Translation/NativeEngine/Overlay');
const source=n=>fs.readFileSync(path.join(base,n+'.swift'),'utf8').match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const api=new Function(source('BrowserSourceTextColor')+source('BrowserSourcePanelRestoration')+source('BrowserSlantedSourceRestoration')+';return {panel:aidokuRestoreSourcePanel,slanted:aidokuRestoreSlantedSource};')();
for(const f of JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/chromatic-glyph-erasure.json'))).fixtures){
 const rgba=new Uint8ClampedArray(zlib.inflateSync(Buffer.from(f.rgba,'base64'))),before=rgba.slice();
 assert.equal(crypto.createHash('sha256').update(rgba).digest('hex'),f.sha256);
 const run=input=>f.kind==='slanted'?api.slanted(input,f.w,f.h,f.box,f.angle,f.palette,f.vertical,f.options):api.panel(input,f.w,f.h,f.b,f.palette,f.options);
 const out=run(rgba);assert.ok(out,f.name+': restore actual native crop');
 assert.deepEqual(rgba,before,'source stays immutable');
 assert.ok(out.erased>=f.minimumErased,f.name+': include the complete white outline');
 for(let y=0;y<f.h;y++)for(let x=0;x<f.w;x++)if(x<2||y<2||x>=f.w-2||y>=f.h-2)
  assert.equal(out.rgba[(y*f.w+x)*4+3],0,'retain the crop boundary');
 if(f.name==='orange-dot-antialias'){
  let remaining=0;
  for(let k=0;k<rgba.length;k+=4){const p=out.rgba[k+3]?out.rgba:rgba;if(p[k]-p[k+2]>30&&p[k]-p[k+1]>25)remaining++;}
  assert.equal(remaining,0,'no orange original dot fragments remain in this bounded crop');
 }
 const transparent=rgba.slice();for(let k=3;k<transparent.length;k+=4)transparent[k]=100;
 assert.equal(run(transparent),null,'do not flatten transparent artwork');
 console.log('PASS',f.name,out.erased);
}
