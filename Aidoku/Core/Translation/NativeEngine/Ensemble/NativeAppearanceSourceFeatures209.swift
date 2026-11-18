import CoreGraphics
import Foundation

/// source_appearance.extract + fused_source_appearance.extract, original grids.
/// 35 palette/topology features +174 RF/seg/OCR/geometry =209 per candidate.
enum NativeAppearanceSourceFeatures209 {
    static let version="source-palette-rf-seg-geometry-v2"
    struct Packet {
        let colors:[[Double]]
        var features:[[Float]]
        let pair:[[[Float]]]
        let fontPixels:Double
        let maskFraction:Double

        func role(_ role:String,fill:Int?=nil,outline:Int?=nil)->[[Float]] {
            features.indices.map { index in
                var row=features[index]
                if role=="outline",let fill {row += pair[fill][index]+features[fill]}
                else if role=="background",let fill,let outline {
                    row += pair[fill][index]+pair[outline][index]+features[fill]+features[outline]
                    row += [index==fill ? 1:0,index==outline ? 1:0]
                }
                return row
            }
        }
        func summary(fill:Int,outline:Int,background:Int)->[Float] {
            var result=features[fill]
            result += features[outline]
            result += features[background]
            result += pair[fill][outline]
            result += pair[fill][background]
            result += pair[outline][background]
            result.append(Float(maskFraction))
            return result
        }
    }
    enum Failure:Error {case emptyPalette,invalidImageOperation,invalidFeatureCount}

    static func palette(rgb:[UInt8],selection:[UInt8],limit:Int,ops:any NativeAppearanceImageOperations) throws -> [[Double]] {
        let selectedCount = selection.reduce(0) { $0 + ($1 != 0 ? 1 : 0) }
        let allPixels = selectedCount == 0
        let population = allPixels ? selection.count : selectedCount
        let step = max(1, population / 180_000)
        let sampledCount = (population + step - 1) / step
        // Scan in selected-pixel order; stride is not a source coordinate stride.
        func visitSamples(_ visit: (Int, Int) -> Void) {
            var skip = 0
            for p in selection.indices where allPixels || selection[p] != 0 {
                if skip > 0 { skip -= 1; continue }
                skip = step - 1
                let offset = p * 3
                let key = Int(rgb[offset] >> 4) * 256 + Int(rgb[offset + 1] >> 4) * 16 + Int(rgb[offset + 2] >> 4)
                visit(key, offset)
            }
        }
        var counts = [Int](repeating: 0, count: 4096)
        visitSamples { key, _ in counts[key] += 1 }
        let minimumCount = max(2, Double(sampledCount) * 0.0005)
        let order = NativeAppearanceNumeric.numpyArgSort(counts.map { -Double($0) })
            .prefix(64).prefix { Double(counts[$0]) >= minimumCount }
        var rank = [Int](repeating: -1, count: 4096)
        for (i, key) in order.enumerated() { rank[key] = i }
        // The quantization key fixes each channel's upper nibble. Only 16
        // attainable values per channel are needed to find the exact median.
        var histograms = [Int](repeating: 0, count: order.count * 48)
        if !order.isEmpty {
            visitSamples { key, offset in
                let i = rank[key]
                if i < 0 { return }
                let start = i * 48
                histograms[start + Int(rgb[offset] & 15)] += 1
                histograms[start + 16 + Int(rgb[offset + 1] & 15)] += 1
                histograms[start + 32 + Int(rgb[offset + 2] & 15)] += 1
            }
        }
        var groups: [(color: [Double], count: Int)] = []
        for (i, key) in order.enumerated() {
            let location = Double(counts[key] - 1) * 0.5
            let low = Int(floor(location)), high = Int(ceil(location)), fraction = location - Double(low)
            let bases = [key >> 8, (key >> 4) & 15, key & 15]
            let color = (0..<3).map { channel -> Double in
                var lower = -1, seen = 0
                let start = i * 48 + channel * 16
                for value in 0..<16 {
                    seen += histograms[start + value]
                    if lower < 0 && seen > low { lower = value }
                    if seen > high {
                        let base = bases[channel] * 16
                        return Double(base + lower) * (1 - fraction) + Double(base + value) * fraction
                    }
                }
                preconditionFailure("Palette histogram lost a counted pixel")
            }
            let candidate=try ops.lab(colors:[color])[0]
            var nearby:Int?
            for i in groups.indices {
                guard zip(groups[i].color,color).map({abs($0-$1)}).max()!<=23 else {continue}
                let prior=try ops.lab(colors:[groups[i].color])[0]
                if sqrt(zip(prior,candidate).reduce(Float(0)) {$0+($1.0-$1.1)*($1.0-$1.1)})<=6 {nearby=i;break}
            }
            if let index=nearby {
                let previous=groups[index],total=previous.count+counts[key]
                groups[index]=((0..<3).map {(previous.color[$0]*Double(previous.count)+color[$0]*Double(counts[key]))/Double(total)},total)
            } else if groups.count<limit {groups.append((color,counts[key]))}
        }
        return groups.map {$0.color.map {$0.rounded(.toNearestOrEven)}}
    }

