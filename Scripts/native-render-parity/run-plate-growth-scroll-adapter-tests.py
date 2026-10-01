#!/usr/bin/env python3
from pathlib import Path
import subprocess,re,json,hashlib,os
root=Path(__file__).resolve().parents[2]; o=root/'Aidoku/Core/Translation/NativeEngine/Overlay'; out=root/os.environ.get('AIDOKU_GROWTH_OUTPUT','build/native-render-parity/plate-growth-scroll-adapter');out.mkdir(parents=True,exist_ok=True)
layout=(o/'NativeTranslationLayout.swift').read_text(); (out/'Models.swift').write_text(layout.split('/// Actor confinement')[0].replace('import UIKit\n',''))
geometry=re.search(r'    static func validGeometry\([\s\S]*?\n    }',layout).group()
shim='import CoreGraphics\nstruct UIEdgeInsets {var top:CGFloat;var left:CGFloat;var bottom:CGFloat;var right:CGFloat}\nextension CGRect {func inset(by i:UIEdgeInsets)->CGRect {CGRect(x:minX+i.left,y:minY+i.top,width:width-i.left-i.right,height:height-i.top-i.bottom)}}\nenum NativeTranslationLayoutPlanner {\n'+geometry+'\n}\n';shim+='\nenum BrowserOverlayLayoutPlanner {static let minimumRenderedFontSize:Double=5}\n';(out/'Shims.swift').write_text(shim)
r=(o/'NativeTranslationRenderer.swift').read_text()
def fn(name):
 start=r.index('    static func '+name+'('); brace=r.index('{',start);depth=1; i=brace+1
 while depth:
  depth+=(r[i]=='{')-(r[i]=='}'); i+=1
 return r[start:i]
card=r[r.index('    struct TextPart {'):r.index('    struct GlossCard {')]
ink=r[r.index('    static func cardInkRect('):re.search(r'    (?:private )?static func glossText\(',r).start()]
transport='import CoreGraphics\nimport Foundation\nenum NativeTranslationRenderer {\nstruct SourcePatch {let image:CGImage;let rect:CGRect}\n'+card+ink+'\n'+'\n'.join(fn(n) for n in ['rgb','color','panelForeground','rotatedBounds','cardPageLineRects','cardPageRangeRects','cardWholeRangeRect','textPartFrame','pageRect','usedRect','usedLayoutItem','remeasureTypography','cardScrollFits'])+'\n}\n'
transport=transport[:-2]+'\n'+'\n'.join(re.findall(r'    static func valid\([\s\S]*?\n    }',r))+'\n}\n'
(out/'Transport.swift').write_text(transport)
names=['NativeTranslationRestoration','NativeSpatialSourceCrop','IPhoneOverlaySettings','NativeSourceGlyphSegmentation','NativeTranslationPixelKernels','NativeSourceColorSampler','NativeSourceColorSamplingStage','NativeObservedSourcePalette','NativeCaptionSourcePalette','NativeForcedComponentRestoration','NativeForcedSourceInpainting','NativeConnectedLettering','NativeFinalRestorationTrial','NativeDeferredForcedRestoration','NativeRendererSourcePosition','NativePartialSourceProof','NativeCSSCoveragePath', 'NativeTranslationSourceStylePostPolish','NativeCandidateResidualCompletion','NativePanelGeometry','NativeKeptSourceRestoration','NativeMinimalRestoredPlate','NativeTranslationTypography','NativeSourceOutlineScan','NativeSourceOutlineEvidence','NativeCaptionPacking','NativeTranslationEffectGloss','NativeTranslationGlossPlacement']
sources={o/(n+'.swift') for n in names}
for pattern in ['NativeRestoration*.swift','NativeObservedRestore*.swift','NativeObservedRestoration*.swift','NativeResidual*.swift','NativeSlanted*.swift']:sources.update(o.glob(pattern))
sources.add(o/'NativeTranslationRenderer+CaptionReflow.swift'); sources.add(o/'NativeTranslationRenderer+TextFrame.swift'); sources.add(o/'NativeCaptionFixedBoxReflow.swift'); sources.add(o/'NativeTranslationRenderer+SlantedTrials.swift'); sources.add(o/'NativeSlantedQuadOutsideBox.swift')
sources.add(o/'NativeCTFontVerticalPainter.swift'); sources.add(o/'NativeVerticalLetterSpacing.swift'); sources.add(o/'NativeCTFontStrokePainter.swift'); sources.update(o.glob('NativeNormal*.swift')); sources.add(o/'NativeRawTextBalance.swift'); sources.update(o.glob('NativeKeepAll*.swift')); sources.update(o.glob('NativePre*.swift')); sources.update(o.glob('NativeVisible*.swift')); sources.update(o.glob('NativeEarly*.swift')); sources.update(o.glob('NativeTypography*.swift')); sources.add(o/'NativeTranslationSurfacePool.swift'); sources.add(o/'NativeEnclosedPaperFinish.swift')
sources.add(o/'NativeTranslationRenderer+TypographyHarmony.swift'); sources.add(o/'NativeTranslationRenderer+CohortSnap.swift'); sources.add(o/'NativeTranslationRenderer+LateWordRepair.swift'); sources.add(o/'NativeLateWordRepair.swift'); sources.add(o/'NativeTranslationRenderer+PlateGrowth.swift'); sources.add(o/'NativeTranslationRenderer+PlateCoverage.swift'); sources.add(o/'NativeSourceSurfaceGeometry.swift'); sources.add(o/'NativeSourceInkCleanup.swift'); sources.add(o/'NativeTextPaintGeometry.swift'); sources.add(o/'NativeVerticalContentFit.swift'); sources.add(o/'NativeTypedArrayFill.swift'); sources.add(o/'NativeTranslationRenderer+CaptionOwnerGraph.swift')
# Current production dependencies of PlateGrowth/Restoration/Typography. Keep
# their actual implementations; the transport below only replaces app hosting.
for name in ['NativeTranslationRenderer+DisplayPeerCap', 'NativeClosedBalloonExclusion',
             'NativeObservedGlyphOwnership', 'NativeCTFontHorizontalFillPainter',
             'NativeCollapsedRowIntrinsicWidth', 'NativeDottedPaperFrame', 'NativeVerticalGlyphOrigins']:
    sources.add(o / (name + '.swift'))
