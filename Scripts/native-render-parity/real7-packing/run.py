#!/usr/bin/env python3
"""Replay captured BUILD33 real7 card16 packing geometry using native CoreText.

This diagnoses the native preferred-cell admission, not original WebKit shaping
or whole-page raster parity. Color-policy stubs are uncalled and trap if reached.
"""
import hashlib,json,pathlib,subprocess
ROOT=pathlib.Path(__file__).resolve().parents[3]
HERE=pathlib.Path(__file__).resolve().parent
OUT=ROOT/'build/native-render-parity/real7-packing-admission'
SNAPSHOT=ROOT/'build/native-render-parity/verify-image-build33-snapshot/real-comic-0007'
SRC=ROOT/'Aidoku/Core/Translation/NativeEngine/Overlay'
OUT.mkdir(parents=True,exist_ok=True)
main=OUT/'main.swift';main.write_text((HERE/'Probe.swift').read_text())
sources=[HERE/'Stub.swift',SRC/'NativeCSSCoveragePath.swift',SRC/'NativePanelGeometry.swift',SRC/'NativeTextPaintGeometry.swift',SRC/'NativeTranslationTypography.swift',main]
subprocess.run(['xcrun','swiftc','-O',*[str(p) for p in sources],'-o',str(OUT/'probe')],check=True)
probes=json.loads(subprocess.check_output([str(OUT/'probe'),str(SNAPSHOT/'native-final-layout.json')]))
native=json.loads((SNAPSHOT/'native-final-layout.json').read_text())
card=next(c for c in native['cards'] if c['id']=='16')
captured=card['captionPacking']['probes'][0]
assert probes[0]['ink']==captured['ink']
assert not probes[0]['anchorAccepted'] and probes[0]['rightExcess']==.375
assert probes[1]['anchorAccepted'] and probes[1]['rightExcess']<0
report={
 'scope':'Native BUILD33 real7 card16 preferred-cell decision; actual captured source and neighbor inks, current macOS CoreText. Does not establish WebKit candidate metrics or complete pixel parity.',
 'capturedNativeProbe':captured,'nativePackingBefore':card['captionPacking'],
 'nativeCoreTextProbes':probes,
 'earliestNativeFailure':'source-anchor displacement guard before final Range containment; block width prevents a source anchor shift',
 'snapshotSHA256':hashlib.sha256((SNAPSHOT/'native-final-layout.json').read_bytes()).hexdigest(),
 'sourcesSHA256':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources if p.is_relative_to(ROOT)},
 'frozenContract':{'file':'Scripts/native-render-parity/reference-source/BrowserOverlayView.swift','prepareCaptionTextLines':[7557,7567],
  'sourceAnchorGuardLines':[7603,7619],'finalContainmentLines':[7620,7622],
  'preservesControlledChildren':'Only koreanLineLayout=word-aware with element children; otherwise textContent=item.text',
  'frozenCard16Final':'Raw text, no koreanLineLayout/sourceHeading marker. Marker deletion only accepted source heading10200; final font alone is not a packing-font observation.'},
 'upstreamLimit':'Need actual initial native/frozen word-aware admission trace to explain why quoteMode0 controlled rows were retained. Do not discard every controlled caption at packing.'}
(OUT/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'capturedInkExact':True,'firstAnchorAccepted':probes[0]['anchorAccepted'],'rawControlAnchorAccepted':probes[1]['anchorAccepted'],'report':str(OUT/'report.json')}))
