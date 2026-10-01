#!/usr/bin/env python3
"""Run the actual cleanup-frame compositor regression with production CoreText and geometry."""
import hashlib
import os
import json
import re
import subprocess
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / 'build/native-render-parity/source-column-anchor-tests'
expected_tests = 1
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
test_source = ROOT / 'AidokuTests/Translation/NativeEngine/NativeSourceColumnAnchorTests.swift'
tests = OUTPUT / test_source.name
tests.write_text(test_source.read_text().replace('@testable import Aidoku\n', ''))
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
owner_graph = (OVERLAY / 'NativeTranslationRenderer+CaptionOwnerGraph.swift').read_text()
owner_transport = re.search(r'    struct CaptionParentOwner[\s\S]*?\n    }', owner_graph).group()
card = renderer[renderer.index('    struct TextPart {'):renderer.index('    struct GlossCard {')]
paintorder = (OVERLAY / 'NativeTranslationRenderer+PaintOrder.swift').read_text()
root_append = '\n'.join(re.search(r'    static func '+name+r'\([\s\S]*?\n    }',paintorder).group() for name in ['nextRootOrder','appendTextToRoot'])
def method(name):
    return re.search(r'    static func '+name+r'\([\s\S]*?\n    }', renderer).group()
ink = '\n'.join(method(name) for name in ['pageRect', 'cardPageLineRects', 'polishFinalGeometry', 'cardContentFits', 'cardInkRect', 'cardPageRangeRects', 'textPartFrame', 'rotatedBounds', 'remeasureTypography', 'color', 'usedLayoutItem', 'rgb', 'cardSurfaceEvidence', 'panelMeetsInk', 'applySourceStyles'])
cohort = (OVERLAY / 'NativeTranslationRenderer+DisplayStyleCohort.swift').read_text()
metadata = cohort[cohort.index('    struct DisplayCohortMetadata {'):cohort.index('    struct DisplayCohortDiagnostic {')]

glyphcover = (OVERLAY / 'NativeTranslationRenderer+GlyphCover.swift').read_text()
ink += '\n' + re.search(r'    static func readabilityOwnerPanel\([\s\S]*?\n    }', glyphcover).group()
postpolish = (OVERLAY / 'NativeTypographyPostPolish.swift').read_text()
source_evidence = OUTPUT / 'NativeSurfaceEvidenceTransport.swift'
source_evidence.write_text('import Foundation\nimport CoreGraphics\nenum NativeTypographyPostPolish {\n' +
    postpolish[postpolish.index('    struct SurfaceEvidence {'):postpolish.index('    struct Candidate {', postpolish.index('    struct SurfaceEvidence {'))] + '\n}\n')
renderer_transport = OUTPUT / 'NativeRendererTransport.swift'
renderer_transport.write_text('import Foundation\nimport CoreGraphics\nenum NativeTranslationRenderer {\n'
    'struct SourcePatch { let image:CGImage; let rect:CGRect }\n' + owner_transport + '\n' + card + ink + '\n' + root_append + '\n' + metadata + '}\n')
display_source = ROOT / 'AidokuTests/Translation/NativeEngine/NativeDisplayLetteringRestorationTests.swift'
if not display_source.exists(): display_source = ROOT / 'build/native-display-lettering/NativeDisplayLetteringRestorationTests.swift'
display_tests = OUTPUT / display_source.name
display_tests.write_text(display_source.read_text().replace('@testable import Aidoku\n', ''))
unit_source = ROOT / 'AidokuTests/Translation/NativeEngine/NativeRestorationUnitInteriorTests.swift'
unit_tests = OUTPUT / unit_source.name
unit_tests.write_text(unit_source.read_text().replace('@testable import Aidoku\n', ''))
entry = OUTPUT / 'Main.swift' 
entry.write_text('import Foundation\nimport Testing\n'
    '@main struct HostTests { static func main() async { exit(await Testing.__swiftPMEntryPoint()) } }\n')
