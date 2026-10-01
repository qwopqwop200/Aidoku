import Foundation
import CoreGraphics
struct Record:Decodable {let id:String;let panel:Panel}
struct Panel:Decodable {let rect:[CGFloat];let coverage:[[CGFloat]];let radius:CGFloat;let background:[CGFloat]}
func rect(_ a:[CGFloat])->CGRect {CGRect(x:a[0],y:a[1],width:a[2],height:a[3])}
let out=URL(fileURLWithPath:CommandLine.arguments[1]);let panels=try JSONDecoder().decode([Record].self,from:Data(contentsOf:out.appendingPathComponent("panels.json")))
for mode in ["old","corrected-clip","corrected-fill"] {
 let cap=try NativeTranslationPDFCapture.capture(bounds:CGRect(x:0,y:212.30263157894737,width:390,height:275.39473684210526),pixels:CGSize(width:3192,height:2254),deviceScale:3) {c in
  for record in panels {
   let p=record.panel,r=rect(p.rect),snapped=NativeTranslationPDFCapture.snappedRect(r,deviceScale:3)
   c.saveGState();defer {c.restoreGState()}
   if mode=="old" {c.addPath(CGPath(roundedRect:r,cornerWidth:p.radius,cornerHeight:p.radius,transform:nil));c.clip()}
   else if mode=="corrected-clip" {c.addPath(NativeTranslationPDFCapture.roundedPath(r,radius:p.radius,deviceScale:3));c.clip()}
   else {c.clip(to:snapped)}
   if mode=="old" || p.coverage != [p.rect] {
    let path=CGMutablePath()
    for values in p.coverage {
     let raw=rect(values)
     if mode=="old" {path.addRect(raw)} else {
      path.addRect(CGRect(x:snapped.minX+CGFloat(Float(raw.minX-r.minX)),y:snapped.minY+CGFloat(Float(raw.minY-r.minY)),width:CGFloat(Float(raw.width)),height:CGFloat(Float(raw.height))))
     }
    }
    c.addPath(path);c.clip()
   }
   c.setFillColor(CGColor(colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!,components:p.background.map {$0/255}+[1])!)
   if mode=="corrected-fill" {c.addPath(NativeTranslationPDFCapture.roundedPath(r,radius:p.radius,deviceScale:3));c.fillPath()}
   else {c.fill(mode=="old" ? r:snapped)}
  }
 }
 try cap.data.write(to:out.appendingPathComponent(mode+"-background.pdf"))
}
