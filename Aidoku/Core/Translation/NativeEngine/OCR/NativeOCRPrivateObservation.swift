import Foundation
import CoreGraphics

/// PROPOSAL ONLY: add `var privateObservation: NativeOCRPrivateObservation.Retained?`
/// to Measurement. At the EXISTING privatePoints.append site, use the SAME
/// Float-rounded local point and call State.append below while frame is available.
/// Keep privatePoints/privateHull/privateSamples/guardPoints unchanged.
/// No source identity, private-cell ownership, provenance or suppression is changed.
@available(iOS 18.0, *)
enum NativeOCRPrivateObservation {
    struct RGBBin {
        var count = 0
        // Only within-bin channel offsets0...7, enough for exact median RGB.
        var channelCounts = [Int](repeating: 0, count: 24)
        mutating func append(_ rgb: SIMD4<UInt8>) {
            count += 1
            for channel in 0..<3 { channelCounts[channel * 8 + Int(rgb[channel] % 8)] += 1 }
        }
        func median(_ channel: Int, base: Int) -> Int {
            func value(at rank: Int) -> Int {
                var cumulative = 0
                for offset in 0..<8 {
                    cumulative += channelCounts[channel * 8 + offset]
                    if cumulative > rank { return base + offset }
                }
                return base + 7
            }
            if count % 2 == 1 { return value(at: count / 2) }
            let a = value(at: count / 2 - 1), b = value(at: count / 2)
            return Int((Double(a + b) / 2).rounded(.toNearestOrEven))
        }
    }
    /// Minimal immutable Measurement payload. The histogram contains only the
    /// top16 repeated8-wide private RGB bins needed by the frozen guard, with
    /// counts and exact diagnostic medians. No private-point or sample arrays.
    struct Retained {
        let moments: NativeOCRResidualPrivatePCAEnvelopeFringe.PrivateMoments
        let privateRGBSamples: Int
        let missingPrivateRGBPixels: Int
        let palettes: [NativeOCRResidualTurningStrokeGuardHistogram.Palette]
        var footprint: NativeOCRDensePrivateFootprintGuard.Footprint? = nil
    }
    /// Temporary accumulator while native privatePoints are still alive.
    struct State {
        var moments = NativeOCRResidualPrivatePCAEnvelopeFringe.PrivateMoments()
        private(set) var privateRGBSamples = 0
        private(set) var bins: [Int: RGBBin] = [:]
        private(set) var missingPrivateRGBPixels = 0

        /// Called once per accepted Float-rounded native local privatePoint.
        /// pixelRGBA MUST fetch the unresized original frame's integer pixel.
        /// Restoring the rounded local point matches the authenticated fixtures;
        /// never substitute hull vertices, filled hull pixels or guardHull corners.
        mutating func append(
            floatRoundedLocal point: CGPoint, origin: CGPoint,
            normal: CGPoint, along: CGPoint,
            pixelRGBA: (Int, Int) -> SIMD4<UInt8>?
        ) {
            let p = CGPoint(x: CGFloat(Float(point.x)), y: CGFloat(Float(point.y)))
            moments.append(p)
            let world = CGPoint(x: origin.x + p.x * normal.x + p.y * along.x,
                                y: origin.y + p.x * normal.y + p.y * along.y)
            let x = floor(world.x + 1e-7), y = floor(world.y + 1e-7)
            guard x.isFinite, y.isFinite,
                  x >= Double(Int.min), x < Double(Int.max), y >= Double(Int.min), y < Double(Int.max),
                  let rgba = pixelRGBA(Int(x), Int(y)) else {
                missingPrivateRGBPixels += 1; return
            }
            guard rgba.w == 255 else { return }
            let code = Int(rgba.x / 8) * 1024 + Int(rgba.y / 8) * 32 + Int(rgba.z / 8)
            bins[code, default: RGBBin()].append(rgba)
            privateRGBSamples += 1
        }
        var retained: Retained {
            .init(moments: moments, privateRGBSamples: privateRGBSamples,
                  missingPrivateRGBPixels: missingPrivateRGBPixels, palettes: palettes)
        }
        var palettes: [NativeOCRResidualTurningStrokeGuardHistogram.Palette] {
            let order = bins.keys.sorted {
                let a = bins[$0]!.count, b = bins[$1]!.count
                return a == b ? $0 < $1 : a > b
            }
            var result: [NativeOCRResidualTurningStrokeGuardHistogram.Palette] = []
            for code in order {
                let bin = bins[code]!
                if bin.count < 3 { break }
                let base = [code / 1024 * 8, (code / 32) % 32 * 8, code % 32 * 8]
                result.append(.init(rgb: (0..<3).map { bin.median($0, base: base[$0]) },
                                    sourceSeedBinCount: bin.count, bin: code))
                if result.count == 16 { break }
            }
            return result
        }
    }
}


