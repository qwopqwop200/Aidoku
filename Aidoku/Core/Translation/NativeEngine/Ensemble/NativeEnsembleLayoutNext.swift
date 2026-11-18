import CoreGraphics
import CoreText
import Foundation

/// Independent v2: score every feasible discrete width/font/leading/anchor candidate. CoreText shared by iOS and macOS.
enum EnsembleCandidate04Next: Ensemble100Candidate {
    static let defaults: [String: Double] = [
        "enabled": 1, "minFontScale": 0.65, "maxFontScale": 1, "fontSteps": 6, "widthSteps": 4,
        "leading": 1.12, "maximumLeading": 1.60, "leadingSteps": 2,
        "strokeFraction": 0.20, "minimumStrokePixels": 2, "safetyPixels": 1,
        "rfConfidence": 0.65, "rfCoverage": 0.85, "rfConflictMargin": 0.10,
        "pixelTolerance": 42, "bodyWidthFraction": 0.65, "maximumWidthGrowth": 2,
        "lineWeight": 1.6, "singletonWeight": 5, "shrinkWeight": 32,
        "sourceDriftWeight": 3, "bodyCenterWeight": 0.8, "widthGrowthWeight": 0.3,
        "haloOverlapWeight": 6, "fillIntrusionWeight": 10, "leadingWeight": 0.5,
        "maxFillIntrusion": 0.20, "maxBalloonDrift": 0.40,
        "useSourceInkAnchor": 0, "sourceAnchorReachEm": 0.75, "sourceAnchorDriftEm": 0.75,
        "emergencyMinFontScale": 0, "limitUnverifiedTripleSourceEnvelope": 1
    ]

    private struct Span {
        var left: CGFloat
        var right: CGFloat
    }
    private struct Space {
        var rect: CGRect
        var spans: [Span]
        var authority: String

        func contains(_ r: CGRect) -> Bool {
            guard r.width > 0, r.height > 0, rect.contains(r) else { return false }
            if spans.isEmpty { return true }
            let step = rect.height / CGFloat(spans.count)
            let first = max(0, Int(floor((r.minY - rect.minY) / step)))
            let last = min(spans.count - 1, Int(floor((r.maxY - rect.minY - 0.0001) / step)))
            guard first <= last else { return false }
            return (first...last).allSatisfy { spans[$0].left <= r.minX && spans[$0].right >= r.maxX }
        }

        var bodyCenterY: CGFloat {
            guard let widest = spans.map({ $0.right - $0.left }).max(), widest > 0 else { return rect.midY }
            var total: CGFloat = 0, weighted: CGFloat = 0
            for (i, span) in spans.enumerated() where span.right - span.left >= widest * 0.65 {
                let width = span.right - span.left
                total += width
                weighted += (rect.minY + (CGFloat(i) + 0.5) * rect.height / CGFloat(spans.count)) * width
            }
            return total > 0 ? weighted / total : rect.midY
        }
    }

    private struct Layout {
        let text: String
        let box: CGRect
        let font: CGFloat
        let pitch: CGFloat
        let rows: [CGRect] // final shaped glyph extents plus compulsory halo and AA margin
        let radius: CGFloat
        let inkRows: [CGRect]
        let singletons: Int
    }

    private struct Choice {
        let layout: Layout
        let score: Double
        let terms: [String: Double]
        let drift: CGFloat
    }

    /// Agent02Next v1 values are viewport coordinates; this is a placement constraint, never grouping authority.
    private struct SourceNear {
        struct Neighbor {
            let anchor: CGRect
            let halo: CGFloat
            let axis: String
            let separator: CGFloat
            let clearance: CGFloat
        }
        struct Polygon {
            let exterior: [CGPoint]
            let holes: [[CGPoint]]
        }
        let owner: String
        let allowed: CGRect
        let anchor: CGRect
        let drift: CGFloat
        let halo: CGFloat
        let neighbors: [Neighbor]
        let polygons: [Polygon]
        let vertical: NativeSourceNearVerticalAnchor

        func permits(_ rows: [CGRect]) -> Bool {
            let block = EnsembleCandidate04Next.union(rows)
            guard vertical.permits(block:block,anchor:anchor,centerDrift:drift) else { return false }
            return rows.allSatisfy { row in
                guard allowed.contains(row) else { return false }
                for neighbor in neighbors {
                    guard !row.intersects(neighbor.anchor.insetBy(dx: -neighbor.halo, dy: -neighbor.halo)) else { return false }
                    let before = neighbor.axis == "x" ? anchor.midX < neighbor.anchor.midX : anchor.midY < neighbor.anchor.midY
                    let low = neighbor.axis == "x" ? row.minX : row.minY
                    let high = neighbor.axis == "x" ? row.maxX : row.maxY
                    if before && high > neighbor.separator - neighbor.clearance / 2 + 1e-7 { return false }
                    if !before && low < neighbor.separator + neighbor.clearance / 2 - 1e-7 { return false }
                }
                // A single polygon must contain the entire row; disconnected parts cannot fill each other's holes.
                return polygons.isEmpty || polygons.contains { EnsembleCandidate04Next.contains(row, polygon: $0) }
            }
        }
    }

