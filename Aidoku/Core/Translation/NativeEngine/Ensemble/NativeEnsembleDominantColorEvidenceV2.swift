import CoreGraphics
import Foundation

/// Source-only veto of surface-contaminated stroke dominance. Never changes original endpoint predictions.
enum NativeEnsembleDominantColorEvidenceV2 {
    static let defaults: [String: Double] = [
        "enabled": 1, "sampleSide": 384, "contextMarginPixels": 16, "endpointTolerance": 26,
        "plateauTolerance": 14, "minimumSeparation": 40, "minimumOffAxis": 22,
        "minimumHaloRun": 2, "minimumSurfaceRun": 2, "rayReach": 32, "maximumCoreSamples": 96,
        "minimumCorePixels": 6, "minimumCoreSpan": 4, "maximumCoreAreaFraction": 0.30,
        "minimumRepeatedCores": 2, "minimumSpatialTiles": 2, "minimumExteriorSides": 2,
        "minimumOpposedAxes": 1, "minimumBridgeFraction": 0.55, "maximumDirectShellFraction": 0.20,
        "useObservedHaloEndpoint": 0, "minimumHaloEndpointSamples": 8
    ]
    static let ranges: [String: ClosedRange<Double>] = [
        "enabled": 0...1, "sampleSide": 128...512, "contextMarginPixels": 8...32, "endpointTolerance": 12...40,
        "plateauTolerance": 8...22, "minimumSeparation": 28...64, "minimumOffAxis": 14...36,
        "minimumHaloRun": 1...3, "minimumSurfaceRun": 2...4, "rayReach": 12...64, "maximumCoreSamples": 32...256,
        "minimumCorePixels": 4...24, "minimumCoreSpan": 3...10, "maximumCoreAreaFraction": 0.15...0.45,
        "minimumRepeatedCores": 2...4, "minimumSpatialTiles": 2...4, "minimumExteriorSides": 2...3,
        "minimumOpposedAxes": 1...3, "minimumBridgeFraction": 0.40...0.80, "maximumDirectShellFraction": 0.05...0.30,
        "useObservedHaloEndpoint": 0...1, "minimumHaloEndpointSamples": 4...64
    ]
    struct Parameters {
        let values: [String: Double]
        init(_ values: [String: Double] = [:]) {
            self.values = defaults.reduce(into: [:]) { result, entry in
                let value = values[entry.key] ?? entry.value, range = ranges[entry.key]!
                result[entry.key] = min(range.upperBound, max(range.lowerBound, value.isFinite ? value : entry.value))
            }
        }
        subscript(_ key: String) -> Double { values[key]! }
    }
    struct RGB: Equatable {
        let r: Double, g: Double, b: Double
        init?(_ values: [Double]) {
            guard values.count == 3, values.allSatisfy({ $0.isFinite && (0...255).contains($0) }) else { return nil }
            r = values[0]; g = values[1]; b = values[2]
        }
        var array: [Double] { [r, g, b] }
        fileprivate func gap(_ other: RGB) -> Double { max(abs(r - other.r), abs(g - other.g), abs(b - other.b)) }
    }
    struct Prediction { let fill: RGB?; let stroke: RGB? }
    enum Role: String { case fill, stroke, unknown }
    struct Selection { let role: Role; let color: RGB? }
    /// Original RGBA only. ownership1=OCR-owned pixels,0=context; excluded pixels cannot vote or connect surfaces.
    struct SourceRaster {
        let rgba: [UInt8], ownership: [UInt8], excluded: [UInt8]
        let width: Int, height: Int
        init?(rgba: [UInt8], width: Int, height: Int, ownership: [UInt8], excluded: [UInt8]? = nil) {
            guard width >= 8, height >= 8, width <= 262144 / height, rgba.count == width * height * 4,
                  ownership.count == width * height, ownership.allSatisfy({ $0 <= 1 }),
                  excluded == nil || excluded?.count == ownership.count else { return nil }
            self.rgba = rgba; self.width = width; self.height = height; self.ownership = ownership
            self.excluded = excluded ?? [UInt8](repeating: 0, count: ownership.count)
        }
    }
    struct Evidence {
        fileprivate(set) var measured = false
        fileprivate(set) var technicalError: String?
        fileprivate(set) var ownedPixels = 0
        fileprivate(set) var coreComponents = 0
        fileprivate(set) var sampledCores = 0
        fileprivate(set) var testedOrigins = 0
        fileprivate(set) var testedRays = 0
        fileprivate(set) var bridgeRays = 0
        fileprivate(set) var directShellRays = 0
        fileprivate(set) var supportedComponents = 0
        fileprivate(set) var spatialTiles = 0
        fileprivate(set) var exteriorSides = 0
        fileprivate(set) var connectedSurfacePixels = 0
        fileprivate(set) var haloSamples = 0
        fileprivate(set) var observedInterveningHalo: RGB?
        fileprivate init() {}
        var bridgeFraction: Double { Double(bridgeRays) / Double(max(1, testedRays)) }
        var directShellFraction: Double { Double(directShellRays) / Double(max(1, bridgeRays + directShellRays)) }
        var audit: [String: Any] {
            guard measured else { return ["originalPixelsMeasured": false, "technicalError": technicalError as Any? ?? NSNull()] }
            return ["originalPixelsMeasured": true, "technicalError": technicalError as Any? ?? NSNull(), "ownedPixels": ownedPixels,
             "coreComponents": coreComponents, "sampledCores": sampledCores, "testedOrigins": testedOrigins,
             "testedRays": testedRays, "bridgeRays": bridgeRays, "directShellRays": directShellRays,
             "supportedComponents": supportedComponents, "spatialTiles": spatialTiles, "exteriorSides": exteriorSides,
             "connectedSurfacePixels": connectedSurfacePixels, "bridgeFraction": bridgeFraction,
             "directShellFraction": directShellFraction, "haloSamples": haloSamples,
             "observedInterveningHalo": observedInterveningHalo?.array as Any? ?? NSNull(),
             "authority": "owned original core/intervening plateau/exterior-connected candidate topology; proxy, not gold"]
        }
    }
    enum Action: String { case preservePrior, rejectSurfaceDominance }
    struct Decision {
        let prediction: Prediction
        let prior: Selection
        let selected: Selection
        let action: Action
        let evidence: Evidence
        let reason: String
        var requiresDisplayStrokeReselection: Bool { action == .rejectSurfaceDominance }
        var audit: [String: Any] {
            ["action": action.rawValue, "reason": reason, "sourcePredictionsChanged": false,
             "predictedFill": prediction.fill?.array as Any? ?? NSNull(),
             "predictedStroke": prediction.stroke?.array as Any? ?? NSNull(),
             "priorRole": prior.role.rawValue, "priorInk": prior.color?.array as Any? ?? NSNull(),
             "selectedRole": selected.role.rawValue, "selectedInk": selected.color?.array as Any? ?? NSNull(),
             "requiresDisplayStrokeReselection": requiresDisplayStrokeReselection, "evidence": evidence.audit]
        }
    }
    private struct Part { let pixels: [Int]; let stable: [Int] }
    private struct Ray { let kind: Int; let halo: RGB? } //0 unknown,1 direct shell,2 bridge to connected surface
    private static func segmentError(_ c: RGB, _ a: RGB, _ b: RGB) -> Double {
        let dr = b.r - a.r, dg = b.g - a.g, db = b.b - a.b
        let length = max(1, dr * dr + dg * dg + db * db)
        let t = max(0, min(1, ((c.r - a.r) * dr + (c.g - a.g) * dg + (c.b - a.b) * db) / length))
        return max(abs(c.r - a.r - t * dr), abs(c.g - a.g - t * dg), abs(c.b - a.b - t * db))
    }
    static func measure(_ raster: SourceRaster, prediction: Prediction, parameters p: Parameters = Parameters()) -> Evidence {
        var e = Evidence()
        guard let fill = prediction.fill, let stroke = prediction.stroke,
              fill.gap(stroke) >= p["minimumSeparation"] else { e.technicalError = "missing or inseparable original endpoints"; return e }
        e.measured = true
        let w = raster.width, h = raster.height, count = w * h
        let tolerance = p["endpointTolerance"], plateau = p["plateauTolerance"]
        let colors: [RGB] = (0..<count).map { i in
            let alpha = Double(raster.rgba[i * 4 + 3]), scale = alpha > 0 ? 255 / alpha : 0
            return RGB((0..<3).map { min(255, Double(raster.rgba[i * 4 + $0]) * scale) })!
        }
        let visible = (0..<count).map { raster.excluded[$0] == 0 && raster.rgba[$0 * 4 + 3] >= 250 }
        let owned = (0..<count).map { visible[$0] && raster.ownership[$0] == 1 }
        e.ownedPixels = owned.filter { $0 }.count
        let candidate = (0..<count).map { visible[$0] && colors[$0].gap(stroke) <= tolerance }
        var connected = [Bool](repeating: false, count: count), queue: [Int] = [], sides = [Int](repeating: 0, count: 4)
        for i in 0..<count where candidate[i] && !owned[i] {
            let x = i % w, y = i / w
            if x == 0 { sides[0] += 1 }; if x == w - 1 { sides[1] += 1 }
            if y == 0 { sides[2] += 1 }; if y == h - 1 { sides[3] += 1 }
            if x == 0 || x == w - 1 || y == 0 || y == h - 1 { connected[i] = true; queue.append(i) }
        }
        var cursor = 0
        while cursor < queue.count {
            let i = queue[cursor]; cursor += 1
            let x = i % w, y = i / w
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && nx < w && ny >= 0 && ny < h {
                let j = ny * w + nx
                if candidate[j] && !connected[j] { connected[j] = true; queue.append(j) }
            }
        }
        e.exteriorSides = sides.filter { $0 >= Int(p["minimumSurfaceRun"]) }.count
        e.connectedSurfacePixels = queue.count
        let core = (0..<count).map { owned[$0] && colors[$0].gap(fill) <= tolerance }
        var seen = [Bool](repeating: false, count: count), parts: [Part] = []
        for seed in 0..<count where core[seed] && !seen[seed] {
            var members = [seed], index = 0, stable: [Int] = []
            var left = seed % w, right = left, top = seed / w, bottom = top, touchesOwnerEdge = false
            seen[seed] = true
            while index < members.count {
                let i = members[index]; index += 1
                let x = i % w, y = i / w
                left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
                var neighbors = 0
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                    guard nx >= 0, nx < w, ny >= 0, ny < h else { touchesOwnerEdge = true; continue }
                    let j = ny * w + nx
                    if !owned[j] { touchesOwnerEdge = true }
                    if core[j] {
                        neighbors += 1
                        if !seen[j] { seen[j] = true; members.append(j) }
                    }
                }
                if neighbors >= 2 { stable.append(i) }
            }
            if !touchesOwnerEdge, stable.count >= Int(p["minimumCorePixels"]),
               max(right - left + 1, bottom - top + 1) >= Int(p["minimumCoreSpan"]),
               Double(members.count) <= Double(e.ownedPixels) * p["maximumCoreAreaFraction"] {
                parts.append(Part(pixels: members, stable: stable))
            }
        }
        e.coreComponents = parts.count
        let directions = [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, -1), (1, -1), (-1, 1)]
        func ray(_ origin: Int, _ dx: Int, _ dy: Int) -> Ray {
            var samples: [Int] = [], leftCore = false
            for d in 1...Int(p["rayReach"]) {
                let x = origin % w + dx * d, y = origin / w + dy * d
                guard x >= 0, x < w, y >= 0, y < h else { break }
                let i = y * w + x
                guard visible[i] else { break }
                if !leftCore && colors[i].gap(fill) <= tolerance { continue }
                leftCore = true; samples.append(i)
            }
            var halo: RGB?, haloRun = 0, surfaceRun = 0, previous: RGB?
            for i in samples {
                let c = colors[i]
                if c.gap(stroke) <= tolerance {
                    surfaceRun += 1
                    if surfaceRun >= Int(p["minimumSurfaceRun"]) {
                        if let halo { return connected[i] ? Ray(kind: 2, halo: halo) : Ray(kind: 0, halo: nil) }
                        if halo == nil { return Ray(kind: 1, halo: nil) }
                    }
                    continue
                }
                surfaceRun = 0
                if let halo {
                    if c.gap(halo) > plateau * 2 && segmentError(c, halo, stroke) > plateau { return Ray(kind: 0, halo: nil) }
                } else if c.gap(fill) >= p["minimumSeparation"], c.gap(stroke) >= p["minimumSeparation"],
                          segmentError(c, fill, stroke) >= p["minimumOffAxis"] {
                    haloRun = previous.map { c.gap($0) <= plateau ? haloRun + 1 : 1 } ?? 1
                    previous = c
                    if haloRun >= Int(p["minimumHaloRun"]) { halo = c }
                } else { haloRun = 0; previous = nil }
            }
            return Ray(kind: 0, halo: nil)
        }
        var supported = Set<Int>(), tiles = Set<Int>(), haloColors: [RGB] = []
        let componentBudget = min(parts.count, Int(p["maximumCoreSamples"]))
        let perCore = max(1, Int(p["maximumCoreSamples"]) / max(1, componentBudget))
        for slot in 0..<componentBudget {
            let ci = slot * parts.count / componentBudget
            let stable = parts[ci].stable
            for offset in stride(from: 0, to: stable.count, by: max(1, Int(ceil(Double(stable.count) / Double(perCore))))) {
                let i = stable[offset]
                let rays = directions.map { ray(i, $0.0, $0.1) }
                e.testedOrigins += 1; e.testedRays += rays.count
                e.bridgeRays += rays.filter { $0.kind == 2 }.count
                e.directShellRays += rays.filter { $0.kind == 1 }.count
                let opposed = (0..<4).filter { axis in
                    let a = rays[axis * 2], b = rays[axis * 2 + 1]
                    return a.kind == 2 && b.kind == 2 && a.halo!.gap(b.halo!) <= plateau * 2
                }.count
                if opposed >= Int(p["minimumOpposedAxes"]) {
                    supported.insert(ci); tiles.insert(((i / w) * 6 / h) * 6 + (i % w) * 6 / w)
                    haloColors.append(contentsOf: rays.compactMap { $0.kind == 2 ? $0.halo : nil })
                }
            }
        }
        e.sampledCores = componentBudget; e.supportedComponents = supported.count; e.spatialTiles = tiles.count
        e.haloSamples = haloColors.count
        if !haloColors.isEmpty {
            let n = Double(haloColors.count)
            e.observedInterveningHalo = RGB([haloColors.reduce(0) { $0 + $1.r } / n,
                haloColors.reduce(0) { $0 + $1.g } / n, haloColors.reduce(0) { $0 + $1.b } / n])
        }
        return e
    }
    static func decide(prediction: Prediction, prior: Selection, evidence: Evidence,
                       parameters p: Parameters = Parameters()) -> Decision {
        var reason = "insufficient independent original topology; preserve prior ink"
        let matchesPrior = prior.role == .stroke && prior.color != nil && prediction.stroke != nil &&
            prior.color!.gap(prediction.stroke!) <= p["endpointTolerance"]
        let reject = p["enabled"] > 0 && evidence.technicalError == nil && matchesPrior && prediction.fill != nil &&
            evidence.exteriorSides >= Int(p["minimumExteriorSides"]) &&
            evidence.supportedComponents >= Int(p["minimumRepeatedCores"]) && evidence.spatialTiles >= Int(p["minimumSpatialTiles"]) &&
            evidence.bridgeFraction >= p["minimumBridgeFraction"] && evidence.directShellFraction <= p["maximumDirectShellFraction"]
        if reject { reason = "repeated core -> independent halo -> exterior-connected candidate; candidate rejected as dominant ink only" }
        else if p["enabled"] == 0 { reason = "disabled; preserve prior" }
        else if !matchesPrior { reason = "prior ink is not the predicted stroke; no dominance override" }
        else if evidence.directShellFraction > p["maximumDirectShellFraction"] { reason = "direct core-to-stroke support; preserve true inverse/bold outline" }
        return Decision(prediction: prediction, prior: prior, selected: reject ? Selection(role: .fill, color: prediction.fill) : prior,
            action: reject ? .rejectSurfaceDominance : .preservePrior, evidence: evidence, reason: reason)
    }
    /// Bounded original-only crop. Context is required; RF boxes/polygons never replace OCR pixel ownership.
    static func capture(original: CGImage, owner: CGRect, polygon: [CGPoint] = [], excludedOwners: [CGRect] = [],
                        parameters p: Parameters = Parameters()) -> SourceRaster? {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard !owner.isNull, !owner.isInfinite, owner.width > 0, owner.height > 0, unit.contains(owner),
              polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }), polygon.isEmpty || polygon.count >= 3 else { return nil }
        let iw = Double(original.width), ih = Double(original.height)
        let box = CGRect(x: owner.minX * iw, y: owner.minY * ih, width: owner.width * iw, height: owner.height * ih)
        let crop = box.insetBy(dx: -p["contextMarginPixels"], dy: -p["contextMarginPixels"]).integral
            .intersection(CGRect(x: 0, y: 0, width: iw, height: ih))
        let scale = min(1, p["sampleSide"] / max(crop.width, crop.height))
        let w = max(1, Int(floor(crop.width * scale))), h = max(1, Int(floor(crop.height * scale)))
        guard w >= 8, h >= 8, let image = original.cropping(to: crop) else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let c = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                    CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            c.interpolationQuality = .none; c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
        }
        guard ok else { return nil }
        let path = CGMutablePath()
        if !polygon.isEmpty { path.addLines(between: polygon); path.closeSubpath() }
        var owned = [UInt8](repeating: 0, count: w * h), excluded = owned
        for y in 0..<h { for x in 0..<w {
            let q = CGPoint(x: (crop.minX + (Double(x) + 0.5) * crop.width / Double(w)) / iw,
                            y: (crop.minY + (Double(y) + 0.5) * crop.height / Double(h)) / ih)
            owned[y * w + x] = owner.contains(q) && (polygon.isEmpty || path.contains(q)) ? 1 : 0
            excluded[y * w + x] = excludedOwners.contains(where: { $0.contains(q) }) ? 1 : 0
        } }
        return SourceRaster(rgba: bytes, width: w, height: h, ownership: owned, excluded: excluded)
    }
    static func evaluate(original: CGImage, owner: CGRect, polygon: [CGPoint] = [], excludedOwners: [CGRect] = [],
                         prediction: Prediction, prior: Selection, parameters p: Parameters = Parameters()) -> Decision {
        var e = Evidence()
        if p["enabled"] > 0 {
            if let raster = capture(original: original, owner: owner, polygon: polygon, excludedOwners: excludedOwners, parameters: p) {
                e = measure(raster, prediction: prediction, parameters: p)
            } else { e.technicalError = "original crop/ownership unavailable; no source evidence" }
        }
        return decide(prediction: prediction, prior: prior, evidence: e, parameters: p)
    }

    enum Failure: Error { case invalidStrokePolicy }
    /// Display-only source witness. An observed third plateau does not overwrite
    /// the independent source-stroke predictor. Prefer its nearest BW endpoint
    /// only if that endpoint meets the unchanged parent fill/stroke contrast gate.
    static func haloEndpoint(fill: RGB, observedHalo: RGB, minimumContrast: Double) -> (stroke: [Double], contrast: Double)? {
        guard minimumContrast.isFinite, (3...4.5).contains(minimumContrast) else { return nil }
        let black = RGB([0, 0, 0])!, white = RGB([255, 255, 255])!
        let chosen = observedHalo.gap(white) < observedHalo.gap(black) ? white : black
        func luminance(_ c: RGB) -> Double {
            let a = c.array.map { $0 / 255 }.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return a[0] * 0.2126 + a[1] * 0.7152 + a[2] * 0.0722
        }
        let a = luminance(fill), b = luminance(chosen)
        let contrast = (max(a, b) + 0.05) / (min(a, b) + 0.05)
        return contrast + 1e-12 >= minimumContrast ? (chosen.array, contrast) : nil
    }
    private static func endpoint(_ value: Any?) -> RGB? {
        guard let values = value as? [Double] else { return nil }; return RGB(values)
    }
    private static func ownerRect(_ value: Any?) -> CGRect? {
        guard let a = value as? [Double], a.count == 4, a.allSatisfy(\.isFinite), a[2] > 0, a[3] > 0 else { return nil }
        return CGRect(x: a[0], y: a[1], width: a[2], height: a[3])
    }
    /// Parent calls AFTER original palette annotation and BEFORE final BW selection/shaping.
    /// The witness runs for a confident existing stroke choice too; nil neutralShellEvidence is not negative evidence.
    static func apply(_ page: Ensemble100Page, parameters: [String: Double],
                      strokeParameters: [String: Double]) throws -> Ensemble100Proposal {
        let p = Parameters(parameters)
        guard p["enabled"] > 0 else { return Ensemble100Proposal(items: page.items, audit: ["dominantColorEvidenceV2": "disabled"]) }
        guard let floor = strokeParameters["minimumFillStrokeContrast"], floor.isFinite, (3...4.5).contains(floor),
              strokeParameters["enabled"] != 0 else { throw Failure.invalidStrokePolicy }
        var items = page.items, records: [[String: Any]] = [], changed: [Int] = [], decisions: [Decision] = []
        for i in page.items.indices {
            let item = page.items[i], source = item["ensemblePaletteAudit"] as? [String: Any] ?? [:]
            let prediction = Prediction(fill: endpoint(source["sourceFill"]), stroke: endpoint(source["sourceStroke"]))
            let role = source["selectedRole"] as? String ?? "unknown"
            let isStroke = ["sourceStroke", "source-stroke", "sourceStrokeOnly"].contains(role)
            let prior = Selection(role: isStroke ? .stroke : .unknown, color: endpoint(item["ensembleDisplayFill"]))
            var decision = decide(prediction: prediction, prior: prior, evidence: Evidence(), parameters: p)
            if isStroke, let color = prior.color, let stroke = prediction.stroke,
               color.gap(stroke) <= p["endpointTolerance"], let owner = ownerRect(item["sourceBounds"]),
               item["keptLettering"] as? Bool != true, item["sourceTextOnly"] as? Bool != true {
                let pairs = item["sourcePolygon"] as? [[Double]] ?? []
                let validPolygonType = item["sourcePolygon"] == nil || item["sourcePolygon"] is NSNull || item["sourcePolygon"] is [[Double]]
                if validPolygonType && (pairs.isEmpty || pairs.count >= 3) && pairs.count <= 1024 &&
                    pairs.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) {
                    let polygon = pairs.map { CGPoint(x: $0[0], y: $0[1]) }
                    let excluded = page.items.enumerated().compactMap { j, other in j == i ? nil : ownerRect(other["sourceBounds"]) }
                    decision = evaluate(original: page.original, owner: owner, polygon: polygon,
                        excludedOwners: excluded, prediction: prediction, prior: prior, parameters: p)
                } else {
                    var error = Evidence(); error.technicalError = "invalid original source polygon; source ownership unavailable"
                    decision = decide(prediction: prediction, prior: prior, evidence: error, parameters: p)
                }
            } else if isStroke && ownerRect(item["sourceBounds"]) == nil {
                var error = Evidence(); error.technicalError = "missing or invalid normalized sourceBounds; original witness not measured"
                decision = decide(prediction: prediction, prior: prior, evidence: error, parameters: p)
            }
            var record = decision.audit
            record["index"] = i; record["id"] = item["id"] ?? i
            record["priorSelectionWasPresent"] = prior.color != nil
            record["neutralShellEvidenceUse"] = "null is not negative evidence; this independent chromatic/neutral witness is not nil-gated"
            record["rfSupportQueries"] = page.rfRegions.filter { region in
                guard region.classID == 0 || region.classID == 1, region.confidence.isFinite, region.confidence >= 0.4,
                      let box = ownerRect(item["sourceBounds"]) else { return false }
                return region.bounds.intersects(box)
            }.map(\.queryID)
            record["rfAuthority"] = "supporting model regions only; not glyph masks or exterior surface truth"
            if decision.action == .rejectSurfaceDominance {
                items[i]["ensembleDisplayFill"] = decision.selected.color!.array
                changed.append(i)
            }
            items[i]["ensembleDominantColorEvidenceV2Audit"] = record
            records.append(record)
            decisions.append(decision)
        }
        if !changed.isEmpty {
            let revised = Ensemble100Page(sourceSHA256: page.sourceSHA256, original: page.original, restored: page.restored,
                removalMask: page.removalMask, viewport: page.viewport, items: items, rfRegions: page.rfRegions, savedEvidence: page.savedEvidence)
            let reselection = try EnsembleCandidate07Next.apply(revised, parameters: strokeParameters)
            // Geometry/peers are provided to the existing policy, but unrelated items retain their exact original paint decisions.
            for i in changed {
                items[i] = reselection.items[i]
                let evidence = decisions[i].evidence
                if p["useObservedHaloEndpoint"] > 0, evidence.measured,
                   evidence.haloSamples >= Int(p["minimumHaloEndpointSamples"]),
                   let halo = evidence.observedInterveningHalo,
                   let fill = endpoint(items[i]["ensembleDisplayFill"]),
                   let preferred = haloEndpoint(fill: fill, observedHalo: halo, minimumContrast: floor) {
                    var audit = items[i]["ensembleStrokeAudit"] as? [String: Any] ?? [:]
                    var paint = items[i]["ensembleStrokePaintPolicy"] as? [String: Any] ?? [:]
                    let previous = items[i]["ensembleDisplayStroke"]
                    items[i]["ensembleDisplayStroke"] = preferred.stroke
                    audit["strokeBeforeObservedHaloPreference"] = previous ?? NSNull()
                    audit["selectedStroke"] = preferred.stroke
                    audit["actualChosenFillStrokeContrast"] = preferred.contrast
                    audit["decision"] = "independent original intervening halo selects eligible BW endpoint; background score cannot override this measured display witness"
                    audit["observedHaloEndpointPreference"] = ["observedHalo": halo.array,
                        "samples": evidence.haloSamples, "sourcePredictionsChanged": false,
                        "minimumFillStrokeContrast": floor, "displayEvidenceNotSourceStrokeGold": true] as [String: Any]
                    paint["actualChosenFillStrokeContrast"] = preferred.contrast
                    paint["endpointContrastEligible"] = true
                    audit["paintPolicy"] = paint
                    items[i]["ensembleStrokePaintPolicy"] = paint
                    items[i]["ensembleStrokeAudit"] = audit
                }
            }
        }
        return Ensemble100Proposal(items: items, audit: ["dominantColorEvidenceV2": records,
            "inputItems": page.items.count, "outputItems": items.count, "displayInkChanges": changed.count,
            "sourcePredictionsChanged": false, "contrastPolicyChanged": false, "actualImagesInspected": 0])
    }
}