    static func extract(_ input:SourceNativeInput,ops:any NativeAppearanceImageOperations) throws -> Packet {
        try input.validate()
        let measured = try extractPhysicalWithLabs(.init(width: input.width, height: input.height, rgb: input.rgb,
            ownMask: input.ownMask, fontPriorSourcePixels: input.fontPriorSourcePixels), ops: ops)
        var packet = measured.packet
        let mask = input.ownMask.map { $0 == 0 ? UInt8(0) : 1 }
        packet.features = try fused(input, packet: packet, mask: mask, labs: measured.labs, ops: ops)
        return packet
    }

    /// Original base35 equations only, without executing fused174 or requiring
    /// boundary, RF, OCR, geometry-raster or rich observation placeholders.
    static func extractPhysical(_ input:NativeSourcePhysicalPaletteInput,
                                ops:any NativeAppearanceImageOperations) throws -> Packet {
        try extractPhysicalWithLabs(input, ops: ops).packet
    }

    static func extractPhysicalWithLabs(_ input: NativeSourcePhysicalPaletteInput,
                                        ops: any NativeAppearanceImageOperations) throws
        -> (packet: Packet, labs: [[Float]], near: [UInt8], radius: Int) {
        try input.validate()
        let w=input.width,h=input.height,n=w*h,f=max(1,input.fontPriorSourcePixels)
        let mask=input.ownMask.map {$0==0 ? UInt8(0):1}
        let radius=max(2,min(16,Int((f*0.12).rounded(.toNearestOrEven))))
        let near=try ops.dilate(mask,width:w,height:h,radius:radius,ellipse:true)
        var exterior=(0..<n).map {near[$0] != 0 && mask[$0]==0 ? UInt8(1):0}
        if exterior.filter({$0 != 0}).count<20 {exterior=mask.map {$0==0 ? 1:0}}
        let insideCount=max(1,mask.filter({$0 != 0}).count),outsideCount=max(1,exterior.filter({$0 != 0}).count)
        var colors=try palette(rgb:input.rgb,selection:mask,limit:14,ops:ops)
        for color in try palette(rgb:input.rgb,selection:exterior,limit:6,ops:ops) {
            if colors.allSatisfy({old in zip(old,color).map {abs($0-$1)}.max()!>23}) {colors.append(color)}
        }
        colors=Array(colors.prefix(20))
        guard !colors.isEmpty else {throw Failure.emptyPalette}
        let labs=try ops.lab(colors:colors),depth=try ops.distance(mask,width:w,height:h,maskSize:3)
        let dark=try ops.darkContrast(rgb:input.rgb,width:w,height:h,
            kernel:max(3,min(31,Int((f*0.25).rounded(.toNearestOrEven))/2*2+1)))
        guard labs.count==colors.count,depth.count==n,dark.count==n else {throw Failure.invalidImageOperation}
        var ownMasks:[[UInt64]]=[],holes:[[UInt64]]=[],contacts:[[UInt64]]=[],features:[[Float]]=[]
        var contextCounts: [(far: Int, border: Int)] = []
        var masses: [Int] = []
        for (index,color) in colors.enumerated() {
            // Palette colors are rounded RGB8. Inclusive bounds preserve the original ±23 test.
            let red = Int(color[0]), green = Int(color[1]), blue = Int(color[2])
            var selected = [UInt8](repeating: 0, count: n), own = [UInt8](repeating: 0, count: n)
            var depths: [Double] = []
            var selectedCount = 0, outCount = 0, far = 0, border = 0
            for y in 0..<h {
                for x in 0..<w {
                    let p = y * w + x, rgb = p * 3
                    guard abs(Int(input.rgb[rgb]) - red) <= 23,
                          abs(Int(input.rgb[rgb + 1]) - green) <= 23,
                          abs(Int(input.rgb[rgb + 2]) - blue) <= 23 else { continue }
                    selected[p] = 1
                    selectedCount += 1
                    if mask[p] != 0 {
                        own[p] = 1
                        depths.append(Double(depth[p]))
                    }
                    if exterior[p] != 0 { outCount += 1 }
                    if near[p] == 0 { far += 1 }
                    if x == 0 || x == w - 1 || y == 0 || y == h - 1 { border += 1 }
                }
            }
            contextCounts.append((far, border))
            let sizes=try ops.componentSizes(own,width:w,height:h).filter {$0>=3}
            let normalized=color.map {$0/255},lc=labs[index]
            let ownCount=depths.count
            masses.append(ownCount)
            depths.sort()
            var vector=normalized+[Double(lc[0])/100,Double(lc[1])/128,Double(lc[2])/128,
                normalized.max()!-normalized.min()!,normalized.min()!,normalized.max()!,
                Double(ownCount)/Double(insideCount),Double(outCount)/Double(outsideCount),
                Double(selectedCount)/Double(n),
                NativeAppearanceNumeric.quantile(sorted: depths,0.5)/f,NativeAppearanceNumeric.quantile(sorted: depths,0.9)/f,
                Double(min(sizes.count,100))/100,NativeAppearanceNumeric.quantile(sizes.map(Double.init),0.5)/(f*f)]
            vector.append(sizes.isEmpty ? 0:Double(sizes.filter {$0<=10}.count)/Double(sizes.count))
            features.append(vector.map(Float.init));ownMasks.append(packedMask(own))
            let closed=try ops.close(selected,width:w,height:h,size:3)
            let filled=try ops.fillHoles(closed,width:w,height:h)
            holes.append(packedMask((0..<n).map {filled[$0] != 0 && closed[$0]==0 ? 1:0}))
            contacts.append(packedMask(try ops.dilate(own,width:w,height:h,radius:2,ellipse:false)))
        }
        var pair=[[[Float]]](repeating:[[Float]](repeating:[Float](repeating:0,count:6),count:colors.count),count:colors.count)
        for i in colors.indices {
            let own = ownMasks[i]
            for j in colors.indices {
                let hole = holes[j], contact = contacts[j]
                var holeCount = 0, contactCount = 0
                for word in own.indices {
                    holeCount += (own[word] & hole[word]).nonzeroBitCount
                    contactCount += (own[word] & contact[word]).nonzeroBitCount
                }
                let mass = Double(max(1, masses[i]))
                let holeFraction = Float(Double(holeCount) / mass)
                let contactFraction = Float(Double(contactCount) / mass)
                pair[i][j][0] = sqrt(zip(labs[i], labs[j]).reduce(Float(0)) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }) / 100
                // The transposed slots use the same intersection and owner mass.
                pair[i][j][1] = holeFraction
                pair[j][i][2] = holeFraction
                pair[i][j][4] = contactFraction
                pair[j][i][3] = contactFraction
                pair[i][j][5] = Float(min(10, Double(masses[j]) / mass) / 10)
            }
        }
        let offset=max(1,min(10,Int((f*0.05).rounded(.toNearestOrEven))))
        let directions=[(1,0),(1,1),(0,1),(-1,1),(-1,0),(-1,-1),(0,-1),(1,-1)]
        let farCount=max(1,near.filter {$0==0}.count),borderCount=max(1,w*2+h*2-4)
        for i in colors.indices {
            features[i] += [pair[i].map {$0[1]}.max()!,pair[i].map {$0[2]}.max()!,pair[i].reduce(Float(0)) {$0+$1[1]}/Float(colors.count)]
            let (far,border)=contextCounts[i]
            features[i] += [0,Float(Double(far)/Double(farCount)),Float(Double(border)/Double(borderCount))]
            let filled = zip(ownMasks[i], holes[i]).map { $0 | $1 }
            var directional:[Double]=[]
            for (dx,dy) in directions {
                var sum=Float(0),count=0
                let shiftX = dx * offset, shiftY = dy * offset
                let x0=max(0,shiftX),x1=min(w,w+shiftX)
                let y0=max(0,shiftY),y1=min(h,h+shiftY)
                if x0<x1,y0<y1 {
                    for y in y0..<y1 {
                        for x in stride(from: x0, to: x1, by: 64) {
                            let pixel = y * w + x
                            let source = (y - shiftY) * w + x - shiftX
                            let valid = UInt64.max >> (64 - min(64, x1 - x))
                            var edge = maskWindow(filled, at: source) & ~maskWindow(filled, at: pixel) & valid
                            count += edge.nonzeroBitCount
                            // Increasing pixel order preserves the Float32 reduction exactly.
                            while edge != 0 {
                                sum += dark[pixel + edge.trailingZeroBitCount]
                                edge &= edge - 1
                            }
                        }
                    }
                }
                directional.append(count==0 ? 0:Double(sum/Float(count)))
            }
            features[i] += (directional+[directional.max()!,directional.min()!,directional.max()!-directional.min()!,directional.reduce(0,+)/8]).map(Float.init)
            guard features[i].count==35 else {throw Failure.invalidFeatureCount}
        }
        let packet=Packet(colors:colors,features:features,pair:pair,fontPixels:f,
            maskFraction:Double(mask.filter {$0 != 0}.count)/Double(n))
        return (packet, labs, near, radius)
    }

    /// Each set bit represents one nonzero crop pixel. Tail padding stays zero.
    private static func packedMask(_ mask: [UInt8]) -> [UInt64] {
        var words = [UInt64](repeating: 0, count: (mask.count + 63) / 64)
        for index in words.indices {
            let start = index * 64
            var bits: UInt64 = 0
            for pixel in start..<min(start + 64, mask.count) where mask[pixel] != 0 {
                bits |= 1 << (pixel - start)
            }
            words[index] = bits
        }
        return words
    }

    private static func maskWindow(_ words: [UInt64], at pixel: Int) -> UInt64 {
        let index = pixel >> 6, shift = pixel & 63
        let low = words[index] >> shift
        guard shift != 0, index + 1 < words.count else { return low }
        return low | (words[index + 1] << (64 - shift))
    }

    private static func fused(_ input:SourceNativeInput,packet:Packet,mask:[UInt8],labs:[[Float]],
                              ops:any NativeAppearanceImageOperations) throws -> [[Float]] {
        let w=input.width,h=input.height,n=w*h,f=packet.fontPixels
        let owner=try ops.raster(polygons:input.memberPolygons,width:w,height:h)
        let merged=try ops.raster(polygons:[input.mergedPolygon],width:w,height:h)
        let inside=try ops.distance(owner,width:w,height:h,maskSize:3)
        let outside=try ops.distance(owner.map {$0==0 ? 1:0},width:w,height:h,maskSize:3)
        let mergedInside=try ops.distance(merged,width:w,height:h,maskSize:3)
        let mergedOutside=try ops.distance(merged.map {$0==0 ? 1:0},width:w,height:h,maskSize:3)
        let rectangle=try ops.minimumAreaRectangle(input.mergedPolygon)
        guard rectangle.count==5 else {throw Failure.invalidImageOperation}
        let cx=Float(rectangle[0]),cy=Float(rectangle[1]),rw=rectangle[2],rh=rectangle[3]
        let angle=rectangle[4]*Double.pi/180,co=Float(cos(angle)),si=Float(sin(angle))
        let near=try ops.dilate(mask,width:w,height:h,radius:max(2,min(24,Int((f*0.12).rounded(.toNearestOrEven)))),ellipse:true)
        let pixelLab=try ops.lab(rgb:input.rgb,width:w,height:h)
        guard pixelLab.count==n*3 else {throw Failure.invalidImageOperation}
        let step=max(1,(n+119_999)/120_000),positions=Array(stride(from:0,to:n,by:step))
        var matrix=[[Float]]();matrix.reserveCapacity(positions.count)
        var regions=[Int]();regions.reserveCapacity(positions.count)
        func clip(_ value:Float)->Float {min(2,max(-2,value))}
        for p in positions {
            let a=input.primary[p],b=input.boundary[p],offset=p*27
            let text=input.rf[offset],sfx=input.rf[offset+3],balloon=input.rf[offset+6],frame=input.rf[offset+9]
            let x=Float(p%w)-cx,y=Float(p/w)-cy
            let u=(x*co+y*si)/Float(max(1,rw*0.5)),v=(-x*si+y*co)/Float(max(1,rh*0.5))
            var row=Array(input.rf[offset..<offset+27])
            row += [a,b,max(a,b),min(a,b),abs(a-b),text*a,sfx*a,text*b,sfx*b,balloon*(1-a),frame*(1-a)]
            row += [Float(owner[p] == 0 ? 0:1),clip((inside[p]-outside[p])/Float(f)),clip(u),clip(v),
                min(abs(u),2),min(abs(v),2),Float(merged[p] == 0 ? 0:1),clip((mergedInside[p]-mergedOutside[p])/Float(f))]
            row += Array(input.ocr[p*8..<p*8+8]);matrix.append(row)
            regions.append(mask[p] != 0 ? 0:near[p] != 0 ? 1:2)
        }
        let counts=(0..<3).map {region in max(1,regions.filter {$0==region}.count)}
        let ownerFraction=Double(owner.filter {$0 != 0}.count)/Double(n)
        let global=[log1p(Double(input.memberPolygons.count)),log(max(1,rw)/max(1,rh)),
            sin(2*angle),cos(2*angle),ownerFraction,f/Double(max(1,min(h,w)))].map(Float.init)
        return packet.colors.indices.map {i in
            var sums=[[Float]](repeating:[Float](repeating:0,count:54),count:3),hits=[Int](repeating:0,count:3)
            for (j,p) in positions.enumerated() {
                let dl=pixelLab[p*3]-labs[i][0],da=pixelLab[p*3+1]-labs[i][1],db=pixelLab[p*3+2]-labs[i][2]
                guard (dl*dl+da*da)+db*db<=100 else {continue}
                let region=regions[j];hits[region]+=1
                for c in 0..<54 {sums[region][c]+=matrix[j][c]}
            }
            var row=packet.features[i]
            for region in 0..<3 {
                row += hits[region]>0 ? sums[region].map {$0/Float(hits[region])}:[Float](repeating:0,count:54)
                row += [Float(Double(hits[region])/Double(counts[region])),hits[region]>0 ? 1:0]
            }
            row += global
            return row
        }
    }
}
