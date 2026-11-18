import CoreGraphics
import Foundation

/// Independent optional experiment. Subtract only structurally supported flat
/// backing components; all other incoming glyph/fill/stroke support stays intact.
enum NativeEnsembleRemovalFlatBacking {
    static let defaults: [String: Double] = [
        "enabled": 1, "minimumDensity": 0.98, "colorTolerance": 12,
        "minimumRectangularity": 0.82, "minimumCellAreaEm2": 0.025,
        "maximumFlatDeviation": 3, "flatCoreTolerance": 6,
        "lineCoreThreshold": 0.55, "maximumBackingDBMean": 0.08,
        "maxPixels": 16_777_216, "maxROIPixels": 1_000_000, "maxWorkPixels": 12_000_000
    ]
    struct Owner {
        let polygon: [CGPoint] // normalized top-left ORIGINAL source geometry
        let fontPixels: Double? // original-pixel em; nil is unknown, not synthesized
        let preserved: Bool
    }
    struct Ownership { let original: CGImage; let owners: [Owner] }
    typealias FullDB = NativeMainAOTRemovalMaskBuilder.SourceProbability
    struct Result {
        let replacementMask: CGImage?
        let requiresRestoration: Bool
        let audit: [String: Any]
    }
    private struct Stop: Error { let reason: String }
    private struct Color {
        let r: Double; let g: Double; let b: Double
        func gap(_ other: Color) -> Double { max(abs(r - other.r), max(abs(g - other.g), abs(b - other.b))) }
    }
    private struct Component {
        let pixels: [Int]
        let color: Int
        let box: CGRect
        let mean: Color
        let deviation: Double
        let boundary: Bool
        let strong: Int
        let dbMean: Double
        var rectangularity: Double { Double(pixels.count) / (box.width * box.height) }
    }

