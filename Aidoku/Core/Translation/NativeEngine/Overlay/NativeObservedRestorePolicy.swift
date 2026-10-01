import CoreGraphics
import Foundation

/// Options travel with every retry. A retry changes only its named admission policy;
/// successful earlier masks retain their original pixel and donor visitation order.
struct NativeObservedRestoreOptions {
    enum ExcludedDonorPolicy { case strictBounds, observedSource }
    /// Broad OCR bounds protect writes; the adapter may separately request
    /// source-classified color donors. Explicit kernel inputs remain strict.
    var excludedDonorPolicy = ExcludedDonorPolicy.strictBounds
    var chromaticBalloon = false
    var vertical = false
    var slantedOwnership = false
    var auxiliary: [CGRect] = []
    var rowEndMarks: [CGRect] = []
    var inferredRubyExclusions: [CGRect] = []
    var excluded: [CGRect] = []
    var readabilityGate = true
    var sampleScale = 1.0
    var compactMask = false
    var protectArtMargin = false
    var preciseFringe = true
    var outlineFringe = true
    var faintBody = true
    var leadingRule = false
    var connectedGlyphRecovery = false
    var enclosedWordRecovery = false
    var shortGlyphRecovery = false
    var denseDonorSampling = false
    var segmentedSurfaceRecovery = false
    var flatPalette = false
    var secondaryInk: NativeRestorationRGB?
    var glyphOwnership: NativeObservedGlyphOwnership?
}

final class NativeObservedRestoreState {
    typealias Pixels = NativeRestorationPixels
    typealias RGB = NativeRestorationRGB
    let pixels: Pixels
    let box: CGRect
    let palette: Pixels.Palette
    let options: NativeObservedRestoreOptions
    let foreground: RGB
    let background: RGB
    let separation: Double
    let legacyDark: Bool
    let matchedInk: Bool
    let measuredHalo: Bool
    let radius: Int
    var auxiliary: [CGRect]
    var raw: [UInt8]
    var observedInk: [UInt8]
    var protectedInk: [UInt8]
    var mask: [UInt8]
    var frameInk: [UInt8]
    var seedRadius: [UInt8]
    var distance: [UInt8]
    var donorBlocked: [UInt8]
    var donorDistance: [UInt8]
    var sourceDonorBlocked: [UInt8]?
    var sourceDonorForbidden: [UInt8]?
    var drawingSurface: [UInt8]
    var queue: [Int] = []
    var queueTail = 0
    var accepted: [Pixels.Component] = []
    var acceptedObserved: [Int] = []
    var texturePoints: [Int] = []
    var textureComponents: [[Int]] = []
    var companions = 0
    var connectedOutlineRuns = 0
    var shortGlyphCandidate = false
    var faintBodyAdded = false
    var extendedHalo = false
    var hasPeriodicTexture = false
    var periodicInk = false
    var unresolved = 0
    var frameInterior = 0
    var innerArea = 0
    var coreCount = 0
    var sourceErasureVerified = false

    init?(_ p: Pixels, box: CGRect, palette: Pixels.Palette, options: NativeObservedRestoreOptions) {
        guard palette.verifiedForeground != nil, palette.verifiedBackground != nil, p.width >= 8, p.height >= 8, p.count <= 262_144, box.minX >= 2, box.minY >= 2,
              box.width > 0, box.height > 0, box.maxX <= CGFloat(p.width - 2), box.maxY <= CGFloat(p.height - 2),
              p.rgba.enumerated().allSatisfy({ $0.offset % 4 != 3 || $0.element >= 254 }) else { return nil }
        self.pixels = p; self.box = box; self.palette = palette; self.options = options
        foreground = palette.foreground; background = palette.background
        separation = foreground.distance(background)
        legacyDark = foreground.maximum <= 80 && background.minimum >= 140
        matchedInk = !legacyDark && separation >= 24 && palette.foregroundConfidence >= 0.55
        guard legacyDark || matchedInk else { return nil }
        let evidence = palette.widthEvidence
        let confidence = palette.metadata["confidence"] as? [String: Any]
        let method = evidence?["method"] as? String ?? ""
        let samplePixels = (evidence?["samplePixels"] as? NSNumber)?.doubleValue ?? .nan
        let scale = (evidence?["sampleScale"] as? NSNumber)?.doubleValue ?? .nan
        measuredHalo = options.readabilityGate && method.hasPrefix("outer stroke boundary") &&
            palette.strokeConfidence >= 0.6 && samplePixels.isFinite && scale.isFinite && scale > 0
        let whiteOutline = !options.slantedOwnership && legacyDark && (palette.stroke?.minimum ?? 0) >= 230 &&
            palette.strokeConfidence >= 0.6 && confidence?["reason"] as? String == "repeated dark glyph interiors enclosed by white source outlines"
        radius = measuredHalo ? max(4, min(12, Int(ceil(samplePixels / scale * options.sampleScale)) + 2)) :
            (options.compactMask && !whiteOutline ? (palette.stroke != nil ? 6 : 3) : 12)
        auxiliary = Array(options.auxiliary.prefix(32)).filter {
            $0.minX >= 2 && $0.minY >= 2 && $0.width > 0 && $0.height > 0 &&
                $0.maxX < CGFloat(p.width - 2) && $0.maxY < CGFloat(p.height - 2)
        }
        let zero = [UInt8](repeating: 0, count: p.count)
        guard let classes = Pixels.nativePixelClasses(p, palette: palette, tolerance: max(10, min(48, separation * 0.4)),
                                                     separation: separation, matched: matchedInk, secondaryInk: options.secondaryInk) else { return nil }
        raw = classes.raw; observedInk = classes.observed; protectedInk = classes.protected
        mask = zero; frameInk = zero; seedRadius = zero; distance = zero
        donorBlocked = zero; donorDistance = zero; drawingSurface = zero
    }

