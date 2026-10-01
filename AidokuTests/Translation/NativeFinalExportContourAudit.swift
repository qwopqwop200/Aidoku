import Foundation
import CoreGraphics
import CoreFoundation

/// Additional final-export evidence only. Missing or mismatched live typography
/// audits cannot authorize a raster exemption; existing raw gates remain intact.
enum NativeFinalExportContourAudit {
    static let contract = "matched live glyph or panel geometry; bounded contour coverage; unchanged raw metrics"

    static func evaluate(reference: CGImage, actual: CGImage, nativeAudit: Data, webAudit: Data) -> [String: Any]? {
        guard reference.width == actual.width, reference.height == actual.height,
              let native = (try? JSONSerialization.jsonObject(with: nativeAudit)) as? [String: Any],
              let web = (try? JSONSerialization.jsonObject(with: webAudit)) as? [String: Any],
              let cards = native["cards"] as? [[String: Any]], cards.count <= 128,
              let layers = web["layers"] as? [[String: Any]], layers.count <= 512,
              let viewport = web["viewport"] as? [String: Any],
              let viewWidth = number(viewport["width"]), let viewHeight = number(viewport["height"]),
              viewWidth > 0, viewHeight > 0 else { return nil }
        let cardIDs = cards.compactMap { $0["id"] as? String }
        let itemLayers = layers.filter { $0["kind"] as? String == "item" }
        let itemIDs = itemLayers.compactMap { $0["id"] as? String }
        guard cardIDs.count == cards.count, Set(cardIDs).count == cards.count,
              itemIDs.count == itemLayers.count, Set(itemIDs).count == itemLayers.count else { return nil }
        let width = reference.width, height = reference.height, scale = Double(width) / viewWidth
        guard scale > 0, scale <= 4, abs(Double(height) / viewHeight - scale) < 0.000001,
              let left = rgba(reference), let right = rgba(actual) else { return nil }
        var strong = 0, changed = 0, maximum = 0, high: Set<Int> = []
        for pixel in 0..<(width * height) {
            let offset = pixel * 4
            guard left[offset + 3] == right[offset + 3] else { return nil }
            let delta = (0..<4).map { abs(Int(left[offset + $0]) - Int(right[offset + $0])) }.max() ?? 0
            if delta > 0 { changed += 1 }
            if delta > 4 { strong += 1 }
            if delta > 16 { high.insert(pixel) }
            maximum = max(maximum, delta)
        }
        guard !high.isEmpty, strong <= width * height / 1000 else { return nil }
        var certified: Set<Int> = [], records: [[String: Any]] = [], cropBudget = 262_144
        for card in cards {
            if let glyph = glyphDescriptor(card: card, layers: layers, scale: scale, width: width, height: height) {
                let bounds = glyph.bounds
                let contained = high.filter { pixel in
                    let x = pixel % width, y = pixel / width
                    return x >= bounds[0] && x < bounds[2] && y >= bounds[1] && y < bounds[3]
                }
                if !contained.isEmpty {
                    let cropWidth = bounds[2] - bounds[0], cropHeight = bounds[3] - bounds[1]
                    let area = cropWidth * cropHeight
                    if area <= 65_536, area <= cropBudget {
                        cropBudget -= area
                        let referenceCrop = crop(left, width: width, bounds: bounds)
                        let actualCrop = crop(right, width: width, bounds: bounds)
                        if let evidence = NativeFinalExportGlyphContourAcceptance.evaluate(reference: referenceCrop, actual: actualCrop,
                            width: cropWidth, height: cropHeight, foreground: glyph.foreground, outline: glyph.outline) {
                            certified.formUnion(contained)
                            records.append(["kind": "glyph", "id": glyph.id, "bounds": bounds,
                                "foreground": glyph.foreground, "outline": glyph.outline,
                                "referenceFillPixels": evidence.referenceFillPixels, "actualFillPixels": evidence.actualFillPixels,
                                "relativeAreaDifference": evidence.relativeAreaDifference,
                                "relativeCoverageDifference": evidence.relativeCoverageDifference,
                                "componentCount": evidence.componentCount,
                                "maximumComponentCoverageDifference": evidence.maximumComponentCoverageDifference,
                                "relativeCoverageRedistribution": evidence.relativeCoverageRedistribution,
                                "certifiedPixelsAboveEight": evidence.certifiedPixelsAboveEight,
                                "certifiedPixelsAboveSixteen": contained.count])
                        }
                    }
                }
            }
            if let panel = NativeFinalExportPanelContourAcceptance.evaluate(reference: left, actual: right,
                width: width, height: height, scale: scale, nativeCard: card, webLayers: layers) {
                certified.formUnion(panel.certifiedPixels)
                records.append(panel.report)
            }
        }
        guard high.isSubset(of: certified) else { return nil }
        return ["contract": contract, "rawChangedPixels": changed, "rawMaximumChannelDifference": maximum,
                "pixelsOverLowDeltaLimit": strong, "certifiedPixelsAboveSixteen": high.count, "regions": records]
    }

