import Foundation

enum NativeAppearanceGlyphBackground24 {
    struct Result {let features:[[Float]];let observed:Bool}
    static func seeds(_ input:SourceNativeInput)->[UInt8] {
        input.ownMask.indices.map {p in
            let rf=input.rf,o=p*27,owner=max(rf[o+15]*rf[o+16],rf[o+17]*rf[o+18])
            return input.ownMask[p] != 0 && input.primary[p]>=0.7 && owner>=0.001 && input.ocr[p*8]>0.2 ? 1:0
        }
    }
    static func glyph(_ input:SourceNativeInput,colors:[[Double]],ops:any NativeAppearanceImageOperations) throws -> Result {
        let w=input.width,h=input.height,n=w*h,seed=seeds(input),count=seed.filter {$0 != 0}.count
        guard count>=3 else {return .init(features:[[Float]](repeating:[Float](repeating:0,count:24),count:colors.count),observed:false)}
        let radius=Float(min(8,max(2,input.fontPriorSourcePixels*0.08)))
        let distance=try ops.distance(seed.map {$0==0 ? 1:0},width:w,height:h,maskSize:5)
        let eligible=(0..<n).map {distance[$0]>0 && distance[$0]<=3*radius && input.primary[$0]<0.2 &&
            !(input.contextMask[$0] != 0 && input.ownMask[$0]==0)}
        let image=try ops.lab(rgb:input.rgb,width:w,height:h),labs=try ops.lab(colors:colors)
        let seedPositions=(0..<n).filter {seed[$0] != 0}
        func mean(_ positions:[Int],_ signal:(Int)->Float)->Double {
            guard !positions.isEmpty else {return 0}
            return Double(positions.reduce(Float(0)) {$0+signal($1)}/Float(positions.count))
        }
        let global:[Double]=[1,log1p(Double(count))/10,Double(count)/Double(max(1,input.ownMask.filter {$0 != 0}.count)),
            mean(seedPositions,{input.primary[$0]}),mean(seedPositions,{p in let o=p*27;return max(input.rf[o+15]*input.rf[o+16],input.rf[o+17]*input.rf[o+18])}),
            mean(seedPositions,{input.ocr[$0*8]})]
        let weights=(0..<n).map {p -> Float in
            let factor=1-input.boundary[p]
            return (exp(-distance[p]/radius)*(1-input.primary[p]))*(factor*factor)
        }
        let matrix=labs.map {color -> [Float] in
            let close=(0..<n).map {p in NativeAppearancePhysicalImage.distance(Array(image[p*3..<p*3+3]),color)<=10}
            var values=global
            for scale:Float in [1,3] {
                let ring=(0..<n).filter {eligible[$0] && distance[$0]<=scale*radius}
                let selected=ring.filter {close[$0]}
                let weightTotal=ring.reduce(Float(0)) {$0+weights[$1]},weightSelected=selected.reduce(Float(0)) {$0+weights[$1]}
                values += [Double(selected.count)/Double(max(1,ring.count)),Double(weightSelected)/max(1e-12,Double(weightTotal)),
                    selected.isEmpty ? 0:Double(selected.filter {input.ownMask[$0] != 0}.count)/Double(selected.count)]
                values += [mean(selected,{input.primary[$0]}),mean(selected,{input.boundary[$0]}),
                    mean(selected,{input.rf[$0*27+6]}),mean(selected,{input.rf[$0*27+9]}),mean(selected,{input.ocr[$0*8]})]
            }
            let matching=(0..<n).filter {eligible[$0] && close[$0]}
            values.append(matching.isEmpty ? 3:Double(matching.map {distance[$0]}.min()!/radius))
            let inner=(0..<n).filter {eligible[$0] && input.ownMask[$0] != 0},outer=(0..<n).filter {eligible[$0] && input.ownMask[$0]==0}
            values.append(Double(inner.filter {close[$0]}.count)/Double(max(1,inner.count)) -
                Double(outer.filter {close[$0]}.count)/Double(max(1,outer.count)))
            return values.map(Float.init)
        }
        return .init(features:matrix,observed:true)
    }

