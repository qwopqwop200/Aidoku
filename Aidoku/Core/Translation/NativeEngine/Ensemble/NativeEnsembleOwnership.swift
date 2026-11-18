import CoreGraphics
import Foundation

/// Conservative raw-item join. No masks, inference, external files, labels or page identifiers.
enum EnsembleCandidate02: Ensemble100Candidate {
    static let defaults: [String: Double] = [
        "enabled": 1, "rfConfidence": 0.55, "rfCoverage": 0.88, "rfAmbiguity": 0.12,
        "overlap": 0.82, "topEm": 0.40, "heightRatio": 1.28, "fontRatio": 1.20,
        "gapEm": 0.90, "fallbackGapEm": 0.40, "displayGapEm": 0.70,
        "pixelDeviation": 0.18, "gutterContamination": 0.035, "paletteDistance": 0.16,
        "maxMembers": 4, "maxItems": 256, "pixelBudget": 262144, "requireSingleColumn": 1,
        "pixelMinimumGap": 1
    ]

    private struct Node {
        let index: Int
        let raw: [String: Any]
        let source: CGRect
        let frame: CGRect
        let font: Double
        let em: Double
        let vertical: Bool
        let text: String
    }
    private struct Owner {
        var query: Int?
        var coverage = 0.0
        var ambiguous = false
    }
    private struct Pixels {
        let rect: CGRect
        let width: Int
        let bytes: [UInt8]

