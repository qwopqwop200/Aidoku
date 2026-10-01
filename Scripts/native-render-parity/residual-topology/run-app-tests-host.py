#!/usr/bin/env python3
"""Run unchanged app topology tests on the host; remove app import only."""
import json, subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
OUT=ROOT/'build/native-render-parity/residual-topology-app-tests'
OUT.mkdir(parents=True,exist_ok=True)
source=ROOT/'AidokuTests/Translation/NativeEngine/NativeResidualTopologyTests.swift'
adapted=OUT/'HostTests.swift'
adapted.write_text(source.read_text().replace('@testable import Aidoku\n','')+'\n@main struct HostTests { static func main() async { exit(await Testing.__swiftPMEntryPoint()) } }\n')
dev=Path(subprocess.check_output(['xcode-select','-p'],text=True).strip());frameworks=dev/'Platforms/MacOSX.platform/Developer/Library/Frameworks';macro=dev/'Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib'
subprocess.run(['xcrun','swiftc','-O','-swift-version','6','-strict-concurrency=complete','-F',str(frameworks),'-load-plugin-library',str(macro),str(ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeResidualTopology.swift'),str(adapted),'-Xlinker','-rpath','-Xlinker',str(frameworks),'-o',str(OUT/'tests')],check=True,cwd=ROOT)
result=subprocess.run([str(OUT/'tests')],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,cwd=ROOT);(OUT/'tests.log').write_text(result.stdout);print(result.stdout,end='');passed=result.returncode==0 and 'Test run with 5 tests' in result.stdout;(OUT/'report.json').write_text(json.dumps({'passed':passed,'tests':5,'scope':'Actual production topology and app Swift Testing source; app import removed for host compilation only.'},indent=2));raise SystemExit(0 if passed else 1)
