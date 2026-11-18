import CoreGraphics
import Foundation

/// Placement capacity only. Original RGB supplies boundary evidence; neither RF
/// polygons nor removal masks are glyph truth. No text or display frame changes.
enum EnsembleCandidate03: Ensemble100Candidate {
    @TaskLocal private static var localRFBoundarySupportOverride: Bool?

    static func withLocalRFBoundarySupport<Value>(_ enabled: Bool,
                                                  operation: () throws -> Value) rethrows -> Value {
        try $localRFBoundarySupportOverride.withValue(enabled, operation: operation)
    }

    static var localRFBoundarySupportEnabled: Bool {
        localRFBoundarySupportOverride ??
            (ProcessInfo.processInfo.environment["AIDOKU_LOCAL_RF_BOUNDARY_SUPPORT"] == "1")
    }

    static let defaults: [String: Double] = [
        "enabled": 1, "rfConfidence": 0.5, "ocrCoverage": 0.84,
        "ambiguityMargin": 0.06, "tailWidthFraction": 0.38,
        "boundarySupport": 0.5, "boundaryTolerancePixels": 10,
        "paperDelta": 42, "paperAgreement": 0.65, "edgeRun": 2,
        "insetPixels": 2, "bands": 96, "rasterSide": 1536,
        "fallbackExpansion": 5, "fallbackMaxSide": 0.6
    ]

