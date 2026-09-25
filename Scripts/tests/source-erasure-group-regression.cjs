// Exercise the actual production group reconciliation and certification helpers.
// node Scripts/tests/source-erasure-group-regression.cjs
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const view=fs.readFileSync(path.resolve(__dirname,'../../Aidoku/Core/Translation/NativeEngine/Overlay/BrowserOverlayView.swift'),'utf8');
const start=view.indexOf('        // Each source mask was classified'),end=view.indexOf('      }\n      if(certifiedErasure.size){',start);
assert.ok(start>=0&&end>start,'production group reconciliation block must be present');
const block=view.slice(start,end);
const typography=fs.readFileSync(path.resolve(__dirname,'../../Aidoku/Core/Translation/NativeEngine/Overlay/BrowserOverlayTypography.swift'),'utf8');
const match=typography.match(/static let script = #"""\n([\s\S]*?)\n    """#/);
assert.ok(match,'production certification helpers must be present');
const run=new Function('restoredPanelGeometry','erasureRetries','root','certifiedErasure','certificationBudget',
 match[1]+';'+block+';return certificationBudget;');
function make({alpha=0,safeValue=1,color=220}={}){const w=12,h=12,rgba=new Uint8ClampedArray(w*h*4);for(let i=0;i<w*h;i++)rgba.set([color,color,color,alpha],i*4);const c={w,h,x:0,y:0,sx:1,sy:1,iw:w,ih:h,frame:[0,0,w,h],safe:new Uint8Array(w*h).fill(safeValue),luminance:new Uint8Array(w*h).fill(100),erasureComplete:true,sourceErasureVerified:true};c.canvas={isConnected:true,width:w,height:h,getContext:()=>({getImageData:()=>({data:rgba})})};return{c,rgba}}
function test(name,f){f();console.log('PASS '+name)}
function scene(){const source=make(),donor=make({alpha:255}),item={},other={},i=5*12+5;source.c.safe[i]=0;const safe=source.c.safe.slice(),lum=source.c.luminance.slice();const pending={item,c:source.c,id:'0',node:{dataset:{}},coverage:[[2,2,8,8]],regions:[[2,2,8,8]],core:[[3,3,6,6]],glyph:4};return{source,donor,item,other,i,safe,lum,pending}}
function apply(s,entries,budget=524288){return run(new Map(entries||[[s.item,s.source.c],[s.other,s.donor.c]]),[s.pending],{contains:()=>true},(s.certified||(s.certified=new Set())),budget)}
test('opaque owned neighboring donors update only cloned unsafe cells',()=>{const s=scene(),safe=s.source.c.safe,lum=s.source.c.luminance;apply(s);assert.equal(s.source.c.safe[s.i],1);assert.equal(s.source.c.luminance[s.i],183);assert.equal(s.source.c.surfaceRevision,1);assert.ok(s.certified.has(s.item),'production certificate accepts complete group erasure');assert.notEqual(s.source.c.safe,safe);assert.notEqual(s.source.c.luminance,lum);assert.deepEqual(safe,s.safe);assert.deepEqual(lum,s.lum);for(let i=0;i<safe.length;i++)if(i!==s.i){assert.equal(s.source.c.safe[i],safe[i]);assert.equal(s.source.c.luminance[i],lum[i]);}});
for(const kind of ['partial-alpha','unsafe-donor','incomplete-mask'])test(kind+' cannot establish group ownership',()=>{const s=scene();if(kind==='partial-alpha')s.donor.rgba[(s.i+1)*4+3]=254;else if(kind==='unsafe-donor')s.donor.c.safe[s.i+1]=0;else s.donor.c.erasureComplete=false;apply(s);assert.equal(s.source.c.safe[s.i],0);assert.equal(s.source.c.surfaceRevision,undefined)});
test('a later partial mask invalidates earlier donor proof',()=>{const s=scene(),later=make({alpha:0});later.rgba[s.i*4+3]=128;apply(s,[[s.item,s.source.c],[s.other,s.donor.c],[{},later.c]]);assert.equal(s.source.c.safe[s.i],0)});
test('own later mask cannot be skipped during composite order',()=>{const s=scene();s.source.rgba[s.i*4+3]=255;apply(s,[[s.other,s.donor.c],[s.item,s.source.c]]);assert.equal(s.source.c.safe[s.i],0)});
test('later opaque donor can establish final visible background',()=>{const s=scene();s.source.rgba[s.i*4+3]=255;apply(s);assert.equal(s.source.c.safe[s.i],1)});
test('exhausted budget performs no surface mutation',()=>{const s=scene();assert.equal(apply(s,null,1),1);assert.deepEqual(s.source.c.safe,s.safe);assert.deepEqual(s.source.c.luminance,s.lum);assert.equal(s.source.c.surfaceRevision,undefined)});
test('unpainted neighboring ruby still vetoes the production certificate',()=>{
 const s=scene();
 for(const i of [4*12+11,5*12+11])s.source.c.safe[i]=0;
 for(let y=3;y<=7;y++)for(let x=10;x<12;x++)s.donor.rgba[(y*12+x)*4+3]=0;
 apply(s);
 assert.equal(s.source.c.safe[s.i],1,'independently proven body pixel is reconciled');
 assert.equal(s.source.c.safe[4*12+11],0,'unpainted ruby remains protected');
 assert.equal(s.certified.has(s.item),false,'real residual-lettering helper blocks certification');
});
console.log('9 production group erasure safety checks passed');
