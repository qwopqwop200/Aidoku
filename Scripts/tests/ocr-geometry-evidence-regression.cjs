// Frozen historical Web renderer reference; production native rendering is tested by AidokuFull.
// Exercise production geometry, color and glyph code with independent pixel labels.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const root=path.resolve(__dirname,'../../AidokuTests/Translation/LegacyBrowserOverlay');
const script=name=>fs.readFileSync(path.join(root,name+'.swift'),'utf8').match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const api=new Function(script('BrowserSourceTextColor')+script('BrowserSourceGlyphSegmentation')+
  ';return {geometry:aidokuOCRGeometryMask,colors:aidokuEstimateOCRSourceColors,segment:aidokuForcedTextMask}')();
const w=144,h=96,n=w*h,rgba=new Uint8ClampedArray(n*4);
for(let i=0;i<n;i++)rgba.set([255,255,255,255],i*4);
function rect(x,y,width,height,color){for(let yy=y;yy<y+height;yy++)for(let xx=x;xx<x+width;xx++)rgba.set([...color,255],(yy*w+xx)*4);}
function glyph(x,y,color){rect(x,y,3,20,color);rect(x+11,y,3,20,color);rect(x,y+8,14,3,color);}
const own=[[10,8],[66,8],[66,82],[10,82]],neighbor=[[84,6],[140,6],[140,90],[84,90]];
for(const y of [12,36,60])glyph(28,y,[28,58,126]);
for(const x of [88,110])for(const y of [10,34,58])glyph(x,y,[194,30,40]);
const unchanged=rgba.slice(),ownership=api.geometry(w,h,[own],[neighbor],1);
const palette=api.colors(rgba,w,h,ownership);
assert.ok(palette.foreground,'owned repeated source glyphs resolve a foreground');
assert.ok(palette.foreground.every((v,i)=>Math.abs(v-[28,58,126][i])<=8),JSON.stringify(palette));
assert.deepEqual(rgba,unchanged,'geometry never fabricates surface pixels');
const result=api.segment(rgba,w,h,[10,8,56,74],{foreground:[28,58,126],background:[255,255,255]},
  {polygons:[own],excludedPolygons:[neighbor],vertical:true});
assert.ok(result);
for(let y=6;y<90;y++)for(let x=84;x<140;x++)assert.equal(result[y*w+x],0,'other OCR lettering untouched');
// A slanted quad leaves most rectangular corners unowned. Even glyph-like
// disconnected artwork in those corners must not be accepted by hue alone.
const diamond=[[72,6],[125,48],[72,90],[19,48]],geo=api.geometry(w,h,[diamond],[],2);
assert.equal(geo[10*w+22],0);assert.equal(geo[48*w+72],1);
assert.equal(api.geometry(w,h,[[[1,1],[2,2],[3,3]]]),null,'degenerate geometry abstains');
assert.equal(api.geometry(w,h,[[[1,1],[NaN,3],[8,8]]]),null,'nonfinite geometry abstains');
const fringe=api.geometry(40,30,[[[8,8],[20,8],[20,20],[8,20]]],[[[21,8],[32,8],[32,20],[21,20]]],7);
assert.equal(fringe[12*40+20],1,'one-pixel glyph fringe remains owned');
assert.equal(fringe[12*40+22],0,'neighbour owns its fringe');
assert.equal(fringe[12*40+12],1,'overlap never removes own core');
console.log('PASS: owned ink RGB, unchanged source, adjacent OCR protection, slanted corners, outline fringe, invalid geometry');
// Real output_hard failure shape: sourceInk omitted stroke, while the separate
// display observer certified a white enclosing band around the same purple ink.
for(let i=0;i<n;i++)rgba.set([140,160,190,255],i*4);
for(const y of [12,36,60]){
 rect(25,y-3,9,26,[250,250,250]);rect(36,y-3,9,26,[250,250,250]);
 rect(25,y+5,20,9,[250,250,250]);glyph(28,y,[70,71,136]);
}
const observed={foreground:[70,71,136],background:[140,160,190],stroke:[250,250,250],confidence:{stroke:.7},
 sourceInk:{foreground:[68,68,137],background:[140,160,190],stroke:null,confidence:{background:.8}}};
const outlined=api.segment(rgba,w,h,[10,8,56,74],observed,{polygons:[own],vertical:true});
assert.ok(outlined);assert.equal(outlined[22*w+25],1,'independently certified white source outline must erase');
const unrelated={...observed,foreground:[210,30,40]};
const untrusted=api.segment(rgba,w,h,[10,8,56,74],unrelated,{polygons:[own],vertical:true});
assert.ok(untrusted);assert.equal(untrusted[22*w+25],0,'outline from a different ink cannot certify this glyph');
console.log('PASS: source/display palette agreement recovers white outline; different ink abstains');
