import Foundation
import CoreGraphics
let url = URL(fileURLWithPath:CommandLine.arguments[1]); let fixtures = try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [[String:Any]]
func ds(_ v:Any?) -> [Double] { (v as? [NSNumber])?.map(\.doubleValue) ?? [] }
func rect(_ a:[Double]) -> CGRect { .init(x:a[0],y:a[1],width:a[2],height:a[3]) }
var output:[[String:Any]] = []
for f in fixtures {
 let width = f["width"] as! Int,height = f["height"] as! Int, raw = (f["rgba"] as! [NSNumber]).map { $0.uint8Value }, p = f["plate"] as! [String:Any], size = ds(p["size"]),origin = ds(p["origin"])
 var plate = NativeGlyphCover.Plate(rect:rect(ds(p["rect"])),size:CGSize(width:size[0],height:size[1]),origin:CGPoint(x:origin[0],y:origin[1]),transformOrigin:.zero,backgroundRGBA:[200,180,150],nodeIsChild:true,ownedNodeCount:1)
 if let m = f["matrix"] as? [String:Double] { plate.transform = .init(a:m["a"]!,b:m["b"]!,c:m["c"]!,d:m["d"]!) }
 if let style = f["style"] as? [String:String] { plate.hasShadow = style["boxShadow"] != nil }
 if let coverage = f["coverage"] as? [[NSNumber]] { plate.clipped = true;plate.coverage = coverage.map { $0.map(\.doubleValue) } }
 plate.frameLines = f["frameLines"] as? Bool ?? false
 let entry = NativeGlyphCover.Entry(id:"one",text:f["text"] as? String ?? "ABC",mode:f["mode"] as? String ?? "readability-panel",record:f["record"] as? [String:Any],sampledInk:ds(f["sampled"]),displayGroup:f["displayGroup"] as? Bool ?? false,sourceBounds:ds(f["bounds"]),sourceFrame:ds(f["frame"]),sourceFontSize:f["glyph"] as? Double,fontSize:20,plate:plate)
 let scene = NativeGlyphCover.Scene(opacity:f["opacity"] as? Double ?? 1,imageSize:CGSize(width:width,height:height),itemCount:1),budget = NativeGlyphCover.Budget()
 let result = NativeGlyphCover.attempt(entry:entry,scene:scene,budget:budget) { crop,w,h in
  var bytes = [UInt8](repeating:0,count:w*h*4)
  for y in 0..<h { for x in 0..<w { let sx = Int(crop.minX)+Int(floor((Double(x)+0.5)*Double(crop.width)/Double(w))),sy = Int(crop.minY)+Int(floor((Double(y)+0.5)*Double(crop.height)/Double(h))); for c in 0..<4 { bytes[(y*w+x)*4+c] = raw[(sy*width+sx)*4+c] } } };return bytes
 }
 let payload:Any
 if let r = result.result { payload = ["width":r.width,"height":r.height,"rgba":r.rgba,"cover":r.cover,"letters":r.letters,"art":r.art,"sourceCrop":[r.sourceCrop.minX,r.sourceCrop.minY,r.sourceCrop.width,r.sourceCrop.height],"metadata":r.metadata,"foreground":r.foreground,"outline":r.outline,"outlineWidth":r.outlineWidth] as [String:Any] } else { payload = NSNull() }
 output.append(["id":f["id"]!,"rejection":result.rejection as Any? ?? NSNull(),"result":payload,"budget":["pixels":budget.pixels,"analysed":budget.analysed,"covers":budget.covers],"error":NSNull()])
}
try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
