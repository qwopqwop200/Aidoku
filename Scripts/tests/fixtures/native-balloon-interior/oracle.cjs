const fs=require('fs'),vm=require('vm'),base=process.argv[3];
const view=fs.readFileSync(base+'/BrowserOverlayView.swift','utf8');
const source=view.slice(view.indexOf('    const estimateBalloonInterior=item=>'),view.indexOf('    // Native planning sees only',view.indexOf('    const estimateBalloonInterior=item=>')));
const box=v=>({left:v[0],top:v[1],right:v[0]+v[2],bottom:v[1]+v[3]});
const output=JSON.parse(fs.readFileSync(process.argv[2])).map(f=>{
 const reads=[],frame=f.frame,context={drawImage(image,x,y,sw,sh,ox,oy,w,h){reads.push([frame[0]+x,frame[1]+y,sw,sh,w,h]);},getImageData:()=>({data:new Uint8ClampedArray(f.rgba)})};
 const c={cleanupImageGeometry:{frame},balloonImage:{complete:true,naturalWidth:frame[2],naturalHeight:frame[3]},opacity:1,balloonCanvas:null,balloonScratch:null,balloonInteriorBudget:f.budget??3000000,budgetStop:()=>true,document:{createElement:()=>({getContext:()=>context})},balloonRectsOf:()=>f.own.map(box),unitMembersOf:()=>f.members?Array(f.members).fill({}):null,sourceRectOf:()=>f.union?box(f.union):null};
 vm.createContext(c);vm.runInContext(source+'\nglobalThis.estimate=estimateBalloonInterior;',c);
 const results=[];for(let i=0;i<(f.repeat||1);i++){const r=c.estimate({sourceFontSize:f.glyph});results.push(r?{w:r.w,h:r.h,k:r.k,fill:Array.from(r.fill),paper:r.surfaceRGB,tight:r.tight,outside:f.queries.map(q=>r.outside(box(q)))}:null);}
 return {name:f.name,reads,remaining:c.balloonInteriorBudget,results};
});fs.writeFileSync(process.argv[4],JSON.stringify(output));