    /// Small restored-pixel witness for model contours; no balloon inference or image output.
    private struct Pixels {
        let bytes: [UInt8]
        let width: Int
        let height: Int
        init?(_ image: CGImage, explicitSampling: Bool = false) {
            let ratio = min(1, 256 / CGFloat(max(image.width, image.height)))
            let width = max(1, Int(CGFloat(image.width) * ratio))
            let height = max(1, Int(CGFloat(image.height) * ratio))
            var data = [UInt8](repeating: 0, count: width * height * 4)
            let ok = data.withUnsafeMutableBytes { bytes -> Bool in
                guard let c = CGContext(data: bytes.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                c.translateBy(x: 0, y: CGFloat(height)); c.scaleBy(x: 1, y: -1)
                // Coordinate-paired witnesses must not inherit the provider's
                // shouldInterpolate flag (PNG vs resident RGB24 differ). Keep
                // the established legacy sampler unchanged for other callers.
                if explicitSampling { c.interpolationQuality = .none }
                c.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard ok else { return nil }
            self.width = width; self.height = height
            self.bytes = data
        }
        func color(_ point: CGPoint, viewport: CGSize) -> [CGFloat] {
            let x = min(width - 1, max(0, Int(point.x / viewport.width * CGFloat(width))))
            let y = min(height - 1, max(0, Int(point.y / viewport.height * CGFloat(height))))
            let start = (y * width + x) * 4
            return (0..<3).map { CGFloat(bytes[start + $0]) }
        }
        func supports(_ space: Space, source: CGRect, viewport: CGSize, tolerance: CGFloat) -> Bool {
            let reference = color(CGPoint(x: source.midX, y: source.midY), viewport: viewport)
            var matches = 0, tested = 0
            for iy in 1...5 {
                let y = space.rect.minY + space.rect.height * CGFloat(iy) / 6
                for ix in 1...5 {
                    let x = space.rect.minX + space.rect.width * CGFloat(ix) / 6
                    let r = CGRect(x: x - 0.01, y: y - 0.01, width: 0.02, height: 0.02)
                    guard space.contains(r) else { continue }
                    tested += 1
                    let sample = color(CGPoint(x: x, y: y), viewport: viewport)
                    if zip(reference, sample).allSatisfy({ abs($0 - $1) <= tolerance }) { matches += 1 }
                }
            }
            return tested >= 5 && Double(matches) / Double(tested) >= 0.72
        }
        /// Background homogeneity witness only, NOT boundary or glyph truth.
        /// Original text cannot vote for paper: exclude OCR envelopes with a
        /// downsample-footprint moat, then choose a robust observed medoid.
        func backgroundSupport(_ space: Space, excluding owners: [CGRect], viewport: CGSize,
                               tolerance: CGFloat) -> (supported: Bool, audit: [String:Any]) {
            let moat = max(viewport.width/CGFloat(width),viewport.height/CGFloat(height))*1.5
            let excluded = owners.map { $0.insetBy(dx:-moat,dy:-moat) }
            var samples: [[CGFloat]] = []
            for iy in 1...11 { for ix in 1...11 {
                let point = CGPoint(x:space.rect.minX+space.rect.width*CGFloat(ix)/12,
                    y:space.rect.minY+space.rect.height*CGFloat(iy)/12)
                guard space.contains(CGRect(x:point.x-0.01,y:point.y-0.01,width:0.02,height:0.02)),
                      !excluded.contains(where: { $0.contains(point) }) else { continue }
                samples.append(color(point,viewport:viewport))
            } }
            guard samples.count >= 5 else {
                return (false,["measured":false,"samples":samples.count,"reason":"insufficient-original-nonglyph-context"])
            }
            func matches(_ a: [CGFloat], _ b: [CGFloat]) -> Bool { zip(a,b).allSatisfy { abs($0-$1)<=tolerance } }
            let scored = samples.map { candidate in (candidate,samples.filter { matches(candidate,$0) }.count) }
            let best = scored.max { $0.1 < $1.1 }!
            let supported = Double(best.1)/Double(samples.count)>=0.72
            return (supported,["measured":true,"samples":samples.count,"matched":best.1,
                "referenceRGB":best.0.map(Double.init),"supported":supported,
                "authority":"original-coordinate background medoid outside expanded OCR envelopes; not boundary/optical/glyph gold"])
        }
        func backgroundAgreement(_ other: Pixels, space: Space, excluding owners: [CGRect], viewport: CGSize) -> (supported:Bool,audit:[String:Any]) {
            let moat = max(viewport.width/CGFloat(width),viewport.height/CGFloat(height))*1.5
            let excluded = owners.map { $0.insetBy(dx:-moat,dy:-moat) }
            var tested=0, matched=0
            for iy in 1...11 { for ix in 1...11 {
                let point=CGPoint(x:space.rect.minX+space.rect.width*CGFloat(ix)/12,
                    y:space.rect.minY+space.rect.height*CGFloat(iy)/12)
                guard space.contains(CGRect(x:point.x-0.01,y:point.y-0.01,width:0.02,height:0.02)),
                      !excluded.contains(where: { $0.contains(point) }) else { continue }
                tested += 1
                if zip(color(point,viewport:viewport),other.color(point,viewport:viewport)).allSatisfy({ abs($0-$1)<=6 }) { matched += 1 }
            } }
            let supported=tested>=5 && Double(matched)/Double(max(1,tested))>=0.9
            return (supported,["measured":tested>=5,"samples":tested,"matched":matched,"supported":supported,
                "authority":"original/restored coordinate-paired samples outside expanded OCR envelopes; not uniform-paper or reconstruction-quality gold"])
        }
    }

    static func apply(_ page: Ensemble100Page, parameters: [String: Double]) throws -> Ensemble100Proposal {
        try apply(page, parameters: parameters, originalBoundaryVerifier: nil)
    }

    /// Main may provide a synchronous source-bound verifier, never a serialized trust flag.
    static func apply(_ page: Ensemble100Page, parameters: [String: Double],
                      originalBoundaryVerifier: (([String: Any]) -> Bool)?) throws -> Ensemble100Proposal {
        let fragmentWidths = FragmentWidths()
        var p = defaults.merging(parameters) { old, new in new.isFinite ? new : old }
        let limits: [String: ClosedRange<Double>] = [
            "minFontScale": 0.25...1, "maxFontScale": 0.25...1, "fontSteps": 1...16, "widthSteps": 1...12,
            "leading": 1...2.5, "maximumLeading": 1...2.5, "leadingSteps": 1...4,
            "strokeFraction": 0.20...0.5, "minimumStrokePixels": 2...12, "safetyPixels": 0.5...8,
            "rfConfidence": 0...1, "rfCoverage": 0...1, "rfConflictMargin": 0...1,
            "pixelTolerance": 0...255, "bodyWidthFraction": 0.3...0.95, "maximumWidthGrowth": 1...3,
            "maxFillIntrusion": 0...0.5, "maxBalloonDrift": 0...1,
            "sourceAnchorReachEm": 0...3, "sourceAnchorDriftEm": 0...3, "emergencyMinFontScale": 0...1
        ]
        for (key, range) in limits { p[key] = min(range.upperBound, max(range.lowerBound, p[key]!)) }
        for key in defaults.keys where key.hasSuffix("Weight") { p[key] = min(1000, max(0, p[key]!)) }
        p["minFontScale"] = min(p["minFontScale"]!, p["maxFontScale"]!)
        guard p["enabled"]! > 0 else {
            return Ensemble100Proposal(items: page.items, audit: ["agent04Next": "disabled"])
        }
        let viewport = page.viewport
        guard viewport.width.isFinite, viewport.height.isFinite, viewport.width > 0, viewport.height > 0 else {
            return Ensemble100Proposal(items: page.items, audit: ["agent04Next": "invalid-viewport; all items retained"])
        }
        let bounds = CGRect(origin: .zero, size: viewport)
        let outputScale = min(CGFloat(page.original.width) / viewport.width, CGFloat(page.original.height) / viewport.height)
        let pixels = page.rfRegions.contains(where: { $0.classID == 2 && !$0.exterior.isEmpty }) ||
            page.items.contains(where: { ($0["balloonInterior"] as? [String: Any])?["modelEstimated"] as? Bool == true })
            ? Pixels(page.restored) : nil
        let peerRects = page.items.map { rect($0) }
        var accepted: [Int: [CGRect]] = [:]
        var output = page.items
        var audit: [[String: Any]] = []
        for index in page.items.indices {
            let item = page.items[index]
            func record(_ status: String, _ extra: [String: Any] = [:]) {
                var row = extra; row["index"] = index; row["status"] = status; audit.append(row)
            }
            guard let text = item["text"] as? String, !text.isEmpty else { record("unchanged-empty-text"); continue }
            guard item["keptLettering"] as? Bool != true, item["sourceTextOnly"] as? Bool != true else {
                record("unchanged-preserved-source"); continue
            }
            guard number(item["rotation"]) == nil || abs(number(item["rotation"])!) < 0.001,
                item["vertical"] as? Bool != true else { record("unchanged-unsupported-rotation-or-vertical"); continue }
            guard let base = peerRects[index], let font = number(item["fontSize"]), font > 0, font <= 1000,
                [base.minX, base.minY, base.maxX, base.maxY].allSatisfy(\.isFinite),
                bounds.intersects(base), text.utf16.count <= 8192 else {
                record("unchanged-invalid-geometry-or-text-budget"); continue
            }
            let inputPitch = number(item["lineHeight"]) ?? font * 1.12
            guard inputPitch > 0, inputPitch <= font * 4 else { record("unchanged-invalid-leading"); continue }
            var near: SourceNear?
            if item["sourceNearLayout"] != nil {
                guard let parsed = sourceNear(item, index: index, items: page.items, viewport: viewport) else {
                    record("unchanged-invalid-or-infeasible-source-near-contract",
                        ["qualityStatus": "unknown-unresolved; input retained; no successful fit claimed"]); continue
                }
                near = parsed
            }
            let source = normalizedRect(item["sourceBounds"], viewport: viewport)
            var space = Space(rect: base.intersection(bounds), spans: [], authority: "existing-layout-heuristic")
            var evidence = "no-supported-contour"
            if let source {
                if let native = nativeSpace(item, viewport: viewport), native.contains(source) {
                    if native.authority != "native-contour", originalBoundaryVerifier?(item) == true {
                        space = native; evidence = "item-contour-rechecked-original-boundary"
                    } else if native.authority == "native-contour" || pixels?.supports(native, source: source,
                        viewport: viewport, tolerance: CGFloat(p["pixelTolerance"]!)) == true {
                        space = native; evidence = "item-contour"
                    } else { evidence = "model-item-contour-pixel-conflict" }
                } else {
                    let choices = page.rfRegions.compactMap { region -> (Space, Double)? in
                        guard region.classID == 2, region.confidence.isFinite,
                              region.confidence >= p["rfConfidence"]!, let candidate = rfSpace(region, source: source,
                                  viewport: viewport, bodyFraction: CGFloat(p["bodyWidthFraction"]!)) else { return nil }
                        let coverage = support(candidate, source: source)
                        guard coverage >= p["rfCoverage"]! else { return nil }
                        return (candidate, coverage * region.confidence)
                    }.sorted { $0.1 > $1.1 }
                    if let best = choices.first {
                        if choices.count > 1 && best.1 - choices[1].1 < p["rfConflictMargin"]! {
                            evidence = "rf-ownership-conflict"
                        } else if pixels?.supports(best.0, source: source, viewport: viewport,
                            tolerance: CGFloat(p["pixelTolerance"]!)) == true {
                            space = best.0; evidence = "rf-with-source-and-restored-pixel-support"
                        } else { evidence = "rf-pixel-conflict" }
                    }
                }
            }

            let balloon = space.authority != "existing-layout-heuristic"
            if balloon,near?.vertical.sourceTop==true {
                record("unchanged-conflicting-top-anchor-and-supported-balloon",
                    ["qualityStatus":"source top proposal rejected; supported balloon keeps centering authority"])
                continue
            }
            let sourceInkEnabled = p["useSourceInkAnchor"]! > 0
            let useSourceAnchor = sourceInkEnabled && !balloon && near == nil && source != nil
            let placementAnchor = near?.anchor ?? (useSourceAnchor ? source : nil)
            let placementDrift = near?.drift ?? font * CGFloat(p["sourceAnchorDriftEm"]!)
            // A local OCR domain can provide room beyond 02Next's estimated preferredRect without asserting a balloon.
            if let near, !balloon { space.rect = near.allowed }
            if useSourceAnchor, let source {
                let reach = font * CGFloat(p["sourceAnchorReachEm"]!)
                space.rect = CGRect(x: source.midX - max(base.width, source.width) / 2 - reach,
                    y: source.minY - reach, width: max(base.width, source.width) + 2 * reach,
                    height: max(source.height, font * 2) + 2 * reach).intersection(bounds)
            }
            // A source grid certifies column order, not extra balloon space.
            // Without a supported contour, fit glyph+mandatory stroke inside
            // the original source envelope before considering font growth.
            if p["limitUnverifiedTripleSourceEnvelope"]! > 0, !balloon,
               (item["sourceLocalTripleGrid"] as? Bool == true || item["sourceAxisRequiresFreshShaping"] as? Bool == true), let source {
                space.rect = space.rect.intersection(source)
                evidence = item["sourceAxisRequiresFreshShaping"] as? Bool == true
                    ? "original-axis-envelope-only; balloon-containment-unverified"
                    : "original-triple-envelope-only; balloon-containment-unverified"
            }
            var top = max(space.rect.minY, near?.allowed.minY ?? space.rect.minY)
            var bottom = min(space.rect.maxY, near?.allowed.maxY ?? space.rect.maxY)
            var shared = false
            if balloon, let source {
                for other in page.items.indices where other != index {
                    guard let s = normalizedRect(page.items[other]["sourceBounds"], viewport: viewport),
                        let t = page.items[other]["text"] as? String, !t.isEmpty, support(space, source: s) >= 0.85 else { continue }
                    shared = true
                    if abs(s.midY - source.midY) < font { continue }
                    let middle = (s.midY + source.midY) / 2
                    if s.midY < source.midY { top = max(top, middle) } else { bottom = min(bottom, middle) }
                }
            }
            guard top < bottom else { record("unchanged-conflicting-paragraph-neighborhood"); continue }
            // A reference CT block measures drift without rewrapping or trusting fits=true.
            let reference = fitted(widths: fragmentWidths, text: text, fontSize: font, pitch: inputPitch, width: base.width,
                center: CGPoint(x: base.midX, y: 0), scale: outputScale, parameters: p, preserveWrap: true)
            let baselineTop = reference?.box.minY ?? 0
            let baselineCenterY = reference.map { base.minY - baselineTop + union($0.rows).midY } ?? base.midY
            let bodyCenter = shared ? (source?.midY ?? baselineCenterY) : space.bodyCenterY
            let sourceAnchorY = placementAnchor?.midY ?? source?.midY ?? baselineCenterY
            let maxWidth = placementAnchor.map { _ in min(space.rect.width, near?.allowed.width ?? space.rect.width,
                base.width * CGFloat(p["maximumWidthGrowth"]!)) }
                ?? min(space.rect.width, base.width * CGFloat(p["maximumWidthGrowth"]!),
                    2 * min(base.midX - space.rect.minX, space.rect.maxX - base.midX))
            guard maxWidth > 0 else { record("unchanged-no-symmetric-width"); continue }
            let minWidth = min(base.width, maxWidth)
            let widthSteps = Int(p["widthSteps"]!)
            let widths = Array(Set((0...widthSteps).map {
                minWidth + (maxWidth - minWidth) * CGFloat($0) / CGFloat(widthSteps)
            } + [min(base.width * 1.25, maxWidth)])).sorted()
            let fontSteps = Int(p["fontSteps"]!), leadingSteps = Int(p["leadingSteps"]!)
            let primaryScales = Array(Set((0...fontSteps).map {
                CGFloat(p["maxFontScale"]! - (p["maxFontScale"]! - p["minFontScale"]!) * Double($0) / Double(fontSteps))
            })).sorted(by: >)
            let emergencyMinimum = max(0.25, p["emergencyMinFontScale"]!)
            let emergencyEnabled = p["emergencyMinFontScale"]! > 0 && emergencyMinimum < p["minFontScale"]!
            let emergencyScales: [CGFloat] = emergencyEnabled ? (1...fontSteps).map {
                CGFloat(p["minFontScale"]! - (p["minFontScale"]! - emergencyMinimum) * Double($0) / Double(fontSteps))
            } : []
            let fontScales = primaryScales + emergencyScales
            var winner: Choice?, firstFeasible: Choice?
            var attempts = 0, feasible = 0, shapedCount = 0
            var emergencyUsed = false
            for (scaleIndex, scale) in fontScales.enumerated() {
                if scaleIndex == primaryScales.count {
                    if winner != nil { break }
                    emergencyUsed = true
                }
                let size = font * scale
                let minPitch = max(size * CGFloat(p["leading"]!), inputPitch * scale)
                let maxPitch = max(minPitch, size * CGFloat(p["maximumLeading"]!))
                let pitches = Array(Set((0...leadingSteps).map {
                    minPitch + (maxPitch - minPitch) * CGFloat($0) / CGFloat(leadingSteps)
                })).sorted()
                for width in widths {
                    // Original line breaks also compete; all other variants use whitespace-only rewrap.
                    let wrapModes = abs(width - base.width) < 0.001 ? [true, false] : [false]
                    for pitch in pitches {
                        for keepWrap in wrapModes {
                            shapedCount += 1
                            guard let shaped = fitted(widths: fragmentWidths, text: text, fontSize: size, pitch: pitch, width: width,
                                center: CGPoint(x: base.midX, y: 0), scale: outputScale,
                                parameters: p, preserveWrap: keepWrap, minimumHalo: near?.halo ?? 0) else { continue }
                            let shapeInk = union(shaped.rows)
                            var centerTargets = balloon ? Array(Set([baselineCenterY, sourceAnchorY, bodyCenter,
                                (baselineCenterY + bodyCenter) / 2])).sorted() : [baselineCenterY]
                            var centerXs = [shapeInk.midX]
                            if let placementAnchor {
                                let allowed = near?.allowed ?? space.rect
                                let lowX = max(allowed.minX + shapeInk.width / 2, placementAnchor.midX - placementDrift)
                                let highX = min(allowed.maxX - shapeInk.width / 2, placementAnchor.midX + placementDrift)
                                let referenceY = near?.vertical.center(anchor:placementAnchor,blockHeight:shapeInk.height) ?? placementAnchor.midY
                                let verticalDrift = near?.vertical.sourceTop==true ? near!.vertical.topDrift : placementDrift
                                let lowY = max(top + shapeInk.height / 2, referenceY - verticalDrift)
                                let highY = min(bottom - shapeInk.height / 2, referenceY + verticalDrift)
                                guard lowX <= highX, lowY <= highY else { continue }
                                centerXs = Array(Set([shapeInk.midX, placementAnchor.midX, (lowX + highX) / 2]
                                    .map { min(highX, max(lowX, $0)) })).sorted()
                                centerTargets = Array(Set((centerTargets + [referenceY, (lowY + highY) / 2])
                                    .map { min(highY, max(lowY, $0)) })).sorted()
                            }
                            for target in centerTargets {
                            for targetX in centerXs {
                                attempts += 1
                                // Without metadata, preserve v2's existing non-balloon top anchoring exactly.
                                let dy = balloon || placementAnchor != nil ? target - shapeInk.midY : base.minY - shaped.box.minY
                                let dx = placementAnchor == nil ? 0 : targetX - shapeInk.midX
                                let layout = shifted(shaped, dx: dx, dy: dy)
                                guard bounds.contains(layout.box),
                                    layout.rows.allSatisfy({ bounds.contains($0) && space.contains($0) && $0.minY >= top && $0.maxY <= bottom })
                                    else { continue }
                                if let near, !near.permits(layout.rows) { continue }
                                let actualCenter = union(layout.rows).midY
                                if balloon && abs(actualCenter - sourceAnchorY) > CGFloat(p["maxBalloonDrift"]!) * space.rect.height { continue }
                                let collides = page.items.indices.contains { peer in
                                    guard peer != index else { return false }
                                    let obstacles = accepted[peer] ?? peerRects[peer].map { [$0] } ?? []
                                    return layout.rows.contains { row in obstacles.contains { $0.intersects(row) } }
                                }
                                guard !collides else { continue }
                                guard let choice = scored(layout, originalFont: font, base: base,
                                    baselineCenter: placementAnchor.map { near?.vertical.center(anchor:$0,blockHeight:shapeInk.height) ?? $0.midY } ?? baselineCenterY,
                                    bodyCenter: bodyCenter, balloon: balloon,
                                    parameters: p, horizontalAnchor: placementAnchor?.midX) else { continue }
                                feasible += 1
                                if firstFeasible == nil { firstFeasible = choice }
                                if winner == nil || choice.score < winner!.score - 1e-9 ||
                                    (abs(choice.score - winner!.score) <= 1e-9 && choice.drift < winner!.drift) {
                                    winner = choice
                                }
                            }
                            }
                        }
                    }
                }
            }
            guard let selected = winner else {
                record("unchanged-no-certified-fit", ["evidence": evidence, "attempts": attempts, "shapedCandidates": shapedCount,
                    "qualityStatus": "unknown-unresolved; unchanged input may overflow; not a successful fit",
                    "noFitIsSuccess": false, "primaryMinimumFontScale": p["minFontScale"]!,
                    "emergencyFontSearchEnabled": emergencyEnabled, "emergencyFontSearchUsed": emergencyUsed]); continue
            }
            let chosen = selected.layout
            guard lexicalUTF16(text) == lexicalUTF16(chosen.text), lexicalUTF8(text) == lexicalUTF8(chosen.text),
                tokenBytes(text) == tokenBytes(chosen.text) else { record("unchanged-byte-invariant-failure"); continue }
            output[index]["text"] = chosen.text
            output[index]["x"] = Double(chosen.box.minX); output[index]["y"] = Double(chosen.box.minY)
            output[index]["width"] = Double(chosen.box.width); output[index]["height"] = Double(chosen.box.height)
            output[index]["fontSize"] = Double(chosen.font); output[index]["lineHeight"] = Double(chosen.pitch)
            accepted[index] = chosen.rows
            var anchorAudit: [String: Any] = [:]
            if emergencyEnabled {
                anchorAudit["emergencyFontSearchUsed"] = emergencyUsed
                anchorAudit["primaryNoCertifiedFit"] = emergencyUsed
                anchorAudit["qualityStatus"] = "geometry-proposal-only; readability and final raster unverified"
                anchorAudit["emergencyMinimumFontScale"] = emergencyMinimum
            }
            if let near {
                // Contract fields, lineage, array order and sourceBounds remain byte-for-byte input values.
                anchorAudit = ["paragraphOwnerKey": near.owner,
                    "protectedNeighborCount": near.neighbors.count,
                    "centerDriftMetric": near.vertical.sourceTop ? "horizontal block center; vertical glyph+halo block top" : "per-axis glyph+halo block center",
                    "haloFloorViewport": Double(near.halo), "rfPolygonFinalCheck": !near.polygons.isEmpty]
            }
            if near != nil || sourceInkEnabled {
                let block = union(chosen.rows)
                anchorAudit["anchorAuthority"] = near != nil ? (near!.vertical.sourceTop ? "sourceNearLayout-v2-source-top" : "sourceNearLayout-v1") : useSourceAnchor
                    ? "sourceBounds-center-estimate;not-pixel-gold" : balloon ? "balloon-contour" : "raw-frame-fallback;source-unknown"
                anchorAudit["rawInputRect"] = [Double(base.minX), Double(base.minY), Double(base.width), Double(base.height)]
                anchorAudit["rawFrameCenterY"] = Double(base.midY)
                anchorAudit["referenceInkCenterY"] = Double(baselineCenterY)
                anchorAudit["referenceInkMeasured"] = reference != nil
                anchorAudit["sourceCenterY"] = source.map { Double($0.midY) } as Any? ?? NSNull()
                anchorAudit["selectedGlyphHaloCenter"] = [Double(block.midX), Double(block.midY)]
                if near?.vertical.sourceTop==true {
                    anchorAudit["selectedGlyphHaloTop"]=Double(block.minY)
                    anchorAudit["originalOCRTop"]=Double(near!.anchor.minY)
                    anchorAudit["verticalTopDriftLimit"]=Double(near!.vertical.topDrift)
                }
                anchorAudit["rawToReferenceInkDeltaY"] = Double(baselineCenterY - base.midY)
                anchorAudit["sourceToReferenceInkDeltaY"] = source.map { Double(baselineCenterY - $0.midY) } as Any? ?? NSNull()
                anchorAudit["sourceRawHeightRatio"] = source.map { Double($0.height / base.height) } as Any? ?? NSNull()
                anchorAudit["parentPainterFrameOverridesMeasured"] = false
            }
            record("proposed-minimum-objective", ["evidence": evidence, "authority": space.authority,
                "attempts": attempts, "shapedCandidates": shapedCount, "feasibleCandidates": feasible,
                "score": selected.score, "terms": selected.terms, "firstFeasibleScore": firstFeasible!.score,
                "firstFeasibleRows": firstFeasible!.layout.rows.count, "selectedRows": chosen.rows.count,
                "singletonRows": chosen.singletons, "fontScale": Double(chosen.font / font),
                "rawTopDelta": Double(chosen.box.minY - base.minY),
                "inkCenterDelta": Double(union(chosen.rows).midY - baselineCenterY),
                "rows": chosen.rows.map { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] },
                "inkRows": chosen.inkRows.map { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] },
                "strokeRadiusViewport": Double(chosen.radius), "tokenBytesEqual": true, "nonWhitespaceUTF16Equal": true,
                "textUTF8Equal": Array(text.utf8) == Array(chosen.text.utf8)].merging(anchorAudit) { _, new in new })
        }
        return Ensemble100Proposal(items: output, audit: ["agent04Next": audit,
            "itemCount": page.items.count, "fontName": "AppleSDGothicNeo-Medium",
            "displayStroke": "mandatory pure BW supplied by parent; radius >= max(2 output pixels, 0.20 * font pixels)",
            "measurement": "all enumerated feasible grid candidates scored; CoreText geometry only, final raster unverified",
            "rfBoxesWithoutMasks": page.rfRegions.filter { $0.exterior.isEmpty }.count,
            "cachedOCR": page.savedEvidence["originalOCR"] == nil || page.savedEvidence["originalOCR"] is NSNull
                ? "missing; sourceBounds fallback, no inference" : "available; no inference"])
    }

