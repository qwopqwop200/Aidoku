import Foundation
import CoreGraphics
@main struct Preflight {
 static func main() throws {
  var style=NativeTranslationTypography.Style(fontScript:"korean",fontSize:15,lineHeight:18)
  style.optimizesKoreanWrapping=false;style.balancesHorizontalLines=false;style.balancesExplicitParagraphs=false;style.keepsWholeWords=false
  let initial=NativeTranslationTypography.layout(text:"카나반칙",in:CGSize(width:15,height:120),style:style)
  let before=NativeTranslationTypography.captionLineMetrics(layout:initial)
  guard before.count>=2 else {fatalError("Actual font did not produce the required syllable stack")}
  let whole=NativeTranslationTypography.koreanLines(text:"카나반칙",available:CGSize(width:200,height:120),style:style,maxLines:before.count)
  guard whole?.count==1 else {fatalError("Actual font could not recover the whole word")}
  let members=[CGRect(x:170,y:100,width:100,height:70),CGRect(x:170,y:270,width:100,height:70)]
  let entry=NativeBalloonUnitParts.Entry(id:"unit",text:"가나다 라마바 사아자 차카타 파하가 나다라",members:members,font:12,ratio:1.2,interiorSpan:500,isRoot:true,obstacles:[],panel:nil,coverage:[])
  let result=NativeBalloonUnitParts.place(entry,measure:{text,frame,font,pitch in
   var style=NativeTranslationTypography.Style(fontScript:"korean",fontSize:font,lineHeight:pitch)
   style.optimizesKoreanWrapping=false;style.keepsWholeWords=true
   let shaped=NativeTranslationTypography.layout(text:text,in:frame.size,style:style)
   let lines=NativeTranslationTypography.captionLineMetrics(layout:shaped).map{$0.rect.offsetBy(dx:frame.minX,dy:frame.minY)}
   let flow=NativeTranslationTypography.wordFlow(layout:shaped,originalText:text)
   return .init(lines:lines,scrollWidth:max(frame.width,shaped.size.width),clientWidth:frame.width,splits:flow.wordSplits>0)
  },outside:{rect in
   let inside=CGRect(x:0,y:0,width:500,height:500).intersection(rect)
   return rect.width*rect.height-(inside.isNull ? 0:inside.width*inside.height)
  })
  guard let result,result.font>12,result.parts.count==2,result.parts[0].frame.midY<result.parts[1].frame.midY else {fatalError("Actual font failed unit-part positive fixture")}
  let report:[String:Any]=["passed":true,"stackActualLineCount":before.count,"stackWholeWordLines":whole!.count,"unitParts":result.parts.count,"unitFont":result.font,"scope":"Actual Core Text preconditions and unit-part policy; iOS renderer adapter test execution is separate."]
  try JSONSerialization.data(withJSONObject:report,options:.sortedKeys).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
 }
}