    func within(_ point: CGPoint, _ rect: CGRect, margin: CGFloat = 0) -> Bool {
        point.x >= rect.minX - margin && point.x <= rect.maxX + margin &&
            point.y >= rect.minY - margin && point.y <= rect.maxY + margin
    }

    func clearRing(_ rect: CGRect, margin: Int, inset: Int, tolerance: Double) -> (Int, Int) {
        let x0 = Int(rect.minX), y0 = Int(rect.minY), x1 = Int(rect.maxX - 1), y1 = Int(rect.maxY - 1)
        var samples = 0, clear = 0
        guard x0 - margin >= 0, y0 - margin >= 0, x1 + margin < pixels.width, y1 + margin < pixels.height else { return (0, 0) }
        for y in (y0 - margin)...(y1 + margin) {
            for x in (x0 - margin)...(x1 + margin) {
                if x > x0 - inset && x < x1 + inset && y > y0 - inset && y < y1 + inset { continue }
                samples += 1
                if pixels.color(y * pixels.width + x).distance(background) <= tolerance { clear += 1 }
            }
        }
        return (samples, clear)
    }

    /// Original faint-ink recruitment. Explicit ruby may have one-pixel seeds;
    /// body fragments need a quiet exposed ring and a component with no dark seed.
    func recruitFaintInk() {
        var regions = auxiliary.map { ($0, true) }
        if options.readabilityGate && options.faintBody && separation >= 60 { regions.append((box, false)) }
        for (rect, ruby) in regions {
            let x0 = Int(floor(rect.minX)), y0 = Int(floor(rect.minY)), x1 = Int(ceil(rect.maxX)), y1 = Int(ceil(rect.maxY))
            var samples = 0, clear = 0, rough = 0
            for y in (y0 - 2)...(y1 + 1) {
                let step = y == y0 - 2 || y == y1 + 1 ? 1 : max(1, x1 - x0 + 3)
                for x in stride(from: x0 - 2, through: x1 + 1, by: step) {
                    let i = y * pixels.width + x; samples += 1
                    if pixels.color(i).distance(background) <= 20 { clear += 1 }
                    if !ruby && x > 0 && y > 0 && x < pixels.width - 1 && y < pixels.height - 1 {
                        let neighbors = [i - 1, i + 1, i - pixels.width, i + pixels.width]
                        if (0..<3).contains(where: { c in
                            abs(Double(pixels.rgba[i * 4 + c]) - neighbors.reduce(0.0) { $0 + Double(pixels.rgba[$1 * 4 + c]) } / 4) > 6
                        }) { rough += 1 }
                    }
                }
            }
            guard samples >= (ruby ? 8 : 16), Double(clear) / Double(samples) >= (ruby ? 0.85 : 0.95),
                  ruby || Double(rough) / Double(samples) <= 0.2 else { continue }
            var soft = [UInt8](repeating: 0, count: pixels.count)
            for y in y0..<y1 { for x in x0..<x1 {
                let i = y * pixels.width + x, color = pixels.color(i)
                guard color.distance(background) >= max(ruby ? 24 : 16, separation * 0.08),
                      Pixels.blend(color, from: foreground, to: background) else { continue }
                if ruby { raw[i] = 1; soft[i] = 1 } else { soft[i] = 1 }
            } }
            if ruby {
                for i in 0..<pixels.count where soft[i] != 0 { observedInk[i] = 1 }
                continue
            }
            for part in pixels.components(soft) {
                let strong = part.points.contains { raw[$0] != 0 }
                var crosses = false
                for i in part.points {
                    let cx = i % pixels.width, cy = i / pixels.width
                    guard cx == x0 || cx == x1 - 1 || cy == y0 || cy == y1 - 1 else { continue }
                    for yy in (cy - 1)...(cy + 1) { for xx in (cx - 1)...(cx + 1) {
                        if xx >= x0 && xx < x1 && yy >= y0 && yy < y1 { continue }
                        let color = pixels.color(yy * pixels.width + xx)
                        if color.distance(background) >= max(16, separation * 0.08) &&
                            Pixels.blend(color, from: foreground, to: background) { crosses = true }
                    } }
                }
                let solid = part.rect.width >= 4 && part.rect.height >= 4 &&
                    Double(part.points.count) > part.rect.width * part.rect.height * 0.9
                if part.points.count >= 2 && !strong && !solid && !crosses {
                    for i in part.points { raw[i] = 1; observedInk[i] = 1; faintBodyAdded = true }
                }
            }
        }
    }

