from pathlib import Path
import numpy as np,json,math
from PIL import Image
ROOT=Path(__file__).resolve().parents[3];BASE=ROOT/'build/native-render-parity/verify-source-canvas-build43-snapshot';OUT=ROOT/'build/native-render-parity/source-canvas-clip/cpu-bilinear43';OUT.mkdir(exist_ok=True)
records=[]
for scene in ['original-six','negative-global','negative-global-half']:
 d=BASE/scene;doc=json.loads((d/'web-dom-and-saved-masks.json').read_text());ref=np.fromfile(d/'web-live-640.rgba',np.uint8).reshape(3000,1920,4)
 for quant in [0,256,512,1024]:
  for rounding in ['nearest','up','floor']:
   canvas=np.full((3000,1920,4),255,np.uint8)
   for c in doc['records']:
    x,y,w,h=c['used'];l,t,r,b=[math.floor(v+.5) for v in [x,y,x+w,y+h]]
    if r<=l or b<=t:continue
    left,top,right,bottom=[v*3 for v in [l,t,r,b]];xx=np.arange(max(0,left),min(1920,right));yy=np.arange(max(0,top),min(3000,bottom))
    src=np.asarray(Image.open(d/f"source-{c['id']}.png").convert('RGBA')).astype(np.float32)
    u=((xx+.5-left)/(right-left)*src.shape[1]-.5);v=((yy+.5-top)/(bottom-top)*src.shape[0]-.5)
    u=np.clip(u,0,src.shape[1]-1);v=np.clip(v,0,src.shape[0]-1);ix=np.floor(u).astype(int);iy=np.floor(v).astype(int);jx=np.minimum(ix+1,src.shape[1]-1);jy=np.minimum(iy+1,src.shape[0]-1)
    fx=u-ix;fy=v-iy
    if quant:fx=np.floor(fx*quant+.5)/quant;fy=np.floor(fy*quant+.5)/quant
    z=(src[iy[:,None],ix[None,:]]*(1-fx)[None,:,None]+src[iy[:,None],jx[None,:]]*fx[None,:,None])*(1-fy)[:,None,None]+(src[jy[:,None],ix[None,:]]*(1-fx)[None,:,None]+src[jy[:,None],jx[None,:]]*fx[None,:,None])*fy[:,None,None]
    z=np.rint(z) if rounding=='nearest' else np.floor(z+.5) if rounding=='up' else np.floor(z)
    canvas[np.ix_(yy,xx)]=z.astype(np.uint8)
   delta=np.abs(canvas.astype(np.int16)-ref.astype(np.int16));records.append(dict(scene=scene,phaseQuantization=quant,outputRounding=rounding,changedPixels=int(np.any(delta,axis=2).sum()),maxDelta=int(delta.max())))
   (OUT/f'{scene}-phase{quant}-{rounding}.rgba').write_bytes(canvas.tobytes())
(OUT/'report.json').write_text(json.dumps(dict(scope='CPU encoded-RGB bilinear models against actual .never iOS43 outputDPR3. Fixed phase/outputrounding alternatives test literal sampler precision; no production policy or fixturechanged.',experiments=records),indent=2));print(json.dumps(records,indent=2))