        init?(_ image: CGImage, rect: CGRect, budget: Int, requireOpaque: Bool = false) {
            let crop = rect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard !crop.isNull, crop.width > 0, crop.height > 0,
                  crop.width * crop.height <= Double(budget), let part = image.cropping(to: crop) else { return nil }
            let w = part.width, h = part.height
            var data = [UInt8](repeating: 0, count: w * h * 4)
            let ok = data.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: w, height: h,
                    bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
                context.setFillColor(gray: 1, alpha: 1)
                context.fill(CGRect(x: 0, y: 0, width: w, height: h))
                if requireOpaque { context.setBlendMode(.copy) }
                context.draw(part, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard ok else { return nil }
            if requireOpaque, !stride(from: 3, to: data.count, by: 4).allSatisfy({ data[$0] == 255 }) { return nil }
            self.rect = crop; width = w; bytes = data
        }

        func rgb(_ x: Double, _ y: Double) -> [Double] {
            let ix = min(width - 1, max(0, Int(x - rect.minX)))
            let iy = min(bytes.count / (width * 4) - 1, max(0, Int(y - rect.minY)))
            let offset = (iy * width + ix) * 4
            return (0..<3).map { Double(bytes[offset + $0]) / 255 }
        }

        func sample(_ box: CGRect) -> [[Double]] {
            let step = max(1, sqrt(box.width * box.height / 1600))
            var result: [[Double]] = []
            for y in stride(from: box.minY + 0.5, to: box.maxY, by: step) {
                for x in stride(from: box.minX + 0.5, to: box.maxX, by: step) { result.append(rgb(x, y)) }
            }
            return result
        }
    }

    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    private static func rect(_ value: Any?) -> CGRect? {
        guard let a = value as? [Any], a.count == 4 else { return nil }
        let n = a.compactMap(number)
        guard n.count == 4, n[2] > 0, n[3] > 0 else { return nil }
        return CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
    }
    private static func array(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height] }
    private static func scale(_ r: CGRect, _ size: CGSize) -> CGRect {
        CGRect(x: r.minX * size.width, y: r.minY * size.height, width: r.width * size.width, height: r.height * size.height)
    }
    private static func lexical(_ s: String) -> [UInt16] {
        // No case folding or normalization: preserve every non-whitespace UTF16 unit exactly.
        Array(String(s.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }).utf16)
    }
    private static func node(_ raw: [String: Any], index: Int, single: Bool, viewport: CGSize) -> Node? {
        guard raw["keptLettering"] as? Bool != true, raw["sourceTextOnly"] as? Bool != true,
              raw["vertical"] as? Bool != true, raw["uprightQuadText"] as? Bool != true,
              raw["drawsUprightQuadText"] as? Bool != true,
              abs(number(raw["rotation"]) ?? 0) < 0.01,
              let vertical = raw["sourceVertical"] as? Bool,
              !vertical || !single || raw["sourceSingleColumn"] as? Bool == true,
              let text = raw["text"] as? String, !lexical(text).isEmpty,
              !text.contains("\n\n"), !text.contains("\u{2029}"),
              let s = rect(raw["sourceBounds"]), CGRect(x: 0, y: 0, width: 1, height: 1).contains(s),
              let x = number(raw["x"]), let y = number(raw["y"]),
              let w = number(raw["width"]), let h = number(raw["height"]), w > 0, h > 0,
              let font = number(raw["fontSize"]), font > 0,
              let line = number(raw["lineHeight"]), line > 0,
              raw["lightSurface"] as? Bool != nil else { return nil }
        if let display = raw["typesettingText"] as? String, lexical(display) != lexical(text) { return nil }
        let frame = CGRect(x: x, y: y, width: w, height: h)
        guard CGRect(origin: .zero, size: viewport).contains(frame) else { return nil }
        let sourceEm: Double = number(raw["sourceFontSize"]) ?? Double(vertical ? s.width * viewport.width : s.height * viewport.height)
        guard sourceEm > 0 else { return nil }
        return Node(index: index, raw: raw, source: s, frame: frame, font: font, em: sourceEm, vertical: vertical, text: text)
    }

    private static func inside(_ p: CGPoint, ring: [CGPoint]) -> Bool {
        guard ring.count >= 3, ring.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
        var result = false
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { result.toggle() }
        }
        return result
    }
    private static func contains(_ p: CGPoint, region: Ensemble100RFRegion) -> Bool {
        region.bounds.contains(p) && inside(p, ring: region.exterior) && !region.holes.contains { inside(p, ring: $0) }
    }
    private static func owner(_ n: Node, regions: [Ensemble100RFRegion], threshold: Double, ambiguity: Double) -> Owner {
        var coverage: [Int: Double] = [:]
        for query in Set(regions.map(\.queryID)) {
            let parts = regions.filter { $0.queryID == query }
            var hits = 0
            for y in 0..<5 { for x in 0..<5 {
                let p = CGPoint(x: n.source.minX + (Double(x) + 0.5) / 5 * n.source.width,
                                y: n.source.minY + (Double(y) + 0.5) / 5 * n.source.height)
                if parts.contains(where: { contains(p, region: $0) }) { hits += 1 }
            } }
            coverage[query] = Double(hits) / 25
        }
        let ranked = coverage.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        guard let best = ranked.first, best.value >= threshold else {
            return Owner(query: nil, coverage: ranked.first?.value ?? 0, ambiguous: (ranked.first?.value ?? 0) >= 0.35)
        }
        return Owner(query: best.key, coverage: best.value,
                     ambiguous: ranked.dropFirst().contains { $0.value >= threshold - ambiguity && best.value - $0.value <= ambiguity })
    }

    private static func compatible(_ a: Node, _ b: Node, viewport: CGSize, adjacent: Bool = true, p: (String) -> Double) -> Bool {
        guard a.vertical == b.vertical, max(a.font, b.font) <= min(a.font, b.font) * p("fontRatio"),
              max(a.em, b.em) <= min(a.em, b.em) * p("fontRatio") else { return false }
        for key in ["lightSurface", "sourceLettering", "fontScript", "wrappingScript", "paragraphID", "paragraphIndex"] {
            if let av = a.raw[key], let bv = b.raw[key], !NSDictionary(dictionary: ["v": av]).isEqual(to: ["v": bv]) { return false }
        }
        let sa = scale(a.source, viewport), sb = scale(b.source, viewport), em = min(a.em, b.em)
        let overlap = min(sa.maxY, sb.maxY) - max(sa.minY, sb.minY)
        let sourceGap = max(sa.minX, sb.minX) - min(sa.maxX, sb.maxX)
        let frameGap = max(a.frame.minX, b.frame.minX) - min(a.frame.maxX, b.frame.maxX)
        return (!adjacent || (sourceGap > 0 && sourceGap <= em * p("gapEm") &&
            frameGap >= -min(a.font, b.font) * 0.15 && frameGap <= min(a.font, b.font) * p("displayGapEm"))) &&
            overlap >= min(sa.height, sb.height) * p("overlap") &&
            abs(sa.minY - sb.minY) <= em * p("topEm") &&
            max(sa.height, sb.height) <= min(sa.height, sb.height) * p("heightRatio") &&
            abs(a.frame.minY - b.frame.minY) <= min(a.font, b.font) * 0.5 &&
            max(a.frame.height, b.frame.height) <= min(a.frame.height, b.frame.height) * 1.4
    }

    private static func distance(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).map { abs($0 - $1) }.max() ?? 1
    }
    private static func luminance(_ rgb: [Double]) -> Double { rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722 }
    private static func quantile(_ samples: [[Double]], _ q: Double) -> [Double]? {
        guard samples.count >= 12 else { return nil }
        let ordered = samples.sorted { luminance($0) < luminance($1) }
        return ordered[min(ordered.count - 1, Int(Double(ordered.count - 1) * q))]
    }

    /// Reuse the original-pixel witness without display-frame/font admission.
    /// The source grouper owns alignment, RF conflicts and final member palette.
    static func originalSurfaceEvidence(_ a: [String: Any], _ b: [String: Any], original: CGImage,
                                        viewport: CGSize, parameters: [String: Double] = [:]) -> [String: Any]? {
        func node(_ raw: [String: Any]) -> Node? {
            guard let vertical = raw["sourceVertical"] as? Bool, raw["lightSurface"] as? Bool != nil,
                  let source = rect(raw["sourceBounds"]), CGRect(x: 0, y: 0, width: 1, height: 1).contains(source),
                  let em = number(raw["sourceFontSize"]), em > 0 else { return nil }
            return Node(index: 0, raw: raw, source: source, frame: scale(source, viewport),
                font: em, em: em, vertical: vertical, text: raw["text"] as? String ?? "")
        }
        guard let left = node(a), let right = node(b) else { return nil }
        func p(_ key: String) -> Double {
            let value = parameters[key] ?? defaults[key] ?? 0
            return value.isFinite ? max(0, min(value, key == "pixelBudget" ? 4_194_304 : 1024)) : defaults[key] ?? 0
        }
        guard var evidence = pixelBridge(left, right, image: original, p: p, requireOpaque: true) else { return nil }
        evidence["originalPixelsMeasured"] = true
        evidence["displayGeometryRead"] = false
        evidence["authority"] = "original source/gutter pixels; not sentence or balloon truth"
        return evidence
    }

    /// A transparent balloon is not a flat white patch. Measure row-local
    /// changes in its source gutter instead of comparing all pixels with one
    /// global background quantile. Caller must already establish original OCR
    /// paragraph geometry and continuous RF/quotation support. Member ink
    /// consensus remains a separate mandatory downstream admission.
    static func originalLocalGutterEvidence(_ a:[String:Any],_ b:[String:Any],original:CGImage,
                                           budget:Int=1_048_576) -> [String:Any]? {
        guard let aa=rect(a["sourceBounds"]),let bb=rect(b["sourceBounds"]),
              CGRect(x:0,y:0,width:1,height:1).contains(aa),
              CGRect(x:0,y:0,width:1,height:1).contains(bb) else{return nil}
        let size=CGSize(width:original.width,height:original.height)
        let sa=scale(aa,size),sb=scale(bb,size)
        let left=sa.midX<sb.midX ? sa : sb,right=sa.midX<sb.midX ? sb : sa
        let gap=right.minX-left.maxX,top=max(sa.minY,sb.minY),bottom=min(sa.maxY,sb.maxY)
        guard gap>=3,bottom-top>=12,
              let pixels=Pixels(original,rect:sa.union(sb),budget:budget,requireOpaque:true) else{return nil}
        let x0=ceil(left.maxX)+0.5,x1=floor(right.minX)-0.5
        guard x1-x0>=2 else{return nil}
        var rowCount=0,abruptRows=0,maximumEdgeFraction=0.0
        var edgeCounts=[Int:Int]()
        for y in stride(from:top+0.5,to:bottom,by:max(1,(bottom-top)/192)) {
            var prior=pixels.rgb(x0,y),abrupt=false
            for x in stride(from:x0+1,through:x1,by:1) {
                let current=pixels.rgb(x,y)
                if distance(current,prior)>0.16 {
                    abrupt=true;edgeCounts[Int(x),default:0] += 1
                }
                prior=current
            }
            if abrupt {abruptRows += 1};rowCount += 1
        }
        guard rowCount>=12 else{return nil}
        maximumEdgeFraction=Double(edgeCounts.values.max() ?? 0)/Double(rowCount)
        let abruptFraction=Double(abruptRows)/Double(rowCount)
        // Reject persistent thin borders even when they occupy very few pixels.
        guard maximumEdgeFraction<=0.12,abruptFraction<=0.2 else{return nil}
        return ["originalPixelsMeasured":true,"displayGeometryRead":false,
                "localGutter":true,"rowCount":rowCount,"abruptRowsFraction":abruptFraction,
                "strongestBoundaryColumn":maximumEdgeFraction,"gutterWidthSourcePixels":gap,
                "authority":"row-local original gutter continuity; RF/OCR required by caller; not glyph or sentence truth"]
    }

    /// OFF candidate. Unlike the gradient witness, classify the *topology* of
    /// local gutter residuals. Short outline fringes attached to their source
    /// column are not a persistent dividing border. This supplies surface
    /// evidence only: the caller still owns sentence, competing-owner, palette,
    /// intervening-source and final text-conservation admission.
    /// Always log the result; only `accepted == true` is usable evidence.
    static func originalComponentCorridorAudit(_ a: [String: Any], _ b: [String: Any], original: CGImage,
                                               sourceOCRItems: [[String: Any]], regions: [Ensemble100RFRegion],
                                               enabled: Bool = false, budget: Int = 1_048_576) -> [String: Any] {
        var audit: [String: Any] = ["accepted": false, "originalPixelsMeasured": false,
            "displayGeometryRead": false, "witness": "original-component-corridor-v1",
            "authority": "original DB components, local residual topology and optional exact RF contour; not paragraph truth"]
        func reject(_ reason: String) -> [String: Any] {
            var result = audit; result["reason"] = reason; return result
        }
        guard enabled else { return reject("disabled") }
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard let aa = rect(a["sourceBounds"]), let bb = rect(b["sourceBounds"]), unit.contains(aa), unit.contains(bb),
              a["sourceVertical"] as? Bool == true, b["sourceVertical"] as? Bool == true else {
            return reject("invalid-original-columns")
        }
        if let x = number(a["rfBodyIndex"]), let y = number(b["rfBodyIndex"]), x != y {
            return reject("different-saved-owners")
        }
        guard sourceOCRItems.count <= 256,
              let ca = originalComponentSupport(aa, rows: sourceOCRItems, image: original),
              let cb = originalComponentSupport(bb, rows: sourceOCRItems, image: original),
              Set(ca.owners).isDisjoint(with: cb.owners) else { return reject("missing-or-ambiguous-original-components") }
        audit["originalComponentCounts"] = [ca.count, cb.count]
        audit["originalComponentMeanProbability"] = [ca.probability, cb.probability]
        let size = CGSize(width: original.width, height: original.height)
        let sa = scale(aa, size), sb = scale(bb, size)
        let left = sa.midX < sb.midX ? sa : sb, right = sa.midX < sb.midX ? sb : sa
        let em = min(sa.width, sb.width), gap = right.minX - left.maxX
        let top = max(sa.minY, sb.minY), bottom = min(sa.maxY, sb.maxY)
        guard em >= 6, gap >= 3, gap <= em * 1.2, bottom - top >= em * 2,
              abs(sa.minY - sb.minY) <= em * 0.3,
              bottom - top >= min(sa.height, sb.height) * 0.8,
              max(sa.height, sb.height) <= min(sa.height, sb.height) * 4 else { return reject("outside-bounded-column-grid") }

        // Confidence never grants a merge. An available segmentation must
        // uniquely own both sources and its exact gutter; holes, notches and
        // multipart discontinuities cannot be filled by endpoint sampling.
        let bodies = regions.filter { $0.classID == 2 && $0.confidence.isFinite && $0.confidence >= 0.55 &&
            $0.bounds.intersects(aa.union(bb)) && $0.exterior.count >= 3 }
        guard bodies.count <= 64,
              bodies.reduce(0, { $0 + $1.exterior.count + $1.holes.reduce(0, { $0 + $1.count }) }) <= 16_384,
              bodies.allSatisfy({ part in
                  part.exterior.allSatisfy { $0.x.isFinite && $0.y.isFinite } &&
                    part.holes.allSatisfy { $0.count >= 3 && $0.allSatisfy { $0.x.isFinite && $0.y.isFinite } }
              }) else { return reject("invalid-or-over-budget-rf-contours") }
        func candidates(_ source: CGRect) -> [(query: Int, hits: Int)] {
            Dictionary(grouping: bodies, by: \.queryID).compactMap { query, parts in
                var hits = 0
                for y in 0..<7 { for x in 0..<7 {
                    let point = CGPoint(x: source.minX + (Double(x) + 0.5) * source.width / 7,
                                        y: source.minY + (Double(y) + 0.5) * source.height / 7)
                    if parts.contains(where: { contains(point, region: $0) }) { hits += 1 }
                } }
                return hits >= 40 ? (query, hits) : nil
            }
        }
        let oa = candidates(aa), ob = candidates(bb)
        if !oa.isEmpty || !ob.isEmpty {
            guard oa.count == 1, ob.count == 1, oa[0].query == ob[0].query, oa[0].hits >= 45, ob[0].hits >= 45 else {
                return reject("different-or-ambiguous-rf-owners")
            }
            let band = CGRect(x: left.maxX / size.width, y: top / size.height,
                              width: gap / size.width, height: (bottom - top) / size.height)
            guard bodies.contains(where: { $0.queryID == oa[0].query && exactCorridorInside(band, region: $0) }) else {
                return reject("rf-hole-notch-or-disconnected-corridor")
            }
            audit["rfQuery"] = oa[0].query
            audit["rfExactCorridor"] = true
        } else {
            // No RF mask is a distinct, much tighter case, never equivalent to
            // RF support. DB evidence is bound separately to each exact source.
            guard bodies.isEmpty, a["rfBodyIndex"] == nil, b["rfBodyIndex"] == nil, gap <= em * 0.35 else {
                return reject("missing-rf-requires-tight-original-grid")
            }
            audit["rfExactCorridor"] = false
        }

        let x0 = Int(ceil(left.maxX)), x1 = Int(floor(right.minX))
        let y0 = Int(ceil(top)), y1 = Int(floor(bottom))
        let width = x1 - x0, height = y1 - y0
        guard width >= 3, height >= 12, budget > 0, budget <= 4_194_304,
              width <= budget / height,
              let pixels = Pixels(original, rect: CGRect(x: x0, y: y0, width: width, height: height),
                                  budget: budget, requireOpaque: true) else { return reject("opaque-pixel-budget-or-empty-corridor") }
        audit["originalPixelsMeasured"] = true
        audit["gutterWidthSourcePixels"] = gap
        audit["scannedPixels"] = width * height
        // A row-local median tracks gradual background shading without borrowing
        // either member's ink or a restored background. Every source pixel is
        // inspected; no stride can jump over a one-pixel border.
        var residual = [Bool](repeating: false, count: width * height), residualCount = 0
        var previous = [[Double]](), transverseRows = 0
        for y in 0..<height {
            let colors = (0..<width).map { pixels.rgb(Double(x0 + $0) + 0.5, Double(y0 + y) + 0.5) }
            if !previous.isEmpty,
               Double(zip(colors, previous).filter { distance($0, $1) > 0.12 }.count) >= Double(width) * 0.85 {
                transverseRows += 1
            }
            previous = colors
            let median = (0..<3).map { channel in colors.map { $0[channel] }.sorted()[width / 2] }
            for x in 0..<width where distance(colors[x], median) > 0.12 {
                residual[y * width + x] = true; residualCount += 1
            }
        }
        var longest = 0, detached = 0, crossGutter = 0, componentCount = 0
        for start in residual.indices where residual[start] {
            var stack = [start], minY = start / width, maxY = minY, touchesLeft = false, touchesRight = false
            residual[start] = false; componentCount += 1
            while let index = stack.popLast() {
                let x = index % width, y = index / width
                minY = min(minY, y); maxY = max(maxY, y)
                touchesLeft = touchesLeft || x == 0; touchesRight = touchesRight || x == width - 1
                for dy in -1...1 { for dx in -1...1 {
                    let xx = x + dx, yy = y + dy
                    guard xx >= 0, xx < width, yy >= 0, yy < height else { continue }
                    let next = yy * width + xx
                    if residual[next] { residual[next] = false; stack.append(next) }
                } }
            }
            longest = max(longest, maxY - minY + 1)
            if !touchesLeft && !touchesRight { detached += 1 }
            if touchesLeft && touchesRight { crossGutter += 1 }
        }
        audit["residualComponents"] = componentCount
        audit["residualFraction"] = Double(residualCount) / Double(width * height)
        audit["longestResidualSourcePixels"] = longest
        audit["originalColumnWidthSourcePixels"] = em
        audit["detachedResidualComponents"] = detached
        audit["crossGutterComponents"] = crossGutter
        audit["transverseBoundaryRows"] = transverseRows
        guard detached == 0, crossGutter == 0, Double(longest) <= em * 1.1,
              transverseRows == 0,
              Double(residualCount) / Double(width * height) <= 0.3 else { return reject("persistent-detached-or-crossing-original-boundary") }
        audit["accepted"] = true
        audit["reason"] = "bounded-original-component-fringes-without-dividing-boundary"
        return audit
    }

    private static func originalComponentSupport(_ source: CGRect, rows: [[String: Any]], image: CGImage)
        -> (count: Int, probability: Double, owners: [String])? {
        let matches = rows.filter { row in
            let box = rect(row["sourceBounds"]) ?? (row["rect"] as? [String: Any]).flatMap { raw -> CGRect? in
                guard let x = number(raw["x"]), let y = number(raw["y"]),
                      let w = number(raw["width"]), let h = number(raw["height"]) else { return nil }
                return rect([x, y, w, h])
            }
            return box.map { zip(array(source), array($0)).allSatisfy { abs($0 - $1) < 1e-7 } } ?? false
        }
        guard matches.count == 1, let row = matches.first, (number(row["confidence"]) ?? 0) >= 0.8,
              row["sourceSingleVerticalColumn"] as? Bool == true else { return nil }
        if let summary = row["sourceOwnedDetectorComponents"] as? [String: Any] {
            guard number(summary["version"]) == 1, summary["complete"] as? Bool == true,
                  number(summary["omittedComponentCount"]) == 0,
                  summary["originalSourceSize"] as? [Double] == [Double(image.width), Double(image.height)],
                  let components = summary["components"] as? [[String: Any]],
                  !components.isEmpty, components.count <= 16 else { return nil }
            var owners = [String: CGRect](), probability = 1.0
            for component in components {
                guard let owner = component["ownerID"] as? String, !owner.isEmpty,
                      let bounds = rect(component["bounds"]),
                      CGRect(x: 0, y: 0, width: 1, height: 1).contains(bounds),
                      let mean = number(component["meanProbability"]), (0.9...1).contains(mean),
                      let pixels = number(component["pixels"]), pixels > 0, pixels <= 262_144 else { return nil }
                owners[owner] = (owners[owner] ?? .null).union(bounds)
                probability = min(probability, mean)
            }
            guard owners.values.allSatisfy({ envelope in
                let overlap = envelope.intersection(source)
                return !overlap.isNull && overlap.width * overlap.height >= envelope.width * envelope.height * 0.9 &&
                    overlap.height >= source.height * 0.6
            }) else { return nil }
            return (components.count, probability, Array(owners.keys).sorted())
        }
        guard let seeds = row["detectorSeedEvidence"] as? [[String: Any]], !seeds.isEmpty, seeds.count <= 8 else { return nil }
        var count = 0, probability = 1.0, owners = [String](), totalRuns = 0
        for seed in seeds {
            guard seed["completeCCScan"] as? Bool == true,
                  seed["provenance"] as? String == "db-complete-cc-candidates-v2",
                  number(seed["ownershipVersion"]) == 2, number(seed["threshold"]) == 0.9,
                  let owner = seed["ownerID"] as? String, !owner.isEmpty, owner.utf8.count <= 160,
                  number(seed["sourceWidth"]) == Double(image.width), number(seed["sourceHeight"]) == Double(image.height),
                  let w = number(seed["mapFullWidth"]), let h = number(seed["mapFullHeight"]), w > 0, h > 0, w <= 32_768, h <= 32_768,
                  let originX = number(seed["mapOriginX"]), let originY = number(seed["mapOriginY"]),
                  originX >= 0, originY >= 0, originX < w, originY < h,
                  let components = seed["components"] as? [[String: Any]], !components.isEmpty, components.count <= 64,
                  let ambiguous = seed["ambiguousComponents"] as? [Any], ambiguous.isEmpty,
                  let candidates = seed["candidateComponents"] as? [Any], candidates.isEmpty else { return nil }
            owners.append(owner)
            var envelope = CGRect.null, componentSeeds = Set<Double>()
            for component in components {
                guard let mean = number(component["meanProbability"]), mean >= 0.9, mean <= 1,
                      let componentSeed = number(component["seed"]), componentSeed >= 0, componentSeed < w * h,
                      componentSeeds.insert(componentSeed).inserted,
                      let runs = component["runs"] as? [[String: Any]], !runs.isEmpty, runs.count <= 4096,
                      let first = runs.first, let firstX = number(first["x"]), let firstY = number(first["y"]),
                      componentSeed == firstY * w + firstX else { return nil }
                totalRuns += runs.count
                guard totalRuns <= 8192 else { return nil }
                var pixels = 0.0, previousY = -1.0, previousEnd = -1.0
                for run in runs {
                    guard let x = number(run["x"]), let y = number(run["y"]), let n = number(run["count"]),
                          x >= originX, y >= originY, n > 0, x + n <= w, y < h,
                          x.rounded() == x, y.rounded() == y, n.rounded() == n,
                          y > previousY || (y == previousY && x >= previousEnd) else { return nil }
                    envelope = envelope.union(CGRect(x: x / w, y: y / h, width: n / w, height: 1 / h))
                    previousY = y; previousEnd = x + n; pixels += n
                }
                guard pixels <= 262_144, pixels == number(component["pixelCount"]) else { return nil }
                probability = min(probability, mean); count += 1
            }
            // DB is text support, not a glyph mask. It must actually correspond
            // to this source rather than a remote component with similar text.
            let overlap = envelope.intersection(source)
            guard !overlap.isNull, overlap.width * overlap.height >= envelope.width * envelope.height * 0.9,
                  overlap.height >= source.height * 0.6 else { return nil }
        }
        return Set(owners).count == owners.count ? (count, probability, owners) : nil
    }

    private static func exactCorridorInside(_ band: CGRect, region: Ensemble100RFRegion) -> Bool {
        let corners = [CGPoint(x: band.minX, y: band.minY), CGPoint(x: band.maxX, y: band.minY),
                       CGPoint(x: band.maxX, y: band.maxY), CGPoint(x: band.minX, y: band.maxY)]
        guard corners.allSatisfy({ contains($0, region: region) }) else { return false }
        func crosses(_ a: CGPoint, _ b: CGPoint) -> Bool {
            var lo = 0.0, hi = 1.0
            for (origin, delta, lower, upper) in [(a.x, b.x - a.x, band.minX, band.maxX),
                                                 (a.y, b.y - a.y, band.minY, band.maxY)] {
                if abs(delta) < 1e-15 {
                    if origin < lower || origin > upper { return false }
                } else {
                    let t0 = (lower - origin) / delta, t1 = (upper - origin) / delta
                    lo = max(lo, min(t0, t1)); hi = min(hi, max(t0, t1))
                    if lo > hi { return false }
                }
            }
            return true
        }
        return !([region.exterior] + region.holes).contains { ring in
            ring.indices.contains { crosses(ring[$0], ring[($0 + 1) % ring.count]) }
        }
    }

    private static func pixelBridge(_ a: Node, _ b: Node, image: CGImage, p: (String) -> Double,
                                    requireOpaque: Bool = false) -> [String: Any]? {
        let size = CGSize(width: image.width, height: image.height)
        let sa = scale(a.source, size), sb = scale(b.source, size)
        let left = sa.minX < sb.minX ? sa : sb, right = sa.minX < sb.minX ? sb : sa
        let top = max(sa.minY, sb.minY), bottom = min(sa.maxY, sb.maxY)
        let gap = right.minX - left.maxX
        // The source grouper admits adjacent columns, but the old two-pixel
        // minimum silently rejected a real one-pixel gutter before inspecting
        // it. One complete source pixel is measurable; touching/overlapping
        // boxes still provide no gutter evidence and remain rejected.
        guard gap >= max(1, p("pixelMinimumGap")) - 1e-6, bottom - top >= 6,
              let pixels = Pixels(image, rect: sa.union(sb), budget: Int(p("pixelBudget")), requireOpaque: requireOpaque) else { return nil }
        let light = a.raw["lightSurface"] as? Bool == true
        let aa = pixels.sample(sa), bb = pixels.sample(sb)
        guard let bgA = quantile(aa, light ? 0.85 : 0.15), let bgB = quantile(bb, light ? 0.85 : 0.15),
              let inkA = quantile(aa, light ? 0.05 : 0.95), let inkB = quantile(bb, light ? 0.05 : 0.95),
              distance(bgA, bgB) <= p("paletteDistance"), distance(inkA, inkB) <= p("paletteDistance"),
              distance(inkA, bgA) >= 0.25, distance(inkB, bgB) >= 0.25 else { return nil }
        let bg = zip(bgA, bgB).map { ($0 + $1) / 2 }
        // Inspect every gutter column (including thin bubble borders), with bounded row sampling.
        var bad = 0, total = 0, strongestColumn = 0.0
        for x in stride(from: left.maxX + 0.25, to: right.minX, by: 1) {
            var columnBad = 0, columnCount = 0
            for y in stride(from: top + 0.5, to: bottom, by: max(1, (bottom - top) / 128)) {
                if distance(pixels.rgb(x, y), bg) > p("pixelDeviation") { columnBad += 1 }
                columnCount += 1
            }
            bad += columnBad; total += columnCount
            strongestColumn = max(strongestColumn, Double(columnBad) / Double(max(1, columnCount)))
        }
        let contamination = Double(bad) / Double(max(1, total))
        guard total > 0, contamination <= p("gutterContamination"), strongestColumn <= 0.25 else { return nil }
        return ["gutterContamination": contamination, "strongestBoundaryColumn": strongestColumn,
                "sourceBackgroundRGB": bg, "sourceInkDistance": distance(inkA, inkB), "sampleCount": total,
                "gutterWidthSourcePixels": gap, "minimumGutterSourcePixels": max(1, p("pixelMinimumGap"))]
    }

    private static func verifiedContourAllows(_ raw: [String: Any], union: CGRect) -> Bool {
        guard let contour = raw["balloonInterior"] as? [String: Any], contour["contourVerified"] as? Bool == true else { return true }
        guard let r = rect(contour["rect"]), r.contains(union),
              let spans = contour["spans"] as? [Double], spans.count >= 4, spans.count % 2 == 0,
              spans.allSatisfy(\.isFinite) else { return false }
        let rows = spans.count / 2
        for k in 0..<5 {
            let y = union.minY + (Double(k) + 0.5) / 5 * union.height
            let row = min(rows - 1, max(0, Int((y - r.minY) / r.height * Double(rows))))
            if spans[row * 2] > union.minX || spans[row * 2 + 1] < union.maxX { return false }
        }
        return true
    }

    static func apply(_ page: Ensemble100Page, parameters: [String: Double]) throws -> Ensemble100Proposal {
        func p(_ key: String) -> Double {
            let fallback = defaults[key] ?? 0
            guard let n = parameters[key], n.isFinite else { return fallback }
            return max(0, min(n, key == "pixelBudget" ? 4194304 : key == "maxItems" ? 1024 : 1024))
        }
        guard p("enabled") > 0, page.items.count <= Int(p("maxItems")),
              page.viewport.width.isFinite, page.viewport.height.isFinite, page.viewport.width > 0, page.viewport.height > 0 else {
            return Ensemble100Proposal(items: page.items, audit: ["candidate": "02", "status": "disabled-or-outside-budget"])
        }
        let nodes = page.items.enumerated().map { node($0.element, index: $0.offset, single: p("requireSingleColumn") > 0, viewport: page.viewport) }
        // Box-only all-class detections are explicitly NOT segmentation evidence.
        let regions = page.rfRegions.filter { $0.classID == 2 && $0.exterior.count >= 3 &&
            $0.confidence.isFinite && $0.confidence >= p("rfConfidence") }
        let owners = nodes.map { n in n.map { owner($0, regions: regions, threshold: p("rfCoverage"), ambiguity: p("rfAmbiguity")) } }
        var output: [[String: Any]] = [], decisions: [[String: Any]] = [], rejected: [String: Int] = [:]
        var i = 0
        while i < page.items.count {
            guard let first = nodes[i] else { output.append(page.items[i]); i += 1; continue }
            var group = [first], edges: [[String: Any]] = [], j = i + 1
            while j < nodes.count, group.count < max(2, Int(p("maxMembers"))), let next = nodes[j], let tail = group.last {
                guard compatible(tail, next, viewport: page.viewport, p: p),
                      group.allSatisfy({ compatible($0, next, viewport: page.viewport, adjacent: false, p: p) }) else { break }
                if group.count > 1 {
                    let previous = group[group.count - 2]
                    guard (tail.source.midX - previous.source.midX) * (next.source.midX - tail.source.midX) > 0 else { break }
                }
                let oa = owners[tail.index]!, ob = owners[next.index]!
                guard !oa.ambiguous, !ob.ambiguous else { rejected["ambiguousRF", default: 0] += 1; break }
                guard Set((group + [next]).compactMap { owners[$0.index]?.query }).count <= 1 else {
                    rejected["differentRF", default: 0] += 1; break
                }
                let sameOwner = oa.query != nil && oa.query == ob.query
                let sa = scale(tail.source, page.viewport), sb = scale(next.source, page.viewport)
                let gap = max(sa.minX, sb.minX) - min(sa.maxX, sb.maxX)
                guard sameOwner || gap <= min(tail.em, next.em) * p("fallbackGapEm") else { break }
                let union = (group + [next]).reduce(CGRect.null) { $0.union($1.source) }
                guard (group + [next]).allSatisfy({ verifiedContourAllows($0.raw, union: union) }) else { break }
                // An RF body shared by endpoints must also own the gutter, including all polygon holes.
                if sameOwner {
                    let bodies = regions.filter { $0.queryID == oa.query }
                    var clear = true
                    for y in 0..<5 { for x in 1...3 {
                        let left = min(tail.source.maxX, next.source.maxX), right = max(tail.source.minX, next.source.minX)
                        let py = max(tail.source.minY, next.source.minY) + (Double(y) + 0.5) / 5 *
                            (min(tail.source.maxY, next.source.maxY) - max(tail.source.minY, next.source.minY))
                        let point = CGPoint(x: left + Double(x) / 4 * (right - left), y: py)
                        if !bodies.contains(where: { contains(point, region: $0) }) { clear = false }
                    } }
                    guard clear else { rejected["rfGutterHole", default: 0] += 1; break }
                }
                let members = Set((group + [next]).map(\.index))
                let frame = (group + [next]).reduce(CGRect.null) { $0.union($1.frame) }
                guard !page.items.indices.contains(where: { k in
                    guard !members.contains(k) else { return false }
                    if let s = rect(page.items[k]["sourceBounds"]), s.intersects(union) { return true }
                    guard let x = number(page.items[k]["x"]), let y = number(page.items[k]["y"]),
                          let w = number(page.items[k]["width"]), let h = number(page.items[k]["height"]) else { return false }
                    return CGRect(x: x, y: y, width: w, height: h).intersects(frame)
                }) else { rejected["interveningItem", default: 0] += 1; break }
                guard var evidence = pixelBridge(tail, next, image: page.original, p: p) else {
                    rejected["pixelBridge", default: 0] += 1; break
                }
                evidence["ownership"] = sameOwner ? "RF-polygon+OCR+pixels" : "tight-OCR+pixels;RF-missing-or-unconfirmed"
                evidence["rfCoverage"] = [oa.coverage, ob.coverage]
                edges.append(evidence); group.append(next); j += 1
            }
            guard group.count > 1 else { output.append(first.raw); i += 1; continue }
            let source = group.reduce(CGRect.null) { $0.union($1.source) }
            let frame = group.reduce(CGRect.null) { $0.union($1.frame) }
            var joined = first.raw
            let text = group.map(\.text).joined(separator: " ")
            guard lexical(text) == group.flatMap({ lexical($0.text) }) else {
                output.append(first.raw); i += 1; continue
            }
            joined["text"] = text
            joined["id"] = "agent02:" + group.map { String($0.index) + ":" + ($0.raw["id"] as? String ?? "") }.joined(separator: "+")
            joined["sourceBounds"] = array(source)
            joined["x"] = frame.minX; joined["y"] = frame.minY; joined["width"] = frame.width; joined["height"] = frame.height
            joined["sourceSingleColumn"] = false
            joined["unitMemberRects"] = group.flatMap { ($0.raw["unitMemberRects"] as? [[Double]]).flatMap { $0.isEmpty ? nil : $0 } ?? [array($0.source)] }
            let sourceMembers = group.compactMap { $0.raw["sourceMemberPolygons"] as? [[[Double]]] }
            if sourceMembers.count == group.count { joined["sourceMemberPolygons"] = sourceMembers.flatMap { $0 } }
            else { joined.removeValue(forKey: "sourceMemberPolygons") }
            joined["auxiliaryInkRects"] = group.flatMap { $0.raw["auxiliaryInkRects"] as? [[Double]] ?? [] }
            joined["auxiliaryInkPolygons"] = group.flatMap { $0.raw["auxiliaryInkPolygons"] as? [[[Double]]] ?? [] }
            // Retain every original raw member (including style, OCR polygons and prior lineage).
            joined["agent02MemberItems"] = group.map(\.raw)
            joined["agent02MemberIndices"] = group.map(\.index)
            joined["agent02MemberIDs"] = group.map { $0.raw["id"] as? String ?? "" }
            for key in ["typesettingText", "sourcePolygon", "sourceQuad", "smallTextReference", "unitPlannedCard",
                        "balloonUnit", "columnLayout", "uprightAlternative", "typesettingPreformattedRows"] {
                joined.removeValue(forKey: key)
            }
            let queries = group.compactMap { owners[$0.index]?.query }
            if queries.count == group.count, Set(queries).count == 1 {
                joined["rfBodyIndex"] = queries[0]
            } else {
                joined.removeValue(forKey: "rfBodyIndex"); joined.removeValue(forKey: "rfBodyConfidence")
                joined.removeValue(forKey: "balloonInterior")
            }
            output.append(joined)
            decisions.append(["memberIndices": group.map(\.index), "memberIDs": joined["agent02MemberIDs"]!,
                              "textUTF16": group.map { $0.text.utf16.count }, "edges": edges])
            i = j
        }
        return Ensemble100Proposal(items: output, audit: ["candidate": "02", "inputCount": page.items.count,
            "outputCount": output.count, "joins": decisions, "rejected": rejected,
            "rfPolygonCount": regions.count, "rfBoxOnlyCount": page.rfRegions.filter { $0.exterior.isEmpty }.count,
            "originalOCR": page.savedEvidence["originalOCR"] == nil ? "missing;raw-item-geometry-fallback;no-inference" : "available;raw-item-geometry-used",
            "evidence": "automated source-pixel and geometry measurements; no visual inspection or quality claim"])
    }
}
