import Foundation
import CoreGraphics
func rect(_ v:[Double])->CGRect {CGRect(x:v[0],y:v[1],width:v[2],height:v[3])}
func array(_ r:CGRect)->[Double] {[r.minX,r.minY,r.width,r.height]}
func shape(_ text:String,_ c:NativeBalloonRelayout.Candidate)->NativeBalloonRelayout.Measurement {
    let words=text.split(separator:" ",omittingEmptySubsequences:true),advance=c.font*0.55,limit=max(1,Int(floor(c.rect.width/advance)))
    var rows:[Int]=[0],split=false
    for word in words {
        let count=word.utf16.count
        if rows[rows.count-1]>0 && rows.last!+1+count>limit {rows.append(0)}
        else if rows.last!>0 {rows[rows.count-1]+=1}
        for _ in 0..<count {if rows.last!>=limit {rows.append(0);split=true};rows[rows.count-1]+=1}
    }
    let height=Double(max(0,rows.count-1))*c.pitch+c.font,width=Double(rows.max() ?? 0)*advance
    let ink=CGRect(x:c.rect.midX-width/2,y:c.rect.midY-height/2,width:width,height:height)
    let nonspace=text.replacingOccurrences(of:" ",with:"").utf16.count
    return .init(ink:ink,scrollWidth:width,clientWidth:Double(c.rect.width),splitsWord:split,strandedSyllable:!split && rows.count>1 && nonspace>=4 && rows.contains(where:{$0<2}))
}
let fixtures=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
let output:[[String:Any]]=fixtures.map {f in
    let text=f["text"] as! String,font=f["font"] as! Double,pitch=f["pitch"] as! Double,original=rect(f["ink"] as! [Double]),box=rect(f["box"] as! [Double]),contour=rect(f["contour"] as! [Double])
    var e=NativeBalloonRelayout.Entry(text:text,renderedText:f["rendered"] as? String ?? text,ink:original,source:(f["source"] as? [Double]).map(rect),frame:(f["frame"] as? [Double]).map(rect),font:font,pitch:pitch,foreign:(f["foreign"] as? [[Double]] ?? []).map(rect))
    e.isUnit=f["unit"] as? Bool ?? false;e.tightInterior=f["tight"] as? Bool ?? false;e.hasInterior=f["interior"] as? Bool ?? true;e.visible=f["visible"] as? Bool ?? true;e.vertical=f["vertical"] as? Bool ?? false;e.rotation=f["rotation"] as? Double ?? 0;e.balancedColumn=f["balanced"] as? Bool ?? false;e.wrappingScript=f["script"] as? String ?? "korean"
    e.strandedBefore=font > 0 ? shape(e.renderedText,.init(rect:box,font:font,pitch:pitch)).strandedSyllable : false
    let nativeInterior=(f["nativeRect"] as? [Double]).flatMap { NativeBalloonRelayout.nativeUnitInterior(frame:rect(f["frame"] as! [Double]),rect:$0.map { CGFloat($0) },spans:f["spans"] as! [Double],surfaceRGB:f["paper"] as? [Double]) }
    if f["nativeRect"] != nil { e.hasInterior = nativeInterior != nil; e.tightInterior = false }
    var interiorValue:Any=NSNull()
    if let nativeInterior {interiorValue=["width":nativeInterior.width,"height":nativeInterior.height,"scale":nativeInterior.scale,"fill":nativeInterior.fill.map(Int.init),"paper":nativeInterior.surfaceRGB,"outside":(f["queries"] as! [[Double]]).map {nativeInterior.outside(rect($0))}]}
    var probes=0
    let result=NativeBalloonRelayout.relayout(e,outside:{r in
        if let nativeInterior {return nativeInterior.outside(r)}
        let w=max(0,min(r.maxX,contour.maxX)-max(r.minX,contour.minX)),h=max(0,min(r.maxY,contour.maxY)-max(r.minY,contour.minY))
        return Double((r.maxX-r.minX)*(r.maxY-r.minY)-w*h)
    },measure:{c in probes+=1;return shape(text,c)})
    var value:Any=NSNull()
    if let result {value=["rect":array(result.candidate.rect),"font":result.candidate.font,"pitch":result.candidate.pitch,"ink":array(result.ink),"diagnostics":result.diagnostics]}
    return ["name":f["name"]!,"result":value,"probes":probes,"interior":interiorValue]
}
try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
