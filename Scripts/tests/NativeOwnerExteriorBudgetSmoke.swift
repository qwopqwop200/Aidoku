import CoreGraphics
import Foundation

@main struct NativeOwnerExteriorBudgetSmoke {
    static func main() throws {
        typealias Predictor = NativeOwnerExteriorBGPrediction
        for count in [Int.min, 0, 6, 7, 48, 49, Int.max] {
            precondition(Predictor.primaryWorkLimit(eligibleOwnerCount: count) == .max)
        }
        var knownQueries = 0
        let colors = [[255,255,255], [0,0,0], [235,189,110], [17,33,69]]
        for count in [5,13,49] {
            for paper in colors {
                let budget = Predictor.Budget()
                budget.remaining = Predictor.primaryWorkLimit(eligibleOwnerCount: count)
                let owners = (0..<count).map { CGRect(x: $0*128+16, y: 16, width: 64, height: 64) }
                for i in 0..<count {
                    var rgba = [UInt8](repeating: 255, count: 96*96*4)
                    for y in 0..<96 { for x in 0..<96 {
                        let color = (24..<72).contains(x) && (24..<72).contains(y) ? [210,30,80] : paper
                        for channel in 0..<3 { rgba[(y*96+x)*4+channel] = UInt8(color[channel]) }
                    } }
                    let observed = try Predictor.predict(rgba: rgba, width: 96, height: 96,
                        roi: CGRect(x: i*128, y: 0, width: 96, height: 96), owner: owners[i],
                        peers: owners.enumerated().filter { $0.offset != i }.map(\.element), budget: budget, id: "\(i)")
                    precondition(observed == paper.map(Double.init),
                        "Owner \(i)/\(count), paper \(paper), observed \(String(describing: observed)), remaining \(budget.remaining), evidence \(String(describing: budget.observations[String(i)]))")
                    knownQueries += 1
                }
                precondition(!budget.exhausted)
                precondition(budget.remaining == .max && budget.spent > 0)
            }
        }
        // Intersecting peers must still exclude their colored source pixels.
        var rgba = [UInt8](repeating: 255, count: 96*96*4)
        for y in 0..<96 { for x in 80..<96 { rgba[(y*96+x)*4] = 0; rgba[(y*96+x)*4+1] = 0 } }
        let peer = CGRect(x: 80, y: 0, width: 16, height: 96)
        let observed = try Predictor.predict(rgba: rgba, width: 96, height: 96,
            roi: CGRect(x: 0, y: 0, width: 96, height: 96), owner: CGRect(x: 16, y: 16, width: 64, height: 64),
            peers: [peer], budget: Predictor.Budget(), id: "near-peer")
        precondition(observed == [255,255,255])
        let invalidBudget = Predictor.Budget()
        let invalid = try Predictor.predict(rgba: rgba, width: 96, height: 96,
            roi: CGRect(x: 0, y: 0, width: 96, height: 96), owner: CGRect(x: 16, y: 16, width: 64, height: 64),
            peers: [CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1)], budget: invalidBudget, id: "invalid")
        precondition(invalid == nil && invalidBudget.observations["invalid"]?["status"] as? String == "invalid-geometry")
        // Different raster strides and ROI origins must not remove a holdout
        // population merely because a regular sampling lattice aliases modulo 3.
        let shapes = [(79,83), (80,84), (81,85), (95,97), (96,96),
                      (127,129), (128,130), (161,163), (257,259), (319,320)]
        var negativeChecks = 0
        for (width,height) in shapes {
            let roi = CGRect(x: 17.25, y: 31.75, width: CGFloat(width), height: CGFloat(height))
            let owner = roi.insetBy(dx: roi.width / 4, dy: roi.height / 4)
            for paper in [[247,242,231], [12,21,45], [167,91,215], [203,217,184]] {
                var pixels = [UInt8](repeating: 255, count: width*height*4)
                for index in 0..<width*height {
                    for channel in 0..<3 { pixels[index*4+channel] = UInt8(paper[channel]) }
                }
                let result = try Predictor.predict(rgba: pixels, width: width, height: height,
                    roi: roi, owner: owner, peers: [], budget: Predictor.Budget(), id: "stride")
                precondition(result == paper.map(Double.init), "Stride \(width)x\(height): \(String(describing: result))")
                knownQueries += 1
            }
            var splitPixels = [UInt8](repeating: 255, count: width*height*4)
            for y in 0..<height { for x in 0..<width/2 {
                for channel in 0..<3 { splitPixels[(y*width+x)*4+channel] = 0 }
            } }
            let ambiguous = try Predictor.predict(rgba: splitPixels, width: width, height: height,
                roi: roi, owner: owner, peers: [], budget: Predictor.Budget(), id: "two-surfaces")
            precondition(ambiguous == nil, "Two distinct source surfaces must not become a single confident panel")
            negativeChecks += 1
        }
        print("{\"knownRGBQueries\":\(knownQueries),\"wrongRGB\":0,\"quotaExhaustions\":0,\"budgetBoundsChecks\":7,\"peerChecks\":2,\"ambiguousSurfaceChecks\":\(negativeChecks)}")
    }
}
