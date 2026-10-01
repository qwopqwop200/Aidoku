import AppKit
import CoreGraphics
import Foundation
import ImageIO
import WebKit
@MainActor final class Probe:NSObject,WKNavigationDelegate {
 let view=WKWebView(frame:NSRect(x:0,y:0,width:390,height:700));let directory:URL;let output:URL;var native:[[String:Any]]=[];var timer:Timer?
 init(directory:URL,output:URL)throws {
  self.directory=directory;self.output=output;super.init();view.navigationDelegate=self
  let items=try JSONSerialization.jsonObject(with:Data(contentsOf:directory.appendingPathComponent("web-layout.json"))) as! [[String:Any]]
  let original=CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(directory.appendingPathComponent("source.png") as CFURL,nil)!,0,nil)!
  let scale=min(1,sqrt(4_000_000/Double(original.width)/Double(original.height))),w=Int(floor(Double(original.width)*scale)),h=Int(floor(Double(original.height)*scale))
  let bitmap=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue)!
  bitmap.draw(original,in:CGRect(x:0,y:0,width:w,height:h));let image=bitmap.makeImage()!
  let destination=CGImageDestinationCreateWithURL(output.deletingLastPathComponent().appendingPathComponent("sampling-source.png") as CFURL,"public.png" as CFString,1,nil)!
  CGImageDestinationAddImage(destination,image,nil);CGImageDestinationFinalize(destination)
  let budget=NativeSourceColorSamplingStage.Budget(remainingSamples:items.filter{$0["sourceColorEligible"] as? Bool == true}.count)
  let reader=NativeSourcePixelReader(image:image);defer{reader.release()};let stage=NativeSourceColorSamplingStage(image:image,enabled:true,phase:"translation",budget:budget,pixelReader:reader)
  for item in items where item["sourceColorEligible"] as? Bool == true {
   let geometry:[String:Any]=["polygon":item["sourcePolygon"]!,"excluded":items.filter{($0["id"] as? String) != (item["id"] as? String)}.map{$0["sourcePolygon"]!}]
   let bounds=(item["sourceBounds"] as! [NSNumber]).map(\.doubleValue)
   native.append(["id":item["id"]!,"result":stage.sample(bounds:bounds,geometry:geometry) as Any? ?? NSNull(),"budget":[budget.pixels,budget.detailPixels,budget.remainingSamples ?? -1],"stats":[stage.stats.pixels,stage.stats.samples,stage.stats.hits]])
  }
 }
 func start(){timer=Timer.scheduledTimer(withTimeInterval:60,repeats:false){_ in MainActor.assumeIsolated{() -> Void in exit(3)}};view.loadHTMLString("<html><body></body></html>",baseURL:nil)}
 func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!){
  do{
   let src=try String(contentsOf:output.deletingLastPathComponent().appendingPathComponent("source.js"),encoding:.utf8)
   let geom=try String(contentsOf:output.deletingLastPathComponent().appendingPathComponent("geometry.js"),encoding:.utf8)
   let raw=try String(contentsOf:directory.appendingPathComponent("web-layout.json"),encoding:.utf8)
   let image=try Data(contentsOf:output.deletingLastPathComponent().appendingPathComponent("sampling-source.png")).base64EncodedString()
   let js=src+"\n"+geom+"\n"+"""
   const items=\(raw),image=new Image();image.src='data:image/png;base64,\(image)';await image.decode();
   const budget={pixels:393216,detailPixels:98304,remainingSamples:items.filter(x=>x.sourceColorEligible).length},reader=aidokuSourcePixelReader(image),stage=aidokuSourceColorSampler(image,true,'translation',budget,reader),rows=[];
   for(const item of items.filter(x=>x.sourceColorEligible)){const result=stage.sample(item.sourceBounds,{polygon:item.sourcePolygon,excluded:items.filter(x=>x!==item).map(x=>x.sourcePolygon)});rows.push({id:item.id,result,budget:[budget.pixels,budget.detailPixels,budget.remainingSamples],stats:[stage.stats.pixels,stage.stats.samples,stage.stats.hits]});}
   reader.release();return {rows,userAgent:navigator.userAgent};
   """
   view.callAsyncJavaScript(js,arguments:[:],in:nil,in:.page){r in do{self.timer?.invalidate();let web=try r.get();let d:[String:Any]=["native":self.native,"web":web];try JSONSerialization.data(withJSONObject:d,options:[.sortedKeys,.prettyPrinted]).write(to:self.output);print("Captured actual source stage pairs");exit(0)}catch{print(error);exit(2)}}
  }catch{print(error);exit(2)}
 }
}
@main struct Main{@MainActor static func main()throws{let app=NSApplication.shared;let p=try Probe(directory:URL(fileURLWithPath:CommandLine.arguments[1]),output:URL(fileURLWithPath:CommandLine.arguments[2]));p.start();withExtendedLifetime(p){app.run()}}}
