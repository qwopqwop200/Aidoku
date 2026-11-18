import Foundation

enum NativeAppearancePalettes {
    static func background(_ input:SourceNativeInput,packet:NativeAppearanceSourceFeatures209.Packet,prediction:[String:Any],
                           heads:NativeAppearanceModelHeads,ops:any NativeAppearanceImageOperations) throws -> [String:Any] {
        let config=try heads.configuration("appearance/background-palette")
        guard let fill=prediction["fillIndex"] as? Int,let outline=prediction["outlineIndex"] as? Int,
              var background=prediction["background"] as? [String:Any] else {throw NativeAppearanceModelHeads.Failure.invalidOutput("background palette")}
        let w=input.width,h=input.height,n=w*h,labs=try ops.lab(colors:packet.colors)
        let pixels=try ops.lab(rgb:input.rgb,width:w,height:h)
        func distance(_ p:Int,_ color:[Float])->Float {
            let x=pixels[p*3]-color[0],y=pixels[p*3+1]-color[1],z=pixels[p*3+2]-color[2]
            return (x*x+y*y)+z*z
        }
        let step=max(1,n/150_000),sample=Array(stride(from:0,to:n,by:step))
        var mass=[Double](repeating:0,count:labs.count)
        for p in sample where input.contextMask[p]==0 {
            var chosen=0,best=distance(p,labs[0])
            for c in labs.indices.dropFirst() {let d=distance(p,labs[c]);if d<best {chosen=c;best=d}}
            mass[chosen]+=1
        }
        let total=max(1,mass.reduce(0,+));mass=mass.map {$0/total}
        var matrix=packet.role("background",fill:fill,outline:outline)
        let visible=(0..<n).filter {input.contextMask[$0]==0},nearOwn=(0..<n).filter {input.ownMask[$0]==0}
        let border=visible.filter {$0/w==0 || $0/w==h-1 || $0%w==0 || $0%w==w-1}
        for c in labs.indices {
            let visibleFraction=Double(visible.filter {distance($0,labs[c])<=100}.count)/Double(max(1,visible.count))
            let borderFraction=Double(border.filter {distance($0,labs[c])<=100}.count)/Double(max(1,border.count))
            let nearFraction=Double(nearOwn.filter {distance($0,labs[c])<=100}.count)/Double(max(1,nearOwn.count))
            matrix[c] += [Float(mass[c]),Float(visibleFraction),Float(borderFraction),Float(nearFraction),Float(Double(visible.count)/Double(n))]
        }
        let scores=try heads.positive("appearance/background-palette/classifier",matrix)
        let threshold=try NativeAppearanceModelHeads.number(config,"threshold")
        let maxColors=Int(try NativeAppearanceModelHeads.number(config,"maxColors"))
        var candidates=NativeAppearanceNumeric.numpyArgSort(scores.map(-)).filter {scores[$0]>=threshold}
        if candidates.isEmpty {
            var best=0;for i in scores.indices.dropFirst() where scores[i]>scores[best] {best=i}
            candidates=[best]
        }
        var selected:[Int]=[]
        for c in candidates {
            if selected.allSatisfy({NativeAppearancePhysicalImage.distance(labs[c],labs[$0])>=6}) {selected.append(c)}
            if selected.count>=maxColors {break}
        }
        var weights=[Double](repeating:0,count:selected.count)
        for c in labs.indices {
            var best=0,d=NativeAppearancePhysicalImage.distance(labs[c],labs[selected[0]])
            for i in selected.indices.dropFirst() {
                let next=NativeAppearancePhysicalImage.distance(labs[c],labs[selected[i]])
                if next<d {best=i;d=next}
            }
            weights[best]+=mass[c]
        }
        let weightTotal=weights.reduce(0,+)
        if weightTotal>0 {weights=weights.map {$0/weightTotal}}
        background["colors"]=selected.map {packet.colors[$0]}
        background["observedContextWeights"]=weightTotal>0 ? weights as Any:NSNull()
        background["candidateScores"]=selected.map {scores[$0]}
        background["representation"]="observed-context-palette"
        background["insufficientObservedContext"]=weightTotal==0
        background["intrinsicBackgroundUnderGlyphsRecovered"]=false
        background["version"]="observed-background-palette-v1"
        background["contextExclusionPolicy"]="caller-predicted-text-union"
        var result=prediction;result["background"]=background;return result
    }
    static func pixelRoles(_ input:SourceNativeInput,featurePrediction:[String:Any],sourcePrediction:[String:Any],
                           heads:NativeAppearanceModelHeads,ops:any NativeAppearanceImageOperations) throws -> [String:Any] {
        let config=try heads.configuration("appearance/pixel-role-model")
        let fields=try ["fill","outline","background"].map {key -> [String:Any] in
            guard let value=featurePrediction[key] as? [String:Any] else {throw NativeAppearanceModelHeads.Failure.invalidMetadata(key)}
            return value
        }
        guard let fill=fields[0]["rgb"] as? [Double],let outline=fields[1]["rgb"] as? [Double],
              let background=fields[2]["rgb"] as? [Double],let present=fields[1]["present"] as? Bool else {
            throw NativeAppearanceModelHeads.Failure.invalidOutput("pixel feature prediction")
        }
        let probability=try NativeAppearanceModelHeads.number(fields[1],"probability")
        let n=input.width*input.height,step=max(1,(n+4095)/4096),positions=Array(stride(from:0,to:n,by:step))
        let matrix=try NativeAppearancePixelFeatures71.extract(input,positions:positions,fill:fill,outline:outline,
            background:background,outlinePresent:present,outlineProbability:probability,ops:ops)
        let model=try heads.model("appearance/pixel-role-model/classifier")
        let scores=try model.predictProbability(matrix.map {$0.map(Double.init)})
        let threshold=try NativeAppearanceModelHeads.number(config,"probabilityThreshold")
        let thresholds=config["roleProbabilityThresholds"] as? [String:Double] ?? [:]
        let shadowPresent=(sourcePrediction["shadow"] as? [String:Any])?["present"] as? Bool == true
        var roles:[String:Any]=[:]
        for (id,name) in ["fill","outline","background","shadowComposite"].enumerated() {
            guard let column=model.classes.firstIndex(of:Double(id)) else {continue}
            let probabilities=scores.map {$0[column]}
            let selected=positions.indices.filter {probabilities[$0] >= (thresholds[name] ?? threshold) && (name != "shadowComposite" || shadowPresent)}
            var observed:[[String:Any]]=[]
            if selected.count>=8 {
                var masses=[Double](repeating:0,count:4096),members=[Int:[Int]]()
                for i in selected {
                    let p=positions[i],rgb=input.rgb
                    let code=Int(rgb[p*3]/16)*256+Int(rgb[p*3+1]/16)*16+Int(rgb[p*3+2]/16)
                    masses[code]+=probabilities[i];members[code,default:[]].append(p)
                }
                let total=masses.reduce(0,+)
                for code in NativeAppearanceNumeric.numpyArgSort(masses.map(-)).prefix(3) where masses[code]>=max(0.05*total,1) {
                    let color=(0..<3).map {channel in
                        NativeAppearanceNumeric.quantile(members[code]!.map {Double(input.rgb[$0*3+channel])},0.5).rounded(.toNearestOrEven)
                    }
                    observed.append(["rgb":color,"observedMass":masses[code]/total])
                }
            }
            roles[name]=["meanProbability":probabilities.reduce(0,+)/Double(max(1,probabilities.count)),
                "confidentSamples":selected.count,"observedColours":observed]
        }
        return ["version":"source-pixel-paint-role-v1","samples":positions.count,"GTAtInference":false,"roles":roles,
            "shadowColourSemantics":"Observed composite colours only; intrinsic shadow colour/opacity/blur are not identified",
            "featureContextPolicy":"source-independent-paint-feature-context-v1"]
    }

