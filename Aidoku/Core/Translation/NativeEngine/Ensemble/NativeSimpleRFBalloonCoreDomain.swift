import CoreGraphics
import Foundation

/// Source-seeded RAW RF placement/protection domains. Model estimates only;
/// never original RGB/native contour, erasure, OCR ownership or paragraph merge.
enum NativeSimpleRFBalloonCoreDomain {
    struct Configuration: Sendable {
        let raw: NativeRFDETRBalloonDomainPolicy
        let coreRadius: Int
        var cacheIdentity: String { raw.cacheIdentity + ":native162-core-v1:r\(coreRadius):four-connected-L1-nearest-positive-bilinear-cell" }
        static func configured() throws -> Self? {
            guard let raw = try NativeRFDETRBalloonDomainPolicy.configured() else { return nil }
            let value = ProcessInfo.processInfo.environment["AIDOKU_SIMPLE_RF_BALLOON_CORE_RADIUS"] ?? "0"
            guard let radius = Int(value), (0...3).contains(radius) else {
                throw NativeRFDETRLayoutError.unsupportedModelContract("invalid balloon core radius")
            }
            return Self(raw: raw, coreRadius: radius)
        }
    }
    struct PreparedQuery: Sendable {
        let queryID: Int
        let queryLogit: Float
        let maskLogit: Float
        let mask: NativeRFDETRLayoutMask
        let labels: [Int32]

        /// Exact same source bilinear decision as RF, then fixed topology label
        /// from the strongest-weight positive native neighbour. No bbox clip.
        func territory(sourceX: Int, sourceY: Int) -> Int32? {
            guard mask.contains(sourceX: sourceX, sourceY: sourceY, decisionLogitThreshold: maskLogit) else { return nil }
            let side = NativeRFDETRLayoutResource.maskSide
            let x = max(0, (Float(sourceX) + 0.5) * Float(side) / Float(mask.sourceWidth) - 0.5)
            let y = max(0, (Float(sourceY) + 0.5) * Float(side) / Float(mask.sourceHeight) - 0.5)
            let x0 = min(side-1, Int(x)), y0 = min(side-1, Int(y))
            let x1 = min(side-1, x0+1), y1 = min(side-1, y0+1)
            let dx = x-Float(x0), dy = y-Float(y0)
            let cells = [y0*side+x0, y0*side+x1, y1*side+x0, y1*side+x1]
            let weights = [(1-dy)*(1-dx), (1-dy)*dx, dy*(1-dx), dy*dx]
            var bestWeight: Float = -1, winner: Int32?
            for i in 0..<4 where mask.logits[cells[i]] > maskLogit && weights[i] > bestWeight {
                bestWeight = weights[i]; winner = labels[cells[i]]
            }
            guard let winner, winner > 0 else { return nil }
            return winner
        }
    }
    struct Assignment: Sendable {
        let sourceIdentity: String
        let policyIdentity: String
        let sourceOwnerBounds: CGRect
        let positiveOwnerPixelCentres: Int
        let ownerPixelCentres: Int
        let territoryID: Int32
        let query: PreparedQuery
        var queryID: Int { query.queryID }
        var modelEstimated: Bool { true }
        var nativeVerified: Bool { false }
        func contains(sourceRect rect: CGRect, sourceIdentity expected: String) -> Bool {
            guard expected == sourceIdentity, !rect.isEmpty, !rect.isNull, !rect.isInfinite,
                  [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy(\.isFinite),
                  rect.minX >= 0, rect.minY >= 0, rect.maxX <= CGFloat(query.mask.sourceWidth),
                  rect.maxY <= CGFloat(query.mask.sourceHeight) else { return false }
            let left = Int(floor(rect.minX)), right = Int(ceil(rect.maxX))
            let top = Int(floor(rect.minY)), bottom = Int(ceil(rect.maxY))
            guard left < right, top < bottom else { return false }
            for y in top..<bottom {
                for x in left..<right where query.territory(sourceX: x, sourceY: y) != territoryID { return false }
            }
            return true
        }
    }

