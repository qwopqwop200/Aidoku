#!/usr/bin/env python3
"""Read-only SDK typecheck against Root's actual built Aidoku module.
No app build or simulator access. Use a successful current native-only Aidoku
build with matching sources/settings; the label records that exact prerequisite.
"""
from pathlib import Path
import argparse, subprocess, json, hashlib
root=Path(__file__).resolve().parents[3]
parser=argparse.ArgumentParser()
parser.add_argument('--build-label',required=True)
parser.add_argument('--helper',type=Path,default=root/'Scripts/native-render-parity/source-canvas-clip/staged/NativeForeignBackgroundPaintParityCapture.swift')
parser.add_argument('--expected-count',type=int,default=4)
parser.add_argument('--additional',type=Path,required=True)
parser.add_argument('--extra',type=Path,action='append',default=[])
parser.add_argument('--products',type=Path,default=root/'build/simulator-fast-release/Build/Products/Release-iphonesimulator')
args=parser.parse_args()
products=args.products.resolve()
helper=args.helper.resolve()
additional=args.additional.resolve()
module=products/'Aidoku.swiftmodule/arm64-apple-ios-simulator.swiftmodule'
out=root/'build/native-render-parity/source-canvas-snapshot-resize/combined-sdk-check'
out.mkdir(parents=True,exist_ok=True)
if not module.is_file(): raise SystemExit('Root-built arm64 Aidoku module missing; no build attempted')
developer=Path(subprocess.check_output(['xcode-select','-p'],text=True).strip())
sdk=subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-path'],text=True).strip()
framework=developer/'Platforms/iPhoneSimulator.platform/Developer/Library/Frameworks'
toolchain=developer/'Toolchains/XcodeDefault.xctoolchain'
plugins=toolchain/'usr/lib/swift/host/plugins/testing'
plugin_server=toolchain/'usr/bin/swift-plugin-server'
command=['xcrun','swiftc','-typecheck','-swift-version','6','-strict-concurrency=complete','-sdk',sdk,
 '-cxx-interoperability-mode=default','-Xcc','-std=gnu++17','-module-cache-path',str(out/'ModuleCache'),
 '-target','arm64-apple-ios18.0-simulator','-F',str(framework),'-F',str(products),'-F',str(products/'PackageFrameworks'),
 '-I',str(products),'-I',str(root/'Scripts/overlay-kernels/native'),'-Xcc',
 '-fmodule-map-file='+str(root/'Scripts/overlay-kernels/native/module.modulemap'),
 '-external-plugin-path',str(plugins)+'#'+str(plugin_server),str(helper)]
generated=products.parents[1]/'Intermediates.noindex/GeneratedModuleMaps-iphonesimulator'
for name in ['SVGKit.modulemap','CocoaLumberjack.modulemap']:
    mapping=generated/name
    if not mapping.is_file(): raise SystemExit('Required actual generated module map missing: '+str(mapping))
    command[-1:-1]=['-Xcc','-fmodule-map-file='+str(mapping)]
command[-1:-1]=['-Xcc','-fmodule-map-file='+str(root/'Vendor/HoshiDicts/include/module.modulemap')]
for include in [root/'Vendor/HoshiDicts/include',products.parents[2]/'SourcePackages/checkouts/SVGKit/Source/include',
                products.parents[2]/'SourcePackages/checkouts/CocoaLumberjack/Sources/CocoaLumberjack/include',
                Path(sdk)/'usr/include/libxml2']:
    command[-1:-1]=['-Xcc','-I'+str(include)]
command.append(str(additional))
for extra in args.extra: command.append(str(extra.resolve()))
result=subprocess.run(command,capture_output=True,text=True,cwd=root)
(out/'typecheck.log').write_text(result.stdout+result.stderr)
hashfile=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
report={'typecheckPassed':result.returncode==0,'scope':'isolated SDK semantics against actual Root-built Aidoku; no runtime/equality proof',
 'rootBuildLabel':args.build_label,'helperPath':str(helper),'helperSHA256':hashfile(helper),'additionalPath':str(additional),'additionalSHA256':hashfile(additional),
 'actualAidokuModulePath':str(module),'actualAidokuModuleSHA256':hashfile(module),
 'extraSources':[{'path':str(extra.resolve()),'SHA256':hashfile(extra.resolve())} for extra in args.extra],'expectedCount':args.expected_count,'runtimePixelEquality':'unverified'}
(out/'report.json').write_text(json.dumps(report,indent=2))
print(result.stdout+result.stderr)
print(json.dumps(report,indent=2))
raise SystemExit(result.returncode)
