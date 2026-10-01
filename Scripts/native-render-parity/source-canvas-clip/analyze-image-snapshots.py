#!/usr/bin/env python3
"""Measure opaque patterned canvas destinations in actual WK snapshot pixels."""
from pathlib import Path
from PIL import Image,ImageChops
from pypdf import PdfReader
from pypdf.generic import ContentStream
import json,math,hashlib
ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).resolve().parent
OUT=ROOT/'build/native-render-parity/source-canvas-clip/image-snapshot'
web=json.loads((OUT/'web.json').read_text());by_color={tuple(c['color']):c for c in web}
page=PdfReader(OUT/'web.pdf').pages[0];pdfHeight=float(page.mediabox.height)
# These dedicated untransformed controls have one image-local cm at each Do.
images=page['/Resources']['/XObject'];stack=[];ctm=(1,0,0,1,0,0);pdfFrames={}
for operands,operator in ContentStream(page.get_contents(),page.pdf).operations:
 if operator==b'q':stack.append(ctm)
 elif operator==b'Q':ctm=stack.pop()
 elif operator==b'cm':
  assert ctm==(1,0,0,1,0,0),'Dedicated controls gained an unexpected outer transform'
  ctm=tuple(float(v) for v in operands)
 elif operator==b'Do':
  c=by_color[tuple(images[operands[0]].get_object().get_data()[:3])]
  a,b,cross,d,x,y=ctm;assert b==0 and cross==0 and a>=0 and d>=0
  pdfFrames[c['id']]=[x,pdfHeight-y-d,a,d]
def edges(box,scale):
 x,y,w,h=box
 def n(v):return math.floor(v*scale+0.5)/scale
 l,t,r,b=n(x),n(y),n(x+w),n(y+h)
 return [l,t,r-l,b-t]
records=[]
for index in [0,1]:
 image=Image.open(OUT/f'snapshot-{index}.png').convert('RGB');scale=image.width/640
 assert image.height==1000*scale
 for c in web:
  x,y,w,h=c['used'];region=(math.floor((x-3)*scale),math.floor((y-3)*scale),math.ceil((x+w+3)*scale),math.ceil((y+h+3)*scale))
  crop=image.crop(region);nonwhite=ImageChops.difference(crop,Image.new('RGB',crop.size,'white')).getbbox()
  pixels=None if nonwhite is None else [region[0]+nonwhite[0],region[1]+nonwhite[1],nonwhite[2]-nonwhite[0],nonwhite[3]-nonwhite[1]]
  css=None if pixels is None else [v/scale for v in pixels]
  candidate=edges(c['used'],1)
  if candidate[2]==0 or candidate[3]==0:assert css is None and c['id'] not in pdfFrames
  else:assert css==candidate==pdfFrames[c['id']],(c['id'],css,candidate,pdfFrames.get(c['id']))
  records.append(dict(id=c['id'],snapshotIndex=index,bitmapSize=image.size,outputScale=scale,deviceScale=c['deviceScale'],dom=c['used'],paintPixels=pixels,paintCSS=css,pdfCSS=pdfFrames.get(c['id']),integerCSSEdges=candidate,deviceEdges=edges(c['used'],c['deviceScale']),outputPixelEdges=edges(c['used'],scale)))
paths=[HERE/'capture-image-snapshots.swift',Path(__file__).resolve(),OUT/'inputs.json',OUT/'capture',OUT/'web.json',OUT/'web.pdf',OUT/'snapshot-0.png',OUT/'snapshot-1.png']
report=dict(passed=True,canvasControls=len(web),snapshotComparisons=len(records),deviceScale=web[0]['deviceScale'],pixelBoundsTolerance=0,
 scope='Actual macOS WK, six unclipped axis-aligned opaque patterned20x20 canvases. Both snapshot output scales2 and4 and WKPDF match integer CSS edge rounding exactly. This is measured destination edge equality, not full sampled RGBA equality or proof arbitrary transforms/iOS behave identically.',
 requiredBeforeProduction='Actual iOS WK controls at native DPR, with the same authored DOM geometry. Existing strict saved export is not changed: frozen saves raw mask at DOM-used frame without live canvas snapping.',
 casesDetail=records,sourceSHA256={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths})
(OUT/'report.json').write_text(json.dumps(report,indent=2));print(json.dumps({k:report[k] for k in ['passed','canvasControls','snapshotComparisons','deviceScale','pixelBoundsTolerance','scope']},indent=2))
