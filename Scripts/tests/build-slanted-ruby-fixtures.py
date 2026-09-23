"""Build frozen rotated ruby masks from the existing real captures and known-background controls.

Run with the Pillow runtime. Optional --preview-dir saves representative inputs.
The manually reviewed body rectangles exclude balloon outlines inside loose OCR boxes.
"""
from pathlib import Path
import json,zlib,base64,math,hashlib
from PIL import Image,ImageDraw
import argparse
parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--preview-dir',type=Path);args=parser.parse_args()
root=args.preview_dir;fixtures=Path(__file__).resolve().parent/'fixtures'
if root:root.mkdir(parents=True,exist_ok=True)
load=lambda n:json.loads((fixtures/n).read_text())
unpack=lambda s:zlib.decompress(base64.b64decode(s))
pack=lambda b:base64.b64encode(zlib.compress(b,9)).decode()
sources=[]
for f in load('source-inpainting-captured-ruby.json'):
 sources.append(dict(f,infer=False))
for f in load('source-inpainting-inferred-ruby.json'):
 if f['name'] in ['diverse-1178-missing-furo-1','expanded-comic-1424-ellipsis']:
  sources.append(dict(f,auxiliary=[f['ruby']],infer=True,vertical=True))
for f in load('source-inpainting-ruby.json')['cases']:
 sources.append(dict(f,infer=False,synthetic=True))
rows=[];preview=[]
for index,f in enumerate(sources):
 im=Image.frombytes('RGBA',(f['w'],f['h']),unpack(f['rgba'])); sc=.75 if f['h']>450 else 1
 if sc<1:im=im.resize((round(im.width*sc),round(im.height*sc)),Image.Resampling.LANCZOS)
 sx=im.width/f['w'];sy=im.height/f['h'];b=[f['b'][0]*sx,f['b'][1]*sy,f['b'][2]*sx,f['b'][3]*sy]
 aux=[[r[0]*sx,r[1]*sy,r[2]*sx,r[3]*sy] for r in f['auxiliary']]
 reviewed={'comic-3397':[[24,34,102,151]],'diverse-1178':[[38,38,86,466]],'diverse-1178-missing-furo-1':[[38,38,86,466]],'comic-0474':[[26,96,99,217],[144,28,72,217],[237,44,59,82]]}
 body=[[r[0]*sx,r[1]*sy,r[2]*sx,r[3]*sy] for r in reviewed.get(f['name'],[f['b']])]
 fg=f['palette']['foreground'];bg=f['palette']['background'];positive=max(bg)>max(fg)
 ink=Image.new('L',im.size);ruby=Image.new('L',im.size);protect=Image.new('L',im.size)
 for y in range(im.height):
  for x in range(im.width):
   rgb=im.getpixel((x,y))[:3]
   inside=lambda r,p=0:x>=r[0]-p and y>=r[1]-p and x<r[0]+r[2]+p and y<r[1]+r[3]+p
   # Independent observed ink cores; the grayscale/rgb ramp remains covered
   # by known-clean synthetic backgrounds and explicit visual comparisons.
   isink=(f.get('synthetic',False) or max(abs(rgb[k]-fg[k]) for k in range(3))<70) and max(abs(rgb[k]-bg[k]) for k in range(3))>24
   if isink and (any(inside(r) for r in body+aux)):ink.putpixel((x,y),255)
   if isink and any(inside(r) for r in aux):ruby.putpixel((x,y),255)
   if not any(inside(r,8) for r in body+aux):protect.putpixel((x,y),255)
 for a in [-78,-55,-45,-25,-8,8,25,45,55,78]:
  angle=math.radians(a);c=math.cos(angle);s=math.sin(angle)
  out=im.rotate(-a,Image.Resampling.BICUBIC,expand=True,fillcolor=(*bg,255))
  def point(x,y):return [(x-im.width/2)*c-(y-im.height/2)*s+out.width/2,(x-im.width/2)*s+(y-im.height/2)*c+out.height/2]
  def polygon(r):return [point(r[0],r[1]),point(r[0]+r[2],r[1]),point(r[0]+r[2],r[1]+r[3]),point(r[0],r[1]+r[3])]
  def rect(r):
   p=polygon(r);xs=[q[0] for q in p];ys=[q[1] for q in p];return [min(xs),min(ys),max(xs)-min(xs),max(ys)-min(ys)]
  center=point(b[0]+b[2]/2,b[1]+b[3]/2)
  masks=[m.rotate(-a,Image.Resampling.NEAREST,expand=True) for m in [ink,ruby,protect]]
  row=dict(id=f"ruby-{index:02d}-{a:+d}",sourceName=f['name'],synthetic=f.get('synthetic',False),infer=f['infer'],w=out.width,h=out.height,box=[center[0]-b[2]/2,center[1]-b[3]/2,b[2],b[3]],angle=angle,polygon=polygon(b),auxiliary=[] if f['infer'] else [rect(r) for r in aux],auxiliaryPolygons=[] if f['infer'] else [polygon(r) for r in aux],referenceRuby=[rect(r) for r in aux],vertical=f.get('vertical',False),palette=f['palette'],rgba=pack(out.tobytes()),ink=pack(masks[0].tobytes()),ruby=pack(masks[1].tobytes()),protected=pack(masks[2].tobytes()),provenance=dict(f.get('provenance',{}),fixture=f['name'],bodyRegions=body,inputSHA256=hashlib.sha256(unpack(f['rgba'])).hexdigest(),scale=sc,rotationDegrees=a))
  rows.append(row)
  if root and a in [-55,25] and index<8:
   out.convert('RGB').save(root/(row['id']+'-source.png'))
(fixtures/'slanted-ruby-pixels.json').write_text(json.dumps({'provenance':'Frozen real ruby crops and known-background controls; rotations are explicit pixel augmentations. Core masks and outside-region preservation masks are independent of restoration.', 'cases':rows},ensure_ascii=False))
print(len(rows),'cases',len(sources),'sources',sum(not r['synthetic'] for r in rows),'real rotations')
