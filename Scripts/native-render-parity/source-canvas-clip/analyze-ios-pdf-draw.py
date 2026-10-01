#!/usr/bin/env python3
"""Factor actual iOS canvas PDF residuals using immutable captured PDF inputs."""
from pathlib import Path
import json,math,hashlib,subprocess,numpy as np
from pypdf import PdfReader,PdfWriter
from pypdf.generic import ContentStream,FloatObject,NameObject,BooleanObject
ROOT=Path(__file__).resolve().parents[3];BASE=ROOT/'build/native-render-parity/verify-source-canvas-build42-snapshot'
OUT=ROOT/'build/native-render-parity/source-canvas-clip/ios-pdf-factor';OUT.mkdir(exist_ok=True)
records=[]
def snap(v):return math.floor(v+0.5)
for scene,mode in [('original-six','pdf'),('negative-global','pdf'),('negative-global','pdf-negative-crop')]:
 directory=BASE/scene;dom=json.loads((directory/'web-dom-and-saved-masks.json').read_text())['records'];colors={tuple(c['color']):c for c in dom}
 meta=json.loads((directory/f'web-{mode}-capture.json').read_text());width,height=meta['rasterWidth'],meta['rasterHeight'];crop=meta['requestedRect']
 ox,oy=math.trunc(float(np.float32(crop[0]))),math.trunc(float(np.float32(crop[1])))
 reference=np.fromfile(directory/f'web-{mode}.rgba',np.uint8).reshape(height,width,4)
 for geometry,interpolation,white in [('raw',True,False),('snapped',True,False),('raw',False,False),('snapped',False,False),('snapped',False,True)]:
  pdf=PdfReader(directory/f'native-{mode}.pdf');page=pdf.pages[0];images=page['/Resources']['/XObject'];stream=ContentStream(page.get_contents(),pdf)
  lastcm=None
  for operands,operator in stream.operations:
   if operator==b'cm':lastcm=operands
   elif operator==b'Do':
    image=images[operands[0]].get_object();c=colors[tuple(image.get_data()[:3])]
    image[NameObject('/Interpolate')]=BooleanObject(interpolation)
    if geometry=='snapped':
     x,y,w,h=c['used'];l,t,r,b=snap(x),snap(y),snap(x+w),snap(y+h)
     lastcm[:]=list(map(FloatObject,[r-l,0,0,b-t,l-ox,float(page.mediabox.height)-(t-oy)-(b-t)]))
  if white:
   f=FloatObject;stream.operations=[([],b'q'),([f(1),f(1),f(1)],b'rg'),([f(0),f(0),f(page.mediabox.width),f(page.mediabox.height)],b're'),([],b'f'),([],b'Q')]+stream.operations
  page[NameObject('/Contents')]=stream
  writer=PdfWriter();writer.add_page(page)
  id=f'{scene}-{mode}-{geometry}-interpolate-{interpolation}-white-{white}';file=OUT/f'{id}.pdf'
  with file.open('wb') as fd:writer.write(fd)
  raw=OUT/f'{id}.rgba';subprocess.run([str(ROOT/'build/native-render-parity/source-canvas-clip/rasterize-pdf'),str(file),str(width),str(height),str(raw)],check=True)
  actual=np.fromfile(raw,np.uint8).reshape(height,width,4);diff=np.abs(actual.astype(np.int16)-reference.astype(np.int16));changed=np.any(diff,axis=2)
  records.append(dict(scene=scene,mode=mode,geometry=geometry,interpolate=interpolation,fullMediaWhiteBackground=white,changedPixels=int(changed.sum()),maxDelta=int(diff.max()),exact=not changed.any(),pdfSHA256=hashlib.sha256(file.read_bytes()).hexdigest()))
report=dict(scope='Controlled derivative nativePDF experiments only. Source20x20 RGB bytes are unchanged; general integerCSS edge formula applies DOMframes and integralcroptranslation. PDF /Interpolate=false default matchesWK. White media background tests fixturebaseline only. macOS CoreGraphics rasterizes actualiOS PDF inputs; iOS runtime production draw is a separate required gate. Saved rawDOM mask composition remains unchanged.',experiments=records)
(OUT/'report.json').write_text(json.dumps(report,indent=2));print(json.dumps(records,indent=2))
