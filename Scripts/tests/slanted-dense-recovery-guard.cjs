// Actual native crops: dense donor recovery is restricted to upright OCR.
// Rectified mask candidates can recruit neighboring lettering after resampling.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),z=require('node:zlib');
const directory=path.join(__dirname,'../../Aidoku/Core/Translation/NativeEngine/Overlay');
const script=name=>fs.readFileSync(path.join(directory,name+'.swift'),'utf8').match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const restore=new Function(script('BrowserSourceTextColor')+script('BrowserSourcePanelRestoration')+script('BrowserSlantedSourceRestoration')+';return aidokuRestoreSlantedSource;')();
for(const row of JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/slanted-dense-recovery-guard.json')))){
 const rgba=new Uint8ClampedArray(z.inflateSync(Buffer.from(row.rgba,'base64'))),original=rgba.slice();
 const result=restore(rgba,row.w,row.h,row.box,row.angle,row.palette,row.vertical,row.options);
 assert.equal(Boolean(result),row.expectedRestored,row.name+': reject new slanted dense masks that can erase neighboring source text');
 assert.deepEqual(rgba,original,'native source pixels remain immutable');
 if(!result){console.log('PASS slanted dense guard '+row.name);continue;}
 assert.equal(result.method,row.expectedMethod,row.name+': established upright palette must remain available');
 assert.equal(result.erased,row.expectedErased,row.name+': retain the visually verified owned glyph footprint');
 assert.deepEqual(rgba,original,'native source pixels remain immutable');
 assert.ok(result.layoutSafe&&result.luminance,'restoration must retain actual spatial safety and contrast data');
 console.log('PASS slanted existing restoration '+row.name);
}
