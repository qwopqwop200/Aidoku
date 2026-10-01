#!/usr/bin/env python3
"""Actual macOS WK + CoreText controls; no app or simulator writes."""
import hashlib,json,pathlib,re,subprocess,zlib
HERE=pathlib.Path(__file__).resolve().parent;ROOT=HERE.parents[2]
OUT=ROOT/'build/native-render-parity/fractional-font-precision';OUT.mkdir(parents=True,exist_ok=True)
for source,name in [('capture.swift','capture'),('Probe.swift','metrics-probe'),('PDFProbe.swift','pdf-probe')]:
 subprocess.run(['xcrun','swiftc',str(HERE/source),'-o',str(OUT/name)],check=True)
subprocess.run([str(OUT/'capture'),str(OUT)],check=True)
(OUT/'coretext.json').write_bytes(subprocess.check_output([str(OUT/'metrics-probe'),str(OUT/'capture.json')]))
subprocess.run([str(OUT/'pdf-probe'),str(OUT/'capture.json'),str(OUT)],check=True)
def streams(path):
 for match in re.finditer(rb'\bstream\r?\n(.*?)\r?\nendstream',path.read_bytes(),re.S):
  raw=match.group(1)
  try:raw=zlib.decompress(raw)
  except zlib.error:pass
  yield raw
def scales(path):
 out=[]
 for raw in streams(path):
  if b'Tf' not in raw:continue
  text=raw.decode('latin1')
  out += [float(a) for a,b in re.findall(r'([-\d.]+)\s+0\s+0\s+([-\d.]+)\s+[-\d.]+\s+[-\d.]+\s+Tm',text)]
 return out
capture=json.loads((OUT/'capture.json').read_text());cases=capture['cases'];metrics=json.loads((OUT/'coretext.json').read_text())
pdfs={name:scales(OUT/name) for name in ['web-controls.pdf','double-controls.pdf','float32-controls.pdf']}
base=ROOT/'build/native-render-parity/verify-image-build40-snapshot/real-comic-0001'
fontFiles={name:[dict(length=len(raw),sha256=hashlib.sha256(raw).hexdigest()) for raw in streams(base/name) if b'AppleSDGothicNeo-Bold' in raw and b'Tf' not in raw] for name in ['native-typography.pdf','web-typography.pdf']}
web=json.loads((base/'web-final-layout.json').read_text())['layers'];native=json.loads((base/'native-final-layout.json').read_text())['cards'];positions=[]
for a in native:
 if a['id'] not in ['2','3','4','7']:continue
 b=next(x for x in web if x['id']==a['id'] and x['kind']=='item')
 deltas=[max(abs(x[0]-y['x']),abs(x[1]-y['y']),abs(x[2]-y['width']),abs(x[3]-y['height'])) for x,y in zip(a['lineRects'],b['lineRects'])]
 positions.append(dict(id=a['id'],nativeFont=a['fontSize'],webComputed=b['style']['fontSize'],webInline=b['inline']['fontSize'],maximumRangeDifference=max(deltas)))
report=dict(cases=len(cases),WKRequestedVersusFloat32WidthMatches=sum(a['metrics']['original']['width']==a['metrics']['float32']['width'] for a in cases),doublePDFScaleMatches=sum(a==b for a,b in zip(pdfs['web-controls.pdf'],pdfs['double-controls.pdf'])),float32PDFScaleMatches=sum(a==b for a,b in zip(pdfs['web-controls.pdf'],pdfs['float32-controls.pdf'])),pdfScales=pdfs,actual40EmbeddedFonts=fontFiles,actual40RangePositions=positions,actual40PDFScales={name:scales(base/name) for name in ['native-typography.pdf','web-typography.pdf']},OS=capture['OS'],sourceCommit='dd5fe1011df7e3438ac4889356abcab7681df46d',sourceSHA256={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [HERE/'capture.swift',HERE/'Probe.swift',HERE/'PDFProbe.swift',*sorted(OUT.glob('Font*.h')),*sorted(OUT.glob('Font*.cpp'))]},scope='Font size is Float32 in primary WebKit; actual PDF scales and requested-vs-float32 Canvas invariance are bounded transport proof. CSSOM serialization alone is not evidence. CoreText double/Float glyph-width accumulation remains slightly different from WK; no glyph-position/raster or global Unicode font equivalence claim. Serif size-adjust order is not covered. No production edits. PNG background differences are independent.')
(OUT/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
print(json.dumps({k:report[k] for k in ['cases','WKRequestedVersusFloat32WidthMatches','doublePDFScaleMatches','float32PDFScaleMatches']}))
