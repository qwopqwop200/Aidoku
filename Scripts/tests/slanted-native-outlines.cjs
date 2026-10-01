// Frozen historical Web renderer reference; production native rendering is tested by AidokuFull.
// UIKit-prepared incident crops: removing only the coloured cores left white letter silhouettes.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),zlib=require('node:zlib'),crypto=require('node:crypto');
const base=path.resolve(__dirname,'../../AidokuTests/Translation/LegacyBrowserOverlay');
const source=n=>fs.readFileSync(path.join(base,n+'.swift'),'utf8').match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const restore=new Function(source('BrowserSourceTextColor')+source('BrowserSourcePanelRestoration')+source('BrowserSlantedSourceRestoration')+';return aidokuRestoreSlantedSource;')();
for(const f of JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/slanted-native-outlines.json'))).fixtures){
 const rgba=new Uint8ClampedArray(zlib.inflateSync(Buffer.from(f.rgba,'base64'))),before=rgba.slice();
 assert.equal(crypto.createHash('sha256').update(rgba).digest('hex'),f.sha256);
 const out=restore(rgba,f.w,f.h,f.box,f.angle,f.palette,f.vertical,f.options);
 assert.ok(out,f.name+': bounded glyph reconstruction must succeed');
 assert.deepEqual(rgba,before,'source is immutable');
 assert.ok(out.erased>=f.minimumErased,f.name+': complete outline, not only coloured cores');
 for(let y=0;y<f.h;y++)for(let x=0;x<f.w;x++)if(x<2||y<2||x>=f.w-2||y>=f.h-2)
  assert.equal(out.rgba[(y*f.w+x)*4+3],0,f.name+': retain crop boundary');
 console.log('PASS',f.name,out.erased);
}
