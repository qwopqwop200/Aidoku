import CoreGraphics
import CoreML
import Foundation
import ImageIO

func check(_ condition: @autoclosure () -> Bool) { precondition(condition(),"actual raw AOT replay contract") }
func rejects(_ body: () throws -> Void) { var did=false;do {try body()} catch {did=true};check(did) }
func png(_ image:CGImage,_ url:URL) {
    let destination=CGImageDestinationCreateWithURL(url as CFURL,"public.png" as CFString,1,nil)!
    CGImageDestinationAddImage(destination,image,nil);check(CGImageDestinationFinalize(destination))
}
func sourceImage(_ rgba:[UInt8],_ side:Int)->CGImage {
    CGImage(width:side,height:side,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:side*4,
        space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue),
        provider:CGDataProvider(data:Data(rgba) as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
}
@main struct Smoke {
    static func main() throws {
        let folder=URL(fileURLWithPath:CommandLine.arguments[1]),s=32
        var rgba=[UInt8](repeating:255,count:s*s*4),binary=[UInt8](repeating:0,count:s*s)
        for y in 10..<15 {for x in 10..<15 {
            let p=y*s+x;binary[p]=255
            for c in 0..<3 {rgba[p*4+c]=0}
        }}
        let source=sourceImage(rgba,s),alpha=try NativeAOTAlphaComposition.prepare(source:source)
        let image=try MLMultiArray(shape:[1,3,1024,1024],dataType:.float16)
        let mask=try MLMultiArray(shape:[1,1,1024,1024],dataType:.float16)
        let raw=try MLMultiArray(shape:[1,3,1024,1024],dataType:.float16)
        let content=try NativeResidentAOT.prepare(rgb:alpha.inferenceRGB,finalMask:binary,width:s,height:s,image:image,mask:mask)
        let ptr=raw.dataPointer.assumingMemoryBound(to:Float16.self)
        for i in 0..<(3*1024*1024) {ptr[i]=Float16(0.95)}
        let policy=NativeAOTExactTensorCache.Policy(installedModelSHA256:String(repeating:"a",count:64),
            computeUnits:"synthetic-no-model",runtime:"synthetic-no-model",tensorABI:NativeAOTTensorCachePolicy.tensorABI)
        let snapshot=try NativeAOTRawPredictionSnapshot.capture(source:source,originalMask:binary,
            image:image,mask:mask,raw:raw,policy:policy,producerSHA256:String(repeating:"b",count:64),
            producerConfigSHA256:String(repeating:"c",count:64))
        check(snapshot.rawBytes == Data(bytes:raw.dataPointer,count:NativeAOTExactTensorCache.outputBytes))
        let variants=try snapshot.composeVariants(source:source,originalMask:binary)
        let off=try NativeAOTAlphaComposition.prepare(source:variants.simple.image).canonicalRGBA
        let on=try NativeAOTAlphaComposition.prepare(source:variants.complex.image).canonicalRGBA
        let direct=try NativeResidentAOT.composeRestoration(source:alpha,originalMask:binary,raw:raw,
            content:content,calibrateBoundaryBias:true)
        let directRGBA=try NativeAOTAlphaComposition.prepare(source:direct.image).canonicalRGBA
        check(on == directRGBA)
        for cap in [8,16] {
            let mean=try NativeResidentAOT.composeRestoration(source:alpha,originalMask:binary,raw:raw,
                content:content,calibrateBoundaryBias:true,boundaryMeanClamp:cap)
            let meanRGBA=try NativeAOTAlphaComposition.prepare(source:mean.image).canonicalRGBA
            check(meanRGBA == on)
            check(mean.coordinateAudit["boundaryBiasPolicy"] as? String == NativeAOTBoundaryBias.policy(meanClamp:cap))
        }
        rejects {_ = try NativeResidentAOT.composeRestoration(source:alpha,originalMask:binary,raw:raw,
            content:content,calibrateBoundaryBias:true,boundaryMeanClamp:32)}
        var transparent=rgba;transparent[0]=0;transparent[1]=0;transparent[2]=0;transparent[3]=0
        let ta=try NativeAOTAlphaComposition.prepare(source:sourceImage(transparent,s))
        let t0=try NativeResidentAOT.composeRestoration(source:ta,originalMask:binary,raw:raw,content:content,calibrateBoundaryBias:false)
        let tm=try NativeResidentAOT.composeRestoration(source:ta,originalMask:binary,raw:raw,content:content,calibrateBoundaryBias:true,boundaryMeanClamp:16)
        let t0rgba=try NativeAOTAlphaComposition.prepare(source:t0.image).canonicalRGBA
        let tmrgba=try NativeAOTAlphaComposition.prepare(source:tm.image).canonicalRGBA
        check(t0rgba == tmrgba && tmrgba[3] == 0)
        var changed=0
        for p in binary.indices {
            if binary[p] == 0 {
                check(Array(off[p*4..<p*4+4]) == Array(rgba[p*4..<p*4+4]))
                check(Array(on[p*4..<p*4+4]) == Array(rgba[p*4..<p*4+4]))
            } else {if off[p*4] != on[p*4] {changed+=1};check(off[p*4+3] == 255 && on[p*4+3] == 255)}
        }
        check(changed == 25)
        check(variants.simple.coordinateAudit["inferenceCalls"] as? Int == 0)
        check(variants.complex.coordinateAudit["inferenceCalls"] as? Int == 0)
        var badMask=binary;badMask[0]=255
        rejects {_ = try snapshot.compose(source:source,originalMask:badMask,calibrateBoundaryBias:false)}
        var badRGBA=rgba;badRGBA[0]=254
        rejects {_ = try snapshot.compose(source:sourceImage(badRGBA,s),originalMask:binary,calibrateBoundaryBias:false)}
        var corrupt=snapshot.rawBytes;corrupt[0] ^= 1
        rejects {_ = try NativeAOTRawPredictionSnapshot(binding:snapshot.binding,rawBytes:corrupt)
            .compose(source:source,originalMask:binary,calibrateBoundaryBias:false)}
        // Snapshot owns a copy: caller mutations never poison stored predictions.
        ptr[0]=Float16(-1);check(snapshot.rawBytes[0] != Data(bytes:raw.dataPointer,count:2)[0] || snapshot.rawBytes[1] != Data(bytes:raw.dataPointer,count:2)[1])
        let sourceURL=folder.appendingPathComponent("source.png"),maskURL=folder.appendingPathComponent("mask.png")
        png(source,sourceURL)
        let maskImage=CGImage(width:s,height:s,bitsPerComponent:8,bitsPerPixel:8,bytesPerRow:s,
            space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.none.rawValue),
            provider:CGDataProvider(data:Data(binary) as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        png(maskImage,maskURL)
        let sourceSHA=NativeAOTRawPredictionSnapshot.sha(try Data(contentsOf:sourceURL))
        let archive=try NativeAOTRawPredictionArchive(directory:folder.appendingPathComponent("bank"),byteBudget:8*1024*1024)
        let record=try archive.append(snapshot,sourceFile:sourceURL,expectedSourceEncodedSHA256:sourceSHA,originalMaskFile:maskURL)
        let loaded=try NativeAOTRawPredictionArchive.read(record)
        let replay=try loaded.snapshot.composeVariants(source:loaded.source,originalMask:loaded.originalMask)
        let replayOff=try NativeAOTAlphaComposition.prepare(source:replay.simple.image).canonicalRGBA
        let replayOn=try NativeAOTAlphaComposition.prepare(source:replay.complex.image).canonicalRGBA
        check(replayOff == off);check(replayOn == on)
        let duplicate=try archive.append(snapshot,sourceFile:sourceURL,expectedSourceEncodedSHA256:sourceSHA,originalMaskFile:maskURL)
        check(duplicate == record)
        let tiny=try NativeAOTRawPredictionArchive(directory:folder.appendingPathComponent("tiny"),byteBudget:1)
        rejects {_ = try tiny.append(snapshot,sourceFile:sourceURL,expectedSourceEncodedSHA256:sourceSHA,originalMaskFile:maskURL)}
        rejects {_ = try NativeAOTRawPredictionArchive(directory:folder.appendingPathComponent("excess"),byteBudget:13*1024*1024*1024)}
        rejects {_ = try archive.append(snapshot,sourceFile:sourceURL,expectedSourceEncodedSHA256:String(repeating:"0",count:64),originalMaskFile:maskURL)}
        let metadataSHA=NativeAOTRawPredictionSnapshot.sha(try Data(contentsOf:record))
        let indexData=try JSONSerialization.data(withJSONObject:["schema":"attested-exact-AOT-raw-replay-index-v1",
            "producerSHA256":String(repeating:"b",count:64),"producerConfigSHA256":String(repeating:"c",count:64),
            "compiledModelSHA256":String(repeating:"a",count:64),
            "records":[["metadataPath":record.path,"metadataSHA256":metadataSHA]]],options:[.sortedKeys])
        let indexURL=folder.appendingPathComponent("index.json");try indexData.write(to:indexURL)
        let indexSHA=NativeAOTRawPredictionSnapshot.sha(indexData)
        let replayIndex=try NativeAOTRawPredictionReplay(indexFile:indexURL,expectedIndexSHA256:indexSHA)
        let hit=try replayIndex.lookup(image:image,mask:mask,policy:policy)
        check(hit.raw != nil && hit.metadataSHA256 == metadataSHA)
        check(Data(bytes:hit.raw!.dataPointer,count:NativeAOTExactTensorCache.outputBytes) == snapshot.rawBytes)
        hit.raw!.dataPointer.assumingMemoryBound(to:UInt16.self)[0] ^= 1
        let again=try replayIndex.lookup(image:image,mask:mask,policy:policy)
        check(Data(bytes:again.raw!.dataPointer,count:NativeAOTExactTensorCache.outputBytes) == snapshot.rawBytes)
        let maskPtr=mask.dataPointer.assumingMemoryBound(to:UInt16.self);let prior=maskPtr[0];maskPtr[0] ^= 1
        let miss=try replayIndex.lookup(image:image,mask:mask,policy:policy);check(miss.raw == nil);maskPtr[0]=prior
        let differentModel=NativeAOTExactTensorCache.Policy(installedModelSHA256:String(repeating:"d",count:64),
            computeUnits:policy.computeUnits,runtime:policy.runtime,tensorABI:policy.tensorABI)
        let modelMiss=try replayIndex.lookup(image:image,mask:mask,policy:differentModel);check(modelMiss.raw == nil)
        rejects {_ = try NativeAOTRawPredictionReplay(indexFile:indexURL,expectedIndexSHA256:String(repeating:"0",count:64))}
        let metadata=try JSONSerialization.jsonObject(with:Data(contentsOf:record)) as! [String:Any]
        let rawFile=record.deletingLastPathComponent().appendingPathComponent(metadata["rawFile"] as! String)
        try corrupt.write(to:rawFile,options:.atomic)
        rejects {_ = try replayIndex.lookup(image:image,mask:mask,policy:policy)}
        try snapshot.rawBytes.write(to:rawFile,options:.atomic)
        print("PASS SAME actual synthetic raw6MiB snapshot; ON/OFF shared production composition;25 inside differences/outside0; bit-exact source+mask+8MiB input rebinding; corruption rejection; immutable output; archive roundtrip+quota+verified-exact-duplicate+source provenance fences; model loads0/predictions0")
        print("PASS explicit attested disk replay exact8MiB input hit; fresh immutable6MiB clone; mask/model-bit misses; index/meta binding; corrupt raw rejects without fallback prediction; default no auto-capture/cache")
    }
}
