import Foundation

/// Private numerical parser, copied from frozen V1 without changing that implementation.
/// Default344 preserves the old arithmetic; explicit376 is separately ABI-validated by its generator.
/// No utility, GT/row lookup, source identity, or ownership operation.
enum NativeOCRLearnedBoundaryNumericForest {
    struct Node { let feature: Int, left: Int, right: Int; let threshold: Double, value: Double }
    struct Forest {
        let trees: [[Node]], rate: Double, bias: Double
        func score(_ x: [Double]) -> Double {
            var result = bias
            for tree in trees {
                var at = 0
                while tree[at].feature >= 0 {
                    let n = tree[at]
                    at = x[n.feature] <= n.threshold ? n.left:n.right
                }
                result += rate*tree[at].value
            }
            return result
        }
    }
    struct Bundle {
        let forests: [Forest]
        let featureCount: Int
        init(data: Data, featureCount: Int = 344) throws {
            enum Bad: Error { case model }
            guard [344, 376].contains(featureCount), let object = try JSONSerialization.jsonObject(with:data) as? [String:Any],
                  let models = object["models"] as? [[String:Any]], models.count == 5 else { throw Bad.model }
            var forests = [Forest]()
            for model in models {
                guard let features = model["featureNames"] as? [String], features.count == featureCount,
                      let raw = model["trees"] as? [[[Double]]], !raw.isEmpty, raw.count <= 256,
                      let rate = model["learningRate"] as? Double, rate.isFinite, rate > 0, rate <= 1,
                      let depth = model["maximumDepth"] as? Int, depth > 0, depth <= 14 else { throw Bad.model }
                let bias = model["initialBias"] as? Double ?? 0
                guard bias.isFinite else { throw Bad.model }
                var trees = [[Node]]()
                for rows in raw {
                    guard !rows.isEmpty, rows.count <= 32767 else { throw Bad.model }
                    var nodes = [Node]()
                    for r in rows {
                        guard r.count == 7, r.allSatisfy(\.isFinite),
                              [r[0],r[2],r[3]].allSatisfy({ $0.rounded() == $0 }),
                              r[0] >= -1, r[0] < Double(featureCount), r[2] >= -1, r[2] < Double(rows.count),
                              r[3] >= -1, r[3] < Double(rows.count), r[5] >= 1, r[6] >= 1 else { throw Bad.model }
                        nodes.append(Node(feature:Int(r[0]),left:Int(r[2]),right:Int(r[3]),threshold:r[1],value:r[4]))
                    }
                    var visited = Set<Int>()
                    func check(_ at: Int, _ level: Int) throws {
                        guard nodes.indices.contains(at), level <= depth, visited.insert(at).inserted else { throw Bad.model }
                        let n = nodes[at]
                        if n.feature >= 0 { try check(n.left,level+1);try check(n.right,level+1) }
                        else if n.left != -1 || n.right != -1 { throw Bad.model }
                    }
                    try check(0,0)
                    guard visited.count == nodes.count else { throw Bad.model }
                    trees.append(nodes)
                }
                forests.append(Forest(trees:trees,rate:rate,bias:bias))
            }
            self.forests = forests
            self.featureCount = featureCount
        }
        func predict(features: [Double]) -> [Double]? {
            guard features.count == featureCount, features.allSatisfy(\.isFinite) else { return nil }
            let y = forests.map { $0.score(features) }
            return y.allSatisfy(\.isFinite) ? y:nil
        }
    }
}
