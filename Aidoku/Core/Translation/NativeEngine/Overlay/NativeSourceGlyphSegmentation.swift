import CoreGraphics
import Foundation

/// Native source-component policies ported from the frozen browser segmenter. All geometry
/// is local crop pixels; accepted components never authorize rectangular source erasure.
enum NativeSourceGlyphSegmentation {
    struct Ink: Sendable {
        var foreground: [Double]
        var background: [Double]?
        var stroke: [Double]? = nil
        var outline: [Double]? = nil
        var backgroundConfidence: Double = 0
    }

    struct Palette: Sendable {
        var foreground: [Double]
        var background: [Double]?
        var stroke: [Double]? = nil
        var outline: [Double]? = nil
        var backgroundConfidence: Double = 0
        var strokeConfidence: Double = 0
        var sourceInk: Ink? = nil
    }

    struct Options: Sendable {
        var polygons: [[CGPoint]] = []
        var excludedPolygons: [[CGPoint]] = []
        var glyphSize: Double = 0
        var conservative = true
    }

    struct Ownership: Sendable {
        let mask: [UInt8]
        let core: [UInt8]
    }

    struct Result: Sendable {
        var mask: [UInt8]
        var sourceCorePixels: Int = 0
        var sourceComponents: Int = 0
        var sourceCoreCandidateCount: Int = 0
        var sourceCoreCandidateCovered: Int = 0
        var sourceOutlineCandidateCount: Int = 0
        var sourceOutlineCandidateCovered: Int = 0
        var sourceCoreCandidateMask: [UInt8] = []
        var sourceOutlineCandidateMask: [UInt8] = []
        var denseSurfaceRecovered = false
    }

    private struct Component {
        let pixels: [Int]
        let left: Int
        let right: Int
        let top: Int
        let bottom: Int
        var width: Int { right - left + 1 }
        var height: Int { bottom - top + 1 }
        var halo: Double = 0
        var outer: Double = 0
        var whiteFill: Double = 0
        var boundaryArtifact = false
    }

