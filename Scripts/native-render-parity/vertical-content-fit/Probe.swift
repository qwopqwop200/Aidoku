import Foundation
import CoreGraphics
@main struct Probe {
 static func main() throws {
  let rows=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
  var out:[[String:Any]]=[]
  func unit(_ v:Double)->CGFloat {CGFloat((Float(v)*64).rounded(.towardZero))/64}
  for row in rows {
   let a=row["a"] as! [String:Any],f=a["font"] as! Double,p=a["pitch"] as! Double,text=a["text"] as! String,pads=a["pads"] as! [Double]
   let width=unit(a["width"] as! Double),height=unit(a["height"] as! Double)
   let content=CGSize(width:max(0,width-unit(pads[1])-unit(pads[3])),height:max(0,height-unit(pads[0])-unit(pads[2])))
   let style=NativeTranslationTypography.Style(fontScript:a["script"] as! String,fontSize:f,vertical:true,lineHeight:p,alignsToTop:a["balanced"] as! Bool,strictLineBreak:true)
   let layout=NativeTranslationTypography.layout(text:text,in:content,style:style)
   let advances=NativeTranslationTypography.verticalLineAdvances(layout:layout)
   let descriptor: [String: Any] = ["id":"probe","text":text,"width":a["width"]!,"height":a["height"]!,
       "fontSize":f,"lineHeight":p,"paddingTop":pads[0],"paddingRight":pads[1],"paddingBottom":pads[2],"paddingLeft":pads[3],
       "vertical":true,"clipsText":a["clips"]!,"balancedColumn":a["balanced"]!,"sourceBounds":[0,0,1,1],"sourceFrame":[0,0,1,1]]
   let item=try JSONDecoder().decode(NativeTranslationLayoutItem.self,from:JSONSerialization.data(withJSONObject:descriptor))
   let metrics=NativeTypographyPostPolish.contentFitMetrics(item:item,typography:layout)!
   let chars=Array(layout.shapedText.utf16)
   let soft=layout.lineRanges.dropLast().contains {r in let end=r.location+r.length;return end>0 && end<=chars.count && chars[end-1] != 10 && chars[end-1] != 13}
   let advance=ceil((advances.max() ?? 0)*64)/64
   let inline=soft ? max(content.height,advance) : advance
   out.append(["metrics":[metrics.clientWidth,metrics.clientHeight,metrics.scrollWidth,metrics.scrollHeight],"columns":layout.lineCount,"advances":advances,"ranges":layout.lineRanges.map {[$0.location,$0.length]},"soft":soft,"inline":inline,"content":[content.width,content.height]])
  }
  try JSONSerialization.data(withJSONObject:out).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
 }
}
