// Validate real-device replay artifacts after running the production WebKit renderer.
// Usage: node Scripts/tests/device-caption-replay-regression.cjs <replay directory> [after subdirectory]
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const directory=process.argv[2];
assert.ok(directory,'Pass the directory containing the three matched device-page replays');
const get=(run,n)=>{if(run==='after')run=process.argv[3]||run;return JSON.parse(fs.readFileSync(path.join(directory,run,`phone-${n}.items.json`),'utf8'));};
const item=(page,id)=>{const value=page.items.find(i=>i.region===String(id));assert.ok(value,`missing region ${id}`);return value;};
const count=fs.existsSync(path.join(directory,'before','phone-4.items.json'))?4:3;
for(let n=1;n<=count;n++){
  const before=get('before',n),after=get('after',n);
  assert.equal(after.items.length,before.items.length);
  for(const a of after.items){const b=item(before,a.region);
    for(const key of ['text','fontSize','hidden'])assert.equal(a[key],b[key],`page ${n} region ${a.region}: ${key}`);
    for(const key of ['overflowX','overflowY'])assert.ok(a[key]<=b[key]+.1,`page ${n} region ${a.region}: ${key}`);
  }
}
const first=get('after',1),moved=item(first,2),neighbor=item(first,4);
assert.ok(moved.ink[0]>=neighbor.ink[0]+neighbor.ink[2]+.5);
const panel=first.layers.find(l=>l.kind==='source-readability-panel'&&l.region==='4');
assert.equal(panel.dataset.captionUnified,'true','나에게도 must be rectangular');
assert.equal(panel.dataset.captionBlankKept,'true','certify original SFX margin before filling');
assert.equal(JSON.parse(panel.dataset.panelCoverage).length,1);
assert.ok(moved.ink[0]>=panel.box[0]+panel.box[2]+.25,'short reply must clear adjacent plate');
assert.ok(Math.abs(JSON.parse(moved.dataset.captionMinimalShift)[0])<3,'keep displacement local');
const unified=first.layers.filter(l=>l.kind==='source-readability-panel'&&l.region==='3');
assert.equal(unified.length,1);assert.equal(unified[0].dataset.captionUnified,'true');
assert.equal(JSON.parse(unified[0].dataset.panelCoverage).length,1,'one solid rectangle');
const row=get('after',2).items.filter(i=>Number(i.region)<=10);
assert.equal(row.length,11);
assert.ok(Math.max(...row.map(i=>i.ink[1]))-Math.min(...row.map(i=>i.ink[1]))<.02,'11 dialogue tops aligned');
const old=item(get('before',3),1),fresh=item(get('after',3),1);
assert.ok(parseFloat(fresh.strokeWidth)<=parseFloat(old.strokeWidth)*.6);
assert.ok(parseFloat(fresh.strokeWidth)>=.6,'retain a visible contrast outline');
if(count===4){
  const fresh=get('after',4),row=fresh.layers.filter(l=>l.kind==='source-readability-panel'&&['7','8','9'].includes(l.region));
  assert.equal(row.length,3);
  for(const panel of row){assert.equal(panel.dataset.captionUnified,'true');assert.equal(JSON.parse(panel.dataset.panelCoverage).length,1);}
  row.sort((a,b)=>a.box[0]-b.box[0]);
  for(let i=1;i<row.length;i++)assert.ok(row[i].box[0]-row[i-1].box[0]-row[i-1].box[2]>=.95,'crowded trio has a real gap');
  for(const id of [7,8])assert.ok(Number(item(fresh,id).dataset.captionGroupShift)<0,'joint spacing includes the short piece');
}
console.log('PASS actual device pages: preserved text/fonts, no added overflow, adjacent plate cleared, solid rectangle, 11-column alignment, thinner outline');
