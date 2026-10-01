import Foundation
import CoreGraphics
let fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: Any]]
func rect(_ a:[Double])->CGRect { CGRect(x:a[0],y:a[1],width:a[2],height:a[3]) }
func read(_ crop:CGRect,_ w:Int,_ h:Int)->[UInt8] {
    var p=[UInt8](repeating:255,count:w*h*4)
    for y in 0..<h { for x in 0..<w {
        let px=Int(floor(crop.minX+(CGFloat(x)+0.5)*crop.width/CGFloat(w)))
        let py=Int(floor(crop.minY+(CGFloat(y)+0.5)*crop.height/CGFloat(h)))
        let a=((px%27)+27)%27,b=((py%37)+37)%37
        if (a>=8 && a<10 && b>=10 && b<28) || (a>=8 && a<21 && (b>=10 && b<12 || b>=18 && b<20 || b>=26 && b<28)) {
            let at=(y*w+x)*4;p[at]=12;p[at+1]=12;p[at+2]=12
        }
    }}; return p
}
let output:[[String:Any]]=fixtures.map { f in
    let input=f["records"] as! [[String:Any]], image=f["image"] as! [Double]
    let records=input.map { r -> NativeSourceOutlineScan.Record in
        var out=NativeSourceOutlineScan.Record(id:r["id"] as! String,sourceBounds:r["bounds"] as! [Double],sourceFrame:rect(r["frame"] as! [Double]),sourceFontSize:r["glyph"] as? Double,sourceVertical:r["vertical"] as? Bool ?? false,sourceColorEligible:r["eligible"] as? Bool ?? true,visible:r["visible"] as? Bool ?? true,backgroundKind:r["mode"] as! String,appliedForeground:r["ink"] as? [Double],appliedStrokeWidth:r["stroke"] as? Double ?? 0,opaquePlate:r["plate"] as? [Double],sample:r["sample"] as? [String:Any] ?? [:])
        out.reserveObservedDarkInk=r["reserve"] as? Bool ?? false;out.partialMainbodyProof=r["proof"] as? String;return out
    }
    var reads:[[Double]]=[]
    let result=NativeSourceOutlineScan.scan(records:records,imageSize:CGSize(width:image[0],height:image[1]),displayFrame:(f["display"] as? [Double]).map(rect),reader:{ crop,w,h in
        reads.append([Double(crop.minX),Double(crop.minY),Double(crop.width),Double(crop.height),Double(w),Double(h)])
        return read(crop,w,h)
    })
    let states=input.map { r -> [String:Any] in
        let id=r["id"] as! String,a=result[id]
        return ["id":id,"ring":a?.ringData as Any? ?? NSNull(),"enclosed":a?.enclosed as Any? ?? NSNull(),"reject":a?.rejection as Any? ?? NSNull()]
    }
    return ["name":f["name"]!,"reads":reads,"states":states]
}
try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
