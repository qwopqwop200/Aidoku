import Foundation
import CoreGraphics
func makeImage(_ bytes:Data,_ width:Int,_ height:Int)->CGImage {
 CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGBitmapInfo.byteOrder32Big.rawValue|CGImageAlphaInfo.premultipliedLast.rawValue),provider:CGDataProvider(data:bytes as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
}
func getBytes(_ image:CGImage)->Data {image.dataProvider!.data! as Data}
func tile(_ bytes:Data,_ width:Int,_ x:Int,_ y:Int,_ w:Int,_ h:Int)->Data {
 var out=Data();for row in y..<(y+h){out.append(bytes[((row*width+x)*4)..<((row*width+x+w)*4)])};return out
}
@main struct Proof {
 static func main()throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]),out=URL(fileURLWithPath:CommandLine.arguments[2]);var results:[[String:Any]]=[]
  for background in ["transparent","opaque"] {
   let directory=root.appendingPathComponent(background),document=try JSONSerialization.jsonObject(with:Data(contentsOf:directory.appendingPathComponent("web-dom-and-saved-masks.json"))) as! [String:Any]
   var canvas=Data(count:960*480*4)
   if background=="opaque" {for i in stride(from:0,to:canvas.count,by:4){canvas[i]=41;canvas[i+1]=65;canvas[i+2]=87;canvas[i+3]=255}}
   let session=NativeCanvasTextureResampler.Session();defer{session.close()}
   for record in document["records"] as! [[String:Any]] {
    let id=record["id"] as! String,w=record["width"] as! Int,h=record["height"] as! Int,f=record["used"] as! [Double]
    let x=Int(f[0]*3),y=Int(f[1]*3),pw=Int(f[2]*3),ph=Int(f[3]*3)
    let source=makeImage(try Data(contentsOf:directory.appendingPathComponent("source-native-\(id).rgba")),w,h)
    let pixels=try NativeCanvasTextureResampler.compositeCanvasImage(image:source,destinationPixels:CGSize(width:pw,height:ph),cropPixels:CGRect(x:0,y:0,width:pw,height:ph),backgroundRGBA:tile(canvas,960,x,y,pw,ph),session:session)
    let rgba=getBytes(pixels)
    for row in 0..<ph{let i=((y+row)*960+x)*4;canvas.replaceSubrange(i..<(i+pw*4),with:rgba[(row*pw*4)..<((row+1)*pw*4)])}
   }
   for requested in [320,160] {
    let rgba:Data
    if requested==320{rgba=canvas}else{rgba=getBytes(try NativeCanvasTextureResampler.resample(image:makeImage(canvas,960,480),outputPixelSize:CGSize(width:480,height:240)))}
    let width=requested*3,height=requested*3/2,ref=try Data(contentsOf:directory.appendingPathComponent("web-live-\(requested).rgba"));var outside=0,total=0,maxd=0
    let scale=Double(width)/320
    for i in stride(from:0,to:rgba.count,by:4){var delta=0;for c in 0..<4{delta=max(delta,abs(Int(rgba[i+c])-Int(ref[i+c])))};total+=delta>0 ? 1:0;maxd=max(maxd,delta)
     let x=Double((i/4)%width),y=Double((i/4)/width);if !(x>=floor(135*scale)&&x<ceil(226*scale)&&y>=floor(7*scale)&&y<ceil(128*scale)){outside+=delta>0 ? 1:0}}
    try rgba.write(to:out.appendingPathComponent("\(background)-\(requested).rgba"))
    results.append(["background":background,"requested":requested,"width":width,"height":height,"changedPixels":total,"maxDelta":maxd,"outsideMinifiedMaskChangedPixels":outside]);print(background,requested,total,maxd,"outside-mask",outside)
    guard outside==0 else {throw NSError(domain:"expanded binary control mismatched",code:1)}
   }
  }
  try JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("results.json"))
 }
}
