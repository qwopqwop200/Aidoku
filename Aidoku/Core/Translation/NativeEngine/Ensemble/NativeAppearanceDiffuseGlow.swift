import Foundation

/// Accepted finite source dip/recovery policy. Observed composite paint never
/// supplies an intrinsic pigment, opacity, displacement or blur estimate.
enum NativeAppearanceDiffuseGlow {
    private struct Ray {
        let component:Int,sector:Int,rgb:[Double],attenuation:Double
    }
    private struct Count {var eligible=0,censored=0,positive=0,sectors=[Int](repeating:0,count:4)}
    private static func q(_ values:[Double],_ p:Double=0.5)->Double {NativeAppearanceNumeric.quantile(values,p)}
    private static func span(_ values:[Double])->Double {(values.max() ?? 0)-(values.min() ?? 0)}
    private static func fraction(_ values:[Bool])->Double {Double(values.filter {$0}.count)/Double(max(1,values.count))}
    private static func medoid(_ colors:[[Double]],ops:any NativeAppearanceImageOperations) throws -> [Double] {
        let labs=try ops.lab(colors:colors),center=(0..<3).map {c in q(labs.map {Double($0[c])})}
        var best=0,distance=Double.infinity
        for i in colors.indices {
            let d=(0..<3).reduce(0.0) {$0+pow(Double(labs[i][$1])-center[$1],2)}
            if d<distance {best=i;distance=d}
        }
        return colors[best]
    }
    private static func dip(pixels:[[Double]],steps:[Int],start:Int,depth:Int,paints:[[Float]],
                            ops:any NativeAppearanceImageOperations) throws -> (rgb:[Double]?,attenuation:Double,reason:String) {
        func no(_ reason:String)->([Double]?,Double,String) {(nil,0,reason)}
        let image=try ops.lab(colors:pixels),referenceIDs=steps.indices.filter {steps[$0]>=depth-3 && steps[$0]<=depth}
        let control=steps.indices.filter {steps[$0]>=depth+2}
        guard referenceIDs.count>=3,control.count>=4 else {return no("insufficient-finite-reference-or-control")}
        let reference=(0..<3).map {c in q(referenceIDs.map {pixels[$0][c]})}
        let referenceLab=try ops.lab(colors:[reference])[0]
        guard span(referenceIDs.map {Double(image[$0][0])})<=6 else {return no("nonplateau-exterior")}
        guard span(control.map {Double(image[$0][0])})<=8,abs(q(control.map {Double(image[$0][0])})-Double(referenceLab[0]))<=6 else {
            return no("shared-background-control-varies")
        }
        let ratios=pixels.map {pixel in (0..<3).map {(reference[$0]-pixel[$0])/max(reference[$0],32)}}
        let neutral=ratios.map {span($0)<=0.1 && $0.min()! >= -0.03}
        let close=image.map {color in paints.contains {NativeAppearancePhysicalImage.distance(color,$0)<=8}}
        let near=steps.indices.filter {steps[$0]>=start && steps[$0]<=min(depth-6,start+max(4,depth/2)) && !close[$0] && neutral[$0]}
        guard let peak=near.min(by:{image[$0][0]<image[$1][0]}) else {return no("no-unoccluded-neutral-dip")}
        let dark=image.map {Double(referenceLab[0]-$0[0])}
        guard dark[peak]>=8 else {return no("insufficient-dark-dip")}
        let sequence=steps.indices.filter {steps[$0]>=steps[peak] && steps[$0]<=depth-3 && neutral[$0] && !close[$0]}
        guard sequence.count>=5 else {return no("short-recovery-native-support")}
        guard sequence.filter({dark[$0]>=8}).count>=3 else {return no("thin-AA-or-crisp-edge")}
        guard zip(sequence.dropFirst(),sequence).allSatisfy({$0-$1<=1}) else {return no("recovery-interrupted-by-paint-or-chroma")}
        let light=sequence.map {Double(image[$0][0])},rises=zip(light.dropFirst(),light).map {$0-$1}
        guard rises.filter({$0>=1}).count>=3,fraction(rises.map {$0 >= -1})>=0.75 else {return no("not-smooth-multistep-recovery")}
        guard light.last!-light[0]>=6 else {return no("no-finite-recovery")}
        return (pixels[peak],q(ratios[peak]),"observed-dip-smooth-recovery")
    }

