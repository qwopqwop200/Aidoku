import Foundation
@main struct Probe {
 static func main() throws {
  let fixtures=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
  func box(_ a:[Double])->CGRect{.init(x:a[0],y:a[1],width:a[2],height:a[3])}
  var output:[[String:Any]]=[]
  for f in fixtures {
   let c=f["input"] as! [String:Any],ink=c["ink"] as! [Double],font=c["font"] as! Double,center=c["center"] as! Bool
   var trace:[[String:Any]]=[]
   let r=NativePageEdgeFit.fit(ink:box(ink),frame:box(c["frame"] as! [Double]),font:font,pitch:c["pitch"] as! Double,plated:c["plated"] as! Bool,allowsResize:c["resize"] as! Bool){size,pitch in
    let factor=size/font,w=ink[2]*factor,h=ink[3]*factor
    let r=[ink[0]+(center ? (ink[2]-w)/2:0),ink[1]+(center ? (ink[3]-h)/2:0),w,h]
    trace.append(["font":size,"pitch":pitch,"ink":r]);return box(r)
   }
   output.append(["result":r.map{["font":$0.font,"pitch":$0.pitch,"shift":[$0.shift.x,$0.shift.y],"outcome":$0.outcome] as [String:Any]} as Any? ?? NSNull(),"trace":trace])
  }
  try JSONSerialization.data(withJSONObject:output).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
 }
}
