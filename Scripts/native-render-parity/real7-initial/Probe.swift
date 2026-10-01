import Foundation
import CoreGraphics
import ImageIO
import Testing
@main struct InitialProbe {
    static func main() async throws {
        if CommandLine.arguments.contains("--tests") { exit(await Testing.__swiftPMEntryPoint()) }
        let p=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/native-render-parity/verify-image-build35-snapshot/real-comic-0007")
        let data=try Data(contentsOf:p.appendingPathComponent("source.png"))
        let original=CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(data as CFData,nil)!,0,nil)!
        let reduction=min(1,sqrt(4_000_000/Double(original.width)/Double(original.height)))
        let w=Int(floor(Double(original.width)*reduction)),h=Int(floor(Double(original.height)*reduction))
        let cg=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        cg.interpolationQuality = .high;cg.draw(original,in:CGRect(x:0,y:0,width:w,height:h));let image=cg.makeImage()!
        let items=try JSONDecoder().decode([NativeTranslationLayoutItem].self,from:Data(contentsOf:p.appendingPathComponent("web-layout.json")))
        let frame=CGRect(x:0,y:(700-390*Double(h)/Double(w))/2,width:390,height:390*Double(h)/Double(w))
        let originalFrame=CGRect(x:items[0].sourceFrame[0],y:items[0].sourceFrame[1],width:items[0].sourceFrame[2],height:items[0].sourceFrame[3])
        let layout=NativeTranslationLayout(imageSize:CGSize(width:3192,height:2254),sourceRect:originalFrame,viewport:CGSize(width:390,height:700),items:items)
        let settings=try JSONDecoder().decode(IPhoneOverlaySettings.self,from:Data(contentsOf:p.appendingPathComponent("settings.json")))
        let restored=try NativeTranslationRestoration.prepare(image:image,layout:layout,settings:settings,cleanupGeometry:.init(frame:frame,clip:frame))
        let refined=try NativeTranslationLayoutPlanner.refining(layout:layout,restoration:restored,settings:settings,sourceImage:image)
        let session=NativeTypographyPostPolish.rendererGrowthSession(layout:refined,restoration:restored,settings:settings,sourceImage:image)
        let recovered=refined.items.map { item in item.keptLettering || item.text.isEmpty ? item:session.context.captionRecovering(item) }
        let entries=recovered.filter { !$0.keptLettering && !$0.text.isEmpty && $0.sourceColorEligible && !$0.sourceTextOnly && !$0.vertical && $0.text.utf16.count<=180 && ($0.nearUprightRotation ?? 0)==0 }.map { NativeTypographyPostPolish.FontEntry(id:$0.id,source:$0.sourceFontSize ?? $0.fontSize,font:$0.fontSize,script:$0.fontScript,vertical:$0.vertical,column:$0.balancedColumn) }
        var rows:[[String:Any]]=[]
        for (i,item) in recovered.enumerated() where !item.keptLettering && !item.text.isEmpty {
            rows.append(["id":item.id,"prepared":items[i].fontSize,"refined":refined.items[i].fontSize,"recovered":item.fontSize,"rect":[item.x,item.y,item.width,item.height],"column":item.balancedColumn,"source":item.sourceFontSize as Any,"referenceResolved":item.smallTextReferenceResolved as Any,"sample":restored.appearances[item.id]?.sourceSample as Any? ?? NSNull()])
        }
        let result:[String:Any]=["rows":rows,"entries":try JSONSerialization.jsonObject(with:JSONEncoder().encode(entries)),"clusters":try JSONSerialization.jsonObject(with:JSONEncoder().encode(NativeTypographyPostPolish.fontClusters(entries))),"dimensions":[w,h]]
        let suffix=ProcessInfo.processInfo.environment["REAL7_CSS_FIT"] == nil ? "baseline":"css-fit"
        let out=p.deletingLastPathComponent().appendingPathComponent("real7-initial-host-"+suffix+".json")
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:out);print(out.path)
    }
}
