// Frozen historical Web renderer reference; production native rendering is tested by AidokuFull.
// Actual UIKit-prepared source crops from reported reader failures.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),zlib=require('node:zlib'),crypto=require('node:crypto');
const base=path.resolve(__dirname,'../../AidokuTests/Translation/LegacyBrowserOverlay');
const source=n=>fs.readFileSync(path.join(base,n+'.swift'),'utf8').match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const restore=new Function(source('BrowserSourceTextColor')+source('BrowserSourcePanelRestoration')+';return aidokuRestoreSourcePanel;')();
for(const f of JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/outlined-caption-restoration.json'))).fixtures){
 const rgba=new Uint8ClampedArray(zlib.inflateSync(Buffer.from(f.rgba,'base64'))),before=rgba.slice();
 assert.equal(crypto.createHash('sha256').update(rgba).digest('hex'),f.sha256);
 const run=input=>restore(input,f.w,f.h,f.b,f.palette,f.options);
 const result=run(rgba);assert.ok(result,f.name+': reconstruct the observed glyphs');
 assert.ok(result.sourceGlyphsVerified&&result.sourceErasureVerified,f.name+': complete source proof');
 assert.deepEqual(rgba,before,'do not mutate the original page');
 for(let y=0;y<f.h;y++)for(let x=0;x<f.w;x++)if(x<2||y<2||x>=f.w-2||y>=f.h-2)
  assert.equal(result.rgba[(y*f.w+x)*4+3],0,'retain the crop boundary');
 if(f.name==='outlined-caption-on-garment'){
  const [l,t,w,h]=f.b;let remaining=0;
  for(let y=Math.ceil(t);y<t+h;y++)for(let x=Math.ceil(l);x<l+w;x++){
   const k=(y*f.w+x)*4,p=result.rgba[k+3]?result.rgba:rgba;
   if(p[k]-p[k+2]>90&&p[k]-p[k+1]>50&&p[k+2]<60)remaining++;
  }
  assert.equal(remaining,0,'do not leave isolated orange source-stroke fragments');
 }
 if(f.name==='paper-caption-next-to-artwork'){
  let preserved=0;
  for(let y=f.h-80;y<f.h;y++)for(let x=f.w-60;x<f.w;x++){
   const k=(y*f.w+x)*4,lo=Math.min(...rgba.slice(k,k+3)),hi=Math.max(...rgba.slice(k,k+3));
   if(lo>35&&hi<210&&hi-lo<35){assert.equal(result.rgba[k+3],0,'retain neighboring garment ink');preserved++;}
  }
  assert.ok(preserved>100,'the real artwork guard must inspect actual ink');
 }
 const transparent=rgba.slice();for(let k=3;k<transparent.length;k+=4)transparent[k]=100;
 assert.equal(run(transparent),null,'do not flatten transparent artwork');
 console.log('PASS',f.name,result.erased);
}
