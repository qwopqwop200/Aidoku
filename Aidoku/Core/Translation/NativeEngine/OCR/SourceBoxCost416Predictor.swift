import Foundation
import CoreFoundation

// Isolated source-only predictor. No frame/source/model file reads, native calls,
// feature extraction, metrics, GT, candidate IDs or fold/group routing here.
enum SourceBoxCost416Predictor {
    static let enabled = false
    enum InvalidModel: Error { case schema, number, dimension, tree, support }
    fileprivate struct Node {
        let feature: Int, left: Int, right: Int
        let threshold: Double, value: Double
    }
    struct Model {
        let featureCount: Int
        let margin: Double // caller policy; not part of prediction arithmetic
        let treeCount: Int
        fileprivate let active: Bool, rate: Double, depth: Int
        fileprivate let trees: [[Node]]
        fileprivate init(featureCount: Int, margin: Double, active: Bool,
                         rate: Double, depth: Int, trees: [[Node]]) {
            self.featureCount=featureCount;self.margin=margin;self.active=active
            self.rate=rate;self.depth=depth;self.trees=trees;self.treeCount=trees.count
        }
    }
    private static func number(_ v: Any?) throws -> Double {
        guard let n=v as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite else {throw InvalidModel.number}
        return n.doubleValue
    }
    private static func integer(_ v: Any?, minimum: Int, maximum: Int) throws -> Int {
        let n=try number(v)
        guard n>=Double(minimum),n<=Double(maximum),n.rounded(.towardZero)==n else {throw InvalidModel.number}
        return Int(n)
    }
    // JSONDecoder is deliberate: Foundation JSONSerialization/NSNumber decoding
    // rounded some source decimals differently from C++ strtod in the parity
    // controls. Decode wire Doubles directly, before constructing an Any object.
    private struct WireModel: Decodable {
        let format: String, enabled: Bool
        let initialBias: Double, fallbackPrediction: Double, learningRate: Double
        let margin: Double, maximumDepth: Int, featureNames: [String]
        let nodeFields: String, trees: [[[Double]]]
    }
    static func decodeCompactJSON(_ compactJSON: Data) throws -> Model {
        let w=try JSONDecoder().decode(WireModel.self,from:compactJSON)
        return try parse(["format":w.format,"enabled":w.enabled,
            "initialBias":w.initialBias,"fallbackPrediction":w.fallbackPrediction,
            "learningRate":w.learningRate,"margin":w.margin,
            "maximumDepth":w.maximumDepth,"featureNames":w.featureNames,
            "nodeFields":w.nodeFields,"trees":w.trees])
    }
    // Accept ONLY the compact model object, never the training-result dictionary.
    // Feature names establish dimension only; they are not retained or scored.
    static func parse(_ object: [String:Any]) throws -> Model {
        let allowed:Set<String>=["format","enabled","initialBias","fallbackPrediction",
            "learningRate","margin","maximumDepth","featureNames","nodeFields","trees"]
        guard Set(object.keys).isSubset(of:allowed),
              object["format"] as? String == "source-box-cost416-compact-v1",
              let flag=object["enabled"] as? NSNumber,
              CFGetTypeID(flag)==CFBooleanGetTypeID(),
              let names=object["featureNames"] as? [String],!names.isEmpty,names.count<=4096,
              let rawTrees=object["trees"] as? [Any],rawTrees.count<=64 else {throw InvalidModel.schema}
        guard try number(object["initialBias"])==0,
              try number(object["fallbackPrediction"])==0,
              try number(object["learningRate"])==0.1 else {throw InvalidModel.schema}
        let margin=try number(object["margin"])
        guard margin>=0 else {throw InvalidModel.number}
        let depth=try integer(object["maximumDepth"],minimum:1,maximum:4)
        var trees:[[Node]]=[]
        for rawTree in rawTrees {
            guard let rawNodes=rawTree as? [Any],!rawNodes.isEmpty,rawNodes.count<=31 else {throw InvalidModel.tree}
            var nodes:[Node]=[]
            for row in rawNodes {
                guard let fields=row as? [Any],fields.count==7 else {throw InvalidModel.tree}
                let feature=try integer(fields[0],minimum:-1,maximum:names.count-1)
                let threshold=try number(fields[1])
                let left=try integer(fields[2],minimum:-1,maximum:rawNodes.count-1)
                let right=try integer(fields[3],minimum:-1,maximum:rawNodes.count-1)
                let value=try number(fields[4])
                // Training support is parsed/validated, then discarded. It is
                // NEVER a score input or an alternative per-group route.
                let samples=try integer(fields[5],minimum:128,maximum:1_000_000_000)
                let groups=try integer(fields[6],minimum:8,maximum:samples)
                guard groups<=samples else {throw InvalidModel.support}
                nodes.append(.init(feature:feature,left:left,right:right,threshold:threshold,value:value))
            }
            var seen=Set<Int>()
            func visit(_ index: Int, _ level: Int) throws {
                guard nodes.indices.contains(index),level<=depth,seen.insert(index).inserted else {throw InvalidModel.tree}
                let node=nodes[index]
                if node.feature<0 {
                    guard node.left == -1,node.right == -1 else {throw InvalidModel.tree}
                } else {
                    guard node.left>=0,node.right>=0 else {throw InvalidModel.tree}
                    try visit(node.left,level+1);try visit(node.right,level+1)
                }
            }
            try visit(0,0)
            guard seen.count==nodes.count else {throw InvalidModel.tree}
            trees.append(nodes)
        }
        return Model(featureCount:names.count,margin:margin,active:flag.boolValue,
                     rate:0.1,depth:depth,trees:trees)
    }
    // Mathematical upper bound on ANY nonfallback completion of the unknown
    // source features. Known values must be authentic pre-generation root values;
    // the generic helper never fills unknown candidate/support slots with guesses.
    static func upperBound(model: Model, known: [Int:Double],
                           experimentEnabled: Bool = enabled) -> Double? {
        guard experimentEnabled else {return nil}
        guard known.allSatisfy({$0.key>=0 && $0.key<model.featureCount && $0.value.isFinite}) else {return nil}
        if !model.active {return 0}
        var sum=0.0
        for tree in model.trees {
            func bound(_ index: Int) -> Double {
                let node=tree[index]
                if node.feature<0 {return node.value}
                if let value=known[node.feature] {
                    return bound(value<=node.threshold ? node.left:node.right)
                }
                return max(bound(node.left),bound(node.right))
            }
            let contribution=model.rate*bound(0)
            sum += contribution
        }
        return sum.isFinite ? sum:nil
    }
    // nil means default OFF or invalid feature row: caller keeps original fallback.
    // Enabling this isolated scorer is NOT native admission or runtime activation.
    static func score(model: Model, sourceFeatures: [Double], fallback: Bool,
                      experimentEnabled: Bool = enabled) -> Double? {
        guard experimentEnabled else {return nil}
        guard sourceFeatures.count==model.featureCount,
              sourceFeatures.allSatisfy({$0.isFinite}) else {return nil}
        if fallback || !model.active {return 0}
        var sum=0.0
        for tree in model.trees {
            var index=0
            while true {
                let node=tree[index]
                if node.feature<0 {
                    // Same ordered multiply + add as frozen C++, no normalization,
                    // score clipping, root-specific correction, or fused multiply-add.
                    let contribution=model.rate*node.value
                    sum += contribution
                    break
                }
                index=sourceFeatures[node.feature]<=node.threshold ? node.left:node.right
            }
        }
        return sum.isFinite ? sum:nil
    }
}
