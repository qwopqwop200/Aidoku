const fs=require('fs');const root=process.argv[2],out=process.argv[3],ref=root+'/Scripts/native-render-parity/reference-source/';const view=fs.readFileSync(ref+'BrowserOverlayView.swift','utf8'),typo=fs.readFileSync(ref+'BrowserOverlayTypography.swift','utf8');
function extract(text,name){let start=text.indexOf('const '+name+' =');if(start<0)start=text.indexOf('function '+name+'(');if(start<0)throw Error(name);const begin=text.indexOf('{',start);let depth=0,end=begin;for(;end<text.length;end++){if(text[end]==='{')depth++;if(text[end]==='}'&&--depth===0)break;}return text.slice(start,end+2);}
const helpers=['aidokuHasResidualLettering','aidokuHasAttachedLeadingInk','aidokuRestoredErasureCovers'].map(n=>extract(typo,n)).join('\n')+'\n'+extract(fs.readFileSync(ref+'BrowserSourcePanelRestoration.swift','utf8'),'aidokuOutlineSourceResolved');
const begin=view.indexOf('    // Final appearance only:'),end=view.indexOf('    (()=>{for(const item of items){',view.indexOf('// Remaining cards over a complete restoration:'));
const code=view.slice(begin,end)+'\n}';
const fixtures=JSON.parse(fs.readFileSync(process.argv[4],'utf8'));
const run=new Function('f',helpers+`
const trace=[],box=r=>({left:r[0],top:r[1],right:r[0]+r[2],bottom:r[1]+r[3],width:r[2],height:r[3]});
const opacity=1,appearance={preserveSourceBackgroundColor:true};const item={id:'A',sourceBounds:f.bounds,auxiliaryInkRects:[],sourceFrame:f.frame,sourceFontSize:f.font,sourceVertical:false,sourceSingleColumn:true,sourceTextOnly:false,rotation:0,balancedColumn:false};
const node={dataset:{aidokuRegion:'A'},style:{fontSize:'10px'},scrollWidth:10,clientWidth:20,scrollHeight:10,clientHeight:20};
const panel={dataset:{aidokuRegion:'A'},getBoundingClientRect:()=>box(f.plate),remove:()=>trace.push('panel-remove')};
const c={w:f.w,h:f.h,iw:f.w,ih:f.h,frame:f.frame,x:0,y:0,sx:1,sy:1,safe:new Uint8Array(f.safe),luminance:new Uint8Array(f.luminance),erasureComplete:true,sourceErasureVerified:f.verified,sourceGlyphsVerified:f.glyphsVerified,sourceRemainingInk:f.remaining,sourceCorePixels:f.corePixels,method:null,partialErasureCertified:f.partial,provisional:false,surfaceRevision:7};
const rgba=new Uint8ClampedArray(f.rgba);c.canvas={isConnected:true,width:f.w,height:f.h,getContext:()=>({getImageData:()=>({data:rgba})})};
const root={contains:()=>true,querySelectorAll:q=>q.includes('"item"')?[node]:q.includes('source-readability-backing')?[]:[panel]};
const items=[item],keptItems=[],restoredPanelGeometry=new Map([[item,c]]),cleanupImageGeometry={frame:f.frame},typographyInkFrames=new Map(),mount={appendChild:()=>{}},measurementHost={remove:()=>{}},readabilityPanels=1;
let artworkSurfaceBudget=f.artworkBudget,paperProposalBudget=0;const budgetStop=()=>true;
const entry={id:'A',fitBalloon:(partial=false,incomplete=false)=>{const mode=partial?'partial':incomplete?'incomplete':'normal';trace.push('fit:'+mode);return f.fits[mode];},restorationFitEligible:()=>{trace.push('eligible');return f.eligible||c.safe.every(x=>x===1);},completeResidualErasure:()=>{trace.push('residual');if(!f.residual)return null;const safe=c.safe.slice(),luma=c.luminance.slice(),rev=c.surfaceRevision;c.safe.fill(1);c.luminance.fill(255);c.surfaceRevision++;return()=>{trace.push('undo-residual');c.safe=safe;c.luminance=luma;c.surfaceRevision++;};},commitRestorationFit:()=>trace.push('commit-residual')};const typographyEntries=[entry];
const document={createRange:()=>({selectNodeContents:()=>{},getBoundingClientRect:()=>box(f.ink)})};const sourceImage={naturalWidth:f.w,naturalHeight:f.h},getComputedStyle=()=>({visibility:'visible',display:'block'}),residualFillKey=()=> 'refused-key';
${code}
return {id:f.id,trace,safe:Array.from(c.safe),luminance:Array.from(c.luminance),revision:c.surfaceRevision,partial:c.partialErasureCertified??false,policy:node.dataset.sourceErasurePolicy??null,residualRefused:c.residualRefused??null,artworkBudget:artworkSurfaceBudget,metadata:node.dataset};
`);fs.writeFileSync(out,JSON.stringify(fixtures.map(run)));
