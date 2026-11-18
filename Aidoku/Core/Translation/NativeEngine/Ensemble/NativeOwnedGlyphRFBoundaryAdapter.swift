import CoreGraphics
import Foundation

/// Optional bridge for the current mask builder, before final protection.
/// `source` must be its decoded NativeRFDETRSourceImage RGB/identity and all
/// other arguments must come from that same current page transaction. The
/// SourceProbability CGImage reference is checked, not rebound by dimensions.
/// Hard protection must be independently rasterized, never union-minus-balloon.
enum NativeOwnedGlyphRFBoundaryAdapter {
    typealias Caller = NativeMainRemovalSourceFactory.NativeCurrentMaskCaller
    private typealias Helper = NativeOwnedGlyphRFBoundaryProtection

    struct Result {
        let pageExemptions: Set<Int>
        let audit: [String: Any]
    }
    enum Failure: Error { case invalidPageEvidence }

    static func evaluate(source: Caller.Source, owners: [Caller.Owner], factoryMask: [UInt8],
                         factoryAudit: [String: Any], records: [[String: Any]],
                         rfRegions: [Ensemble100RFRegion], original: CGImage,
                         probability: NativeMainAOTRemovalMaskBuilder.SourceProbability?,
                         hardProtection: [UInt8], balloonBoundary: [UInt8],
                         enabled: Bool = NativeOwnedGlyphRFBoundaryProtection.runtimeEnabled) throws -> Result {
        var exemptions = Set<Int>(), observations = [[String: Any]](), work = 0
        func finish(_ status: String) -> Result {
            Result(pageExemptions: exemptions, audit: ["enabled": enabled, "status": status,
                "exemptedBalloonBoundaryPixels": exemptions.count, "owners": observations,
                "roiWorkPixels": work, "factoryOnly": true, "hardProtectionRetained": true,
                "bboxFill": false, "sourceIdentity": source.revision])
        }
        guard enabled else { return finish("disabled") }
        try Task.checkCancellation()
        let w = source.width, h = source.height
        guard w > 0, h > 0, w <= 16_777_216 / h,
              original.width == w, original.height == h, !source.revision.isEmpty,
              source.rgb.count == w * h * 3, factoryMask.count == w * h,
              hardProtection.count == w * h, balloonBoundary.count == w * h,
              owners.count <= 256, records.count == owners.count, rfRegions.count <= 4096,
              Set(owners.map(\.id)).count == owners.count else { throw Failure.invalidPageEvidence }
        guard let probability else { return finish("missing-probability-retained-base") }
        guard probability.original === original, probability.width > 0, probability.height > 0,
              probability.width <= w, probability.height <= h,
              probability.values.count == probability.width * probability.height,
              probability.values.allSatisfy({ $0.isFinite && (0...1).contains($0) })
        else { return finish("invalid-or-stale-probability-retained-base") }
        let base = factoryAudit["base"] as? [[String: Any]] ?? []
        let chroma = factoryAudit["chroma"] as? [[String: Any]] ?? []
        let canvas = CGRect(x: 0, y: 0, width: w, height: h)
        let measuredAuthorities: Set<String> = ["explicit-original-pixel-source-measurement",
            "sourceFontSize*originalWidth/sourceFrameWidth"]
        for (index, owner) in owners.enumerated() where owner.translated {
            try Task.checkCancellation()
            func skip(_ status: String) { observations.append(["owner": owner.id, "status": status]) }
            let palettes = base.filter { $0["owner"] as? String == owner.id }
            guard records[index]["index"] as? Int == index,
                  let authority = records[index]["fontAuthority"] as? String,
                  measuredAuthorities.contains(authority), owner.fontPixels.isFinite,
                  (2...512).contains(owner.fontPixels),
                  !owner.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  palettes.count == 1, let bg = palettes[0]["backgroundRGB"] as? [Double],
                  bg.count == 3, bg.allSatisfy({ $0.isFinite && (0...255).contains($0) }),
                  (3...16).contains(owner.polygon.count),
                  owner.polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite &&
                      $0.x >= 0 && $0.y >= 0 && $0.x <= CGFloat(w - 1) && $0.y <= CGFloat(h - 1) }),
                  Caller.convex(owner.polygon)
            else { skip("invalid-or-unmeasured-owner-retained-base"); continue }
            let xs = owner.polygon.map(\.x), ys = owner.polygon.map(\.y)
            let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            guard box.width > 0, box.height > 0 else { skip("empty-owner"); continue }
            // Ensemble100RFRegion uses text0/SFX1/balloon2/frame3. Do NOT use
            // NativeRFDETRLayoutClass.canonicalClassID (text1) on this contract.
            let nominations = rfRegions.filter { region in
                let b = region.bounds
                guard region.classID == 0, region.confidence.isFinite, region.confidence >= 0.55,
                      [b.minX, b.minY, b.width, b.height].allSatisfy(\.isFinite),
                      b.width > 0, b.height > 0, b.minX >= 0, b.minY >= 0,
                      b.maxX <= 1, b.maxY <= 1 else { return false }
                let r = CGRect(x: b.minX * CGFloat(w), y: b.minY * CGFloat(h),
                    width: b.width * CGFloat(w), height: b.height * CGFloat(h))
                let overlap = box.intersection(r)
                return !overlap.isNull && overlap.width * overlap.height >= box.width * box.height * 0.35
            }
            // Even two same-query rectangles are ambiguous; never use a first
            // row or a union to quietly enlarge the RF nomination domain.
            guard nominations.count == 1, let selected = nominations.first else {
                skip("missing-or-ambiguous-RF-text-support"); continue
            }
            let pad = ceil(owner.fontPixels * 0.6) + 4
            let roi = box.insetBy(dx: -pad, dy: -pad).integral.intersection(canvas)
            let x0 = Int(roi.minX), y0 = Int(roi.minY), cw = Int(roi.width), ch = Int(roi.height)
            let count = cw * ch
            guard count > 0, count <= 1_000_000, work <= 12_000_000 - count else {
                skip("optional-ROI-work-budget-retained-base"); continue
            }
            work += count
            guard NativeOriginalMaskFringeCompletion.isOpaque(original: original, roi: roi) else {
                skip("source-ROI-opacity-unverified-retained-base"); continue
            }
            let localPolygon = owner.polygon.map { CGPoint(x: $0.x - CGFloat(x0), y: $0.y - CGFloat(y0)) }
            let owned = Caller.raster(localPolygon, width: cw, height: ch)
            let b = selected.bounds
            // Clip the nomination to the ROI BEFORE Caller.raster; its lattice
            // conversion expects finite bounded coordinates. This clips only
            // nomination, never the original RGB connected components.
            let textBox = CGRect(x: b.minX * CGFloat(w), y: b.minY * CGFloat(h),
                width: b.width * CGFloat(w), height: b.height * CGFloat(h)).intersection(roi)
            let support = Caller.raster([
                CGPoint(x: textBox.minX - CGFloat(x0), y: textBox.minY - CGFloat(y0)),
                CGPoint(x: textBox.maxX - CGFloat(x0), y: textBox.minY - CGFloat(y0)),
                CGPoint(x: textBox.maxX - CGFloat(x0), y: textBox.maxY - CGFloat(y0)),
                CGPoint(x: textBox.minX - CGFloat(x0), y: textBox.maxY - CGFloat(y0))], width: cw, height: ch)
            var rgb = [UInt8](), factory = [UInt8](), hard = [UInt8](), balloon = [UInt8](), db = [Float]()
            rgb.reserveCapacity(count * 3)
            factory.reserveCapacity(count); hard.reserveCapacity(count)
            balloon.reserveCapacity(count); db.reserveCapacity(count)
            for y in 0..<ch {
                if y % 64 == 0 { try Task.checkCancellation() }
                for x in 0..<cw {
                    let global = (y0 + y) * w + x0 + x
                    rgb.append(contentsOf: source.rgb[global * 3..<global * 3 + 3])
                    factory.append(factoryMask[global]); hard.append(hardProtection[global])
                    balloon.append(balloonBoundary[global])
                    db.append(sampleProbability(probability, sourceX: x0 + x, sourceY: y0 + y, width: w, height: h))
                }
            }
            let inks = chroma.filter { $0["owner"] as? String == owner.id }
            let ink = inks.count == 1 ? inks[0]["ink"] as? [Double] : nil
            let result: Helper.Result
            do {
                result = try Helper.evaluate(.init(width: cw, height: ch, rgb: rgb, owned: owned,
                    factoryMask: factory, hardProtection: hard, balloonBoundary: balloon,
                    probability: db, textSupport: support, background: bg, fontPixels: owner.fontPixels,
                    sourceRevision: source.revision, probabilitySourceRevision: source.revision,
                    ownerSourceRevision: source.revision, factorySourceRevision: source.revision,
                    rfSourceRevision: source.revision, ownerID: owner.id, factoryOwnerID: owner.id,
                    textSupportOwnerID: owner.id, originalOpaque: true, chromaticInk: ink,
                    probabilityCellArea: Double(w * h) / Double(probability.values.count)))
            } catch is Helper.Failure {
                skip("invalid-helper-evidence-retained-base"); continue
            }
            let pageIndices = result.boundaryExemptions.map { (y0 + $0 / cw) * w + x0 + $0 % cw }
            let newCount = pageIndices.reduce(0) { $0 + (exemptions.contains($1) ? 0 : 1) }
            guard exemptions.count <= 131_072 - newCount else { skip("page-exemption-budget"); continue }
            for k in pageIndices where hardProtection[k] == 0 && factoryMask[k] != 0 && balloonBoundary[k] != 0 {
                exemptions.insert(k)
            }
            observations.append(["owner": owner.id, "status": "evaluated", "rfTextQuery": selected.queryID,
                "roi": [x0, y0, cw, ch], "acceptedComponents": result.acceptedComponents,
                "boundaryExemptions": result.boundaryExemptions.count, "hardVetoComponents": result.hardVetoComponents,
                "rejections": result.rejectionCounts, "DBRejectedComponentCounts": result.dbRejectedComponentCounts])
        }
        return finish("evaluated")
    }

    /// Same half-pixel, clamped, bilinear mapping as the current factory caller.
    /// Call only after validating the source and probability dimensions/counts.
    static func sampleProbability(_ probability: NativeMainAOTRemovalMaskBuilder.SourceProbability,
                                  sourceX: Int, sourceY: Int, width: Int, height: Int) -> Float {
        let sx = max(0, min(Double(probability.width - 1),
            (Double(sourceX) + 0.5) * Double(probability.width) / Double(width) - 0.5))
        let sy = max(0, min(Double(probability.height - 1),
            (Double(sourceY) + 0.5) * Double(probability.height) / Double(height) - 0.5))
        let ax = Int(floor(sx)), bx = min(probability.width - 1, ax + 1), tx = sx - Double(ax)
        let ay = Int(floor(sy)), by = min(probability.height - 1, ay + 1), ty = sy - Double(ay)
        func row(_ y: Int) -> Float {
            Float(Double(probability.values[y * probability.width + ax]) * (1 - tx) +
                Double(probability.values[y * probability.width + bx]) * tx)
        }
        return Float(Double(row(ay)) * (1 - ty) + Double(row(by)) * ty)
    }
}
