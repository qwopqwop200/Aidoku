import Foundation

enum NativeAppearanceWidth {
    struct Result {let prediction:[String:Any];let referenceWidth:Double;let adaptive:NativeAppearanceAdaptiveWidth50.Evidence?}
    static func apply(_ input:SourceNativeInput,packet:NativeAppearanceSourceFeatures209.Packet,prediction:[String:Any],
                      heads:NativeAppearanceModelHeads,ops:any NativeAppearanceImageOperations,
                      sourceIndex:Int=0,diagnostics:NativeSourceFeatureObserver?=nil) throws -> Result {
        let config=try heads.configuration("appearance/width-model")
        guard var outline=prediction["outline"] as? [String:Any],let present=outline["present"] as? Bool,
              let fill=(prediction["fill"] as? [String:Any])?["rgb"] as? [Double],let stroke=outline["rgb"] as? [Double],
              let fillIndex=prediction["fillIndex"] as? Int,let outlineIndex=prediction["outlineIndex"] as? Int,
              var background=prediction["backgroundIndex"] as? Int else {throw NativeAppearanceModelHeads.Failure.invalidOutput("width source colours")}
        var result=prediction
        guard present else {
            outline["widthPx"]=0.0;outline["widthRangePx"]=[0.0,0.0];result["outline"]=outline
            return .init(prediction:result,referenceWidth:0,adaptive:nil)
        }
        if config["backgroundContextRanker"] != nil {
            let conditioned=config["backgroundContextConditioned"] as? Bool == true
            let matrix=packet.role("background",fill:conditioned ? fillIndex:nil,outline:conditioned ? outlineIndex:nil)
            let scores=try heads.positive("appearance/width-model/backgroundContextRanker",matrix)
            background=0
            for i in scores.indices.dropFirst() where scores[i]>scores[background] {background=i}
        }
        let observed=try NativeAppearanceOutlineWidthEvidence.measure(rgb:input.rgb,mask:input.ownMask,
            width:input.width,height:input.height,fill:fill,outline:stroke)
        let vector=observed.vector,f=packet.fontPixels
        var features=vector+[f,log1p(f)]+vector[1..<7].map {$0/max(1,f)}
        features += packet.summary(fill:fillIndex,outline:outlineIndex,background:background).map(Double.init)
        guard features.count==662 else {throw NativeAppearanceModelHeads.Failure.invalidOutput("width662")}
        let regressor=try heads.model("appearance/width-model/regressor")
        let original=try regressor.predict(features)[0]
        let resolution=(config["outputResolutionPx"] as? NSNumber)?.doubleValue ?? 0
        func project(_ value:Double,_ resolution:Double)->Double {
            let value=max(0.25,value)
            return resolution>0 ? max(0.25,(value/resolution).rounded(.toNearestOrEven)*resolution):value
        }
        var raw=max(0.25,original),adaptive:NativeAppearanceAdaptiveWidth50.Evidence?
        var referenceResolution=resolution
        var diagnosticTrees:[Double]?
        if let extensionConfig=config["adaptiveNormalRefinement"] as? [String:Any] {
            let native=try NativeAppearanceAdaptiveWidth50.measure(input,fill:fill,primary:stroke,present:true,ops:ops)
            guard native.features.count==50 else {throw NativeAppearanceModelHeads.Failure.invalidOutput("adaptive width50")}
            adaptive=native
            let model=try heads.model("appearance/width-model/adaptiveNormalRefinement/regressor")
            let full=features+native.features
            let candidate:Double
            if let policy=extensionConfig["forestConsensus"] as? [String:Any],let parameters=policy["configuration"] as? [String:Any] {
                let treeValues=try model.predictTrees(full).map {$0[0]}.sorted()
                if diagnostics != nil {diagnosticTrees=treeValues}
                let trim=Int(floor(Double(treeValues.count)*(try NativeAppearanceModelHeads.number(parameters,"trimFraction"))))
                let retained=Array(treeValues[trim..<treeValues.count-trim])
                let center=NativeAppearanceNumeric.fsum(retained)/Double(retained.count)
                let upper=NativeAppearanceNumeric.quantile(treeValues,try NativeAppearanceModelHeads.number(parameters,"upperQuantile"))
                let scale=try NativeAppearanceModelHeads.number(parameters,"upperScale")
                candidate=max(0.25,center*(1-scale)+upper*scale)
            } else {candidate=max(0.25,try model.predict(full)[0])}
            let scale=try NativeAppearanceModelHeads.number(extensionConfig,"scale")
            raw=max(0.25,max(0.25,original)*(1-scale)+candidate*scale)
            referenceResolution=(extensionConfig["sourceGeometryReferenceResolutionPx"] as? NSNumber)?.doubleValue ?? resolution
        }
        let width=project(raw,resolution),radius=try NativeAppearanceModelHeads.number(config,"uncertaintyRadiusPx")
        if let diagnostics {
            try diagnostics(sourceIndex,"width-features",[
                "schema":"source-width-calculation-v1","sourceOnly":true,"GTAtInference":false,
                "sourceIdentity":input.sourceIdentity,"sourcePrior":f,
                "selectedFillIndex":fillIndex,"selectedOutlineIndex":outlineIndex,"selectedBackgroundIndex":background,
                "selectedFill":fill,"selectedOutline":stroke,"source662":features,
                "native50":adaptive?.features ?? [],"sortedAdaptiveTreeOutputs":diagnosticTrees ?? [],
                "baseRawWidth":original,"unroundedConsensusWidth":raw,
                "outputResolutionPx":resolution,"projectedWidth":width,
                "referenceWidth":project(original,referenceResolution),
                "modelWeightsChanged":false] as [String:Any])
        }
        outline["widthPx"]=width;outline["widthRangePx"]=[max(0,width-radius),width+radius]
        outline["measurementEvidence"]=["reliable":observed.reliable,"usableRays":observed.runs.count,
            "suggestedWidthPx":vector[1],"coreRunPx":["p10":vector[2],"p25":vector[3],"median":vector[4],"p75":vector[5]],
            "medianTransitionPx":vector[6]] as [String:Any]
        result["outline"]=outline
        return .init(prediction:result,referenceWidth:project(original,referenceResolution),adaptive:adaptive)
    }
}