    /// Call after all mask additions/protection and before final cache binding/AOT.
    /// DB is shrunk LINE-CORE association, never glyph segmentation. Use the full
    /// incoming source-factory mask, NOT an already DB-clipped DenseSupport mask.
    /// There is no DB-mask intersection, DB-radius clipping, RF/body input, text
    /// mutation or restored-image dependency. Caller validates actual DB provenance.
    static func apply(original: CGImage, mask: CGImage, ownership: Ownership, probability: FullDB?,
                      parameters: [String: Double] = [:]) throws -> Result {
        let started = Date(), ownerCount = ownership.owners.count
        func p(_ key: String, _ range: ClosedRange<Double>) -> Double {
            let v = parameters[key] ?? defaults[key]!
            return v.isFinite ? max(range.lowerBound, min(range.upperBound, v)) : defaults[key]!
        }
        func unchanged(_ reason: String, _ records: [[String: Any]] = []) -> Result {
            let done = Set(records.compactMap { $0["index"] as? Int })
            let inventory = records + (0..<ownerCount).filter { !done.contains($0) }.map {
                ["index": $0, "status": "not-evaluated-\(reason)"] as [String: Any]
            }
            return .init(replacementMask: nil, requiresRestoration: false,
                audit: ["status": "unchanged", "reason": reason, "changedPixels": 0,
                    "inputOwners": ownerCount, "accountedOwners": ownerCount, "owners": inventory,
                    "postfilterSeconds": Date().timeIntervalSince(started), "qualityAccepted": false,
                    "DBInterpretation": "shrunk-line-core-not-glyph-mask"])
        }
        guard p("enabled", 0...1) > 0 else { return unchanged("disabled") }
        guard ownership.original === original else { return unchanged("ownership-source-identity-mismatch") }
        let w = original.width, h = original.height
        guard w > 0, h > 0, w <= Int(p("maxPixels", 1...16_777_216)) / h,
              mask.width == w, mask.height == h, ownerCount <= 256 else { return unchanged("source-mask-dimensions-or-budget") }
        guard ownership.owners.allSatisfy({ o in
            (3...1024).contains(o.polygon.count) && o.polygon.allSatisfy {
                $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y)
            }
        }) else { return unchanged("invalid-source-ownership") }
        if let db = probability {
            guard db.original === original else { return unchanged("DB-source-identity-mismatch") }
            guard db.width > 0, db.height > 0, db.width <= w, db.height <= h,
                  db.values.count == db.width * db.height,
                  db.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return unchanged("invalid-actual-full-DB-grid") }
        }
        var records: [[String: Any]] = [], work = 0, rgb: [UInt8]?
        do {
            let input = try gray(mask)
            var votes = [UInt8](repeating: 0, count: w * h)
            for (index, owner) in ownership.owners.enumerated() {
                try Task.checkCancellation()
                let points = owner.polygon.map { CGPoint(x: $0.x * CGFloat(w), y: $0.y * CGFloat(h)) }
                let box = CGRect(x: points.map(\.x).min()!, y: points.map(\.y).min()!,
                    width: points.map(\.x).max()! - points.map(\.x).min()!,
                    height: points.map(\.y).max()! - points.map(\.y).min()!).integral
                    .intersection(CGRect(x: 0, y: 0, width: w, height: h))
                guard !box.isNull, !box.isEmpty, !box.isInfinite else { throw Stop(reason: "degenerate-owner-\(index)") }
                let rw = Int(box.width), rh = Int(box.height), x0 = Int(box.minX), y0 = Int(box.minY), n = rw * rh
                guard n <= Int(p("maxROIPixels", 64...4_000_000)),
                      work <= Int(p("maxWorkPixels", 64...32_000_000)) - n else { throw Stop(reason: "ROI-or-total-budget-\(index)") }
                work += n
                let own = try raster(points, box: box, width: rw, height: rh)
                let owned = own.indices.filter { own[$0] != 0 }
                guard !owned.isEmpty else { throw Stop(reason: "empty-owner-\(index)") }
                func global(_ i: Int) -> Int { (y0 + i / rw) * w + x0 + i % rw }
                let masked = owned.filter { input[global($0)] != 0 }
                let density = Double(masked.count) / Double(owned.count)
                var record: [String: Any] = ["index": index, "ownedPixels": owned.count, "maskedPixels": masked.count, "density": density]
                func retain(_ reason: String) {
                    for i in masked { votes[global(i)] |= 2 }; record["status"] = reason
                }
                guard !owner.preserved else { retain("preserved-owner-not-arbitrated"); records.append(record); continue }
                guard density >= p("minimumDensity", 0.8...1) else { retain("non-dense-byte-exact-bypass"); records.append(record); continue }
                guard let em = owner.fontPixels, em.isFinite, em > 0, em <= Double(max(w, h)) else {
                    retain("missing-original-pixel-em"); records.append(record); continue
                }
                guard let db = probability else { retain("missing-full-DB-abstention"); records.append(record); continue }
                if rgb == nil {
                    do { rgb = Array(try NativeRFDETRSourceImage.decode(original).rgb) }
                    catch { throw Stop(reason: "source-RGB-decode-\(String(reflecting: error))") }
                }
                let source = rgb!
                func color(_ i: Int) -> Color {
                    let k = global(i) * 3
                    return Color(r: Double(source[k]), g: Double(source[k + 1]), b: Double(source[k + 2]))
                }
                var hist = [Int](repeating: 0, count: 4096), sums = [[Double]](repeating: [0, 0, 0], count: 4096)
                for i in owned {
                    let c = color(i), key = Int(c.r) / 16 * 256 + Int(c.g) / 16 * 16 + Int(c.b) / 16
                    hist[key] += 1; sums[key][0] += c.r; sums[key][1] += c.g; sums[key][2] += c.b
                }
                // Fixed source-derived palette, not neighbor-to-neighbor chaining
                // across an arbitrary gradient. Unknown colors remain untouched.
                var palette: [Color] = []
                let keys = hist.indices.filter { hist[$0] >= max(16, owned.count / 100) }.sorted {
                    hist[$0] == hist[$1] ? $0 < $1 : hist[$0] > hist[$1]
                }
                for key in keys {
                    let c = Color(r: sums[key][0] / Double(hist[key]), g: sums[key][1] / Double(hist[key]), b: sums[key][2] / Double(hist[key]))
                    if palette.allSatisfy({ $0.gap(c) >= 48 }) { palette.append(c) }
                    if palette.count == 8 { break }
                }
                guard palette.count >= 2 else { retain("no-separated-source-palette"); records.append(record); continue }
                var colors = [Int16](repeating: -1, count: n), labels = [Int32](repeating: -1, count: n)
                var prob = [Float](repeating: 0, count: n)
                for i in owned {
                    let c = color(i)
                    var best = p("colorTolerance", 4...20) + 0.01, chosen = -1
                    for k in palette.indices {
                        let d = palette[k].gap(c)
                        if d < best { best = d; chosen = k }
                    }
                    colors[i] = Int16(chosen)
                    prob[i] = sample(db, x: x0 + i % rw, y: y0 + i / rw, width: w, height: h)
                }
                var components: [Component] = []
                for start in owned where colors[start] >= 0 && labels[start] < 0 {
                    guard components.count < 8192 else { throw Stop(reason: "source-component-budget-\(index)") }
                    let id = Int32(components.count), key = colors[start]
                    var queue = [start], cursor = 0, minX = rw, maxX = 0, minY = rh, maxY = 0
                    var boundary = false, strong = 0, totalP = 0.0
                    var sum = [Double](repeating: 0, count: 3), square = sum
                    labels[start] = id
                    while cursor < queue.count {
                        let i = queue[cursor], x = i % rw, y = i / rw; cursor += 1
                        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                        let c = color(i), values = [c.r, c.g, c.b]
                        for ch in 0..<3 { sum[ch] += values[ch]; square[ch] += values[ch] * values[ch] }
                        totalP += Double(prob[i])
                        if prob[i] >= Float(p("lineCoreThreshold", 0.35...0.85)) && input[global(i)] != 0 { strong += 1 }
                        for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                            let xx = x + dx, yy = y + dy
                            guard xx >= 0, yy >= 0, xx < rw, yy < rh else { boundary = true; continue }
                            let j = yy * rw + xx
                            if own[j] == 0 { boundary = true }
                            if colors[j] == key && labels[j] < 0 { labels[j] = id; queue.append(j) }
                        }
                    }
                    let count = Double(queue.count), mean = sum.map { $0 / count }
                    let deviation = (0..<3).map { sqrt(max(0, square[$0] / count - mean[$0] * mean[$0])) }.max()!
                    components.append(.init(pixels: queue, color: Int(key),
                        box: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1),
                        mean: .init(r: mean[0], g: mean[1], b: mean[2]), deviation: deviation,
                        boundary: boundary, strong: strong, dbMean: totalP / count))
                }
                func flatCell(_ c: Component) -> Bool {
                    let short = min(c.box.width, c.box.height), long = max(c.box.width, c.box.height)
                    return c.pixels.count >= max(64, Int(ceil(em * em * p("minimumCellAreaEm2", 0.005...0.15)))) &&
                        short >= max(6, em * 0.08) && long <= short * 3 &&
                        c.rectangularity >= p("minimumRectangularity", 0.65...0.98) &&
                        c.deviation <= p("maximumFlatDeviation", 1...6)
                }
                let boundaries = components.indices.filter {
                    let c = components[$0]
                    return c.boundary && flatCell(c) && c.strong == 0 && c.dbMean <= p("maximumBackingDBMean", 0.01...0.2)
                }
                let families = Set(boundaries.map { components[$0].color })
                let separated = families.contains { a in families.contains { b in a != b && palette[a].gap(palette[b]) >= 80 } }
                record["sourceComponents"] = components.count;
                record["sameColorBoundaryLineConnectionsHeldWhole"] = components.filter { $0.boundary && $0.strong > 0 }.count; record["boundaryBackingWitnesses"] = boundaries.count
                record["boundaryColorFamilies"] = families.count
                guard separated else { retain("no-two-color-boundary-backing-proof"); records.append(record); continue }
                var adjacentToSeed = Set<Int>()
                for c in components where c.strong > 0 {
                    for i in c.pixels {
                        let x = i % rw, y = i / rw
                        for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                            let xx = x + dx, yy = y + dy
                            if xx >= 0 && yy >= 0 && xx < rw && yy < rh && labels[yy * rw + xx] >= 0 {
                                adjacentToSeed.insert(Int(labels[yy * rw + xx]))
                            }
                        }
                    }
                }
                // Need at least one interior source component with actual line association and
                // contrasting source topology. A flat backing cell with a false DB
                // patch is not independently a glyph anchor.
                let anchors = components.indices.filter { k in
                    let c = components[k]
                    guard !c.boundary, c.strong >= 4, c.pixels.count >= 8,
                          max(c.box.width, c.box.height) <= em * 4, Double(c.pixels.count) <= em * em * 4 else { return false }
                    if !families.contains(c.color) || c.rectangularity < p("minimumRectangularity", 0.65...0.98) { return true }
                    return c.pixels.contains { i in
                        let x = i % rw, y = i / rw
                        for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                            let xx = x + dx, yy = y + dy
                            if xx >= 0 && yy >= 0 && xx < rw && yy < rh {
                                let j = Int(labels[yy * rw + xx])
                                if j >= 0 && !families.contains(components[j].color) { return true }
                            }
                        }
                        return false
                    }
                }
                record["independentSourceLineAssociations"] = anchors.count
                guard !anchors.isEmpty else { retain("no-independent-glyph-topology-abstention"); records.append(record); continue }
                var subtract = [UInt8](repeating: 0, count: n), accepted = 0, ambiguous = 0
                for k in components.indices {
                    let c = components[k]
                    guard families.contains(c.color), flatCell(c) else { continue }
                    let peers = boundaries.filter { components[$0].color == c.color }
                    let span = max(c.box.width, c.box.height)
                    let peer = peers.contains { witness in
                        let s = max(components[witness].box.width, components[witness].box.height)
                        return span >= s * 0.65 && span <= s * 1.5
                    }
                    guard c.boundary || peer else { continue }
                    // Whole same-color or directly touching fill/stroke connections
                    // are held intact across DB-zero extents, NOT cropped to a line core radius.
                    if c.strong > 0 || adjacentToSeed.contains(k) { ambiguous += 1; continue }
                    guard c.dbMean <= p("maximumBackingDBMean", 0.01...0.2) else { ambiguous += 1; continue }
                    accepted += 1
                    for i in c.pixels where c.mean.gap(color(i)) <= p("flatCoreTolerance", 1...12) { subtract[i] = 1 }
                }
                record["ambiguousBackingConnectionsHeldWhole"] = ambiguous
                record["flatBackingCells"] = accepted
                guard accepted >= 4 else { retain("insufficient-repeated-flat-backing-cells"); records.append(record); continue }
                let removed = masked.reduce(0) { $0 + Int(subtract[$1]) }
                guard removed >= 64 else { retain("insufficient-flat-core-subtraction"); records.append(record); continue }
                for i in masked { votes[global(i)] |= subtract[i] == 0 ? 2 : 1 }
                record["status"] = "flat-backing-component-proposal"; record["proposedRemovedPixels"] = removed
                record["wholeLineAssociatedSourceComponentsRetained"] = components.filter { $0.strong > 0 }.count
                records.append(record)
            }
            var output = input, changed = 0, vetoed = 0
            for i in input.indices where votes[i] & 1 != 0 {
                if votes[i] & 2 != 0 { vetoed += 1 } else { output[i] = 0; changed += 1 }
            }
            guard changed > 0 else { return unchanged("no-subtraction-after-component-and-overlap-veto", records) }
            guard let provider = CGDataProvider(data: Data(output) as CFData),
                  let result = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                    decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw Stop(reason: "output-allocation") }
            return .init(replacementMask: result, requiresRestoration: true,
                audit: ["status": "source-flat-backing-component-postfilter", "changedPixels": changed,
                    "inputOwners": ownerCount, "accountedOwners": ownerCount, "owners": records,
                    "overlapVetoPixels": vetoed, "roiPixelsVisited": work, "maskAdditions": 0,
                    "DBRadiusClipping": false, "DBInterpretation": "shrunk-line-core-not-glyph-mask",
                    "restoredPixelsRead": false, "qualityAccepted": false,
                    "postfilterSeconds": Date().timeIntervalSince(started)])
        } catch let stop as Stop { return unchanged(stop.reason, records) }
    }

    private static func gray(_ image: CGImage) throws -> [UInt8] {
        guard !image.isMask, image.bitsPerComponent == 8, image.bitsPerPixel == 8,
              image.colorSpace?.model == .monochrome, image.alphaInfo == .none else { throw Stop(reason: "invalid-binary-gray-format") }
        var a = [UInt8](repeating: 0, count: image.width * image.height)
        try a.withUnsafeMutableBytes { raw in
            guard let c = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { throw Stop(reason: "mask-allocation") }
            c.setBlendMode(.copy); c.interpolationQuality = .none
            c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        guard a.allSatisfy({ $0 == 0 || $0 == 255 }) else { throw Stop(reason: "nonbinary-mask") }
        return a
    }
    private static func raster(_ points: [CGPoint], box: CGRect, width: Int, height: Int) throws -> [UInt8] {
        var a = [UInt8](repeating: 0, count: width * height)
        try a.withUnsafeMutableBytes { raw in
            guard let c = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { throw Stop(reason: "owner-allocation") }
            c.setShouldAntialias(false); c.setFillColor(gray: 1, alpha: 1)
            c.translateBy(x: -box.minX, y: CGFloat(height) + box.minY); c.scaleBy(x: 1, y: -1)
            c.addLines(between: points); c.closePath(); c.fillPath()
        }
        return a
    }
    private static func sample(_ db: FullDB, x: Int, y: Int, width: Int, height: Int) -> Float {
        let sx = max(0, min(Double(db.width - 1), (Double(x) + 0.5) * Double(db.width) / Double(width) - 0.5))
        let sy = max(0, min(Double(db.height - 1), (Double(y) + 0.5) * Double(db.height) / Double(height) - 0.5))
        let x0 = Int(floor(sx)), y0 = Int(floor(sy)), x1 = min(db.width - 1, x0 + 1), y1 = min(db.height - 1, y0 + 1)
        let dx = sx - Double(x0), dy = sy - Double(y0)
        let a = Float(Double(db.values[y0 * db.width + x0]) * (1 - dx) + Double(db.values[y0 * db.width + x1]) * dx)
        let b = Float(Double(db.values[y1 * db.width + x0]) * (1 - dx) + Double(db.values[y1 * db.width + x1]) * dx)
        return Float(Double(a) * (1 - dy) + Double(b) * dy)
    }
}
