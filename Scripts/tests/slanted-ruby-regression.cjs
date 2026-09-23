// Frozen real raster captures, explicitly rotated with independent source/ruby
// and illustration masks. Includes light/dark, faint/colored and missing ruby.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),zlib=require('node:zlib');
const source=n=>fs.readFileSync(path.resolve(__dirname,'../../Aidoku/Core/Translation/NativeEngine/Overlay/'+n+'.swift'),'utf8').match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const {restore,geometry}=new Function(source('BrowserSourceTextColor')+source('BrowserSourcePanelRestoration')+source('BrowserSlantedSourceRestoration')+';return {restore:aidokuRestoreSlantedSource,geometry:aidokuSlantedLocalGeometry}')();
const fixtures=JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/slanted-ruby-pixels.json'))).cases;
const unpack=s=>new Uint8ClampedArray(zlib.inflateSync(Buffer.from(s,'base64')));
let accepted=0,retained=0,totalInk=0,remainingInk=0,totalRuby=0,remainingRuby=0,protectedCount=0,changedArt=0;
for(const f of fixtures){
 const rgba=unpack(f.rgba),before=rgba.slice(),ink=unpack(f.ink),ruby=unpack(f.ruby),protected=unpack(f.protected);
 const options={auxiliary:f.auxiliary,auxiliaryPolygons:f.auxiliaryPolygons,inferRuby:f.infer};
 const out=restore(rgba,f.w,f.h,f.box,f.angle,f.palette,f.vertical,options);
 assert.deepEqual(rgba,before,`${f.id}: immutable original`);
 if(!out){assert.equal(f.sourceName,'comic-0474',`${f.id}: reviewed clear lettering must apply`);retained++;continue;}
 accepted++;let count=0,left=0,rc=0,rl=0,art=0,changed=0,backgroundError=0;
 for(let i=0;i<ink.length;i++){
  const delta=Math.max(...[0,1,2].map(k=>Math.abs(out.rgba[i*4+k]-rgba[i*4+k])));
  const erased=out.rgba[i*4+3]>=250&&delta>10;
  // Binary masks use nearest-neighbor rotation; don't count a now-white
  // sample as original ink after bicubic image resampling.
  const visible=Math.max(...f.palette.background.map((v,k)=>Math.abs(v-rgba[i*4+k])))>24;
  if(ink[i]&&visible){
   count++;if(!erased)left++;
   if(f.synthetic)for(let k=0;k<3;k++)backgroundError+=Math.abs((out.rgba[i*4+3]?out.rgba[i*4+k]:rgba[i*4+k])-f.palette.background[k]);
  }
  if(ruby[i]&&visible){rc++;if(!erased)rl++;}
  if(protected[i]){art++;if(out.rgba[i*4+3]&&delta>3)changed++;}
 }
 assert(count>20&&rc>0&&art>1000,`${f.id}: nonempty independent oracle`);
 assert.equal(changed,0,`${f.id}: protected drawing changed`);
 assert.equal(left,0,`${f.id}: source residue ${left}/${count}`);
 assert.equal(rl,0,`${f.id}: ruby residue ${rl}/${rc}`);
 if(f.synthetic)assert(backgroundError/(count*3)<=3,`${f.id}: known clean background reconstruction`);
 totalInk+=count;remainingInk+=left;totalRuby+=rc;remainingRuby+=rl;protectedCount+=art;changedArt+=changed;
 console.log(`PASS ${f.id}: ink ${left}/${count}, ruby ${rl}/${rc}, protected changes ${changed}/${art}`);
}
assert(accepted>=197);assert(retained<=3);
// Missing reading inference cannot take a neighboring OCR region's ownership.
const f=fixtures.find(f=>f.id==='ruby-07-+25');
const excluded=restore(unpack(f.rgba),f.w,f.h,f.box,f.angle,f.palette,true,
 {inferRuby:true,inferredRubyExclusions:f.referenceRuby});
assert(excluded);assert.equal(excluded.auxiliary.length,0);
const mask=unpack(f.ruby),input=unpack(f.rgba);let surviving=0;
for(let i=0;i<mask.length;i++)if(mask[i]&&!excluded.rgba[i*4+3])surviving++;
assert(surviving>50,'neighbor lettering must survive missing-ruby inference');
// At 45 degrees, a page-axis envelope has no unique oriented inverse. The
// retained OCR quad, not an inflated envelope, defines a 15-by-45 reading.
const q=fixtures.find(f=>f.id==='ruby-19-+45');
const g=geometry(q.box,q.angle,true,{auxiliary:q.auxiliary,auxiliaryPolygons:q.auxiliaryPolygons});
assert(Math.abs(g.auxiliary[0][2]-15)<.001&&Math.abs(g.auxiliary[0][3]-45)<.001);
console.log(JSON.stringify({cases:fixtures.length,accepted,retained,totalInk,remainingInk,totalRuby,remainingRuby,protectedCount,changedArt,controls:2}));
