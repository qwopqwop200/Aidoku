import CoreGraphics
import Foundation

/// Subtractive experiment AFTER final source-mask union/protection, BEFORE AOT.
/// Only dense/low-specificity owners are arbitrated; sparse cleanup is byte-exact.
enum NativeEnsembleRemovalDenseSupport {
    static let defaults: [String: Double] = [
        "enabled": 1, "denseFraction": 0.72, "minimumDensity": 0.55,
        "requireSeparatedModes": 0, "ridgeProbability": 0.55, "reachEm": 0.12,
        "supportProbability": 0.12, "lowDBFraction": 0.35, "modeFraction": 0.10,
        "maxTrimFraction": 0.92, "maxPixels": 16_777_216, "maxROIPixels": 1_000_000,
        "maxWorkPixels": 12_000_000
    ]

    /// Original-image NORMALIZED top-left polygon and ORIGINAL-pixel measured em.
    /// A preserved/non-target owner participates in overlap veto, not arbitration.
    struct Owner {
        let polygon: [CGPoint]
        let fontPixels: Double?
        let preserved: Bool
    }
    struct Ownership {
        let original: CGImage // strong same-object binding; not an ID/string claim
        let owners: [Owner] // prejoin ownership inventory, not merged display boxes
    }
    typealias FullDB = NativeMainAOTRemovalMaskBuilder.SourceProbability
    struct Result {
        let replacementMask: CGImage?
        let requiresRestoration: Bool
        let audit: [String: Any]
    }
    private struct Stop: Error { let reason: String }

