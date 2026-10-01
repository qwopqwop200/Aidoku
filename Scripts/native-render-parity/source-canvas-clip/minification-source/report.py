"""Source-only backing-route evidence. Never samples or modifies capture pixels."""
from pathlib import Path
import json,hashlib
ROOT=Path(__file__).resolve().parents[4]
OUT=ROOT/'build/native-render-parity/source-canvas-minification';SRC=OUT/'primary-source'
ACTUAL=ROOT/'build/native-render-parity/verify-source-canvas-alpha-build48-snapshot'
COMMIT='dd5fe1011df7e3438ac4889356abcab7681df46d'
paths={'CanvasBase.cpp':'WebCore/html/CanvasBase.cpp','CanvasRenderingContext.cpp':'WebCore/html/canvas/CanvasRenderingContext.cpp',
'RenderLayerCompositor.cpp':'WebCore/rendering/RenderLayerCompositor.cpp','RenderLayerBacking.cpp':'WebCore/rendering/RenderLayerBacking.cpp',
'HTMLCanvasElement.cpp':'WebCore/html/HTMLCanvasElement.cpp','RenderHTMLCanvas.cpp':'WebCore/rendering/RenderHTMLCanvas.cpp',
'GraphicsContextCG.cpp':'WebCore/platform/graphics/cg/GraphicsContextCG.cpp','GraphicsContext.cpp':'WebCore/platform/graphics/GraphicsContext.cpp','ImageBuffer.cpp':'WebCore/platform/graphics/ImageBuffer.cpp',
'ImageBufferIOSurfaceBackend.cpp':'WebCore/platform/graphics/cg/ImageBufferIOSurfaceBackend.cpp',
'IOSurface.mm':'WebCore/platform/graphics/cocoa/IOSurface.mm','GraphicsLayerCA.cpp':'WebCore/platform/graphics/ca/GraphicsLayerCA.cpp',
'PlatformCALayerCocoa.mm':'WebCore/platform/graphics/ca/cocoa/PlatformCALayerCocoa.mm',
'RemoteLayerBackingStore.mm':'WebKit/Shared/RemoteLayerTree/RemoteLayerBackingStore.mm',
'WKWebView.mm':'WebKit/UIProcess/API/Cocoa/WKWebView.mm','WKWebViewIOS.mm':'WebKit/UIProcess/API/ios/WKWebViewIOS.mm',
'Settings.yaml':'WebCore/page/Settings.yaml','UnifiedWebPreferences.yaml':'WTF/Scripts/Preferences/UnifiedWebPreferences.yaml',
'ImageQualityController.cpp':'WebCore/rendering/ImageQualityController.cpp'}
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
source={n:dict(url=f'https://github.com/WebKit/WebKit/blob/{COMMIT}/Source/{path}',sha256=sha(SRC/n)) for n,path in paths.items()}
records=[]
for backing in ['transparent','opaque']:
 folder=ACTUAL/backing
 doc=json.loads((folder/'web-dom-and-saved-masks.json').read_text());viewport=json.loads((folder/'capture-viewport.json').read_text());capture=json.loads((folder/'web-live-320-capture.json').read_text())
 scale=capture['actualOutputScale'];assert scale==viewport['screenScale']==3
 for r in doc['records']:
  w,h=r['width'],r['height'];x,y,cw,ch=r['used'];pixels=[cw*scale,ch*scale]
  records.append(dict(backing=backing,id=r['id'],sourcePixels=[w,h],sourceArea=w*h,usedCSS=r['used'],screenRaster=[x*scale,y*scale,*pixels],
   scaleRatio=[pixels[0]/w,pixels[1]/h],minification=pixels[0]<w or pixels[1]<h,
   exceedsPinnedOwnLayerThreshold=w*h>=5000,predictedOwnPaintedLayerIfAccelerated=w*h>=5000,
   directImageContentsBranch=False,sourceIsUnscaledBitmap=False,
   sourcePNGHash=sha(folder/f'source-canvas-{r["id"]}.png'),sourceRGBAHash=sha(folder/f'source-canvas-{r["id"]}.rgba')))