    static func observe(input:SourceNativeInput,prediction:[String:Any],ops:any NativeAppearanceImageOperations) throws -> [String:Any]? {
        guard let fill=prediction["fill"] as? [String:Any],let rgb=fill["rgb"] as? [Double],
              let outline=prediction["outline"] as? [String:Any],
              let background=(prediction["background"] as? [String:Any])?["rgb"] as? [Double] else {
            throw NativeAppearanceModelHeads.Failure.invalidOutput("glow source colors")
        }
        let colors=try ops.lab(colors:[rgb,background]),contrast=Double(NativeAppearancePhysicalImage.distance(colors[0],colors[1]))
        // The accepted caller only invokes the local-core policy in this case.
        guard outline["present"] as? Bool != true,contrast<8 else {return nil}
        let w=input.width,h=input.height,n=w*h,f=input.fontPriorSourcePixels,minimum=max(12,f*f*0.005)
        let image=try ops.lab(rgb:input.rgb,width:w,height:h),roi=try ops.raster(polygons:input.memberPolygons,width:w,height:h)
        let delta=(0..<n).map {Double(NativeAppearancePhysicalImage.distance(Array(image[$0*3..<$0*3+3]),colors[0]))}
        let similar=(0..<n).map {delta[$0]<=max(3,min(18,contrast*0.35)) && input.ownMask[$0] != 0 ? UInt8(1):0}
        let components=try NativeAppearancePhysicalImage.components(similar,width:w,height:h)
        var seeds=[Int](repeating:0,count:components.areas.count)
        for p in 0..<n where roi[p] != 0 {seeds[Int(components.labels[p])]+=1}
        var core=[UInt8](repeating:0,count:n),accepted:[[String:Any]]=[],censored=0
        for id in components.areas.indices.dropFirst() where Double(components.areas[id])>=minimum && seeds[id]>=3 {
            let b=components.bounds[id]
            if b.minX<3 || b.minY<3 || b.maxX+3>Double(w) || b.maxY+3>Double(h) {censored+=1;continue}
            let component=components.labels.map {$0==Int32(id) ? UInt8(1):0}
            let dilated=try ops.dilate(component,width:w,height:h,radius:3,ellipse:false)
            let ring=(0..<n).filter {dilated[$0] != 0 && similar[$0]==0}
            guard ring.count>=8 else {continue}
            let lower=q(ring.map {delta[$0]},0.25),median=q(ring.map {delta[$0]})
            guard lower>=3,median>=8 else {continue}
            for p in 0..<n where component[p] != 0 {core[p]=1}
            accepted.append(["nativePixels":components.areas[id],"lowerBoundaryDeltaE":lower,"medianBoundaryDeltaE":median])
        }
        let pixels=core.filter {$0 != 0}.count,used=accepted.count>=3 && pixels>=20
        let coreEvidence:[String:Any]=["version":"source-locally-supported-fill-core-v1","usedLocalFallback":used,
            "GTAtInference":false,"contextExpanded":false,"globalFillBackgroundDeltaE":contrast,
            "finiteContrastingComponents":accepted,"censoredComponents":censored,"nativeCorePixels":pixels,
            "reason":used ? "Repeated native fill components contrast against their own local exterior":"Insufficient repeated finite local boundary support"]
        var profile:[String:Any]=["version":"source-native-dip-recovery-glow-v2","policy":"three-pixel-dip","identified":false,
            "observedRGB":NSNull(),"intrinsicRGB":NSNull(),"offsetPx":NSNull(),"blurRadiusPx":NSNull(),"opacity":NSNull(),
            "GTAtInference":false,"contextExpanded":false,"coreEvidence":coreEvidence]
        func finish(_ reason:String)->[String:Any] {profile["reason"]=reason;return ["profile":profile,"paint":NSNull()]}
        guard used else {return finish("No locally separated source core")}
        let cc=try NativeAppearancePhysicalImage.components(core,width:w,height:h)
        let ids=Array(cc.areas.indices.dropFirst().filter {Double(cc.areas[$0])>=minimum}.sorted {
            cc.areas[$0]==cc.areas[$1] ? $0<$1:cc.areas[$0]>cc.areas[$1]
        }.prefix(12))
        guard ids.count>=3 else {profile["components"]=ids.count;return finish("Fewer than three source components")}
        let inside=try ops.distance(core,width:w,height:h,maskSize:5)
        let outside=try ops.distance(core.map {$0==0 ? 1:0},width:w,height:h,maskSize:5)
        let smooth=try NativeAppearancePhysicalImage.gaussian(zip(inside,outside).map {$0-$1},width:w,height:h,sigma:1)
        let gradient=NativeAppearancePhysicalImage.gradient(smooth,width:w,height:h)
        let nearest=try NativeAppearanceEuclideanDistance.transform(seed:core,width:w,height:h).nearest
        let eroded=try NativeAppearancePhysicalImage.erode(core,width:w,height:h)
        var edge=(0..<n).filter {core[$0] != 0 && eroded[$0]==0 && ids.contains(Int(cc.labels[$0]))}
        if edge.count>1600 {let original=edge;edge=(0..<1600).map {original[Int(Double($0)*Double(original.count-1)/1599)]}}
        let start=1,depth=max(11,min(32,max(10,Int((f*0.25).rounded(.toNearestOrEven)))))
        let paints=try ops.lab(colors:[rgb]+(fill["colors"] as? [[Double]] ?? []))
        var counts=Dictionary(uniqueKeysWithValues:ids.map {($0,Count())}),reasons:[String:Int]=[:],positive:[Ray]=[]
        for p in edge {
            let norm=hypot(gradient.x[p],gradient.y[p]);if norm<=0.2 {continue}
            let dx = -gradient.x[p]/norm,dy = -gradient.y[p]/norm,id=Int(cc.labels[p])
            var positions:[Int]=[],steps:[Int]=[],outsideCrop=false
            for step in 0..<(depth+9) {
                let x=Int((Float(p%w)+dx*Float(step)).rounded(.toNearestOrEven))
                let y=Int((Float(p/w)+dy*Float(step)).rounded(.toNearestOrEven))
                if x<0 || x>=w || y<0 || y>=h {outsideCrop=true;break}
                if positions.last != y*w+x {positions.append(y*w+x);steps.append(step)}
            }
            if outsideCrop {counts[id]!.censored+=1;reasons["outside-real-crop",default:0]+=1;continue}
            if positions.contains(where:{cc.labels[nearest[$0]] != Int32(id)}) {
                counts[id]!.censored+=1;reasons["other-component-context",default:0]+=1;continue
            }
            counts[id]!.eligible+=1
            let samples=positions.map {p in (0..<3).map {Double(input.rgb[p*3+$0])}}
            let ray=try dip(pixels:samples,steps:steps,start:start,depth:depth,paints:paints,ops:ops)
            reasons[ray.reason,default:0]+=1
            if let color=ray.rgb {
                // Match float32 angular sector arithmetic used by the source ABI.
                let angle=atan2(dy,dx)+Float.pi/4
                let wrapped=(angle.truncatingRemainder(dividingBy:2*Float.pi)+2*Float.pi).truncatingRemainder(dividingBy:2*Float.pi)
                let sector=Int(wrapped/(Float.pi/2))%4
                counts[id]!.positive+=1;counts[id]!.sectors[sector]+=1
                positive.append(.init(component:id,sector:sector,rgb:color,attenuation:ray.attenuation))
            }
        }
        let measured=ids.filter {counts[$0]!.eligible>=10}
        let evidence:[[String:Any]]=ids.map {id in let c=counts[id]!;return ["sourceComponent":id,"eligible":c.eligible,
            "censored":c.censored,"positive":c.positive,"sectors":c.sectors,"support":Double(c.positive)/Double(max(1,c.eligible))]}
        let eligible=counts.values.reduce(0) {$0+$1.eligible}
        profile.merge(["components":ids.count,"measuredComponents":measured.count,"rayReasons":reasons,"componentEvidence":evidence,
            "eligibleProfiles":eligible,"censoredProfiles":counts.values.reduce(0) {$0+$1.censored},
            "positiveProfiles":positive.count,"sourceProfileDepthPx":depth]) {_,new in new}
        guard measured.count>=3 else {return finish("Fewer than three independently observed profile components")}
        let fit=measured.enumerated().filter {$0.offset%2==0}.map(\.element),validation=measured.enumerated().filter {$0.offset%2==1}.map(\.element)
        let fitPositive=positive.filter {fit.contains($0.component)},valPositive=positive.filter {validation.contains($0.component)}
        guard !fitPositive.isEmpty,!valPositive.isEmpty else {return finish("Dip/recovery absent on component fit or validation side")}
        let color=try medoid(fitPositive.map(\.rgb),ops:ops),colorLab=try ops.lab(colors:[color])[0]
        let valLabs=try ops.lab(colors:valPositive.map(\.rgb))
        let colorAgreement=fraction(valLabs.map {NativeAppearancePhysicalImage.distance($0,colorLab)<=10})
        let sectors=(0..<4).map {s in positive.filter {$0.sector==s}.count}
        func supported(_ id:Int)->Bool {let c=counts[id]!;return c.positive>=3 && Double(c.positive)/Double(max(1,c.eligible))>=0.1}
        let fitAgreement=fraction(fit.map(supported)),validationAgreement=fraction(validation.map(supported))
        let support=Double(positive.count)/Double(max(1,eligible))
        let identified=positive.count>=30 && support>=0.1 && sectors.filter({$0>=5}).count>=3 &&
            fitAgreement>=0.5 && validationAgreement>=0.5 && measured.filter(supported).count>=3 && colorAgreement>=0.5
        profile.merge(["identified":identified,"reason":identified ? "Repeated native dark dip and smooth exterior recovery":"Dip/recovery fails repeated component/background controls",
            "observedRGB":identified ? color as Any:NSNull(),"candidateObservedRGB":color,"profileSupport":support,"sectors":sectors,
            "fitComponents":fit.count,"validationComponents":validation.count,"fitComponentAgreement":fitAgreement,
            "validationComponentAgreement":validationAgreement,"validationObservedColourAgreement":colorAgreement,
            "semantics":"Observed source composite at repeated dip samples only; no intrinsic pigment, displacement, blur or opacity identified"]) {_,new in new}
        let paint:Any=identified ? try observedPaint(positive,measured:measured,background:background,ops:ops):NSNull()
        return ["profile":profile,"paint":paint]
    }

