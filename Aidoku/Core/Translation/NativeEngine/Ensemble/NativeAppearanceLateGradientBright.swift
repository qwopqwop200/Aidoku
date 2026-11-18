import Foundation

extension NativeAppearanceLateGradient.Engine {
    struct BrightHole {let component:Int,hole:Int,body:[UInt8],core:[Int],ring:[Int],median:[Double],area:Int,rawFraction:Double,width:Double}
    struct BrightProposal {let color:[Double],candidate:[Double],holes:[BrightHole],core:[Int],ring:[Int],witness:Int,samples:Int,support:Double}
    struct InteriorBody {let positions:[Int],support:[Bool],bodyPixels:Int,id:Int
        var fraction:Double {Double(support.filter {$0}.count)/Double(max(1,support.count))}
    }
    func brightEligible(_ prediction:D) throws -> Bool {
        typealias L=NativeAppearanceLateGradient
        if L.part(prediction,"outline")["present"] as? Bool != true {return false}
        let colors=try labs([L.vector(L.part(prediction,"fill")["rgb"]),L.vector(L.part(prediction,"background")["rgb"])])
        return colors[0][0]>=85 && colors[1][0]>=85 && L.d(colors[0],colors[1])<=10
    }
    func take(_ positions:[Int],limit:Int)->[Int] {
        if positions.count<=limit {return positions}
        return (0..<limit).map {positions[$0*(positions.count-1)/(limit-1)]}
    }
    func brightProposals(_ prediction:D) throws -> [BrightProposal] {
        typealias L=NativeAppearanceLateGradient
        if try !brightEligible(prediction) {return []}
        var proposals:[BrightProposal]=[]
        let minimum=max(12,font*0.3),targets=try labs(packet.colors)
        for (ci,color) in packet.colors.enumerated() where targets[ci][0]<=80 {
            let native=try family(color),closed=try ops.close(native,width:w,height:h,size:3),cc=try component(closed)
            var valid:[BrightHole]=[]
            for label in 1..<cc.areas.count where Double(cc.areas[label])>=max(20,font) {
                let ring=cc.labels.map {$0==Int32(label) ? UInt8(1):0},raw=(0..<n).filter {ring[$0] != 0 && native[$0] != 0}
                let rawFraction=Double(raw.count)/Double(cc.areas[label])
                if rawFraction<0.75 || Double(raw.filter {input.ownMask[$0] != 0}.count)/Double(max(1,raw.count))<0.65 {continue}
                let filled=try ops.fillHoles(ring,width:w,height:h),holes=(0..<n).map {filled[$0] != 0 && ring[$0]==0 ? UInt8(1):0}
                if !holes.contains(1) {continue}
                let distance=try depth(holes.map {$0==0 ? 1:0}),width=L.q(raw.map {Double(distance[$0])},0.75)
                if width>max(3,font*0.12) {continue}
                let hc=try component(holes)
                for hi in 1..<hc.areas.count where Double(hc.areas[hi])>=minimum {
                    let positions=(0..<n).filter {hc.labels[$0]==Int32(hi)}
                    let seeds=positions.filter {input.ownMask[$0] != 0 && (input.memberPolygons.isEmpty || roi[$0] != 0)}.count
                    if Double(seeds)<minimum || Double(seeds)/Double(positions.count)<0.5 {continue}
                    let median=L.median(positions.map {lab($0)})
                    if median[0]-targets[ci][0]<20 {continue}
                    let body=mask(positions),dist=try depth(body.map {$0==0 ? 1:0}),near=raw.filter {Double(dist[$0])<=max(3,font*0.12)}
                    if near.count<12 || near.contains(where:{$0%w<2 || $0/w<2 || $0%w>=w-2 || $0/w>=h-2}) {continue}
                    let centerX=positions.reduce(0.0) {$0+Double($1%w)}/Double(positions.count),centerY=positions.reduce(0.0) {$0+Double($1/w)}/Double(positions.count)
                    let sectors=Set(near.map {Int((atan2(Double($0/w)-centerY,Double($0%w)-centerX)+Double.pi)/(Double.pi/2))%4})
                    if sectors.count<4 {continue}
                    valid.append(.init(component:label,hole:hi,body:body,core:take(positions,limit:128),ring:take(near,limit:256),median:median,area:positions.count,rawFraction:rawFraction,width:width))
                }
            }
            var groups:[[BrightHole]]=[]
            for hole in valid {
                if groups.flatMap({$0}).contains(where:{$0.core==hole.core}) {continue}
                let group=groups.firstIndex {g in g.allSatisfy {other in
                    let a=hole.median,b=other.median,ca=hypot(a[1],a[2]),cb=hypot(b[1],b[2])
                    return ca>=8 && cb>=8 ? abs(a[0]-b[0])<=20 && (a[1]*b[1]+a[2]*b[2])/(ca*cb)>=0.9:L.d(a,b)<=15
                }}
                if let group {groups[group].append(hole)} else {groups.append([hole])}
            }
            for group in groups where group.count>=3 {
                let ring=Set(group.flatMap(\.ring)).sorted(),core=Set(group.flatMap(\.core)).sorted()
                let close=ring.filter {L.d(lab($0),targets[ci])<=8}
                if close.count<12 {continue}
                let median=L.median(close.map {lab($0)}),witness=close.min {L.d(lab($0),median)<L.d(lab($1),median)}!
                proposals.append(.init(color:rgb(witness),candidate:color,holes:group,core:core,ring:ring,witness:witness,samples:close.count,support:Double(close.count)/Double(ring.count)))
            }
        }
        return proposals.sorted {a,b in
            if a.samples != b.samples {return a.samples>b.samples}
            if a.support != b.support {return a.support>b.support};return a.holes.count>b.holes.count
        }
    }
    func brightSemantic(_ proposal:BrightProposal)->D {
        typealias L=NativeAppearanceLateGradient
        var holes:[D]=[]
        for hole in proposal.holes {
            let positions=hole.core,seg=L.q(positions.map {Double(max(input.primary[$0],input.boundary[$0]))})
            let owners=positions.map {p in max(Double(input.rf[p*27+15])*Double(input.rf[p*27+16]),Double(input.rf[p*27+17])*Double(input.rf[p*27+18]))}
            let owner=L.q(owners),ocr=Double(positions.filter {input.ocr[$0*8]>0}.count)/Double(positions.count)
            let scores=positions.filter {input.ocr[$0*8+1]>0}.map {Double(input.ocr[$0*8+2])},detector=scores.isEmpty ? nil:L.q(scores)
            let confirmed=seg>=0.5 && owner>=0.001 && ocr>=0.8 && (detector==nil || detector!>=0.2)
            holes.append(["softSegmentationMedian":seg,"rfOwnerMedian":owner,"ocrBoxFraction":ocr,"detectorConfidenceMedian":detector as Any? ?? NSNull(),"confirmed":confirmed])
        }
        let ringSeg=L.q(proposal.ring.map {Double(max(input.primary[$0],input.boundary[$0]))})
        return ["accepted":holes.filter {$0["confirmed"] as? Bool == true}.count>=3 && ringSeg>=0.5,"holes":holes,
            "ringSoftSegmentationMedian":ringSeg,"GTAtInference":false]
    }
    func contour(_ prediction:D) throws -> (D,D) {
        typealias L=NativeAppearanceLateGradient
        var result=prediction,diagnostic:D=["version":L.contourVersion,"applied":false]
        if L.part(prediction,"outline")["present"] as? Bool != true {
            diagnostic["reason"]="Outline presence is off; this head only refines colour";return(result,diagnostic)
        }
        let groups=try gradientGroups(prediction)
        if groups.isEmpty {diagnostic["gradientGroups"]=0;diagnostic["reason"]="No independently repeated gradient fill bodies"}
        else {
            let (confirmed,semantic)=try trusted(groups,prediction:prediction);diagnostic["semantic"]=semantic
            if confirmed.isEmpty {diagnostic["reason"]="Source ownership/known fill seeds do not corroborate gradient bodies"}
            else {
                let observation=try contourMeasure(confirmed),identified=observation["identified"] as? Bool == true
                diagnostic["sourceObservation"]=observation;diagnostic["mechanism"]="confirmed-gradient-body";diagnostic["GTAtInference"]=false
                if identified {
                    let old=L.vector(L.part(prediction,"outline")["rgb"]),delta=L.d(try labs([L.vector(observation["rgb"])])[0],try labs([old])[0])
                    diagnostic["colourDifferenceFromRankerDeltaE"]=delta;diagnostic["applied"]=delta>10
                    if delta>10 {
                        var outline=L.part(result,"outline");outline["rgb"]=observation["rgb"]
                        outline["gradientContourCorrection"]=["version":L.contourVersion,"previousRGB":old,"sourceEvidence":diagnostic,
                            "interpretation":"Observed bounded source-composite contour RGB; intrinsic pigment and width are not reidentified",
                            "preservedFields":"Original index, classifier probability, presence, nominal width/interval and every other style output"] as D
                        result["outline"]=outline
                    }
                    return(result,diagnostic)
                }
            }
        }
        let candidates=try brightProposals(prediction)
        for proposal in candidates {
            let semantic=brightSemantic(proposal);if semantic["accepted"] as? Bool != true {continue}
            let old=L.vector(L.part(prediction,"outline")["rgb"]),ll=try labs([old,proposal.color]),delta=L.d(ll[0],ll[1])
            let holes=proposal.holes.map {hole -> D in
                let ps=hole.body.indices.filter {hole.body[$0] != 0}
                return ["centre":[ps.reduce(0.0) {$0+Double($1%w)}/Double(ps.count),ps.reduce(0.0) {$0+Double($1/w)}/Double(ps.count)],
                    "medianLab":hole.median,"nativeArea":hole.area,"component":hole.component,"hole":hole.hole,
                    "rawRingFraction":hole.rawFraction,"nativeRingWidthQ75":hole.width]
            }
            let support=(proposal.core+proposal.ring).map(Int64.init)
            let sha=support.withUnsafeBytes {L.hash(Data($0))}
            let observation:D=["rgb":proposal.color,"candidateRGB":proposal.candidate,"holes":holes,"coreCount":proposal.holes.count,
                "nativeColourSupport":proposal.support,"nativeRGBWitnessXY":point(proposal.witness),"nativeColourSamples":proposal.samples,
                "sourceSupportPositionsSHA256":sha]
            diagnostic=["version":L.contourVersion,"mechanism":"bounded-bright-interiors","applied":delta>10,"sourceObservation":observation,
                "semantic":semantic,"colourDifferenceFromRankerDeltaE":delta,"GTAtInference":false]
            result=prediction
            if delta>10 {
                var outline=L.part(result,"outline");outline["rgb"]=proposal.color
                outline["gradientContourCorrection"]=["version":L.contourVersion,"previousRGB":old,"sourceEvidence":diagnostic,
                    "interpretation":"Observed native contour RGB supported by bounded bright interiors; no inferred intrinsic pigment or width",
                    "preservedFields":"Original index, classifier probability, presence, nominal width/interval and every other style output"] as D
                result["outline"]=outline
            }
            return(result,diagnostic)
        }
        if try brightEligible(prediction) {diagnostic["brightRingCandidateCount"]=candidates.count;diagnostic["brightRingConfirmed"]=false}
        return(result,diagnostic)
    }
    func brightInteriors(_ prediction:D,diagnostic:D) throws -> [InteriorBody] {
        typealias L=NativeAppearanceLateGradient
        if L.part(prediction,"outline")["present"] as? Bool != true {return []}
        let color=L.vector(L.part(diagnostic,"sourceObservation")["rgb"]),outline=try labs([color])[0],chroma=hypot(outline[1],outline[2])
        if chroma<20 {return []}
        let ring=(0..<n).map {p -> UInt8 in
            let l=lab(p),pc=hypot(l[1],l[2]),cosine=(l[1]*outline[1]+l[2]*outline[2])/max(1e-6,pc*chroma)
            return L.d(l,outline)<=10 || (cosine>=0.96 && pc>=max(15,chroma*0.4) && abs(l[0]-outline[0])<30) ? 1:0
        }
        let closed=try ops.close(ring,width:w,height:h,size:3),filled=try ops.fillHoles(closed,width:w,height:h)
        let holes=(0..<n).map {filled[$0] != 0 && closed[$0]==0 ? UInt8(1):0},cc=try component(holes)
        var bodies:[InteriorBody]=[]
        for id in 1..<cc.areas.count where cc.areas[id]>=6 {
            let positions=(0..<n).filter {cc.labels[$0]==Int32(id)},seeds=positions.filter {roi[$0] != 0}.count
            if seeds<3 || Double(positions.filter {input.ownMask[$0] != 0}.count)/Double(positions.count)<0.8 {continue}
            let distance=try exactDepth(mask(positions)),inner=positions.filter {distance[$0]>1.5}
            if inner.count<6 {continue}
            bodies.append(.init(positions:inner,support:inner.map {supported($0)},bodyPixels:positions.count,id:id))
        }
        return bodies
    }
    func confirmedBodies(_ diagnostic:D) throws -> ([UInt8],[D]) {
        typealias L=NativeAppearanceLateGradient
        let semantic=L.part(diagnostic,"semantic"),observation=L.part(diagnostic,"sourceObservation")
        var core=[UInt8](repeating:0,count:n),certificates:[D]=[]
        if diagnostic["mechanism"] as? String=="bounded-bright-interiors" {
            if semantic["accepted"] as? Bool != true {return(core,[])}
            let native=try family(L.vector(observation["candidateRGB"])),closed=try ops.close(native,width:w,height:h,size:3),cc=try component(closed)
            let holes=L.rows(observation["holes"]),support=L.rows(semantic["holes"])
            guard holes.count==support.count else {throw NativeOpenCV.Failure.native("Bright certificate correspondence")}
            for (hole,s) in zip(holes,support) where s["confirmed"] as? Bool == true {
                let label=Int(L.number(hole["component"])),identity=Int(L.number(hole["hole"]))
                let ring=cc.labels.map {$0==Int32(label) ? UInt8(1):0},filled=try ops.fillHoles(ring,width:w,height:h)
                let interior=(0..<n).map {filled[$0] != 0 && ring[$0]==0 ? UInt8(1):0},hc=try component(interior)
                let body=hc.labels.map {$0==Int32(identity) ? UInt8(1):0},area=body.filter {$0 != 0}.count
                guard area==Int(L.number(hole["nativeArea"])) else {throw NativeOpenCV.Failure.native("Fresh bright topology mismatch")}
                for p in 0..<n where body[p] != 0 {core[p]=1}
                certificates.append(["kind":"bright-hole","nativeArea":area,"sourceComponent":label,"sourceHole":identity])
            }
        } else {
            for group in L.rows(semantic["groups"]) {
                let seeds=L.rows(group["seeds"]).filter {$0["confirmed"] as? Bool == true}
                if L.number(group["confirmedSeeds"])<3 || seeds.count<3 {continue}
                guard seeds.count==Int(L.number(group["confirmedSeeds"])) else {throw NativeOpenCV.Failure.native("Gradient certificate count")}
                for seed in seeds {
                    let xy=L.vector(seed["xy"])
                    guard xy.count==2,xy[0]>=0,xy[1]>=0,xy[0]<Double(w),xy[1]<Double(h),let body=flood(Int(xy[1])*w+Int(xy[0])) else {throw NativeOpenCV.Failure.native("Invalid certified gradient body")}
                    for p in 0..<n where body[p] != 0 {core[p]=1}
                    certificates.append(["kind":"gradient-body","nativeArea":body.filter {$0 != 0}.count,"seedXY":xy])
                }
            }
        }
        if certificates.count<3 {core=[UInt8](repeating:0,count:n)}
        return(core,certificates)
    }
}
