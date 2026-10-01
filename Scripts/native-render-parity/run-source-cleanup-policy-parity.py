#!/usr/bin/env python3
"""Callable dormant cleanup capability versus frozen appendSourceCleanup.

This explicitly invokes the original dormant function as a policy oracle. It
DOES NOT imply the legacy renderer invoked it, or enable a new production pass.
All crops use nonuniform integer native-size pixels, with exact RGBA comparison.
"""
import hashlib,json,pathlib,subprocess
ROOT=pathlib.Path(__file__).resolve().parents[2];HERE=pathlib.Path(__file__).resolve().parent
SRC=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay';OUT=ROOT/'build/native-render-parity/source-cleanup'
NODE=r'''
const fs=require('fs'),vm=require('vm'),base=process.argv[1],fixtures=JSON.parse(fs.readFileSync(0,'utf8'));
function script(name){return fs.readFileSync(base+'/'+name+'.swift','utf8').split('static let script = """')[1].split('"""')[0];}
const source=fs.readFileSync(base+'/BrowserOverlayView.swift','utf8'),body=source.slice(source.indexOf('const appendSourceCleanup ='),source.indexOf('// Optional restoration;'));
class Canvas{constructor(){this.canvas=this;this.style={};}getContext(){return this;}setAttribute(){}
 drawImage(image,x,y,sw,sh,dx,dy,w,h){if(sw!==w||sh!==h||!Number.isInteger(x)||!Number.isInteger(y))throw Error('oracle requires exact crop');this.data=new Uint8ClampedArray(w*h*4);for(let yy=0;yy<h;yy++)for(let xx=0;xx<w;xx++){let from=((yy+y)*image.naturalWidth+xx+x)*4,to=(yy*w+xx)*4;for(let c=0;c<4;c++)this.data[to+c]=image.rgba[from+c];}}
 getImageData(){return {data:this.data};}createImageData(w,h){return {data:new Uint8ClampedArray(w*h*4)}}putImageData(output){this.output=output;}}
const results=[];
for(const f of fixtures){
 const image={complete:true,naturalWidth:f.width,naturalHeight:f.height,rgba:Uint8ClampedArray.from(f.rgba)},children=[];
 const c=vm.createContext({sourceImage:image,cleanupContext:new Canvas(),cleanupCanvas:null,opacity:f.opacity??1,
   cleanupImageGeometry:{frame:f.items[0].sourceFrame},cachedSourceSample:()=>f.sample,cleanupBudget:f.budget??2000000,coloredCleanupBudget:f.coloredBudget??262144,
   cleanedDenseSourceItems:new Set(),cleanupPixels:0,cleanupCount:0,coloredCleanupAudit:[],cleanupCache:{entries:new Map()},budgetStop:()=>true,
   storeCleanup:(key,p)=>c.cleanupCache.entries.set(key,p),document:{createElement:()=>new Canvas()},root:{appendChild:x=>children.push(x)},
   aidokuCleanupClip:()=>'',scrollX:0,scrollY:0});
 c.cleanupCanvas=c.cleanupContext;
 vm.runInContext(script('BrowserSourceInkCleanup')+'\n'+body+'\nglobalThis.apply=appendSourceCleanup;',c);
 const queries=[];
 for(const item of f.items){
  const previous=children.length;c.apply(item);const canvas=children.length>previous?children[children.length-1]:null;
  const output=canvas?{rect:['left','top','width','height'].map(k=>Number.parseFloat(canvas.style[k])),width:canvas.width,height:canvas.height,rgba:Array.from(canvas.output.data),count:Array.from(canvas.output.data).filter((v,i)=>i%4===3&&v!==0).length,dense:c.cleanedDenseSourceItems.has(item)}:null;
  queries.push({output,budget:c.cleanupBudget,coloredBudget:c.coloredCleanupBudget,cleanedPixels:c.cleanupPixels,cleanupCount:c.cleanupCount,denseItems:Array.from(c.cleanedDenseSourceItems).map(x=>x.id).sort(),audit:Array.from(c.coloredCleanupAudit)});
 }
 results.push({name:f.name,queries});
}
process.stdout.write(JSON.stringify(results));
'''
def fixtures():
 fs=[]
 def add(name,background=(255,255,255),ink=(0,0,0),paint=True,**override):
  w,h=180,120;rgba=list(background)+( [255] );rgba=rgba*(w*h)
  if paint:
   for xx in (32,72,112):
    for x,y,ww,hh in [(xx,30,4,35),(xx+15,30,4,35),(xx,42,19,4)]:
     for yy in range(y,y+hh):
      for xxx in range(x,x+ww):rgba[(yy*w+xxx)*4:(yy*w+xxx)*4+4]=list(ink)+[255]
  item={'id':name,'text':'ABC','width':120,'height':60,'fontSize':18,'lineHeight':20,'sourceBounds':[20/w,20/h,120/w,60/h],
    'sourceFrame':[0,0,w,h],'sourceCleanup':True,'sourceCleanupLexical':True,'sourceColorEligible':True}
  f={'name':name,'width':w,'height':h,'rgba':rgba,'sample':{'foreground':list(ink),'background':list(background)},'items':[item]}
  for k,v in override.items():
   if k in ('budget','coloredBudget','opacity','sample'):f[k]=v
   else:item[k]=v
  fs.append(f);return f
 add('plain white')
 add('vertical white',sourceVertical=True)
 add('tinted lexical',(230,240,245))
 add('gray fallback',(240,240,240))
 add('dark lexical',(32,32,32),(255,255,255))
 add('tinted cleanup only',(230,240,245),sourceCleanup=False)
 add('white success spares gray allowance',(249,249,249))
 add('lexical gate disabled',(230,240,245),sourceCleanupLexical=False)
 add('translation gate disabled',(230,240,245),sourceColorEligible=False,sourceCleanup=False)
 add('rotation skipped',rotation=.1)
 add('zero opacity',opacity=0)
 add('no image ink',paint=False)
 add('budget stop',budget=10)
 add('colored budget stop',(230,240,245),coloredBudget=0)
 add('foreground missing',(230,240,245),sample={'background':[230,240,245]})
 add('backing missing',sample={'foreground':[0,0,0],'background':None})
 add('page edge skipped',sourceBounds=[0,0,.3,.3])
 f=add('repeated prepared cache',(230,240,245));f['items']*=3
 f=add('same pixels different ids',(230,240,245));f['items'].append({**f['items'][0],'id':'second'})
 return fs

