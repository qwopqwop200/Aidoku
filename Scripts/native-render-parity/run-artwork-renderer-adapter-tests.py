#!/usr/bin/env python3
from pathlib import Path
import subprocess,re,json,hashlib,os
root=Path(__file__).resolve().parents[2]; o=root/'Aidoku/Core/Translation/NativeEngine/Overlay'; out=Path(os.environ.get('AIDOKU_RENDERER_ADAPTER_OUTPUT',root/'build/native-render-parity/artwork-adapter'));out.mkdir(parents=True,exist_ok=True)
layout=(o/'NativeTranslationLayout.swift').read_text(); (out/'Models.swift').write_text(layout.split('/// Actor confinement')[0].replace('import UIKit\n',''))
geometry=re.search(r'    static func validGeometry\([\s\S]*?\n    }',layout).group()
shim='import CoreGraphics\nstruct UIEdgeInsets {var top:CGFloat;var left:CGFloat;var bottom:CGFloat;var right:CGFloat}\nextension CGRect {func inset(by i:UIEdgeInsets)->CGRect {CGRect(x:minX+i.left,y:minY+i.top,width:width-i.left-i.right,height:height-i.top-i.bottom)}}\nenum NativeTranslationLayoutPlanner {\n'+geometry+'\n}\n';shim+='\nenum BrowserOverlayLayoutPlanner {static let minimumRenderedFontSize:Double=5}\n';settings=(root/'Aidoku/Core/Translation/ReaderTranslationSettings.swift').read_text(); default=re.search(r'    static let defaultOverlay = IPhoneOverlaySettings\([\s\S]*?\n    \)',settings).group();shim+='\nenum ReaderTranslationSettings {\n'+default+'\n}\n';(out/'Shims.swift').write_text(shim)
r=(o/'NativeTranslationRenderer.swift').read_text()
def fn(name):
 start=r.index('    static func '+name+'('); brace=r.index('{',start);depth=1; i=brace+1
 while depth:
  depth+=(r[i]=='{')-(r[i]=='}'); i+=1
 return r[start:i]
card=r[r.index('    struct TextPart {'):r.index('    struct GlossCard {')]
ink=fn('cardInkRect')
transport='import CoreGraphics\nimport Foundation\nenum NativeTranslationRenderer {\nstruct SourcePatch {let image:CGImage;let rect:CGRect}\n'+card+ink+'\n'+'\n'.join(fn(n) for n in ['rgb','color','panelForeground','rotatedBounds','cardPageLineRects','cardPageRangeRects','cardWholeRangeRect','cardScrollFits','usedLayoutItem','textPartFrame','pageRect','columnSourceErasureRects','remeasureTypography','sampleSource'])+'\n'+re.search(r'    static func valid\(_ rect: CGRect\)[\s\S]*?\n    }',r).group()+'\n}\n'
harmony=(o/'NativeTranslationRenderer+TypographyHarmony.swift').read_text()
start=harmony.index('    static func scaleTypographyHarmony(');brace=harmony.index('{',start);depth=1;i=brace+1
while depth:
 depth+=(harmony[i]=='{')-(harmony[i]=='}');i+=1
owner=harmony[harmony.index('    struct TypographyHarmonyOwner {'):harmony.index('    /// Frozen scaleTo/safeAt:')]
safe_start=harmony.index('    static func safeTypographyHarmony(');safe_brace=harmony.index('{',safe_start);depth=1;safe_end=safe_brace+1
while depth:
 depth+=(harmony[safe_end]=='{')-(harmony[safe_end]=='}');safe_end+=1
