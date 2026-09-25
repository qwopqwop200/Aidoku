// Execute the production final palette pass with committed geometry.
// Policy regression only; WebKit screenshots verify native stroke rendering.
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const directory=path.join(__dirname,'../../Aidoku/Core/Translation/NativeEngine/Overlay');
const helpers=fs.readFileSync(path.join(directory,'BrowserSourceTextColor.swift'),'utf8')
  .match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const view=fs.readFileSync(path.join(directory,'BrowserOverlayView.swift'),'utf8');
const start=view.indexOf('    // Geometry is now committed. Recheck the actual owning surface, then');
const end=view.indexOf('    root.dataset.readabilityPanels=',start);
assert.ok(start>0&&end>start);
const pass=view.slice(start,end);
function box(left=0,top=0,width=100,height=80){return {left,top,width,height,right:left+width,bottom:top+height};}
function panel(color,frame=box()){
  return {dataset:{aidokuImageOcrOverlay:'source-readability-panel'},style:{backgroundColor:`rgb(${color.join(',')})`},getBoundingClientRect:()=>frame};
}
function run(fixtures,extraPanels=[]){
  const root={dataset:{}};
  const nodes=fixtures.map((fixture,i)=>({
    dataset:{aidokuRegion:String(i),sourceAppliedTextRGB:fixture.ink.join(','),
      sourceBackgroundColor:fixture.background?'readability-panel':'inpainted',
      ...(fixture.range?{sourcePanelSurfaceLuminance:JSON.stringify(fixture.range)}:{}),
      ...(fixture.cluster?{inkCluster:fixture.cluster.join(',')}:{})},
    style:{fontSize:`${fixture.font||24}px`},
    parentElement:fixture.background?panel(fixture.background):root,
    getBoundingClientRect:()=>fixture.frame||box(10,10,40,30)
  }));
  const panels=[...nodes.map(n=>n.parentElement).filter(n=>n!==root),...extraPanels];
  root.querySelectorAll=selector=>selector.includes('source-readability-panel')?panels:nodes;
  const document={createRange:()=>({selectNodeContents(n){this.node=n;},getBoundingClientRect(){return this.node.getBoundingClientRect();}})};
  const items=fixtures.map((fixture,i)=>({id:i,sourceColorEligible:true,sourceTextOnly:false}));
  const context=vm.createContext({root,items,document,appearance:{preserveSourceTextColor:true},opacity:1,
    cachedSourceSample:item=>fixtures[item.id].sample||{}});
  vm.runInContext(helpers+pass,context);
  return nodes;
}
const sample={foreground:[247,133,135],stroke:[24,6,5],confidence:{foreground:.8,stroke:.7}};
let [node]=run([{ink:[26,9,9],background:[248,238,244],font:31.75,sample,cluster:[26,9,9]}]);
assert.equal(node.dataset.sourceAppliedTextRGB,'247,133,135','actual observed pink lettering returns to pink');
assert.equal(node.dataset.sourceAppliedStrokeRGB,'24,6,5');
assert.equal(node.dataset.sourceTextOutline,'true');
assert.equal(node.style.paintOrder,'stroke fill');
assert.ok(parseFloat(node.style.webkitTextStrokeWidth)<=1.15);
assert.ok(Number(node.dataset.sourceFinalMinimumContrast)>=4.5);
assert.equal(node.dataset.inkCluster,undefined,'flat-fill clustering cannot erase native fill/stroke roles');
[node]=run([{ink:[26,9,9],background:[248,238,244],font:8.5,sample}]);
assert.notEqual(node.dataset.sourceTextOutline,'true','small type must remain fill-only');
[node]=run([{ink:[26,9,9],background:[248,238,244],sample:{...sample,confidence:{foreground:.3,stroke:.7}}}]);
assert.notEqual(node.dataset.sourceTextOutline,'true','uncertain fill must not be promoted to native outline pair');
[node]=run([{ink:[200,190,180],range:[.8,.95],font:24,sample}]);
assert.equal(node.style.zIndex,'3');
assert.notEqual(node.dataset.sourceTextOutline,'true','transparent restoration needs an expanded spatial check, so this pass cannot add stroke');
assert.ok(Number(node.dataset.sourceFinalMinimumContrast)>=4.5);
const grouped=run([
  {ink:[157,75,126],background:[255,255,255],cluster:[157,75,126]},
  {ink:[154,74,124],background:[239,239,239],cluster:[157,75,126]}
]);
assert.equal(grouped[0].dataset.sourceAppliedTextRGB,grouped[1].dataset.sourceAppliedTextRGB);
assert.ok(grouped.every(n=>Number(n.dataset.sourceFinalMinimumContrast)>=4.5));
const split=run([
  {ink:[252,252,252],background:[20,20,20],cluster:[252,252,252]},
  {ink:[17,17,17],background:[250,250,250],cluster:[252,252,252]}
]);
assert.notEqual(split[0].dataset.sourceAppliedTextRGB,split[1].dataset.sourceAppliedTextRGB,'opposite backing polarities cannot force one unreadable shared fill');
[node]=run([{ink:[180,180,180],range:[.01,.01]}],[panel([100,100,100])]);
assert.ok(Number(node.dataset.sourceFinalMinimumContrast)>=4.5,'overlapping opaque plate participates in final contrast');
console.log('PASS final palette: native source stroke, small/uncertain abstention, restoration guard, coherent cohorts and overlap contrast');