    func classifyComponents() -> Bool {
        var isolated: [Int] = [], fragments: [[Int]] = [], rules: [Pixels.Component] = [], readings: [(Pixels.Component, Bool)] = []
        let inset: CGFloat = options.slantedOwnership ? 0.000001 : 0
        for part in pixels.components(raw) {
            let x0 = part.rect.minX, y0 = part.rect.minY, x1 = part.rect.maxX - 1, y1 = part.rect.maxY - 1
            let tail = part.points.count, cx = (x0 + x1) / 2, cy = (y0 + y1) / 2
            if options.readabilityGate && tail <= 4 && texturePoints.count < 8192 {
                texturePoints.append(Int(cy) * pixels.width + Int(cx)); textureComponents.append(part.points)
            }
            let body = cx >= box.minX - 3 + inset && cx <= box.maxX + 3 - inset &&
                cy >= box.minY - 3 + inset && cy <= box.maxY + 3 - inset
            let ruby = auxiliary.contains { within(CGPoint(x: cx, y: cy), $0, margin: 2) }
            let rowEnd = !body && !ruby && options.rowEndMarks.contains {
                x0 >= $0.minX - 3 && x1 <= $0.maxX + 3 && y0 >= $0.minY - 3 && y1 <= $0.maxY + 3
            }
            var rule = false
            if options.leadingRule && palette.stroke != nil && cy < box.minY && x1 - x0 <= max(3, box.width * 0.12) &&
                y1 - y0 >= box.width * 0.75 && y1 - y0 <= min(120, box.width * 3) &&
                cx >= box.minX + box.width * 0.25 && cx <= box.minX + box.width * 0.75 &&
                y0 >= box.minY - min(120, box.width * 3) && y1 >= box.minY - 8 && y1 <= box.minY + box.width * 0.6 {
                var samples = 0, outlined = 0
                for y in stride(from: Int(y0) + 3, to: Int(y1) - 2, by: 1) { for x in [Int(x0) - 3, Int(x1) + 3] {
                    if x < 1 || x >= pixels.width - 1 { continue }
                    samples += 1; if pixels.color(y * pixels.width + x).minimum > 240 { outlined += 1 }
                } }
                rule = samples > 8 && Double(outlined) / Double(samples) > 0.9
            }
            let observed = matchedInk ? part.points.reduce(0) { $0 + Int(observedInk[$1]) } : tail
            let slantedWord = options.slantedOwnership && body && x0 >= box.minX && y0 >= box.minY &&
                x1 < box.maxX && y1 < box.maxY && x1 - x0 < box.width * 0.96 && y1 - y0 < box.height * 0.96 &&
                Double(tail) < part.rect.width * part.rect.height * 0.8
            let connected = options.connectedGlyphRecovery && options.readabilityGate && !options.slantedOwnership && options.vertical && body &&
                box.height >= box.width * 2.5 && y1 - y0 >= 100 && !part.touchesEdge && connectedOutlineRun(part)
            var enclosed = false
            if options.enclosedWordRecovery && body && !options.slantedOwnership && tail >= 12 &&
                x0 >= box.minX && y0 >= box.minY && x1 < box.maxX && y1 < box.maxY &&
                Double(tail) < part.rect.width * part.rect.height * 0.7 && min(part.rect.width, part.rect.height) >= 3 {
                let ring = clearRing(part.rect, margin: 3, inset: 2, tolerance: 18)
                enclosed = ring.0 >= 40 && Double(ring.1) >= Double(ring.0) * 0.98
            }
            var artLine = false
            if body && !ruby && !rule && !rowEnd && !options.slantedOwnership && tail >= 8 {
                let extent = max(part.rect.width, part.rect.height)
                if extent >= 12 && Double(tail) <= max(2.5, extent * 0.2) * extent {
                    var outside = 0, reach: CGFloat = 0
                    for i in part.points {
                        let x = CGFloat(i % pixels.width), y = CGFloat(i / pixels.width)
                        let d = max(box.minX - x, x - box.maxX, box.minY - y, y - box.maxY)
                        if d >= 2 { outside += 1; reach = max(reach, d) }
                    }
                    artLine = reach > max(4, min(box.width, box.height) * 0.15) &&
                        (Double(outside) >= Double(tail) * 0.6 || Double(outside) >= Double(tail) * 0.4 &&
                         extent >= max(16, max(box.width, box.height) * 0.35))
                }
            }
            let keep = !artLine && (!matchedInk || Double(observed) >= max(ruby || rowEnd ? 1 : 2, Double(tail) * 0.1)) &&
                (tail >= 2 || (ruby || rowEnd) && tail == 1) && !part.touchesEdge && (body || ruby || rule || rowEnd) &&
                (slantedWord || enclosed || connected || max(x1 - x0, y1 - y0) < (rule ? 121 : min(100, max(box.width, box.height) * 0.6)))
            if !keep && body && options.readabilityGate && options.vertical && !options.slantedOwnership &&
                Double(observed) >= Double(tail) * 0.9 && palette.stroke != nil && palette.strokeConfidence >= 0.6 &&
                foreground.maximum - foreground.minimum >= 40 && x0 >= box.minX && x1 < box.maxX && y0 >= box.minY && y1 < box.maxY &&
                x1 - x0 <= max(6, box.width * 0.045) && y1 - y0 >= max(100, (x1 - x0) * 10) && y1 - y0 <= box.height * 0.55 {
                var samples = 0, outlined = 0
                for yy in stride(from: Int(y0) + 3, to: Int(y1) - 2, by: 1) { for xx in [Int(x0) - 3, Int(x1) + 3] {
                    samples += 1
                    if pixels.color(yy * pixels.width + xx).distance(palette.stroke!) <= 24 { outlined += 1 }
                } }
                if samples > 20 && Double(outlined) >= Double(samples) * 0.9 { rules.append(part) }
            }
            if keep && connected { connectedOutlineRuns += 1 }
            if keep && !body && !rowEnd { companions += 1 }
            if !keep && body && tail == 1 && !part.touchesEdge { isolated.append(part.points[0]) }
            for i in part.points {
                if keep { mask[i] = 1; seedRadius[i] = UInt8((ruby || rowEnd) && !body ? min(6, radius) : radius) }
                else { protectedInk[i] = 1; if part.touchesEdge { frameInk[i] = 1 } }
            }
            if keep && !rowEnd { accepted.append(part); acceptedObserved.append(observed) }
            if !keep && options.vertical && fragments.count < 64 && tail <= 8 &&
                x0 >= box.maxX - 3 && x1 <= box.maxX + 8 && y0 >= box.minY && y1 <= box.maxY &&
                x1 - x0 <= 3 && y1 - y0 <= 7 && !part.touchesEdge { fragments.append(part.points) }
            if options.vertical && tail >= 2 && tail <= 256 && readings.count < 64 && !part.touchesEdge && auxiliary.contains(where: {
                $0.height >= $0.width * 2 && box.height >= box.width * 2 && $0.minX >= box.minX + box.width * 0.5 &&
                    x0 >= $0.minX - 2 && x1 <= $0.maxX + 2 && y0 > $0.maxY + 2 && y1 <= min(box.maxY, $0.maxY + min(72, box.width)) &&
                    x1 - x0 <= $0.width * 0.8 && y1 - y0 <= $0.width * 0.9
            }) { readings.append((part, keep)) }
        }
        for rule in rules {
            let cx = rule.rect.midX - 0.5
            guard accepted.contains(where: { $0.points.count >= 8 && cx >= $0.rect.minX && cx <= $0.rect.maxX - 1 &&
                (rule.rect.minY - ($0.rect.maxY - 1) >= 0 && rule.rect.minY - ($0.rect.maxY - 1) <= 24 ||
                 $0.rect.minY - (rule.rect.maxY - 1) >= 0 && $0.rect.minY - (rule.rect.maxY - 1) <= 24) }) else { continue }
            for i in rule.points { mask[i] = 1; protectedInk[i] = 0; seedRadius[i] = UInt8(radius) }
            accepted.append(rule); acceptedObserved.append(rule.points.count)
        }
        hasPeriodicTexture = options.readabilityGate && Pixels.periodicEvidence(pixels, points: texturePoints, box: box)
        let nearTexture = texturePoints.filter { i in accepted.contains {
            $0.points.count > 4 && within(CGPoint(x: i % pixels.width, y: i / pixels.width), CGRect(x: $0.rect.minX, y: $0.rect.minY, width: $0.rect.width - 1, height: $0.rect.height - 1), margin: 12)
        } }.count
        periodicInk = hasPeriodicTexture && nearTexture >= 32
        if periodicInk {
            for k in accepted.indices.reversed() where accepted[k].points.count <= 4 { accepted.remove(at: k); acceptedObserved.remove(at: k) }
            for points in textureComponents { for i in points { mask[i] = 0; protectedInk[i] = 0; seedRadius[i] = 0 } }
            for i in 0..<pixels.count where mask[i] != 0 { seedRadius[i] = 8 }
        }
        if accepted.count < (options.flatPalette ? 2 : 3) {
            var isolatedValid = options.readabilityGate && !hasPeriodicTexture && !accepted.isEmpty && companions == 0
            var bounds = CGRect.null, count = 0
            for part in accepted {
                if part.rect.minX < box.minX + 2 || part.rect.minY < box.minY + 2 || part.rect.maxX - 1 >= box.maxX - 2 ||
                    part.rect.maxY - 1 >= box.maxY - 2 || part.points.count < 8 || min(part.rect.width, part.rect.height) < 3 ||
                    Double(part.points.count) > part.rect.width * part.rect.height * 0.7 { isolatedValid = false }
                bounds = bounds.union(part.rect); count += part.points.count
            }
            if Double(count) < box.width * box.height * 0.025 || bounds.width - 1 < box.width * 0.25 || bounds.height - 1 < box.height * 0.25 {
                isolatedValid = false
            }
            if isolatedValid {
                let ring = clearRing(bounds, margin: 3, inset: 2, tolerance: 24)
                isolatedValid = ring.0 >= 32 && Double(ring.1) >= Double(ring.0) * 0.98
            }
            if !isolatedValid { return false }
            if !options.shortGlyphRecovery { shortGlyphCandidate = true; return false }
        }
        for rect in auxiliary {
            let candidates = readings.filter { part, _ in
                part.rect.minX >= rect.minX - 2 && part.rect.maxX - 1 <= rect.maxX + 2 && part.rect.minY > rect.maxY + 2 &&
                    part.rect.maxY - 1 <= min(box.maxY, rect.maxY + min(72, box.width))
            }
            guard candidates.contains(where: { !$0.1 }) else { continue }
            let bounds = candidates.reduce(CGRect.null) { $0.union($1.0.rect) }
            let points = candidates.flatMap { $0.0.points }
            guard points.count >= 6, Double(points.count) <= bounds.width * bounds.height * 0.75,
                  bounds.width - 1 <= rect.width * 0.8, bounds.height - 1 <= rect.width * 1.1 else { continue }
            let ring = clearRing(bounds, margin: 2, inset: 2, tolerance: 32)
            guard ring.0 == ring.1 else { continue }
            for i in points { mask[i] = 1; protectedInk[i] = 0; seedRadius[i] = 6 }
            companions += candidates.filter { !$0.1 }.count
        }
        let bodyFragments = (periodicInk ? [] : isolated).filter { i in
            pixels.indices(CGRect(x: i % pixels.width - 6, y: i / pixels.width - 6, width: 13, height: 13)).contains { mask[$0] != 0 }
        }
        for i in bodyFragments { mask[i] = 1; protectedInk[i] = 0; seedRadius[i] = 6 }
        let edgeFragments = fragments.filter { points in
            guard points.contains(where: { protectedInk[$0] != 0 }) else { return false }
            let own = Set(points); var owned = false, unsafe = false
            for i in points {
                let x = i % pixels.width, y = i / pixels.width
                for j in pixels.indices(CGRect(x: x - 3, y: y - 3, width: 7, height: 7)) {
                    if protectedInk[j] != 0 && !own.contains(j) { unsafe = true }
                    if mask[j] != 0 && max(abs(j % pixels.width - x), abs(j / pixels.width - y)) <= 2 { owned = true }
                }
            }
            return owned && !unsafe
        }
        for points in edgeFragments {
            for i in points { mask[i] = 1; protectedInk[i] = 0; seedRadius[i] = 2 }
            companions += 1
        }
        return !accepted.isEmpty
    }

