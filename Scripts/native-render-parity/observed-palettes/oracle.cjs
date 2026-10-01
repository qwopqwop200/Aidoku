// Frozen pre-migration source-color policy; no production JavaScript execution.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),zlib=require('node:zlib');
const root=path.resolve(__dirname,'../../..');
const frozen=fs.readFileSync(path.join(root,'AidokuTests/Translation/LegacyReaderTranslationRenderScript.swift'),'utf8');
const match=frozen.match(/static let BrowserSourceTextColor = """\n([\s\S]*?)\n    """/);
if(!match)throw Error('frozen BrowserSourceTextColor oracle unavailable');
const context=vm.createContext({});
vm.runInContext(match[1]+`\nglobalThis.observe=(rgba,w,h,box,result,hint)=>{
const glyphs=aidokuObservedGlyphPalette(rgba,w,h,box,hint);
const lettering=aidokuObservedLetteringInk(rgba,w,h,box);
const display=aidokuResolveDisplayGlyphs(result,glyphs);
const stroke=aidokuObservedStrokePalette(rgba,w,h,box,glyphs,display,result);
return {glyphs,lettering,display,stroke,observedInk:aidokuSourceObservedDisplayInk(result),displayInk:aidokuSourceDisplayInk(result)};
};globalThis.estimate=aidokuEstimateSourceColors;`,context);
const {raster,rect,resize}=require(path.join(root,'Scripts/tests/source-color-test-harness.cjs'));
const cases=[];
function add(id,rgba,width,height,box,result=null) {
  if(!result)result=context.estimate(rgba,width,height);
  const hint=result?.foreground&&result?.background?{foreground:result.foreground,background:result.background}:null;
  const expected=context.observe(new Uint8ClampedArray(rgba),width,height,box,result,hint);
  cases.push({id,rgba:Buffer.from(rgba).toString('base64'),width,height,box,result,hint,expected});
}
for(const background of [[255,255,255],[20,35,54],[232,161,95]])for(const kind of ['flat','frame','art','glyph','outlined']) {
  const image=raster(160,100,background);
  if(kind==='frame') {
    rect(image,4,4,152,3,[3,3,3]);rect(image,4,93,152,3,[3,3,3]);
    rect(image,4,4,3,92,[3,3,3]);rect(image,153,4,3,92,[3,3,3]);
  }
  for(const x of [30,65,100]) {
    if(kind==='art')rect(image,x,30,20,40,[63,113,42]);
    if(kind==='outlined') {
      for(let yy=27;yy<73;yy++)for(let xx=x-3;xx<x+23;xx++) {
        const gx=xx-x,gy=yy-30;
        let hit=false;
        for(let dy=-3;dy<=3;dy++)for(let dx=-3;dx<=3;dx++) {
          const sx=gx+dx,sy=gy+dy;
          if(dx*dx+dy*dy<=9&&sx>=0&&sx<20&&sy>=0&&sy<40&&(sx<3||sx>=17||(sy>=18&&sy<21)))hit=true;
        }
        if(hit)rect(image,xx,yy,1,1,[255,255,255]);
      }
    }
    if(kind==='glyph'||kind==='outlined') {
      rect(image,x,30,3,40,[180,42,59]);rect(image,x+17,30,3,40,[180,42,59]);rect(image,x,48,20,3,[180,42,59]);
    }
  }
  add('synthetic-'+background.join('-')+'-'+kind,image.data,160,100,[10,10,140,80]);
}
for(const name of ['source-color-diversity.json','source-color-stroke-confirmation.json']) {
  const fixtures=JSON.parse(fs.readFileSync(path.join(root,'Scripts/tests/fixtures',name))).fixtures;
  for(const fixture of fixtures) {
    const original=new Uint8ClampedArray(zlib.inflateSync(Buffer.from(fixture.rgba,'base64')));
    const scale=Math.min(1,Math.sqrt(24576/(fixture.width*fixture.height)));
    const width=Math.max(8,Math.floor(fixture.width*scale)),height=Math.max(8,Math.min(Math.floor(24576/width),Math.floor(fixture.height*scale)));
    const image={naturalWidth:fixture.width,naturalHeight:fixture.height,data:original};
    const rgba=resize(image,0,0,fixture.width,fixture.height,width,height);
    const bounds=fixture.bounds||[0,0,1,1];
    const box=[bounds[0]*width,bounds[1]*height,bounds[2]*width,bounds[3]*height];
    add(fixture.id,rgba,width,height,box);
  }
}
const opaque=raster(80,80,[255,255,255]);opaque.data[3]=0;
add('alpha-rejection',opaque.data,80,80,[5,5,70,70],{});
// Independently corroborated pipeline results exercise preservation branches,
// including widthEvidence null versus omitted and distinct fill/stroke roles.
const reasons=[
  'matching colored glyph interiors inside observed white outlines in independent strips',
  'agreeing native detail palettes preserve fill and outline roles',
  'enclosed glyph fill and distinct enclosing source stroke',
  'repeated colored interiors enclosed by source white outlines',
  'repeated dark glyph interiors enclosed by white source outlines',
  'observed glyph fill and following halo'
];
for(const fixture of [...cases].filter(c=>c.result?.foreground&&c.result?.stroke).slice(0,12)) {
  for(const reason of reasons) {
    const result={...fixture.result,widthEvidence:{samplePixels:2,glyphPixels:20,relativeToGlyph:.1,
      method:'outer stroke boundary distance to validated ink; external Manhattan band'},
      lettering:{color:fixture.result.stroke,pixels:48,components:4,bands:4,exterior:.01},
      confidence:{...fixture.result.confidence,foreground:.9,background:.8,stroke:.8,reason}};
    add(fixture.id+'-'+reason,Buffer.from(fixture.rgba,'base64'),fixture.width,fixture.height,fixture.box,result);
  }
}
for(const result of [{foreground:[-1,0,0]}, {displayForeground:[256,0,0]}, {foreground:[10,20,30],displayEvidence:{color:[260,0,0]}},
  {foreground:[255,255,255],background:[255,255,255],stroke:[130,30,50],confidence:{stroke:.8}},
  {foreground:[0,0,0],background:[255,255,255],displayEvidence:{color:[120,120,120]},confidence:{foreground:.9}}]) {
  const image=raster(80,80,[230,230,230]);
  add('display-validation-'+cases.length,image.data,80,80,[5,5,70,70],result);
}
fs.writeFileSync(process.argv[2],JSON.stringify(cases));
console.log(JSON.stringify({cases:cases.length}));
