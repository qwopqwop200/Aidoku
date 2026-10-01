const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const root=path.resolve(__dirname,'../../AidokuTests/Translation/LegacyBrowserOverlay');
const script=name=>fs.readFileSync(path.join(root,name+'.swift'),'utf8').match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const fill=new Function(script('BrowserSourcePanelRestoration')+script('BrowserForcedInpaintQuality')+';return aidokuCertifiedSurfaceFill')();
const w=100,h=90,n=w*h,clean=new Uint8ClampedArray(n*4),ink=new Uint8ClampedArray(n*4),mask=new Uint8Array(n),blocked=new Uint8Array(n);
for(let y=0;y<h;y++)for(let x=0;x<w;x++)clean.set([175+x*.2,190+y*.1,205+x*.15,255],(y*w+x)*4);
ink.set(clean);
for(let y=20;y<70;y++)for(let x=20;x<80;x++){const i=y*w+x;mask[i]=1;ink.set([30,25,35,255],i*4);}
const options={sourceForeground:[30,25,35]};
const result=fill(ink,w,h,mask,blocked,options);
assert.ok(result?.quality.safe,'independently fitted smooth surface can repair a broad area');
let error=0,count=0;
for(let i=0;i<n;i++)for(let c=0;c<4;c++){
 if(mask[i]&&c<3){error+=Math.abs(result.rgba[i*4+c]-clean[i*4+c]);count++;}
 if(!mask[i])assert.equal(result.rgba[i*4+c],ink[i*4+c],'outside owned repair stays byte-exact');
}
assert.ok(error/count<1,'plane reconstructs independent clean gradient');
const texture=ink.slice();
for(let y=0;y<h;y++)for(let x=0;x<w;x++)if(!mask[y*w+x])texture.set((x+y)%2?[60,65,70,255]:[210,200,190,255],(y*w+x)*4);
assert.equal(fill(texture,w,h,mask,blocked,options),null,'illustration texture cannot be certified as a plane');
const singleSide=blocked.slice();for(let y=0;y<h;y++)for(let x=0;x<w;x++)if(x>=20)singleSide[y*w+x]=1;
assert.equal(fill(ink,w,h,mask,singleSide,options),null,'one-sided donors cannot prove the hidden surface');
assert.ok(!fill(clean,w,h,mask,blocked,{sourceForeground:[190,195,210]}),'surface matching source ink cannot certify erasure');
console.log(JSON.stringify({smoothSurfaceMAE:error/count,textureRejected:true,oneSidedRejected:true,inkReconstructionRejected:true}));
