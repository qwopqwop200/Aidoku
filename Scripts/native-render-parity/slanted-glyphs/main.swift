import Foundation
import CoreGraphics
let expected:[String:[CGFloat]] = [
 "가":[0,17.299999237060547,16.234375,1.578125],"나":[0,17.299999237060547,16.234375,1.578125],"다":[0,17.299999237060547,16.234375,1.578125],
 "A":[0,13,14.53125,0],"B":[0,12.420000076293945,14.53125,0],"C":[0,11.720000267028809,14.75,0],
 ".":[0,5.019999980926514,2.828125,0],",": [0,5.019999980926514,2.15625,1.875],"!":[0,5.579999923706055,15.046875,0],"?":[0,8.699999809265137,15.03125,0]]
var cases=0
for scale:CGFloat in [1,0.9] {for guardPixels:CGFloat in [1,0.25] {for (text,m) in expected {
 let style=NativeTranslationTypography.Style(fontScript:"korean",fontSize:20,optimizesKoreanWrapping:false,horizontalScale:scale)
 let layout=NativeTranslationTypography.layout(text:text,in:CGSize(width:180,height:40),style:style)
 let range=layout.rangeBounds[0]
 let actual=NativeTranslationTypography.slantedGlyphRects(layout:layout,style:style,guardPixels:guardPixels)[0]
 let baseline=range.minY+(range.height-24)/2+18
 let target=CGRect(x:range.minX-m[0]*scale-guardPixels*scale,y:baseline-m[2]-guardPixels,width:(m[0]+m[1]+2*guardPixels)*scale,height:m[2]+m[3]+2*guardPixels)
 let delta=max(abs(actual.minX-target.minX),abs(actual.minY-target.minY),abs(actual.width-target.width),abs(actual.height-target.height))
 precondition(delta<0.00001,"Canvas metric mismatch \(text) \(actual) \(target)")
 cases += 1
}}}
let style=NativeTranslationTypography.Style(fontScript:"korean",fontSize:20,optimizesKoreanWrapping:false,balancesHorizontalLines:true,balancesExplicitParagraphs:true)
let layout=NativeTranslationTypography.layout(text:"알림\n아름다운 우리 세상 함께 출발하자",in:CGSize(width:110,height:180),style:style)
var bodyStyle=style;bodyStyle.balancesExplicitParagraphs=false
let body=NativeTranslationTypography.layout(text:"아름다운 우리 세상 함께 출발하자",in:CGSize(width:110,height:180),style:bodyStyle)
precondition(layout.shapedText == "알림\n"+body.shapedText)
print("{\"cases\":\(cases),\"passed\":true,\"canvasMetricEvidence\":\"actual macOS WebKit scalar Canvas font bounds; DOM ranges separately audited against iOS; not slanted raster equality\",\"headingBalancesBodyIndependently\":true}")
