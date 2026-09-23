// Real missing-ruby capture: erase both reading glyphs without painting the
// balloon contour or the neighboring drawing. Run with node --test.
const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');
const source = fs.readFileSync(path.join(__dirname,
  '../../Aidoku/Core/Translation/NativeEngine/Overlay/BrowserSourcePanelRestoration.swift'), 'utf8')
  .match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const api = new Function(source + ';return {restore:aidokuRestoreSourcePanel,infer:aidokuInferVerticalRuby};')();
const fixtures = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures/source-inpainting-inferred-ruby.json')));
const pixels = f => new Uint8ClampedArray(zlib.inflateSync(Buffer.from(f.rgba, 'base64')));
const inside = (x,y,r,pad=0) => x>=r[0]-pad&&y>=r[1]-pad&&x<r[0]+r[2]+pad&&y<r[1]+r[3]+pad;
for (const f of fixtures) test(`${f.name}: body and unannotated ruby disappear, artwork stays`, () => {
  const rgba=pixels(f), before=rgba.slice();
  const out=api.restore(rgba,f.w,f.h,f.b,f.palette,{readabilityGate:true,vertical:true});
  assert(out);assert.deepEqual(rgba,before);
  let ruby=0,protectedInk=0;
  for(let y=0;y<f.h;y++)for(let x=0;x<f.w;x++){
    const p=(y*f.w+x)*4;
    if(Math.max(...rgba.subarray(p,p+3))>=110)continue;
    if(inside(x,y,f.ruby)){
      ruby++;assert.equal(out.rgba[p+3],255,`ruby core remains at ${x},${y}`);
      assert(Math.min(...out.rgba.subarray(p,p+3))>=245);
    }else if(!inside(x,y,f.b,3)&&!inside(x,y,f.ruby,8)){
      protectedInk++;assert.equal(out.rgba[p+3],0,`artwork erased at ${x},${y}`);
    }
  }
  assert(ruby>(f.minimumRubyPixels||200));assert(protectedInk>100);
});
test('a neighboring OCR region retains ownership of its lettering', () => {
  const f=fixtures[0],rgba=pixels(f);
  const out=api.restore(rgba,f.w,f.h,f.b,f.palette,
    {readabilityGate:true,vertical:true,inferredRubyExclusions:[f.ruby]});
  assert(out);
  let protectedRuby=0;
  for(let y=0;y<f.h;y++)for(let x=0;x<f.w;x++){
    const p=(y*f.w+x)*4;
    if(inside(x,y,f.ruby)&&Math.max(...rgba.subarray(p,p+3))<110&&!out.rgba[p+3])protectedRuby++;
  }
  assert(protectedRuby>200);
});
test('one isolated small glyph cannot establish an unannotated ruby column', () => {
  const f=fixtures[0],rgba=pixels(f);
  for(let y=220;y<290;y++)for(let x=128;x<180;x++)rgba.set([255,255,255,255],(y*f.w+x)*4);
  const raw=Uint8Array.from({length:f.w*f.h},(_,i)=>Math.max(...rgba.subarray(i*4,i*4+3))<110?1:0);
  assert.deepEqual(api.infer(raw,rgba,f.w,f.h,f.b,f.palette.background),[]);
});
test('a rule between the body and a small column prevents ruby ownership', () => {
  const f=fixtures[0],rgba=pixels(f),b=[f.b[0]-25,f.b[1],f.b[2],f.b[3]];
  for(let y=150;y<290;y++)rgba.set([0,0,0,255],(y*f.w+120)*4);
  const raw=Uint8Array.from({length:f.w*f.h},(_,i)=>Math.max(...rgba.subarray(i*4,i*4+3))<110?1:0);
  assert.deepEqual(api.infer(raw,rgba,f.w,f.h,b,f.palette.background),[]);
});
test('aligned solid dots alone cannot establish a missing reading column', () => {
  const w=120,h=200,rgba=new Uint8ClampedArray(w*h*4).fill(255),raw=new Uint8Array(w*h);
  for(const top of [50,60,70])for(let y=top;y<top+2;y++)for(let x=92;x<94;x++){
    raw[y*w+x]=1;rgba.set([0,0,0,255],(y*w+x)*4);
  }
  assert.deepEqual(api.infer(raw,rgba,w,h,[50,20,30,160],[255,255,255]),[]);
});
