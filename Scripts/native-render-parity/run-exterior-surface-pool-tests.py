#!/usr/bin/env python3
"""Compile unchanged production pooled scan and its actual Swift Testing suite."""
from pathlib import Path
import subprocess, json, hashlib
root=Path(__file__).resolve().parents[2]
out=root/'build/native-render-parity/exterior-surface-pool';out.mkdir(parents=True,exist_ok=True)
source=root/'Aidoku/Core/Translation/NativeEngine/Overlay/NativeTranslationSurfacePool.swift'
test=root/'AidokuTests/Translation/NativeEngine/NativeExteriorSurfacePoolTests.swift'
(out/test.name).write_text(test.read_text().replace('@testable import Aidoku\n',''))
(out/'Main.swift').write_text('import Testing\nimport Foundation\n@main struct Main { static func main() async { exit(await Testing.__swiftPMEntryPoint()) } }\n')
developer=Path(subprocess.check_output(['xcode-select','-p'],text=True).strip());frameworks=developer/'Platforms/MacOSX.platform/Developer/Library/Frameworks';macro=developer/'Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib'
subprocess.run(['xcrun','swiftc','-swift-version','6','-strict-concurrency=complete','-F',str(frameworks),'-load-plugin-library',str(macro),str(source),str(out/test.name),str(out/'Main.swift'),'-Xlinker','-rpath','-Xlinker',str(frameworks),'-o',str(out/'tests')],check=True,cwd=root)
subprocess.run([str(out/'tests')],check=True,cwd=root)
(out/'report.json').write_text(json.dumps(dict(passed=3,scope='Actual production pooled mixed interior/exterior scan + unchanged app Swift Testing suite',sourceSHA256=hashlib.sha256(source.read_bytes()).hexdigest(),testSHA256=hashlib.sha256(test.read_bytes()).hexdigest()),indent=2))
