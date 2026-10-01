#!/usr/bin/env python3
"""Compile the production backing painter and exact stored Backing transport."""
import hashlib, json, re, subprocess
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'build/native-render-parity/source-backing-paint-tests'
OUT.mkdir(parents=True, exist_ok=True)
OVERLAY = ROOT / 'Aidoku/Core/Translation/NativeEngine/Overlay'
model = (OVERLAY / 'NativePanelGeometry.swift').read_text()
backing = re.search(r'    struct Backing \{[^\n]*\}', model).group()
renderer = (OVERLAY / 'NativeTranslationRenderer.swift').read_text()
color = re.search(r'    static func color\([\s\S]*?\n    }', renderer).group()
transport = OUT / 'Transport.swift'
transport.write_text('import CoreGraphics\nimport Foundation\nenum NativePanelGeometry {\n' + backing + '\n}\nenum NativeTranslationRenderer {\n' + color + '\n}\n')
test = ROOT / 'AidokuTests/Translation/NativeEngine/NativeSourceBackingPaintTests.swift'
local_test = OUT / test.name
local_test.write_text(test.read_text().replace('@testable import Aidoku\n',''))
entry = OUT / 'Main.swift'
entry.write_text('import Foundation\nimport Testing\n@main struct Host { static func main() async { exit(await Testing.__swiftPMEntryPoint()) } }\n')
sources = [OVERLAY / 'NativeTranslationRenderer+SourceBacking.swift', OVERLAY / 'NativeTranslationPDFCapture.swift', OVERLAY / OVERLAY / 'NativeTranslationRenderer+CoverageClip.swift', OVERLAY / 'NativeSourceCanvasClip.swift']
frozen = []
for source in sources:
    target = OUT / source.name
    target.write_bytes(source.read_bytes()); frozen.append(target)
developer = Path(subprocess.check_output(['xcode-select','-p'], text=True).strip())
frameworks = developer / 'Platforms/MacOSX.platform/Developer/Library/Frameworks'
macro = developer / 'Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib'
subprocess.run(['xcrun','swiftc','-O','-swift-version','6','-strict-concurrency=complete','-F',str(frameworks),'-load-plugin-library',str(macro),*map(str,[transport,*frozen,local_test,entry]),'-Xlinker','-rpath','-Xlinker',str(frameworks),'-o',str(OUT/'tests')],check=True,cwd=ROOT)
run = subprocess.run([str(OUT/'tests')],text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
(OUT/'tests.log').write_text(run.stdout); print(run.stdout,end='')
passed = run.returncode == 0 and 'Test run with 2 tests' in run.stdout
(OUT/'report.json').write_text(json.dumps({'passed':passed,'declarations':2,'cases':2,'scope':'Production backing painter and exact Backing transport; captured vector local-clip raster control rejects former global clip, bitmap state-preservation control. Actual PaintScene binding parsed separately; no host UIKit simulation.', 'sourceSHA256':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [*sources,test,OVERLAY/'NativeTranslationRenderer+PaintOrder.swift']},'compiledTransportSHA256':hashlib.sha256(transport.read_bytes()).hexdigest()},indent=2))
raise SystemExit(0 if passed else 1)
