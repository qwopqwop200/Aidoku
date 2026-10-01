from pathlib import Path
import subprocess
ROOT=Path(__file__).resolve().parents[4];HERE=Path(__file__).resolve().parent;O=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay';OUT=ROOT/'build/native-render-parity/vertical-optical-tracking'
test=OUT/'TrackingTests.swift';test.write_text((HERE/'NativeVerticalLetterSpacingTests.swift').read_text().replace('@testable import Aidoku\n','')+'\n@main struct HostTests { static func main() async { exit(await Testing.__swiftPMEntryPoint()) } }\n')
dev=Path(subprocess.check_output(['xcode-select','-p'],text=True).strip());frameworks=dev/'Platforms/MacOSX.platform/Developer/Library/Frameworks';macro=dev/'Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib'
sources=[O/'NativeTranslationTypography.swift',O/'NativeTextPaintGeometry.swift',*[O/(n+'.swift') for n in ('NativePreformattedTabs','NativeKeepAllAutoLines','NativeKeepAllTextBalance','NativeKeepAllBreakOpportunities','NativeRawTextBalance','NativeVerticalLetterSpacing','NativeNormalTextFlow','NativeNormalBreakOpportunities','NativeCTFontStrokePainter','NativeVisibleControlGlyphs')],test]
subprocess.run(['xcrun','swiftc','-O','-swift-version','6','-strict-concurrency=complete','-F',str(frameworks),'-load-plugin-library',str(macro),*map(str,sources),'-Xlinker','-rpath','-Xlinker',str(frameworks),'-o',str(OUT/'tracking-tests')],check=True)
r=subprocess.run([str(OUT/'tracking-tests')],text=True,capture_output=True);(OUT/'tracking-tests.log').write_text(r.stdout+r.stderr);print(r.stdout+r.stderr);raise SystemExit(r.returncode)
