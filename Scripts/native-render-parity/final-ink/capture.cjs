const fs=require('fs'),path=require('path');
const root=process.argv[2],output=process.argv[3],ref=path.join(root,'Scripts/native-render-parity/reference-source');
const files=fs.readdirSync(ref).filter(f=>f.endsWith('.swift')).map(f=>fs.readFileSync(path.join(ref,f),'utf8'));
const view=fs.readFileSync(path.join(ref,'BrowserOverlayView.swift'),'utf8');
function helper(name){for(const s of files){let start=s.indexOf('const '+name+' =');if(start<0)start=s.indexOf('function '+name+'(');if(start<0)continue;
 if(name==='aidokuSourceColorLuminance')return s.slice(start,s.indexOf('    const aidokuLuminanceContrast',start));
 let depth=0,opening=s.indexOf('{',start);for(let i=opening;i<s.length;i++){if(s[i]==='{')depth++;if(s[i]==='}'&&!--depth)return s.slice(start,i+2);}}
 throw Error('helper absent '+name);}
const names=['aidokuSourceColorLuminance','aidokuLuminanceContrast','aidokuSourceColorContrast','aidokuChromaticOutlineMinimum','aidokuAdjustInkForContrast','aidokuReadableSourceOutline','aidokuSourceStyleOutline','aidokuSlantedLinear','aidokuRobustSurfaceInk'];
const start=view.indexOf('    if(appearance?.preserveSourceTextColor&&opacity===1&&items.length<=256){',view.indexOf('// Geometry is now committed. Recheck'));
const end=view.indexOf('    // Minimal-area plates.',start);if(start<0||end<start)throw Error('final colors absent');
const run=new Function('input',names.map(helper).join('\n')+`
const appearance={preserveSourceTextColor:true},opacity=1,inpaintingEnabled=true;
const root={dataset:{}},mount={appendChild(){}},measurementHost={remove(){}};
const rect=i=>({left:i*100,top:0,right:i*100+40,bottom:20,width:40,height:20});
const panels=[],nodes=input.map((c,i)=>{
 const owner=c.ownerBackground?{dataset:{aidokuImageOcrOverlay:'source-readability-panel'},style:{backgroundColor:'rgb('+c.ownerBackground.join(',')+')'},getBoundingClientRect:()=>rect(i)}:root;
 if(owner!==root)panels.push(owner);
 for(const color of c.overlapColors)panels.push({dataset:{},style:{backgroundColor:'rgb('+color.join(',')+')'},getBoundingClientRect:()=>rect(i)});
 const n={parentElement:owner,style:{fontSize:c.font+'px',color:'rgb('+c.foreground.join(',')+')'},dataset:{aidokuRegion:c.id,sourceBackgroundColor:c.restored?'inpainted':'readability-panel',sourceAppliedTextRGB:c.foreground.join(','),sourceAppliedStrokeRGB:c.stroke?.join(',')||'',sourceStrokeColor:c.strokePreserved?'preserved':'none'},getBoundingClientRect:()=>rect(i)};
 if(c.cluster)n.dataset.inkCluster=c.cluster.join(',');if(c.surfaceRange)n.dataset.sourcePanelSurfaceLuminance=JSON.stringify(c.surfaceRange);
 if(c.inkBeforeSurface)n.dataset.sourcePanelInkBeforeSurface=c.inkBeforeSurface.join(',');
 if(c.partialSourcePositionProof)n.dataset.partialMainbodyProof='outlined-source-position';
 n.style.webkitTextStrokeWidth=c.strokeWidth+'px';return n;});
root.querySelectorAll=s=>s.includes('source-readability-panel')?panels:nodes;
const document={createRange:()=>({selectNodeContents(n){this.n=n;},getBoundingClientRect(){return this.n.getBoundingClientRect();}})};
const items=input.map(c=>({id:c.id,sourceColorEligible:c.eligible,sourceTextOnly:c.sourceTextOnly,rotation:c.rotation}));
const cachedSourceSample=item=>input.find(c=>c.id===item.id).sample;
const typographyEntries=input.map(c=>({id:c.id,surfaceInk:c.surfaceHistogram?(ink=>aidokuRobustSurfaceInk(ink,c.surfaceHistogram)):null}));
${view.slice(start,end)}
return nodes.map(n=>({foreground:n.dataset.sourceAppliedTextRGB.split(',').map(Number),stroke:n.dataset.sourceAppliedStrokeRGB?n.dataset.sourceAppliedStrokeRGB.split(',').map(Number):null,strokeWidth:parseFloat(n.style.webkitTextStrokeWidth),strokePreserved:n.dataset.sourceStrokeColor==='preserved',cluster:n.dataset.inkCluster?n.dataset.inkCluster.split(',').map(Number):null}));
`);
let seed=4123;const rand=()=>((seed=(Math.imul(seed,1664525)+1013904223)>>>0)/4294967296),rgb=()=>[0,0,0].map(()=>Math.floor(rand()*256));
const fixtures=[];
for(let page=0;page<120;page++){
 const original=rgb(),input=[];
 for(let i=0;i<6;i++){
 const foreground=page%3?original.slice():rgb(),stroke=page%4===0?rgb():null;
 const c={id:'c'+i,eligible:page%13!==0||i>0,sourceTextOnly:page%17===0&&i===0,rotation:page%19===0&&i===0?.2:0,font:8+(page%24),foreground,stroke,strokeWidth:stroke?1.5:0,strokePreserved:Boolean(stroke),ownerBackground:page%2?rgb():null,restored:page%2===0,surfaceRange:page%2===0?[page%4===0?0:.7,page%4===0?.15:1]:null,overlapColors:page%2===0&&page%5===0?[rgb()]:[],cluster:page%3?original.slice():null,sample:page%4===0?{foreground:rgb(),stroke:rgb(),confidence:{foreground:.9,stroke:.8},widthEvidence:{relativeToGlyph:.12}}:{foreground:foreground.slice(),confidence:{foreground:.8}},partialSourcePositionProof:page%11===0&&i===0,inkBeforeSurface:null,surfaceHistogram:null};
 if(page%8===0){c.inkBeforeSurface=rgb();c.surfaceHistogram=Array(256).fill(0);for(let j=0;j<1000;j++)c.surfaceHistogram[Math.floor(rand()*35)+210]++;}
 input.push(c);
 }
 fixtures.push({input,expected:run(input)});
}
fs.writeFileSync(output,JSON.stringify(fixtures));console.log(JSON.stringify({cases:fixtures.length,cards:fixtures.length*6}));