    func connectedOutlineRun(_ part: Pixels.Component) -> Bool {
        let cross = min(box.width, part.rect.width * 1.25)
        guard part.rect.height >= cross * 1.6, part.rect.width <= cross * 1.1,
              part.rect.minX >= box.minX - 3, part.rect.maxX - 1 <= box.maxX + 3,
              part.rect.minY >= box.minY - 3, part.rect.maxY - 1 <= box.maxY + 3,
              Double(part.points.count) <= part.rect.width * part.rect.height * 0.72, palette.foregroundConfidence >= 0.6 else { return false }
        let localWidth = Int(part.rect.width) + 2, localHeight = Int(part.rect.height) + 2
        guard localWidth * localHeight <= 262_144 else { return false }
        let step = max(1, Int(ceil(Double(part.points.count) / 256)))
        let edgeColor = RGB((0..<3).map { c in
            let values = stride(from: 0, to: part.points.count, by: step).map { Double(pixels.rgba[part.points[$0] * 4 + c]) }.sorted()
            return values[values.count / 2]
        })
        let colors = [palette.verifiedForeground, palette.stroke, Pixels.rgb(palette.sourceInk?["foreground"]), Pixels.rgb(palette.sourceInk?["stroke"])].compactMap { $0 }
        guard colors.contains(where: { $0.distance(edgeColor) <= 32 }) else { return false }
        var local = Pixels(width: localWidth, height: localHeight), wall = [UInt8](repeating: 0, count: localWidth * localHeight)
        let x0 = Int(part.rect.minX), y0 = Int(part.rect.minY)
        for i in part.points { wall[(i / pixels.width - y0 + 1) * localWidth + i % pixels.width - x0 + 1] = 1 }
        local.rgba = [UInt8](repeating: 0, count: local.count * 4)
        var bands = Set<Int>(), holes = 0, minY = Double.infinity, maxY = -Double.infinity
        let open = wall.map { $0 == 0 ? UInt8(1) : 0 }
        for hole in local.components(open, diagonal: false) {
            let r = hole.rect
            guard r.minX > 0, r.minY > 0, r.maxX < CGFloat(localWidth), r.maxY < CGFloat(localHeight),
                  hole.points.count >= 6, r.width >= 3, r.height >= 3, r.width - 1 <= cross, r.height - 1 <= cross * 1.5 else { continue }
            let distinct = hole.points.filter { i in
                let index = (i / localWidth + y0 - 1) * pixels.width + i % localWidth + x0 - 1
                return pixels.color(index).distance(edgeColor) >= 48
            }.count
            guard Double(distinct) >= Double(hole.points.count) * 0.7 else { continue }
            let cy = Double(r.midY - 0.5); holes += 1; minY = min(minY, cy); maxY = max(maxY, cy)
            bands.insert(Int(floor(cy / Double(max(4, cross * 0.6)))))
        }
        return holes >= 2 && bands.count >= 2 && maxY - minY >= Double(part.rect.height) * 0.45
    }
}

