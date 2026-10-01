#!/usr/bin/env python3
"""Run unchanged app candidate tests against the actual native restoration files."""
import hashlib
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUTPUT = ROOT / 'build/native-render-parity/glyph-cover-adapter-tests'
OUTPUT.mkdir(parents=True, exist_ok=True)
OVERLAY = ROOT / 'Aidoku/Core/Translation/NativeEngine/Overlay'
layout = (OVERLAY / 'NativeTranslationLayout.swift').read_text()
models = OUTPUT / 'NativeTranslationModels.swift'
models.write_text(layout.split('/// Actor confinement')[0].replace('import UIKit\n', ''))
geometry = re.search(r'    static func validGeometry\([\s\S]*?\n    }', layout).group()
shims = OUTPUT / 'LayoutHostShims.swift'
shims.write_text('import CoreGraphics\n'
    'struct UIEdgeInsets { var top:CGFloat; var left:CGFloat; var bottom:CGFloat; var right:CGFloat }\n'
    'extension CGRect { func inset(by i:UIEdgeInsets)->CGRect { '
    'CGRect(x:minX+i.left,y:minY+i.top,width:width-i.left-i.right,height:height-i.top-i.bottom) } }\n'
    'enum NativeTranslationLayoutPlanner {\n' + geometry + '\n}\n')
test_source = ROOT / 'AidokuTests/Translation/NativeEngine/NativeGlyphCoverTests.swift'
tests = OUTPUT / test_source.name
test = test_source.read_text().replace('@testable import Aidoku\n', '')
start = test.index('    private func fixtures()'); end = test.index('    private func numbers',start)
fixture = ROOT / 'build/native-render-parity/glyph-cover/app-manifest.json'
inputs = json.loads((ROOT/'build/native-render-parity/glyph-cover/fixtures.json').read_text())
expected = json.loads((ROOT/'build/native-render-parity/glyph-cover/expected.json').read_text())
fixture.write_text(json.dumps(dict(cases=[dict(input=i,expected=e) for i,e in zip(inputs,expected)])))
test = test[:start] + '    private func fixtures() throws -> [[String:Any]] { (try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:'+json.dumps(str(fixture))+'))) as! [String:Any])["cases"] as! [[String:Any]] }\n' + test[end:]
tests.write_text(test)
position_source = ROOT / 'AidokuTests/Translation/NativeEngine/NativeRendererSourcePositionTests.swift'
position_tests = OUTPUT / position_source.name
position_tests.write_text(position_source.read_text().replace('@testable import Aidoku\n', ''))
kept_source = ROOT / 'AidokuTests/Translation/NativeEngine/NativeKeptSourceRestorationTests.swift'
kept_tests = OUTPUT / kept_source.name
kept_tests.write_text(kept_source.read_text().replace('@testable import Aidoku\n', ''))
minimal_source = ROOT / 'AidokuTests/Translation/NativeEngine/NativeMinimalRestoredPlateTests.swift'
minimal_tests = OUTPUT / minimal_source.name
minimal_tests.write_text(minimal_source.read_text().replace('@testable import Aidoku\n', ''))
# This is the production Card transport and ink measurement verbatim; the host
# excludes the unrelated UIKit bitmap renderer and async reader entrypoints.
renderer = (OVERLAY / 'NativeTranslationRenderer.swift').read_text()
card = renderer[renderer.index('    struct TextPart {'):renderer.index('    struct GlossCard {')]
def method(name):
    return re.search(r'    static func '+name+r'\([\s\S]*?\n    }', renderer).group()
ink = '\n'.join(method(name) for name in ['cardInkRect', 'cardPageRangeRects', 'textPartFrame', 'rotatedBounds', 'remeasureTypography', 'color', 'usedLayoutItem', 'rgb', 'pageRect'])
cohort = (OVERLAY / 'NativeTranslationRenderer+DisplayStyleCohort.swift').read_text()
metadata = cohort[cohort.index('    struct DisplayCohortMetadata {'):cohort.index('    struct DisplayCohortDiagnostic {')]

renderer_transport = OUTPUT / 'NativeRendererTransport.swift'
renderer_transport.write_text('import Foundation\nimport CoreGraphics\nenum NativeTranslationRenderer {\n'
    'struct SourcePatch { let image:CGImage; let rect:CGRect }\n' + card + ink + '\n' + metadata + '}\n')
