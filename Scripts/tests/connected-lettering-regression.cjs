// An accepted in-place erasure is completed along the caption's own lettering
// (glyphs fused with a background shape or a rule), while rules, thin drawing
// lines, marks between the text lines and textured surroundings keep their pixels.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const source=fs.readFileSync(path.resolve(__dirname,'../../AidokuTests/Translation/LegacyBrowserOverlay/BrowserSourcePanelRestoration.swift'),'utf8');
const script=source.match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const complete=new Function(script+';return aidokuCompleteConnectedLettering;')();

const BLUE=[190,227,254],WHITE=[255,255,255],BLACK=[5,7,11];
function page(w,h,fill=BLUE){const rgba=new Uint8ClampedArray(w*h*4);for(let i=0;i<w*h;i++)rgba.set([...fill,255],i*4);return rgba;}
function rect(rgba,w,x,y,ww,hh,color){for(let yy=y;yy<y+hh;yy++)for(let xx=x;xx<x+ww;xx++)rgba.set([...color,255],(yy*w+xx)*4);}
// Letter "H" with 8 px strokes, 40 px tall, at x.
function letter(rgba,w,x,y=30){rect(rgba,w,x,y,8,40,BLACK);rect(rgba,w,x+22,y,8,40,BLACK);rect(rgba,w,x,y+16,30,8,BLACK);}
// The restoration repainted letters with the background colour (alpha 255 marks repainted pixels).
function restoredFor(original,w,h,xs,fill=BLUE,y=30){
  const rgba=new Uint8ClampedArray(w*h*4),safe=new Uint8Array(w*h);
  for(const x of xs)for(let yy=y-2;yy<y+42;yy++)for(let xx=x-2;xx<x+32;xx++){const i=yy*w+xx;rgba.set([...fill,255],i*4);safe[i]=1;}
  return {rgba,layoutSafe:safe,erased:1};
}
const isInk=(rgba,i)=>rgba[i*4]<60&&rgba[i*4+1]<60&&rgba[i*4+2]<60;
const composite=(original,restored,i)=>restored.rgba[i*4+3]?restored.rgba.slice(i*4,i*4+3):original.slice(i*4,i*4+3);

// 1. CH|ARACT|ER: the outer letters touch a white shape, the middle ones were erased.
{
  const w=260,h=100,original=page(w,h);
  rect(original,w,0,0,40,60,WHITE);rect(original,w,220,50,40,50,WHITE);
  for(const x of [20,60,100,140,180,220])letter(original,w,x);
  const before=original.slice(),restored=restoredFor(original,w,h,[60,100,140,180]);
  const painted=complete(original,w,h,[18,28,236,44],restored,[],false);
  assert.ok(painted>0,'the fused outer letters are completed');
  assert.deepEqual(original,before,'the original pixels are never modified');
  let left=0;
  for(const x of [20,220])for(let y=30;y<70;y++)for(let xx=x;xx<x+30;xx++){const i=y*w+xx;if(isInk(original,i)&&composite(original,restored,i)[0]<60)left++;}
  assert.equal(left,0,'no letter ink is left at either end of the word');
  // The shape away from the letters keeps its original pixels.
  for(let y=0;y<20;y++)for(let x=0;x<12;x++)assert.equal(restored.rgba[(y*w+x)*4+3],0,'white shape untouched');
  console.log('PASS fused outer letters completed, shape kept');
}

// 2. A glyph touching a thin rule: the glyph goes, the rule stays.
{
  const w=200,h=110,original=page(w,h,WHITE);
  for(const x of [30,70,110])letter(original,w,x);
  rect(original,w,0,72,w,2,BLACK);rect(original,w,118,69,8,4,BLACK);
  const restored=restoredFor(original,w,h,[30,70],WHITE);
  complete(original,w,h,[28,28,114,44],restored,[],false);
  for(let x=0;x<w;x++){if(x>=104&&x<=146)continue;const i=(72*w+x);assert.ok(composite(original,restored,i)[0]<60,'rule pixel '+x+' kept');}
  let left=0;for(let y=30;y<68;y++)for(let x=110;x<140;x++){const i=y*w+x;if(isInk(original,i)&&composite(original,restored,i)[0]<60)left++;}
  assert.equal(left,0,'the glyph touching the rule is erased');
  console.log('PASS glyph touching a rule erased, rule kept');
}

// 3. Drawing lines thinner than the erased strokes, marks between text lines,
//    another caption's box and textured surroundings keep their pixels.
{
  const w=200,h=160,original=page(w,h,WHITE);
  for(const x of [30,70])letter(original,w,x);
  rect(original,w,112,34,40,3,BLACK);                     // thin drawing line in the text line
  rect(original,w,40,112,24,24,BLACK);rect(original,w,46,118,12,12,WHITE); // mark below the text line
  const restored=restoredFor(original,w,h,[30,70],WHITE);
  const painted=complete(original,w,h,[28,28,140,110],restored,[],false);
  assert.equal(painted,0,'nothing that is not lettering is repainted');
  const excluded=page(w,h,WHITE);for(const x of [30,70,110])letter(excluded,w,x);
  const r2=restoredFor(excluded,w,h,[30,70],WHITE);
  assert.equal(complete(excluded,w,h,[28,28,114,44],r2,[[105,25,40,50]],false),0,'another owner is never erased');
  const noisy=page(w,h,WHITE);
  for(let y=0;y<h;y++)for(let x=0;x<w;x++)if((x*7+y*13)%5===0)noisy.set([140,140,140,255],(y*w+x)*4);
  for(const x of [30,70,110])letter(noisy,w,x);
  const r3=restoredFor(noisy,w,h,[30,70],WHITE);
  assert.equal(complete(noisy,w,h,[28,28,114,44],r3,[],false),0,'textured surroundings keep the leftover');
  assert.equal(complete(original,w,h,[28,28,140,110],{rgba:new Uint8ClampedArray(w*h*4),layoutSafe:new Uint8Array(w*h)},[],false),0,
    'no erased exemplar, no completion');
  console.log('PASS thin lines, marks off the text line, other owners and textures kept');
}