report=dict(scope='Read-only pinned WebKit compositing/backing contract plus immutable actual48 canvas geometry; no observed runtime layer tree, no filter approximation, no app edits.',
 sourceCommit=COMMIT,source=source,records=records,
 rules=[dict(file='Settings.yaml',lines=[288,302],contract='minimumAccelerated2DContextArea default0 onCA; do not confuse with5000compositingthreshold'),
 dict(file='UnifiedWebPreferences.yaml',lines=[1874,1888],contract='CanvasUsesAcceleratedDrawing WebKitdefaulttrue'),
 dict(file='CanvasBase.cpp',lines=[279,329],contract='getContext2d defaultwillReadFrequentlyfalse permits accelerated ImageBuffer; resolutionScale1'),
 dict(file='CanvasRenderingContext.cpp',lines=[106,113],contract='CoreGraphics2DdoesnotdelegatesDisplay; Skiaonly2Ddelegates; GPUBased/placeholderseparate'),
 dict(file='RenderLayerBacking.cpp',lines=[125,137],contract='accelerated2D→CanvasPaintedToLayer; delegatesDisplayonly→CanvasAsLayerContents'),
 dict(file='RenderLayerCompositor.cpp',lines=[123,123,3891,3913],contract='iOSnormalpolicyCanvasPaintedToLayer forcedowncompositingwhenintrinsicarea>=5000'),
 dict(file='RenderLayerBacking.cpp',lines=[606,610],contract='An own HTML canvas layer enables accelerated drawing when canvas.shouldAccelerate is true, even if the compositor-wide accelerated drawing setting is false'),
 dict(file='RenderLayerBacking.cpp',lines=[935,952,3383,3421],contract='Linear/nearestcontentsfiltersetONLYCanvasAsLayerContents. CSSsize!=intrinsicsize meansunscaledBitmapOnlyfalse→appliesDeviceScaletrue'),
 dict(file='GraphicsLayerCA.cpp',lines=[4332,4352],contract='backingcontentsScale=pageScale*deviceScale*limitingFactor; image/video layercontentsfilterbranchisnot2Dpaint'),
 dict(file='RenderHTMLCanvas.cpp',lines=[78,103],contract='styleimageRenderingautomaintainscontextdefault; paintreplacedContentRect'),
 dict(file='HTMLCanvasElement.cpp',lines=[640,660],contract='nondelegated2D→context.drawImageBuffer atsnappedIntRect'),
 dict(file='ImageQualityController.cpp',lines=[104,117],contract='image-rendering:auto returns no interpolation override; inherited CGContext quality remains active'),
 dict(file='GraphicsContextCG.cpp',lines=[67,82,210,219,365,416,1387,1399],contract='Read inherited CG interpolation quality; on iOS disable image-edge antialiasing and round destination through user-to-device transform; translate and flip Y before CGContextDrawImage; full source bypasses subimage padding'),
 dict(file='GraphicsContext.cpp',lines=[364,390],contract='ImageBuffer native-image draw preserves optional interpolation settings and applies source resolutionScale'),
 dict(file='IOSurface.mm',lines=[490,496],contract='WebKitdrawcontextcreatedbyCGIOSurfaceContextCreate (privateSPI); notpublicbitmaprenderer'),
 dict(file='RemoteLayerBackingStore.mm',lines=[265,279,413,442],contract='remote layerstore uses8bitBGRA fortransparentSDR,paintsactualCALayercontentsthenserializesIOSurface'),
 dict(file='WKWebView.mm',lines=[1548,1570],contract='iOSsnapshotWidthmultipliedbydeviceScale; UIImage wrapperretainsDPR'),
 dict(file='WKWebViewIOS.mm',lines=[4573,4591],contract='parentedvisiblewindowlivebranchcallsCARenderServer intoIOSurface; renderInContext/customWebContentsnapshotbranchesdistinct')],
 conclusions=['Source predicts a real20x20 vs412x527ownlayerbranch undermatchingdefaults, not an inventedcanvas-size filter switch.',
 'DefaultCALayer.contentsMinificationFilter linear does not identify actual2DCGIOSurfaceimage kernel.',
 'A CPUCGBitmapContext draw ordirectCALayer.contents texture test does not exercise same2DCanvasPaintedToLayer route.',
 'Public native UIView/CALayerdelegate paint intoon-screenown91x121DPR3backing is a source-motivated diagnostic; exact pixel proof required before any production adoption.'],
 boundaries=['Runtimeactual48private layer/backingstrategywasnotcaptured; flags/sourcecommitcorrespondenceareconditions,notprovenprivateobjectstate.',
 'CGIOSurfaceminificationkernel andrender-servercompositorimplementationareclosedplatformcode; publicWebKitsource doesnot supplytapweights.',
 'No proposed fittedkernel,thresholdpixelrewrite,privateAPIshipping,orcompletedpixelparity claim.'])
(OUT/'source-route.json').write_text(json.dumps(report,indent=2))
print(json.dumps(dict(records=len(records),largeCanvasArea=412*527,largeCanvasScreenPixels=[91*3,121*3],sourceFiles=len(source),report=str((OUT/'source-route.json').relative_to(ROOT))),indent=2))
