import CoreGraphics
import Foundation

/// Applies shared source-feature rules to measured foreground. Rules contain
/// normalized evidence classes, never image IDs, GT coordinates or read text.
@available(iOS 18.0, *)
enum NativeOCRSourceComponentBounds {
    typealias Measurement = NativeOCRSourceComponentMeasurements.Measurement
    struct Features {
        let owned: Int
        let normalRatio: CGFloat
        let alongRatio: CGFloat
        let angle: CGFloat
        let residual: CGFloat?
    }
    static let routingScheme = "angle"
    static let independentScheme = "confidence-angle"
    static let independentRules: [String: [Double]] = [
        "2|compact|narrow|short|fallback": [-1.0, 0.0, 0.0, 0.0, 0.0],
        "2|long|fit|fit|strong|straight": [0.0, 0.0, 1.0, 0.25, 1.0],
        "2|long|fit|fit|strong|tilted": [0.25, 1.0, 1.0, 0.75, 0.0],
        "2|long|fit|long|fallback": [-1.0, 0.0, 0.0, 0.0, 0.0],
        "2|long|fit|short|fallback": [-1.0, 0.0, 0.0, 0.0, 0.0],
        "2|long|narrow|fit|fallback": [-1.0, 0.0, 0.0, 0.0, 0.0],
        "2|long|narrow|short|fallback": [-1.0, 0.0, 0.0, 0.0, 0.0],
        "2|long|wide|fit|fallback": [0.5, 0.5, 1.0, 0.5, 0.0],
        "2|long|wide|short|fallback": [-1.0, 0.0, 0.0, 0.0, 0.0],
        "2|medium|fit|fit|fallback": [0.0, 1.0, 3.0, 0.25, 0.0],
        "2|medium|fit|short|fallback": [-1.0, 0.0, 0.0, 0.0, 0.0],
        "2|medium|narrow|fit|fallback": [-1.0, 0.0, 0.0, 0.0, 0.0],
        "2|medium|narrow|short|fallback": [-1.0, 0.0, 0.0, 0.0, 0.0],
        "2|medium|wide|fit|fallback": [-1.0, 0.0, 0.0, 0.0, 0.0],
        "identity": [-1.0, 0.0, 0.0, 0.0, 0.0],
    ]
    // Shared source-feature parameters selected offline; no GT is read at runtime.
    static let rules: [String: [Double]] = [
        "0|compact|fit|fit|straight": [-1.0, 0.0, 0.0, 0.0, 0.0],
        "0|compact|fit|long|fallback": [-1.0, 0.0, 0.0, 0.0, 0.0],
        "0|compact|fit|short|straight": [0.25, 0.0, 0.1, 0.5, 4.0],
        "0|compact|narrow|fit|straight": [0.0, 0.0, 0.1, 0.75, 3.0],
        "0|compact|narrow|long|fallback": [-1.0, 0.0, 0.0, 0.0, 0.0],
        "0|compact|narrow|short|straight": [0.25, 0.0, 0.1, 0.5, 2.0],
        "0|compact|wide|fit|straight": [0.0, 0.0, 1.0, 0.25, 1.0],
        "0|compact|wide|long|fallback": [-1.0, 0.0, 0.0, 0.0, 0.0],
        "0|compact|wide|short|straight": [-1.0, 0.0, 0.0, 0.0, 0.0],
        "0|long|fit|fit|straight": [0.5, 1.0, 1.0, 0.25, 2.0],
        "0|long|fit|fit|tilted": [0.5, 0.0, 1.0, 0.25, 2.0],
        "0|long|fit|short|fallback": [-1.0, 0.0, 0.0, 0.0, 0.0],
        "0|long|fit|short|straight": [0.0, 0.0, 3.0, 0.5, 4.0],
        "0|long|narrow|fit|fallback": [-1.0, 0.0, 0.0, 0.0, 0.0],
        "0|long|narrow|fit|straight": [0.25, 0.0, 1.0, 1.0, 4.0],
        "0|long|narrow|short|fallback": [-1.0, 0.0, 0.0, 0.0, 0.0],
        "0|long|wide|fit|fallback": [-1.0, 0.0, 0.0, 0.0, 0.0],
        "0|long|wide|fit|straight": [0.0, 0.0, 0.06, 0.25, 2.0],
        "0|long|wide|long|fallback": [-1.0, 0.0, 0.0, 0.0, 0.0],
        "0|long|wide|short|fallback": [-1.0, 0.0, 0.0, 0.0, 0.0],
        "0|medium|fit|fit|straight": [0.0, 1.0, 2.0, 0.5, 3.0],
        "0|medium|fit|fit|tilted": [0.25, 1.0, 0.06, 0.25, 2.0],
        "0|medium|fit|long|fallback": [-1.0, 0.0, 0.0, 0.0, 0.0],
        "0|medium|fit|short|straight": [0.0, 1.0, 0.1, 0.5, 2.0],
        "0|medium|fit|short|tilted": [0.25, 0.0, 1.0, 0.25, 0.0],
        "0|medium|narrow|fit|straight": [0.0, 1.0, 0.1, 0.75, 2.0],
        "0|medium|narrow|fit|tilted": [0.25, 0.5, 0.1, 0.25, 2.0],
        "0|medium|narrow|long|fallback": [-1.0, 0.0, 0.0, 0.0, 0.0],
        "0|medium|narrow|short|straight": [0.5, 1.0, 0.1, 0.75, 3.0],
        "0|medium|narrow|short|tilted": [0.25, 1.0, 0.1, 0.5, 2.0],
        "0|medium|wide|fit|straight": [-1.0, 0.0, 0.0, 0.0, 0.0],
        "0|medium|wide|fit|tilted": [0.5, 1.0, 1.0, 0.5, 4.0],
        "0|medium|wide|long|fallback": [-1.0, 0.0, 0.0, 0.0, 0.0],
        "0|medium|wide|short|straight": [0.0, 0.0, 1.0, 0.75, 4.0],
        "0|medium|wide|short|tilted": [0.0, 0.5, 0.06, 0.75, 0.0],
        "1|compact|fit|fit|fallback": [-1.0, 0.0, 0.0, 0.0, 0.0],
        "1|compact|narrow|fit|fallback": [-1.0, 0.0, 0.0, 0.0, 0.0],
        "1|long|fit|fit|fallback": [-1.0, 0.0, 0.0, 0.0, 0.0],
        "1|long|fit|fit|straight": [0.0, 1.0, 1.0, 0.5, 1.0],
        "1|long|fit|short|fallback": [-1.0, 0.0, 0.0, 0.0, 0.0],
        "1|long|narrow|fit|fallback": [-1.0, 0.0, 0.0, 0.0, 0.0],
        "1|long|wide|fit|fallback": [-1.0, 0.0, 0.0, 0.0, 0.0],
        "1|long|wide|fit|straight": [0.25, 0.0, 1.0, 0.75, 4.0],
        "1|long|wide|short|fallback": [-1.0, 0.0, 0.0, 0.0, 0.0],
        "1|medium|fit|fit|fallback": [-1.0, 0.0, 0.0, 0.0, 0.0],
        "1|medium|fit|short|fallback": [-1.0, 0.0, 0.0, 0.0, 0.0],
        "1|medium|narrow|fit|fallback": [-1.0, 0.0, 0.0, 0.0, 0.0],
        "1|medium|narrow|short|fallback": [-1.0, 0.0, 0.0, 0.0, 0.0],
        "1|medium|wide|fit|fallback": [-1.0, 0.0, 0.0, 0.0, 0.0],
        "1|medium|wide|short|fallback": [-1.0, 0.0, 0.0, 0.0, 0.0],
        "identity": [-1.0, 0.0, 0.0, 0.0, 0.0],
    ]

