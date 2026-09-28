// Compare production replays before/after geometric caption separation.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const [before,after,payloads]=process.argv.slice(2);
assert.ok(before&&after&&payloads,'Pass before, after and device payload directories');
const overlap=(a,b)=>Math.min(a[0]+a[2],b[0]+b[2])-Math.max(a[0],b[0])>.05&&
  Math.min(a[1]+a[3],b[1]+b[3])-Math.max(a[1],b[1])>.05;
for(let n=1;n<=3;n++){
  const read=dir=>JSON.parse(fs.readFileSync(path.join(dir,`phone-${n}.items.json`),'utf8'));
  const b=read(before),a=read(after);
  assert.equal(a.items.length,b.items.length);assert.equal(a.layers.length,b.layers.length);
  for(const i of a.items){const previous=b.items.find(p=>p.region===i.region);assert.ok(previous);
    for(const key of ['text','fontSize','hidden','rects','lineHeight'])assert.deepEqual(i[key],previous[key],`page ${n} region ${i.region} ${key}`);
    for(const key of ['overflowX','overflowY'])assert.ok(i[key]<=previous[key]+.1,`page ${n} ${key}`);
    assert.ok(Math.abs(i.ink[2]-previous.ink[2])<.05&&Math.abs(i.ink[3]-previous.ink[3])<.05,'no rewrap or scaling');
    assert.ok(Math.hypot(i.ink[0]-previous.ink[0],i.ink[1]-previous.ink[1])<4,'local displacement only');
  }
  const panels=a.layers.filter(l=>l.kind==='source-readability-panel');
  if(n===1){
    for(let i=0;i<panels.length;i++)for(let j=i+1;j<panels.length;j++)assert.ok(!overlap(panels[i].box,panels[j].box),`panels ${panels[i].region}/${panels[j].region} overlap`);
    const left=panels.find(p=>p.region==='4'),right=panels.find(p=>p.region==='2');
    assert.ok(right.box[0]-(left.box[0]+left.box[2])>=.95,'a real gap, not a border');
    const payload=JSON.parse(fs.readFileSync(path.join(payloads,'phone-1.payload.json'),'utf8'));
    for(const panel of panels){
      const i=payload.items.find(i=>i.id===panel.region),f=i.sourceFrame,s=i.sourceBounds;
      const source=[f[0]+s[0]*f[2],f[1]+s[1]*f[3],s[2]*f[2],s[3]*f[3]],r=panel.box;
      const old=b.layers.find(l=>l.kind===panel.kind&&l.region===panel.region).box;
      const coverage=r=>Math.max(0,Math.min(r[0]+r[2],source[0]+source[2])-Math.max(r[0],source[0]))*Math.max(0,Math.min(r[1]+r[3],source[1]+source[3])-Math.max(r[1],source[1]));
      assert.ok(coverage(r)>=coverage(old)-.1,`source coverage ${panel.region}`);
    }
  }
  if(n===3)assert.deepEqual(panels.map(p=>p.box),b.layers.filter(l=>l.kind==='source-readability-panel').map(p=>p.box),'already separated panels unchanged');
}
console.log('PASS no overlapping panels on reported page; real gap; source coverage, fonts and wrapping preserved on all 3 pages');
