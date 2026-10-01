import CoreGraphics
import Foundation
func rect(_ a: [Double]) -> CGRect { CGRect(x: a[0], y: a[1], width: a[2], height: a[3]) }
func array(_ r: CGRect) -> [Double] { [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)] }
let inputs = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: Any]]
let provider = CGDataProvider(data: Data([255, 255, 255, 255]) as CFData)!
let image = CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
var outputs: [[String: Any]] = []
for f in inputs {
    let records = (f["records"] as! [[String: Any]]).map { r -> NativeTranslationEffectGloss.Record in
        var record = NativeTranslationEffectGloss.Record(id: r["id"] as! String, text: r["text"] as! String,
            role: r["role"] as? String, source: rect(r["source"] as! [Double]),
            ink: rect(r["ink"] as! [Double]), fontSize: r["fontSize"] as! Double)
        record.sourceFontSize = r["glyph"] as? Double; record.sourceVertical = r["vertical"] as? Bool ?? false
        record.sourceQuad = r["quad"] as? [Double]; record.hidden = r["hidden"] as? Bool ?? false
        record.hasBalloon = r["balloon"] as? Bool ?? false; record.glyphReplacement = r["glyphReplacement"] as? Bool ?? false
        record.preservedGloss = r["preservedGloss"] as? Bool ?? false
        record.sampledForeground = r["fill"] as? [Double]; record.sampledStroke = r["stroke"] as? [Double]
        record.sampledBackground = r["background"] as? [Double]
        record.auxiliary = (r["auxiliary"] as? [[Double]] ?? []).map(rect)
        record.plates = (r["plates"] as? [[String: Any]] ?? []).map {
            .init(rect: rect($0["rect"] as! [Double]), colour: $0["colour"] as! [Double], opaque: $0["opaque"] as? Bool ?? true)
        }
        return record
    }
    let value = NativeTranslationEffectGloss.refining(records: records, keptSources: [], frame: rect(f["frame"] as! [Double]),
        opacity: 1, inpaintingEnabled: f["inpainting"] as? Bool ?? false, image: image,
        readSource: { _, w, h in [UInt8](repeating: 255, count: w * h * 4) },
        measure: { _, text, size, width, lh, origin, _ in
            let natural = Double(text.utf16.count) * size * 0.53, lines = max(1, ceil(natural / width)), tw = min(width, natural)
            return [CGRect(x: origin.x + (width - tw) / 2, y: origin.y + size * 0.08, width: tw, height: lines * lh * 0.82)]
        })
    outputs.append(["name": f["name"]!, "notes": value.notes.map { n -> [String: Any] in
        ["id": n.id, "text": n.text, "size": n.placement.size, "width": n.placement.width,
         "lh": n.placement.lineHeight, "side": n.placement.side, "rank": n.placement.rank,
         "angle": n.placement.angle ?? 0, "left": n.origin.x + n.placement.moves[0].x,
         "top": n.origin.y + n.placement.moves[0].y, "fill": n.fill, "outline": n.outline, "stroke": n.strokeWidth,
         "members": n.members, "unit": n.unit, "anchor": n.anchor]
    }, "hidden": value.hiddenIDs.sorted(), "removed": value.removedLayerIDs.sorted(),
        "zones": value.sourceZones.map { ["id": $0.id, "rect": array($0.rect)] }, "rejected": value.rejected, "units": value.units])
}
try JSONSerialization.data(withJSONObject: outputs, options: [.sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
