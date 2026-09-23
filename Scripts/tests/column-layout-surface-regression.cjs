// Execute the production pixel gate, with a deterministic canvas sampling stub.
// Real font layout and rasterization are covered by ReaderColumnLayoutTests.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.resolve(__dirname, '../../Aidoku/Core/Translation/NativeEngine/Overlay/BrowserOverlayView.swift'), 'utf8');
const start = source.indexOf('    const columnItems = items.filter');
const end = source.indexOf('    const inpaintingEnabled =', start);
assert.ok(start > 0 && end > start);
const code = source.slice(start, end);
assert.ok(!code.includes('\\('), 'Unexpected Swift interpolation');
function run({art = false, glyphs = false, gradient = false, strongGradient = false, fold = false, step = false, image = true, palette = true} = {}) {
  const items = [0, 1, 2].map(i => ({x:20+i*35,y:10,width:6,height:100,
    sourceBounds:[.1+i*.175,.05,.03,.5],sourceFrame:[0,0,200,200],
    columnLayout:{x:10+i*48,y:10,width:44,height:60,balancedColumn:true}}));
  const root = {dataset:{}}, cleanupCanvas = {};
  let crop, reads = 0;
  const context = {
    drawImage(_image,x,y,width,height){crop={x,y,width,height};},
    getImageData(_x,_y,w,h){
      reads += w*h;
      const data = new Uint8ClampedArray(w*h*4);
      for(let y=0;y<h;y++)for(let x=0;x<w;x++){
        const px=crop.x+(x+.5)*crop.width/w,py=crop.y+(y+.5)*crop.height/h;
        const known=items.some(i=>px>=i.x&&px<=i.x+i.width&&py>=i.y&&py<=i.y+i.height);
        const ink = (art && px>34 && px<45 && py>20 && py<60) || (glyphs && known);
        const v=ink?20:gradient?240+Math.round(py/200*10):255;
        const rgb=strongGradient?[210-60*(py/200)**2,180-90*(py/200)**2,130-40*(py/200)**2]:[v,v,v];
        if(fold)for(let c=0;c<3;c++)rgb[c]-=60*Math.exp(-(((py-36)/12)**2));
        if(step&&py>35)for(let c=0;c<3;c++)rgb[c]-=65;
        data.set([...rgb,255],(y*w+x)*4);
      }
      return {data};
    }
  };
  vm.runInNewContext(code,{items,root,cleanupCanvas,cleanupContext:context,
    cleanupImageGeometry:null,sourceImage:image?{complete:true,naturalWidth:200,naturalHeight:200}:null,
    cachedSourceSample:()=>palette?{background:[255,255,255]}:null});
  assert.ok(reads<=4096,'bounded inspection budget');
  return {items,root};
}
for(const [name,options,accepted] of [
  ['open whitespace',{},true],['known source ink',{glyphs:true},true],
  ['smooth light gradient',{gradient:true},true],
  ['curved colored lighting',{strongGradient:true},true],['soft curtain fold',{strongGradient:true,fold:true},true],['hard colored boundary',{strongGradient:true,step:true},false],['art in a gutter',{art:true},false],
  ['unavailable source image',{image:false},false],['manual color mode',{palette:false},true]
]) {
  const result=run(options);
  assert.equal(result.root.dataset.balancedColumns,accepted?'3':'0',name);
  assert.equal(Boolean(result.items[0].balancedColumn),accepted,name);
  assert.equal(result.items[0].x,accepted?10:20,'ordinary placement retained on rejection');
  console.log(`PASS ${name}`);
}
console.log('9/9 column surface regressions passed');
