import Foundation
import CoreGraphics
let records = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:"Scripts/native-render-parity/content-fit/captured-dom.json"))) as! [[String:Any]]
func unit(_ x:CGFloat)->CGFloat{CGFloat((Float(x)*64).rounded(.towardZero))/64}
for record in records {
 let a=record["a"] as! [String:Any], n=a["n"] as! Int
 let width=unit(CGFloat((a["width"] as! NSNumber).doubleValue)), height=unit(CGFloat((a["height"] as! NSNumber).doubleValue))
 let pad=unit(CGFloat((a["pad"] as! NSNumber).doubleValue)), pitch=floor(CGFloat((a["pitch"] as! NSNumber).doubleValue))
 let block=a["block"] as! Bool, hidden=a["hidden"] as! Bool
 let stack=CGFloat(n)*pitch, top=block ? pad : pad+unit((height-2*pad-stack)/2)
 let metrics=NativeTypographyPostPolish.layoutOverflowMetrics(box:CGSize(width:width,height:height),body:CGRect(x:pad,y:top,width:1,height:stack),trailingPadding:CGSize(width:pad,height:pad),block:block,clips:hidden)
 precondition(metrics.clientHeight==record["client"] as! Int && metrics.scrollHeight==record["scroll"] as! Int,"DOM scroll mismatch")
}
let data=try Data(contentsOf:URL(fileURLWithPath:"build/native-render-parity/verify-image-build30-snapshot/mixed-multiple-cards/web-layout.json"))
var item=try JSONDecoder().decode([NativeTranslationLayoutItem].self,from:data)[0]
let ratio=item.lineHeight/item.fontSize; item.fontSize=31.5;item.lineHeight=31.5*ratio
let used=NativeTypographyPostPolish.usedLayoutItem(item)
let style=NativeTranslationTypography.Style(fontScript:"korean",fontSize:item.fontSize,lineHeight:item.lineHeight,optimizesKoreanWrapping:false,balancesHorizontalLines:true)
let shaped=NativeTranslationTypography.layout(text:item.text,in:used.contentRect.size,style:style)
let metrics=NativeTypographyPostPolish.contentFitMetrics(item:item,typography:shaped)!
precondition(shaped.lineCount==2 && !shaped.fits && metrics.clientHeight==86 && metrics.scrollHeight==86 && NativeTypographyPostPolish.contentFits(item:item,typography:shaped))
print("Actual macOS WebKit160 scroll/client predicates pass; mixed font31.5 CoreText ink-fit false/CSS paddingbox fit true86/86")
