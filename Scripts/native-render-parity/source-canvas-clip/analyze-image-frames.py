#!/usr/bin/env python3
"""Audit actual WKPDF image transforms separately from clip basic shapes."""
from pathlib import Path
from pypdf import PdfReader
from pypdf.generic import ContentStream
import json,math,hashlib
ROOT=Path(__file__).resolve().parents[3];OUT=ROOT/'build/native-render-parity/source-canvas-clip'
web=json.loads((OUT/'web.json').read_text());by_color={tuple(c['color']):c for c in web}
pdf=PdfReader(OUT/'web.pdf');page=pdf.pages[0];height=float(page.mediabox.height)
images=page['/Resources']['/XObject'];matrix=(1,0,0,1,0,0);stack=[];ops=[];observed={}
def multiply(l,r):
 a,b,c,d,e,f=l;g,h,i,j,k,m=r
 return (a*g+c*h,b*g+d*h,a*i+c*j,b*i+d*j,a*k+c*m+e,b*k+d*m+f)
def point(m,x,y):
 a,b,c,d,e,f=m
 return (a*x+c*y+e,b*x+d*y+f)
for operands,operator in ContentStream(page.get_contents(),pdf).operations:
 if operator==b'q':stack.append((matrix,ops.copy()))
 elif operator==b'Q':matrix,ops=stack.pop()
 elif operator==b'cm':
  values=tuple(float(v) for v in operands);matrix=multiply(matrix,values);ops.append(values)
 elif operator==b'Do':
  obj=images[operands[0]].get_object();c=by_color[tuple(obj.get_data()[:3])]
  corners=[point(matrix,x,y) for x,y in [(0,0),(1,0),(0,1),(1,1)]]
  x=min(p[0] for p in corners);right=max(p[0] for p in corners)
  y=height-max(p[1] for p in corners);bottom=height-min(p[1] for p in corners)
  observed[c['id']]=dict(imageName=str(operands[0]),cm=ops.copy(),combinedCTM=matrix,pdfHTMLFrame=[x,y,right-x,bottom-y],sourcePixelDimensions=[int(obj['/Width']),int(obj['/Height'])])
def nearest(v,scale):return math.floor(v*scale+0.5)/scale
def edge(box,scale):
 x,y,w,h=box;l=nearest(x,scale);t=nearest(y,scale);r=nearest(x+w,scale);b=nearest(y+h,scale)
 return [l,t,r-l,b-t]
def independent(box,scale):return [nearest(v,scale) for v in box]
records=[];errors={k:0 for k in ['nearestEdgesScale1','independentScale1','nearestEdgesDeviceScale','independentDeviceScale']}
for c in web:
 x,y,w,h=c['used'];box=[x+c['parent'][0],y+c['parent'][1],w,h]
 candidates=dict(nearestEdgesScale1=edge(box,1),independentScale1=independent(box,1),nearestEdgesDeviceScale=edge(box,c['deviceScale']),independentDeviceScale=independent(box,c['deviceScale']))
 actual=observed.get(c['id']);record=dict(id=c['id'],savedDOMFrame=box,candidates=candidates,actualImage=actual)
 if actual:
  diffs={k:max(abs(a-b) for a,b in zip(actual['pdfHTMLFrame'],v)) for k,v in candidates.items()}
  record['maximumCoordinateErrors']=diffs
  for k,v in diffs.items():errors[k]=max(errors[k],v)
 else:record['omittedImage']='Zero device-rounded draw width; no Do operator observed.'
 records.append(record)
report=dict(cases=len(records),imageOperations=len(observed),candidateMaximumErrors=errors,
 provenScope='Existing axis-aligned untransformed 20x20 opaque canvas controls, actual macOS WKPDF export at captured DPR2. Eleven image Do frames match nearest integer CSS edge rounding; the twelfth has zero rounded width and is omitted. This describes PDF operations only, not a general live-screen or arbitrary transform policy.',
 unresolved=['Whether actual on-screen WK rendering uses backing-device scale for image destination rounding.','Whether PDF rounding follows the actual graphics-context scale rather than DPR.','Alpha/patterned image resampling and rotated/nonuniform transforms are not exercised.','Negative global positions and offscreen page clipping are not exercised; existing negative cases are child-relative within positive page bounds.'],
 nextControl='Capture un-clipped axis canvases with patterned RGBA using WK snapshot at output widths640 and1280, record output pixel dimensions and actual DPR. Compare painted edge boundaries with scale1 vsdevice2 edge candidates. Preserve saved-export DOMframe and clip-reference independently.',
 casesDetail=records,inputSHA256={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [OUT/'web.json',OUT/'web.pdf',Path(__file__).resolve()]})
(OUT/'image-frame-analysis.json').write_text(json.dumps(report,indent=2));print(json.dumps({k:report[k] for k in ['cases','imageOperations','candidateMaximumErrors','provenScope']},indent=2))
