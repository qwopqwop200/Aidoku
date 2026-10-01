import Foundation
import CoreGraphics
while let line=readLine(){
 do{
 let v=try JSONSerialization.jsonObject(with:Data(line.utf8)) as! [String:Any]
 func rect(_ a:[Double])->CGRect{CGRect(x:a[0],y:a[1],width:a[2],height:a[3])}
 let w=v["width"] as! Int,h=v["height"] as! Int,crop=rect(v["crop"] as! [Double]),core=(v["core"] as! [[Double]]).map(rect)
 let font=v["font"] as! Double,text=v["text"] as! String,ratio=v["ratio"] as! Double,glyph=v["glyph"] as! Double
 func style(_ size:CGFloat)->NativeTranslationTypography.Style{.init(fontScript:"korean",fontSize:size,lineHeight:size*ratio,optimizesKoreanWrapping:false)}
 var widths:[String:CGFloat]=[:]
 let bound=min(font,max(8.5,font*0.95)),upper=floor(font*4)/4
 let sizes=(0..<6).map{max(ceil(bound*4)/4,floor((upper-(upper-bound)*Double($0)/5)*4)/4)}
 let scalars=text.unicodeScalars.map{String($0)}
 for size in Set(sizes){for i in scalars.indices{for j in (i+1)...scalars.count{
  let part=scalars[i..<j].joined(),s=style(size)
  widths[String(format:"%.6f",size)+"|"+Data(part.utf8).base64EncodedString()]=NativeTranslationTypography.measuredWidth(text:part,style:s)-CGFloat(max(0,part.unicodeScalars.count-1))*s.tracking
 }}}
 let interior=v["interior"] as? [Int]
 let allows:((CGPoint)->Bool)?=interior.map{mask in {p in let x=Int(floor((p.x-crop.minX)/crop.width*CGFloat(w))),y=Int(floor((p.y-crop.minY)/crop.height*CGFloat(h)));return x>=0&&y>=0&&x<w&&y<h&&mask[y*w+x] != 0}}
 let grid=NativeTypographyRestoredSurfaceFit.Grid(safe:(v["safe"] as! [Int]).map{UInt8($0)},width:w,height:h,crop:crop,page:rect(v["page"] as! [Double]),sourceRects:core,sourceCenter:CGPoint(x:core[0].midX,y:core[0].midY),glyph:glyph,obstacles:(v["obstacles"] as! [[Double]]).map(rect),paintedAlpha:(v["painted"] as? [Int])?.map{UInt8($0)},interiorAllows:allows)
 var budget=v["budget"] as! Int
 let p=grid.map{NativeTypographyRestoredSurfaceFit.proposals(text:text,font:font,lineHeightRatio:ratio,originalLines:v["lines"] as! Int,sourceWidth:core[0].width,baseWidth:v["baseWidth"] as! Double,glyph:glyph,grid:$0,style:style,budget:&budget)} ?? []
 let out:[String:Any]=["budget":budget,"widths":widths,"gridValid":grid != nil,"proposals":p.map{["size":$0.size,"measure":$0.measure,"d":$0.distance,"x":$0.center.x,"y":$0.center.y]}]
 print(String(data:try JSONSerialization.data(withJSONObject:out,options:.sortedKeys),encoding:.utf8)!)
 }catch{print("{\"error\":\"\(error)\"}")}
}
