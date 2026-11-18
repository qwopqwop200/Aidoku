import CoreGraphics
import Foundation

/// Source geometry only. An axis-aligned union rectangle cannot reveal tilt;
/// preserve the original member quads and never infer an angle from translation.
enum NativeSourceTextRotation {
    struct Observation {
        let radians: Double
        let members: Int
        let agreeingMembers: Int
    }
    struct PixelObservation {
        let radians: Double
        let samples: Int
        let gain: Double
        let shoulderRatio: Double
        let orientedBounds: [Double]
        let sourceSize: CGSize
    }
    private struct Sample { let angle: Double; let weight: Double }
    private static let maximumAngle = Double.pi / 6
    private static let agreement = Double.pi / 90
    private static let deadband = Double.pi / 240

    private static func residual(_ radians: Double) -> Double {
        var angle = radians.remainder(dividingBy: .pi / 2)
        if angle > .pi / 4 { angle -= .pi / 2 }
        if angle < -.pi / 4 { angle += .pi / 2 }
        return angle
    }

    static func estimate(_ polygons: Any?) -> Observation? {
        guard let polygons = polygons as? [[[Double]]], !polygons.isEmpty, polygons.count <= 256 else { return nil }
        var samples: [Sample] = []
        for quad in polygons {
            guard quad.count == 4, quad.allSatisfy({ $0.count == 2 && $0.allSatisfy { $0.isFinite && abs($0) <= 10_000_000 } }) else {
                return nil
            }
            let turns = (0..<4).map { i -> Double in
                let a = quad[i], b = quad[(i + 1) % 4], c = quad[(i + 2) % 4]
                return (b[0] - a[0]) * (c[1] - b[1]) - (b[1] - a[1]) * (c[0] - b[0])
            }
            guard turns.allSatisfy({ $0 > 0 }) || turns.allSatisfy({ $0 < 0 }) else { continue }
            var angles: [Double] = [], lengths: [Double] = []
            for i in 0..<4 {
                let a = quad[i], b = quad[(i + 1) % 4]
                let dx = b[0] - a[0], dy = b[1] - a[1]
                angles.append(residual(atan2(dy, dx))); lengths.append(hypot(dx, dy))
            }
            guard lengths.allSatisfy({ $0 > 1 }) else { continue }
            let first = lengths[0] + lengths[2], second = lengths[1] + lengths[3]
            let indices = first >= second ? [0, 2] : [1, 3]
            guard abs(angles[indices[0]] - angles[indices[1]]) <= agreement else { continue }
            if max(first, second) < min(first, second) * 1.25,
               (angles.max()! - angles.min()!) > agreement { continue }
            let weight = lengths[indices[0]] + lengths[indices[1]]
            let angle = indices.reduce(0.0) { $0 + angles[$1] * lengths[$1] } / weight
            guard abs(angle) <= maximumAngle else { continue }
            samples.append(Sample(angle: angle, weight: weight))
        }
        guard !samples.isEmpty else { return nil }
        samples.sort { $0.angle < $1.angle }
        let total = samples.reduce(0.0) { $0 + $1.weight }
        var cumulative = 0.0, median = samples[0].angle
        for sample in samples {
            cumulative += sample.weight
            if cumulative >= total / 2 { median = sample.angle; break }
        }
        let agreeing = samples.filter { abs($0.angle - median) <= agreement }
        let support = agreeing.reduce(0.0) { $0 + $1.weight }
        guard support >= total * 0.6 else { return nil }
        let angle = agreeing.reduce(0.0) { $0 + $1.angle * $1.weight } / support
        return Observation(radians: abs(angle) < deadband ? 0 : angle,
                           members: samples.count, agreeingMembers: agreeing.count)
    }

