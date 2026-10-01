#!/usr/bin/env python3
"""Compile the actual UnitParts child style producer and actual CoreText tests."""
from pathlib import Path
import hashlib,json,re,subprocess
ROOT=Path(__file__).resolve().parents[3];O=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay'
OUT=ROOT/'build/native-render-parity/unit-parts-style';OUT.mkdir(parents=True,exist_ok=True)
producer=O/'NativeTranslationRenderer+UnitParts.swift';text=producer.read_text()
start=text.index('    static func unitPartTypographyStyle(');brace=text.index('{',start);end=brace+1;depth=1
while depth:
 depth+=(text[end]=='{')-(text[end]=='}');end+=1
transport=OUT/'Producer.swift';transport.write_text('import CoreGraphics\nenum NativeTranslationRenderer {\n'+text[start:end]+'\n}\n')
source=ROOT/'AidokuTests/Translation/NativeEngine/NativeBalloonUnitPartsStyleTests.swift'
test=OUT/'Tests.swift';test.write_text(source.read_text().replace('@testable import Aidoku\n','')+'\n@main struct HostTests {static func main() async {exit(await Testing.__swiftPMEntryPoint())}}\n')
files={O/(n+'.swift') for n in ['NativeTranslationTypography','NativeTextPaintGeometry','NativePreformattedTabs','NativeRawTextBalance','NativeVerticalLetterSpacing','NativeCTFontStrokePainter']}
files.update(O.glob('NativeKeepAll*.swift'));files.update(O.glob('NativeNormal*.swift'))
snapshot=OUT/'Sources';snapshot.mkdir(exist_ok=True);compiled=[]
for f in sorted(files):
 p=snapshot/f.name;p.write_bytes(f.read_bytes());compiled.append(p)
dev=Path(subprocess.check_output(['xcode-select','-p'],text=True).strip());framework=dev/'Platforms/MacOSX.platform/Developer/Library/Frameworks';macro=dev/'Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib'
cmd=['xcrun','swiftc','-O','-swift-version','6','-strict-concurrency=complete','-F',str(framework),'-load-plugin-library',str(macro),*map(str,compiled),str(transport),str(test),'-Xlinker','-rpath','-Xlinker',str(framework),'-o',str(OUT/'tests')]
r=subprocess.run(cmd,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True);(OUT/'compile.log').write_text(r.stdout);print(r.stdout,end='')
if not r.returncode:
 r=subprocess.run([str(OUT/'tests')],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True);(OUT/'tests.log').write_text(r.stdout);print(r.stdout,end='')
(OUT/'report.json').write_text(json.dumps({'passed':r.returncode==0,'testFunctions':2,'parameterCases':3,'scope':'Actual UnitParts child style producer extracted verbatim; current CoreText typography, supplied actual app tests. Full UnitParts spatial placement and final PNG equivalence are separate gates.','sourceSHA256':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(files)+[producer,source]},'artifactSHA256':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in [transport,test,OUT/'tests',OUT/'tests.log'] if p.exists()}},indent=2))
raise SystemExit(r.returncode)
