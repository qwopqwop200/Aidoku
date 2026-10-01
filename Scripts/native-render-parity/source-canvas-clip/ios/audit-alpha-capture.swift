import Foundation
import CoreGraphics
import ImageIO
import CryptoKit

// Read-only provenance audit. No changed pixels are written or substituted.
let input = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format:"%02x",$0) }.joined() }
func json(_ name: String) throws -> [String: Any] { try JSONSerialization.jsonObject(with:Data(contentsOf:input.appendingPathComponent(name))) as! [String:Any] }
func image(_ file:URL)->CGImage { CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(file as CFURL,nil)!,0,nil)! }
func canonical(_ image:CGImage)->Data {
    let c=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,
        space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo.byteOrder32Big.rawValue|CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
    return Data(bytes:c.data!,count:image.width*image.height*4)
}
func delta(_ a:Data,_ b:Data)->[String:Int] {
    guard a.count == b.count else{return ["changedPixels":-1]}
    var count=0,bytes=0,maxDelta=0
    a.withUnsafeBytes { l in b.withUnsafeBytes { r in
        let left=l.bindMemory(to:UInt8.self),right=r.bindMemory(to:UInt8.self)
        for i in stride(from:0,to:a.count,by:4) {
            var different=false
            for ch in 0..<4 {let d=abs(Int(left[i+ch])-Int(right[i+ch]));if d>0{different=true;bytes+=1;maxDelta=max(maxDelta,d)}}
            if different{count+=1}
        }
    } }
    return ["changedPixels":count,"changedBytes":bytes,"maxChannelDelta":maxDelta]
}
func pma(_ data:Data)->[String:Int] {
    var invalid=0,hidden=0,clear=0,opaque=0,partial=0
    data.withUnsafeBytes { b in
        let p=b.bindMemory(to:UInt8.self)
        for i in stride(from:0,to:data.count,by:4) {
            let a=p[i+3]
            if max(p[i],p[i+1],p[i+2])>a{invalid+=1}
            if a==0{clear+=1;if p[i] != 0 || p[i+1] != 0 || p[i+2] != 0 {hidden+=1}}
            else if a==255{opaque+=1}else{partial+=1}
        }
    }
    return ["invalidPMA":invalid,"hiddenRGBAtZeroAlpha":hidden,"clearPixels":clear,"opaquePixels":opaque,"partialAlphaPixels":partial]
}
var scenes:[[String:Any]]=[]
for background in ["transparent","opaque"] {
    let directory=input.appendingPathComponent(background)
    let dom=try json(background+"/web-dom-and-saved-masks.json")
    let records=dom["records"] as! [[String:Any]]
    var sources:[[String:Any]]=[], captures:[[String:Any]]=[]
    for r in records {
        let id=r["id"] as! String,url=r["png"] as! String,encoded=url.split(separator:",",maxSplits:1)[1]
        let original=Data(base64Encoded:String(encoded))!
        let file=directory.appendingPathComponent("source-canvas-\(id).png")
        let png=try Data(contentsOf:file),source=image(file)
        let canvas=try Data(contentsOf:directory.appendingPathComponent("source-canvas-\(id).rgba"))
        let native=try Data(contentsOf:directory.appendingPathComponent("source-native-\(id).rgba"))
        sources.append(["id":id,"width":source.width,"height":source.height,"frame":r["used"]!,
            "toDataURLSavedPNGExact":original==png,"PNGCanonicalDelta":delta(canonical(source),canvas),
            "nativeInputCanvasDelta":delta(canvas,native),"PNGHash":hash(png),"RGBAHash":hash(canvas),"PMA":pma(canvas),
            "PNGColorSpace":source.colorSpace?.name as String? ?? "nil"])
    }
    for prefix in ["web-live-160","web-live-320","native-live-160","native-live-320","native-live-backing"] {
        let png=directory.appendingPathComponent(prefix+".png"),decoded=image(png)
        let raw=try Data(contentsOf:directory.appendingPathComponent(prefix+".rgba"))
        let stride=decoded.width*4
        let point=[min(decoded.width-1,Int(Double(decoded.width)/320*290)),min(decoded.height-1,Int(Double(decoded.height)/160*145))]
        let index=point[1]*stride+point[0]*4
        captures.append(["file":prefix,"width":decoded.width,"height":decoded.height,
            "byteCountMatchesDimensions":raw.count==decoded.width*decoded.height*4,"PNGCanonicalDelta":delta(canonical(decoded),raw),
            "PNGColorSpace":decoded.colorSpace?.name as String? ?? "nil","PNGAlphaInfo":decoded.alphaInfo.rawValue,
            "PMA":pma(raw),"outsideSourceSampleCSS":[290,145],"outsideSourceRGBA":Array(raw[index..<index+4]),"RGBAHash":hash(raw)])
    }
    var binaryExpected=Data()
    for y in 0..<20 {for x in 0..<20 {
        if (x+y)%5<2 || x<3{binaryExpected.append(contentsOf:[0,0,0,0])}
        else{binaryExpected.append(contentsOf:[UInt8(23+x*9),UInt8(17+y*10),201,255])}
    }}
    let binary=try Data(contentsOf:directory.appendingPathComponent("source-native-binary.rgba"))
    let overlap=try Data(contentsOf:directory.appendingPathComponent("source-native-overlap.rgba"))
    scenes.append(["background":background,"sources":sources,"captures":captures,
        "binaryLiteralSourceExact":binary==binaryExpected,"binaryOverlapSourceExact":binary==overlap,
        "viewport":try json(background+"/capture-viewport.json"),"backingContext":try json(background+"/native-live-backing-capture.json")])
}
let original=try Data(contentsOf:input.appendingPathComponent("immutable-actual44-mask0.png"))
let report:[String:Any]=["scope":"read-only actual iOS48 input/capture/PMA/color-space audit, not a pixel algorithm model",
    "originalMaskPNGHash":hash(original),"originalMaskBytes":original.count,"fixture":try json("fixture-provenance.json"),
    "scenes":scenes,"algorithmOrOracleChanges":false]
try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("report.json"))
print(output.appendingPathComponent("report.json").path)
