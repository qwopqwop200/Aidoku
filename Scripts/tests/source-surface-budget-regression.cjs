// Tests the production restored-surface gate, including a retry under a fresh
// bounded allowance. No duplicate acceptance algorithm lives in this fixture.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const assert=require('node:assert/strict'),test=require('node:test');
const source=fs.readFileSync(process.env.SURFACE_OVERLAY_PATH||path.resolve(__dirname,'../../Aidoku/Core/Translation/NativeEngine/Overlay/BrowserOverlayView.swift'),'utf8');
const start=source.indexOf('        const panelGeometry=restoredPanelGeometry.get(item);');
const end=source.indexOf("        if(node.dataset.captionFontRecovery==='accepted'&&preRecoveryProfile){",start);
assert.ok(start>=0&&end>start);
const gate=source.slice(start,end).replace(/\\([\\"])/g,'$1');
function run({initial=1,retry=100,unsafe=false,outside=false}={}){
 return vm.runInNewContext(`(()=>{
  const node={style:{fontSize:'10px'},dataset:{}},item={},displayedText='번역',foreground='0,0,0',sampled={};
  let restoredTextInspectionBudget=8192,restoredPanelLookupBudget=${initial},restoredExteriorPixelBudget=1048576;
  const c={frame:[0,0,10,10],iw:10,ih:10,w:10,h:10,sx:1,sy:1,x:0,y:0,
    safe:new Uint8Array(100).fill(1),luminance:new Uint8Array(100).fill(255)};
  if(${unsafe})c.safe[11]=0;
  const restoredPanelGeometry=new Map([[item,c]]),restoredSourcePanels=new Set([item]);
  let profile={ink:[[${outside?-1:1},1,2,2]]};
  const contentFits=()=>true,lineProfile=()=>profile;
  const aidokuCaptionPalette=()=>({foreground:[0,0,0]});
  const aidokuSourceColorLuminance=rgb=>rgb[0]/255,aidokuAdjustInkForContrast=rgb=>rgb;
  ${gate}
  const first=node.dataset.sourcePanelTextFit,remaining=restoredPanelLookupBudget;
  restoredPanelLookupBudget=${retry};
  const recovered=fitsRestoredSurface(profile);
  return {first,recovered,remaining,after:restoredPanelLookupBudget};
 })()`);
}
test('a pixel-budget refusal can retry the same glyph geometry with a fresh allowance',()=>{
 const result=run();assert.equal(result.first,'caption');assert.equal(result.remaining,1);
 assert.equal(result.recovered,true,'resource exhaustion must not permanently cache an unsafe surface');
 assert.equal(result.after,96,'the successful retry still charges every inspected pixel');
});
test('a retry cannot inspect more pixels than its replacement allowance',()=>{
 const result=run({retry:3});assert.equal(result.recovered,false);assert.equal(result.after,3);
});
test('fresh budgets never turn surviving artwork into a safe surface',()=>{
 const result=run({initial:100,unsafe:true});assert.equal(result.first,'caption');assert.equal(result.recovered,false);
});
test('fresh budgets never admit glyphs outside the inspected crop',()=>{
 const result=run({initial:100,outside:true});assert.equal(result.first,'caption');assert.equal(result.recovered,false);
});
