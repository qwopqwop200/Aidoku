import CoreGraphics
import Foundation

// The host shims retain production palette parsing and max-channel distance.
// Pixel algorithms, glyph segmentation and every quality policy compile unchanged.
struct NativeRestorationRGB { let channels: [Double]; init(_ values: [Double]) { channels = values } }
struct NativeRestorationPixels {
    struct Palette {
        var foreground: NativeRestorationRGB; var background: NativeRestorationRGB; var stroke: NativeRestorationRGB?
        var metadata: [String: Any] = [:]
        var sourceInk: [String: Any]? { metadata["sourceInk"] as? [String: Any] }
        var verifiedForeground: NativeRestorationRGB? { metadata.isEmpty ? foreground : NativeRestorationPixels.rgb(metadata["foreground"]) }
        var verifiedBackground: NativeRestorationRGB? { metadata.isEmpty ? background : NativeRestorationPixels.rgb(metadata["background"]) }
    }
    static func rgb(_ value: Any?) -> NativeRestorationRGB? {
        guard let channels = value as? [NSNumber], channels.count == 3 else { return nil }
        let values = channels.map(\.doubleValue)
        guard values.allSatisfy({ $0.isFinite && (0...255).contains($0) }) else { return nil }
        return NativeRestorationRGB(values)
    }
    static func palette(_ sample: [String: Any]) -> Palette? {
        guard rgb(sample["foreground"]) != nil || rgb(sample["background"]) != nil ||
            rgb((sample["sourceInk"] as? [String: Any])?["foreground"]) != nil else { return nil }
        let foreground = rgb(sample["foreground"]) ?? NativeRestorationRGB([255, 255, 255])
        return Palette(foreground: foreground, background: rgb(sample["background"]) ?? NativeRestorationRGB([255, 255, 255]), stroke: rgb(sample["stroke"]), metadata: sample)
    }
}
enum NativeObservedRestorationHelpers {
    static func distance(_ p: [Double], _ color: [Double]?) -> Double {
        guard let color, color.count == 3 else { return .infinity }
        return max(abs(p[0] - color[0]), abs(p[1] - color[1]), abs(p[2] - color[2]))
    }
}
func rectangles(_ input: Any?) -> [CGRect] {
    (input as? [[Double]] ?? []).compactMap { r in r.count == 4 ? CGRect(x:r[0],y:r[1],width:r[2],height:r[3]):nil }
}
func polygons(_ input: Any?) -> [[CGPoint]] {
    (input as? [[[Double]]] ?? []).map { $0.compactMap { $0.count == 2 ? CGPoint(x:$0[0],y:$0[1]):nil } }
}
func surface(_ s: NativeResidualProof.Surface) -> [String: Any] {
    var r:[String:Any] = ["safe":s.safe,"reason":s.reason,"samples":s.samples]
    if let value=s.coefficients { r["coefficients"]=value }
    if s.rmse.isFinite {r["rmse"]=s.rmse};if s.outliers.isFinite {r["outliers"]=s.outliers}
    if s.localRMSE.isFinite {r["localSamples"]=s.localSamples;r["localRMSE"]=s.localRMSE}
    if s.edgeFraction.isFinite {r["edgeFraction"]=s.edgeFraction}
    return r
}
func quality(_ q: NativeResidualProof.Quality, method: String) -> [String: Any] {
    if method == "certified-surface-plane" {
        return ["safe":q.safe,"erased":q.erased,"residualSourceInk":q.residualSourceInk,
                "surface":q.surface.map(surface) as Any? ?? NSNull(),"supportSides":q.supportSides as Any? ?? NSNull()]
    }
    var r:[String:Any] = ["safe":q.safe,"erased":q.erased,"noDonor":q.noDonor,"continuous":q.continuous,
        "seams":q.seams,"wide":q.wide,"wideDiscordant":q.wideDiscordant,"maxSpan":q.maxSpan,"continuityRatio":q.continuityRatio,
        "edgeRelaxationIterations":q.edgeRelaxationIterations]
    r["residualSourceInk"]=q.residualSourceInk;r["whiteHaloFractionInner"]=q.whiteHaloFractionInner;r["whiteHaloFractionOuter"]=q.whiteHaloFractionOuter
    return r
}
@main struct Probe {
static func main() throws {
    let fixtures=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
    var results:[[String:Any]]=[]
    for f in fixtures {
        let palette=(f["palette"] as? [String:Any]).flatMap(NativeRestorationPixels.palette)
        let rgba=(f["rgba"] as! [NSNumber]).map(\.uint8Value),box=f["box"] as! [Double],o=f["options"] as? [String:Any] ?? [:]
        var options=NativeForcedSourceInpainting.Options()
        options.auxiliary=rectangles(o["auxiliary"]);options.excluded=rectangles(o["excluded"]);options.donorExcluded=rectangles(o["donorExcluded"])
        options.polygons=polygons(o["polygons"]);options.excludedPolygons=polygons(o["excludedPolygons"])
        options.trailing=(o["trailing"] as? NSNumber)?.doubleValue ?? 0;options.vertical=o["vertical"] as? Bool ?? false
        options.glyphSize=(o["glyphSize"] as? NSNumber)?.doubleValue ?? 0;options.requireSafeDonors=o["requireSafeDonors"] as? Bool ?? false
        options.excludedMask=(o["excludedMask"] as? [NSNumber])?.map(\.uint8Value);options.protected=(o["protected"] as? [NSNumber])?.map(\.uint8Value)
        let outcome=NativeForcedSourceInpainting.restore(rgba:rgba,width:f["w"] as! Int,height:f["h"] as! Int,
            box:CGRect(x:box[0],y:box[1],width:box[2],height:box[3]),palette:palette,options:options)
        var row:[String:Any] = ["failure":outcome.failure,"result":NSNull()]
        if let r=outcome.result {
            row["result"]=["rgba":r.rgba,"layoutSafe":r.layoutSafe,"erased":r.erased,"method":r.method,
                "quality":r.quality.map { quality($0,method:r.method) } as Any? ?? NSNull(),
                "sourceTouchesCropEdge":r.sourceTouchesCropEdge,"postFillPaletteInkPixels":r.postFillPaletteInkPixels,
                "sourceGlyphsVerified":r.sourceGlyphsVerified,"sourceErasureVerified":r.sourceErasureVerified,
                "sourceRemainingInk":r.sourceRemainingInk,"sourceCorePixels":r.sourceCorePixels,
                "sourceOutlinePixels":r.sourceOutlinePixels,"sourceRemainingOutline":r.sourceRemainingOutline,
                "preservedPixels":r.preservedPixels,"preservedCore":r.preservedCore,"forcedCoverage":r.forcedCoverage,
                "forcedOutlineCoverage":r.forcedOutlineCoverage,"forcedMaskMode":r.forcedMaskMode]
        }
        results.append(row)
    }
    try JSONSerialization.data(withJSONObject:results,options:[.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
}}
