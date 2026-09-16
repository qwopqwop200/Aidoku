// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import CoreGraphics
import Foundation

/// A narrow image-evidence veto for joining neighbouring rows or columns.
/// This does not infer balloon ownership: only long straight dark rules with
/// bright pixels on BOTH sides are admitted, never broad dark CG backgrounds.
struct NativeOCRRegionSeparator {
    private let pixels: [UInt8]
    private let width: Int
    private let height: Int
    private let sx: CGFloat
    private let sy: CGFloat

    init?(image: CGImage) {
        let scale = min(1, 1024 / CGFloat(max(image.width, image.height)))
        width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        sx = CGFloat(width) / CGFloat(image.width)
        sy = CGFloat(height) / CGFloat(image.height)
        var data = [UInt8](repeating: 255, count: width * height)
        let w = width, h = height
        let drawn = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: w, height: h))
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        pixels = data
    }

    func separates(_ a: CGRect, _ b: CGRect, orientation: BrowserOCRSourceOrientation) -> Bool {
        guard !Task.isCancelled, orientation != .unknown, !a.isEmpty, !b.isEmpty,
              [a.minX, a.minY, a.maxX, a.maxY, b.minX, b.minY, b.maxX, b.maxY].allSatisfy(\.isFinite)
        else { return false }
        let verticalWriting = orientation == .vertical
        let columnOverlap = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        let sameColumnContinuation = verticalWriting
            && (a.maxY <= b.minY || b.maxY <= a.minY)
            && columnOverlap >= min(a.width, b.width) * 0.8
        // A vertical sentence can be split down its reading axis. Its gap has
        // horizontal panel rules, not vertical column rules.
        let vertical = verticalWriting && !sameColumnContinuation
        let first = vertical ? (a.minX < b.minX ? a : b) : (a.minY < b.minY ? a : b)
        let last = first == a ? b : a
        let font = verticalWriting ? min(a.width, b.width) : min(a.height, b.height)
        let gapStart = vertical ? first.maxX : first.maxY
        let gapEnd = vertical ? last.minX : last.minY
        let crossStart = vertical ? max(a.minY, b.minY) : max(a.minX, b.minX)
        let crossEnd = vertical ? min(a.maxY, b.maxY) : min(a.maxX, b.maxX)
        guard font > 0, gapEnd - gapStart >= 2, gapEnd - gapStart <= font * (sameColumnContinuation ? 1.1 : 0.9),
              crossEnd - crossStart >= font * (sameColumnContinuation ? 0.6 : 2) else { return false }
        let primaryScale = vertical ? sx : sy, crossScale = vertical ? sy : sx
        let pLimit = vertical ? width : height, cLimit = vertical ? height : width
        let start = Int(max(0, min(CGFloat(pLimit - 1), ceil(gapStart * primaryScale) + 1)))
        let end = Int(max(0, min(CGFloat(pLimit - 1), floor(gapEnd * primaryScale))))
        let lo = Int(max(0, min(CGFloat(cLimit), ceil(crossStart * crossScale))))
        let hi = Int(max(0, min(CGFloat(cLimit), floor(crossEnd * crossScale))))
        guard end > start, hi - lo >= 6, end - start <= 128 else { return false }
        let count = min(256, hi - lo)
        func occupancy(_ p: Int, bright: Bool) -> Double {
            guard p >= 0, p < pLimit else { return 0 }
            var matches = 0
            for n in 0..<count {
                let c = lo + n * (hi - lo) / count
                let value = pixels[vertical ? c * width + p : p * width + c]
                if bright ? value >= 200 : value <= 110 { matches += 1 }
            }
            return Double(matches) / Double(count)
        }
        var p = start
        while p <= end {
            guard occupancy(p, bright: false) >= 0.9 else { p += 1; continue }
            let runStart = p
            repeat { p += 1 } while p <= end && occupancy(p, bright: false) >= 0.9
            let runEnd = p - 1
            guard runEnd - runStart + 1 <= max(1, Int(ceil(font * primaryScale * 0.2))) else { continue }
            if occupancy(runStart - 2, bright: true) >= 0.8,
               occupancy(runEnd + 2, bright: true) >= 0.8 { return true }
        }
        return false
    }
}
