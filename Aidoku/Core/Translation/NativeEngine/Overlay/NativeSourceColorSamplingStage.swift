import CoreGraphics
import Foundation

/// Per-page sampling admission, phase cache and policy chain. Only original source
/// pixels enter observers: translated glyphs never become evidence for a later revision.
final class NativeSourceColorSamplingStage {
    typealias Payload = [String: Any]
    typealias RGB = [Double]

    final class Budget {
        var pixels: Int
        var detailPixels: Int
        var remainingSamples: Int?
        init(pixels: Int = 393_216, detailPixels: Int = 98_304, remainingSamples: Int? = nil) {
            self.pixels = pixels
            self.detailPixels = detailPixels
            self.remainingSamples = remainingSamples
        }
    }

    struct Stats {
        var pixels = 0
        var hits = 0
        var samples = 0
        var milliseconds: Double = 0
    }

    private final class PhaseCache: @unchecked Sendable {
        struct Value { let result: Payload? }
        struct Entry {
            weak var image: CGImage?
            var phases: [String: [String: Value]] = [:]
            var orders: [String: [String]] = [:]
        }
        static let shared = PhaseCache()
        private let lock = NSLock()
        private var entries: [ObjectIdentifier: Entry] = [:]
        func lookup(image: CGImage, phase: String, key: String) -> Value? {
            lock.lock(); defer { lock.unlock() }
            let identity = ObjectIdentifier(image)
            guard let entry = entries[identity], entry.image === image else { return nil }
            return entry.phases[phase]?[key]
        }
        func store(_ result: Payload?, image: CGImage, phase: String, key: String) {
            lock.lock(); defer { lock.unlock() }
            entries = entries.filter { $0.value.image != nil }
            let identity = ObjectIdentifier(image)
            var entry = entries[identity] ?? Entry(image: image)
            if entry.image !== image { entry = Entry(image: image) }
            var order = entry.orders[phase] ?? []
            var values = entry.phases[phase] ?? [:]
            if values.count >= 256, !order.isEmpty { values.removeValue(forKey: order.removeFirst()) }
            if values[key] == nil { order.append(key) }
            values[key] = Value(result: result)
            entry.orders[phase] = order
            entry.phases[phase] = values
            entries[identity] = entry
        }
    }

    private let image: CGImage
    private let enabled: Bool
    private let phase: String
    let budget: Budget
    private let pixelReader: NativeSourcePixelReader?
    private var unavailable = false
    private(set) var stats = Stats()

    init(image: CGImage, enabled: Bool, phase: String = "ocr", budget: Budget = Budget(),
         pixelReader: NativeSourcePixelReader? = nil) {
        self.image = image
        self.enabled = enabled
        self.phase = phase == "translation" ? "translation" : "ocr"
        self.budget = budget
        self.pixelReader = pixelReader
    }

