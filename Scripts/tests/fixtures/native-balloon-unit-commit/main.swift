import Foundation
import CoreGraphics
func rect(_ a:[Double])->CGRect {CGRect(x:a[0],y:a[1],width:a[2],height:a[3])}
func array(_ r:CGRect)->[Double] {[r.minX,r.minY,r.width,r.height]}
func shape(_ text:String,font:Double,width:Double,pitch:Double,pad:Double)->NativeTranslationBalloonUnitCommit.Measurement {
    let a=font*0.55,limit=max(1,Int(floor(width/a)));var rows:[Int]=[0]
    for word in text.split(separator:" ",omittingEmptySubsequences:true) {let count=word.utf16.count;if rows.last!>0 && rows.last!+1+count>limit {rows.append(0)}else if rows.last!>0 {rows[rows.count-1]+=1};rows[rows.count-1]+=count}
    let w=Double(rows.max() ?? 0)*a,h=Double(rows.count-1)*pitch+font
    return .init(ink:CGRect(x:pad+(width-w)/2,y:pad+(pitch-font)/2,width:w,height:h),nodeRect:CGRect(x:0,y:0,width:width+pad*2,height:Double(rows.count)*pitch+pad*2),scrollWidth:max(width+pad*2,w+pad*2),clientWidth:width+pad*2)
}
let fixtures=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
let outputs:[[String:Any]]=fixtures.map {f in
    let frame=rect(f["frame"] as! [Double]),raw=f["records"] as! [[String:Any]]
    let records=raw.map {r -> NativeTranslationBalloonUnitCommit.Record in
        var e=NativeTranslationBalloonUnitCommit.Record(id:r["id"] as! String,text:r["text"] as! String,sourceBounds:r["bounds"] as! [Double],sourceRects:(r["sources"] as! [[Double]]).map(rect),ink:rect(r["ink"] as! [Double]),font:r["font"] as! Double,pitch:r["pitch"] as! Double,sourceFontSize:r["glyph"] as? Double)
        if let u=r["unit"] as? [String:Any] {e.unit = .init(members:u["members"] as! [String],interior:.init(rect:u["rect"] as! [Double],center:u["center"] as! [Double],spans:u["spans"] as! [Double]))}
        e.sourceVertical=r["sourceVertical"] as? Bool ?? true;e.hasNode=r["hasNode"] as? Bool ?? true;e.rotation=r["rotation"] as? Double ?? 0;e.vertical=r["vertical"] as? Bool ?? false;e.balancedColumn=r["balanced"] as? Bool ?? false;e.isRoot=r["root"] as? Bool ?? true;e.transformNone=r["transform"] as? Bool ?? true;e.preservedGloss=r["gloss"] as? Bool ?? false;e.hasScaleStyle=r["scale"] as? Bool ?? false;e.backgroundKind=r["background"] as? String ?? "inpainted";e.restoredSourcePanel=r["restored"] as? Bool ?? true;e.restoredSurfaceFontFit=r["surfaceFit"] as? Bool ?? false;e.hasRestoration=r["hasRestoration"] as? Bool ?? true;e.erasureComplete=r["complete"] as? Bool ?? true;e.provisional=r["provisional"] as? Bool ?? false;e.restorationHidden=r["hidden"] as? Bool ?? false;e.sourceAlignment=r["alignment"] as? String;e.sourceHeading=r["heading"] as? Bool ?? false;return e
    }
    let layers=(f["layers"] as? [[String:Any]] ?? []).map {NativeTranslationBalloonUnitCommit.Layer(ownerID:$0["id"] as! String,rect:rect($0["rect"] as! [Double]),participates:$0["participates"] as? Bool ?? true)}
    let kept=(f["kept"] as? [[String:Any]] ?? []).map {NativeTranslationBalloonUnitCommit.ProtectedSource(id:$0["id"] as! String,rects:($0["rects"] as! [[Double]]).map(rect))}
    let result=NativeTranslationBalloonUnitCommit.commit(records:records,layers:layers,kept:kept,frame:frame,measure:{record,font,width,pitch,pad,commit in
        if commit,raw.first(where:{$0["id"] as? String==record.id})?["commitFail"] as? Bool == true {return nil}
        return shape(record.text,font:font,width:width,pitch:pitch,pad:pad)
    },widestWord:{text,font in Double(text.split(separator:" ",omittingEmptySubsequences:true).map { $0.utf16.count }.max() ?? 0)*font*0.55},verify:{record,p,m in
        let dx=raw.first(where:{$0["id"] as? String==record.id})?["verifyDx"] as? Double ?? 0
        return m.ink.offsetBy(dx:p.rect.minX-m.nodeRect.minX+dx,dy:p.rect.minY-m.nodeRect.minY)
    })
    let states=result.records.map {r -> [String:Any] in
        var p:Any=NSNull();if let placement=r.placement {p=["rect":array(placement.rect),"font":placement.font,"pitch":placement.pitch,"padding":placement.padding,"order":placement.order,"members":placement.members,"from":placement.from]}
        return ["id":r.id,"ink":array(r.ink),"font":r.font,"pitch":r.pitch,"placement":p,"blocked":r.blocked as Any? ?? NSNull()]
    }
    return ["name":f["name"]!,"states":states,"layouts":result.layouts,"probes":result.probes,"outcomes":result.outcomes]
}
try JSONSerialization.data(withJSONObject:outputs,options:[.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
