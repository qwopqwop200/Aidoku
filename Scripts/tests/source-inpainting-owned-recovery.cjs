// Single-letter production crop: component count must not force a full panel.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),z=require('node:zlib');
const source=path.resolve(__dirname,'../../Aidoku/Core/Translation/NativeEngine/Overlay/BrowserSourcePanelRestoration.swift');
const script=fs.readFileSync(source,'utf8').match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const restore=new Function(script+';return aidokuRestoreSourcePanel;')();
for(const r of JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/source-inpainting-owned-recovery.json')))){
 const rgba=new Uint8ClampedArray(z.inflateSync(Buffer.from(r.rgba,'base64'))),prior=rgba.slice();
 const out=restore(rgba,r.w,r.h,r.b,r.palette,r.options);
 assert.ok(out,'isolated single kana has independently observed clear backing');
 assert.equal(out.sourceErasureVerified,true,'no original owned ink remains');
 assert.deepEqual(rgba,prior,'source pixels are immutable');
 let ink=0;
 for(let y=0;y<r.h;y++)for(let x=0;x<r.w;x++){
  const i=(y*r.w+x)*4;
  if(x>=34&&x<=55&&y>=35&&y<=59&&rgba[i]<110){ink++;assert.equal(out.rgba[i+3],255);assert.ok(out.rgba[i]>240,'paper reconstructed behind kana');}
  if(x<r.b[0]||x>=r.b[0]+r.b[2]||y<r.b[1]||y>=r.b[1]+r.b[3]){
   if(rgba[i]<110)assert.equal(out.rgba[i+3],0,'balloon contour and outside illustration remain intact');
  }
 }
 assert.ok(ink>100);
 // Same short mark on an uncertain surface must still reject. Preserve the
 // lettering but replace its surrounding paper with high-frequency texture.
 const textured=rgba.slice();
 for(let y=24;y<68;y++)for(let x=24;x<63;x++){
  const i=(y*r.w+x)*4;if(textured[i]<110)continue;
  const color=(x+y)%2?170:250;textured.set([color,color,color,255],i);
 }
 assert.equal(restore(textured,r.w,r.h,r.b,r.palette,r.options),null,'texture cannot establish short-glyph ownership');
 console.log('PASS '+r.name+'/'+r.id+' single kana; contour and texture guards');
}
