import Foundation
import CoreGraphics
import ImageIO
func context(_ width: Int,_ height: Int)->CGContext {
    CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo.byteOrder32Big.rawValue|CGImageAlphaInfo.premultipliedLast.rawValue)!
}
func decoded(_ data:Data)->CGImage { CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(data as CFData,nil)!,0,nil)! }
func canonical(_ image:CGImage)->Data {
    let c=context(image.width,image.height);c.interpolationQuality = .none;c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height));return Data(bytes:c.data!,count:image.width*image.height*4)
}
@main struct Proof {
    static func main()throws {
        let directory=URL(fileURLWithPath:CommandLine.arguments[1])
        let records=try JSONSerialization.jsonObject(with:Data(contentsOf:directory.appendingPathComponent("web.json"))) as! [[String:Any]]
        var results:[[String:Any]]=[]
        for index in 0..<2 {
            let web=decoded(try Data(contentsOf:directory.appendingPathComponent("web-\(index).png")))
            let c=context(web.width,web.height);let scale=CGFloat(web.width)/320
            c.scaleBy(x:scale,y:scale);c.translateBy(x:0,y:160);c.scaleBy(x:1,y:-1)
            if index==1 { c.setFillColor(CGColor(colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!,components:[41.0/255,65.0/255,87.0/255,1])!);c.fill(CGRect(x:0,y:0,width:320,height:160)) }
            for record in records {
                let png=(record["png"] as! String).split(separator:",",maxSplits:1)[1]
                let source=decoded(Data(base64Encoded:String(png))!)
                let f=record["used"] as! [Double], rect=CGRect(x:f[0],y:f[1],width:f[2],height:f[3])
                let filtered=try NativeCanvasTextureResampler.resample(image:source,outputPixelSize:CGSize(width:rect.width*scale,height:rect.height*scale))
                c.saveGState();c.interpolationQuality = .none;c.translateBy(x:rect.minX,y:rect.maxY);c.scaleBy(x:1,y:-1);c.draw(filtered,in:CGRect(origin:.zero,size:rect.size));c.restoreGState()
            }
            let native=canonical(c.makeImage()!), reference=canonical(web)
            var changed=0,delta=0
            for i in stride(from:0,to:native.count,by:4) {
                var pixel=false
                for j in 0..<4 { let d=abs(Int(native[i+j])-Int(reference[i+j]));delta=max(delta,d);pixel = pixel || d>0 }
                if pixel { changed+=1 }
            }
            try native.write(to:directory.appendingPathComponent("native-\(index).rgba"));try reference.write(to:directory.appendingPathComponent("web-\(index).rgba"))
            print("background \(index) changed \(changed) max \(delta)")
            results.append(["background":index==0 ? "transparent" : "opaque","changedPixels":changed,"maxDelta":delta,"dimensions":[web.width,web.height]])
        }
        try JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("report.json"))
    }
}
