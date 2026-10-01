#!/usr/bin/env python3
"""Run both actual app policy suites; remove app imports only for standalone host."""
import json, subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
OUT=ROOT/'build/native-render-parity/final-restoration-trial-app-tests'
OUT.mkdir(parents=True,exist_ok=True)
adapted=[]
for name in ['NativeResidualTopologyTests','NativeFinalRestorationTrialTests']:
 source=ROOT/'AidokuTests/Translation/NativeEngine'/(name+'.swift');target=OUT/(name+'.swift')
 target.write_text(source.read_text().replace('@testable import Aidoku\n',''));adapted.append(target)
entry=OUT/'HostTests.swift';entry.write_text('import Foundation\nimport Testing\n@main struct HostTests { static func main() async { exit(await Testing.__swiftPMEntryPoint()) } }\n')
dev=Path(subprocess.check_output(['xcode-select','-p'],text=True).strip());frameworks=dev/'Platforms/MacOSX.platform/Developer/Library/Frameworks';macro=dev/'Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib'
sources=[ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay'/(name+'.swift') for name in ['NativeResidualTopology','NativeFinalRestorationTrial']]
subprocess.run(['xcrun','swiftc','-O','-swift-version','6','-strict-concurrency=complete','-F',str(frameworks),'-load-plugin-library',str(macro),*map(str,sources+adapted+[entry]),'-Xlinker','-rpath','-Xlinker',str(frameworks),'-o',str(OUT/'tests')],check=True,cwd=ROOT)
result=subprocess.run([str(OUT/'tests')],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,cwd=ROOT);(OUT/'tests.log').write_text(result.stdout);print(result.stdout,end='');passed=result.returncode==0 and 'Test run with 10 tests' in result.stdout;(OUT/'report.json').write_text(json.dumps({'passed':passed,'tests':10,'scope':'Both unchanged app Swift Testing sources and production policies; @testable app import removed for host compilation only.'},indent=2));raise SystemExit(0 if passed else 1)
