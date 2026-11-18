import Foundation

/// Final exact-local background ranker: original palette + incumbent, source15
/// and RF27/seg2/OCR8/interactions6 conditional+joint support87. No colour invention.
enum NativeAppearanceBackgroundFeatures102 {
    struct RoleColor {let rgb:[Double];let observedMass:Double}
    struct Packet {
        let colors:[[Double]]
        let features:[[Float]]
        let localPositions:[Int]
        let localNearestMass:[Double]
        let localColourFraction:[Double]
        let localMatchedFraction:Double
    }
    static func extract(_ input:SourceNativeInput,palette:[[Double]],weights:[Double],incumbent:[Double],
                        fill:[Double],outline:[Double],backgroundRole:[RoleColor],
                        ops:any NativeAppearanceImageOperations) throws -> Packet {
        try input.validate()
        guard !palette.isEmpty,palette.count==weights.count,weights.allSatisfy(\.isFinite) else {
            throw SourceNativeInput.Failure.invalidPredictions
        }
        let colors=palette+[incumbent],w=input.width,h=input.height,n=w*h
        let labs=try ops.lab(colors:colors),pixelLab=try ops.lab(rgb:input.rgb,width:w,height:h)
        let sourceLabs=try ops.lab(colors:[fill,outline])
        let roleLabs=try ops.lab(colors:backgroundRole.map(\.rgb))
        let distance=try ops.distance(input.ownMask.map {$0==0 ? 1:0},width:w,height:h,maskSize:3)
        let radius=min(12,max(2,input.fontPriorSourcePixels*0.12))
        let positions=(0..<n).filter {distance[$0]>0 && Double(distance[$0])<=radius && input.contextMask[$0]==0}
        let visibleCount=max(1,input.contextMask.filter {$0==0}.count)
        let borderCount=max(1,(0..<n).filter {p in input.contextMask[p]==0 && (p/w==0 || p/w==h-1 || p%w==0 || p%w==w-1)}.count)
        func square(_ a:[Float],_ b:[Float])->Float {
            let x=a[0]-b[0],y=a[1]-b[1],z=a[2]-b[2]
            return (x*x+y*y)+z*z
        }
        let incumbentNearest=palette.indices.min {square(labs[$0],labs.last!)<square(labs[$1],labs.last!)}!
        var visible=[Float](),border=[Float]()
        for c in palette.indices {
            var v=0,b=0
            for p in 0..<n where input.contextMask[p]==0 {
                let pixel=Array(pixelLab[p*3..<p*3+3])
                if square(pixel,labs[c])<=100 {
                    v+=1
                    if p/w==0 || p/w==h-1 || p%w==0 || p%w==w-1 {b+=1}
                }
            }
            visible.append(Float(Double(v)/Double(visibleCount)));border.append(Float(Double(b)/Double(borderCount)))
        }
        visible.append(visible[incumbentNearest]);border.append(border[incumbentNearest])
        var signals=[[Double]]();signals.reserveCapacity(positions.count)
        var pixelColors=[[Float]]();pixelColors.reserveCapacity(positions.count)
        for p in positions {
            let o=p*27,a=input.primary[p],b=input.boundary[p]
            var row=Array(input.rf[o..<o+27])+[a,b]+Array(input.ocr[p*8..<p*8+8])
            row += [input.rf[o+6]*(1-a),input.rf[o+9]*(1-a),input.rf[o+19]*(1-a),
                input.rf[o+21]*(1-a),input.rf[o]*a,input.rf[o+3]*a]
            signals.append(row.map(Double.init));pixelColors.append(Array(pixelLab[p*3..<p*3+3]))
        }
        var sums=[[Double]](repeating:[Double](repeating:0,count:43),count:colors.count)
        var hits=[Int](repeating:0,count:colors.count),nearest=[Int](repeating:0,count:colors.count),matched=0
        for p in positions.indices {
            var best=Float.infinity,chosen=0
            for c in colors.indices {
                let d=square(pixelColors[p],labs[c])
                if d<best {best=d;chosen=c}
                if d<=100 {
                    hits[c]+=1
                    for i in 0..<43 {sums[c][i]+=signals[p][i]}
                }
            }
            if best<=100 {nearest[chosen]+=1;matched+=1}
        }
        let denominator=Double(max(1,positions.count)),fraction=hits.map {Double($0)/denominator}
        let matchedFraction=Double(matched)/denominator,nearestMass=nearest.map {Double($0)/denominator}
        let allWeights=weights+[weights[incumbentNearest]],maximum=max(1e-6,fraction.max() ?? 0)
        let matrix=colors.indices.map {c -> [Float] in
            let roleNearest=backgroundRole.indices.min {square(labs[c],roleLabs[$0])<square(labs[c],roleLabs[$1])}
            let roleDistance=roleNearest.map {Double(sqrt(square(labs[c],roleLabs[$0]))/100)} ?? 2
            let roleMass=roleNearest.map {backgroundRole[$0].observedMass} ?? 0
            let lab=labs[c]
            var row=[lab[0]/100,lab[1]/100,lab[2]/100,Float(allWeights[c]),visible[c],border[c],
                Float(nearestMass[c]),Float(fraction[c]),Float(fraction[c]/maximum),Float(roleDistance),Float(roleMass),
                sqrt(square(lab,sourceLabs[0]))/100,sqrt(square(lab,sourceLabs[1]))/100,
                Float(matchedFraction),Float(log1p(Double(positions.count))/10)]
            let mean=hits[c]>0 ? sums[c].map {$0/Double(hits[c])}:[Double](repeating:0,count:43)
            row += mean.map(Float.init)
            row += mean.map {Float($0*fraction[c])}
            row.append(hits[c]>0 ? 1:0)
            return row
        }
        return .init(colors:colors,features:matrix,localPositions:positions,localNearestMass:nearestMass,
            localColourFraction:fraction,localMatchedFraction:matchedFraction)
    }
}