growth_override=os.environ.get('AIDOKU_PLATE_GROWTH_SOURCE')
if growth_override: sources.discard(o/'NativeTranslationRenderer+PlateGrowth.swift'); sources.add(Path(growth_override))
staged=os.environ.get('AIDOKU_ARTWORK_POST_POLISH')
if staged: sources.discard(o/'NativeTypographyPostPolish.swift'); sources.add(Path(staged))
cohort_policy=os.environ.get('AIDOKU_COHORT_POLICY')
cohort_adapter=os.environ.get('AIDOKU_COHORT_ADAPTER')
if cohort_policy: sources.add(Path(cohort_policy))
if cohort_adapter: sources.add(Path(cohort_adapter))
test_source=Path(os.environ.get('AIDOKU_GROWTH_SCROLL_TEST',str(root/'AidokuTests/Translation/NativeEngine/NativePlateGrowthScrollTests.swift')))
assert test_source.exists()
test=out/'Tests.swift';test.write_text(test_source.read_text().replace('@testable import Aidoku\n',''))
metadata_source=root/'AidokuTests/Translation/NativeEngine/NativeForcedComponentMetadataTests.swift'
metadata_test=out/'MetadataTests.swift'; metadata_test.write_text(metadata_source.read_text().replace('@testable import Aidoku\n',''))
extra_tests=[]
extra_source=os.environ.get('AIDOKU_HARMONY_TEST')
if extra_source:
 extra=out/'HarmonyTests.swift'; extra.write_text(Path(extra_source).read_text().replace('@testable import Aidoku\n',''));extra_tests.append(extra)
entry=out/'Main.swift';entry.write_text('import Foundation\nimport Testing\n@main struct Main {static func main() async {exit(await Testing.__swiftPMEntryPoint())}}\n')
developer=Path(subprocess.check_output(['xcode-select','-p'],text=True).strip()); framework=developer/'Platforms/MacOSX.platform/Developer/Library/Frameworks';macro=developer/'Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib'
snapshot=out/'Sources';snapshot.mkdir(exist_ok=True)
source_hashes={str(f.relative_to(root)) if f.is_relative_to(root) else str(f):hashlib.sha256(f.read_bytes()).hexdigest() for f in sorted(sources)+[test_source,metadata_source,o/'NativeTranslationRenderer.swift']+([Path(extra_source)] if extra_source else [])}
compiled=[]
for f in sorted(sources):
 copy=snapshot/f.name;copy.write_bytes(f.read_bytes());compiled.append(copy)