display_source = ROOT / 'AidokuTests/Translation/NativeEngine/NativeDisplayLetteringRestorationTests.swift'
if not display_source.exists(): display_source = ROOT / 'build/native-display-lettering/NativeDisplayLetteringRestorationTests.swift'
display_tests = OUTPUT / display_source.name
display_tests.write_text(display_source.read_text().replace('@testable import Aidoku\n', ''))
entry = OUTPUT / 'Main.swift' 
entry.write_text('import Foundation\nimport Testing\n'
    '@main struct HostTests { static func main() async { exit(await Testing.__swiftPMEntryPoint()) } }\n')
names = ['NativeTranslationRestoration', 'NativeSpatialSourceCrop', 'IPhoneOverlaySettings',
    'NativeSourceGlyphSegmentation', 'NativeTranslationPixelKernels', 'NativeSourceColorSampler',
    'NativeSourceColorSamplingStage', 'NativeObservedSourcePalette', 'NativeCaptionSourcePalette',
    'NativeForcedComponentRestoration', 'NativeForcedSourceInpainting', 'NativeConnectedLettering',
    'NativeFinalRestorationTrial', 'NativeDeferredForcedRestoration', 'NativeRendererSourcePosition',
    'NativePartialSourceProof', 'NativeCSSCoveragePath', 'NativeTranslationSourceStylePostPolish', 'NativeCandidateResidualCompletion',
    'NativePanelGeometry', 'NativeKeptSourceRestoration', 'NativeMinimalRestoredPlate', 'NativeEnclosedPaperFinish',
    'NativeTranslationRenderer+MinimalPlates', 'NativeTranslationTypography', 'NativeSourceOutlineScan',
    'NativeSourceOutlineEvidence', 'NativeCaptionPacking', 'NativeTranslationEffectGloss', 'NativeTranslationGlossPlacement', 'NativeDisplayLetteringPixels', 'NativeDisplayLetteringBW',
    'NativeDisplayLetteringBWFinish', 'NativeDisplayLetteringBWFill', 'NativeDisplayLetteringTrial', 'NativeDisplayLetteringStage']
sources = {OVERLAY / (name + '.swift') for name in names}
for pattern in ['NativeRestoration*.swift', 'NativeObservedRestore*.swift', 'NativeObservedRestoration*.swift',
                'NativeResidual*.swift', 'NativeSlanted*.swift']:
    sources.update(OVERLAY.glob(pattern))
sources.add(OVERLAY / 'NativeTranslationRenderer+DisplayLettering.swift')
sources.update([OVERLAY / 'NativeGlyphCover.swift', OVERLAY / 'NativeTranslationRenderer+GlyphCover.swift'])
developer = Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip())
frameworks = developer / 'Platforms/MacOSX.platform/Developer/Library/Frameworks'
macro = developer / 'Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib'
subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-strict-concurrency=complete',
    '-I', 'Scripts/overlay-kernels/native', '-L', 'build/native-overlay-kernels-host', '-lAidokuOverlayKernels',
    '-F', str(frameworks), '-load-plugin-library', str(macro), *map(str, [models, shims] + sorted(sources) + [renderer_transport, tests, entry]),
    '-Xlinker', '-rpath', '-Xlinker', str(frameworks), '-o', str(OUTPUT / 'tests')], check=True, cwd=ROOT)
run = subprocess.run([str(OUTPUT / 'tests')], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, cwd=ROOT)
(OUTPUT / 'tests.log').write_text(run.stdout)
print(run.stdout, end='')
passed = run.returncode == 0 and 'Test run with 4 tests' in run.stdout
(OUTPUT / 'report.json').write_text(json.dumps({'passed': passed, 'tests': 4,
    'scope': 'Actual unchanged GlyphCover app test bodies and production Card/adapter/source-reader. Only fixture bundle transport and UIKit entrypoints excluded. '
             'Host-only UIKit edge-inset transport and actual geometry validation; app import removed.',
    'sourceSHA256': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                     for p in sorted(sources) + [test_source, position_source, kept_source, minimal_source, display_source, OVERLAY / 'NativeTranslationRenderer.swift']}}, indent=2))
raise SystemExit(0 if passed else 1)