    func sample(bounds: [Double], geometry: Payload? = nil) -> Payload? {
        guard enabled, !unavailable, bounds.count == 4, bounds.allSatisfy(\.isFinite),
              bounds[0] >= 0, bounds[1] >= 0, bounds[2] > 0, bounds[3] > 0,
              bounds[0] + bounds[2] <= 1.000001, bounds[1] + bounds[3] <= 1.000001 else { return nil }
        let key = Self.cacheKey(bounds: bounds, geometry: geometry)
        if let cached = PhaseCache.shared.lookup(image: image, phase: phase, key: key) {
            stats.hits += 1
            return cached.result
        }
        let detailLimit = Int(floor(Double(budget.detailPixels) / Double(max(1, budget.remainingSamples ?? 1))))
        if let remaining = budget.remainingSamples { budget.remainingSamples = max(0, remaining - 1) }
        var detailSpent = 0
        let iw = Double(image.width), ih = Double(image.height)
        let sourceWidth = bounds[2] * iw, sourceHeight = bounds[3] * ih
        let vertical = sourceHeight >= sourceWidth
        let longText = max(sourceWidth, sourceHeight) >= min(sourceWidth, sourceHeight) * 1.5
        let margin = max(4, min(16, ceil(min(sourceWidth, sourceHeight) * 0.5)))
        let x = max(0, floor(bounds[0] * iw) - margin), y = max(0, floor(bounds[1] * ih) - margin)
        let sw = min(iw, ceil((bounds[0] + bounds[2]) * iw) + margin) - x
        let sh = min(ih, ceil((bounds[1] + bounds[3]) * ih) + margin) - y
        guard sw > 0, sh > 0 else { return nil }
        let sampleLimit = min(24_576, Int(floor(Double(budget.pixels) / Double(max(1, (budget.remainingSamples ?? 0) + 1)))))
        guard sampleLimit >= 1 else { return nil }
        let scale = min(1, sqrt(Double(sampleLimit) / (sw * sh)))
        let width = min(sampleLimit, max(1, Int(floor(sw * scale))))
        let height = min(sampleLimit / width, max(1, Int(floor(sh * scale))))
        guard width * height <= budget.pixels else { return nil }
        budget.pixels -= width * height
        stats.pixels += width * height
        stats.samples += 1
        let started = ProcessInfo.processInfo.systemUptime
        var result: Payload?
        defer {
            stats.milliseconds += (ProcessInfo.processInfo.systemUptime - started) * 1_000
            PhaseCache.shared.store(result, image: image, phase: phase, key: key)
        }
        do {
            let rgba = try read(x: x, y: y, sourceWidth: sw, sourceHeight: sh, width: width, height: height)
            let opaque = stride(from: 3, to: rgba.count, by: 4).allSatisfy { rgba[$0] >= 250 }
            let inner = [(bounds[0] * iw - x) * Double(width) / sw,
                         (bounds[1] * ih - y) * Double(height) / sh,
                         bounds[2] * iw * Double(width) / sw, bounds[3] * ih * Double(height) / sh]
            func localPolygon(_ polygon: [[Double]]) -> [[Double]] {
                polygon.map { [($0[0] * iw - x) * Double(width) / sw, ($0[1] * ih - y) * Double(height) / sh] }
            }
            let polygons = Self.polygon(geometry?["polygon"]).map { [localPolygon($0)] } ?? []
            let excluded = (geometry?["excluded"] as? [Any] ?? []).compactMap(Self.polygon).map(localPolygon)
            let ownership = Self.geometryMask(width: width, height: height, polygons: polygons, excluded: excluded, margin: 1)
            result = Self.estimateOCR(rgba: rgba, width: width, height: height, ownership: ownership)
            result = NativeCaptionSourcePalette.recoverSourcePanel(rgba: rgba, width: width, height: height, box: inner, result: result)
            result = Self.tightPaperRetry(rgba: rgba, width: width, height: height, box: inner, result: result)
            if var evidence = result?["widthEvidence"] as? Payload { evidence["sampleScale"] = scale; result?["widthEvidence"] = evidence }
            var lettering = NativeObservedSourcePalette.observedLetteringInk(rgba: rgba, width: width, height: height, box: inner, opaque: opaque)
            var nativeGlyphs: [[Payload]] = []
            let hasColor = Self.chromatic(Self.rgb(result?["foreground"])) ||
                (Self.chromatic(Self.rgb(result?["stroke"])) && Self.confidence(result, "stroke") >= 0.55)
            let foreground = Self.rgb(result?["foreground"])
            if !hasColor && (foreground == nil || Self.minimum(foreground) >= 225 ||
                (Self.confidence(result, "background") < 0.5 && Self.confidence(result, "foreground") <= 0.7)) {
                for factor in [0.5, 0.75] {
                    let cw = Int(floor(Double(width) * factor)), ch = Int(floor(Double(height) * factor)), pixels = cw * ch
                    let reserved = max(0, budget.remainingSamples ?? 0) * 64
                    guard cw >= 8, ch >= 8, pixels <= budget.pixels - reserved,
                          pixels <= budget.detailPixels, detailSpent + pixels <= detailLimit else { continue }
                    spendDetail(pixels, spent: &detailSpent)
                    let detail = try NativeSourcePixelReader.draw(image: image, x: x, y: y,
                        sourceWidth: sw, sourceHeight: sh, width: cw, height: ch)
                    let candidate = NativeSourceColorSampler.estimate(rgba: detail, width: cw, height: ch)
                    guard let fill = Self.rgb(candidate?["foreground"]), Self.confidence(candidate, "foreground") >= 0.6 else { continue }
                    guard Self.chromatic(fill) || (Self.minimum(fill) >= 225 && Self.chromatic(Self.rgb(candidate?["stroke"])) &&
                        Self.confidence(candidate, "stroke") >= 0.55) else { continue }
                    result = Self.with(result, values: ["foreground": fill, "stroke": candidate?["stroke"] ?? NSNull(),
                        "outline": candidate?["stroke"] ?? NSNull(), "widthEvidence": NSNull()],
                        confidence: ["foreground": Self.confidence(candidate, "foreground"), "stroke": Self.confidence(candidate, "stroke"),
                                     "reason": "validated chromatic glyphs at an independent reduction ratio"])
                    break
                }
            }
            let verifyWhiteHalo = Self.rgb(result?["foreground"]) != nil && Self.confidence(result, "foreground") >= 0.6 &&
                Self.minimum(Self.rgb(result?["foreground"])) >= 230 && Self.rgb(result?["background"]) != nil &&
                Self.minimum(Self.rgb(result?["background"])) < 245
            let enclosedDark = NativeCaptionSourcePalette.recoverOutlinedColor(rgba: rgba, width: width, height: height,
                result: result, allowDark: true, opaque: opaque)
            var panelSupportedDark = false
            if let enclosedDark, let background = Self.rgb(result?["background"]), Self.minimum(background) >= 175,
               Self.confidence(result, "background") >= 0.5, Self.maximum(Self.rgb(enclosedDark["foreground"])) < 80 {
                let darkPixels = stride(from: 0, to: rgba.count, by: 4).filter {
                    max(rgba[$0], rgba[$0 + 1], rgba[$0 + 2]) < 80
                }.count
                panelSupportedDark = darkPixels > 0 && Self.number(enclosedDark["fillPixels"]) >= Double(darkPixels) * 0.65
            }
            if let enclosedDark, Self.maximum(Self.rgb(enclosedDark["foreground"])) < 80,
               Self.rgb(result?["foreground"]) == nil || Self.minimum(Self.rgb(result?["foreground"])) < 225 || panelSupportedDark {
                result = Self.with(result, values: ["foreground": enclosedDark["foreground"] ?? NSNull(),
                    "stroke": enclosedDark["stroke"] ?? NSNull(), "outline": enclosedDark["stroke"] ?? NSNull()],
                    confidence: ["foreground": 0.75, "stroke": 0.75,
                                 "reason": "repeated dark glyph interiors enclosed by white source outlines"])
            }
            let protectedDarkInk = Self.rgb(result?["foreground"]) != nil && Self.confidence(result, "foreground") > 0 &&
                Self.maximum(Self.rgb(result?["foreground"])) < 80 && Self.spread(Self.rgb(result?["foreground"])) < 24
            let detailPalette = verifyWhiteHalo ? Self.with(result, values: ["foreground": NSNull()]) : result
            let localFill = NativeCaptionSourcePalette.recoverOutlinedColor(rgba: rgba, width: width, height: height,
                result: detailPalette, allowDark: false, opaque: opaque)
            if let localFill, Self.number(localFill["confidence"]) >= 0.6, !verifyWhiteHalo, !protectedDarkInk {
                result = Self.with(result, values: ["foreground": localFill["foreground"] ?? NSNull(),
                    "stroke": localFill["stroke"] ?? NSNull(), "outline": localFill["stroke"] ?? NSNull(), "widthEvidence": NSNull()],
                    confidence: ["foreground": Self.number(localFill["confidence"]), "stroke": Self.number(localFill["confidence"]),
                                 "reason": "repeated colored interiors enclosed by source white outlines"])
            }
            let needsRoleDetails = Self.rgb(result?["foreground"]) == nil || Self.confidence(result, "foreground") < 0.6 || verifyWhiteHalo ||
                (scale < 1 && Self.rgb(result?["stroke"]) != nil && Self.rgb(result?["foreground"]) != nil &&
                 Self.distance(Self.rgb(result?["foreground"]), Self.rgb(result?["stroke"])) < 80)
            let needsLetteringDetails = scale < 1 && Self.rgb(result?["foreground"]) != nil &&
                Self.maximum(Self.rgb(result?["foreground"])) >= 225 && Self.minimum(Self.rgb(result?["foreground"])) >= 180
            if longText, !protectedDarkInk, needsRoleDetails || needsLetteringDetails {
                var candidates: [Payload] = [], nativeCandidates: [Payload] = [], letteringCandidates: [Payload] = []
                let palette = verifyWhiteHalo ? Self.with(result, values: ["foreground": NSNull()]) : result
                let stripLength = min(192, floor((vertical ? sh : sw) / 2),
                    floor(Double(detailLimit - detailSpent) / (2 * (vertical ? sw : sh))))
                for fraction in [0.0, 1.0, 0.5] {
                    let stripWidth = vertical ? sw : stripLength, stripHeight = vertical ? stripLength : sh
                    guard stripWidth > 0, stripHeight > 0 else { break }
                    let stripX = x + (vertical ? 0 : fraction * (sw - stripWidth))
                    let stripY = y + (vertical ? fraction * (sh - stripHeight) : 0)
                    let stripScale = min(1, sqrt(24_576 / (stripWidth * stripHeight)))
                    let cw = Int(floor(stripWidth * stripScale)), ch = Int(floor(stripHeight * stripScale)), pixels = cw * ch
                    let reserved = min(budget.pixels, max(0, budget.remainingSamples ?? 0) * 64)
                    guard cw >= 8, ch >= 8, pixels <= budget.pixels - reserved,
                          pixels <= budget.detailPixels, detailSpent + pixels <= detailLimit else { break }
                    spendDetail(pixels, spent: &detailSpent)
                    var detail = try read(x: stripX, y: stripY, sourceWidth: stripWidth, sourceHeight: stripHeight, width: cw, height: ch)
                    if fraction != 0.5 {
                        let box = [(bounds[0] * iw - stripX) * Double(cw) / stripWidth,
                                   (bounds[1] * ih - stripY) * Double(ch) / stripHeight,
                                   bounds[2] * iw * Double(cw) / stripWidth, bounds[3] * ih * Double(ch) / stripHeight]
                        if let glyphs = NativeObservedSourcePalette.observedGlyphPalette(rgba: detail, width: cw, height: ch, box: box) {
                            nativeGlyphs.append(glyphs)
                        }
                        if let observed = NativeObservedSourcePalette.observedLetteringInk(rgba: detail, width: cw, height: ch, box: box) {
                            letteringCandidates.append(observed)
                        }
                    }
                    guard needsRoleDetails else { continue }
                    if !vertical { detail = Self.transposed(detail, width: cw, height: ch) }
                    let dw = vertical ? cw : ch, dh = vertical ? ch : cw
                    if let native = NativeSourceColorSampler.estimate(rgba: detail, width: dw, height: dh),
                       Self.rgb(native["foreground"]) != nil, Self.confidence(native, "foreground") >= 0.6 { nativeCandidates.append(native) }
                    var candidate = NativeCaptionSourcePalette.recoverOutlinedColor(rgba: detail, width: dw, height: dh,
                        result: palette, allowDark: false, opaque: false)
                    if let found = candidate, verifyWhiteHalo, let fill = Self.rgb(found["foreground"]) {
                        var observed = 0
                        for pixel in stride(from: 0, to: detail.count, by: 4) where Self.pixelDistance(detail, pixel, fill) <= 28 { observed += 1 }
                        if observed == 0 || Self.number(found["fillPixels"]) < Double(observed) * 0.7 { candidate = nil }
                    }
                    if let candidate { candidates.append(candidate) }
                    if candidates.count >= 2 && Self.distance(Self.rgb(candidates[0]["foreground"]), Self.rgb(candidates.last?["foreground"])) <= 28 { break }
                }
                let matchingLettering = Self.agreeing(letteringCandidates, field: "color", threshold: 24)
                if matchingLettering.count >= 2 {
                    lettering = Self.stableDescending(matchingLettering, by: { Self.number($0["pixels"]) }).first
                }
                let agreeing = Self.agreeing(candidates, field: "foreground", threshold: 28)
                if Self.rgb(result?["foreground"]) == nil,
                   let best = Self.stableDescending(nativeCandidates, by: { Self.confidence($0, "foreground") }).first {
                    result = Self.with(result, values: ["displayForeground": best["foreground"] ?? NSNull()])
                }
                let nativeAgreement = nativeCandidates.filter { candidate in
                    (!verifyWhiteHalo || Self.minimum(Self.rgb(candidate["foreground"])) >= 225) &&
                        nativeCandidates.filter { Self.distance(Self.rgb(candidate["foreground"]), Self.rgb($0["foreground"])) <= 20 }.count >= 2
                }
                if nativeAgreement.count >= 2, agreeing.count < 2 {
                    let best = nativeAgreement.first(where: { Self.rgb($0["stroke"]) != nil }) ?? nativeAgreement[0]
                    let stroke = best["stroke"] as? [Double] ?? Self.rgb(result?["stroke"])
                    result = Self.with(result, values: ["foreground": best["foreground"] ?? NSNull(),
                        "stroke": stroke as Any? ?? NSNull(), "outline": stroke as Any? ?? NSNull(), "widthEvidence": best["widthEvidence"] ?? NSNull()],
                        confidence: ["foreground": Self.confidence(best, "foreground"),
                                     "stroke": Self.rgb(best["stroke"]) != nil ? Self.confidence(best, "stroke") : Self.confidence(result, "stroke"),
                                     "reason": "agreeing native detail palettes preserve fill and outline roles"])
                }
                if agreeing.count >= 2 {
                    func average(_ key: String) -> [Double] {
                        (0..<3).map { channel in
                            floor(agreeing.reduce(0.0) { $0 + (Self.rgb($1[key])?[channel] ?? 0) } / Double(agreeing.count) + 0.5)
                        }
                    }
                    result = Self.with(result, values: ["foreground": average("foreground"), "stroke": average("stroke"),
                        "outline": average("stroke"), "widthEvidence": NSNull()],
                        confidence: ["foreground": 0.75, "stroke": 0.75,
                                     "reason": "matching colored glyph interiors inside observed white outlines in independent strips"])
                }
            }
            if result != nil {
                let surface = NativeCaptionSourcePalette.observedSourceSurface(rgba: rgba, width: width, height: height, box: inner, result: result)
                if let surface, Self.rgb(result?["background"]) == nil || Self.confidence(result, "background") < 0.5 ||
                    (Self.minimum(Self.rgb(result?["background"])) >= 230 && Self.spread(Self.rgb(surface["color"])) < 35) { result?["surface"] = surface }
            }
            result = NativeCaptionSourcePalette.observedCaptionPalette(rgba: rgba, width: width, height: height, box: inner, result: result)
            let displayed = NativeObservedSourcePalette.sourceObservedDisplayInk(sample: result)
            if !Self.chromatic(displayed), !(Self.chromatic(Self.rgb(result?["stroke"])) && Self.confidence(result, "stroke") >= 0.55),
               Self.rgb(result?["foreground"]) == nil || Self.minimum(Self.rgb(result?["foreground"])) >= 225 ||
                (Self.maximum(Self.rgb(result?["foreground"])) > 40 && Self.confidence(result, "background") < 0.5) {
                if let recovered = NativeCaptionSourcePalette.recoverHaloInk(rgba: rgba, width: width, height: height, box: inner) {
                    result = Self.with(result, values: ["foreground": recovered["foreground"] ?? NSNull(), "stroke": NSNull(),
                        "outline": NSNull(), "widthEvidence": NSNull()], confidence: ["foreground": 0.7, "stroke": 0,
                        "reason": "repeated chromatic strokes locally enclosed by white source halos"])
                }
            }
            if let lettering { result = Self.with(result, values: ["lettering": lettering]) }
            var hint: Payload?
            if let background = Self.rgb(result?["background"]),
               (Self.rgb(result?["foreground"]) != nil && Self.confidence(result, "foreground") >= 0.5) ||
                (Self.rgb(result?["foreground"]) == nil && Self.rgb(result?["displayForeground"]) != nil) {
                hint = ["foreground": Self.rgb(result?["foreground"]) ?? Self.rgb(result?["displayForeground"]) ?? [], "background": background]
            }
            let glyphs = NativeObservedSourcePalette.observedGlyphPalette(rgba: rgba, width: width, height: height, box: inner, hint: hint)
            var display = NativeObservedSourcePalette.resolveDisplayGlyphs(result: result, glyphs: glyphs)
            if let current = display, Self.minimum(current) >= 160, Self.spread(current) < 40, nativeGlyphs.count >= 2 {
                let supportedMain = Self.confidence(result, "foreground") >= 0.85 && (glyphs ?? []).contains {
                    Self.number($0["coverage"]) >= 0.75 && Self.distance(Self.rgb($0["color"]), current) <= 16
                }
                let candidates = nativeGlyphs[0].filter { candidate in
                    guard let color = Self.rgb(candidate["color"]), Self.number(candidate["coverage"]) >= 0.35,
                          Self.distance(color, current) <= 64 else { return false }
                    return (!supportedMain || (0..<3).allSatisfy { color[$0] >= current[$0] - 8 }) && nativeGlyphs[1].contains {
                        Self.number($0["coverage"]) >= 0.35 && Self.distance(color, Self.rgb($0["color"])) <= 20
                    }
                }
                if let best = Self.stableDescending(candidates, by: { Self.number($0["score"]) }).first { display = Self.rgb(best["color"]) }
            }
            result = Self.with(result, values: ["displayEvidence": ["color": display as Any? ?? NSNull()]])
            result = NativeCaptionSourcePalette.interiorCaptionSurface(rgba: rgba, width: width, height: height, box: inner, result: result)
            result = NativeCaptionSourcePalette.observedCaptionBackground(rgba: rgba, width: width, height: height, box: inner, result: result)
            var sourceInk: Payload?
            if let fill = Self.rgb(result?["foreground"]), let backing = Self.rgb(result?["background"]) {
                sourceInk = ["foreground": fill, "background": backing, "stroke": result?["stroke"] ?? NSNull(),
                             "widthEvidence": result?["widthEvidence"] ?? NSNull(), "confidence": result?["confidence"] as? Payload ?? [:]]
            }
            let strokeEvidence = NativeObservedSourcePalette.observedStrokePalette(rgba: rgba, width: width, height: height,
                box: inner, glyphs: glyphs, display: display, result: result, opaque: opaque)
            var widthEvidence: Any? = result?["widthEvidence"]
            if let strokeEvidence {
                if let supplied = strokeEvidence["widthEvidence"] { widthEvidence = supplied }
                else if Self.rgb(result?["stroke"]) != nil,
                        Self.distance(Self.rgb(result?["stroke"]), Self.rgb(strokeEvidence["stroke"])) <= 25 {
                    widthEvidence = result?["widthEvidence"] ?? NSNull()
                } else {
                    let band = Self.number(strokeEvidence["band"]), glyphPixels = Self.number(strokeEvidence["glyphPixels"])
                    widthEvidence = ["samplePixels": band, "relativeToGlyph": band / glyphPixels,
                                     "glyphPixels": glyphPixels, "sampleScale": scale,
                                     "method": strokeEvidence["method"] ?? "bounded fill to stroke to exterior transitions"] as Payload
                }
            }
            var finalRoles: Payload = ["sourceInk": sourceInk as Any? ?? NSNull(),
                "stroke": strokeEvidence?["stroke"] ?? NSNull(), "outline": strokeEvidence?["stroke"] ?? NSNull()]
            if let widthEvidence { finalRoles["widthEvidence"] = widthEvidence }
            result = Self.with(result, values: finalRoles, confidence: ["stroke": strokeEvidence != nil ? 0.7 : 0,
                    "strokeReason": strokeEvidence != nil ? "observed narrow enclosing band" : "no independent enclosing band"])
            if let strokeEvidence { result?["foreground"] = strokeEvidence["foreground"] }
        } catch { unavailable = true }
        return result
    }