    static func geometryMask(width: Int, height: Int, polygons: [[CGPoint]], excluded: [[CGPoint]] = [], margin: Double = 0) -> Ownership? {
        guard width > 0, height > 0, width <= 750_000 / height else { return nil }
        func valid(_ polygon: [CGPoint]) -> Bool {
            guard (3...32).contains(polygon.count), polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
            return abs(polygon.enumerated().reduce(CGFloat.zero) { total, pair in
                let next = polygon[(pair.offset + 1) % polygon.count]
                return total + pair.element.x * next.y - next.x * pair.element.y
            }) >= 8
        }
        guard polygons.contains(where: valid) else { return nil }
        func raster(_ shapes: [[CGPoint]]) -> [UInt8] {
            var mask = [UInt8](repeating: 0, count: width * height)
            let shapes = shapes.filter(valid).filter { shape in
                (shape.map(\.x).min() ?? 0) < CGFloat(width) && (shape.map(\.x).max() ?? 0) > 0 &&
                    (shape.map(\.y).min() ?? 0) < CGFloat(height) && (shape.map(\.y).max() ?? 0) > 0
            }.prefix(64)
            for shape in shapes {
                // Clamp in floating point before converting off-canvas coordinates.
                let x0 = Int(max(0, min(CGFloat(width), floor(shape.map(\.x).min() ?? 0))))
                let x1 = Int(max(0, min(CGFloat(width), ceil(shape.map(\.x).max() ?? 0))))
                let y0 = Int(max(0, min(CGFloat(height), floor(shape.map(\.y).min() ?? 0))))
                let y1 = Int(max(0, min(CGFloat(height), ceil(shape.map(\.y).max() ?? 0))))
                guard x0 < x1, y0 < y1 else { continue }
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        let px = CGFloat(x) + 0.5, py = CGFloat(y) + 0.5
                        var inside = false, previous = shape.count - 1
                        for index in shape.indices {
                            let a = shape[index], b = shape[previous]
                            if (a.y > py) != (b.y > py), px < (b.x - a.x) * (py - a.y) / (b.y - a.y) + a.x { inside.toggle() }
                            previous = index
                        }
                        if inside { mask[y * width + x] = 1 }
                    }
                }
            }
            return mask
        }
        let core = raster(polygons), radius = Int(min(12, max(0, ceil(margin.isFinite ? margin : 0))))
        var mask = core
        if radius > 0 {
            var horizontal = [UInt8](repeating: 0, count: core.count)
            mask = [UInt8](repeating: 0, count: core.count)
            for y in 0..<height {
                var count = (0..<min(width, radius)).reduce(0) { $0 + Int(core[y * width + $1]) }
                for x in 0..<width {
                    if x + radius < width { count += Int(core[y * width + x + radius]) }
                    if x - radius - 1 >= 0 { count -= Int(core[y * width + x - radius - 1]) }
                    horizontal[y * width + x] = count > 0 ? 1 : 0
                }
            }
            for x in 0..<width {
                var count = (0..<min(height, radius)).reduce(0) { $0 + Int(horizontal[$1 * width + x]) }
                for y in 0..<height {
                    if y + radius < height { count += Int(horizontal[(y + radius) * width + x]) }
                    if y - radius - 1 >= 0 { count -= Int(horizontal[(y - radius - 1) * width + x]) }
                    mask[y * width + x] = count > 0 ? 1 : 0
                }
            }
        }
        let other = raster(excluded)
        for index in mask.indices where other[index] != 0 && core[index] == 0 { mask[index] = 0 }
        return Ownership(mask: mask, core: core)
    }

    static func forcedTextMask(rgba: [UInt8], width: Int, height: Int, box: CGRect,
                               palette: Palette, options: Options = Options()) -> Result? {
        let ink = palette.sourceInk ?? Ink(foreground: palette.foreground, background: palette.background,
            stroke: palette.stroke, outline: palette.outline, backgroundConfidence: palette.backgroundConfidence)
        let fg = ink.foreground, bg = ink.background
        let limit = options.conservative ? 750_000 : 262_144
        guard width >= 5, height >= 5, width <= limit / height, width * height >= 64,
              rgba.count == width * height * 4, validColor(fg),
              [box.minX, box.minY, box.width, box.height].allSatisfy(\.isFinite), box.width > 0, box.height > 0 else { return nil }
        let n = width * height, dark = (fg.max() ?? 255) <= 135, chromatic = (fg.max() ?? 0) - (fg.min() ?? 0) >= 75
        let backgroundContrast = bg.map { validColor($0) ? distance($0, fg) : 0 } ?? 0
        let observedSurface = backgroundContrast >= 60 && ink.backgroundConfidence >= 0.55
        guard dark || chromatic || observedSurface else { return nil }
        func close(_ index: Int) -> Bool { pixelDistance(rgba, index: index, color: fg) <= 40 }
        func bright(_ index: Int) -> Bool {
            let offset = index * 4, channels = [rgba[offset], rgba[offset + 1], rgba[offset + 2]]
            return (channels.min() ?? 0) >= 210 && Int(channels.max() ?? 0) - Int(channels.min() ?? 0) <= 48
        }
        func surface(_ index: Int) -> Bool {
            bright(index) || observedSurface && bg.map { pixelDistance(rgba, index: index, color: $0) <= 28 } == true
        }
        let ownership = geometryMask(width: width, height: height, polygons: options.polygons, excluded: options.excludedPolygons, margin: 7)
        let x0 = Int(max(2, min(CGFloat(width), floor(box.minX - 7))))
        let y0 = Int(max(2, min(CGFloat(height), floor(box.minY - 7))))
        let x1 = Int(min(CGFloat(width - 3), max(1, ceil(box.maxX + 7))))
        let y1 = Int(min(CGFloat(height - 3), max(1, ceil(box.maxY + min(46, max(14, box.height * 0.13))))))
        guard x0 <= x1, y0 <= y1 else { return nil }
        var raw = [UInt8](repeating: 0, count: n), mask = raw, coreCandidate = raw
        for y in y0...y1 {
            for x in x0...x1 {
                let index = y * width + x
                if (ownership == nil || ownership?.mask[index] != 0) && close(index) { raw[index] = 1 }
            }
        }
        let maxDimension: Double
        if options.conservative && options.glyphSize > 0 { maxDimension = min(180, max(48, options.glyphSize * 1.6)) }
        else if options.conservative && dark && !(bg.map { validColor($0) && ($0.min() ?? 0) >= 230 } == true) { maxDimension = 56 }
        else { maxDimension = min(78, max(48, Double(min(box.width, box.height)) * 0.48)) }
        let maxArea: Double = options.conservative ? (options.glyphSize > 0 ? max(3_200, options.glyphSize * options.glyphSize * 1.3) :
            (dark ? max(3_200, Double(box.width * box.height) * 0.14) : max(1_800, Double(box.width * box.height) * 0.08))) :
            max(1_800, Double(box.width * box.height) * 0.08)
        var strong: [Component] = [], weak: [Component] = []
        for var component in components(raw, width: width, height: height, diagonal: false) {
            let l = component.left, r = component.right, t = component.top, d = component.bottom
            let cw = component.width, ch = component.height, area = cw * ch
            guard CGFloat(r) >= box.minX - 1, CGFloat(l) <= box.maxX + 1, CGFloat(d) >= box.minY - 1, CGFloat(t) <= box.maxY + 1,
                  component.pixels.count >= 3, Double(cw) <= maxDimension, Double(ch) <= maxDimension,
                  Double(area) <= maxArea, l >= 2, t >= 2, r < width - 2, d < height - 2 else { continue }
            var ring2 = 0, ring4 = 0, total2 = 0, total4 = 0, interior = 0
            for y in max(2, t - 4)...min(height - 3, d + 4) {
                for x in max(2, l - 4)...min(width - 3, r + 4) {
                    let dist = max(max(l - x, x - r, 0), max(t - y, y - d, 0)), index = y * width + x
                    if dist == 2 { total2 += 1; if surface(index) { ring2 += 1 } }
                    if dist == 4 { total4 += 1; if surface(index) { ring4 += 1 } }
                    if dist == 0 && bright(index) { interior += 1 }
                }
            }
            component.halo = Double(ring2) / Double(max(1, total2)); component.outer = Double(ring4) / Double(max(1, total4))
            component.whiteFill = Double(interior) / Double(area)
            let outside = CGFloat(l) < box.minX - 2 || CGFloat(r) > box.maxX + 2 || CGFloat(t) < box.minY - 2 || CGFloat(d) > box.maxY + 2
            component.boundaryArtifact = outside && component.pixels.count < 60 ||
                (CGFloat(l) < box.minX + 3 || CGFloat(r) > box.maxX - 3) && cw > 35 && component.pixels.count < 180
            let solid = !component.boundaryArtifact && ((dark || observedSurface) ? component.halo >= 0.30 && component.outer >= 0.22 :
                component.whiteFill >= 0.16 && Double(component.pixels.count) >= max(18, Double(area) * 0.13))
            if solid { strong.append(component) } else { weak.append(component) }
        }
        guard strong.count >= 2 else { return nil }
        for component in strong + weak where !component.boundaryArtifact &&
            (dark ? component.halo >= 0.22 && component.outer >= 0.15 : component.whiteFill >= 0.10) {
            for index in component.pixels { coreCandidate[index] = 1 }
        }
        var accepted = strong
        for component in weak where !component.boundaryArtifact && component.pixels.count <= 140 &&
            component.right - component.left < 34 && component.bottom - component.top < 36 && strong.contains(where: {
                max($0.left - component.right, component.left - $0.right, 0) <= 9 &&
                    max($0.top - component.bottom, component.top - $0.bottom, 0) <= 14
            }) { accepted.append(component) }
        for component in accepted { for index in component.pixels { mask[index] = 1; coreCandidate[index] = 1 } }
        if dark {
            let owned = mask
            for y in y0...y1 {
                for x in x0...x1 {
                    let index = y * width + x
                    guard raw[index] != 0, mask[index] == 0 else { continue }
                    var near = false
                    for yy in max(y0, y - 13)...min(y1, y + 13) where !near {
                        for xx in max(x0, x - 13)...min(x1, x + 13) where owned[yy * width + xx] != 0 { near = true; break }
                    }
                    guard near else { continue }
                    func probe(_ dx: Int, _ dy: Int) -> Bool {
                        for step in 1...6 {
                            let xx = x + dx * step, yy = y + dy * step
                            guard xx >= 2, yy >= 2, xx < width - 2, yy < height - 2 else { break }
                            if bright(yy * width + xx) { return true }
                        }
                        return false
                    }
                    if probe(-1, 0) && probe(1, 0) || probe(0, -1) && probe(0, 1) { mask[index] = 1 }
                }
            }
        }
        var seenHole = [UInt8](repeating: 0, count: n)
        for component in accepted where chromatic && component.whiteFill >= 0.12 {
            for y in component.top...component.bottom {
                for x in component.left...component.right {
                    let start = y * width + x
                    guard raw[start] == 0, seenHole[start] == 0, bright(start) else { continue }
                    var group = [start], head = 0, edge = false
                    seenHole[start] = 1
                    while head < group.count && group.count <= 400 {
                        let index = group[head], xx = index % width, yy = index / width
                        head += 1
                        if xx <= component.left || xx >= component.right || yy <= component.top || yy >= component.bottom { edge = true; break }
                        for neighbor in [index - 1, index + 1, index - width, index + width] where
                            raw[neighbor] == 0 && seenHole[neighbor] == 0 && bright(neighbor) {
                            seenHole[neighbor] = 1; group.append(neighbor)
                        }
                    }
                    if !edge && group.count <= 400 { for index in group { mask[index] = 1 } }
                }
            }
        }
        let observedStroke = palette.strokeConfidence >= 0.55 && validColor(palette.foreground) && distance(palette.foreground, fg) <= 24 ? palette.stroke : nil
        let stroke = ink.stroke ?? ink.outline ?? observedStroke
        let outlined = stroke.map { validColor($0) && distance($0, fg) >= 48 } == true
        let seeds = mask.indices.filter { mask[$0] != 0 }, plain = !outlined && !chromatic
        for index in seeds {
            let x = index % width, y = index / width
            for yy in max(2, y - 5)...min(height - 3, y + 5) {
                for xx in max(2, x - 5)...min(width - 3, x + 5) {
                    let dist = abs(xx - x) + abs(yy - y)
                    guard dist <= 5, xx >= x0, xx <= x1, yy >= y0, yy <= y1 else { continue }
                    let target = yy * width + xx, offset = target * 4
                    if plain && dist > 2 && min(rgba[offset], rgba[offset + 1], rgba[offset + 2]) >= 248 { continue }
                    mask[target] = 1
                }
            }
        }
        if let ownership { for index in mask.indices where ownership.mask[index] == 0 { mask[index] = 0 } }
        var candidateCount = 0, candidateCovered = 0, outlineCount = 0, outlineCovered = 0
        var outlineCandidate = [UInt8](repeating: 0, count: n)
        if outlined, let bg, !validColor(bg) { return nil }
        let separateOutline = outlined && bg != nil && stroke.map { distance($0, bg!) >= 48 } == true
        let outlineRadius = separateOutline ? Int(min(14, max(4, ceil(options.glyphSize * 0.13)))) : 4
        for index in coreCandidate.indices where coreCandidate[index] != 0 {
            candidateCount += 1; if mask[index] != 0 { candidateCovered += 1 }
            let x = index % width, y = index / width
            for yy in max(2, y - outlineRadius)...min(height - 3, y + outlineRadius) {
                for xx in max(2, x - outlineRadius)...min(width - 3, x + outlineRadius) {
                    guard abs(xx - x) + abs(yy - y) <= outlineRadius else { continue }
                    let target = yy * width + xx
                    if (ownership == nil || ownership?.mask[target] != 0) && coreCandidate[target] == 0 && bright(target) {
                        outlineCandidate[target] = 1
                        if outlined && (stroke?.min() ?? 0) >= 200 && mask[index] != 0 { mask[target] = 1 }
                    }
                }
            }
        }
        for index in outlineCandidate.indices where outlineCandidate[index] != 0 { outlineCount += 1; if mask[index] != 0 { outlineCovered += 1 } }
        return Result(mask: mask, sourceCorePixels: seeds.count, sourceComponents: accepted.count,
            sourceCoreCandidateCount: candidateCount, sourceCoreCandidateCovered: candidateCovered,
            sourceOutlineCandidateCount: outlineCount, sourceOutlineCandidateCovered: outlineCovered,
            sourceCoreCandidateMask: coreCandidate, sourceOutlineCandidateMask: outlineCandidate)
    }

    /// Neutral source cleanup keeps boundary-connected frames intact and admits dense crops
    /// only when independent shaped components explain the observed nonwhite surface.
    static func neutralSourceInkMask(rgba: [UInt8], width: Int, height: Int, vertical: Bool) -> Result? {
        guard width >= 14, height >= 14, width <= 262_144 / height, rgba.count == width * height * 4 else { return nil }
        let n = width * height, coreWidth = width - 5, coreHeight = height - 5
        var whiteCount = 0, coloredCount = 0, insideCount = 0, rimWhite = 0, rimTotal = 0
        func channels(_ index: Int) -> (low: Int, high: Int) {
            let p = index * 4
            return (Int(min(rgba[p], rgba[p + 1], rgba[p + 2])), Int(max(rgba[p], rgba[p + 1], rgba[p + 2])))
        }
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x, values = channels(index), white = values.low >= 245 && values.high - values.low <= 10
                guard rgba[index * 4 + 3] == 255 else { return nil }
                if x < 2 || y < 2 || x >= width - 2 || y >= height - 2 { rimTotal += 1; if white { rimWhite += 1 } }
                else { insideCount += 1; if white { whiteCount += 1 }; if values.high - values.low > 20 { coloredCount += 1 } }
            }
        }
        let dense = Double(whiteCount) / Double(insideCount) < 0.75
        guard Double(coloredCount) / Double(insideCount) <= 0.02,
              !dense || Double(rimWhite) / Double(rimTotal) >= 0.98 else { return nil }
        var dark = [UInt8](repeating: 0, count: n), mask = dark, kept = 0, shaped = 0
        for y in 2..<(height - 2) {
            for x in 2..<(width - 2) {
                let index = y * width + x, values = channels(index)
                if values.high <= 180 && values.high - values.low <= 20 { dark[index] = 1 }
            }
        }
        for component in components(dark, width: width, height: height, diagonal: true) {
            let cw = component.width, ch = component.height, count = component.pixels.count
            let touchesBoundary = component.left <= 2 || component.top <= 2 || component.right >= width - 3 || component.bottom >= height - 3
            guard !touchesBoundary, count >= 2, Double(count) <= Double(coreWidth * coreHeight) * 0.25,
                  Double(cw) <= Double(coreWidth) * 0.8, Double(ch) <= Double(coreHeight) * 0.8,
                  max(cw, ch) <= 8 * min(cw, ch) else { continue }
            for index in component.pixels { mask[index] = 255 }
            kept += count
            if cw >= 3 && ch >= 3 && count >= 6 && Double(count) / Double(cw * ch) < 0.85 { shaped += 1 }
        }
        guard kept > 0 else { return nil }
        var cleaned = mask
        for y in 3..<(height - 3) {
            for x in 3..<(width - 3) {
                let index = y * width + x, values = channels(index)
                guard mask[index] == 0, values.low > 180, values.high < 245, values.high - values.low <= 10 else { continue }
                if (-1...1).contains(where: { dy in (-1...1).contains { dx in mask[index + dy * width + dx] != 0 } }) { cleaned[index] = 255 }
            }
        }
        if dense {
            guard shaped >= 3 else { return nil }
            var remaining = 0, remainingWhite = 0, nonwhite = 0, explained = 0
            for y in 2..<(height - 2) {
                for x in 2..<(width - 2) {
                    let index = y * width + x, values = channels(index), white = values.low >= 245 && values.high - values.low <= 10
                    if !white { nonwhite += 1; if cleaned[index] != 0 { explained += 1 } }
                    if cleaned[index] == 0 {
                        remaining += 1
                        var supported = white
                        if !supported && values.low > 180 && values.high - values.low <= 10 {
                            supported = (-2...2).contains { dy in (-2...2).contains { dx in cleaned[index + dy * width + dx] != 0 } }
                        }
                        if supported { remainingWhite += 1 }
                    }
                }
            }
            guard remaining > 0, Double(remainingWhite) / Double(remaining) >= 0.99, nonwhite > 0,
                  Double(explained) / Double(nonwhite) >= 0.95 else { return nil }
        }
        _ = vertical // The frozen kernel deliberately applies the same component gates to both flows.
        return Result(mask: cleaned, sourceCorePixels: kept, sourceComponents: shaped, denseSurfaceRecovered: dense)
    }

    /// Flat-surface-only, nonrecursive antialias recovery. Distances come from the original
    /// mask; source fill and stroke alignment must not touch independently protected ink.
    @discardableResult
    static func recoverInkHalo(rgba: [UInt8], width: Int, height: Int, mask: inout [UInt8], foreground: [Double]?,
                               background: [Double], stroke: [Double]?, protectedInk: [UInt8]) -> Int {
        guard width >= 7, height >= 7, width <= 750_000 / height, rgba.count == width * height * 4,
              mask.count == width * height, protectedInk.count == mask.count, validColor(background),
              foreground.map(validColor) != false, stroke.map(validColor) != false else { return 0 }
        var distances = mask.map { $0 != 0 ? UInt8(0) : 3 }
        for y in 1..<height {
            for x in 1..<(width - 1) {
                let index = y * width + x
                distances[index] = min(distances[index], 1 + min(distances[index - 1], distances[index - width - 1],
                    distances[index - width], distances[index - width + 1]))
            }
        }
        for y in stride(from: height - 2, through: 0, by: -1) {
            for x in stride(from: width - 2, through: 1, by: -1) {
                let index = y * width + x
                distances[index] = min(distances[index], 1 + min(distances[index + 1], distances[index + width - 1],
                    distances[index + width], distances[index + width + 1]))
            }
        }
        func aligned(_ index: Int, _ color: [Double]?) -> Bool {
            guard let color else { return false }
            let d = (0..<3).map { color[$0] - background[$0] }, norm = d.reduce(0) { $0 + $1 * $1 }
            guard norm >= 64 else { return false }
            let offset = index * 4, a = (0..<3).map { Double(rgba[offset + $0]) - background[$0] }
            let t = zip(a, d).reduce(0) { $0 + $1.0 * $1.1 } / norm
            return t >= -0.02 && t <= 1.05 && ((0..<3).map { abs(a[$0] - t * d[$0]) }.max() ?? 0) <= 5
        }
        var added = 0
        for y in 3..<(height - 3) {
            for x in 3..<(width - 3) {
                let index = y * width + x
                guard distances[index] > 0, distances[index] <= 2,
                      !(-1...1).contains(where: { dy in (-1...1).contains { dx in protectedInk[index + dy * width + dx] != 0 } }),
                      aligned(index, foreground) || aligned(index, stroke) else { continue }
                mask[index] = 1; added += 1
            }
        }
        return added
    }

    struct ComponentDescriptor: Sendable {
        let box: CGRect
        let pixels: Int
    }

    struct ColoredResult: Sendable {
        var reason: String
        var mask: [UInt8]? = nil
        var fill: [Double]? = nil
        var erased = 0
        var strokeAdded = 0
        var outlineInterior = false
        var enclosedFill = 0
        var fringeAdded = 0
        var haloAdded = 0
        var acceptedCount: Int? = nil
        var accepted: [ComponentDescriptor] = []
        var rejected: [ComponentDescriptor] = []
        var solid: Double? = nil
        var rim: Double? = nil
    }

    static func coloredSourceInkMask(rgba: [UInt8], width: Int, height: Int, palette: Palette) -> ColoredResult {
        guard width > 0, height > 0, width <= 262_144 / height, rgba.count == width * height * 4,
              validColor(palette.foreground), let bg = palette.background, validColor(bg), palette.stroke.map(validColor) != false else {
            return ColoredResult(reason: "missing-palette/budget")
        }
        let sourceFG = palette.foreground, sourceStroke = palette.stroke
        let outlineInterior = sourceStroke.map { distance(sourceFG, bg) < 48 && distance($0, bg) > 55 } == true
        let fg = outlineInterior ? sourceStroke! : sourceFG, stroke = outlineInterior ? nil : sourceStroke, n = width * height
        func dist(_ index: Int, _ color: [Double]) -> Double { pixelDistance(rgba, index: index, color: color) }
        func alignment(_ index: Int, _ start: [Double]?, _ end: [Double]?) -> Bool {
            guard let start, let end else { return false }
            let d = (0..<3).map { end[$0] - start[$0] }, norm = d.reduce(0) { $0 + $1 * $1 }
            guard norm >= 64 else { return false }
            let a = (0..<3).map { Double(rgba[index * 4 + $0]) - start[$0] }
            let t = zip(a, d).reduce(0) { $0 + $1.0 * $1.1 } / norm
            return t >= 0.08 && t <= 1.15 && ((0..<3).map { abs(a[$0] - t * d[$0]) }.max() ?? 0) <= 18
        }
        var raw = [UInt8](repeating: 0, count: n), owned = raw, protected = raw
        for index in 0..<n {
            guard rgba[index * 4 + 3] == 255 else { return ColoredResult(reason: "alpha") }
            if dist(index, bg) > 18 && (dist(index, fg) <= 48 || alignment(index, bg, fg) || (stroke != nil && alignment(index, stroke, fg))) {
                raw[index] = 1
            }
        }
        let all = components(raw, width: width, height: height, diagonal: true)
        func edge(_ component: Component) -> Bool {
            component.left < 2 || component.top < 2 || component.right >= width - 2 || component.bottom >= height - 2
        }
        func core(_ component: Component) -> Int { component.pixels.filter { dist($0, fg) <= 48 }.count }
        let plausibleIndices = all.indices.filter { index in
            let c = all[index]
            return !edge(c) && core(c) >= 2 && c.pixels.count >= 3 && max(c.width, c.height) <= 8 * min(c.width, c.height) &&
                Double(c.width) < Double(width) * 0.85 && Double(c.height) < Double(height) * 0.85
        }
        guard plausibleIndices.count >= 3 else { return ColoredResult(reason: "few-independent-ink-components") }
        let horizontal = width > height
        let dimensions = plausibleIndices.map { all[$0] }.filter { $0.pixels.count >= 12 }.map { horizontal ? $0.width : $0.height }.sorted()
        let median = dimensions.isEmpty ? 0 : dimensions[dimensions.count / 2]
        func enclosed(_ component: Component) -> [UInt8] {
            let cw = component.width + 2, ch = component.height + 2
            var wall = [UInt8](repeating: 0, count: cw * ch), outside = wall
            for index in component.pixels { wall[(index / width - component.top + 1) * cw + index % width - component.left + 1] = 1 }
            var queue = [0], head = 0; outside[0] = 1
            while head < queue.count {
                let index = queue[head], x = index % cw, y = index / cw; head += 1
                for next in [x > 0 ? index - 1 : -1, x + 1 < cw ? index + 1 : -1, y > 0 ? index - cw : -1, y + 1 < ch ? index + cw : -1] {
                    guard next >= 0, outside[next] == 0, wall[next] == 0 else { continue }
                    outside[next] = 1; queue.append(next)
                }
            }
            return outside.enumerated().map { index, value in value == 0 && wall[index] == 0 ? 1 : 0 }
        }
        func joinedEvidence(_ component: Component) -> Bool {
            guard outlineInterior, !edge(component), component.pixels.count >= 24 else { return false }
            let cw = component.width + 2, ch = component.height + 2
            let holes = enclosed(component)
            var islands = [UInt8](repeating: 0, count: holes.count)
            for y in 1..<(ch - 1) {
                for x in 1..<(cw - 1) {
                    let local = y * cw + x, global = (component.top + y - 1) * width + component.left + x - 1
                    if holes[local] != 0 && dist(global, sourceFG) <= 8 && dist(global, sourceFG) + 4 < dist(global, bg) { islands[local] = 1 }
                }
            }
            return components(islands, width: cw, height: ch, diagonal: true).filter {
                $0.pixels.count >= 4 && $0.width >= 2 && $0.height >= 2 &&
                    Double($0.pixels.count) <= Double(component.width * component.height) * 0.35
            }.count >= 3
        }
        let plausible = Set(plausibleIndices)
        var acceptedIndices: [Int] = []
        for index in all.indices {
            let c = all[index], keep = plausible.contains(index) && (Double(horizontal ? c.width : c.height) <= Double(median) * 1.8 || joinedEvidence(c))
            for pixel in c.pixels { if keep { owned[pixel] = 1 } else { protected[pixel] = 1 } }
            if keep { acceptedIndices.append(index) }
        }
        guard acceptedIndices.count >= 3 else { return ColoredResult(reason: "few-glyph-scale-components") }
        var mask = owned, strokeAdded = 0, enclosedFill = 0
        if let stroke, distance(stroke, bg) > 18 {
            var distances = [Int](repeating: -1, count: n), queue: [Int] = [], head = 0
            for index in owned.indices where owned[index] != 0 { distances[index] = 0; queue.append(index) }
            let radius = Int(min(12, max(2, floor(Double(median) * 0.35 + 0.5))))
            while head < queue.count {
                let index = queue[head], x = index % width, y = index / width; head += 1
                guard distances[index] < radius else { continue }
                for next in [x > 0 ? index - 1 : -1, x + 1 < width ? index + 1 : -1, y > 0 ? index - width : -1, y + 1 < height ? index + width : -1] {
                    guard next >= 0, distances[next] < 0, protected[next] == 0, dist(next, bg) > 18,
                          dist(next, stroke) <= 30 || alignment(next, bg, stroke) || alignment(next, fg, stroke) else { continue }
                    distances[next] = distances[index] + 1; queue.append(next); mask[next] = 1; strokeAdded += 1
                }
            }
        }
        if outlineInterior {
            for index in acceptedIndices {
                let c = all[index], cw = c.width + 2, ch = c.height + 2, holes = enclosed(c)
                for y in 1..<(ch - 1) {
                    for x in 1..<(cw - 1) {
                        let local = y * cw + x, global = (c.top + y - 1) * width + c.left + x - 1
                        if holes[local] != 0 && mask[global] == 0 && protected[global] == 0 &&
                            dist(global, sourceFG) <= 18 && dist(global, sourceFG) + 4 < dist(global, bg) { mask[global] = 1; enclosedFill += 1 }
                    }
                }
            }
        }
        var clean = 0, total = 0, rimClean = 0, rimTotal = 0
        var histograms = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 3)
        for index in 0..<n {
            let x = index % width, y = index / width, solid = dist(index, bg) <= 18
            if x < 3 || y < 3 || x >= width - 3 || y >= height - 3 { rimTotal += 1; if solid { rimClean += 1 } }
            if mask[index] != 0 || protected[index] != 0 { continue }
            total += 1
            if solid { clean += 1; for c in 0..<3 { histograms[c][Int(rgba[index * 4 + c])] += 1 } }
        }
        let solidRatio = Double(clean) / Double(total), rimRatio = Double(rimClean) / Double(rimTotal)
        if solidRatio < 0.94 || rimRatio < 0.9 && solidRatio < 0.98 {
            return ColoredResult(reason: "not-flat-after-owned-mask", strokeAdded: strokeAdded,
                acceptedCount: acceptedIndices.count, solid: solidRatio, rim: rimRatio)
        }
        let fill = histograms.map { histogram -> Double in
            var cumulative = 0
            for value in 0..<256 { cumulative += histogram[value]; if cumulative > clean / 2 { return Double(value) } }
            return Double.nan
        }
        var fringeAdded = 0
        if outlineInterior && distance(sourceFG, bg) <= 24, let sourceStroke {
            let before = mask, d = (0..<3).map { sourceStroke[$0] - bg[$0] }, norm = d.reduce(0) { $0 + $1 * $1 }
            if norm >= 64 && width >= 7 && height >= 7 {
                for y in 3..<(height - 3) {
                    for x in 3..<(width - 3) {
                        let index = y * width + x
                        guard before[index] == 0, protected[index] == 0 else { continue }
                        let neighbors = [-width - 1, -width, -width + 1, -1, 1, width - 1, width, width + 1].map { index + $0 }
                        guard neighbors.contains(where: { before[$0] != 0 }),
                              !([index] + neighbors).contains(where: { before[$0] == 0 && (raw[$0] != 0 || protected[$0] != 0) }) else { continue }
                        let a = (0..<3).map { Double(rgba[index * 4 + $0]) - bg[$0] }, t = zip(a, d).reduce(0) { $0 + $1.0 * $1.1 } / norm
                        guard t >= -0.005, t <= 0.6, ((0..<3).map { abs(a[$0] - t * d[$0]) }.max() ?? 0) <= 4 else { continue }
                        mask[index] = 1; fringeAdded += 1
                    }
                }
            }
        }
        let acceptedSet = Set(acceptedIndices)
        var haloProtection = [UInt8](repeating: 0, count: n)
        for index in all.indices where !acceptedSet.contains(index) {
            let c = all[index]
            if edge(c) || core(c) > 0 || c.pixels.count > 12 || Double(max(c.width, c.height)) > Double(median) * 0.5 {
                for pixel in c.pixels { haloProtection[pixel] = 1 }
            }
        }
        let haloAdded = recoverInkHalo(rgba: rgba, width: width, height: height, mask: &mask,
            foreground: sourceFG, background: fill, stroke: sourceStroke, protectedInk: haloProtection)
        return ColoredResult(reason: "accepted", mask: mask, fill: fill, erased: mask.filter { $0 != 0 }.count,
            strokeAdded: strokeAdded, outlineInterior: outlineInterior, enclosedFill: enclosedFill, fringeAdded: fringeAdded, haloAdded: haloAdded,
            accepted: acceptedIndices.map { descriptor(all[$0]) }, rejected: all.indices.filter { !acceptedSet.contains($0) }.map { descriptor(all[$0]) },
            solid: solidRatio, rim: rimRatio)
    }

    private static func descriptor(_ component: Component) -> ComponentDescriptor {
        ComponentDescriptor(box: CGRect(x: component.left, y: component.top, width: component.width, height: component.height), pixels: component.pixels.count)
    }

    enum Side: String, Sendable { case start, end }
    struct Marks: Sendable { var rects: [CGRect] = []; var open = false }

    /// Infer only a complete punctuation run adjoining the caption's own reading band.
    static func rowEndMarks(rgba: [UInt8], width: Int, height: Int, box: CGRect, glyph: Double,
                            palette: Palette, vertical: Bool, side: Side, excluded: [CGRect] = [],
                            pair: [Double]? = nil, allowDotRun: Bool = false) -> Marks {
        guard validColor(palette.foreground), let bg = palette.background, validColor(bg), glyph >= 6,
              width >= 4, height >= 4, width <= 750_000 / height, rgba.count == width * height * 4 else { return Marks() }
        let fg = palette.foreground, separation = distance(fg, bg)
        guard separation >= 60 else { return Marks() }
        let n = width * height, inkLevel = max(40, separation * 0.45), coreLevel = max(24, separation * 0.3)
        func toBg(_ index: Int) -> Double { pixelDistance(rgba, index: index, color: bg) }
        func toFg(_ index: Int) -> Double { pixelDistance(rgba, index: index, color: fg) }
        let along0 = Double(vertical ? box.minY : box.minX), along1 = Double(vertical ? box.maxY : box.maxX)
        let cross0 = Double(vertical ? box.minX : box.minY), cross1 = Double(vertical ? box.maxX : box.maxY)
        var ink = [UInt8](repeating: 0, count: n), labels = [Int](repeating: 0, count: n)
        for index in 0..<n { let distance = toBg(index); if distance >= inkLevel && toFg(index) < distance { ink[index] = 1 } }
        struct MarkComponent {
            let component: Component
            let a0: Double; let a1: Double; let c0: Double; let c1: Double
            let core: Int; let inner: Bool; let outer: Bool; let beyond: Bool; let long: Bool; let noise: Bool; let tailRule: Bool
        }
        struct Glyph {
            var a0: Double; var a1: Double; var c0: Double; var c1: Double
            var pixels: Int; var core: Int; var members: [Int]
        }
        let speck = max(3, glyph * glyph * 0.004)
        var comps: [MarkComponent] = []
        for (index, c) in components(ink, width: width, height: height, diagonal: true).enumerated() {
            for pixel in c.pixels { labels[pixel] = index + 1 }
            let a0 = Double(vertical ? c.top : c.left), a1 = Double(vertical ? c.bottom : c.right)
            let c0 = Double(vertical ? c.left : c.top), c1 = Double(vertical ? c.right : c.bottom)
            let inner = vertical ? (side == .end ? c.top <= 0 : c.bottom >= height - 1) : (side == .end ? c.left <= 0 : c.right >= width - 1)
            let outer = (vertical ? c.left <= 0 || c.right >= width - 1 : c.top <= 0 || c.bottom >= height - 1) ||
                (vertical ? (side == .end ? c.bottom >= height - 1 : c.top <= 0) : (side == .end ? c.right >= width - 1 : c.left <= 0))
            let beyond = side == .end ? a1 > along1 + 3 && a0 >= along1 - glyph : (a0 + a1) / 2 < along0 - 3
            let long = Double(max(c.width, c.height)) > glyph * 1.1
            let tailRule = side == .end && vertical && long && (palette.stroke?.min() ?? 0) >= 230 &&
                (fg.max() ?? 0) - (fg.min() ?? 0) >= 60 && Double(c.width) <= glyph * 0.25 && Double(c.height) <= glyph * 4 &&
                Double(c.top) >= along1 - glyph && Double(c.pixels.count) >= Double(c.width * c.height) * 0.55
            comps.append(MarkComponent(component: c, a0: a0, a1: a1, c0: c0, c1: c1, core: c.pixels.filter { toFg($0) <= coreLevel }.count,
                inner: inner, outer: outer, beyond: beyond, long: long, noise: Double(c.pixels.count) < speck, tailRule: tailRule))
        }
        guard comps.filter({ $0.beyond && !$0.noise && (side == .end ? $0.a0 <= along1 + glyph * 1.3 : $0.a1 >= along0 - glyph * 1.3) }).count <= 24 else { return Marks() }
        var glyphs: [Glyph] = []
        for (index, c) in comps.enumerated() {
            guard c.beyond, !c.inner, !c.outer, !c.long || c.tailRule, !c.noise else { continue }
            if let into = glyphs.firstIndex(where: { c.a0 <= $0.a1 + 1 && c.a1 >= $0.a0 - 1 && c.c0 <= $0.c1 + glyph * 0.2 && c.c1 >= $0.c0 - glyph * 0.2 }) {
                glyphs[into].a0 = min(glyphs[into].a0, c.a0); glyphs[into].a1 = max(glyphs[into].a1, c.a1)
                glyphs[into].c0 = min(glyphs[into].c0, c.c0); glyphs[into].c1 = max(glyphs[into].c1, c.c1)
                glyphs[into].pixels += c.component.pixels.count; glyphs[into].core += c.core; glyphs[into].members.append(index + 1)
            } else { glyphs.append(Glyph(a0: c.a0, a1: c.a1, c0: c.c0, c1: c.c1, pixels: c.component.pixels.count, core: c.core, members: [index + 1])) }
        }
        func rect(_ g: Glyph) -> CGRect {
            vertical ? CGRect(x: g.c0, y: g.a0, width: g.c1 - g.c0 + 1, height: g.a1 - g.a0 + 1) :
                CGRect(x: g.a0, y: g.c0, width: g.a1 - g.a0 + 1, height: g.c1 - g.c0 + 1)
        }
        func clearRing(_ g: Glyph) -> Bool {
            let r = rect(g), x0 = Int(r.minX), y0 = Int(r.minY), x1 = Int(r.maxX - 1), y1 = Int(r.maxY - 1)
            let radius = Int(max(2, floor(glyph * 0.15 + 0.5)))
            var samples = 0, clear = 0
            for y in (y0 - radius)...(y1 + radius) {
                for x in (x0 - radius)...(x1 + radius) {
                    if x >= x0 - 1 && x <= x1 + 1 && y >= y0 - 1 && y <= y1 + 1 || x < 0 || y < 0 || x >= width || y >= height { continue }
                    samples += 1; if toBg(y * width + x) <= 40 { clear += 1 }
                }
            }
            if samples >= 8 && Double(clear) >= Double(samples) * 0.95 { return true }
            guard (fg.max() ?? 0) - (fg.min() ?? 0) >= 60 else { return false }
            func white(_ x: Int, _ y: Int) -> Bool {
                guard x >= 0, y >= 0, x < width, y < height else { return false }
                let index = (y * width + x) * 4
                return min(rgba[index], rgba[index + 1], rgba[index + 2]) >= 230
            }
            let reach = Int(max(2, min(6, floor(glyph * 0.08 + 0.5))))
            var rows = 0, outlined = 0
            for y in y0...y1 {
                var left = false, right = false
                for d in 1...reach { left = left || white(x0 - d, y); right = right || white(x1 + d, y) }
                rows += 1; if left && right { outlined += 1 }
            }
            return rows >= 4 && Double(outlined) >= Double(rows) * 0.9
        }
        func qualifies(_ g: Glyph) -> Bool {
            let along = g.a1 - g.a0 + 1, cross = g.c1 - g.c0 + 1
            let tail = g.members.count == 1 && comps[g.members[0] - 1].tailRule
            guard along <= glyph * (tail ? 4 : cross <= glyph * 0.35 ? 1 : 0.6), cross <= glyph * 0.95,
                  Double(g.pixels) >= speck, g.core * 4 >= g.pixels, g.c0 >= cross0 - glyph * 0.12, g.c1 <= cross1 + glyph * 0.12 else { return false }
            let r = rect(g)
            guard !excluded.contains(where: { r.maxX >= $0.minX - 2 && r.minX <= $0.maxX + 2 && r.maxY >= $0.minY - 2 && r.minY <= $0.maxY + 2 }) else { return false }
            return clearRing(g)
        }
        func corridorClear(_ g: Glyph, edge: Double) -> Bool {
            let from = side == .end ? max(0, Int(ceil(edge)) + 1) : Int(g.a1) + 1
            let to = side == .end ? Int(g.a0) - 1 : min(vertical ? height : width, Int(floor(edge))) - 1
            let c0 = max(0, Int(floor(max(g.c0 - glyph * 0.35, cross0 - glyph * 0.12))))
            let c1 = min((vertical ? width : height) - 1, Int(ceil(min(g.c1 + glyph * 0.35, cross1 + glyph * 0.12))))
            guard from <= to, c0 <= c1 else { return true }
            var faint = 0
            for s in from...to {
                for c in c0...c1 {
                    let index = vertical ? s * width + c : c * width + s, label = labels[index]
                    if label > 0 && !g.members.contains(label) && (comps[label - 1].outer || comps[label - 1].beyond && !comps[label - 1].noise || comps[label - 1].long) { return false }
                    if label > 0 || toBg(index) <= 40 || (side == .end ? Double(s) >= g.a0 - 2 : Double(s) <= g.a1 + 2) { continue }
                    let x = index % width, y = index / width
                    let near = (-1...1).contains { dy in (-1...1).contains { dx in
                        let xx = x + dx, yy = y + dy
                        return xx >= 0 && yy >= 0 && xx < width && yy < height && labels[yy * width + xx] > 0
                    } }
                    if !near { faint += 1; if faint >= 3 { return false } }
                }
            }
            return true
        }
        let outward = glyphs.filter { $0.c1 >= cross0 - glyph * 0.12 && $0.c0 <= cross1 + glyph * 0.12 }.sorted {
            side == .end ? $0.a0 < $1.a0 : $0.a1 > $1.a1
        }
        func paired(_ g: Glyph) -> Bool {
            guard let pair, pair.count >= 2 else { return false }
            return [g.a1 - g.a0 + 1, g.c1 - g.c0 + 1].enumerated().allSatisfy { $0.element >= pair[$0.offset] * 0.75 && $0.element <= pair[$0.offset] * 1.33 }
        }
        func repeats(_ g: Glyph, _ previous: Glyph?) -> Bool {
            guard let previous else { return false }
            return [(g.a1 - g.a0, previous.a1 - previous.a0), (g.c1 - g.c0, previous.c1 - previous.c0), (Double(g.pixels), Double(previous.pixels))].allSatisfy {
                $0.0 + 1 >= ($0.1 + 1) * 0.75 && $0.0 + 1 <= ($0.1 + 1) * 1.33
            }
        }
        let dotRun = allowDotRun && side == .start && (4...24).contains(outward.count) && outward.allSatisfy { g in
            g.a1 - g.a0 + 1 <= glyph * 0.35 && g.c1 - g.c0 + 1 <= glyph * 0.35 &&
                abs((g.c0 + g.c1 - outward[0].c0 - outward[0].c1) / 2) <= glyph * 0.12 && repeats(g, outward[0])
        }
        var marks = Marks(), edge = side == .end ? along1 : along0, last: Glyph?
        for g in outward {
            let gap = side == .end ? g.a0 - edge : edge - g.a1
            let reach = !marks.rects.isEmpty ? (repeats(g, last) ? 1.2 : 0.7) : (side == .end || paired(g) ? 0.75 : 0.35)
            if gap > glyph * reach { if repeats(g, last) && gap <= glyph * 1.6 { return Marks() }; break }
            guard marks.rects.count < (dotRun ? 24 : 3), qualifies(g), corridorClear(g, edge: edge),
                  !(g.members.count == 1 && g.c1 - g.c0 + 1 > glyph * 0.6 && gap > glyph * 0.12) else { return Marks() }
            marks.rects.append(rect(g)); last = g; edge = side == .end ? max(edge, g.a1) : min(edge, g.a0)
        }
        if !dotRun && outward.filter({ $0.a1 - $0.a0 + 1 <= glyph * 0.6 && $0.c1 - $0.c0 + 1 <= glyph * 0.6 }).count > 4 { return Marks() }
        if marks.rects.count >= 2 && (side == .end ? Double((vertical ? height : width) - 1) - edge : edge) < glyph * 1.3 { marks.open = true }
        return marks
    }

    static func adjacentDotRun(rgba: [UInt8], width: Int, height: Int, box: CGRect, glyph: Double,
                               palette: Palette, excluded: [CGRect] = []) -> [CGRect] {
        guard validColor(palette.foreground), glyph >= 8, width > 0, height > 0, width <= 262_144 / height,
              rgba.count == width * height * 4 else { return [] }
        var mask = [UInt8](repeating: 0, count: width * height)
        for index in mask.indices where rgba[index * 4 + 3] >= 254 && pixelDistance(rgba, index: index, color: palette.foreground) <= 40 { mask[index] = 1 }
        let possible = components(mask, width: width, height: height, diagonal: true).filter { c in
            c.left >= 3 && c.top >= 3 && c.right < width - 3 && c.bottom < height - 3 &&
                Double(c.width) >= glyph * 0.06 && Double(c.height) >= glyph * 0.06 && Double(c.width) <= glyph * 0.3 && Double(c.height) <= glyph * 0.3 &&
                Double(max(c.width, c.height)) <= Double(min(c.width, c.height)) * 1.6 && Double(c.pixels.count) >= Double(c.width * c.height) * 0.5 &&
                !excluded.contains { CGFloat(c.left) < $0.maxX + 2 && CGFloat(c.right) > $0.minX - 2 && CGFloat(c.top) < $0.maxY + 2 && CGFloat(c.bottom) > $0.minY - 2 }
        }
        guard possible.count <= 40 else { return [] }
        func cx(_ c: Component) -> Double { Double(c.left + c.right) / 2 }
        func cy(_ c: Component) -> Double { Double(c.top + c.bottom) / 2 }
        func size(_ c: Component) -> Double { sqrt(Double(c.width * c.height)) }
        var runs: [(center: Double, items: [Component])] = []
        for seed in possible {
            let x = cx(seed)
            if x >= Double(box.minX) - glyph * 0.1 && x <= Double(box.maxX) + glyph * 0.1 { continue }
            if x < Double(box.minX) - glyph || x > Double(box.maxX) + glyph { continue }
            let run = possible.filter { abs(cx($0) - x) <= glyph * 0.12 && size($0) >= size(seed) * 0.7 && size($0) <= size(seed) * 1.4 }.sorted { cy($0) < cy($1) }
            guard (5...24).contains(run.count), Double(run.last!.bottom - run[0].top) >= glyph * 1.2,
                  CGFloat(run[0].top) <= box.maxY, CGFloat(run.last!.bottom) >= box.minY else { continue }
            let gaps = (1..<run.count).map { cy(run[$0]) - cy(run[$0 - 1]) }, median = gaps.sorted()[gaps.count / 2]
            guard median >= size(seed) * 1.2, median <= size(seed) * 3, gaps.allSatisfy({ $0 >= median * 0.65 && $0 <= median * 1.4 }),
                  Double(run[0].top) >= median * 1.5, Double(height - 1 - run.last!.bottom) >= median * 1.5,
                  !runs.contains(where: { abs($0.center - x) < glyph * 0.25 }) else { continue }
            runs.append((x, run))
        }
        return runs.flatMap { $0.items.map { CGRect(x: $0.left - 2, y: $0.top - 2, width: $0.right - $0.left + 5, height: $0.bottom - $0.top + 5) } }
    }

    static func inferVerticalRuby(raw: [UInt8], rgba: [UInt8], width: Int, height: Int, box: CGRect, background: [Double]) -> [CGRect] {
        guard [box.minX, box.minY, box.width, box.height].allSatisfy(\.isFinite),
              box.height >= box.width * 2.5, box.width >= 12, validColor(background), (background.min() ?? 0) >= 220,
              width > 0, height > 0, width <= 750_000 / height, raw.count == width * height, rgba.count == raw.count * 4 else { return [] }
        let left = box.maxX - box.width * 0.15, right = min(CGFloat(width - 3), box.maxX + min(96, box.width * 0.8)), limit = box.width * 0.6
        struct Ruby { let c: Component; let solid: Bool }
        var candidates: [Ruby] = []
        let y0 = Int(max(3, min(CGFloat(height), floor(box.minY))))
        let y1 = Int(max(0, ceil(min(CGFloat(height - 3), box.maxY))))
        let x0 = Int(max(3, min(CGFloat(width), floor(left))))
        let x1 = Int(max(0, ceil(right)))
        guard y0 < y1, x0 < x1 else { return [] }
        let starts = (y0..<y1).flatMap { y in (x0..<x1).map { y * width + $0 } }
        for c in components(raw, width: width, height: height, diagonal: true, seeds: starts) {
            // The JS flood starts only from pixels in the right-hand probe strip. A component
            // wholly outside that strip must not become an inferred annotation.
            let startsInProbe = c.pixels.contains { index in
                let x = index % width, y = index / width
                return y >= y0 && CGFloat(y) < min(CGFloat(height - 3), box.maxY) &&
                    x >= x0 && CGFloat(x) < right
            }
            guard startsInProbe, c.pixels.count >= 3, CGFloat(c.left) >= left, CGFloat(c.right) <= right,
                  CGFloat(c.top) >= box.minY, CGFloat(c.bottom) <= box.maxY, c.left >= 3, c.top >= 3, c.right < width - 3, c.bottom < height - 3,
                  CGFloat(c.width) <= limit, CGFloat(c.height) <= limit else { continue }
            let solid = Double(c.pixels.count) > Double(c.width * c.height) * 0.85
            if solid && (CGFloat(max(c.width, c.height)) > box.width * 0.25 || max(c.width, c.height) > min(c.width, c.height) * 2) { continue }
            candidates.append(Ruby(c: c, solid: solid)); if candidates.count > 32 { return [] }
        }
        var result: [CGRect] = []
        for seed in candidates {
            let group = candidates.filter { abs(CGFloat($0.c.left + $0.c.right - seed.c.left - seed.c.right) / 2) <= box.width * 0.22 }
            let l = group.map { $0.c.left }.min()!, r = group.map { $0.c.right }.max()!
            guard CGFloat(r - l + 1) <= limit, group.filter({ !$0.solid }).count >= 2 else { continue }
            var rows: [(start: Int, end: Int)] = []
            for candidate in group.sorted(by: { $0.c.top < $1.c.top }) {
                if let previous = rows.last, CGFloat(candidate.c.top) <= CGFloat(previous.end) + box.width * 0.14 {
                    rows[rows.count - 1].end = max(previous.end, candidate.c.bottom)
                } else { rows.append((candidate.c.top, candidate.c.bottom)) }
            }
            guard (2...12).contains(rows.count), (1..<rows.count).allSatisfy({ CGFloat(rows[$0].start - rows[$0 - 1].end) <= box.width * 1.3 }) else { continue }
            let t = rows[0].start, d = rows.last!.end
            var clear = true
            for y in (t - 3)...(d + 3) where clear {
                for x in (l - 3)...(r + 3) {
                    if x > l - 3 && x < r + 3 && y > t - 3 && y < d + 3 { continue }
                    if pixelDistance(rgba, index: y * width + x, color: background) > 32 { clear = false; break }
                }
            }
            let corridor0 = Int(max(0, min(CGFloat(width), ceil(box.maxX + 3)))), corridor1 = l - 3
            if corridor0 < corridor1 {
                for y in t...d where clear {
                    for x in corridor0..<corridor1 where pixelDistance(rgba, index: y * width + x, color: background) > 32 { clear = false; break }
                }
            }
            guard clear else { continue }
            let rect = CGRect(x: l - 1, y: t - 1, width: r - l + 3, height: d - t + 3)
            if !result.contains(rect) { result.append(rect) }
        }
        return Array(result.prefix(4))
    }

    struct GridResult: Sendable {
        let rgba: [UInt8]
        let layoutSafe: [UInt8]
        let erased: Int
        let components: Int
        let rules: [Int]
        let readableRules: [UInt8]
        let paper: [Double]
    }

    /// Restore letters on manuscript/table rules without erasing the grid. Rule crossings use
    /// each band's independently measured ink and retain pieces owned by neighboring captions.
    static func ruledGridRestore(rgba: [UInt8], width: Int, height: Int, box: CGRect,
                                 vertical: Bool?, auxiliary: [CGRect] = [], excluded: [CGRect] = []) -> GridResult? {
        guard auxiliary.isEmpty, vertical != nil, width >= 16, height >= 16, width <= 262_144 / height,
              rgba.count == width * height * 4, [box.minX, box.minY, box.width, box.height].allSatisfy(\.isFinite) else { return nil }
        let n = width * height
        let l = Int(max(1, min(CGFloat(width), floor(box.minX)))), t = Int(max(1, min(CGFloat(height), floor(box.minY))))
        let r = Int(min(CGFloat(width - 1), max(0, ceil(box.maxX)))), bt = Int(min(CGFloat(height - 1), max(0, ceil(box.maxY))))
        let bw = r - l, bh = bt - t
        guard bw >= 24, bh >= 16 else { return nil }
        var counts = [Int](repeating: 0, count: 4_096), sums = [Double](repeating: 0, count: 4_096 * 3), samples = 0, opaque = true
        for y in stride(from: t, to: bt, by: 2) {
            for x in stride(from: l, to: r, by: 2) {
                let i = (y * width + x) * 4
                if rgba[i + 3] < 254 { opaque = false; continue }
                let key = Int(rgba[i] >> 4) * 256 + Int(rgba[i + 1] >> 4) * 16 + Int(rgba[i + 2] >> 4)
                counts[key] += 1; for c in 0..<3 { sums[key * 3 + c] += Double(rgba[i + c]) }; samples += 1
            }
        }
        guard opaque, samples > 0 else { return nil }
        var top = 0
        for index in 1..<4_096 where counts[index] > counts[top] { top = index }
        guard Double(counts[top]) >= Double(samples) * 0.3 else { return nil }
        let paper = (0..<3).map { sums[top * 3 + $0] / Double(counts[top]) }
        guard (paper.min() ?? 0) >= 150 else { return nil }
        func dist(_ index: Int, _ color: [Double]) -> Double { pixelDistance(rgba, index: index, color: color) }
        struct Band { var start: Int; var end: Int; var center: Double { Double(start + end) / 2 } }
        var ink: [UInt8]?
        func bands(_ horizontal: Bool) -> [Band] {
            let from = horizontal ? max(0, t - 4) : max(0, l - 4), to = horizontal ? min(height, bt + 4) : min(width, r + 4)
            let a0 = horizontal ? l : t, a1 = horizontal ? r : bt, span = a1 - a0
            var hit = [UInt8](repeating: 0, count: to), cover = [Double](repeating: 0, count: to)
            for k in from..<to {
                if ink == nil {
                    var found = 0
                    for j in 0..<16 {
                        let a = a0 + Int(floor((Double(j) + 0.5) * Double(span) / 16)), i = horizontal ? k * width + a : a * width + k
                        if dist(i, paper) > 24 { found += 1 }
                    }
                    if found < 12 { cover[k] = Double(found) / 16; continue }
                }
                var run = 0, best = 0, sum = 0
                for a in a0..<a1 {
                    let i = horizontal ? k * width + a : a * width + k
                    if ink.map({ $0[i] != 0 }) ?? (dist(i, paper) > 24) { run += 1; sum += 1; best = max(best, run) } else { run = 0 }
                }
                hit[k] = Double(best) >= Double(span) * 0.85 ? 1 : 0; cover[k] = Double(sum) / Double(span)
            }
            var raw: [Band] = [], k = from
            let limit = max(4, Int(floor(Double(min(bw, bh)) * 0.12 + 0.5)))
            while k < to {
                guard hit[k] != 0 else { k += 1; continue }
                var end = k
                while end + 1 < to && hit[end + 1] != 0 { end += 1 }
                if let last = raw.last, k - last.end <= 4 { raw[raw.count - 1].end = end } else { raw.append(Band(start: k, end: end)) }
                k = end + 1
            }
            return raw.filter { band in
                let before = band.start - 3 >= 0 ? cover[band.start - 3] : 0, after = band.end + 3 < to ? cover[band.end + 3] : 0
                return band.end - band.start + 1 <= limit && before < 0.5 && after < 0.5
            }
        }
        func pitch(_ list: [Band]) -> Double {
            guard list.count >= 2 else { return 0 }
            let gaps = (1..<list.count).map { list[$0].center - list[$0 - 1].center }.sorted()
            return gaps[gaps.count / 2]
        }
        var rows = bands(true)
        if rows.count >= 2 && Double(bw) < pitch(rows) { rows = [] }
        guard rows.count >= 2 else { return nil }
        let away = (0..<n).map { UInt8(clamping: Int(dist($0, paper))) }
        ink = (0..<n).map { dist($0, paper) > 24 ? 1 : 0 }
        var cols = bands(false)
        if cols.count >= 2 && Double(bh) < pitch(cols) { cols = [] }
        func even(_ list: [Band]) -> Bool {
            guard list.count >= 3 else { return true }
            let gaps = (1..<list.count).map { list[$0].center - list[$0 - 1].center }, middle = pitch(list)
            return middle >= 6 && Double(gaps.filter { abs($0 - middle) <= middle * 0.2 }.count) >= Double(gaps.count) * 0.75
        }
        func inside(_ list: [Band], _ a: Int, _ z: Int) -> Int {
            list.filter { $0.center > Double(a) + Double(z - a) * 0.12 && $0.center < Double(z) - Double(z - a) * 0.12 }.count
        }
        guard rows.count >= 2, cols.count >= 2, inside(rows, t, bt) + inside(cols, l, r) >= 2, even(rows), even(cols) else { return nil }
        var rule = [Int](repeating: -1, count: n), references: [[Double]] = []
        for (horizontal, list) in [(true, rows), (false, cols)] {
            for band in list {
                let a0 = horizontal ? l : t, a1 = horizontal ? r : bt
                for k in (band.start - 1)...(band.end + 1) {
                    guard k >= 0, k < (horizontal ? height : width) else { continue }
                    var histogram = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 3)
                    for a in a0..<a1 { let i = (horizontal ? k * width + a : a * width + k) * 4; for c in 0..<3 { histogram[c][Int(rgba[i + c])] += 1 } }
                    let ref = histogram.map { values -> Double in
                        var seen = 0, value = 0
                        while value < 255 { seen += values[value]; if seen > (a1 - a0) / 2 { break }; value += 1 }
                        return Double(value)
                    }
                    let id = references.count; references.append(ref)
                    if (k < band.start || k > band.end) && distance(ref, paper) < 24 { continue }
                    for a in 0..<(horizontal ? width : height) {
                        let i = horizontal ? k * width + a : a * width + k
                        if (a < a0 - 6 || a >= a1 + 6) && dist(i, ref) > 40 { continue }
                        rule[i] = id
                    }
                }
            }
        }
        let ruleInk = references.map { distance($0, paper) }, colored = references.enumerated().filter { ruleInk[$0.offset] >= 24 }.map(\.element)
        var ruleColor: [Double]? = colored.isEmpty ? nil : (0..<3).map { c in colored.map { $0[c] }.sorted()[colored.count / 2] }
        if (ruleColor?.max() ?? 255) < 120 { ruleColor = nil }
        var paint = [UInt8](repeating: 0, count: n), foreign = paint, labels = [Int](repeating: -1, count: n), sizes: [Int] = [], glyphLike: [Bool] = []
        let pitchH = Double(rows.last!.end + rows.last!.start - rows[0].start - rows[0].end) / 2 / Double(rows.count - 1)
        let pitchV = Double(cols.last!.end + cols.last!.start - cols[0].start - cols[0].end) / 2 / Double(cols.count - 1), cell = max(pitchH, pitchV) * 1.6
        let glyphMask = (0..<n).map { ink![$0] != 0 && rule[$0] < 0 ? UInt8(1) : 0 }
        var count = 0
        for c in components(glyphMask, width: width, height: height, diagonal: true) {
            let id = sizes.count; sizes.append(c.pixels.count)
            glyphLike.append(c.left > 0 && c.top > 0 && c.right < width - 1 && c.bottom < height - 1 && Double(c.pixels.count) <= cell * cell * 0.6)
            for i in c.pixels { labels[i] = id }
            let hits = c.pixels.filter { let x = $0 % width, y = $0 / width; return x >= l && x < r && y >= t && y < bt }.count
            if Double(hits) < max(4, Double(c.pixels.count) * 0.25) { if c.pixels.count >= 12 { for i in c.pixels { foreign[i] = 1 } }; continue }
            if c.left <= 0 || c.top <= 0 || c.right >= width - 1 || c.bottom >= height - 1 {
                if Double(hits) >= Double(c.pixels.count) * 0.8 { return nil }
                for i in c.pixels { foreign[i] = 1 }; continue
            }
            guard Double(c.width) <= cell, Double(c.height) <= cell,
                  !(Double(c.pixels.count) > Double(c.width * c.height) * 0.9 && Double(c.pixels.count) > cell * cell * 0.2) else { return nil }
            if let ruleColor, Double(c.pixels.count) <= cell * 4 {
                let mean = (0..<3).map { channel in c.pixels.reduce(0.0) { $0 + Double(rgba[$1 * 4 + channel]) } / Double(c.pixels.count) }
                if distance(mean, ruleColor) <= 40 { continue }
            }
            for i in c.pixels { paint[i] = 1 }; count += 1
        }
        guard count > 0 else { return nil }
        var redrawn = 0, ruleTotal = 0
        for i in 0..<n where rule[i] >= 0 {
            ruleTotal += 1
            let ref = references[rule[i]], darker = ref.reduce(0, +) - (0..<3).reduce(0.0) { $0 + Double(rgba[i * 4 + $1]) }
            if Double(away[i]) > ruleInk[rule[i]] + 24 && dist(i, ref) > max(40, ruleInk[rule[i]] * 0.5) || darker > 60 { paint[i] = 2; redrawn += 1 }
        }
        guard Double(redrawn) <= Double(ruleTotal) * 0.35 else { return nil }
        var state = [UInt8](repeating: 0, count: sizes.count)
        for i in 0..<n where labels[i] >= 0 && paint[i] == 1 { state[labels[i]] = 1 }
        var pairs: [Int: (Int, Int)] = [:]
        func facing(_ horizontal: Bool, _ band: Band, _ a: Int) {
            func at(_ k: Int) -> Int { horizontal ? k * width + a : a * width + k }
            let limit = horizontal ? height : width
            var before = -1, after = -1
            for k in stride(from: band.start - 2, through: max(0, band.start - 3), by: -1) where before < 0 { before = labels[at(k)] }
            if band.end + 2 <= min(limit - 1, band.end + 3) {
                for k in (band.end + 2)...min(limit - 1, band.end + 3) where after < 0 { after = labels[at(k)] }
            }
            if before >= 0 && after >= 0 && before != after { pairs[before * sizes.count + after] = (before, after) }
        }
        for band in rows { for a in 0..<width { facing(true, band, a) } }
        for band in cols { for a in 0..<height { facing(false, band, a) } }
        var drop: Set<Int> = [], take: Set<Int> = []
        for (x, y) in pairs.values where state[x] != state[y] && glyphLike[x] && glyphLike[y] {
            let inside = state[x] != 0 ? x : y, outside = state[x] != 0 ? y : x
            if sizes[outside] > sizes[inside] { drop.insert(inside) } else { take.insert(outside) }
        }
        for i in 0..<n where labels[i] >= 0 {
            let id = labels[i], x = CGFloat(i % width), y = CGFloat(i / width)
            if drop.contains(id) { paint[i] = 0; foreign[i] = 1 }
            else if take.contains(id) && !drop.contains(id) && !excluded.contains(where: { x >= $0.minX && x < $0.maxX && y >= $0.minY && y < $0.maxY }) { paint[i] = 1; foreign[i] = 0 }
        }
        func neighbors(_ i: Int) -> [Int] {
            let x = i % width, y = i / width
            return [x > 0 ? i - 1 : -1, x + 1 < width ? i + 1 : -1, y > 0 ? i - width : -1, y + 1 < height ? i + width : -1].filter { $0 >= 0 }
        }
        for _ in 0..<4 {
            let keep = (0..<n).filter { paint[$0] == 2 && neighbors($0).contains { foreign[$0] != 0 } }
            for i in keep { paint[i] = 0; foreign[i] = 1 }
        }
        for _ in 0..<2 {
            let fringe = (0..<n).filter { i in paint[i] == 0 && rule[i] < 0 && away[i] > 6 && neighbors(i).contains { paint[$0] == 1 } }
            for i in fringe { paint[i] = 1 }
        }
        let edge = (0..<n).filter { i in paint[i] == 0 && rule[i] >= 0 && neighbors(i).contains { paint[$0] != 0 } }
        for i in edge { paint[i] = 2 }
        for _ in 0..<2 {
            let edge = (0..<n).filter { i in paint[i] == 0 && rule[i] < 0 && foreign[i] == 0 && neighbors(i).contains { paint[$0] == 1 } }
            for i in edge { paint[i] = 1 }
        }
        var readable = [UInt8](repeating: 0, count: n), output = [UInt8](repeating: 0, count: n * 4), safe = readable, erased = 0
        for i in 0..<n {
            if rule[i] >= 0 && paint[i] != 1 {
                let ref = references[rule[i]]
                if 0.2126 * ref[0] + 0.7152 * ref[1] + 0.0722 * ref[2] >= 110 { readable[i] = 1 }
            }
            let x = i % width, y = i / width
            if x >= l - 1 && x <= r && y >= t - 1 && y <= bt && foreign[i] == 0 { safe[i] = 1 }
            guard paint[i] != 0 else { continue }
            let color = paint[i] == 2 ? references[rule[i]] : paper
            for c in 0..<3 { output[i * 4 + c] = UInt8(clamping: Int(color[c].rounded(.toNearestOrEven))) }
            output[i * 4 + 3] = 255; erased += 1; safe[i] = 1
        }
        guard erased >= 8, Double(erased) <= Double(bw * bh) * 0.6 else { return nil }
        return GridResult(rgba: output, layoutSafe: safe, erased: erased, components: count, rules: [rows.count, cols.count], readableRules: readable, paper: paper)
    }

    private static func validColor(_ color: [Double]) -> Bool { color.count >= 3 && color.allSatisfy(\.isFinite) }
    private static func distance(_ a: [Double], _ b: [Double]) -> Double { (0..<3).map { abs(a[$0] - b[$0]) }.max() ?? 0 }
    private static func pixelDistance(_ rgba: [UInt8], index: Int, color: [Double]) -> Double {
        (0..<3).map { abs(Double(rgba[index * 4 + $0]) - color[$0]) }.max() ?? 0
    }

    private static func components(_ mask: [UInt8], width: Int, height: Int, diagonal: Bool, seeds: [Int]? = nil) -> [Component] {
        var seen = [UInt8](repeating: 0, count: mask.count), output: [Component] = []
        for start in seeds ?? Array(mask.indices) where mask[start] != 0 && seen[start] == 0 {
            var queue = [start], head = 0, l = width, r = 0, t = height, d = 0
            seen[start] = 1
            while head < queue.count {
                let index = queue[head], x = index % width, y = index / width
                head += 1; l = min(l, x); r = max(r, x); t = min(t, y); d = max(d, y)
                let offsets = diagonal ? [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)] : [(-1, 0), (1, 0), (0, -1), (0, 1)]
                for (dx, dy) in offsets {
                    let xx = x + dx, yy = y + dy
                    guard xx >= 0, yy >= 0, xx < width, yy < height else { continue }
                    let neighbor = yy * width + xx
                    if mask[neighbor] != 0 && seen[neighbor] == 0 { seen[neighbor] = 1; queue.append(neighbor) }
                }
            }
            output.append(Component(pixels: queue, left: l, right: r, top: t, bottom: d))
        }
        return output
    }
}
