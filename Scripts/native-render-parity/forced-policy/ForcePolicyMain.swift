import CoreGraphics
import Foundation
import CryptoKit

enum ForceTrace {
    nonisolated(unsafe) static var directory = URL(fileURLWithPath: "/tmp")
    nonisolated(unsafe) static var prefix = ""
    nonisolated(unsafe) static var donorQuality: [[String: Any]] = []
    static func bitmap(_ name: String, _ values: [UInt8]) {
        try! Data(values).write(to: directory.appendingPathComponent(prefix + "-" + name + ".bin"))
    }
    static func quality(_ q: NativeResidualProof.Quality) {
        donorQuality.append(["safe": q.safe,"erased": q.erased,"noDonor": q.noDonor,"continuous": q.continuous,
            "seams": q.seams,"wide": q.wide,"wideDiscordant": q.wideDiscordant,"maxSpan": q.maxSpan])
    }
    static func rect(_ r: [Double]) -> CGRect { CGRect(x:r[0],y:r[1],width:r[2],height:r[3]) }
    static func rects(_ raw: Any?) -> [CGRect] { (raw as? [[Double]] ?? []).map(rect) }
    static func polygons(_ raw: Any?) -> [[CGPoint]] {
        (raw as? [[[Double]]] ?? []).map { $0.map { CGPoint(x:$0[0],y:$0[1]) } }
    }
    static func run(_ file: String) throws {
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf:URL(fileURLWithPath:file))) as! [String:Any]
        let id = raw["id"] as! String, w = raw["width"] as! Int, h = raw["height"] as! Int
        let rgba = [UInt8](try Data(contentsOf:URL(fileURLWithPath:raw["rgbaFile"] as! String)))
        let palette = NativeRestorationPixels.palette(raw["palette"] as! [String:Any])!
        let options = raw["options"] as! [String:Any], box = rect(raw["box"] as! [Double])
        for keepExcluded in [true,false] {
            prefix = id + (keepExcluded ? "" : "-without-offcrop-kept")
            var settings = NativeForcedSourceInpainting.Options()
            settings.auxiliary = rects(options["auxiliary"])
            settings.excluded = keepExcluded ? rects(options["excluded"]) : []
            settings.donorExcluded = rects(options["donorExcluded"])
            settings.polygons = polygons(options["polygons"])
            settings.excludedPolygons = polygons(options["excludedPolygons"])
            settings.vertical = options["vertical"] as? Bool ?? false
            settings.trailing = options["trailing"] as? Double ?? 0
            settings.glyphSize = options["glyphSize"] as? Double ?? 0
            settings.requireSafeDonors = options["requireSafeDonors"] as? Bool ?? false
            let segmentation = NativeSourceGlyphSegmentation.forcedTextMask(rgba:rgba,width:w,height:h,box:box,
                palette:NativeResidualProof.componentSegmentationPalette(palette),
                options:.init(polygons:settings.polygons,excludedPolygons:settings.excludedPolygons,glyphSize:settings.glyphSize))
            if let segmentation {
                bitmap("component-core",segmentation.sourceCoreCandidateMask)
                bitmap("component-outline",segmentation.sourceOutlineCandidateMask)
            }
            var p = NativeRestorationPixels(width:w,height:h); p.rgba = rgba
            donorQuality = []
            let component = NativeResidualProof.forceComponent(p,box:box,auxiliary:settings.auxiliary,
                excluded:settings.excluded,palette:palette,vertical:settings.vertical,polygons:settings.polygons,
                excludedPolygons:settings.excludedPolygons,glyphSize:settings.glyphSize,trailing:settings.trailing,
                donorExcluded:settings.donorExcluded,requireSafeDonors:settings.requireSafeDonors)
            let componentQuality = donorQuality
            donorQuality = []
            let legacy = NativeForcedSourceInpainting.restore(rgba:rgba,width:w,height:h,box:box,palette:palette,options:settings)
            let output: [String:Any] = ["id":id,"keptExclusions":keepExcluded,
                "inputRGBAsha256":SHA256.hash(data:Data(rgba)).map { String(format:"%02x",$0) }.joined(),
                "component": component.map { ["method":$0.method ?? "", "erased":($0.layoutSafe ?? []).reduce(0) { $0+Int($1) }] } as Any? ?? NSNull(),
                "componentDonorQuality":componentQuality,
                "legacy":legacy.result.map { ["method":$0.method,"erased":$0.erased] } as Any? ?? NSNull(),
                "legacyFailure":legacy.failure,"legacyDonorQuality":donorQuality]
            try JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent(prefix+".json"))
        }
    }
}
@main enum Main {
    static func main() throws {
        ForceTrace.directory = URL(fileURLWithPath:CommandLine.arguments[1])
        for file in CommandLine.arguments.dropFirst(2) { try ForceTrace.run(file) }
    }
}
