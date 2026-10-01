#!/usr/bin/env python3
"""Bounded actual compositor/CoreGraphics prefix controls on the macOS worker.
No Xcode build or simulator. Device foreign4 remains Root-owned.
"""
from pathlib import Path
import subprocess,json,hashlib,shutil
ROOT=Path(__file__).resolve().parents[2]
O=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay'
OUT=ROOT/'build/native-render-parity/foreign-background-compositor-tests';OUT.mkdir(parents=True,exist_ok=True)
def block(source, needle):
    s=source.index(needle);a=source.index('{',s);depth=1;b=a+1
    while depth:
        depth+=(source[b]=='{')-(source[b]=='}');b+=1
    return source[s:b]
models=OUT/'Models.swift'
models.write_text('import CoreGraphics\nimport Foundation\nenum NativeTranslationSourceStylePostPolish {\n'+block((O/'NativeTranslationSourceStylePostPolish.swift').read_text(),'    struct Panel {')+'\n}\nenum NativeCaptionPacking {\n'+block((O/'NativeCaptionPacking.swift').read_text(),'    struct ForeignFill {')+'\n}\n')
core=O/'NativeLayerTreeCapture.swift'
if not core.exists(): core=ROOT/'Scripts/native-render-parity/foreign-background-gradient/staged/NativeLayerTreeCapture.swift'
sources=[core]+[O/(n+'.swift') for n in ['NativeCanvasTextureResampler','NativeCanvasBacking','NativeForeignBackgroundGradient','NativeTranslationPDFCapture','NativeCSSCoveragePath','NativeForeignBackgroundCompositor']]
test=ROOT/'AidokuTests/Translation/NativeEngine/NativeForeignBackgroundCompositorTests.swift'
snapshot=OUT/'source-snapshot';snapshot.mkdir(exist_ok=True)
copied=[];hashes={}
for p in sources:
 q=snapshot/p.name;shutil.copyfile(p,q);copied.append(q);hashes[str(p.relative_to(ROOT))]=hashlib.sha256(q.read_bytes()).hexdigest()
tests=OUT/test.name;tests.write_text(test.read_text().replace('@testable import Aidoku\n',''))
main=OUT/'Main.swift';main.write_text('import Foundation\nimport Testing\n@main struct Host { static func main() async { exit(await Testing.__swiftPMEntryPoint()) } }\n')
developer=Path(subprocess.check_output(['xcode-select','-p'],text=True).strip());framework=developer/'Platforms/MacOSX.platform/Developer/Library/Frameworks';macro=developer/'Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib'
cmd=['xcrun','swiftc','-O','-swift-version','6','-strict-concurrency=complete','-F',str(framework),'-load-plugin-library',str(macro),*map(str,[models]+copied+[tests,main]),'-Xlinker','-rpath','-Xlinker',str(framework),'-o',str(OUT/'tests')]
c=subprocess.run(cmd,capture_output=True,text=True,cwd=ROOT);(OUT/'compile.log').write_text(c.stdout+c.stderr)
if c.returncode: print(c.stdout+c.stderr);raise SystemExit(c.returncode)
r=subprocess.run([str(OUT/'tests')],capture_output=True,text=True,cwd=ROOT);log=r.stdout+r.stderr;(OUT/'tests.log').write_text(log);print(log)
report={'passed':r.returncode==0,'declarations':2,'cases':9,'scope':'Actual production compositor/public CA worker; canonical partial-alpha top/bottom prefix preservation outside owner and unsupported-context/resource refusal. macOS only, not iOS foreign4 proof. Actual model declarations extracted verbatim; no painter mocks.','sources':hashes,'testSHA256':hashlib.sha256(test.read_bytes()).hexdigest()}
(OUT/'report.json').write_text(json.dumps(report,indent=2)+'\n');raise SystemExit(r.returncode)
