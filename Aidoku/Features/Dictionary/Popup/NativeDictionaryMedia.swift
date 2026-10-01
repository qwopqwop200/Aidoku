import UIKit
import SVGKit
import SwiftSoup

/// Dictionary media uses native raster decoders and SVGKit's Core Animation vector tree.
/// Structured dimensions are in dictionary units, independent of image pixel density.
@available(iOS 18.0, *)
@MainActor
enum NativeDictionaryMedia {
    struct Geometry: Equatable {
        let size: CGSize
        let baselineOffset: CGFloat
    }

    static func geometry(_ node: [String: Any], naturalSize: CGSize, font: UIFont, availableWidth: CGFloat) -> Geometry {
        func number(_ key: String) -> CGFloat? {
            let result = (node[key] as? NSNumber).map { CGFloat($0.doubleValue) } ?? (node[key] as? String).flatMap { Double($0) }.map { CGFloat($0) }
            return result.flatMap { $0.isFinite && $0 > 0 && $0 <= 1_000_000 ? $0 : nil }
        }
        let preferredWidth = number("preferredWidth"), preferredHeight = number("preferredHeight")
        let width = number("width") ?? 100, height = number("height") ?? 100
        let explicit = preferredWidth != nil || preferredHeight != nil || number("width") != nil || number("height") != nil
        let em = node["sizeUnits"] as? String == "em"
        var ratio = preferredWidth != nil && preferredHeight != nil ? preferredHeight! / preferredWidth! : height / width
        var usedWidth = preferredWidth ?? preferredHeight.map { $0 / ratio } ?? width
        if !explicit {
            usedWidth = naturalSize.width
            ratio = naturalSize.height / max(1, naturalSize.width)
        } else if em && preferredWidth == nil && preferredHeight == nil {
            ratio = naturalSize.height / max(1, naturalSize.width)
            usedWidth = number("width") ?? number("height").map { $0 / ratio } ?? width
        }
        let unit = explicit ? (em ? font.pointSize : font.pointSize / 15) : 1
        var size = CGSize(width: usedWidth * unit, height: usedWidth * ratio * unit)
        if let css = node["style"] as? [String: Any] {
            if let value = NativeDictionaryCSS.length(css["width"], font: font, relativeTo: availableWidth) { size.width = value }
            if let value = NativeDictionaryCSS.length(css["height"], font: font, relativeTo: size.height) { size.height = value }
        }
        if !size.width.isFinite || !size.height.isFinite || size.width <= 0 || size.height <= 0 {
            size = CGSize(width: 100, height: 100)
        }
        let maximum = availableWidth.isFinite ? max(1, availableWidth) : 260
        let fit = min(1, maximum / max(1, size.width), 4096 / max(1, size.height))
        size = CGSize(width: max(1, size.width * fit), height: max(1, size.height * fit))
        let alignment = node["verticalAlign"] as? String ?? "baseline"
        let baseline: CGFloat
        switch alignment {
        case "middle": baseline = (font.xHeight - size.height) / 2
        case "top", "text-top": baseline = font.ascender - size.height
        case "bottom", "text-bottom": baseline = font.descender
        case "super": baseline = font.pointSize * 0.4
        case "sub": baseline = -font.pointSize * 0.2
        default: baseline = 0
        }
        return Geometry(size: size, baselineOffset: baseline)
    }