extension NativeRestorationPixels {
    final class ObservedContext {
        var shortGlyphCandidate = false
        var denseDonorCandidate = false
    }

    static func exactObserved(_ p: Self, box: CGRect, palette: Palette, options: NativeObservedRestoreOptions,
                              context: ObservedContext = ObservedContext()) -> Self? {
        typealias H = NativeObservedRestorationHelpers
        if palette.verifiedForeground != nil && palette.verifiedBackground != nil && palette.foreground.minimum >= 175 && palette.background.maximum <= 115 && !options.auxiliary.isEmpty {
            var inverted = p
            for i in 0..<p.count { for c in 0..<3 { inverted.rgba[i * 4 + c] = 255 - p.rgba[i * 4 + c] } }
            var flipped = palette, flippedOptions = options
            flipped.foreground = NativeRestorationRGB(palette.foreground.channels.map { 255 - $0 })
            flipped.background = NativeRestorationRGB(palette.background.channels.map { 255 - $0 })
            flipped.stroke = palette.stroke.map { NativeRestorationRGB($0.channels.map { 255 - $0 }) }
            flippedOptions.secondaryInk = options.secondaryInk.map { NativeRestorationRGB($0.channels.map { 255 - $0 }) }
            guard var output = exactObserved(inverted, box: box, palette: flipped, options: flippedOptions, context: context) else { return nil }
            for i in 0..<p.count where output.rgba[i * 4 + 3] != 0 { for c in 0..<3 { output.rgba[i * 4 + c] = 255 - output.rgba[i * 4 + c] } }
            if let coefficients = output.surfaceQuality?["coefficients"] as? [[Double]] {
                output.surfaceQuality?["coefficients"] = coefficients.map { [255 - $0[0], -$0[1], -$0[2]] }
            }
            return output
        }
        guard let state = NativeObservedRestoreState(p, box: box, palette: palette, options: options) else { return nil }
        func retryPrevious() -> Self? {
            guard state.faintBodyAdded || state.extendedHalo else { return nil }
            var next = options; next.faintBody = false; next.outlineFringe = false
            guard next.faintBody != options.faintBody || next.outlineFringe != options.outlineFringe else { return nil }
            return exactObserved(p, box: box, palette: palette, options: next, context: context)
        }
        guard state.establishMask() else {
            if state.shortGlyphCandidate { context.shortGlyphCandidate = true }
            return retryPrevious()
        }
        var quality = options.readabilityGate ? surface(p, mask: state.mask, blocked: state.donorBlocked, dense: options.denseDonorSampling) : nil
        if options.readabilityGate && quality == nil && !options.denseDonorSampling && Int(ceil(sqrt(Double(p.count) / 4096))) > 1 &&
            surfaceDonorCount(p, mask: state.mask, blocked: state.donorBlocked) < 24 {
            context.denseDonorCandidate = true
        }
        if let current = quality, state.flatSurfaceFringe(current) {
            state.queueTail = H.maskQueue(state.mask, queue: &state.queue, n: p.count)
            quality = surface(p, mask: state.mask, blocked: state.donorBlocked, dense: options.denseDonorSampling)
        }
        if (state.periodicInk || quality.map { $0.safe && $0.rmse > 3 } == true) && state.frameInterior == 0 {
            if let repeated = periodicFill(p, mask: state.mask, blocked: state.donorBlocked,
                                           halftone: state.periodicInk, texturePoints: state.texturePoints) {
                var result = state.certified(repeated, quality: quality)
                result.surfaceQuality = result.surfaceQuality ?? [:]
                result.surfaceQuality?["reason"] = "periodic"
                result.surfaceQuality?["vectors"] = repeated.surfaceQuality?["vectors"]
                result.surfaceQuality?["repetitionError"] = repeated.surfaceQuality?["repetitionError"]
                return result
            }
        }
        guard !state.periodicInk else { return nil }
        if state.followHalo && quality?.safe == true && quality?.reason == "smooth" && state.frameInterior == 0 {
            let priorTail = state.queueTail
            let tail = H.followPlanarHalo(p.rgba, w: p.width, h: p.height, queue: &state.queue, tail: priorTail,
                mask: &state.mask, distance: &state.distance, seedRadius: &state.seedRadius, donorBlocked: state.donorBlocked,
                drawingSurface: state.drawingSurface, coefficients: quality!.coefficients, stroke: palette.stroke?.channels,
                preciseFringe: options.preciseFringe)
            state.queueTail = tail
            if tail > priorTail {
                state.extendedHalo = true
                quality = surface(p, mask: state.mask, blocked: state.donorBlocked, dense: options.denseDonorSampling)
            }
        }
        if let quality, options.preciseFringe && state.extendedHalo && quality.reason == "smooth" && quality.rmse > 8 && quality.outliers > 0.03 {
            var next = options; next.preciseFringe = false
            return exactObserved(p, box: box, palette: palette, options: next, context: context)
        }
        if let quality {
            let sparseDrawing = quality.reason == "smooth" && quality.samples < 96 && quality.rmse > 12 && quality.outliers > 0.04 &&
                Double(state.frameInterior) > max(8, Double(state.innerArea) * 0.005)
            let denseDrawing = quality.rmse > 4.5 && Double(state.frameInterior) > max(8, Double(state.innerArea) * 0.05)
            let isolatedSlanted = options.slantedOwnership && options.protectArtMargin && quality.reason == "smooth" &&
                quality.rmse <= 8 && quality.outliers <= 0.025
            if !isolatedSlanted && !options.segmentedSurfaceRecovery && (sparseDrawing || denseDrawing ||
                quality.rmse > 5 && Double(state.frameInterior) > max(8, Double(state.innerArea) * 0.02)) { return nil }
            if quality.safe, let stroke = palette.stroke, stroke.distance(palette.background) >= 20 {
                let center = NativeRestorationRGB(quality.coefficients.map {
                    $0[0] + $0[1] * Double(box.midX) / Double(p.width) + $0[2] * Double(box.midY) / Double(p.height)
                })
                if center.distance(stroke) <= 12 && center.distance(palette.background) >= 20 { return nil }
            }
        }
        if options.segmentedSurfaceRecovery && !(quality?.safe == true && quality!.rmse <= 3 && quality!.outliers <= 0) { return nil }
        let verifiedLocal = state.sourceErasureVerified && state.frameInterior == 0 && state.matchedInk &&
            palette.foreground.maximum - palette.foreground.minimum >= 40 && (quality?.localSamples ?? 0) >= 128 &&
            (quality?.localRMSE ?? .infinity) <= 2 && quality?.edgeFraction == 0
        if options.readabilityGate && (quality == nil || !quality!.safe || quality!.reason == "locally-smooth" && !options.compactMask && !verifiedLocal) {
            if !options.compactMask {
                var next = options; next.compactMask = true
                return exactObserved(p, box: box, palette: palette, options: next, context: context)
            }
            return retryPrevious()
        }
        var reconstruction = state.reconstructionDonors(quality)
        if let quality, quality.safe && quality.reason == "smooth" && quality.rmse > 3 && state.frameInterior == 0,
           let colorQuality = reconstruction.quality,
           let texture = exemplarFill(p, mask: state.mask, blocked: reconstruction.forbidden, palette: palette, surface: colorQuality) {
            var result = state.certified(texture, quality: colorQuality)
            result.surfaceQuality?["reason"] = "exemplar-texture"
            return result
        }
        if let current = quality, current.reason == "smooth" && current.safe && current.rmse <= 3 && current.outliers == 0 &&
            current.samples >= 64 && state.frameInterior == 0 {
            let priorTail = state.queueTail
            let margins = state.auxiliary.map { [Double($0.minX - 21), Double($0.minY - 21), Double($0.maxX + 21), Double($0.maxY + 21)] }
            let tail = H.expandPlanarRing(p.rgba, w: p.width, h: p.height, queue: &state.queue, priorTail: priorTail,
                mask: &state.mask, distance: &state.distance, seedRadius: &state.seedRadius, donorBlocked: state.donorBlocked,
                drawingSurface: state.drawingSurface, rubyMargins: margins, coefficients: current.coefficients,
                foreground: palette.foreground.channels, stroke: palette.stroke?.channels)
            if tail > priorTail {
                if let expanded = surface(p, mask: state.mask, blocked: state.donorBlocked, dense: options.denseDonorSampling),
                    expanded.safe && expanded.reason == "smooth" && expanded.rmse <= 3 && expanded.outliers == 0 && expanded.samples >= 64 {
                    quality = expanded
                    state.queueTail = tail
                    reconstruction = state.reconstructionDonors(quality)
                } else { for k in priorTail..<tail { state.mask[state.queue[k]] = 0 } }
            }
        }
        if let quality, (quality.rmse <= 3 || state.measuredHalo && quality.rmse <= 8 && quality.outliers <= 0.02 && state.frameInterior == 0) &&
            (!options.compactMask || quality.samples >= 64), let colorQuality = reconstruction.quality {
            return state.certified(planeFill(p, mask: state.mask, surface: colorQuality), quality: colorQuality)
        }
        if let result = state.diffuse(reconstruction.quality, colorDonors: reconstruction.blocked) { return result }
        if !options.protectArtMargin && state.mask.contains(1) {
            var next = options; next.protectArtMargin = true
            return exactObserved(p, box: box, palette: palette, options: next, context: context)
        }
        return retryPrevious()
    }
}
