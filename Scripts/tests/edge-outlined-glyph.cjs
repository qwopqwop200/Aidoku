// Real cached source crop: the OCR edge bisects two white-ringed glyph components.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),zlib=require('node:zlib'),crypto=require('node:crypto');
const base=path.resolve(__dirname,'../../AidokuTests/Translation/LegacyBrowserOverlay');
const source=n=>fs.readFileSync(path.join(base,n+'.swift'),'utf8').match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const restore=new Function(source('BrowserSourceTextColor')+source('BrowserSourcePanelRestoration')+';return aidokuRestoreChromaticBalloonGlyphs;')();
const f=JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/edge-outlined-glyph.json')));
const rgba=new Uint8ClampedArray(zlib.inflateSync(Buffer.from(f.rgba,'base64'))),before=rgba.slice();
assert.equal(crypto.createHash('sha256').update(rgba).digest('hex'),f.sha256);
const result=restore(rgba,f.w,f.h,f.b,f.palette,f.options);
assert.ok(result?.sourceErasureVerified);assert.equal(result.sourceRemainingInk,0);assert.deepEqual(rgba,before);
let cores=0,missing=0,residual=0;
const fg=f.palette.sourceInk.foreground,low=Math.min(...fg),span=Math.max(...fg)-low;
// Separately flood source-colour ink connected to the crop edge. Those are
// neighbouring rows cut by this crop, not this caption's complete glyphs.
const colour=new Uint8Array(f.w*f.h),outside=new Uint8Array(f.w*f.h),queue=[];
for(let i=0;i<colour.length;i++){
 const c=rgba.slice(i*4,i*4+3),lo=Math.min(...c),d=Math.max(...c)-lo;
 if(d>=65&&Math.max(...c.map((v,k)=>Math.abs((v-lo)/d-(fg[k]-low)/span)))<=28/255)colour[i]=1;
 if(colour[i]&&(i%f.w<3||i%f.w>=f.w-3||i/f.w<3||i/f.w>=f.h-3)){outside[i]=1;queue.push(i);}
}
for(let head=0;head<queue.length;head++){
 const i=queue[head],x=i%f.w,y=Math.floor(i/f.w);
 for(const [xx,yy] of [[x-1,y],[x+1,y],[x,y-1],[x,y+1]]){
  if(xx<0||yy<0||xx>=f.w||yy>=f.h)continue;const j=yy*f.w+xx;
  if(colour[j]&&!outside[j]){outside[j]=1;queue.push(j);}
 }
}
for(let y=Math.ceil(f.b[1]);y<f.b[1]+f.b[3];y++)for(let x=Math.ceil(f.b[0]);x<f.b[0]+f.b[2];x++){
 if(outside[y*f.w+x])continue;
 const k=(y*f.w+x)*4,c=rgba.slice(k,k+3),lo=Math.min(...c),d=Math.max(...c)-lo;
 if(d<90||Math.max(...c.map((v,i)=>Math.abs((v-lo)/d-(fg[i]-low)/span)))>.09)continue;
 cores++;if(!result.rgba[k+3])missing++;
 const out=result.rgba[k+3]?result.rgba:rgba;
 if(out[k]-out[k+1]>100&&out[k+2]-out[k+1]>65)residual++;
}
for(let i=0;i<outside.length;i++)if(outside[i])assert.equal(result.rgba[i*4+3],0,'retain crop-connected neighbouring ink');
assert.ok(cores>1400);assert.equal(missing,0);assert.equal(residual,0);
for(let y=0;y<f.h;y++)for(let x=0;x<f.w;x++)if(x<2||y<2||x>=f.w-2||y>=f.h-2)
 assert.equal(result.rgba[(y*f.w+x)*4+3],0,'keep crop/frame boundaries');
assert.equal(restore(rgba,f.w,f.h,f.b,f.palette,{...f.options,inferredRubyExclusions:[[0,0,f.w,f.h]]}),null,
 'a neighbouring region owns the bisected glyph: keep it');
const noRing=rgba.slice();for(let k=0;k<noRing.length;k+=4)if(Math.min(...noRing.slice(k,k+3))>=200)noRing.set([130,130,130],k);
assert.equal(restore(noRing,f.w,f.h,f.b,f.palette,f.options),null);
console.log('PASS clipped outlined glyph',JSON.stringify({cores,missing,residual,erased:result.erased}));