    struct Glyph {
        var id: String
        var bounds: [Int]
        var foreground: [Double]
        var outline: [Double]
    }

    static func glyphDescriptor(card: [String: Any], layers: [[String: Any]],
                                        scale: Double, width: Int, height: Int) -> Glyph? {
        guard let id = card["id"] as? String, let text = card["text"] as? String, !text.isEmpty,
              card["removed"] as? Bool == false, card["hidden"] as? Bool == false,
              let web = layers.first(where: { $0["kind"] as? String == "item" && $0["id"] as? String == id }),
              web["text"] as? String == text, let style = web["style"] as? [String: Any],
              let font = number(card["fontSize"]), font > 0, font <= 512, let webFont = cssNumber(style["fontSize"]), abs(font - webFont) < 0.000001,
              let lineHeight = number(card["lineHeight"]), lineHeight > 0, lineHeight <= 1024, let webLineHeight = cssNumber(style["lineHeight"]),
              abs(lineHeight - webLineHeight) < 0.000001, style["fontWeight"] as? String == "700",
              style["fontStyle"] as? String == "normal", style["opacity"] as? String == "1",
              style["visibility"] as? String == "visible",
              let family = style["fontFamily"] as? String, family.contains("Apple SD Gothic Neo"), card["fontName"] as? String == "system",
              let typography = card["typographyFinal"] as? [String: Any],
              let rows = typography["coreTextRows"] as? [[String: Any]], !rows.isEmpty,
              let foreground = numbers(card["foreground"], count: 3), cssColor(style["color"]) == foreground,
              let outlineWidth = number(card["outlineWidth"]), outlineWidth >= 0, outlineWidth <= 64, let webOutlineWidth = cssNumber(style["webkitTextStrokeWidth"]),
              abs(outlineWidth - webOutlineWidth) < 0.000001,
              let rotation = number(card["rotation"]), abs(rotation) <= .pi,
              let horizontalScale = number(card["horizontalScale"]), horizontalScale > 0, horizontalScale <= 4,
              let matrix = cssMatrix(style["transform"]),
              abs(matrix[0] - cos(rotation) * horizontalScale) < 0.00001,
              abs(matrix[1] - sin(rotation) * horizontalScale) < 0.00001,
              abs(matrix[2] + sin(rotation)) < 0.00001, abs(matrix[3] - cos(rotation)) < 0.00001,
              abs(matrix[4]) < 0.00001, abs(matrix[5]) < 0.00001,
              let nativeRectData = card["pageRangeBounds"] as? [[Any]],
              let scalars = web["scalarRects"] as? [[String: Any]], nativeRectData.count == scalars.count,
              !nativeRectData.isEmpty, nativeRectData.count <= 2048, scale.isFinite, scale > 0, scale <= 4,
              width > 0, height > 0, width <= 16_777_216, height <= 16_777_216 else { return nil }
        let nativeRects = nativeRectData.compactMap { numbers($0, count: 4) }
        guard nativeRects.count == nativeRectData.count else { return nil }
        let rowTexts = rows.compactMap { $0["text"] as? String }
        func words(_ value: String) -> [String] { value.split(whereSeparator: { $0.isWhitespace }).map(String.init) }
        guard rowTexts.count == rows.count, words(rowTexts.joined()) == words(text),
              let shaped = typography["shapedText"] as? String, words(shaped) == words(text) else { return nil }
        for row in rows {
            guard let runs = row["runs"] as? [[String: Any]], !runs.isEmpty else { return nil }
            for run in runs {
                guard run["fontName"] as? String == "AppleSDGothicNeo-Bold",
                      let size = number(run["fontSize"]), abs(size - font) < 0.000001 else { return nil }
            }
        }
        let characters = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(String.init)
        guard scalars.compactMap({ $0["scalar"] as? String }) == characters else { return nil }
        var union = CGRect.null
        for (nativeRect, scalar) in zip(nativeRects, scalars) {
            guard nativeRect.count == 4, nativeRect.allSatisfy(\.isFinite),
                  let rect = scalar["rect"] as? [String: Any],
                  let x = number(rect["x"]), let y = number(rect["y"]),
                  let w = number(rect["width"]), let h = number(rect["height"]), w > 0, h > 0 else { return nil }
            let webRect = [x, y, w, h]
            let viewWidth = Double(width) / scale, viewHeight = Double(height) / scale
            for values in [nativeRect, webRect] {
                guard values[0] >= 0, values[1] >= 0, values[2] > 0, values[3] > 0,
                      values[0] <= viewWidth, values[2] <= viewWidth,
                      values[1] <= viewHeight, values[3] <= viewHeight,
                      values[0] + values[2] <= viewWidth, values[1] + values[3] <= viewHeight else { return nil }
            }
            guard zip(nativeRect, webRect).allSatisfy({ abs($0.0 - $0.1) * scale <= 1 }) else { return nil }
            union = union.union(CGRect(x: x, y: y, width: w, height: h))
                .union(CGRect(x: nativeRect[0], y: nativeRect[1], width: nativeRect[2], height: nativeRect[3]))
        }
        let backdrop: [Double]
        if outlineWidth > 0 {
            guard let value = numbers(card["outline"], count: 3), cssColor(style["webkitTextStrokeColor"]) == value,
                  let order = card["outlinePaintOrder"] as? String, let cssOrder = style["paintOrder"] as? String,
                  (order == "fillThenStroke" && ["normal", "fill stroke"].contains(cssOrder))
                    || (order == "strokeThenFill" && ["stroke", "stroke fill"].contains(cssOrder)) else { return nil }
            backdrop = value
        } else {
            guard let panels = card["panels"] as? [[String: Any]], panels.count == 1,
                  let value = numbers(panels[0]["background"], count: 3),
                  let panel = layers.first(where: { $0["kind"] as? String == "source-rotated-panel" && $0["id"] as? String == id }),
                  let panelStyle = panel["style"] as? [String: Any], panelStyle["backgroundImage"] as? String == "none",
                  cssColor(panelStyle["backgroundColor"]) == value else { return nil }
            backdrop = value
        }
        guard !union.isNull, !union.isInfinite, union.minX.isFinite, union.minY.isFinite,
              union.maxX.isFinite, union.maxY.isFinite else { return nil }
        let margin = ceil(outlineWidth * scale / 2) + 3
        let bounds = [max(0, Int(floor(union.minX * scale - margin))), max(0, Int(floor(union.minY * scale - margin))),
                      min(width, Int(ceil(union.maxX * scale + margin))), min(height, Int(ceil(union.maxY * scale + margin)))]
        guard bounds[0] < bounds[2], bounds[1] < bounds[3] else { return nil }
        return Glyph(id: id, bounds: bounds, foreground: foreground, outline: backdrop)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private static func numbers(_ value: Any?, count: Int) -> [Double]? {
        guard let array = value as? [Any], array.count == count else { return nil }
        let result = array.compactMap(number)
        return result.count == count ? result : nil
    }

    private static func cssNumber(_ value: Any?) -> Double? {
        guard let string = value as? String, string.hasSuffix("px"), let value = Double(string.dropLast(2)), value.isFinite else { return nil }
        return value
    }

    private static func cssColor(_ value: Any?) -> [Double]? {
        guard let string = value as? String, string.hasPrefix("rgb("), string.hasSuffix(")") else { return nil }
        let values = string.dropFirst(4).dropLast().split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        return values.count == 3 && values.allSatisfy({ $0.isFinite && (0...255).contains($0) }) ? values : nil
    }

    private static func cssMatrix(_ value: Any?) -> [Double]? {
        if value as? String == "none" { return [1, 0, 0, 1, 0, 0] }
        guard let string = value as? String, string.hasPrefix("matrix("), string.hasSuffix(")") else { return nil }
        let values = string.dropFirst(7).dropLast().split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        return values.count == 6 && values.allSatisfy(\.isFinite) ? values : nil
    }

    private static func crop(_ pixels: [UInt8], width: Int, bounds: [Int]) -> [UInt8] {
        var result: [UInt8] = []; result.reserveCapacity((bounds[2] - bounds[0]) * (bounds[3] - bounds[1]) * 4)
        for y in bounds[1]..<bounds[3] { result.append(contentsOf: pixels[((y * width + bounds[0]) * 4)..<((y * width + bounds[2]) * 4)]) }
        return result
    }

    private static func rgba(_ image: CGImage) -> [UInt8]? {
        let (count, overflow) = image.width.multipliedReportingOverflow(by: image.height)
        guard !overflow, count > 0, count <= 16_777_216, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: count * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? bytes : nil
    }
}
