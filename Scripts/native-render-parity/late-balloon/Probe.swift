import Foundation
@main struct Probe {
 static func main() throws {
  let fixtures=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
  func box(_ a:[Double])->CGRect{.init(x:a[0],y:a[1],width:a[2],height:a[3])}
  var output:[Any]=[]
  for f in fixtures {
   let c=f["input"] as! [String:Any], type=f["type"] as! String
   if type=="floor" {
    let scroll=c["scroll"] as! [Double],after=box(c["after"] as! [Double])
    let r=NativeLateBalloonStages.readableFloor(font:c["font"] as! Double,pitch:c["pitch"] as! Double,before:box(c["before"] as! [Double]),frame:box(c["frame"] as! [Double]),neighbors:(c["neighbors"] as! [[Double]]).map(box)){_,_ in .init(ink:after,scrollWidth:scroll[0],clientWidth:scroll[1],scrollHeight:scroll[2],clientHeight:scroll[3])}
    output.append(r.map{["font":$0.font,"pitch":$0.pitch,"ink":c["after"]!] as [String:Any]} as Any? ?? NSNull())
   } else if type=="center" {
    let ink=box(c["ink"] as! [Double]),shape=box(c["shape"] as! [Double]),center=c["center"] as! [Double],drift=c["drift"] as! [Double]
    let r=NativeLateBalloonStages.centeredShift(ink:ink,center:.init(x:center[0],y:center[1]),font:c["font"] as! Double,parent:(c["parent"] as? [Double]).map(box),neighbors:(c["neighbors"] as! [[Double]]).map(box),outside:{$0.minX<shape.minX || $0.maxX>shape.maxX || $0.minY<shape.minY || $0.maxY>shape.maxY},measureShift:{shift in ink.offsetBy(dx:shift.x+(shift == .zero ? 0:drift[0]),dy:shift.y+(shift == .zero ? 0:drift[1]))})
    output.append(r.map{[$0.x,$0.y]} as Any? ?? NSNull())
   } else {
    let panel=box(c["panel"] as! [Double]),sources=(c["sources"] as! [[Double]]).map(box),inks=(c["inks"] as! [[Double]]).map(box)
    let verified=(c["native"] as! Bool) && (c["verified"] as! Bool),unit=((c["unit"] as! Bool) && (c["native"] as! Bool)) || verified
    let req=(verified ? []:[sources[0]]+sources.dropFirst().map{$0.insetBy(dx:-3,dy:-3)})+(unit ? inks:inks.map{$0.insetBy(dx:-3,dy:-3)})
    let r=NativeLateBalloonStages.clip(panel:panel,coverage:(c["coverage"] as! [[Double]]).map(box),required:req,interior:box(c["interior"] as! [Double]),scale:c["scale"] as! Double,width:c["width"] as! Int,height:c["height"] as! Int,fill:(c["fill"] as! [NSNumber]).map(\.uint8Value))
    output.append(r.map{["coverage":$0.coverage.map{[$0.minX,$0.minY,$0.width,$0.height]},"removedPixels":$0.removedPixels] as [String:Any]} as Any? ?? NSNull())
   }
  }
  try JSONSerialization.data(withJSONObject:output).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
 }
}
