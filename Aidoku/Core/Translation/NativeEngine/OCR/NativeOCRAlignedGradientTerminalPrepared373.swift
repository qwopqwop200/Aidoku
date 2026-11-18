import Foundation
import CoreGraphics

/// Explicit opt-in prepared GG. Default NativeOCRAlignedGradientTerminalGuard is UNCHANGED.
/// One immutable actual old/RGBA/palettes/basis/private membership session, sequential use.
/// Pure stable isPrivatePixel is sampled for opaque old pixels ONCE, never mutated.
@available(iOS 18.0, *)
enum NativeOCRAlignedGradientTerminalPrepared373 {
    typealias LocalRGBA=NativeOCRAlignedGradientTerminalGuard.LocalRGBA
    typealias Palette=NativeOCRAlignedGradientTerminalGuard.Palette
    typealias Witness=NativeOCRAlignedGradientTerminalGuard.Witness
    typealias Result=NativeOCRAlignedGradientTerminalGuard.Result
    private struct Component {
        var pixels: [Int]
        var open: Bool
        var bounds: [Double]
        var n0: Double
        var n1: Double
        var a0: Double
        var a1: Double
        var oldCount: Int
        var newCount: Int
        var oldCore: Int
        var newCore: Int
        var privateRetained: Int
        var minorVariance: Double
    }
    private struct SourceData {
        let rgb:[[Double]]
        let opaque:[Bool],oldInside:[Bool],privateOld:[Bool]
        let np:[Double],ap:[Double]
        let nearEdge:[Bool]
    }
    private struct StaticComponent {let component:Component;let privateEndpoints:[Int]}
    private struct PairKey:Hashable {let foreground:[Int];let background:[Int]}
    private struct RayData {let core:[Bool];let components:[StaticComponent];let estimatedBytes:Int}
    struct Statistics:Codable {
        let sourcePreparations:Int,rayBuilds:Int,rayCacheHits:Int,rayCacheEntries:Int
        let estimatedCachedPayloadBytes:Int,uncachedRayBuildsDueToBudget:Int
    }
    final class Prepared {
        private let oldValue:[CGPoint],rgbaValue:LocalRGBA,authenticatedPalettesValue:[Palette]
        private let frameOriginValue:CGPoint,normalValue:CGPoint,alongValue:CGPoint,sourceWidthValue:Double
        private let privatePixel:(Int,Int)->Bool
        private let maximumCachedPayloadBytes:Int
        private var source:SourceData?
        private var rays:[PairKey:RayData]=[:]
        private var sourcePreparations=0,rayBuilds=0,rayCacheHits=0,cachedBytes=0,uncachedBuilds=0
        init(old:[CGPoint],rgba:LocalRGBA,authenticatedPalettes:[Palette],frameOrigin:CGPoint,
             normal:CGPoint,along:CGPoint,sourceWidth:Double,maximumCachedPayloadBytes:Int=32*1024*1024,
             isPrivatePixel:@escaping (Int,Int)->Bool) {
            self.oldValue=old;self.rgbaValue=rgba;self.authenticatedPalettesValue=authenticatedPalettes
            self.frameOriginValue=frameOrigin;self.normalValue=normal;self.alongValue=along;self.sourceWidthValue=sourceWidth
            self.maximumCachedPayloadBytes=max(0,maximumCachedPayloadBytes);self.privatePixel=isPrivatePixel
        }
        var statistics:Statistics {
            .init(sourcePreparations:sourcePreparations,rayBuilds:rayBuilds,rayCacheHits:rayCacheHits,rayCacheEntries:rays.count,
                  estimatedCachedPayloadBytes:cachedBytes,uncachedRayBuildsDueToBudget:uncachedBuilds)
        }
        func assess(new:[CGPoint],includeMasks:Bool=false)->Result {
            let old=oldValue,rgba=rgbaValue,authenticatedPalettes=authenticatedPalettesValue
            let frameOrigin=frameOriginValue,normal=normalValue,along=alongValue,sourceWidth=sourceWidthValue
            let isPrivatePixel=privatePixel
        func result(_ decision: String, _ witnesses: [Witness] = [], _ pairs: Int = 0,
                    _ bodies: Int = 0, _ bm: [UInt8]? = nil, _ tm: [UInt8]? = nil) -> Result {
            .init(decision: decision, witnesses: witnesses, examinedPairs: pairs,
                  authenticatedBodies: bodies, bodyMask: bm, terminalMask: tm,
                  noVetoIsNotAdmission: true, ownershipMutated: false)
        }
        let w = rgba.width, h = rgba.height, stride = rgba.bytesPerRow
        let finite = old + new + [rgba.origin, frameOrigin, normal, along]
        guard w > 0, h > 0, w <= 600_000 / h, w <= Int.max / 4,
              stride >= w * 4, h <= Int.max / stride, rgba.bytes.count >= h * stride,
              old.count == 4, new.count == 4, sourceWidth.isFinite, sourceWidth > 0,
              finite.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              abs(hypot(normal.x, normal.y) - 1) < 0.01,
              abs(hypot(along.x, along.y) - 1) < 0.01,
              abs(normal.x * along.x + normal.y * along.y) < 0.01 else {
            return result("uncertain-invalid-source-input")
        }
        guard old.allSatisfy({ $0.x >= rgba.origin.x && $0.y >= rgba.origin.y &&
            $0.x <= rgba.origin.x + Double(w) && $0.y <= rgba.origin.y + Double(h) }) else {
            return result("uncertain-inherited-source-not-observed")
        }
        func contains(_ q: [CGPoint], _ p: CGPoint) -> Bool {
            var positive = false, negative = false
            for i in 0..<q.count {
                let a = q[i], b = q[(i + 1) % q.count]
                let c = (b.x-a.x)*(p.y-a.y) - (b.y-a.y)*(p.x-a.x)
                if c > 1e-7 { positive = true }; if c < -1e-7 { negative = true }
            }
            return !positive || !negative
        }
        func distance(_ q: [CGPoint], _ p: CGPoint) -> Double {
            if contains(q, p) { return 0 }
            var value = Double.infinity
            for i in 0..<q.count {
                let a = q[i], b = q[(i+1)%q.count], dx = b.x-a.x, dy = b.y-a.y
                let length = dx*dx + dy*dy
                let t = length > 0 ? max(0, min(1, ((p.x-a.x)*dx+(p.y-a.y)*dy)/length)) : 0
                value = min(value, hypot(p.x-a.x-t*dx, p.y-a.y-t*dy))
            }
            return value
        }
        if source == nil {
        let count = w*h
        var rgb = [[Double]](repeating: [], count: count)
        var opaque = [Bool](repeating: false, count: count)
        var oldInside = opaque, privateOld = opaque
        var np = [Double](repeating: 0, count: count), ap = np
        for p in 0..<count {
            let x = p%w, y = p/w, offset = y*stride+x*4
            opaque[p] = rgba.bytes[offset+3] == 255
            rgb[p] = (0..<3).map { Double(rgba.bytes[offset+$0]) }
            let point = CGPoint(x: rgba.origin.x+Double(x)+0.5, y: rgba.origin.y+Double(y)+0.5)
            oldInside[p] = contains(old, point)
            let dx = point.x-frameOrigin.x, dy = point.y-frameOrigin.y
            np[p] = dx*normal.x+dy*normal.y; ap[p] = dx*along.x+dy*along.y
            privateOld[p] = opaque[p] && oldInside[p] &&
                isPrivatePixel(Int(floor(point.x+1e-7)), Int(floor(point.y+1e-7)))
        }
        // Retained8 bins can contain only background when a tiny gradient stem
        // spreads its real colours over many bins. Re-observe endpoint colours
        // ONLY on original, private, old+new-retained source-contrast pixels.
        // Binning learns palette anchors; CC segmentation below remains a RGB ray.
        var edge = [Bool](repeating: false, count: count)
        if w >= 3 && h >= 3 {
            for y in 1..<(h-1) { for x in 1..<(w-1) {
                let p = y*w+x
                for c in 0..<3 {
                    let a=rgb[p-w-1][c],b=rgb[p-w][c],d=rgb[p-w+1][c]
                    let e=rgb[p-1][c],f=rgb[p+1][c]
                    let g=rgb[p+w-1][c],h=rgb[p+w][c],j=rgb[p+w+1][c]
                    if max(abs(-a+d-2*e+2*f-g+j),abs(-a-2*b-d+g+2*h+j)) > 144 {
                        edge[p] = true; break
                    }
                }
            }}
        }
        var nearEdge = [Bool](repeating:false,count:count)
        for p in 0..<count where privateOld[p] {
            let x=p%w,y=p/w
            nearEdge[p] = (max(0,y-1)...min(h-1,y+1)).contains { yy in
                (max(0,x-1)...min(w-1,x+1)).contains { xx in edge[yy*w+xx] }
            }
        }
        source = SourceData(rgb:rgb,opaque:opaque,oldInside:oldInside,privateOld:privateOld,np:np,ap:ap,nearEdge:nearEdge)
        sourcePreparations += 1
        }
        let data=source!,count=w*h
        let rgb=data.rgb,opaque=data.opaque,oldInside=data.oldInside,np=data.np,ap=data.ap
        var newInside=[Bool](repeating:false,count:count),privateRetained=newInside
        var outside=[Double](repeating:0,count:count)
        for p in 0..<count {
            let point=CGPoint(x:rgba.origin.x+Double(p%w)+0.5,y:rgba.origin.y+Double(p/w)+0.5)
            newInside[p]=contains(new,point)
            privateRetained[p]=data.privateOld[p] && newInside[p]
            outside[p]=oldInside[p] && !newInside[p] ? distance(new,point):0
        }
        var palettes = authenticatedPalettes.filter {
            $0.rgb.count == 3 && $0.sourceSeedBinCount >= 3 && $0.rgb.allSatisfy({ (0...255).contains($0) })
        }
        var endpointBins: [Int: [Int]] = [:]
        for p in 0..<count where privateRetained[p] {
            guard data.nearEdge[p] else { continue }
            let code = Int(rgb[p][0])/32*64+Int(rgb[p][1])/32*8+Int(rgb[p][2])/32
            endpointBins[code,default:[]].append(p)
        }
        let endpointOrder = endpointBins.keys.sorted {
            endpointBins[$0]!.count == endpointBins[$1]!.count ? $0 < $1 : endpointBins[$0]!.count > endpointBins[$1]!.count
        }
        for code in endpointOrder.prefix(16) {
            let pixels=endpointBins[code]!
            guard pixels.count >= 3 else { continue }
            let colour = (0..<3).map { c -> Int in
                let sorted=pixels.map { rgb[$0][c] }.sorted(), middle=sorted.count/2
                let median=sorted.count%2==0 ? (sorted[middle-1]+sorted[middle])/2 : sorted[middle]
                return Int(median.rounded(.toNearestOrEven))
            }
            if !palettes.contains(where: { $0.rgb == colour }) {
                palettes.append(.init(rgb:colour,sourceSeedBinCount:pixels.count,bin:code))
            }
        }
        var pairs: [(Int, Int, Double, Int)] = []
        for i in palettes.indices { for j in palettes.indices where i != j {
            let d = zip(palettes[i].rgb, palettes[j].rgb).map { Double($0-$1) }
            let contrast = sqrt(d.reduce(0) { $0+$1*$1 })
            if contrast >= 64 { pairs.append((i,j,contrast,min(palettes[i].sourceSeedBinCount,palettes[j].sourceSeedBinCount))) }
        }}
        pairs.sort { $0.3 == $1.3 ? ($0.2 == $1.2 ? ($0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0) : $0.2 > $1.2) : $0.3 > $1.3 }
        var examined = 0, bodyCount = 0
        var bodyMask = [UInt8](repeating: 0, count: includeMasks ? count : 0)
        var terminalMask = bodyMask
        for pair in pairs.prefix(32) {
            let foreground = palettes[pair.0].rgb, background = palettes[pair.1].rgb
            // Do not promote an intermediate AA shade into a body endpoint when
            // a stronger authenticated endpoint explains the same colour ray.
            // This only removes candidate colour pairs; pixel tolerance stays0.1.
            let intermediate = palettes.indices.contains { k in
                guard k != pair.0 && k != pair.1,
                      palettes[k].sourceSeedBinCount >= palettes[pair.0].sourceSeedBinCount else { return false }
                let ray = (0..<3).map { Double(palettes[k].rgb[$0]-background[$0]) }
                let length2 = ray.reduce(0) { $0+$1*$1 }, length = sqrt(length2)
                guard length > pair.2*1.15 else { return false }
                let t = (0..<3).reduce(0.0) { $0+Double(foreground[$1]-background[$1])*ray[$1] }/length2
                guard t >= 0.2 && t <= 0.95 else { return false }
                let error = (0..<3).map { abs(Double(foreground[$0]-background[$0])-t*ray[$0]) }.max()!
                return error <= max(16,length*0.15)
            }
            if intermediate { continue }
            examined += 1
            let preparedRay=rayFor(foreground:foreground,background:background,contrast:pair.2,data:data)
            let core=preparedRay.core
            let components=preparedRay.components.map { cached -> Component in
                var c=cached.component
                var nc=0,ncore=0
                for p in c.pixels where newInside[p] { nc+=1;if core[p] {ncore+=1} }
                c.newCount=nc;c.newCore=ncore
                c.privateRetained=cached.privateEndpoints.filter {newInside[$0]}.count
                return c
            }
            let bodies = components.filter { !$0.open && $0.privateRetained >= 4 &&
                $0.n1-$0.n0+1 <= 1.7*sourceWidth && $0.a1-$0.a0+1 <= 2.2*sourceWidth }
            bodyCount += bodies.count
            if includeMasks { for body in bodies { for p in body.pixels { bodyMask[p] = 255 } } }
            guard !bodies.isEmpty else { continue }
            for terminal in components where !terminal.open && terminal.oldCore >= 4 &&
                terminal.n1-terminal.n0+1 <= max(4,0.8*sourceWidth) &&
                terminal.a1-terminal.a0+1 <= max(4,0.8*sourceWidth) && terminal.minorVariance >= 0.15 {
                let terminalFill = Double(terminal.pixels.count)/((terminal.bounds[2]-terminal.bounds[0])*(terminal.bounds[3]-terminal.bounds[1]))
                let fullCore = Set(terminal.pixels.filter { core[$0] })
                let solidCore = fullCore.contains { p in
                    p%w < w-1 && p/w < h-1 && fullCore.contains(p+1) && fullCore.contains(p+w) && fullCore.contains(p+w+1)
                }
                guard terminalFill >= 0.35, solidCore else { continue }
                let lostCore = terminal.pixels.filter { core[$0] && oldInside[$0] && !newInside[$0] }.count
                let fraction = Double(lostCore)/Double(terminal.oldCore)
                var lost2x2 = 0
                let membership = Set(terminal.pixels.filter { oldInside[$0] && !newInside[$0] && outside[$0] > 1+1e-7 })
                for p in membership where p%w < w-1 && p/w < h-1 {
                    if membership.contains(p+1) && membership.contains(p+w) && membership.contains(p+w+1) { lost2x2 += 1 }
                }
                let wholeLoss = terminal.newCount == 0 && terminal.oldCount >= 4 && lost2x2 > 0
                let partialLoss = lostCore >= 2 && fraction >= 0.15
                guard wholeLoss || partialLoss else { continue }
                for body in bodies {
                    let overlap = max(0,min(terminal.n1,body.n1)-max(terminal.n0,body.n0)+1)
                    let minimumWidth = min(terminal.n1-terminal.n0+1,body.n1-body.n0+1)
                    let centerOffset = abs((terminal.n0+terminal.n1-body.n0-body.n1)/2)
                    let gap = max(0,terminal.a0-body.a1-1,body.a0-terminal.a1-1)
                    let outsideBody = (terminal.a0+terminal.a1)/2 < body.a0 || (terminal.a0+terminal.a1)/2 > body.a1
                    guard outsideBody, overlap >= 0.4*minimumWidth,
                          centerOffset <= max(1,sourceWidth*0.35), gap <= 1.5*sourceWidth else { continue }
                    let actual = body.pixels.filter { privateRetained[$0] && core[$0] }
                    var low = [255,255,255], high = [0,0,0]
                    for p in actual { for c in 0..<3 { low[c] = min(low[c],Int(rgb[p][c])); high[c] = max(high[c],Int(rgb[p][c])) } }
                    if includeMasks { for p in terminal.pixels { terminalMask[p] = 255 } }
                    let witness = Witness(foreground:foreground,background:background,contrast:pair.2,
                        terminalBounds:terminal.bounds,terminalPixels:terminal.pixels.count,
                        oldIncluded:terminal.oldCount,newIncluded:terminal.newCount,
                        oldCore:terminal.oldCore,newCore:terminal.newCore,lostCore:lostCore,
                        oldCoreLossFraction:fraction,lost2x2:lost2x2,terminalMinorVariance:terminal.minorVariance,
                        bodyBounds:body.bounds,retainedAuthenticBodyPixels:body.privateRetained,
                        bodyRGBMin:low,bodyRGBMax:high,normalOverlap:overlap,alongGap:gap,
                        reason:wholeLoss ? "whole-qualified-aligned-gradient-terminal-lost" : "partial-qualified-terminal-core-loss")
                    return result("reject",[witness],examined,bodyCount,includeMasks ? bodyMask:nil,includeMasks ? terminalMask:nil)
                }
            }
        }
        return result("no-qualified-terminal-loss-observed",[],examined,bodyCount,
                      includeMasks ? bodyMask:nil,includeMasks ? terminalMask:nil)
        }
        private func rayFor(foreground:[Int],background:[Int],contrast:Double,data:SourceData)->RayData {
            let key=PairKey(foreground:foreground,background:background)
            if let cached=rays[key] {rayCacheHits+=1;return cached}
            rayBuilds+=1
            let rgba=rgbaValue,w=rgba.width,h=rgba.height,count=w*h
            let rgb=data.rgb,opaque=data.opaque,np=data.np,ap=data.ap,oldInside=data.oldInside
            let delta = zip(foreground,background).map { Double($0-$1) }
            let squared = contrast*contrast, tolerance = max(12, contrast*0.1)
            // A line-compatible AA shard is not an authenticated body endpoint.
            // Require actual retained private pixels near the foreground endpoint.
            let endpointTolerance = max(16, contrast*0.05)
            var mask = [Bool](repeating: false, count: count), core = mask
            for p in 0..<count where opaque[p] {
                var t = 0.0
                for c in 0..<3 { t += (rgb[p][c]-Double(background[c]))*delta[c] }
                t /= squared
                guard t >= 0.25 && t <= 1.6 else { continue }
                var residual = 0.0
                for c in 0..<3 { residual = max(residual, abs(rgb[p][c]-Double(background[c])-t*delta[c])) }
                if residual <= tolerance { mask[p] = true; core[p] = t >= 0.45 }
            }
            var seen = [Bool](repeating: false, count: count), components: [StaticComponent] = []
            for seed in 0..<count where mask[seed] && !seen[seed] {
                var queue = [seed], cursor = 0, open = false, x0 = w, y0 = h, x1 = 0, y1 = 0
                var n0 = Double.infinity, n1 = -Double.infinity, a0 = n0, a1 = n1
                var oc = 0, ocore = 0, pr = 0
                seen[seed] = true
                while cursor < queue.count {
                    let p = queue[cursor]; cursor += 1; let x = p%w, y = p/w
                    x0 = min(x0,x); x1 = max(x1,x); y0 = min(y0,y); y1 = max(y1,y)
                    open = open || x == 0 || y == 0 || x == w-1 || y == h-1
                    n0 = min(n0,np[p]); n1 = max(n1,np[p]); a0 = min(a0,ap[p]); a1 = max(a1,ap[p])
                    if oldInside[p] { oc += 1; if core[p] { ocore += 1 } }
                    if data.privateOld[p] && core[p] {
                        let error = (0..<3).map { abs(rgb[p][$0]-Double(foreground[$0])) }.max()!
                        if error <= endpointTolerance { pr += 1 }
                    }
                    for yy in max(0,y-1)...min(h-1,y+1) { for xx in max(0,x-1)...min(w-1,x+1) {
                        let next = yy*w+xx
                        if mask[next] && !seen[next] { seen[next] = true; queue.append(next) }
                    }}
                }
                let meanN = queue.reduce(0.0) { $0+np[$1] }/Double(queue.count)
                let meanA = queue.reduce(0.0) { $0+ap[$1] }/Double(queue.count)
                var xx = 0.0, xy = 0.0, yy = 0.0
                for p in queue { let n=np[p]-meanN, a=ap[p]-meanA; xx += n*n; xy += n*a; yy += a*a }
                let denominator = Double(queue.count); xx /= denominator; xy /= denominator; yy /= denominator
                let minor = max(0,(xx+yy-hypot(xx-yy,2*xy))/2)
                let component=Component(pixels:queue,open:open,
                    bounds:[rgba.origin.x+Double(x0),rgba.origin.y+Double(y0),rgba.origin.x+Double(x1+1),rgba.origin.y+Double(y1+1)],
                    n0:n0,n1:n1,a0:a0,a1:a1,oldCount:oc,newCount:0,oldCore:ocore,newCore:0,
                    privateRetained:pr,minorVariance:minor)
                let endpoints=queue.filter { p in
                    guard data.privateOld[p] && core[p] else{return false}
                    let error=(0..<3).map {abs(rgb[p][$0]-Double(foreground[$0]))}.max()!
                    return error<=endpointTolerance
                }
                components.append(.init(component:component,privateEndpoints:endpoints))
            }

            let estimate=core.count+components.reduce(0){$0+$1.component.pixels.count*MemoryLayout<Int>.stride+$1.privateEndpoints.count*MemoryLayout<Int>.stride+256}
            let built=RayData(core:core,components:components,estimatedBytes:estimate)
            // Budget only changes reuse, NEVER decisions/abstention. Uncached rays still
            // execute exactly; dynamic endpoint colours can create new source pair keys.
            if estimate<=maximumCachedPayloadBytes-cachedBytes {rays[key]=built;cachedBytes+=estimate}
            else {uncachedBuilds+=1}
            return built
        }
    }
}
