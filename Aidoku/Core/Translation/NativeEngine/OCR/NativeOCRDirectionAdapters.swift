import CoreGraphics
import Foundation

@available(iOS 18.0, *)
enum NativeOCRDirectionAdapters {
    static func support(_ p: NativeRFDETRLayoutPrimitive) -> [CGPoint] {
        p.supportPolygon ?? NativeOCRDirectionGeometry.corners(p.sourceBounds)
    }

    static func coverage(_ polygon: [CGPoint], by p: NativeRFDETRLayoutPrimitive) -> CGFloat {
        let area = NativeOCRDirectionGeometry.area(polygon)
        return area > 0 ? min(1,NativeOCRDirectionGeometry.intersectionArea(polygon,support(p))/area) : 0
    }

    /// RF cannot veto already detected DB ink. For an enclosing endpoint
    /// proposal, apply the existing 60% RF membership floor to added area only.
    /// Brand-new candidates still use their separate 90% admission rule.
    static func supportsExpansion(_ proposal: [CGPoint], preserving original: [CGPoint],
                                  by primitive: NativeRFDETRLayoutPrimitive) -> Bool {
        let area = NativeOCRDirectionGeometry.area(proposal)
        let oldArea = NativeOCRDirectionGeometry.area(original)
        guard oldArea > 0, area > oldArea,
              original.allSatisfy({ NativeOCRDirectionGeometry.contains(proposal,$0) }) else { return false }
        let support = support(primitive)
        let unsupported = area - NativeOCRDirectionGeometry.intersectionArea(proposal,support)
        let oldUnsupported = oldArea - NativeOCRDirectionGeometry.intersectionArea(original,support)
        return unsupported - oldUnsupported <= (area-oldArea)*0.4 + 0.000001
    }

    static func scopeFrames(_ scope: CGRect, boxes: [NativeCoreMLDetectionBox],
                            probability: NativeMainEnsembleOCRProbability.Sample?) -> [NativeOCRDirectionGeometry.Frame] {
        var frames: [NativeOCRDirectionGeometry.Frame] = []
        if NativeOCRDirectionGeometry.enabled("mixedDirections") {
            for b in boxes.sorted(by: { NativeOCRDirectionGeometry.area($0.polygon) > NativeOCRDirectionGeometry.area($1.polygon) }) {
                guard b.score >= 0.25, NativeOCRDirectionGeometry.coverage(b.polygon,by:scope) >= 0.6,
                      let q = NativeOCRDirectionGeometry.readingQuad(b.polygon,vertical:true),
                      let f = NativeOCRDirectionGeometry.Frame(q), f.rect.height >= f.rect.width*1.2,
                      !frames.contains(where: { NativeOCRDirectionGeometry.compatible(q,with:$0) }) else { continue }
                frames.append(f)
            }
        } else if let f = scopeFrame(scope,boxes:boxes) { frames = [f] }
        if frames.isEmpty, NativeOCRDirectionGeometry.enabled("unanchored"),
           scopeFrame(scope,boxes:boxes) == nil, let probability,
           let f = evidenceFrame(scope,probability:probability) { frames = [f] }
        return frames
    }

