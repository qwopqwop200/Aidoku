import CoreGraphics
import CryptoKit
import Foundation

// This focused executable compiles the ACTUAL backend with an explicit fake
// resident. It intentionally does not compile/import CoreML or NativeResidentAOT.
struct NativeAOTResult {let image:CGImage;let coordinateAudit:[String:Any]}
struct NativeAOTRawPredictionSnapshot {
    enum Failure:Error {case producer}
    static func validSHA(_ value:String)->Bool {value.count == 64 && value.allSatisfy(\.isHexDigit)}
}
final class NativeAOTRawPredictionReplay {}
final class NativeResidentAOT {
    static var calls=0
    func restore(source:CGImage,validatedMask:NativeAOTValidatedMask,
                 calibrateBoundaryBias:Bool,boundaryMeanClamp:Int? = nil,
                 rejectNewBoundarySaturation:Bool = false,
                 rawPredictionSink:((NativeAOTRawPredictionSnapshot)throws->Void)? = nil) throws -> NativeAOTResult {
        try restore(source:source,originalMask:validatedMask.bytes,maskWidth:validatedMask.width,
            maskHeight:validatedMask.height,calibrateBoundaryBias:calibrateBoundaryBias,
            boundaryMeanClamp:boundaryMeanClamp,rawPredictionSink:rawPredictionSink)
    }
    init(url:URL,captureProducerSHA256:String? = nil,captureProducerConfigSHA256:String? = nil,
         rawPredictionReplay:NativeAOTRawPredictionReplay? = nil) throws {
        let marker=try Data(contentsOf:url.appendingPathComponent("MODEL_FREE_FAKE"))
        precondition(marker == Data("fake".utf8))
    }
    func restore(source:CGImage,originalMask:[UInt8],maskWidth:Int,maskHeight:Int,
                 calibrateBoundaryBias:Bool,
                 boundaryMeanClamp:Int? = nil,
                 rawPredictionSink:((NativeAOTRawPredictionSnapshot)throws->Void)? = nil) throws -> NativeAOTResult {
        try Task.checkCancellation();Self.calls+=1
        try rawPredictionSink?(NativeAOTRawPredictionSnapshot())
        return .init(image:source,coordinateAudit:["fakeResidentCalls":1,"inferenceCalls":0])
    }
}
func check(_ value:@autoclosure ()->Bool){precondition(value(),"AOT handoff admission")}
func rgba(_ bytes:[UInt8])->CGImage {
    CGImage(width:2,height:1,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:8,
        space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue),
        provider:CGDataProvider(data:Data(bytes) as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
}
func gray(_ values:[UInt8])->CGImage {
    CGImage(width:2,height:1,bitsPerComponent:8,bitsPerPixel:8,bytesPerRow:2,
        space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.none.rawValue),
        provider:CGDataProvider(data:Data(values) as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
}

@main struct NativeAOTHandoffAdmissionSmoke {
    static func main() async throws {
        let temporary=URL(fileURLWithPath:CommandLine.arguments[1])
        let bundle=temporary.appendingPathComponent("Fake.bundle")
        let resources=bundle.appendingPathComponent("Contents/Resources/AOT-1024-FP16.mlmodelc")
        try FileManager.default.createDirectory(at:resources,withIntermediateDirectories:true)
        try Data("fake".utf8).write(to:resources.appendingPathComponent("MODEL_FREE_FAKE"))
        let info:[String:Any]=["CFBundleIdentifier":"test.model-free-aot-handoff","CFBundleName":"Fake","CFBundlePackageType":"BNDL","CFBundleVersion":"1"]
        try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0)
            .write(to:bundle.appendingPathComponent("Contents/Info.plist"))
        setenv("AIDOKU_HOST_MODEL_BUNDLE",bundle.path,1)
        let sourceBytes:[UInt8]=[20,30,40,255,50,60,70,255]
        let source=rgba(sourceBytes),restored=rgba([100,110,120,255,50,60,70,255])
        let mask=gray([255,0]),changed=gray([0,255]),empty=gray([0,0])
        let backend=NativeMainAOTBackend.shared
        var strictRejected=false
        do {_ = try backend.restore(source:source,mask:gray([1,0]))}
        catch NativeMainAOTBackend.Failure.maskFormat {strictRejected=true}
        check(strictRejected && NativeResidentAOT.calls == 0)
        if CommandLine.arguments.last == "--capture" {
            var invalid=false,captured=0
            do {try backend.configureRawPredictionCapture(producerSHA256:"bad",producerConfigSHA256:"bad"){_ in}}
            catch NativeAOTRawPredictionSnapshot.Failure.producer {invalid=true}
            check(invalid)
            enum SinkError:Error {case quota}
            try backend.configureRawPredictionCapture(producerSHA256:String(repeating:"b",count:64),producerConfigSHA256:String(repeating:"c",count:64)) {_ in
                captured+=1;if captured == 2 {throw SinkError.quota}
            }
            try backend.registerCachedRestoration(source:source,mask:mask,restored:restored)
            invalid=false
            do {_ = try backend.restore(source:source,mask:mask)}
            catch NativeMainAOTBackend.Failure.captureRequiresActualRaw {invalid=true}
            check(invalid && NativeResidentAOT.calls == 0 && captured == 0)
            _ = try backend.restore(source:source,mask:mask)
            check(NativeResidentAOT.calls == 1 && captured == 1)
            invalid=false
            do {try backend.configureRawPredictionCapture(producerSHA256:String(repeating:"c",count:64),producerConfigSHA256:String(repeating:"c",count:64)){_ in}}
            catch NativeMainAOTBackend.Failure.captureAlreadyLoaded {invalid=true}
            check(invalid)
            invalid=false
            do {_ = try backend.restore(source:source,mask:mask)}catch SinkError.quota {invalid=true}
            check(invalid && NativeResidentAOT.calls == 2 && captured == 2)
            print("PASS actual backend opt-in capture: invalid producer; pre-load-only config; cached-PNG raw unavailable stops without fresh prediction; callback once; callback quota error propagates; real models0")
            return
        }
        func disposition(_ result:NativeAOTResult)->String {result.coordinateAudit["cacheDisposition"] as! String}
        // OFF/no handoff: ordinary resident path, no attempted cache registration.
        let off=try backend.restore(source:source,mask:mask)
        check(disposition(off)=="not-registered" && NativeResidentAOT.calls==1)
        // ON/valid actual source and mask: one-use verified restoration handoff.
        try backend.registerCachedRestoration(source:source,mask:mask,restored:restored)
        let hit=try backend.restore(source:source,mask:mask)
        check(disposition(hit)=="registered-handoff-consumed" && NativeResidentAOT.calls==1)
        let currentSHA=SHA256.hash(data:Data([255,0])).map{String(format:"%02x",$0)}.joined()
        check(hit.coordinateAudit["cacheMaskSHA256"] as? String == currentSHA)
        check(hit.coordinateAudit["cacheRestoredPixelVerificationPerformed"] as? Bool == true)
        let consumed=try backend.restore(source:source,mask:mask)
        check(disposition(consumed)=="not-registered" && NativeResidentAOT.calls==2)
        try backend.registerCachedRestoration(source:source,mask:mask,restored:restored)
        let mismatch=try backend.restore(source:source,mask:changed)
        check(disposition(mismatch)=="mask-sha256-mismatch" && NativeResidentAOT.calls==3)
        try backend.registerCachedRestoration(source:source,mask:mask,restored:restored)
        let otherObject=rgba(sourceBytes)
        let sourceMismatch=try backend.restore(source:otherObject,mask:mask)
        check(disposition(sourceMismatch)=="source-identity-mismatch" && NativeResidentAOT.calls==4)
        try backend.registerCachedRestoration(source:source,mask:mask,restored:restored)
        let policyMismatch=try backend.restore(source:source,mask:mask,calibrateBoundaryBias:true)
        check(disposition(policyMismatch)=="restoration-policy-mismatch" && NativeResidentAOT.calls==5)
        try backend.registerCachedRestoration(source:source,mask:mask,restored:restored)
        let zero=try backend.restore(source:source,mask:empty)
        check(disposition(zero)=="empty-mask-cleared-handoff" && NativeResidentAOT.calls==5)
        let afterZero=try backend.restore(source:source,mask:mask)
        check(disposition(afterZero)=="not-registered" && NativeResidentAOT.calls==6)
        try backend.registerCachedRestoration(source:source,mask:mask,restored:restored)
        let task=Task {
            withUnsafeCurrentTask{$0?.cancel()}
            do {_ = try backend.restore(source:source,mask:mask);return false}
            catch is CancellationError {return true}
            catch {return false}
        }
        let cancelled=await task.value;check(cancelled && NativeResidentAOT.calls==6)
        let afterCancellation=try backend.restore(source:source,mask:mask)
        check(disposition(afterCancellation)=="not-registered" && NativeResidentAOT.calls==7)
        try backend.registerCachedRestoration(source:source,mask:mask,restored:restored)
        var refused=false
        do {_ = try backend.restore(source:source,mask:source)}
        catch NativeMainAOTBackend.Failure.maskFormat {refused=true}
        check(refused && NativeResidentAOT.calls==7)
        let afterBadRestore=try backend.restore(source:source,mask:mask)
        check(disposition(afterBadRestore)=="not-registered" && NativeResidentAOT.calls==8)
        try backend.registerCachedRestoration(source:source,mask:mask,restored:restored)
        refused=false
        do {try backend.registerCachedRestoration(source:source,mask:source,restored:restored)}
        catch NativeMainAOTBackend.Failure.maskFormat {refused=true}
        check(refused && NativeResidentAOT.calls==8)
        let afterBadRegistration=try backend.restore(source:source,mask:mask)
        check(disposition(afterBadRegistration)=="not-registered" && NativeResidentAOT.calls==9)
        try backend.registerCachedRestoration(source:source,mask:mask,restored:restored,
            boundaryBiasPolicy:NativeAOTBoundaryBias.policy(meanClamp:16))
        let meanHit=try backend.restore(source:source,mask:mask,calibrateBoundaryBias:true,boundaryMeanClamp:16)
        check(disposition(meanHit)=="registered-handoff-consumed" && NativeResidentAOT.calls==9)
        try backend.registerCachedRestoration(source:source,mask:mask,restored:restored,
            boundaryBiasPolicy:NativeAOTBoundaryBias.policy(meanClamp:16))
        let medianMiss=try backend.restore(source:source,mask:mask,calibrateBoundaryBias:true)
        check(disposition(medianMiss)=="restoration-policy-mismatch" && NativeResidentAOT.calls==10)
        try backend.registerCachedRestoration(source:source,mask:mask,restored:restored,
            boundaryBiasPolicy:NativeAOTBoundaryBias.policy(meanClamp:8))
        let capMiss=try backend.restore(source:source,mask:mask,calibrateBoundaryBias:true,boundaryMeanClamp:16)
        check(disposition(capMiss)=="restoration-policy-mismatch" && NativeResidentAOT.calls==11)
        refused=false
        do {_ = try backend.restore(source:source,mask:mask,calibrateBoundaryBias:true,boundaryMeanClamp:32)}
        catch NativeMainAOTBackend.Failure.invalidCachePolicy {refused=true}
        check(refused && NativeResidentAOT.calls==11)
        refused=false
        do {_ = try backend.restore(source:source,mask:mask,calibrateBoundaryBias:false,boundaryMeanClamp:16)}
        catch NativeMainAOTBackend.Failure.invalidCachePolicy {refused=true}
        check(refused && NativeResidentAOT.calls==11)
        // Verify this test actually exercises the approved lazy guard order.
        let code=try String(contentsOfFile:CommandLine.arguments[2],encoding:.utf8)
        check(!code.contains("let digest = Self.sha256(bytes)"))
        check(code.contains("else if cached.maskSHA256 != Self.sha256(bytes)"))
        print("PASS actual handoff backend OFF/ON/hit/consumed/miss/changedmask/source/policy/empty/cancellation/error-clears; mean8/16/median distinct policy fences+invalid-mode rejects; cachedSHA equals actual currentmask SHA; real models=0")
    }
}
