#!/usr/bin/env python3
"""Independently decode immutable repeat captures; no oracle selection or edits."""
from pathlib import Path
import argparse,hashlib,json,itertools
import numpy as np
from PIL import Image
ROOT=Path(__file__).resolve().parents[3]
parser=argparse.ArgumentParser()
parser.add_argument('--snapshot',type=Path,default=ROOT/'build/native-render-parity/verify-canvas-rotation-repeat-build57-snapshot')
parser.add_argument('--output',type=Path,default=ROOT/'build/native-render-parity/source-canvas-clip/rotation-repeat57-audit')
args=parser.parse_args();snapshot=args.snapshot.resolve();out=args.output.resolve();out.mkdir(parents=True,exist_ok=True)
sha=lambda b:hashlib.sha256(b).hexdigest()
recipe=bytes(c for y in range(20) for x in range(20) for c in (23+x*9,17+y*10,201,255))
assert sha(recipe)=='ba555c281c4574a1edf76efe4ea1d60ecf485586f1474eed5bf4a778eb913e33'
assert (snapshot/'immutable-source-recipe.rgba').read_bytes()==recipe
runtime=json.loads((snapshot/'report.json').read_text());assert runtime['count']==runtime['expectedCount']==12
observations={};controls=[];doms=[];manifest={};decoded=[]
for view in range(3):
 directory=snapshot/f'fresh-view-{view}'
 domFile=directory/'web-dom-and-saved-masks.json';doms.append(domFile.read_bytes());manifest[str(domFile.relative_to(snapshot))]=sha(domFile.read_bytes())
 dom=json.loads(domFile.read_text());assert dom['matrix']==runtime['matrix']
 for sourceID in ['positive','negative']:
  png=directory/f'source-{sourceID}.png';raw=directory/f'source-{sourceID}.rgba'
  rgba=Image.open(png).convert('RGBA').tobytes();assert rgba==raw.read_bytes()==recipe
  controls.append({'view':view,'sourceID':sourceID,'PNGDecodeExactlyEqualsCanonicalRecipe':True,'RGBAHash':sha(rgba),'PNGHash':sha(png.read_bytes())})
  for p in [png,raw]:manifest[str(p.relative_to(snapshot))]=sha(p.read_bytes())
 for round in range(2):
  for width in [160,320]:
   id=f'view-{view}-round-{round}-width-{width}';png=directory/(id+'.png');raw=directory/(id+'.rgba');metadata=directory/(id+'.json')
   image=Image.open(png).convert('RGBA');bytes=image.tobytes();assert bytes==raw.read_bytes()
   info=json.loads(metadata.read_text());assert sha(bytes)==info['RGBAHash'];assert sha(png.read_bytes())==info['PNGHash']
   expected=(width*3,width*3//2);assert image.size==expected and info['dimensionsValid']
   pixels=np.frombuffer(bytes,np.uint8).reshape(expected[1],expected[0],4);assert np.all(pixels[:,:,3]==255)
   observations[(view,round,width)]={'id':id,'pixels':pixels,'hash':sha(bytes)}
   decoded.append({'id':id,'dimensions':list(image.size),'PNGDecodeExactlyEqualsSavedRGBA':True,'RGBAHash':sha(bytes),'PNGHash':sha(png.read_bytes()),'CGImage':info['CGImage'],'viewport':info['viewport']})
   for p in [png,raw,metadata]:manifest[str(p.relative_to(snapshot))]=sha(p.read_bytes())
assert doms[0]==doms[1]==doms[2]
def comparison(a,b):
 x=a['pixels'];y=b['pixels'];delta=np.abs(x.astype(np.int16)-y.astype(np.int16));mask=np.any(delta!=0,axis=2)
 return {'referenceID':a['id'],'comparedID':b['id'],'exactRGBA':not mask.any(),'changedPixels':int(mask.sum()),'maxChannelDelta':int(delta.max()),'referenceRGBAHash':a['hash'],'comparedRGBAHash':b['hash'],'changedPoints':[{'xy':[int(px),int(py)],'reference':x[py,px].tolist(),'compared':y[py,px].tolist()} for py,px in np.argwhere(mask)]}
pairwise=[]
for width in [160,320]:
 for (ka,a),(kb,b) in itertools.combinations([(k,v) for k,v in observations.items() if k[2]==width],2):
  c=comparison(a,b);c['sameView']=ka[0]==kb[0];c['requestedWidth']=width;pairwise.append(c)
reported={(c['referenceID'],c['comparedID']):c for c in runtime['descriptivePairwiseComparisons']}
for c in pairwise:
 r=reported[(c['referenceID'],c['comparedID'])]
 for name in ['exactRGBA','changedPixels','maxChannelDelta','referenceRGBAHash','comparedRGBAHash']:assert c[name]==r[name],(name,c,r)
actual56=ROOT/'build/native-render-parity/verify-source-canvas-transform-build56-snapshot/rotation'
againstNative=[]
for (view,round,width),observation in observations.items():
 nativeBytes=(actual56/f'native-live-{width}.rgba').read_bytes();assert len(nativeBytes)==observation['pixels'].size
 native={'id':f'actual56-native-{width}','hash':sha(nativeBytes),'pixels':np.frombuffer(nativeBytes,np.uint8).reshape(observation['pixels'].shape)}
 c=comparison(observation,native);c['view']=view;c['round']=round;c['requestedWidth']=width;againstNative.append(c)
 for prefix in ['web','native']:
  file=actual56/f'{prefix}-live-{width}.rgba';manifest[str(file.relative_to(ROOT))]=sha(file.read_bytes())
helper=ROOT/'AidokuTests/Translation/NativeSourceCanvasRotationRepeatDiagnosticCapture.swift'
helperSHA=sha(helper.read_bytes()) if helper.exists() else None
assert helperSHA=='19e8b091f73c80f078bffbabe9f448fc9d97fca3ee3a5508d0811d1868f9323f'
report={'auditPassed':True,'pixelParityClaimed':False,'scope':'Immutable actual iOS57 three fresh WKViews, two160→320 pairs each; independent PNG decoding/source/metadata/pairwise recomputation. No reference selection, shader changes or broader randomness claim.',
 'observedCaptures':12,'decodedSourceControls':6,'allPNGDecodedRGBAExactlyEqualsSaved':True,'allSourceRGBAExactlyEqualsRecipe':True,'allFreshViewDOMFilesByteEqual':True,'sameViewAllSixPairwiseComparisonsExact':all(c['exactRGBA'] for c in pairwise if c['sameView']),
 'freshViewCrossComparisonVariabilityObserved':any(not c['exactRGBA'] for c in pairwise if not c['sameView']),
 'interpretation':'In this12-observation batch, repeats within each fixed view are stable; views0/1 are identical, view2 differs from them by1pixel at half capture and2pixels at full capture, max1. This establishes bounded cross-view output nonrepeatability with the declared controls equal. It does not establish global randomness or identify backend/rounding cause.',
 'limitations':['No WK process/backend/pipeline identity or private framebuffer state was captured.','Actual56 native is an immutable comparison, not a fresh iOS57 native rendering.','All strict transform references remain unchanged; none of the12 observations is selected as a favorable oracle.'],
 'sourceControls':controls,'captureDecodes':decoded,'pairwise':pairwise,'actual56NativeComparisons':againstNative,'promotedHelperSHA256':helperSHA,'artifactSHA256':manifest}
(out/'report.json').write_text(json.dumps(report,indent=2));print(json.dumps({k:report[k] for k in ['auditPassed','sameViewAllSixPairwiseComparisonsExact','freshViewCrossComparisonVariabilityObserved','interpretation']},indent=2))
