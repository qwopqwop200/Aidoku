import Foundation
import CoreGraphics

typealias G = NativeTypographyPlateGrowth
func num(_ d:[String:Any],_ k:String,_ f:Double=0)->Double{(d[k] as? NSNumber)?.doubleValue ?? f}
func flag(_ d:[String:Any],_ k:String)->Bool{d[k] as? Bool ?? false}
func rect(_ x:Any?)->CGRect{let a=x as! [Double];return CGRect(x:a[0],y:a[1],width:a[2],height:a[3])}
func run(_ f:[String:Any])->[String:Any]{let iw=Int(num(f,"width")),ih=Int(num(f,"height")),data=f["rgba"] as! [UInt8],budget=G.Budget();budget.flatRoomPixels=Int(num(f,"budget",786432));var reads=0
 let e=G.FlatRoomInput(plate:rect(f["plate"]),glyph:num(f,"glyph"),covered:(f["covered"] as! [[Double]]).map(rect),frame:rect(f["frame"]),imageWidth:iw,imageHeight:ih,color:f["color"] as! [Double],opaque:!flag(f,"transparent"),hasImage:flag(f,"image"),hasShadow:flag(f,"shadow"),hasBorder:flag(f,"border"),transformed:flag(f,"transformed"))
 let room=G.flatRoom(e,budget:budget){x,y,w,h in reads+=1;var out:[UInt8]=[];for yy in y..<y+h{out+=data[(yy*iw+x)*4..<(yy*iw+x+w)*4]};return out}
 var out:[String:Any]=["name":f["name"]!,"budget":budget.flatRoomPixels,"reads":reads,"bounds":NSNull(),"free":[]]
 if let room{out["bounds"]=[room.left,room.top,room.right,room.bottom];out["free"]=(f["queries"] as! [[Double]]).map{room.free(rect($0))}}
 return out
}
@main struct Main{static func main()throws{let a=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]];try JSONSerialization.data(withJSONObject:a.map(run),options:[.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))}}
