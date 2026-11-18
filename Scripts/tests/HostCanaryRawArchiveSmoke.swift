import CoreGraphics
import CoreML
import Foundation
import ImageIO

func png(_ image:CGImage,_ url:URL)throws {
    let destination=CGImageDestinationCreateWithURL(url as CFURL,"public.png" as CFString,1,nil)!
    CGImageDestinationAddImage(destination,image,nil)
    precondition(CGImageDestinationFinalize(destination))
}
@main struct CanaryArchiveSmoke {
    static func main()throws {
        if CommandLine.arguments.count > 2 {
            let old=try NativeAOTRawPredictionArchive.read(URL(fileURLWithPath:CommandLine.arguments[2]))
            precondition(old.snapshot.capturedOriginalMask==nil)
            print("PASS existing legacy actual raw archive read: capture-only context nil; source/mask/input8MiB verified; model0")
        }
        let root=URL(fileURLWithPath:CommandLine.arguments[1])
        let sourceFile=root.appendingPathComponent("source.png"),manifest=root.appendingPathComponent("producer.json")
        let rgba:[UInt8]=[1,2,3,255,4,5,6,255,7,8,9,255,10,11,12,255,13,14,15,255,16,17,18,255]
        let original=CGImage(width:3,height:2,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:12,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),
            provider:CGDataProvider(data:Data(rgba) as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        try png(original,sourceFile)
        try Data("{\"actualCompiledSources\":\"synthetic-no-model-fixture\"}".utf8).write(to:manifest)
        let source=CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(sourceFile as CFURL,nil)!,0,nil)!
        let sourceSHA=NativeAOTRawPredictionSnapshot.sha(try Data(contentsOf:sourceFile)),config=Data("{\"synthetic\":true}".utf8)
        func archive(_ name:String,budget:Int=32*1024*1024)throws->HostCanaryRawArchive {
            try HostCanaryRawArchive(directory:root.appendingPathComponent(name),sourceFile:sourceFile,
                expectedSourceEncodedSHA256:sourceSHA,producerManifest:manifest,producerConfig:config,byteBudget:budget)
        }
        let writer=try archive("archive")
        let image=try MLMultiArray(shape:[1,3,1024,1024],dataType:.float16),mask=try MLMultiArray(shape:[1,1,1024,1024],dataType:.float16)
        let raw=try MLMultiArray(shape:[1,3,1024,1024],dataType:.float16)
        raw.dataPointer.initializeMemory(as:UInt8.self,repeating:0,count:raw.count*2)
        var removal:[UInt8]=[255,0,0,0,255,0]
        let alpha=try NativeAOTAlphaComposition.prepare(source:source)
        _ = try NativeResidentAOT.prepare(rgb:alpha.inferenceRGB,finalMask:removal,width:3,height:2,image:image,mask:mask)
        let policy=NativeAOTExactTensorCache.Policy(installedModelSHA256:String(repeating:"a",count:64),
            computeUnits:"cpuAndGPU",runtime:ProcessInfo.processInfo.operatingSystemVersionString,tensorABI:NativeAOTTensorCachePolicy.tensorABI)
        let snapshot=try NativeAOTRawPredictionSnapshot.capture(source:source,originalMask:removal,image:image,mask:mask,raw:raw,
            policy:policy,producerSHA256:writer.producerSHA256,producerConfigSHA256:writer.producerConfigSHA256)
        removal[0]=0
        precondition(snapshot.capturedOriginalMask==[255,0,0,0,255,0])
        let legacy=NativeAOTRawPredictionSnapshot(binding:snapshot.binding,rawBytes:snapshot.rawBytes)
        precondition(legacy.capturedOriginalMask==nil)
        var rejected=false
        do {try writer.append(legacy)}catch {rejected=true};precondition(rejected)
        try writer.append(snapshot)
        try writer.append(snapshot) // Exact cache-reuse duplicate does not add a record.
        let receipt=try writer.finish()
        let index=URL(fileURLWithPath:receipt["replayIndex"] as! String)
        let replay=try NativeAOTRawPredictionReplay(indexFile:index,expectedIndexSHA256:receipt["replayIndexSHA256"] as! String)
        try NativeAOTHostPredictionBudget.configure()
        let hit=try replay.lookup(image:image,mask:mask,policy:policy)
        precondition(hit.raw != nil && NativeAOTHostPredictionBudget.snapshot().actualCalls==0)
        let metadataObject=try JSONSerialization.jsonObject(with:Data(contentsOf:index)) as! [String:Any]
        let record=URL(fileURLWithPath:(metadataObject["records"] as! [[String:String]])[0]["metadataPath"]!)
        let stored=try NativeAOTRawPredictionArchive.read(record)
        precondition(stored.snapshot.capturedOriginalMask==nil && stored.originalMask==snapshot.capturedOriginalMask!)
        precondition((receipt["retainedBytes"] as! Int) <= 32*1024*1024)
        let wrong=NativeAOTRawPredictionSnapshot(binding:snapshot.binding,rawBytes:snapshot.rawBytes,capturedOriginalMask:[0,0,0,0,255,0])
        let wrongWriter=try archive("wrong")
        rejected=false;do {try wrongWriter.append(wrong)}catch {rejected=true};precondition(rejected)
        let quota=try archive("quota",budget:NativeAOTExactTensorCache.outputBytes+1024)
        rejected=false;do {try quota.append(snapshot)}catch HostCanaryRawArchive.Failure.quota {rejected=true};precondition(rejected)
        rejected=false;do {_ = try wrongWriter.finish()}catch HostCanaryRawArchive.Failure.noCapture {rejected=true};precondition(rejected)
        let mismatch=try archive("source-mismatch")
        var changed=try Data(contentsOf:sourceFile);changed.append(0);try changed.write(to:sourceFile)
        rejected=false;do {try mismatch.append(snapshot)}catch {rejected=true};precondition(rejected)
        let meta=try JSONSerialization.jsonObject(with:Data(contentsOf:record)) as! [String:Any]
        let rawFile=record.deletingLastPathComponent().appendingPathComponent(meta["rawFile"] as! String)
        var corrupt=try Data(contentsOf:rawFile);corrupt[0]^=1;try corrupt.write(to:rawFile)
        rejected=false;do {_ = try replay.lookup(image:image,mask:mask,policy:policy)}catch {rejected=true};precondition(rejected)
        print("PASS capture-only COW mask context; legacy2arg/read nil; strict source+mask regenerated8MiB append; real1record replayindex hit; budget0; corruption/quota/mask/source/noCapture failclosed; syntheticmodels0")
    }
}
