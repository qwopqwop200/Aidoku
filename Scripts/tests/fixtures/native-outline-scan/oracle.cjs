const fs=require('fs'),vm=require('vm'),base=process.argv[3];
const view=fs.readFileSync(base+'/BrowserOverlayView.swift','utf8'),typ=fs.readFileSync(base+'/BrowserOverlayTypography.swift','utf8'),col=fs.readFileSync(base+'/BrowserSourceTextColor.swift','utf8');
const colors=col.slice(col.indexOf('    const aidokuSourceColorLuminance ='),col.indexOf('    // Keep an already readable color.'));
const helpers=view.slice(view.indexOf('      const validO=rgb=>'),view.indexOf('      const nodesO=',view.indexOf('      const validO=rgb=>')));
const enclosed=typ.slice(typ.indexOf('    const aidokuEnclosedCaptionOutline ='),typ.indexOf('    const aidokuChromaticOutlineMinimum ='));
let scan=view.slice(view.indexOf('      const nodesO='),view.indexOf('        const ink=node.dataset.sourceAppliedTextRGB?',view.indexOf('      const nodesO=')));
scan=scan.replace('        if(!result)continue;','        if(result&&!result.reject){const r=x=>Math.round(x*100)/100;node._ring={kind:result.kind,core:result.core,outline:result.outline,uniform:r(result.uniform),hug:r(result.hug),exterior:result.exterior===null?null:r(result.exterior),width:r(result.width),reached:r(result.reached),boxRing:result.boxRing===null?null:r(result.boxRing),surface:result.surface?[...result.surface.rgb,result.surface.flat?1:0]:null};}\n        if(!result)continue;')+'\n}})();';
function read(crop,w,h){const p=new Uint8ClampedArray(w*h*4).fill(255);for(let y=0;y<h;y++)for(let x=0;x<w;x++){
 const px=Math.floor(crop[0]+(x+.5)*crop[2]/w),py=Math.floor(crop[1]+(y+.5)*crop[3]/h),a=((px%27)+27)%27,b=((py%37)+37)%37;
 if(a>=8&&a<10&&b>=10&&b<28||a>=8&&a<21&&(b>=10&&b<12||b>=18&&b<20||b>=26&&b<28)){const at=(y*w+x)*4;p[at]=12;p[at+1]=12;p[at+2]=12;}
}return p;}
const output=JSON.parse(fs.readFileSync(process.argv[2])).map(f=>{
 const items=f.records.map(r=>({...r,sourceBounds:r.bounds,sourceFrame:r.frame,sourceFontSize:r.glyph,sourceVertical:r.vertical||false,sourceColorEligible:r.eligible!==false})),reads=[];
 const nodes=items.map(i=>({dataset:{aidokuRegion:String(i.id),sourceBackgroundColor:i.mode,sourceAppliedTextRGB:i.ink?.join(','),partialMainbodyProof:i.proof},style:{visibility:i.visible===false?'hidden':'visible',webkitTextStrokeWidth:String(i.stroke||0),backgroundColor:i.plate?'rgb('+i.plate.join(',')+')':''},_rect:{left:0,top:0,right:10,bottom:10}}));
 for(let n=0;n<nodes.length;n++){const p=items[n].plate?{dataset:{aidokuRegion:String(items[n].id),aidokuImageOcrOverlay:'source-readability-panel'},style:{backgroundColor:'rgb('+items[n].plate.join(',')+')'}}:null;nodes[n].parentElement=p;}
 const panels=nodes.map(n=>n.parentElement).filter(Boolean),context={},c={items,root:{querySelectorAll:q=>q.includes('="item"')?nodes:q.includes('source-readability-panel')?panels:[]},document:{createElement:()=>({getContext:()=>context}),createRange:()=>({selectNodeContents(n){this.n=n;},getBoundingClientRect(){return this.n._rect;}})},cachedSourceSample:i=>i.sample||{},restoredPanelGeometry:new Map(items.filter(i=>i.reserve).map(i=>[i,{observedDarkInk:true}])),rotatedPlates:nodes,frameO:f.display||null,ringSource:{naturalWidth:f.image[0],naturalHeight:f.image[1]},ringPixels:393216,sourcePixelReader:{read(ctx,x,y,sw,sh,w,h){reads.push([x,y,sw,sh,w,h]);return read([x,y,sw,sh],w,h);}}};
 vm.createContext(c);vm.runInContext(colors+helpers+enclosed+scan,c);
 return {name:f.name,reads,states:nodes.map(n=>({id:n.dataset.aidokuRegion,ring:n._ring||null,enclosed:n.dataset.enclosedCaptionOutline?JSON.parse(n.dataset.enclosedCaptionOutline):null,reject:n.dataset.outlinedLetteringReject||null}))};
});fs.writeFileSync(process.argv[4],JSON.stringify(output));
