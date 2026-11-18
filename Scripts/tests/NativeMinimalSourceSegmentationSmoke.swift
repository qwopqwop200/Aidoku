import CoreGraphics
import Foundation

// Private graph proof only: NO actual classifier/detector implementation or
// weights is linked. Counters expose forbidden eager legacy construction.
enum Calls {
    static var primaryLoads=0, predictions=0, base=0, chroma=0, features=0
    static var legacy=0, fullObservations=0, detections=0
}
struct NativePixelRFForest {
    static let primarySourceFileSHA256 = "8f5dba949b25c2cf54359bd8e4066c6423970980a0355887c83e150d82a0e617"
    static func primaryResource(in directory: URL) -> URL? { nil }
    static func readPackedPrimary(at url: URL) throws -> Self? { nil }
    let featureCount=62
    init() {}
    init(data: Data) throws { fatalError("No actual asset loading in this test") }
    func probabilities(_ matrix: NativePixelRFFeatures.Matrix) throws -> [Float] {
        Calls.predictions += 1
        return (0..<matrix.pixelCount).map { [Float(0),0.49,0.5,1][$0 % 4] }
    }
}
enum NativeRFDETRLayoutResource {
    static let highresSourceWeightsSHA256=String(repeating:"9",count:64)
    static let highresSourceRevision="synthetic"
}
enum NativeRFDETRLayoutError: Error { case modelUnavailable }
struct NativeRFDETRSourceImage { let width:Int;let height:Int;let rgb:[UInt8];let identity:String }
struct NativeRFDETRLayoutResult {
    struct Grid { let modelWeightsSHA256:String }
    let imageIdentity:String
    let semanticGrid:Grid?
}
final class NativeRFDETRLayoutDetector: @unchecked Sendable {
    init(cacheByteLimit:Int,retainAllQueryMasks:Bool,expectedWeightsSHA256:String,expectedSourceRevision:String,resolveModelURL:() throws -> URL) {}
    func detect(source:NativeRFDETRSourceImage) async throws -> NativeRFDETRLayoutResult {
        Calls.detections += 1
        return .init(imageIdentity:source.identity,semanticGrid:.init(modelWeightsSHA256:NativeRFDETRLayoutResource.highresSourceWeightsSHA256))
    }
}
struct NativePixelRFEvidence {
    struct Support { let full:[Float];let coarse:[Float];let affinityScores:[Float] }
    init(result:NativeRFDETRLayoutResult) throws {}
    func support(crop:CGRect,polygons:[[CGPoint]],sourceIdentity:String) throws -> Support {
        let n=Int(crop.width*crop.height)
        var full=[Float](repeating:0,count:n*27)
        for i in 0..<n {full[i*27]=[Float(0),0.49,0.5,1][i%4]}
        return .init(full:full,coarse:[Float](repeating:0,count:n*4),affinityScores:[Float](repeating:0,count:5))
    }
}
enum NativeSourceBackedRFProtection {
    struct Request {}
    struct PackedSeed {}
    static func pack(rawNative:[UInt8],selected:[UInt8],crop:CGRect,sourceIdentity:String,original:CGImage,
                     request:Request?,work:inout Int)->PackedSeed? { nil }
    static func admitOwnerMajorityComponents(mask:[UInt8],width:Int,height:Int,localPolygon:[CGPoint]) -> (mask:[UInt8],audit:[String:Any])? {
        fatalError("Final component admission is not exercised by this segmentation graph proof")
    }
}
enum NativeMainRemovalSourceFactory {
    enum NativeCurrentMaskCaller {
        struct Source {let width:Int;let height:Int;let rgb:[UInt8];let revision:String}
        struct Owner {let id:String;let polygon:[CGPoint];let fontPixels:Double;let translated:Bool;let balloon:Bool}
    }
    struct Mask {let mask:[UInt8]}
    enum NativeSourceBaseMask {
        static func extract(source:NativeCurrentMaskCaller.Source,owners:[NativeCurrentMaskCaller.Owner]) throws -> Mask {
            Calls.base += 1;return .init(mask:(0..<(source.width*source.height)).map {$0%2==0 ? 0 : 255})
        }
    }
    enum NativeChromaticMaskCompletion {
        struct Owner {let id:String;let polygon:[CGPoint];let fontPixels:Double}
        static func complete(rgb:[UInt8],width:Int,height:Int,base:[UInt8],protection:[UInt8],owners:[Owner]) throws -> Mask {
            Calls.chroma += 1;return .init(mask:base)
        }
    }
}
enum NativePixelRFFeatures {
    struct Input {let width:Int;let height:Int;let rgb:[UInt8];let nativeMask:[UInt8];let polygons:[[CGPoint]];let fontPixels:Double;let coarseRF:[Float];let fullRF:[Float]?}
    struct Matrix {let pixelCount:Int}
    static func extract(_ input:Input) throws -> Matrix {Calls.features += 1;return .init(pixelCount:input.width*input.height)}
}
enum NativeSourceSegmentationObservations {
    struct Models {init(assetDirectory:URL?,bundle:Bundle) throws {Calls.legacy += 1}}
    struct Completed {let mask:[UInt8]}
    struct Output {let primary:[Float];let boundary:[Float];let rawNative:[UInt8];let completed:Completed}
    static func sourceCrop(rgb:[UInt8],width:Int,height:Int,polygons:[[CGPoint]],fontPixels:Double,coarseRF:[Float],fullRF:[Float],rfModelWeightsSHA256:String,models:Models) throws -> Output {
        Calls.fullObservations += 1;fatalError("Forbidden full observation graph")
    }
}
final class NativeSelectedSourceSegmentationProducer {
    static let activePolicySHA256=String(repeating:"a",count:64),activePolicyRevision="synthetic-accepted"
    struct Output {let mask:[UInt8];let primary:[Float];let boundary:[Float];let rawNative:[UInt8];let completed:[UInt8];let audit:[String:Any]}
    struct SourceOutput {let input:SourceNativeInput;let audit:[String:Any]}
    typealias SourceReplayObserver=(SourceNativeInput) throws -> Void
    init(bundle:Bundle,sourceDirectory:URL?,numericDirectory:URL?) throws {Calls.legacy += 1}
    func predict(rgb:[UInt8],width:Int,height:Int,polygons:[[CGPoint]],fontPixels:Double,coarseRF:[Float],fullRF:[Float],affinity:[Float],rfModelWeightsSHA256:String) throws -> Output {fatalError("Forbidden legacy graph")}
    func segment(_ input:SourceNativeInput,replayObserver:SourceReplayObserver?) throws -> SourceOutput {fatalError("Forbidden legacy graph")}
}
enum NativeSourceInferencePolicy {
    enum Failure:Error {case invalidPolicy}
    static var invalid=false
    static var minimalSegmentationConfiguration:NativeMinimalSourceSegmentation.Configuration? = .init(mode:.rfTextOnly)
    static var erasureSegmentationConfiguration:NativeMinimalSourceSegmentation.Configuration? = nil
    static func validate() throws {if invalid {throw Failure.invalidPolicy}}
}

