import CoreGraphics
import Foundation

/// CSS SVG path data is parsed to Float coordinates before its owner moves.
/// Preserve the actual command kind: relative h/v accumulation is not an
/// ideal rectangle at every Float precision boundary.
enum NativeCSSCoveragePath {
    enum Commands { case absolute, relative }
    enum InsetUnit { case pixels, percent }
    struct Inset { let values: [Float]; let unit: InsetUnit }
    struct Declaration {
        let subpaths: [[CGPoint]]
        let inset: Inset?
        init(subpaths: [[CGPoint]], inset: Inset? = nil) {
            self.subpaths = subpaths; self.inset = inset
        }
    }

    /// Inset declarations retain the actual parsed CSS unit and components.
    static func inset(_ values: [CGFloat], unit: InsetUnit) -> Declaration? {
        guard values.count == 4, values.allSatisfy({ $0.isFinite && Float($0).isFinite }) else { return nil }
        return Declaration(subpaths: [], inset: Inset(values: values.map(Float.init), unit: unit))
    }

    static func declaration(coverage: [CGRect], origin: CGPoint, commands: Commands) -> Declaration? {
        guard !coverage.isEmpty, coverage.count <= 512,
              origin.x.isFinite, origin.y.isFinite else { return nil }
        var paths: [[CGPoint]] = []
        for rect in coverage {
            guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
                  rect.width > 0, rect.height > 0 else { return nil }
            let left = Float(rect.minX - origin.x), top = Float(rect.minY - origin.y)
            let right: Float, bottom: Float, returnedLeft: Float
            switch commands {
            case .absolute:
                right = Float(rect.maxX - origin.x); bottom = Float(rect.maxY - origin.y)
                returnedLeft = left
            case .relative:
                right = left + Float(rect.width); bottom = top + Float(rect.height)
                returnedLeft = right + Float(-rect.width)
            }
            guard [left, top, right, bottom, returnedLeft].allSatisfy(\.isFinite) else { return nil }
            paths.append([CGPoint(x: CGFloat(left), y: CGFloat(top)),
                CGPoint(x: CGFloat(right), y: CGFloat(top)),
                CGPoint(x: CGFloat(right), y: CGFloat(bottom)),
                CGPoint(x: CGFloat(returnedLeft), y: CGFloat(bottom))])
        }
        return Declaration(subpaths: paths)
    }

    static func path(_ declaration: Declaration, paintedOrigin: CGPoint) -> CGPath? {
        guard declaration.inset == nil, paintedOrigin.x.isFinite, paintedOrigin.y.isFinite,
              Float(paintedOrigin.x).isFinite, Float(paintedOrigin.y).isFinite,
              !declaration.subpaths.isEmpty, declaration.subpaths.count <= 512 else { return nil }
        let originX = Double(Float(paintedOrigin.x)), originY = Double(Float(paintedOrigin.y))
        let result = CGMutablePath()
        for subpath in declaration.subpaths {
            guard subpath.count == 4 else { return nil }
            var points: [CGPoint] = []
            for local in subpath {
                let x = Float(originX + Double(Float(local.x)))
                let y = Float(originY + Double(Float(local.y)))
                guard x.isFinite, y.isFinite else { return nil }
                points.append(CGPoint(x: CGFloat(x), y: CGFloat(y)))
            }
            result.move(to: points[0])
            for point in points.dropFirst() { result.addLine(to: point) }
            result.closeSubpath()
        }
        return result
    }

    static func path(_ declaration: Declaration, referenceBox: CGRect) -> CGPath? {
        guard let inset = declaration.inset else { return path(declaration, paintedOrigin: referenceBox.origin) }
        let x = Float(referenceBox.minX), y = Float(referenceBox.minY)
        let width = Float(referenceBox.width), height = Float(referenceBox.height)
        guard [x,y,width,height].allSatisfy(\.isFinite), width > 0, height > 0,
              inset.values.count == 4 else { return nil }
        func evaluate(_ value: Float, extent: Float) -> Float {
            switch inset.unit {
            case .pixels: value
            case .percent: Float((Double(value) / 100.0) * Double(extent))
            }
        }
        let top = evaluate(inset.values[0], extent: height), right = evaluate(inset.values[1], extent: width)
        let bottom = evaluate(inset.values[2], extent: height), left = evaluate(inset.values[3], extent: width)
        let originX = left + x, originY = top + y
        let remainingWidth = max((width - left) - right, 0), remainingHeight = max((height - top) - bottom, 0)
        let farX = originX + remainingWidth, farY = originY + remainingHeight
        guard [originX,originY,farX,farY].allSatisfy(\.isFinite) else { return nil }
        let result = CGMutablePath()
        result.move(to: CGPoint(x: CGFloat(originX), y: CGFloat(originY)))
        result.addLine(to: CGPoint(x: CGFloat(farX), y: CGFloat(originY)))
        result.addLine(to: CGPoint(x: CGFloat(farX), y: CGFloat(farY)))
        result.addLine(to: CGPoint(x: CGFloat(originX), y: CGFloat(farY)))
        result.addLine(to: CGPoint(x: CGFloat(originX), y: CGFloat(originY)))
        result.closeSubpath()
        return result
    }
}
