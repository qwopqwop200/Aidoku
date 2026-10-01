from pathlib import Path
import json,os,subprocess
ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).resolve().parent
O=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay';OUT=ROOT/'build/native-render-parity/preformatted-tab'
typography=Path(os.environ.get('AIDOKU_TAB_TYPOGRAPHY',str(O/'NativeTranslationTypography.swift')))
tabs=Path(os.environ.get('AIDOKU_TAB_POLICY',str(O/'NativePreformattedTabs.swift')))
source=ROOT/'AidokuTests/Translation/NativePreformattedTabTests.swift'
if not source.exists(): source=HERE/'NativePreformattedTabTests.swift'
test=OUT/'AppTests.swift';test.write_text(source.read_text().replace('@testable import Aidoku\n','')+'\n@main struct HostTests {static func main() async {exit(await Testing.__swiftPMEntryPoint())}}\n')
dev=Path(subprocess.check_output(['xcode-select','-p'],text=True).strip());frameworks=dev/'Platforms/MacOSX.platform/Developer/Library/Frameworks';macro=dev/'Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib'
subprocess.run(['xcrun','swiftc','-O','-swift-version','6','-strict-concurrency=complete','-F',str(frameworks),'-load-plugin-library',str(macro),str(typography),str(O/'NativeTextPaintGeometry.swift'),str(tabs),*[str(O/(name+'.swift')) for name in ('NativeKeepAllAutoLines','NativeKeepAllTextBalance','NativeKeepAllBreakOpportunities','NativeRawTextBalance')],str(test),'-Xlinker','-rpath','-Xlinker',str(frameworks),'-o',str(OUT/'app-tests')],check=True,cwd=ROOT)
r=subprocess.run([str(OUT/'app-tests')],text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,cwd=ROOT);(OUT/'app-tests.log').write_text(r.stdout);print(r.stdout,end='')
(OUT/'app-tests-report.json').write_text(json.dumps(dict(passed=r.returncode==0,tests=3,scope='Actual typography/CoreText and literal tab helper, staged or app test source without assertions removed. No UIKit bitmap rendering included.'),indent=2))
raise SystemExit(r.returncode)
