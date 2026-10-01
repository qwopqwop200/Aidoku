"""Pinned source evidence; no rendering, noise synthesis, or capture mutation."""
import hashlib,json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
OUT=ROOT/'build/native-render-parity/foreign-background-gradient';SRC=OUT/'primary-source'
COMMIT='dd5fe1011df7e3438ac4889356abcab7681df46d'
paths={
'GradientCG.cpp':'platform/graphics/cg/GradientCG.cpp',
'GradientRendererCG.cpp':'platform/graphics/cg/GradientRendererCG.cpp',
'GradientRendererCG.h':'platform/graphics/cg/GradientRendererCG.h',
'Gradient.cpp':'platform/graphics/Gradient.cpp',
'GradientImage.cpp':'platform/graphics/GradientImage.cpp',
'CSSGradientValue.cpp':'css/CSSGradientValue.cpp',
'StyleGradientImage.cpp':'rendering/style/StyleGradientImage.cpp',
'StyleGradient.cpp':'style/values/images/StyleGradient.cpp',
'CSSGradient.cpp':'css/values/images/CSSGradient.cpp',
'CSSPropertyParserConsumer+Image.cpp':'css/parser/CSSPropertyParserConsumer+Image.cpp'}
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
sources={name:dict(url=f'https://github.com/WebKit/WebKit/blob/{COMMIT}/Source/WebCore/{path}',sha256=sha(SRC/name)) for name,path in paths.items()}
audit=json.loads((OUT/'interior-audit.json').read_text())
assert all(r['base']['differentPixels']==0 for r in audit['cases'])
for r in audit['cases']:
 for layer in r['layers']:
  assert layer['maxChannelDifference']==1 and len(layer['nativePalette'])==1
  assert all(p['rgba'][3]==255 and all(abs(a-b)<=1 for a,b in zip(p['rgba'][:3],layer['expectedRGBA'][:3])) for p in layer['webPalette'])
report=dict(scope='Pinned source and immutable actual53 constant-gradient interiors; no app/test/build changes or fitted noise',sourceCommit=COMMIT,source=sources,interiorAuditSHA256=sha(OUT/'interior-audit.json'),
 contracts=[
 dict(file='CSSPropertyParserConsumer+Image.cpp',lines=[330,369],rule='Legacy integer rgb stops choose premultiplied sRGB unless an explicit interpolation method is provided'),
 dict(file='GradientRendererCG.cpp',lines=[399,425],rule='sRGB stops without missing components select CGGradient; opaque same-alpha stops also avoid shading on the older premultiplication fallback'),
 dict(file='GradientRendererCG.cpp',lines=[465,503],rule='Bounded sRGB stops resolve Float color components, promote to CGFloat, and use cached sRGB CGColorSpace'),
 dict(file='GradientRendererCG.cpp',lines=[530,532],rule='Construct CGGradient from components, with premultiplication options when the platform feature is available; public fallback has no options'),
 dict(file='GradientRendererCG.cpp',lines=[683,694],rule='CGGradient paints with CGContextDrawLinearGradient; alternative color spaces use an axial CGShading with a color callback'),
 dict(file='GradientCG.cpp',lines=[137,139],rule='Ordinary non-repeating gradient extends before the first and after the last location'),
 dict(file='GradientImage.cpp',lines=[43,53],rule='Direct gradient image draw clips the destination, maps the source into it, and fills the generator bounds'),
 dict(file='GradientImage.cpp',lines=[56,95],rule='Pattern drawing is a distinct aligned-image-buffer path; it must not be assumed for a direct no-repeat tile')],
 interpretation=[
 'Source contains no gradient dither or noise policy. Equal opaque endpoints are constant under ideal sRGB or any same-color interpolation.',
 'Observed spatial RGB variation within +/-1 is isolated to gradient interiors while opaque base interiors are exact; this is compatible with backend quantization/dithering but does not identify its algorithm.',
 'A source-correct public component CGGradient constructor is a bounded control. Equal opaque stops make premultiplication mathematically irrelevant, but public and private constructor backend identity remains unproven.',
 'A public on-screen UIView CGContext gradient and a CAGradientLayer gradient are useful backend controls; the latter is not the direct source CGContextDrawLinearGradient route.'],
 boundaries=['No explicit public CoreGraphics dither switch was identified by the source trace.','Do not replace captured gradients with fitted noise or color offsets.','CPU/mac controls do not establish actual iOS GPU behavior.','Actual iOS backend capture is required before any production correction.'])
(OUT/'source-report.json').write_text(json.dumps(report,indent=2))
print(json.dumps(dict(sourceFiles=len(sources),cases=len(audit['cases']),gradientInteriors=sum(len(r['layers']) for r in audit['cases']),allBaseInteriorsExact=True,allGradientInteriorMaxDifference=1),indent=2))
