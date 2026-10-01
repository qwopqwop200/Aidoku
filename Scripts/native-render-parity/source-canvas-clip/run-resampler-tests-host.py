#!/usr/bin/env python3
"""Run actual native texture sampling and Float-over primitive tests."""
from pathlib import Path
import hashlib,json,subprocess
ROOT=Path(__file__).resolve().parents[3]
OUT=ROOT/'build/native-render-parity/source-canvas-clip/resampler-app-tests';OUT.mkdir(parents=True,exist_ok=True)
helper=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeCanvasTextureResampler.swift'
source=ROOT/'AidokuTests/Translation/NativeEngine/NativeCanvasTextureResamplerTests.swift'
snapshot=OUT/'NativeCanvasTextureResampler.swift';snapshot.write_bytes(helper.read_bytes())
test=OUT/'Tests.swift';test.write_text(source.read_text().replace('@testable import Aidoku\n','')+'\n@main struct HostTests {static func main() async {exit(await Testing.__swiftPMEntryPoint())}}\n')
dev=Path(subprocess.check_output(['xcode-select','-p'],text=True).strip())
framework=dev/'Platforms/MacOSX.platform/Developer/Library/Frameworks'
macro=dev/'Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib'
cmd=['xcrun','swiftc','-O','-swift-version','6','-strict-concurrency=complete','-F',str(framework),'-load-plugin-library',str(macro),str(snapshot),str(test),'-Xlinker','-rpath','-Xlinker',str(framework),'-o',str(OUT/'tests')]
r=subprocess.run(cmd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True);(OUT/'compile.log').write_text(r.stdout);print(r.stdout,end='')
if not r.returncode:
 r=subprocess.run([str(OUT/'tests')],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True);(OUT/'tests.log').write_text(r.stdout);print(r.stdout,end='')
(OUT/'report.json').write_text(json.dumps(dict(passed=r.returncode==0,testFunctions=6,parameterCases=6,scope='Actual PMA identity/crop, bounded allocation, session close, cancellation, one-pass Float source-over and composited-crop app tests. Optimized strict Swift6 host; no WK alpha composition claim.',sourceSHA256={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [helper,source]},artifactSHA256={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in [snapshot,test,OUT/'tests',OUT/'tests.log'] if p.exists()}),indent=2))
raise SystemExit(r.returncode)
