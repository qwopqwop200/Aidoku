// Execute the production plate-release pass, including its final CSS assignment.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const dir=path.join(__dirname,'../../Aidoku/Core/Translation/NativeEngine/Overlay');
const helpers=fs.readFileSync(path.join(dir,'BrowserSourceTextColor.swift'),'utf8').match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const view=fs.readFileSync(path.join(dir,'BrowserOverlayView.swift'),'utf8');
const start=view.indexOf('    // Complete glyph erasure and text readability are separate decisions.');
const end=view.indexOf('    aidokuUprightCaptionText(root, items);',start);
assert.ok(start>0&&end>start);
function run(sample,ring,preserve=true){
 const node={style:{fontSize:'8px'},dataset:{sourceAppliedTextRGB:'120,50,5',...(ring?{outlinedLettering:JSON.stringify(ring)}:{})},
  getBoundingClientRect:()=>({left:0,top:0,width:30,height:80})};
 const root={dataset:{},querySelector:()=>node,querySelectorAll:()=>[],appendChild:()=>{}};
 const item={id:1,sourceFrame:[0,0,430,323],sourceBounds:[.7,.1,.03,.4]},c={sourceGlyphsVerified:true,erasureComplete:true,canvas:{isConnected:true}};
 const ctx=vm.createContext({root,items:[item],opacity:1,inpaintingEnabled:true,appearance:{preserveSourceTextColor:preserve},
  restoredPanelGeometry:new Map([[item,c]]),sourceColorCache:new Map([[item,sample]]),scrollX:0,scrollY:0});
 vm.runInContext(helpers+view.slice(start,end),ctx);
 assert.equal(root.dataset.glyphPlateError,undefined);
 return node;
}
for(const [fill,stroke] of [[[253,253,251],[2,2,1]],[[254,253,249],[221,90,7]],[[180,35,50],[255,255,255]]]){
 const node=run({foreground:fill,stroke,confidence:{foreground:.85,stroke:.7}});
 assert.equal(node.style.color,`rgb(${fill.join(',')})`);
 assert.equal(node.dataset.sourceAppliedStrokeRGB,stroke.join(','));
 assert.ok(node.style.webkitTextStroke.endsWith(`rgb(${stroke.join(',')})`));
 assert.equal(node.style.paintOrder,'stroke fill');
 assert.equal(parseFloat(node.style.webkitTextStroke),3.2,'8px source lettering retains a visible outer band');
 assert.equal(node.dataset.sourceStrokeColor,'preserved');
}
// Plain source ink keeps its polarity on the reconstructed local surface.
for(const [fill,background] of [[[248,248,248],[2,2,2]],[[255,255,253],[106,64,117]],[[180,35,95],[250,247,244]]]){
 const sample={foreground:fill,background,stroke:null,confidence:{foreground:.85,background:.8,stroke:0}};
 const node=run(sample);
 assert.equal(node.style.color,`rgb(${fill.join(',')})`);
 assert.equal(node.style.webkitTextStroke,'0px transparent');
 assert.equal(node.style.paintOrder,'normal');
 assert.equal(node.dataset.sourceTextOutline,'false');
 assert.equal(node.dataset.sourceStrokeColor,'none');
 assert.equal(node.dataset.sourceTextColorAdjusted,'false');
 assert.equal(run({...sample,confidence:{foreground:.3,background:.8}},null).dataset.sourceStrokeColor,'readability');
 assert.equal(run(sample,null,false).dataset.sourceStrokeColor,'readability');
}
// Actual translucent-balloon palettes: perimeter variation lowers background
// confidence, but the exposed OCR interior still supports the original white ink.
for(const sample of [
 {foreground:[246,245,246],background:[99,60,107],confidence:{foreground:.997,background:.464},
  captionBackgroundEvidence:{color:[112,72,117],coverage:.676}},
 {foreground:[246,244,245],background:[116,73,117],confidence:{foreground:1,background:.388},
  surface:{color:[128,83,127]},captionBackgroundEvidence:{color:[127,81,123],coverage:.691}}
]){
 assert.equal(run(sample).dataset.sourceAppliedTextRGB,sample.foreground.join(','));
 assert.equal(run(sample).style.webkitTextStroke,'0px transparent');
 assert.equal(run(sample).style.paintOrder,'normal');
 assert.equal(run({...sample,captionBackgroundEvidence:{...sample.captionBackgroundEvidence,coverage:.2}}).dataset.sourceStrokeColor,'readability');
}
const ring={kind:'outline',core:[254,252,241],outline:[221,90,8],hug:1,uniform:.93};
assert.equal(run({foreground:ring.outline,stroke:null},ring).dataset.sourceAppliedTextRGB,ring.core.join(','));
for(const candidate of [null,{...ring,hug:.2},{...ring,uniform:.2},{...ring,core:[NaN,0,0]}])
 assert.equal(run({},candidate).dataset.sourceStrokeColor,'readability');
assert.equal(run({foreground:[255,255,255],stroke:[0,0,0],confidence:{foreground:1,stroke:1}},null,false).dataset.sourceStrokeColor,'readability');
// The actual device cache replay checks final rendered CSS, not stale diagnostics.
if(process.argv[2]){
 const base=process.argv[2],before=JSON.parse(fs.readFileSync(path.join(base,'before/incident.items.json'))),after=JSON.parse(fs.readFileSync(path.join(base,'after/incident.items.json')));
 assert.equal(after.items.length,6);
 for(const item of after.items){
  const old=before.items.find(n=>n.region===item.region),numbers=s=>s.match(/[\d.]+/g).map(Number);
  assert.equal(item.text,old.text);assert.equal(item.fontSize,old.fontSize);assert.deepEqual(item.box,old.box);
  assert.ok(Math.min(...numbers(item.color))>=230);
  assert.equal(parseFloat(item.strokeWidth),3.2,'final typography keeps the shared readable outline');
  assert.equal(item.dataset.strokeClusterCount,'3','orange and black source styles form separate cohorts');
  assert.ok(item.overflowX<=old.overflowX&&item.overflowY<=old.overflowY);
  assert.equal(item.dataset.sourceAppliedStrokeRGB,numbers(item.stroke).join(','));
  const rgb=numbers(item.stroke);
  if(['0','3','5'].includes(item.region))assert.ok(rgb[0]>200&&rgb[1]<110&&rgb[2]<25);
  else assert.ok(Math.max(...rgb)<16);
 }
}
console.log('PASS released captions: physical fill/stroke roles, native ring recovery, uncertain/disabled fallback and final CSS');
