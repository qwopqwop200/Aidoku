// Reproduced small-ink/display failures and preservation of periodic backings.
// --color-source FILE --restoration-source FILE --measure-only --report FILE
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),zlib=require('node:zlib'),crypto=require('node:crypto');
const {resize}=require('./source-color-test-harness.cjs');
const arg=name=>process.argv.includes(name)?process.argv[process.argv.indexOf(name)+1]:null;
const root=path.resolve(__dirname,'../../Aidoku/Core/Translation/NativeEngine/Overlay');
const script=file=>fs.readFileSync(file,'utf8').match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const document={createElement(){let d;return{getContext(){return{drawImage(image,sx,sy,sw,sh,dx,dy,w,h){d={image,sx,sy,sw,sh,w,h};},getImageData(){return{data:resize(d.image,d.sx,d.sy,d.sw,d.sh,d.w,d.h)};}};}};}};
const [sample,display]=new Function('document',script(arg('--color-source')||path.join(root,'BrowserSourceTextColor.swift'))+';return [aidokuSourceColorSampler,aidokuSourceDisplayInk];')(document);
const restore=new Function(script(arg('--restoration-source')||path.join(root,'BrowserSourcePanelRestoration.swift'))+';return aidokuRestoreSourcePanel;')();
const hash=a=>crypto.createHash('sha256').update(a).digest('hex'),rows=[];
const fixtures=JSON.parse(fs.readFileSync(path.join(__dirname,'fixtures/source-inpainting-hard-cases.json'))).fixtures;
for(const f of fixtures){
 const rgba=new Uint8ClampedArray(zlib.inflateSync(Buffer.from(f.rgba,'base64'))),before=hash(rgba),budget={pixels:393216,detailPixels:98304};
 assert.equal(before,f.pixelSHA256);
 const sampler=sample({complete:true,naturalWidth:f.w,naturalHeight:f.h,data:rgba},true,'ocr',budget);
 const palette=sampler.sample(f.b.map((v,i)=>v/(i%2?f.h:f.w))),color=display(palette);
 const colorError=f.expectedColor?(color?Math.max(...color.map((v,c)=>Math.abs(v-f.expectedColor[c]))):255):null;
 const out=f.expectAccepted===undefined?null:restore(rgba,f.w,f.h,f.b,palette,{readabilityGate:true,vertical:f.vertical,sampleScale:f.scale});
 let damage=0;for(const i of f.protectedPixels||[])damage+=!!out?.rgba[i*4+3];
 const pass=(colorError===null||colorError<=f.colorTolerance)&&(f.expectAccepted===undefined||!!out===f.expectAccepted)&&
   (!f.expectedSurface||out?.surfaceQuality?.reason===f.expectedSurface)&&damage===0;
 rows.push({id:f.name,color,colorError,accepted:!!out,surface:out?.surfaceQuality?.reason,protectedDamage:damage,pass});
 assert.equal(hash(rgba),before);assert.ok(budget.pixels>=0&&budget.detailPixels>=0&&sampler.stats.pixels<=393216);
 if(!process.argv.includes('--measure-only'))assert.ok(pass,`${f.name}: ${f.review}; ${JSON.stringify(rows.at(-1))}`);
}
// Known clean periodic backgrounds independently score every restored pixel,
// including exterior mask growth. Text, phase, period, hue and polarity vary.
for(const [px,py] of [[36,24],[48,32],[54,36]])for(const dark of [false,true]){
 const w=400,h=200,rgba=new Uint8ClampedArray(w*h*4),ink=[],bg=dark?[42,50,62]:[230,238,192],fg=dark?[242,236,225]:[20,30,40];
 for(let y=0;y<h;y++)for(let x=0;x<w;x++){
   const z=Math.sin((x+7)*Math.PI*2/px)*Math.cos((y+5)*Math.PI*2/py);
   rgba.set([bg[0]+12*z,bg[1]+8*z,bg[2]+10*z,255],(y*w+x)*4);
 }
 const clean=rgba.slice();
 for(let k=0;k<8;k++)for(let y=83;y<116;y++)for(let x=40+k*40;x<62+k*40;x++){
   if(x>=45+k*40&&y>=88&&y<111)continue;const i=y*w+x;ink.push(i);rgba.set([...fg,255],i*4);
 }
 const before=hash(rgba),out=restore(rgba,w,h,[36,78,312,44],{foreground:fg,background:bg,confidence:{foreground:1,background:1}},{readabilityGate:true});
 let error=0,count=0,covered=0,edgeDamage=0;
 for(let i=0;i<w*h;i++)if(out?.rgba[i*4+3]){
   for(let c=0;c<3;c++){error+=Math.abs(out.rgba[i*4+c]-clean[i*4+c]);count++;}
   const x=i%w,y=i/w|0;if(x<12||y<12||x>=w-12||y>=h-12)edgeDamage++;
 }
 for(const i of ink)covered+=out?.rgba[i*4+3]===255;
 const mae=count?error/count:255,pass=covered===ink.length&&mae<=1&&edgeDamage===0;
 rows.push({id:`periodic-${px}-${py}-${dark?'dark':'light'}`,mae,recall:covered/ink.length,edgeDamage,pass});
 assert.equal(hash(rgba),before);
 if(!process.argv.includes('--measure-only'))assert.ok(pass,JSON.stringify(rows.at(-1)));
}
if(arg('--report'))fs.writeFileSync(arg('--report'),JSON.stringify(rows,null,2));
console.log(`${rows.filter(r=>r.pass).length}/${rows.length} hard-case color, mask and known-background regressions passed`);
