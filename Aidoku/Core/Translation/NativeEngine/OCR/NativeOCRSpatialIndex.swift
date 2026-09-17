import CoreGraphics

/// A balanced bounding-box tree. Queries cross tree boundaries and return all
/// intersecting boxes, including large boxes spanning many small neighbours.
/// Unlike a pixel grid, it needs no coordinate-to-integer conversion or cells
/// proportional to the area of a long webtoon.
@available(iOS 18.0, *)
struct NativeOCRSpatialIndex {
    private struct Node {
        let bounds: CGRect
        let left: Int
        let right: Int
        let items: [Int]
    }

    private let boxes: [CGRect]
    private let nodes: [Node]
    private let root: Int?

    init(boxes: [CGRect]) {
        self.boxes = boxes
        var nodes: [Node] = []
        func build(_ indices: [Int]) -> Int {
            let bounds = indices.reduce(CGRect.null) { $0.union(boxes[$1]) }
            if indices.count <= 8 {
                nodes.append(Node(bounds: bounds, left: -1, right: -1, items: indices))
            } else {
                let vertical = bounds.height >= bounds.width
                let ordered = indices.sorted {
                    let left = vertical ? boxes[$0].midY : boxes[$0].midX
                    let right = vertical ? boxes[$1].midY : boxes[$1].midX
                    return left != right ? left < right : $0 < $1
                }
                let middle = ordered.count / 2
                let left = build(Array(ordered[..<middle]))
                let right = build(Array(ordered[middle...]))
                nodes.append(Node(bounds: bounds, left: left, right: right, items: []))
            }
            return nodes.count - 1
        }
        root = boxes.isEmpty ? nil : build(Array(boxes.indices))
        self.nodes = nodes
    }

    func indices(intersecting bounds: CGRect) -> [Int] {
        guard let root, !bounds.isNull else { return [] }
        var pending = [root]
        var result: [Int] = []
        while let index = pending.popLast() {
            let node = nodes[index]
            guard node.bounds.intersects(bounds) else { continue }
            if node.items.isEmpty {
                pending.append(node.left)
                pending.append(node.right)
            } else {
                // Keep traversal/item order without allocating a temporary
                // filtered array for every visited leaf.
                for item in node.items where boxes[item].intersects(bounds) {
                    result.append(item)
                }
            }
        }
        return result
    }
}
