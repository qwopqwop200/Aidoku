import Foundation
import CoreGraphics
@main struct ResidualCompletionProbe {
    static func main() throws {
        let args = CommandLine.arguments
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[1]))) as! [[String: Any]]
        var outputs: [[String: Any]] = []
        for row in rows {
            let w = row["w"] as! Int, h = row["h"] as! Int
            let iw = row["iw"] as? Int ?? w, ih = row["ih"] as? Int ?? h
            let ox = row["ox"] as? Int ?? 0, oy = row["oy"] as? Int ?? 0
            var source = NativeRestorationPixels(width: iw, height: ih)
            source.rgba = (row["sourceRGBA"] as? [Int] ?? row["original"] as! [Int]).map(UInt8.init)
            var original = NativeRestorationPixels(width: w, height: h)
            original.rgba = (row["original"] as! [Int]).map(UInt8.init)
            var repaired = original
            repaired.rgba = (row["rgba"] as! [Int]).map(UInt8.init)
            repaired.layoutSafe = (row["safe"] as! [Int]).map(UInt8.init)
            repaired.erasureComplete = true
            let itemObject: [String: Any] = ["id": "candidate", "text": "검증", "sourceTextOnly": false,
                "sourceBounds": row["box"]!, "sourceFrame": [0, 0, iw, ih], "sourceFontSize": row["sourceFont"] ?? 8,
                "x": 10, "y": 8, "width": 20, "height": 16, "fontSize": 10, "lineHeight": 12]
            let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: JSONSerialization.data(withJSONObject: itemObject))
            let box = (row["box"] as! [Double])
            let rect = CGRect(x: box[0] * Double(iw) - Double(ox), y: box[1] * Double(ih) - Double(oy), width: box[2] * Double(iw), height: box[3] * Double(ih))
            let prepared = NativeSpatialSourceCrop.Prepared(pixels: original, crop: CGRect(x: ox, y: oy, width: w, height: h),
                source: rect, box: rect, auxiliary: [], excluded: [], marks: [], leadingRule: false, sx: 1, sy: 1, synthetic: [])
            let candidate = NativeRestorationCandidate(prepared: prepared, repaired: repaired,
                luminance: (row["luminance"] as! [Int]).map(UInt8.init), imageSize: CGSize(width: iw, height: ih),
                frame: CGRect(x: 0, y: 0, width: iw, height: ih), item: item)!
            var initial = candidate.beginTrial(); initial.residualLettering = true; initial.surfaceRevision = 4
            candidate.commit(initial)
            let plate = (row["plate"] as! [Double]), others = row["other"] as! [[Double]]
            let undo = candidate.completeResidualErasure(item: item, fontSize: 10,
                plate: CGRect(x: plate[0], y: plate[1], width: plate[2], height: plate[3]), sourceImage: source.image()!,
                otherSourceRects: others.map { CGRect(x: $0[0] * Double(iw), y: $0[1] * Double(ih), width: $0[2] * Double(iw), height: $0[3] * Double(ih)) },
                sampledForeground: row["foreground"] as? [Double], sampledBackground: row["background"] as? [Double])
            func normalized() -> [String: Any] {
                ["rgba": candidate.rawRGBA, "safe": candidate.safe, "luminance": candidate.luminance,
                 "residual": candidate.surface.residualLettering as Any, "revision": candidate.revision,
                 "filled": candidate.sourceResidualFilled.map { $0 as Any } ?? NSNull()]
            }
            var result: [String: Any] = ["accepted": undo != nil, "after": normalized()]
            if let undo { undo(); result["undo"] = normalized() }
            outputs.append(result)
        }
        try JSONSerialization.data(withJSONObject: outputs, options: [.sortedKeys]).write(to: URL(fileURLWithPath: args[2]))
    }
}
