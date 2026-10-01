import CoreGraphics
import Foundation

/// Source image geometry and coverage paths use page coordinates throughout.
enum NativeSourceSurfaceGeometry {
    struct Geometry {
        let frame: CGRect
        let clip: CGRect
    }
    struct Insets: Equatable {
        let top: CGFloat
        let right: CGFloat
        let bottom: CGFloat
        let left: CGFloat
        let empty: Bool
        var isUnclipped: Bool { !empty && top == 0 && right == 0 && bottom == 0 && left == 0 }
    }
    static func contentGeometry(rect: CGRect, naturalSize: CGSize, style: [String: String]) -> Geometry? {
        guard [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height, naturalSize.width, naturalSize.height].allSatisfy(\.isFinite),
              rect.size.width > 0, rect.size.height > 0, naturalSize.width > 0, naturalSize.height > 0,
              style["transform"] == "none" else { return nil }
        for key in ["borderLeftWidth", "borderTopWidth", "borderRightWidth", "borderBottomWidth",
                    "paddingLeft", "paddingTop", "paddingRight", "paddingBottom"] {
            let value = style[key].flatMap { $0.isEmpty ? nil : $0 } ?? "0"
            guard floatPrefix(value) == 0 else { return nil }
        }
        let fit = style["objectFit"] ?? ""
        if fit == "fill" { return Geometry(frame: rect, clip: rect) }
        guard fit == "contain" || fit == "cover" else { return nil }
        let position = (style["objectPosition"].flatMap { $0.isEmpty ? nil : $0 } ?? "50% 50%").split(whereSeparator: \.isWhitespace).map(String.init)
        guard position.count == 2 else { return nil }
        let scale = fit == "contain" ? min(rect.width / naturalSize.width, rect.height / naturalSize.height)
            : max(rect.width / naturalSize.width, rect.height / naturalSize.height)
        let width = naturalSize.width * scale, height = naturalSize.height * scale
        guard let x = offset(position[0], space: rect.width - width, horizontal: true),
              let y = offset(position[1], space: rect.height - height, horizontal: false), x.isFinite, y.isFinite else { return nil }
        return Geometry(frame: CGRect(x: rect.minX + x, y: rect.minY + y, width: width, height: height), clip: rect)
    }
    static func cleanupClip(_ geometry: Geometry?, rect: CGRect) -> Insets {
        guard let bounds = geometry?.clip else { return Insets(top: 0, right: 0, bottom: 0, left: 0, empty: false) }
        let left = max(0, bounds.minX - rect.minX), top = max(0, bounds.minY - rect.minY)
        let right = max(0, rect.maxX - bounds.maxX), bottom = max(0, rect.maxY - bounds.maxY)
        let empty = left >= rect.width || right >= rect.width || top >= rect.height || bottom >= rect.height
        return Insets(top: top, right: right, bottom: bottom, left: left, empty: empty)
    }
    static func rebaseCoverageClip(_ coverage: [CGRect], origin: CGPoint, hasClip: Bool) -> [CGRect]? {
        guard hasClip else { return nil }
        return coverage.map { $0.offsetBy(dx: -origin.x, dy: -origin.y) }
    }
    static func coveragePath(_ coverage: [CGRect], origin: CGPoint = .zero) -> CGPath {
        let result = CGMutablePath()
        for rect in coverage { result.addRect(rect.offsetBy(dx: -origin.x, dy: -origin.y)) }
        return result
    }
    private static func offset(_ token: String, space: CGFloat, horizontal: Bool) -> CGFloat? {
        let keywords: [String: CGFloat] = horizontal ? ["left": 0, "center": 0.5, "right": 1] : ["top": 0, "center": 0.5, "bottom": 1]
        if let fraction = keywords[token] { return space * fraction }
        guard token.range(of: "^-?(?:[0-9]+\\.?[0-9]*|\\.[0-9]+)(?:%|px)$", options: .regularExpression) != nil else { return nil }
        if token.hasSuffix("%"), let value = Double(token.dropLast()), (0...100).contains(value) { return space * CGFloat(value) / 100 }
        if token.hasSuffix("px"), let value = Double(token.dropLast(2)) { return CGFloat(value) }
        return nil
    }
    private static func floatPrefix(_ text: String) -> Double? {
        guard let range = text.range(of: "^[\\t\\n\\r ]*[+-]?(?:[0-9]+\\.?[0-9]*|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?", options: .regularExpression)
        else { return nil }
        return Double(text[range].trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
