/// Test-only two-color glyph coverage certificate. Semantic/style agreement is
/// required separately by the live audit adapter; this function proves pixels.
enum NativeFinalExportGlyphContourAcceptance {
    struct Evidence {
        let referenceFillPixels: Int
        let actualFillPixels: Int
        let relativeAreaDifference: Double
        let relativeCoverageDifference: Double
        let componentCount: Int
        let maximumComponentCoverageDifference: Double
        let relativeCoverageRedistribution: Double
        let certifiedPixelsAboveEight: Int
    }

    private struct Coverage {
        var mask: [Bool]
        var soft: [Double]
        var valid: [Bool]
    }

    private struct Components {
        var labels: [Int]
        var pixels: [[Int]]
    }

    static func evaluate(reference: [UInt8], actual: [UInt8], width: Int, height: Int,
                         foreground: [Double], outline: [Double]) -> Evidence? {
        guard width > 4, height > 4, foreground.count == 3, outline.count == 3,
              (foreground + outline).allSatisfy({ $0.isFinite && (0...255).contains($0) }) else { return nil }
        let (count, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, count <= 65_536, reference.count == count * 4, actual.count == count * 4 else { return nil }
        let vector = zip(foreground, outline).map { $0.0 - $0.1 }
        let norm = vector.reduce(0) { $0 + $1 * $1 }
        guard norm >= 32 * 32 else { return nil }
        func coverage(_ bytes: [UInt8]) -> Coverage? {
            var result = Coverage(mask: .init(repeating: false, count: count), soft: .init(repeating: 0, count: count),
                valid: .init(repeating: false, count: count))
            for pixel in 0..<count {
                let offset = pixel * 4
                guard bytes[offset + 3] == 255 else { return nil }
                var numerator = 0.0
                for channel in 0..<3 { numerator += (Double(bytes[offset + channel]) - outline[channel]) * vector[channel] }
                let projected = numerator / norm, clipped = min(1, max(0, projected))
                var error = 0.0
                for channel in 0..<3 {
                    error = max(error, abs(Double(bytes[offset + channel]) - outline[channel] - clipped * vector[channel]))
                }
                result.valid[pixel] = error <= 8
                result.mask[pixel] = projected >= 0.5 && error <= 8
                result.soft[pixel] = error <= 8 ? clipped : 0
            }
            return result
        }
        guard let left = coverage(reference), let right = coverage(actual) else { return nil }
        let leftCount = left.mask.filter { $0 }.count, rightCount = right.mask.filter { $0 }.count
        guard leftCount >= 32, rightCount >= 32 else { return nil }
        let areaDifference = Double(abs(leftCount - rightCount)) / Double(leftCount)
        let leftMass = left.soft.reduce(0, +), rightMass = right.soft.reduce(0, +)
        let coverageDifference = abs(leftMass - rightMass) / leftMass
        let redistribution = zip(left.soft, right.soft).reduce(0) { $0 + abs($1.0 - $1.1) } / leftMass
        guard areaDifference <= 0.01, coverageDifference <= 0.01, redistribution <= 0.10 else { return nil }
        func neighbors(_ pixel: Int) -> [Int] {
            let x = pixel % width, y = pixel / width
            return (max(0, y - 1)...min(height - 1, y + 1)).flatMap { row in
                (max(0, x - 1)...min(width - 1, x + 1)).map { row * width + $0 }
            }
        }
        // No cropped-off glyph component is certifiable.
        for pixel in 0..<count where left.mask[pixel] || right.mask[pixel] {
            let x = pixel % width, y = pixel / width
            guard x >= 2, y >= 2, x < width - 2, y < height - 2 else { return nil }
        }
        func boundary(_ mask: [Bool]) -> [Bool] {
            mask.indices.map { pixel in mask[pixel] && neighbors(pixel).contains { !mask[$0] } }
        }
        let leftBoundary = boundary(left.mask), rightBoundary = boundary(right.mask)
        for pixel in 0..<count {
            let nearby = neighbors(pixel)
            if left.mask[pixel] && !nearby.contains(where: { right.mask[$0] }) { return nil }
            if right.mask[pixel] && !nearby.contains(where: { left.mask[$0] }) { return nil }
            if leftBoundary[pixel] && !nearby.contains(where: { rightBoundary[$0] }) { return nil }
            if rightBoundary[pixel] && !nearby.contains(where: { leftBoundary[$0] }) { return nil }
        }
        func components(_ mask: [Bool]) -> Components {
            var result = Components(labels: .init(repeating: -1, count: count), pixels: [])
            for pixel in 0..<count where mask[pixel] && result.labels[pixel] < 0 {
                let label = result.pixels.count
                var queue = [pixel], head = 0
                result.labels[pixel] = label
                while head < queue.count {
                    let current = queue[head]; head += 1
                    for neighbor in neighbors(current) where mask[neighbor] && result.labels[neighbor] < 0 {
                        result.labels[neighbor] = label
                        queue.append(neighbor)
                    }
                }
                result.pixels.append(queue)
            }
            return result
        }
        let leftComponents = components(left.mask), rightComponents = components(right.mask)
        guard leftComponents.pixels.count == rightComponents.pixels.count else { return nil }
        var paired: Set<Int> = [], maximumComponentDifference = 0.0
        for component in leftComponents.pixels {
            let leftExpansion = Set(component.flatMap(neighbors))
            let matches = Set(leftExpansion.map { rightComponents.labels[$0] }.filter { $0 >= 0 })
            guard matches.count == 1, let match = matches.first, paired.insert(match).inserted else { return nil }
            let other = rightComponents.pixels[match]
            let rightExpansion = Set(other.flatMap(neighbors))
            let componentLeftMass = leftExpansion.reduce(0) { $0 + left.soft[$1] }
            let componentRightMass = rightExpansion.reduce(0) { $0 + right.soft[$1] }
            guard componentLeftMass > 0 else { return nil }
            let massDifference = abs(componentLeftMass - componentRightMass) / componentLeftMass
            guard massDifference <= 0.01 else { return nil }
            maximumComponentDifference = max(maximumComponentDifference, massDifference)
        }
        var certified = 0
        for pixel in 0..<count {
            let offset = pixel * 4
            let difference = (0..<4).map { abs(Int(reference[offset + $0]) - Int(actual[offset + $0])) }.max() ?? 0
            guard difference > 8 else { continue }
            guard left.valid[pixel], right.valid[pixel], neighbors(pixel).contains(where: {
                leftBoundary[$0] || rightBoundary[$0]
            }) else { return nil }
            certified += 1
        }
        guard certified > 0 else { return nil }
        return Evidence(referenceFillPixels: leftCount, actualFillPixels: rightCount, relativeAreaDifference: areaDifference,
            relativeCoverageDifference: coverageDifference, componentCount: paired.count,
            maximumComponentCoverageDifference: maximumComponentDifference,
            relativeCoverageRedistribution: redistribution, certifiedPixelsAboveEight: certified)
    }
}
