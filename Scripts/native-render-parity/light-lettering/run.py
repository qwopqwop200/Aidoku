#!/usr/bin/env python3
import json,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).resolve().parent
OUT=ROOT/'build/native-render-parity/light-lettering';OUT.mkdir(parents=True,exist_ok=True)
OVERLAY=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay'
native=OVERLAY/'NativeLightLettering.swift'
if not native.exists():native=HERE.parent/'NativeLightLettering.swift'
subprocess.run(['node',str(HERE/'capture.cjs'),str(ROOT),str(OUT/'fixtures.json')],check=True)
subprocess.run(['xcrun','swiftc','-swift-version','6','-strict-concurrency=complete',str(OVERLAY/'NativeCSSCoveragePath.swift'),str(OVERLAY/'NativeTranslationSourceStylePostPolish.swift'),str(native),str(HERE/'Probe.swift'),'-o',str(OUT/'probe')],check=True,cwd=ROOT)
subprocess.run([str(OUT/'probe'),str(OUT/'fixtures.json'),str(OUT/'actual.json')],check=True)
f=json.loads((OUT/'fixtures.json').read_text());a=json.loads((OUT/'actual.json').read_text())
bad=[]
for i,(fixture,actual) in enumerate(zip(f,a)):
 expected=fixture['expected']
 if expected!=actual:bad.append({'case':i,'expected':{k:v for k,v in expected.items() if k!='sampled'},'actual':{k:v for k,v in actual.items() if k!='sampled'},'sampleExact':expected['sampled']==actual['sampled']})
r={'cases':len(f),'exact':len(f)-len(bad),'passed':not bad,'accepted':sum(x['styled'] for x in a),'sampled':sum(x['sampled'] is not None for x in a),'failures':bad}
(OUT/'report.json').write_text(json.dumps(r,indent=2));print(json.dumps(r))
if bad:raise SystemExit(1)
test_source=ROOT/'AidokuTests/Translation/NativeEngine/NativeLightLetteringTests.swift'
tests=OUT/test_source.name;tests.write_text(test_source.read_text().replace('@testable import Aidoku\n',''))
entry=OUT/'Main.swift';entry.write_text('import Foundation\nimport Testing\n@main struct HostTests { static func main() async { exit(await Testing.__swiftPMEntryPoint()) } }\n')
dev=Path(subprocess.check_output(['xcode-select','-p'],text=True).strip())
frameworks=dev/'Platforms/MacOSX.platform/Developer/Library/Frameworks'
macro=dev/'Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib'
subprocess.run(['xcrun','swiftc','-swift-version','6','-strict-concurrency=complete','-F',str(frameworks),'-load-plugin-library',str(macro),str(OVERLAY/'NativeCSSCoveragePath.swift'),str(OVERLAY/'NativeTranslationSourceStylePostPolish.swift'),str(native),str(tests),str(entry),'-Xlinker','-rpath','-Xlinker',str(frameworks),'-o',str(OUT/'tests')],check=True,cwd=ROOT)
run=subprocess.run([str(OUT/'tests')],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
(OUT/'tests.log').write_text(run.stdout);print(run.stdout,end='')
raise SystemExit(run.returncode)
