#!/usr/bin/env python3
"""Run actual cleanup-frame helper and Codable tests with host-only UIEdgeInsets transport."""
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'build/native-render-parity/cleanup-geometry-tests'
OUT.mkdir(parents=True, exist_ok=True)
OVERLAY = ROOT / 'Aidoku/Core/Translation/NativeEngine/Overlay'
layout = (OVERLAY / 'NativeTranslationLayout.swift').read_text()
(OUT / 'Models.swift').write_text(layout.split('/// Actor confinement')[0].replace('import UIKit\n', ''))
validation = re.search(r'    static func validGeometry\([\s\S]*?\n    }', layout).group()
(OUT / 'Host.swift').write_text('import CoreGraphics\n'
    'struct UIEdgeInsets { var top:CGFloat; var left:CGFloat; var bottom:CGFloat; var right:CGFloat }\n'
    'extension CGRect { func inset(by i:UIEdgeInsets)->CGRect { CGRect(x:minX+i.left,y:minY+i.top,width:width-i.left-i.right,height:height-i.top-i.bottom) } }\n'
    'enum NativeTranslationRenderer {}\nenum NativeTranslationLayoutPlanner {\n' + validation + '\n}\n')
test = ROOT / 'AidokuTests/Translation/NativeEngine/NativeCleanupGeometryTests.swift'
(OUT / 'Tests.swift').write_text(test.read_text().replace('@testable import Aidoku\n', ''))
(OUT / 'Main.swift').write_text('import Foundation\nimport Testing\n@main struct HostTests { static func main() async { exit(await Testing.__swiftPMEntryPoint()) } }\n')
dev = Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip())
framework = dev / 'Platforms/MacOSX.platform/Developer/Library/Frameworks'
macro = dev / 'Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib'
sources = [OUT / name for name in ['Models.swift', 'Host.swift', 'Tests.swift', 'Main.swift']]
sources += [OVERLAY / name for name in ['NativeSourceSurfaceGeometry.swift', 'NativeTranslationRenderer+CleanupGeometry.swift']]
subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-strict-concurrency=complete', '-F', str(framework),
    '-load-plugin-library', str(macro), *map(str, sources), '-Xlinker', '-rpath', '-Xlinker', str(framework),
    '-o', str(OUT / 'tests')], check=True, cwd=ROOT)
run = subprocess.run([str(OUT / 'tests')], text=True, capture_output=True, cwd=ROOT)
(OUT / 'tests.log').write_text(run.stdout + run.stderr)
report = {'passed': run.returncode == 0, 'tests': 3,
    'scope': 'Actual source geometry helper, actual layout Codable models and unchanged app tests; UIEdgeInsets transport only. Does not run the complete renderer or pixel restoration.'}
(OUT / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report))
if run.returncode:
    print(run.stdout + run.stderr)
    raise SystemExit(run.returncode)
