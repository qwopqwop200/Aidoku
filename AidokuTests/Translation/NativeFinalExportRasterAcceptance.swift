/// Final images permit low/sparse RGBA deltas or a certified common edge move.
/// The sparse color budget counts pixels whose maximum channel delta exceeds 4.
/// The separate common-displacement certificate retains its complete-change budget.
/// This test-only policy does not certify geometry or replace exact source/art
/// protection, pixel-kernel, layout, source-erasure, or cross-depth cache checks.
enum NativeFinalExportRasterAcceptance {
    static let policy = "same dimensions; RGBA channel delta <= 4 anywhere; delta <= 16 on at most 0.1% pixels over delta 4; "
        + "or bounded common axis displacement <= 1 physical pixel"
    static let unrestrictedChannelDeltaLimit = 4
    static let sparseChannelDeltaLimit = 16

    nonisolated static func accepts(referenceWidth: Int, referenceHeight: Int, actualWidth: Int, actualHeight: Int,
                        changedPixels: Int, pixelsOverLowDeltaLimit: Int, maximumChannelDelta: Int) -> Bool {
        guard referenceWidth > 0, referenceHeight > 0,
              actualWidth == referenceWidth, actualHeight == referenceHeight,
              changedPixels >= 0, maximumChannelDelta >= 0, maximumChannelDelta <= sparseChannelDeltaLimit else { return false }
        let (pixels, overflow) = referenceWidth.multipliedReportingOverflow(by: referenceHeight)
        guard !overflow, changedPixels <= pixels, pixelsOverLowDeltaLimit >= 0,
              pixelsOverLowDeltaLimit <= changedPixels else { return false }
        // A zero difference and a nonzero maximum cannot describe the same raster.
        guard (changedPixels == 0) == (maximumChannelDelta == 0) else { return false }
        guard (maximumChannelDelta <= unrestrictedChannelDeltaLimit) == (pixelsOverLowDeltaLimit == 0) else { return false }
        return pixelsOverLowDeltaLimit <= pixels / 1000
    }
}

/// A final-export-only certificate for an isolated, coherent subpixel edge move.
/// The complete difference envelope shares one axis and one coverage weight.
/// Opposing moves or balanced thick/thin edits cannot borrow each other's ink.
extension NativeFinalExportRasterAcceptance {
    struct DisplacementEvidence {
        let axis: String
        let direction: Int
        let coverage: Double
        let changedPixels: Int
        let bounds: [Int]
        let maximumFitResidual: Double

        var report: [String: Any] {
            ["axis": axis, "direction": direction, "coverage": coverage,
             "changedPixels": changedPixels, "bounds": bounds,
             "maximumFitResidual": maximumFitResidual,
             "opaqueUnchangedBorder": true, "exactChannelMass": true, "exactProjectedMass": true]
        }
    }

    // Four directions, no larger search or shifted raster allocations. Large or
    // scattered envelopes conservatively fail, even if their changed count is low.
    static let maximumDisplacementEnvelopePixels = 65_536

    nonisolated static func displacement<Bytes: RandomAccessCollection>(
        reference: Bytes, actual: Bytes, width: Int, height: Int, actualWidth: Int, actualHeight: Int
    ) -> DisplacementEvidence? where Bytes.Element == UInt8, Bytes.Index == Int {
        guard width > 0, height > 0, actualWidth == width, actualHeight == height,
              reference.startIndex == 0, actual.startIndex == 0 else { return nil }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
        guard !overflow, !byteOverflow, pixels <= Int(Int64.max / 255),
              reference.count == bytes, actual.count == bytes else { return nil }
        var changed = 0, minX = width, minY = height, maxX = -1, maxY = -1
        var mass = [Int64](repeating: 0, count: 4)
        for pixel in 0..<pixels {
            let offset = pixel * 4
            guard reference[offset + 3] == actual[offset + 3] else { return nil }
            var differs = false
            for channel in 0..<4 {
                let delta = Int(actual[offset + channel]) - Int(reference[offset + channel])
                differs = differs || delta != 0
                mass[channel] += Int64(delta)
            }
            if differs {
                changed += 1
                guard changed <= pixels / 1000 else { return nil }
                let x = pixel % width, y = pixel / width
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard changed > 0, mass.allSatisfy({ $0 == 0 }), minX >= 2, minY >= 2,
              maxX < width - 2, maxY < height - 2 else { return nil }
        let x0 = minX - 2, y0 = minY - 2, x1 = maxX + 2, y1 = maxY + 2
        let (area, areaOverflow) = (x1 - x0 + 1).multipliedReportingOverflow(by: y1 - y0 + 1)
        guard !areaOverflow, area <= maximumDisplacementEnvelopePixels else { return nil }
        for y in y0...y1 {
            for x in x0...x1 where reference[(y * width + x) * 4 + 3] != 255 { return nil }
        }
        let backdrop = (y0 * width + x0) * 4
        for y in y0...y1 {
            for x in x0...x1 where x < x0 + 2 || x > x1 - 2 || y < y0 + 2 || y > y1 - 2 {
                let offset = (y * width + x) * 4
                for channel in 0..<4 {
                    guard reference[offset + channel] == reference[backdrop + channel],
                          actual[offset + channel] == reference[backdrop + channel] else { return nil }
                }
            }
        }
        for axis in 0..<2 {
            // Summing along the moved axis must preserve EACH orthogonal line,
            // not merely the global ink total. No pixel may leave the border.
            var projected = true
            let fixedRange = axis == 0 ? x0...x1 : y0...y1
            let movingRange = axis == 0 ? y0...y1 : x0...x1
            for fixed in fixedRange {
                var lineMass = [Int64](repeating: 0, count: 4)
                for moving in movingRange {
                    let offset = ((axis == 0 ? moving : fixed) * width + (axis == 0 ? fixed : moving)) * 4
                    for channel in 0..<4 {
                        lineMass[channel] += Int64(actual[offset + channel]) - Int64(reference[offset + channel])
                    }
                }
                if lineMass.contains(where: { $0 != 0 }) { projected = false; break }
            }
            guard projected else { continue }
            for direction in [-1, 1] {
                let neighborOffset = (axis == 0 ? width : 1) * direction * 4
                var numerator = 0.0, denominator = 0.0
                for y in (y0 + 1)..<y1 {
                    for x in (x0 + 1)..<x1 {
                        let offset = (y * width + x) * 4
                        for channel in 0..<3 {
                            let original = Double(reference[offset + channel])
                            let step = Double(reference[offset - neighborOffset + channel]) - original
                            numerator += (Double(actual[offset + channel]) - original) * step
                            denominator += step * step
                        }
                    }
                }
                guard denominator > 0 else { continue }
                let coverage = numerator / denominator
                guard coverage > 0, coverage <= 1 else { continue }
                var maximumResidual = 0.0
                for y in (y0 + 1)..<y1 {
                    for x in (x0 + 1)..<x1 {
                        let offset = (y * width + x) * 4
                        for channel in 0..<3 {
                            let original = Double(reference[offset + channel])
                            let step = Double(reference[offset - neighborOffset + channel]) - original
                            let residual = abs(Double(actual[offset + channel]) - original - coverage * step)
                            maximumResidual = max(maximumResidual, residual)
                        }
                    }
                }
                guard maximumResidual <= 1 else { continue }
                return DisplacementEvidence(axis: axis == 0 ? "y" : "x", direction: direction,
                    coverage: coverage, changedPixels: changed, bounds: [x0, y0, x1 + 1, y1 + 1],
                    maximumFitResidual: maximumResidual)
            }
        }
        return nil
    }
}
