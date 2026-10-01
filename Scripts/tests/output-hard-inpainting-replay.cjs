// Frozen historical Web renderer reference; production native rendering is tested by AidokuFull.
// Replay captured production repair arguments; real pages have no ground-truth clean image.
const fs=require('node:fs'),path=require('node:path'),zlib=require('node:zlib'),vm=require('node:vm');
const [fixture,baseline,output,captureDirectory]=process.argv.slice(2);
if(captureDirectory)fs.mkdirSync(captureDirectory,{recursive:true});
const root=path.resolve(__dirname,'../../AidokuTests/Translation/LegacyBrowserOverlay');
const script=file=>fs.readFileSync(file,'utf8').match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const adapter=fs.readFileSync(path.join(root,'BrowserSourceGlyphConservative.swift'),'utf8');
const load=old=>{
 const scripts=[];
 const adapterFile=old&&fs.existsSync(path.join(baseline,'BrowserSourceGlyphConservative.swift'))?path.join(baseline,'BrowserSourceGlyphConservative.swift'):path.join(root,'BrowserSourceGlyphConservative.swift');
 const adapter=fs.readFileSync(adapterFile,'utf8');
 for(const name of ['BrowserSourceTextColor','BrowserSourcePanelRestoration','BrowserSourceGlyphSegmentation',
   'BrowserForcedInpaintQuality','BrowserForcedSourceInpainting','BrowserForcedComponentInpainting']){
   const file=old&&fs.existsSync(path.join(baseline,name+'.swift'))?path.join(baseline,name+'.swift'):path.join(root,name+'.swift');
   let s=script(file);
   if(name==='BrowserSourceGlyphSegmentation')for(const [,a,b]of adapter.matchAll(/of:\s*"([^"]+)"\s*,\s*with:\s*"([^"]+)"/g))s=s.replace(a,b);
   scripts.push(s);
 }
 return new Function(scripts.join('\n')+';return {aidokuForceInpaintSource,aidokuForceInpaintSourceComponent,aidokuForcedDonorFill,aidokuOCRGeometryMask};')();
};
const before=load(true),after=load(false),rows=[];
for(const line of fs.readFileSync(fixture,'utf8').trim().split('\n')){
 const v=JSON.parse(line),rgba=new Uint8ClampedArray(zlib.inflateSync(Buffer.from(v.rgba,'base64')));
 const run=ctx=>{
  const result=ctx[v.function](rgba,v.w,v.h,v.box,v.palette,v.options);
  if(!result)return {accepted:false,reason:ctx[v.function].lastFailure,donorFailure:ctx.aidokuForcedDonorFill.lastFailure,quality:ctx.aidokuForcedDonorFill.lastQuality};
  if(captureDirectory&&v.page==='0023'&&v.function==='aidokuForceInpaintSourceComponent'){
   const prefix=path.join(captureDirectory,`${v.page}-${v.index}-${ctx===before?'before':'after'}`);
   fs.writeFileSync(prefix+'.rgba',result.rgba);fs.writeFileSync(prefix+'.mask',result.layoutSafe);
   fs.writeFileSync(prefix+'.json',JSON.stringify({w:v.w,h:v.h,box:v.box,method:result.method}));
   fs.writeFileSync(prefix+'-source.rgba',rgba);
  }
  let spill=0;const geometry=ctx.aidokuOCRGeometryMask(v.w,v.h,v.options.polygons,v.options.excludedPolygons,7);
  for(let i=0;i<v.w*v.h;i++)if(result.layoutSafe[i]&&geometry&&!geometry[i])spill++;
  return {accepted:true,method:result.method,qualitySafe:result.quality?.safe===true,erased:result.erased,
   remainingInk:result.sourceRemainingInk,paletteInk:result.postFillPaletteInkPixels,spill};
 };
 rows.push({page:v.page,index:v.index,function:v.function,before:run(before),after:run(after)});
}
const summary=side=>({accepted:rows.filter(r=>r[side].accepted).length,
 certified:rows.filter(r=>r[side].qualitySafe).length,
 erased:rows.reduce((s,r)=>s+(r[side].erased||0),0),
 unverifiedAccepted:rows.filter(r=>r[side].accepted&&!r[side].qualitySafe).length,
 paletteInk:rows.reduce((s,r)=>s+(r[side].paletteInk||0),0),spill:rows.reduce((s,r)=>s+(r[side].spill||0),0)});
const result={calls:rows.length,before:summary('before'),after:summary('after'),rows,
 note:'Captured calls include fallback attempts; acceptance is not image accuracy. Palette ink may also be illustration. No labelled clean-background ground truth.'};
fs.writeFileSync(output,JSON.stringify(result,null,2));console.log(JSON.stringify({...result,rows:undefined}));
