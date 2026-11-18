import CoreGraphics
import Foundation

/// Initial source-paper role model. Never corrects a sealed panel prediction.
/// Address-disjoint validation is not independent statistical or RGB ground truth.
enum NativeOwnerHostBackgroundPrediction {
    enum Quota: Error { case exhausted }
    static func predict(
        rgba: [UInt8], width: Int, height: Int, sourceROI: CGRect, owner: CGRect, peers: [CGRect],
        budget: NativeOwnerExteriorBGPrediction.Budget
    ) throws -> [String: Any] {
        // Contract: NativeSourcePixelReader.draw/read supplies packed unpremultiplied
        // sRGB RGBA8, row-major top-origin after BGRA swap and alpha unpremultiply.
        // Other provider bytes must not enter this helper without conversion.
        func finiteRect(_ r: CGRect, positive: Bool) -> Bool {
            !r.isNull && !r.isInfinite
                && [r.minX, r.minY, r.maxX, r.maxY, r.width, r.height].allSatisfy(\.isFinite)
                && (positive
                    ? r.size.width > 0 && r.size.height > 0 : r.size.width >= 0 && r.size.height >= 0)
        }
        guard width > 0, height > 0, width <= 4_194_304 / height,
            rgba.count == width * height * 4, finiteRect(sourceROI, positive: true),
            finiteRect(owner, positive: true),
            sourceROI.contains(owner), peers.count <= 64,
            peers.allSatisfy({ finiteRect($0, positive: false) })
        else {
            return ["accepted": false, "status": "invalid-geometry", "work": 0]
        }
        let margin = 16.0
        let expanded = owner.insetBy(dx: -margin, dy: -margin)
        guard finiteRect(expanded, positive: true) else {
            return ["accepted": false, "status": "invalid-geometry", "work": 0]
        }
        let roi = expanded.intersection(sourceROI)
        guard finiteRect(roi, positive: true) else {
            return ["accepted": false, "status": "invalid-geometry", "work": 0]
        }
        let aspectGrid = 1024 * (roi.width / roi.height)
        guard aspectGrid.isFinite, aspectGrid > 0 else {
            return ["accepted": false, "status": "invalid-geometry", "work": 0]
        }
        // Clamp in Double before conversion: extreme finite aspect must not trap Int.
        let w = max(1, Int(min(512, floor(sqrt(aspectGrid)))))
        let h = max(1, min(512, 1024 / w))
        var work = 0
        func charge(_ n: Int = 1) throws {
            guard n >= 0 else { throw Quota.exhausted }
            let (next, overflow) = work.addingReportingOverflow(n)
            guard !overflow, budget.charge(n) else { throw Quota.exhausted }
            work = next
        }
        try charge(13 + 4 * peers.count)
        struct Sample {
            let rgb: [Int]
            let address: Int
            let center: CGPoint
        }
        func pixel(_ p: CGPoint) throws -> Sample? {
            try charge()
            guard roi.contains(p) else { return nil }
            let x = Int((p.x - sourceROI.minX) / sourceROI.width * Double(width))
            let y = Int((p.y - sourceROI.minY) / sourceROI.height * Double(height))
            guard x >= 0, y >= 0, x < width, y < height else { return nil }
            let address = y * width + x
            let center = CGPoint(
                x: sourceROI.minX + (Double(x) + 0.5) * sourceROI.width / Double(width),
                y: sourceROI.minY + (Double(y) + 0.5) * sourceROI.height / Double(height))
            guard roi.contains(center) else { return nil }
            for peer in peers {
                try charge()
                if peer.contains(center) { return nil }
            }
            try charge()
            guard rgba[address * 4 + 3] >= 240 else { return nil }
            try charge(3)
            return Sample(
                rgb: (0..<3).map { Int(rgba[address * 4 + $0]) }, address: address, center: center)
        }
        func bin(_ rgb: [Int]) -> Int { (rgb[0] / 16) * 256 + (rgb[1] / 16) * 16 + rgb[2] / 16 }
        func held(_ address: Int) -> Bool { address % 3 == 2 }
        var bodyFold = [[Int: Int]](repeating: [:], count: 2)
        var outerFold = bodyFold
        var seen = Set<Int>()
        var bodyN = 0
        var outerN = 0
        var duplicates = 0
        for y in 0..<h {
            try Task.checkCancellation()
            for x in 0..<w {
                let p = CGPoint(
                    x: roi.minX + ((Double(x) + 0.5) / Double(w)) * roi.width,
                    y: roi.minY + ((Double(y) + 0.5) / Double(h)) * roi.height)
                if let s = try pixel(p) {
                    var samples = [s]
                    // A regular sparse grid can miss an entire physical address shard.
                    // Query a REAL adjacent captured pixel in the opposite shard, not a copy.
                    for delta in [-2, -1, 1, 2] {
                        let nx = s.address % width + delta
                        guard nx >= 0, nx < width else { continue }
                        let address = s.address / width * width + nx
                        guard held(address) != held(s.address) else { continue }
                        let center = CGPoint(
                            x: sourceROI.minX + (Double(nx) + 0.5) * sourceROI.width / Double(width),
                            y: s.center.y)
                        if let neighbor = try pixel(center) {
                            samples.append(neighbor)
                            break
                        }
                    }
                    for value in samples {
                        try charge()
                        guard seen.insert(value.address).inserted else {
                            duplicates += 1
                            continue
                        }
                        let fold = held(value.address) ? 1 : 0
                        if owner.contains(value.center) {
                            bodyFold[fold][bin(value.rgb), default: 0] += 1
                            bodyN += 1
                        } else {
                            outerFold[fold][bin(value.rgb), default: 0] += 1
                            outerN += 1
                        }
                    }
                }
            }
        }
        // Select the candidate mode from FIT only. Held source addresses never
        // select the endpoint or change the chosen mode.
        func dominant(_ histogram: [Int: Int]) throws -> Int? {
            try charge(histogram.count * max(1, Int(ceil(log2(Double(max(2, histogram.count)))))) * 4)
            let sorted = histogram.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            guard let first = sorted.first, first.value >= 12,
                first.value >= 3 * max(1, sorted.dropFirst().first?.value ?? 0)
            else { return nil }
            return first.key
        }
        let bodyMode = try dominant(bodyFold[0])
        let outerMode = try dominant(outerFold[0])
        guard let key = bodyMode, try dominant(bodyFold[1]) == key else {
            return [
                "accepted": false, "status": "spatial-mode-ambiguous", "work": work,
                "duplicateGridPoints": duplicates,
                "bodySamples": bodyN, "outerSamples": outerN, "additionalCapturePixels": 0,
                "fitBodyHistogram": bodyFold[0].map { ["key": $0.key, "count": $0.value] },
                "heldBodyHistogram": bodyFold[1].map { ["key": $0.key, "count": $0.value] },
            ]
        }
        let target = [key / 256 * 16 + 8, (key / 16) % 16 * 16 + 8, key % 16 * 16 + 8]
        struct Band {
            var samples: [Int: Sample] = [:]
            var rays = 0
            var matchingRays = 0
        }
        var bands = [Int: Band]()
        var collapsed = 0
        var ownedEndpoints = [Int: Sample]()
        for side in 0..<4 {
            let length = side < 2 ? owner.height : owner.width
            let n = Int(max(12, min(64, floor(length))))
            for i in 0..<n {
                if i.isMultiple(of: 8) { try Task.checkCancellation() }
                let f = (Double(i) + 0.5) / Double(n)
                let along = side < 2 ? owner.minY + f * owner.height : owner.minX + f * owner.width
                let p: [CGPoint]
                if side == 0 {
                    p = [
                        CGPoint(x: owner.minX + 2, y: along), CGPoint(x: owner.minX - 2, y: along),
                        CGPoint(x: owner.minX - 6, y: along),
                    ]
                } else if side == 1 {
                    p = [
                        CGPoint(x: owner.maxX - 2, y: along), CGPoint(x: owner.maxX + 2, y: along),
                        CGPoint(x: owner.maxX + 6, y: along),
                    ]
                } else if side == 2 {
                    p = [
                        CGPoint(x: along, y: owner.minY + 2), CGPoint(x: along, y: owner.minY - 2),
                        CGPoint(x: along, y: owner.minY - 6),
                    ]
                } else {
                    p = [
                        CGPoint(x: along, y: owner.maxY - 2), CGPoint(x: along, y: owner.maxY + 2),
                        CGPoint(x: along, y: owner.maxY + 6),
                    ]
                }
                let values = try p.compactMap(pixel)
                guard values.count == 3 else { continue }
                try charge(3)
                guard Set(values.map { $0.address }).count == 3 else {
                    collapsed += 1
                    continue
                }
                guard owner.contains(values[0].center), !owner.contains(values[1].center),
                    !owner.contains(values[2].center)
                else { continue }
                var band = bands[side * 8 + i / 8] ?? Band()
                band.rays += 1
                try charge(9)
                let match = values.allSatisfy { s in
                    (0..<3).allSatisfy { abs(s.rgb[$0] - target[$0]) <= 12 }
                }
                if match {
                    band.matchingRays += 1
                    ownedEndpoints[values[0].address] = values[0]
                }
                for s in values { band.samples[s.address] = s }
                bands[side * 8 + i / 8] = band
            }
        }
        var acceptedBands = [Int]()
        var acceptedAddresses = Set<Int>()
        var proof = [[String: Any]]()
        for k in bands.keys.sorted() {
            let b = bands[k]!
            var fit = 0
            var hold = 0
            var fitMatch = 0
            var holdMatch = 0
            for s in b.samples.values {
                try charge(3)
                let matches = (0..<3).allSatisfy { abs(s.rgb[$0] - target[$0]) <= 12 }
                if held(s.address) {
                    hold += 1
                    if matches { holdMatch += 1 }
                } else {
                    fit += 1
                    if matches { fitMatch += 1 }
                }
            }
            let disjoint = acceptedAddresses.isDisjoint(with: b.samples.keys)
            let accepted =
                b.rays >= 6 && b.matchingRays * 5 >= b.rays * 4 && fit >= 4 && hold >= 2
                && fitMatch * 5 >= fit * 4 && holdMatch * 5 >= hold * 4 && disjoint
            if accepted {
                acceptedBands.append(k)
                acceptedAddresses.formUnion(b.samples.keys)
            }
            proof.append([
                "band": k, "fit": fit, "held": hold, "fitMatching": fitMatch, "heldMatching": holdMatch,
                "rays": b.rays, "matchingRays": b.matchingRays, "disjoint": disjoint, "accepted": accepted,
            ])
        }
        let endpoints = ownedEndpoints.values.filter { !held($0.address) }
        try charge(endpoints.count * max(1, Int(ceil(log2(Double(max(2, endpoints.count)))))) * 3)
        let median =
            endpoints.count >= 12
            ? (0..<3).map { k in endpoints.map { $0.rgb[k] }.sorted()[endpoints.count / 2] } : nil
        let accepted = acceptedBands.count >= 2 && ownedEndpoints.count >= 24 && median != nil
        return [
            "accepted": accepted, "status": accepted ? "host-bridge-supported" : "bridge-insufficient",
            "selected": accepted ? median! as Any : NSNull(), "work": work, "additionalCapturePixels": 0,
            "duplicateGridPoints": duplicates, "collapsedRays": collapsed,
            "uniqueOwnedEndpoints": ownedEndpoints.count,
            "fitOwnedEndpoints": endpoints.count, "bodySamples": bodyN, "outerSamples": outerN,
            "mode": target,
            "acceptedBands": acceptedBands, "bands": proof, "capture": [width, height],
            "sampleGrid": [w, h],
            "fitHeldAddressOverlap": 0,
            "heldoutAuthority": "disjoint physical addresses; spatial correlation remains",
            "outerFitMode": outerMode as Any? ?? NSNull(),
            "authority": "source spatial model; RGBGT unknown",
        ]

    }
}
