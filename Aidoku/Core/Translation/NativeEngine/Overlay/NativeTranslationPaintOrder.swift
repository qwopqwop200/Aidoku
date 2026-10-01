import CoreGraphics
import Foundation

/// The root-layer lifting pass. All rectangles are actual CSS Range boxes;
/// layer order is the root DOM order captured before this pass.
enum NativeTranslationPaintOrder {
    struct Layer {
        let id: String
        var z: Int
        var order: Double
        let quad: [CGPoint]
        var coverage: [CGRect] = []
        var usesQuad = false
        var opaque = true
        var shown = true
        var background: [Double]?
    }
    struct Node {
        let id: String
        let layerID: String
        let glyphs: [CGRect]
        let quad: [CGPoint]
        var isRoot = true
        var opaque = false
        var rotatingPanel = false
        var ownRotatedPlate: String?
        var foreground: [Double]?
        var lift: String?
    }
    struct Result { let nodes: [Node]; let layers: [Layer]; let lifted: Int }
    static func apply(nodes input: [Node], layers initial: [Layer], itemCount: Int) -> Result {
        guard itemCount <= 256 else { return .init(nodes: input,layers: initial,lifted: 0) }
        var nodes = input, layers = initial, lifted = 0
        let indices = Dictionary(layers.enumerated().map { ($0.element.id,$0.offset) },uniquingKeysWith: {first,_ in first})
        func above(_ a: String, _ b: String) -> Bool {
            guard a != b, let ai = indices[a], let bi = indices[b] else {return false}
            let x = layers[ai], y = layers[bi]
            return x.z != y.z ? x.z > y.z : x.order > y.order
        }
        func covered(_ layer: Layer, _ p: CGPoint) -> Bool {
            layer.usesQuad ? inside(layer.quad,p) : layer.coverage.contains { r in
                p.x >= r.minX && p.x <= r.maxX && p.y >= r.minY && p.y <= r.maxY
            }
        }
        func points(_ node: Node) -> [CGPoint] {
            node.glyphs.flatMap { r in [(0.5,0.5),(0.3,0.35),(0.7,0.35),(0.3,0.65),(0.7,0.65)].map { x,y in
                CGPoint(x: r.minX+r.width*x,y: r.minY+r.height*y)
            } }
        }
        func paints(_ node: Node, _ point: CGPoint) -> Bool {
            if node.opaque {return inside(node.quad,point)}
            return node.glyphs.contains { r in point.x >= r.minX-1 && point.x <= r.maxX+1 && point.y >= r.minY-1 && point.y <= r.maxY+1 } &&
                (!node.rotatingPanel || inside(node.quad,point))
        }
        for i in nodes.indices {
            let node = nodes[i], own = points(node)
            guard node.isRoot, !own.isEmpty, let ni = indices[node.layerID] else {continue}
            let covering = own.compactMap { point -> Int? in
                var top: Int?
                for j in layers.indices where layers[j].id != node.layerID && layers[j].shown && layers[j].opaque &&
                    above(layers[j].id,node.layerID) && covered(layers[j],point) {
                    if top == nil || above(layers[j].id,layers[top!].id) {top=j}
                }
                return top
            }
            let hidden = covering.count
            guard Double(hidden) >= max(1,Double(own.count)*0.1) else {continue}
            let previous = layers[ni].z
            let plateIndex = node.ownRotatedPlate.flatMap { indices[$0] }
            if let pi = plateIndex, layers[pi].shown {
                let aboveNodes = nodes.indices.filter { j in j != i && above(nodes[j].layerID,layers[pi].id) &&
                    points(nodes[j]).contains {inside(layers[pi].quad,$0)} }
                let oldZ = layers[pi].z, oldOrder = layers[pi].order
                layers[pi].z = 3; layers[pi].order = layers[ni].order-0.1; layers[ni].z = 3
                if !aboveNodes.contains(where: { !above(nodes[$0].layerID,layers[pi].id) }) {
                    nodes[i].lift = "\(hidden)/\(own.count)";lifted+=1;continue
                }
                layers[pi].z = oldZ;layers[pi].order = oldOrder;layers[ni].z = previous
            }
            let aboveNodes = nodes.indices.filter { j in j != i && above(nodes[j].layerID,node.layerID) &&
                points(nodes[j]).contains {paints(node,$0)} }
            var readable = plateIndex == nil
            if let color = node.foreground, plateIndex != nil {
                readable = covering.allSatisfy { j in
                    guard let surface = layers[j].background else {return false}
                    let a=luminance(color),b=luminance(surface)
                    return (max(a,b)+0.05)/(min(a,b)+0.05) >= 3
                }
            }
            layers[ni].z = 3
            if !readable || aboveNodes.contains(where: { !above(nodes[$0].layerID,node.layerID) }) {
                layers[ni].z = previous;nodes[i].lift = "blocked";continue
            }
            nodes[i].lift = "\(hidden)/\(own.count)";lifted+=1
        }
        return .init(nodes: nodes,layers: layers,lifted: lifted)
    }
    static func inside(_ q: [CGPoint], _ p: CGPoint) -> Bool {
        guard q.count == 4 else {return false}
        var sign = 0
        for i in 0..<4 {
            let a=q[i],b=q[(i+1)%4],c=(b.x-a.x)*(p.y-a.y)-(b.y-a.y)*(p.x-a.x)
            if abs(c) < 1e-9 {continue}
            let next = c > 0 ? 1 : -1
            if sign != 0 && sign != next {return false};sign=next
        }
        return true
    }
    private static func luminance(_ rgb: [Double]) -> Double {
        guard rgb.count == 3 else {return .nan}
        return zip(rgb,[0.2126,0.7152,0.0722]).reduce(0) { total,pair in
            let x=pair.0/255
            return total+pair.1*(x<=0.04045 ? x/12.92:pow((x+0.055)/1.055,2.4))
        }
    }
}
