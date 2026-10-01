import CoreGraphics
import Foundation
@main struct Main {
 static func main() throws {
  let fixtures = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
  var output:[[String:Any]]=[]
  for f in fixtures {
   func d(_ k:String,_ v:Double)->Double {(f[k] as? NSNumber)?.doubleValue ?? v}
   func b(_ k:String,_ v:Bool)->Bool {f[k] as? Bool ?? v}
   let font=d("font",14),minimum=d("minimum",5),box=CGRect(x:20,y:20,width:100,height:60),text=f["text"] as? String ?? "HELLO WORDS"
   let floorSize=ceil(max(minimum,min(font,8),font*0.75)*4)/4
   var seen=Set<Double>();let sizes=[0.9,0.8,0.7,0.65].map{max(floorSize,floor(font*$0*4)/4)}.filter{$0<font&&seen.insert($0).inserted}
   let baseline=NativeArtworkProtection.Measurement(ink:[box],lines:2,lineStarts:[0,6],flow:.init(),contentFits:true)
   var e=NativeArtworkProtection.Entry(id:f["name"] as! String,text:text,font:font,sizes:sizes,frame:CGRect(x:0,y:0,width:500,height:500),source:CGRect(x:55,y:30,width:30,height:35),background:[245,245,245],plate:b("plate",true) ? box:nil,original:b("profile",true) ? baseline:nil)
   e.enabled=b("enabled",true);e.balancedColumn=b("balanced",false);e.rotation=d("rotation",0);e.rightToLeft=b("rtl",false);e.alreadyRestored=b("restored",false);e.hasSurfaceQuery=b("surfaceQuery",false);e.erasureComplete=b("complete",false);e.residualLettering=b("residual",false);e.hasSourceImage=b("image",true)
   if b("sharedSource",false) {e.otherSources=[CGRect(x:40,y:25,width:20,height:20)]}
   if b("sharedText",false) {e.otherText=[CGRect(x:40,y:25,width:20,height:20)]}
   var budget=NativeArtworkProtection.Budget(type:Int(d("type",8192)),probePixels:Int(d("probe",32768)),surface:Int(d("surface",1048576)))
   var callbacks=0
   let result=NativeArtworkProtection.run(e,budget:&budget,hooks:.init(read:{_ in
    if b("readFails",false) {return nil};return (0..<1024).flatMap {i->[UInt8] in let x=i%32,y=i/32;let dark=b("solid",false) || x<3 || x>=29 || y<3 || y>=29
     return [UInt8](arrayLiteral:dark ? 40:245,dark ? 60:245,dark ? 80:245,UInt8(d("alpha",255)))
    }
   },measure:{c in
    let k=c.font/font,rect=CGRect(x:box.midX-box.width*k/2+d("shift",0),y:box.midY-box.height*k/2,width:box.width*k,height:box.height*k)
    return .init(ink:[rect],lines:b("badLines",false) ? 3:2,lineStarts:[0,6],flow:.init(breaks:b("badFlow",false) ? 1:0),contentFits:!b("overflows",false))
   },surface:{_,allowance in callbacks+=1;allowance-=min(allowance,Int(d("cost",1200)));return b("surfaceAccept",false)}))
   var o:[String:Any]=["name":f["name"]!,"accepted":result != nil,"type":budget.type,"probe":budget.probePixels,"surface":budget.surface,"callbacks":callbacks]
   if let r=result {o["font"]=r.candidate.font;o["lines"]=r.candidate.frozenLines;o["metadata"]=r.metadata;o["released"]=r.releasedPlate}
   output.append(o)
  }
  try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
 }
}
