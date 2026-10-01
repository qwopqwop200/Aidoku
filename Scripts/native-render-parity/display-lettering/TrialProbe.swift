import CoreGraphics
import Foundation
@main struct TrialProbe {
    static func main() throws {
        let args = CommandLine.arguments
        let rows = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:args[1]))) as! [[String:Any]]
        func rect(_ a:[Double])->CGRect { CGRect(x:a[0],y:a[1],width:a[2],height:a[3]) }
        func a(_ r:CGRect)->[Double] { [Double(r.minX),Double(r.minY),Double(r.width),Double(r.height)] }
        var outputs:[Any] = []
        for f in rows {
            let input = NativeDisplayLetteringTrial.Input(text:f["text"] as! String,source:rect(f["source"] as! [Double]),frame:(f["frame"] as? [Double]).map(rect),glyph:f["glyph"] as! Double,current:f["current"] as! Double,ratio:f["ratio"] as! Double,priorInk:rect(f["priorInk"] as! [Double]),others:(f["others"] as! [[Double]]).map(rect))
            let measurements = f["measurements"] as! [[String:Any]]
            let accepted = NativeDisplayLetteringTrial.prepare(input) { probe in
                guard let m = measurements.first(where:{ ($0["probe"] as! [String:Any])["size"] as! Double == probe.size }) else { return nil }
                return .init(ink:rect(m["ink"] as! [Double]),longestWord:m["longestWord"] as! Double,contentFits:m["contentFits"] as! Bool)
            }
            if let v = accepted { outputs.append(["rect":a(v.probe.rect),"size":v.probe.size,"strokeWidth":v.probe.strokeWidth,"inset":v.probe.inset,"lineHeight":v.probe.lineHeight,"ink":a(v.measured.ink)]) } else { outputs.append(NSNull()) }
        }
        try JSONSerialization.data(withJSONObject:outputs,options:[.sortedKeys]).write(to:URL(fileURLWithPath:args[2]))
    }
}
