#!/usr/bin/env python3
"""Export observed OCR/color crops for offline production-JS evidence replay.
Needs Pillow; image bytes stay under the chosen ignored output folder.
No OCR, translation service, credentials, or source-text copies are needed.
"""
import argparse,base64,json,math,subprocess,zlib
from pathlib import Path
from PIL import Image
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--run',required=True,type=Path)
p.add_argument('--output',required=True,type=Path)
p.add_argument('--baseline',type=Path)
a=p.parse_args();a.run=a.run.resolve();a.output=a.output.resolve();a.output.mkdir(parents=True,exist_ok=True)
fixture=a.output/'crops.jsonl';pages=[];regions=slanted=0
with fixture.open('w') as out:
 for d in sorted(a.run.iterdir()):
  if not d.name.isdigit():continue
  def stage(s):
   f=next(d.glob('*-'+s+'.json'),None)
   return json.loads(f.read_text())['value'] if f else None
  v=json.loads((d/'final.json').read_text());W,H=v['width'],v['height']
  image=Image.open(d/'input.png').convert('RGBA')
  items=(stage('render-payload') or {}).get('items',[])
  for item in items:
   b=item.get('sourceBounds');poly=item.get('sourcePolygon',[])
   if not b or len(poly)<3:continue
   sw,sh=b[2]*W,b[3]*H
   if min(sw,sh)<8:continue
   margin=max(4,min(16,math.ceil(min(sw,sh)*.5)))
   x=max(0,math.floor(b[0]*W)-margin);y=max(0,math.floor(b[1]*H)-margin)
   right=min(W,math.ceil((b[0]+b[2])*W)+margin);bottom=min(H,math.ceil((b[1]+b[3])*H)+margin)
   cw,ch=right-x,bottom-y;scale=min(1,math.sqrt(24576/(cw*ch)))
   w=max(1,math.floor(cw*scale));h=max(1,math.floor(ch*scale))
   if min(w,h)<8:continue
   def local(p):return [[(v[0]*W-x)*w/cw,(v[1]*H-y)*h/ch] for v in p]
   polygons=[local(poly)]
   excluded=[local(i['sourcePolygon']) for i in items if i is not item and len(i.get('sourcePolygon',[]))>=3]
   rgba=image.crop((x,y,right,bottom)).resize((w,h),Image.Resampling.BILINEAR).tobytes()
   area=abs(sum(poly[i][0]*poly[(i+1)%len(poly)][1]-poly[(i+1)%len(poly)][0]*poly[i][1] for i in range(len(poly))))/2
   ratio=area/(b[2]*b[3]);regions+=1;slanted+=ratio<.85
   out.write(json.dumps({'page':Path(v['input']).name,'id':item['id'],'w':w,'h':h,'polygons':polygons,'excluded':excluded,
     'quadBoxAreaRatio':ratio,'rgba':base64.b64encode(zlib.compress(rgba)).decode()})+'\n')
  maps=stage('detector-probability-map')
  if maps:pages.append({'page':Path(v['input']).name,'width':maps['width'],'height':maps['height'],
    'raw':str((d/maps['raw']).resolve()),'threshold':(stage('input') or {}).get('configuration',{}).get('detectorPixelThreshold',.3),
    'detectorComponents':(stage('native-ocr') or {}).get('diagnostics',{}).get('detection',{}).get('candidateComponents')})
(a.output/'maps.json').write_text(json.dumps(pages))
cmd=['node',str(ROOT/'Scripts/tests/output-hard-evidence-replay.cjs'),str(fixture),str(a.output)]
if a.baseline:cmd.append(str(a.baseline.resolve()))
subprocess.run(cmd,cwd=ROOT,check=True)
print(json.dumps({'pages':len(pages),'colorCrops':regions,'quadBoxAreaBelow85Percent':slanted,'report':str(a.output/'evidence-summary.json')}))
