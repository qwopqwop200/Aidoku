// A fitted unit must certify the opaque box it adds, including between ragged lines.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const source=fs.readFileSync(path.join(__dirname,'../../Aidoku/Core/Translation/NativeEngine/Overlay/BrowserOverlayView.swift'),'utf8');
const pass=source.indexOf('// Lettering is final. A joined balloon unit');
const start=source.indexOf('        const outside=(rects,dx,dy,fs)=>{',pass);
const end=source.indexOf('        const before=',start);
assert.ok(start>pass&&end>start);
const run=new Function('plated','rects',`
 const root={},container=plated?{}:root,calls=[];
 const interior={outside:r=>{calls.push(r);return r.left<7?10:0;}};
 ${source.slice(start,end)}
 return {value:outside(rects,0,0,10),calls};
`);
const rects=[{left:9,top:10,right:30,bottom:20},{left:15,top:22,right:35,bottom:32}];
const plated=run(true,rects);
assert.deepEqual(plated.calls,[{left:6,top:7,right:38,bottom:35}]);
assert.equal(plated.value,10,'3 px opaque margin crosses the outline although a 2 px text margin fits');
const bare=run(false,rects);
assert.equal(bare.calls.length,2);
assert.equal(bare.value,0,'plate-free text keeps its existing per-line boundary contract');
assert.equal(run(true,[]).value,Infinity);
assert.match(source.slice(pass),/const partial=container===root&&!best/,'partial outline improvement must not authorize new opaque coverage');
console.log('PASS balloon unit containment checks the complete padded plate footprint');
// Restoration ranks members by area; layout must not silently reuse that rank as reading order.
const helperStart=source.indexOf('    const unitMembersOf=item=>{');
const helperEnd=source.indexOf('    // A joined unit\'s balloon measured',helperStart);
const partsStart=source.indexOf('    // A joined unit whose block had to be contained');
const membersStart=source.indexOf('        const members=',partsStart);
const membersEnd=source.indexOf('\n',membersStart);
const ordered=new Function('item',`${source.slice(helperStart,helperEnd)}\n${source.slice(membersStart,membersEnd)}\nreturn members;`);
const item={sourceBounds:[0,0,1,1],balloonInterior:{spans:[0,1]},unitMemberRects:[[.7,.1,.1,.1],[.1,.1,.3,.3]]};
assert.deepEqual(ordered(item),item.unitMemberRects,'small first member keeps source reading order');
assert.equal(ordered({...item,unitMemberRects:[[0,0,2,2],[0,0,.1,.1]]}),null,'invalid members remain rejected');
const passes=source.slice(pass,source.indexOf('    // The readable floor holds',pass));
assert.equal((passes.match(/const others=items\.concat\(keptItems\)/g)||[]).length,2,'both layout passes protect kept lettering');
console.log('PASS unit parts retain native reading order and both passes reserve kept lettering');
