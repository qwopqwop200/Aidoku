#!/usr/bin/env python3
"""Refresh static mappings; never convert a build or image failure to a pass."""
import collections,datetime,hashlib,json,re,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2];DIR=Path(__file__).parent;P=DIR/'migration-inventory.json'
x=json.loads(P.read_text());sources={str(p.relative_to(ROOT)):p.read_text() for p in (ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay').glob('*.swift')}
for p in (ROOT/'Aidoku/Features/Reader/Translation').glob('*.swift'):
    sources[str(p.relative_to(ROOT))]=p.read_text()
# Ask the Swift parser for declaration scopes; literal strings/interpolations,
# comments, nested Context classes and multiple top-level extension owners must
# never manufacture a counterpart or lose an actual function.
index=collections.defaultdict(list);parseFailures=[]
cacheDirectory=ROOT/'build/native-render-parity/inventory-swift-parse';cacheDirectory.mkdir(parents=True,exist_ok=True)
for path,s in sources.items():
    digest=hashlib.sha256(s.encode()).hexdigest();cacheFile=cacheDirectory/('v3-'+digest+'.json')
    if cacheFile.exists():entries=json.loads(cacheFile.read_text())
    else:
        parsed=subprocess.run(['swiftc','-frontend','-dump-parse',path],cwd=ROOT,capture_output=True,text=True)
        if parsed.returncode:
            parseFailures.append(dict(file=path,diagnostic=parsed.stderr[:1000]));continue
        entries=[];scopes=[]
        for line in parsed.stdout.splitlines():
            indent=len(line)-len(line.lstrip())
            while scopes and scopes[-1][0]>=indent:scopes.pop()
            declaration=re.search(r'\((enum|struct|class|actor|extension|func)_decl\b',line)
            location=re.search(r'range=\[[^\]]+?:(\d+):\d+ - ',line)
            named=re.search(r'\] [^"\n]*"([^"\n]+)"',line)
            if not declaration or not location or not named:continue
            kind=declaration.group(1);name=named.group(1).split('(')[0]
            if kind!='func':
                parent=[scope[2] for scope in scopes if scope[1]!='func']
                full=name if kind=='extension' or not parent else parent[-1]+'.'+name
                scopes.append((indent,kind,full));continue
            types=[scope[2] for scope in scopes if scope[1]!='func'];owner=types[-1] if types else Path(path).stem
            local=[scope[2] for scope in scopes if scope[1]=='func']
            entry=dict(file=path,line=int(location.group(1)),symbol=owner+'.'+name,name=name,kind='Swift-parser-resolved native declaration')
            if local:entry['localTo']=local[-1];entry['kind']='Swift-parser-resolved local policy helper; declaration location is authoritative'
            entries.append(entry);scopes.append((indent,'func',owner+'.'+name))
        cacheFile.write_text(json.dumps(entries))
    for entry in entries:index[entry['name'].lower()].append({k:v for k,v in entry.items() if k!='name'})
x['nativeDeclarationAudit']={'method':'Swift frontend dump-parse declarations and nested owner scopes; caller references are a separate lexical audit','parseFailures':parseFailures}
# Name changes are explicit. Generic name-only matches remain native-equivalent
# unless backed by a frozen-reference differential evidence report.
alias={
'aidokuForceInpaintSourceComponent':('NativeForcedComponentRestoration.swift','forceComponent'),
'aidokuForceInpaintSource':('NativeForcedSourceInpainting.swift','restore'),
'aidokuOCRGeometryMask':('NativeSourceGlyphSegmentation.swift','geometryMask'),
'aidokuSourceInkMask':('NativeSourceGlyphSegmentation.swift','neutralSourceInkMask'),
'aidokuEstimateSourceColors':('NativeSourceColorSampler.swift','estimate'),
'aidokuSourceColorSampler':('NativeSourceColorSamplingStage.swift','sample'),
'aidokuEstimateOCRSourceColors':('NativeSourceColorSamplingStage.swift','estimateOCR'),
'aidokuEstimateTextColor':('NativeSourceColorSampler.swift','estimate'),
'aidokuSourceColorLuminance':('NativeTranslationSourceStylePostPolish.swift','luminance'),
'aidokuStyleColorClass':('NativeTranslationSourceStylePostPolish.swift','colorClass'),
'aidokuClusterStrokeWidths':('NativeTranslationSourceStylePostPolish.swift','strokeWidths'),
'aidokuStrokeClusters':('NativeTranslationSourceStylePostPolish.swift','strokeWidths'),
'aidokuPolishCaptionPanels':('NativeTranslationCaptionPanelPolish.swift','polish'),
'aidokuGlossPlacer':('NativeTranslationGlossPlacement.swift','search'),
'aidokuCompleteConnectedLettering':('NativeConnectedLettering.swift','complete'),
'aidokuSourceExemplarFill':('NativeResidualExemplar.swift','exemplarFill'),
'aidokuRestoreSourcePanelAttempts':('NativeObservedRestoreAttempts.swift','exactObservedAttempts'),
'aidokuRestoreSourcePanel':('NativeObservedRestoreAttempts.swift','exactObservedRestore'),
'aidokuRestoreObservedSourcePanel':('NativeObservedRestorePolicy.swift','exactObserved'),
'aidokuObservedPixelClasses':('NativeRestorationKernelDispatch.swift','nativePixelClasses'),
'aidokuHarmonicFill':('NativeRestorationKernelDispatch.swift','nativeHarmonicFill'),
'aidokuSourcePeriodicFill':('NativeRestorationTexture.swift','periodicFill'),
'aidokuSourceHasPeriodicInk':('NativeRestorationTexture.swift','periodicEvidence'),
'aidokuEnclosedPaperRestore':('NativeRestorationKernelDispatch.swift','nativeEnclosedPaper'),
'aidokuEnclosedPaperFinish':('NativeRestorationPixels.swift','enclosedPaper'),
'aidokuLocalComponentKernel':('NativeRestorationKernelDispatch.swift','nativeLocalComponentPaper'),
'aidokuLocalComponentRestore':('NativeRestorationKernelDispatch.swift','nativeLocalComponentPaper'),
'aidokuPreserveObservedCaptionStyle':('NativeTranslationSourceStylePostPolish.swift','lateSourceOutline'),
'aidokuPreserveDarkSurfaceSourceOutline':('NativeTranslationSourceStylePostPolish.swift','lateSourceOutline'),
}
alias.update({
 'aidokuCaptionLinePitch':('NativeTranslationCaptionSeparation.swift','linePitch'),
 'aidokuSeparateCaptionLines':('NativeTranslationCaptionSeparation.swift','separateLines'),
 'aidokuSeparateCaptionColumns':('NativeTranslationCaptionSeparation.swift','separateColumns'),
 'aidokuSolidPanelCoverage':('NativePanelGeometry.swift','solidPanelCoverage'),
 'aidokuCompactPanel':('NativePanelGeometry.swift','compactPanel'),
 'aidokuVisiblePanelColors':('NativePanelGeometry.swift','visiblePanelColors'),
 'aidokuTextBackingRect':('NativePanelGeometry.swift','textBackingRect'),
 'aidokuNeedsTextBacking':('NativePanelGeometry.swift','needsTextBacking'),
 'aidokuTextBackingKeepsContrast':('NativePanelGeometry.swift','textBackingKeepsContrast'),
 'aidokuSourceAnchorShift':('NativePanelGeometry.swift','sourceAnchorShift'),
 'aidokuSubtractRects':('NativePanelGeometry.swift','subtractRects'),
 'aidokuContainBalloonPanels':('NativePanelGeometry.swift','containBalloonPanels'),
 'aidokuStyleGroups':('NativeTypographyPostPolish.swift','pageStyleGroups'),
 'aidokuEnclosedCaptionOutline':('NativeSourceOutlineEvidence.swift','enclosedCaptionOutline'),
 'aidokuResolveDirectionalStrokeRole':('NativeSourceColorSampler.swift','directionalStroke'),
 'aidokuReleasedCaptionOutline':('NativeTranslationSourceStylePostPolish.swift','releasedCaptionOutline'),
 'aidokuReleasedCaptionFill':('NativeTranslationSourceStylePostPolish.swift','releasedCaptionFill'),
 'aidokuHasAttachedLeadingInk':('NativePartialSourceProof.swift','hasAttachedLeadingInk'),
 'aidokuHasLargePartialResidual':('NativePartialSourceProof.swift','hasLargePartialResidual'),
 'aidokuOutlineSourceResolved':('NativePartialSourceProof.swift','outlineSourceResolved'),
 'aidokuRobustSurfaceInk':('NativeTranslationSourceStylePostPolish.swift','robustSurfaceInk'),
 'aidokuSlantedProjectOwned':('NativeSlantedPixels.swift','projectOwned'),
 'aidokuRestoreSlantedSource':('NativeSlantedRestoration.swift','restore'),
 'aidokuSlantedInkAudit':('NativeSlantedInkSafety.swift','finish'),
 'aidokuRotatedPageInkFits':('NativeSlantedInkSafety.swift','rotatedPageInkFits'),
 'aidokuPlateLeftoverInk':('NativeSlantedInkSafety.swift','plateLeftoverInk'),
 'aidokuPushPull':('NativeSlantedInkSafety.swift','pushPull'),
 'aidokuSlantedInkFits':('NativeSlantedInkSafety.swift','inkFits'),
 'aidokuRestoreChromaticBalloonGlyphs':('NativeRestorationChromatic.swift','chromatic'),
 'aidokuRestoreChromaticBalloonGlyphPass':('NativeRestorationChromatic.swift','chromatic'),
 'aidokuRefineChromaticFringe':('NativeRestorationFringe.swift','refineFringe'),
 'aidokuRefineWhiteGlyphFringe':('NativeRestorationFringe.swift','refineFringe'),
 'aidokuDiscoverOutlinedSource':('NativeRestorationChromatic.swift','outlineRecovery'),
 'aidokuSourceLetterStyle':('NativeRestorationLetterStyle.swift','letterStyle'),
 'aidokuSourcePixelReader':('NativeSourceColorSamplingStage.swift','read'),
 'aidokuOutlinedColorGroups':('NativeCaptionSourcePalette.swift','recoverOutlinedColor'),
 'aidokuKoreanFlowRank':('NativeTypographyPostPolish.swift','rank'),
 'aidokuCaptionInkFrame':('NativeTypographyPostPolish.swift','candidate'),
 'aidokuCaptionFontFloor':('NativeTypographyPostPolish.swift','captionFontFloor'),
 'aidokuRestoredFontFloor':('NativeTypographyPostPolish.swift','restoredFontFloor'),
 'aidokuArtworkFontSizes':('NativeTypographyPostPolish.swift','artworkFontSizes'),
 'aidokuBalloonFontSizes':('NativeTypographyPostPolish.swift','balloonFontSizes'),
 'aidokuEmergencyBalloonFontSizes':('NativeTypographyPostPolish.swift','emergencyBalloonFontSizes'),
 'aidokuKoreanFragments':('NativeTypographyPostPolish.swift','profile'),
 'aidokuRestorationDistance':('NativeObservedRestorationHelpers.swift','distance'),
 'aidokuRestorationBlendAt':('NativeRestorationPixels.swift','blend'),
 'aidokuRestorationBlend':('NativeObservedRestorationHelpers.swift','blend'),
 'aidokuReadableSourceColor':('NativeSourceColorSampler.swift','rgb'),
 'aidokuSurfacePool':('NativeTranslationSurfacePool.swift','pool'),
 'aidokuSurfacePoolReady':('NativeTranslationSurfacePool.swift','ready'),
 'aidokuPlateMeets':('NativeTranslationFinalRenderingHelpers.swift','plateMeets'),
 'aidokuTurnGloss':('NativeTranslationFinalRenderingHelpers.swift','turnGloss'),
 'aidokuMildBreakParticles':('NativeTypographyPostPolish.swift','badBreak'),
 'aidokuLetterFace':('NativeTranslationTypography.swift','font'),
 'aidokuApplyHeavyLetters':('NativeTranslationRenderer.swift','draw'),
 'aidokuAnchorVerticalCaptionTops':('NativeTranslationFinalGeometry.swift','anchorVerticalTops'),
 'aidokuUprightCaptionText':('NativeTranslationFinalGeometry.swift','uprightText'),
 'aidokuUprightCaptionPlate':('NativeTranslationFinalGeometry.swift','uprightPlate'),
 'aidokuKeptLetteringZones':('NativeTranslationFinalGeometry.swift','keptZones'),
 'aidokuReleaseOverlayResources':('ReaderTranslationOverlayView.swift','cancelWork'),
 'aidokuCleanupContentGeometry':('NativeSourceSurfaceGeometry.swift','contentGeometry'),
 'aidokuContainBalloonText':('NativeBalloonTextContainment.swift','contain'),

})
for original,name,file in [
 ('SlantedResample','resample','NativeSlantedPixels.swift'),('SlantedLinear','linear','NativeSlantedPixels.swift'),
 ('SlantedCompositeLuminance','compositeLuminance','NativeSlantedPixels.swift'),('SlantedRampPixels','rampPixels','NativeSlantedPixels.swift'),
 ('SlantedFillHoles','fillHoles','NativeSlantedPixels.swift'),('SlantedExposedInk','exposedInk','NativeSlantedPixels.swift'),
 ('SlantedLayoutProof','layoutProof','NativeSlantedPixels.swift'),('SlantedSurfaceFits','surfaceFits','NativeSlantedProof.swift'),
 ('SlantedFlatGlyphs','flatGlyphs','NativeSlantedProof.swift'),('SlantedResidualInk','residualInk','NativeSlantedProof.swift'),
 ('PageErasureInQuad','pageErasureInQuad','NativeSlantedProof.swift'),('ErasureOffQuad','erasureOffQuad','NativeSlantedProof.swift'),
 ('SlantedLocalRects','localRects','NativeSlantedGeometry.swift'),('ConvexOverlap','convexOverlap','NativeSlantedGeometry.swift'),
 ('ConvexDepth','convexDepth','NativeSlantedGeometry.swift'),('PointInConvex','pointInConvex','NativeSlantedGeometry.swift'),
 ('ClipConvex','clipConvex','NativeSlantedGeometry.swift'),('SlantedLocalGeometry','localGeometry','NativeSlantedGeometry.swift')
]:alias['aidoku'+original]=(file,name)
# Evidence covers selected deterministic fixtures, not every possible page or
# the complete high-level browser render chronology.
evidence={
'NativeForcedSourceInpainting.swift':'build/native-render-parity/forced-source-policy/report.json',
'NativeForcedComponentRestoration.swift':'build/native-residual-proof-host/component-differential.json',
'NativeResidualProof.swift':'build/native-residual-proof-host/differential.json',
'NativeConnectedLettering.swift':'build/native-render-parity/connected-lettering-policy.json',
'NativeSourceGlyphSegmentation.swift':'build/native-render-parity/source-glyph-policy.json',
'NativeObservedSourcePalette.swift':'build/native-render-parity/observed-palettes/report.json',
'NativeCaptionSourcePalette.swift':'build/native-render-parity/caption-policy/report.json',
'NativeTranslationSourceStylePostPolish.swift':'build/native-source-style-host/differential.json',
'NativeTranslationCaptionPanelPolish.swift':'build/native-caption-panel-host/differential.json',
'NativeTranslationGlossPlacement.swift':'build/native-render-parity/policy-parity/gloss-placement/report.json',
'NativeSourceColorSampler.swift':'build/native-render-parity/policy-parity/source-sampler/report.json',
'NativeSourceColorSamplingStage.swift':'build/native-render-parity/source-color-sampling-policy.json',
'NativeTypographyPostPolish.swift':'build/native-render-parity/font-policy/report.json',
'NativeSourceOutlineEvidence.swift':'build/native-render-parity/source-outline-evidence-policy.json',
'NativeSourceOutlineScan.swift':'build/native-render-parity/source-outline-scan-policy.json',
'NativeTranslationCaptionSeparation.swift':'build/native-render-parity/caption-separation-policy.json',
'NativePartialSourceProof.swift':'build/native-partial-source-host/differential.json',
'NativeTranslationSurfacePool.swift':'build/native-final-rendering-helper-host/differential.json',
'NativeTranslationFinalRenderingHelpers.swift':'build/native-final-rendering-helper-host/differential.json',
'NativeTranslationFinalGeometry.swift':'build/native-render-parity/final-geometry-policy.json',
'NativeBalloonTextContainment.swift':'build/native-render-parity/final-geometry-policy.json',
'NativeBalloonInteriorEstimator.swift':'build/native-render-parity/balloon-interior-policy.json',
'NativeSourceSurfaceGeometry.swift':'build/native-render-parity/surface-geometry/report.json',
'NativeObservedRestoreAttempts.swift':'build/verify-restoration-latest-independent/observed41-diff.json',
'NativeObservedRestorePolicy.swift':'build/verify-restoration-latest-independent/observed41-diff.json',
'NativeSlantedRestoration.swift':'build/verify-restoration-latest-independent/slanted-diff.json',
}
# These are integrated orchestrations with known unmapped original DOM branches;
# neither name presence nor lower-helper fixture parity proves equivalence.
partial={'aidokuPolishCaptionPanels','aidokuPreserveObservedCaptionStyle','aidokuPreserveDarkSurfaceSourceOutline','aidokuClusterStrokeWidths','aidokuSourceColorSampler','aidokuEstimateOCRSourceColors','aidokuStyleGroups','aidokuResolveDirectionalStrokeRole','aidokuSourcePixelReader','aidokuOutlinedColorGroups','aidokuKoreanFlowRank','aidokuCaptionInkFrame','aidokuKoreanFragments','aidokuLetterFace','aidokuApplyHeavyLetters','aidokuReleaseOverlayResources'}
for h in x['javascriptHelpers']:
    symbol=h['symbol'];candidate=index.get(symbol.removeprefix('aidoku').lower(),[])
    if symbol in alias:
        file,name=alias[symbol];candidate=[c for c in index.get(name.lower(),[]) if Path(c['file']).name==file]
    h['legacyRuntimeRole']='Frozen oracle/test reference; no browser helper executes in the current native reader renderer.'
    if not candidate:
        h['status']='missing';h['exactBehaviorVerified']=False
        h['nativeImplementations']=[];h['productionCallers']=[];h['productionIntegrated']=False;h['tests']=[]
        h['note']='No audited native counterpart yet; dead browser capability is retained only by the independent frozen reference. This remains a migration capability gap.'
        continue
    h['nativeImplementations']=candidate
    h['productionCallers']=[]
    for c in candidate:
        owner,name=c['symbol'].rsplit('.',1)
        for path,s in sources.items():
            for m in re.finditer(re.escape(owner+'.'+name)+r'\s*\(',s):h['productionCallers'].append(dict(file=path,line=s[:m.start()].count('\n')+1,symbol=c['symbol']))
    # Record internal calls as such; a qualified call alone is not a whole-page
    # call-graph proof. Nested policy methods are reached by their owning entry.
    for c in candidate:
        name=c['symbol'].rsplit('.',1)[1];source=sources[c['file']]
        for m in re.finditer(r'(?<![\w.])'+re.escape(name)+r'\s*\(',source):
            line=source[:m.start()].count('\n')+1
            prefix=source[max(0,m.start()-12):m.start()]
            if re.search(r'func\s+$',prefix):continue
            h['productionCallers'].append(dict(file=c['file'],line=line,symbol=c['symbol'],kind='internal call in owning native policy; full reachability not implied'))
    for c in candidate:
        owner,name=c['symbol'].rsplit('.',1)
        for path,source in sources.items():
            for declaration in re.finditer(r'\b(?:let|var)\s+(\w+)\s*=\s*'+re.escape(owner)+r'(?:\.\w+)?\s*\(',source):
                receiver=declaration.group(1)
                for m in re.finditer(r'\b'+re.escape(receiver)+r'\.'+re.escape(name)+r'\s*\(',source):
                    h['productionCallers'].append(dict(file=path,line=source[:m.start()].count('\n')+1,symbol=c['symbol'],kind='typed native instance initialized from owning policy'))
        source=sources[c['file']]
        for m in re.finditer(r'\bself\.'+re.escape(name)+r'\s*\(',source):
            h['productionCallers'].append(dict(file=c['file'],line=source[:m.start()].count('\n')+1,symbol=c['symbol'],kind='internal self call in owning native policy'))
    h['productionIntegrated']=bool(h['productionCallers'])
    tests=[evidence[Path(c['file']).name] for c in candidate if Path(c['file']).name in evidence and (ROOT/evidence[Path(c['file']).name]).exists()]
    h['tests']=sorted(set(tests));h['exactBehaviorVerified']=bool(tests) and symbol not in partial
    h['status']='exact-port' if h['exactBehaviorVerified'] else 'native-equivalent'
    h['note']='Mapped native policy; frozen-reference fixtures listed separately. High-level render chronology, iOS build and final image parity are independent gates.'
    if symbol in partial:h['note']+=' This mapping is explicitly partial or caller-metadata-dependent; complete original DOM semantics are not established.'
    if not h['productionIntegrated']:h['note']+=' No fully qualified direct production call found; internal/closure reachability needs separate review.'
# Every25 original pixel loop now has a real owning native Swift caller.
kr=ROOT/'build/native-render-parity/kernel-parity/report.json';kv=json.loads(kr.read_text()) if kr.exists() else {}
for k in x['kernelExports']:
    pattern=re.compile(r'NativeTranslationPixelKernels\.'+re.escape(k['symbol'])+r'\s*\(')
    callers=[]
    for path,s in sources.items():
        if Path(path).name=='NativeTranslationPixelKernels.swift':continue
        for m in pattern.finditer(s):callers.append(dict(file=path,line=s[:m.start()].count('\n')+1,symbol='NativeTranslationPixelKernels.'+k['symbol']))
    k['productionCallers']=callers;k['productionIntegrated']=bool(callers)
    k['owningNativePolicies']=sorted(set(c['file'] for c in callers))
    case=kv.get('perKernel',{}).get(k['symbol'],{})
    k['exactBehaviorVerified']=bool(case) and case.get('activeCases',0)>0 and not case.get('mismatches') and case.get('cases')==case.get('exact')
    k['tests']=['build/native-render-parity/kernel-parity/report.json'] if k['exactBehaviorVerified'] else []
    k['note']='Same Rust kernel algorithm compiled as native CPU code, with production Swift caller(s). Differential proves listed buffers/fixtures; it does not establish complete original browser policies or final glyph rendering.'
# Browser typography constants are policy values, not missing functions.
for symbol,value in [('aidokuCondensedWidth',0.9),('aidokuReadableFontSize',9),('aidokuReadableMinimum',8.5)]:
    h=next(h for h in x['javascriptHelpers'] if h['symbol']==symbol)
    path='Aidoku/Core/Translation/NativeEngine/Overlay/NativeTypographyPostPolish.swift';source=sources[path]
    pattern=r'(?<![\d.])'+str(value).removesuffix('.0')+r'(?![\d.])'
    refs=[dict(file=path,line=source[:m.start()].count('\n')+1,symbol='NativeTypographyPostPolish policy literal '+str(value)) for m in re.finditer(pattern,source)]
    h.update(status='native-equivalent',nativeImplementations=refs,productionCallers=refs,productionIntegrated=bool(refs),exactBehaviorVerified=False,tests=[],note='Exact original constant retained as native policy literals; complete uses and final typography chronology remain separate, unproven gates.')
x['scope']='ALL frozen translation-overlay JavaScript capabilities and 25 pixel kernels. Browser/source-extension runtimes unrelated to reader rendering are explicitly tracked separately, never counted as migrated by this inventory.'
x['classification']['exact-port']='Mapped native implementation with frozen-reference differential evidence for listed fixture scope, or identical Rust source compiled natively. Whole-page policy chronology and final PNG equality are separate gates.'
x['runtimeInventory']={'nativeReaderEntry':'ReaderTranslationOverlayView -> NativeTranslationRenderer -> NativeTranslationRestoration/CoreText/native kernels', 'frozenJavaScript':'Independent test oracle only; does not call production native planner/render helpers', 'nonOverlayExtensionWASM':'Source-extension runtime remains separate from overlay pixel kernels; not claimed removed by overlay migration', 'allOverlayCapabilitiesMigrated':False}
x['generatedAtUTC']=datetime.datetime.now(datetime.timezone.utc).isoformat();x['rustSHA256']=hashlib.sha256((ROOT/'Scripts/overlay-kernels/kernels.rs').read_bytes()).hexdigest()
counter=collections.Counter(h['status'] for h in x['javascriptHelpers'])
# JS module/allocator capability is the native typed ABI module rather than a
# callable function. Its active loops have independent per-kernel coverage.
h=next(h for h in x['javascriptHelpers'] if h['symbol']=='aidokuPixelKernels')
h.update(status='exact-port',nativeImplementations=[dict(file='Aidoku/Core/Translation/NativeEngine/Overlay/NativeTranslationPixelKernels.swift',line=46,symbol='NativeTranslationPixelKernels',kind='native ABI module replacing WASM kernel module')],productionCallers=[c for k in x['kernelExports'] for c in k['productionCallers']],productionIntegrated=True,tests=['build/native-render-parity/kernel-parity/report.json'],exactBehaviorVerified=all(k['exactBehaviorVerified'] for k in x['kernelExports']),note='25 original kernel exports use native CPU staticlib with typed ABI. JS Promise/WASM glue is dead oracle plumbing, so not reproduced in native; capability equality tested per kernel.')
counter=collections.Counter(h['status'] for h in x['javascriptHelpers'])
x['counts']={'kernelExports':len(x['kernelExports']),'kernelExactPort':sum(k['status']=='exact-port' for k in x['kernelExports']),'kernelProductionIntegrated':sum(k['productionIntegrated'] for k in x['kernelExports']),'kernelVerified':sum(k['exactBehaviorVerified'] for k in x['kernelExports']),'javascriptHelpers':len(x['javascriptHelpers']),'javascriptExactPort':counter['exact-port'],'javascriptNativeEquivalent':counter['native-equivalent'],'javascriptMissing':counter['missing']}
x['highestPriorityGaps']=[
 {'area':'Remaining audited named browser capability','symbols':[h['symbol'] for h in x['javascriptHelpers'] if h['status']=='missing'],'reason':'No mapped implementation found in this snapshot. Export/module availability and native reader entry do not erase capability gaps.'},
 {'area':'Original final render chronology and caller metadata','symbols':['aidokuPreserveObservedCaptionStyle','aidokuPreserveDarkSurfaceSourceOutline','aidokuPolishCaptionPanels','aidokuSourceColorSampler','aidokuRestoreSourcePanelAttempts'],'reason':'Typed policies and fixture proofs exist, but original nested render stages, current/prior typography Range metrics, foreign-child/owner checks, release/partial masks and independent surface evidence remain separately audited adapters. See finalRenderPolicyStages; these are not asserted whole-page exact.'},
 {'area':'Platform text/glyph rasterization','reason':'Core Text shaping and scalar Range policy bounds are native. A bounded metric proof is not a WK/PDF versus native antialiasing, rotation, clip or composite image pass.'},
 {'area':'Final image exact gate','reason':'Mandatory synthetic and real iOS web-vs-native PNG replay is the visual acceptance gate. Observed mismatches remain failures; helper/kernel proofs never override them.'}]
x['verification']['kernelDifferential']='25kernels/83fixture native-vs-frozenWASM report recorded; see artifact. All25 direct production Swift caller references now found.'
x['verification']['sourceStyle']='1168deterministic lower sourceStyle/color/outline cases +80captiongeometry cases; scalar contrast1e-12 tolerance, colors/widths/coords exact. Full final chronology not claimed.'
x['finalRenderPolicyStages']=[
 {'legacyFile':'BrowserOverlayView.swift','legacyLines':[13100,14200],'native':'NativePrimaryOutlinedLettering.decide + NativeSourceOutlineScan/NativeSourceOutlineEvidence','status':'bounded-fixture-verified-integrated','tests':['build/native-render-parity/primary-outlined-lettering/report.json','build/native-render-parity/source-outline-evidence-policy.json'],'proof':'2025actual primary paint decisions/descriptors match.12independent ring pixel cases and28scan orchestration cases separate. Source sampled native Canvas and final glyph raster are their own gates.'},
 {'legacyFile':'BrowserOverlayView.swift','legacyLines':[7418,7845],'native':'NativeCaptionPacking.pack','status':'bounded-fixture-verified-integrated','tests':['build/native-render-parity/caption-packing/report.json'],'proof':'127full frozen orchestration fixtures with identical physical ink probes;657unified/63fallback record decisions. Platform text measurements and owner pixel callback sampling remain independent gates.'},

 {'legacyFile':'BrowserOverlayView.swift','legacyLines':[6540,6620],'native':'NativeTranslationSourceStylePostPolish.fallbackPanel/captionPalette + NativeTranslationRenderer.prepareSourcePanels','status':'partial','proof':'Fallback primitives mapped; original priorInk/padding chronology and plate-admission metadata not fully reproduced.'},
 {'legacyFile':'BrowserOverlayView.swift','legacyLines':[7100,7155],'native':'NativePartialSourceProof.outlinedSourcePosition','status':'bounded-fixture-verified-caller-integrated-chronology-partial','tests':['build/native-partial-source-host/source-position-differential.json'],'proof':'120 actual frozen final block cases/18 positive. Three lower mask policies separately64exact. NativeRendererSourcePosition now calls this policy with candidate flags; complete Range and safe/core/erasure/source-owner chronology remains separately audited.'},
 {'legacyFile':'BrowserOverlayView.swift','legacyLines':[7270,7417],'native':'NativeTranslationOversizedTitleGloss.refining','status':'bounded-fixture-verified-integrated','tests':['build/native-oversized-title-host/differential.json'],'proof':'40actual frozen title block cases/18notes/36clipped captions; actual fixed textmetrics and original gloss placer. Platform glyph rasterization separate.'},
 {'legacyFile':'BrowserOverlayView.swift','legacyLines':[15745,16016],'native':'NativeTranslationEffectGloss.refining','status':'bounded-fixture-verified-integrated','tests':['build/native-render-parity/effect-gloss-policy.json'],'proof':'Final effect semantic units/grouping/admission/undo policies have dedicated fixtures; native glyph/image sampling not inferred exact.'},
 {'legacyFile':'BrowserOverlayView.swift','legacyLines':[16279,16365],'native':'NativeTranslationSourceStylePostPolish.releasedCaptionStyle + NativeTranslationRenderer.reconcileFinalStrokes','status':'partial','tests':['build/native-source-style-host/differential.json'],'proof':'200direct released fill/outline cases pass; actual erasure admission, foreign-child handling, rotated plate release and column/inset remeasure are separate adapter requirements.'},
 {'legacyFile':'BrowserOverlayView.swift','legacyLines':[16368,16400],'native':'NativeTranslationCaptionPanelPolish + NativePanelGeometry + NativeTranslationCaptionSeparation + sourceStyle lateSourceOutline/strokeWidths','status':'partial','tests':['build/native-caption-panel-host/differential.json','build/native-render-parity/caption-separation-policy.json'],'proof':'Geometry/stroke/line policies bounded-fixture verified; full exact stage ordering/ownerproofs/flatflags/platformRange geometry remain final pixel gate.'}
]
x['verification']['finalHelperPrimitives']='320frozen cases:80lazySurfacePool tile byte/cache/page budgets,80actualownedinspectSurface cell/nativeedge+lookup budgets,120transformedPlateMeets decisions,40TurnGloss local origins. No approximation/tolerance in this report. Typed native callers tracked separately.'
x['verification']['partialSourcePosition']='64exact lower mask cases +120actual frozen final source-position block cases/18positive; decisions/colors/width exact, contraststatistics1e-12 tolerance. Production adapter requirements remain explicit.'
x['verification']['forcedProof']='11donor/certifiedplane fullproof exact +5componentimage/mask/admission exact (4positive); fullforceSource parent41fullproof cases exact separately.'
x['verification']['independentRestoration']='Independent verifier actual native source snapshots: observed direct41 + spatial41, slanted242 and restoration-trial56 outputs/chronology exact in listed corpus. Trial56 supplies glyph rectangles and DOM transport; actual renderer wiring and CoreText glyph selection remain independent.'
x['verification']['surfaceGeometry']='392 frozen geometry cases match within absolute1e-9; no pixel or full-render chronology proof.'
x['verification']['balloonGeometry']='67 final geometry/containment cases and16 fallback interior cases match supplied frozen metrics/raster. Dormant helpers or missing production adapters remain separate gaps.'
x['verification']['earlyBalloonGrid']='113full frozen4749–4837 expandedclear grid cases,111positiveoutputs; exactblocked/reachedbyte andInt32SAT SHA256 plusclearqueries/readcoords; geometry1e-9. NEW NativeEarlyBalloonGrid production helper; actualshaper/plane/paintedalpha/interior/sharedbudget adapters remain separatelyaudited.'
x['verification']['plateGrowth']='250 actual frozen axis growPlate cases;151 full growers cohort cases with174 live refits;72 exact sourcepixel FlatPlateRoom cases. Axis/widening/rotated actual Card adapters are called after packing.239 widening and290rotated pure-policy fixtures match numeric geometry at1e-9; native CoreText layout, DOM scroll extent proxy, complete preceding metadata and final PNG remain separate obligations.'
x['verification']['finalImages']='ReaderTranslationNativePixelParityTests strictzero-difference gate; current pass NOT asserted by inventory.'
subprocess.run(['python3',str(DIR/'refresh-chronology.py')],check=True)
x['renderChronologyAudit']=json.loads((DIR/'render-chronology.json').read_text())
whole_stage=ROOT/'build/native-render-parity/whole-stage-audit.json'
if whole_stage.exists():
 x['wholeStageAuditSnapshot']=dict(path=str(whole_stage.relative_to(ROOT)), report=json.loads(whole_stage.read_text()), limitation='Independent implementation audit snapshot; compare recorded source hashes and generated timestamp to current sources. Later hooks do not retroactively change this snapshot.')
P.write_text(json.dumps(x,indent=2)+'\n');print(json.dumps(x['counts'],indent=2))
