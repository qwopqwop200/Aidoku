import CoreGraphics
import Foundation

// Test-only feature/observation adapters, not real model or pixel extraction.
enum NativePixelRFFeatures {struct Matrix {let values:[Float];let featureCount:Int;let pixelCount:Int}}
enum NativeSourceSegmentationObservations {
    enum Failure:Error {case artifactMismatch,missingAcceptedAssets}
    struct Models {
        init() {}
        init(assetDirectory:URL?,bundle:Bundle)throws {fatalError("No accepted assets loaded in seam test")}
    }
    struct Completed {let mask:[UInt8]}
    struct Output {let primary:[Float];let boundary:[Float];let rawNative:[UInt8];let completed:Completed}
    static func sourceCrop(rgb:[UInt8],width:Int,height:Int,polygons:[[CGPoint]],fontPixels:Double,coarseRF:[Float],fullRF:[Float],rfModelWeightsSHA256:String,models:Models)throws->Output {fatalError("No model calls in producer seam test")}
}
enum NativeSegmentationFinalFeatures {
    enum Metric {case chebyshev}
    protocol ImageOperations {
        func fillExternalContours(_ mask:[UInt8],width:Int,height:Int)throws->[UInt8]
        func distance(_ mask:[UInt8],width:Int,height:Int,metric:Metric,labels:Bool)throws->(values:[Float],labels:[Int32]?)
    }
    nonisolated(unsafe) static var styleCalls=0,auxiliaryCalls=0
    static func edgeContext(rgb:[UInt8],primary:[Float],native:[UInt8],coarseRF:[Float],fullRF:[Float],width:Int,height:Int,fontPixels:Double,operations:any ImageOperations)throws->NativePixelRFFeatures.Matrix {.init(values:[],featureCount:60,pixelCount:width*height)}
    static func context(edge:NativePixelRFFeatures.Matrix,base:[UInt8],boundary:[Float],width:Int,height:Int,fontPixels:Double,positions:[Int],operations:any ImageOperations)throws->NativePixelRFFeatures.Matrix {.init(values:[],featureCount:83,pixelCount:positions.count)}
    static func style(rgb:[UInt8],base:[UInt8],distance:[Float],primary:[Float],boundary:[Float],width:Int,height:Int,fontPixels:Double,affinity:[Float])throws->[Double] {styleCalls += 1;return Array(repeating:0.2,count:18)}
    static func auxiliary(edge:NativePixelRFFeatures.Matrix,style:[Double],positions:[Int])throws->NativePixelRFFeatures.Matrix {auxiliaryCalls += 1;return .init(values:[],featureCount:78,pixelCount:positions.count)}
}
final class Counter:NativeSelectedSourceSegmentationProducer.PixelClassifier {
    let featureCount:Int;var calls=0
    init(_ count:Int){featureCount=count}
    func probabilities(_ features:NativePixelRFFeatures.Matrix)throws->[Double] {calls += 1;return Array(repeating:0.99,count:features.pixelCount)}
}
final class Operations:NativeSegmentationFinalFeatures.ImageOperations {
    var distances=0
    func fillExternalContours(_ mask:[UInt8],width:Int,height:Int)throws->[UInt8] {mask}
    func distance(_ mask:[UInt8],width:Int,height:Int,metric:NativeSegmentationFinalFeatures.Metric,labels:Bool)throws->(values:[Float],labels:[Int32]?) {distances += 1;return (Array(repeating:Float(0),count:width*height),nil)}
}
struct NativeSegmentationOpenCVOperations:NativeSegmentationFinalFeatures.ImageOperations {
    func fillExternalContours(_ mask:[UInt8],width:Int,height:Int)throws->[UInt8] {fatalError("No CV in seam test")}
    func distance(_ mask:[UInt8],width:Int,height:Int,metric:NativeSegmentationFinalFeatures.Metric,labels:Bool)throws->(values:[Float],labels:[Int32]?) {fatalError("No CV in seam test")}
}
struct NativeFrozenSourceModel {
    typealias PreparedPositiveBatch=([Float],Int,Int?)throws->[Double]
    var featureCount:Int {0};var classes:[Int] {[]};var link:String {""}
    init(data:Data)throws {fatalError("No learned model load in seam test")}
    func preparedPositiveProbabilities()->PreparedPositiveBatch? {nil}
    func predictProbability(_ vector:[Double])throws->[Double] {fatalError("No learned model calls in seam test")}
}

