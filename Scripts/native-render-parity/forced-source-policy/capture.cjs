const fs=require('node:fs'),path=require('node:path'),zlib=require('node:zlib');
const [root,output]=process.argv.slice(2),reference=path.join(root,'Scripts/native-render-parity/reference-source');
const script=name=>fs.readFileSync(path.join(reference,name+'.swift'),'utf8').match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const adapter=fs.readFileSync(path.join(reference,'BrowserSourceGlyphConservative.swift'),'utf8');
let glyph=script('BrowserSourceGlyphSegmentation');
for(const [,a,b] of adapter.matchAll(/of:\s*"([^"]+)"\s*,\s*with:\s*"([^"]+)"/g))glyph=glyph.replace(a,b);
const force=new Function(script('BrowserSourceTextColor')+script('BrowserSourcePanelRestoration')+glyph+
  script('BrowserForcedInpaintQuality')+script('BrowserForcedSourceInpainting')+';return aidokuForceInpaintSource;')();
const fixtures=[];
function make(name,{background=[250,250,250],foreground=[20,20,20],stroke=null,box=[20,18,56,40],options={},count=3,gradient=false,art=false,edge=false,alpha=255,extra=false}={}) {
 const w=96,h=80,rgba=new Uint8ClampedArray(w*h*4);
 for(let y=0;y<h;y++)for(let x=0;x<w;x++)rgba.set(background.map(v=>gradient?v+x*.12+y*.08:v).concat(alpha),(y*w+x)*4);
 if(art)for(let y=0;y<h;y++)for(let x=47;x<55;x++)rgba.set([35,100,150,255],(y*w+x)*4);
 for(let k=0;k<count;k++){
  const l=(edge?2:27)+k*16,t=25;
  if(stroke)for(let y=t-3;y<t+27;y++)for(let x=l-3;x<l+8;x++)rgba.set(stroke.concat(255),(y*w+x)*4);
  for(let y=t;y<t+24;y++)for(let x=l;x<l+5;x++)rgba.set(foreground.concat(255),(y*w+x)*4);
 }
 if(extra)for(const y of [17,19])rgba.set(foreground.concat(255),(y*w+78)*4);
 const palette={foreground,background,stroke,confidence:{foreground:.9,background:.9,stroke:stroke ? .9 : 0}};
 fixtures.push({name,w,h,rgba:Array.from(rgba),box,palette,options});
}
make('glyph-flat-safe',{options:{requireSafeDonors:true}});
make('glyph-flat');
make('rect-single-component',{count:1});
make('rect-unsegmented-bright',{foreground:[180,180,180],count:1});
make('glyph-gradient',{background:[212,216,218],gradient:true});
make('rect-gradient',{count:1,background:[210,211,214],gradient:true});
make('outlined-gray',{background:[150,158,167],stroke:[255,255,255]});
make('outlined-gray-safe',{background:[150,158,167],stroke:[255,255,255],options:{requireSafeDonors:true,glyphSize:20}});
make('art-edge-safe',{art:true,options:{requireSafeDonors:true}});
make('art-edge-ordinary',{art:true});
make('incomplete-safe',{extra:true,options:{requireSafeDonors:true}});
make('cropped-edge',{edge:true,box:[0,18,56,40]});
make('cropped-edge-safe',{edge:true,box:[0,18,56,40],options:{requireSafeDonors:true}});
make('unsegmented-display-rejected',{count:1,options:{requireSafeDonors:true}});
make('incomplete-ordinary',{extra:true});
make('source-ink-hypothesis',{options:{requireSafeDonors:true}});
fixtures.at(-1).palette={...fixtures.at(-1).palette,foreground:[95,80,70],sourceInk:{foreground:[20,20,20],background:[250,250,250],confidence:{background:.9}}};
make('excluded-and-protected-masks');
fixtures.at(-1).options={excludedMask:Array.from({length:96*80},(_,i)=>i%96<18?1:0),protected:Array.from({length:96*80},(_,i)=>i%96>78?1:0)};
make('donors-completely-blocked-safe',{options:{requireSafeDonors:true,donorExcluded:[[0,0,96,80]]}});
make('donors-completely-blocked',{options:{donorExcluded:[[0,0,96,80]]}});
make('overlapping-neighbor',{options:{excluded:[[24,24,18,26]]}});
make('donor-only-overlap',{options:{donorExcluded:[[24,24,18,26]]}});
make('polygon-ownership',{options:{polygons:[[[20,18],[76,20],[76,60],[20,58]]],excludedPolygons:[[[66,18],[90,18],[90,62],[66,62]]]}});
make('auxiliary-trailing',{box:[20,18,25,40],options:{auxiliary:[[49,22,18,30]],trailing:12,vertical:true}});
make('alpha-donors-rejected',{alpha:200});
make('nil-palette-rect',{count:1});fixtures.at(-1).palette=null;
make('background-only-rect',{count:1});fixtures.at(-1).palette={background:[250,250,250],confidence:{background:.9}};
make('source-ink-only-safe',{options:{requireSafeDonors:true}});fixtures.at(-1).palette={sourceInk:fixtures.at(-1).palette};
make('source-ink-only-with-unowned-stroke',{options:{requireSafeDonors:true}});fixtures.at(-1).palette={stroke:[255,255,255],confidence:{stroke:.9},sourceInk:fixtures.at(-1).palette};
make('incomplete-source-ink-object',{options:{requireSafeDonors:true}});fixtures.at(-1).palette.sourceInk={background:[250,250,250]};
make('null-background-dark-glyph',{options:{requireSafeDonors:true}});fixtures.at(-1).palette.background=null;
make('null-background-muted-display',{foreground:[180,180,180],options:{requireSafeDonors:true}});fixtures.at(-1).palette.background=null;
make('empty-owned-crop',{count:0,box:[110,110,10,10]});
make('invalid-crop',{count:0,box:[20,20,0,10]});
for(const name of ['source-inpainting-captured-residuals','source-inpainting-owned-recovery','outlined-caption-restoration','source-segmented-restoration']) {
 const input=JSON.parse(fs.readFileSync(path.join(root,'Scripts/tests/fixtures',name+'.json')));
 const rows=Array.isArray(input)?input:input.fixtures||[];
 for(const f of rows.slice(0,4))if(f.palette&&f.rgba){
  const rgba=zlib.inflateSync(Buffer.from(f.rgba,'base64'));
  if(rgba.length!==f.w*f.h*4)continue;
  fixtures.push({name:name+'/'+f.name+'/'+f.id,w:f.w,h:f.h,rgba:Array.from(rgba),box:f.b||f.box,palette:f.palette,options:f.options||{}});
 }
}
function normalize(value){if(ArrayBuffer.isView(value))return Array.from(value);if(Array.isArray(value))return value.map(normalize);if(value&&typeof value==='object')return Object.fromEntries(Object.entries(value).map(([k,v])=>[k,normalize(v)]));return value;}
for(const f of fixtures){
 const input=Uint8ClampedArray.from(f.rgba),before=input.slice();
 const result=force(input,f.w,f.h,f.box,f.palette,f.options);
 if(Buffer.compare(Buffer.from(before),Buffer.from(input)))throw Error('Oracle mutates original '+f.name);
 f.expected={failure:force.lastFailure,result:normalize(result)};
}
fs.writeFileSync(output,JSON.stringify(fixtures));
console.log(JSON.stringify(fixtures.map(f=>({name:f.name,accepted:!!f.expected.result,method:f.expected.result?.method,mask:f.expected.result?.forcedMaskMode,failure:f.expected.failure}))));
