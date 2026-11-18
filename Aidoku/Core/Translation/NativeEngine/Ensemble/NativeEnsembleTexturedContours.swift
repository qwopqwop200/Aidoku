import CoreGraphics
import Foundation

/// Additional placement capacity for unresolved owners on nonuniform surfaces.
/// RF segmentation supplies topology; original RGB supplies local edge evidence.
/// Neither is source silhouette/glyph gold. No erasure, rendering or text edits.
enum NativeEnsembleTexturedContours: Ensemble100Candidate {
    static let defaults: [String: Double] = [
        "enabled": 1, "rfConfidence": 0.6, "ocrCoverage": 0.9,
        "ambiguityMargin": 0.08, "boundarySupport": 0.65, "sectorSupport": 0.4,
        "minimumGradient": 20, "normalAlignment": 0.8, "edgeDominance": 1.4,
        "alignmentTolerancePixels": 4, "offsetMADPixels": 2.5,
        "sourceEdgeFraction": 0.008, "insetPixels": 6,
        "tailWidthFraction": 0.38, "bands": 96, "boundarySamples": 160, "rasterSide": 1536
    ]

    private struct Span {
        let left: Double, right: Double
        var width: Double { right - left }
    }
    private struct Body {
        let rect: CGRect
        let spans: [Span]
        var center: CGPoint {
            let maximum = spans.map(\.width).max() ?? 0
            var mass = 0.0, x = 0.0, y = 0.0
            for (i, row) in spans.enumerated() where row.width >= maximum * 0.65 {
                mass += row.width
                x += (row.left + row.right) * 0.5 * row.width
                y += (rect.minY + (Double(i) + 0.5) * rect.height / Double(spans.count)) * row.width
            }
            return CGPoint(x: x / mass, y: y / mass)
        }
        var json: [String: Any] {
            ["rect": [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)],
             "center": [Double(center.x), Double(center.y)],
             "spans": spans.flatMap { [$0.left, $0.right] },
             "contourVerified": false, "modelEstimated": true]
        }
    }
    private struct Raster {
        let width: Int, height: Int
        let rgba: [UInt8]
        init?(_ image: CGImage, side: Int) {
            let scale = min(1, Double(side) / Double(max(image.width, image.height)))
            let w = max(1, Int((Double(image.width) * scale).rounded()))
            let h = max(1, Int((Double(image.height) * scale).rounded()))
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let color = CGColorSpace(name: CGColorSpace.sRGB),
                      let context = CGContext(data: buffer.baseAddress, width: w, height: h,
                        bitsPerComponent: 8, bytesPerRow: w * 4, space: color,
                        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: w, height: h))
                context.interpolationQuality = .medium
                context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard ok else { return nil }
            width = w; height = h; rgba = bytes
        }
        func color(_ point: CGPoint) -> SIMD3<Double>? {
            // Pixel centre coordinates; do not clamp off-page probes into a
            // spurious boundary at the page edge.
            let x = point.x - 0.5, y = point.y - 0.5
            guard x >= 0, y >= 0, x < Double(width - 1), y < Double(height - 1) else { return nil }
            let ix = Int(x), iy = Int(y), dx = x - Double(ix), dy = y - Double(iy)
            func rgb(_ xx: Int, _ yy: Int) -> SIMD3<Double> {
                let p = (yy * width + xx) * 4
                return SIMD3(Double(rgba[p]), Double(rgba[p + 1]), Double(rgba[p + 2]))
            }
            return (rgb(ix, iy) * (1 - dx) + rgb(ix + 1, iy) * dx) * (1 - dy) +
                (rgb(ix, iy + 1) * (1 - dx) + rgb(ix + 1, iy + 1) * dx) * dy
        }
        func pixel(_ normalized: CGPoint) -> CGPoint {
            CGPoint(x: normalized.x * Double(width), y: normalized.y * Double(height))
        }
    }
    private struct EdgeEvidence {
        let support: Double
        let sectors: [Double]
        let offsetMAD: Double
        let probes: Int
        var json: [String: Any] {
            ["supportedFraction": support, "normalSectors": sectors,
             "offsetMADPixels": offsetMAD, "probes": probes,
             "authority": "automated original-RGB local gradients aligned with model normals; not visual QA"]
        }
    }

    static func apply(_ page: Ensemble100Page, parameters: [String: Double]) throws -> Ensemble100Proposal {
        func p(_ key: String, _ lo: Double, _ hi: Double) -> Double {
            let v = parameters[key] ?? defaults[key]!
            return min(hi, max(lo, v.isFinite ? v : defaults[key]!))
        }
        guard p("enabled", 0, 1) > 0 else {
            return Ensemble100Proposal(items: page.items, audit: ["status": "disabled", "inputItems": page.items.count])
        }
        let regions = page.rfRegions.filter {
            $0.classID == 2 && $0.confidence.isFinite && $0.confidence >= p("rfConfidence", 0, 1) &&
                valid($0.exterior) && $0.holes.count <= 128 && $0.holes.allSatisfy(valid) &&
                $0.exterior.count + $0.holes.reduce(0, { $0 + $1.count }) <= 8192
        }
        var output = page.items, decisions: [[String: Any]] = []
        var raster: Raster?
        for index in output.indices {
            try Task.checkCancellation()
            var decision: [String: Any] = ["itemIndex": index]
            defer { decisions.append(decision) }
            // This is strictly an additive fallback. Preserve even uncertain
            // existing records; the parent alone adjudicates replacement.
            let primary = output[index]["balloonInterior"]
            let nested = (output[index]["balloonUnit"] as? [String: Any])?["interior"]
            if (primary != nil && !(primary is NSNull)) || (nested != nil && !(nested is NSNull)) {
                decision["status"] = "existing-interior-preserved"; continue
            }
            guard let source = sourceRect(output[index]["sourceBounds"]) else {
                decision["status"] = "missing-or-invalid-ocr-envelope"; continue
            }
            let matches = regions.compactMap { region -> (Ensemble100RFRegion, Double)? in
                guard contains(CGPoint(x: source.midX, y: source.midY), region) else { return nil }
                var covered = 0
                for y in 0..<7 { for x in 0..<7 {
                    if contains(CGPoint(x: source.minX + (Double(x) + 0.5) * source.width / 7,
                                        y: source.minY + (Double(y) + 0.5) * source.height / 7), region) { covered += 1 }
                } }
                let coverage = Double(covered) / 49
                return coverage >= p("ocrCoverage", 0.5, 1) ? (region, coverage) : nil
            }.sorted { $0.1 == $1.1 ? $0.0.confidence > $1.0.confidence : $0.1 > $1.1 }
            guard let selected = matches.first else { decision["status"] = "no-rf-polygon-owner"; continue }
            decision["coverage"] = selected.1
            decision["queryID"] = selected.0.queryID
            if matches.dropFirst().contains(where: {
                $0.1 >= selected.1 - p("ambiguityMargin", 0, 0.2) &&
                    $0.0.confidence >= selected.0.confidence - p("ambiguityMargin", 0, 0.2)
            }) {
                decision["status"] = "ambiguous-rf-ownership"; continue
            }
            if raster == nil { raster = Raster(page.original, side: Int(p("rasterSide", 256, 2048))) }
            guard let pixels = raster else { decision["status"] = "original-raster-unavailable"; continue }
            let margin = max(p("insetPixels", 1, 16), p("alignmentTolerancePixels", 1, 10) + 2)
            guard let body = capacity(selected.0, source: source, pixels: pixels,
                                      count: Int(p("bands", 32, 192)), margin: margin,
                                      tail: p("tailWidthFraction", 0.15, 0.65)) else {
                decision["status"] = "no-conservative-body-spans"; continue
            }
            let variation = sourceVariation(source, pixels, minimum: p("minimumGradient", 4, 100) * 0.5)
            decision["sourceEdgeFraction"] = variation
            guard variation >= p("sourceEdgeFraction", 0, 0.2) else {
                decision["status"] = "no-original-ocr-envelope-variation"; continue
            }
            let evidence = boundary(selected.0, body: body, pixels: pixels,
                sampleCount: Int(p("boundarySamples", 64, 256)), tolerance: Int(p("alignmentTolerancePixels", 1, 10)),
                minimum: p("minimumGradient", 4, 100), alignment: p("normalAlignment", 0.5, 1),
                dominance: p("edgeDominance", 1, 4))
            decision["boundary"] = evidence.json
            guard evidence.probes >= 24, evidence.support >= p("boundarySupport", 0.3, 1),
                  evidence.sectors.allSatisfy({ $0 >= p("sectorSupport", 0.1, 1) }),
                  evidence.offsetMAD <= p("offsetMADPixels", 0.5, 8) else {
                decision["status"] = "weak-or-ambiguous-original-boundary"; continue
            }
            output[index]["balloonInterior"] = body.json
            output[index]["rfBodyIndex"] = selected.0.queryID
            output[index]["rfBodyConfidence"] = selected.0.confidence
            output[index]["texturedContourEvidence"] = ["boundary": evidence.json,
                "coverage": selected.1, "sourceEdgeFraction": variation,
                "sourceVerified": false, "glyphGroundTruth": false,
                "authority": "RF topology + original-RGB normal-gradient alignment; estimated capacity"]
            decision["status"] = "added-textured-model-estimate"
        }
        return Ensemble100Proposal(items: output, audit: ["candidate": "textured-contours",
            "inputItems": page.items.count, "outputItems": output.count, "decisions": decisions,
            "addedModelContours": decisions.filter { $0["status"] as? String == "added-textured-model-estimate" }.count,
            "rasterWidth": raster?.width ?? 0, "rasterHeight": raster?.height ?? 0,
            "authority": "automated technical measurements only; input original/RF binding supplied by caller",
            "identityProof": "caller-bound immutable original/RF; no local encoded SHA proof required or claimed",
            "textFramesMasksUnchanged": true])
    }

    /// Rebuild the witness from immutable original pixels and actual RF regions.
    /// Direct original-boundary evidence for a caller that already computed
    /// conservative scanlines from this SAME RF region. It does not assert
    /// uniform paper, verified glyphs or optical-centre ground truth.
    static func boundaryWitness(_ region: Ensemble100RFRegion, original: CGImage) -> (supported: Bool, audit: [String:Any]) {
        guard region.classID == 2, region.confidence.isFinite, region.confidence >= defaults["rfConfidence"]!,
              valid(region.exterior), region.holes.count <= 128, region.holes.allSatisfy(valid),
              region.exterior.count + region.holes.reduce(0,{ $0+$1.count }) <= 8192,
              let pixels = Raster(original,side:Int(defaults["rasterSide"]!)) else {
            return (false,["measured":false,"reason":"invalid-or-unavailable-original-RF-boundary"])
        }
        let body = Body(rect:region.bounds,spans:[])
        let evidence = boundary(region,body:body,pixels:pixels,sampleCount:Int(defaults["boundarySamples"]!),
            tolerance:Int(defaults["alignmentTolerancePixels"]!),minimum:defaults["minimumGradient"]!,
            alignment:defaults["normalAlignment"]!,dominance:defaults["edgeDominance"]!)
        let supported = evidence.probes >= 24 && evidence.support >= defaults["boundarySupport"]! &&
            evidence.sectors.allSatisfy { $0 >= defaults["sectorSupport"]! } && evidence.offsetMAD <= defaults["offsetMADPixels"]!
        return (supported,["measured":true,"supported":supported,"evidence":evidence.json,
            "authority":"RF outer contour and independent original local normal-gradient alignment; estimated topology, not glyph gold"])
    }

    /// Rebuild the witness from immutable original pixels and actual RF regions.
    /// Serialized flags cannot promote an arbitrary or stale contour to trusted capacity.
    static func rechecks(_ raw: [String: Any], original: CGImage, viewport: CGSize,
                         regions: [Ensemble100RFRegion], parameters: [String: Double]) throws -> Bool {
        guard raw["texturedContourEvidence"] is [String: Any],
              let expected = raw["balloonInterior"] as? [String: Any],
              expected["modelEstimated"] as? Bool == true else { return false }
        var probe = raw
        probe.removeValue(forKey: "balloonInterior")
        let page = Ensemble100Page(sourceSHA256: "", original: original, restored: original,
            removalMask: original, viewport: viewport, items: [probe], rfRegions: regions, savedEvidence: [:])
        let result = try apply(page, parameters: parameters)
        guard result.audit["addedModelContours"] as? Int == 1,
              let observed = result.items.first?["balloonInterior"] as? [String: Any] else { return false }
        return NSDictionary(dictionary: expected).isEqual(to: observed)
    }

    private static func sourceRect(_ value: Any?) -> CGRect? {
        guard let b = value as? [Double], b.count == 4, b.allSatisfy(\.isFinite), b[2] > 1e-9, b[3] > 1e-9 else { return nil }
        let rect = CGRect(x: b[0], y: b[1], width: b[2], height: b[3])
        return CGRect(x: 0, y: 0, width: 1, height: 1).contains(rect) ? rect : nil
    }
    private static func valid(_ ring: [CGPoint]) -> Bool {
        guard ring.count >= 3, ring.count <= 4096, ring.allSatisfy({
            $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.y >= 0 && $0.x <= 1 && $0.y <= 1
        }) else { return false }
        let area = ring.indices.reduce(0.0) { sum, i in
            let a = ring[i], b = ring[(i + 1) % ring.count]
            return sum + a.x * b.y - a.y * b.x
        }
        return abs(area) > 1e-10
    }
    private static func intervals(_ y: Double, _ ring: [CGPoint]) -> [Span] {
        var x: [Double] = []
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            if (a.y > y) != (b.y > y) { x.append(a.x + (b.x - a.x) * (y - a.y) / (b.y - a.y)) }
        }
        x.sort()
        return stride(from: 0, to: max(0, x.count - 1), by: 2).map { Span(left: x[$0], right: x[$0 + 1]) }
    }
    private static func runs(_ y: Double, _ region: Ensemble100RFRegion) -> [Span] {
        var spans = intervals(y, region.exterior)
        for hole in region.holes {
            for cut in intervals(y, hole) {
                spans = spans.flatMap { span -> [Span] in
                    guard cut.right > span.left, cut.left < span.right else { return [span] }
                    var output: [Span] = []
                    if cut.left > span.left { output.append(Span(left: span.left, right: cut.left)) }
                    if cut.right < span.right { output.append(Span(left: cut.right, right: span.right)) }
                    return output
                }
            }
        }
        return spans
    }
    private static func contains(_ point: CGPoint, _ region: Ensemble100RFRegion) -> Bool {
        runs(point.y, region).contains { $0.left <= point.x && point.x <= $0.right }
    }

    /// Equal-height bands intersect all relevant polygon extrema over the
    /// band's FULL height plus an erosion margin in both source axes.
    private static func capacity(_ region: Ensemble100RFRegion, source: CGRect, pixels: Raster,
                                 count: Int, margin: Double, tail: Double) -> Body? {
        let vertices = (region.exterior + region.holes.flatMap { $0 }).map(\.y)
        let top = region.exterior.map(\.y).min()!, bottom = region.exterior.map(\.y).max()!
        let step = (bottom - top) / Double(count)
        guard step > 1e-12 else { return nil }
        let mx = margin / Double(pixels.width), my = margin / Double(pixels.height), epsilon = step * 1e-5
        let bands: [Span?] = (0..<count).map { i in
            let a = top + Double(i) * step - my, b = top + Double(i + 1) * step + my
            guard a > top, b < bottom else { return nil }
            var probes = [a, (a + b) / 2, b]
            for vertex in vertices where vertex > a && vertex < b {
                probes += [max(a, vertex - epsilon), min(b, vertex + epsilon)]
            }
            var left = 0.0, right = 1.0
            for y in probes {
                guard let run = runs(y, region).first(where: { $0.left <= source.midX && source.midX <= $0.right }) else { return nil }
                left = max(left, run.left); right = min(right, run.right)
            }
            return right - left > 2 * mx ? Span(left: left + mx, right: right - mx) : nil
        }
        let seed = min(count - 1, max(0, Int((source.midY - top) / step)))
        guard bands[seed] != nil else { return nil }
        let maximum = bands.compactMap { $0?.width }.max() ?? 0
        func connected(_ a: Int, _ b: Int) -> Bool {
            guard let first = bands[a], let next = bands[b], next.width >= maximum * tail else { return false }
            return min(first.right, next.right) > max(first.left, next.left)
        }
        var first = seed, last = seed
        while first > 0 && connected(first, first - 1) { first -= 1 }
        while last + 1 < count && connected(last, last + 1) { last += 1 }
        guard last - first >= 5 else { return nil }
        let rows = (first...last).compactMap { bands[$0] }
        let left = rows.map(\.left).min()!, right = rows.map(\.right).max()!
        let rect = CGRect(x: left, y: top + Double(first) * step, width: right - left, height: Double(rows.count) * step)
        guard rect.contains(source) else { return nil }
        for (i, row) in rows.enumerated() {
            let y0 = rect.minY + Double(i) * step, y1 = y0 + step
            if y1 > source.minY && y0 < source.maxY && (row.left > source.minX || row.right < source.maxX) { return nil }
        }
        return Body(rect: rect, spans: rows)
    }

    private static func magnitude(_ value: SIMD3<Double>) -> Double {
        sqrt((value.x * value.x + value.y * value.y + value.z * value.z) / 3)
    }
    private static func sourceVariation(_ source: CGRect, _ pixels: Raster, minimum: Double) -> Double {
        var tested = 0, edges = 0
        for y in 0..<16 { for x in 0..<16 {
            let p = pixels.pixel(CGPoint(x: source.minX + (Double(x) + 0.5) * source.width / 16,
                                         y: source.minY + (Double(y) + 0.5) * source.height / 16))
            guard let a = pixels.color(CGPoint(x: p.x - 1, y: p.y)), let b = pixels.color(CGPoint(x: p.x + 1, y: p.y)),
                  let c = pixels.color(CGPoint(x: p.x, y: p.y - 1)), let d = pixels.color(CGPoint(x: p.x, y: p.y + 1)) else { continue }
            tested += 1
            if max(magnitude((a - b) * 0.5), magnitude((c - d) * 0.5)) >= minimum { edges += 1 }
        } }
        return tested > 0 ? Double(edges) / Double(tested) : 0
    }

    private static func boundary(_ region: Ensemble100RFRegion, body: Body, pixels: Raster,
                                 sampleCount: Int, tolerance: Int, minimum: Double,
                                 alignment: Double, dominance: Double) -> EdgeEvidence {
        let ring = region.exterior.map(pixels.pixel)
        let lengths = ring.indices.map { i in hypot(ring[(i + 1) % ring.count].x - ring[i].x,
                                                    ring[(i + 1) % ring.count].y - ring[i].y) }
        let perimeter = lengths.reduce(0, +)
        guard perimeter > 0 else { return EdgeEvidence(support: 0, sectors: [0, 0, 0, 0], offsetMAD: 0, probes: 0) }
        var segment = 0, start = 0.0, tested = [Int](repeating: 0, count: 4), supported = tested, offsets: [Double] = []
        let yMargin = max(body.rect.height * 0.08, Double(tolerance + 3) / Double(pixels.height))
        for sample in 0..<sampleCount {
            let distance = (Double(sample) + 0.5) / Double(sampleCount) * perimeter
            while segment + 1 < ring.count && start + lengths[segment] < distance { start += lengths[segment]; segment += 1 }
            guard lengths[segment] > 0 else { continue }
            let a = ring[segment], b = ring[(segment + 1) % ring.count], fraction = (distance - start) / lengths[segment]
            let point = CGPoint(x: a.x + (b.x - a.x) * fraction, y: a.y + (b.y - a.y) * fraction)
            // Long narrow tails must not supply most of the boundary votes.
            let yn = point.y / Double(pixels.height)
            guard yn >= body.rect.minY - yMargin, yn <= body.rect.maxY + yMargin else { continue }
            let nx = (b.y - a.y) / lengths[segment], ny = -(b.x - a.x) / lengths[segment]
            let sector = abs(nx) >= abs(ny) ? (nx < 0 ? 0 : 1) : (ny < 0 ? 2 : 3)
            tested[sector] += 1
            func gradients(_ offset: Double) -> (Double, Double)? {
                let p = CGPoint(x: point.x + nx * offset, y: point.y + ny * offset)
                func average(_ x: Double, _ y: Double) -> SIMD3<Double>? {
                    guard let a = pixels.color(CGPoint(x: x - ny, y: y + nx)),
                          let b = pixels.color(CGPoint(x: x, y: y)),
                          let c = pixels.color(CGPoint(x: x + ny, y: y - nx)) else { return nil }
                    return (a + b + c) / 3
                }
                guard let a = average(p.x - nx, p.y - ny), let b = average(p.x + nx, p.y + ny),
                      let c = average(p.x + ny, p.y - nx), let d = average(p.x - ny, p.y + nx) else { return nil }
                let normal = magnitude((a - b) * 0.5), tangent = magnitude((c - d) * 0.5)
                return (normal, normal / max(1e-9, hypot(normal, tangent)))
            }
            guard let inner = gradients(-Double(tolerance + 4)), let outer = gradients(Double(tolerance + 4)) else { continue }
            let control = max(4, max(inner.0, outer.0))
            var best: (Double, Int)?
            for offset in -tolerance...tolerance {
                guard let evidence = gradients(Double(offset)), evidence.0 >= minimum,
                      evidence.1 >= alignment, evidence.0 >= control * dominance else { continue }
                if best == nil || evidence.0 > best!.0 { best = (evidence.0, offset) }
            }
            if let best { supported[sector] += 1; offsets.append(Double(best.1)) }
        }
        let count = tested.reduce(0, +)
        let median = offsets.sorted().dropFirst(offsets.count / 2).first ?? 0
        let deviations = offsets.map { abs($0 - median) }.sorted()
        let mad = deviations.dropFirst(deviations.count / 2).first ?? Double(tolerance + 1)
        return EdgeEvidence(support: Double(offsets.count) / Double(max(1, count)),
            sectors: (0..<4).map { tested[$0] >= 3 ? Double(supported[$0]) / Double(tested[$0]) : 0 },
            offsetMAD: mad, probes: count)
    }
}
