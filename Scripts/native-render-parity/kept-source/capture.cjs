const fs=require('node:fs'),path=require('node:path');const [root,out]=process.argv.slice(2);
const typography=fs.readFileSync(path.join(root,'Scripts/native-render-parity/reference-source/BrowserOverlayTypography.swift'),'utf8');
const helpers=typography.slice(typography.indexOf('    const aidokuSubtractRects ='),typography.indexOf('    // Gloss placement at kept source lettering'));
const zones=new Function('kept','painted',helpers+'return aidokuKeptLetteringZones(kept,painted);');
const view=fs.readFileSync(path.join(root,'Scripts/native-render-parity/reference-source/BrowserOverlayView.swift'),'utf8');
const finalStart=view.indexOf('        const collided=new Set(keptItems.filter(k=>'),finalEnd=view.indexOf('\n        if(pieces.length&&pieces.length<=1024',finalStart);
const body=view.slice(finalStart,finalEnd).replace("for(const panel of root.querySelectorAll('[data-caption-blank-kept=\"true\"]'))",'for(const panel of blankMargins)');
const select=new Function('keptItems','keptZones','effectZones','glyphLines','covers','image','blankMargins',helpers+
 'const box=r=>({left:r.left,top:r.top,right:r.right,bottom:r.bottom});const meets=(a,b)=>Math.min(a.right,b.right)-Math.max(a.left,b.left)>.25&&Math.min(a.bottom,b.bottom)-Math.max(a.top,b.top)>.25;const area=(a,b)=>Math.max(0,Math.min(a.right,b.right)-Math.max(a.left,b.left))*Math.max(0,Math.min(a.bottom,b.bottom)-Math.max(a.top,b.top));'+body+
 ';const emitted=pieces.length&&pieces.length<=1024&&image.width>0&&image.height>0;return {pieces:emitted?pieces.map(p=>[p.left,p.top,p.right-p.left,p.bottom-p.top]):[],collisions:[...collided].sort(),overlaps:[...overlaps].sort(),restoredIDs:emitted?[...new Set(zones.map(z=>z.id))].sort():[]};');
const rect=r=>({left:r[0],top:r[1],right:r[0]+r[2],bottom:r[1]+r[3]});const fixtures=[];
for(let seed=0;seed<80;seed++){
 const kept=[{id:'kept',x:10,y:10,width:20,height:12,sourceFontSize:seed%3?10:null}];
 if(seed%7===0)kept.push({id:'kept2',x:34,y:14,width:10,height:30,sourceFontSize:24});
 const painted=seed%4===0?[[25,8,10,20]]:seed%4===1?[[12,12,4,4]]:seed%4===2?[[80,80,10,10]]:[];
 const glyphs=seed%5===0?[[10,10,3,3]]:seed%5===1?[[10,10,10,10]]:seed%5===2?[[26,11,2,2]]:seed%5===3?[[70,70,6,6]]:[];
 const covers=seed%6===0?[]:[[8,8,50,50]],effects=seed%9===0?[{id:'effect',...rect([50,20,12,8])}]:[];
 const blank=seed%11===0?[[8,8,4,20]]:[],image={...rect(seed%13===0?[14,12,40,24]:[0,0,100,100]),width:100,height:100};
 const kz=zones(kept,painted);
 const expected=select(kept,kz,effects,glyphs.map(rect),covers.map(rect),image,blank.map(r=>({getBoundingClientRect:()=>rect(r)})));
 fixtures.push({seed,kept,painted,glyphs,covers,effects:effects.map(e=>({id:e.id,rect:[e.left,e.top,e.right-e.left,e.bottom-e.top]})),blank,image:[image.left,image.top,image.right-image.left,image.bottom-image.top],expectedZones:kz.map(z=>({id:z.id,rect:[z.left,z.top,z.right-z.left,z.bottom-z.top]})),expected});
}
fs.writeFileSync(out,JSON.stringify(fixtures));console.log(JSON.stringify({cases:fixtures.length,positiveSmallOverlaps:fixtures.filter(f=>f.glyphs.length&&f.expected.pieces.length&&!f.expected.collisions.length).length,collisions:fixtures.filter(f=>f.expected.collisions.length).length}));
