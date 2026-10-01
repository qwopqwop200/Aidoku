import Foundation
import AppKit
let snapshot=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [String:Any]
let cards=snapshot["cards"] as! [[String:Any]]
let a=snapshot["cleanupFrame"] as! [Double]
let frame=CGRect(x:a[0],y:a[1],width:a[2],height:a[3])
let c=cards.first{$0["id"] as? String=="16"}!
let b=c["sourceBounds"] as! [Double]
let source=CGRect(x:frame.minX+b[0]*frame.width,y:frame.minY+b[1]*frame.height,width:b[2]*frame.width,height:b[3]*frame.height)
func rect(_ a:[Double])->CGRect{CGRect(x:a[0],y:a[1],width:a[2],height:a[3])}
let old=rect((c["captionPacking"] as! [String:Any])["beforeInk"] as! [Double])
let obstacles=cards.filter{$0["id"] as? String != "16"}.compactMap{($0["captionPacking"] as? [String:Any])?["beforeInk"] as? [Double]}.map(rect)
let text="부, 부탁드립니다♡",controlled="부, \n부탁드립\n니다♡"
let cell=CGRect(x:0,y:375.0625,width:33.265625,height:73.4375)
var results:[[String:Any]]=[]
for font in [8.25,8.75] {
 for block in [true,false] {
  var style=NativeTranslationTypography.Style(fontScript:"korean",fontSize:font,tracking:-font*0.012,lineHeight:font*1.193359375,
   optimizesKoreanWrapping:false,balancesHorizontalLines:true,usesBlockWordLayout:block)
  style.koreanQuoteMode=0
  let shape=NativeTranslationTypography.layout(text:block ? controlled:text,in:CGSize(width:cell.width-6,height:cell.height-6),style:style)
  let ink=shape.rangeBounds.reduce(CGRect.null){$0.union($1)}.offsetBy(dx:cell.minX+3,dy:cell.minY+3)
  let row:[String:Any]=["font":font,"block":block,"text":shape.shapedText,"lineCount":shape.lineCount,"fits":shape.fits,
   "ink":[ink.minX,ink.minY,ink.width,ink.height],"allowedRight":cell.maxX-3+0.5,
   "rightExcess":ink.maxX-(cell.maxX-3+0.5)]
  var enriched=row
  let shift=NativePanelGeometry.sourceAnchorShift(ink,source:source,plate:cell,obstacles:obstacles)
  enriched["anchorAccepted"]=NativePanelGeometry.packingRetainsSourceAnchor(originalInk:old,proposedInk:ink,source:source,cell:cell,obstacles:obstacles)
  enriched["anchorShift"]=shift.map{[$0.x,$0.y]} as Any? ?? NSNull()
  enriched["source"]=[source.minX,source.minY,source.width,source.height]
  enriched["oldDistance"]=hypot(old.midX-source.midX,old.midY-source.midY)
  enriched["newDistance"]=hypot(ink.midX+(shift?.x ?? 0)-source.midX,ink.midY+(shift?.y ?? 0)-source.midY)
  enriched["anchorTolerance"]=max(4,min(8,min(source.width,source.height)*0.15))
  results.append(enriched)
 }
}
print(String(data:try JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
