import Foundation

extension NativeAppearanceLateGradient.Engine {
    func emittedPalette(_ prediction:D)->[[Double]] {
        typealias L=NativeAppearanceLateGradient
        let fill=L.part(prediction,"fill"),primary=L.vector(fill["rgb"])
        if fill["representation"] as? String=="source-fusion-observed-palette" {return [primary]+Array(L.colors(fill["colors"]).dropFirst())}
        return [primary]+L.rows(L.part(L.part(L.part(prediction,"pixelRoleEvidence"),"roles"),"fill")["observedColours"]).map {L.vector($0["rgb"])}
    }
    func paletteChoice(_ bodies:[InteriorBody],prediction:D,extra:[[Double]],bright:Bool,maximum:Int) throws -> ([[Double]],[D],D) {
        typealias L=NativeAppearanceLateGradient
        let positions=bodies.flatMap(\.positions),support=bodies.flatMap(\.support)
        let ids=bodies.enumerated().flatMap {i,b in Array(repeating:i,count:b.positions.count)}
        guard !positions.isEmpty else {return([],[],["eligible":false])}
        let baseline=emittedPalette(prediction)+extra,old=try labs(baseline),ll=positions.map {lab($0)}
        var distance=ll.map {color in old.map {L.d(color,$0)}.min()!}
        let original=distance,baselineCovered=original.filter {$0<=10}.count
        var candidates:[Int]=[]
        if bright {
            var bins=[[Int]:[Int]]()
            for i in positions.indices {bins[ll[i].map {Int(floor($0/6))},default:[]].append(i)}
            for key in bins.keys.sorted(by:{$0.lexicographicallyPrecedes($1)}) {
                let indices=bins[key]!,center=L.median(indices.map {ll[$0]})
                candidates.append(indices.min {L.d(ll[$0],center)<L.d(ll[$1],center)}!)
            }
        } else {
            var distinct=[Int:Int]()
            for i in positions.indices {let c=rgb(positions[i]),key=Int(c[0])*65536+Int(c[1])*256+Int(c[2]);if distinct[key]==nil {distinct[key]=i}}
            candidates=distinct.keys.sorted().map {distinct[$0]!}
        }
        let originalCandidates=candidates
        var additions:[[Double]]=[],selected:[D]=[],admissible=0,top:[D]=[]
        for _ in 0..<maximum {
            let uncovered=distance.map {$0>10}
            if uncovered.filter({$0}).count<max(12,Int(ceil(0.02*Double(positions.count)))) {break}
            let emitted=try labs(baseline+additions)
            var best:(record:D,dist:[Double],gain:Int,reduction:Double,color:[Double])?
            var ranked:[D]=[]
            for index in candidates where emitted.map({L.d(ll[index],$0)}).min()!>6 {
                let dd=ll.map {L.d($0,ll[index])},gain=positions.indices.filter {uncovered[$0] && dd[$0]<=10}
                if Double(gain.count)<max(12,0.02*Double(positions.count)) {continue}
                var votes:[Int]=[],witnesses:[D]=[]
                for body in bodies.indices {
                    let hits=gain.filter {support[$0] && ids[$0]==body};if hits.count<3 {continue}
                    votes.append(body);let chosen=hits.min {dd[$0]<dd[$1]}!
                    var witness:D=[bright ? "body":"component":body,"xy":point(positions[chosen]),"rgb":rgb(positions[chosen]),"deltaE":dd[chosen]]
                    witness[bright ? "supportedNewPixels":"sourceSupportedNewPixels"]=hits.count;witnesses.append(witness)
                }
                if votes.count<2 {continue}
                let reduction=positions.indices.reduce(0.0) {$0+max(0,min(distance[$1],10)-min(dd[$1],10))},color=rgb(positions[index])
                let record:D=["rgb":color,"gainPixels":gain.count,"gainFraction":Double(gain.count)/Double(positions.count),"cappedDistanceReduction":reduction,
                    "components":votes,"witnesses":witnesses,"exactRGBWitnessXY":point(positions[index]),"exactRGBWitnessComponent":ids[index]]
                ranked.append(record)
                if best==nil || gain.count>best!.gain || (gain.count==best!.gain && (reduction>best!.reduction || (reduction==best!.reduction && color.lexicographicallyPrecedes(best!.color)))) {
                    best=(record,dd,gain.count,reduction,color)
                }
            }
            admissible=ranked.count
            ranked.sort {a,b in
                if L.number(a["gainPixels"]) != L.number(b["gainPixels"]) {return L.number(a["gainPixels"])>L.number(b["gainPixels"])}
                if L.number(a["cappedDistanceReduction"]) != L.number(b["cappedDistanceReduction"]) {return L.number(a["cappedDistanceReduction"])>L.number(b["cappedDistanceReduction"])}
                return L.vector(a["rgb"]).lexicographicallyPrecedes(L.vector(b["rgb"]))
            }
            top=Array(ranked.prefix(12))
            guard let best else {break}
            selected.append(best.record);additions.append(best.color);distance=zip(distance,best.dist).map {min($0,$1)}
        }
        let reports:D=["eligible":true,"bodies":bodies.count,"nativeInteriorPixels":positions.count,"interiorPixels":positions.count,
            "supportedInteriorPixels":support.filter {$0}.count,"sourceSupportedInteriorPixels":support.filter {$0}.count,
            "baselineCoveredPixels":baselineCovered,"baselineCoverage":Double(baselineCovered)/Double(positions.count),
            "candidateCoveredPixels":distance.filter {$0<=10}.count,"candidateCoverage":Double(distance.filter {$0<=10}.count)/Double(positions.count),
            "distinctActualInteriorRGBs":Set(positions.map {rgb($0)}).count,"novelActualInteriorRGBs":originalCandidates.filter {i in old.map {L.d(ll[i],$0)}.min()!>6}.count,
            "admissibleCandidates":admissible,"selected":selected.first as Any? ?? NSNull(),"topCandidates":top,
            "maximumAdditions":maximum,"minimumBodySourceSupport":0.95,"additions":selected]
        return(additions,selected,reports)
    }
    func extendPalette(_ prediction:D,baseline:D,diagnostic:D) throws -> D {
        typealias L=NativeAppearanceLateGradient
        var additions:[[Double]]=[],evidence:D
        if diagnostic["mechanism"] as? String=="bounded-bright-interiors" && L.part(diagnostic,"semantic")["accepted"] as? Bool == true {
            let bodies=try brightInteriors(baseline,diagnostic:diagnostic).filter {$0.fraction>=0.95}
            if bodies.count<3 {return prediction}
            let (_,selected,report)=try paletteChoice(bodies,prediction:baseline,extra:[],bright:true,maximum:3)
            let kept=selected.filter {L.number($0["gainPixels"])/L.number(report["nativeInteriorPixels"])>=0.1}
            additions=kept.map {L.vector($0["rgb"])}
            evidence=["version":"certified-bright-native-palette-v1","eligible":!additions.isEmpty,"mechanism":"bounded-bright-interiors",
                "diagnostic":diagnostic,"groups":[D](),"nativeBodyReport":report,"selectedAdditions":kept,"GTAtInference":false]
        } else if diagnostic["mechanism"] as? String=="confirmed-gradient-body" && L.part(diagnostic,"sourceObservation")["identified"] as? Bool == true {
            let (groups,semantic)=try trusted(gradientGroups(baseline),prediction:baseline)
            var reports:[D]=[]
            for (gi,group) in groups.enumerated() {
                let contour=try contourMeasure([group])
                if contour["identified"] as? Bool != true {reports.append(["group":gi,"rejected":"group lacks independent contour","contour":contour]);continue}
                let bodies=group.enumerated().map {i,b in InteriorBody(positions:b.positions,support:b.positions.map {supported($0)},bodyPixels:b.body.filter {$0 != 0}.count,id:i)}
                if bodies.count<3 {continue}
                let (extra,_,report)=try paletteChoice(bodies,prediction:baseline,extra:additions,bright:false,maximum:1)
                additions+=extra
                var entry=report;entry["group"]=gi;entry["contour"]=contour
                entry["bodies"]=bodies.enumerated().map {i,b -> D in ["component":i,"bodyPixels":b.bodyPixels,"interiorPixels":b.positions.count,"seedXY":point(group[i].seed)]}
                reports.append(entry)
            }
            evidence=["eligible":true,"diagnostic":diagnostic,"semantic":semantic,"groups":reports]
        } else {return prediction}
        if additions.isEmpty {return prediction}
        var out=prediction,fill=L.part(prediction,"fill");let previous=L.colors(fill["colors"]),primary=L.vector(fill["rgb"])
        guard fill["representation"] as? String=="source-fusion-observed-palette",previous.first==primary else {throw NativeOpenCV.Failure.native("Owned gradient palette contract")}
        fill["colors"]=previous+additions
        fill["gradientPaletteCorrection"]=["version":L.paletteVersion,"policyVersion":"independent-contour-native-marginal-coverage-v2",
            "primaryRGB":primary,"previousColors":previous,"addedRGB":additions,"sourceEvidence":evidence] as D
        out["fill"]=fill;return out
    }
    func certifiedPrimary(_ prediction:D,diagnostic:D) throws -> D {
        typealias L=NativeAppearanceLateGradient
        guard diagnostic["mechanism"] as? String=="bounded-bright-interiors",L.part(diagnostic,"semantic")["accepted"] as? Bool == true else {return prediction}
        let bodies=try brightInteriors(prediction,diagnostic:diagnostic).filter {$0.fraction>=0.95}
        if bodies.count<3 {return prediction}
        let positions=bodies.flatMap(\.positions),support=bodies.flatMap(\.support),ids=bodies.enumerated().flatMap {i,b in Array(repeating:i,count:b.positions.count)}
        let ll=positions.map {lab($0)},old=try labs([L.vector(L.part(prediction,"fill")["rgb"])])[0]
        let coverage=Double(ll.filter {L.d($0,old)<=10}.count)/Double(ll.count)
        if coverage>=0.1 {return prediction}
        let medians=bodies.map {L.median($0.positions.map {lab($0)})},center=L.median(medians),candidates=positions.indices.filter {support[$0]}
        guard let nearest=candidates.min(by:{L.d(ll[$0],center)<L.d(ll[$1],center)}) else {return prediction}
        let color=rgb(positions[nearest]),cl=ll[nearest]
        if medians.map({L.d($0,cl)}).max()!>10 {return prediction}
        let distances=ll.map {L.d($0,cl)},newCoverage=Double(distances.filter {$0<=10}.count)/Double(positions.count)
        if newCoverage<0.2 {return prediction}
        var witnesses:[D]=[]
        for i in bodies.indices {
            let hits=positions.indices.filter {ids[$0]==i && support[$0] && distances[$0]<=10}
            if hits.count<3 {return prediction}
            let chosen=hits.min {distances[$0]<distances[$1]}!
            witnesses.append(["body":i,"xy":point(positions[chosen]),"rgb":rgb(positions[chosen]),"deltaE":distances[chosen],"supportedPixels":hits.count])
        }
        var out=prediction,fill=L.part(prediction,"fill");let previous=L.colors(fill["colors"]),prior=L.vector(fill["rgb"])
        let evidence:D=["sourceDiagnostic":diagnostic,"sourceBodySupportFractions":bodies.map(\.fraction),"version":L.brightPrimaryVersion,"eligible":true,
            "sourceOnly":true,"GTAtInference":false,"bodies":bodies.count,"oldPrimaryCoverage":coverage,"newPrimaryCoverage":newCoverage,
            "bodyMedianLab":medians,"nativeInteriorPixels":positions.count,"witnesses":witnesses,"exactNativeRGB":color,
            "exactNativeXY":point(positions[nearest]),"exactNativeBody":ids[nearest]]
        fill["rgb"]=color;fill["colors"]=[color]+previous.filter {$0 != color}
        fill["brightPrimaryCorrection"]=["version":L.brightPrimaryVersion,"previousRGB":prior,"previousColors":previous,"newRGB":color,"sourceEvidence":evidence] as D
        out["fill"]=fill;return out
    }
    func prunePalette(_ prediction:D,diagnostic:D) throws -> D {
        typealias L=NativeAppearanceLateGradient
        guard diagnostic["mechanism"] as? String=="bounded-bright-interiors",L.part(diagnostic,"semantic")["accepted"] as? Bool == true,
              L.part(prediction,"fill")["representation"] as? String=="source-fusion-observed-palette" else {return prediction}
        let bodies=try brightInteriors(prediction,diagnostic:diagnostic).filter {$0.fraction>=0.95}
        if bodies.count<3 {return prediction}
        let positions=bodies.flatMap(\.positions),support=bodies.flatMap(\.support),ids=bodies.enumerated().flatMap {i,b in Array(repeating:i,count:b.positions.count)}
        let observation=L.part(diagnostic,"sourceObservation"),semantic=L.part(diagnostic,"semantic")
        let native=try family(L.vector(observation["candidateRGB"])),closed=try ops.close(native,width:w,height:h,size:3),cc=try component(closed)
        let certified=Set(zip(L.rows(observation["holes"]),L.rows(semantic["holes"])).filter {$0.1["confirmed"] as? Bool == true}.map {Int(L.number($0.0["component"]))}).sorted()
        let (core,_)=try confirmedBodies(diagnostic),contour=(0..<n).map {native[$0] != 0 && certified.contains(Int(cc.labels[$0])) ? UInt8(1):0}
        let boundary=(0..<n).filter {contour[$0] != 0}
        guard !boundary.isEmpty else {throw NativeOpenCV.Failure.native("Missing certified native boundary")}
        let toContour=try NativeAppearanceEuclideanDistance.transform(seed:contour,width:w,height:h).values
        let toCore=try NativeAppearanceEuclideanDistance.transform(seed:core,width:w,height:h).values
        let possible=(0..<n).filter {input.ownMask[$0] != 0 && supported($0,detector:false)}
        var out=prediction,fill=L.part(prediction,"fill"),retained:[[Double]]=[],reports:[D]=[]
        let colors=L.colors(fill["colors"]),primary=L.vector(fill["rgb"])
        guard colors.first==primary else {throw NativeOpenCV.Failure.native("Emitted primary palette contract")}
        for (index,color) in colors.enumerated() {
            let cl=try labs([color])[0],distances=positions.map {L.d(lab($0),cl)},hits=positions.indices.filter {support[$0] && distances[$0]<=10}
            let nearest=(0..<n).min {L.d(lab($0),cl)<L.d(lab($1),cl)}!,cropMinimum=L.d(lab(nearest),cl)
            let possibleMatches=possible.filter {L.d(lab($0),cl)<=10},unmatched=possibleMatches.filter {toContour[$0]>2}
            let boundaryWitness=boundary.min {L.d(lab($0),cl)<L.d(lab($1),cl)}!,boundaryDelta=L.d(lab(boundaryWitness),cl)
            let exclusive=boundaryDelta<=10 && !possibleMatches.isEmpty && unmatched.isEmpty
            let keep=color==primary || hits.count>=1 || (cropMinimum<=10 && !exclusive)
            if keep {retained.append(color)}
            var votes:[D]=[]
            for body in bodies.indices {
                let bodyHits=hits.filter {ids[$0]==body};if bodyHits.isEmpty {continue}
                let chosen=bodyHits.min {distances[$0]<distances[$1]}!
                votes.append(["body":body,"supportedPixels":bodyHits.count,"xy":point(positions[chosen]),"rgb":rgb(positions[chosen]),"deltaE":distances[chosen]])
            }
            let unexplained:D?=unmatched.first.map {p in ["xy":point(p),"rgb":rgb(p),"distanceToContourPx":toContour[p],"distanceToCorePx":toCore[p]]}
            reports.append(["nativeCropWitness":["xy":point(nearest),"rgb":rgb(nearest),"deltaE":cropMinimum],"minimumNativeCropDeltaE":cropMinimum,
                "possibleTextPixels":possibleMatches.count,"unexplainedTextPixels":unmatched.count,"unexplainedTextWitness":unexplained as Any? ?? NSNull(),
                "nativeBoundaryWitness":["xy":point(boundaryWitness),"rgb":rgb(boundaryWitness),"deltaE":boundaryDelta,"component":Int(cc.labels[boundaryWitness])],
                "boundaryExclusive":exclusive,"index":index,"rgb":color,"kept":keep,"primary":color==primary,"supportedNativePixels":hits.count,
                "minimumNativeDeltaE":positions.indices.filter {support[$0]}.map {distances[$0]}.min()! ,"bodyWitnesses":votes])
        }
        if retained==colors {return out}
        let evidence:D=["certifiedContourComponents":certified,"sourceContourPixels":boundary.count,"confirmedSourceCorePixels":core.filter {$0 != 0}.count,
            "version":L.pruningVersion,"eligible":true,"minimumPixels":1,"bodies":bodies.count,"sourceBodySupportFractions":bodies.map(\.fraction),
            "sourceDiagnostic":diagnostic,"sourceOnly":true,"GTAtInference":false,"nativeInteriorPixels":positions.count,"supportedInteriorPixels":support.filter {$0}.count,"colours":reports]
        fill["colors"]=retained;fill["interiorPalettePruning"]=["version":L.pruningVersion,"primaryRGB":primary,"previousColors":colors,"retainedColors":retained,"sourceEvidence":evidence] as D
        out["fill"]=fill;return out
    }
}