    private func spendDetail(_ pixels: Int, spent: inout Int) {
        budget.pixels -= pixels
        budget.detailPixels -= pixels
        spent += pixels
        stats.pixels += pixels
    }

    private func read(x: Double, y: Double, sourceWidth: Double, sourceHeight: Double, width: Int, height: Int) throws -> [UInt8] {
        if let pixelReader { return try pixelReader.read(x: x, y: y, sourceWidth: sourceWidth, sourceHeight: sourceHeight, width: width, height: height) }
        return try NativeSourcePixelReader.draw(image: image, x: x, y: y, sourceWidth: sourceWidth, sourceHeight: sourceHeight,
            width: width, height: height)
    }

    private static func cacheKey(bounds: [Double], geometry: Payload?) -> String {
        let serialized = geometry.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        let base = bounds.map { String($0) }.joined(separator: ",")
        let suffix = serialized.map { "|" + String(decoding: $0, as: UTF8.self) } ?? ""
        return base + suffix
    }
    private static func rgb(_ value: Any?) -> RGB? { NativeSourceColorSampler.rgb(value) }
    private static func number(_ value: Any?) -> Double { NativeSourceColorSampler.number(value) }
    private static func confidence(_ result: Payload?, _ field: String) -> Double { number((result?["confidence"] as? Payload)?[field]) }
    private static func minimum(_ color: RGB?) -> Double { color?.min() ?? .infinity }
    private static func maximum(_ color: RGB?) -> Double { color?.max() ?? -.infinity }
    private static func spread(_ color: RGB?) -> Double { maximum(color) - minimum(color) }
    private static func chromatic(_ color: RGB?) -> Bool { color != nil && spread(color) >= 40 }
    private static func distance(_ first: RGB?, _ second: RGB?) -> Double {
        guard let first, let second, first.count >= 3, second.count >= 3 else { return .infinity }
        return (0..<3).map { abs(first[$0] - second[$0]) }.max() ?? .infinity
    }
    private static func pixelDistance(_ rgba: [UInt8], _ offset: Int, _ color: RGB) -> Double {
        (0..<3).map { abs(Double(rgba[offset + $0]) - color[$0]) }.max() ?? .infinity
    }
    private static func with(_ result: Payload?, values: Payload, confidence changes: Payload? = nil) -> Payload {
        var result = result ?? [:]
        for (key, value) in values { result[key] = value }
        if let changes {
            var confidence = result["confidence"] as? Payload ?? [:]
            for (key, value) in changes { confidence[key] = value }
            result["confidence"] = confidence
        }
        return result
    }
    private static func agreeing(_ candidates: [Payload], field: String, threshold: Double) -> [Payload] {
        candidates.filter { candidate in candidates.filter { distance(rgb(candidate[field]), rgb($0[field])) <= threshold }.count >= 2 }
    }
    private static func stableDescending(_ values: [Payload], by score: (Payload) -> Double) -> [Payload] {
        values.enumerated().sorted { first, second in
            let a = score(first.element), b = score(second.element)
            return a == b ? first.offset < second.offset : a > b
        }.map(\.element)
    }
    private static func transposed(_ rgba: [UInt8], width: Int, height: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: rgba.count)
        for y in 0..<height { for x in 0..<width { for channel in 0..<4 {
            result[(x * height + y) * 4 + channel] = rgba[(y * width + x) * 4 + channel]
        } } }
        return result
    }

    static func estimateOCR(rgba: [UInt8], width: Int, height: Int, ownership: [UInt8]?) -> Payload? {
        guard let ownership, ownership.count == width * height else {
            return NativeSourceColorSampler.estimate(rgba: rgba, width: width, height: height)
        }
        let original = NativeSourceColorSampler.estimate(rgba: rgba, width: width, height: height)
        let candidate = NativeSourceColorSampler.estimate(rgba: rgba, width: width, height: height, ownership: ownership)
        guard let ink = rgb(original?["foreground"]), confidence(original, "foreground") >= 0.6 else { return candidate }
        var inside = 0, total = 0
        for index in 0..<(width * height) where pixelDistance(rgba, index * 4, ink) <= 24 {
            total += 1
            if ownership[index] != 0 { inside += 1 }
        }
        let changedRole = spread(ink) >= 40 && rgb(candidate?["foreground"]) != nil && minimum(rgb(candidate?["foreground"])) >= 225
        let retain = Double(inside) >= max(12, Double(total) * 0.4) && (rgb(candidate?["foreground"]) == nil ||
            confidence(candidate, "foreground") + 0.1 < confidence(original, "foreground") || changedRole)
        var result = retain ? original : candidate
        result?["ocrOwnershipEvidence"] = ["matchedInside": inside, "matchedTotal": total, "retainedValidatedInk": retain]
        return result
    }

    private static func tightPaperRetry(rgba: [UInt8], width: Int, height: Int, box: [Double], result: Payload?) -> Payload? {
        guard let foreground = rgb(result?["foreground"]), let stroke = rgb(result?["stroke"]), confidence(result, "stroke") >= 0.55 else { return result }
        let light = NativeSourceColorSampler.luminance(foreground) > NativeSourceColorSampler.luminance(stroke) ? foreground : stroke
        let dark = light == foreground ? stroke : foreground
        guard contrast(light, dark) >= 4.5, lightRegionIsPaper(rgba: rgba, width: width, height: height, box: box, light: light, dark: dark) else { return result }
        let left = max(0, Int(floor(box[0]))), top = max(0, Int(floor(box[1])))
        let bw = min(width, Int(ceil(box[0] + box[2]))) - left, bh = min(height, Int(ceil(box[1] + box[3]))) - top
        guard bw > 0, bh > 0 else { return result }
        var tight = [UInt8](repeating: 0, count: bw * bh * 4)
        for row in 0..<bh {
            let begin = ((row + top) * width + left) * 4
            tight.replaceSubrange((row * bw * 4)..<((row + 1) * bw * 4), with: rgba[begin..<(begin + bw * 4)])
        }
        guard let retry = NativeSourceColorSampler.estimate(rgba: tight, width: bw, height: bh),
              let fill = rgb(retry["foreground"]), let background = rgb(retry["background"]), rgb(retry["stroke"]) == nil,
              confidence(retry, "foreground") >= 0.8,
              NativeSourceColorSampler.luminance(background) > NativeSourceColorSampler.luminance(fill), contrast(fill, background) >= 4.5 else { return result }
        return with(retry, values: [:], confidence: ["reason": "tight box: light role was thick paper, not lettering"])
    }

    static func lightRegionIsPaper(rgba: [UInt8], width: Int, height: Int, box: [Double], light: RGB, dark: RGB) -> Bool {
        guard light.count >= 3, dark.count >= 3, light.prefix(3).allSatisfy(\.isFinite), dark.prefix(3).allSatisfy(\.isFinite),
              box.count == 4, box.allSatisfy(\.isFinite), rgba.count == width * height * 4 else { return false }
        let left = Int(max(0, min(Double(width), floor(box[0])))), top = Int(max(0, min(Double(height), floor(box[1]))))
        let right = Int(max(0, min(Double(width), ceil(box[0] + box[2])))), bottom = Int(max(0, min(Double(height), ceil(box[1] + box[3]))))
        let bw = right - left, bh = bottom - top
        guard bw >= 6, bh >= 6, bw * bh <= 65_536 else { return false }
        func thickness(_ color: RGB) -> Int? {
            var distances = [Int](repeating: 0, count: bw * bh), count = 0
            for y in 0..<bh { for x in 0..<bw where pixelDistance(rgba, ((y + top) * width + x + left) * 4, color) <= 40 {
                distances[y * bw + x] = 65_535
                count += 1
            } }
            guard count >= 8 else { return nil }
            for y in 0..<bh { for x in 0..<bw {
                let index = y * bw + x
                guard distances[index] != 0 else { continue }
                distances[index] = min(distances[index], x > 0 ? distances[index - 1] + 1 : 1,
                    y > 0 ? distances[index - bw] + 1 : 1)
            } }
            for y in stride(from: bh - 1, through: 0, by: -1) { for x in stride(from: bw - 1, through: 0, by: -1) {
                let index = y * bw + x
                guard distances[index] != 0 else { continue }
                distances[index] = min(distances[index], x < bw - 1 ? distances[index + 1] + 1 : 1,
                    y < bh - 1 ? distances[index + bw] + 1 : 1)
            } }
            var histogram = [Int](repeating: 0, count: Int(ceil(Double(min(bw, bh)) / 2)) + 1)
            for value in distances where value > 0 { histogram[value] += 1 }
            var cumulative = 0
            for value in 1..<histogram.count {
                cumulative += histogram[value]
                if cumulative > count / 2 { return value }
            }
            return nil
        }
        guard let paper = thickness(light), let ink = thickness(dark) else { return false }
        return paper >= 3 && paper >= ink * 3
    }

    private static func contrast(_ first: RGB, _ second: RGB) -> Double {
        let a = NativeSourceColorSampler.luminance(first), b = NativeSourceColorSampler.luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private static func polygon(_ value: Any?) -> [[Double]]? {
        guard let values = value as? [Any], (3...32).contains(values.count) else { return nil }
        var result: [[Double]] = []
        for point in values {
            guard let coordinates = point as? [Any], coordinates.count == 2 else { return nil }
            let pair = coordinates.compactMap { ($0 as? NSNumber)?.doubleValue }
            guard pair.count == 2, pair.allSatisfy(\.isFinite) else { return nil }
            result.append(pair)
        }
        return result
    }

    static func geometryMask(width: Int, height: Int, polygons: [[[Double]]], excluded: [[[Double]]] = [], margin: Double = 0) -> [UInt8]? {
        func valid(_ polygon: [[Double]]) -> Bool {
            guard (3...32).contains(polygon.count), polygon.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) else { return false }
            let area = polygon.enumerated().reduce(0.0) { sum, pair in
                let next = polygon[(pair.offset + 1) % polygon.count]
                return sum + pair.element[0] * next[1] - next[0] * pair.element[1]
            }
            return abs(area) >= 8
        }
        guard width > 0, height > 0, width <= 750_000 / height, polygons.contains(where: valid) else { return nil }
        func raster(_ shapes: [[[Double]]]) -> [UInt8] {
            var mask = [UInt8](repeating: 0, count: width * height)
            let eligible = shapes.filter(valid).filter { polygon in
                (polygon.map { $0[0] }.min() ?? .infinity) < Double(width) &&
                    (polygon.map { $0[0] }.max() ?? -.infinity) > 0 &&
                    (polygon.map { $0[1] }.min() ?? .infinity) < Double(height) &&
                    (polygon.map { $0[1] }.max() ?? -.infinity) > 0
            }.prefix(64)
            for polygon in eligible {
                let x0 = Int(max(0, min(Double(width), floor(polygon.map { $0[0] }.min()!))))
                let x1 = Int(max(0, min(Double(width), ceil(polygon.map { $0[0] }.max()!))))
                let y0 = Int(max(0, min(Double(height), floor(polygon.map { $0[1] }.min()!))))
                let y1 = Int(max(0, min(Double(height), ceil(polygon.map { $0[1] }.max()!))))
                guard x0 < x1, y0 < y1 else { continue }
                for y in y0..<y1 { for x in x0..<x1 {
                    var inside = false, previous = polygon.count - 1
                    let px = Double(x) + 0.5, py = Double(y) + 0.5
                    for index in polygon.indices {
                        let a = polygon[index], b = polygon[previous]
                        if (a[1] > py) != (b[1] > py), px < (b[0] - a[0]) * (py - a[1]) / (b[1] - a[1]) + a[0] { inside.toggle() }
                        previous = index
                    }
                    if inside { mask[y * width + x] = 1 }
                } }
            }
            return mask
        }
        let core = raster(polygons)
        let radius = min(12, max(0, margin.isFinite ? Int(ceil(margin)) : 0))
        var mask = core
        if radius > 0 {
            var horizontal = [UInt8](repeating: 0, count: width * height)
            mask = [UInt8](repeating: 0, count: width * height)
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
        return mask
    }
}

