#!/usr/bin/env python3
import json, subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
HERE=Path(__file__).resolve().parent
OUT=ROOT/'build/native-render-parity/residual-completion';OUT.mkdir(parents=True,exist_ok=True)
OVERLAY=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay'
MODELS=ROOT/'build/native-render-parity/restoration-candidate-tests/NativeTranslationModels.swift'
SHIMS=MODELS.with_name('LayoutHostShims.swift')
names=['NativeTranslationRestoration','NativeSpatialSourceCrop','IPhoneOverlaySettings','NativeSourceGlyphSegmentation','NativeTranslationPixelKernels','NativeSourceColorSampler','NativeSourceColorSamplingStage','NativeObservedSourcePalette','NativeCaptionSourcePalette','NativeForcedComponentRestoration','NativeForcedSourceInpainting','NativeConnectedLettering','NativeFinalRestorationTrial','NativeDeferredForcedRestoration','NativeCandidateResidualCompletion','NativeCSSCoveragePath', 'NativeTranslationSourceStylePostPolish']
sources={OVERLAY/(n+'.swift') for n in names}
for glob in ['NativeRestoration*.swift','NativeObservedRestore*.swift','NativeObservedRestoration*.swift','NativeResidual*.swift','NativeSlanted*.swift']:sources.update(OVERLAY.glob(glob))
subprocess.run(['node',str(HERE/'capture.cjs'),str(ROOT),str(OUT/'fixtures.json')],check=True,cwd=ROOT)
subprocess.run(['xcrun','swiftc','-swift-version','6','-strict-concurrency=complete','-I','Scripts/overlay-kernels/native','-L','build/native-overlay-kernels-host','-lAidokuOverlayKernels',str(MODELS),str(SHIMS),*map(str,sorted(sources)),str(HERE/'Probe.swift'),'-o',str(OUT/'probe')],check=True,cwd=ROOT)
subprocess.run([str(OUT/'probe'),str(OUT/'fixtures.json'),str(OUT/'actual.json')],check=True,cwd=ROOT)
f=json.loads((OUT/'fixtures.json').read_text());a=json.loads((OUT/'actual.json').read_text());failed=[]
for fixture,actual in zip(f,a):
 if fixture['expected']!=actual:failed.append({'seed':fixture['seed'],'accepted':actual['accepted']})
r={'cases':len(f),'exact':len(f)-len(failed),'passed':not failed,'accepted':sum(v['accepted'] for v in a),'mismatches':failed}
(OUT/'report.json').write_text(json.dumps(r,indent=2));print(json.dumps(r));raise SystemExit(0 if not failed else 1)