    /// Estimate an undirected axis only from elongated DB-probability components.
    /// Ambiguous/isotropic or disagreeing components abstain; RF aspect is not evidence.
    static func evidenceFrame(_ scope: CGRect, probability m: NativeMainEnsembleOCRProbability.Sample) -> NativeOCRDirectionGeometry.Frame? {
        guard m.width > 0, m.height > 0, m.values.count == m.width*m.height,
              m.region == CGRect(x:0,y:0,width:m.width,height:m.height),
              m.width == m.resizedWidth, m.height == m.resizedHeight else { return nil }
        let sx = CGFloat(m.sourceWidth)/CGFloat(m.width), sy = CGFloat(m.sourceHeight)/CGFloat(m.height)
        let x0=max(0,Int(floor(scope.minX/sx))), x1=min(m.width,Int(ceil(scope.maxX/sx)))
        let y0=max(0,Int(floor(scope.minY/sy))), y1=min(m.height,Int(ceil(scope.maxY/sy)))
        let width=x1-x0, height=y1-y0
        guard width > 0, height > 0, width <= 262_144/height else { return nil }
        var visited=Set<Int>(), votes: [(Double,Double)] = []
        for y in y0..<y1 { for x in x0..<x1 {
            let start=y*m.width+x
            guard m.values[start] >= 0.15, !visited.contains(start) else { continue }
            var queue=[start], cursor=0; visited.insert(start)
            var points:[CGPoint]=[]
            while cursor < queue.count {
                let cell=queue[cursor]; cursor += 1
                let xx=cell % m.width, yy=cell/m.width
                points.append(CGPoint(x:(CGFloat(xx)+0.5)*sx,y:(CGFloat(yy)+0.5)*sy))
                for (dx,dy) in [(1,0),(-1,0),(0,1),(0,-1)] {
                    let nx=xx+dx, ny=yy+dy, n=ny*m.width+nx
                    if nx >= x0 && nx < x1 && ny >= y0 && ny < y1 && m.values[n] >= 0.15 && !visited.contains(n) {
                        visited.insert(n); queue.append(n)
                    }
                }
            }
            guard points.count >= 16 else { continue }
            let n=Double(points.count), mx=points.reduce(0.0){$0+Double($1.x)}/n, my=points.reduce(0.0){$0+Double($1.y)}/n
            var xx=0.0, yy=0.0, xy=0.0
            for p in points { let x=Double(p.x)-mx, y=Double(p.y)-my; xx+=x*x; yy+=y*y; xy+=x*y }
            let delta=hypot(xx-yy,2*xy), major=(xx+yy+delta)/2, minor=(xx+yy-delta)/2
            guard major >= max(1,minor)*6 else { continue }
            votes.append((0.5*atan2(2*xy,xx-yy),n))
        } }
        guard !votes.isEmpty else { return nil }
        let cx=votes.reduce(0.0){$0+cos(2*$1.0)*$1.1}, cy=votes.reduce(0.0){$0+sin(2*$1.0)*$1.1}
        let weight=votes.reduce(0.0){$0+$1.1}
        guard hypot(cx,cy)/weight >= 0.98 else { return nil }
        let a=0.5*atan2(cy,cx), v=CGPoint(x:cos(a),y:sin(a)), u=CGPoint(x:v.y,y:-v.x)
        let c=CGPoint(x:scope.midX,y:scope.midY)
        func p(_ x:CGFloat,_ y:CGFloat)->CGPoint { CGPoint(x:c.x+u.x*x+v.x*y,y:c.y+u.y*x+v.y*y) }
        return NativeOCRDirectionGeometry.Frame([p(-1,-4),p(1,-4),p(1,4),p(-1,4)])
    }
    static func scopeFrame(_ scope: CGRect, boxes: [NativeCoreMLDetectionBox]) -> NativeOCRDirectionGeometry.Frame? {
        let anchors = boxes.compactMap { box -> (CGFloat, NativeOCRDirectionGeometry.Frame)? in
            let r = NativeOCRDirectionGeometry.bounds(box.polygon), overlap = r.intersection(scope)
            let coverage = NativeOCRDirectionGeometry.enabled("rfOverlap")
                ? NativeOCRDirectionGeometry.coverage(box.polygon, by: scope)
                : (overlap.isNull ? 0 : overlap.width*overlap.height / max(0.000001, r.width*r.height))
            guard box.score >= 0.25, coverage >= 0.6,
                  let f = NativeOCRDirectionGeometry.Frame(box.polygon), f.rect.height >= f.rect.width*1.2 else { return nil }
            return (r.width*r.height,f)
        }
        return anchors.max(by: { $0.0 < $1.0 })?.1
    }

    static func window(_ frame: NativeOCRDirectionGeometry.Frame, scope: CGRect,
                       boxes: [NativeCoreMLDetectionBox]) -> NativeOCRDirectionGeometry.Window? {
        let world = boxes.reduce(scope) { r,box in
            let b = NativeOCRDirectionGeometry.bounds(box.polygon)
            return b.intersects(scope) ? r.union(b) : r
        }
        return NativeOCRDirectionGeometry.Window(frame: frame, world: world)
    }

