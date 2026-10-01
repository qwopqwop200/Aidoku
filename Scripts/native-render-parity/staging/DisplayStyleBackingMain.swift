import Foundation
import CoreGraphics
func n(_ d:[String:Any],_ k:String,_ fallback:Double=0)->Double {(d[k] as? NSNumber)?.doubleValue ?? fallback}
func rect(_ a:Any?)->CGRect {let a=a as? [Double] ?? [0,0,0,0];return CGRect(x:a[0],y:a[1],width:a[2],height:a[3])}
func run(_ job:[String:Any])->[String:Any] {
 let j=job["backing"] as! [String:Any],origin=j["origin"] as! [Double],scale=j["scale"] as! [Double],image=j["image"] as! [Double]
 let fractional=j["fractional"] as? Bool ?? false,data=j["luminance"] as! [Double]
 let input=NativeDisplayStyleCohort.BackingInput(ink:rect(j["ink"]),frame:rect(j["frame"]),imageWidth:image[0],imageHeight:image[1],originX:origin[0],originY:origin[1],scaleX:scale[0],scaleY:scale[1],width:Int(n(j,"width")),height:Int(n(j,"height")),luminance:fractional ? nil:data.map {UInt8(Int($0))},fractionalLuminance:fractional ? data:nil,connected:j["connected"] as? Bool ?? true,fallback:j["fallback"] as? [Double])
 let panels=(j["panels"] as? [[String:Any]] ?? []).map {NativeDisplayStyleCohort.Panel(rect:rect($0["rect"]),color:$0["color"] as? [Double])}
 let budget=NativeDisplayStyleCohort.BackingBudget(Int(n(j,"budget",600000)))
 let range=NativeDisplayStyleCohort.backing(input,panels:panels,budget:budget)
 return ["name":job["name"] as! String,"range":range as Any? ?? NSNull(),"budget":budget.samples]
}
@main struct Main {static func main()throws {
 let jobs=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
 try JSONSerialization.data(withJSONObject:jobs.map(run),options:[.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
}}
