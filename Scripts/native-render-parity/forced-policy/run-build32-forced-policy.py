#!/usr/bin/env python3
"""Compare same captured iOS RGBA and full metadata; host-only trace insertions."""
from pathlib import Path
import subprocess,json,hashlib,re
ROOT=Path(__file__).resolve().parents[3];O=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay';OUT=ROOT/'build/native-render-parity/build32-forced-native';OUT.mkdir(parents=True,exist_ok=True)
src=O/'NativeRestorationPixels.swift';s=src.read_text()
core=s[:s.index('    /// Sample the original crop')]
def fn(text,name):
 start=text.index('    static func '+name+('' if '(' in name else '(')); b=text.index('{',start);i=b+1;depth=1
 while depth: depth+=(text[i]=='{')-(text[i]=='}');i+=1
 return text[start:i]
(OUT/'Core.swift').write_text(core+fn(s,'palette(_ sample')+'\n'+fn(s,'rgb')+'\n}\n')
h=(O/'NativeObservedRestorationHelpers.swift').read_text();(OUT/'ObservedDistance.swift').write_text('import Foundation\nenum NativeObservedRestorationHelpers {\n'+fn(h,'distance')+'\n}\n')
names=['NativeSourceGlyphSegmentation','NativeTranslationPixelKernels','NativeResidualProof','NativeResidualExemplar','NativeResidualTopology','NativeForcedComponentRestoration','NativeForcedSourceInpainting','NativeTypedArrayFill']
hashes={str(src.relative_to(ROOT)):hashlib.sha256(src.read_bytes()).hexdigest()};compiled=[]
for name in names:
 p=O/(name+'.swift');s=p.read_text();hashes[str(p.relative_to(ROOT))]=hashlib.sha256(p.read_bytes()).hexdigest()
 if name=='NativeForcedComponentRestoration':
  marker='        var options = Options();'
  assert marker in s;s=s.replace(marker,'        ForceTrace.bitmap("component-painted",painted); ForceTrace.bitmap("component-blocked",blocked); ForceTrace.bitmap("component-protected",protected)\n'+marker,1)
 if name=='NativeForcedSourceInpainting':
  marker='        var method = "forced-donor-front", quality:'
  assert marker in s;s=s.replace(marker,'        ForceTrace.bitmap("legacy-painted",painted); ForceTrace.bitmap("legacy-blocked",blocked); ForceTrace.bitmap("legacy-protected",protectedPixels)\n'+marker,1)
 if name=='NativeResidualProof':
  marker='        guard quality.safe else {'
  assert marker in s;s=s.replace(marker,'        ForceTrace.quality(quality)\n'+marker,1)
 copy=OUT/p.name;copy.write_text(s);compiled.append(copy)
main=Path(__file__).parent/'ForcePolicyMain.swift'
subprocess.run(['xcrun','swiftc','-O','-swift-version','6','-strict-concurrency=complete','-I',str(ROOT/'Scripts/overlay-kernels/native'),'-L',str(ROOT/'build/native-overlay-kernels-host'),'-lAidokuOverlayKernels',str(OUT/'Core.swift'),str(OUT/'ObservedDistance.swift'),*map(str,compiled),str(main),'-o',str(OUT/'native')],check=True,cwd=ROOT)
inputs=ROOT/'build/native-render-parity/build32-forced-policy-inputs';subprocess.run([str(OUT/'native'),str(OUT),str(inputs/'4.json'),str(inputs/'14.json')],check=True,cwd=ROOT)
ref=ROOT/'build/native-render-parity/build32-forced-policy-oracle';cases=[]
for id in ['4','14']:
 web=json.loads((ref/(id+'.json')).read_text());native=json.loads((OUT/(id+'.json')).read_text());masks=[]
 for kind in ['component-painted','component-blocked','component-protected','component-core','component-outline','legacy-painted','legacy-blocked','legacy-protected']:
  a=(ref/(id+'-'+kind+'.bin')).read_bytes();b=(OUT/(id+'-'+kind+'.bin')).read_bytes();masks.append(dict(kind=kind,bytes=len(a),exact=a==b,differingBytes=sum(x!=y for x,y in zip(a,b)),nativeSHA256=hashlib.sha256(b).hexdigest(),frozenSHA256=hashlib.sha256(a).hexdigest()))
 positive=json.loads((OUT/(id+'-without-offcrop-kept.json')).read_text())
 cases.append(dict(id=id,native=native,web=web,masks=masks,withoutOffcropKept=positive,passed=native['component'] is None and native['legacy'] is None and native['legacyFailure']==web['legacyFailure'] and all(x['exact'] for x in masks) and positive['component'] is not None))
report=dict(passed=all(c['passed'] for c in cases),scope='Captured actual iOS same RGBA + identical full native cached metadata + actual caller options. Native CPU25 bridge active. Trace insertions capture only, frozen criteria unchanged. Full mask/blocked/protected bytes compared. Current browser nested-cache equality not inferred; final PNG equality remains independent.',sourceSHA256=hashes,cases=cases)
frozen=ROOT/'Scripts/native-render-parity/reference-source'; report['frozenSourceSHA256']={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in frozen.glob('Browser*.swift')}; report['fullPolicyScope']='Complete forceComponent and legacy forceSource execution, actual CPU25 bridge and original rejection gates; trace captures only. Null terminal results match complete calls. Positive counterfactual acceptance method/count recorded; positive outputRGBA equality not inferred.'
(OUT/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(dict(passed=report['passed'],cases=[dict(id=c['id'],passed=c['passed'],masks=[dict(kind=m['kind'],exact=m['exact'],differingBytes=m['differingBytes']) for m in c['masks']]) for c in cases]),indent=2));raise SystemExit(not report['passed'])