def main():
 OUT.mkdir(parents=True,exist_ok=True);fs=fixtures();(OUT/'fixtures.json').write_text(json.dumps(fs))
 model=(SRC/'NativeTranslationLayout.swift').read_text();(OUT/'Models.swift').write_text(model[:model.index('private actor NativeTranslationLayoutWorker')].replace('import UIKit\n',''))
 (OUT/'Shims.swift').write_text('import CoreGraphics\nstruct UIEdgeInsets{var top:CGFloat;var left:CGFloat;var bottom:CGFloat;var right:CGFloat}\nextension CGRect{func inset(by p:UIEdgeInsets)->CGRect{CGRect(x:minX+p.left,y:minY+p.top,width:width-p.left-p.right,height:height-p.top-p.bottom)}}\nenum NativeTranslationLayoutPlanner{static func validGeometry(imageSize:CGSize,sourceRect:CGRect,viewport:CGSize)->Bool{true}}\n')
 names=['NativeSourceInkCleanup','NativeSourceGlyphSegmentation','NativeTranslationPixelKernels','NativeSourceColorSampler','NativeSourceColorSamplingStage','NativeObservedSourcePalette','NativeCaptionSourcePalette','NativeForcedComponentRestoration','NativeForcedSourceInpainting','NativeConnectedLettering']
 files=set(SRC/(n+'.swift') for n in names)
 for pattern in ['NativeRestoration*.swift','NativeObservedRestore*.swift','NativeObservedRestoration*.swift','NativeResidual*.swift']:files.update(SRC.glob(pattern))
 files={p for p in files if 'extension NativeTranslationRestoration' not in p.read_text()} # Uncalled renderer-only extensions.
 snapshot=OUT/'source';snapshot.mkdir(exist_ok=True);paths=[];digest=hashlib.sha256()
 for p in sorted(files):raw=p.read_bytes();(snapshot/p.name).write_bytes(raw);paths.append(str(snapshot/p.name));digest.update(raw)
 lib=ROOT/'build/native-overlay-kernels-host/libAidokuOverlayKernels.a';digest.update(str(lib.stat().st_mtime_ns).encode())
 raw=(HERE/'SourceCleanupParityMain.swift').read_bytes();(OUT/'main.swift').write_bytes(raw);digest.update(raw)
 digest.update((OUT/'Models.swift').read_bytes());digest.update((OUT/'Shims.swift').read_bytes())
 cache=OUT/'build-hash';binary=OUT/'native'
 if not binary.exists() or not cache.exists() or cache.read_text()!=digest.hexdigest():
  subprocess.run(['swiftc','-swift-version','6','-O','-I',str(ROOT/'Scripts/overlay-kernels/native'),str(OUT/'Models.swift'),str(OUT/'Shims.swift'),*paths,str(OUT/'main.swift'),str(lib),'-o',str(binary)],check=True);cache.write_text(digest.hexdigest())
 subprocess.run([str(binary),str(OUT/'fixtures.json'),str(OUT/'native.json')],check=True)
 browser=json.loads(subprocess.check_output(['node','-e',NODE,str(HERE/'reference-source')],input=json.dumps(fs).encode()));(OUT/'browser.json').write_text(json.dumps(browser));native=json.loads((OUT/'native.json').read_text())
 failures=[{'name':a['name'],'native':a,'browser':b} for a,b in zip(native,browser) if a!=b]
 report={'fixtures':len(fs),'passed':len(fs)-len(failures),'failed':failures,'scope':'Explicit callable dormant cleanup policy, exact RGBA/crop/budgets; not enabling legacy-uninvoked pass'}
 (OUT/'report.json').write_text(json.dumps(report,indent=2));print(json.dumps({'fixtures':len(fs),'passed':report['passed'],'failed':[x['name'] for x in failures]}));raise SystemExit(bool(failures))
if __name__=='__main__':main()