    private static func union(_ rows: [CGRect]) -> CGRect {
        rows.reduce(CGRect.null) { $0.union($1) }
    }

    private static func sourceNear(_ raw: [String: Any], index: Int, items: [[String: Any]], viewport: CGSize) -> SourceNear? {
        guard let m = raw["sourceNearLayout"] as? [String: Any], let vertical=NativeSourceNearVerticalAnchor.parse(m),
            m["coordinateSpace"] as? String == "viewport-top-left", m["feasible"] as? Bool == true,
            m["mergeParagraphs"] as? Bool == false, m["paragraphsRemainSeparate"] as? Bool == true,
            m["boundsIncludeHalo"] as? Bool == true, number(m["outputIndex"]) == CGFloat(index),
            let owner = m["paragraphOwnerKey"] as? String, !owner.isEmpty,
            let allowed = viewportRect(m["allowedRect"]), let anchor = viewportRect(m["anchorRect"]),
            let original = normalizedRect(raw["sourceBounds"], viewport: viewport),
            let declared = normalizedRect(m["sourceBoundsNormalized"], viewport: viewport),
            sameRect(original, declared), allowed.contains(anchor),
            (sameRect(anchor, original) || sourceRevisionInteriorCapacity(raw, contract: m,
                original: original, anchor: anchor, allowed: allowed)),
            CGRect(origin: .zero, size: viewport).contains(allowed),
            let drift = number(m["maxCenterDrift"]), drift >= 0, drift <= max(viewport.width, viewport.height),
            vertical.topDrift<=max(viewport.width,viewport.height),
            let halo = number(m["haloMargin"]), halo >= 0, halo <= min(allowed.width, allowed.height) / 2,
            let neighborObjects = m["protectedNeighbors"] as? [[String: Any]], neighborObjects.count <= items.count else { return nil }
        guard !items.indices.contains(where: { i in
            i != index && (items[i]["sourceNearLayout"] as? [String: Any])?["paragraphOwnerKey"] as? String == owner
        }) else { return nil }
        var neighbors: [SourceNear.Neighbor] = []
        for n in neighborObjects {
            guard let id = number(n["itemIndex"]), id >= 0, id < CGFloat(items.count), id.rounded(.down) == id,
                Int(id) != index, let key = n["paragraphOwnerKey"] as? String, !key.isEmpty, key != owner,
                let rect = viewportRect(n["anchorRect"]), let source = normalizedRect(n["sourceBoundsNormalized"], viewport: viewport),
                let actual = normalizedRect(items[Int(id)]["sourceBounds"], viewport: viewport),
                sameRect(rect, source), sameRect(source, actual),
                let margin = number(n["haloMargin"]), margin >= 0, margin <= max(viewport.width, viewport.height),
                let axis = n["separationAxis"] as? String, axis == "x" || axis == "y",
                let separator = number(n["separator"]), let clearance = number(n["clearance"]), clearance >= 0 else { return nil }
            if let otherKey = (items[Int(id)]["sourceNearLayout"] as? [String: Any])?["paragraphOwnerKey"] as? String,
                otherKey != key { return nil }
            neighbors.append(.init(anchor: rect, halo: margin,
                axis: axis, separator: separator, clearance: clearance))
        }
        var polygons: [SourceNear.Polygon] = []
        if let values = m["rfPolygonsNormalized"] {
            guard let objects = values as? [[String: Any]], objects.count <= 256 else { return nil }
            for object in objects {
                guard let exterior = normalizedRing(object["exterior"], viewport: viewport),
                    let holeValues = object["holes"] as? [Any], holeValues.count <= 256 else { return nil }
                let holes = holeValues.compactMap { normalizedRing($0, viewport: viewport) }
                guard holes.count == holeValues.count else { return nil }
                polygons.append(.init(exterior: exterior, holes: holes))
            }
        }
        if m["rfPolygonFinalCheckRequired"] as? Bool == true && polygons.isEmpty { return nil }
        guard !vertical.sourceTop || polygons.isEmpty else{return nil}
        return SourceNear(owner: owner, allowed: allowed, anchor: anchor, drift: drift, halo: halo,
            neighbors: neighbors, polygons: polygons,vertical:vertical)
    }

