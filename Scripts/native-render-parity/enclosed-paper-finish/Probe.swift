import Foundation
import CoreGraphics
@main enum Probe {
 static func main() throws {
  let fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: Any]]
  func rect(_ values: [Double]) -> CGRect { CGRect(x: values[0], y: values[1], width: values[2], height: values[3]) }
  let results: [Any] = fixtures.map { f in
   guard let r = NativeEnclosedPaperFinish.finish(source: f["source"] as! [UInt8], width: f["w"] as! Int, height: f["h"] as! Int,
     core: rect(f["core"] as! [Double]), auxiliary: (f["aux"] as! [[Double]]).map(rect), rgba: f["rgba"] as! [UInt8], safe: f["safe"] as! [UInt8]) else { return NSNull() }
   return ["rgba": r.rgba, "safe": r.safe, "erased": r.erased] as [String: Any]
  }
  try JSONSerialization.data(withJSONObject: results).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
 }
}
