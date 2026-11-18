import CoreGraphics
import Foundation

/// Display-outline experiment only. Source predictions, dominant ink, text and layout are immutable.
enum EnsembleCandidate07Next2: Ensemble100Candidate {
    static let defaults: [String: Double] = [
        "enabled": 1, "sampleSide": 128, "fillWeight": 0.70, "backgroundMeanWeight": 0.95,
        "backgroundTailWeight": 0.45, "sourceToneWeight": 0.85, "sourceContrastWeight": 0.25,
        "sourceTolerance": 28, "minimumEndpointPixels": 6, "minimumSourceContacts": 4,
        "decisionMargin": 0.02, "strokeRatio": 0.20, "extraWidth1": 0, "extraWidth2": 0,
        "minimumStrokePixels": 2, "widthCost": 0.10, "safetyWeight": 4,
        "counterReservePixels": 1, "protectCounters": 1
    ]
    static let ranges: [String: ClosedRange<Double>] = [
        "enabled": 0...1, "sampleSide": 64...256, "fillWeight": 0...2,
        "backgroundMeanWeight": 0...3, "backgroundTailWeight": 0...2,
        "sourceToneWeight": 0...3, "sourceContrastWeight": 0...2, "sourceTolerance": 12...48,
        "minimumEndpointPixels": 3...32, "minimumSourceContacts": 2...24, "decisionMargin": 0...0.25,
        "strokeRatio": 0.20...0.32, "extraWidth1": 0...0.12, "extraWidth2": 0...0.16,
        "minimumStrokePixels": 2...4, "widthCost": 0...1, "safetyWeight": 1...10,
        "counterReservePixels": 1...3, "protectCounters": 0...1
    ]
    private struct RGB {
        let r: Double, g: Double, b: Double
        var array: [Double] { [r, g, b] }
        var luminance: Double {
            func linear(_ v: Double) -> Double { let v = v / 255; return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }
        func gap(_ other: RGB) -> Double { max(abs(r - other.r), abs(g - other.g), abs(b - other.b)) }
        func contrast(_ other: RGB) -> Double {
            let a = luminance, b = other.luminance
            return log((max(a, b) + 0.05) / (min(a, b) + 0.05)) / log(21)
        }
        var isBW: Bool { array == [0, 0, 0] || array == [255, 255, 255] }
    }
    private struct Pixel { let color: RGB; let alpha: UInt8 }
    private struct Target {
        let width: Int, height: Int
        let fill: [Bool], holes: [Bool]
        let geometry: [String: Any]
    }
    private static func n(_ value: Any?) -> Double? {
        guard let v = (value as? NSNumber)?.doubleValue, v.isFinite else { return nil }; return v
    }
    private static func rgb(_ value: Any?) -> RGB? {
        guard let a = value as? [Any], a.count == 3 else { return nil }
        let v = a.compactMap(n)
        guard v.count == 3, v.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return RGB(r: v[0], g: v[1], b: v[2])
    }
    private static func rect(_ value: Any?) -> CGRect? {
        guard let a = value as? [Any], a.count == 4 else { return nil }
        let v = a.compactMap(n)
        guard v.count == 4, v[2] > 0, v[3] > 0 else { return nil }
        let r = CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
        return r.isNull || r.isInfinite ? nil : r
    }
    private static func polygon(_ value: Any?) -> [CGPoint] {
        guard let a = value as? [[Double]], a.count >= 3, a.count <= 1024,
              a.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) else { return [] }
        return a.map { CGPoint(x: $0[0], y: $0[1]) }
    }
    private static func inside(_ q: CGPoint, _ ring: [CGPoint]) -> Bool {
        guard !ring.isEmpty else { return true }
        var result = false, j = ring.count - 1
        for i in ring.indices {
            let a = ring[i], b = ring[j]
            if (a.y > q.y) != (b.y > q.y), q.x < (b.x - a.x) * (q.y - a.y) / (b.y - a.y) + a.x { result.toggle() }
            j = i
        }
        return result
    }
    private static func pixels(_ image: CGImage, roi: CGRect, w: Int, h: Int) -> [Pixel]? {
        let crop = CGRect(x: roi.minX * Double(image.width), y: roi.minY * Double(image.height),
            width: roi.width * Double(image.width), height: roi.height * Double(image.height))
        guard let part = image.cropping(to: crop.integral), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let c = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                    CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            c.interpolationQuality = .none
            let a = crop.integral
            c.draw(part, in: CGRect(x: (a.minX - crop.minX) / crop.width * Double(w),
                y: (crop.maxY - a.maxY) / crop.height * Double(h),
                width: a.width / crop.width * Double(w), height: a.height / crop.height * Double(h)))
            return true
        }
        guard ok else { return nil }
        return (0..<(w * h)).map { i in
            let alpha = bytes[i * 4 + 3], scale = alpha > 0 ? 255 / Double(alpha) : 0
            return Pixel(color: RGB(r: min(255, Double(bytes[i * 4]) * scale),
                g: min(255, Double(bytes[i * 4 + 1]) * scale), b: min(255, Double(bytes[i * 4 + 2]) * scale)), alpha: alpha)
        }
    }
    /// Pure mask arithmetic on an already supplied target mask; no font/page rendering or inference.
    static func halo(fill: [Bool], width: Int, height: Int, radius: Int, protected: [Bool]) -> [Bool] {
        guard width > 0, height > 0, width <= 262144 / height, fill.count == width * height,
              protected.count == fill.count else { return [] }
        let radius = min(max(width, height), max(1, radius)), far = width + height + 1
        var distance = fill.map { $0 ? 0 : far }
        // Chebyshev dilation is a conservative occupancy bound on a round outline.
        for y in 0..<height { for x in 0..<width {
            let i = y * width + x
            if x > 0 { distance[i] = min(distance[i], distance[i - 1] + 1) }
            if y > 0 {
                distance[i] = min(distance[i], distance[i - width] + 1)
                if x > 0 { distance[i] = min(distance[i], distance[i - width - 1] + 1) }
                if x + 1 < width { distance[i] = min(distance[i], distance[i - width + 1] + 1) }
            }
        } }
        for y in (0..<height).reversed() { for x in (0..<width).reversed() {
            let i = y * width + x
            if x + 1 < width { distance[i] = min(distance[i], distance[i + 1] + 1) }
            if y + 1 < height {
                distance[i] = min(distance[i], distance[i + width] + 1)
                if x > 0 { distance[i] = min(distance[i], distance[i + width - 1] + 1) }
                if x + 1 < width { distance[i] = min(distance[i], distance[i + width + 1] + 1) }
            }
        } }
        return fill.indices.map { distance[$0] <= radius && !fill[$0] && !protected[$0] }
    }
    private static func holes(_ fill: [Bool], _ w: Int, _ h: Int) -> [Bool] {
        var outside = fill, queue: [Int] = []
        for i in fill.indices where !fill[i] && (i < w || i >= w * (h - 1) || i % w == 0 || i % w == w - 1) {
            outside[i] = true; queue.append(i)
        }
        var cursor = 0
        while cursor < queue.count {
            let i = queue[cursor]; cursor += 1
            let x = i % w, y = i / w
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && nx < w && ny >= 0 && ny < h {
                let j = ny * w + nx
                if !outside[j] { outside[j] = true; queue.append(j) }
            }
        }
        return fill.indices.map { !outside[$0] }
    }
    private static func runs(_ mask: [Bool], _ w: Int, _ h: Int) -> [[Int]] {
        var result: [[Int]] = []
        for y in 0..<h {
            var x = 0
            while x < w {
                if !mask[y * w + x] { x += 1; continue }
                let left = x
                while x < w && mask[y * w + x] { x += 1 }
                result.append([y, left, x])
            }
        }
        return result
    }
    private static func cgImage(_ value: Any?) -> CGImage? {
        guard let value, CFGetTypeID(value as CFTypeRef) == CGImage.typeID else { return nil }
        return (value as! CGImage)
    }
    private static func target(_ page: Ensemble100Page, raw: [String: Any], frame: CGRect, font: Double) -> Target? {
        guard let id = raw["id"] as? String,
              let all = page.savedEvidence["targetGlyphEvidenceByID"] as? [String: [String: Any]], let entry = all[id],
              let image = cgImage(entry["fillMask"]), let suppliedFont = n(entry["fontOutputPixels"]),
              abs(suppliedFont - font) <= 0.1, let suppliedFrame = rect(entry["frameOutputPixels"]),
              abs(suppliedFrame.minX - frame.minX) <= 0.1, abs(suppliedFrame.minY - frame.minY) <= 0.1,
              abs(suppliedFrame.width - frame.width) <= 0.1, abs(suppliedFrame.height - frame.height) <= 0.1,
              n(entry["completeUTF16"]) == Double((raw["text"] as? String ?? "").utf16.count),
              frame.width <= 512, frame.height <= 512,
              image.width == Int(frame.width.rounded()), image.height == Int(frame.height.rounded()),
              image.width <= 512, image.height <= 512,
              let bytes = pixels(image, roi: CGRect(x: 0, y: 0, width: 1, height: 1), w: image.width, h: image.height) else { return nil }
        // A mask is documented as white ink / black void, independent of its alpha representation.
        let fill = bytes.map { $0.alpha >= 128 && $0.color.r >= 128 }
        guard fill.contains(true) else { return nil }
        return Target(width: image.width, height: image.height, fill: fill,
            holes: holes(fill, image.width, image.height), geometry: entry)
    }

    static func apply(_ page: Ensemble100Page, parameters: [String: Double]) throws -> Ensemble100Proposal {
        func p(_ key: String) -> Double {
            let v = parameters[key] ?? defaults[key]!, r = ranges[key]!
            return min(r.upperBound, max(r.lowerBound, v.isFinite ? v : defaults[key]!))
        }
        guard p("enabled") > 0 else { return Ensemble100Proposal(items: page.items, audit: ["agent07Next2": "disabled"]) }
        var output = page.items, records: [[String: Any]] = []
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let black = RGB(r: 0, g: 0, b: 0), white = RGB(r: 255, g: 255, b: 255)
        for index in page.items.indices {
            let raw = page.items[index], prior = raw["ensemblePaletteAudit"] as? [String: Any] ?? [:]
            let display = rgb(raw["ensembleDisplayFill"]) ?? rgb(prior["displayFill"]) ?? rgb(prior["selectedOriginalInk"])
            let sourceFill = rgb(prior["sourceFill"]) ?? rgb(raw["originalFill"]) ?? rgb(raw["sourceFill"])
            let sourceStroke = rgb(prior["sourceStroke"]) ?? rgb(raw["originalStroke"]) ?? rgb(raw["sourceStroke"])
            var audit: [String: Any] = ["index": index, "id": raw["id"] ?? index,
                "sourcePredictionsChanged": false, "displayFillChanged": false, "sourceEvidence": prior,
                "authority": "automated source-support and restored-distribution measurement; not image inspection or gold"]
            let sx = page.viewport.width.isFinite && page.viewport.width > 0 ? Double(page.restored.width) / page.viewport.width : 1
            let sy = page.viewport.height.isFinite && page.viewport.height > 0 ? Double(page.restored.height) / page.viewport.height : sx
            let font = max(1, (n(raw["fontSize"]) ?? 12) * sx)
            let targetRect = rect([n(raw["x"]) ?? 0, n(raw["y"]) ?? 0, n(raw["width"]) ?? 0, n(raw["height"]) ?? 0])
            let frame = targetRect.map { CGRect(x: $0.minX * sx, y: $0.minY * sy, width: $0.width * sx, height: $0.height * sy) }
            let targetMask = frame.flatMap { target(page, raw: raw, frame: $0, font: font) }
            var background: [(RGB, Int)] = [], sourceCounts = [0, 0], contacts = 0
            if let box = rect(raw["sourceBounds"]), box.intersects(unit), let sourceFill, let sourceStroke,
               sourceFill.gap(sourceStroke) > p("sourceTolerance") * 2 {
                let roi = box.intersection(unit), side = Int(p("sampleSide"))
                let scale = min(Double(side) / max(roi.width * Double(page.original.width), roi.height * Double(page.original.height)), 1)
                let w = max(1, Int(ceil(roi.width * Double(page.original.width) * scale)))
                let h = max(1, Int(ceil(roi.height * Double(page.original.height) * scale)))
                if let original = pixels(page.original, roi: roi, w: w, h: h) {
                    let shape = polygon(raw["sourcePolygon"])
                    let peers = page.items.enumerated().compactMap { $0.offset == index ? nil : rect($0.element["sourceBounds"]) }
                    var labels = [Int](repeating: -1, count: w * h)
                    for i in original.indices where original[i].alpha >= 245 {
                        let q = CGPoint(x: roi.minX + (Double(i % w) + 0.5) / Double(w) * roi.width,
                            y: roi.minY + (Double(i / w) + 0.5) / Double(h) * roi.height)
                        guard inside(q, shape), !peers.contains(where: { $0.contains(q) }) else { continue }
                        let a = original[i].color.gap(sourceFill), b = original[i].color.gap(sourceStroke)
                        if min(a, b) <= p("sourceTolerance") { let role = a <= b ? 0 : 1; labels[i] = role; sourceCounts[role] += 1 }
                    }
                    for i in labels.indices where labels[i] >= 0 {
                        if i % w + 1 < w, labels[i + 1] >= 0, labels[i] != labels[i + 1] { contacts += 1 }
                        if i / w + 1 < h, labels[i + w] >= 0, labels[i] != labels[i + w] { contacts += 1 }
                    }
                } else { audit["sourceTechnicalError"] = "original owned ROI decode failed" }
            }
            if let frame, frame.width > 0, frame.height > 0 {
                let normalized = CGRect(x: frame.minX / Double(page.restored.width), y: frame.minY / Double(page.restored.height),
                    width: frame.width / Double(page.restored.width), height: frame.height / Double(page.restored.height))
                if unit.contains(normalized) {
                    let scale = min(1, p("sampleSide") / max(frame.width, frame.height))
                    let w = max(1, Int(ceil(frame.width * scale))), h = max(1, Int(ceil(frame.height * scale)))
                    if let restored = pixels(page.restored, roi: normalized, w: w, h: h) {
                        let peers = page.items.enumerated().compactMap { j, item -> CGRect? in
                            guard j != index, let r = rect([n(item["x"]) ?? 0, n(item["y"]) ?? 0,
                                n(item["width"]) ?? 0, n(item["height"]) ?? 0]) else { return nil }
                            return CGRect(x: r.minX * sx, y: r.minY * sy, width: r.width * sx, height: r.height * sy)
                        }
                        for i in restored.indices where restored[i].alpha >= 245 {
                            let q = CGPoint(x: frame.minX + (Double(i % w) + 0.5) * frame.width / Double(w),
                                y: frame.minY + (Double(i / w) + 0.5) * frame.height / Double(h))
                            guard !peers.contains(where: { $0.contains(q) }) else { continue }
                            let ti: Int
                            if let mask = targetMask {
                                let normalizedY = Double(i / w) / Double(h)
                                let normalizedX = Double(i % w) / Double(w)
                                let maskY = min(mask.height - 1, Int(normalizedY * Double(mask.height)))
                                let maskX = min(mask.width - 1, Int(normalizedX * Double(mask.width)))
                                ti = maskY * mask.width + maskX
                            } else { ti = -1 }
                            background.append((restored[i].color, ti))
                        }
                    } else { audit["backgroundTechnicalError"] = "restored target ROI decode failed" }
                } else { audit["backgroundTechnicalError"] = "display frame lies outside restored page; no clipped-frame proxy" }
            } else { audit["backgroundTechnicalError"] = "missing/invalid target display geometry" }
            var counterpart: RGB?, sourceConfidence = 0.0
            if let display, let sourceFill, let sourceStroke,
               sourceCounts.min()! >= Int(p("minimumEndpointPixels")), contacts >= Int(p("minimumSourceContacts")) {
                let a = display.gap(sourceFill), b = display.gap(sourceStroke)
                if min(a, b) <= p("sourceTolerance"), abs(a - b) >= p("sourceTolerance") {
                    counterpart = a <= b ? sourceStroke : sourceFill
                    sourceConfidence = min(1, Double(contacts) / (p("minimumSourceContacts") * 2))
                }
            }
            audit["originalEndpointOwnedSamples"] = sourceCounts; audit["originalEndpointContacts"] = contacts
            audit["sourceHierarchyConfidence"] = sourceConfidence
            audit["sourceUncertainty"] = counterpart == nil ? "missing/conflicting/unobserved roles; source hierarchy weight zero" :
                "prior roles supported by owned original colours/contact; not new source predictions"
            audit["backgroundSamples"] = background.count
            audit["backgroundLuminanceDistribution"] = [0.1, 0.5, 0.9].map { q -> Double in
                let values = background.map { $0.0.luminance }.sorted(); return values.isEmpty ? -1 : values[Int(Double(values.count - 1) * q)]
            }
            audit["targetGlyphAuthority"] = targetMask == nil ? "actual target mask absent/stale/incomplete; bbox background proxy; counter safety unknown" :
                "supplied complete target fill mask at exact output frame/font; not RF/source mask"
            audit["rfStatus"] = "OCR ownership + original pixels; RF is support only, never glyph truth"
            audit["rfBoxesWithoutMasks"] = page.rfRegions.filter { $0.exterior.isEmpty }.count
            let base = max(p("strokeRatio"), p("minimumStrokePixels") / font)
            let widths = Array(Set([base, max(base, p("strokeRatio") + p("extraWidth1")),
                max(base, p("strokeRatio") + p("extraWidth2"))])).sorted()
            var scores: [(RGB, Double, Double, [String: Any])] = []
            for ratio in widths {
                let radius = ratio * font
                let empty = targetMask.map { [Bool](repeating: false, count: $0.fill.count) } ?? []
                let haloMask = targetMask.map { halo(fill: $0.fill, width: $0.width, height: $0.height,
                    radius: Int(min(Double(max($0.width, $0.height)), ceil(radius))), protected: empty) } ?? []
                let holesCount = targetMask?.holes.filter { $0 }.count ?? 0
                let counterHit = targetMask.map { mask in mask.holes.indices.filter { mask.holes[$0] && haloMask[$0] }.count } ?? 0
                let counterRisk = holesCount > 0 ? Double(counterHit) / Double(holesCount) : 0
                for stroke in [black, white] {
                    let samples = background.filter { pair in
                        guard let mask = targetMask else { return true }
                        return pair.1 >= 0 && haloMask[pair.1] && !mask.holes[pair.1]
                    }
                    let contrasts = samples.map { stroke.contrast($0.0) }.sorted()
                    let mean = contrasts.isEmpty ? 0 : contrasts.reduce(0, +) / Double(contrasts.count)
                    let tail = contrasts.isEmpty ? 0 : contrasts[Int(Double(contrasts.count - 1) * 0.2)]
                    let fillContrast = display.map { stroke.contrast($0) } ?? 0
                    let tone = counterpart.map { 1 - abs(stroke.luminance - $0.luminance) } ?? 0
                    let hierarchy: Double
                    if let sourceFill, let sourceStroke { hierarchy = 1 - abs(fillContrast - sourceFill.contrast(sourceStroke)) } else { hierarchy = 0 }
                    let risk = p("protectCounters") > 0 && targetMask != nil ? 0 : counterRisk
                    let score = p("fillWeight") * fillContrast + p("backgroundMeanWeight") * mean + p("backgroundTailWeight") * tail +
                        sourceConfidence * (p("sourceToneWeight") * tone + p("sourceContrastWeight") * hierarchy) -
                        p("widthCost") * (ratio - base) - p("safetyWeight") * risk
                    scores.append((stroke, ratio, score, ["stroke": stroke.array, "ratio": ratio, "score": score,
                        "fillContrast": fillContrast, "backgroundMean": mean, "backgroundTail20": tail,
                        "sourceCounterpartTone": tone, "sourceContrastMatch": hierarchy,
                        "unprotectedCounterCoverage": counterRisk, "haloBackgroundSamples": samples.count]))
                }
            }
            scores.sort { a, b in a.2 == b.2 ? (a.1 == b.1 ? a.0.r < b.0.r : a.1 < b.1) : a.2 > b.2 }
            var selected = scores[0]
            let priorStroke = rgb(raw["ensembleDisplayStroke"])
            let opposite = scores.first { $0.0.r != selected.0.r }
            if let opposite, selected.2 - opposite.2 < p("decisionMargin"), let priorStroke, priorStroke.isBW,
               let keep = scores.first(where: { $0.0.r == priorStroke.r && $0.1 == base }) {
                selected = keep; audit["decision"] = "score tie/uncertainty; keep valid prior BW at legal base width"
            } else { audit["decision"] = "maximum scored BW/width proposal" }
            output[index]["ensembleDisplayStroke"] = selected.0.array
            output[index]["ensembleStrokeRatio"] = selected.1
            let radius = selected.1 * font
            var paint: [String: Any] = ["order": "stroke-before-fill", "allHalosBeforeAllFills": true,
                "outwardRadiusPixels": radius, "requiredPaddingPixels": ceil(radius) + 1,
                "retainedRasterCertified": false, "protectCounterVoids": false]
            if let mask = targetMask, p("protectCounters") > 0 {
                let reserve = halo(fill: mask.holes, width: mask.width, height: mask.height,
                    radius: Int(p("counterReservePixels")), protected: [Bool](repeating: false, count: mask.fill.count))
                let protected = mask.holes.indices.map { mask.holes[$0] || reserve[$0] }
                paint["protectCounterVoids"] = true
                paint["counterRuns"] = runs(protected, mask.width, mask.height)
                paint["counterSpace"] = "local target fill mask pixels; y,x0,x1Exclusive"
                paint["frameOutputPixels"] = frame.map { [$0.minX, $0.minY, $0.width, $0.height] }
                paint["maskSize"] = [mask.width, mask.height]
                paint["fontOutputPixels"] = font
            }
            output[index]["ensembleStrokePaintPolicy"] = paint
            audit["scores"] = scores.map { $0.3 }; audit["selectedStroke"] = selected.0.array
            audit["selectedRatio"] = selected.1; audit["paintPolicy"] = paint
            audit["smallCounterSafety"] = targetMask == nil ? "unknown; parent retained glyph/counter check required" :
                p("protectCounters") > 0 ? "protected counter runs supplied; parent must honor runs at retained frame/font" : "unprotected risk measured; parent must reject unsafe retention"
            output[index]["ensembleStrokeAudit"] = audit
            records.append(audit)
        }
        return Ensemble100Proposal(items: output, audit: ["agent07Next2": records, "inputItems": page.items.count,
            "outputItems": output.count, "actualImagesInspected": 0, "sourcePredictionsChanged": false])
    }
}
