// Execute the production measurement closure at the exhausted search budget.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const source=fs.readFileSync(path.join(__dirname,'../../Aidoku/Core/Translation/NativeEngine/Overlay/BrowserOverlayView.swift'),'utf8');
const start=source.indexOf('        const blocks=(f,w,commit=false)=>{');
const end=source.indexOf('        const place=',start);
assert.ok(start>0&&end>start);
const run=new Function('commit', `
 let unitProbes=480,unitBudget=480;
 const memberNodes=[0,1].map(()=>({style:{},scrollWidth:40,clientWidth:40,getBoundingClientRect:()=>({left:0,top:0})}));
 const members=[{text:'first'},{text:'second'}],ratios=[1.2,1.2],scrollX=0,scrollY=0;
 const inkOf=n=>({left:0,top:0,right:40,bottom:parseFloat(n.style.fontSize)});
 ${source.slice(start,end)}
 return {result:blocks(12,40,commit),memberNodes,unitProbes};
`);
const search=run(false);assert.equal(search.result,null);assert.ok(search.memberNodes.every(n=>!n.style.fontSize));
const committed=run(true);assert.equal(committed.result.length,2);
assert.deepEqual(committed.memberNodes.map(n=>[n.textContent,n.style.fontSize]),[['first','12px'],['second','12px']]);
assert.equal(committed.unitProbes,480,'commit does not reopen the exhausted search budget');
console.log('PASS exhausted balloon search cannot leave a stale trial layout on commit');