    static func attachment(_ node: [String: Any], dictionary: String, attributes: [NSAttributedString.Key: Any],
                           availableWidth: CGFloat, load: ((String, String) -> Data)? = nil) -> NSAttributedString {
        let path = node["path"] as? String ?? node["src"] as? String ?? ""
        let alt = (node["data"] as? [String: Any])?["alt"] as? String ?? node["alt"] as? String ?? node["title"] as? String ?? path
        let data = load?(dictionary, path) ?? LookupEngine.shared.getMediaFile(dictName: dictionary, mediaPath: path)
        let font = attributes[.font] as? UIFont ?? .systemFont(ofSize: 15)
        let foreground = attributes[.foregroundColor] as? UIColor ?? .label
        let css = node["style"] as? [String: Any] ?? [:]
        var image = UIImage(data: data)
        if image == nil, let xml = String(data: data, encoding: .utf8), xml.contains("<svg") {
            // The renderer receives dictionary bytes, not a URL or executable document.
            // External entities/scripts are rejected instead of allowing parser fetches.
            guard !xml.localizedCaseInsensitiveContains("<!ENTITY"), !xml.localizedCaseInsensitiveContains("<script"),
                  let vector = SVGKImage(data: data) else { return missing(alt, attributes: attributes) }
            let natural = vector.hasSize() ? vector.size : CGSize(width: 100, height: 100)
            let dimensions = geometry(node, naturalSize: natural, font: font, availableWidth: availableWidth)
            vector.size = dimensions.size
            let format = UIGraphicsImageRendererFormat(); format.scale = min(3, UIScreen.main.scale); format.preferredRange = .standard
            image = UIGraphicsImageRenderer(size: dimensions.size, format: format).image { renderer in
                vector.caLayerTree.render(in: renderer.cgContext)
            }
        }
        guard let decoded = image, decoded.size.width > 0, decoded.size.height > 0 else { return missing(alt, attributes: attributes) }
        let dimensions = geometry(node, naturalSize: decoded.size, font: font, availableWidth: availableWidth)
        // popup.js masks monochrome bytes with exact black/white, independent of dictionary text colors.
        let monochrome = UIColor { $0.userInterfaceStyle == .dark ? .white : .black }
        let border = node["border"] as? String ?? css["border"] as? String ?? ""
        let borderParts = border.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let borderWidth = NativeDictionaryCSS.length(css["border-width"], font: font, relativeTo: dimensions.size.width)
            ?? borderParts.first.flatMap { NativeDictionaryCSS.length($0, font: font, relativeTo: dimensions.size.width) } ?? 0
        let borderColor = NativeDictionaryCSS.color(css["border-color"] as? String ?? borderParts.last ?? "currentColor", current: foreground) ?? foreground
        let radius = NativeDictionaryCSS.length(node["borderRadius"] ?? css["border-radius"], font: font,
                                                relativeTo: min(dimensions.size.width, dimensions.size.height)) ?? 0
        let background = (css["background-color"] as? String ?? css["background"] as? String)
            .flatMap { NativeDictionaryCSS.color($0, current: foreground) }
        let result = NativeDictionaryImageAttachment(image: decoded, tint: node["appearance"] as? String == "monochrome" ? monochrome : nil,
            pixelated: node["pixelated"] as? Bool == true || node["imageRendering"] as? String == "pixelated", title: alt,
            borderWidth: border.contains("none") || border.contains("hidden") ? 0 : max(0, borderWidth),
            borderColor: borderColor, cornerRadius: max(0, radius), background: background)
        result.bounds = CGRect(x: 0, y: dimensions.baselineOffset, width: dimensions.size.width, height: dimensions.size.height)
        var value = attributes
        value[.attachment] = result
        return NSAttributedString(string: "\u{FFFC}", attributes: value)
    }

    private static func missing(_ alt: String, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        NSAttributedString(string: "[" + (alt.isEmpty ? "image" : alt) + "]", attributes: attributes)
    }
}

@MainActor
final class NativeDictionaryImageAttachment: NSTextAttachment {
    let original: UIImage
    let tint: UIColor?
    let pixelated: Bool
    let title: String
    let borderWidth: CGFloat
    let borderColor: UIColor
    let cornerRadius: CGFloat
    let background: UIColor?
    init(image: UIImage, tint: UIColor?, pixelated: Bool, title: String,
         borderWidth: CGFloat = 0, borderColor: UIColor = .label, cornerRadius: CGFloat = 0, background: UIColor? = nil) {
        original = image; self.tint = tint; self.pixelated = pixelated; self.title = title
        self.borderWidth = borderWidth; self.borderColor = borderColor; self.cornerRadius = cornerRadius; self.background = background
        super.init(data: nil, ofType: nil)
        self.image = image
    }
    required init?(coder: NSCoder) { nil }
    override func image(forBounds imageBounds: CGRect, textContainer: NSTextContainer?, characterIndex charIndex: Int) -> UIImage? {
        let size = imageBounds.size.width > 0 && imageBounds.size.height > 0 ? imageBounds.size : original.size
        let format = UIGraphicsImageRendererFormat(); format.scale = min(3, UIScreen.main.scale); format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let rectangle = CGRect(origin: .zero, size: size)
            let radius = min(cornerRadius, min(size.width, size.height) / 2)
            let clipping = UIBezierPath(roundedRect: rectangle, cornerRadius: radius)
            renderer.cgContext.saveGState()
            clipping.addClip()
            let imageRect = rectangle.insetBy(dx: min(borderWidth, size.width / 2), dy: min(borderWidth, size.height / 2))
            let scale = min(imageRect.width / max(1, original.size.width), imageRect.height / max(1, original.size.height))
            let fittedSize = CGSize(width: original.size.width * scale, height: original.size.height * scale)
            let fitted = CGRect(x: imageRect.midX - fittedSize.width / 2, y: imageRect.midY - fittedSize.height / 2,
                                width: fittedSize.width, height: fittedSize.height)
            if pixelated { renderer.cgContext.interpolationQuality = .none }
            original.draw(in: fitted)
            if let tint {
                tint.setFill()
                renderer.cgContext.setBlendMode(.sourceIn)
                renderer.cgContext.fill(rectangle)
                renderer.cgContext.setBlendMode(.normal)
            }
            if let background {
                background.setFill()
                renderer.cgContext.setBlendMode(.destinationOver)
                clipping.fill()
                renderer.cgContext.setBlendMode(.normal)
            }
            renderer.cgContext.restoreGState()
            if borderWidth > 0 {
                borderColor.setStroke()
                let border = UIBezierPath(roundedRect: rectangle.insetBy(dx: borderWidth / 2, dy: borderWidth / 2),
                                          cornerRadius: max(0, radius - borderWidth / 2))
                border.lineWidth = borderWidth
                border.stroke()
            }
        }
    }
}
