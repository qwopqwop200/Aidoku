// Real native crop supplied by the replay; no image display or provider request.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const base=path.resolve(__dirname,'../../AidokuTests/Translation/LegacyBrowserOverlay');
const source=n=>fs.readFileSync(path.join(base,n+'.swift'),'utf8').match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const color=source('BrowserSourceTextColor'),script=source('BrowserSourcePanelRestoration');
const make=s=>new Function(color+s+';return aidokuRestoreChromaticBalloonGlyphs;')();
const restore=make(script),baseline=make(script.replace('Math.max(3,Math.min(8,Math.ceil(glyph*.25))):3','3:3'));
const f=JSON.parse(fs.readFileSync(process.argv[2]))[0],rgba=new Uint8ClampedArray(f.rgba),before=rgba.slice();
assert.equal(baseline(rgba,f.w,f.h,f.b,f.palette,f.options),null,'reproduce the detached-core rejection');
const result=restore(rgba,f.w,f.h,f.b,f.palette,f.options);
assert.ok(result?.sourceErasureVerified&&result.observedDarkInk);assert.equal(result.sourceRemainingInk,0);assert.deepEqual(rgba,before);
let total=0,residual=0,unpainted=0;
// Independent original dark-core threshold, before inspecting candidate alpha.
for(let y=Math.ceil(f.b[1]);y<f.b[1]+f.b[3];y++)for(let x=Math.ceil(f.b[0]);x<f.b[0]+f.b[2];x++){
 const k=(y*f.w+x)*4;if(Math.max(...rgba.slice(k,k+3))>38)continue;
 total++;const p=result.rgba[k+3]?result.rgba:rgba;
 if(Math.max(...p.slice(k,k+3))<=38)residual++;
 if(!result.rgba[k+3])unpainted++;
}
assert.ok(total>=640);assert.equal(residual,0);assert.equal(unpainted,0);
for(let y=0;y<f.h;y++)for(let x=0;x<f.w;x++)if(x<2||y<2||x>=f.w-2||y>=f.h-2)
 assert.equal(result.rgba[(y*f.w+x)*4+3],0,'do not alter crop/frame boundaries');
const noRing=rgba.slice();for(let k=0;k<noRing.length;k+=4)if(Math.min(...noRing.slice(k,k+3))>=200)noRing.set([130,130,130],k);
assert.equal(restore(noRing,f.w,f.h,f.b,f.palette,f.options),null);
const palette=structuredClone(f.palette);(palette.sourceInk||palette).confidence.stroke=0;
assert.equal(restore(rgba,f.w,f.h,f.b,palette,f.options),null);
console.log('PASS real detached dark-core fixture',JSON.stringify({originalCorePixels:total,residual,unpainted,erased:result.erased}));
