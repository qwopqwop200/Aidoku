// Verify final output from original-backed cached replays without opening images.
// node Scripts/tests/rectangular-balloon-json-regression.cjs <artifact-root> <old-control-root>
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const [root,oldControls]=process.argv.slice(2);assert.ok(root&&oldControls);
const read=p=>JSON.parse(fs.readFileSync(p));
const final=read(path.join(root,'final/incident-10.items.json'));
const payload=read(path.join(root,'native-after/incident-10.payload.json'));
const regions=read(path.join(root,'native-after/incident-10.regions.json'));
assert.equal(regions.length,24);assert.equal(regions.filter(r=>r.unitMemberRects?.length===2).length,1);
assert.equal(final.items.length,20);
assert.equal(final.layers.filter(l=>l.kind==='source-readability-panel').length,16);
function solid(j){
 for(const l of j.layers){
  if(!l.kind.startsWith('source-readability')||l.hidden)continue;
  const coverage=JSON.parse(l.dataset.panelCoverage||'null');
  if(l.clipPath!=='none'){
   assert.equal(coverage?.length,1,'opaque card cannot have separate stepped footprints');
   assert.equal((l.clipPath.match(/M /g)||[]).length,1,'actual path has one rectangle');
   assert.ok(!/polygon/.test(l.clipPath));
  }
 }
}
solid(final);
let contained=0;
for(const item of payload.items){
 const b=item.balloonInterior;if(!b?.contourVerified)continue;
 const node=final.items.find(i=>i.region===String(item.id));assert.ok(node);
 const f=item.sourceFrame,top=f[1]+b.rect[1]*f[3],height=b.rect[3]*f[3],bands=b.spans.length/2;
 for(const [x,y,w,h] of node.lines){
  assert.ok(y>=top-.05&&y+h<=top+height+.05);
  const first=Math.max(0,Math.floor((y-top)/height*bands));
  const last=Math.min(bands-1,Math.ceil((y+h-top)/height*bands)-1);
  for(let k=first;k<=last;k++){
   assert.ok(b.spans[k*2]>=0,'no unverified gap in balloon contour');
   assert.ok(x>=f[0]+b.spans[k*2]*f[2]-.05);
   assert.ok(x+w<=f[0]+b.spans[k*2+1]*f[2]+.05);
  }
 }
 contained++;
}
assert.equal(contained,4);
const hit=(a,b)=>Math.min(a[0]+a[2],b[0]+b[2])-Math.max(a[0],b[0])>.5&&
 Math.min(a[1]+a[3],b[1]+b[3])-Math.max(a[1],b[1])>.5;
for(let i=0;i<final.items.length;i++)for(let j=i+1;j<final.items.length;j++){
 assert.ok(!final.items[i].lines.some(a=>final.items[j].lines.some(b=>hit(a,b))),'no final translated-line collisions');
}
let controls=0;
for(const id of ['panel-1','panel-2','panel-3','panel-4','panel-5','panel-6','panel-7','panel-9','title']){
 const before=read(path.join(oldControls,id+'.items.json')),after=read(path.join(root,'controls-final',id+'.items.json'));
 solid(after);assert.equal(after.items.length,before.items.length);
 const raster=j=>j.layers.filter(l=>l.raster).map(l=>l.raster);
 assert.deepEqual(raster(after),raster(before),'holdout restoration pixels');
 for(const node of after.items){
  controls++;const prior=before.items.find(i=>i.region===node.region);assert.ok(prior);
  for(const k of ['text','fontSize','color','strokeWidth','hidden','transform'])assert.deepEqual(node[k],prior[k],id+': '+k);
  for(let k=0;k<4;k++)assert.ok(Math.abs(node.ink[k]-prior.ink[k])<.05,'subpixel rounding only');
 }
}
assert.equal(controls,48);
console.log('PASS: 24 OCR regions with 1 joined unit; 16 rectangular panels; all 4 measured balloons contain text; 48 control captions and raster hashes preserved');