    private static func sourceRevisionInteriorCapacity(_ raw: [String: Any], contract: [String: Any],
        original: CGRect, anchor: CGRect, allowed: CGRect) -> Bool {
        guard raw["sourceRevisionOwnCapacityRequired"] as? Bool == true,
              contract["sourceRevisionOwnCapacityRequired"] as? Bool == true,
              let reserve = number(contract["sourceRevisionInteriorReservePixels"]),
              abs(reserve - min(original.width, original.height) * 0.1) < 1e-6,
              reserve > 0, sameRect(anchor, allowed),
              sameRect(allowed, original.insetBy(dx: reserve, dy: reserve)),
              original.contains(allowed) else { return false }
        return true
    }

    private static func viewportRect(_ value: Any?) -> CGRect? {
        guard let a = value as? [Any], a.count == 4 else { return nil }
        let v = a.compactMap(number)
        guard v.count == 4, v[2] > 0, v[3] > 0 else { return nil }
        let r = CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
        return [r.minX, r.minY, r.maxX, r.maxY].allSatisfy(\.isFinite) ? r : nil
    }

    private static func sameRect(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1e-6 && abs(a.minY - b.minY) < 1e-6 &&
            abs(a.width - b.width) < 1e-6 && abs(a.height - b.height) < 1e-6
    }

    private static func normalizedRing(_ value: Any?, viewport: CGSize) -> [CGPoint]? {
        // Direct Swift chaining carries CGFloat arrays; saved JSON carries NSNumber/Double arrays.
        guard let pairs = value as? [[Any]], pairs.count >= 3, pairs.count <= 16384 else { return nil }
        var result: [CGPoint] = []
        for pair in pairs {
            let v = pair.compactMap(number)
            guard pair.count == 2, v.count == 2, v.allSatisfy({ $0 >= 0 && $0 <= 1 }) else { return nil }
            result.append(CGPoint(x: v[0] * viewport.width, y: v[1] * viewport.height))
        }
        return result
    }

    private static func contains(_ row: CGRect, polygon: SourceNear.Polygon) -> Bool {
        let corners = [CGPoint(x: row.minX, y: row.minY), CGPoint(x: row.maxX, y: row.minY),
            CGPoint(x: row.maxX, y: row.maxY), CGPoint(x: row.minX, y: row.maxY)]
        guard corners.allSatisfy({ inside($0, ring: polygon.exterior) }),
            !edgeEnters(row, ring: polygon.exterior) else { return false }
        return polygon.holes.allSatisfy { hole in
            !corners.contains(where: { inside($0, ring: hole) }) && !edgeEnters(row, ring: hole)
        }
    }

