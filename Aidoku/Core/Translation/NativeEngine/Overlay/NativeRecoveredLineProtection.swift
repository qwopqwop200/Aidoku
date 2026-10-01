import CoreGraphics
import Foundation

/// Recovered OCR utterances remain printed when their final readability plates
/// obscure artwork outside the source box. The source raster is supplied by the
/// caller so this bounded policy neither owns a bitmap nor performs another fit.
enum NativeRecoveredLineProtection {
    struct Plate { let rect: CGRect; let color: [Double]? }
    struct Item {
        let id: String
        let recoveredLine: Bool
        let sourceBounds: [Double]
        let sourceFontSize: Double?
        let hasNode: Bool
        let plates: [Plate]
    }
    struct Crop {
        let x: Int
        let y: Int
        let sourceWidth: Int
        let sourceHeight: Int
        let width: Int
        let height: Int
    }
    struct Share { let id: String; let value: Double? }
    struct Kept { let id: String; let rect: CGRect; let sourceFontSize: Double? }
    struct Result {
        let droppedIDs: Set<String>
        let shares: [Share]
        let kept: [Kept]
        let painted: [CGRect]
        let remainingBudget: Int
    }

    static func evaluate(items: [Item], cleanupFrame: CGRect, imageSize: CGSize, opacity: Double,
        read: (Crop) throws -> [UInt8]?) throws -> Result {
        var budget = 262_144
        var droppedIDs = Set<String>(), shares: [Share] = []
        let recovered = items.filter(\.recoveredLine)
        let validFrame = [cleanupFrame.origin.x, cleanupFrame.origin.y, cleanupFrame.size.width, cleanupFrame.size.height].allSatisfy(\.isFinite)
            && cleanupFrame.size.width > 0 && cleanupFrame.size.height > 0
        guard !recovered.isEmpty, opacity == 1, validFrame, imageSize.width.isFinite, imageSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0, imageSize.width <= 16_384, imageSize.height <= 16_384 else {
            return Result(droppedIDs: [], shares: [], kept: [], painted: [], remainingBudget: budget)
        }
        let iw = Double(imageSize.width), ih = Double(imageSize.height)
        func validBounds(_ bounds: [Double]) -> Bool { bounds.count == 4 && bounds.allSatisfy(\.isFinite) }
        for item in recovered where item.hasNode && validBounds(item.sourceBounds) {
            try Task.checkCancellation()
            let bounds = item.sourceBounds
            var harm = 0, total = 0
            for plate in item.plates {
                guard let color = plate.color, color.count >= 3, color.prefix(3).allSatisfy(\.isFinite),
                      [plate.rect.origin.x, plate.rect.origin.y, plate.rect.size.width, plate.rect.size.height].allSatisfy(\.isFinite) else { continue }
                let x0 = max(0, floor((Double(plate.rect.origin.x) - Double(cleanupFrame.origin.x)) / Double(cleanupFrame.size.width) * iw))
                let y0 = max(0, floor((Double(plate.rect.origin.y) - Double(cleanupFrame.origin.y)) / Double(cleanupFrame.size.height) * ih))
                let x1 = min(iw, ceil((Double(plate.rect.origin.x + plate.rect.size.width) - Double(cleanupFrame.origin.x)) / Double(cleanupFrame.size.width) * iw))
                let y1 = min(ih, ceil((Double(plate.rect.origin.y + plate.rect.size.height) - Double(cleanupFrame.origin.y)) / Double(cleanupFrame.size.height) * ih))
                let sw = x1 - x0, sh = y1 - y0
                guard sw >= 2, sh >= 2 else { continue }
                let scale = min(1, sqrt(32_768 / (sw * sh)))
                let width = max(1, Int(floor(sw * scale + 0.5))), height = max(1, Int(floor(sh * scale + 0.5)))
                guard width * height <= budget else { continue }
                budget -= width * height
                guard let rgba = try read(Crop(x: Int(x0), y: Int(y0), sourceWidth: Int(sw), sourceHeight: Int(sh),
                    width: width, height: height)), rgba.count == width * height * 4 else { continue }
                let bx0 = (bounds[0] * iw - 2 - x0) * scale, by0 = (bounds[1] * ih - 2 - y0) * scale
                let bx1 = ((bounds[0] + bounds[2]) * iw + 2 - x0) * scale
                let by1 = ((bounds[1] + bounds[3]) * ih + 2 - y0) * scale
                for y in 0..<height {
                    if y & 31 == 0 { try Task.checkCancellation() }
                    for x in 0..<width {
                        total += 1
                        if Double(x) + 0.5 >= bx0 && Double(x) + 0.5 < bx1 &&
                            Double(y) + 0.5 >= by0 && Double(y) + 0.5 < by1 { continue }
                        let p = (y * width + x) * 4
                        if max(abs(Double(rgba[p]) - color[0]), abs(Double(rgba[p + 1]) - color[1]),
                            abs(Double(rgba[p + 2]) - color[2])) > 40 { harm += 1 }
                    }
                }
            }
            let share = total > 0 ? Double(harm) / Double(total) : 0
            shares.append(Share(id: item.id, value: item.plates.isEmpty ? nil : floor(share * 1000 + 0.5) / 1000))
            if share >= 0.02 { droppedIDs.insert(item.id) }
        }
        func sourceRect(_ bounds: [Double]) -> CGRect {
            CGRect(x: Double(cleanupFrame.origin.x) + bounds[0] * Double(cleanupFrame.size.width),
                y: Double(cleanupFrame.origin.y) + bounds[1] * Double(cleanupFrame.size.height),
                width: bounds[2] * Double(cleanupFrame.size.width), height: bounds[3] * Double(cleanupFrame.size.height))
        }
        let kept = items.filter { droppedIDs.contains($0.id) }.map {
            Kept(id: $0.id, rect: sourceRect($0.sourceBounds), sourceFontSize: $0.sourceFontSize.flatMap { $0 > 0 ? $0 : nil })
        }
        let painted = droppedIDs.isEmpty ? [] : items.filter { !droppedIDs.contains($0.id) && validBounds($0.sourceBounds) }
            .map { sourceRect($0.sourceBounds) }
        return Result(droppedIDs: droppedIDs, shares: shares, kept: kept, painted: painted, remainingBudget: budget)
    }
}
