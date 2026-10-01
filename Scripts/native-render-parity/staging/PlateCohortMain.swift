import Foundation
import CoreGraphics

typealias G = NativeTypographyPlateGrowth
func number(_ d:[String:Any],_ k:String,_ fallback:Double=0)->Double{(d[k] as? NSNumber)?.doubleValue ?? fallback}
func flag(_ d:[String:Any],_ k:String,_ fallback:Bool=false)->Bool{d[k] as? Bool ?? fallback}
func rect(_ a:Any?)->CGRect?{guard let a=a as? [Double],a.count==4 else{return nil};return CGRect(x:a[0],y:a[1],width:a[2],height:a[3])}
func run(_ job:[String:Any])->[String:Any]{
 let rows=job["members"] as! [[String:Any]],inputs=job["growers"] as! [[String:Any]]
 var fonts=Dictionary(uniqueKeysWithValues:rows.map{($0["id"] as! String,number($0,"font"))}),trace:[[String:Any]]=[]
 func member(_ row:[String:Any])->G.Member{
  let id=row["id"] as! String,font=fonts[id] ?? number(row,"font"),peer=number(row,"peer")
  return G.Member(id:id,source:number(row,"source"),script:row["script"] as? String ?? "korean",vertical:flag(row,"vertical"),sourceVertical:flag(row,"sourceVertical"),sourceRect:rect(row["rect"]),cohortFont:max(peer,number(row,"preFont",font)),memberFont:max(peer,font),styleKey:row["style"] as? String ?? "",visible:flag(row,"visible",true),rotation:number(row,"rotation"),nearUprightRotation:number(row,"near"))
 }
 var growers=inputs.map{f in G.Grower(id:f["id"] as! String,source:number(f,"source"),script:f["script"] as? String ?? "korean",vertical:flag(f,"vertical"),inPlace:flag(f,"inPlace"),size:number(f,"size"),extended:flag(f,"extended"),base:number(f,"base"),interiorBase:f["interiorBase"] == nil ? nil : number(f,"interiorBase"))}
 G.reconcile(&growers,members:{rows.map(member)},kept:(job["kept"] as? [[String:Any]] ?? []).map(member),run:{id,cap,strict in
  let f=inputs.first{$0["id"] as? String==id}!,current=fonts[id] ?? 0
  let capped=cap.isFinite ? cap : number(f,"maximum",current)
  let size=floor(min(capped,number(f,"maximum",current))*(strict ? number(f,"strictFactor",1):1)*4)/4+number(f,"offset")
  let result=size<number(f,"minimum",0) ? nil : size
  trace.append(["id":id,"cap":cap.isFinite ? cap as Any:"Infinity","strict":strict,"size":result as Any? ?? NSNull()]);if let result{fonts[id]=result};return result
 },readableHold:{id in
  guard let row=rows.first(where:{$0["id"] as? String==id}),let size=fonts[id] else{return 0}
  let ink=rect(row["ink"]) ?? rect(row["rect"]) ?? .zero
  let others=rows.filter{$0["id"] as? String != id && flag($0,"visible",true)}.map{rect($0["ink"]) ?? rect($0["rect"]) ?? .zero}
  return G.readableHold(source:number(row,"source"),script:row["script"] as? String ?? "korean",font:size,ink:ink,otherVisibleInk:others)
 },plateFilled:{id in flag(rows.first{$0["id"] as? String==id}!,"filled")},interiorGaps:{id,font in
  let f=inputs.first{$0["id"] as? String==id}!
  return max(0,Int(ceil(font-number(f,"gapLimit",Double.infinity))))
 })
 let out=growers.map{g -> [String:Any] in var o:[String:Any]=["id":g.id,"size":g.size as Any? ?? NSNull()];if let x=g.cohortTarget{o["cohort"]=x};if let x=g.releasedTarget{o["released"]=x.isFinite ? x as Any : "Infinity"};if let x=g.styleCap{o["styleCap"]=x};if let x=g.interiorRefit{o["interiorRefit"]=x};return o}
 return ["name":job["name"] as! String,"growers":out,"fonts":fonts,"trace":trace]
}
@main struct Main{static func main()throws{let jobs=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]];try JSONSerialization.data(withJSONObject:jobs.map(run),options:[.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))}}