@main enum Smoke {
    static func input() -> NativeMinimalSourceSegmentation.Input {
        let polygon=[CGPoint(x:0,y:0),CGPoint(x:2,y:0),CGPoint(x:2,y:2),CGPoint(x:0,y:2)]
        var full=[Float](repeating:0,count:108)
        for i in 0..<4 {full[i*27]=[Float(0),0.49,0.5,1][i]}
        return .init(width:2,height:2,rgb:[UInt8](repeating:127,count:12),fullRF:full,
            coarseRF:[0,1,0,0,1,0,0,0,0,0,1,1,0,0,0,0],memberPolygons:[polygon],fontPixels:2,
            rfModelWeightsSHA256:NativeRFDETRLayoutResource.highresSourceWeightsSHA256)
    }
    static func reject(_ body:()throws->Void) {do {try body();fatalError("Expected rejection")}catch {}}
    static func main() throws {
        let value=input()
        let primary=try NativeMinimalSourceSegmentation(configuration:.init(mode:.primaryOnly),loadPrimary:{Calls.primaryLoads += 1;return .init()})
        let p=try primary.predict(value)
        precondition(p.mask==[0,0,255,255] && p.primary==[0,0.49,0.5,1] && p.nativeSeed==[0,255,0,255])
        precondition(Calls.primaryLoads==1 && Calls.predictions==1 && Calls.base==1 && Calls.chroma==1 && Calls.features==1)
        let weak=try NativeMinimalSourceSegmentation(configuration:.init(mode:.primaryOnly,threshold:0.5,
            weakRecovery:.init(minimumPrimaryProbability:0.01,radius:1)),loadPrimary:{Calls.primaryLoads += 1;return .init()})
        let weakOutput=try weak.predict(value)
        precondition(weakOutput.mask==[0,255,255,255] && weakOutput.primary==p.primary && weakOutput.nativeSeed==p.nativeSeed)
        precondition(weakOutput.audit["weakPixelsAddedBeforeClosing"] as? Int == 1)
        let callsBeforeStatic=Calls.predictions
        let staticMask=try NativeMinimalSourceSegmentation.postprocessPrimary(p.primary!,width:2,height:2,
            configuration:weak.configuration)
        precondition(staticMask==weakOutput.mask && Calls.predictions==callsBeforeStatic)
        reject {_ = try NativeMinimalSourceSegmentation.postprocessPrimary(p.primary!,width:2,height:2,configuration:.init(mode:.rfTextOnly))}
        reject {_ = try NativeMinimalSourceSegmentation.postprocessPrimary([],width:2,height:2,configuration:weak.configuration)}
        for mode in [NativeMinimalSourceSegmentation.Mode.rfTextOnly,.rfCoarseTextSFX] {
            let model=try NativeMinimalSourceSegmentation(configuration:.init(mode:mode),loadPrimary:{fatalError("RF must never load primary")})
            let output=try model.predict(value)
            precondition(output.primary==nil && output.nativeSeed==nil)
            precondition(output.mask==(mode == .rfTextOnly ? [0,0,255,255] : [255,255,0,0]))
        }
        precondition(Calls.predictions==2 && Calls.base==2 && Calls.chroma==2 && Calls.features==2)
        let execution=try NativeSourceSegmentationExecution()
        precondition(execution.isMinimal)
        let executed=try execution.predictMinimal(value)
        precondition(executed.mask==[0,0,255,255])
        reject {_ = try execution.predict(rgb:value.rgb,width:2,height:2,polygons:value.memberPolygons,fontPixels:2,
            coarseRF:value.coarseRF,fullRF:value.fullRF,affinity:[],rfModelWeightsSHA256:value.rfModelWeightsSHA256)}
        reject {_ = try NativeMinimalSourceSegmentation(configuration:.init(mode:.primaryOnly,threshold:.nan),loadPrimary:{fatalError()})}
        // The actual fallback producer shares the minimal policy and never
        // reconstructs the default learned graph behind the backend's back.
        let bytes=Data([UInt8](repeating:127,count:12))
        let provider=CGDataProvider(data:bytes as CFData)!
        let image=CGImage(width:2,height:2,bitsPerComponent:8,bitsPerPixel:24,bytesPerRow:6,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:0),provider:provider,
            decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        let source=NativeRFDETRSourceImage(width:2,height:2,rgb:Array(bytes),identity:"synthetic")
        let page=try NativeSelectedSourceSegmentationPageProducer.shared.build(original:image,decodedSource:source,
            owners:[.init(polygon:value.memberPolygons[0],fontPixels:2)])
        precondition(page.masks.entries.count==1 && page.masks.entries[0].mask==[0,0,255,255])
        precondition(page.masks.entries[0].positiveSourceSeed==nil && Calls.legacy==0 && Calls.fullObservations==0)
        NativeSourceInferencePolicy.invalid=true
        reject {_ = try NativeSourceSegmentationExecution()}
        NativeSourceInferencePolicy.invalid=false
        precondition(Calls.legacy==0)
        NativeSourceInferencePolicy.minimalSegmentationConfiguration=nil
        let accepted=try NativeSourceSegmentationExecution()
        precondition(!accepted.isMinimal && Calls.legacy==1) // Nil configuration retains old construction.
        NativeSourceInferencePolicy.erasureSegmentationConfiguration = .init(mode:.rfTextOnly)
        let independent=try NativeSourceSegmentationExecution(purpose:.erasure)
        precondition(independent.isMinimal && Calls.legacy==1) // Rich-feature config nil does not restore old erasure graph.
        var cases:[[String:Any]]=[]
        var recoveryCases:[[String:Any]]=[]
        var random:UInt64=20261117
        for (w,h) in [(1,1),(17,1),(7,7),(17,11)] {
            var mask=[UInt8]()
            for _ in 0..<(w*h) {random=random &* 6364136223846793005 &+ 1;mask.append(random >> 61 == 0 ? 255 : 0)}
            for radius in 0...3 {
                cases.append(["width":w,"height":h,"radius":radius,"input":mask,
                    "output":try NativeMinimalSourceSegmentation.close(mask,width:w,height:h,radius:radius)])
            }
        }
        let levels:[Float]=[0,0.001,0.01,0.03,0.05,0.1,0.2,0.25,0.5,1]
        for (w,h) in [(1,1),(8,1),(1,8),(7,9),(17,11)] {
            var probabilities=[Float]()
            for _ in 0..<(w*h) {random=random &* 6364136223846793005 &+ 1;probabilities.append(levels[Int(random%UInt64(levels.count))])}
            for (index,floor) in [Float(0.01),0.05,0.1].enumerated() {for radius in [1,2] {
                let beforeClose=try NativeMinimalSourceSegmentation.recoverWeak(primary:probabilities,width:w,height:h,
                    strongThreshold:0.25,recovery:.init(minimumPrimaryProbability:floor,radius:radius))
                recoveryCases.append(["width":w,"height":h,"primary":probabilities,"floorIndex":index,"radius":radius,
                    "beforeClose":beforeClose,"closed":try NativeMinimalSourceSegmentation.close(beforeClose,width:w,height:h,radius:1),
                    "staticPostprocess":try NativeMinimalSourceSegmentation.postprocessPrimary(probabilities,width:w,height:h,
                        configuration:.init(mode:.primaryOnly,threshold:0.25,closingRadius:1,
                            weakRecovery:.init(minimumPrimaryProbability:floor,radius:radius)))])
            }}
        }
        let baselineSHA=NativeMinimalSourceSegmentation.Configuration(mode:.primaryOnly,threshold:0.25,closingRadius:1).policySHA256
        precondition(baselineSHA=="f1936c07954d20292f7a9a9cbebd8297cc5e9ab34b74890c053c04b6e4a468f3")
        let recoverySHA=NativeMinimalSourceSegmentation.Configuration(mode:.primaryOnly,threshold:0.25,closingRadius:1,
            weakRecovery:.init(minimumPrimaryProbability:0.01,radius:2)).policySHA256
        precondition(recoverySHA != baselineSHA)
        print(String(data:try JSONSerialization.data(withJSONObject:["passed":true,"acceptedControlConstructors":Calls.legacy,
            "forbiddenLegacyConstructorsInMinimal":Calls.legacy-1,
            "actualNNCalls":0,"primaryStubCalls":Calls.predictions,"morphologyCases":cases,
            "recoveryCases":recoveryCases,"baselinePolicySHA256":baselineSHA,"recoveryPolicySHA256":recoverySHA],options:[.sortedKeys]),encoding:.utf8)!)
    }
}
