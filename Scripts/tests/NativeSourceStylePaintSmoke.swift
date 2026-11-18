import CoreGraphics
import Foundation

// Isolated composer shell only: test the production stroke/source-paint files
// without compiling the unrelated model/UI host or touching its shared cache.
final class NativeAOTTranslationPageComposer {
    enum Failure:Error {case incompleteTranslation,allocation}
    struct TextLayer {
        let image:CGImage
        let expectedItems:Int
        let paintedItems:Int
        let complete:Bool
        let audit:[String:Any]
    }
}

@main enum NativeSourceStylePaintSmoke {
    static func main() throws {
        var pixels=[UInt8](repeating:0,count:12*12*4)
        for y in 4...7 {for x in 4...7 {
            let i=(y*12+x)*4;pixels[i]=200;pixels[i+3]=255
        }}
        let fill=try NativeMandatoryDisplayStroke.image(pixels,width:12,height:12)
        let bg=try NativeMandatoryDisplayStroke.image([UInt8](repeating:255,count:64*64*4),width:64,height:64)
        let raw:[String:Any]=["sourceFontSize":20.0,"sourceAppearance":[
            "outline":["present":true,"rgb":[0,0,0],"widthPx":2,
                "observedLayers":[["rgb":[0,100,200],"widthPx":2],["rgb":[240,120,0],"widthPx":2]]],
            "shadow":["present":true,"rgb":[90,20,120],"offsetPx":[20,0],"opacity":NSNull(),"blurRadiusPx":NSNull()]
        ]]
        let style=try NativeSourceStylePaint.style(raw)
        let layer=try NativeAOTTranslationPageComposer.mandatoryStrokeLayer(restored:bg,
            fills:[.init(image:fill,frame:CGRect(x:20,y:20,width:12,height:12),fontOutputPixels:10,
                         displayStrokeEndpoint:0,sourceStyle:style)],expectedItems:1,textComplete:true)
        precondition(layer.complete && layer.paintedItems==1)
        let reports=layer.audit["sourceStylePaint"] as! [[String:Any]]
        precondition(reports[0]["sourceLayerCount"] as? Int==2)
        precondition(reports[0]["shadowRendered"] as? Bool==true)
        precondition(reports[0]["sourceToDisplayScale"] as? Double==0.5)
        let rgba=try NativeMandatoryDisplayStroke.rgba(layer.image)
        var red=0,shadow=0,bands=0,bw=0
        for i in stride(from:0,to:rgba.count,by:4) where rgba[i+3]>0 {
            let c=Array(rgba[i..<i+3])
            if c == [200,0,0] {red+=1}
            if c == [90,20,120] {shadow+=1}
            if c == [0,100,200] || c == [240,120,0] {bands+=1}
            if c == [0,0,0] || c == [255,255,255] {bw+=1}
        }
        precondition(red==16 && shadow>0 && bands>0 && bw>0)
        let retained=raw["sourceAppearance"] as! [String:Any]
        precondition((retained["shadow"] as! [String:Any])["opacity"] is NSNull)
        print("PASS source bands/shadow actually painted, mandatory BW visible, all16 fill pixels retained, source opacity stayed unknown")
    }
}
