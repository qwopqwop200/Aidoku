#!/usr/bin/env python3
"""Actual macOS WK frozen phase sampling versus production Swift on bounded real pixels.

The host CoreGraphics normalization is correlated to the iOS native sample;
platform-specific Canvas byte equality remains a separate iOS diagnostic.
"""
import argparse,hashlib,json,re,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
HERE=Path(__file__).resolve().parent
SRC=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay'
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--fixture',type=Path,default=ROOT/'build/native-render-parity/verify-image-build31-snapshot/real-comic-0015');p.add_argument('--output',type=Path,default=ROOT/'build/native-render-parity/real-source-sampling');a=p.parse_args();out=a.output.resolve();out.mkdir(parents=True,exist_ok=True);ref=ROOT/'Scripts/native-render-parity/reference-source';hashes={}
 for name,target in [('BrowserSourceTextColor.swift','source.js'),('BrowserSourceGlyphSegmentation.swift','geometry.js')]:
  raw=(ref/name).read_bytes();hashes[name]=hashlib.sha256(raw).hexdigest();s=re.search(r'static let script = """\n([\s\S]*?)\n    """',raw.decode())[1];(out/target).write_text(re.sub(r'^    ','',s,flags=re.M))
 sources=[]
 for name in ['NativeTranslationPixelKernels','NativeSourceColorSampler','NativeObservedSourcePalette','NativeCaptionSourcePalette','NativeSourceColorSamplingStage']:
  raw=(SRC/(name+'.swift')).read_bytes();hashes[name]=hashlib.sha256(raw).hexdigest();target=out/(name+'.swift');target.write_bytes(raw);sources.append(str(target))
 binary=out/'probe';subprocess.run(['swiftc','-O','-I',str(ROOT/'Scripts/overlay-kernels/native'),*sources,str(HERE/'Probe.swift'),str(ROOT/'build/native-overlay-kernels-host/libAidokuOverlayKernels.a'),'-o',str(binary)],check=True)
 capture=out/'prepared-captured.json';subprocess.run([str(binary),str(a.fixture.resolve()),str(capture)],check=True)
 d=json.loads(capture.read_text());rows=[{'id':n['id'],'paletteExact':n['result']==w['result'],'budgetExact':n['budget']==w['budget'],'statsExact':n['stats']==w['stats']} for n,w in zip(d['native'],d['web']['rows'])];actual=json.loads((a.fixture/'native-final-layout.json').read_text());n7=next(x['sourceSample'] for x in actual['cards'] if x['id']=='7');h7=next(x['result'] for x in d['native'] if x['id']=='7');web=json.loads((a.fixture/'web-final-layout.json').read_text());w7=next(x for x in web['layers'] if x.get('kind')=='item' and x.get('id')=='7')['dataset']['sourceSampledTextRGB']
 report={'scope':'Host CG normalized4MP original source → unchanged production full phase sampler versus live macOS WK frozen full sampler. UIKit normalization is independently correlated by matching entire actual iOS native id7 descriptor. This does not claim iOS Canvas pixel equality.','rows':rows,'exact':sum(all(x[k] for k in ['paletteExact','budgetExact','statsExact']) for x in rows),'cases':len(rows),'actualIOSNativeItem7FullDescriptorExact':h7==n7,'hostForegroundItem7':h7['foreground'],'actualIOSWebForegroundItem7':w7,'userAgent':d['web']['userAgent'],'sources':hashes}
 (out/'report.json').write_text(json.dumps(report,indent=2));print(json.dumps(report));return 0 if report['exact']==len(rows) and report['actualIOSNativeItem7FullDescriptorExact'] else 1
if __name__=='__main__':raise SystemExit(main())
