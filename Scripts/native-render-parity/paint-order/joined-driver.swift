import Foundation
import CoreGraphics
func rect(_ a:[Double])->CGRect {CGRect(x:a[0],y:a[1],width:a[2],height:a[3])}
func box(_ r:CGRect)->[Double] {[Double(r.minX),Double(r.minY),Double(r.width),Double(r.height)]}
let rows=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
var outputs:[[String:Any]]=[]
for row in rows {
 let fs=row["font"] as! Double,ratio=1.2,span=row["span"] as! Double,text=row["text"] as! String
 let centers=(row["centres"] as! [[Double]]).map{CGPoint(x:$0[0],y:$0[1])},safe=rect(row["safe"] as! [Double])
 let obstacle=(row["obstacles"] as! [[Double]]).map(rect),parent=(row["parent"] as? [Double]).map(rect)
 func measure(_ c:NativeJoinedUnitContainment.Candidate)->NativeJoinedUnitContainment.Shape? {
  let words=text.split(separator:" ").map{Double($0.count)*c.font*0.55};var widths:[Double]=[],w=0.0
  for word in words {if w>0 && w+c.font*0.4+word>Double(c.rect.width) {widths.append(w);w=word} else{w = w == 0 ? word:w+c.font*0.4+word}}
  if w>0 {widths.append(w)}
  let total=Double(widths.count)*c.pitch,top=Double(c.rect.midY)-total/2
  let lines=widths.enumerated().map{CGRect(x:Double(c.rect.midX)-$0.element/2,y:top+Double($0.offset)*c.pitch,width:$0.element,height:c.font)}
  return .init(lines:lines,widthFits:widths.allSatisfy{$0<=Double(c.rect.width)+1},splitsWord:false)
 }
 func outside(_ r:CGRect)->Double {
  let x0=Int(floor(r.minX)),y0=Int(floor(r.minY)),x1=Int(ceil(r.maxX)),y1=Int(ceil(r.maxY));var n=0
  if x1<=x0 || y1<=y0{return 0}
  for y in y0..<y1 {for x in x0..<x1 {if CGFloat(x)<safe.minX || CGFloat(x)>=safe.maxX || CGFloat(y)<safe.minY || CGFloat(y)>=safe.maxY {n+=1}}};return Double(n)
 }
 let initial=NativeJoinedUnitContainment.Candidate(rect:rect(row["initial"] as! [Double]),font:fs,pitch:fs*ratio)
 let r=NativeJoinedUnitContainment.contain(.init(font:fs,pitch:fs*ratio,lines:measure(initial)!.lines,parentPlate:parent,span:span,centres:centers,canGrow:row["grow"] as! Bool,sourceFont:row["sourceFont"] as? Double,obstacles:obstacle),outside:outside,measure:measure)
 outputs.append(["candidate":r.candidate.map{["rect":box($0.rect),"font":$0.font,"pitch":$0.pitch] as [String:Any]} as Any? ?? NSNull(),"before":r.before,"after":r.after as Any? ?? NSNull(),"partial":r.partial,"searched":r.searched])
}
print(String(data:try JSONSerialization.data(withJSONObject:outputs,options:[.sortedKeys]),encoding:.utf8)!)