/// Original-pixel observation only. Private-cell inventories are not modified.
@available(iOS 18.0, *)
enum NativeOCRDensePrivateFootprintGuard {
    struct Footprint {
        let width: Int
        let height: Int
        let scaleX: CGFloat
        let scaleY: CGFloat
        let cells: Set<Int>
        func contains(_ point: CGPoint) -> Bool {
            guard scaleX.isFinite, scaleY.isFinite, scaleX > 0, scaleY > 0,
                  point.x.isFinite, point.y.isFinite else { return false }
            let xx=floor(point.x/scaleX+1e-7), yy=floor(point.y/scaleY+1e-7)
            guard xx >= 0, xx < CGFloat(width), yy >= 0, yy < CGFloat(height) else { return false }
            return cells.contains(Int(yy)*width+Int(xx))
        }
    }
    struct RGBA {
        let bytes: [UInt8]
        let width: Int
        let height: Int
        let stride: Int
        let origin: CGPoint
    }
    struct Witness: Codable {
        let colour: [Int]
        let sourceObservedPixels: Int
        let componentPixels: Int
        let deepLossPixels: Int
        let deepLost2x2: Int
        let erodedCoreDeepLoss: Int
        let erodedCoreDeep2x2: Int
        let partialVeto: Bool
        let relativeDeepLossFraction: Double
        let oldSourceSupportFraction: Double
        let sourceSupportedOldPixels: Int
        let oldComponentPixels: Int
        let insufficientSupportForLargeLoss: Bool
        let coreVeto: Bool
        let normalSpan: Double
        let alongSpan: Double
        let fill: Double
        let sourceBounds: [Double]
    }
    struct Result: Codable {
        let decision: String
        let palettes: [[Int]]
        let privateDenseContrastSamples: Int
        let denseSourcePixels: Int
        let witnesses: [Witness]
    }
    static func assess(old: [CGPoint], proposed: [CGPoint], rgba: RGBA,
                       footprints: [Footprint], origin: CGPoint, normal: CGPoint,
                       along: CGPoint, sourceWidth: CGFloat) -> Result {
        func result(_ decision: String, _ palettes: [[Int]] = [], _ samples: Int = 0,
                    _ dense: Int = 0, _ witnesses: [Witness] = []) -> Result {
            .init(decision:decision,palettes:palettes,privateDenseContrastSamples:samples,
                  denseSourcePixels:dense,witnesses:witnesses)
        }
        let w=rgba.width,h=rgba.height,stride=rgba.stride
        guard w > 0,h > 0,w <= Int.max/h,w <= Int.max/4,stride >= w*4,h <= Int.max/stride,
              rgba.bytes.count >= h*stride, old.count==4,proposed.count==4,
              (old+proposed+[rgba.origin,origin,normal,along]).allSatisfy({$0.x.isFinite && $0.y.isFinite}),
              sourceWidth.isFinite,sourceWidth > 0 else { return result("uncertain") }
        let size=w*h
        func contains(_ q:[CGPoint],_ p:CGPoint)->Bool {
            var positive=true,negative=true
            for i in 0..<4 {
                let a=q[i],b=q[(i+1)%4],c=(b.x-a.x)*(p.y-a.y)-(b.y-a.y)*(p.x-a.x)
                positive=positive && c >= -1e-7;negative=negative && c <= 1e-7
            }
            return positive || negative
        }
        func distanceSquared(_ p:CGPoint)->CGFloat {
            if contains(proposed,p) { return 0 }
            var best=CGFloat.infinity
            for i in 0..<4 {
                let a=proposed[i],b=proposed[(i+1)%4],dx=b.x-a.x,dy=b.y-a.y,length=dx*dx+dy*dy
                let t=length > 0 ? max(0,min(1,((p.x-a.x)*dx+(p.y-a.y)*dy)/length)) : 0
                let x=p.x-a.x-t*dx,y=p.y-a.y-t*dy
                best=min(best,x*x+y*y)
            }
            return best
        }
        func world(_ p:Int)->CGPoint { .init(x:rgba.origin.x+CGFloat(p%w)+0.5,y:rgba.origin.y+CGFloat(p/w)+0.5) }
        func channel(_ x:Int,_ y:Int,_ c:Int)->Int { Int(rgba.bytes[y*stride+x*4+c]) }
        func reflected(_ i:Int,_ count:Int)->Int { count <= 1 ? 0 : i < 0 ? -i : i >= count ? 2*count-i-2 : i }
        var edge=[Bool](repeating:false,count:size)
        for y in 0..<h { for x in 0..<w {
            let xm=reflected(x-1,w),xp=reflected(x+1,w),ym=reflected(y-1,h),yp=reflected(y+1,h)
            for c in 0..<3 {
                let a=channel(xm,ym,c),b=channel(x,ym,c),d=channel(xp,ym,c)
                let e=channel(xm,y,c),f=channel(xp,y,c),g=channel(xm,yp,c)
                let hh=channel(x,yp,c),j=channel(xp,yp,c)
                if max(abs(-a+d-2*e+2*f-g+j),abs(-a-2*b-d+g+2*hh+j)) > 144 { edge[y*w+x]=true;break }
            }
        }}
        var observed=[Bool](repeating:false,count:size),deep=observed
        var oldMask=observed, oldSourceMask=observed
        var histogram=[Int](repeating:0,count:512),sampleCount=0,denseCount=0
        for y in 0..<h { for x in 0..<w {
            let p=y*w+x,point=world(p),oldInside=contains(old,point)
            oldMask[p]=oldInside
            oldSourceMask[p]=oldInside && footprints.contains(where:{$0.contains(point)})
            deep[p]=oldInside && distanceSquared(point)>1+1e-7
            guard oldInside,footprints.contains(where:{$0.contains(point)}) else { continue }
            denseCount += 1
            var near=false
            for yy in max(0,y-1)...min(h-1,y+1) {
                for xx in max(0,x-1)...min(w-1,x+1) where edge[yy*w+xx] { near=true }
            }
            guard near,rgba.bytes[y*stride+x*4+3]==255 else { continue }
            observed[p]=true;sampleCount += 1
            histogram[channel(x,y,0)/32*64+channel(x,y,1)/32*8+channel(x,y,2)/32] += 1
        }}
        guard sampleCount >= 4 else { return result("uncertain",[],sampleCount,denseCount) }
        var palettes:[[Int]]=[]
        for code in (0..<512).sorted(by:{ histogram[$0]==histogram[$1] ? $0 < $1 : histogram[$0] > histogram[$1] }) {
            if histogram[code] < 3 { break }
            let colour=[code/64*32+16,(code/8)%8*32+16,code%8*32+16]
            if palettes.allSatisfy({ c in zip(c,colour).map{abs($0-$1)}.max()! > 40 }) { palettes.append(colour) }
            if palettes.count==6 { break }
        }
        var witnesses:[Witness]=[]
        var weakSupportLoss=false
        for colour in palettes {
            var mask=[UInt8](repeating:0,count:size)
            for y in 0..<h { for x in 0..<w {
                if rgba.bytes[y*stride+x*4+3]==255 && (0..<3).allSatisfy({abs(channel(x,y,$0)-colour[$0])<=24}) { mask[y*w+x]=1 }
            }}
            var queue:[Int]=[]
            for seed in 0..<size where mask[seed] != 0 {
                queue.removeAll(keepingCapacity:true);queue.append(seed);mask[seed]=0
                var cursor=0,x0=w,y0=h,x1=0,y1=0,sourceCount=0
                var open=false,lost:[Int]=[]
                var n0=CGFloat.infinity,n1 = -CGFloat.infinity,a0=CGFloat.infinity,a1 = -CGFloat.infinity
                while cursor < queue.count {
                    let p=queue[cursor];cursor += 1;let x=p%w,y=p/w
                    x0=min(x0,x);x1=max(x1,x);y0=min(y0,y);y1=max(y1,y)
                    open=open || x==0 || x==w-1 || y==0 || y==h-1
                    if observed[p] { sourceCount += 1 };if deep[p] { lost.append(p) }
                    let point=world(p),px=point.x-origin.x,py=point.y-origin.y
                    let nn=px*normal.x+py*normal.y,aa=px*along.x+py*along.y
                    n0=min(n0,nn);n1=max(n1,nn);a0=min(a0,aa);a1=max(a1,aa)
                    for yy in max(0,y-1)...min(h-1,y+1) { for xx in max(0,x-1)...min(w-1,x+1) {
                        let next=yy*w+xx
                        if mask[next] != 0 { mask[next]=0;queue.append(next) }
                    }}
                }
                guard !open,sourceCount > 0,queue.count >= 4,lost.count >= 4 else { continue }
                let ns=n1-n0+1,als=a1-a0+1,cw=x1-x0+1,ch=y1-y0+1
                let fill=Double(queue.count)/Double(cw*ch)
                guard ns<=1.7*sourceWidth,als<=2.2*sourceWidth,fill>=0.08,
                      !(fill>0.88 && CGFloat(queue.count)>0.35*sourceWidth*sourceWidth && CGFloat(min(cw,ch))>0.4*sourceWidth) else { continue }
                let members=Set(queue),lostSet=Set(lost)
                func squares(_ set:Set<Int>)->Int {
                    set.reduce(0) { count,p in count + (p%w<w-1 && p/w<h-1 && set.contains(p+1) && set.contains(p+w) && set.contains(p+w+1) ? 1 : 0) }
                }
                let coreLost=Set(lost.filter { p in
                    let x=p%w,y=p/w
                    guard x>0,x<w-1,y>0,y<h-1 else { return false }
                    return (-1...1).allSatisfy{dy in (-1...1).allSatisfy{dx in members.contains(p+dy*w+dx)}}
                })
                let blocks=squares(lostSet),coreBlocks=squares(coreLost)
                let oldCount=queue.reduce(0){$0 + (oldMask[$1] ? 1 : 0)}
                let sourceOldCount=queue.reduce(0){$0 + (oldSourceMask[$1] ? 1 : 0)}
                let deepFraction=Double(lost.count)/Double(max(1,oldCount))
                let supportFraction=Double(sourceOldCount)/Double(max(1,oldCount))
                let substantialFraction=blocks>0 && deepFraction>=0.10
                let relativeVeto=substantialFraction && supportFraction>=0.10
                let insufficientSupport=substantialFraction && supportFraction<0.10
                weakSupportLoss = weakSupportLoss || insufficientSupport
                witnesses.append(.init(colour:colour,sourceObservedPixels:sourceCount,componentPixels:queue.count,
                    deepLossPixels:lost.count,deepLost2x2:blocks,erodedCoreDeepLoss:coreLost.count,
                    erodedCoreDeep2x2:coreBlocks,partialVeto:relativeVeto,
                    relativeDeepLossFraction:deepFraction,oldSourceSupportFraction:supportFraction,
                    sourceSupportedOldPixels:sourceOldCount,oldComponentPixels:oldCount,
                    insufficientSupportForLargeLoss:insufficientSupport,coreVeto:coreLost.count>=4 && coreBlocks>0,
                    normalSpan:Double(ns),alongSpan:Double(als),fill:fill,
                    sourceBounds:[Double(rgba.origin.x)+Double(x0),Double(rgba.origin.y)+Double(y0),
                                  Double(rgba.origin.x)+Double(x1+1),Double(rgba.origin.y)+Double(y1+1)]))
            }
        }
        return result(witnesses.contains(where:{$0.partialVeto}) ? "reject" : weakSupportLoss ? "uncertain" : "no-substantial-source-relative-loss-observed",
                      palettes,sampleCount,denseCount,witnesses)
    }
}
