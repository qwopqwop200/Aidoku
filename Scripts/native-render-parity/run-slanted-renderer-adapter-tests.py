#!/usr/bin/env python3
from pathlib import Path
import subprocess,re,json,hashlib
root=Path(__file__).resolve().parents[2]; o=root/'Aidoku/Core/Translation/NativeEngine/Overlay'; out=root/'build/native-render-parity/slanted-adapter';out.mkdir(parents=True,exist_ok=True)
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
ink=r[r.index('    static func cardInkRect('):r.index('    private static func glossText(')]
transport='import CoreGraphics\nimport Foundation\nenum NativeTranslationRenderer {\nstruct SourcePatch {let image:CGImage;let rect:CGRect}\n'+card+ink+'\n'+'\n'.join(fn(n) for n in ['rgb','color','panelForeground','rotatedBounds','cardPageLineRects','cardPageRangeRects','textPartFrame'])+'\n}\n'
(out/'Transport.swift').write_text(transport)
names=['NativeTextPaintGeometry','NativeSourceSurfaceGeometry','NativeEnclosedPaperFinish','NativeTranslationRestoration','NativeSpatialSourceCrop','IPhoneOverlaySettings','NativeSourceGlyphSegmentation','NativeTranslationPixelKernels','NativeSourceColorSampler','NativeSourceColorSamplingStage','NativeObservedSourcePalette','NativeCaptionSourcePalette','NativeForcedComponentRestoration','NativeForcedSourceInpainting','NativeConnectedLettering','NativeFinalRestorationTrial','NativeDeferredForcedRestoration','NativeRendererSourcePosition','NativePartialSourceProof','NativeCSSCoveragePath', 'NativeTranslationSourceStylePostPolish','NativeCandidateResidualCompletion','NativePanelGeometry','NativeKeptSourceRestoration','NativeMinimalRestoredPlate','NativeTranslationTypography','NativeSourceOutlineScan','NativeSourceOutlineEvidence','NativeCaptionPacking','NativeTranslationEffectGloss','NativeTranslationGlossPlacement']
sources={o/(n+'.swift') for n in names}
for pattern in ['NativeRestoration*.swift','NativeObservedRestore*.swift','NativeObservedRestoration*.swift','NativeResidual*.swift','NativeSlanted*.swift']:sources.update(o.glob(pattern))
sources.add(o/'NativeTranslationRenderer+SlantedTrials.swift'); sources.add(o/'NativeSlantedQuadOutsideBox.swift')
test_source=root/'AidokuTests/Translation/NativeSlantedRendererAdapterTests.swift'
if not test_source.exists():test_source=root/'Scripts/native-render-parity/NativeSlantedRendererAdapterTests.swift'
test=out/'Tests.swift';test.write_text(test_source.read_text().replace('@testable import Aidoku\n',''))
entry=out/'Main.swift';entry.write_text('import Foundation\nimport Testing\n@main struct Main {static func main() async {exit(await Testing.__swiftPMEntryPoint())}}\n')
developer=Path(subprocess.check_output(['xcode-select','-p'],text=True).strip()); framework=developer/'Platforms/MacOSX.platform/Developer/Library/Frameworks';macro=developer/'Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib'
snapshot=out/'source';snapshot.mkdir(exist_ok=True)
captured_sources=[];captured_hashes={}
for f in sorted(sources):
 raw=f.read_bytes();target=snapshot/f.name;target.write_bytes(raw);captured_sources.append(target)
 captured_hashes[str(f.relative_to(root))]=hashlib.sha256(raw).hexdigest()
captured_hashes[str(test_source.relative_to(root))]=hashlib.sha256(test_source.read_bytes()).hexdigest()
captured_hashes[str((o/'NativeTranslationRenderer.swift').relative_to(root))]=hashlib.sha256(r.encode()).hexdigest()
cmd=['xcrun','swiftc','-swift-version','6','-strict-concurrency=complete','-I','Scripts/overlay-kernels/native',str(out/'Models.swift'),str(out/'Shims.swift'),str(out/'Transport.swift'),*map(str,captured_sources),str(test),str(entry),'-L','build/native-overlay-kernels-host','-lAidokuOverlayKernels','-F',str(framework),'-load-plugin-library',str(macro),'-Xlinker','-rpath','-Xlinker',str(framework),'-o',str(out/'tests')]
p=subprocess.run(cmd,cwd=root,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True);(out/'typecheck.log').write_text(p.stdout);print(p.stdout);
if p.returncode==0:p=subprocess.run([str(out/'tests')],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True);(out/'tests.log').write_text(p.stdout);print(p.stdout)
(out/'report.json').write_text(json.dumps({'passed':p.returncode==0,'tests':3,'scope':'Actual CoreText native typography, production SlantedContext admissions/commit/clipping with original source proof raster; renderer Card and geometry helpers extracted verbatim; host UIEdgeInsets transport only. No injected shaping or safety callbacks.','sourceSHA256':captured_hashes},indent=2))
raise SystemExit(p.returncode)