    static func refine(_ polygons: [[CGPoint]], indices: [Int], hasInk: [Bool],
                       baselines: [[CGPoint]?] = [], terminalProofs: [[CGPoint]?] = [], pointProofs: [[CGPoint]?] = [],
                       originals: [NativeCoreMLDetectionBox], prepared: [NativeCoreMLDetectionBox], groups: [Int: [Int]],
                       scopes: [NativeOCRSourceComponentMeasurements.Scope],
                       frameProvider: @escaping () -> NativeOCRRGBAFrame?,
                       accepts: (Int, [CGPoint]) -> Bool = { _, _ in true }) -> [[CGPoint]] {
        guard !(rules.isEmpty && independentRules.isEmpty), polygons.count == indices.count else { return polygons }
        let context = NativeOCRSourceComponentMeasurements.Context(originals: originals, prepared: prepared, groups: groups,
            scopes: scopes, frameProvider: frameProvider)
        return polygons.enumerated().map { offset, original in
            guard let metadata = context.metadata(index: indices[offset], polygon: original), couldUse(metadata),
                  let measured = context.measure(index: indices[offset], polygon: original,
                    hasInk: hasInk.indices.contains(offset) ? hasInk[offset] : false), measured.status == "measured",
                  let basic = proposal(measured, gap: 0, axis: 0, padding: 2) else { return original }
            let angled = proposal(measured, gap: 0, axis: 1, padding: 2)
            let selectedRules = measured.kind == "independent" ? independentRules : rules
            let scheme = measured.kind == "independent" ? independentScheme : routingScheme
            let key = classKey(measured, basic: basic.1, angled: angled?.1, scheme: scheme)
            let parent = key.split(separator: "|").prefix(4).joined(separator: "|") + "|fallback"
            guard let parameter = selectedRules[key] ?? selectedRules[parent], parameter.count == 5, parameter[0] >= 0,
                  let source = proposal(measured, gap: CGFloat(parameter[0]), axis: CGFloat(parameter[1]), padding: CGFloat(parameter[2])) else {
                return original
            }
            let operated = operate(original, proposal: source.0, action: Int(parameter[4]), frame: measured)
            let candidate = interpolate(original, proposal: operated, fraction: CGFloat(parameter[3]))
            let caps = protectedCaps(measured, baseline: baselines.indices.contains(offset) ? baselines[offset] : nil,
                terminal: terminalProofs.indices.contains(offset) ? terminalProofs[offset] : nil,
                point: pointProofs.indices.contains(offset) ? pointProofs[offset] : nil)
            guard accepts(indices[offset], candidate), candidate.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.x >= -1e-7 && $0.y >= -1e-7 }),
                  (measured.guardPoints + caps + visibleForeground(measured)).allSatisfy({ NativeOCRSourceComponentMeasurements.contains(candidate, $0, tolerance: 0.75) }) else {
                return original
            }
            return candidate
        }
    }
    /// Preserve already visible, same-palette text, including terminals without DB cells.
    /// Only closed components selected from source evidence participate; foreign owners do not.
    static func visibleForeground(_ m: Measurement) -> [CGPoint] {
        let primary = m.components.filter { c in
            let overlap = max(0, min(c.bounds.maxX, m.rect.maxX) - max(c.bounds.minX, m.rect.minX))
            return Double(c.ownedPixels) >= max(2, min(8, Double(c.pixels) * 0.04)) &&
                overlap >= min(c.bounds.width, m.rect.width) * 0.4 && c.insidePixels >= 2
        }
        guard !primary.isEmpty else { return [] }
        var result: [CGPoint] = []
        for c in m.components where c.foreignPixels == 0 && c.insidePixels >= 2 {
            let overlap = max(0, min(c.bounds.maxX, m.rect.maxX) - max(c.bounds.minX, m.rect.minX))
            guard overlap >= min(c.bounds.width, m.rect.width) * 0.4,
                  primary.contains(where: { NativeOCRSourceComponentMeasurements.colourDistance(c.colour, $0.colour) <= 40 }) else { continue }
            result += clip(c.hull.map(m.restore), to: m.polygon)
        }
        return result
    }
    static func clip(_ points: [CGPoint], to polygon: [CGPoint]) -> [CGPoint] {
        guard polygon.count == 4 else { return [] }
        func cross(_ a: CGPoint, _ b: CGPoint, _ p: CGPoint) -> CGFloat {
            (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
        }
        let area = polygon.indices.reduce(CGFloat(0)) { total, i in
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            return total + a.x * b.y - b.x * a.y
        }
        let sign: CGFloat = area >= 0 ? 1 : -1
        var output = points
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count], input = output
            output = []
            guard var previous = input.last else { return [] }
            var previousDistance = sign * cross(a, b, previous)
            for current in input {
                let distance = sign * cross(a, b, current)
                if (distance >= 0) != (previousDistance >= 0) {
                    let t = previousDistance / (previousDistance - distance)
                    output.append(.init(x: previous.x + t * (current.x - previous.x),
                                        y: previous.y + t * (current.y - previous.y)))
                }
                if distance >= 0 { output.append(current) }
                previous = current; previousDistance = distance
            }
        }
        return output
    }
    /// Only measured extensions beyond the detector baseline are protected;
    /// this does not freeze the baseline's empty crop padding.
    static func protectedCaps(_ m: Measurement, baseline: [CGPoint]?, terminal: [CGPoint]?, point: [CGPoint]?) -> [CGPoint] {
        guard let baseline, baseline.count == 4 else { return [] }
        let old = bounds(baseline.map(m.project))
        var result: [CGPoint] = []
        let polygon = m.polygon.map(m.project), x = m.rect.midX
        var crossings: [CGFloat] = []
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            if abs(b.x - a.x) < 1e-9 {
                if abs(a.x - x) < 1e-7 { crossings += [a.y, b.y] }
            } else if x >= min(a.x, b.x) && x <= max(a.x, b.x) {
                crossings.append(a.y + (x - a.x) * (b.y - a.y) / (b.x - a.x))
            }
        }
        let visibleMin = crossings.min() ?? m.rect.minY, visibleMax = crossings.max() ?? m.rect.maxY
        for proof in [terminal, point].compactMap({ $0 }) where proof.count == 4 {
            let observed = bounds(proof.map(m.project))
            if observed.minY < old.minY - 1 {
                result.append(m.restore(.init(x: m.rect.midX, y: max(visibleMin, observed.minY))))
            }
            if observed.maxY > old.maxY + 1 {
                result.append(m.restore(.init(x: m.rect.midX, y: min(visibleMax, observed.maxY))))
            }
        }
        return result
    }
    static func couldUse(_ m: Measurement) -> Bool {
        guard m.rect.width > 0 else { return false }
        let kind = m.kind == "group" ? "1" : m.kind == "independent" ? "2" : "0"
        let ratio = m.rect.height / m.rect.width, aspect = ratio < 3 ? "compact" : ratio < 8 ? "medium" : "long"
        let confidence = m.score < 0.8 ? "weak" : m.score < 0.9 ? "mid" : "strong"
        let selectedRules = m.kind == "independent" ? independentRules : rules
        let scheme = m.kind == "independent" ? independentScheme : routingScheme
        return selectedRules.contains { key, value in
            let parts = key.split(separator: "|").map(String.init)
            guard value.count == 5, value[0] >= 0, parts.count >= 4, parts[0] == kind, parts[1] == aspect else { return false }
            return !scheme.contains("confidence") || parts.last == "fallback" || (parts.count > 4 && parts[4] == confidence)
        }
    }
    static func classKey(_ m: Measurement, basic: Features, angled: Features?, scheme: String = routingScheme) -> String {
        let kind = m.kind == "group" ? "1" : m.kind == "independent" ? "2" : "0"
        let aspect = m.rect.height / m.rect.width
        var fields = [kind, aspect < 3 ? "compact" : aspect < 8 ? "medium" : "long",
            basic.normalRatio < 0.8 ? "narrow" : basic.normalRatio < 1.05 ? "fit" : "wide",
            basic.alongRatio < 0.85 ? "short" : basic.alongRatio < 1.05 ? "fit" : "long"]
        if scheme.contains("confidence") { fields.append(m.score < 0.8 ? "weak" : m.score < 0.9 ? "mid" : "strong") }
        if scheme.contains("angle") { fields.append(abs(angled?.angle ?? 0) > 1 ? "tilted" : "straight") }
        if scheme.contains("density") { fields.append(basic.owned < 6 ? "few" : "many") }
        return fields.joined(separator: "|")
    }

    static func proposal(_ m: Measurement, gap: CGFloat, axis: CGFloat, padding: CGFloat) -> ([CGPoint], Features)? {
        guard m.status == "measured" else { return nil }
        let width = m.rect.width, components = m.components
        var chosen: [Int] = []
        for i in components.indices {
            let c = components[i]
            let overlap = max(0, min(c.bounds.maxX, m.rect.maxX) - max(c.bounds.minX, m.rect.minX))
            if Double(c.ownedPixels) >= max(2, min(8, Double(c.pixels) * 0.04)),
               overlap >= min(c.bounds.width, width) * 0.4, c.insidePixels >= 2 { chosen.append(i) }
        }
        guard !chosen.isEmpty else { return nil }
        if gap > 0 {
            var changed = true
            while changed {
                changed = false
                let top = chosen.map { components[$0].bounds.minY }.min()!, bottom = chosen.map { components[$0].bounds.maxY }.max()!
                let normal = median(chosen.map { components[$0].center.x }), colours = chosen.map { components[$0].colour }
                for i in components.indices where !chosen.contains(i) {
                    let c = components[i], b = c.bounds
                    guard c.foreignPixels == 0, max(0, top - b.maxY, b.minY - bottom) <= width * gap,
                          abs(c.center.x - normal) <= width * 0.3,
                          b.minY >= m.rect.minY - width * 0.8, b.maxY <= m.rect.maxY + width * 0.8,
                          colours.contains(where: { NativeOCRSourceComponentMeasurements.colourDistance(c.colour, $0) <= 40 }) else { continue }
                    let world = m.restore(c.center), middle = m.restore(.init(x: m.rect.midX, y: m.rect.midY))
                    guard m.scopes.contains(where: { scope in
                        let r = scope.rect
                        return world.x >= r.minX && world.x <= r.maxX && world.y >= r.minY && world.y <= r.maxY &&
                            middle.x >= r.minX && middle.x <= r.maxX && middle.y >= r.minY && middle.y <= r.maxY
                    }) else { continue }
                    if b.minY < top || b.maxY > bottom { chosen.append(i); changed = true }
                }
            }
        }
        let ink = chosen.flatMap { components[$0].hull }
        guard !ink.isEmpty else { return nil }
        let inkBounds = bounds(ink)
        guard inkBounds.height >= max(width * 0.5, m.rect.height * 0.45) else { return nil }
        var beta: CGFloat = 0, residual: CGFloat?
        if axis > 0, m.rect.height >= width * 3, chosen.count >= 4 {
            var bins: [Int: (x: CGFloat, y: CGFloat, weight: CGFloat)] = [:]
            for i in chosen {
                let c = components[i], weight = min(CGFloat(c.pixels), pow(0.5 * width / m.step, 2))
                let key = Int(floor((c.center.y - m.rect.minY) / (width * 0.5)))
                let previous = bins[key] ?? (0, 0, 0)
                bins[key] = (previous.x + c.center.x * weight, previous.y + c.center.y * weight, previous.weight + weight)
            }
            let samples = bins.keys.sorted().compactMap { key -> (x: CGFloat, y: CGFloat, weight: CGFloat)? in
                guard let value = bins[key], value.weight > 0 else { return nil }
                return (value.x / value.weight, value.y / value.weight, sqrt(value.weight))
            }
            if samples.count >= 4, samples.map(\.y).max()! - samples.map(\.y).min()! > width * 2 {
                var weights = samples.map(\.weight), errors = [CGFloat](repeating: 0, count: samples.count), slope: CGFloat = 0
                for _ in 0..<3 {
                    let total = weights.reduce(0, +)
                    let mx = samples.indices.reduce(CGFloat(0)) { $0 + samples[$1].x * weights[$1] } / total
                    let my = samples.indices.reduce(CGFloat(0)) { $0 + samples[$1].y * weights[$1] } / total
                    let numerator = samples.indices.reduce(CGFloat(0)) { $0 + weights[$1] * (samples[$1].x - mx) * (samples[$1].y - my) }
                    let denominator = samples.indices.reduce(CGFloat(0)) { $0 + weights[$1] * pow(samples[$1].y - my, 2) }
                    slope = numerator / max(1e-9, denominator)
                    let intercept = mx - slope * my
                    for i in samples.indices {
                        errors[i] = samples[i].x - slope * samples[i].y - intercept
                        weights[i] = samples[i].weight * min(1, width * 0.2 / max(abs(errors[i]), 1e-6))
                    }
                }
                residual = median(errors.map(abs)) / width
                if abs(slope) <= tan(CGFloat.pi / 15), (residual ?? 1) < 0.2 { beta = atan(slope) * axis }
            }
        }
        let c = cos(beta), s = sin(beta)
        let projected = (ink + m.privateHull).map { CGPoint(x: $0.x * c - $0.y * s, y: $0.x * s + $0.y * c) }
        var rect = bounds(projected)
        let margin = max(0.5 * m.step, padding >= 1 ? padding : padding * width)
        rect = rect.insetBy(dx: -margin, dy: -margin)
        let quad = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                    CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)].map { point in
            m.restore(.init(x: point.x * c + point.y * s, y: -point.x * s + point.y * c))
        }
        guard quad.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.x >= -1e-7 && $0.y >= -1e-7 }) else { return nil }
        return (quad, .init(owned: chosen.filter { components[$0].ownedPixels > 0 }.count,
            normalRatio: inkBounds.width / width, alongRatio: inkBounds.height / m.rect.height,
            angle: beta * 180 / .pi, residual: residual))
    }
    static func operate(_ original: [CGPoint], proposal: [CGPoint], action: Int, frame: Measurement) -> [CGPoint] {
        if action == 0 { return interpolate(original, proposal: proposal, fraction: 1) }
        let old = original.map(frame.project), next = proposal.map(frame.project), a = bounds(old), b = bounds(next)
        var lo = CGPoint(x: b.minX, y: b.minY), hi = CGPoint(x: b.maxX, y: b.maxY)
        if action == 3 { hi.y = a.maxY }; if action == 4 { lo.y = a.minY }
        if action == 1 {
            guard hi.x > lo.x else { return original }
            return old.map { frame.restore(.init(x: ($0.x - a.minX) * (hi.x - lo.x) / max(1e-9, a.width) + lo.x, y: $0.y)) }
        }
        guard hi.y > lo.y else { return original }
        return old.map { frame.restore(.init(x: $0.x, y: ($0.y - a.minY) * (hi.y - lo.y) / max(1e-9, a.height) + lo.y)) }
    }
    static func interpolate(_ original: [CGPoint], proposal: [CGPoint], fraction: CGFloat) -> [CGPoint] {
        var aligned = proposal, distance = CGFloat.greatestFiniteMagnitude
        for reversed in [false, true] {
            let values = reversed ? Array(proposal.reversed()) : proposal
            for shift in 0..<4 {
                let option = (0..<4).map { values[($0 - shift + 4) % 4] }
                let score = (0..<4).reduce(CGFloat(0)) { $0 + pow(option[$1].x - original[$1].x, 2) + pow(option[$1].y - original[$1].y, 2) }
                if score < distance { aligned = option; distance = score }
            }
        }
        return (0..<4).map { .init(x: original[$0].x * (1 - fraction) + aligned[$0].x * fraction,
                                  y: original[$0].y * (1 - fraction) + aligned[$0].y * fraction) }
    }
    static func bounds(_ points: [CGPoint]) -> CGRect {
        CGRect(x: points.map(\.x).min()!, y: points.map(\.y).min()!,
               width: points.map(\.x).max()! - points.map(\.x).min()!, height: points.map(\.y).max()! - points.map(\.y).min()!)
    }
    static func median(_ values: [CGFloat]) -> CGFloat {
        let sorted = values.sorted(), n = sorted.count
        return n % 2 == 0 ? (sorted[n / 2 - 1] + sorted[n / 2]) / 2 : sorted[n / 2]
    }
}
