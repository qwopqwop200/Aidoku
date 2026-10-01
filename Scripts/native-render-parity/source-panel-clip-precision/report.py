"""Pinned path-coordinate source report. No capture pixels are modified."""
from pathlib import Path
import hashlib,json
ROOT=Path(__file__).resolve().parents[3];OUT=ROOT/'build/native-render-parity/source-panel-clip-precision';SRC=OUT/'primary-source'
COMMIT='dd5fe1011df7e3438ac4889356abcab7681df46d'
paths={
'StylePathFunction.cpp':'style/values/shapes/StylePathFunction.cpp',
'RenderLayer.cpp':'rendering/RenderLayer.cpp',
'SVGPathParser.cpp':'svg/SVGPathParser.cpp',
'SVGPathBuilder.cpp':'svg/SVGPathBuilder.cpp',
'SVGPathStringViewSource.cpp':'svg/SVGPathStringViewSource.cpp',
'SVGPathUtilities.cpp':'svg/SVGPathUtilities.cpp',
'Path.cpp':'platform/graphics/Path.cpp',
'PathStream.cpp':'platform/graphics/PathStream.cpp',
'PathSegment.cpp':'platform/graphics/PathSegment.cpp',
'PathSegmentData.cpp':'platform/graphics/PathSegmentData.cpp',
'PathCG.cpp':'platform/graphics/cg/PathCG.cpp',
'AffineTransform.cpp':'platform/graphics/transforms/AffineTransform.cpp'}
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
control=ROOT/'build/native-render-parity/build54-panel7-clip'
report=dict(scope='Pinned CSS SVG path coordinate transport and independently authored public panel clip control; no app edits, fitted offsets, or universal rectangle rewrite',sourceCommit=COMMIT,
 source={n:dict(url=f'https://github.com/WebKit/WebKit/blob/{COMMIT}/Source/WebCore/{p}',sha256=sha(SRC/n)) for n,p in paths.items()},
 controlFiles={n:sha(control/n) for n in ['Main.swift','geometry.json','mode0.pdf','mode1.pdf','mode3.pdf','mode4.pdf']},
 stagedHelperSHA256=sha(ROOT/'Scripts/native-render-parity/source-panel-clip-precision/NativeSVGClipCoverage.staged.swift'),
 coordinateSequence=['Parse authored local M/H/V/H or M/h/v/h arguments into Float','Normalize relative commands in Float current-point state; preserve reverse-h accumulation','Snap the owner reference border, then narrow its origin to FloatPoint','Map every path vertex using Double affine arithmetic, then narrow each mapped point to Float','Convert mapped move/line/close segments into CGPath and CGContextClip'],
 actualAbsoluteControl=dict(original=[117.34375,240.125,33.84375,59.359375],snappedOrigin=[117.33333587646484,240],mappedRight=151.17709350585938,endpointWidth=33.84375762939453,observedPDFRect=[117.3333,187.6667,33.84376,59.33333],controlOwner='impl_restoration',mode0EdgeDifferentPixels=300,mode0EdgeMaxDifference=1,mode4EdgeDifferentPixels=0),
 boundaries=['CSSOM decimal serialization is not the original parser input','GraphicsContextCG has no explicit SVG-axis-rectangle optimization; PDF rectangle serialization is Quartz behavior','Absolute and relative command producers are not interchangeable at nonzero local origins','Actual producer provenance must be transported rather than inferred from stale styling markers','Selected edge ROI equality does not claim full-page or arbitrary live-path parity'])
(OUT/'source-report.json').write_text(json.dumps(report,indent=2))
print(json.dumps(dict(sourceFiles=len(paths),controlFiles=len(report['controlFiles']),report=str((OUT/'source-report.json').relative_to(ROOT))),indent=2))
