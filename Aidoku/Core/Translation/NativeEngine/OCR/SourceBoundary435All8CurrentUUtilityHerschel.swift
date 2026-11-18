import Foundation
import CoreGraphics

/// Generic second-stage SHADOW argmax. Caller first computes current source-only U.
/// No page/source IDs, hashes, folds, variant names or GT are accepted as inputs.
enum SourceBoundary435All8CurrentUUtilityHerschel {
    typealias Utility=SourceBoundary435UtilityHerschel
    struct Offer {
        let polygon:[CGPoint]
        let relativeTargets:[Double]
    }
    static func preferred(model:Utility.Model,sourceFeatures50:[Double],offers:[Offer],
                          currentU:[CGPoint],rootW:CGFloat,frame:CGSize)
        -> (index:Int,score:Double,receipt:[String:Any])? {
        guard offers.count<=8 else {return nil}
        var bestIndex:Int?=nil,bestScore=0.0,valid=0
        for (i,offer) in offers.enumerated() {
            guard let v=Utility.preferred(model:model,sourceFeatures50:sourceFeatures50,
                predictedRelative5:offer.relativeTargets,candidate:offer.polygon,
                baseline:currentU,rootW:rootW,frame:frame) else {continue}
            valid += 1
            // Strict comparison: exact ties retain first actual input offer.
            if v.score>bestScore {bestScore=v.score;bestIndex=i}
        }
        guard let index=bestIndex,bestScore>model.margin else {return nil}
        return(index,bestScore,["sourceOnly":true,"featureCount":63,
            "utilityThreshold":model.margin,"actualOfferCount":offers.count,
            "validComparedOffers":valid,"baselineIsCurrentU":true,
            "cascadeMeanUComputedFirst":true,"variantIdentityUsedAsFeature":false,
            "legacy425PolicyApplied":false,"shadowOnly":true,
            "nativeAdmissionGranted":false,"physicalCoreAndOwnershipReviewRequired":true])
    }
}