    private static func inside(_ p: CGPoint, ring: [CGPoint]) -> Bool {
        var hit = false
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            let dx = b.x - a.x, dy = b.y - a.y
            let cross = (p.x - a.x) * dy - (p.y - a.y) * dx
            if abs(cross) <= 1e-7 * max(1, abs(dx) + abs(dy)),
                p.x >= min(a.x, b.x) - 1e-7, p.x <= max(a.x, b.x) + 1e-7,
                p.y >= min(a.y, b.y) - 1e-7, p.y <= max(a.y, b.y) + 1e-7 { return true }
            if (a.y > p.y) != (b.y > p.y), p.x < a.x + dx * (p.y - a.y) / dy { hit.toggle() }
        }
        return hit
    }

    /// Segment/open-rectangle intersection catches concave notches and holes wholly inside a row, in O(edges).
    private static func edgeEnters(_ rect: CGRect, ring: [CGPoint]) -> Bool {
        let interior = rect.insetBy(dx: 1e-7, dy: 1e-7)
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            var lo: CGFloat = 0, hi: CGFloat = 1
            var possible = true
            for (start, delta, minimum, maximum) in [(a.x, b.x - a.x, interior.minX, interior.maxX),
                (a.y, b.y - a.y, interior.minY, interior.maxY)] {
                if abs(delta) < 1e-12 {
                    if start < minimum || start > maximum { possible = false; break }
                } else {
                    let t1 = (minimum - start) / delta, t2 = (maximum - start) / delta
                    lo = max(lo, min(t1, t2)); hi = min(hi, max(t1, t2))
                    if lo > hi { possible = false; break }
                }
            }
            if possible && lo <= hi { return true }
        }
        return false
    }

    private static func shifted(_ layout: Layout, dx: CGFloat = 0, dy: CGFloat) -> Layout {
        Layout(text: layout.text, box: layout.box.offsetBy(dx: dx, dy: dy), font: layout.font, pitch: layout.pitch,
            rows: layout.rows.map { $0.offsetBy(dx: dx, dy: dy) }, radius: layout.radius,
            inkRows: layout.inkRows.map { $0.offsetBy(dx: dx, dy: dy) }, singletons: layout.singletons)
    }

    private static func scored(_ layout: Layout, originalFont: CGFloat, base: CGRect,
        baselineCenter: CGFloat, bodyCenter: CGFloat, balloon: Bool, parameters p: [String: Double],
        horizontalAnchor: CGFloat? = nil) -> Choice? {
        var haloOverlap: CGFloat = 0, fillIntrusion: CGFloat = 0
        for i in layout.rows.indices {
            for j in layout.rows.indices where j > i {
                let a = layout.rows[i], b = layout.rows[j]
                let overlap = a.intersection(b)
                if !overlap.isNull { haloOverlap += overlap.width * overlap.height / max(1, min(a.width * a.height, b.width * b.height)) }
                let inkA = layout.inkRows[i], inkB = layout.inkRows[j]
                if inkA.intersects(inkB) { return nil }
                for (halo, ink) in [(a, inkB), (b, inkA)] {
                    let intrusion = halo.intersection(ink)
                    let fraction = intrusion.isNull ? 0 : intrusion.width * intrusion.height / max(1, ink.width * ink.height)
                    if fraction > CGFloat(p["maxFillIntrusion"]!) { return nil }
                    fillIntrusion += fraction
                }
            }
        }
        let center = union(layout.rows).midY
        let drift = abs(center - baselineCenter) / max(originalFont, base.height)
        let shrink = 1 - Double(layout.font / originalFont)
        let growth = max(0, Double(layout.box.width / base.width - 1))
        var terms: [String: Double] = [
            "lines": Double(layout.rows.count) * p["lineWeight"]!,
            "singletons": Double(layout.singletons) * p["singletonWeight"]!,
            "shrink": shrink * shrink * p["shrinkWeight"]!,
            "sourceDrift": Double(drift * drift) * p["sourceDriftWeight"]!,
            "bodyCenter": balloon ? pow(Double((center - bodyCenter) / max(originalFont, base.height)), 2) * p["bodyCenterWeight"]! : 0,
            "widthGrowth": growth * growth * p["widthGrowthWeight"]!,
            "haloOverlap": Double(haloOverlap) * p["haloOverlapWeight"]!,
            "fillIntrusion": Double(fillIntrusion) * p["fillIntrusionWeight"]!,
            "leading": pow(max(0, Double(layout.pitch / layout.font) - p["leading"]!), 2) * p["leadingWeight"]!
        ]
        if let horizontalAnchor {
            terms["horizontalAnchor"] = pow(Double((union(layout.rows).midX - horizontalAnchor) / max(originalFont, base.width)), 2)
                * p["sourceDriftWeight"]!
        }
        let score = terms.values.reduce(0, +)
        guard score.isFinite else { return nil }
        return Choice(layout: layout, score: score, terms: terms, drift: drift)
    }

    private static func number(_ value: Any?) -> CGFloat? {
        guard let n = value as? NSNumber, n.doubleValue.isFinite else { return nil }
        return CGFloat(n.doubleValue)
    }
    private static func rect(_ item: [String: Any]) -> CGRect? {
        guard let x = number(item["x"]), let y = number(item["y"]),
              let w = number(item["width"]), let h = number(item["height"]), w > 0, h > 0 else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }
    private static func normalizedRect(_ value: Any?, viewport: CGSize) -> CGRect? {
        guard let a = value as? [Double], a.count == 4, a.allSatisfy(\.isFinite), a[2] > 0, a[3] > 0,
              CGRect(x: 0, y: 0, width: 1, height: 1).contains(CGRect(x: a[0], y: a[1], width: a[2], height: a[3])) else { return nil }
        return CGRect(x: a[0] * viewport.width, y: a[1] * viewport.height,
            width: a[2] * viewport.width, height: a[3] * viewport.height)
    }
    private static func nativeSpace(_ item: [String: Any], viewport: CGSize) -> Space? {
        guard let obj = item["balloonInterior"] as? [String: Any],
              obj["contourVerified"] as? Bool == true || obj["modelEstimated"] as? Bool == true,
              let r = normalizedRect(obj["rect"], viewport: viewport), let s = obj["spans"] as? [Double],
              s.count >= 4, s.count <= 4096, s.count % 2 == 0, s.allSatisfy(\.isFinite) else { return nil }
        var spans: [Span] = []
        for i in stride(from: 0, to: s.count, by: 2) {
            if s[i] < 0 && s[i + 1] < 0 { spans.append(Span(left: 1, right: -1)); continue }
            guard s[i] >= 0, s[i + 1] <= 1, s[i + 1] > s[i] else { return nil }
            spans.append(Span(left: max(r.minX, s[i] * viewport.width), right: min(r.maxX, s[i + 1] * viewport.width)))
        }
        return Space(rect: r, spans: spans,
            authority: obj["contourVerified"] as? Bool == true ? "native-contour" : "model-item-contour")
    }
    private static func support(_ space: Space, source: CGRect) -> Double {
        var count = 0
        for iy in 0..<3 {
            for ix in 0..<3 {
                let point = CGPoint(x: source.minX + source.width * (CGFloat(ix) + 0.5) / 3,
                    y: source.minY + source.height * (CGFloat(iy) + 0.5) / 3)
                if space.contains(CGRect(x: point.x, y: point.y, width: 0.001, height: 0.001)) { count += 1 }
            }
        }
        return Double(count) / 9
    }
    private static func intervals(_ ring: [CGPoint], y: CGFloat) -> [Span] {
        guard ring.count >= 3, ring.count <= 16384, ring.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return [] }
        var crosses: [CGFloat] = []
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            if (a.y > y) != (b.y > y) { crosses.append(a.x + (b.x - a.x) * (y - a.y) / (b.y - a.y)) }
        }
        crosses.sort()
        return stride(from: 0, to: max(0, crosses.count - 1), by: 2).map { Span(left: crosses[$0], right: crosses[$0 + 1]) }
    }
    private static func rfSpace(_ region: Ensemble100RFRegion, source: CGRect,
        viewport: CGSize, bodyFraction: CGFloat) -> Space? {
        guard region.exterior.count >= 3, !region.bounds.isEmpty,
              [region.bounds.minX, region.bounds.minY, region.bounds.maxX, region.bounds.maxY].allSatisfy(\.isFinite) else { return nil }
        let r = CGRect(x: region.bounds.minX * viewport.width, y: region.bounds.minY * viewport.height,
            width: region.bounds.width * viewport.width, height: region.bounds.height * viewport.height)
        guard CGRect(origin: .zero, size: viewport).contains(r), r.intersects(source) else { return nil }
        let count = 96
        var spans: [Span] = []
        for i in 0..<count {
            // Intersection over several samples makes each band conservative; holes split the allowed interval.
            var left = r.minX, right = r.maxX
            for offset: CGFloat in [0.001, 0.25, 0.5, 0.75, 0.999] {
                let y = (r.minY + (CGFloat(i) + offset) * r.height / CGFloat(count)) / viewport.height
                var options = intervals(region.exterior, y: y)
                for hole in region.holes {
                    for cut in intervals(hole, y: y) {
                        options = options.flatMap { span -> [Span] in
                            if cut.right <= span.left || cut.left >= span.right { return [span] }
                            return [Span(left: span.left, right: min(span.right, cut.left)),
                                Span(left: max(span.left, cut.right), right: span.right)].filter { $0.right > $0.left }
                        }
                    }
                }
                let anchor = source.midX / viewport.width
                guard let chosen = options.first(where: { $0.left <= anchor && $0.right >= anchor }) else {
                    left = 1; right = -1; break
                }
                left = max(left, chosen.left * viewport.width); right = min(right, chosen.right * viewport.width)
            }
            spans.append(Span(left: left, right: right))
        }
        // Tail bands may be retained as constraints, but cannot pull the main-body center down.
        let widest = spans.map { $0.right - $0.left }.max() ?? 0
        guard widest >= source.width, spans.filter({ $0.right - $0.left >= widest * max(0.3, min(0.95, bodyFraction)) }).count >= 3 else { return nil }
        return Space(rect: r, spans: spans, authority: "rf-polygon-pixel-supported")
    }

    private static func lexicalUTF16(_ text: String) -> [UInt16] {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })).utf16.map { $0 }
    }

    private static func lexicalUTF8(_ text: String) -> [UInt8] {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })).utf8.map { $0 }
    }

    private static func tokenBytes(_ text: String) -> [[UInt8]] {
        text.split(whereSeparator: \.isWhitespace).map { Array($0.utf8) }
    }

    private static func rewrapped(_ text: String, width: CGFloat, expression: NSRegularExpression, measure: (String) -> CGFloat) -> String? {
        let ns = text as NSString
        let matches = expression.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }
        var result = "", current = "", end = 0
        for match in matches {
            let token = ns.substring(with: match.range)
            guard measure(token) <= width else { return nil }
            let gap = ns.substring(with: NSRange(location: end, length: match.range.location - end))
            let normalizedGap = gap.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            if normalizedGap.filter({ $0 == "\n" }).count >= 2 {
                result += gap + token; current = token
            } else {
                let separator = normalizedGap.contains("\n") ? " " : gap
                let next = current + separator + token
                if current.isEmpty || measure(next) <= width { result += separator + token; current = next }
                else { result += "\n" + token; current = token }
            }
            end = match.range.location + match.range.length
        }
        result += ns.substring(from: end)
        return result
    }

    /// Width searches repeatedly measure the same tokens and whole lines across different box widths
    /// and pitches. These intrinsic measurements use only their exact text and the resolved font.
    final class FragmentWidths {
        lazy var words = try! NSRegularExpression(pattern: "\\S+")
        private var face: CTFont?
        private var attributes: [NSAttributedString.Key: Any] = [:]
        private var widths: [[UInt8]: CGFloat] = [:]
        private var keyBytes = 0

        func bind(_ font: CTFont) {
            if let face, CFEqual(face, font) { return }
            face = font
            attributes = [NSAttributedString.Key(kCTFontAttributeName as String): font]
            widths.removeAll(keepingCapacity: true)
            keyBytes = 0
        }

        func measure(_ value: String) -> CGFloat {
            let bytes = value.utf8
            let key = bytes.count <= 512 ? Array(bytes) : nil
            if let key, let width = widths[key] { return width }
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attributes))
            let width = max(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)),
                CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds]).width)
            if let key, widths.count < 256, key.capacity <= 16_384 - keyBytes {
                widths[key] = width
                keyBytes += key.capacity
            }
            return width
        }
    }

    private static func fitted(widths: FragmentWidths, text: String, fontSize: CGFloat, pitch: CGFloat, width: CGFloat,
        center: CGPoint, scale: CGFloat, parameters: [String: Double], preserveWrap: Bool = false, minimumHalo: CGFloat = 0) -> Layout? {
        guard scale > 0, fontSize > 0 else { return nil }
        let font = CTFontCreateWithName("AppleSDGothicNeo-Medium" as CFString, fontSize, nil)
        let radius = max(minimumHalo, CGFloat(max(0.20, parameters["strokeFraction"]!)) * fontSize,
            CGFloat(max(2, parameters["minimumStrokePixels"]!)) / scale)
        let margin = radius + CGFloat(max(0.5, parameters["safetyPixels"]!)) / scale
        let available = width - 2 * margin
        guard available > fontSize * 0.25 else { return nil }
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        widths.bind(font)
        func measure(_ value: String) -> CGFloat { widths.measure(value) }
        // Existing horizontal whitespace survives unless that boundary is chosen for a line break.
        // Single old line breaks may reflow; paragraph delimiters, token UTF8 and lexical UTF16 are invariant.
        guard let wrapped = preserveWrap ? text : rewrapped(text, width: available, expression: widths.words, measure: measure),
            !wrapped.isEmpty, lexicalUTF16(text) == lexicalUTF16(wrapped),
            lexicalUTF8(text) == lexicalUTF8(wrapped), tokenBytes(text) == tokenBytes(wrapped) else { return nil }
        let logicalLines = wrapped.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        guard logicalLines.allSatisfy({ measure($0) <= available }) else { return nil }
        var alignment = CTTextAlignment.center
        var minimum = max(pitch, CTFontGetAscent(font) + CTFontGetDescent(font)), maximum = minimum
        let style: CTParagraphStyle = withUnsafePointer(to: &alignment) { a in
            withUnsafePointer(to: &minimum) { lo in
                withUnsafePointer(to: &maximum) { hi in
                    let settings = [CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: a),
                        CTParagraphStyleSetting(spec: .minimumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: lo),
                        CTParagraphStyleSetting(spec: .maximumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: hi)]
                    return CTParagraphStyleCreate(settings, settings.count)
                }
            }
        }
        var styled = attributes; styled[NSAttributedString.Key(kCTParagraphStyleAttributeName as String)] = style
        let attributed = NSAttributedString(string: wrapped, attributes: styled)
        let height = CGFloat(logicalLines.count) * maximum + fontSize + 2 * margin
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0),
            CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil), nil)
        let visible = CTFrameGetVisibleStringRange(frame)
        guard visible.location == 0, visible.length == wrapped.utf16.count else { return nil }
        let lines = CTFrameGetLines(frame) as! [CTLine]
        // No automatic emergency token splitting may occur after the explicit whitespace-only wrap.
        guard lines.count == logicalLines.count else { return nil }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        var rows: [CGRect] = [], inkRows: [CGRect] = []
        var singletons = 0
        for (i, line) in lines.enumerated() {
            // Image bounds also cover fallback/bitmap glyphs such as color emoji without outline paths.
            let pathBounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
            let imageBounds = CTLineGetImageBounds(line, nil)
            let glyph = pathBounds.union(imageBounds)
            if glyph.isNull || glyph.isEmpty { continue } // Deliberate blank paragraph rows have no glyph ink.
            let ink = CGRect(x: origins[i].x + glyph.minX, y: height - origins[i].y - glyph.maxY,
                width: glyph.width, height: glyph.height)
            let row = ink.insetBy(dx: -margin, dy: -margin)
            let range = CTLineGetStringRange(line)
            let contents = (wrapped as NSString).substring(with: NSRange(location: range.location, length: range.length))
            if contents.filter({ !$0.isWhitespace }).count == 1 { singletons += 1 }
            inkRows.append(ink)
            guard row.minX >= 0, row.maxX <= width else { return nil }
            rows.append(row)
        }
        guard let first = rows.first else { return nil }
        let union = rows.dropFirst().reduce(first) { $0.union($1) }
        let origin = CGPoint(x: center.x - width / 2, y: center.y - union.midY)
        // Trim only unused bottom frame slack. The first baseline stays at its original top offset.
        let lastBaseline = origins.last.map { height - $0.y } ?? height
        let compactHeight = min(height, max(union.maxY, lastBaseline + CTFontGetDescent(font) + margin) + 0.5 / scale)
        return Layout(text: wrapped, box: CGRect(origin: origin, size: CGSize(width: width, height: compactHeight)),
            font: fontSize, pitch: maximum, rows: rows.map { $0.offsetBy(dx: origin.x, dy: origin.y) }, radius: radius,
            inkRows: inkRows.map { $0.offsetBy(dx: origin.x, dy: origin.y) }, singletons: singletons)
    }

    /// Optional display-only rescue for uncertified fallback frames. Parent may
    /// call this after its other layout proposals; OFF unless explicitly enabled.
    /// Each owner keeps its own source envelope, text, palette and lineage. An
    /// overlapping source contract does not grant extra space or merge authority.
    static func sourceEnvelopeRefit(_ page: Ensemble100Page,
                                    parameters: [String: Double] = [:]) throws -> Ensemble100Proposal {
        let fragmentWidths = FragmentWidths()
        guard let enabled = parameters["enabled"], enabled.isFinite, enabled > 0 else {
            return .init(items: page.items, audit: ["status": "disabled"])
        }
        let viewport = page.viewport
        guard viewport.width.isFinite, viewport.height.isFinite, viewport.width > 0, viewport.height > 0,
              page.items.count <= 128 else {
            return .init(items: page.items, audit: ["status": "invalid-or-over-budget-preserved"])
        }
        let bounds = CGRect(origin: .zero, size: viewport)
        let scale = min(CGFloat(page.original.width) / viewport.width, CGFloat(page.original.height) / viewport.height)
        func option(_ key: String, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
            let value = parameters[key] ?? fallback
            return value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
        }
        let minimum = option("minimumFontScale", 0.65, 0.5...1)
        let minimumPixels = CGFloat(option("minimumFontPixels", 12, 8...32))
        let steps = Int(option("fontSteps", 8, 1...12))
        let sources = page.items.map { normalizedRect($0["sourceBounds"], viewport: viewport) }
        var output = page.items, accepted: [Int: [CGRect]] = [:], records: [[String: Any]] = []
        for (index, raw) in page.items.enumerated() {
            try Task.checkCancellation()
            func record(_ status: String, _ extra: [String: Any] = [:]) {
                records.append(extra.merging(["index": index, "id": raw["id"] ?? NSNull(), "status": status]) { _, new in new })
            }
            guard raw["ensembleLockLayout"] as? Bool != true,
                  raw["sourceTextOnly"] as? Bool != true, raw["keptLettering"] as? Bool != true,
                  raw["sourceVertical"] as? Bool == true, raw["vertical"] as? Bool != true,
                  abs(number(raw["rotation"]) ?? 0) < 0.001,
                  let text = raw["text"] as? String, !text.isEmpty, text.utf16.count <= 2048,
                  let source = sources[index], let base = rect(raw),
                  let font = number(raw["fontSize"]), font > 0, font <= 1000,
                  [base.minX, base.minY, base.maxX, base.maxY].allSatisfy(\.isFinite) else {
                record("unsupported-or-certified-preserved"); continue
            }
            // Existing supported contours keep their own centering/containment.
            // A model bbox alone is not a contour and cannot enlarge this slot.
            guard raw["balloonInterior"] == nil, raw["balloonUnit"] == nil,
                  NativeEnsembleLayoutContour.contour(raw: raw, viewport: viewport) == nil,
                  !page.rfRegions.contains(where: { region in
                      guard region.classID == 2, region.confidence >= 0.65,
                            let space = rfSpace(region, source: source, viewport: viewport, bodyFraction: 0.65) else { return false }
                      return support(space, source: source) >= 0.85
                  }) else { record("contour-policy-preserved"); continue }
            var p = defaults
            let strokeRatio = max(0.20, number(raw["ensembleStrokeRatio"]) ?? 0.20)
            guard strokeRatio <= 0.5 else { record("unsupported-stroke-width-preserved"); continue }
            p["strokeFraction"] = Double(strokeRatio)
            p["safetyPixels"] = 2 // AA and outward pixel rounding, in addition to the mandatory stroke.
            let near = raw["sourceNearLayout"] as? [String: Any]
            let halo = max(0, number(near?["haloMargin"]) ?? 0)
            let pitch = max(font * 1.12, number(raw["lineHeight"]) ?? font * 1.12)
            guard pitch <= font * 4 else { record("invalid-leading-preserved"); continue }
            let reference = fitted(widths: fragmentWidths, text: text, fontSize: font, pitch: pitch, width: base.width,
                center: CGPoint(x: base.midX, y: 0), scale: scale, parameters: p,
                preserveWrap: true, minimumHalo: halo)
            if let reference {
                let retained = shifted(reference, dy: base.minY - reference.box.minY)
                if retained.rows.allSatisfy({ source.contains($0) }) {
                    record("already-source-contained-preserved"); continue
                }
            }
            let obstacles = page.items.indices.filter { $0 != index }.flatMap { peer -> [CGRect] in
                // Protect preserved source even when its display frame is empty.
                let sourceObstacle = sources[peer].map { [$0] } ?? []
                let display = accepted[peer] ?? rect(output[peer]).map { [$0] } ?? []
                return sourceObstacle + display
            }
            var winner: Choice?, attempts = 0
            for step in 0...steps {
                let ratio = 1 - (1 - minimum) * Double(step) / Double(steps)
                let size = font * CGFloat(ratio)
                guard size * scale >= minimumPixels else { continue }
                for fraction: CGFloat in [1, 0.85, 0.7] {
                    for leading: CGFloat in [1.3, 1.5, 1.7] {
                        guard let shape = fitted(widths: fragmentWidths, text: text, fontSize: size, pitch: max(pitch * CGFloat(ratio), size * leading),
                            width: source.width * fraction, center: .zero, scale: scale, parameters: p,
                            minimumHalo: halo) else { continue }
                        let block = union(shape.rows)
                        guard block.height <= source.height else { continue }
                        let centers = Set([source.midX, source.minX + block.width / 2, source.maxX - block.width / 2])
                        for center in centers.sorted() {
                            attempts += 1
                            let plan = shifted(shape, dx: center - block.midX, dy: source.minY - block.minY)
                            guard bounds.contains(plan.box), plan.rows.allSatisfy({ row in
                                source.contains(row) && !obstacles.contains(where: {
                                    row.intersects($0.insetBy(dx: -1 / scale, dy: -1 / scale))
                                })
                            }), let choice = scored(plan, originalFont: font, base: base,
                                baselineCenter: source.minY + block.height / 2, bodyCenter: source.midY,
                                balloon: false, parameters: p, horizontalAnchor: source.midX) else { continue }
                            if winner == nil || choice.score < winner!.score { winner = choice }
                        }
                    }
                }
                // Prefer the largest feasible display font; never shrink merely
                // to win a line-count objective over an already feasible plan.
                if winner != nil { break }
            }
            guard let selected = winner else {
                record("no-contained-complete-plan-preserved", ["attempts": attempts, "qualityAccepted": false]); continue
            }
            let chosen = selected.layout
            guard lexicalUTF16(text) == lexicalUTF16(chosen.text), lexicalUTF8(text) == lexicalUTF8(chosen.text),
                  tokenBytes(text) == tokenBytes(chosen.text) else { record("text-conservation-veto-preserved"); continue }
            output[index]["text"] = chosen.text
            output[index]["x"] = Double(chosen.box.minX); output[index]["y"] = Double(chosen.box.minY)
            output[index]["width"] = Double(chosen.box.width); output[index]["height"] = Double(chosen.box.height)
            output[index]["fontSize"] = Double(chosen.font); output[index]["lineHeight"] = Double(chosen.pitch)
            output[index]["ensembleLockLayout"] = true
            // Geometry only: palette and sourceNearLayout ownership metadata are
            // retained. Parent must check the lock survives final painting.
            let evidence: [String: Any] = ["status": "source-envelope-plan-proposed", "attempts": attempts,
                "sourceEnvelopeViewport": [Double(source.minX), Double(source.minY), Double(source.width), Double(source.height)],
                "glyphAndStrokeRowsViewport": chosen.rows.map { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] },
                "strokeRadiusViewport": Double(chosen.radius), "fontScale": Double(chosen.font / font),
                "nonWhitespaceUTF16Equal": true, "nonWhitespaceUTF8Equal": true, "tokenBytesEqual": true,
                "sourceTopAligned": true, "sourceGeometryChanged": false, "sentenceMerge": false,
                "sourceNearDisplayPlacementSuperseded": near != nil, "balloonContainmentCertified": false,
                "finalRasterMeasured": false, "qualityAccepted": false]
            output[index]["ensembleSourceEnvelopeAudit"] = evidence
            accepted[index] = chosen.rows
            record("source-envelope-plan-proposed", evidence)
        }
        return .init(items: output, audit: ["status": "complete", "items": records, "labelsRead": false,
            "sourceGroupingChanged": false, "qualityAccepted": false])
    }

    /// Relocate an infeasible source-near box only when its final display still
    /// intersects the specific peer named by the source-near conflict receipt.
    /// Keep every owner and its shaped text; all other pages are identity inputs.
    static func resolveInfeasibleSourceNearCollisions(_ page: Ensemble100Page) -> Ensemble100Proposal {
        var output = page.items
        var repairs: [[String: Any]] = []
        let bounds = CGRect(origin: .zero, size: page.viewport)
        let scale = min(CGFloat(page.original.width) / page.viewport.width,
            CGFloat(page.original.height) / page.viewport.height)
        guard scale.isFinite, scale > 0 else { return .init(items: output) }
        func margin(_ item: [String: Any]) -> CGFloat {
            let near = item["sourceNearLayout"] as? [String: Any]
            return max(1, CGFloat(number(near?["haloMargin"]) ?? 0) / scale)
        }
        for index in output.indices {
            let item = output[index]
            guard let near = item["sourceNearLayout"] as? [String: Any],
                  near["feasible"] as? Bool == false,
                  let neighbors = near["protectedNeighbors"] as? [[String: Any]],
                  !neighbors.isEmpty,
                  let old = rect(item),
                  let source = normalizedRect(item["sourceBounds"], viewport: page.viewport),
                  let text = item["text"] as? String, text.count >= 20,
                  item["ensembleLockLayout"] as? Bool != true,
                  neighbors.contains(where: { neighbor in
                      guard let peerID = neighbor["itemID"] as? String,
                            let peer = output.first(where: { $0["id"] as? String == peerID }),
                            let peerBox = rect(peer) else { return false }
                      let overlap = old.intersection(peerBox)
                      return !overlap.isNull && overlap.width >= min(old.width, peerBox.width) * 0.6 &&
                          overlap.height >= min(old.height, peerBox.height) * 0.8
                  }) else { continue }
            let padding = margin(item)
            let obstacles = output.indices.compactMap { peer -> CGRect? in
                guard peer != index,
                      output[peer]["sourceTextOnly"] as? Bool != true,
                      output[peer]["keptLettering"] as? Bool != true,
                      let box = rect(output[peer]) else { return nil }
                return box.insetBy(dx: -(padding + margin(output[peer])),
                    dy: -(padding + margin(output[peer])))
            }
            let sourceX = source.minX
            var y = max(old.minY, source.minY)
            let maximumY = min(bounds.maxY - old.height, source.minY + source.height * 0.25)
            var proposed: CGRect?
            while y <= maximumY {
                let box = CGRect(x: sourceX, y: y, width: old.width, height: old.height)
                guard bounds.contains(box) else { break }
                let collisions = obstacles.filter { box.intersects($0) }
                if collisions.isEmpty { proposed = box; break }
                let nextY = collisions.map(\.maxY).max() ?? y
                guard nextY > y + 0.001 else { break }
                y = nextY + 0.01
            }
            guard let proposed, abs(proposed.minX - old.minX) > 0.001 ||
                    abs(proposed.minY - old.minY) > 0.001 else { continue }
            output[index]["x"] = Double(proposed.minX)
            output[index]["y"] = Double(proposed.minY)
            repairs.append(["index": index, "id": item["id"] ?? NSNull(),
                "from": [old.minX, old.minY, old.width, old.height],
                "to": [proposed.minX, proposed.minY, proposed.width, proposed.height],
                "reason": "observed-final-conflict-and-infeasible-source-near"])
        }
        return .init(items: output, audit: ["repairs": repairs, "unchangedCount": output.count - repairs.count])
    }

    /// Match open vertical source columns by their observed top and em, not by
    /// translation length or background-colour confidence. Separate owners stay
    /// separate. A supported balloon retains its own containment/centering policy.
    static func sourceAlignedColumns(_ page: Ensemble100Page) -> Ensemble100Proposal {
        let fragmentWidths = FragmentWidths()
        struct Node {
            let index: Int
            let source: CGRect
            let allowed: CGRect
            let em: CGFloat
            let text: String
        }
        let nodes: [Node] = page.items.enumerated().compactMap { index, raw in
            guard raw["sourceVertical"] as? Bool == true, raw["vertical"] as? Bool != true,
                  raw["sourceTextOnly"] as? Bool != true, raw["keptLettering"] as? Bool != true,
                  abs(number(raw["rotation"]) ?? 0) < 0.001,
                  raw["balloonInterior"] == nil, raw["balloonUnit"] == nil,
                  NativeEnsembleLayoutContour.contour(raw: raw, viewport: page.viewport) == nil,
                  let near = raw["sourceNearLayout"] as? [String: Any],
                  near["rfStatus"] as? String == "missing-polygon;OCR-local-fallback",
                  let source = normalizedRect(raw["sourceBounds"], viewport: page.viewport),
                  let em = number(raw["sourceFontSize"]), em > 0,
                  let text = raw["text"] as? String, !text.isEmpty, text.utf16.count <= 2048 else { return nil }
            let conflicts = near["conflictingSourceIndices"] as? [Int] ?? []
            var allowed = viewportRect(near["allowedRect"])
            if !conflicts.isEmpty {
                // A tall OCR union can overlap a later, narrower column fragment.
                // Admit only a genuinely stacked dependency; keep that owner as
                // an obstacle below, never merge its sentence or erase its box.
                guard conflicts.allSatisfy({ peer in
                    guard page.items.indices.contains(peer),
                          let other = normalizedRect(page.items[peer]["sourceBounds"], viewport: page.viewport),
                          page.items[peer]["sourceVertical"] as? Bool == true else { return false }
                    return other.minY-source.minY > em*2 && other.width <= source.width*0.65
                        && other.minX >= source.minX-em*0.4 && other.maxX <= source.maxX+em*0.4
                }), let drift = number(near["maxCenterDrift"]), drift > 0 else { return nil }
                allowed = source.insetBy(dx:-drift,dy:-drift)
                    .intersection(CGRect(origin:.zero,size:page.viewport))
            } else if near["feasible"] as? Bool != true { return nil }
            guard let allowed, allowed.width > 0, allowed.height > 0 else { return nil }
            return Node(index: index, source: source, allowed: allowed, em: em, text: text)
        }
        func compatible(_ a: Node, _ b: Node) -> Bool {
            max(a.em, b.em) <= min(a.em, b.em) * 1.45 &&
                abs(a.source.minY - b.source.minY) <= min(a.em, b.em) * 0.65 &&
                (a.source.maxX <= b.source.minX || b.source.maxX <= a.source.minX)
        }
        var groups: [[Node]] = []
        for node in nodes.sorted(by: { $0.source.minX < $1.source.minX }) {
            if let i = groups.firstIndex(where: { $0.count < 32 && $0.allSatisfy { compatible($0, node) } }) {
                groups[i].append(node)
            } else { groups.append([node]) }
        }
        let scale = min(CGFloat(page.original.width) / page.viewport.width, CGFloat(page.original.height) / page.viewport.height)
        var output = page.items, records: [[String: Any]] = []
        let hasRowPeers = groups.contains { $0.count > 1 }
        for originalGroup in groups where originalGroup.count > 1 || hasRowPeers {
            var group = originalGroup
            // A missing RF polygon is not evidence of an open caption. When
            // only one source surface was measured, directly recheck the peer
            // pixels using its observed background rather than treating an
            // uncertain peer palette as evidence against common top alignment.
            let witnesses = group.filter { node in
                let near = page.items[node.index]["sourceNearLayout"] as? [String: Any]
                let witness = near?["sourceTopSurfaceWitness"] as? [String: Any]
                return witness?["accepted"] as? Bool == true && witness?["originalPixelsMeasured"] as? Bool == true
            }
            var peerSurfaceChecks: [[String: Any]] = []
            if witnesses.count < 2 {
                group = group.filter { node in
                    if witnesses.contains(where: { $0.index == node.index }) { return true }
                    let otherNear = page.items[node.index]["sourceNearLayout"] as? [String: Any]
                    let previous = otherNear?["sourceTopSurfaceWitness"] as? [String: Any]
                    // Do not override a measured enclosure/closed-surface veto.
                    let priorBackground = previous?["backgroundRGB"] as? [Double] ?? []
                    let possibleWhiteHalo = priorBackground.count == 3 && priorBackground.min()! >= 225
                    if previous?["originalPixelsMeasured"] as? Bool == true && !possibleWhiteHalo {
                        peerSurfaceChecks.append(["index": node.index, "status": "measured-surface-veto-preserved"])
                        return false
                    }
                    let pixels = CGRect(x: node.source.minX * scale, y: node.source.minY * scale,
                        width: node.source.width * scale, height: node.source.height * scale)
                    let measured = NativeSourceTopSurfaceWitness.measureLocal(original: page.original, source: pixels,
                        fontPixels: node.em * scale)
                    peerSurfaceChecks.append(["index": node.index, "evidence": measured])
                    return measured["accepted"] as? Bool == true
                }
                // Artwork/gradients can cut a real open caption's component
                // down to one escaping side. Two independently open peers and
                // tight original top/font agreement corroborate that case;
                // neither missing RF nor a lone one-sided patch is sufficient.
                if group.count >= 2 && originalGroup.count >= 3 {
                    let peerEm = group.map(\.em).sorted()[group.count / 2]
                    let peerTop = group.map { $0.source.minY }.sorted()[group.count / 2]
                    for node in originalGroup where !group.contains(where: { $0.index == node.index }) {
                        guard max(node.em,peerEm) <= min(node.em,peerEm)*1.25,
                              abs(node.source.minY-peerTop) <= min(node.em,peerEm)*0.35,
                              let record = peerSurfaceChecks.first(where: { $0["index"] as? Int == node.index }),
                              let evidence = record["evidence"] as? [String:Any],
                              let candidates = evidence["candidateChecks"] as? [[String:Any]],
                              candidates.contains(where: { c in
                                  let rgb = c["backgroundRGB"] as? [Double] ?? []
                                  return c["originalPixelsMeasured"] as? Bool == true && rgb.count == 3
                                      && rgb.max()! > 56 && rgb.min()! < 225
                                      && (c["openContextSides"] as? Int ?? 0) >= 1
                                      && (c["sourceComponentDominance"] as? Double ?? 0) >= 0.6
                                      && (c["matchingSourcePixels"] as? Int ?? 0) >= 12
                              }) else { continue }
                        group.append(node)
                        peerSurfaceChecks.append(["index":node.index,
                            "status":"one-side-original-context-plus-two-open-row-peers",
                            "authority":"joint geometric/pixel proxy; not balloon or paragraph truth"])
                    }
                }
            }
            guard group.count >= (originalGroup.count == 1 ? 1 : 2) else {
                records.append(["status": "insufficient-independent-open-surface-witnesses-preserved",
                    "indices": originalGroup.map(\.index), "witnessCount": witnesses.count,
                    "peerSurfaceChecks": peerSurfaceChecks])
                continue
            }
            let members = Set(group.map(\.index))
            let em = group.map(\.em).sorted()[group.count / 2]
            let top = group.map { $0.source.minY }.sorted()[group.count / 2]
            let obstacles = page.items.enumerated().flatMap { index, raw -> [CGRect] in
                guard !members.contains(index) else { return [] }
                return [rect(raw), normalizedRect(raw["sourceBounds"], viewport: page.viewport)].compactMap { $0 }
            }
            var plans: [Layout] = []
            // Use a single jointly feasible font, rather than independently
            // maximizing six different translation-length-dependent fonts.
            for step in 0...25 {
                let font = group.count == 1
                    ? min(em * 0.95, number(page.items[group[0].index]["fontSize"]) ?? em) * (1 - CGFloat(step) * 0.02)
                    : em * (0.95 - CGFloat(step) * 0.02)
                var trial: [Layout] = []
                for node in group {
                    guard let shape = fitted(widths: fragmentWidths, text: node.text, fontSize: font, pitch: font * 1.3,
                        width: node.allowed.width, center: .zero, scale: scale, parameters: defaults) else { break }
                    let block = union(shape.rows)
                    let cx = min(node.allowed.maxX - block.width / 2,
                        max(node.allowed.minX + block.width / 2, node.source.midX))
                    let plan = shifted(shape, dx: cx - block.midX, dy: top - block.minY)
                    guard plan.rows.allSatisfy({ row in node.allowed.contains(row) &&
                        !obstacles.contains(where: { $0.intersects(row) }) }),
                        !trial.flatMap(\.rows).contains(where: { a in plan.rows.contains { a.intersects($0) } }) else { break }
                    trial.append(plan)
                }
                if trial.count == group.count { plans = trial; break }
            }
            guard plans.count == group.count else {
                records.append(["status": "no-common-contained-fit-preserved", "indices": group.map(\.index)])
                continue
            }
            for (node, plan) in zip(group, plans) {
                let i = node.index
                output[i]["text"] = plan.text
                output[i]["x"] = Double(plan.box.minX); output[i]["y"] = Double(plan.box.minY)
                output[i]["width"] = Double(plan.box.width); output[i]["height"] = Double(plan.box.height)
                output[i]["fontSize"] = Double(plan.font); output[i]["lineHeight"] = Double(plan.pitch)
                output[i]["ensembleLockLayout"] = true
                output[i]["ensembleStrokeRatio"] = max(0.20, defaults["strokeFraction"] ?? 0.20)
                output[i]["ensembleSharedFlowAudit"] = [
                    "centerAuthority": "source-aligned-column-cohort; common glyph+halo top and font; not balloon centering",
                    "indices": group.map(\.index), "commonFontViewport": Double(plan.font),
                    "commonGlyphHaloTopViewport": Double(top), "sentenceMerge": false,
                    "authority": "original OCR top and source-font estimates; no background colour prerequisite"] as [String: Any]
            }
            records.append(["status": group.count == 1 ? "source-top-single-owner-proposed" : "common-font-and-top-proposed", "indices": group.map(\.index),
                "fontViewport": Double(plans[0].font), "glyphHaloTopViewport": Double(top),
                "peerSurfaceChecks": peerSurfaceChecks])
        }
        return .init(items: output, audit: ["groups": records, "sentenceMerge": false, "labelsRead": false])
    }

    /// A shared balloon is a layout budget, never sentence-merge permission.
    /// Resolve only top-aligned OCR-column conflicts, leaving every owner/text/
    /// palette separate. All plans must fit the supported polygon together.
    static func sharedBalloonFlow(_ page: Ensemble100Page, parameters: [String: Double],
                                  layoutParameters: [String: Double], sourceDriftEm: Double) throws -> Ensemble100Proposal {
        let fragmentWidths = FragmentWidths()
        func option(_ name: String, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
            let value = parameters[name] ?? fallback
            return value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
        }
        guard option("enabled", 0, 0...1) > 0 else { return .init(items: page.items) }
        let viewport = page.viewport
        guard viewport.width > 0, viewport.height > 0, page.items.count <= 256,
              sourceDriftEm.isFinite, sourceDriftEm > 0 else { return .init(items: page.items) }
        struct Node {
            let index: Int, query: Int
            let id: String, text: String
            let source: CGRect
            let em: CGFloat
            let conflicts: [Int]
        }
        let protectedOwners = Set(page.savedEvidence["jointFlowProtectedOwnerKeys"] as? [String] ?? [])
        let nodes: [Node] = page.items.enumerated().compactMap { index, raw in
            guard let id = raw["id"] as? String, !protectedOwners.contains(id),
                  let text = raw["text"] as? String, !text.isEmpty, text.utf16.count <= 2048,
                  raw["sourceVertical"] as? Bool == true, raw["vertical"] as? Bool != true,
                  raw["keptLettering"] as? Bool != true, raw["sourceTextOnly"] as? Bool != true,
                  abs(number(raw["rotation"]) ?? 0) < 0.001,
                  let near = raw["sourceNearLayout"] as? [String: Any],
                  let query = near["rfQueryID"] as? Int,
                  let drift = number(near["maxCenterDrift"]), drift > 0,
                  let source = normalizedRect(raw["sourceBounds"], viewport: viewport) else { return nil }
            return Node(index:index, query:query, id:id, text:text, source:source,
                em:drift / CGFloat(sourceDriftEm), conflicts:near["conflictingSourceIndices"] as? [Int] ?? [])
        }
        let overlapY = CGFloat(option("minimumVerticalOverlap", 0.9, 0.8...0.99))
        let maximumOverlapX = CGFloat(option("maximumOverlapFraction", 0.25, 0.05...0.4))
        let topEm = CGFloat(option("maximumTopDifferenceEm", 0.35, 0.1...0.5))
        func compatible(_ a: Node, _ b: Node) -> Bool {
            guard a.query == b.query, max(a.em,b.em) <= min(a.em,b.em) * 1.3,
                  abs(a.source.minY-b.source.minY) <= min(a.em,b.em) * topEm,
                  max(a.source.height,b.source.height) <= min(a.source.height,b.source.height) * 4 else { return false }
            let intersection = a.source.intersection(b.source)
            let oy = max(0,min(a.source.maxY,b.source.maxY)-max(a.source.minY,b.source.minY))
            let ox = intersection.isNull ? 0 : intersection.width
            let gap = max(a.source.minX,b.source.minX)-min(a.source.maxX,b.source.maxX)
            return oy >= min(a.source.height,b.source.height) * overlapY &&
                ox <= min(a.source.width,b.source.width) * maximumOverlapX && gap <= min(a.em,b.em) * 0.4
        }
        var remaining = Set(nodes.map(\.index)), groups: [[Node]] = []
        for a in nodes where remaining.contains(a.index) {
            guard let b = nodes.first(where: { remaining.contains($0.index) && $0.index != a.index &&
                (a.conflicts.contains($0.index) || $0.conflicts.contains(a.index)) && compatible(a,$0) }) else { continue }
            var group = [a,b]
            for other in nodes where remaining.contains(other.index) && !group.contains(where: { $0.index == other.index }) {
                guard group.count < 6, group.allSatisfy({ $0.query == other.query &&
                    abs($0.source.minY-other.source.minY) <= min($0.em,other.em) * topEm &&
                    max($0.em,other.em) <= min($0.em,other.em) * 1.3 }),
                    group.contains(where: { compatible($0,other) }) else { continue }
                group.append(other)
            }
            for node in group { remaining.remove(node.index) }
            groups.append(group.sorted { $0.source.midX > $1.source.midX })
        }
        guard !groups.isEmpty else { return .init(items:page.items,audit:["status":"no-supported-column-conflict", "groups":[]]) }
        let explicitSampling = option("explicitPixelSampling", 1, 0...1) > 0
        guard let originalPixels = Pixels(page.original, explicitSampling: explicitSampling),
              let restoredPixels = Pixels(page.restored, explicitSampling: explicitSampling) else {
            return .init(items:page.items,audit:["status":"pixel-evidence-unavailable-preserved"])
        }
        var p = defaults
        p.merge(layoutParameters) { _, new in new }
        let outputScale = min(CGFloat(page.original.width)/viewport.width,CGFloat(page.original.height)/viewport.height)
        let minimumScale = CGFloat(option("minimumFontScale", 0.5, 0.35...0.7))
        let maximumScale = CGFloat(option("maximumFontScale", 0.8, 0.7...1))
        let gapEm = CGFloat(option("paragraphGapEm", 0.25, 0.1...0.6))
        // This optional flow is an improvement proposal, not the emergency
        // admission path. Do not replace an existing display with a much smaller
        // one merely because an oversized connected RF contour also contains it.
        let retainedFontRatio = CGFloat(option("minimumRetainedFontRatio", 0, 0...1))
        var output = page.items, records: [[String:Any]] = []
        let sourceExclusions = page.items.compactMap { normalizedRect($0["sourceBounds"],viewport:viewport) }
        var adoptedRows: [CGRect] = []
        for group in groups {
            try Task.checkCancellation()
            let members = Set(group.map(\.index))
            let source = group.reduce(CGRect.null) { $0.union($1.source) }
            var boundaryCounts: [String:Int] = [:]
            var pixelWitnesses: [[String:Any]] = []
            let spaces = page.rfRegions.compactMap { region -> Space? in
                guard region.classID == 2, region.queryID == group[0].query, region.confidence >= 0.65 else { return nil }
                boundaryCounts["rfParts",default:0] += 1
                guard let space = rfSpace(region,source:source,viewport:viewport,bodyFraction:0.65) else { return nil }
                boundaryCounts["scanlineParts",default:0] += 1
                guard support(space,source:source) >= 0.9 else { return nil }
                boundaryCounts["sourceCoverageParts",default:0] += 1
                let originalSupported: Bool, restoredSupported: Bool
                if option("useOriginalBoundaryWitness",0,0...1)>0 {
                    let a = NativeEnsembleTexturedContours.boundaryWitness(region,original:page.original)
                    let b = originalPixels.backgroundAgreement(restoredPixels,space:space,excluding:sourceExclusions,viewport:viewport)
                    originalSupported=a.supported; restoredSupported=b.supported
                    pixelWitnesses.append(["originalBoundary":a.audit,"restoredBackgroundAgreement":b.audit])
                } else if option("useBackgroundWitness",0,0...1)>0 {
                    let a = originalPixels.backgroundSupport(space,excluding:sourceExclusions,viewport:viewport,tolerance:42)
                    let b = restoredPixels.backgroundSupport(space,excluding:sourceExclusions,viewport:viewport,tolerance:42)
                    originalSupported=a.supported; restoredSupported=b.supported
                    pixelWitnesses.append(["original":a.audit,"restored":b.audit,
                        "oldOriginalCentroidSupported":originalPixels.supports(space,source:source,viewport:viewport,tolerance:42),
                        "oldRestoredCentroidSupported":restoredPixels.supports(space,source:source,viewport:viewport,tolerance:42)])
                } else {
                    originalSupported=originalPixels.supports(space,source:source,viewport:viewport,tolerance:42)
                    restoredSupported=restoredPixels.supports(space,source:source,viewport:viewport,tolerance:42)
                }
                guard originalSupported else { return nil }
                boundaryCounts["originalPixelSupportedParts",default:0] += 1
                guard restoredSupported else { return nil }
                boundaryCounts["restoredPixelSupportedParts",default:0] += 1
                return space
            }.sorted { $0.rect.width*$0.rect.height < $1.rect.width*$1.rect.height }
            guard let space = spaces.first else {
                records.append(["owners":group.map(\.id),"status":"original-restored-boundary-conflict-preserved",
                    "boundaryEvidence":boundaryCounts,"pixelWitnesses":pixelWitnesses]); continue
            }
            let obstacles = page.items.enumerated().flatMap { index,raw -> [CGRect] in
                guard !members.contains(index), (raw["text"] as? String)?.isEmpty == false ||
                    raw["keptLettering"] as? Bool == true || raw["sourceTextOnly"] as? Bool == true else { return [] }
                return [rect(raw),normalizedRect(raw["sourceBounds"],viewport:viewport)].compactMap { $0 }
            } + page.rfRegions.filter { $0.classID == 1 && $0.confidence >= 0.6 }.map {
                CGRect(x:$0.bounds.minX*viewport.width,y:$0.bounds.minY*viewport.height,
                    width:$0.bounds.width*viewport.width,height:$0.bounds.height*viewport.height)
            } + adoptedRows
            var winner: (layouts:[Layout],score:Double)?
            let em = group.map(\.em).sorted()[group.count/2]
            for step in 0...3 {
                let scale = maximumScale - (maximumScale-minimumScale)*CGFloat(step)/3
                for widthFraction: CGFloat in [0.65,0.82,0.96] {
                    let width = space.rect.width*widthFraction
                    var shapes: [Layout] = []
                    for node in group {
                        let font = node.em*scale
                        let existingFont = number(page.items[node.index]["fontSize"]) ?? 0
                        guard font >= existingFont * retainedFontRatio else { break }
                        guard let shape = fitted(widths: fragmentWidths, text:node.text,fontSize:font,pitch:font*1.3,width:width,
                            center:.zero,scale:outputScale,parameters:p) else { break }
                        shapes.append(shape)
                    }
                    guard shapes.count == group.count else { continue }
                    let gap = em*scale*gapEm
                    let totalHeight = shapes.reduce(0) { $0+union($1.rows).height } + gap*CGFloat(group.count-1)
                    let cx = min(space.rect.maxX-width/2,max(space.rect.minX+width/2,source.midX))
                    var y = space.bodyCenterY-totalHeight/2
                    var plans: [Layout] = [], rows: [CGRect] = []
                    for shape in shapes {
                        let block = union(shape.rows)
                        let dx = cx-block.midX, dy = y-block.minY
                        let shifted = Layout(text:shape.text,box:shape.box.offsetBy(dx:dx,dy:dy),font:shape.font,pitch:shape.pitch,
                            rows:shape.rows.map { $0.offsetBy(dx:dx,dy:dy) },radius:shape.radius,
                            inkRows:shape.inkRows.map { $0.offsetBy(dx:dx,dy:dy) },singletons:shape.singletons)
                        plans.append(shifted); rows += shifted.rows; y += block.height+gap
                    }
                    guard rows.allSatisfy({ row in space.contains(row) && !obstacles.contains(where: {
                        row.intersects($0.insetBy(dx:-1/outputScale,dy:-1/outputScale)) }) }) else { continue }
                    let score = Double(plans.reduce(0) { $0+$1.rows.count })*1.5 +
                        Double(plans.reduce(0) { $0+$1.singletons })*10 + pow(Double(1-scale),2)*24
                    if winner == nil || score < winner!.score { winner = (plans,score) }
                }
            }
            guard let winner else {
                records.append(["owners":group.map(\.id),"status":"no-joint-contained-plan-preserved",
                    "minimumRetainedFontRatio":Double(retainedFontRatio)]); continue
            }
            for (node,plan) in zip(group,winner.layouts) {
                output[node.index]["text"] = plan.text
                output[node.index]["x"] = Double(plan.box.minX); output[node.index]["y"] = Double(plan.box.minY)
                output[node.index]["width"] = Double(plan.box.width); output[node.index]["height"] = Double(plan.box.height)
                output[node.index]["fontSize"] = Double(plan.font); output[node.index]["lineHeight"] = Double(plan.pitch)
                output[node.index]["ensembleLockLayout"] = true
                output[node.index]["ensembleStrokeRatio"] = max(0.20,p["strokeFraction"] ?? 0.20)
                output[node.index]["ensembleSharedFlowAudit"] = ["separateOwner":node.id,"readingOrder":group.map(\.id),
                    "sourceNearContractReplacedForDisplayOnly":true,"sourceGeometryUnchanged":true,
                    "finalFontViewport":Double(plan.font),"finalStrokeRadiusViewport":Double(plan.radius),
                    "fontReference":"02source-em proxy inferred from its declared center drift, not font gold",
                    "centerAuthority":"shared RF scanline width-mass body-center estimate supported by original/restored samples; not optical-center gold",
                    "authority":"shared RF polygon plus original/restored pixels and complete shaped glyph+stroke containment"] as [String:Any]
            }
            adoptedRows += winner.layouts.flatMap(\.rows)
            records.append(["owners":group.map(\.id),"status":"joint-plan-proposed","sentenceMerge":false,
                "fontSizes":winner.layouts.map { Double($0.font) },"score":winner.score,
                "boundaryEvidence":boundaryCounts,"pixelWitnesses":pixelWitnesses])
        }
        return .init(items:output,audit:["status":"complete","groups":records,"sourceGeometryChanged":false,
            "sentenceMerge":false,"labelsRead":false,"qualityAccepted":false])
    }
}
