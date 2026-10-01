#!/usr/bin/env python3
"""Compile the actual final panel policy, Panel value type, and app regression tests."""
from pathlib import Path
import json,subprocess
ROOT=Path(__file__).resolve().parents[3]
OUT=ROOT/'build/native-render-parity/caption-background';OUT.mkdir(parents=True,exist_ok=True)
overlay=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay'
source=(overlay/'NativeTranslationSourceStylePostPolish.swift').read_text()
start=source.index('    struct Panel {');opening=source.index('{',start);depth=1;end=opening+1
while depth:
 depth+=(source[end]=='{')-(source[end]=='}');end+=1
geometry=(overlay/'NativePanelGeometry.swift').read_text()
backing=next(line for line in geometry.splitlines() if 'struct Backing {' in line)
(OUT/'Panel.swift').write_text('import CoreGraphics\nimport Foundation\nenum NativeTranslationSourceStylePostPolish {\n'+source[start:end]+'\n}\nenum NativePanelGeometry {\n'+backing+'\n}\n')
app=ROOT/'AidokuTests/Translation/NativeEngine/NativeCaptionPanelBackgroundTests.swift'
(OUT/'AppTests.swift').write_text(app.read_text().replace('@testable import Aidoku\n','')+'\n@main struct HostTests { static func main() async { exit(await Testing.__swiftPMEntryPoint()) } }\n')
dev=Path(subprocess.check_output(['xcode-select','-p'],text=True).strip())
frameworks=dev/'Platforms/MacOSX.platform/Developer/Library/Frameworks'
macro=dev/'Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib'
subprocess.run(['xcrun','swiftc','-O','-swift-version','6','-strict-concurrency=complete','-F',str(frameworks),'-load-plugin-library',str(macro),
 str(overlay/'NativeCSSCoveragePath.swift'),str(OUT/'Panel.swift'),str(overlay/'NativeTranslationCaptionPanelPolish.swift'),str(OUT/'AppTests.swift'),
 '-Xlinker','-rpath','-Xlinker',str(frameworks),'-o',str(OUT/'app-tests')],check=True)
r=subprocess.run([str(OUT/'app-tests')],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,cwd=ROOT)
(OUT/'app-tests.log').write_text(r.stdout);print(r.stdout,end='')
passed=r.returncode==0 and 'Test run with 1 test' in r.stdout
(OUT/'report.json').write_text(json.dumps({'passed':passed,'tests':1,'parameterCases':4,
 'scope':'Actual production panel policy and extracted verbatim Panel declaration; actual app tests with app import removed; no renderer or iOS raster execution.'},indent=2))
raise SystemExit(not passed)
