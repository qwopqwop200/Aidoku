import CoreGraphics
import CoreML
import CryptoKit
import Foundation

@available(macOS 13.0, *)
@main enum NativeAOTExactTensorCacheSmoke {
    enum Failure: Error { case parity, arguments(String), expected }
    static func digest(_ bytes:[UInt8]) -> String {
        var hash=SHA256();bytes.withUnsafeBytes {hash.update(bufferPointer:$0)}
        return hash.finalize().map {String(format:"%02x",$0)}.joined()
    }
    static func fixture() throws -> (CGImage,[UInt8],[UInt8]) {
        let w=1536,h=1152
        var rgba=[UInt8](repeating:0,count:w*h*4)
        for y in 0..<h {for x in 0..<w {
            let p=(y*w+x)*4,alpha=(x<20 || x>=w-20 || y<20 || y>=h-20) ? 200 : 255
            let colors=[(x*3+y*5)%256,(x*7+y*11)%256,(x*13+y*17)%256]
            for c in 0..<3 {rgba[p+c]=UInt8((colors[c]*alpha+127)/255)}
            rgba[p+3]=UInt8(alpha)
        }}
        guard let provider=CGDataProvider(data:Data(rgba) as CFData),
              let image=CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:w*4,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,
                bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) else {
            throw Failure.arguments("Synthetic CG allocation")
        }
        var mask=[UInt8](repeating:0,count:w*h)
        for y in 223..<267 {for x in 257..<337 {mask[y*w+x]=255}}
        var changed=mask
        changed[(h-9)*w+w-11]=255 // Previously unmasked support, also tests source alpha.
        return (image,mask,changed)
    }
    static func checkOutput(_ output:CGImage,source:NativeAOTAlphaComposition.Source,mask:[UInt8]) throws -> [String:Any] {
        guard output.width==source.width,output.height==source.height else {throw Failure.parity}
        let actual=try NativeAOTAlphaComposition.prepare(source:output)
        var outside=0,insideNonopaque=0
        for p in 0..<mask.count {
            if mask[p]==0 {
                if (0..<4).contains(where:{actual.canonicalRGBA[p*4+$0] != source.canonicalRGBA[p*4+$0]}) {outside+=1}
            } else if actual.canonicalRGBA[p*4+3] != 255 {insideNonopaque+=1}
        }
        guard outside==0,insideNonopaque==0 else {throw Failure.parity}
        return ["finalRGBA256":digest(actual.canonicalRGBA),"outsideOriginalMaskChangedPixels":outside,
                "insideMaskNonopaquePixels":insideNonopaque,"originalSize":[source.width,source.height]]
    }

    static func main() async throws {
        let (image,mask,changed)=try fixture()
        let source=try NativeAOTAlphaComposition.prepare(source:image)
        let input=try MLMultiArray(shape:[1,3,1024,1024],dataType:.float16)
        let inputMask=try MLMultiArray(shape:[1,1,1024,1024],dataType:.float16)
        let raw=try MLMultiArray(shape:[1,3,1024,1024],dataType:.float16)
        raw.dataPointer.initializeMemory(as:UInt8.self,repeating:0,count:NativeAOTExactTensorCache.outputBytes)
        let policy=NativeAOTExactTensorCache.Policy(installedModelSHA256:String(repeating:"a",count:64),
            computeUnits:"synthetic",runtime:"synthetic",tensorABI:NativeAOTTensorCachePolicy.tensorABI)
        let cache=NativeAOTExactTensorCache()
        var fresh=0,keys:[String]=[],outputs:[String]=[]
        for current in [mask,mask,changed] {
            let content=try NativeResidentAOT.prepare(rgb:source.inferenceRGB,finalMask:current,
                width:source.width,height:source.height,image:input,mask:inputMask)
            let lookup=try cache.predict(image:input,mask:inputMask,policy:policy){fresh+=1;return raw}
            let rgb=try NativeResidentAOT.composePixels(source:source.inferenceRGB,finalMask:current,
                width:source.width,height:source.height,raw:lookup.raw,content:content)
            let image=try NativeAOTAlphaComposition.makeImage(source:source,restoredRGB:rgb,originalMask:current)
            let proof=try checkOutput(image,source:source,mask:current)
            keys.append(lookup.key);outputs.append(proof["finalRGBA256"] as! String)
        }
        guard fresh==2,keys[0]==keys[1],keys[0] != keys[2],outputs[0]==outputs[1] else {throw Failure.parity}
        var sparse=mask;sparse[230*source.width+270]=0
        let content=try NativeResidentAOT.prepare(rgb:source.inferenceRGB,finalMask:sparse,width:source.width,
            height:source.height,image:input,mask:inputMask)
        let same=try cache.predict(image:input,mask:inputMask,policy:policy){throw Failure.parity}
        guard same.hit,same.key==keys[0] else {throw Failure.parity}
        let rgb=try NativeResidentAOT.composePixels(source:source.inferenceRGB,finalMask:sparse,
            width:source.width,height:source.height,raw:same.raw,content:content)
        let current=try NativeAOTAlphaComposition.makeImage(source:source,restoredRGB:rgb,originalMask:sparse)
        let proof=try checkOutput(current,source:source,mask:sparse)
        guard proof["finalRGBA256"] as? String != outputs[0] else {throw Failure.parity}
        same.raw.dataPointer.assumingMemoryBound(to:Float16.self)[0]=1
        let cloned=try cache.predict(image:input,mask:inputMask,policy:policy){throw Failure.parity}
        guard cloned.raw.dataPointer.assumingMemoryBound(to:Float16.self)[0]==0 else {throw Failure.parity}
        raw.dataPointer.assumingMemoryBound(to:Float16.self)[0]=2
        let owned=try cache.predict(image:input,mask:inputMask,policy:policy){throw Failure.parity}
        guard owned.raw.dataPointer.assumingMemoryBound(to:Float16.self)[0]==0 else {throw Failure.parity}
        raw.dataPointer.assumingMemoryBound(to:Float16.self)[0]=0
        let key=try cache.key(image:input,mask:inputMask,policy:policy)
        for p in [
            NativeAOTExactTensorCache.Policy(installedModelSHA256:String(repeating:"b",count:64),
                computeUnits:policy.computeUnits,runtime:policy.runtime,tensorABI:policy.tensorABI),
            NativeAOTExactTensorCache.Policy(installedModelSHA256:policy.installedModelSHA256,
                computeUnits:"other",runtime:policy.runtime,tensorABI:policy.tensorABI),
            NativeAOTExactTensorCache.Policy(installedModelSHA256:policy.installedModelSHA256,
                computeUnits:policy.computeUnits,runtime:"other",tensorABI:policy.tensorABI)
        ] {
            guard try cache.key(image:input,mask:inputMask,policy:p) != key else {throw Failure.parity}
        }
        let bits=input.dataPointer.assumingMemoryBound(to:UInt16.self),original=bits[0]
        bits[0] ^= 1
        guard try cache.key(image:input,mask:inputMask,policy:policy) != key else {throw Failure.parity}
        bits[0]=original
        let bounded=NativeAOTExactTensorCache(budget:2*NativeAOTExactTensorCache.outputBytes)
        for value in [Float16(0.125),Float16(0.25),Float16(0.5)] {
            bits[0]=value.bitPattern
            _ = try bounded.predict(image:input,mask:inputMask,policy:policy){raw}
            guard bounded.statistics()["retainedBytes"]!<=2*NativeAOTExactTensorCache.outputBytes else {throw Failure.parity}
        }
        guard bounded.statistics()["entries"]==2,
              NativeAOTExactTensorCache(budget:128*1_048_576).statistics()["budget"]==64*1_048_576 else {throw Failure.parity}
        bits[0]=original
        let wrong=try MLMultiArray(shape:[1,1,1024,1024],dataType:.float32)
        do {_ = try cache.predict(image:input,mask:wrong,policy:policy){throw Failure.parity};throw Failure.parity}
        catch NativeAOTExactTensorCache.Failure.inputContract {}
        let zero=NativeAOTExactTensorCache(budget:0);var zeroCalls=0
        for _ in 0..<2 {_ = try zero.predict(image:input,mask:inputMask,policy:policy){zeroCalls+=1;return raw}}
        guard zeroCalls==2,zero.statistics()["retainedBytes"]==0 else {throw Failure.parity}
        let failed=NativeAOTExactTensorCache()
        do {_ = try failed.predict(image:input,mask:inputMask,policy:policy){throw Failure.expected};throw Failure.parity}
        catch Failure.expected {}
        let retry=try failed.predict(image:input,mask:inputMask,policy:policy){raw}
        guard !retry.hit,failed.statistics()["freshClosures"]==2 else {throw Failure.parity}
        let invalid=NativeAOTExactTensorCache()
        let bad=try MLMultiArray(shape:[1,3,1024,1024],dataType:.float16)
        bad.dataPointer.initializeMemory(as:UInt8.self,repeating:0,count:NativeAOTExactTensorCache.outputBytes)
        bad.dataPointer.assumingMemoryBound(to:Float16.self)[0] = .nan
        for _ in 0..<2 {_ = try invalid.predict(image:input,mask:inputMask,policy:policy){bad}}
        guard invalid.statistics()["entries"]==0,invalid.statistics()["rejectedSnapshots"]==2 else {throw Failure.parity}
        try await lifecycle(input:input,mask:inputMask,raw:raw,policy:policy)
        try modelHashFixtures()
        let flag=await Task.detached {NativeAOTTensorCachePolicy.enabled}.value
        guard flag==NativeAOTTensorCachePolicy.enabled else {throw Failure.parity}
        print("PASS actual native cache: current-mask/sourceRGBA/alpha/resolution, exact8MiB key,6MiB immutable hit, model/compute/runtime/input-bit invalidation, bad tensor/nonfinite/failure, cancellation+idle purge+live clone,0budget. Model loads0/predictions0; optIn=\(flag).")
    }
    static func lifecycle(input:MLMultiArray,mask:MLMultiArray,raw:MLMultiArray,
                          policy:NativeAOTExactTensorCache.Policy) async throws {
        let joined=NativeAOTExactTensorCache(),begin=DispatchSemaphore(value:0),end=DispatchSemaphore(value:0)
        let owner=Task.detached {try joined.predict(image:input,mask:mask,policy:policy){
            begin.signal();end.wait();return raw
        }}
        await Task.detached {blockingWait(begin)}.value
        let joining=DispatchSemaphore(value:0)
        let follower=Task.detached {
            joining.signal()
            return try joined.predict(image:input,mask:mask,policy:policy){throw Failure.parity}
        }
        await Task.detached {blockingWait(joining)}.value
        end.signal()
        _ = try await owner.value
        let hit=try await follower.value
        guard hit.hit,joined.statistics()["freshClosures"]==1 else {throw Failure.parity}
        let cancelled=NativeAOTExactTensorCache(),began=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0)
        let work=Task.detached {
            try cancelled.predict(image:input,mask:mask,policy:policy){
                began.signal();release.wait();return raw
            }
        }
        await Task.detached {blockingWait(began)}.value
        work.cancel();release.signal()
        do {_ = try await work.value;throw Failure.parity}catch is CancellationError {}
        guard cancelled.statistics()["entries"]==0 else {throw Failure.parity}
        let shared=NativeAOTExactTensorCache.shared;shared.clear()
        let started=DispatchSemaphore(value:0),finish=DispatchSemaphore(value:0)
        let active=Task.detached {try shared.predict(image:input,mask:mask,policy:policy){
            started.signal();finish.wait();return raw
        }}
        await Task.detached {blockingWait(started)}.value
        let purging=DispatchSemaphore(value:0),purged=DispatchSemaphore(value:0)
        let pressure=Task.detached {
            purging.signal();await NativeAOTExactTensorCache.discardWhenIdle();purged.signal()
        }
        await Task.detached {blockingWait(purging)}.value
        let stillRunning=await Task.detached {timedOut(purged)}.value
        guard stillRunning else {throw Failure.parity}
        finish.signal()
        let live=try await active.value
        await pressure.value
        guard shared.statistics()["entries"]==0,
              live.raw.dataPointer.assumingMemoryBound(to:Float16.self)[0]==0 else {throw Failure.parity}
        // In-use consumer owns its raw clone/fresh result even after eviction.
        _ = try shared.predict(image:input,mask:mask,policy:policy){raw}
        let liveHit=try shared.predict(image:input,mask:mask,policy:policy){throw Failure.parity}
        shared.clear()
        guard liveHit.raw.dataPointer.assumingMemoryBound(to:Float16.self)[0]==0 else {throw Failure.parity}
    }
    static func modelHashFixtures() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("aot-identity-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:folder)}
        var values:[String]=[]
        for name in ["a","b"] {
            let resource=folder.appendingPathComponent(name+".mlmodelc")
            try FileManager.default.createDirectory(at:resource,withIntermediateDirectories:true)
            try Data(name.utf8).write(to:resource.appendingPathComponent("synthetic.bin"))
            values.append(try NativeAOTCompiledModelIdentity.digest(resource))
        }
        guard values[0] != values[1] else {throw Failure.parity}
        let samePath=folder.appendingPathComponent("a.mlmodelc")
        let artifact=samePath.appendingPathComponent("synthetic.bin")
        let before=try NativeAOTCompiledModelIdentity.digest(samePath)
        let oldDate=try FileManager.default.attributesOfItem(atPath:artifact.path)[.modificationDate]!
        // Different bytes, same path AND length, restored mtime: metadata-only
        // or URL memoization would return the stale previous model identity.
        try Data("z".utf8).write(to:artifact)
        try FileManager.default.setAttributes([.modificationDate:oldDate],ofItemAtPath:artifact.path)
        let after=try NativeAOTCompiledModelIdentity.digest(samePath)
        guard before != after else {throw Failure.parity}
        let input=try MLMultiArray(shape:[1,3,1024,1024],dataType:.float16)
        let mask=try MLMultiArray(shape:[1,1,1024,1024],dataType:.float16)
        input.dataPointer.initializeMemory(as:UInt8.self,repeating:0,count:NativeAOTExactTensorCache.imageBytes)
        mask.dataPointer.initializeMemory(as:UInt8.self,repeating:0,count:NativeAOTExactTensorCache.maskBytes)
        let cache=NativeAOTExactTensorCache()
        let a=NativeAOTExactTensorCache.Policy(installedModelSHA256:before,computeUnits:"same",runtime:"same",
            tensorABI:NativeAOTTensorCachePolicy.tensorABI)
        let b=NativeAOTExactTensorCache.Policy(installedModelSHA256:after,computeUnits:"same",runtime:"same",
            tensorABI:NativeAOTTensorCachePolicy.tensorABI)
        guard try cache.key(image:input,mask:mask,policy:a) != cache.key(image:input,mask:mask,policy:b) else {throw Failure.parity}
        let raw=try MLMultiArray(shape:[1,3,1024,1024],dataType:.float16)
        raw.dataPointer.initializeMemory(as:UInt8.self,repeating:0,count:NativeAOTExactTensorCache.outputBytes)
        _ = try cache.predict(image:input,mask:mask,policy:a){raw}
        let rebound=try cache.predict(image:input,mask:mask,policy:b){raw}
        guard !rebound.hit,cache.statistics()["freshClosures"]==2 else {throw Failure.parity}
    }
    static func blockingWait(_ semaphore:DispatchSemaphore) {semaphore.wait()}
    static func timedOut(_ semaphore:DispatchSemaphore) -> Bool {semaphore.wait(timeout:.now()+0.02) == .timedOut}
}
