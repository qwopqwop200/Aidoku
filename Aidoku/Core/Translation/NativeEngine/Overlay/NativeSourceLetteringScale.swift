import Foundation

/// Diagnostic typography evidence in input-raster pixels. Never a font-size GT,
/// source-removal mask, OCR decision, or permission to alter original pixels.
enum NativeSourceLetteringScale {
    struct ProxySelection {
        let value: Double?
        let provenance: String
        let fallbackReason: String?
    }

    static func selectProxy(record: [String: Any]?, forecast: Double?, requested: Double) -> ProxySelection {
        if let record, record["supported"] as? Bool == true,
           record["logicalUnits"] as? String == "logical-page-units",
           let observed = record["logicalCrossSpan"] as? Double, observed.isFinite, observed > 0 {
            return .init(value: observed, provenance: "observed owned source cross-ink proxy", fallbackReason: nil)
        }
        let reason = record?["unknownReason"] as? String ?? "source-observation-unavailable"
        if let forecast, forecast.isFinite, forecast > 0 {
            return .init(value: forecast, provenance: "saved sourceFontSize forecast fallback", fallbackReason: reason)
        }
        return .init(value: requested.isFinite && requested > 0 ? requested : nil,
            provenance: "requested font fallback estimate", fallbackReason: reason)
    }

