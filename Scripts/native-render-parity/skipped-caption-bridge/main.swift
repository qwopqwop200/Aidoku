import CoreGraphics
import Foundation
func rect(_ a: [Double]) -> CGRect { CGRect(x:a[0],y:a[1],width:a[2],height:a[3]) }
func array(_ r: CGRect) -> [Double] { [Double(r.minX),Double(r.minY),Double(r.width),Double(r.height)] }
let fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
let output: [[String:Any]] = fixtures.map { f in
    let sources = (f["sources"] as! [[String:Any]]).map { s in
        NativeSkippedCaptionBridge.Source(bounds:(s["bounds"] as! [[Double]]).map(rect),font:s["font"] as! Double,
            sourceFont:s["sourceFont"] as? Double,priorPadding:s["priorPadding"] as? Double ?? 0,
            vertical:s["vertical"] as? Bool ?? false,oversizedUnrestored:s["oversized"] as? Bool ?? false)
    }
    let required = NativeSkippedCaptionBridge.required(sources,inks:(f["inks"] as! [[Double]]).map(rect))
    let layer = rect(f["layer"] as! [Double]), clipped = f["clipped"] as? Bool ?? false
    let old = clipped ? (f["coverage"] as! [[Double]]).map(rect) : [layer]
    let result = NativeSkippedCaptionBridge.coverage(layer:layer,original:old,required:required)
    return ["name":f["name"]!,"coverage":result?.map(array) ?? (clipped ? old.map(array) : []),"bridge":result != nil]
}
try JSONSerialization.data(withJSONObject:output).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