    static func box(_ b: NativeCoreMLDetectionBox, map: (CGPoint) -> CGPoint) -> NativeCoreMLDetectionBox {
        .init(polygon: b.polygon.map(map), score: b.score, erasurePolygons: b.erasurePolygons,
              recognitionPolygon: b.recognitionPolygon?.map(map), isThinFinePrintRecovery: b.isThinFinePrintRecovery,
              finePrintRetryPolygons: b.finePrintRetryPolygons.map { $0.map(map) },
              recognitionColumnEvidence: b.recognitionColumnEvidence, detectorSeedEvidence: b.detectorSeedEvidence)
    }

    static func layout(_ original: NativeRFDETRLayoutResult, primitives: [NativeRFDETRLayoutPrimitive],
                       window: NativeOCRDirectionGeometry.Window? = nil) -> NativeRFDETRLayoutResult {
        let width = window?.width ?? original.sourceWidth, height = window?.height ?? original.sourceHeight
        let transformed = primitives.map { p -> NativeRFDETRLayoutPrimitive in
            guard let window else { return p }
            let r = window.bounds(NativeOCRDirectionGeometry.corners(p.sourceBounds))
            var transformed = NativeRFDETRLayoutPrimitive(queryID: p.queryID, semanticClass: p.semanticClass, confidence: p.confidence,
                normalizedBounds: CGRect(x:r.minX/CGFloat(width),y:r.minY/CGFloat(height),
                                         width:r.width/CGFloat(width),height:r.height/CGFloat(height)),
                sourceBounds: r, mask: nil)
            if NativeOCRDirectionGeometry.enabled("rfShape") { transformed.supportPolygon = support(p).map(window.project) }
            return transformed
        }
        return .init(imageIdentity: original.imageIdentity, sourceWidth: width, sourceHeight: height,
            primitives: transformed, maskQueriesOmittedByBudget: original.maskQueriesOmittedByBudget,
            preprocessingMilliseconds: original.preprocessingMilliseconds, modelMilliseconds: original.modelMilliseconds,
            decodeMilliseconds: original.decodeMilliseconds, computeUnits: original.computeUnits, fromCache: original.fromCache)
    }

    static func probability(_ original: NativeMainEnsembleOCRProbability.Sample,
                            window: NativeOCRDirectionGeometry.Window,
                            support: [CGPoint]? = nil,
                            preserving: [[CGPoint]] = [],
                            spacing: CGSize? = nil) -> NativeMainEnsembleOCRProbability.Sample? {
        guard original.width > 0, original.height > 0,
              original.width == original.resizedWidth, original.height == original.resizedHeight,
              original.values.count == original.width*original.height,
              original.region == CGRect(x:0,y:0,width:original.width,height:original.height) else { return nil }
        let sx = CGFloat(original.sourceWidth)/CGFloat(original.width)
        let sy = CGFloat(original.sourceHeight)/CGFloat(original.height)
        let u = window.frame.across, v = window.frame.along
        let dx = spacing?.width ?? 1/hypot(u.x/sx,u.y/sy)
        let dy = spacing?.height ?? 1/hypot(v.x/sx,v.y/sy)
        let width = max(1,Int(ceil(CGFloat(window.width)/dx))), height = max(1,Int(ceil(CGFloat(window.height)/dy)))
        guard width <= 4_194_304/height else { return nil }
        var values = [Float](repeating:0,count:width*height)
        let supportQuad = support.flatMap(NativeOCRDirectionGeometry.Containment.init)
        let preservedQuads = preserving.compactMap(NativeOCRDirectionGeometry.Containment.init)
        for y in 0..<height { for x in 0..<width {
            let p = window.restore(CGPoint(x:(CGFloat(x)+0.5)*CGFloat(window.width)/CGFloat(width),
                                            y:(CGFloat(y)+0.5)*CGFloat(window.height)/CGFloat(height)))
            if support != nil, supportQuad?.contains(p) != true,
               !preservedQuads.contains(where: { $0.contains(p) }) { continue }
            let xx = Int(floor(p.x/sx)), yy = Int(floor(p.y/sy))
            if xx >= 0, yy >= 0, xx < original.width, yy < original.height {
                values[y*width+x] = original.values[yy*original.width+xx]
            }
        } }
        return .init(sourceWidth: window.width, sourceHeight: window.height, resizedWidth: width, resizedHeight: height,
            region: CGRect(x:0,y:0,width:width,height:height), width: width, height: height, values: values)
    }
}