    static func directional(_ input:SourceNativeInput,colors:[[Double]],ops:any NativeAppearanceImageOperations) throws -> Result {
        let w=input.width,h=input.height,n=w*h,seed=seeds(input)
        let empty=Result(features:[[Float]](repeating:[Float](repeating:0,count:24),count:colors.count),observed:false)
        guard seed.filter({$0 != 0}).count>=3 else {return empty}
        let components=try NativeAppearancePhysicalImage.components(seed,width:w,height:h)
        let radius=min(24,max(4,input.fontPriorSourcePixels*0.4))
        struct Witness {let body:Int;let sector:Int;let pixel:Int;let distance:Double}
        var witnesses:[Witness]=[],bodies=0
        for label in 1..<components.areas.count where components.areas[label]>=3 {
            let positions=(0..<n).filter {components.labels[$0]==Int32(label)}
            let centerX=Double(positions.reduce(0) {$0+$1%w})/Double(positions.count)
            let centerY=Double(positions.reduce(0) {$0+$1/w})/Double(positions.count)
            let body=bodies;bodies+=1
            for sector in 0..<8 {
                let dx=cos(Double(sector)*Double.pi/4),dy=sin(Double(sector)*Double.pi/4)
                var edge=positions[0],best = -Double.infinity
                for p in positions {
                    let projection=(Double(p%w)-centerX)*dx+(Double(p/w)-centerY)*dy
                    if projection>best {best=projection;edge=p}
                }
                var last:Int?,run:[Witness]=[]
                let steps=Int(ceil((radius+0.5-1)/0.5))
                for i in 0..<steps {
                    let distance=1+Double(i)*0.5
                    let x=Int((Double(edge%w)+dx*distance).rounded(.toNearestOrEven))
                    let y=Int((Double(edge/w)+dy*distance).rounded(.toNearestOrEven))
                    if x<0 || x>=w || y<0 || y>=h {break}
                    let p=y*w+x
                    if last==p {continue};last=p
                    if input.contextMask[p] != 0 && input.ownMask[p]==0 {break}
                    if input.primary[p]<0.2 && input.boundary[p]<0.2 {
                        run.append(.init(body:body,sector:sector,pixel:p,distance:hypot(Double(x-edge%w),Double(y-edge/w))))
                        if run.count==2 {witnesses += run;break}
                    } else {run=[]}
                }
            }
        }
        guard !witnesses.isEmpty else {return empty}
        let labs=try ops.lab(colors:colors),image=try ops.lab(rgb:input.rgb,width:w,height:h)
        let distances=witnesses.map(\.distance),median=NativeAppearanceNumeric.quantile(distances,0.5)
        let common=[1,log1p(Double(bodies)),Double(witnesses.count)/Double(max(1,16*bodies)),distances.reduce(0,+)/Double(distances.count)/radius]
        let matrix=labs.map {color -> [Float] in
            let errors=witnesses.map {witness -> Float in
                let p=witness.pixel
                return NativeAppearancePhysicalImage.distance(Array(image[p*3..<p*3+3]),color)
            }
            let close=errors.map {$0<=10}
            let fractions=(0..<bodies).map {body -> Double in
                let indices=witnesses.indices.filter {witnesses[$0].body==body}
                return Double(indices.filter {close[$0]}.count)/Double(max(1,indices.count))
            }
            let sectors=(0..<bodies).map {body in
                Set(witnesses.indices.filter {witnesses[$0].body==body && close[$0]}.map {witnesses[$0].sector})
            }
            let opposite=sectors.reduce(0) {sum,set in sum+(0..<4).filter {set.contains($0) && set.contains($0+4)}.count}
            let sectorCoverage=Set(sectors.flatMap {Array($0)}).count
            let near=witnesses.indices.filter {distances[$0]<=median},far=witnesses.indices.filter {distances[$0]>median}
            let weights=distances.map {1/(1+$0)},weightTotal=weights.reduce(0,+)
            let numericErrors=errors.map(Double.init)
            let values=common+[Double(close.filter {$0}.count)/Double(close.count),NativeAppearanceNumeric.quantile(fractions,0.5),
                NativeAppearanceNumeric.quantile(fractions,0.1),fractions.min()!,Double(fractions.filter {$0>=0.5}.count)/Double(bodies),
                Double(opposite)/Double(max(1,4*bodies)),Double(sectorCoverage)/8,
                Double(errors.reduce(Float(0),+))/Double(errors.count)/100,
                NativeAppearanceNumeric.quantile(numericErrors,0.5)/100,NativeAppearanceNumeric.quantile(numericErrors,0.1)/100,
                NativeAppearanceNumeric.quantile(numericErrors,0.9)/100,Double(near.filter {close[$0]}.count)/Double(max(1,near.count)),
                Double(far.filter {close[$0]}.count)/Double(max(1,far.count)),
                weights.indices.filter {close[$0]}.reduce(0) {$0+weights[$1]}/weightTotal]
            let selected=witnesses.indices.filter {close[$0]}.map {witnesses[$0].pixel}
            let signals:[(Int)->Float]=[{input.rf[$0*27+15]},{input.rf[$0*27+6]},{input.rf[$0*27+9]},
                {input.primary[$0]},{input.boundary[$0]},{input.ocr[$0*8]}]
            return (values+signals.map {signal in selected.isEmpty ? 0:Double(selected.reduce(Float(0)) {$0+signal($1)}/Float(selected.count))}).map(Float.init)
        }
        return .init(features:matrix,observed:true)
    }
}
