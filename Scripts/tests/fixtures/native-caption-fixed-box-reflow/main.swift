import Foundation
import CoreGraphics
let fixtures=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
func n(_ d:[String:Any],_ k:String,_ fallback:Double=0)->Double {(d[k] as? NSNumber)?.doubleValue ?? fallback}
func rect(_ a:[Double])->CGRect {CGRect(x:a[0],y:a[1],width:a[2],height:a[3])}
func profile(_ d:[String:Any]?)->NativeCaptionFixedBoxReflow.Profile? {guard let d else {return nil};return .init(lines:Int(n(d,"lines")),breaks:d["breaks"] as? [Int] ?? [],badStarts:d["starts"] as? [Int] ?? [],badEnds:d["ends"] as? [Int] ?? [],hangulIsolated:Int(n(d,"isolated")),punctuationOnly:Int(n(d,"punctuation")),ink:(d["ink"] as? [[Double]] ?? []).map(rect))}
var output:[[String:Any]]=[]
for f in fixtures {
 var entry=NativeCaptionFixedBoxReflow.Entry(text:f["text"] as? String ?? "가나다 라마바",x:n(f,"x",110),width:n(f,"width",50),paddingLeft:n(f,"left",5),paddingRight:n(f,"right",5),panel:rect(f["panel"] as? [Double] ?? [100,100,120,100]),padding:n(f,"pad",5),obstacles:(f["others"] as? [[Double]] ?? []).map(rect))
 entry.preserveBackground=f["preserve"] as? Bool ?? true;entry.opacity=n(f,"opacity",1);entry.automaticRecovery=f["automatic"] as? Bool ?? true;entry.vertical=f["vertical"] as? Bool ?? false;entry.script=f["script"] as? String ?? "korean"
 let session=NativeCaptionFixedBoxReflow.Session(characters:Int(n(f,"budget",8192)));var calls:[[Double]]=[],at=0
 let probes=f["probes"] as! [[String:Any]]
 let result=NativeCaptionFixedBoxReflow.reflow(entry,session:session,baseline:{profile(f["baseline"] as? [String:Any])},measure:{x,w in calls.append([x,w]);defer {at+=1};let v=probes[min(at,probes.count-1)];guard let p=profile(v["profile"] as? [String:Any]) else {return nil};return .init(profile:p,fits:v["fits"] as? Bool ?? true)})
 var v:[String:Any]=["name":f["name"]!,"accepted":result != nil,"budget":session.characters,"calls":calls]
 if let r=result {v["x"]=r.x;v["width"]=r.width;v["originalWidth"]=r.originalWidth;v["originalLines"]=r.originalLines;v["finalLines"]=r.finalLines}
 output.append(v)
}
try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
