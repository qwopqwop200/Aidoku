#!/usr/bin/env python3
from pathlib import Path
import json,subprocess
ROOT=Path(__file__).resolve().parents[3];OUT=ROOT/'build/native-render-parity/pdf-crop';OUT.mkdir(parents=True,exist_ok=True)
service=(ROOT/'Aidoku/Core/Translation/ReaderTranslationService.swift').read_text()
start=service.index('enum ReaderTranslationGeometry {');end=service.index('\n@available(iOS 18.0, *)\nactor ReaderOCRService',start)
(OUT/'Geometry.swift').write_text('import Foundation\nimport CoreGraphics\n'+service[start:end])
a=OUT/'AppTests.swift';a.write_text((ROOT/'AidokuTests/Translation/NativePDFCropTests.swift').read_text().replace('@testable import Aidoku\n','')+'\n@main struct HostTests { static func main() async { exit(await Testing.__swiftPMEntryPoint()) } }\n')
dev=Path(subprocess.check_output(['xcode-select','-p'],text=True).strip());frameworks=dev/'Platforms/MacOSX.platform/Developer/Library/Frameworks';macro=dev/'Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib'
subprocess.run(['xcrun','swiftc','-O','-swift-version','6','-strict-concurrency=complete','-F',str(frameworks),'-load-plugin-library',str(macro),str(ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeTranslationPDFCapture.swift'),str(OUT/'Geometry.swift'),str(a),'-Xlinker','-rpath','-Xlinker',str(frameworks),'-o',str(OUT/'app-tests')],check=True)
r=subprocess.run([str(OUT/'app-tests')],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,cwd=ROOT);(OUT/'app-tests.log').write_text(r.stdout);print(r.stdout,end='')
passed=r.returncode==0 and 'Test run with 2 tests' in r.stdout
(OUT/'report.json').write_text(json.dumps(dict(passed=passed,tests=2,scope='Actual app test source, production PDF capture and actual ReaderTranslationGeometry; app import removed for host compilation. Both captures compare every RGBA byte.'),indent=2));raise SystemExit(not passed)
