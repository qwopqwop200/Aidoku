#!/usr/bin/env python3
from pathlib import Path
import json,subprocess
ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).resolve().parent
OUT=ROOT/'build/native-render-parity/recovered-line';OUT.mkdir(parents=True,exist_ok=True)
source=ROOT/'AidokuTests/Translation/NativeRecoveredLineProtectionTests.swift'
adapted=OUT/'AppTests.swift';adapted.write_text(source.read_text().replace('@testable import Aidoku\n','')+'\n@main struct HostTests { static func main() async { exit(await Testing.__swiftPMEntryPoint()) } }\n')
model=OUT/'Model.swift';model.write_text('import Foundation\nimport CoreGraphics\nstruct NativeTranslationLayoutItem { let id:String; let keptLettering:Bool;let sourceBounds:[CGFloat];let sourceFrame:[CGFloat];let sourceFontSize:CGFloat? }\n')
OVERLAY=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay'
sources=[OVERLAY/(name+'.swift') for name in ('NativeRecoveredLineProtection','NativeKeptSourceRestoration','NativePanelGeometry','NativeTranslationSourceStylePostPolish')]
dev=Path(subprocess.check_output(['xcode-select','-p'],text=True).strip());frameworks=dev/'Platforms/MacOSX.platform/Developer/Library/Frameworks';macro=dev/'Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib'
subprocess.run(['xcrun','swiftc','-O','-swift-version','6','-strict-concurrency=complete','-F',str(frameworks),'-load-plugin-library',str(macro),str(model),*map(str,sources),str(adapted),'-Xlinker','-rpath','-Xlinker',str(frameworks),'-o',str(OUT/'app-tests')],check=True)
result=subprocess.run([str(OUT/'app-tests')],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,cwd=ROOT)
(OUT/'app-tests.log').write_text(result.stdout);print(result.stdout,end='')
passed=result.returncode==0 and 'Test run with 3 tests' in result.stdout
(OUT/'app-tests-report.json').write_text(json.dumps(dict(passed=passed,tests=3,scope='Actual app test source and native policy; app import removed only for host compilation.'),indent=2))
raise SystemExit(0 if passed else 1)
