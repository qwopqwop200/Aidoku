import Foundation
import CoreGraphics
@main struct Probe { static func main() {
while let line=readLine() {
 let a=(try! JSONSerialization.jsonObject(with:Data(line.utf8))) as! [String:Any]
 let mode=a["mode"] as! String, text=a["text"] as! String, width=a["width"] as! Double
 let align=a["align"] as! String
 let style=NativeTranslationTypography.Style(fontScript:(a["script"] as? String) ?? "korean",fontSize:a["font"] as! Double,lineHeight:(a["font"] as! Double)*1.2,optimizesKoreanWrapping:false,
 usesBlockWordLayout:false,usesPreformattedBlockRows:true,blockWordLayoutUsesTopPadding:true,horizontalAlignment:align == "left" ? .left:align == "right" ? .right:.center)
 let available=CGSize(width:width,height:150)
 let shape=NativeTranslationTypography.layout(text:text,in:available,style:style)
 func box(_ r:CGRect)->[Double]{[r.minX,r.minY,r.width,r.height]}
 let whole=NativeTranslationTypography.wholeRangeBounds(layout:shape,style:style,available:available,preservesBlockWrapper:mode == "wrapper")
 print(String(data:try! JSONSerialization.data(withJSONObject:["whole":whole.map(box) ?? [],"text":shape.shapedText,"lines":NativeTranslationTypography.captionLineMetrics(layout:shape).map{box($0.rect)},"ranges":shape.lineRanges.map{[$0.location,$0.length]}]),encoding:.utf8)!)
}

}}