    /// Bounded deskew fallback for a source whose original member quads are
    /// absent. Only authenticated erasure-mask pixels matching source paint
    /// participate; no translated raster or guessed rectangular ink mask.
    static func estimatePixels(rgb: [UInt8], mask: [UInt8], width: Int, height: Int,
                               rect: CGRect, foreground: [Double], background: [Double],
                               font: Double) -> PixelObservation? {
        guard width>0,height>0,width<=16_000_000/height,rgb.count==width*height*3,mask.count==width*height,
              foreground.count==3,background.count==3,(foreground+background).allSatisfy({$0.isFinite && (0...255).contains($0)}),
              font.isFinite,font>=1,rect.minX.isFinite,rect.minY.isFinite,rect.width.isFinite,rect.height.isFinite,
              rect.width>0,rect.height>0,
              rect.width>rect.height*1.25 || rect.height>rect.width*1.25 else{return nil}
        let box=rect.intersection(CGRect(x:0,y:0,width:width,height:height))
        guard !box.isNull,box.width*box.height<=1_000_000,box.width*box.height>=32 else{return nil}
        let delta=zip(foreground,background).map {$0.0-$0.1},norm=delta.reduce(0.0){$0+$1*$1}
        guard delta.map(abs).max()!>=32,norm>0 else{return nil}
        let step=max(1,Int(ceil(sqrt(box.width*box.height/20_000))))
        var points:[(x:Double,y:Double,weight:Double)]=[]
        for y in stride(from:Int(ceil(box.minY)),to:Int(floor(box.maxY)),by:step) {
            for x in stride(from:Int(ceil(box.minX)),to:Int(floor(box.maxX)),by:step) {
                let index=y*width+x
                guard mask[index] != 0 else{continue}
                let color=(0..<3).map {Double(rgb[index*3+$0])}
                let amount=min(1,max(0,(0..<3).reduce(0.0){$0+(color[$1]-background[$1])*delta[$1]}/norm))
                guard amount>=0.35,(0..<3).allSatisfy({abs(color[$0]-background[$0]-amount*delta[$0])<=32})else{continue}
                points.append((Double(x)-Double(box.midX),Double(y)-Double(box.midY),amount))
            }
        }
        guard points.count>=32 else{return nil}
        let horizontal=box.width>box.height,bin=max(1,font*0.1)
        let bound=Int(ceil((box.width+box.height)/CGFloat(bin)))+4
        guard bound<=8192 else{return nil}
        let mass=points.reduce(0.0){$0+$1.weight}
        func score(_ angle:Double)->Double {
            let c=cos(angle),s=sin(angle)
            var histogram=[Double](repeating:0,count:bound*2+1)
            for point in points {
                let normal=horizontal ? -point.x*s+point.y*c:point.x*c+point.y*s
                let index=Int(floor(normal/bin))+bound
                if histogram.indices.contains(index){histogram[index]+=point.weight}
            }
            return histogram.reduce(0.0){$0+$1*$1}/(mass*mass)
        }
        var best=(angle:0.0,score:score(0))
        for degrees in -30...30 {
            let angle=Double(degrees)*Double.pi/180,value=score(angle)
            if value>best.score {best=(angle,value)}
        }
        let coarse=best.angle
        for quarter in -4...4 {
            let angle=coarse+Double(quarter)*Double.pi/720
            guard abs(angle)<=maximumAngle else{continue}
            let value=score(angle)
            if value>best.score {best=(angle,value)}
        }
        let zero=score(0),gain=best.score/max(zero,1e-12)
        let shoulder=max(score(best.angle-Double.pi/36),score(best.angle+Double.pi/36))/max(best.score,1e-12)
        guard abs(best.angle)>=deadband,gain>=1.15,shoulder<=0.96 else{return nil}
        let c=cos(best.angle),s=sin(best.angle)
        let along=points.map {($0.x+Double(box.midX))*c+($0.y+Double(box.midY))*s}
        let normal=points.map {-($0.x+Double(box.midX))*s+($0.y+Double(box.midY))*c}
        return PixelObservation(radians:best.angle,samples:points.count,gain:gain,shoulderRatio:shoulder,
            orientedBounds:[along.min()!,normal.min()!,along.max()!,normal.max()!],sourceSize:CGSize(width:width,height:height))
    }

