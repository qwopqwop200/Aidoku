import Foundation
@main struct Probe {
 static func main() throws {
  let input = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
  let fixtures = try JSONSerialization.jsonObject(with: input) as! [[String:Any]]
  var outputs:[[String:Any]]=[]
  for (index, fixture) in fixtures.enumerated() {
   let pixels=(fixture["rgba"] as! [NSNumber]).map{UInt8($0.intValue)}
   let result=NativeSourceColorSampler.estimate(rgba:pixels,width:fixture["width"] as! Int,height:fixture["height"] as! Int,preferredSurfaceKey:fixture["surface"] as? Int,exteriorSurface:fixture["exterior"] as? [Double],inkSeed:fixture["seed"] as? [Double],minimumInkDistance:(fixture["minDistance"] as? NSNumber)?.doubleValue ?? 60,ownership:(fixture["ownership"] as? [NSNumber])?.map{UInt8($0.intValue)})
   outputs.append(["index":index,"actual":result as Any? ?? NSNull()])
  }
  let output=try JSONSerialization.data(withJSONObject: outputs,options:[.sortedKeys])
  try output.write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
 }
}
