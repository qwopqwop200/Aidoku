import CoreGraphics
import Foundation

/// A conservative original-color bounding witness, never an erasure mask.
/// False positives preserve the old larger backing; no pixel-shaped paint is emitted.
enum NativeSourceCoverageWitness {
    struct Evidence {
        let bounds: CGRect
        let backgroundSupport: Double
    }
    static func bounds(rgba: [UInt8], width: Int, height: Int, roi: CGRect,
                       surface: NativeTextBoxContainment.Surface, foreground: [Double], stroke: [Double],
                       background: [Double], peers: [CGRect], maximumGlyphSpan: CGFloat? = nil) throws -> CGRect? {
        try evidence(rgba: rgba, width: width, height: height, roi: roi, surface: surface,
            foreground: foreground, stroke: stroke, background: background, peers: peers,
            maximumGlyphSpan: maximumGlyphSpan)?.bounds
    }

    static func evidence(rgba: [UInt8], width: Int, height: Int, roi: CGRect,
                         surface: NativeTextBoxContainment.Surface, foreground: [Double], stroke: [Double],
                         background: [Double], peers: [CGRect], maximumGlyphSpan: CGFloat? = nil) throws -> Evidence? {
        guard width >= 8, height >= 8, width <= 320, height <= 320,
              rgba.count == width * height * 4, roi.width > 0, roi.height > 0,
              [foreground, stroke, background].allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isFinite) }),
              zip(foreground, stroke).map({ abs($0.0 - $0.1) }).max()! >= 48,
              zip(foreground, background).map({ abs($0.0 - $0.1) }).max()! >= 48 else { return nil }
        let dx = roi.width / CGFloat(width), dy = roi.height / CGFloat(height)
        let distinctStroke = zip(stroke, background).map { abs($0.0 - $0.1) }.max()! >= 48
        func matches(_ x: Int, _ y: Int, _ rgb: [Double]) -> Bool {
            guard x >= 0, y >= 0, x < width, y < height else { return false }
            let offset = (y * width + x) * 4
            return rgba[offset + 3] >= 240 && (0..<3).allSatisfy { abs(Double(rgba[offset + $0]) - rgb[$0]) <= 20 }
        }
        // Connected palette observations reject long balloon rims and large
        // artwork islands that share the font palette. These are only bounding
        // evidence; no component bitmap is retained or used to erase/paint.
        var rejected = Set<Int>()
        if let maximumGlyphSpan, maximumGlyphSpan.isFinite, maximumGlyphSpan > 0 {
            var visited = Set<Int>()
            for seed in 0..<(width * height) where !visited.contains(seed)
                && matches(seed % width, seed / width, foreground) {
                if seed.isMultiple(of: 1024) { try Task.checkCancellation() }
                var points = [seed], cursor = 0
                var left = seed % width, right = left, top = seed / width, bottom = top
                visited.insert(seed)
                while cursor < points.count {
                    let index = points[cursor], x = index % width, y = index / width
                    cursor += 1
                    left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
                    for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                        where nx >= 0 && ny >= 0 && nx < width && ny < height {
                        let next = ny * width + nx
                        if !visited.contains(next), matches(nx, ny, foreground) {
                            visited.insert(next); points.append(next)
                        }
                    }
                }
                if CGFloat(right - left + 1) * dx > maximumGlyphSpan
                    || CGFloat(bottom - top + 1) * dy > maximumGlyphSpan {
                    rejected.formUnion(points)
                }
            }
        }
        var minX = width, maxX = -1, minY = height, maxY = -1, count = 0
        var backgroundSamples = 0, backgroundMatches = 0
        for y in 1..<(height - 1) {
            if y.isMultiple(of: 32) { try Task.checkCancellation() }
            for x in stride(from: 1, to: width - 1, by: 4) {
                let point = CGPoint(x: roi.minX + (CGFloat(x) + 0.5) * dx,
                                    y: roi.minY + (CGFloat(y) + 0.5) * dy)
                if surface.contains(CGRect(x: point.x, y: point.y, width: dx / 2, height: dy / 2)) {
                    backgroundSamples += 1
                    if matches(x, y, background) { backgroundMatches += 1 }
                }
            }
            for x in 1..<(width - 1) where !rejected.contains(y * width + x) && matches(x, y, foreground) {
                let point = CGPoint(x: roi.minX + (CGFloat(x) + 0.5) * dx,
                                    y: roi.minY + (CGFloat(y) + 0.5) * dy)
                // Exclude balloon rims and other paragraphs. Interior paired
                // source colors, including rejected/unassigned OCR fragments,
                // still witness ORIGINAL ink that shrinking must not uncover.
                guard surface.contains(CGRect(x: point.x, y: point.y,
                    width: dx / 2, height: dy / 2)), !peers.contains(where: { $0.contains(point) }) else { continue }
                let directions = [(1, 0), (-1, 0), (0, 1), (0, -1)]
                let nearest = directions.map { direction in
                    (1...8).first { matches(x + direction.0 * $0, y + direction.1 * $0, stroke) }
                }
                // A single white rim beside similarly colored artwork is not
                // evidence of an outlined source glyph. Require an enclosing
                // pair on one axis, rather than any nearby outline-colored pixel.
                let paired = (nearest[0] != nil && nearest[1] != nil)
                    || (nearest[2] != nil && nearest[3] != nil)
                guard paired else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y); count += 1
                if distinctStroke {
                    for (directionIndex, direction) in directions.enumerated() {
                        guard let first = nearest[directionIndex] else { continue }
                        for offset in first...8 {
                            let sx = x + direction.0 * offset, sy = y + direction.1 * offset
                            guard matches(sx, sy, stroke) else { break }
                            minX = min(minX, sx); maxX = max(maxX, sx)
                            minY = min(minY, sy); maxY = max(maxY, sy)
                        }
                    }
                }
            }
        }
        guard count >= 6, maxX >= minX, maxY >= minY else { return nil }
        return Evidence(bounds: CGRect(x: roi.minX + CGFloat(minX) * dx, y: roi.minY + CGFloat(minY) * dy,
            width: CGFloat(maxX - minX + 1) * dx, height: CGFloat(maxY - minY + 1) * dy),
            backgroundSupport: backgroundSamples == 0 ? 0 : Double(backgroundMatches) / Double(backgroundSamples))
    }
}
