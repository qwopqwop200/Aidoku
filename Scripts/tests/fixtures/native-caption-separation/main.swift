import CoreGraphics
import Foundation
func rect(_ a: [Double]) -> CGRect { CGRect(x:a[0],y:a[1],width:a[2],height:a[3]) }
func array(_ r: CGRect) -> [Double] { [r.minX,r.minY,r.width,r.height] }
let fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
let outputs: [[String:Any]] = fixtures.map { f in
    let records = f["entries"] as! [[String:Any]]
    let entries = records.map { r -> NativeTranslationCaptionSeparation.Entry in
        let metrics = (r["metrics"] as! [[Double]]).map { NativeTranslationCaptionSeparation.Metric(ascent:$0[0],descent:$0[1]) }
        return .init(id:r["id"] as! String,frame:rect(r["frame"] as! [Double]),source:rect(r["source"] as! [Double]),text:r["text"] as! String,
            sourceVertical:r["eligible"] as! Bool,vertical:false,rotation:0,hasBalloon:false,isRoot:true,inpainted:true,keepsSource:false,
            visible:r["visible"] as! Bool,horizontalWriting:true,horizontalTransform:true,font:r["font"] as! Double,stroke:r["stroke"] as! Double,metrics:metrics,
            lineHeight:r["pitch"] as! Double,height:60,lines:(r["lines"] as! [[Double]]).map(rect))
    }
    var after = NativeTranslationCaptionSeparation.separateLines(entries) { e,pitch in
        let lines = e.lines.enumerated().map { $0.element.offsetBy(dx:0,dy:Double($0.offset)*(pitch-e.lineHeight)) }
        return .init(lines:lines,height:max(e.height,ceil(Double(e.lines.count)*pitch)),shiftY:0)
    }
    after = NativeTranslationCaptionSeparation.separateColumns(after,keptSources:(f["kept"] as! [[Double]]).map(rect))
    return ["name":f["name"]!,"entries":after.map { e in ["id":e.id,"lines":e.lines.map(array),"pitch":e.lineHeight,"shift":[e.shift.x,e.shift.y],"columnShift":e.columnShift] as [String:Any] }]
}
try JSONSerialization.data(withJSONObject:outputs,options:[.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