    private struct Span {
        var left: Double
        var right: Double
        var width: Double { right - left }
    }
    private struct Body {
        var rect: CGRect
        var spans: [Span]
        var center: CGPoint {
            let maximum = spans.map(\.width).max() ?? 0
            var mass = 0.0, x = 0.0, y = 0.0
            for (i, span) in spans.enumerated() where span.width >= maximum * 0.65 {
                mass += span.width
                x += (span.left + span.right) * 0.5 * span.width
                y += (rect.minY + (Double(i) + 0.5) * rect.height / Double(spans.count)) * span.width
            }
            return mass > 0 ? CGPoint(x: x / mass, y: y / mass) : CGPoint(x: rect.midX, y: rect.midY)
        }
        var json: [String: Any] {
            ["rect": [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)],
             "center": [Double(center.x), Double(center.y)],
             "spans": spans.flatMap { [$0.left, $0.right] },
             "contourVerified": false, "modelEstimated": true]
        }
    }
    private struct RGB {
        let r: Int, g: Int, b: Int
        func distance(_ other: RGB) -> Int {
            max(abs(r - other.r), max(abs(g - other.g), abs(b - other.b)))
        }
    }
    private struct Pixels {
        let width: Int, height: Int
        private let originX: Int, originY: Int, storageWidth: Int
        let bytes: [UInt8]
        init?(_ image: CGImage, side: Int) {
            let scale = min(1, Double(side) / Double(max(image.width, image.height)))
            width = max(1, Int((Double(image.width) * scale).rounded()))
            height = max(1, Int((Double(image.height) * scale).rounded()))
            originX = 0; originY = 0; storageWidth = width
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            let w = width, h = height
            let success = rgba.withUnsafeMutableBytes { buffer -> Bool in
                guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                      let context = CGContext(data: buffer.baseAddress, width: w, height: h,
                        bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                            CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
                context.interpolationQuality = .medium
                context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard success else { return nil }
            bytes = rgba
        }
        init?(_ image: CGImage, window: CGRect) {
            guard let crop = image.cropping(to: window),
                  let local = Pixels(crop, side: max(crop.width, crop.height)) else { return nil }
            width = image.width; height = image.height
            originX = Int(window.minX); originY = Int(window.minY); storageWidth = crop.width
            bytes = local.bytes
        }
        func rgb(_ x: Int, _ y: Int) -> RGB? {
            guard x >= 0, y >= 0, x < width, y < height else { return nil }
            let xx = x - originX, yy = y - originY
            guard xx >= 0, yy >= 0, xx < storageWidth, yy < bytes.count / 4 / storageWidth else { return nil }
            let i = (yy * storageWidth + xx) * 4
            guard bytes[i + 3] >= 250 else { return nil }
            return RGB(r: Int(bytes[i]), g: Int(bytes[i + 1]), b: Int(bytes[i + 2]))
        }
        func rgb(_ point: CGPoint) -> RGB? {
            rgb(Int(point.x * Double(width)), Int(point.y * Double(height)))
        }
    }

    static func apply(_ page: Ensemble100Page, parameters: [String: Double]) throws -> Ensemble100Proposal {
        func p(_ key: String, _ lower: Double, _ upper: Double) -> Double {
            let value = parameters[key] ?? defaults[key]!
            return min(upper, max(lower, value.isFinite ? value : defaults[key]!))
        }
        guard p("enabled", 0, 1) > 0 else {
            return Ensemble100Proposal(items: page.items, audit: ["candidate": 3, "status": "disabled"])
        }
        let sources = page.items.map { rect($0["sourceBounds"]) }
        let availability: [String: Any] = [
            "rfRegions": page.rfRegions.count,
            "rfBalloonBoxesWithoutPolygon": page.rfRegions.filter { $0.classID == 2 && $0.exterior.isEmpty }.count,
            "cachedOriginalOCRAvailable": page.savedEvidence["originalOCR"] != nil,
            "sourceBoundsAuthority": "saved item OCR envelope proxy; not glyph GT",
            "rfBoxAuthority": "all-class boxes are not segmentation; only valid balloon polygons used"
        ]
        guard sources.contains(where: { $0 != nil }),
              let pixels = Pixels(page.original, side: Int(p("rasterSide", 256, 2048))) else {
            return Ensemble100Proposal(items: page.items, audit: ["candidate": 3,
                "status": "missing-source-or-raster", "evidenceAvailability": availability])
        }
        let regions = page.rfRegions.filter {
            $0.classID == 2 && $0.confidence.isFinite && $0.confidence >= p("rfConfidence", 0, 1) &&
            validRing($0.exterior) && $0.holes.count <= 128 && $0.holes.allSatisfy(validRing) &&
            $0.exterior.count + $0.holes.reduce(0, { $0 + $1.count }) <= 8192
        }
        let bandCount = Int(p("bands", 24, 192))
        let delta = Int(p("paperDelta", 8, 100))
        let edgeRun = Int(p("edgeRun", 1, 5))
        let inset = p("insetPixels", 0, 8)
        let certifying = localRFBoundarySupportEnabled && NativeEnsembleLayoutContour.supportedEstimatedContourEnabled
        let regionsSHA256 = certifying ? NativeSupportedEstimatedContour.materialization(page.rfRegions) : ""
        var output = page.items, decisions: [[String: Any]] = []
        for i in output.indices {
            // Recompute current RGB evidence; serialized old receipts never
            // survive a failed observation on a new source transaction.
            output[i].removeValue(forKey: NativeSupportedEstimatedContour.receiptKey)
            var audit: [String: Any] = ["itemIndex": i]
            defer { decisions.append(audit) }
            guard let source = sources[i] else { audit["status"] = "invalid-source-bounds"; continue }
            // Existing native verification is retained, never manufactured here.
            if let native = output[i]["balloonInterior"] as? [String: Any],
               native["contourVerified"] as? Bool == true {
                audit["status"] = "existing-native-preserved"
                continue
            }
            let paper = paperColor(source, pixels: pixels, delta: delta,
                                   agreement: p("paperAgreement", 0.5, 0.95))
            if paper == nil && !localRFBoundarySupportEnabled {
                audit["status"] = "ambiguous-source-background"
                continue
            }
            let ranked = regions.compactMap { region -> (Ensemble100RFRegion, Double)? in
                // Cheap rejection before repeated polygon/hole intersection work.
                let xs = region.exterior.map(\.x), ys = region.exterior.map(\.y)
                guard source.midX >= xs.min()!, source.midX <= xs.max()!,
                      source.midY >= ys.min()!, source.midY <= ys.max()! else { return nil }
                var hits = 0
                for y in 0..<5 {
                    let row = source.minY + (Double(y) + 0.5) * source.height / 5
                    let intervals = spans(row, region: region)
                    for x in 0..<5 {
                        let column = source.minX + (Double(x) + 0.5) * source.width / 5
                        if intervals.contains(where: { $0.left <= column && $0.right >= column }) { hits += 1 }
                    }
                }
                let coverage = Double(hits) / 25
                return coverage >= p("ocrCoverage", 0.5, 1) ? (region, coverage) : nil
            }.sorted {
                $0.1 == $1.1 ? $0.0.confidence > $1.0.confidence : $0.1 > $1.1
            }
            let ambiguous = ranked.count > 1 && ranked[1].1 >= ranked[0].1 - p("ambiguityMargin", 0, 0.2) &&
                ranked[1].0.confidence >= ranked[0].0.confidence - p("ambiguityMargin", 0, 0.2)
            audit["rfMatches"] = ranked.count
            audit["rfAmbiguous"] = ambiguous
            if paper == nil || certifying {
                audit["status"] = "ambiguous-source-background"
                audit["localBoundaryStatus"] = "no-unambiguous-owner-polygon"
                guard !ambiguous, let match = ranked.first,
                      match.0.holes.isEmpty,
                      contains(CGPoint(x: source.midX, y: source.midY), region: match.0) else { continue }
                let body: Body
                let margin: Double
                let method: String
                var observedRasterSHA256 = ""
                if certifying {
                    // A uniform paper colour is not required: transparent bodies
                    // can still have a closed original black rim. RF supplies
                    // only the bounded search window, never the interior pixels.
                    margin = max(2, inset)
                    method = "closed-original-rgb-rim-component"
                    guard let measured = closedRimObservation(match.0, source: source, original: page.original,
                        working: pixels, bands: bandCount, tolerance: Int(p("boundaryTolerancePixels", 1, 32)), margin: margin) else {
                        audit["localBoundaryStatus"] = "no-closed-original-rgb-rim"
                        continue
                    }
                    body = measured.body
                    observedRasterSHA256 = measured.rasterSHA256
                } else {
                    guard let model = polygonBody(match.0, source: source, pixels: pixels, bands: bandCount,
                        inset: 0, tailFraction: p("tailWidthFraction", 0.15, 0.65)) else { continue }
                    let support = localPairedBoundary(match.0, pixels: pixels,
                        tolerance: Int(p("boundaryTolerancePixels", 1, 32)), contrast: max(48, delta), sampleSpacing: 4)
                    audit["localBoundarySamples"] = support.samples
                    audit["localBoundarySupportedSamples"] = support.supported
                    audit["localBoundaryStatus"] = support.status
                    guard support.status == "supported", support.samples >= 16,
                          support.supported == support.samples else { continue }
                    margin = max(2, inset) + 6 + support.maximumInwardOffset
                    method = "local-paired-inside-outside-original-rgb"
                    guard let contracted = contractLocalBody(model, source: source, pixels: pixels, margin: margin) else {
                        audit["localBoundaryStatus"] = "inward-body-does-not-retain-owner"
                        continue
                    }
                    body = contracted
                }
                // Same boundary-supported estimate authority as the established
                // path, with the distinct measurement method retained explicitly.
                let authority = "rf-polygon-original-rgb-boundary-supported"
                output[i]["balloonInterior"] = body.json
                output[i]["agent03BalloonEvidence"] = ["authority": authority,
                    "source": "original-rgb", "glyphGroundTruth": false, "sourceVerified": false,
                    "boundarySupportMethod": method,
                    "workingRasterInwardMarginPixels": margin]
                if certifying {
                    output[i][NativeSupportedEstimatedContour.receiptKey] = NativeSupportedEstimatedContour.receipt(
                        raw: output[i], sourceSHA256: page.sourceSHA256, regionsSHA256: regionsSHA256,
                        rasterSHA256: observedRasterSHA256)
                }
                audit["status"] = "attached-estimated-interior"
                audit["authority"] = authority
                audit["rfQueryID"] = match.0.queryID
                audit["spanCount"] = body.spans.count
                audit["localBoundaryInwardMarginPixels"] = margin
                audit["localBoundaryStatus"] = "supported"
                audit["boundarySupportMethod"] = method
                continue
            }
            // The uniform-paper path and all its thresholds remain unchanged.
            guard let paper else { continue }
            let roi = fallbackROI(source, expansion: p("fallbackExpansion", 2, 8),
                                  maxSide: p("fallbackMaxSide", 0.2, 1))
            let native = pixelBody(source: source, roi: roi, pixels: pixels, paper: paper,
                delta: delta, edgeRun: edgeRun, inset: inset, bands: bandCount,
                tailFraction: p("tailWidthFraction", 0.15, 0.65))
            var selected: Body?, authority = "", query: Int?
            if !ambiguous, let match = ranked.first,
               let model = polygonBody(match.0, source: source, pixels: pixels, bands: bandCount,
                                       inset: inset, tailFraction: p("tailWidthFraction", 0.15, 0.65)) {
                let support = boundarySupport(model, pixels: pixels, paper: paper,
                    delta: delta, tolerance: p("boundaryTolerancePixels", 1, 32), edgeRun: edgeRun)
                audit["rfBoundarySupport"] = support
                if support >= p("boundarySupport", 0.2, 1) {
                    selected = model
                    authority = "rf-polygon-original-rgb-boundary-supported"
                    query = match.0.queryID
                    // Only contract spans inward where the observed original
                    // boundary agrees spatially with the model; never expand it.
                    if let native, intersectionRatio(model.rect, native.rect) >= 0.7,
                       let refined = intersect(model, native, source: source) {
                        selected = refined
                        authority = "rf-polygon-contracted-to-original-rgb-boundary"
                    }
                }
            }
            if selected == nil, let native {
                selected = native
                authority = ambiguous ? "original-rgb-native-fallback-rf-conflict" : "original-rgb-native-fallback-rf-miss"
            }
            guard let body = selected else { audit["status"] = "no-supported-enclosure-preserved"; continue }
            output[i]["balloonInterior"] = body.json
            // Dedicated metadata does not assign common ownership or merge paragraphs.
            output[i]["agent03BalloonEvidence"] = ["authority": authority,
                "source": "original-rgb", "glyphGroundTruth": false, "sourceVerified": false]
            if let query { audit["rfQueryID"] = query }
            audit["status"] = "attached-estimated-interior"
            audit["authority"] = authority
            audit["spanCount"] = body.spans.count
        }
        return Ensemble100Proposal(items: output, audit: ["candidate": 3, "items": decisions,
            "evidenceAvailability": availability,
            "sourceEvidence": "automated original-RGB boundary measurements; no visual QA or glyph GT",
            "rasterWidth": pixels.width, "rasterHeight": pixels.height,
            "textAndParagraphsUnchanged": true])
    }

    private static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
    private static func rect(_ value: Any?) -> CGRect? {
        guard let a = value as? [Double], a.count == 4, a.allSatisfy(\.isFinite), a[2] > 0, a[3] > 0 else { return nil }
        let r = CGRect(x: a[0], y: a[1], width: a[2], height: a[3])
        return unit.contains(r) ? r : nil
    }
    private static func validRing(_ ring: [CGPoint]) -> Bool {
        ring.count >= 3 && ring.count <= 4096 && ring.allSatisfy {
            $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.x <= 1 && $0.y >= 0 && $0.y <= 1
        }
    }
    private static func intervals(_ y: Double, ring: [CGPoint]) -> [Span] {
        var crossings: [Double] = []
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            if (a.y > y) != (b.y > y) {
                crossings.append(a.x + (b.x - a.x) * (y - a.y) / (b.y - a.y))
            }
        }
        crossings.sort()
        return stride(from: 0, to: max(0, crossings.count - 1), by: 2).map {
            Span(left: crossings[$0], right: crossings[$0 + 1])
        }
    }
    private static func spans(_ y: Double, region: Ensemble100RFRegion) -> [Span] {
        var result = intervals(y, ring: region.exterior)
        for hole in region.holes {
            for cut in intervals(y, ring: hole) {
                result = result.flatMap { span -> [Span] in
                    if cut.right <= span.left || cut.left >= span.right { return [span] }
                    var pieces: [Span] = []
                    if cut.left > span.left { pieces.append(Span(left: span.left, right: cut.left)) }
                    if cut.right < span.right { pieces.append(Span(left: cut.right, right: span.right)) }
                    return pieces
                }
            }
        }
        return result
    }
    private static func contains(_ point: CGPoint, region: Ensemble100RFRegion) -> Bool {
        spans(point.y, region: region).contains { $0.left <= point.x && $0.right >= point.x }
    }
    private static func polygonBody(_ region: Ensemble100RFRegion, source: CGRect, pixels: Pixels,
                                    bands: Int, inset: Double, tailFraction: Double) -> Body? {
        let top = region.exterior.map(\.y).min()!, bottom = region.exterior.map(\.y).max()!
        guard bottom > top else { return nil }
        let step = (bottom - top) / Double(bands)
        let vertices = (region.exterior + region.holes.flatMap { $0 }).map(\.y).sorted()
        let rows: [Span?] = (0..<bands).map { row in
            let y0 = top + Double(row) * step, y1 = y0 + step
            let epsilon = step * 1e-5
            var samples = [y0 + epsilon, (y0 + y1) / 2, y1 - epsilon]
            // Vertex-adjacent samples preserve notches and small holes between
            // the regular bands. Linear polygon edges have extrema at vertices.
            for vertex in vertices where vertex > y0 && vertex < y1 {
                samples += [max(y0 + epsilon, vertex - epsilon), min(y1 - epsilon, vertex + epsilon)]
            }
            var left = 0.0, right = 1.0
            for y in samples {
                guard let run = spans(y, region: region).first(where: {
                    $0.left <= source.midX && $0.right >= source.midX
                }) else { return nil }
                left = max(left, run.left); right = min(right, run.right)
            }
            let result = Span(left: left + inset / Double(pixels.width), right: right - inset / Double(pixels.width))
            return result.width > 0 ? result : nil
        }
        return body(rows, top: top, step: step, source: source, tailFraction: tailFraction)
    }

    private struct LocalBoundarySupport {
        var samples = 0
        var supported = 0
        var maximumInwardOffset = 0.0
        var status = "unsupported-local-edge"
    }

    /// Thin closed rims need not survive whole-page downsampling. Reuse the
    /// same bounded witness on an original-resolution RF-local observation;
    /// coordinates remain original-source normalized throughout.
    private static func closedRimObservation(_ region: Ensemble100RFRegion, source: CGRect, original: CGImage,
                                             working: Pixels, bands: Int, tolerance: Int, margin: Double)
        -> (body: Body, rasterSHA256: String)? {
        let scale = max(Double(original.width) / Double(working.width), Double(original.height) / Double(working.height))
        let radius = Int(ceil(Double(tolerance) * scale))
        let padding = radius + 6
        let x0 = Int(floor(region.exterior.map(\.x).min()! * Double(original.width))) - padding
        let x1 = Int(ceil(region.exterior.map(\.x).max()! * Double(original.width))) + padding
        let y0 = Int(floor(region.exterior.map(\.y).min()! * Double(original.height))) - padding
        let y1 = Int(ceil(region.exterior.map(\.y).max()! * Double(original.height))) + padding
        guard x0 > 0, y0 > 0, x1 < original.width, y1 < original.height,
              x1 > x0, y1 > y0, (x1 - x0) * (y1 - y0) <= 250_000,
              let pixels = Pixels(original, window: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)),
              let measured = closedRimBody(region, source: source, pixels: pixels, bands: bands,
                  tolerance: radius, margin: margin * scale) else { return nil }
        return (measured, NativeSupportedEstimatedContour.rasterDigest(pixels.bytes))
    }

    /// Observe an actual closed dark rim, including on nonuniform/transparent
    /// interiors. Flooding starts outside the proposed search window; touching
    /// that window or the image edge is unknown, never artificial closure.
    /// The threshold is the existing source-contour strong-black observation.
    private static func closedRimBody(_ region: Ensemble100RFRegion, source: CGRect, pixels: Pixels,
                                      bands: Int, tolerance: Int, margin: Double) -> Body? {
        func trace(_ reason: String) {
            if ProcessInfo.processInfo.environment["AIDOKU_TRACE_COHORT"] == "1" {
                fputs("closed-rim \(reason)\n", stderr)
            }
        }
        guard region.holes.isEmpty else { return nil }
        let padding = tolerance + 6
        let x0 = Int(floor(region.exterior.map(\.x).min()! * Double(pixels.width))) - padding
        let x1 = Int(ceil(region.exterior.map(\.x).max()! * Double(pixels.width))) + padding
        let y0 = Int(floor(region.exterior.map(\.y).min()! * Double(pixels.height))) - padding
        let y1 = Int(ceil(region.exterior.map(\.y).max()! * Double(pixels.height))) + padding
        let w = x1 - x0, h = y1 - y0
        guard x0 > 0, y0 > 0, x1 < pixels.width, y1 < pixels.height,
              w >= 8, h >= 8, w * h <= 250_000 else { return nil }
        var rim = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w {
            guard let color = pixels.rgb(x0 + x, y0 + y) else { trace("unknown-pixel x=\(x0+x) y=\(y0+y)"); return nil }
            if max(color.r, max(color.g, color.b)) < 60 { rim[y * w + x] = 1 }
        } }
        var outside = [UInt8](repeating: 0, count: w * h), queue = [Int](repeating: 0, count: w * h)
        var read = 0, count = 0
        func seed(_ at: Int) {
            if rim[at] == 0 && outside[at] == 0 { outside[at] = 1; queue[count] = at; count += 1 }
        }
        for x in 0..<w { seed(x); seed((h - 1) * w + x) }
        for y in 0..<h { seed(y * w); seed(y * w + w - 1) }
        while read < count {
            let at = queue[read], x = at % w, y = at / w
            read += 1
            // Eight-neighbour leakage is deliberately conservative: a diagonal
            // pinhole may not be filled into a fabricated closed boundary.
            for dy in -1...1 { for dx in -1...1 {
                let xx = x + dx, yy = y + dy
                if xx >= 0 && xx < w && yy >= 0 && yy < h { seed(yy * w + xx) }
            } }
        }
        let owner = CGRect(x: source.minX * Double(pixels.width) - Double(x0),
            y: source.minY * Double(pixels.height) - Double(y0),
            width: source.width * Double(pixels.width), height: source.height * Double(pixels.height))
        let area = owner.width * owner.height
        guard area > 0 else { return nil }
        var labels = [Int](repeating: 0, count: w * h), label = 0, selected = 0, bestCoverage = 0.0
        for start in labels.indices where outside[start] == 0 && labels[start] == 0 {
            label += 1; read = 0; count = 1; queue[0] = start; labels[start] = label
            var covered = 0.0, interior = 0, touchesEdge = false
            while read < count {
                let at = queue[read], x = at % w, y = at / w
                read += 1
                if rim[at] == 0 { interior += 1 }
                if owner.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) { covered += 1 }
                if x == 0 || y == 0 || x == w - 1 || y == h - 1 { touchesEdge = true }
                for (xx, yy) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                    guard xx >= 0, xx < w, yy >= 0, yy < h else { continue }
                    let next = yy * w + xx
                    if outside[next] == 0 && labels[next] == 0 {
                        labels[next] = label; queue[count] = next; count += 1
                    }
                }
            }
            // These are owner-support/topology checks, not a paper histogram.
            if !touchesEdge, covered >= area * 0.9, Double(count) >= area * 1.2,
               interior >= count / 2, covered > bestCoverage {
                selected = label; bestCoverage = covered
            }
        }
        guard selected > 0 else { trace("no-owned-enclosure components=\(label) ownerArea=\(area)"); return nil }
        let step = Double(h) / Double(bands)
        var rows: [Span?] = []
        for band in 0..<bands {
            let first = Int(floor(Double(band) * step))
            let last = min(h - 1, Int(ceil(Double(band + 1) * step)) - 1)
            var left = 0, right = w - 1, valid = true
            for y in first...last {
                let free = (0..<w).filter { labels[y * w + $0] == selected && rim[y * w + $0] == 0 }
                guard let lo = free.first, let hi = free.last, lo < hi,
                      (lo...hi).allSatisfy({ labels[y * w + $0] == selected }) else { valid = false; break }
                left = max(left, lo); right = min(right, hi)
            }
            rows.append(valid && left < right ? Span(left: Double(x0 + left) / Double(pixels.width),
                right: Double(x0 + right + 1) / Double(pixels.width)) : nil)
        }
        guard let measured = body(rows, top: Double(y0) / Double(pixels.height),
            step: step / Double(pixels.height), source: source, tailFraction: 0) else { trace("no-connected-bands"); return nil }
        guard intersectionRatio(measured.rect, region.bounds) >= 0.7 else { trace("rf-extent-conflict"); return nil }
        let result = contractLocalBody(measured, source: source, pixels: pixels, margin: margin)
        if result == nil { trace("inward-body-does-not-retain-owner") }
        return result
    }

    /// Search only beside the existing polygon, never across the page. Stable
    /// paired patches reject smooth gradients and texture masquerading as a rim;
    /// either a sharp inside/outside step or a narrow contrasting rim is needed.
    private static func localPairedBoundary(_ region: Ensemble100RFRegion, pixels: Pixels,
                                            tolerance: Int, contrast: Int, sampleSpacing: Double) -> LocalBoundarySupport {
        var result = LocalBoundarySupport()
        let rings = [region.exterior] + region.holes
        var budget = 0
        for ring in rings {
            for i in ring.indices {
                let a = ring[i], b = ring[(i + 1) % ring.count]
                let length = hypot((b.x - a.x) * Double(pixels.width), (b.y - a.y) * Double(pixels.height))
                budget += max(1, Int(ceil(length / sampleSpacing)))
                guard budget <= 2048 else { result.status = "local-edge-budget-exceeded"; return result }
            }
        }
        let offsets = [0] + (1...tolerance).flatMap { [$0, -$0] }
        for ring in rings {
            for i in ring.indices {
                let a = CGPoint(x: ring[i].x * Double(pixels.width), y: ring[i].y * Double(pixels.height))
                let b = CGPoint(x: ring[(i + 1) % ring.count].x * Double(pixels.width),
                                y: ring[(i + 1) % ring.count].y * Double(pixels.height))
                let length = hypot(b.x - a.x, b.y - a.y)
                guard length > 0 else { result.status = "degenerate-local-edge"; return result }
                let tx = (b.x - a.x) / length, ty = (b.y - a.y) / length
                let count = max(1, Int(ceil(length / sampleSpacing)))
                for sample in 0..<count {
                    result.samples += 1
                    let fraction = (Double(sample) + 0.5) / Double(count)
                    let x = a.x + (b.x - a.x) * fraction, y = a.y + (b.y - a.y) * fraction
                    var nx = -ty, ny = tx
                    func owned(_ sign: Double) -> Bool {
                        contains(CGPoint(x: (x + sign * nx * 0.75) / Double(pixels.width),
                                         y: (y + sign * ny * 0.75) / Double(pixels.height)), region: region)
                    }
                    let plus = owned(1), minus = owned(-1)
                    guard plus != minus else { return result }
                    if !plus { nx = -nx; ny = -ny }
                    var found: Int?
                    for offset in offsets {
                        let cx = x + nx * Double(offset), cy = y + ny * Double(offset)
                        func color(_ depth: Double, _ tangent: Double = 0) -> RGB? {
                            pixels.rgb(Int(floor(cx + nx * depth + tx * tangent)),
                                       Int(floor(cy + ny * depth + ty * tangent)))
                        }
                        guard let inside = color(4), let outside = color(-4), let rim = color(0) else { continue }
                        // Small patches must be locally coherent on BOTH sides.
                        // Contrast alone would happily accept arbitrary texture.
                        let stable = [-1.0, 0, 1].allSatisfy { tangent in
                            [3.0, 4, 5].allSatisfy { depth in
                                guard let inner = color(depth, tangent), let outer = color(-depth, tangent) else { return false }
                                return inner.distance(inside) <= 18 && outer.distance(outside) <= 18
                            }
                        }
                        guard stable else { continue }
                        let step: Bool
                        if let nearInside = color(1), let nearOutside = color(-1) {
                            step = inside.distance(outside) >= contrast && nearInside.distance(nearOutside) >= contrast
                        } else { step = false }
                        let ridge = rim.distance(inside) >= contrast && rim.distance(outside) >= contrast &&
                            [-1.0, 0, 1].allSatisfy { tangent in
                                guard let value = color(0, tangent) else { return false }
                                return value.distance(rim) <= 18
                            }
                        if step || ridge { found = offset; break }
                    }
                    guard let found else { return result }
                    result.supported += 1
                    result.maximumInwardOffset = max(result.maximumInwardOffset, Double(found))
                }
            }
        }
        result.status = "supported"
        return result
    }

    /// Erode across neighbouring rows as well as horizontally. This preserves
    /// polygon notches/holes and provides an inward margin at top/bottom rims;
    /// merely shrinking the bounding rectangle would fill curved obstacles.
    private static func contractLocalBody(_ model: Body, source: CGRect, pixels: Pixels, margin: Double) -> Body? {
        let dx = margin / Double(pixels.width), dy = margin / Double(pixels.height)
        let step = model.rect.height / Double(model.spans.count)
        var rows: [Span?] = []
        for i in model.spans.indices {
            let y0 = model.rect.minY + Double(i) * step - dy
            let y1 = model.rect.minY + Double(i + 1) * step + dy
            guard y0 >= model.rect.minY, y1 <= model.rect.maxY else { rows.append(nil); continue }
            let first = max(0, Int(floor((y0 - model.rect.minY) / step)))
            let last = min(model.spans.count - 1, Int(ceil((y1 - model.rect.minY) / step)) - 1)
            let neighbours = model.spans[first...last]
            let left = neighbours.map(\.left).max()! + dx, right = neighbours.map(\.right).min()! - dx
            rows.append(right > left ? Span(left: left, right: right) : nil)
        }
        guard let result = body(rows, top: model.rect.minY, step: step, source: source, tailFraction: 0) else { return nil }
        // Include partially touched source bands too, not just their centres.
        for (i, span) in result.spans.enumerated() {
            let y0 = result.rect.minY + Double(i) * step, y1 = y0 + step
            if y0 < source.maxY && y1 > source.minY &&
                (span.left > source.minX || span.right < source.maxX) { return nil }
        }
        return result
    }

    private static func paperColor(_ source: CGRect, pixels: Pixels, delta: Int, agreement: Double) -> RGB? {
        let dx = max(2 / Double(pixels.width), source.width * 0.08)
        let dy = max(2 / Double(pixels.height), source.height * 0.08)
        var samples: [RGB] = []
        for i in 0..<16 {
            let t = (Double(i) + 0.5) / 16
            let points = [CGPoint(x: source.minX + t * source.width, y: source.minY - dy),
                          CGPoint(x: source.minX + t * source.width, y: source.maxY + dy),
                          CGPoint(x: source.minX - dx, y: source.minY + t * source.height),
                          CGPoint(x: source.maxX + dx, y: source.minY + t * source.height)]
            samples += points.compactMap { pixels.rgb($0) }
        }
        guard samples.count >= 32 else { return nil }
        let radius = delta / 2
        var support = [Int](repeating: 1, count: samples.count) // Each sample supports itself.
        for i in samples.indices {
            for j in (i + 1)..<samples.endIndex where samples[i].distance(samples[j]) <= radius {
                support[i] += 1; support[j] += 1
            }
        }
        let best = samples[support.indices.max { support[$0] < support[$1] }!]
        let cluster = samples.filter { $0.distance(best) <= radius }
        guard Double(cluster.count) / Double(samples.count) >= agreement else { return nil }
        return RGB(r: cluster.map(\.r).sorted()[cluster.count / 2],
                   g: cluster.map(\.g).sorted()[cluster.count / 2], b: cluster.map(\.b).sorted()[cluster.count / 2])
    }
    private static func fallbackROI(_ source: CGRect, expansion: Double, maxSide: Double) -> CGRect {
        let w = max(source.width, min(maxSide, source.width * expansion))
        let h = max(source.height, min(maxSide, source.height * expansion))
        return CGRect(x: source.midX - w / 2, y: source.midY - h / 2, width: w, height: h).intersection(unit)
    }
    private static func pixelBody(source: CGRect, roi: CGRect, pixels: Pixels, paper: RGB,
                                  delta: Int, edgeRun: Int, inset: Double, bands: Int, tailFraction: Double) -> Body? {
        let step = roi.height / Double(bands)
        let anchor = Int(source.midX * Double(pixels.width))
        let lo = max(0, Int(roi.minX * Double(pixels.width)))
        let hi = min(pixels.width - 1, Int(roi.maxX * Double(pixels.width)))
        let rows: [Span?] = (0..<bands).map { row in
            let y0 = roi.minY + Double(row) * step
            let y1 = y0 + step
            // Intersect every working-raster row in this height band, including
            // both band limits; a narrow obstacle cannot vanish between samples.
            let firstY = max(0, Int(floor(y0 * Double(pixels.height))))
            let lastY = min(pixels.height - 1, Int(floor(y1 * Double(pixels.height))))
            guard firstY <= lastY else { return nil }
            var leftBound = 0.0, rightBound = 1.0
            for y in firstY...lastY {
                let yn = (Double(y) + 0.5) / Double(pixels.height)
                func edge(_ direction: Int) -> Int? {
                    var x = anchor, bad = 0
                    while x >= lo && x <= hi {
                        let point = CGPoint(x: (Double(x) + 0.5) / Double(pixels.width), y: yn)
                        let owned = source.contains(point)
                        guard let color = pixels.rgb(x, y) else { return nil }
                        if !owned && color.distance(paper) > delta { bad += 1 } else { bad = 0 }
                        if bad >= edgeRun { return x - direction * (edgeRun - 1) }
                        x += direction
                    }
                    return nil // Open page/search boundary is not an enclosure.
                }
                guard let left = edge(-1), let right = edge(1) else { return nil }
                leftBound = max(leftBound, (Double(left) + 1 + inset) / Double(pixels.width))
                rightBound = min(rightBound, (Double(right) - inset) / Double(pixels.width))
            }
            let span = Span(left: leftBound, right: rightBound)
            return span.width > 0 ? span : nil
        }
        // A native fallback needs observed closure above and below the text.
        guard let first = rows.firstIndex(where: { $0 != nil }),
              let last = rows.lastIndex(where: { $0 != nil }), first > 0, last < bands - 1 else { return nil }
        let yPad = Double(edgeRun + 1) / Double(pixels.height)
        guard let result = body(rows, top: roi.minY, step: step, source: source, tailFraction: tailFraction),
              result.rect.minY > roi.minY + yPad, result.rect.maxY < roi.maxY - yPad else { return nil }
        return result
    }
    private static func body(_ rows: [Span?], top: Double, step: Double, source: CGRect, tailFraction: Double) -> Body? {
        let seed = min(rows.count - 1, max(0, Int((source.midY - top) / step)))
        guard let middle = rows[seed], middle.left <= source.midX, middle.right >= source.midX else { return nil }
        let maximum = rows.compactMap { $0?.width }.max() ?? 0
        let minimum = maximum * tailFraction
        func connected(_ a: Int, _ b: Int) -> Bool {
            guard let first = rows[a], let next = rows[b], next.width >= minimum else { return false }
            return min(first.right, next.right) - max(first.left, next.left) > min(first.width, next.width) * 0.4
        }
        var first = seed, last = seed
        while first > 0 && connected(first, first - 1) { first -= 1 }
        while last + 1 < rows.count && connected(last, last + 1) { last += 1 }
        guard last - first >= 5 else { return nil }
        let bands = (first...last).compactMap { rows[$0] }
        let left = bands.map(\.left).min()!, right = bands.map(\.right).max()!
        let box = CGRect(x: left, y: top + Double(first) * step, width: right - left, height: Double(bands.count) * step)
        // An estimate must encompass its own OCR support, not only its centroid.
        guard unit.contains(box), box.contains(source), bands.allSatisfy({ $0.width > 0 }) else { return nil }
        for (i, span) in bands.enumerated() {
            let y = box.minY + (Double(i) + 0.5) * step
            if y >= source.minY && y <= source.maxY &&
                (span.left > source.minX || span.right < source.maxX) { return nil }
        }
        return Body(rect: box, spans: bands)
    }
    private static func boundarySupport(_ body: Body, pixels: Pixels, paper: RGB,
                                         delta: Int, tolerance: Double, edgeRun: Int) -> Double {
        var support = 0, count = 0
        for i in stride(from: 0, to: body.spans.count, by: max(1, body.spans.count / 24)) {
            let y = Int((body.rect.minY + (Double(i) + 0.5) * body.rect.height / Double(body.spans.count)) * Double(pixels.height))
            for (x, direction) in [(body.spans[i].left, -1), (body.spans[i].right, 1)] {
                count += 1
                let center = Int(x * Double(pixels.width))
                var found = false
                for offset in -Int(tolerance)...Int(tolerance) {
                    let candidate = center + offset
                    // Evidence is a transition FROM this balloon's paper INTO
                    // a boundary, rather than any dark pixel near an RF edge.
                    guard let inside = pixels.rgb(candidate - direction * 2, y), inside.distance(paper) <= delta else { continue }
                    let boundary = (0..<edgeRun).allSatisfy { k in
                        guard let color = pixels.rgb(candidate + direction * k, y) else { return false }
                        return color.distance(paper) > delta
                    }
                    if boundary { found = true; break }
                }
                if found { support += 1 }
            }
        }
        return count > 0 ? Double(support) / Double(count) : 0
    }
    private static func intersectionRatio(_ a: CGRect, _ b: CGRect) -> Double {
        let overlap = a.intersection(b)
        return overlap.isNull ? 0 : overlap.width * overlap.height / max(a.width * a.height, b.width * b.height)
    }
    private static func intersect(_ a: Body, _ b: Body, source: CGRect) -> Body? {
        var rows: [Span?] = []
        let step = a.rect.height / Double(a.spans.count)
        for (i, span) in a.spans.enumerated() {
            // Require the entire model band inside the native vertical range.
            let y0 = a.rect.minY + Double(i) * step, y1 = y0 + step
            guard y0 >= b.rect.minY, y1 <= b.rect.maxY else { rows.append(nil); continue }
            let first = max(0, Int((y0 - b.rect.minY) / b.rect.height * Double(b.spans.count)))
            let last = min(b.spans.count - 1, Int((y1 - b.rect.minY) / b.rect.height * Double(b.spans.count)))
            let peers = b.spans[first...last]
            let intersection = Span(left: max(span.left, peers.map(\.left).max()!),
                                    right: min(span.right, peers.map(\.right).min()!))
            rows.append(intersection.width > 0 ? intersection : nil)
        }
        return body(rows, top: a.rect.minY, step: step, source: source, tailFraction: 0)
    }
}
