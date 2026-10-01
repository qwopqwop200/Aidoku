import CoreGraphics
import CryptoKit
import Foundation
@main enum EarlyBalloonGridMain {
    static func main() throws {
        let args=CommandLine.arguments
        let jobs=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:args[1]))) as! [[String:Any]]
        func rect(_ a:[Double])->CGRect {CGRect(x:a[0],y:a[1],width:a[2],height:a[3])}
        func box(_ r:CGRect)->[Double] {[Double(r.minX),Double(r.minY),Double(r.width),Double(r.height)]}
        func hash(_ bytes:[UInt8])->String {SHA256.hash(data:Data(bytes)).map {String(format:"%02x",$0)}.joined()}
        let output=jobs.map {j->[String:Any] in
            let w=j["w"] as! Int,h=j["h"] as! Int,at=j["at"] as! [Double],frame=rect(j["frame"] as! [Double])
            let geometry=NativeEarlyBalloonGrid.Geometry(width:w,height:h,origin:CGPoint(x:at[0],y:at[1]),sx:at[2],sy:at[3],imageWidth:at[4],imageHeight:at[5],frame:frame)
            let safe=j["safe"] as! [UInt8],sources=j["sources"] as! [[Double]],coeff=j["coeff"] as? [[Double]],kind=j["exterior"] as! String
            var painted:[UInt8]?
            if let alpha=j["painted"] as? [UInt8] {painted=alpha.flatMap {[UInt8(0),0,0,$0]}}
            let input=NativeEarlyBalloonGrid.Input(geometry:geometry,safe:safe,paintedRGBA:painted,surfaceSafe:j["surfaceSafe"] as! Bool,coefficients:coeff,
                sourceRects:sources,sourceGlyph:j["glyph"] as! Double,font:8,clearSearch:j["clearSearch"] as! Bool,late:j["late"] as! Bool,
                otherLayers:(j["obstacles"] as! [[Double]]).map(rect))
            var reads:[[Double]]=[]
            let interior=j["interior"] as? [Double]
            var interiorFn:((CGPoint)->Bool)?
            if let a=interior {
                let left:Double=a[0],top:Double=a[1],right:Double=a[0]+a[2],bottom:Double=a[1]+a[3]
                interiorFn={p in
                    let x=Double(p.x),y=Double(p.y)
                    return x>=left && x<right && y>=top && y<bottom
                }
            }
            let reader:(CGRect,Int,Int)->[UInt8]? = {r,rw,rh in
                reads.append(box(r)+[Double(rw),Double(rh)])
                if kind=="absent" {return nil}
                let kx=at[4]/Double(frame.width)*at[2],ky=at[5]/Double(frame.height)*at[3]
                let ex=floor(64*kx+0.5),ey=floor(64*ky+0.5)
                var data=[UInt8](repeating:0,count:rw*rh*4)
                for y in 0..<rh {for x in 0..<rw {
                    let xx=(Double(x)-ex)/Double(w),yy=(Double(y)-ey)/Double(h)
                    let coefficients:[[Double]]=coeff ?? [[240,0,0],[240,0,0],[240,0,0]]
                    let plane:[Double]=coefficients.map {a in max(0,min(255,a[0]+a[1]*xx+a[2]*yy))}
                    let bias=kind=="wrong" ? 19:kind=="tolerance" ? 18:kind=="striped" && x%7==0 ? 19:0
                    let i=(y*rw+x)*4
                    for c in 0..<3 {data[i+c]=UInt8(max(0,min(255,floor(plane[c]+Double(bias)+0.5))))}
                    data[i+3]=kind=="alpha253" ? 253:kind=="alpha254" ? 254:255
                }}
                return data
            }
            let grid=NativeEarlyBalloonGrid.build(input,interiorAllows:interiorFn,readExterior:reader)
            var result:[String:Any] = ["name":j["name"]!,"reads":reads,"accepted":grid != nil]
            if let grid {
                let queries=[[0,0,grid.width,grid.height],[0,0,1,1],[grid.width/2,grid.height/2,1,1],[grid.width/3,grid.height/3,2,2],
                             [max(0,grid.width-2),max(0,grid.height-2),2,2]]
                let satBytes=grid.summedArea.flatMap {v->[UInt8] in let n=UInt32(v);return [UInt8(n&255),UInt8((n>>8)&255),UInt8((n>>16)&255),UInt8((n>>24)&255)]}
                result["width"]=grid.width;result["height"]=grid.height;result["crop"]=box(grid.crop)
                result["kx"]=Double(grid.kx);result["ky"]=Double(grid.ky);result["span"]=box(grid.sourceSpan)
                result["sourceCentre"]=[Double(grid.sourceCentre.x),Double(grid.sourceCentre.y)]
                result["gridCentre"]=[Double(grid.gridCentre.x),Double(grid.gridCentre.y)]
                result["blocked"]=hash(grid.blocked);result["reached"]=hash(grid.reached);result["sat"]=hash(satBytes)
                result["clear"]=queries.map {grid.clear($0[0],$0[1],$0[2],$0[3])}
                result["reachable"]=grid.reached.reduce(0) {$0+Int($1)}
            }
            return result
        }
        try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]).write(to:URL(fileURLWithPath:args[2]))
    }
}
