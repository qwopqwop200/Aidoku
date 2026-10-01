const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const root=path.resolve(__dirname,'../../AidokuTests/Translation/LegacyBrowserOverlay');
const script=name=>fs.readFileSync(path.join(root,name+'.swift'),'utf8').match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const {patch,ray}=new Function(['BrowserSourceTextColor','BrowserSourcePanelRestoration','BrowserForcedInpaintQuality'].map(script).join('\n')+
 ';return {patch:aidokuComponentExemplarFill,ray:aidokuForcedDonorFill};')();
const w=144,h=128,n=w*h,clean=new Uint8ClampedArray(n*4),ink=new Uint8ClampedArray(n*4),mask=new Uint8Array(n),blocked=new Uint8Array(n);
for(let y=0;y<h;y++)for(let x=0;x<w;x++){
 const texture=((x%8)<4?7:-7)+((y%8)<4?5:-5);
 clean.set([160+texture,180+texture,200+texture,255],(y*w+x)*4);
}
ink.set(clean);
for(const x0 of [45,83])for(let y=40;y<80;y++)for(let x=x0;x<x0+12;x++){const i=y*w+x;mask[i]=1;ink.set([20,30,40,255],i*4);}
const options={sourceForeground:[20,30,40]};
const repaired=patch(ink,w,h,mask,blocked,options),simple=ray(ink,w,h,mask);
assert.ok(repaired?.quality.safe,'matching clean patches can reconstruct source component texture');
let error=0,rayError=0,count=0;
for(let i=0;i<n;i++)for(let c=0;c<4;c++){
 if(mask[i]&&c<3){count++;error+=Math.abs(clean[i*4+c]-repaired.rgba[i*4+c]);rayError+=Math.abs(clean[i*4+c]-simple.rgba[i*4+c]);}
 else assert.equal(repaired.rgba[i*4+c],ink[i*4+c],'outside paint mask stays exact');
}
assert.ok(error/count<3,`periodic texture restored: ${error/count}`);
assert.ok(error<rayError*.4,'matching patches avoid texture stretched along donor rays');
blocked.fill(1);
assert.ok(!patch(ink,w,h,mask,blocked,options),'excluded neighbouring lettering cannot supply a patch');
console.log(JSON.stringify({matchedPatchMAE:error/count,rayMAE:rayError/count,unchangedOutside:true,excludedDonorsRejected:true}));
