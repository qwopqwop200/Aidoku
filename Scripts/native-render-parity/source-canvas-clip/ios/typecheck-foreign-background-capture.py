#!/usr/bin/env python3
"""Read-only SDK typecheck against Root's actual built Aidoku module.
No app build or simulator access. Run after Root declares BUILD52 complete:
51's module predates the retained background declaration fields.
"""
from pathlib import Path
import argparse, subprocess, json, hashlib
root=Path(__file__).resolve().parents[4]
parser=argparse.ArgumentParser()
parser.add_argument('--build-label',required=True)
parser.add_argument('--helper',type=Path,default=root/'Scripts/native-render-parity/source-canvas-clip/staged/NativeForeignBackgroundPaintParityCapture.swift')
parser.add_argument('--expected-count',type=int,default=4)
parser.add_argument('--products',type=Path,default=root/'build/simulator-fast-release/Build/Products/Release-iphonesimulator')
args=parser.parse_args()
products=args.products.resolve()
helper=args.helper.resolve()
module=products/'Aidoku.swiftmodule/arm64-apple-ios-simulator.swiftmodule'
out=root/'build/native-render-parity/source-canvas-clip/ios-sdk-check'/helper.stem
out.mkdir(parents=True,exist_ok=True)
if not module.is_file(): raise SystemExit('Root-built arm64 Aidoku module missing; no build attempted')
developer=Path(subprocess.check_output(['xcode-select','-p'],text=True).strip())
sdk=subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-path'],text=True).strip()
framework=developer/'Platforms/iPhoneSimulator.platform/Developer/Library/Frameworks'
macro=developer/'Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib'
command=['xcrun','swiftc','-typecheck','-swift-version','6','-strict-concurrency=complete','-sdk',sdk,
 '-cxx-interoperability-mode=default','-Xcc','-std=gnu++17','-module-cache-path',str(out/'ModuleCache'),
 '-target','arm64-apple-ios18.0-simulator','-F',str(framework),'-F',str(products),'-F',str(products/'PackageFrameworks'),
 '-I',str(products),'-I',str(root/'Scripts/overlay-kernels/native'),'-Xcc',
 '-fmodule-map-file='+str(root/'Scripts/overlay-kernels/native/module.modulemap'),
 '-load-plugin-library',str(macro),str(helper)]
for component in ['wasm3-c','wasm3-support']:
    command[-1:-1]=['-Xcc','-I'+str(root/'Vendor/Wasm3/Sources'/component/'include')]
generated=products.parents[1]/'Intermediates.noindex/GeneratedModuleMaps-iphonesimulator'
for name in ['wasm3-c.modulemap','wasm3-support.modulemap','SVGKit.modulemap','CocoaLumberjack.modulemap']:
    mapping=generated/name
    if not mapping.is_file(): raise SystemExit('Required actual generated module map missing: '+str(mapping))
    command[-1:-1]=['-Xcc','-fmodule-map-file='+str(mapping)]
command[-1:-1]=['-Xcc','-fmodule-map-file='+str(root/'Vendor/HoshiDicts/include/module.modulemap')]
for include in [root/'Vendor/HoshiDicts/include',products.parents[2]/'SourcePackages/checkouts/SVGKit/Source/include',
                products.parents[2]/'SourcePackages/checkouts/CocoaLumberjack/Sources/CocoaLumberjack/include',
                Path(sdk)/'usr/include/libxml2']:
    command[-1:-1]=['-Xcc','-I'+str(include)]
result=subprocess.run(command,capture_output=True,text=True,cwd=root)
(out/'typecheck.log').write_text(result.stdout+result.stderr)
hashfile=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
report={'typecheckPassed':result.returncode==0,'scope':'isolated SDK semantics against actual Root-built Aidoku; no runtime/equality proof',
 'rootBuildLabel':args.build_label,'helperPath':str(helper),'helperSHA256':hashfile(helper),
 'actualAidokuModulePath':str(module),'actualAidokuModuleSHA256':hashfile(module),
 'expectedCount':args.expected_count,'runtimePixelEquality':'unverified'}
(out/'report.json').write_text(json.dumps(report,indent=2))
print(result.stdout+result.stderr)
print(json.dumps(report,indent=2))
raise SystemExit(result.returncode)