cmd=['xcrun','swiftc','-swift-version','6','-strict-concurrency=complete','-I','Scripts/overlay-kernels/native',str(out/'Models.swift'),str(out/'Shims.swift'),str(out/'Transport.swift'),*map(str,compiled),str(test),str(metadata_test),*map(str,extra_tests),str(entry),'-L','build/native-overlay-kernels-host','-lAidokuOverlayKernels','-F',str(framework),'-load-plugin-library',str(macro),'-Xlinker','-rpath','-Xlinker',str(framework),'-o',str(out/'tests')]
if os.environ.get('AIDOKU_GROWTH_OPTIMIZE') == '1': cmd.insert(2,'-O')
if os.environ.get('AIDOKU_GROWTH_SEPARATE_MODULE') == '1':
 test.write_text(test_source.read_text()); metadata_test.write_text(metadata_source.read_text())
 if extra_source: extra_tests[0].write_text(Path(extra_source).read_text())
 modulecmd=['xcrun','swiftc','-O','-swift-version','6','-strict-concurrency=complete','-enable-testing','-emit-library','-emit-module','-module-name','Aidoku','-I','Scripts/overlay-kernels/native',str(out/'Models.swift'),str(out/'Shims.swift'),str(out/'Transport.swift'),*map(str,compiled),'-L','build/native-overlay-kernels-host','-lAidokuOverlayKernels','-emit-module-path',str(out/'Aidoku.swiftmodule'),'-o',str(out/'libAidoku.dylib')]
 if os.environ.get('AIDOKU_GROWTH_ASAN') == '1': modulecmd.insert(2,'-sanitize=address')
 module=subprocess.run(modulecmd,cwd=root,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
 (out/'module.log').write_text(module.stdout);print(module.stdout)
 if module.returncode:raise SystemExit(module.returncode)
 cmd=['xcrun','swiftc','-O','-swift-version','6','-I',str(out),'-I','Scripts/overlay-kernels/native',str(test),str(metadata_test),*map(str,extra_tests),str(entry),'-L',str(out),'-lAidoku','-F',str(framework),'-load-plugin-library',str(macro),'-Xlinker','-rpath','-Xlinker',str(framework),'-Xlinker','-rpath','-Xlinker',str(out),'-o',str(out/'tests')]
if os.environ.get('AIDOKU_GROWTH_DIRECT_DRIVER'):
 cmd=['xcrun','swiftc','-parse-as-library','-O','-swift-version','6','-I',str(out),'-I','Scripts/overlay-kernels/native',os.environ['AIDOKU_GROWTH_DIRECT_DRIVER'],'-L',str(out),'-lAidoku','-Xlinker','-rpath','-Xlinker',str(out),'-o',str(out/'tests')]
if os.environ.get('AIDOKU_GROWTH_ASAN') == '1': cmd.insert(2,'-sanitize=address')
p=subprocess.run(cmd,cwd=root,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True);(out/'typecheck.log').write_text(p.stdout);print(p.stdout);
if p.returncode==0:p=subprocess.run([str(out/'tests')],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True);(out/'tests.log').write_text(p.stdout);print(p.stdout)
driver_only=bool(os.environ.get('AIDOKU_GROWTH_DIRECT_DRIVER'))
observed_tests=re.search(r'Test run with (\d+) tests',p.stdout)
test_count=0 if driver_only or not observed_tests else int(observed_tests.group(1))
parameter_count=test_count+sum(int(n)-1 for n in re.findall(r'with (\d+) test cases passed',p.stdout))
artifact_hashes={f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in [out/'tests',out/'libAidoku.dylib',out/'Tests.swift',out/'MetadataTests.swift',out/'Transport.swift',out/'Models.swift',out/'tests.log'] if f.exists()}
scope=('Macro-free direct driver only: initial growth, capped refit, styleGlyph refit, rejected refit with original-state recovery, session close and closed-session rejection. No Swift Testing suite executed.' if driver_only else 'Actual production PlateGrowth and whole Harmony extensions compiled as actual Card/CoreText transport. Runtime coverage is limited to the selected supplied Swift Testing methods and parameter cases recorded in tests.log; helper compilation does not establish execution of other lifetime, budget, geometry or Harmony policies. Only unrelated UIKit painter excluded. Final PNG equality not inferred.')
(out/'report.json').write_text(json.dumps({'passed':p.returncode==0,'tests':test_count,'parameterCases':parameter_count,'driverOnly':driver_only,'optimizes':os.environ.get('AIDOKU_GROWTH_OPTIMIZE')=='1' or os.environ.get('AIDOKU_GROWTH_SEPARATE_MODULE')=='1','separateModules':os.environ.get('AIDOKU_GROWTH_SEPARATE_MODULE')=='1','sanitizer':'address' if os.environ.get('AIDOKU_GROWTH_ASAN')=='1' else None,'scope':scope,'sourceSHA256':source_hashes,'artifactSHA256':artifact_hashes},indent=2))
raise SystemExit(p.returncode)
