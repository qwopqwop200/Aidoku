import Foundation
@main struct Probe {
 static func main() throws {
  let input=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
  let fixtures=try JSONSerialization.jsonObject(with:input) as! [[String:Any]]
  var results:[[String:Any]]=[]
  for fixture in fixtures {
   let w=fixture["w"] as! Int,h=fixture["h"] as! Int,queue=fixture["queue"] as! [Int]
   var p=(fixture["p"] as! [NSNumber]).map{UInt8($0.intValue)},mask=(fixture["mask"] as! [NSNumber]).map{UInt8($0.intValue)}
   let blocked=(fixture["blocked"] as! [NSNumber]).map{UInt8($0.intValue)},paint=(fixture["paint"] as! [NSNumber]).map{UInt8($0.intValue)}
   let donors=NativeObservedRestorationHelpers.contaminatedFrontDonors(p:p,w:w,h:h,queue:queue,tail:queue.count,donorBlocked:blocked,paintMask:paint,coefficients:fixture["coeff"] as! [[Double]],strokes:fixture["strokes"] as! [[Double]],inks:fixture["inks"] as! [[Double]])
   NativeObservedRestorationHelpers.fillFromDonorFront(p:&p,w:w,n:w*h,queue:queue,tail:queue.count,mask:&mask,donorBlocked:blocked,paintMask:paint)
   results.append(["p":p,"mask":mask,"indices":donors.indices,"specks":donors.specks])
  }
  try JSONSerialization.data(withJSONObject:results).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
 }
}
