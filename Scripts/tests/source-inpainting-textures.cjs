// Texture metrics use known clean backgrounds; random texture cannot be recovered pixel for pixel.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),zlib=require('node:zlib');
const {resize}=require('./source-color-test-harness.cjs');
const arg=name=>process.argv.includes(name)?process.argv[process.argv.indexOf(name)+1]:null;
const source=path.resolve(__dirname,'../../Aidoku/Core/Translation/NativeEngine/Overlay');
const script=file=>fs.readFileSync(file,'utf8').match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const restore=new Function(script(arg('--restoration-source')||path.join(source,'BrowserSourcePanelRestoration.swift'))+';return aidokuRestoreSourcePanel;')();
const document={createElement(){let d;return{getContext(){return{drawImage(image,sx,sy,sw,sh,dx,dy,w,h){d={image,sx,sy,sw,sh,w,h};},getImageData(){return{data:resize(d.image,d.sx,d.sy,d.sw,d.sh,d.w,d.h)};}};}};}};
const sample=new Function('document',script(arg('--color-source')||path.join(source,'BrowserSourceTextColor.swift'))+';return aidokuSourceColorSampler;')(document);
const hash=a=>crypto.createHash('sha256').update(a).digest('hex'),rows=[];
for(const f of JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/source-inpainting-textures.json'))).fixtures){
 const rgba=new Uint8ClampedArray(zlib.inflateSync(Buffer.from(f.rgba,'base64'))),before=hash(rgba),budget={pixels:393216,detailPixels:98304};assert.equal(before,f.pixelSHA256);
 const sampler=sample({complete:true,naturalWidth:f.w,naturalHeight:f.h,data:rgba},true,'ocr',budget),palette=sampler.sample(f.b.map((v,i)=>v/(i%2?f.h:f.w)));
 const out=restore(rgba,f.w,f.h,f.b,palette,{readabilityGate:true,vertical:f.vertical,sampleScale:f.scale});
 const damage=f.protectedPixels.reduce((n,i)=>n+Boolean(out?.rgba[i*4+3]),0),pass=!!out&&out.surfaceQuality?.reason===f.expectedSurface&&damage===0;
 rows.push({id:f.name,accepted:!!out,surface:out?.surfaceQuality?.reason,protectedDamage:damage,pass});
 assert.equal(hash(rgba),before);assert.ok(budget.pixels>=0&&budget.detailPixels>=0&&sampler.stats.pixels<=393216);
 if(!process.argv.includes('--measure-only'))assert.ok(pass,JSON.stringify(rows.at(-1)));
}
for(const type of ['grain','dots'])for(const dark of [false,true])for(const seed of [1,2,3]){
 const w=240,h=180,b=[24,52,192,64],rgba=new Uint8ClampedArray(w*h*4),bg=dark?[50,60,65]:[195,200,205],fg=dark?[245,240,230]:[10,12,14];
 let state=seed;const random=()=>((state=(Math.imul(state,1664525)+1013904223)>>>0)/4294967296);
 for(let y=0;y<h;y++)for(let x=0;x<w;x++){
  const v=type==='grain'?(random()-.5)*(20+seed*4):((x+seed)% (4+seed)===0&&(y+seed)%(4+seed)===0?(dark?185:-185):0);
  for(let c=0;c<3;c++)rgba[(y*w+x)*4+c]=bg[c]+v+(type==='grain'?x/w*8+y/h*4:0);rgba[(y*w+x)*4+3]=255;
 }
 const clean=rgba.slice(),ink=[];
 // Independent raster mask, with a contrasting outline on dotted backgrounds.
 for(let k=0;k<5;k++)for(let y=70;y<102;y++)for(let x=35+k*35;x<55+k*35;x++){
  if(x>=40+k*35&&y>=75&&y<97)continue;ink.push(y*w+x);
 }
 if(type==='dots')for(const i of ink){const x=i%w,y=i/w|0;for(let yy=y-3;yy<=y+3;yy++)for(let xx=x-3;xx<=x+3;xx++)rgba.set([...bg,255],(yy*w+xx)*4);}
 for(const i of ink)rgba.set([...fg,255],i*4);
 const palette={foreground:fg,background:bg,confidence:{foreground:1,background:1},...(type==='dots'?{stroke:bg}: {})};
 const before=hash(rgba);
 const start=performance.now(),out=restore(rgba,w,h,b,palette,{readabilityGate:true}),mask=out?.rgba;
 let error=0,count=0,recall=0,a=0,c=0,damage=0;
 if(mask)for(let y=1;y<h-1;y++)for(let x=1;x<w-1;x++){
  const i=y*w+x;if(!mask[i*4+3])continue;for(let k=0;k<3;k++){error+=Math.abs(mask[i*4+k]-clean[i*4+k]);count++;}
  if(x<20||x>w-20||y<40||y>130)damage++;
  if([i-1,i+1,i-w,i+w].every(j=>mask[j*4+3])){
   a+=(mask[i*4+1]-[i-1,i+1,i-w,i+w].reduce((s,j)=>s+mask[j*4+1],0)/4)**2;
   c+=(clean[i*4+1]-[i-1,i+1,i-w,i+w].reduce((s,j)=>s+clean[j*4+1],0)/4)**2;
  }
 }
 for(const i of ink)recall+=Boolean(mask?.[i*4+3]);
 const row={id:`${type}-${dark}-${seed}`,accepted:!!out,reason:out?.surfaceQuality?.reason,mae:error/Math.max(1,count),recall:recall/ink.length,textureRatio:Math.sqrt(a/Math.max(1,c)),damage,ms:performance.now()-start};row.pass=row.accepted&&row.recall===1&&row.damage===0&&(type==='dots'?row.mae<=1&&row.textureRatio>=.9&&row.textureRatio<=1.1:row.mae<=12&&row.textureRatio>=.8&&row.textureRatio<=1.2);
 assert.equal(hash(rgba),before);rows.push(row);
 if(!process.argv.includes('--measure-only'))assert.ok(row.pass,JSON.stringify(row));
}
if(arg('--report'))fs.writeFileSync(arg('--report'),JSON.stringify(rows,null,2));
console.log(`${rows.filter(x=>x.pass).length}/${rows.length} real texture and known-background checks passed`);
