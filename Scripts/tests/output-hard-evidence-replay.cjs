// Observed corpus replay. These measurements are evidence, not annotated accuracy.
const fs=require('node:fs'),path=require('node:path'),zlib=require('node:zlib');
const [input,output,baseline]=process.argv.slice(2);
const root=path.resolve(__dirname,'../../Aidoku/Core/Translation/NativeEngine/Overlay');
const script=file=>fs.readFileSync(file,'utf8').match(/static let script = """\n([\s\S]*?)\n    """/)[1];
function api(dir){return new Function(script(path.join(dir,'BrowserSourceTextColor.swift'))+
 script(path.join(root,'BrowserSourceGlyphSegmentation.swift'))+
 ';return {colors:aidokuEstimateSourceColors,geometry:aidokuOCRGeometryMask,owned:typeof aidokuEstimateOCRSourceColors==="function"?aidokuEstimateOCRSourceColors:null}')();}
const current=api(root),old=baseline?api(baseline):current,rows=[];
const dist=(a,b)=>a&&b?Math.max(...a.map((v,k)=>Math.abs(v-b[k]))):null;
for(const line of fs.readFileSync(input,'utf8').trim().split('\n')){
 const v=JSON.parse(line),rgba=new Uint8ClampedArray(zlib.inflateSync(Buffer.from(v.rgba,'base64')));
 const owner=current.geometry(v.w,v.h,v.polygons,v.excluded,1);
 const before=old.colors(rgba,v.w,v.h),after=current.owned(rgba,v.w,v.h,owner);
 const support=color=>{if(!color)return null;let inside=0,outside=0;
  for(let i=0;i<owner.length;i++)if(Math.max(...color.map((c,k)=>Math.abs(c-rgba[i*4+k])))<=24){
   if(owner[i])inside++;else outside++;
  }return {inside,outside};};
 rows.push({page:v.page,id:v.id,quadBoxAreaRatio:v.quadBoxAreaRatio,
  before:before?.foreground||null,after:after?.foreground||null,delta:dist(before?.foreground,after?.foreground),
  beforeSupport:support(before?.foreground),afterSupport:support(after?.foreground),
  beforeConfidence:before?.confidence?.foreground||0,afterConfidence:after?.confidence?.foreground||0});
}
const maps=JSON.parse(fs.readFileSync(path.join(output,'maps.json'),'utf8')).map(m=>{
 const raw=fs.readFileSync(m.raw),n=m.width*m.height,seen=new Uint8Array(n),queue=new Int32Array(n);
 let components=0,large=0,selected=0;const boxes=[];
 for(let i=0;i<n;i++)if(raw.readFloatLE(i*4)>=m.threshold)seen[i]=1,selected++;
 for(let start=0;start<n;start++)if(seen[start]){
  let tail=1,l=m.width,r=0,t=m.height,b=0;queue[0]=start;seen[start]=0;
  for(let head=0;head<tail;head++){
   const i=queue[head],x=i%m.width,y=i/m.width|0;l=Math.min(l,x);r=Math.max(r,x);t=Math.min(t,y);b=Math.max(b,y);
   // Detector components use eight-connected threshold topology.
   for(let yy=Math.max(0,y-1);yy<=Math.min(m.height-1,y+1);yy++)
    for(let xx=Math.max(0,x-1);xx<=Math.min(m.width-1,x+1);xx++){
     const j=yy*m.width+xx;if(seen[j]){seen[j]=0;queue[tail++]=j;}
    }
  }
  components++;if(tail>=16){large++;boxes.push({x:l,y:t,width:r-l+1,height:b-t+1,pixels:tail});}
 }
 return {...m,raw:undefined,thresholdComponents:components,componentsAtLeast16Pixels:large,selected,boxes};
});
const summary={pages:maps.length,colorCrops:rows.length,quadBoxAreaBelow85Percent:rows.filter(r=>r.quadBoxAreaRatio<.85).length,
 changedColorAtLeast24:rows.filter(r=>r.delta>=24).length,
 previouslyUnresolvedNowResolved:rows.filter(r=>!r.before&&r.after).length,
 previouslyResolvedNowUnresolved:rows.filter(r=>r.before&&!r.after).length,
 note:'No manually labelled corpus ground truth. Color changes and component counts are diagnostic, not accuracy percentages.',rows,maps};
fs.writeFileSync(path.join(output,'evidence-summary.json'),JSON.stringify(summary,null,2));
console.log(JSON.stringify({...summary,rows:undefined,maps:undefined}));
