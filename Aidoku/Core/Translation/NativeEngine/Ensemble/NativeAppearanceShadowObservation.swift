import Foundation

enum NativeAppearanceShadowObservation {
    private static let version="source-observed-shadow-parameters-v4"
    private struct Proposal {var evidence:[String:Any];let rgb:[Double]?;let candidates:[[String:Any]]}
    private static func propose(_ input:SourceNativeInput,prediction:[String:Any],reference:[String:Any],
                                heads:NativeAppearanceModelHeads,ops:any NativeAppearanceImageOperations) throws -> Proposal {
        var result:[String:Any]=["version":version,"available":false,"rgb":NSNull(),"GTAtInference":false]
        guard (prediction["shadow"] as? [String:Any])?["present"] as? Bool == true else {
            result["reason"]="Source shadow presence is off";return .init(evidence:result,rgb:nil,candidates:[])
        }
        let w=input.width,h=input.height,n=w*h,f=input.fontPriorSourcePixels
        let radius=max(4,min(24,Int((0.2*f).rounded(.toNearestOrEven))))
        let referenceRadius=max(3,min(12,Int((0.08*f).rounded(.toNearestOrEven))))
        let positions=Array(stride(from:0,to:n,by:max(1,(n+4095)/4096))).filter {
            $0%w>=referenceRadius && $0%w<w-referenceRadius && $0/w>=referenceRadius && $0/w<h-referenceRadius
        }
        guard !positions.isEmpty else {
            result["reason"]="No bounded source samples";return .init(evidence:result,rgb:nil,candidates:[])
        }
        guard let refFill=(reference["fill"] as? [String:Any])?["rgb"] as? [Double],
              let refOutline=reference["outline"] as? [String:Any],let refStroke=refOutline["rgb"] as? [Double],
              let refBackground=(reference["background"] as? [String:Any])?["rgb"] as? [Double],
              let refPresent=refOutline["present"] as? Bool else {throw NativeAppearanceModelHeads.Failure.invalidOutput("shadow feature context")}
        let matrix=try NativeAppearancePixelFeatures71.extract(input,positions:positions,fill:refFill,outline:refStroke,
            background:refBackground,outlinePresent:refPresent,
            outlineProbability:NativeAppearanceModelHeads.number(refOutline,"probability"),ops:ops)
        let model=try heads.model("appearance/pixel-role-model/classifier")
        guard let column=model.classes.firstIndex(of:3) else {
            result["reason"]="Source classifier has no shadow-composite class";return .init(evidence:result,rgb:nil,candidates:[])
        }
        let probabilities=try model.predictProbability(matrix.map {$0.map(Double.init)}).map {$0[column]}
        guard let fill=prediction["fill"] as? [String:Any],let fillRGB=fill["rgb"] as? [Double],
              let outline=prediction["outline"] as? [String:Any],let stroke=outline["rgb"] as? [Double] else {
            throw NativeAppearanceModelHeads.Failure.invalidOutput("shadow source paints")
        }
        var paints=[fillRGB]+(fill["colors"] as? [[Double]] ?? [])
        if outline["present"] as? Bool == true {paints.append(stroke)}
        let colors=try ops.lab(colors:paints),image=try ops.lab(rgb:input.rgb,width:w,height:h)
        let close=(0..<n).map {p in colors.contains {NativeAppearancePhysicalImage.distance(Array(image[p*3..<p*3+3]),$0)<=10}}
        let rawPaint=(0..<n).map {close[$0] && input.ownMask[$0] != 0 ? UInt8(1):0}
        let roi=try ops.raster(polygons:input.memberPolygons,width:w,height:h)
        let components=try NativeAppearancePhysicalImage.components(rawPaint,width:w,height:h)
        var seeded=[Int](repeating:0,count:components.areas.count)
        for p in 0..<n where roi[p] != 0 {seeded[Int(components.labels[p])]+=1}
        let paint=components.labels.map {$0>0 && seeded[Int($0)]>=3 ? UInt8(1):0}
        guard paint.filter({$0 != 0}).count>=20 else {
            result["reason"]="Insufficient owned source paint";return .init(evidence:result,rgb:nil,candidates:[])
        }
        let distance=try ops.distance(paint.map {$0==0 ? 1:0},width:w,height:h,maskSize:5)
        var referenceRGB=[UInt8](repeating:0,count:n*3)
        for c in 0..<3 {
            let channel=(0..<n).map {input.rgb[$0*3+c]}
            let dilated=try ops.dilate(channel,width:w,height:h,radius:referenceRadius,ellipse:false)
            for p in 0..<n {referenceRGB[p*3+c]=dilated[p]}
        }
        let refLab=try ops.lab(rgb:referenceRGB,width:w,height:h)
        let near=(0..<n).map {distance[$0]>0 && distance[$0]<=Float(radius) && !close[$0]}
        let physical=(0..<n).map {p -> Bool in
            guard near[p],refLab[p*3]-image[p*3]>=5 else {return false}
            let ratios=(0..<3).map {c in (Double(referenceRGB[p*3+c])-Double(input.rgb[p*3+c]))/max(32,Double(referenceRGB[p*3+c]))}
            return ratios.max()!-ratios.min()!<=0.1 && ratios.min()!>=0
        }
        let config=try heads.configuration("appearance/pixel-role-model")
        let thresholds=config["roleProbabilityThresholds"] as? [String:Double] ?? [:]
        let threshold=try thresholds["shadowComposite"] ?? NativeAppearanceModelHeads.number(config,"probabilityThreshold")
        var hypotheses:[[String:Any]]=[],support:[String:Any]=[:]
        for (name,selected) in [("physical-neighborhood",positions.indices.filter {physical[positions[$0]]}),
                                ("confident-role-neighborhood",positions.indices.filter {near[positions[$0]] && probabilities[$0]>=threshold})] {
            let rgb=selected.map {i in (0..<3).map {Double(input.rgb[positions[i]*3+$0])}}
            let clusters=try NativeAppearanceColorNeighborhoods.clusters(rgb:rgb,weights:selected.map {1+probabilities[$0]},ops:ops)
            let dominant=NativeAppearanceColorNeighborhoods.dominant(clusters)
            support[name]=["colours":clusters,"dominanceRatio":2.0,"clearDominant":dominant != nil]
            if var candidate=dominant {candidate["origin"]=name;hypotheses.append(candidate)}
        }
        result["candidateHypotheses"]=hypotheses;result["sourcePaletteSupport"]=support
        func finish(_ reason:String)->Proposal {var output=result;output["reason"]=reason;return .init(evidence:output,rgb:nil,candidates:hypotheses)}
        let selected=positions.indices.filter {physical[positions[$0]]}
        result["samples"]=selected.count
        guard selected.count>=30 else {return finish("Insufficient physical fringe support")}
        var masses=[Double](repeating:0,count:4096),bins=[Int:[Int]]()
        for i in selected {
            let p=positions[i],rgb=input.rgb
            let code=Int(rgb[p*3]/16)*256+Int(rgb[p*3+1]/16)*16+Int(rgb[p*3+2]/16)
            masses[code]+=1+probabilities[i];bins[code,default:[]].append(i)
        }
        var code=0;for i in masses.indices.dropFirst() where masses[i]>masses[code] {code=i}
        let total=masses.reduce(0,+),members=bins[code] ?? []
        guard members.count>=8,masses[code]>=max(0.05*total,1) else {return finish("Insufficient observed colour-mode support")}
        var cells:[String:Int]=[:]
        for i in members {let p=positions[i];cells["\(Int(floor(Double(p%w)/max(1,f)))):\(Int(floor(Double(p/w)/max(1,f))))",default:0]+=1}
        let repeated=cells.values.filter {$0>=3}.count
        guard repeated>=2 else {return finish("Observed colour does not repeat across source cells")}
        let median=(0..<3).map {c in NativeAppearanceNumeric.quantile(members.map {Double(input.rgb[positions[$0]*3+c])},0.5)}
        var chosen=members[0],best=Double.infinity
        for i in members {
            let d=(0..<3).reduce(0) {s,c in let v=Double(input.rgb[positions[i]*3+c])-median[c];return s+v*v}
            if d<best {chosen=i;best=d}
        }
        let color=(0..<3).map {Double(input.rgb[positions[chosen]*3+$0])}
        result.merge(["available":true,"reason":"Native neutral fringe with bounded RF/pixel/OCR support","rgb":color,
            "modeSamples":members.count,"repeatedSpatialBins":repeated,"observedMass":masses[code]/total,
            "meanSourceShadowRoleProbability":members.reduce(0) {$0+probabilities[$1]}/Double(members.count),
            "weightPolicy":"one native vote plus bounded source-role probability"]) {_,new in new}
        return .init(evidence:result,rgb:color,candidates:hypotheses)
    }