    private static func observedPaint(_ rays:[Ray],measured:[Int],background:[Double],ops:any NativeAppearanceImageOperations) throws -> [String:Any] {
        let version="source-shadow-background-normalized-composite-v2"
        var normalization:[String:Any]=["version":version,"identified":false,"rgb":NSNull(),"intrinsicRGB":NSNull(),
            "opacity":NSNull(),"blurRadiusPx":NSNull(),"GTAtInference":false,
            "semantics":"Conditional neutral-black attenuation applied to a predicted source background; not a unique intrinsic colour or opacity estimate"]
        func peaks(_ parity:Int)->[Double] {measured.enumerated().filter {$0.offset%2==parity}.compactMap {entry in
            let values=rays.filter {$0.component==entry.element}.map(\.attenuation);return values.count>=3 ? q(values,0.9):nil
        }}
        let fit=peaks(0),validation=peaks(1)
        if fit.count<2 || validation.count<2 {normalization["reason"]="Insufficient repeated attenuation observations"}
        else {
            let value=q(fit),agreement=fraction(validation.map {abs($0-value)<=0.1})
            let valid=value>=0.03 && value<=0.95 && agreement>=0.6 && validation.filter({abs($0-value)<=0.1}).count>=2
            let color=background.map {min(255,max(0,$0*(1-value))).rounded(.toNearestOrEven)}
            normalization.merge(["identified":valid,"rgb":valid ? color as Any:NSNull(),"candidateRGB":color,
                "conditionalPeakAttenuation":value,"fitComponentPeaks":fit,"validationComponentPeaks":validation,
                "validationAgreement":agreement,"reason":valid ? "Component attenuation repeats after local-background normalization":"Attenuation does not repeat on held-out source components"]) {_,new in new}
        }
        var result:[String:Any]=["version":version,"identified":false,"rgb":NSNull(),"intrinsicRGB":NSNull(),"opacity":NSNull(),
            "blurRadiusPx":NSNull(),"GTAtInference":false,"normalization":normalization,
            "semantics":"Native dark shadow-core sample with strong relative attenuation; normalization validates shared attenuation, not absolute RGB equality across backgrounds"]
        func no(_ reason:String)->[String:Any] {result["reason"]=reason;return result}
        guard normalization["identified"] as? Bool == true else {return no("Source attenuation is inconsistent")}
        let points=rays.filter {measured.contains($0.component)}
        guard points.count>=8 else {return no("Insufficient native shadow samples")}
        let labs=try ops.lab(colors:points.map(\.rgb)),attenuation=q(points.map(\.attenuation),0.9),light=q(labs.map {Double($0[0])},0.1)
        let selected=points.indices.filter {points[$0].attenuation>=attenuation && Double(labs[$0][0])<=light}
        var counts:[Int:Int]=[:];for i in selected {counts[points[i].component,default:0]+=1}
        let repeated=counts.values.filter {$0>=2}.count
        guard selected.count>=8,repeated>=2 else {result["nativeSamples"]=selected.count;return no("Strong dark paint is isolated rather than repeated")}
        let colors=selected.map {points[$0].rgb},color=try medoid(colors,ops:ops)
        result.merge(["identified":true,"rgb":color,"nativeActualSample":true,"nativeSamples":selected.count,
            "repeatedComponents":repeated,"observedRangeRGB":[0.1,0.9].map {p in (0..<3).map {c in q(colors.map {$0[c]},p)}},
            "reason":"Repeated native dark paint agrees with independently validated relative attenuation"]) {_,new in new}
        return result
    }
}
