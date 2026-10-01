// Replay actual renderer arguments against both versions of the glyph segmenter.
const fs=require('node:fs'),path=require('node:path'),zlib=require('node:zlib');
const [fixture,baseline,output]=process.argv.slice(2),root=path.resolve(__dirname,'../../AidokuTests/Translation/LegacyBrowserOverlay');
const text=file=>fs.readFileSync(file,'utf8').match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const adapter=fs.readFileSync(path.join(root,'BrowserSourceGlyphConservative.swift'),'utf8');
const adapt=s=>{for(const [,a,b] of adapter.matchAll(/of:\s*"([^"]+)"\s*,\s*with:\s*"([^"]+)"/g))s=s.replace(a,b);return s;};
const old=new Function(adapt(text(path.join(baseline,'BrowserSourceGlyphSegmentation.swift')))+';return aidokuForcedTextMask')();
const now=new Function(adapt(text(path.join(root,'BrowserSourceGlyphSegmentation.swift')))+
 ';return {segment:aidokuForcedTextMask,geometry:aidokuOCRGeometryMask}')();
const rows=[],seen=new Set();let duplicateCalls=0;
for(const line of fs.readFileSync(fixture,'utf8').trim().split('\n')){
 if(!line)continue;
 const v=JSON.parse(line),rgba=new Uint8ClampedArray(zlib.inflateSync(Buffer.from(v.rgba,'base64')));
 const identity=require('node:crypto').createHash('sha256').update(rgba).update(JSON.stringify({w:v.w,h:v.h,box:v.box,palette:v.palette,options:v.options})).digest('hex');
 if(seen.has(identity)){duplicateCalls++;continue;}seen.add(identity);
 const before=old(rgba,v.w,v.h,v.box,v.palette,v.options),after=now.segment(rgba,v.w,v.h,v.box,v.palette,v.options);
 const geo=now.geometry(v.w,v.h,v.options.polygons,v.options.excludedPolygons,7);
 const count=m=>m?m.reduce((n,x)=>n+!!x,0):0;
 const outside=m=>m&&geo?m.reduce((n,x,i)=>n+(x&&!geo[i]?1:0),0):0;
 if(after&&outside(after))throw new Error('production segmentation violated polygon ownership');
 rows.push({page:v.page,index:v.index,beforeReturned:!!before,afterReturned:!!after,beforePixels:count(before),afterPixels:count(after),
  beforeOutsideOwnership:outside(before),afterOutsideOwnership:outside(after),
  core:after?[after.sourceCoreCandidateCovered,after.sourceCoreCandidateCount]:null,
  outline:after?[after.sourceOutlineCandidateCovered,after.sourceOutlineCandidateCount]:null});
}
const paired=rows.filter(r=>r.beforeReturned&&r.afterReturned);
const result={replayedCrops:rows.length,duplicateCalls,pairedReturned:paired.length,
 pixelsOutsideOwnershipBefore:paired.reduce((n,r)=>n+r.beforeOutsideOwnership,0),
 pixelsOutsideOwnershipAfter:paired.reduce((n,r)=>n+r.afterOutsideOwnership,0),
 returnedBefore:rows.filter(r=>r.beforeReturned).length,returnedAfter:rows.filter(r=>r.afterReturned).length,rows,
 note:'Polygon ownership measures spill into neighbouring/corner areas; it is not a manually labelled text-mask IoU.'};
fs.writeFileSync(output,JSON.stringify(result,null,2));console.log(JSON.stringify({...result,rows:undefined}));