    static func apply(input:SourceNativeInput,prediction:[String:Any],featurePrediction:[String:Any],referenceWidth:Double,
                      heads:NativeAppearanceModelHeads,ops:any NativeAppearanceImageOperations) throws -> [String:Any] {
        guard var shadow=prediction["shadow"] as? [String:Any],let baseline=shadow["present"] as? Bool else {
            throw NativeAppearanceModelHeads.Failure.invalidOutput("source shadow")
        }
        let policies=try heads.configuration("appearance/policies")
        guard let policy=policies["SHADOW-OBSERVATION-POLICY.json"] as? [String:Any] else {throw NativeAppearanceInferenceGraph.Failure.invalidPolicy("shadow observation")}
        let threshold=try NativeAppearanceModelHeads.number(policy,"minimumUncorroboratedProbability")
        var descriptor=prediction
        if var outline=descriptor["outline"] as? [String:Any] {outline["widthPx"]=referenceWidth;descriptor["outline"]=outline}
        if baseline {
            let proposal=try propose(input,prediction:descriptor,reference:featurePrediction,heads:heads,ops:ops)
            var displacement=try NativeAppearanceShadowDisplacement.estimate(input,prediction:descriptor,
                observedRGB:proposal.rgb,referenceWidth:referenceWidth,ops:ops)
            var trials:[[String:Any]]=[]
            if displacement["identified"] as? Bool != true {
                var seen:[[Double]]=[],best:[String:Any]?,quality:(Double,Double)?
                for candidate in proposal.candidates {
                    guard let rgb=candidate["rgb"] as? [Double],!seen.contains(rgb) else {continue};seen.append(rgb)
                    let trial=try NativeAppearanceShadowDisplacement.estimate(input,prediction:descriptor,
                        observedRGB:rgb,referenceWidth:referenceWidth,ops:ops)
                    trials.append(["candidate":candidate,"evidence":trial])
                    if trial["identified"] as? Bool == true {
                        let v=try NativeAppearanceModelHeads.number(trial,"sourceValidationF1"),t=try NativeAppearanceModelHeads.number(trial,"sourceTrainingF1")
                        if quality==nil || v>quality!.0 || (v==quality!.0 && t>quality!.1) {best=trial;quality=(v,t)}
                    }
                }
                if let best {displacement=best}
            }
            var observation:[String:Any]=["version":version,"proposal":proposal.evidence,"displacement":displacement,"candidateTrials":trials,
                "widthContext":["version":"independent-source-geometry-for-adaptive-width-v1","sourceOnly":true,"GTAtInference":false,
                    "referenceWidthPx":referenceWidth,"emittedStyleWidthPx":(prediction["outline"] as? [String:Any])?["widthPx"] ?? NSNull(),
                    "semantics":"Existing base source regressor silhouette, independent of the replacement nominal-width head"]]
            if displacement["identified"] as? Bool == true {
                if shadow["rgb"]==nil || shadow["rgb"] is NSNull {shadow["rgb"]=displacement["observedCompositeRGB"];shadow["rgbInterpretation"]="observed-source-composite"}
                if shadow["offsetPx"]==nil || shadow["offsetPx"] is NSNull {shadow["offsetPx"]=displacement["offsetPx"];shadow["offsetInterpretation"]="component-validated-visible-paint-displacement"}
            }
            if (descriptor["outline"] as? [String:Any])?["present"] as? Bool != true,
               shadow["rgb"]==nil || shadow["rgb"] is NSNull || shadow["rgbInterpretation"] as? String == "observed-dark-shadow-core-on-mixed-background" {
                let glow=try NativeAppearanceDiffuseGlow.observe(input:input,prediction:descriptor,ops:ops)
                if let glow {
                    observation["diffuseGlow"]=glow
                    if let paint=glow["paint"] as? [String:Any],paint["identified"] as? Bool == true {
                        shadow["rgb"]=paint["rgb"];shadow["rgbInterpretation"]="observed-dark-shadow-core-on-mixed-background"
                    }
                }
            }
            shadow["sourceObservation"]=observation
        }
        var observation=shadow["sourceObservation"] as? [String:Any] ?? [:]
        let displacement=(observation["displacement"] as? [String:Any])?["identified"] as? Bool == true
        let glow=((observation["diffuseGlow"] as? [String:Any])?["profile"] as? [String:Any])?["identified"] as? Bool == true
        let probability=try NativeAppearanceModelHeads.number(shadow,"probability")
        let present=baseline && (probability>=threshold || displacement || glow)
        var result=prediction
        var rawRole:Any=NSNull()
        if var pixel=result["pixelRoleEvidence"] as? [String:Any],var roles=pixel["roles"] as? [String:Any],var role=roles["shadowComposite"] as? [String:Any] {
            rawRole=role
            if !present {role["confidentSamples"]=0;role["observedColours"]=[] as [[String:Any]];roles["shadowComposite"]=role;pixel["roles"]=roles;result["pixelRoleEvidence"]=pixel}
        }
        observation["presenceRefinement"]=["version":"source-shadow-confidence-and-structure-v1","baselinePresent":baseline,
            "baselineProbability":probability,"minimumUncorroboratedProbability":threshold,"independentNativeSupport":displacement || glow,
            "rawShadowRoleEvidence":rawRole] as [String:Any]
        shadow["probabilityInterpretation"]="pre-refinement-region-classifier-probability"
        shadow["present"]=present;shadow["sourceObservation"]=observation;result["shadow"]=shadow
        return result
    }
}