    /// No additions, no RF/body input, no text mutation, no restored image reads.
    /// Caller validates DB provenance/canvas mapping; ROI upper bounds are NOT DB.
    static func apply(original: CGImage, mask: CGImage, ownership: Ownership, probability: FullDB?,
                      parameters: [String: Double] = [:]) throws -> Result {
        let started = Date()
        func p(_ key: String, _ range: ClosedRange<Double>) -> Double {
            let value = parameters[key] ?? defaults[key]!
            return value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : defaults[key]!
        }
        let count = ownership.owners.count
        func abstain(_ reason: String, records: [[String: Any]] = []) -> Result {
            let evaluated = Set(records.compactMap { $0["index"] as? Int })
            let inventory = records + (0..<count).filter { !evaluated.contains($0) }.map {
                ["index": $0, "status": "not-evaluated-\(reason)"] as [String: Any]
            }
            return .init(replacementMask: nil, requiresRestoration: false,
                audit: ["status": "unchanged", "reason": reason, "inputOwners": count,
                    "accountedOwners": count, "evaluatedOwners": records.count, "owners": inventory, "changedPixels": 0,
                    "restoredPixelsRead": false, "qualityAccepted": false,
                    "postfilterSeconds": Date().timeIntervalSince(started)])
        }
        guard p("enabled", 0...1) > 0 else { return abstain("disabled") }
        guard ownership.original === original else { return abstain("ownership-source-identity-mismatch") }
        let w = original.width, h = original.height
        guard w > 0, h > 0, w <= Int(p("maxPixels", 1...16_777_216)) / h,
              count <= 256, mask.width == w, mask.height == h else {
            return abstain("source-mask-dimensions-or-budget")
        }
        // Incomplete ownership could hide another paragraph: abort the WHOLE filter.
        guard ownership.owners.allSatisfy({ owner in
            (3...1024).contains(owner.polygon.count) && owner.polygon.allSatisfy {
                    $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y)
                }
        }) else { return abstain("invalid-owner-geometry-or-source-em") }
        if let db = probability {
            guard db.original === original else { return abstain("probability-source-identity-mismatch") }
            guard db.width > 0, db.height > 0, db.width <= w, db.height <= h,
                  db.values.count == db.width * db.height,
                  db.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                return abstain("invalid-full-DB-grid-not-ROI-upper-bounds")
            }
        }
        var records: [[String: Any]] = [], work = 0, filtered = 0
        do {
            let input = try gray(mask)
            // bit1: subtract proposal; bit2: any other owner retains original support.
            // Owner order cannot change the result; uncertain overlaps never subtract.
            var votes = [UInt8](repeating: 0, count: w * h), rgb: [UInt8]?
            for (index, owner) in ownership.owners.enumerated() {
                try Task.checkCancellation()
                let points = owner.polygon.map { CGPoint(x: $0.x * CGFloat(w), y: $0.y * CGFloat(h)) }
                let box = CGRect(x: points.map(\.x).min()!, y: points.map(\.y).min()!,
                    width: points.map(\.x).max()! - points.map(\.x).min()!,
                    height: points.map(\.y).max()! - points.map(\.y).min()!).integral
                    .intersection(CGRect(x: 0, y: 0, width: w, height: h))
                guard !box.isNull, !box.isEmpty, !box.isInfinite else { throw Stop(reason: "degenerate-owner-\(index)") }
                let x0 = Int(box.minX), y0 = Int(box.minY), rw = Int(box.width), rh = Int(box.height), n = rw * rh
                guard n > 0 else { throw Stop(reason: "degenerate-owner-\(index)") }
                guard n <= Int(p("maxROIPixels", 64...4_000_000)),
                      work <= Int(p("maxWorkPixels", 64...32_000_000)) - n else {
                    throw Stop(reason: "owner-or-cumulative-work-budget-\(index)")
                }
                work += n
                let owned = try raster(points, box: box, width: rw, height: rh)
                var pixels: [Int] = [], ownedCount = 0
                for i in 0..<n where owned[i] != 0 {
                    ownedCount += 1
                    if input[(y0 + i / rw) * w + x0 + i % rw] != 0 { pixels.append(i) }
                }
                guard ownedCount > 0 else { throw Stop(reason: "empty-owner-raster-\(index)") }
                let density = Double(pixels.count) / Double(ownedCount)
                var record: [String: Any] = ["index": index, "ownedPixels": ownedCount,
                    "maskedPixels": pixels.count, "density": density]
                func retain(_ reason: String) {
                    for i in pixels { votes[(y0 + i / rw) * w + x0 + i % rw] |= 2 }
                    record["status"] = reason
                }
                guard !owner.preserved else {
                    retain("preserved-owner-not-arbitrated"); records.append(record); continue
                }
                // Even strongly bimodal black/white or colored sparse text is bypassed.
                guard density >= p("minimumDensity", 0.55...1) else {
                    retain("sparse-byte-exact-bypass"); records.append(record); continue
                }
                guard let em = owner.fontPixels, em.isFinite, em > 0, em <= Double(max(w, h)) else {
                    retain("missing-original-pixel-em-abstention"); records.append(record); continue
                }
                record["sourceEmPixels"] = em
                guard let db = probability else {
                    retain("missing-full-DB-explicit-abstention"); records.append(record); continue
                }
                if rgb == nil {
                    do { rgb = Array(try NativeRFDETRSourceImage.decode(original).rgb) }
                    catch { throw Stop(reason: "source-RGB-decode-\(String(reflecting: error))") }
                }
                let source = rgb!
                var hist = [Int](repeating: 0, count: 4096), low = 0
                var prob = [Float](repeating: 0, count: n)
                for i in 0..<n where owned[i] != 0 {
                    let x = x0 + i % rw, y = y0 + i / rw, k = (y * w + x) * 3
                    let key = Int(source[k] / 16) * 256 + Int(source[k + 1] / 16) * 16 + Int(source[k + 2] / 16)
                    hist[key] += 1
                    prob[i] = sample(db, x: x, y: y, width: w, height: h)
                }
                for i in pixels where prob[i] < Float(p("supportProbability", 0.02...0.3)) { low += 1 }
                let first = hist.indices.max(by: { hist[$0] < hist[$1] })!
                func separated(_ key: Int) -> Bool {
                    max(abs(key / 256 - first / 256), max(abs(key / 16 % 16 - first / 16 % 16), abs(key % 16 - first % 16))) >= 4
                }
                let second = hist.indices.filter(separated).map { hist[$0] }.max() ?? 0
                let modal = Double(min(hist[first], second)) / Double(ownedCount) >= p("modeFraction", 0.05...0.25)
                let lowFraction = Double(low) / Double(max(1, pixels.count))
                record["twoSeparatedSourceModes"] = modal
                record["dominantModeFraction"] = Double(hist[first]) / Double(ownedCount)
                record["separatedModeFraction"] = Double(second) / Double(ownedCount)
                record["maskedLowDBFraction"] = lowFraction
                let suspicious = (p("requireSeparatedModes", 0...1) == 0 || modal) &&
                    (density >= p("denseFraction", 0.6...0.95) || modal) &&
                    lowFraction >= p("lowDBFraction", 0.15...0.8)
                guard suspicious else {
                    retain("no-dense-low-specificity-evidence"); records.append(record); continue
                }
                var ridge = [UInt8](repeating: 0, count: n), edge = [UInt8](repeating: 0, count: n)
                for i in pixels where prob[i] >= Float(p("ridgeProbability", 0.35...0.85)) {
                    ridge[i] = 1
                    let x = x0 + i % rw, y = y0 + i / rw, k = (y * w + x) * 3
                    for (dx, dy) in [(-2, 0), (2, 0), (0, -2), (0, 2)] {
                        let xx = x + dx, yy = y + dy
                        guard xx >= 0, yy >= 0, xx < w, yy < h else { continue }
                        let q = (yy * w + xx) * 3
                        if (0..<3).contains(where: { abs(Int(source[k + $0]) - Int(source[q + $0])) >= 24 }) { edge[i] = 1 }
                    }
                }
                // DB is not glyph truth: reject large/fill-box ridges and require
                // actual RGB edge support within each independently connected ridge.
                var seen = [UInt8](repeating: 0, count: n), distance = [Int16](repeating: -1, count: n)
                var queue: [Int] = [], accepted = 0, checked = 0
                for start in pixels where ridge[start] != 0 && seen[start] == 0 {
                    checked += 1
                    guard checked <= 8192 else { throw Stop(reason: "ridge-component-work-budget-\(index)") }
                    var component = [start], cursor = 0, edges = 0, minX = rw, minY = rh, maxX = 0, maxY = 0
                    seen[start] = 1
                    while cursor < component.count {
                        let i = component[cursor], x = i % rw, y = i / rw; cursor += 1
                        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                        edges += Int(edge[i])
                        for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                            let xx = x + dx, yy = y + dy
                            guard xx >= 0, yy >= 0, xx < rw, yy < rh else { continue }
                            let j = yy * rw + xx
                            if ridge[j] != 0 && seen[j] == 0 { seen[j] = 1; component.append(j) }
                        }
                    }
                    let bw = maxX - minX + 1, bh = maxY - minY + 1, size = component.count
                    guard size >= 3, edges >= 3, Double(edges) / Double(size) >= 0.05,
                          Double(max(bw, bh)) <= em * 4,
                          Double(size) <= em * em * 4,
                          !(size * 10 > bw * bh * 9 && min(bw, bh) >= 6) else { continue }
                    accepted += 1
                    for i in component { distance[i] = 0; queue.append(i) }
                }
                record["sourceEdgeSupportedRidgeComponents"] = accepted
                record["sourceEdgeSupportedRidgePixels"] = queue.count
                guard queue.count >= 12 else {
                    retain("no-trustworthy-source-and-DB-ridge-abstention"); records.append(record); continue
                }
                let reach = max(2, min(24, Int(ceil(em * p("reachEm", 0.03...0.25)))))
                let weak = Float(p("supportProbability", 0.02...0.3))
                var cursor = 0
                while cursor < queue.count {
                    let i = queue[cursor], x = i % rw, y = i / rw; cursor += 1
                    guard distance[i] < reach else { continue }
                    for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                        let xx = x + dx, yy = y + dy
                        guard xx >= 0, yy >= 0, xx < rw, yy < rh else { continue }
                        let j = yy * rw + xx
                        if distance[j] < 0 && owned[j] != 0 && prob[j] >= weak &&
                            input[(y0 + yy) * w + x0 + xx] != 0 {
                            distance[j] = distance[i] + 1; queue.append(j)
                        }
                    } }
                }
                // Two-source-pixel reconstruction/AA margin around supported glyphs,
                // bounded to original mask+ownership. Never grows the input erasure.
                var keep = [UInt8](repeating: 0, count: n)
                for i in queue {
                    let x = i % rw, y = i / rw
                    for dy in -2...2 { for dx in -2...2 where dx * dx + dy * dy <= 4 {
                        let xx = x + dx, yy = y + dy
                        if xx >= 0 && yy >= 0 && xx < rw && yy < rh { keep[yy * rw + xx] = 1 }
                    } }
                }
                let removed = pixels.reduce(0) { $0 + (keep[$1] == 0 ? 1 : 0) }
                let fraction = Double(removed) / Double(max(1, pixels.count))
                record["proposedRemovedPixels"] = removed; record["proposedRemovedFraction"] = fraction
                guard removed > 0, fraction <= p("maxTrimFraction", 0.5...0.98) else {
                    retain("empty-or-overwhelming-subtraction-abstention"); records.append(record); continue
                }
                for i in pixels { votes[(y0 + i / rw) * w + x0 + i % rw] |= keep[i] == 0 ? 1 : 2 }
                filtered += 1; record["status"] = "dense-source-DB-arbitration-proposal"; records.append(record)
            }
            var output = input, changed = 0, overlapVeto = 0
            for i in input.indices where votes[i] & 1 != 0 {
                if votes[i] & 2 != 0 { overlapVeto += 1 }
                else { output[i] = 0; changed += 1 }
            }
            guard changed > 0 else { return abstain("no-subtraction-after-overlap-veto", records: records) }
            guard let provider = CGDataProvider(data: Data(output) as CFData),
                  let result = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                    decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw Stop(reason: "output-allocation") }
            return Result(replacementMask: result, requiresRestoration: true,
                audit: ["status": "dense-source-support-postfilter", "inputOwners": count, "accountedOwners": count,
                    "owners": records, "filteredOwners": filtered, "changedPixels": changed,
                    "overlapVetoPixels": overlapVeto, "roiPixelsVisited": work, "restoredPixelsRead": false,
                    "sourceRGBPixelsDecoded": rgb == nil ? 0 : w * h,
                    "postfilterSeconds": Date().timeIntervalSince(started),
                    "maskAdditions": 0, "requiresFreshAOT": true, "qualityAccepted": false])
        } catch let stop as Stop { return abstain(stop.reason, records: records) }
    }

    private static func gray(_ image: CGImage) throws -> [UInt8] {
        guard !image.isMask, image.bitsPerComponent == 8, image.bitsPerPixel == 8,
              image.colorSpace?.model == .monochrome, image.alphaInfo == .none else { throw Stop(reason: "invalid-binary-gray-format") }
        var bytes = [UInt8](repeating: 0, count: image.width * image.height)
        try bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)
            else { throw Stop(reason: "mask-allocation") }
            context.setBlendMode(.copy); context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        guard bytes.allSatisfy({ $0 == 0 || $0 == 255 }) else { throw Stop(reason: "nonbinary-mask") }
        return bytes
    }

    private static func raster(_ points: [CGPoint], box: CGRect, width: Int, height: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height)
        try bytes.withUnsafeMutableBytes { raw in
            guard let c = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { throw Stop(reason: "ownership-allocation") }
            c.setShouldAntialias(false); c.setFillColor(gray: 1, alpha: 1)
            c.translateBy(x: -box.minX, y: CGFloat(height) + box.minY); c.scaleBy(x: 1, y: -1)
            c.addLines(between: points); c.closePath(); c.fillPath()
        }
        return bytes
    }

    /// Same source-center, edge-clamped bilinear reconstruction as the frozen
    /// caller: Float horizontal rounding precedes the vertical interpolation.
    private static func sample(_ db: FullDB, x: Int, y: Int, width: Int, height: Int) -> Float {
        let sx = max(0, min(Double(db.width - 1), (Double(x) + 0.5) * Double(db.width) / Double(width) - 0.5))
        let sy = max(0, min(Double(db.height - 1), (Double(y) + 0.5) * Double(db.height) / Double(height) - 0.5))
        let x0 = Int(floor(sx)), y0 = Int(floor(sy)), x1 = min(db.width - 1, x0 + 1), y1 = min(db.height - 1, y0 + 1)
        let dx = sx - Double(x0), dy = sy - Double(y0)
        let top = Float(Double(db.values[y0 * db.width + x0]) * (1 - dx) + Double(db.values[y0 * db.width + x1]) * dx)
        let bottom = Float(Double(db.values[y1 * db.width + x0]) * (1 - dx) + Double(db.values[y1 * db.width + x1]) * dx)
        return Float(Double(top) * (1 - dy) + Double(bottom) * dy)
    }
}