    private static func anchor(_ bounds:[Double],angle:Double,size:CGSize,guide:[String:Any])->[Double]? {
        guard bounds.count==4,size.width.isFinite,size.height.isFinite,size.width>0,size.height>0 else{return nil}
        let along:Double
        switch guide["horizontal"] as? String {
        case "left":along=bounds[0]
        case "right":along=bounds[2]
        case "center":along=(bounds[0]+bounds[2])/2
        default:return nil
        }
        let normal:Double
        switch guide["vertical"] as? String {
        case "top":normal=bounds[1]
        case "bottom":normal=bounds[3]
        case "center":normal=(bounds[1]+bounds[3])/2
        default:return nil
        }
        return [(along*cos(angle)-normal*sin(angle))/Double(size.width),
                (along*sin(angle)+normal*cos(angle))/Double(size.height)]
    }

    private static func permitsOrientedAnchor(_ raw:[String:Any])->Bool {
        let clusterAbsent=raw["sourceClusterAlignment"]==nil || raw["sourceClusterAlignment"]is NSNull
        let bodyAbsent=raw["balloonPlacement"]==nil || raw["balloonPlacement"]is NSNull
        return clusterAbsent && bodyAbsent && raw["ensembleLockLayout"]as?Bool != true &&
            (raw["textExpansionPolicy"]as?[String:Any])?["kind"]as?String != "inside-balloon-mask"
    }

    static func annotate(_ items: [[String: Any]],pageSize:CGSize?=nil,
                         pixelObservation: (([String: Any],[String: Any])->PixelObservation?)? = nil) -> [[String: Any]] {
        var result = items
        for i in items.indices {
            guard var guide = items[i]["textPlacementGuide"] as? [String: Any],
                  guide["sourceRotationRadians"] == nil || guide["sourceRotationRadians"] is NSNull else { continue }
            let observation: Observation
            let authority: String
            if let value = items[i]["rotation"] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
               value.doubleValue.isFinite, abs(value.doubleValue) <= maximumAngle,
               abs(value.doubleValue) > 1e-6 {
                observation = Observation(radians: value.doubleValue, members: 0, agreeingMembers: 0)
                authority = "explicit-source-layout-radians"
            } else {
                if let measured = estimate(items[i]["sourceMemberPolygons"]), measured.radians != 0 {
                    observation = measured; authority = "original-member-quad-long-edge-consensus"
                } else {
                    let absent=items[i]["sourceMemberPolygons"] == nil || items[i]["sourceMemberPolygons"] is NSNull ||
                        (items[i]["sourceMemberPolygons"] as? [[[Double]]])?.isEmpty == true
                    guard absent,let measured=pixelObservation?(items[i],guide)else{continue}
                    guide["sourceRotationRadians"]=measured.radians
                    if permitsOrientedAnchor(items[i]),let point=anchor(measured.orientedBounds,
                        angle:measured.radians,size:measured.sourceSize,guide:guide) {
                        guide["rotationAnchorNormalized"]=point
                    }
                    result[i]["textPlacementGuide"]=guide
                    result[i]["sourceRotationObservation"]=["radians":measured.radians,
                        "authority":"source-mask-paint-palette-projection","sourceOnly":true,
                        "sourcePolygonsModified":false,"maskRestricted":true,"samples":measured.samples,
                        "gain":measured.gain,"shoulderRatio":measured.shoulderRatio]
                    continue
                }
            }
            guide["sourceRotationRadians"] = observation.radians
            if permitsOrientedAnchor(items[i]),let size=pageSize,
               let polygons=items[i]["sourceMemberPolygons"]as?[[[Double]]],!polygons.isEmpty {
                let points=polygons.flatMap {$0}
                if !points.isEmpty,points.allSatisfy({$0.count==2 && $0.allSatisfy(\.isFinite)}) {
                    let c=cos(observation.radians),s=sin(observation.radians)
                    let along=points.map {$0[0]*c+$0[1]*s},normal=points.map {-$0[0]*s+$0[1]*c}
                    if let point=anchor([along.min()!,normal.min()!,along.max()!,normal.max()!],
                        angle:observation.radians,size:size,guide:guide) {guide["rotationAnchorNormalized"]=point}
                }
            }
            result[i]["textPlacementGuide"] = guide
            result[i]["sourceRotationObservation"] = ["radians": observation.radians,
                "members": observation.members, "agreeingMembers": observation.agreeingMembers,
                "authority": authority, "sourceOnly": true, "sourcePolygonsModified": false]
        }
        return result
    }
}
