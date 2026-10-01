import Foundation
import CoreGraphics
func rect(_ v:[Double])->CGRect { CGRect(x:v[0],y:v[1],width:v[2],height:v[3]) }
func array(_ r:CGRect)->[Double] { [Double(r.minX),Double(r.minY),Double(r.width),Double(r.height)] }
func serial(_ p:NativeTranslationGlossPlacement.Placement?)->Any {
    guard let p else { return NSNull() }
    return ["cost":p.cost,"size":p.size,"width":p.width,"lineHeight":p.lineHeight,"moves":p.moves.map { [Double($0.x),Double($0.y)] },"edge":p.edge,"rank":p.rank,"side":p.side,"gap":p.gap,"texture":p.texture,
        "ink":p.ink.map(array) as Any? ?? NSNull(),"angle":p.angle as Any? ?? NSNull(),"center":p.center.map { [Double($0.x),Double($0.y)] } as Any? ?? NSNull(),"block":p.block.map { [Double($0.width),Double($0.height)] } as Any? ?? NSNull()] as [String:Any]
}
@main enum GlossProbe {
static func main() throws {
let fixtures=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
var output:[[String:Any]]=[]
for fixture in fixtures {
    let f=rect(fixture["frame"] as! [Double]),s=rect(fixture["band"] as! [Double]),rgba=(fixture["rgba"] as! [Int]).map(UInt8.init)
    let placer=NativeTranslationGlossPlacement(frame:f,band:s,fill:fixture["fill"] as! [Double],ground:fixture["ground"] as? [Double]) { _,_,w,h in
        precondition(w==fixture["gw"] as! Int && h==fixture["gh"] as! Int);return rgba
    }
    let options=fixture["options"] as! [String:Any],specs=fixture["nodeSpecs"] as! [[String:Double]],blocked=(fixture["blocked"] as! [[Double]]).map(rect),q=fixture["tiltedFrame"] as! [String:Double]
    let opt=NativeTranslationGlossPlacement.Options(start:options["start"] as! Double,minimum:options["minimum"] as! Double,lines:options["lines"] as! Double,texture:options["texture"] as! Bool)
    let measure:NativeTranslationGlossPlacement.Measure={ size,width,lh in specs.map { spec in
        let natural=spec["length"]!*size*0.53,lines=max(1,ceil(natural/width)),tw=min(width,natural),height=lines*lh*0.82
        return CGRect(x:spec["left"]!+(width-tw)/2,y:spec["top"]!+size*0.08,width:tw,height:height)
    } }
    let e=placer.underneath(rect(fixture["test"] as! [Double]),inset:3)
    let divided=placer.divided(CGRect(x:f.minX,y:s.minY,width:f.width,height:s.height+60),wide:true),ink=placer.inkOf(s)
    let axis=placer.search(source:s,blocked:blocked,before:fixture["before"] as! Bool,options:opt,measure:measure)
    let tilted=placer.searchTilted(frame:.init(cx:q["cx"]!,cy:q["cy"]!,angle:q["angle"]!,hw:q["hw"]!,hh:q["hh"]!),blocked:blocked,before:fixture["before"] as! Bool,options:opt,measure:measure)
    output.append(["evidence":["rule":e.rule,"edge":e.edge,"edgeMax":e.edgeMax,"own":e.own,"paper":e.paper],"divided":divided,"ink":array(ink),"axis":serial(axis),"tilted":serial(tilted),"reasons":placer.reasons])
}
try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))

}
}
