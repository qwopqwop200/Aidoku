"""Read-only interior palette audit of immutable actual iOS captures."""
import json, hashlib, math
from collections import Counter
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
CAP=ROOT/'build/native-render-parity/verify-foreign-background-build53-snapshot'
OUT=ROOT/'build/native-render-parity/foreign-background-gradient'
inputs=json.loads((CAP/'literal-inputs.json').read_text())
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
records=[]
for case in inputs:
 folder=CAP/case['name'];web=(folder/'web-live.rgba').read_bytes();native=(folder/'native-live.rgba').read_bytes();dom=json.loads((folder/'web-dom.json').read_text())
 width,height=960,480;assert len(web)==len(native)==width*height*4
 owner=dom['usedFinalOwner'];dpr=dom['devicePixelRatio'];assert dpr==3
 rects=[]
 for layer in case['layers']:
  x=owner[0]+layer['position'][0];y=owner[1]+layer['position'][1];w,h=layer['size']
  rects.append([max(x,owner[0])*dpr,max(y,owner[1])*dpr,min(x+w,owner[0]+owner[2])*dpr,min(y+h,owner[1]+owner[3])*dpr])
 def sample(rect,exclude,expected):
  # A fixed 3-raster-pixel inset excludes all fractional clip/image edges.
  x0,y0,x1,y1=rect;x0=math.ceil(x0)+3;y0=math.ceil(y0)+3;x1=math.floor(x1)-3;y1=math.floor(y1)-3
  counters=[Counter(),Counter()];diff=0;max_delta=0
  for y in range(max(0,y0),min(height,y1)):
   for x in range(max(0,x0),min(width,x1)):
    if any(a-3<=x<c+3 and b-3<=y<d+3 for a,b,c,d in exclude):continue
    i=(y*width+x)*4;colors=[tuple(b[i:i+4]) for b in [web,native]]
    for c,p in zip(counters,colors):c[p]+=1
    if colors[0]!=colors[1]:diff+=1
    max_delta=max(max_delta,max(abs(a-b) for a,b in zip(*colors)))
  return dict(interiorRaster=[x0,y0,x1,y1],expectedRGBA=expected+[255],pixels=sum(counters[0].values()),differentPixels=diff,maxChannelDifference=max_delta,
   webPalette=[dict(rgba=list(c),count=n) for c,n in counters[0].most_common()],nativePalette=[dict(rgba=list(c),count=n) for c,n in counters[1].most_common()])
 layers=[dict(index=i,**sample(rect,rects[:i]+rects[i+1:],case['layers'][i]['color'])) for i,rect in enumerate(rects)]
 ox,oy,ow,oh=owner;base=sample([ox*dpr,oy*dpr,(ox+ow)*dpr,(oy+oh)*dpr],rects,case['base'])
 records.append(dict(name=case['name'],webSHA256=sha(folder/'web-live.rgba'),nativeSHA256=sha(folder/'native-live.rgba'),domSHA256=sha(folder/'web-dom.json'),base=base,layers=layers))
report=dict(scope='Read-only constant-gradient interior palette audit, fixed three-raster-pixel edge exclusion; no filter fitting or pixel replacement',inputSHA256=sha(CAP/'literal-inputs.json'),cases=records)
(OUT/'interior-audit.json').write_text(json.dumps(report,indent=2))
print(json.dumps([dict(name=r['name'],basePixels=r['base']['pixels'],baseDifferent=r['base']['differentPixels'],layers=[dict(index=l['index'],pixels=l['pixels'],differentPixels=l['differentPixels'],maxDifference=l['maxChannelDifference'],webPaletteCount=len(l['webPalette']),nativePaletteCount=len(l['nativePalette'])) for l in r['layers']]) for r in records],indent=2))
