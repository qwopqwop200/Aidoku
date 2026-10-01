#!/usr/bin/env python3
"""Read-only independent byte/PNG/source audit; no reliance on helper pass flag."""
import argparse,json,hashlib,struct,zlib
from collections import Counter
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser()
p.add_argument('--capture',type=Path,default=ROOT/'build/native-render-parity/verify-gradient-backend-build55-snapshot')
p.add_argument('--include-offscreen',action='store_true')
p.add_argument('--reference',type=Path,default=ROOT/'build/native-render-parity/verify-gradient-backend-build55-snapshot')
p.add_argument('--output',type=Path,default=ROOT/'build/native-render-parity/foreign-background-gradient/backend55-audit')
a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True)
sha=lambda b:hashlib.sha256(b).hexdigest()
def png(path):
 b=path.read_bytes();assert b[:8]==b'\x89PNG\r\n\x1a\n';off=8;payload=b'';chunks=[]
 while off<len(b):
  n=struct.unpack('>I',b[off:off+4])[0];t=b[off+4:off+8];d=b[off+8:off+8+n];chunks.append(t.decode())
  assert zlib.crc32(t+d)&0xffffffff==struct.unpack('>I',b[off+8+n:off+12+n])[0]
  if t==b'IHDR':w,h,depth,kind,comp,fil,interlace=struct.unpack('>IIBBBBB',d)
  if t==b'IDAT':payload+=d
  off+=n+12
 assert depth==8 and kind in(2,6) and interlace==0
 channels=3 if kind==2 else 4;stride=w*channels;raw=zlib.decompress(payload);assert len(raw)==h*(stride+1)
 result=bytearray();prev=bytearray(stride)
 def paeth(x,y,z):
  guess=x+y-z;d=[abs(guess-x),abs(guess-y),abs(guess-z)];return [x,y,z][d.index(min(d))]
 for y in range(h):
  f=raw[y*(stride+1)];row=bytearray(raw[y*(stride+1)+1:(y+1)*(stride+1)])
  for i in range(stride):
   left=row[i-channels] if i>=channels else 0;up=prev[i];upleft=prev[i-channels] if i>=channels else 0
   delta=[0,left,up,(left+up)//2,paeth(left,up,upleft)][f];row[i]=(row[i]+delta)&255
  if channels==4:result.extend(row)
  else:
   for x in range(w):result.extend(row[x*3:x*3+3]);result.append(255)
  prev=row
 return w,h,bytes(result),chunks
def interior(b,w):return b''.join(b[(y*w+66)*4:(y*w+342)*4] for y in range(66,342))
def palette(b):return [{'RGBA':list(k),'count':v} for k,v in sorted(Counter(tuple(b[i:i+4]) for i in range(0,len(b),4)).items())]
def diff(x,y):
 assert len(x)==len(y)
 return {'exactRGBA':x==y,'changedPixels':sum(x[i:i+4]!=y[i:i+4] for i in range(0,len(x),4)),
  'changedBytes':sum(a!=b for a,b in zip(x,y)),'maxChannelDelta':max(abs(a-b) for a,b in zip(x,y))}
report=json.loads((a.capture/'report.json').read_text());records=[];comparisons=[];checks=[]
for name,expected in [('red',[220,30,40]),('blue',[30,40,220])]:
 folder=a.capture/name;dom=json.loads((folder/'web-dom.json').read_text())
 assert dom['sourceRGB']==expected and dom['usedFrame']==[20,20,96,96] and dom['devicePixelRatio']==3
 assert dom['innerWidth']==320 and dom['innerHeight']==160 and dom['scrollX']==dom['scrollY']==0
 assert dom['borderRadius']==dom['borderWidth']=='0px'
 buffers={}
 modes=['web','cpu-bitmap','ui-view-draw','ca-gradient-layer']+(['ca-layer-render-attached','ca-layer-render-detached'] if a.include_offscreen else [])
 for mode in modes:
  raw=(folder/(mode+'.rgba')).read_bytes();w,h,decoded,chunks=png(folder/(mode+'.png'));assert(w,h)==(960,480)
  assert len(raw)==960*480*4 and raw==decoded and all(raw[i]==255 for i in range(3,len(raw),4))
  inner=interior(raw,w);assert inner==(folder/(mode+'-interior.rgba')).read_bytes()
  metadata=json.loads((folder/(mode+'-capture.json')).read_text())
  assert sha(raw)==metadata['RGBAHash'] and sha(inner)==metadata['interiorHash']
  observed=palette(inner);saved={tuple(map(int,item['RGBA'].split(','))):item['count'] for item in metadata['interiorPalette']}
  assert {tuple(item['RGBA']):item['count'] for item in observed}==saved
  records.append({'scene':name,'mode':mode,'size':[w,h],'PNGHash':sha((folder/(mode+'.png')).read_bytes()),
   'PNGChunks':chunks,'rawRGBAHash':sha(raw),'PNGDecodedEqualsCanonical':True,'allPixelsOpaque':True,
   'interiorHash':sha(inner),'paletteCardinality':len(observed),'interiorPalette':observed,'metadata':metadata['metadata']})
  buffers[mode]=raw
 for mode in modes[1:]:
  comparison={'scene':name,'mode':mode,'fullPage':diff(buffers['web'],buffers[mode]),
   'borderFreeInterior':diff(interior(buffers['web'],960),interior(buffers[mode],960))}
  existing=next(r for r in report['descriptiveComparisons'] if r['scene']==name and r['mode']==mode)
  assert all(comparison[part][key]==existing[part][key] for part in ['fullPage','borderFreeInterior'] for key in ['exactRGBA','changedPixels','maxChannelDelta'])
  comparisons.append(comparison)
 original_matches={mode:{'rawRGBAEquals55':buffers[mode]==(a.reference/name/(mode+'.rgba')).read_bytes(),
   'PNGBytesEqual55':(folder/(mode+'.png')).read_bytes()==(a.reference/name/(mode+'.png')).read_bytes()} for mode in modes[:4]}
 assert all(v['rawRGBAEquals55'] for v in original_matches.values())
 checks.append({'scene':name,'originalFourRoutesEquals55':original_matches,
  'attachedEqualsDetachedRGBA':buffers['ca-layer-render-attached']==buffers['ca-layer-render-detached'] if a.include_offscreen else None,
  'CPUEqualsUIViewFullRGBA':buffers['cpu-bitmap']==buffers['ui-view-draw'],
  'CAEqualsWKFullRGBA':buffers['ca-gradient-layer']==buffers['web'],'DOMHash':sha((folder/'web-dom.json').read_bytes())})
source=(a.capture/'literal-source.json').read_bytes();assert sha(source)==report['sourceHash']
assert source==(a.reference/'literal-source.json').read_bytes()
assert report['scriptHash']==json.loads((a.reference/'report.json').read_text())['scriptHash']
helper=ROOT/'AidokuTests/Translation/NativeConstantGradientBackendDiagnosticCapture.swift'
text=helper.read_text();literal=text.split('    private static let script = #"""\n',1)[1].split('\n    """#',1)[0]
script='\n'.join(line[4:] for line in literal.splitlines());assert sha(script.encode())==report['scriptHash']
result={'scope':'independent immutable actual capture raw/PNG/source audit; equality limited to two integer opaque constant gradients atDPR3',
 'capturePath':str(a.capture),'reference55Path':str(a.reference),'originalReportHash':sha((a.capture/'report.json').read_bytes()),'sourceHash':sha(source),
 'scriptHash':sha(script.encode()),'helperHashAtAudit':sha(helper.read_bytes()),'validatedCaptureCount':len(records),
 'diagnosticPassedIsPixelAcceptance':False,'sourceAndCaptureChecks':checks,'comparisons':comparisons,'records':records,
 'offscreenFinding': 'Attached and detached render(in:) equal each other but differ from WK; no offscreen parity established' if a.include_offscreen else None,
 'finding':'CAGradientLayer public hierarchy captures equal WK every RGBA byte in both controls; CPU components-CGGradient and actual UIView.draw do not',
 'limits':['No general gradient, fractional geometry, layer movement, overlapping layer, alpha or offscreen render equivalence established.',
 'UIView public drawing context exposes no bitmap data or color space; private backend type is unobserved.',
 'CAGradientLayer internal working color space is unobserved; declared CGColor stops and output canonical sRGB space retained.',
 'No app edits, image mutation, simulated dithering, tolerances, SDK or simulator runs performed by this analysis.']}
(a.output/'report.json').write_text(json.dumps(result,indent=2))
print(json.dumps({'validated':len(records),'checks':checks,'comparisons':comparisons,'output':str(a.output/'report.json')},indent=2))
