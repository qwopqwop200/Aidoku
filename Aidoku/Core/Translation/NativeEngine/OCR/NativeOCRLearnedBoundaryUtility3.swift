// Agent3 learned global utility. Required deformation13 Float32 serialization parity.
import Foundation

enum NativeOCRLearnedBoundaryUtility3 {
    struct Model {
        let forest: NativeOCRLearnedBoundaryModel442.Forest
        let margin: Double
        init(data: Data) throws {
            enum Bad: Error { case model }
            guard let o = try JSONSerialization.jsonObject(with:data) as? [String:Any],
                  o["format"] as? String == "source-current72-pixel-utility-v1",
                  (o["featureNames"] as? [String])?.count == 357,
                  let raw = o["trees"] as? [[[Double]]], !raw.isEmpty, raw.count <= 256,
                  let depth = o["maximumDepth"] as? Int, depth > 0, depth <= 14,
                  let rate = o["learningRate"] as? Double, rate.isFinite, rate > 0, rate <= 1,
                  let margin = o["margin"] as? Double, margin.isFinite, margin >= 0 else { throw Bad.model }
            let bias = o["initialBias"] as? Double ?? 0
            guard bias.isFinite else { throw Bad.model }
            var trees = [[NativeOCRLearnedBoundaryModel442.Node]]()
            for rows in raw {
                guard !rows.isEmpty, rows.count <= 32767 else { throw Bad.model }
                var nodes = [NativeOCRLearnedBoundaryModel442.Node]()
                for r in rows {
                    guard r.count == 7, r.allSatisfy(\.isFinite),
                          [r[0],r[2],r[3]].allSatisfy({ $0.rounded() == $0 }),
                          r[0] >= -1, r[0] < 357, r[2] >= -1, r[2] < Double(rows.count),
                          r[3] >= -1, r[3] < Double(rows.count), r[5] >= 1, r[6] >= 1 else { throw Bad.model }
                    nodes.append(.init(feature:Int(r[0]),left:Int(r[2]),right:Int(r[3]),threshold:r[1],value:r[4]))
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
            self.forest = .init(trees:trees,rate:rate,bias:bias)
            self.margin = margin
        }
    }
}
