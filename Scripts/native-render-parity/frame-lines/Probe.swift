import Foundation
@main struct Probe {
 static func main() throws {
  let fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: Any]]
  func box(_ a: [Double]) -> CGRect { CGRect(x:a[0],y:a[1],width:a[2],height:a[3]) }
  var results: [[String: Any]] = []
  for fixture in fixtures {
   let input = fixture["input"] as! [String: Any], expected = fixture["expected"] as! [String: Any]
   let frame = box(input["frame"] as! [Double]), image = input["image"] as! [Double], panels = input["panels"] as! [[String: Any]]
   let text = (input["text"] as! [[Double]]).map(box), samples = expected["samples"] as! [[String: Any]]
   var budget = 3_000_000, counts: [Int] = [], outputs: [[String: Any]] = [], reads: [[String: Any]] = [], sampleIndex = 0
   for panel in panels {
    let p = box(panel["rect"] as! [Double]), b = panel["bounds"] as! [Double]
    let source = CGRect(x: frame.minX+b[0]*frame.width,y:frame.minY+b[1]*frame.height,width:b[2]*frame.width,height:b[3]*frame.height)
    guard input["opacity"] as? Double ?? 1 == 1, panel["hidden"] as? Bool != true, panel["rotated"] as? Bool != true,
     let crop = NativeSourceFrameLines.crop(panel:p,source:source,frame:frame,imageSize:CGSize(width:image[0],height:image[1]),budget:&budget)
    else { counts.append(0);continue }
    let sample = samples[sampleIndex]; sampleIndex += 1
    let rgba = (sample["rgba"] as! [NSNumber]).map(\.uint8Value)
    reads.append(["source":[crop.source.origin.x,crop.source.origin.y,crop.source.width,crop.source.height],"width":crop.width,"height":crop.height,"rgba":rgba])
    if let r = NativeSourceFrameLines.restore(crop:crop,rgba:rgba,panel:p,source:source,textBoxes:text) {
     counts.append(r.painted);outputs.append(["width":r.width,"height":r.height,"rgba":r.rgba])
    } else { counts.append(0) }
   }
   results.append(["remaining":budget,"restored":counts.filter{$0>0}.count,"counts":counts,"samples":reads,"painted":outputs])
  }
  try JSONSerialization.data(withJSONObject:results).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
 }
}
