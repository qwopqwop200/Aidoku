import CoreGraphics
import Foundation

/// Source color hypotheses use the same 4-bit bins, first-seen ordering and component evidence as the frozen renderer.
/// Dictionary descriptors retain all observer evidence; assigning a display role must not overwrite erasure evidence.
enum NativeSourceColorSampler {
    typealias Payload = [String: Any]

    static func estimate(rgba: [UInt8], width: Int, height: Int, preferredSurfaceKey: Int? = nil,
                         exteriorSurface: [Double]? = nil, inkSeed: [Double]? = nil,
                         minimumInkDistance: Double = 60, ownership: [UInt8]? = nil) -> Payload? {
        guard width >= 8, height >= 8, width <= 24_576 / height,
              rgba.count == width * height * 4, !Task.isCancelled,
              let observation = Observation(rgba: rgba, width: width, height: height) else { return nil }
        return Estimator(rgba: rgba, width: width, height: height, observation: observation, ownership: ownership)
            .run(surfaceKey: preferredSurfaceKey, exterior: exteriorSurface, seed: inkSeed, minimumDistance: minimumInkDistance)
    }

    static func displayedInk(_ result: Payload?) -> [Double]? {
        guard let result else { return nil }
        let display = observedDisplayInk(result)
        let ink = rgb(result["foreground"]) ?? rgb(result["displayForeground"])
        let backing = rgb(result["captionBackground"]) ?? rgb((result["surface"] as? Payload)?["color"]) ?? rgb(result["background"])
        let confidence = result["confidence"] as? Payload ?? [:]
        guard let display, let ink, let backing,
              rgb(result["stroke"]) == nil || number(confidence["stroke"]) < 0.55 else { return display }
        func contrast(_ color: [Double]) -> Double { luminanceContrast(luminance(color), luminance(backing), luminance(backing)) }
        func spread(_ color: [Double]) -> Double { (color.max() ?? 0) - (color.min() ?? 0) }
        if number(confidence["foreground"]) >= 0.6, rgb(result["foreground"]) != nil, spread(display) < 24,
           spread(ink) >= 40 || (ink.max() ?? 255) < 48, contrast(ink) >= 3, contrast(display) * 1.5 < contrast(ink) { return ink }
        let axis = subtract(backing, ink), length = dot(axis, axis)
        guard (axis.map(abs).max() ?? 0) >= 96, (ink.max() ?? 255) < 48 || (ink.min() ?? 0) > 207 else { return display }
        let factor = dot(subtract(display, ink), axis) / length
        guard factor >= 0.15, factor <= 1.05,
              zip(display, zip(ink, axis)).allSatisfy({ abs($0.0 - ($0.1.0 + factor * $0.1.1)) <= 20 }) else { return display }
        return contrast(display) < 4.5 && contrast(ink) >= 4.5 ? ink : display
    }

    static func observedDisplayInk(_ result: Payload?) -> [Double]? {
        guard let result else { return nil }
        if let value = rgb((result["displayEvidence"] as? Payload)?["color"]) { return value }
        if let value = rgb((result["lettering"] as? Payload)?["color"]) { return value }
        guard let foreground = rgb(result["foreground"]) else { return rgb(result["displayForeground"]) }
        let confidence = result["confidence"] as? Payload ?? [:]
        let background = rgb((result["surface"] as? Payload)?["color"]) ?? rgb(result["background"])
        if (foreground.min() ?? 0) >= 225, let stroke = rgb(result["stroke"]), number(confidence["stroke"]) >= 0.55,
           (stroke.max() ?? 0) - (stroke.min() ?? 0) >= 40, let background,
           luminanceContrast(luminance(stroke), luminance(background), luminance(background)) >
            luminanceContrast(luminance(foreground), luminance(background), luminance(background)) { return stroke }
        return foreground
    }

