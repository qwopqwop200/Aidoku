import Foundation
import CoreGraphics
func rect(_ v:[Double])->CGRect { CGRect(x:v[0],y:v[1],width:v[2],height:v[3]) }
func array(_ r:CGRect)->[Double] { [r.minX,r.minY,r.width,r.height] }
let fixtures=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
let output:[[String:Any]]=fixtures.map { f in
    let records=f["entries"] as! [[String:Any]]
    var entries=records.map { r -> NativeTranslationFinalGeometry.Entry in
        var e=NativeTranslationFinalGeometry.Entry(id:r["id"] as! String,frame:rect(r["frame"] as! [Double]),source:rect(r["source"] as! [Double]),lines:(r["lines"] as! [[Double]]).map(rect),font:r["font"] as! Double,pitch:r["pitch"] as! Double,stroke:r["stroke"] as? Double ?? 0)
        e.uprightQuadText=r["upright"] as? Bool ?? false;e.sourceDisplay=r["display"] as? Bool ?? false;e.sourceVertical=r["sourceVertical"] as? Bool ?? false;e.vertical=r["vertical"] as? Bool ?? false;e.originalRotation=r["angle"] as? Double ?? 0;e.hasBalloon=r["balloon"] as? Bool ?? false;e.hasBalancedColumnPlan=r["column"] as? Bool ?? false;e.isRoot=r["root"] as? Bool ?? true;e.inpainted=r["inpainted"] as? Bool ?? false;e.keepsSource=r["keeps"] as? Bool ?? false;e.visible=r["visible"] as? Bool ?? true;e.horizontalScale=r["scale"] as? Double ?? 1;e.textUpright=r["textUpright"] as? Bool ?? false
        if let p=r["plate"] as? [String:Any] {
            let m=p["matrix"] as! [Double],size=p["size"] as! [Double]
            var plate=NativeTranslationFinalGeometry.Plate(rect:rect(p["rect"] as! [Double]),size:CGSize(width:size[0],height:size[1]),matrix:.init(a:m[0],b:m[1],c:m[2],d:m[3],e:m[4],f:m[5],is2D:p["is2D"] as? Bool ?? true))
            if let points=p["clip"] as? [[Double]] {plate.clip = .polygon(points.map { CGPoint(x:$0[0],y:$0[1]) })}
            if p["unsupported"] as? Bool == true {plate.clip = .unsupported}
            plate.hasBackgroundImage=p["image"] as? Bool ?? false;e.plate=plate
        };return e
    }
    if f["text"] as? Bool == true {
        entries=NativeTranslationFinalGeometry.uprightText(entries,reshape:{ e,font,pitch,scale in
            let r=records.first { $0["id"] as? String == e.id }!,box=rect(r["box"] as! [Double]),base=r["base"] as! [[Double]],ratio=font/(r["font"] as! Double)
            let lines=base.map { v -> CGRect in
                let b=rect(v),x=box.midX+(b.minX-box.midX)*scale
                return CGRect(x:x,y:b.minY,width:b.width*ratio*scale,height:b.height*ratio)
            }
            let overflow=r["overflow"] as? Bool ?? false
            return .init(lines:lines,scrollSize:CGSize(width:box.width+(overflow ? 2:0),height:box.height),clientSize:box.size)
        })
    }
    if f["plate"] as? Bool == true { entries=NativeTranslationFinalGeometry.uprightPlate(entries) }
    if f["anchor"] as? Bool == true { entries=NativeTranslationFinalGeometry.anchorVerticalTops(entries,itemCount:f["count"] as? Int) }
    var containment:[[String:Any]]=[]
    if f["contain"] as? Bool == true {
        let input=entries.map {e -> NativeBalloonTextContainment.Entry in
            let r=records.first {$0["id"] as? String == e.id}!
            var out=NativeBalloonTextContainment.Entry(geometry:e,balloonRect:(r["balloonRect"] as? [Double] ?? [0.2,0.2,0.6,0.6]).map {CGFloat($0)},spans:r["spans"] as? [Double] ?? [0.2,0.8,0.2,0.8],center:(r["center"] as? [Double]).map {$0.map {CGFloat($0)}})
            out.contourVerified=r["verified"] as? Bool ?? true;out.horizontalTransform=r["transform"] as? Bool ?? true;out.horizontalWriting=r["writing"] as? Bool ?? true
            out.parentBox=(r["parent"] as? [Double]).map(rect);out.hasPlates=r["hasPlates"] as? Bool ?? false;out.covers=(r["covers"] as? [[Double]] ?? []).map(rect)
            return out
        }
        let result=NativeBalloonTextContainment.contain(input,itemCount:f["count"] as? Int,reshape:{e,font,pitch in
            let r=records.first {$0["id"] as? String == e.id}!,ratio=font/(r["font"] as! Double)
            return (r["base"] as! [[Double]]).map {b in CGRect(x:b[0],y:b[1],width:b[2]*ratio,height:b[3]*ratio)}
        })
        entries=result.map(\.geometry)
        containment=result.map {["id":$0.geometry.id,"fit":$0.fit as Any? ?? NSNull(),"rejected":$0.rejected]}
    }
    let states=entries.map { e -> [String:Any] in
        var p:Any=NSNull()
        if let plate=e.plate {p=["rect":array(plate.rect),"upright":plate.upright]}
        return ["id":e.id,"font":e.font,"pitch":e.pitch,"scale":e.horizontalScale,"lines":e.lines.map(array),"textUpright":e.textUpright,"proof":e.uprightTextProof as Any? ?? NSNull(),"plate":p,"shiftY":e.shift.y,"anchored":e.sourceTopAnchored]
    }
    let kept=(f["kept"] as? [[String:Any]] ?? []).map { NativeTranslationFinalGeometry.Kept(id:$0["id"] as! String,rect:rect($0["rect"] as! [Double]),sourceFontSize:$0["font"] as? Double) }
    let zones=NativeTranslationFinalGeometry.keptZones(kept:kept,painted:(f["painted"] as? [[Double]] ?? []).map(rect)).map { ["id":$0.id,"rect":array($0.rect)] as [String:Any] }
    return ["name":f["name"]!,"states":states,"zones":zones,"containment":containment]
}
try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
