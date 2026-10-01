#!/usr/bin/env python3
"""Exact full-RGBA dark export probe; preserves actual captured text/font bytes.

Regenerates only settled vector background geometry with production capture,
then replays those vectors in the actual same-capture native PDF. This isolates
PDF scale serialization from the UIKit runtime and font-policy work in flight.
"""
import hashlib,json,pathlib,subprocess
ROOT=pathlib.Path(__file__).resolve().parents[3]
HERE=pathlib.Path(__file__).resolve().parent
OUT=ROOT/'build/native-render-parity/dark-export-alpha';OUT.mkdir(parents=True,exist_ok=True)
FIXTURE=ROOT/'build/native-render-parity/verify-image-build29-snapshot/dark-translucent'
def run(args):return subprocess.run([str(x) for x in args],cwd=ROOT,check=True,capture_output=True,text=True).stdout
(OUT/'main.swift').write_text((HERE/'GeometryProbe.swift').read_text())
run(['swiftc',ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeTranslationPDFCapture.swift',OUT/'main.swift','-o',OUT/'geometry'])
run([OUT/'geometry'])
run(['python3',HERE/'patch-pdf.py',FIXTURE,OUT])
run(['swiftc',HERE/'pdf-probe.swift','-o',OUT/'raster'])
for name,pdf in [('web',FIXTURE/'web-typography.pdf'),('native',FIXTURE/'native-typography.pdf'),('native-derived-transform',OUT/'native-derived-transform.pdf')]:
 run([OUT/'raster',FIXTURE/'source.png',pdf,OUT/(name+'.png')])
def differences(name):
 text=run(['swift',HERE/'pixels.swift',OUT/'web.png',OUT/(name+'.png')])
 return [line for line in text.splitlines() if line]
before=differences('native');after=differences('native-derived-transform')
report={'scope':'Full640x880 decoded sRGB RGBA, actual frozen source and same-capture PDF text/font preserved; actual production capture regenerates vector background geometry only',
 'runtimeRendererRetestRequired':True,'beforeDifferentPixels':len(before),'beforePixelValues':before,'afterDifferentPixels':len(after),'allRGBAExact':not after,
 'deviceScale':3,'matrixScale':3*float.fromhex('0x1.555556p-2'),
 'source':'https://github.com/WebKit/WebKit/blob/main/Source/WebKit/WebProcess/WebPage/WebPage.cpp#L3744-L3777',
 'files':{n:hashlib.sha256((FIXTURE/n).read_bytes()).hexdigest() for n in ['web-typography.pdf','native-typography.pdf','source.png']}}
(OUT/'report.json').write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2));assert len(before)==2 and not after
