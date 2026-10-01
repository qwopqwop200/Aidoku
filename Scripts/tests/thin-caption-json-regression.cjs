// Final WebKit output from cached originals. Images are processed, never opened.
// Usage: node Scripts/tests/thin-caption-json-regression.cjs <replay artifact directory>
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const root=process.argv[2];assert.ok(root,'Pass the thin-inpainting replay directory');
const read=(dir,id)=>JSON.parse(fs.readFileSync(path.join(root,dir,id+'.items.json')));
let controls=0;
for(const id of ['panel-1','panel-2','panel-3','panel-4','panel-5','panel-6','panel-7','panel-9']){
 const a=read('controls-before',id),b=read('controls-stable',id);
 assert.ok(b.items.length);controls+=b.items.length;
 assert.deepEqual(b.items,a.items,id+': unchanged captions');
 assert.deepEqual(b.layers,a.layers,id+': unchanged layers and restoration raster hashes');
}
assert.equal(controls,46);
const before=read('page-before','incident-10'),after=read('page-stable','incident-10');
const panels=j=>j.layers.filter(l=>l.kind==='source-readability-panel'&&!l.hidden).length;
assert.equal(panels(before),19);assert.equal(panels(after),17);
assert.equal(after.items.length,21);assert.equal(before.items.length,21);
for(const item of after.items){
 const old=before.items.find(i=>i.region===item.region);assert.ok(old);
 assert.equal(item.text,old.text);assert.equal(item.hidden,old.hidden);
 if(item.region!=='0')assert.equal(item.color,old.color,'preserve unrelated colour decisions');
 if(!['0','2','7','11'].includes(item.region)){
  for(const key of ['fontSize','strokeWidth','ink'])assert.deepEqual(item[key],old[key]);
 }
 // Reflow in the newly cleared region may change line count, but not move
 // the caption to another part of the page.
 for(let axis=0;axis<2;axis++){
  const center=r=>r[axis]+r[axis+2]/2;
  assert.ok(Math.abs(center(item.ink)-center(old.ink))<=4,'bounded final anchor displacement');
 }
 if(['7','11'].includes(item.region)){
  assert.equal(old.dataset.sourceBackgroundColor,'readability-panel');
  assert.equal(item.dataset.sourceBackgroundColor,'inpainted');
  assert.ok(parseFloat(item.strokeWidth)>=1);
 }
 for(const [key,value] of Object.entries(after.root))assert.ok(!/error$/i.test(key)||!value,key);
}
const overlap=(a,b)=>Math.min(a[0]+a[2],b[0]+b[2])-Math.max(a[0],b[0])>.5&&
 Math.min(a[1]+a[3],b[1]+b[3])-Math.max(a[1],b[1])>.5;
for(let i=0;i<after.items.length;i++)for(let j=i+1;j<after.items.length;j++){
 assert.ok(!overlap(after.items[i].ink,after.items[j].ink),'no caption ink-box collision');
}
console.log('PASS 2 plates erased, 21 caption texts preserved, unrelated colours stable, 46 control captions and raster hashes unchanged');
