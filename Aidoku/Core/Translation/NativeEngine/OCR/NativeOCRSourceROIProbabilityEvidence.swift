import Foundation
import CryptoKit

/// Measured probability upper bounds, never a permission to erase or ignore ink.
/// A consumer must independently certify original-image components and ownership.
struct NativeOCRSourceROIProbabilityEvidence: Codable, Equatable, Sendable {
    struct PixelRect: Codable, Equatable, Sendable {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }
    struct Detector: Codable, Equatable, Sendable {
        let originX: Int
        let originY: Int
        let width: Int
        let height: Int
        let fullWidth: Int
        let fullHeight: Int
    }
    let version: Int
    let sourceWidth: Int
    let sourceHeight: Int
    /// SHA256 of exact top-left-origin, premultiplied RGBA8 packed source rows.
    let sourceDigest: String
    let roi: PixelRect
    let detector: Detector
    /// Original source pixel row-major ceil(255 * maximum overlapping DB cell).
    /// Unknown, uncovered, or invalid probabilities are 255, never background.
    let upperBounds: Data
    static let maximumPixels = 262_144
    static let maximumPageBytes = 1_048_576

    var isValid: Bool {
        guard version == 1, Self.validDimensions(sourceWidth, sourceHeight),
              Self.validDigest(sourceDigest),
              roi.x >= 0, roi.y >= 0, roi.x < sourceWidth, roi.y < sourceHeight,
              roi.width > 0, roi.height > 0,
              roi.width <= sourceWidth - roi.x, roi.height <= sourceHeight - roi.y,
              roi.width <= Self.maximumPixels / roi.height,
              upperBounds.count == roi.width * roi.height,
              Self.validDetector(detector) else { return false }
        return true
    }
    static func validDimensions(_ width: Int, _ height: Int) -> Bool {
        width > 0 && height > 0 && width <= 131_072 && height <= 131_072
    }
    static func validDigest(_ digest: String) -> Bool {
        digest.utf8.count == 64 &&
        digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    }
    static func validDetector(_ d: Detector) -> Bool {
        d.fullWidth > 0 && d.fullHeight > 0 && d.fullWidth <= 32_768 && d.fullHeight <= 32_768 &&
        d.originX >= 0 && d.originY >= 0 && d.originX < d.fullWidth && d.originY < d.fullHeight &&
        d.width > 0 && d.height > 0 && d.width <= d.fullWidth - d.originX && d.height <= d.fullHeight - d.originY
    }

    /// One page-level identity; row padding is deliberately excluded.
    static func sourceIdentity(rgba: UnsafeBufferPointer<UInt8>, width: Int, height: Int,
                               bytesPerRow: Int) -> String? {
        guard validDimensions(width, height), bytesPerRow >= width * 4,
              bytesPerRow <= Int.max / height, rgba.count >= bytesPerRow * height,
              let base = rgba.baseAddress else { return nil }
        var hasher = SHA256()
        for y in 0..<height {
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: base + y * bytesPerRow, count: width * 4))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Reads immutable row-major detector storage; retains only the bounded ROI.
    /// The caller binds this map and digest to the SAME immutable source frame.
    /// For dirty maps detector origin/full dimensions preserve the full-frame transform.
    static func capture(sourceWidth: Int, sourceHeight: Int, sourceDigest: String,
                        roi: PixelRect, detector: Detector,
                        probabilities: [Float]) -> Self? {
        guard validDimensions(sourceWidth, sourceHeight), validDigest(sourceDigest), validDetector(detector),
              roi.x >= 0, roi.y >= 0, roi.x < sourceWidth, roi.y < sourceHeight,
              roi.width > 0, roi.height > 0, roi.width <= sourceWidth - roi.x,
              roi.height <= sourceHeight - roi.y, roi.width <= maximumPixels / roi.height else { return nil }
        // Bound CPU as well as retained bytes for hostile or extreme transforms.
        let cellsAcross = (detector.fullWidth + sourceWidth - 1) / sourceWidth + 1
        let cellsDown = (detector.fullHeight + sourceHeight - 1) / sourceHeight + 1
        guard cellsAcross <= 1_048_576 / cellsDown,
              roi.width * roi.height <= 1_048_576 / (cellsAcross * cellsDown) else { return nil }
        guard probabilities.count == detector.width * detector.height else { return nil }
        // Each source pixel covers a fixed interval on each detector axis.
        // Quantization is monotonic, so the byte for a rectangle is exactly
        // the maximum of its quantized columns (invalid samples map to 255).
        let right = detector.originX + detector.width
        let bottom = detector.originY + detector.height
        let firstCell = max(detector.originX, roi.x * detector.fullWidth / sourceWidth)
        let pastCell = min(right, ((roi.x + roi.width) * detector.fullWidth + sourceWidth - 1) / sourceWidth)
        var columns: [Range<UInt16>] = []
        columns.reserveCapacity(roi.width)
        for x in roi.x..<(roi.x + roi.width) {
            let first = x * detector.fullWidth / sourceWidth
            let end = ((x + 1) * detector.fullWidth + sourceWidth - 1) / sourceWidth
            // Index zero is the unknown sentinel for partially covered pixels.
            // The validated detector width is at most 32,768 cells.
            if first >= detector.originX && end <= right {
                columns.append(UInt16(first - firstCell + 1)..<UInt16(end - firstCell + 1))
            } else {
                columns.append(0..<1)
            }
        }
        let cellCount = max(0, pastCell - firstCell)
        var columnMaxima = [UInt8](repeating: 255, count: cellCount + 1)
        var bytes = Data(count: roi.width * roi.height)
        bytes.withUnsafeMutableBytes { raw in
            let output = raw.bindMemory(to: UInt8.self).baseAddress!
            var lastY0 = -1, lastY1 = -1
            for y in 0..<roi.height {
                let gy0 = (roi.y + y) * detector.fullHeight / sourceHeight
                let gy1 = ((roi.y + y + 1) * detector.fullHeight + sourceHeight - 1) / sourceHeight
                let row = output + y * roi.width
                if gy0 == lastY0 && gy1 == lastY1 {
                    memcpy(row, row - roi.width, roi.width)
                    continue
                }
                lastY0 = gy0
                lastY1 = gy1
                guard gy0 >= detector.originY, gy1 <= bottom, cellCount > 0 else {
                    memset(row, 255, roi.width)
                    continue
                }
                let start = (gy0 - detector.originY) * detector.width + firstCell - detector.originX
                for column in 0..<cellCount {
                    var upper: Float = 0
                    for gy in 0..<(gy1 - gy0) {
                        let value = probabilities[start + gy * detector.width + column]
                        guard value >= 0, value <= 1 else { upper = 1; break }
                        upper = max(upper, value)
                    }
                    columnMaxima[column + 1] = UInt8(ceil(Double(upper) * 255))
                }
                for x in columns.indices {
                    let cells = columns[x]
                    let first = Int(cells.lowerBound)
                    var upper = columnMaxima[first]
                    for index in (first + 1)..<Int(cells.upperBound) {
                        upper = max(upper, columnMaxima[index])
                    }
                    row[x] = upper
                }
            }
        }
        let value = Self(version: 1, sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                         sourceDigest: sourceDigest, roi: roi, detector: detector, upperBounds: bytes)
        return value.isValid ? value : nil
    }
}
