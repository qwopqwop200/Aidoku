import Foundation
import CoreGraphics
@main struct Probe {
    static func main() throws {
        let args = CommandLine.arguments
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[1]))) as! [[String:Any]]
        var outputs: [[String:Any]] = []
        for f in rows {
            let b = f["box"] as! [Double], box = CGRect(x:b[0],y:b[1],width:b[2],height:b[3])
            let p = (f["rgba"] as! [Int]).map(UInt8.init), w = f["w"] as! Int, h = f["h"] as! Int, glyph = f["glyph"] as! Double
            let r = f["kind"] as! String == "colour"
                ? NativeDisplayLetteringPixels.colour(rgba:p,width:w,height:h,box:box,glyph:glyph,surface:f["surface"] as? [Double],text:f["text"] as? [Double])
                : NativeDisplayLetteringPixels.blackWhite(rgba:p,width:w,height:h,box:box,glyph:glyph,borders:f["borders"] as! [Bool])
            if let reject = r.reject { outputs.append(["reject":reject]); continue }
            var value: [String:Any] = ["output":r.output,"fill":r.fill ?? NSNull(),"outline":r.outline ?? NSNull(),"width":r.width,"masked":r.masked]
            if let halo = r.halo { value["halo"] = halo }
            if let stats = r.stats { value["stats"] = stats }; if let polarity = r.polarity { value["polarity"] = polarity }; if let ends = r.ends { value["ends"] = ends }
            outputs.append(value)
        }
        try JSONSerialization.data(withJSONObject: outputs,options:[.sortedKeys]).write(to:URL(fileURLWithPath:args[2]))
    }
}
