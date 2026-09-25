// Real captured crops pin the separation of resolved lettering from preserved
// frame-connected artwork. Hashes pin both restoration paint and layout safety.
const fs=require('node:fs'),path=require('node:path'),z=require('node:zlib'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const source=fs.readFileSync(path.resolve(__dirname,'../../Aidoku/Core/Translation/NativeEngine/Overlay/BrowserSourcePanelRestoration.swift'),'utf8');
const script=source.match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const restore=new Function(script+';return aidokuRestoreSourcePanel;')();
const hash=a=>crypto.createHash('sha256').update(a).digest('hex');
const cases=JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/source-body-art-evidence.json')));
assert.equal(cases.length,6);
for(const f of cases){
 const rgba=new Uint8ClampedArray(z.inflateSync(Buffer.from(f.rgba,'base64'))),before=rgba.slice();
 const r=restore(rgba,f.w,f.h,f.b,f.palette,f.options);assert.ok(r,f.name+'/'+f.id);
 assert.equal(r.sourceGlyphsVerified===true,f.body,'resolved body remains distinct from whole-rectangle erasure');
 assert.equal(r.sourceErasureVerified,f.full,'protected drawing never becomes full erasure evidence');
 assert.equal(hash(r.rgba),f.rgbaSHA,'drawing and original-pixel restoration must be unchanged');
 assert.equal(hash(r.layoutSafe),f.safeSHA,'translation cannot gain permission to write over drawing');
 assert.deepEqual(rgba,before);assert.equal(restore.classificationCache,null);
 console.log('PASS body/art evidence '+f.name+'/'+f.id);
}
// Explicit auxiliary lettering cannot be released just because body ink resolved.
const begin=script.indexOf('let sourceGlyphsVerified=unresolved===0;');
const end=script.indexOf('// Texture outside',begin);assert.ok(begin>=0&&end>begin);
const proof=new Function('protectedInk','frameInk','w','auxiliary','unresolved','frameInterior',script+';'+script.slice(begin,end)+';return {body:sourceGlyphsVerified,full:sourceErasureVerified};');
const p=new Uint8Array(400),f=new Uint8Array(400);
assert.deepEqual(proof(p,f,20,[],0,10),{body:true,full:false});
assert.deepEqual(proof(p,f,20,[],1,0),{body:false,full:false});
p[5*20+5]=1;assert.deepEqual(proof(p,f,20,[[4,4,3,3]],0,0),{body:false,full:false});
p[105]=0;f[105]=1;assert.deepEqual(proof(p,f,20,[[4,4,3,3]],0,0),{body:false,full:false});
console.log('4 unresolved/auxiliary ownership controls passed');
// A new art-preserving candidate preceding an established partial candidate
// must not consume its placement first (actual holdout 1141 regression).
const view=fs.readFileSync(path.resolve(__dirname,'../../Aidoku/Core/Translation/NativeEngine/Overlay/BrowserOverlayView.swift'),'utf8');
const start=view.indexOf('let partialProofBudget='),finish=view.indexOf('// Retry remaining opaque captions',start);
assert.ok(start>=0&&finish>start);
const transaction=new Function('s','with(s){'+view.slice(start,finish)+'}');
const make=(id,full)=>({id,item:{id,sourceBounds:[0,0,.1,.1],sourceFrame:[0,0,100,100],auxiliaryInkRects:[]},c:{w:4,h:4,safe:new Uint8Array(16),erasureComplete:true,sourceErasureVerified:full,sourceGlyphsVerified:true},node:{dataset:{},getBoundingClientRect:()=>({})},core:[[0,0,1,1]],glyph:4});
const fresh=make('new',false),prior=make('prior',true),order=[];
const state={partialErasureCandidates:[fresh,prior],mount:{appendChild(){}},measurementHost:{remove(){}},plates:new Map([['new',{}],['prior',{}]]),certifiedErasure:new Set(),inks:new Map(),cleanupImageGeometry:null,rect:r=>r,
 document:{createRange:()=>({selectNodeContents(){},getBoundingClientRect:()=>({})})},aidokuHasAttachedLeadingInk:()=>false,aidokuHasLargePartialResidual:()=>false,aidokuMainbodyCellsClear:()=>false,
 typographyEntries:[{id:'new',fitBalloon(){order.push('new');return false}},{id:'prior',fitBalloon(){order.push('prior');return true}}]};
transaction(state);assert.deepEqual(order,['prior','new','new']);assert.equal(state.plates.has('prior'),false);assert.equal(state.plates.has('new'),true);
assert.equal(fresh.c.partialErasureCertified,undefined);assert.equal(fresh.node.dataset.sourceErasurePolicy,undefined);
assert.equal(prior.node.dataset.sourceErasureReleased,'[]','nonrectangular proof never releases a whole OCR box');
console.log('PASS existing placement priority, failed-fit rollback and nonrectangular release');
const auxiliary=make('auxiliary',false);auxiliary.c.sourceGlyphsVerified=false;
auxiliary.c.sourceRemainingInk=1;auxiliary.c.sourceCorePixels=100;
auxiliary.core.push([2,2,1,1]);let attempted=false;
transaction({...state,partialErasureCandidates:[auxiliary],plates:new Map([['auxiliary',{}]]),
 typographyEntries:[{id:'auxiliary',fitBalloon(){attempted=true;return true}}]});
assert.equal(attempted,false,'speck tolerance cannot authorize explicitly owned unresolved auxiliary text');
console.log('PASS residual-speck retry retains unresolved explicit auxiliary text');
