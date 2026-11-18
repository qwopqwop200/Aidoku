import Foundation

enum NativeAppearanceFinalBackground {
    private struct Choice {let index:Int;let report:[String:Any]}
    private static func choose(_ features:[[Float]],baseline:Int,key:String,threshold:Double,observed:Bool,
                               heads:NativeAppearanceModelHeads) throws -> Choice {
        guard observed else {return .init(index:baseline,report:["chosenIndex":baseline,"thresholdPassed":false,"anchorsObserved":false])}
        let a=features[baseline]
        func pair(_ a:[Float],_ b:[Float])->[Float] {let delta=zip(b,a).map {$0-$1};return a+b+delta+delta.map {abs($0)}}
        let forward=try heads.positive(key,features.map {pair(a,$0)})
        let reverse=try heads.positive(key,features.map {pair($0,a)})
        var relative=zip(forward,reverse).map {($0+1-$1)/2};relative[baseline]=0.5
        var proposal=0
        for i in relative.indices.dropFirst() where relative[i]>relative[proposal] {proposal=i}
        let accepted=relative[proposal]>=threshold,index=accepted ? proposal:baseline
        return .init(index:index,report:["baselineIndex":baseline,"proposalIndex":proposal,"chosenIndex":index,
            "thresholdPassed":accepted,"anchorsObserved":true,"minimumRelativeProbability":threshold,
            "relativeQualityProbabilities":relative,"pairForwardBetterProbabilities":forward,
            "pairReverseBetterProbabilities":reverse,"sourceOnly":true,"GTAtInference":false])
    }
    static func apply(_ input:SourceNativeInput,prediction:[String:Any],heads:NativeAppearanceModelHeads,
                      ops:any NativeAppearanceImageOperations) throws -> [String:Any] {
        let config=try heads.configuration("appearance/final-background-model")
        guard var background=prediction["background"] as? [String:Any],let incumbent=background["rgb"] as? [Double],
              let palette=background["colors"] as? [[Double]],!palette.isEmpty,
              let weights=background["observedContextWeights"] as? [Double] else {return prediction}
        guard let fill=(prediction["fill"] as? [String:Any])?["rgb"] as? [Double],
              let outline=(prediction["outline"] as? [String:Any])?["rgb"] as? [Double],
              let roleEvidence=prediction["pixelRoleEvidence"] as? [String:Any],let roles=roleEvidence["roles"] as? [String:Any] else {
            throw NativeAppearanceModelHeads.Failure.invalidOutput("final source background")
        }
        let rawColors=(roles["background"] as? [String:Any])?["observedColours"] as? [[String:Any]] ?? []
        let role=try rawColors.map {color -> NativeAppearanceBackgroundFeatures102.RoleColor in
            guard let rgb=color["rgb"] as? [Double] else {throw NativeAppearanceModelHeads.Failure.invalidOutput("background role colour")}
            return .init(rgb:rgb,observedMass:try NativeAppearanceModelHeads.number(color,"observedMass"))
        }
        let packet=try NativeAppearanceBackgroundFeatures102.extract(input,palette:palette,weights:weights,
            incumbent:incumbent,fill:fill,outline:outline,backgroundRole:role,ops:ops)
        let scores=try heads.positive("appearance/final-background-model/classifier",packet.features),old=scores.count-1
        var best=0;for i in scores.indices.dropFirst() where scores[i]>scores[best] {best=i}
        guard let parameters=config["configuration"] as? [String:Any] else {throw NativeAppearanceModelHeads.Failure.invalidMetadata("final background gates")}
        let maximum=try NativeAppearanceModelHeads.number(parameters,"maximumIncumbentScore")
        let minimum=try NativeAppearanceModelHeads.number(parameters,"minimumNewScore")
        let baseline=scores[old]<=maximum && scores[best]>=minimum ? best:old
        let relative=try choose(packet.features,baseline:baseline,key:"appearance/final-background-model/relativeQualityModel/classifier",
            threshold:0.95,observed:true,heads:heads)
        let glyph=try NativeAppearanceGlyphBackground24.glyph(input,colors:packet.colors,ops:ops)
        let glyphFeatures=packet.features.indices.map {packet.features[$0]+glyph.features[$0]}
        let glyphChoice=try choose(glyphFeatures,baseline:relative.index,key:"appearance/final-background-model/glyphQualityModel/classifier",
            threshold:0.95,observed:glyph.observed,heads:heads)
        let directional=try NativeAppearanceGlyphBackground24.directional(input,colors:packet.colors,ops:ops)
        let directionalFeatures=glyphFeatures.indices.map {glyphFeatures[$0]+directional.features[$0]}
        let final=try choose(directionalFeatures,baseline:glyphChoice.index,key:"appearance/final-background-model/directionalQualityModel/classifier",
            threshold:0.95,observed:directional.observed,heads:heads)
        var result=prediction
        if packet.colors[final.index] != incumbent {
            background["rgb"]=packet.colors[final.index]
            background["primaryCorrectionEvidence"]=["version":"final-source-background-refinement-v5",
                "modelVersion":config["version"] ?? NSNull(),"sourceOnly":true,"GTAtInference":false,
                "previousRGB":incumbent,"score":scores[final.index],"incumbentScore":scores[old],
                "configuration":parameters,"sourcePaletteIndex":final.index,
                "backgroundIndexSemantics":"Original ranker provenance; final RGB is post-head",
                "v2BaselineIndex":baseline,"v2BaselineRGB":packet.colors[baseline],"relativeQualityEvidence":relative.report,
                "v3BaselineIndex":relative.index,"v3BaselineRGB":packet.colors[relative.index],"glyphQualityEvidence":glyphChoice.report,
                "v4BaselineIndex":glyphChoice.index,"v4BaselineRGB":packet.colors[glyphChoice.index],"directionalQualityEvidence":final.report] as [String:Any]
            result["background"]=background
        }
        return result
    }
}
