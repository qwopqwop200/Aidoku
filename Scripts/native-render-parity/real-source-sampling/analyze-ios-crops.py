#!/usr/bin/env python3
"""Bounded iOS frozen Canvas/native diagnostics; no rendering or threshold edits."""
import argparse,base64,collections,json
from pathlib import Path

def summarize(row):
 a=base64.b64decode(row['nativeRGBA']);b=base64.b64decode(row['webRGBA']);width,height=row.get('size',[0,0]);assert len(a)==len(b)==width*height*4
 changed=[i for i,(x,y) in enumerate(zip(a,b)) if x!=y];channels={name:collections.Counter(int(b[i])-int(a[i]) for i in range(c,len(a),4) if a[i]!=b[i]) for c,name in enumerate(['r','g','b','a'])}
 def flip(horizontal,vertical):
  for y in range(height):
   yy=height-1-y if vertical else y
   for x in range(width):
    xx=width-1-x if horizontal else x;o=(y*width+x)*4;p=(yy*width+xx)*4
    if a[o:o+4]!=b[p:p+4]:return False
  return True
 output={'id':row.get('id',row.get('item')),'size':[width,height],'rect':row.get('rect'),'exact':not changed,'changedBytes':len(changed),'changedPixels':len({i//4 for i in changed}),'maxDelta':max((abs(a[i]-b[i]) for i in changed),default=0),'opaqueNative':all(x==255 for x in a[3::4]),'opaqueWeb':all(x==255 for x in b[3::4]),'signedChannelDifferences':{k:dict(sorted(v.items())) for k,v in channels.items()},'orientationEquality':{k:flip(*v) for k,v in [('horizontal',(True,False)),('vertical',(False,True)),('both',(True,True))]} if changed else {}}
 if changed:
  premul=lambda x,alpha:int(x*alpha/255+0.5)
  unpremul=lambda x,alpha:0 if not alpha else min(255,int(x*255/alpha+0.5))
  for name,transform in [('nativePremultiplied',premul),('nativeUnpremultiplied',unpremul)]:
   output[name+'ChangedBytes']=sum(transform(a[i],a[i-i%4+3])!=b[i] for i in range(len(a)) if i%4!=3)+sum(a[i]!=b[i] for i in range(3,len(a),4))
 return output

def source_phase_proof(rows):
 """Enumerate integer source phases using only independently equal raw tiles."""
 base=rows[0];w,h=base['size'];x,y,sw,sh=base['rect']
 if sw!=w*2 or sh!=h*2:return None
 native=base64.b64decode(base['nativeRGBA']);web=base64.b64decode(base['webRGBA'])
 candidates=[]
 for dx in range(-2,3):
  for dy in range(-2,3):
   errors=[];native_errors=[]
   for tile in rows[1:]:
    tw,th=tile['size'];tx,ty,tsw,tsh=tile['rect']
    raw=base64.b64decode(tile['nativeRGBA'])
    if raw!=base64.b64decode(tile['webRGBA']) or tw!=tsw or th!=tsh or any(a!=255 for a in raw[3::4]):continue
    ox,oy=(tx-x)/2,(ty-y)/2
    if ox!=int(ox) or oy!=int(oy):continue
    for yy in range(1,th//2-2):
     for xx in range(1,tw//2-2):
      for c in range(3):
       v=sum(raw[((2*yy+dy+cy)*tw+2*xx+dx+cx)*4+c] for cy in (0,1) for cx in (0,1))//4
       index=((int(oy)+yy)*w+int(ox)+xx)*4+c
       errors.append(abs(v-web[index]));native_errors.append(abs(v-native[index]))
   if errors:candidates.append({'dx':dx,'dy':dy,'rgbSamples':len(errors),'webExact':sum(v==0 for v in errors),'webMaxDelta':max(errors),'webMeanDelta':sum(errors)/len(errors),'nativeExact':sum(v==0 for v in native_errors),'nativeMaxDelta':max(native_errors)})
 candidates.sort(key=lambda r:(r['webMeanDelta'],r['webMaxDelta']))
 return {'method':'Opaque raw-source 2x2 box-floor oracle, enumerated integer source phase; crop edges excluded. Same raw source tile byte equality is required.','bestWeb':candidates[0] if candidates else None,'unshifted':next((c for c in candidates if c['dx']==0 and c['dy']==0),None),'topCandidates':candidates[:3]}

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('snapshot',type=Path);p.add_argument('--output',type=Path);a=p.parse_args();reports=[]
 for fixture,name in [('real-comic-0015','source-canvas-item-7.json'),('real-comic-0025','source-canvas-forced-item-4.json'),('real-comic-0025','source-canvas-forced-item-14.json')]:
  f=a.snapshot/fixture/name
  if not f.exists():reports.append({'fixture':fixture,'file':name,'available':False});continue
  d=json.loads(f.read_text());rows=d.get('rows',[d]);r={'fixture':fixture,'file':name,'available':True,'preparedSourceSize':d.get('preparedSourceSize'),'webSourceSize':d.get('webSourceSize'),'sameSourceDimensions':d.get('preparedSourceSize')==d.get('webSourceSize'),'rows':[summarize(x) for x in rows]}
  if 'nativeCropPNGRoundtrip' in d:
   roundtrip={**d['nativeCropPNGRoundtrip'],'id':'native-crop-PNG-roundtrip','size':rows[0]['size']};r['nativeCropPNGRoundtrip']=summarize(roundtrip)
   base=r['rows'][0];direct=r['rows'][1:];r['sourcePhaseProof']=source_phase_proof(rows)
   if not r['sameSourceDimensions']:r['finding']='Prepared native and frozen decoded source dimensions differ; source normalization/admission must be inspected first.'
   elif base['exact']:r['finding']='Actual reduced source bytes are equal. The sampled RGB discrepancy lies after source transport (policy/kernel/phase/cache), not this crop raster.'
   elif all(x['exact'] for x in direct) and r['nativeCropPNGRoundtrip']['exact']:r['finding']='Native PNG roundtrip and checked integer source pixels are equal; divergence is isolated to reduced Canvas/CG raster interpolation on this iOS backend.'
   elif not r['nativeCropPNGRoundtrip']['exact']:r['finding']='Native smallcrop PNG decode/Canvas roundtrip differs; inspect color space/alpha transport before sampler policy.'
   else:r['finding']='Integer source samples differ too; inspect prepared source PNG/native color-space/orientation conversion. Reduced-crop interpolation alone is not yet isolated.'
  else:r['finding']='Forced exact 1:1 crop bytes '+('are equal; donor/ownership/certification policy remains downstream.' if r['rows'][0]['exact'] else 'differ; inspect source transport before restoration policy.')
  reports.append(r)
 output=a.output or a.snapshot/'source-canvas-analysis.json';output.write_text(json.dumps({'scope':'Exact same-input bounded iOS source byte diagnostics; no pixel tolerance or threshold tuning. Orientation checks are exact flips; color-space cause remains conditional evidence.','reports':reports},indent=2));print(output)
 return 0
if __name__=='__main__':raise SystemExit(main())
