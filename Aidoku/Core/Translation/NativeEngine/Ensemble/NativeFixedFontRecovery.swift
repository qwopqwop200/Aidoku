import CoreGraphics
import Foundation

/// Immutable, native output-pixel OUTER layout width; never a domain override.
struct NativeOwnerOutputWidthPlan {
    let outputPixels: CGFloat
}

/// A finite geometry search. Exhaustion means only this candidate set was tried,
/// never physical impossibility. No owner identity or lexical rules live here.
enum NativeFixedFontRecovery {
    struct CacheBudgetFailure:Error {let owner:String;let resource:String;let audit:[String:Int]}
    /// Conservative retained-data accounting, not a claim about process RSS.
    /// The multiplier reserves source-witness/intermediate data along with RGBA.
    final class CacheBudget {
        let maxPixels:Int,maxRuns:Int,maxBytes:Int
        private(set) var pixels=0,runs=0,bytes=0
        private struct Charge {
            let image:CGImage
            let pixels:Int
            let runs:Int
            let bytes:Int
        }
        private var images:[ObjectIdentifier:Charge]=[:]
        init(maxPixels:Int=16_000_000,maxRuns:Int=1_000_000,maxBytes:Int=64*1024*1024) {
            self.maxPixels=min(16_000_000,max(0,maxPixels))
            self.maxRuns=min(1_000_000,max(0,maxRuns))
            self.maxBytes=min(64*1024*1024,max(0,maxBytes))
        }
        var audit:[String:Int] {["chargedPixels":pixels,"chargedRuns":runs,"conservativeChargedBytes":bytes,
            "maxPixels":maxPixels,"maxRuns":maxRuns,"maxBytes":maxBytes]}
        func checkImage(owner:String,width:Int,height:Int) throws {
            try Task.checkCancellation()
            guard width>0,height>0,height<=maxPixels,width<=maxPixels/max(1,height) else {
                throw CacheBudgetFailure(owner:owner,resource:"pixels",audit:audit)
            }
            let added=width*height
            guard pixels<=maxPixels-added else {throw CacheBudgetFailure(owner:owner,resource:"pixels",audit:audit)}
            guard added<=maxBytes/16,bytes<=maxBytes-added*16 else {
                throw CacheBudgetFailure(owner:owner,resource:"bytes",audit:audit)
            }
        }
        @discardableResult
        func retain(owner:String,image:CGImage,runCount:Int=0,metadataBytes:Int=4096) throws -> Bool {
            try Task.checkCancellation()
            let identity=ObjectIdentifier(image)
            if images[identity] != nil {return false}
            try checkImage(owner:owner,width:image.width,height:image.height)
            guard runCount>=0,runCount<=maxRuns,runs<=maxRuns-runCount else {
                throw CacheBudgetFailure(owner:owner,resource:"runs",audit:audit)
            }
            let addedBytes=image.bytesPerRow*image.height*4+runCount*24+max(0,metadataBytes)
            guard addedBytes<=maxBytes,bytes<=maxBytes-addedBytes else {
                throw CacheBudgetFailure(owner:owner,resource:"bytes",audit:audit)
            }
            let addedPixels=image.width*image.height
            pixels+=addedPixels;runs+=runCount;bytes+=addedBytes
            images[identity]=Charge(image:image,pixels:addedPixels,runs:runCount,bytes:addedBytes)
            return true
        }
        /// Only discard a newly generated candidate after its caller rejects it.
        /// Accepted alternatives and the incumbent remain charged and retained.
        func releaseDiscarded(image:CGImage) {
            guard let charge=images.removeValue(forKey:ObjectIdentifier(image)) else{return}
            pixels-=charge.pixels;runs-=charge.runs;bytes-=charge.bytes
        }
    }
    final class Metrics: @unchecked Sendable {
        var cache=CacheBudget()
        var recoveryActive=false
        var activeCache:CacheBudget? {recoveryActive ? cache:nil}
        var ordinaryShapeGenerations:[String:Int]=[:]
        var ordinaryShapesByFont:[String:Int]=[:]
        var baselineShapesByFont:[String:Int]=[:]
        var baselineChargedOwners=Set<String>()
        var sourceNearDiagnostics:[[String:Any]]=[]
        func beginRecovery() {
            let old=cache
            cache=CacheBudget(maxPixels:old.maxPixels,maxRuns:old.maxRuns,maxBytes:old.maxBytes)
            recoveryActive=true
            shapeGenerations=[:];shapesByFont=[:];baselineShapesByFont=[:];baselineChargedOwners=[]
            placementAttempts=0;peerPreparationCalls=0;verificationAttempts=0
            combinationQueueNodes=0;combinationEvaluations=0;paintCalls=0
            sourceNearDiagnostics=[]
        }
        var shapeGenerations:[String:Int]=[:]
        var shapesByFont:[String:Int]=[:]
        func count(owner:String,fontPixels:CGFloat)->Int {
            let key="\(owner)|\(Double(fontPixels).bitPattern)"
            return (shapesByFont[key] ?? 0)+max(baselineShapesByFont[key] ?? 0,ordinaryShapesByFont[key] ?? 0)
        }
        func recordShape(owner:String,fontPixels:CGFloat) {
            if recoveryActive {
                shapeGenerations[owner,default:0]+=1
                shapesByFont["\(owner)|\(Double(fontPixels).bitPattern)",default:0]+=1
            } else {
                ordinaryShapeGenerations[owner,default:0]+=1
                ordinaryShapesByFont["\(owner)|\(Double(fontPixels).bitPattern)",default:0]+=1
            }
        }
        var initialPlacementCalls=0
        var peerPreparationCalls=0
        var placementAttempts=0
        var verificationAttempts=0
        var combinationQueueNodes=0
        var combinationEvaluations=0
        var paintCalls=0
    }
    @TaskLocal static var metrics:Metrics?
    static func withMetrics<T>(_ body:()throws->T)rethrows -> T {
        try $metrics.withValue(Metrics(),operation:body)
    }
    enum Status: String {
        case recovered, noFeasibleShape, alternativesExhausted, combinationBudget, nodeBudget, unaffectedPeerAdmissionFailed, finalVerificationRejected, cacheBudget
    }
    struct Receipt {
        let status: Status
        let combinations: Int
        let nodes: Int
        let selected: [Int]?
        var audit: [String: Any] {
            ["status": status.rawValue, "combinations": combinations, "nodes": nodes,
             "selectedShapeIndices": selected as Any? ?? NSNull(),
             "physicalImpossibilityProven": false,
             "nodeScope":"combination queue only; not NativeFinalTextPaintAdmission internal solve nodes",
             "combinationLimit":64,"combinationQueueNodeLimit":4096]
        }
    }
    static func search(counts: [Int], maxCombinations: Int = 64, maxNodes: Int = 4096,
                       evaluate: ([Int]) throws -> Bool) throws -> Receipt {
        guard !counts.isEmpty, counts.allSatisfy({ (1...8).contains($0) }) else {
            return .init(status: .noFeasibleShape, combinations: 0, nodes: 0, selected: nil)
        }
        let combinationLimit=max(0,min(64,maxCombinations)),nodeLimit=max(0,min(4096,maxNodes))
        var queue: [[Int]] = [], seen = Set<[Int]>()
        var nodes = 0, combinations = 0, hitNodes = false
        func add(_ indices: [Int]) {
            guard !seen.contains(indices) else { return }
            guard nodes < nodeLimit else { hitNodes = true; return }
            seen.insert(indices); queue.append(indices); nodes += 1
        }
        add(Array(repeating: 0, count: counts.count))
        // Try coherent group geometry changes before the product explodes.
        for k in 1..<(counts.max() ?? 1) { add(counts.map { min(k, $0 - 1) }) }
        while !queue.isEmpty && combinations < combinationLimit {
            try Task.checkCancellation()
            let indices = queue.removeFirst()
            combinations += 1
            metrics?.combinationQueueNodes=nodes
            metrics?.combinationEvaluations=combinations
            if try evaluate(indices) {
                return .init(status: .recovered, combinations: combinations, nodes: nodes, selected: indices)
            }
            for owner in counts.indices where indices[owner] + 1 < counts[owner] {
                var next = indices; next[owner] += 1; add(next)
            }
        }
        let status: Status = !queue.isEmpty ? .combinationBudget : hitNodes ? .nodeBudget : .alternativesExhausted
        return .init(status: status, combinations: combinations, nodes: nodes, selected: nil)
    }
}
