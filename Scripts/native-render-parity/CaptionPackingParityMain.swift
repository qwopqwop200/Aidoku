import Foundation
import CoreGraphics
let fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: Any]]
var output: [[String: Any]] = []
for f in fixtures {
    func r(_ a: [Double]) -> CGRect { CGRect(x: a[0], y: a[1], width: a[2], height: a[3]) }
    func d(_ a: CGRect) -> [Double] { [a.minX,a.minY,a.width,a.height].map(Double.init) }
    let descriptors=f["entries"] as! [[String:Any]],page=r(f["page"] as! [Double])
    var entries: [NativeCaptionPacking.Entry] = []
    for e in descriptors {
        let panels=(e["panels"] as! [[String:Any]]).map { p in NativeCaptionPacking.Panel(rect:r(p["rect"] as! [Double]),color:p["color"] as! [Double],sourceErasure:p["erasure"] as? Bool ?? false,clipped:p["clipped"] as? Bool ?? false,backing:p["backing"] as? Bool ?? false) }
        entries.append(.init(id:e["id"] as! String,text:e["text"] as! String,font:e["font"] as! Double,originalFont:e["originalFont"] as? Double,lineRatio:e["ratio"] as? Double ?? 1.2,ink:r(e["ink"] as! [Double]),source:(e["source"] as? [Double]).map { a in r([(a[0]-Double(page.minX))/Double(page.width)*Double(page.width)+Double(page.minX),(a[1]-Double(page.minY))/Double(page.height)*Double(page.height)+Double(page.minY),a[2]/Double(page.width)*Double(page.width),a[3]/Double(page.height)*Double(page.height)]) },sourceFont:e["sourceFont"] as? Double,vertical:e["vertical"] as? Bool ?? false,rotation:e["rotation"] as? Double ?? 0,balancedColumn:e["balancedColumn"] as? Bool ?? false,packingValid:e["valid"] as? Bool ?? true,panels:panels,isUnit:e["unit"] as? Bool ?? false,unitResidue:e["unitResidue"] as? Bool ?? false,sourceErasurePreserved:e["erasurePreserved"] as? Bool ?? false,readabilityPanel:e["readabilityPanel"] as? Bool ?? true))
    }
    let result=NativeCaptionPacking.pack(entries,page:page,minimumFont:f["minimum"] as? Double ?? 5,opacity:1,measure:{ e,cell,font in
        let descriptor=descriptors.first { $0["id"] as? String == e.id }!
        let demand=(descriptor["demand"] as! Double)*font,available=max(0,Double(cell.width)-6)
        let lines=max(1,ceil(demand/max(1,available))),width=min(demand,available)+((descriptor["overshoot"] as? Double) ?? 0),height=font*e.lineRatio*lines
        return .init(ink:CGRect(x:cell.midX-width/2,y:cell.midY-height/2,width:width,height:height))
    },readSource:{ region,w,h in
        let requested=region.intersection(page),native=w==0&&h==0
        let iw=native ? max(0,Int(ceil(requested.maxX)-floor(requested.minX))) : w
        let ih=native ? max(0,Int(ceil(requested.maxY)-floor(requested.minY))) : h
        guard iw>0,ih>0,iw<=65536/ih else { return nil }
        let color=f["sourceColor"] as? [UInt8] ?? [255,255,255]
        return .init(rgba:(0..<(iw*ih)).flatMap{_ in color+[255]},width:iw,height:ih)
    },balloonRelayout:{ e in
        let descriptor=descriptors.first { $0["id"] as? String == e.id }!
        guard let relayout=descriptor["relayout"] as? [String:Any] else { return nil }
        return .init(ink:r(relayout["ink"] as! [Double]),font:relayout["font"] as! Double,sources:(relayout["sources"] as! [[Double]]).map(r),interiorOutside:{ _ in relayout["outside"] as? Double ?? .infinity })
    })
    output.append(["name":f["name"]!,"measurements":result.measurements,"balloonLayouts":result.balloonLayouts,"fallbacks":result.fallbacks,"entries":result.entries.map { e -> [String:Any] in
        ["id":e.id,"font":e.font,"ink":d(e.ink),"cell":e.cell.map(d) as Any? ?? NSNull(),"unified":e.unified,"fit":e.fitPreserved as Any? ?? NSNull(),"compact":e.compactOriginal.map(d) as Any? ?? NSNull(),"panels":e.panels.map { p -> [String:Any] in ["rect":d(p.rect),"color":p.color,"radius":p.radius,"clipped":p.clipped,"coverage":p.coverage.map(d)] },"shift":e.finalAnchorShift.map{[Double($0.x),Double($0.y)]} as Any? ?? NSNull(),"foreign":e.foreignFills.map{["rect":d($0.rect),"color":$0.color]}]
    }])
}
try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
