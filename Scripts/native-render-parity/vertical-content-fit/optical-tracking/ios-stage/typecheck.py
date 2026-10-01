"""Isolated SDK typecheck of the staged test and actual production dependencies.
Does not build, install, or launch the app or simulator.
"""
from pathlib import Path
import subprocess
root = Path(__file__).resolve().parents[5]
here = Path(__file__).resolve().parent
out = root / 'build/native-render-parity/vertical-ideograph-paint'
test = out / 'NativeHanPDFPaintParityTypecheck.swift'
test.write_text((here / 'NativeHanPDFPaintParityTests.swift').read_text().replace('@testable import Aidoku\n', ''))
o = root / 'Aidoku/Core/Translation/NativeEngine/Overlay'
names = ['NativeTranslationTypography', 'NativeTranslationPDFCapture', 'NativeTextPaintGeometry', 'NativePreformattedTabs',
         'NativeKeepAllAutoLines', 'NativeKeepAllTextBalance', 'NativeKeepAllBreakOpportunities', 'NativeRawTextBalance',
         'NativeVerticalLetterSpacing', 'NativeNormalTextFlow', 'NativeNormalBreakOpportunities', 'NativeCTFontStrokePainter',
         'NativeVisibleControlGlyphs']
dev = Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip())
sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
frameworks = dev / 'Platforms/iPhoneSimulator.platform/Developer/Library/Frameworks'
plugin = dev / 'Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib'
result = subprocess.run(['xcrun', 'swiftc', '-typecheck', '-swift-version', '6', '-target', 'arm64-apple-ios18.0-simulator',
    '-sdk', sdk, '-F', str(frameworks), '-load-plugin-library', str(plugin),
    *[str(o / (name + '.swift')) for name in names], str(test)], capture_output=True, text=True)
(out / 'ios-staged-typecheck.log').write_text(result.stdout + result.stderr)
print(result.stdout + result.stderr)
raise SystemExit(result.returncode)