transport+='\nextension NativeTranslationRenderer {\n'+owner+harmony[start:i]+'\n'+harmony[safe_start:safe_end]+'\n}\n'
(out/'Transport.swift').write_text(transport)
names=['NativeTranslationRestoration','NativeSpatialSourceCrop','IPhoneOverlaySettings','NativeSourceGlyphSegmentation','NativeTranslationPixelKernels','NativeSourceColorSampler','NativeSourceColorSamplingStage','NativeObservedSourcePalette','NativeCaptionSourcePalette','NativeForcedComponentRestoration','NativeForcedSourceInpainting','NativeConnectedLettering','NativeFinalRestorationTrial','NativeDeferredForcedRestoration','NativeRendererSourcePosition','NativePartialSourceProof','NativeCSSCoveragePath', 'NativeTranslationSourceStylePostPolish','NativeCandidateResidualCompletion','NativePanelGeometry','NativeKeptSourceRestoration','NativeMinimalRestoredPlate','NativeTranslationTypography','NativeSourceOutlineScan','NativeSourceOutlineEvidence','NativeCaptionPacking','NativeTranslationEffectGloss','NativeTranslationGlossPlacement']
sources={o/(n+'.swift') for n in names}
for pattern in ['NativeRestoration*.swift','NativeObservedRestore*.swift','NativeObservedRestoration*.swift','NativeResidual*.swift','NativeSlanted*.swift']:sources.update(o.glob(pattern))
sources.add(o/'NativeTranslationRenderer+SlantedTrials.swift'); sources.add(o/'NativeSlantedQuadOutsideBox.swift')
sources.add(o/'NativeRawTextBalance.swift'); sources.update(o.glob('NativeKeepAll*.swift')); sources.add(o/'NativePreformattedTabs.swift'); sources.update(o.glob('NativeTypography*.swift')); sources.update(o.glob('NativeEarly*.swift')); sources.add(o/'NativeTranslationSurfacePool.swift'); sources.add(o/'NativeEnclosedPaperFinish.swift'); sources.add(o/'NativeSourceSurfaceGeometry.swift'); sources.add(o/'NativeTextPaintGeometry.swift')
sources.add(o/'NativeArtworkProtection.swift');sources.add(o/'NativeTranslationRenderer+ArtworkProtection.swift');sources.add(o/'NativeTranslationRenderer+CaptionOwnerGraph.swift');sources.add(o/'NativeTranslationRenderer+SourceAlignment.swift');sources.add(o/'NativeTranslationSourceAlignment.swift');sources.add(o/'NativeTranslationRenderer+RecoveredLines.swift');sources.add(o/'NativeRecoveredLineProtection.swift');sources.add(o/'NativeTypedArrayFill.swift');sources.add(o/'NativeVerticalContentFit.swift');sources.add(o/'NativeNormalTextFlow.swift');sources.add(o/'NativeCTFontStrokePainter.swift');sources.add(o/'NativeVerticalLetterSpacing.swift');sources.add(o/'NativeNormalBreakOpportunities.swift');sources.add(o/'NativePreLineTextFlow.swift');sources.add(o/'NativeVisibleControlGlyphs.swift')
staged=os.environ.get('AIDOKU_ARTWORK_POST_POLISH')
if staged: sources.discard(o/'NativeTypographyPostPolish.swift'); sources.add(Path(staged))
test_source=Path(os.environ.get('AIDOKU_RENDERER_ADAPTER_TEST_SOURCE',root/'AidokuTests/Translation/NativeArtworkProtectionTests.swift')).resolve()
if not test_source.exists():test_source=root/'Scripts/native-render-parity/NativeArtworkProtectionTests.swift'
test=out/'Tests.swift';test.write_text(test_source.read_text().replace('@testable import Aidoku\n',''))
entry=out/'Main.swift';entry.write_text('import Foundation\nimport Testing\n@main struct Main {static func main() async {exit(await Testing.__swiftPMEntryPoint())}}\n')
developer=Path(subprocess.check_output(['xcode-select','-p'],text=True).strip()); framework=developer/'Platforms/MacOSX.platform/Developer/Library/Frameworks';macro=developer/'Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib'
snapshot=out/'Sources';snapshot.mkdir(exist_ok=True)
source_hashes={str(f.relative_to(root)) if f.is_relative_to(root) else str(f):hashlib.sha256(f.read_bytes()).hexdigest() for f in sorted(sources)+[test_source,o/'NativeTranslationRenderer.swift',root/'Aidoku/Core/Translation/ReaderTranslationSettings.swift',o/'NativeTranslationRenderer+TypographyHarmony.swift']}
compiled=[]
for f in sorted(sources):
 copy=snapshot/f.name;copy.write_bytes(f.read_bytes());compiled.append(copy)
cmd=['xcrun','swiftc','-swift-version','6','-strict-concurrency=complete','-I','Scripts/overlay-kernels/native',str(out/'Models.swift'),str(out/'Shims.swift'),str(out/'Transport.swift'),*map(str,compiled),str(test),str(entry),'-L','build/native-overlay-kernels-host','-lAidokuOverlayKernels','-F',str(framework),'-load-plugin-library',str(macro),'-Xlinker','-rpath','-Xlinker',str(framework),'-o',str(out/'tests')]
p=subprocess.run(cmd,cwd=root,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True);(out/'typecheck.log').write_text(p.stdout);print(p.stdout);
if p.returncode==0:p=subprocess.run([str(out/'tests')],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True);(out/'tests.log').write_text(p.stdout);print(p.stdout)
(out/'report.json').write_text(json.dumps({'passed':p.returncode==0,'tests':len(re.findall(r'@Test',test_source.read_text())),'scope':'Actual normalized renderer adapters, CoreText scalar ranges, native source sampling and retained mask/surface session; actual Card/geometry/default settings extracted verbatim, UIEdgeInsets host transport only.', 'testSource':str(test_source.relative_to(root)),'sourceSHA256':source_hashes},indent=2))
raise SystemExit(p.returncode)