    /// Separate observation transport. The immutable source forecast is not an
    /// input/output of these conversions. Source writing direction selects the
    /// cross axis even when translated typography is horizontal.
    static func originalTransport(observation: Observation, sourceVertical: Bool,
                                  sampleWidth: Int, sampleHeight: Int,
                                  croppedSourceWidth: Double, croppedSourceHeight: Double,
                                  croppedSourceX: Double = 0, croppedSourceY: Double = 0) -> [String: Any] {
        var result = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(observation))) as? [String: Any] ?? [:]
        result["sourceVertical"] = sourceVertical
        result["sampleDimensions"] = [sampleWidth, sampleHeight]
        result["croppedOriginalDimensions"] = [croppedSourceWidth, croppedSourceHeight]
        result["croppedOriginalOrigin"] = [croppedSourceX, croppedSourceY]
        result["supported"] = false
        let sampleCross = Double(sourceVertical ? sampleWidth : sampleHeight)
        let originalCross = sourceVertical ? croppedSourceWidth : croppedSourceHeight
        guard sampleCross.isFinite, sampleCross > 0, originalCross.isFinite, originalCross > 0,
              observation.units == "sample-pixels", observation.unknownReason == nil,
              let span = observation.pixelAdvanceProxy, span.isFinite, span > 0,
              observation.confidence >= 0.5 else {
            result["unknownReason"] = observation.unknownReason ?? "insufficient-observation-quality-or-transform"
            return result
        }
        let scale = originalCross / sampleCross, converted = span * scale
        guard converted.isFinite, converted > 0 else { result["unknownReason"] = "invalid-original-cross-transform"; return result }
        result["supported"] = true
        result["sampleToOriginalCrossScale"] = scale
        result["originalPixelCrossSpan"] = converted
        result["originalUnits"] = "original-source-pixels"
        let sampleAlong = Double(sourceVertical ? sampleHeight : sampleWidth)
        let originalAlong = sourceVertical ? croppedSourceHeight : croppedSourceWidth
        let originAlong = sourceVertical ? croppedSourceY : croppedSourceX
        if sampleAlong > 0, originalAlong.isFinite, originalAlong > 0, originAlong.isFinite,
           let inkStart = observation.lanes.map(\.bodyInkAlongStart).min() {
            result["originalAlongInkStart"] = originAlong + Double(inkStart) * originalAlong / sampleAlong
            result["originalAlongInkStartUnits"] = "original-source-pixels"
            let originCross = sourceVertical ? croppedSourceX : croppedSourceY
            result["originalLaneEvidence"] = observation.lanes.map { lane -> [String: Any] in
                ["crossAxis": lane.crossAxis, "alongAxis": lane.alongAxis,
                 "crossStart": originCross + Double(lane.crossStart) * scale,
                 "crossEnd": originCross + Double(lane.crossEnd) * scale,
                 "bodyInkAlongStart": originAlong + Double(lane.bodyInkAlongStart) * originalAlong / sampleAlong,
                 "bodyInkAlongEnd": originAlong + Double(lane.bodyInkAlongEnd) * originalAlong / sampleAlong,
                 "supportedRows": lane.supportedRows, "confidence": lane.confidence,
                 "authority": "owned observed ink support; not exact glyph top or baseline",
                 "units": "original-source-pixels"]
            }
        }
        return result
    }

    /// The sampling stage receives the bounded restoration raster, not always
    /// the full declared image. Restore its coordinate reference before a
    /// caller converts original pixels to logical page units.
    static func restorationTransport(record: [String: Any], sourceVertical: Bool,
                                     capturedWidth: Double, capturedHeight: Double,
                                     originalWidth: Double, originalHeight: Double) -> [String: Any] {
        var result = record
        result["capturedSourceRasterDimensions"] = [capturedWidth, capturedHeight]
        result["declaredOriginalDimensions"] = [originalWidth, originalHeight]
        guard [capturedWidth, capturedHeight, originalWidth, originalHeight].allSatisfy({ $0.isFinite && $0 > 0 }),
              record["supported"] as? Bool == true,
              record["sourceVertical"] as? Bool == sourceVertical,
              let span = record["originalPixelCrossSpan"] as? Double, span.isFinite, span > 0 else {
            result["supported"] = false
            result["unknownReason"] = record["unknownReason"] ?? "invalid-captured-to-original-transform"
            return result
        }
        let sx = originalWidth / capturedWidth, sy = originalHeight / capturedHeight
        let cross = sourceVertical ? sx : sy, along = sourceVertical ? sy : sx
        guard [sx, sy, span * cross].allSatisfy({ $0.isFinite && $0 > 0 }) else {
            result["supported"] = false
            result["unknownReason"] = "overflowing-captured-to-original-transform"
            return result
        }
        result["capturedToOriginalScale"] = [sx, sy]
        result["originalPixelCrossSpan"] = span * cross
        if let scale = record["sampleToOriginalCrossScale"] as? Double {
            result["sampleToOriginalCrossScale"] = scale * cross
        }
        for key in ["croppedOriginalOrigin", "croppedOriginalDimensions"] {
            if let values = record[key] as? [Double], values.count == 2 {
                result["capturedRaster" + key.prefix(1).uppercased() + key.dropFirst()] = values
                result[key] = [values[0] * sx, values[1] * sy]
            }
        }
        if let top = record["originalAlongInkStart"] as? Double { result["originalAlongInkStart"] = top * along }
        if let lanes = record["originalLaneEvidence"] as? [[String: Any]] {
            result["originalLaneEvidence"] = lanes.map { lane in
                var mapped = lane
                for key in ["crossStart", "crossEnd"] {
                    if let value = lane[key] as? Double { mapped[key] = value * cross }
                }
                for key in ["bodyInkAlongStart", "bodyInkAlongEnd"] {
                    if let value = lane[key] as? Double { mapped[key] = value * along }
                }
                return mapped
            }
        }
        result["coordinateAuthority"] = "captured restoration raster mapped to declared original; observed proxy, not font truth"
        return result
    }

    static func logicalTransport(record: [String: Any], sourceVertical: Bool,
                                 originalCrossLength: Double, logicalCrossLength: Double) -> [String: Any] {
        var result = record
        result["supported"] = false
        guard record["supported"] as? Bool == true,
              record["sourceVertical"] as? Bool == sourceVertical,
              record["originalUnits"] as? String == "original-source-pixels",
              let span = record["originalPixelCrossSpan"] as? Double, span.isFinite, span > 0,
              originalCrossLength.isFinite, originalCrossLength > 0,
              logicalCrossLength.isFinite, logicalCrossLength > 0 else {
            result["unknownReason"] = record["unknownReason"] ?? "unsupported-original-observation-or-logical-transform"
            return result
        }
        let scale = logicalCrossLength / originalCrossLength, converted = span * scale
        guard converted.isFinite, converted > 0 else { result["unknownReason"] = "invalid-logical-cross-transform"; return result }
        result["supported"] = true
        result["originalToLogicalCrossScale"] = scale
        result["logicalCrossSpan"] = converted
        result["logicalUnits"] = "logical-page-units"
        return result
    }
    struct QualityThresholds: Codable, Equatable, Sendable {
        let maximumSamplePixels: Int
        let maximumDimension: Int
        let colourTolerance: Double
        let minimumColourSeparation: Double
        let minimumOpaqueAlpha: UInt8
        let minimumStrokeMatches: Int
        let minimumFillMatches: Int
        let maximumStrokeOwnerFraction: Double
        let bodyEvidenceWorkPerSamplePixel: Int
        let maximumCoreComponents: Int
        let coreStrokeNeighbourRadius: Int
        let maximumLanes: Int
        let minimumBodyEnvelopeFraction: Double
        let maximumNearEnvelopeDeviation: Double
        let maximumAggregateLaneRatio: Double
        let projectionAlongDivisor: Int
        let minimumProjectionMatches: Int
        let bodySupportEnvelopeFraction: Double
        let minimumRowInk: Int
        let compactMinimumAspect: Double
        let compactMaximumAspect: Double
        let compactMinimumDensity: Double
        let confidenceCap: Double
        let edgeConfidenceFactor: Double
        let maximumCoreOwnerFraction: Double
        let minimumRepeatedBodies: Int
        let minimumBodyHeightToCross: Double
        let maximumBodyHeightToCross: Double
        let maximumBodyGapFraction: Double
    }
    static let qualityThresholds = QualityThresholds(maximumSamplePixels: 262_144, maximumDimension: 4096,
        colourTolerance: 12, minimumColourSeparation: 32, minimumOpaqueAlpha: 250,
        minimumStrokeMatches: 12, minimumFillMatches: 6, maximumStrokeOwnerFraction: 0.65,
        bodyEvidenceWorkPerSamplePixel: 4, maximumCoreComponents: 4096, coreStrokeNeighbourRadius: 2, maximumLanes: 32,
        minimumBodyEnvelopeFraction: 0.6,
        maximumNearEnvelopeDeviation: 0.25, maximumAggregateLaneRatio: 1.25,
        projectionAlongDivisor: 100, minimumProjectionMatches: 2, bodySupportEnvelopeFraction: 0.65,
        minimumRowInk: 3, compactMinimumAspect: 0.7, compactMaximumAspect: 1.4,
        compactMinimumDensity: 0.65, confidenceCap: 0.9, edgeConfidenceFactor: 0.7,
        maximumCoreOwnerFraction: 0.25, minimumRepeatedBodies: 3,
        minimumBodyHeightToCross: 0.6, maximumBodyHeightToCross: 2.5, maximumBodyGapFraction: 0.2)

    struct GlyphBody: Codable, Equatable, Sendable {
        let crossStart: Int
        let crossEnd: Int
        let alongStart: Int
        let alongEnd: Int
        let coreFillPixels: Int
    }

    struct Lane: Codable, Equatable, Sendable {
        let crossAxis: String // Original raster x/y, independent of translated text.
        let alongAxis: String
        let crossStart: Int
        let crossEnd: Int // Exclusive; x for vertical lettering, y for horizontal.
        let alongStart: Int
        let alongEnd: Int
        let bodyInkAlongStart: Int
        let bodyInkAlongEnd: Int
        let pixelAdvanceProxy: Double
        let confidence: Double
        let supportedRows: Int
        let nearEnvelopeRows: Int
        let bodyScanlineWidth80th: Double
        let supportedInkPixels: Int
        let edgeLimited: Bool
        let coreFillPixels: Int
        let repeatedGlyphBodies: Int
        let bodyAlongHeightMedian: Double
        let strokeEnvelopeCrossSpan: Double
        let glyphBodies: [GlyphBody]
    }

    struct Observation: Codable, Equatable, Sendable {
        let units: String
        let confidenceAuthority: String
        let qualityThresholds: QualityThresholds
        let pixelAdvanceProxy: Double?
        let lanes: [Lane]
        let confidence: Double
        let method: String
        let unknownReason: String?
        let ignoredCompactBands: Int
    }

    private static let method = "owned-core-fill-repeated-glyph-body-cross-span-v2"
    private static func unknown(_ reason: String, lanes: [Lane] = [], ignored: Int = 0) -> Observation {
        .init(units: "sample-pixels", confidenceAuthority: "heuristic evidence score; uncalibrated",
              qualityThresholds: qualityThresholds, pixelAdvanceProxy: nil, lanes: lanes, confidence: 0, method: method,
              unknownReason: reason, ignoredCompactBands: ignored)
    }

    /// RGBA8 is opaque, unpremultiplied (or opaque premultiplied) sRGB. Ownership
    /// is one byte per pixel, exactly 0/1, in the SAME top-left raster. RGBs must
    /// be independently observed source endpoints, never boosted display RGBs.
    /// No source text, page identity, expected font size, or peer median enters.
    static func observe(rgba: [UInt8], width: Int, height: Int, ownership: [UInt8],
                        fill: [Double], stroke: [Double], sourceVertical: Bool) -> Observation {
        let q = qualityThresholds
        guard width > 0, height > 0, width <= q.maximumDimension, height <= q.maximumDimension,
              width <= q.maximumSamplePixels / height else { return unknown("invalid-or-unbounded-raster") }
        let count = width * height
        guard rgba.count == count * 4, ownership.count == count,
              ownership.allSatisfy({ $0 <= 1 }), ownership.contains(1),
              fill.count == 3, stroke.count == 3,
              (fill + stroke).allSatisfy({ $0.isFinite && (0...255).contains($0) })
        else { return unknown("invalid-ownership-or-endpoints") }
        let separation = zip(fill, stroke).map { abs($0 - $1) }.max()!
        guard separation == 0 || separation >= q.minimumColourSeparation else { return unknown("unresolved-colour-pair") }
        let cross = sourceVertical ? width : height
        let along = sourceVertical ? height : width
        var ink = [UInt8](repeating: 0, count: count)
        var fillHits = ink, owned = ink
        var inkCount = 0, fillCount = 0, ownedCount = 0
        for y in 0..<along {
            for x in 0..<cross {
                let physical = sourceVertical ? y * width + x : x * width + y
                guard ownership[physical] == 1 else { continue }
                let offset = physical * 4, index = y * cross + x
                guard rgba[offset + 3] >= q.minimumOpaqueAlpha else { return unknown("nonopaque-owned-pixels") }
                owned[index] = 1; ownedCount += 1
                func matches(_ rgb: [Double]) -> Bool {
                    (0..<3).allSatisfy { abs(Double(rgba[offset + $0]) - rgb[$0]) <= q.colourTolerance }
                }
                if matches(fill) { fillHits[index] = 1; fillCount += 1 }
                if matches(stroke) { ink[index] = 1; inkCount += 1 }
            }
        }
        // This is an observation-support bound, not a selected text/font size.
        guard inkCount >= q.minimumStrokeMatches, fillCount >= q.minimumFillMatches else { return unknown("observed-pair-not-supported") }
        guard Double(inkCount) <= Double(ownedCount) * q.maximumStrokeOwnerFraction else { return unknown("endpoint-covers-owner-surface") }

        // Stroke connectivity is not a glyph or lane certificate. Thick white
        // outlines can bridge several columns and recruit an entire paper gap.
        // Independently flood ORIGINAL matching fill, discard surface-sized
        // components, and require anchored fill before considering body scale.
        var core = [UInt8](repeating: 0, count: count)
        var coreVisited = core, contactFill = core, coreComponents = 0
        var surfaceConnectedFillProjection = [Int](repeating: 0, count: cross)
        for seed in fillHits.indices where fillHits[seed] == 1 && coreVisited[seed] == 0 {
            coreComponents += 1
            guard coreComponents <= q.maximumCoreComponents else { return unknown("core-component-budget-exceeded") }
            var queue = [seed], cursor = 0, anchored = 0
            coreVisited[seed] = 1
            while cursor < queue.count {
                let i = queue[cursor]; cursor += 1
                let x = i % cross, y = i / cross
                // Local ORIGINAL endpoint contact, independent of any outline
                // component envelope or recruited paper. Radius only allows the
                // bounded AA transition between observed fill and stroke RGBs.
                let radius = q.coreStrokeNeighbourRadius
                var contact = separation == 0
                for yy in max(0, y - radius)...min(along - 1, y + radius) {
                    for xx in max(0, x - radius)...min(cross - 1, x + radius) where ink[yy * cross + xx] == 1 { contact = true }
                }
                if contact { anchored += 1; contactFill[i] = 1 }
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let xx = x + dx, yy = y + dy
                        guard xx >= 0, xx < cross, yy >= 0, yy < along else { continue }
                        let next = yy * cross + xx
                        if fillHits[next] == 1 && coreVisited[next] == 0 {
                            coreVisited[next] = 1; queue.append(next)
                        }
                    }
                }
            }
            if Double(queue.count) > Double(ownedCount) * q.maximumCoreOwnerFraction {
                // White core may leak into same-colour paper when outlines
                // overlap. Do not quietly drop that potential body lane while
                // publishing a scale from its two observable neighbours.
                for i in queue where contactFill[i] == 1 { surfaceConnectedFillProjection[i % cross] += 1 }
                continue
            }
            guard queue.count >= q.minimumFillMatches,
                  anchored >= max(q.minimumFillMatches, Int(ceil(sqrt(Double(queue.count))))) else { continue }
            for i in queue { core[i] = 1 }
        }
        guard core.contains(1) else { return unknown("independent-core-fill-not-supported") }
        var projection = [Int](repeating: 0, count: cross)
        for y in 0..<along { for x in 0..<cross where core[y * cross + x] == 1 { projection[x] += 1 } }
        let repeatedSupport = max(q.minimumProjectionMatches, along / q.projectionAlongDivisor)
        var intervals: [(Int, Int)] = [], start: Int?
        for x in 0...cross {
            if x < cross && projection[x] >= repeatedSupport {
                if start == nil { start = x }
            } else if let first = start { intervals.append((first, x)); start = nil }
        }
        guard intervals.count <= q.maximumLanes else { return unknown("lane-budget-exceeded") }
        var lanes: [Lane] = [], ignored = 0, bodyEvidenceBudget = count * q.bodyEvidenceWorkPerSamplePixel
        for (left, right) in intervals {
            var spans = [Int](repeating: 0, count: along), pixels = spans, runs = spans
            var rowLeft = [Int](repeating: right, count: along), rowRight = [Int](repeating: left, count: along)
            for y in 0..<along {
                var first: Int?, last = left, previous = false
                for x in left..<right {
                    let hit = core[y * cross + x] == 1
                    if hit { first = first ?? x; last = x; pixels[y] += 1; if !previous { runs[y] += 1 } }
                    previous = hit
                }
                if let first { spans[y] = last - first + 1; rowLeft[y] = first; rowRight[y] = last + 1 }
            }
            // Compact solid round/blob bands are not independent glyph-body
            // evidence. This intentionally withholds circles/blocks as well as
            // ellipsis dots when pixels alone cannot distinguish their meaning.
            var bandStart: Int?
            for y in 0...along {
                if y < along && spans[y] > 0 { if bandStart == nil { bandStart = y } }
                else if let first = bandStart {
                    let length = y - first, peak = spans[first..<y].max()!
                    let area = pixels[first..<y].reduce(0, +)
                    let middle = first + length / 2
                    let roundedProfile = (first..<middle).allSatisfy { spans[$0 + 1] + 1 >= spans[$0] } &&
                        (middle..<max(middle, y - 1)).allSatisfy { spans[$0] + 1 >= spans[$0 + 1] }
                    let compactBlob = Double(length) >= Double(peak) * q.compactMinimumAspect &&
                        Double(length) <= Double(peak) * q.compactMaximumAspect &&
                        Double(area) >= Double(length * peak) * q.compactMinimumDensity &&
                        roundedProfile && runs[first..<y].allSatisfy { $0 <= 1 }
                    if compactBlob || area < q.minimumFillMatches {
                        ignored += 1
                        for yy in first..<y { spans[yy] = 0; pixels[yy] = 0 }
                    }
                    bandStart = nil
                }
            }
            // Bounded along-axis hypotheses account for disconnected glyph
            // strokes without assuming CC == glyph. The repeated BODY height
            // is an independent veto on a three-column cross envelope. Gaps are
            // owner-local ratios, never an expected font or page-wide median.
            var bestBodies: [GlyphBody] = [], bestProxy: Double = 0
            for gap in Set([0, Int(Double(right - left) * q.maximumBodyGapFraction / 2),
                            Int(Double(right - left) * q.maximumBodyGapFraction)]).sorted() {
                var bodies: [GlyphBody] = [], y = 0
                while y < along {
                    guard spans[y] > 0 else { y += 1; continue }
                    let first = y
                    var end = y + 1, last = y, bodyLeft = rowLeft[y], bodyRight = rowRight[y], area = pixels[y]
                    y += 1
                    while y < along {
                        if spans[y] > 0 {
                            guard y - last - 1 <= gap else { break }
                            last = y; end = y + 1; bodyLeft = min(bodyLeft, rowLeft[y]); bodyRight = max(bodyRight, rowRight[y])
                            area += pixels[y]
                        } else if y - last > gap { break }
                        y += 1
                    }
                    let width = bodyRight - bodyLeft, length = end - first
                    guard width > 0, area >= q.minimumFillMatches,
                          Double(width) >= Double(right - left) * q.bodySupportEnvelopeFraction,
                          Double(length) >= Double(width) * q.minimumBodyHeightToCross,
                          Double(length) <= Double(width) * q.maximumBodyHeightToCross else { continue }
                    bodies.append(.init(crossStart: bodyLeft, crossEnd: bodyRight,
                        alongStart: first, alongEnd: end, coreFillPixels: area))
                }
                guard bodies.count >= q.minimumRepeatedBodies else { continue }
                let widths = bodies.map { Double($0.crossEnd - $0.crossStart) }.sorted()
                let proxy = widths[min(widths.count - 1, widths.count * 4 / 5)]
                let repeated = bodies.filter {
                    abs(Double($0.crossEnd - $0.crossStart) - proxy) <= proxy * q.maximumNearEnvelopeDeviation
                }
                guard repeated.count >= q.minimumRepeatedBodies else { continue }
                if proxy > bestProxy || proxy == bestProxy && repeated.count > bestBodies.count {
                    bestProxy = proxy; bestBodies = repeated
                }
            }
            guard bestBodies.count >= q.minimumRepeatedBodies else { continue }
            let proxy = bestProxy
            let bodyLeft = bestBodies.map(\.crossStart).min()!, bodyRight = bestBodies.map(\.crossEnd).max()!
            let first = bestBodies.map(\.alongStart).min()!, last = bestBodies.map(\.alongEnd).max()!
            var bodyRows = [Bool](repeating: false, count: along)
            for body in bestBodies { for y in body.alongStart..<body.alongEnd { bodyRows[y] = true } }
            let supported = spans.indices.filter { bodyRows[$0] && pixels[$0] >= q.minimumRowInk }
            let stable = supported.filter { abs(Double(spans[$0]) - proxy) <= proxy * q.maximumNearEnvelopeDeviation }.count
            let stability = Double(stable) / Double(max(1, supported.count))
            let widths = supported.map { spans[$0] }.sorted()
            guard !widths.isEmpty else { continue }
            let bodyWidth = Double(widths[min(widths.count - 1, widths.count * 4 / 5)])
            let heights = bestBodies.map { Double($0.alongEnd - $0.alongStart) }.sorted()
            // Diagnostic outline envelope only; never feeds the selected body
            // proxy. This deliberately exposes bridged stroke disagreement.
            let strokeWork = bodyRows.filter { $0 }.count * cross
            guard strokeWork <= bodyEvidenceBudget else { return unknown("body-evidence-budget-exceeded", lanes: lanes, ignored: ignored) }
            bodyEvidenceBudget -= strokeWork
            var strokeLeft = cross, strokeRight = 0
            for y in bodyRows.indices where bodyRows[y] {
                for x in 0..<cross where ink[y * cross + x] == 1 { strokeLeft = min(strokeLeft, x); strokeRight = max(strokeRight, x + 1) }
            }
            let strokeSpan = Double(max(0, strokeRight - strokeLeft))
            let edge = bodyLeft == 0 || bodyRight == cross || supported.contains { y in
                (bodyLeft > 0 && owned[y * cross + bodyLeft - 1] == 0) ||
                (bodyRight < cross && owned[y * cross + bodyRight] == 0)
            }
            let confidence = min(q.confidenceCap, 0.45 + 0.35 * stability + 0.1 * min(1, Double(supported.count) / (proxy * 4)))
                * (edge ? q.edgeConfidenceFactor : 1)
            lanes.append(.init(crossAxis: sourceVertical ? "x" : "y", alongAxis: sourceVertical ? "y" : "x",
                crossStart: bodyLeft, crossEnd: bodyRight, alongStart: first, alongEnd: last,
                bodyInkAlongStart: first, bodyInkAlongEnd: last,
                pixelAdvanceProxy: proxy, confidence: confidence, supportedRows: supported.count,
                nearEnvelopeRows: stable, bodyScanlineWidth80th: bodyWidth,
                supportedInkPixels: supported.reduce(0) { $0 + pixels[$1] }, edgeLimited: edge,
                coreFillPixels: bestBodies.reduce(0) { $0 + $1.coreFillPixels }, repeatedGlyphBodies: bestBodies.count,
                bodyAlongHeightMedian: heights[heights.count / 2], strokeEnvelopeCrossSpan: strokeSpan,
                glyphBodies: bestBodies))
        }
        guard !lanes.isEmpty else { return unknown("insufficient-glyph-body-evidence", ignored: ignored) }
        var unresolvedRun = 0, maximumUnresolvedRun = 0
        for x in 0..<cross {
            if surfaceConnectedFillProjection[x] >= repeatedSupport,
               !lanes.contains(where: { x >= $0.crossStart && x < $0.crossEnd }) {
                unresolvedRun += 1; maximumUnresolvedRun = max(maximumUnresolvedRun, unresolvedRun)
            } else { unresolvedRun = 0 }
        }
        if Double(maximumUnresolvedRun) >= lanes.map(\.pixelAdvanceProxy).min()! * q.minimumBodyEnvelopeFraction {
            return unknown("unresolved-core-fill-connected-to-owner-surface", lanes: lanes, ignored: ignored)
        }
        let values = lanes.map(\.pixelAdvanceProxy).sorted()
        // A small adjacent lane can be ruby OR deliberate small lettering. Keep
        // both measurements, withhold a single source hierarchy rather than
        // silently discarding one lane or flattening intentional emphasis.
        guard values.last! <= values.first! * q.maximumAggregateLaneRatio else {
            return unknown("mixed-lane-scales-possible-ruby-or-emphasis", lanes: lanes, ignored: ignored)
        }
        let middle = values.count / 2
        let median = values.count % 2 == 0 ? (values[middle - 1] + values[middle]) / 2 : values[middle]
        return .init(units: "sample-pixels", confidenceAuthority: "heuristic evidence score; uncalibrated",
            qualityThresholds: q, pixelAdvanceProxy: median, lanes: lanes, confidence: lanes.map(\.confidence).min()!,
            method: method, unknownReason: nil, ignoredCompactBands: ignored)
    }
}
