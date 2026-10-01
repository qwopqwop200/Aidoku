import Foundation
@main struct Probe {
 static func main() throws {
  let fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
  func rgb(_ value: Any?) -> [Double]? { (value as? [Double])?.map { abs($0) } }
  var output: [[String:Any]]=[]
  for f in fixtures {
   let c=f["input"] as! [String:Any]
   let entry=NativePolarityLegibility.Entry(plate:rgb(c["plate"]),fill:rgb(c["fill"]),source:rgb(c["source"]),backing:rgb(c["backing"]),confidence:c["confidence"] as! Double,font:c["font"] as! Double,strokeWidth:c["strokeWidth"] as! Double,strokePreserved:c["strokePreserved"] as! Bool,ringAction:c["ringAction"] as? String,ringKind:c["ringKind"] as? String,ringCore:c["ringCore"] as? [Double],sharedOwner:c["sharedOwner"] as! Bool,foreignOwner:c["foreignOwner"] as! Bool,otherInks:(c["otherInks"] as! [Any]).map{$0 as? [Double]})
   let r=NativePolarityLegibility.resolve(entry)
   output.append(["fill":r.fill as Any? ?? NSNull(),"plate":r.plate as Any? ?? NSNull(),"contrast":r.contrast as Any? ?? NSNull(),"rejection":r.rejection as Any? ?? NSNull()])
  }
  try JSONSerialization.data(withJSONObject:output).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
 }
}
