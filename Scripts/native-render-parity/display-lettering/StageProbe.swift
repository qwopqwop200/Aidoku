import CoreGraphics
import Foundation
@main struct StageProbe {
    static func main() throws {
        let args=CommandLine.arguments,rows=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:args[1]))) as! [[String:Any]]
        func rect(_ a:[Double])->CGRect { CGRect(x:a[0],y:a[1],width:a[2],height:a[3]) }
        func a(_ r:CGRect)->[Double] { [Double(r.minX),Double(r.minY),Double(r.width),Double(r.height)] }
        var output:[[String:Any]]=[]
        for v in rows {
            let frame=rect(v["frame"] as! [Double]),bounds=v["bounds"] as! [Double],size=v["imageSize"] as! [Double]
            let others=(v["others"] as! [[String:Any]]).map { NativeDisplayLetteringStage.Other(bounds:$0["bounds"] as! [Double],mode:$0["mode"] as? String,plates:($0["plates"] as! [[Double]]).map(rect)) }
            let budget=NativeDisplayLetteringStage.Budget();budget.colour=v["budget"] as! Int
            let crop=NativeDisplayLetteringStage.crop(bounds:bounds,frame:frame,imageSize:CGSize(width:size[0],height:size[1]),glyph:v["glyph"] as! Double,budget:budget)
            var value:[String:Any]=["crowded":NativeDisplayLetteringStage.crowded(bounds:bounds,others:others),"hidesOther":NativeDisplayLetteringStage.hidesOther(plate:rect(v["plate"] as! [Double]),frame:frame,others:others),"remaining":budget.colour,"crop":NSNull()]
            if let c=crop {value["crop"]=["x":c.x,"y":c.y,"sw":c.sw,"sh":c.sh,"width":c.width,"height":c.height,"scale":c.scale,"box":a(c.box),"glyph":c.glyph,"rect":a(c.rect),"borders":c.borders]}
            output.append(value)
        }
        try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]).write(to:URL(fileURLWithPath:args[2]))
    }
}