    static func partition(foreground: [Bool], side: Int, coreRadius radius: Int) throws -> [Int32] {
        guard side > 0, side <= 1024, foreground.count == side*side, (0...3).contains(radius) else {
            throw NativeRFDETRLayoutError.unsupportedModelContract("invalid native core topology")
        }
        func neighbours(_ i: Int) -> [Int] {
            let x = i % side, y = i / side
            var result: [Int] = []
            if y > 0 { result.append(i-side) }
            if x > 0 { result.append(i-1) }
            if x+1 < side { result.append(i+1) }
            if y+1 < side { result.append(i+side) }
            return result
        }
        func connected(_ binary: [Bool]) -> ([Int32], Int) {
            var labels = [Int32](repeating: 0, count: binary.count), number = 0
            for seed in binary.indices where binary[seed] && labels[seed] == 0 {
                number += 1; labels[seed] = Int32(number)
                var queue = [seed], head = 0
                while head < queue.count {
                    let current = queue[head]; head += 1
                    for next in neighbours(current) where binary[next] && labels[next] == 0 {
                        labels[next] = Int32(number); queue.append(next)
                    }
                }
            }
            return (labels, number)
        }
        let (components, number) = connected(foreground)
        if radius == 0 || number == 0 { return components }
        let stride = side+2, infinity = side*2+8
        var distance = [Int](repeating: 0, count: stride*stride)
        for y in 0..<side { for x in 0..<side where foreground[y*side+x] { distance[(y+1)*stride+x+1] = infinity } }
        for y in 1...side { for x in 1...side {
            let i = y*stride+x
            distance[i] = min(distance[i], min(distance[i-1]+1, distance[i-stride]+1))
        } }
        for y in (1...side).reversed() { for x in (1...side).reversed() {
            let i = y*stride+x
            distance[i] = min(distance[i], min(distance[i+1]+1, distance[i+stride]+1))
        } }
        var cores = [Bool](repeating: false, count: foreground.count), surviving = [Bool](repeating: false, count: number+1)
        for i in foreground.indices where foreground[i] {
            cores[i] = distance[(i/side+1)*stride+i%side+1] > radius
            if cores[i] { surviving[Int(components[i])] = true }
        }
        for i in foreground.indices where foreground[i] && !surviving[Int(components[i])] { cores[i] = true }
        let (coreLabels, count) = connected(cores)
        var labels = coreLabels, seeds = [[Int]](repeating: [], count: count+1)
        for i in labels.indices where labels[i] > 0 { seeds[Int(labels[i])].append(i) }
        var queue: [Int] = [], head = 0
        for label in 1...count { queue.append(contentsOf: seeds[label]) }
        while head < queue.count {
            let current = queue[head]; head += 1
            for next in neighbours(current) where foreground[next] && labels[next] == 0 {
                labels[next] = labels[current]; queue.append(next)
            }
        }
        return labels
    }

    static func prepare(result: NativeRFDETRLayoutResult, configuration: Configuration) throws -> [PreparedQuery] {
        let primitives = try configuration.raw.balloons(result)
        let logits = Dictionary(uniqueKeysWithValues: result.classEvidence.map { ($0.queryID, $0.logits[2]) })
        return try primitives.map { primitive in
            let mask = primitive.mask!
            let foreground = mask.logits.map { $0 > configuration.raw.maskLogit }
            return PreparedQuery(queryID: primitive.queryID, queryLogit: logits[primitive.queryID]!, maskLogit: configuration.raw.maskLogit,
                mask: mask, labels: try partition(foreground: foreground, side: NativeRFDETRLayoutResource.maskSide, coreRadius: configuration.coreRadius))
        }
    }

    static func assign(sourceOwnerBounds owners: [CGRect], result: NativeRFDETRLayoutResult, sourceIdentity expected: String,
                       configuration: Configuration) throws -> [Assignment?] {
        guard expected == result.imageIdentity else { throw NativeRFDETRLayoutError.invalidImage }
        let queries = try prepare(result: result, configuration: configuration)
        return owners.map { owner in
            guard !owner.isEmpty, !owner.isNull, !owner.isInfinite,
                  [owner.minX, owner.minY, owner.maxX, owner.maxY].allSatisfy(\.isFinite) else { return nil }
            let width = CGFloat(result.sourceWidth), height = CGFloat(result.sourceHeight)
            let left = Int(floor(max(0, min(width, owner.minX)))), right = Int(ceil(max(0, min(width, owner.maxX))))
            let top = Int(floor(max(0, min(height, owner.minY)))), bottom = Int(ceil(max(0, min(height, owner.maxY))))
            guard left < right, top < bottom else { return nil }
            var bestQuery: PreparedQuery?, bestLabel: Int32 = 0, bestCount = 0
            for query in queries {
                var counts: [Int32: Int] = [:]
                for y in top..<bottom { for x in left..<right {
                    if let label = query.territory(sourceX: x, sourceY: y) { counts[label, default: 0] += 1 }
                } }
                for (label, count) in counts {
                    let oldLogit = bestQuery?.queryLogit ?? -.infinity, oldID = bestQuery?.queryID ?? Int.max
                    if count > bestCount || (count == bestCount && (query.queryLogit > oldLogit || (query.queryLogit == oldLogit &&
                        (query.queryID < oldID || (query.queryID == oldID && label < bestLabel))))) {
                        bestQuery = query; bestLabel = label; bestCount = count
                    }
                }
            }
            guard let bestQuery else { return nil }
            return Assignment(sourceIdentity: expected, policyIdentity: configuration.cacheIdentity, sourceOwnerBounds: owner,
                positiveOwnerPixelCentres: bestCount, ownerPixelCentres: (right-left)*(bottom-top), territoryID: bestLabel, query: bestQuery)
        }
    }
}