    static func fill(_ packet:NativeAppearanceSourceFeatures209.Packet,prediction:[String:Any],
                     heads:NativeAppearanceModelHeads,ops:any NativeAppearanceImageOperations) throws -> [String:Any] {
        let config=try heads.configuration("appearance/source-fill-palette-model")
        guard let original=prediction["fill"] as? [String:Any],let primary=original["rgb"] as? [Double],
              let outline=prediction["outline"] as? [String:Any],let present=outline["present"] as? Bool,
              let pixel=prediction["pixelRoleEvidence"] as? [String:Any],let roles=pixel["roles"] as? [String:Any] else {
            throw NativeAppearanceModelHeads.Failure.invalidOutput("source fill palette")
        }
        let baseline=(roles["fill"] as? [String:Any])?["observedColours"] as? [[String:Any]] ?? []
        var selected=baseline
        let threshold=try NativeAppearanceModelHeads.number(config,"threshold")
        let merge=try NativeAppearanceModelHeads.number(config,"mergeDelta")
        let limit=Int(try NativeAppearanceModelHeads.number(config,"limit"))
        if threshold<=1 {
            let labs=try ops.lab(colors:packet.colors)
            let reference=try ["fill","outline","background"].map {key -> [Float] in
                guard let rgb=(prediction[key] as? [String:Any])?["rgb"] as? [Double] else {
                    throw NativeAppearanceModelHeads.Failure.invalidOutput(key)
                }
                return try ops.lab(colors:[rgb])[0]
            }
            let probability=try NativeAppearanceModelHeads.number(outline,"probability")
            let matrix=packet.features.indices.map {i -> [Float] in
                var row=packet.features[i]
                for color in reference {
                    let delta=zip(labs[i],color).map {$0-$1}
                    row += delta.map {$0/100}
                    row.append(sqrt(delta.reduce(0) {$0+$1*$1})/100)
                }
                row += [present ? 1:0,Float(probability)]
                return row
            }
            let scores=try heads.positive("appearance/source-fill-palette-model/classifier",matrix)
            for i in NativeAppearanceNumeric.numpyArgSort(scores.map(-)) {
                if scores[i]<threshold {break}
                let current=[primary]+selected.compactMap {$0["rgb"] as? [Double]}
                let currentLabs=try ops.lab(colors:current)
                if currentLabs.contains(where:{prior in sqrt(zip(prior,labs[i]).reduce(Float(0)) {$0+($1.0-$1.1)*($1.0-$1.1)})<=Float(merge)}) {continue}
                selected.append(["rgb":packet.colors[i],"sourcePaletteProbability":scores[i]])
                if selected.count>=limit {break}
            }
        }
        var result=prediction,updated=original
        updated["colors"]=[primary]+selected.compactMap {$0["rgb"] as? [Double]}
        updated["representation"]="source-fusion-observed-palette";updated["paletteVersion"]="source-full-fusion-fill-palette-v1"
        result["fill"]=updated
        result["sourceFillPaletteEvidence"]=["version":"source-full-fusion-fill-palette-v1","GTAtInference":false,
            "primaryColourPreserved":true,"pixelRoleColoursPreserved":true,"retainedPixelRoleColours":baseline.count,
            "addedColours":Array(selected.dropFirst(baseline.count)),
            "role":"Source observed colour hypotheses; not a spatial substyle or intrinsic shadow decomposition"] as [String:Any]
        return result
    }
}