names = ['NativeTranslationRestoration', 'NativeSpatialSourceCrop', 'IPhoneOverlaySettings',
    'NativeSourceGlyphSegmentation', 'NativeTranslationPixelKernels', 'NativeSourceColorSampler',
    'NativeSourceColorSamplingStage', 'NativeObservedSourcePalette', 'NativeCaptionSourcePalette',
    'NativeForcedComponentRestoration', 'NativeForcedSourceInpainting', 'NativeConnectedLettering',
    'NativeTypedArrayFill', 'NativeFinalRestorationTrial', 'NativeDeferredForcedRestoration', 'NativeRendererSourcePosition',
    'NativePartialSourceProof', 'NativeCSSCoveragePath', 'NativeTranslationSourceStylePostPolish', 'NativeCandidateResidualCompletion',
    'NativeSourceSurfaceGeometry', 'NativePanelGeometry', 'NativeKeptSourceRestoration', 'NativeMinimalRestoredPlate', 'NativeEnclosedPaperFinish',
    'NativeTranslationRenderer+MinimalPlates', 'NativeVerticalContentFit', 'NativeTextPaintGeometry', 'NativeTranslationTypography', 'NativeSourceOutlineScan',
    'NativeSourceOutlineEvidence', 'NativeCaptionPacking', 'NativeTranslationEffectGloss', 'NativeTranslationGlossPlacement', 'NativeDisplayLetteringPixels', 'NativeDisplayLetteringBW',
    'NativeDisplayLetteringBWFinish', 'NativeDisplayLetteringBWFill', 'NativeDisplayLetteringTrial', 'NativeDisplayLetteringStage', 'NativeTranslationFinalRenderingHelpers', 'NativeTranslationFinalGeometry']
sources = {OVERLAY / (name + '.swift') for name in names}
for pattern in ['NativeRestoration*.swift', 'NativeObservedRestore*.swift', 'NativeObservedRestoration*.swift',
                'NativeResidual*.swift', 'NativeSlanted*.swift']:
    sources.update(OVERLAY.glob(pattern))
sources.add(OVERLAY / 'NativeTranslationRenderer+DisplayLettering.swift')
for name in ['NativeEarlyPlateContrast', 'NativeTranslationRenderer+EarlyPlateContrast']:
    path = OVERLAY / (name + '.swift')
    sources.add(path if path.exists() else ROOT / 'build/native-early-plate-contrast' / path.name)
sources.add(source_evidence)
early_source = ROOT / 'AidokuTests/Translation/NativeEngine/NativeEarlyPlateContrastTests.swift'
if not early_source.exists(): early_source = ROOT / 'build/native-early-plate-contrast/NativeEarlyPlateContrastTests.swift'
early_tests = OUTPUT / early_source.name
early_tests.write_text(early_source.read_text().replace('@testable import Aidoku\n', ''))
developer = Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip())
frameworks = developer / 'Platforms/MacOSX.platform/Developer/Library/Frameworks'
macro = developer / 'Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib'
snapshot = OUTPUT / 'source-snapshot'
snapshot.mkdir(exist_ok=True)
captured_hashes = {}
frozen_sources = []
for source in sorted(sources):
    target = snapshot / source.name
    shutil.copyfile(source, target)
    captured_hashes[str(source.relative_to(ROOT))] = hashlib.sha256(target.read_bytes()).hexdigest()
    frozen_sources.append(target)
subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-strict-concurrency=complete',
    '-I', 'Scripts/overlay-kernels/native', '-L', 'build/native-overlay-kernels-host', '-lAidokuOverlayKernels',
    '-F', str(frameworks), '-load-plugin-library', str(macro), *map(str, [models, shims] + frozen_sources + [renderer_transport, tests, entry]),
    '-Xlinker', '-rpath', '-Xlinker', str(frameworks), '-o', str(OUTPUT / 'tests')], check=True, cwd=ROOT)
run = subprocess.run([str(OUTPUT / 'tests')], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, cwd=ROOT)
(OUTPUT / 'tests.log').write_text(run.stdout)
print(run.stdout, end='')
passed = run.returncode == 0 and f'Test run with {expected_tests} test' in run.stdout
(OUTPUT / 'report.json').write_text(json.dumps({'passed': passed, 'tests': expected_tests,
    'scope': 'Unchanged app numeric cleanup-frame regression using production Card, polishPanelGeometry, CoreText and geometry. '
             'Host-only UIKit edge-inset transport; unrelated drawing excluded and app import removed.',
    'capturedCompiledSourceSHA256': captured_hashes,
    'sourceSHA256': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                     for p in sorted(sources) + [test_source, position_source, kept_source, minimal_source, display_source, OVERLAY / 'NativeTranslationRenderer.swift']}}, indent=2))
raise SystemExit(0 if passed else 1)