/// Canvas-equivalent crop coordinates over CGImage. Exact native-size crops can
/// reuse one verified page raster, while fractional and scaled draws stay independent.
final class NativeSourcePixelReader {
    private let image: CGImage
    private let limit: Int
    private let threshold: Int
    private var page: [UInt8]?
    private var state = 0
    private var exactCrops = 0
    enum ReadError: Error { case invalidGeometry, bitmapUnavailable }

    init(image: CGImage, limit: Int = 4_194_304, threshold: Int = 3) {
        self.image = image
        self.limit = limit
        self.threshold = threshold
    }

    func release() { page = nil; state = -1 }

    func read(x: Double, y: Double, sourceWidth: Double, sourceHeight: Double, width: Int, height: Int) throws -> [UInt8] {
        let exact = sourceWidth == Double(width) && sourceHeight == Double(height) && x == floor(x) && y == floor(y) &&
            x >= 0 && y >= 0 && width > 0 && height > 0 && x + Double(width) <= Double(image.width) && y + Double(height) <= Double(image.height)
        if state == 1, exact, let page { return slice(page, x: Int(x), y: Int(y), width: width, height: height) }
        let drawn = try Self.draw(image: image, x: x, y: y, sourceWidth: sourceWidth, sourceHeight: sourceHeight, width: width, height: height)
        if state == 0, exact {
            exactCrops += 1
            if exactCrops >= threshold {
                state = -1
                if image.width <= limit / max(1, image.height),
                   let whole = try? Self.draw(image: image, x: 0, y: 0, sourceWidth: Double(image.width), sourceHeight: Double(image.height),
                    width: image.width, height: image.height), slice(whole, x: Int(x), y: Int(y), width: width, height: height) == drawn {
                    page = whole
                    state = 1
                }
            }
        }
        return drawn
    }

