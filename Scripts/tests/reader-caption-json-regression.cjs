// Final WebKit JSON from original-backed replays; no visual inspection.
// node Scripts/tests/reader-caption-json-regression.cjs <before> <after>
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const [before,after]=process.argv.slice(2);assert.ok(before&&after,'Pass before/after replay directories');
const read=(dir,id)=>JSON.parse(fs.readFileSync(path.join(dir,id+'.items.json')));
const overlaps=(a,b)=>Math.min(a[0]+a[2],b[0]+b[2])-Math.max(a[0],b[0])>.5&&
 Math.min(a[1]+a[3],b[1]+b[3])-Math.max(a[1],b[1])>.5;
let count=0,strengthened=0;
for(const id of ['panel-1','panel-2','panel-3','panel-4','panel-5','panel-6','panel-7','panel-9','title']){
 const old=read(before,id),fresh=read(after,id);
 assert.ok(fresh.items.length>0,id+': zero captions is not success');
 assert.equal(fresh.items.length,old.items.length);
 for(const [k,v] of Object.entries(fresh.root))assert.ok(!/error$/i.test(k)||!v,id+': '+k);
 const raster=d=>d.layers.filter(l=>l.raster).map(l=>l.raster);
 assert.deepEqual(raster(fresh),raster(old),id+': reconstruction pixels unchanged');
 for(const item of fresh.items){
  count++;const prior=old.items.find(i=>i.region===item.region);assert.ok(prior);
  for(const k of ['text','fontSize','color','hidden'])assert.deepEqual(item[k],prior[k],id+': '+k);
  assert.equal(item.hidden,false);
  for(const k of ['overflowX','overflowY'])assert.ok(item[k]<=prior[k]+.05);
  const title=id==='title'&&item.region==='0';
  if(title){assert.equal(item.transform,'none');assert.equal(item.dataset.uprightQuadProof,'fixed-source-plate');}
  else assert.deepEqual(item.ink,prior.ink,id+': caption positions and line breaks unchanged');
  if(id!=='title'){
   assert.equal(item.dataset.sourceBackgroundColor,'inpainted');
   assert.ok(parseFloat(item.strokeWidth)>=1,id+': final stroke must survive every late pass');
   if(parseFloat(item.strokeWidth)>parseFloat(prior.strokeWidth))strengthened++;
  }
 }
 for(let i=0;i<fresh.items.length;i++)for(let j=i+1;j<fresh.items.length;j++){
  assert.ok(!fresh.items[i].lines.some(a=>fresh.items[j].lines.some(b=>overlaps(a,b))),id+': overlapping translated lines');
 }
 const plates=d=>d.layers.filter(l=>['source-readability-panel','source-rotated-panel'].includes(l.kind));
 if(id==='title')assert.deepEqual(plates(fresh),plates(old),'upright text cannot enlarge or rotate the source-erasure plate');
 else assert.equal(plates(fresh).length,0,id+': no unnecessary opaque panels');
}
assert.equal(count,48);assert.equal(strengthened,46);
console.log(`PASS 9 original-backed pages / ${count} captions: upright title, ${strengthened} stronger outlines, no line collisions, stable reconstruction pixels/colors/fonts`);
