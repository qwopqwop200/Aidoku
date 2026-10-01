const fs=require('fs');const [root,out,fixturePath]=process.argv.slice(2);const ref=root+'/Scripts/native-render-parity/reference-source/';const view=fs.readFileSync(ref+'BrowserOverlayView.swift','utf8'),typo=fs.readFileSync(ref+'BrowserOverlayTypography.swift','utf8'),rest=fs.readFileSync(ref+'BrowserSourcePanelRestoration.swift','utf8');
function extract(text,name){let start=text.indexOf('const '+name+' =');if(start<0)start=text.indexOf('function '+name+'(');if(start<0)throw Error(name);const begin=text.indexOf('{',start);let depth=0,end=begin;for(;end<text.length;end++){if(text[end]==='{')depth++;if(text[end]==='}'&&--depth===0)break;}return text.slice(start,end+2);}
const helper=extract(typo,'aidokuHasAttachedLeadingInk')+'\n'+extract(rest,'aidokuOutlineSourceResolved')+'\n'+extract(view,'aidokuHasLargePartialResidual');
const start=view.indexOf('            const f=cleanupImageGeometry?.frame||item.sourceFrame,b=item.sourceBounds',view.indexOf('// Retry remaining opaque captions against a larger paper component.'));const end=view.indexOf('            const saved={...c}',start),body=view.slice(start,end);
const run=new Function('fixture',helper+`
const f=fixture,trace=[],item={id:'A',sourceBounds:f.bounds,sourceFrame:f.frame,auxiliaryInkRects:f.auxiliary,sourceFontSize:f.sourceFont,sourceVertical:f.vertical,sourceSingleColumn:f.single};
const cleanupImageGeometry={frame:f.frame},sourceImage={naturalWidth:f.iw,naturalHeight:f.ih},node={style:{fontSize:String(f.font)}},cleanupContext={};let paperProposalBudget=f.budget;const scrollX=0,scrollY=0;
const items=[item,...f.excluded.map(sourceBounds=>({sourceBounds,auxiliaryInkRects:[]}))],keptItems=[];
const sourcePixelReader={read:(_,x,y,sw,sh,w,h)=>{trace.push(['read',x,y,sw,sh,w,h]);if(f.readFails)throw Error('source');return new Uint8ClampedArray(f.original);}};
const aidokuEnclosedPaperRestore=(rgba,w,h,box,opts)=>{trace.push(['restore',w,h,box,opts]);return f.repair?{rgba:new Uint8ClampedArray(f.repair.rgba),layoutSafe:new Uint8Array(f.repair.safe),sourceErasureVerified:f.repair.verified}:null;};
const document={createElement:()=>({style:{},setAttribute:()=>{},getContext:()=>({createImageData:(w,h)=>({data:new Uint8ClampedArray(w*h*4)}),putImageData:()=>{}})})},aidokuCleanupClip=()=>'';
for(const unused of [0]){${body}
return {id:fixture.id,trace,budget:paperProposalBudget,result:{crop:[bx,by,w,h],viewport:[f[0]+bx/iw*f[2],f[1]+by/ih*f[3],w/iw*f[2],h/ih*f[3]],core,excluded,original:Array.from(rgba),rgba:Array.from(result.rgba),safe:Array.from(result.layoutSafe),verified:result.sourceErasureVerified,luminance:Array.from(luminance)}};
}return {id:f.id,trace,budget:paperProposalBudget,result:null};
`);fs.writeFileSync(out,JSON.stringify(JSON.parse(fs.readFileSync(fixturePath,'utf8')).map(run)));