    static func rgb(_ value: Any?) -> [Double]? {
        guard let numbers = value as? [NSNumber], numbers.count == 3 else { return nil }
        let result = numbers.map(\.doubleValue)
        return result.allSatisfy { $0.isFinite && (0...255).contains($0) } ? result : nil
    }
    static func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }
    static func luminance(_ rgb: [Double]) -> Double {
        zip(rgb, [0.2126, 0.7152, 0.0722]).reduce(0) { value, pair in
            let source = pair.0 / 255
            return value + (source <= 0.04045 ? source / 12.92 : pow((source + 0.055) / 1.055, 2.4)) * pair.1
        }
    }
    static func luminanceContrast(_ text: Double, _ low: Double, _ high: Double) -> Double {
        if text >= low, text <= high { return 1 }
        return min((max(text, low) + 0.05) / (min(text, low) + 0.05), (max(text, high) + 0.05) / (min(text, high) + 0.05))
    }
    fileprivate static func subtract(_ lhs: [Double], _ rhs: [Double]) -> [Double] { zip(lhs, rhs).map(-) }
    fileprivate static func dot(_ lhs: [Double], _ rhs: [Double]) -> Double { zip(lhs, rhs).reduce(0) { $0 + $1.0 * $1.1 } }
    fileprivate static func distance(_ lhs: [Double], _ rhs: [Double]) -> Double { zip(lhs, rhs).map { abs($0 - $1) }.max() ?? 0 }
    fileprivate static func rounded(_ rgb: [Double]) -> [Double] { rgb.map { floor($0 + 0.5) } }

    fileprivate final class Bin {
        let key: Int
        let order: Int
        var count = 0
        var sums = [Double](repeating: 0, count: 3)
        var mean: [Double] { sums.map { $0 / Double(count) } }
        init(key: Int, order: Int) { self.key = key; self.order = order }
        func add(_ rgba: [UInt8], _ offset: Int) {
            count += 1
            for channel in 0..<3 { sums[channel] += Double(rgba[offset + channel]) }
        }
    }

    fileprivate final class Observation {
        var bins: [Bin] = []
        var byKey: [Int: Bin] = [:]
        var rim: [Int: Int] = [:]
        var rimOrder: [Int] = []
        var rimCount = 0
        init?(rgba: [UInt8], width: Int, height: Int) {
            #if canImport(AidokuOverlayKernels)
            do {
                let input = try NativeKernelBuffer<UInt8>(values: rgba), counts = try NativeKernelBuffer<Int32>(count: 4_096)
                let sums = try NativeKernelBuffer<Int32>(count: 12_288), order = try NativeKernelBuffer<Int32>(count: 4_096)
                let selected = try NativeTranslationPixelKernels.bins_inside(
                    rgba: input, w: Int32(width), h: Int32(height), left: 0, right: Double(width), top: 0, bottom: Double(height),
                    check_alpha: 1, counts: counts, sums: sums, order: order)
                guard selected >= 0 else { return nil }
                for index in 0..<Int(selected) {
                    let key = Int(order[index]), bin = Bin(key: key, order: index)
                    bin.count = Int(counts[key]); bin.sums = (0..<3).map { Double(sums[key * 3 + $0]) }
                    bins.append(bin); byKey[key] = bin
                }
            } catch { return nil }
            #endif
            for y in 0..<height {
                for x in 0..<width {
                    let p = (y * width + x) * 4
                    guard rgba[p + 3] >= 250 else { return nil }
                    let key = Int(rgba[p] >> 4) * 256 + Int(rgba[p + 1] >> 4) * 16 + Int(rgba[p + 2] >> 4)
                    #if !canImport(AidokuOverlayKernels)
                    if byKey[key] == nil { let bin = Bin(key: key, order: bins.count); bins.append(bin); byKey[key] = bin }
                    byKey[key]!.add(rgba, p)
                    #endif
                    if y < 2 || y >= height - 2 || x < 2 || x >= width - 2 {
                        if rim[key] == nil { rimOrder.append(key) }
                        rim[key, default: 0] += 1; rimCount += 1
                    }
                }
            }
        }
    }

    fileprivate struct Hole {
        let component: Int
        let count: Int
        let rgb: [Double]
        let foreign: Int
        let compactness: Double
        let interiorWidth: Int
        let interiorHeight: Int
        let glyphHeight: Int
        let band: Double
    }
    fileprivate struct Component {
        var points: [Int]
        var left: Int
        var top: Int
        var right: Int
        var bottom: Int
        var boundary: Bool
        var width: Int { right - left + 1 }
        var height: Int { bottom - top + 1 }
        var area: Int { width * height }
    }

    fileprivate final class Estimator {
        let rgba: [UInt8]
        let width: Int
        let height: Int
        let count: Int
        let observation: Observation
        let ownership: [UInt8]?
        init(rgba: [UInt8], width: Int, height: Int, observation: Observation, ownership: [UInt8]?) {
            self.rgba = rgba; self.width = width; self.height = height; count = width * height
            self.observation = observation; self.ownership = ownership?.count == width * height ? ownership : nil
        }
        func color(_ index: Int) -> [Double] { (0..<3).map { Double(rgba[index * 4 + $0]) } }
        func neighbors(_ index: Int) -> [Int] {
            let x = index % width, y = index / width
            var result: [Int] = []
            if x > 0 { result.append(index - 1) }; if x + 1 < width { result.append(index + 1) }
            if y > 0 { result.append(index - width) }; if y + 1 < height { result.append(index + width) }
            return result
        }
        func components(_ mask: [UInt8]) -> [Component] {
            var seen = [UInt8](repeating: 0, count: count), result: [Component] = []
            for start in 0..<count where mask[start] != 0 && seen[start] == 0 {
                var points = [start], read = 0, component = Component(points: [], left: width, top: height, right: 0, bottom: 0, boundary: false)
                seen[start] = 1
                while read < points.count {
                    let i = points[read], x = i % width, y = i / width; read += 1
                    component.left = min(component.left, x); component.right = max(component.right, x)
                    component.top = min(component.top, y); component.bottom = max(component.bottom, y)
                    if x == 0 || y == 0 || x == width - 1 || y == height - 1 { component.boundary = true }
                    for next in neighbors(i) where mask[next] != 0 && seen[next] == 0 { seen[next] = 1; points.append(next) }
                }
                component.points = points; result.append(component)
            }
            return result
        }
        func nearOwners(_ accepted: [Int], reach: Int) -> (near: [Int], owner: [Int]) {
            var near = [Int](repeating: 0, count: count), owners = near, queue: [Int] = []
            for i in 0..<count where accepted[i] != 0 { near[i] = 1; owners[i] = accepted[i]; queue.append(i) }
            var read = 0
            while read < queue.count {
                let i = queue[read]; read += 1
                if near[i] > reach { continue }
                for next in neighbors(i) where near[next] == 0 { near[next] = near[i] + 1; owners[next] = owners[i]; queue.append(next) }
            }
            return (near, owners)
        }

        func run(surfaceKey: Int?, exterior: [Double]?, seed: [Double]?, minimumDistance: Double) -> Payload? {
            if Task.isCancelled { return nil }
            let bins = observation.bins
            guard let key = surfaceKey ?? observation.rimOrder.max(by: {
                observation.rim[$0, default: 0] < observation.rim[$1, default: 0]
            }), let background = observation.byKey[key]?.mean else { return nil }
            func backgroundDistance(_ bin: Bin) -> Double { distance(bin.mean, background) }
            var solidCount = 0, solidRim = 0, candidateCount = 0
            var winner: Bin?
            for bin in bins {
                if backgroundDistance(bin) <= 12 { solidCount += bin.count; solidRim += observation.rim[bin.key, default: 0] }
                if backgroundDistance(bin) >= minimumDistance {
                    candidateCount += bin.count
                    if winner == nil || bin.count > winner!.count { winner = bin }
                }
            }
            let confidence: Payload = ["foreground": 0.0, "background": min(1, Double(solidRim) / Double(observation.rimCount)),
                                       "stroke": 0.0, "reason": "dominant observed rim; no validated glyph yet"]
            let colors: Payload = ["foreground": NSNull(), "background": rounded(background), "stroke": NSNull(),
                                   "outline": NSNull(), "widthEvidence": NSNull(), "confidence": confidence]
            var modes = bins
            if let ownership {
                var owned: [Int: Bin] = [:]; modes = []
                for i in 0..<count where ownership[i] != 0 {
                    let p = i * 4, key = Int(rgba[p] >> 4) * 256 + Int(rgba[p + 1] >> 4) * 16 + Int(rgba[p + 2] >> 4)
                    if owned[key] == nil { let bin = Bin(key: key, order: modes.count); owned[key] = bin; modes.append(bin) }
                    owned[key]!.add(rgba, p)
                }
                candidateCount = modes.filter { backgroundDistance($0) >= minimumDistance }.reduce(0) { $0 + $1.count }
            }
            func resolve(_ original: Payload) -> Payload {
                if seed != nil { return original }
                if rgb(original["foreground"]) == nil, Double(solidCount) >= Double(count) * 0.5,
                   Double(solidRim) >= Double(observation.rimCount) * 0.5 {
                    let stable = Double(solidRim) >= Double(observation.rimCount) * 0.75 && Double(solidCount) >= Double(count) * 0.5
                    let choices = modes.filter { Double($0.count) >= max(3, Double(count) * 0.0005) && backgroundDistance($0) >= (stable ? 24 : 60) }
                        .sorted { $0.count != $1.count ? $0.count > $1.count : $0.order < $1.order }.prefix(32)
                    var seeds: [[Double]] = []
                    for mode in choices {
                        var selected = mode.mean
                        let vector = subtract(selected, background), squared = dot(vector, vector)
                        for bin in choices {
                            let candidate = bin.mean, delta = subtract(candidate, background), factor = dot(delta, vector) / squared
                            if factor >= 1, Double(bin.count) >= max(3, Double(mode.count) * 0.05),
                               zip(delta, vector).map({ abs($0 - factor * $1) }).max() ?? 0 <= 12,
                               distance(candidate, background) > distance(selected, background) { selected = candidate }
                        }
                        if seeds.contains(where: { distance($0, selected) < 24 }) { continue }
                        seeds.append(selected)
                        if var candidate = run(surfaceKey: surfaceKey, exterior: exterior, seed: selected,
                                               minimumDistance: distance(selected, background) < 60 ? 24 : 60),
                           rgb(candidate["foreground"]) != nil,
                           number((candidate["confidence"] as? Payload)?["foreground"]) >= 0.6,
                           rgb(candidate["background"]) == nil || distance(rgb(candidate["background"])!, background) <= 32 {
                            var evidence = candidate["confidence"] as? Payload ?? [:]
                            evidence["reason"] = "independent observed ink mode; " + (evidence["reason"] as? String ?? "")
                            candidate["confidence"] = evidence; return candidate
                        }
                        if seeds.count >= 4 { break }
                    }
                }
                if surfaceKey != nil || rgb(original["foreground"]) != nil { return original }
                guard let dominant = bins.filter({ backgroundDistance($0) >= 60 }).max(by: {
                    $0.count != $1.count ? $0.count < $1.count : $0.order > $1.order
                }), var competing = run(surfaceKey: dominant.key, exterior: background, seed: nil, minimumDistance: 60),
                      rgb(competing["foreground"]) != nil else { return original }
                if let surface = rgb(competing["background"]), distance(surface, dominant.mean) > 32 { return original }
                var evidence = competing["confidence"] as? Payload ?? [:]
                evidence["reason"] = "competing interior surface with validated ink; " + (evidence["reason"] as? String ?? "")
                competing["confidence"] = evidence; return competing
            }
            guard winner != nil, Double(candidateCount) >= max(6, Double(count) * 0.004) else { return resolve(colors) }
            let inkBins = modes.filter { backgroundDistance($0) >= minimumDistance }.sorted {
                backgroundDistance($0) != backgroundDistance($1) ? backgroundDistance($0) > backgroundDistance($1) : $0.order < $1.order
            }
            let target = max(6, Double(candidateCount) * 0.12)
            var tailCount = 0.0, tailSum = [Double](repeating: 0, count: 3)
            for bin in inkBins {
                let take = min(Double(bin.count), target - tailCount)
                for channel in 0..<3 { tailSum[channel] += bin.mean[channel] * take }
                tailCount += take; if tailCount >= target { break }
            }
            let seedColor = seed ?? tailSum.map { $0 / tailCount }, direction = subtract(seedColor, background)
            let squared = dot(direction, direction)
            var mask = [UInt8](repeating: 0, count: count), core = mask, selected = 0, aligned = 0
            for i in 0..<count {
                let value = color(i), delta = subtract(value, background), factor = dot(delta, direction) / squared
                if delta.map(abs).max() ?? 0 < minimumDistance || factor < 0.15 || factor > 1.2 ||
                    zip(delta, direction).map({ abs($0 - factor * $1) }).max() ?? 0 > 24 { continue }
                mask[i] = 1; aligned += 1
                if distance(value, seedColor) <= 24 { core[i] = 1; selected += 1 }
            }
            guard selected >= 3 else { return resolve(colors) }
            var accepted = [Int](repeating: 0, count: count), closed = [UInt8](repeating: 0, count: count)
            var glyphHeights: [Int] = [], holes: [Hole] = [], fillBudget = count
            var sum = [Double](repeating: 0, count: 3), coreCount = 0, retained = 0, componentCount = 0
            func addCore(_ i: Int) {
                // This intentionally uses scan-array neighbors, as the oracle does after border components are excluded.
                let neighbors = [i - 1, i + 1, i - width, i + width].reduce(0) { $0 + ($1 >= 0 && $1 < count ? Int(mask[$1]) : 0) }
                if core[i] == 0 || neighbors < 3 { return }
                for channel in 0..<3 { sum[channel] += Double(rgba[i * 4 + channel]) }; coreCount += 1
            }
            for component in components(mask) {
                if component.boundary { continue }
                if let ownership, Double(component.points.filter { ownership[$0] != 0 }.count) < Double(component.points.count) * 0.6 { continue }
                let tail = component.points.count
                if tail < 3 || Double(component.width) > Double(width) * 0.9 || Double(component.height) > Double(height) * 0.9 ||
                    minimumDistance < 60 && max(component.width, component.height) < 5 ||
                    (tail > 12 || minimumDistance < 60) && Double(tail) / Double(component.area) > 0.9 { continue }
                componentCount += 1; retained += tail; glyphHeights.append(component.height)
                for i in component.points { accepted[i] = componentCount }
                if component.area <= fillBudget, component.width >= 3, component.height >= 3 {
                    fillBudget -= component.area
                    var owned = [UInt8](repeating: 0, count: component.area)
                    for i in component.points { owned[(i / width - component.top) * component.width + i % width - component.left] = 1 }
                    var visited = owned.map { _ in UInt8(0) }
                    for start in 0..<component.area where visited[start] == 0 && owned[start] == 0 {
                        var flood = [start], read = 0, open = false; visited[start] = 1
                        while read < flood.count {
                            let i = flood[read], x = i % component.width, y = i / component.width; read += 1
                            if x == 0 || y == 0 || x == component.width - 1 || y == component.height - 1 { open = true }
                            var next: [Int] = []
                            if x > 0 { next.append(i - 1) }; if x + 1 < component.width { next.append(i + 1) }
                            if y > 0 { next.append(i - component.width) }; if y + 1 < component.height { next.append(i + component.width) }
                            for j in next where visited[j] == 0 && owned[j] == 0 { visited[j] = 1; flood.append(j) }
                        }
                        if open { continue }
                        var localBins: [Int: Bin] = [:], localOrder: [Bin] = [], sampled = 0, foreign = 0
                        var left = component.width, top = component.height, right = 0, bottom = 0
                        for point in flood {
                            let x = point % component.width, y = point / component.width
                            let global = (y + component.top) * width + x + component.left
                            if mask[global] != 0 { foreign += 1; continue }
                            let p = global * 4, key = Int(rgba[p] >> 4) * 256 + Int(rgba[p + 1] >> 4) * 16 + Int(rgba[p + 2] >> 4)
                            if localBins[key] == nil { let bin = Bin(key: key, order: localOrder.count); localBins[key] = bin; localOrder.append(bin) }
                            localBins[key]!.add(rgba, p); sampled += 1
                            left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
                        }
                        if sampled >= 2, let mode = localOrder.max(by: { $0.count != $1.count ? $0.count < $1.count : $0.order > $1.order }) {
                            for point in flood {
                                let global = (point / component.width + component.top) * width + point % component.width + component.left
                                if mask[global] == 0 { closed[global] = 1 }
                            }
                            holes.append(Hole(component: component.points[0], count: sampled, rgb: mode.mean, foreign: foreign,
                                compactness: Double(sampled) / Double(max(1, (right - left + 1) * (bottom - top + 1))),
                                interiorWidth: right - left + 1, interiorHeight: bottom - top + 1, glyphHeight: component.height,
                                band: Double(tail) / Double(2 * (component.width + component.height))))
                        }
                    }
                }
                for i in component.points { addCore(i) }
            }
            // Continue with connected-surface, halo, and independent enclosing-fill roles using these exact observations.
            return finish(colors: colors, confidence: confidence, background: background, bins: bins,
                          surfaceKey: surfaceKey, exterior: exterior, resolve: resolve, mask: mask, core: core,
                          accepted: accepted, closed: closed, heights: glyphHeights, holes: holes,
                          sum: sum, coreCount: coreCount, retained: retained, aligned: aligned,
                          componentCount: componentCount, direction: direction, squared: squared,
                          solidCount: solidCount, solidRim: solidRim)
        }

        func finish(colors: Payload, confidence: Payload, background: [Double], bins: [Bin], surfaceKey: Int?, exterior: [Double]?,
                    resolve: (Payload) -> Payload, mask: [UInt8], core: [UInt8], accepted: [Int], closed: [UInt8],
                    heights: [Int], holes: [Hole], sum: [Double], coreCount: Int, retained: Int, aligned: Int,
                    componentCount: Int, direction: [Double], squared: Double, solidCount: Int, solidRim: Int) -> Payload {
            var colors = colors, confidence = confidence, accepted = accepted, heights = heights
            var sum = sum, coreCount = coreCount, retained = retained, aligned = aligned, componentCount = componentCount
            func coreNeighbors(_ i: Int) -> Int {
                [i - 1, i + 1, i - width, i + width].reduce(0) { $0 + ($1 >= 0 && $1 < count ? Int(mask[$1]) : 0) }
            }
            func evidence(_ band: Double, _ glyph: Double, _ method: String) -> Payload {
                ["samplePixels": band, "relativeToGlyph": band / glyph, "glyphPixels": glyph, "method": method]
            }
            func recoverHalo() -> Payload {
                guard surfaceKey != nil, let exterior, componentCount >= 2, coreCount >= 3 else { return colors }
                let sorted = heights.sorted(), glyph = Double(sorted[Int(floor(Double(sorted.count - 1) * 0.75))])
                let reach = min(24, max(6, Int(ceil(glyph * 0.8)))), nearest = nearOwners(accepted, reach: reach)
                var bands: [Double] = [], owners: Set<Int> = [], strokePixels = 0
                let selected = (0..<count).map { accepted[$0] == 0 && closed[$0] == 0 && distance(color($0), background) <= 24 ? UInt8(1) : 0 }
                for component in components(selected) {
                    var outer: [Int] = [], localOwners: Set<Int> = []
                    for i in component.points {
                        if nearest.owner[i] != 0 { localOwners.insert(nearest.owner[i]) }
                        if neighbors(i).contains(where: { selected[$0] == 0 && accepted[$0] == 0 && distance(color($0), exterior) <= 32 }) {
                            outer.append(nearest.near[i] != 0 ? nearest.near[i] - 1 : reach + 1)
                        }
                    }
                    guard outer.count >= 4, component.points.count >= 6 else { continue }
                    outer.sort(); let median = outer[outer.count / 2], p90 = outer[Int(floor(Double(outer.count - 1) * 0.9))]
                    if Double(median) > max(2, ceil(glyph * 0.3)) || Double(p90) > max(3, ceil(glyph * 0.45)) { continue }
                    strokePixels += component.points.count; bands.append(max(0.5, Double(median) - 0.5)); owners.formUnion(localOwners)
                }
                guard strokePixels >= 6, owners.count >= 2 else { return colors }
                var inkSum = [Double](repeating: 0, count: 3), inkPixels = 0
                for i in 0..<count where core[i] != 0 && owners.contains(accepted[i]) && coreNeighbors(i) >= 3 {
                    for channel in 0..<3 { inkSum[channel] += Double(rgba[i * 4 + channel]) }; inkPixels += 1
                }
                guard inkPixels >= 3 else { return colors }
                let observed = inkSum.map { $0 / Double(inkPixels) }
                guard distance(observed, exterior) > 12 else { return colors }
                bands.sort(); let band = bands[bands.count / 2], stroke = rounded(background)
                return ["foreground": rounded(observed), "background": NSNull(), "stroke": stroke, "outline": stroke,
                    "widthEvidence": evidence(band, glyph, "alternative observed ink with glyph-following halo; exterior surface unverified"),
                    "confidence": ["foreground": min(0.9, 0.5 + Double(owners.count) * 0.08), "background": 0.0,
                        "stroke": min(0.9, 0.5 + Double(owners.count) * 0.08),
                        "reason": "observed glyph fill and following halo; no validated flat exterior surface"]]
            }
            var broadlySupported = false
            if surfaceKey != nil {
                let surfacePixels = bins.filter { distance($0.mean, background) <= 24 }.reduce(0) { $0 + $1.count }
                broadlySupported = surfacePixels > count / 2 && Double(retained) >= Double(aligned) * 0.35 && coreCount >= 3
            }
            if surfaceKey != nil, !broadlySupported {
                guard componentCount >= 2 else { return recoverHalo() }
                let surfaceMask = (0..<count).map { distance(color($0), background) <= 32 ? UInt8(1) : 0 }
                let regions = components(surfaceMask)
                var labels = [Int](repeating: 0, count: count)
                for (offset, region) in regions.enumerated() { for i in region.points { labels[i] = offset + 1 } }
                var owners = (0...componentCount).map { _ in Component(points: [], left: width, top: height, right: 0, bottom: 0, boundary: false) }
                for i in 0..<count where accepted[i] != 0 {
                    let id = accepted[i], x = i % width, y = i / width
                    owners[id].points.append(i); owners[id].left = min(owners[id].left, x); owners[id].right = max(owners[id].right, x)
                    owners[id].top = min(owners[id].top, y); owners[id].bottom = max(owners[id].bottom, y)
                }
                var surfaceOwners = (0...regions.count).map { _ in [Int]() }, surfaceInk = [Int](repeating: 0, count: regions.count + 1)
                for id in 1..<owners.count where owners[id].points.count >= 6 {
                    var counts = [Int](repeating: 0, count: regions.count + 1), order: [Int] = []
                    for i in owners[id].points {
                        let x = i % width, y = i / width
                        for yy in max(0, y - 2)...min(height - 1, y + 2) {
                            for xx in max(0, x - 2)...min(width - 1, x + 2) {
                                let label = labels[yy * width + xx]
                                if label != 0 { if counts[label] == 0 { order.append(label) }; counts[label] += 1 }
                            }
                        }
                    }
                    var bestLabel = 0, bestCount = 0
                    for label in order where counts[label] > bestCount { bestLabel = label; bestCount = counts[label] }
                    if bestLabel != 0 { surfaceOwners[bestLabel].append(id); surfaceInk[bestLabel] += owners[id].points.count }
                }
                var best: (label: Int, ink: Int, localAligned: Int, bounds: Component)?
                for label in 1..<surfaceOwners.count where surfaceOwners[label].count >= 2 {
                    var bounds = Component(points: [], left: width, top: height, right: 0, bottom: 0, boundary: false)
                    for id in surfaceOwners[label] {
                        bounds.left = min(bounds.left, owners[id].left); bounds.right = max(bounds.right, owners[id].right)
                        bounds.top = min(bounds.top, owners[id].top); bounds.bottom = max(bounds.bottom, owners[id].bottom)
                    }
                    var supported = 0, localAligned = 0
                    for y in bounds.top...bounds.bottom { for x in bounds.left...bounds.right {
                        let i = y * width + x
                        if labels[i] == label { supported += 1 }; if mask[i] != 0 { localAligned += 1 }
                    } }
                    if Double(supported) <= Double(bounds.area) / 2 || Double(surfaceInk[label]) < Double(localAligned) * 0.35 { continue }
                    if best == nil || surfaceInk[label] > best!.ink { best = (label, surfaceInk[label], localAligned, bounds) }
                }
                guard let best else { return recoverHalo() }
                var extended = 0
                for i in 0..<count where labels[i] == best.label {
                    let x = i % width, y = i / width
                    if x < best.bounds.left - 2 || x > best.bounds.right + 2 || y < best.bounds.top - 2 || y > best.bounds.bottom + 2 { extended += 1 }
                }
                guard Double(extended) >= max(6, Double(regions[best.label - 1].points.count) * 0.2) else { return recoverHalo() }
                let kept = Dictionary(uniqueKeysWithValues: surfaceOwners[best.label].enumerated().map { ($0.element, $0.offset + 1) })
                sum = [Double](repeating: 0, count: 3); coreCount = 0
                for i in 0..<count {
                    accepted[i] = kept[accepted[i], default: 0]
                    if accepted[i] == 0 || core[i] == 0 || coreNeighbors(i) < 3 { continue }
                    for channel in 0..<3 { sum[channel] += Double(rgba[i * 4 + channel]) }; coreCount += 1
                }
                heights = surfaceOwners[best.label].map { owners[$0].height }
                componentCount = surfaceOwners[best.label].count; retained = best.ink; aligned = best.localAligned
            }
            guard componentCount >= 1, Double(retained) >= Double(aligned) * 0.35, coreCount >= 3 else { return resolve(colors) }
            colors["foreground"] = rounded(sum.map { $0 / Double(coreCount) })
            confidence["foreground"] = min(1, Double(retained) / Double(max(1, aligned))) * min(1, Double(componentCount) / 3)
            confidence["reason"] = "observed validated ink components"
            heights.sort(); let glyphHeight = Double(heights[Int(floor(Double(heights.count - 1) * 0.75))])
            var observedBandPixels = 0, independentSurface = false
            func outsideStroke(_ rgb: [Double]) -> Bool {
                guard distance(rgb, background) > 12, distance(rgb, NativeSourceColorSampler.rgb(colors["foreground"])!) >= 24 else { return false }
                let delta = subtract(rgb, background), factor = dot(delta, direction) / max(1, squared)
                return factor < -0.03 || factor > 1.1 || (zip(delta, direction).map { abs($0 - factor * $1) }.max() ?? 0) > 24
            }
            let strokeBins = bins.filter { $0.count >= 3 && outsideStroke($0.mean) }
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0.order < $1.order }
            if let first = strokeBins.first {
                let strokeSeed = first.mean, reach = min(24, max(6, Int(ceil(glyphHeight * 0.8))))
                let nearest = nearOwners(accepted, reach: reach)
                let strokeMask = (0..<count).map { accepted[$0] == 0 && closed[$0] == 0 &&
                    distance(color($0), strokeSeed) <= 24 && outsideStroke(color($0)) ? UInt8(1) : 0 }
                var bands: [Double] = [], strokePixels = 0, strokeOwners: Set<Int> = [], surface: (count: Int, rgb: [Double])?
                for component in components(strokeMask) {
                    var outer: [Int] = [], owners: Set<Int> = []
                    for i in component.points {
                        if nearest.owner[i] != 0 { owners.insert(nearest.owner[i]) }
                        if neighbors(i).contains(where: { strokeMask[$0] == 0 && accepted[$0] == 0 && distance(color($0), background) <= 32 }) {
                            outer.append(nearest.near[i] != 0 ? nearest.near[i] - 1 : reach + 1)
                        }
                    }
                    guard outer.count >= 4, component.points.count >= 6 else { continue }
                    outer.sort(); let median = outer[outer.count / 2], p90 = outer[Int(floor(Double(outer.count - 1) * 0.9))]
                    if Double(median) <= max(2, ceil(glyphHeight * 0.30)), Double(p90) <= max(3, ceil(glyphHeight * 0.45)) {
                        strokePixels += component.points.count; bands.append(max(0.5, Double(median) - 0.5)); strokeOwners.formUnion(owners)
                    } else if Double(component.points.count) >= Double(count) * 0.1,
                              surface == nil || component.points.count > surface!.count { surface = (component.points.count, rounded(strokeSeed)) }
                }
                if strokePixels >= 6, strokeOwners.count >= 2 {
                    colors["stroke"] = rounded(strokeSeed); colors["outline"] = colors["stroke"]
                    bands.sort(); let band = bands[bands.count / 2]
                    colors["widthEvidence"] = evidence(band, glyphHeight, "outer stroke boundary distance to validated ink; external Manhattan band")
                    confidence["stroke"] = min(0.9, 0.5 + Double(strokeOwners.count) * 0.08)
                    confidence["reason"] = "observed fill with glyph-following third-color outer band"
                    observedBandPixels = strokePixels
                } else if let surface {
                    colors["background"] = surface.rgb; confidence["background"] = 0.8
                    confidence["reason"] = "independent surrounding text surface, not a glyph stroke"; independentSurface = true
                }
            }
            colors["confidence"] = confidence
            if independentSurface { return resolve(colors) }
            let fillCandidates = holes.filter { hole in
                let foreground = rgb(colors["foreground"])!
                if distance(hole.rgb, foreground) < 24 || hole.compactness >= 0.8 && hole.foreign < 3 { return false }
                let delta = subtract(hole.rgb, background), factor = dot(delta, direction) / max(1, squared)
                return distance(hole.rgb, background) <= 12 || factor < 0 ||
                    (zip(delta, direction).map { abs($0 - factor * $1) }.max() ?? 0) > 24
            }
            struct Cluster { var rgb: [Double]; var count: Int; var sums: [Double]; var components: Set<Int>; var holes: [Hole] }
            var clusters: [Cluster] = []
            for hole in fillCandidates {
                let index: Int
                if let found = clusters.firstIndex(where: { distance($0.rgb, hole.rgb) <= 12 }) { index = found }
                else { index = clusters.count; clusters.append(Cluster(rgb: hole.rgb, count: 0, sums: [0, 0, 0], components: [], holes: [])) }
                clusters[index].holes.append(hole); clusters[index].count += hole.count; clusters[index].components.insert(hole.component)
                for channel in 0..<3 { clusters[index].sums[channel] += hole.rgb[channel] * Double(hole.count) }
                clusters[index].rgb = clusters[index].sums.map { $0 / Double(clusters[index].count) }
            }
            let fill = clusters.enumerated().max { $0.element.count != $1.element.count ? $0.element.count < $1.element.count : $0.offset > $1.offset }?.element
            let fillTotal = fillCandidates.reduce(0) { $0 + $1.count }
            var grain = false
            if let fill, distance(fill.rgb, background) > 12, Double(fill.count) < Double(retained) * 0.25 {
                var open = 0, near = 0
                for i in 0..<count where mask[i] == 0 && closed[i] == 0 { open += 1; if distance(color(i), fill.rgb) <= 12 { near += 1 } }
                grain = open >= 64 && Double(near) >= Double(open) * 0.2
            }
            if let fill {
                let fillBackground = distance(fill.rgb, background) <= 12 || grain
                let shaped = fill.holes.contains { $0.compactness < 0.7 || $0.foreign >= 3 }
                let joined = fill.holes.filter { $0.count >= 6 && ($0.compactness < 0.7 || $0.foreign >= 3) }.count >= 3 &&
                    Double(fill.count) >= Double(retained) * 0.5
                let thinOwners = Set(holes.filter { Double($0.interiorHeight) >= Double($0.glyphHeight) * 0.65 &&
                    Double($0.interiorWidth) <= Double($0.glyphHeight) * 0.15 && $0.interiorHeight >= $0.interiorWidth * 4 &&
                    distance($0.rgb, background) < distance(rgb(colors["foreground"])!, background) * 0.3 }.map(\.component))
                let repeatedThin = fillBackground && thinOwners.count >= 3
                let foreground = rgb(colors["foreground"])!
                if fill.components.count >= 2 || joined || repeatedThin,
                   fill.count >= 6, Double(fill.count) >= Double(fillTotal) * 0.5, Double(fill.count) >= Double(observedBandPixels) * 0.5,
                   !fillBackground || (foreground.max()! - foreground.min()! > 20 &&
                    ((fill.components.count >= 3 && Double(fill.components.count) >= Double(componentCount) * 0.6 && shaped) || joined || repeatedThin)) {
                    colors["stroke"] = foreground; colors["outline"] = foreground; colors["foreground"] = rounded(fill.rgb)
                    let bands = fill.holes.map(\.band).sorted(), band = bands[bands.count / 2]
                    colors["widthEvidence"] = evidence(band, glyphHeight, "own-component enclosure stroke area over bounding perimeter; external band")
                    confidence["stroke"] = fillBackground ? 0.55 : 0.85; confidence["foreground"] = confidence["stroke"]
                    confidence["reason"] = "enclosed glyph fill and distinct enclosing source stroke"; colors["confidence"] = confidence
                    return resolve(colors)
                }
            }
            if rgb(colors["background"]) == nil, Double(solidRim) >= Double(observation.rimCount) * 0.85,
               Double(solidCount) >= Double(count - retained) * 0.65 { colors["background"] = rounded(background) }
            if let candidate = rgb(colors["stroke"]), confidence["reason"] as? String == "observed fill with glyph-following third-color outer band" {
                let surfaceSeed = rgb(colors["foreground"])!
                var inkEnergy = 0.0, surfaceEnergy = 0.0, inkSamples = 0, surfaceSamples = 0
                var candidateMask = [UInt8](repeating: 0, count: count)
                for y in 0..<height { for x in 0..<width {
                    let i = y * width + x, value = color(i), isInk = distance(value, candidate) <= 24, isSurface = distance(value, surfaceSeed) <= 24
                    if isInk { candidateMask[i] = 1 }
                    if x < 2 || y < 2 || x >= width - 2 || y >= height - 2 || !isInk && !isSurface { continue }
                    var energy = 0.0
                    for channel in 0..<3 {
                        var average = 0.0
                        for next in [i - 2, i + 2, i - width * 2, i + width * 2] { average += Double(rgba[next * 4 + channel]) / 4 }
                        energy = max(energy, abs(value[channel] - average))
                    }
                    if isInk { inkEnergy += energy; inkSamples += 1 }; if isSurface { surfaceEnergy += energy; surfaceSamples += 1 }
                } }
                inkEnergy /= Double(max(1, inkSamples)); surfaceEnergy /= Double(max(1, surfaceSamples))
                if inkEnergy >= 12, surfaceEnergy < inkEnergy * 0.6 {
                    var glyphs = 0, inkPixels = 0, left = width, top = height, right = 0, bottom = 0
                    for c in components(candidateMask) {
                        let tail = c.points.count
                        if c.boundary || tail < 9 || Double(c.height) < glyphHeight * 0.5 || c.width > c.height * 3 ||
                            Double(c.width) > Double(width) * 0.9 || Double(c.height) > Double(height) * 0.9 ||
                            Double(tail) / Double(c.area) < 0.15 || tail > 12 && Double(tail) / Double(c.area) > 0.9 { continue }
                        glyphs += 1; inkPixels += tail; left = min(left, c.left); top = min(top, c.top); right = max(right, c.right); bottom = max(bottom, c.bottom)
                    }
                    var beyond = 0
                    for y in 0..<height { for x in 0..<width {
                        if x >= left - 2 && x <= right + 2 && y >= top - 2 && y <= bottom + 2 { continue }
                        if distance(color(y * width + x), surfaceSeed) <= 24 { beyond += 1 }
                    } }
                    if glyphs >= 2, inkPixels >= 6, Double(beyond) >= max(6, Double(surfaceSamples) * 0.2) {
                        colors["foreground"] = candidate; colors["background"] = surfaceSeed; colors["stroke"] = NSNull(); colors["outline"] = NSNull()
                        colors["widthEvidence"] = NSNull(); confidence["foreground"] = 0.65; confidence["background"] = 0.5; confidence["stroke"] = 0.0
                        confidence["reason"] = "observed glyph topology and local contrast distinguish the broader source surface"
                    }
                }
            }
            colors["confidence"] = confidence
            let resolved = resolve(colors)
            return surfaceKey == nil ? directionalStroke(resolved) : resolved
        }

        func directionalStroke(_ original: Payload) -> Payload {
            guard let foreground = rgb(original["foreground"]), let stroke = rgb(original["stroke"]), let background = rgb(original["background"]),
                  let widthEvidence = original["widthEvidence"] as? Payload,
                  var confidence = original["confidence"] as? Payload,
                  confidence["reason"] as? String == "observed fill with glyph-following third-color outer band",
                  distance(foreground, background) > 32, distance(stroke, background) > 32 else { return original }
            let mask = (0..<count).map { distance(color($0), stroke) <= 24 ? UInt8(1) : 0 }
            let total = mask.reduce(0) { $0 + Int($1) }
            var valid = [UInt8](repeating: 0, count: count), kept = 0, accepted = 0
            for component in components(mask) {
                let tail = component.points.count
                if component.boundary || tail < 3 || Double(component.height) < max(3, number(widthEvidence["glyphPixels"]) * 0.5) ||
                    component.width > component.height * 3 || Double(component.height) >= Double(height) * 0.9 ||
                    Double(tail) / Double(component.area) < 0.15 { continue }
                accepted += 1; kept += tail; for i in component.points { valid[i] = 1 }
            }
            guard accepted >= 2, Double(kept) >= Double(total) * 0.5 else { return original }
            let dx = [1, -1, 0, 0, 1, 1, -1, -1], dy = [0, 0, 1, -1, 1, -1, 1, -1]
            func enclosure(_ selected: [Double], other: [Double], restricted: [UInt8]?) -> (ratio: Double, samples: Int) {
                var sum = 0.0, samples = 0
                for i in 0..<count {
                    if restricted != nil && restricted![i] == 0 || distance(color(i), selected) > 16 { continue }
                    let x = i % width, y = i / width
                    var ink = 0, surface = 0
                    for direction in 0..<8 {
                        for step in 1...6 {
                            let xx = x + dx[direction] * step, yy = y + dy[direction] * step
                            if xx < 0 || yy < 0 || xx >= width || yy >= height { break }
                            let rgb = color(yy * width + xx), di = distance(rgb, other), db = distance(rgb, background), ds = distance(rgb, selected)
                            if di + 16 < db && di + 16 < ds { ink += 1; break }
                            if db + 16 < di && db + 16 < ds { surface += 1; break }
                        }
                    }
                    if ink + surface >= 5 { sum += Double(ink) / Double(ink + surface); samples += 1 }
                }
                return (sum / Double(max(1, samples)), samples)
            }
            let candidate = enclosure(stroke, other: foreground, restricted: valid)
            let current = enclosure(foreground, other: stroke, restricted: nil)
            guard candidate.samples >= 6, current.samples >= 6, candidate.ratio > 0.5, candidate.ratio > current.ratio else { return original }
            var result = original
            result["foreground"] = stroke; result["stroke"] = foreground; result["outline"] = foreground
            confidence["reason"] = "directional enclosure of repeated source ink fragments distinguishes fill from outline"
            confidence["foreground"] = 0.6; confidence["stroke"] = 0.6; result["confidence"] = confidence
            return result
        }
    }
}
