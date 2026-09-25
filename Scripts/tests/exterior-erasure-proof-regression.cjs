// Extract the live production certificate; no copied implementation.
const fs=require('fs'),path=require('path'),assert=require('assert'),vm=require('vm');
const source=fs.readFileSync(process.env.CAPTION_SOURCE||path.resolve(__dirname,'../../Aidoku/Core/Translation/NativeEngine/Overlay/BrowserOverlayView.swift'),'utf8');
const start=source.indexOf('const certifyOccludedExterior='),end=source.indexOf('\n        // Certify each',start);
assert(start>=0&&end>start);
const run=(c,core,glyph,budget=262144)=>vm.runInNewContext('let exteriorProofBudget=budget;'+source.slice(start,end)+';certifyOccludedExterior(c,core,glyph)',{c,core,glyph,budget,Uint8Array,Int32Array,Set,Math,Array});
const make=()=>{const w=50,h=50,safe=new Uint8Array(w*h).fill(1);for(let y=0;y<h;y++)safe[y*w+24]=0;safe[20*w+27]=safe[21*w+27]=0;return {w,h,safe,sourceErasureVerified:true,erasureComplete:true};};
let n=0;const test=(name,fn)=>{fn();console.log('PASS '+name);n++};const core=[[10,15,10,10]],glyph=8;
test('continuous contour occludes exterior component',()=>{const c=make(),old=c.safe.slice(),r=run(c,core,glyph);assert(r&&r.ignored===2);assert.deepStrictEqual(c.safe,old);assert.equal(r.safe[20*50+27],1);assert.equal(r.safe[20*50+24],0)});
test('gap toward original remains unsafe',()=>{const c=make();c.safe[20*50+24]=c.safe[21*50+24]=1;assert.equal(run(c,core,glyph),null)});
test('visible ruby before contour stays blocking',()=>{const c=make();c.safe[20*50+22]=c.safe[21*50+22]=0;assert.equal(run(c,core,glyph),null)});
test('owned source remnants stay blocking',()=>{const c=make();c.safe[20*50+16]=c.safe[21*50+16]=0;assert.equal(run(c,core,glyph),null)});
test('unverified source rejected',()=>{const c=make();c.sourceErasureVerified=false;assert.equal(run(c,core,glyph),null)});
test('incomplete source rejected',()=>{const c=make();c.erasureComplete=false;assert.equal(run(c,core,glyph),null)});
test('bounded scan quota fails closed',()=>assert.equal(run(make(),core,glyph,1),null));
test('auxiliary source on exterior side defeats occlusion',()=>assert.equal(run(make(),[...core,[29,15,5,10]],glyph),null));
test('an unprobed opening in the same connected contour cannot certify ruby as exterior',()=>{
 const w=140,h=140,safe=new Uint8Array(w*h).fill(1);
 // An open contour is still one edge-connected component via the right edge.
 // Its gap exposes a source-edge point missed by the six sampled rays.
 for(let y=0;y<h;y++){if(y<58||y>62)safe[y*w+90]=0;safe[y*w+139]=0;}
 for(let x=90;x<w;x++){safe[x]=0;safe[(h-1)*w+x]=0;}
 safe[70*w+100]=safe[71*w+100]=0;
 for(let step=1;step<=20;step++)assert.equal(safe[(70-step)*w+100-step],1,'clear ray to source point (80,50)');
 const c={w,h,safe,sourceErasureVerified:true,erasureComplete:true};
 assert.equal(run(c,[[10,20,70,100]],24),null,'visible omitted text must continue blocking panel release');
});
test('fractionally overlapping source cells remain owned',()=>{
 const c=make();c.safe.fill(1);for(let y=0;y<c.h;y++)c.safe[y*c.w+11]=0;
 c.safe[20*c.w+10]=c.safe[21*c.w+10]=0;
 assert.equal(run(c,[[10.4,15,3.6,10]],8),null);
});
test('duplicate source seeding consumes bounded allowance',()=>{
 assert.equal(run(make(),Array(100).fill(core[0]),glyph,5000),null);
});
console.log(n+' exterior proof checks passed');
