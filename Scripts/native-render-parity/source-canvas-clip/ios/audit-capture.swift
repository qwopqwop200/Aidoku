import Foundation
import CoreGraphics
import ImageIO
import CryptoKit

// Read-only audit. Shift comparisons below diagnose a viewport translation;
// they never replace saved pixels or the actual strict parity gate.
let input = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
func json(_ file: URL) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
}
func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format:"%02x", $0) }.joined() }
func image(_ file: URL) throws -> CGImage {
    CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(file as CFURL, nil)!, 0, nil)!
}
func canonical(_ image: CGImage) -> Data {
    let context = CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,
        space:CGColorSpace(name:CGColorSpace.sRGB)!, bitmapInfo:CGBitmapInfo.byteOrder32Big.rawValue|CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
    return Data(bytes:context.data!,count:image.width*image.height*4)
}
func changes(_ a: Data, _ b: Data) -> Int {
    guard a.count == b.count else { return -1 }
    var count = 0
    a.withUnsafeBytes { left in b.withUnsafeBytes { right in
        let x=left.bindMemory(to:UInt8.self),y=right.bindMemory(to:UInt8.self)
        for p in stride(from:0,to:a.count,by:4) {
            if x[p] != y[p] || x[p+1] != y[p+1] || x[p+2] != y[p+2] || x[p+3] != y[p+3] { count += 1 }
        }
    } }
    return count
}
func borderBounds(_ data: Data, width: Int, colors: [[Int]]) -> [[Int]] {
    let byRGB = Dictionary(uniqueKeysWithValues:colors.enumerated().map{($0.element[0]<<16|$0.element[1]<<8|$0.element[2],$0.offset)})
    var result=colors.map{_ in [width,Int.max,-1,-1]}
    data.withUnsafeBytes { buffer in
        let bytes=buffer.bindMemory(to:UInt8.self)
        for p in stride(from:0,to:data.count,by:4) {
            if bytes[p] == 255 && bytes[p+1] == 255 && bytes[p+2] == 255 { continue }
            let key=Int(bytes[p])<<16|Int(bytes[p+1])<<8|Int(bytes[p+2])
            guard bytes[p+3] == 255,let i=byRGB[key] else { continue }
            let x=(p/4)%width,y=(p/4)/width
            result[i][0]=min(result[i][0],x);result[i][1]=min(result[i][1],y)
            result[i][2]=max(result[i][2],x);result[i][3]=max(result[i][3],y)
        }
    }
    return result.map{$0[2]<0 ? []:[$0[0],$0[1],$0[2]-$0[0]+1,$0[3]-$0[1]+1]}
}
var scenes:[[String:Any]]=[]
for scene in ["original-six","negative-global"] {
    let folder=input.appendingPathComponent(scene),dom=try json(folder.appendingPathComponent("web-dom-and-saved-masks.json"))
    let records=dom["records"] as! [[String:Any]], colors=records.map{$0["color"] as! [Int]}
    var sources:[[String:Any]]=[], captures:[[String:Any]]=[]
    for r in records {
        let id=r["id"] as! String,base64=(r["png"] as! String).split(separator:",",maxSplits:1)[1]
        let original=Data(base64Encoded:String(base64))!,png=try Data(contentsOf:folder.appendingPathComponent("source-\(id).png"))
        let source=try image(folder.appendingPathComponent("source-\(id).png")),actual=try Data(contentsOf:folder.appendingPathComponent("source-\(id).rgba"))
        let used=r["used"] as! [Double],parent=r["parent"] as! [Double],raw=r["raw"] as! [Double]
        func unit(_ x:Double)->Double { Double((Float(x)*64).rounded(.towardZero))/64 }
        let derived=[unit(raw[0])+parent[0],unit(raw[1])+parent[1],unit(raw[2]),unit(raw[3])]
        sources.append(["id":id,"toDataURLMatchesSavedPNG":original==png,"sourcePNGHash":hash(png),
            "sourcePNGCanonicalMatchesRGBA":canonical(source)==actual,"sourceColorSpace":source.colorSpace?.name as String? ?? "nil",
            "DOMFrameMatchesNativeIndependentLayoutUnit":used==derived,"DOMFrame":used,"independentlyDerivedFrame":derived])
    }
    for mode in ["pdf","live-320","live-640"] + (scene == "negative-global" ? ["pdf-negative-crop"]:[]) {
        let webImage=try image(folder.appendingPathComponent("web-\(mode).png"))
        let nativeImage=try image(folder.appendingPathComponent("native-\(mode).png"))
        let web=try Data(contentsOf:folder.appendingPathComponent("web-\(mode).rgba"))
        let native=try Data(contentsOf:folder.appendingPathComponent("native-\(mode).rgba"))
        var report:[String:Any]=["mode":mode,"webSize":[webImage.width,webImage.height],"nativeSize":[nativeImage.width,nativeImage.height],
            "webPNGCanonicalChangedPixels":changes(canonical(webImage),web),"nativePNGCanonicalChangedPixels":changes(canonical(nativeImage),native),
            "rawChangedPixels":changes(web,native),"webRGBAHash":hash(web),"nativeRGBAHash":hash(native),
            "webColorSpace":webImage.colorSpace?.name as String? ?? "nil","nativeColorSpace":nativeImage.colorSpace?.name as String? ?? "nil"]
        if mode.hasPrefix("live") {
            let scale=Double(webImage.width)/640,shift=Int(62*scale),stride=webImage.width*4
            let w=borderBounds(web,width:webImage.width,colors:colors),n=borderBounds(native,width:nativeImage.width,colors:colors)
            report["opaqueBorderBounds"]=records.indices.map{["id":records[$0]["id"]!,"web":w[$0],"native":n[$0]]}
            // Same saved raw data, diagnostic slices only. Remaining differences
            // still fail the original exact gate; no translated file is saved.
            report["diagnostic62CSSShiftRows"]=shift
            report["diagnosticChangedPixelsAfterComparingNativeAtPlus62CSS"]=changes(
                web.subdata(in:(shift*stride)..<web.count),native.subdata(in:0..<(native.count-shift*stride)))
            report["remainingScope"]="full RGBA gate remains untouched; corrected capture required"
        }
        captures.append(report)
    }
    scenes.append(["scene":scene,"innerWidth":dom["innerWidth"]!,"innerHeight":dom["innerHeight"]!,
        "visualViewport":dom["visualViewport"]!,"sourceAudit":sources,"captures":captures])
}
let report:[String:Any]=["scope":"read-only actual iOS42 provenance audit; no oracle substitutions", "scenes":scenes,
    "confirmedHarnessDefects":["automatic safe-area viewport adjustment shifts live pixels62CSS; frozen reader uses.never",
        "negative PDF crop white background was limited to layout page, leaving transparent strips"],
    "genuineRemainingPaintScope":"PDF source canvas destination rounding/interpolation; parity author owns frame analysis"]
try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("report.json"))
print("audit saved",output.appendingPathComponent("report.json").path)