@main enum NativeSegmentationConnectedWeakProducerSmoke {
    static func main()throws {
        let enabled=NativeSelectedSourceSegmentationProducer.connectedWeakEnabled
        let context=Counter(83),aux=Counter(78),operations=Operations()
        let models=try NativeSelectedSourceSegmentationProducer.Models(observations:.init(),context83:context,style78:enabled ? nil:aux)
        let producer=NativeSelectedSourceSegmentationProducer(models:models,operations:operations)
        let n=21,w=7,h=3
        func run(_ p:[Float],capture:NativeSelectedSourceSegmentationProducer.Capture?=nil,
                 observer:NativeSelectedSourceSegmentationProducer.ReplayObserver?=nil)throws->NativeSelectedSourceSegmentationProducer.Output {
            try producer.finalMask(rgb:Array(repeating:0,count:n*3),width:w,height:h,fontPixels:12,
                coarseRF:Array(repeating:0,count:n*4),fullRF:Array(repeating:0,count:n*27),affinity:Array(repeating:0,count:5),
                rfModelWeightsSHA256:"03de2f77281974f5084cdd8652ace2b55dc15ac0378aed66654e62537cdda255",
                observations:.init(primary:p,boundary:Array(repeating:0.1,count:n),rawNative:Array(repeating:0,count:n),
                    completed:.init(mask:Array(repeating:255,count:n))),capture:capture,replayObserver:observer)
        }
        let weak=try run(Array(repeating:0.1,count:n))
        precondition(weak.mask.filter{$0 != 0}.count==(enabled ? 0:n))
        var p=Array(repeating:Float(0.1),count:n);p[10]=0.8
        let anchored=try run(p);precondition(anchored.mask==Array(repeating:255,count:n))
        precondition(context.calls==2 && aux.calls==(enabled ? 0:2))
        precondition(operations.distances==(enabled ? 2:4))
        precondition(NativeSegmentationFinalFeatures.styleCalls==(enabled ? 2:4))
        precondition(NativeSegmentationFinalFeatures.auxiliaryCalls==(enabled ? 0:2))
        var rejection=0
        if enabled {
            for test in 0..<2 {
                do {
                    if test==0 {_=try run(p,capture:{_,_,_ in fatalError("fabricated stage capture")})}
                    else {_=try run(p,observer:{_ in fatalError("fabricated replay stage")})}
                    preconditionFailure("unsupported observer accepted")
                } catch NativeSelectedSourceSegmentationProducer.Failure.unsupportedLegacyStageObserver {rejection += 1}
            }
            do {
                _=try producer.predict(rgb:[],width:1,height:1,polygons:[],fontPixels:1,coarseRF:[],fullRF:[],affinity:[],
                    rfModelWeightsSHA256:"",capture:{_,_,_ in fatalError("fabricated capture")})
                preconditionFailure("predict observer accepted before source model")
            } catch NativeSelectedSourceSegmentationProducer.Failure.unsupportedLegacyStageObserver {rejection += 1}
            precondition(context.calls==2)
            precondition(anchored.audit["style78Executed"] as? Bool==false)
            precondition(NativeSelectedSourceSegmentationProducer.activePolicySHA256 != NativeSegmentationFinalPolicy.policySHA256)
        } else {
            do {_=try NativeSelectedSourceSegmentationProducer.Models(observations:.init(),context83:context,style78:nil);preconditionFailure("default missing style head accepted")}catch {rejection += 1}
            precondition(NativeSelectedSourceSegmentationProducer.activePolicySHA256==NativeSegmentationFinalPolicy.policySHA256)
        }
        print(String(data:try JSONSerialization.data(withJSONObject:["passed":true,"enabled":enabled,"contextCalls":context.calls,
            "style78Calls":aux.calls,"stageOrMissingHeadRejections":rejection,"activePolicySHA256":NativeSelectedSourceSegmentationProducer.activePolicySHA256],options:[.sortedKeys]),encoding:.utf8)!)
    }
}
