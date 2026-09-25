// Production paper proposals preserve neighboring ink and require a committed
// source cleanup before outline-only text can replace a panel.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const source=fs.readFileSync(path.resolve(__dirname,'../../Aidoku/Core/Translation/NativeEngine/Overlay/BrowserSourcePanelRestoration.swift'),'utf8');
const script=source.match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const api=new Function(script+';return {paper:aidokuEnclosedPaperRestore,local:aidokuLocalComponentRestore,outline:aidokuOutlineSourceResolved};')();
const w=80,h=90,b=[20,20,30,45],rgba=new Uint8ClampedArray(w*h*4).fill(255);
function ink(x,y,ww,hh){for(let yy=y;yy<y+hh;yy++)for(let xx=x;xx<x+ww;xx++){const i=(yy*w+xx)*4;rgba[i]=rgba[i+1]=rgba[i+2]=0;}}
ink(25,25,3,12);ink(34,25,3,12);ink(25,30,12,3);ink(25,45,12,3);ink(30,45,3,12);
const original=rgba.slice(),paper=api.paper(rgba,w,h,b);
assert.ok(paper?.sourceErasureVerified);assert.ok(paper.erased>0);assert.deepEqual(rgba,original);
for(let i=0;i<w*h;i++)if(paper.rgba[i*4+3])assert.equal(rgba[i*4],0,'only enclosed original ink is painted');
assert.equal(api.paper(rgba,w,h,b,{excluded:[[24,24,15,15]]}),null,'another owner cannot be erased');
for(const a of [[-1,1,4,4],[1,1,Infinity,4],[79,1,4,4]])assert.equal(api.paper(rgba,w,h,b,{auxiliary:[a]}),null);
ink(0,20,80,2);const bordered=api.paper(rgba,w,h,b);assert.ok(bordered);assert.equal(bordered.sourceErasureVerified,false);
for(let x=0;x<w;x++)assert.equal(bordered.rgba[(20*w+x)*4+3],0,'frame-connected drawing survives');
const c={w,h,safe:new Uint8Array(w*h).fill(1),iw:80,sx:1,frame:[0,0,80,90],sourceGlyphsVerified:true};
assert.equal(api.outline(c,[b]),true);
for(let y=28;y<38;y++)for(let x=28;x<36;x++)c.safe[y*w+x]=0;
assert.equal(api.outline(c,[b]),false,'unresolved central original letters veto an outline');
assert.equal(api.outline({...c,safe:null},[b]),false);
assert.equal(api.outline({...c,sourceGlyphsVerified:false},[b]),false);
const colored=original.slice();for(let i=0;i<w*h;i++)if(colored[i*4]===255){colored[i*4]=240;colored[i*4+1]=210;colored[i*4+2]=200;}
const local=api.local(colored,w,h,b,{});assert.ok(local?.sourceErasureVerified);
const excluded=api.local(colored,w,h,b,{}, {excluded:[[24,24,15,15]]});
assert.ok(!excluded?.sourceErasureVerified);
if(excluded)for(let y=24;y<39;y++)for(let x=24;x<39;x++)assert.equal(excluded.rgba[(y*w+x)*4+3],0);
assert.equal(api.local(colored,w,h,b,{}, {auxiliary:[[1,1,Infinity,2]]}),null);
console.log('PASS paper and local proposals: original pixels, neighbors, frame, auxiliary bounds and outline residual veto');
const z=require('node:zlib'),crypto=require('node:crypto');
for(const f of JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/source-paper-proposals.json')))){
 const image=new Uint8ClampedArray(z.inflateSync(Buffer.from(f.rgba,'base64'))),before=image.slice();
 const r=api.local(image,f.w,f.h,f.b,f.palette,f.options);assert.ok(r);
 assert.equal(r.sourceErasureVerified,f.expectedFull);
 assert.equal(crypto.createHash('sha256').update(r.rgba).digest('hex'),f.rgbaSHA);
 const c={w:f.w,h:f.h,safe:r.layoutSafe,sourceGlyphsVerified:r.sourceGlyphsVerified,sourceErasureVerified:r.sourceErasureVerified,iw:f.w*2,sx:1,frame:[0,0,f.w,f.h]};
 assert.equal(api.outline(c,[f.b]),f.expectedOutline,'retained source shapes cannot become outline-only evidence');
 assert.deepEqual(image,before);console.log('PASS captured paper proposal '+f.name+'/'+f.id);
}
