const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),zlib=require('node:zlib');
const assert=require('node:assert/strict'),test=require('node:test');
const source=fs.readFileSync(path.join(__dirname,'../../Aidoku/Core/Translation/NativeEngine/Overlay/BrowserOverlayView.swift'),'utf8');
const extract=name=>{
 const start=source.indexOf('const '+name+' =');assert(start>=0);const brace=source.indexOf('{',start);let depth=1,end=brace+1;
 for(;depth&&end<source.length;end++){if(source[end]==='{')depth++;if(source[end]==='}')depth--;}
 assert.equal(depth,0);return source.slice(start,end)+';';
};
const api=vm.runInNewContext(extract('aidokuMainbodyCellsClear')+extract('aidokuHasLargePartialResidual')+';({clear:aidokuMainbodyCellsClear,large:aidokuHasLargePartialResidual})');
const w=80,h=100,glyph=20,core=[[40,20,20,60]],blank=()=>new Uint8Array(w*h).fill(1);
const ink=(s,x,y,width,height)=>{for(let yy=y;yy<y+height;yy++)for(let xx=x;xx<x+width;xx++)s[yy*w+xx]=0;};
test('partial proof accepts only safe actual body and explicit auxiliary cells',()=>{
 const s=blank();assert(api.clear(s,w,h,core));ink(s,30,20,3,4);assert(api.clear(s,w,h,core));
 assert(!api.clear(s,w,h,[...core,[30,20,3,4]]));ink(s,45,30,1,1);assert(!api.clear(s,w,h,core));
 s[30*w+45]=2;assert(!api.clear(s,w,h,core));
});
test('partial cell proof rejects missing, clipped or invalid source regions',()=>{
 const s=blank();assert(!api.clear(s,w,h,[]));assert(!api.clear(null,w,h,core));
 assert(!api.clear(s,w,h,[[-.01,20,20,20]]));assert(!api.clear(s,w,h,[[79,20,2,20]]));
});
test('two substantial exterior characters in reading order retain the card',()=>{
 const s=blank();ink(s,26,30,8,10);ink(s,26,47,8,10);assert(api.large(s,w,h,core,glyph,true));
});
test('tiny ruby and a lone uncertain mark do not block partial restoration',()=>{
 const s=blank();ink(s,35,30,3,4);ink(s,35,40,3,4);assert(!api.large(s,w,h,core,glyph,true));
 const single=blank();ink(single,26,30,8,10);assert(!api.large(single,w,h,core,glyph,true));
});
test('an actual closed boundary protects exterior artwork, but an opening cannot',()=>{
 const s=blank();ink(s,26,30,8,10);ink(s,26,47,8,10);ink(s,36,0,1,h);
 assert(!api.large(s,w,h,core,glyph,true));s[70*w+36]=1;assert(api.large(s,w,h,core,glyph,true));
});
test('horizontal reading and invalid masks receive the same protection',()=>{
 const s=blank();ink(s,25,8,8,10);ink(s,42,8,8,10);assert(api.large(s,w,h,[[20,20,40,30]],glyph,false));
 assert(api.large(null,w,h,core,glyph,true));assert(api.large(blank(),w,h,[[NaN,1,2,3]],glyph,true));
});
for(const f of JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/partial-mainbody-residuals.json'),'utf8')))
 test(`captured ${f.page}/${f.id} ${f.reject?'keeps large original words covered':'allows tiny exterior ruby'}`,()=>{
  const safe=new Uint8Array(zlib.inflateSync(Buffer.from(f.safe,'base64')));
  assert.equal(api.large(safe,f.w,f.h,f.core,f.glyph,f.vertical),f.reject);
 });
