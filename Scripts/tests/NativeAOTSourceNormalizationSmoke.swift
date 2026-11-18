import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

enum SourceSmokeFailure:Error {case invalid(String)}
func checkSource(_ image:CGImage)throws->(String,String,Bool) {
    let old=try FrozenScalarAlpha.prepare(source:image),actual=try NativeAOTAlphaComposition.prepare(source:image)
    guard old.canonicalRGBA==actual.canonicalRGBA,old.inferenceRGB==actual.inferenceRGB,
          old.hasTransparency==actual.hasTransparency else {throw SourceSmokeFailure.invalid("source-byte-parity")}
    return (SHA256.hash(data:Data(actual.canonicalRGBA)).map{String(format:"%02x",$0)}.joined(),
            SHA256.hash(data:Data(actual.inferenceRGB)).map{String(format:"%02x",$0)}.joined(),actual.hasTransparency)
}
func cornerControls()throws->Int {
    var count=0
    for (w,h) in [(1,1),(31,17),(129,2),(5,7)] {
        for space in [CGColorSpace(name:CGColorSpace.sRGB)!,CGColorSpace(name:CGColorSpace.displayP3)!] {
            for premultiplied in [true,false] {
                for pattern in 0..<3 {
                    var bytes=[UInt8](repeating:0,count:w*h*4)
                    for p in 0..<w*h {
                        let alpha=pattern==0 ? 255:(pattern==1 ? 0:[0,1,127,128,254,255][p%6])
                        for c in 0..<3 {
                            let value=(p*17+c*53+31)&255
                            bytes[p*4+c]=UInt8(premultiplied ? (value*alpha)/255:value)
                        }
                        bytes[p*4+3]=UInt8(alpha)
                    }
                    guard let provider=CGDataProvider(data:Data(bytes) as CFData),let image=CGImage(width:w,height:h,
                        bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:w*4,space:space,
                        bitmapInfo:CGBitmapInfo(rawValue:(premultiplied ? CGImageAlphaInfo.premultipliedLast:CGImageAlphaInfo.last).rawValue|CGBitmapInfo.byteOrder32Big.rawValue),
                        provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) else {throw SourceSmokeFailure.invalid("fixture")}
                    _ = try checkSource(image);count+=1
                }
            }
        }
        for components in [1,3] {
            let bytes=(0..<w*h*components).map{UInt8(($0*19+37)&255)}
            guard let provider=CGDataProvider(data:Data(bytes) as CFData),let image=CGImage(width:w,height:h,
                bitsPerComponent:8,bitsPerPixel:components*8,bytesPerRow:w*components,
                space:components==1 ? CGColorSpaceCreateDeviceGray():CGColorSpace(name:CGColorSpace.sRGB)!,
                bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.none.rawValue),provider:provider,
                decode:nil,shouldInterpolate:false,intent:.defaultIntent) else {throw SourceSmokeFailure.invalid("opaque-fixture")}
            _ = try checkSource(image);count+=1
        }
    }
    var bad=false
    do {_ = try NativeAOTAlphaComposition.prepare(canonicalRGBA:[200,0,0,1],width:1,height:1,encoding:.premultipliedRGBA8)}
    catch NativeAOTAlphaComposition.Failure.invalidPremultiplication {bad=true}
    guard bad else {throw SourceSmokeFailure.invalid("invalid-premultiplication-no-longer-rejected")}
    return count
}
@main struct SourceNormalizationSmoke {
    static func main()throws {
        let corners=try cornerControls()
        var count=0
        while let line=readLine() {
            let row:[String:Any]=try autoreleasepool {
                let r=try JSONSerialization.jsonObject(with:Data(line.utf8)) as! [String:Any]
                let data=try Data(contentsOf:URL(fileURLWithPath:r["source"] as! String))
                guard SHA256.hash(data:data).map({String(format:"%02x",$0)}).joined()==r["sourceSHA256"] as? String,
                      let src=CGImageSourceCreateWithData(data as CFData,nil),let image=CGImageSourceCreateImageAtIndex(src,0,nil)
                else {throw SourceSmokeFailure.invalid("source-reference")}
                let proof=try checkSource(image)
                if let rgba=r["expectedRGBA_SHA256"] as? String,let rgb=r["expectedRGB_SHA256"] as? String {
                    guard proof.0==rgba,proof.1==rgb else {throw SourceSmokeFailure.invalid("actual-neural-bank-source-binding")}
                }
                return ["page_id":r["page_id"]!,"split":r["split"]!,"status":"PASS-production-canonicalRGBA-RGB-hasTransparency-scalar-parity",
                    "RGBA_SHA256":proof.0,"RGB_SHA256":proof.1,"hasTransparency":proof.2,
                    "actualNNSourceBindingMatched":r["expectedRGBA_SHA256"] != nil]
            }
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]));FileHandle.standardOutput.write(Data([10]))
            count+=1
        }
        FileHandle.standardError.write(Data("PASS actual production vs frozen scalar source normalization: \(count) source rows + \(corners) transparent/partial/opaque sRGB/DisplayP3/gray/RGB24 corner fixtures; invalid premultiplication rejection; models/predictions/API0\n".utf8))
    }
}
