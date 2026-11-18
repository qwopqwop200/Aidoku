import CoreGraphics
import Foundation

/// Strict original uniform rectangular enclosure, not a semantic balloon or RF
/// class. Non-text holes must be explained by the source-bound removal mask.
enum NativeClosedSourceRectangle {
    static func inspect(rgba:[UInt8],component:[Int],width:Int,height:Int,crop:CGRect,source:CGRect,
                        background:[Double],removalMask:CGImage) -> [String:Any] {
        func reject(_ reason:String)->[String:Any] { ["accepted":false,"reason":reason,"originalPixelsMeasured":true] }
        guard width>0,height>0,width<=1_048_576/height,!component.isEmpty,rgba.count==width*height*4,
              component.allSatisfy({$0>=0 && $0<width*height}),background.count==3 else{return reject("missing-component")}
        var x0=width,x1 = -1,y0=height,y1 = -1
        var member=[Bool](repeating:false,count:width*height)
        for i in component {
            member[i]=true;x0=min(x0,i%width);x1=max(x1,i%width);y0=min(y0,i/width);y1=max(y1,i/width)
        }
        guard x0>0,y0>0,x1+1<width,y1+1<height else{return reject("component-clipped-by-context")}
        let bounds=CGRect(x:crop.minX+CGFloat(x0),y:crop.minY+CGFloat(y0),width:CGFloat(x1-x0+1),height:CGFloat(y1-y0+1))
        guard bounds.contains(source) else{return reject("source-not-contained-by-original-surface")}
        let edges=[(y0...y1).map{$0*width+x0},(y0...y1).map{$0*width+x1},
                   (x0...x1).map{y0*width+$0},(x0...x1).map{y1*width+$0}]
        guard edges.allSatisfy({Double($0.filter{member[$0]}.count)/Double($0.count)>=0.98}) else {
            return reject("not-a-rectangular-source-surface; irregular-contours-unimplemented")
        }
        func gap(_ i:Int)->Double {
            guard rgba[i*4+3]>=245 else{return 255}
            return (0..<3).map{abs(Double(rgba[i*4+$0])*255/Double(rgba[i*4+3])-background[$0])}.max()!
        }
        let outside=[(y0...y1).map{$0*width+x0-1},(y0...y1).map{$0*width+x1+1},
                     (x0...x1).map{(y0-1)*width+$0},(x0...x1).map{(y1+1)*width+$0}]
        guard outside.allSatisfy({Double($0.filter{gap($0)>36}.count)/Double($0.count)>=0.98}) else {
            return reject("original-exterior-boundary-not-closed")
        }
        guard let mask=removalMask.cropping(to:crop),mask.width==width,mask.height==height else{return reject("source-mask-crop-unavailable")}
        var owned=[UInt8](repeating:0,count:width*height)
        let ok=owned.withUnsafeMutableBytes { b->Bool in
            guard let c=CGContext(data:b.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width,
                space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue) else{return false}
            c.draw(mask,in:CGRect(x:0,y:0,width:width,height:height));return true
        }
        guard ok else{return reject("source-mask-decode-failed")}
        var ownedHolePixels=0
        for y in y0...y1 {for x in x0...x1 {
            let i=y*width+x
            if gap(i)>8 {
                guard owned[i]>=128 else{return reject("unowned-artwork-or-preserved-lettering-inside-surface")}
                ownedHolePixels += 1
            }
        }}
        return ["accepted":true,"originalPixelsMeasured":true,"rectOutputPixels":[bounds.minX,bounds.minY,bounds.width,bounds.height],
            "ownedHolePixels":ownedHolePixels,"unownedHolesAllowed":false,"backgroundRGB":background,
            "authority":"original closed uniform rectangular surface + source-bound removal ownership; not RF or semantic balloon truth"]
    }
}
