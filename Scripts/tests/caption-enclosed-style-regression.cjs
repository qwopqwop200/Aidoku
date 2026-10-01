// Frozen historical Web renderer reference; production native rendering is tested by AidokuFull.
const fs=require('node:fs'),vm=require('node:vm'),zlib=require('node:zlib'),assert=require('node:assert/strict'),path=require('node:path');
const dir=path.join(__dirname,'../../AidokuTests/Translation/LegacyBrowserOverlay');
const typography=fs.readFileSync(path.join(dir,'BrowserOverlayTypography.swift'),'utf8').split('static let script = #"""')[1].split('"""#')[0];
const color=fs.readFileSync(path.join(dir,'BrowserSourceTextColor.swift'),'utf8').match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const api=vm.runInNewContext('const getComputedStyle = node => node.style;'+color+typography+';({detect:aidokuEnclosedCaptionOutline,style:aidokuObservedCaptionStyle,apply:aidokuPreserveObservedCaptionStyle})');
const captures=JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/caption-enclosed-styles.json')));
for(const f of captures){
 const rgba=new Uint8ClampedArray(zlib.inflateSync(Buffer.from(f.rgba,'base64'))),copy=Buffer.from(rgba);
 const actual=api.detect(rgba,f.w,f.h,f.b,f.glyph,f.ink);
 assert.ok(actual,f.id+' omitted observed white interiors');
 assert.ok(Math.min(...actual.foreground)>=230,f.id+' must keep light fill');
 assert.deepEqual(Array.from(actual.stroke),f.ink,f.id+' must keep own outline RGB');
 assert.deepEqual(Buffer.from(rgba),copy,'source image immutable');
 assert.equal(api.detect(rgba,f.w,f.h,f.b,f.glyph,[0,0,0]),null,'neutral roles need independent corroboration');
 const styled=api.style(actual,6);assert.ok(styled&&styled.width<=1.8,'small Korean counters stay open');
}
// A solid chromatic glyph with compact white counters must not become white-fill
// lettering. This negative changes topology, not simply expected implementation data.
const w=80,h=160,rgba=new Uint8ClampedArray(w*h*4);for(let i=0;i<w*h;i++)rgba.set([255,255,255,255],i*4);
const rect=(x,y,ww,hh,c)=>{for(let yy=y;yy<y+hh;yy++)for(let xx=x;xx<x+ww;xx++)rgba.set([...c,255],(yy*w+xx)*4);};
for(let y=10;y<140;y+=30){rect(25,y,30,22,[155,69,123]);rect(35,y+6,8,8,[255,255,255]);}
assert.equal(api.detect(rgba,w,h,[10,0,70,160],30,[155,69,123]),null);
assert.equal(api.style({foreground:[250,250,250],stroke:null,confidence:{foreground:1}},12),null);
assert.equal(api.style({foreground:[250,250,250],stroke:[0,0,0],background:[0,0,0],confidence:{foreground:1,stroke:1}},12),null);
assert.equal(api.style({foreground:[0,0,0],stroke:[250,250,250],background:[0,0,0],confidence:{foreground:1,stroke:1}},12).width,2);
rgba[3]=0;assert.equal(api.detect(rgba,w,h,[10,0,70,160],30,[155,69,123]),null);
console.log(`PASS ${captures.length} actual source crops: enclosed outline roles, small-glyph width, bare dark caption and solid-counter negatives`);
const corpus=JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/source-color-diversity.json'))).fixtures;
const labels=JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/source-color-strokes.json'))).fixtures;
let negatives=0;
for(const label of labels){
 const f=corpus.find(f=>f.id===label.id);
 if(!f||!label.scored||label.expectedStroke||Math.max(...f.expected)-Math.min(...f.expected)<40)continue;
 const b=[f.bounds[0]*f.width,f.bounds[1]*f.height,(f.bounds[0]+f.bounds[2])*f.width,(f.bounds[1]+f.bounds[3])*f.height];
 const glyph=Math.min(b[2]-b[0],b[3]-b[1]);
 const rgba=new Uint8ClampedArray(zlib.inflateSync(Buffer.from(f.rgba,'base64')));
 assert.equal(api.detect(rgba,f.width,f.height,b,glyph,f.expected),null,'real plain colored lettering '+f.id);
 negatives++;
}
console.log(`PASS ${negatives} independent annotated plain-colored source crops stay unoutlined`);

// Production final style application: actual merged-caption palette and ring
// audit disagree with the closed-counter fallback. The native paper roles win.
const sampled={foreground:[220,46,153],stroke:null,confidence:{foreground:.9,stroke:0}};
const enclosed={foreground:[248,246,249],stroke:[226,41,153],confidence:{foreground:.85,stroke:.85}};
const paper={kind:'paper',core:[220,46,153],outline:[251,251,250],hug:1,uniform:.98};
function apply(sample,ring,evidence=enclosed){
 const node={style:{fontSize:'11px',color:'rgb(220,46,153)'},dataset:{sourceBackgroundColor:'inpainted',
  enclosedCaptionOutline:JSON.stringify(evidence),outlinedLettering:JSON.stringify(ring)}};
 api.apply({querySelector:()=>node},[{id:'3',sourceColorEligible:true}],()=>sample);
 return node;
}
const rejected=apply(sampled,paper);
assert.equal(rejected.style.color,'rgb(220,46,153)');
assert.equal(rejected.dataset.enclosedCaptionOutlineRejected,'paper-role-conflict');
assert.equal(rejected.dataset.observedCaptionStyle,undefined);
for(const ring of [null,{...paper,kind:'outline'},{...paper,core:[10,10,10]}]){
 const kept=apply(sampled,ring);
 assert.equal(kept.style.color,'rgb(248,246,249)');
 assert.equal(kept.style.webkitTextStrokeColor,'rgb(226,41,153)');
}
console.log('PASS actual merged-caption paper audit blocks inverted fallback; genuine enclosed outlines remain available');

const confident=(foreground,stroke)=>({foreground,stroke,confidence:{foreground:1,stroke:1}});
assert.equal(api.style(confident([255,255,255],[220,90,6]),7.5).width,1.8,
 'medium-contrast orange edge stays visible at phone scale');
assert.ok(api.style(confident([255,255,255],[155,69,123]),7.5).width<=1.2,
 'higher-contrast purple edge does not get an unnecessary thickening');
assert.ok(api.style(confident([255,255,255],[0,0,0]),6).width<=1.2,
 'compact neutral dialogue retains its thinner stroke');

const purple=captures.find(f=>f.id==='stroke-purple-1');
const purplePixels=new Uint8ClampedArray(zlib.inflateSync(Buffer.from(purple.rgba,'base64')));
const proof=api.detect(purplePixels,purple.w,purple.h,purple.b,purple.glyph,purple.ink);
const purpleSample={foreground:purple.ink,stroke:null,confidence:{foreground:1,stroke:0}};
const paperConflict={kind:'paper',core:purple.ink,outline:proof.foreground,hug:1,uniform:.98};
const corrected=apply(purpleSample,paperConflict,proof);
assert.equal(corrected.style.color,`rgb(${proof.foreground.join(',')})`);
assert.equal(corrected.dataset.enclosedCaptionOutlineRejected,undefined);
assert.equal(apply(purpleSample,paperConflict,{...proof,proof:undefined}).dataset.enclosedCaptionOutlineRejected,'paper-role-conflict');
console.log('PASS real closed-filament proof resolves chromatic paper ambiguity; unproved palette remains guarded');