    private func slice(_ page: [UInt8], x: Int, y: Int, width: Int, height: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            let begin = ((y + row) * image.width + x) * 4
            result.replaceSubrange((row * width * 4)..<((row + 1) * width * 4), with: page[begin..<(begin + width * 4)])
        }
        return result
    }

    static func draw(image: CGImage, x: Double, y: Double, sourceWidth: Double, sourceHeight: Double, width: Int, height: Int) throws -> [UInt8] {
        guard [x, y, sourceWidth, sourceHeight, x + sourceWidth, y + sourceHeight].allSatisfy(\.isFinite), sourceWidth > 0, sourceHeight > 0,
              width > 0, height > 0, width <= 4_194_304 / height else { throw ReadError.invalidGeometry }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let success = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(data: bytes.baseAddress,
                width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
            context.interpolationQuality = .low
            let sx = Double(width) / sourceWidth, sy = Double(height) / sourceHeight
#if os(iOS)
            // WebKit's CG image path keeps the full texture for a uniform reduction.
            // On iOS it aligns the adjusted destination origin AND size to device
            // pixels before flipping/drawing. Rounding the two endpoints instead
            // changes the extent at a half-pixel origin. This is source transport,
            // independent of palette thresholds or the requested crop position.
            // Float precision follows WebCore FloatRect and FloatSize arithmetic.
            let canvasSX = Float(width) / Float(sourceWidth)
            let canvasSY = Float(height) / Float(sourceHeight)
            // shouldUseSubimage multiplies Float rect dimensions by the
            // AffineTransform's Double scale before division. Its essential
            // equality predicate therefore uses Double epsilon; the adjusted
            // destination below separately retains FloatSize arithmetic.
            let deviceSX = Double(Float(width)) / Double(Float(sourceWidth))
            let deviceSY = Double(Float(height)) / Double(Float(sourceHeight))
            let delta = abs(deviceSX - deviceSY)
            let uniform = deviceSX == deviceSY ||
                (delta / abs(deviceSX) <= Double.ulpOfOne && delta / abs(deviceSY) <= Double.ulpOfOne)
            if uniform, canvasSX < 1, canvasSY < 1, x >= 0, y >= 0,
               x + sourceWidth <= Double(image.width), y + sourceHeight <= Double(image.height) {
                let left = Double((-Float(x) * canvasSX).rounded(.toNearestOrAwayFromZero))
                let top = Double((-Float(y) * canvasSY).rounded(.toNearestOrAwayFromZero))
                let extentWidth = Double((Float(image.width) * canvasSX).rounded(.toNearestOrAwayFromZero))
                let extentHeight = Double((Float(image.height) * canvasSY).rounded(.toNearestOrAwayFromZero))
                context.setShouldAntialias(false)
                context.draw(image, in: CGRect(x: left, y: Double(height) - top - extentHeight,
                    width: extentWidth, height: extentHeight))
                return true
            }
#endif
            // drawImage clamps its texture at the requested source crop. Drawing the
            // entire page leaks adjacent pixels into the first/last enlarged sample.
#if os(iOS)
            // enclosingIntRect receives a FloatRect. In particular maxY is
            // added in Float precision BEFORE ceil; promoting each operand to
            // Double first can recruit an extra source row at a Float ULP edge.
            let cropX = max(0, floor(Double(Float(x)))), cropY = max(0, floor(Double(Float(y))))
            let right = ceil(Double(Float(x) + Float(sourceWidth)))
            let bottom = ceil(Double(Float(y) + Float(sourceHeight)))
#else
            let cropX = max(0, floor(x)), cropY = max(0, floor(y))
            let right = ceil(x + sourceWidth), bottom = ceil(y + sourceHeight)
#endif
            // CGImage clips its backing pixels at the image edge. Canvas retains
            // the requested enclosing texture extent when mapping that clipped bitmap.
            guard right > cropX, bottom > cropY,
                  let cropped = image.cropping(to: CGRect(x: cropX, y: cropY, width: right - cropX, height: bottom - cropY)) else { return true }
#if os(iOS)
            // The same device-pixel alignment applies to an isolated texture
            // for anisotropic scaling and magnification. Keep origin and size
            // rounding separate, as roundedIntRect does on the Canvas context.
            let left = Double(((Float(cropX) - Float(x)) * canvasSX).rounded(.toNearestOrAwayFromZero))
            let top = Double(((Float(cropY) - Float(y)) * canvasSY).rounded(.toNearestOrAwayFromZero))
            let extentWidth = Double((Float(right - cropX) * canvasSX).rounded(.toNearestOrAwayFromZero))
            let extentHeight = Double((Float(bottom - cropY) * canvasSY).rounded(.toNearestOrAwayFromZero))
            context.setShouldAntialias(false)
            context.draw(cropped, in: CGRect(x: left, y: Double(height) - top - extentHeight,
                width: extentWidth, height: extentHeight))
#else
            context.draw(cropped, in: CGRect(x: (cropX - x) * sx, y: Double(height) - (bottom - y) * sy,
                width: (right - cropX) * sx, height: (bottom - cropY) * sy))
#endif
            return true
        }
        guard success else { throw ReadError.bitmapUnavailable }
        // Match the native BGRA Canvas bitmap path before exposing getImageData RGBA.
        // CoreGraphics RGBA storage selects a different interpolation rounding path.
        for offset in stride(from: 0, to: rgba.count, by: 4) { rgba.swapAt(offset, offset + 2) }
        // getImageData exposes unpremultiplied channels, unlike CGContext storage.
        // WebKit rounds positive half-channel values upward (e.g. 140*255/200=178.5 → 179).
        for offset in stride(from: 0, to: rgba.count, by: 4) where rgba[offset + 3] > 0 && rgba[offset + 3] < 255 {
            let alpha = Double(rgba[offset + 3])
            for channel in 0..<3 {
                rgba[offset + channel] = UInt8(min(255, max(0, (Double(rgba[offset + channel]) * 255 / alpha).rounded(.toNearestOrAwayFromZero))))
            }
        }
        return rgba
    }
}
