import CoreGraphics
@preconcurrency import CoreML
import CryptoKit
import Darwin
import Foundation

/// HOST ONLY. Immutable actual ALL300 RF output, before any consumer selection.
/// No GT, bbox reconstruction, training, source image or RGB serialization.
@available(macOS 15.0, *)
enum HostRFRawReplay {
    enum Failure: Error { case invalid(String), missing, quota, disabledRoute }
    enum Mode: String { case capture, replayOnly = "replay-only" }
    static let preprocessCodeSHA = "__RF_V2_PREPROCESS_CODE_SHA__"
    static let decoderCodeSHA = "__RF_V2_DECODER_CODE_SHA__"
    // Exact resize revisions in chronological order. A previous archive is
    // eligible only when the current normalized input also matches its FP32 SHA.
    private static let exactResizeRevisions = [
        "5d610e178b98d382ceeabf2ba9dfd9524a7ddc05244406e03f73c10378612633",
        "1fab4aaa70120d1925c64fa553284ea98d3782fec97a218c0cf089be694e97cf",
        "992188ed542d9704199bbfc8da9a5cca4d451d8e56072c2cc3f0a960022d9403",
        "95180763eb478e58f7fe363e179d2a126e32dddf35b98ef807797c4bfb345455",
    ]
    static let payloadBytes = 31_503_600
    static let maximumConfiguredRecords = 1_024
    static let maximumConfiguredBytes = 32 * 1_024 * 1_024 * 1_024

    /// Explicit host capture budgets; normal defaults remain32 records/1GiB.
    /// A corpus producer may raise these bounded limits without changing the
    /// raw tensor identity, decoder, model or per-artifact checksum contract.
    static func archiveBudgets(_ environment: [String: String]) throws -> (records: Int, bytes: Int) {
        func value(_ key: String, fallback: Int, minimum: Int, maximum: Int) throws -> Int {
            guard let text = environment[key] else { return fallback }
            guard let parsed = Int(text), parsed >= minimum, parsed <= maximum else {
                throw Failure.invalid("archive quota configuration")
            }
            return parsed
        }
        return (try value("AIDOKU_HOST_RF_RAW_MAX_RECORDS", fallback: 32,
                          minimum: 1, maximum: maximumConfiguredRecords),
                try value("AIDOKU_HOST_RF_RAW_MAX_BYTES", fallback: 1_073_741_824,
                          minimum: 0, maximum: maximumConfiguredBytes))
    }
    static let specs: [(String,[Int],Int)] = [
        ("boxes",[1,300,4],4_800),("logits",[1,300,5],6_000),
        ("instance_masks",[1,300,162,162],31_492_800)
    ]
    struct Identity: Codable, Hashable {
        let schema: String
        let base: NativeRFRawRequestCache.Key
        let width: Int
        let height: Int
        let inputSHA256: String
        let preprocessCodeSHA256: String
        // Decoder/cap/retain are deliberately NOT part of raw inference identity.
    }
    struct Header: Codable {
        let version: Int
        let identity: Identity
        let payloadSHA256: String
        let tensorSHA256: [String:String]
        let payloadBytes: Int
        let encoding: String
    }
    struct Binding {
        let identitySHA256: String
        let payloadSHA256: String
        let disposition: String
        let archivePreprocessCodeSHA256: String
    }
    final class Session: @unchecked Sendable {
        let root: URL
        let mode: Mode
        let modelURL: URL?
        let modelSHA: String
        let preprocessSHA: String
        let decoderSHA: String
        let maximumRecords: Int
        let maximumBytes: Int
        init(root: URL, mode: Mode, modelSHA: String, preprocessSHA: String, decoderSHA: String,
             modelURL: URL? = nil, maximumRecords: Int = 32, maximumBytes: Int = 1_073_741_824) throws {
            guard Self.hex(modelSHA),Self.hex(preprocessSHA),Self.hex(decoderSHA),
                  maximumRecords > 0,maximumRecords <= HostRFRawReplay.maximumConfiguredRecords,
                  maximumBytes >= 0,maximumBytes <= HostRFRawReplay.maximumConfiguredBytes else {
                throw Failure.invalid("archive configuration")
            }
            self.root=root.standardizedFileURL.resolvingSymlinksInPath()
            self.mode=mode;self.modelSHA=modelSHA;self.preprocessSHA=preprocessSHA;self.decoderSHA=decoderSHA
            self.modelURL=modelURL;self.maximumRecords=maximumRecords;self.maximumBytes=maximumBytes
            if mode == .capture {try FileManager.default.createDirectory(at:self.root,withIntermediateDirectories:true)}
        }
        static func hex(_ s:String)->Bool {s.count==64 && s.utf8.allSatisfy{(48...57).contains($0)||(97...102).contains($0)}}
        func identity(input:MLMultiArray,source:any NativeRFDETRInferenceSource,key:NativeRFRawRequestCache.Key) throws -> Identity {
            guard key.sourceRGBIdentity==source.identity,key.installedModelTreeSHA256==modelSHA else {
                throw Failure.invalid("source or model binding")
            }
            if let modelURL,try HostRFRawReplay.treeDigest(modelURL) != modelSHA {
                throw Failure.invalid("same-path compiled model replacement")
            }
            guard input.dataType == .float32,input.shape.map(\.intValue)==[1,3,648,648],
                  input.strides.map(\.intValue)==[1_259_712,419_904,648,1] else {throw Failure.invalid("input FP32 ABI")}
            let hash=HostRFRawReplay.digest(UnsafeRawBufferPointer(start:input.dataPointer,count:5_038_848))
            return Identity(schema:"rf-actual-f32-all300-le-v2",base:key,width:source.width,height:source.height,
                inputSHA256:hash,preprocessCodeSHA256:preprocessSHA)
        }
        /// Cross-process flock covers lookup + cold capture. Thus only ONE actual
        /// predictor runs per cold key; no race can consume a different winner.
        func snapshot(input:MLMultiArray,source:any NativeRFDETRInferenceSource,key:NativeRFRawRequestCache.Key,
                      preprocessingMS:Double=0,
                      fresh:() throws -> (MLFeatureProvider,Double)) throws -> (NativeRFRawSnapshot,Binding) {
            let id=try identity(input:input,source:source,key:key)
            let idSHA=try HostRFRawReplay.objectSHA(id)
            return try locked {
                try Task.checkCancellation()
                let record=root.appendingPathComponent(idSHA+".record.json")
                if FileManager.default.fileExists(atPath:record.path) {
                    let (header,data)=try read(id:id,idSHA:idSHA)
                    return (try materialize(data,source:source,key:key,preprocessMS:preprocessingMS,modelMS:0),
                        Binding(identitySHA256:idSHA,payloadSHA256:header.payloadSHA256,disposition:"disk-replay",
                            archivePreprocessCodeSHA256: id.preprocessCodeSHA256))
                }
                if mode == .replayOnly, let index = HostRFRawReplay.exactResizeRevisions.firstIndex(of: preprocessSHA) {
                    for revision in HostRFRawReplay.exactResizeRevisions[..<index].reversed() {
                        let prior = Identity(schema: id.schema, base: id.base, width: id.width, height: id.height,
                            inputSHA256: id.inputSHA256,
                            preprocessCodeSHA256: revision)
                        let priorSHA = try HostRFRawReplay.objectSHA(prior)
                        if FileManager.default.fileExists(atPath: root.appendingPathComponent(priorSHA + ".record.json").path) {
                            let (header, data) = try read(id: prior, idSHA: priorSHA)
                            return (try materialize(data, source: source, key: key, preprocessMS: preprocessingMS, modelMS: 0),
                                Binding(identitySHA256: priorSHA, payloadSHA256: header.payloadSHA256, disposition: "disk-replay",
                                    archivePreprocessCodeSHA256: prior.preprocessCodeSHA256))
                        }
                    }
                }
                guard mode == .capture else {throw Failure.missing}
                try quota(reserving:HostRFRawReplay.payloadBytes+65_536)
                // No inference is permitted until all lookup/quota checks pass.
                let (output,modelMS)=try fresh()
                try Task.checkCancellation()
                let data=try HostRFRawReplay.encode(output)
                let sha=HostRFRawReplay.digest(data)
                let header=Header(version:2,identity:id,payloadSHA256:sha,
                    tensorSHA256:HostRFRawReplay.tensorHashes(data),payloadBytes:data.count,encoding:"IEEE754-f32-le")
                let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
                let metadata=try encoder.encode(header)
                guard metadata.count<=65_536 else {throw Failure.invalid("oversized header")}
                try Task.checkCancellation()
                try publish(data,to:root.appendingPathComponent(sha+".f32le"))
                try publish(metadata,to:record)
                let (stored,verified)=try read(id:id,idSHA:idSHA)
                guard stored.payloadSHA256==sha else {throw Failure.invalid("publication conflict")}
                return (try materialize(verified,source:source,key:key,preprocessMS:preprocessingMS,modelMS:modelMS),
                    Binding(identitySHA256:idSHA,payloadSHA256:sha,disposition:"captured-actual",
                        archivePreprocessCodeSHA256: id.preprocessCodeSHA256))
            }
        }
        private func locked<T>(_ body:() throws->T) throws->T {
            let path=root.appendingPathComponent(".archive.lock").path
            let flags=mode == .capture ? O_CREAT|O_RDWR|O_CLOEXEC|O_NOFOLLOW : O_RDONLY|O_CLOEXEC|O_NOFOLLOW
            let fd=Darwin.open(path,flags,0o600)
            guard fd>=0 else {throw Failure.missing}
            defer {Darwin.close(fd)}
            guard flock(fd,mode == .capture ? LOCK_EX : LOCK_SH)==0 else {throw Failure.invalid("lock")}
            defer {flock(fd,LOCK_UN)}
            return try body()
        }
        private func quota(reserving:Int) throws {
            var records=0,total=0
            for file in try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey]) {
                let value=try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
                guard value.isSymbolicLink != true,value.isRegularFile==true else {throw Failure.invalid("archive member")}
                let size=value.fileSize ?? 0
                guard size>=0,size<=maximumBytes,total<=maximumBytes-size else {throw Failure.quota}
                total+=size
                if file.lastPathComponent.hasSuffix(".record.json"){records+=1}
            }
            guard records<maximumRecords,reserving<=maximumBytes,total<=maximumBytes-reserving else {throw Failure.quota}
        }
        private func read(id:Identity,idSHA:String) throws->(Header,Data) {
            let metadata=try ownedRead(root.appendingPathComponent(idSHA+".record.json"),maximum:65_536)
            let header=try JSONDecoder().decode(Header.self,from:metadata)
            guard header.version==2,header.identity==id,header.encoding=="IEEE754-f32-le",
                  header.payloadBytes==HostRFRawReplay.payloadBytes,Self.hex(header.payloadSHA256),
                  Set(header.tensorSHA256.keys)==Set(HostRFRawReplay.specs.map{$0.0}),
                  header.tensorSHA256.values.allSatisfy(Self.hex) else {throw Failure.invalid("header/identity")}
            let bytes=try ownedRead(root.appendingPathComponent(header.payloadSHA256+".f32le"),maximum:HostRFRawReplay.payloadBytes)
            guard bytes.count==HostRFRawReplay.payloadBytes,HostRFRawReplay.digest(bytes)==header.payloadSHA256,
                  HostRFRawReplay.tensorHashes(bytes)==header.tensorSHA256 else {throw Failure.invalid("raw checksum/size")}
            return (header,bytes)
        }
        private func ownedRead(_ url:URL,maximum:Int) throws->Data {
            let fd=Darwin.open(url.path,O_RDONLY|O_CLOEXEC|O_NOFOLLOW)
            guard fd>=0 else {throw Failure.invalid("missing/symlink payload")}
            let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
            defer {try? handle.close()}
            var state=stat()
            guard fstat(fd,&state)==0,(state.st_mode&S_IFMT)==S_IFREG,state.st_size>=0,state.st_size<=maximum else {
                throw Failure.invalid("payload type/size")
            }
            var bytes=Data()
            while bytes.count < Int(state.st_size) {
                let part=try handle.read(upToCount:Int(state.st_size)-bytes.count) ?? Data()
                guard !part.isEmpty else {throw Failure.invalid("short payload read")}
                bytes.append(part)
            }
            guard bytes.count==Int(state.st_size),bytes.count<=maximum,
                  (try handle.read(upToCount:1) ?? Data()).isEmpty else {throw Failure.invalid("incomplete payload")}
            return bytes // Owned bytes, not mmap: post-check file mutation cannot change consumed snapshot.
        }
        private func publish(_ bytes:Data,to destination:URL) throws {
            if FileManager.default.fileExists(atPath:destination.path) {
                guard try ownedRead(destination,maximum:bytes.count)==bytes else {throw Failure.invalid("immutable blob collision")}
                return
            }
            let temp=root.appendingPathComponent(".pending-"+UUID().uuidString)
            defer {try? FileManager.default.removeItem(at:temp)}
            try bytes.write(to:temp,options:.withoutOverwriting)
            let fd=Darwin.open(temp.path,O_RDONLY|O_CLOEXEC|O_NOFOLLOW)
            guard fd>=0 else {throw Failure.invalid("temporary open")}
            let synced=fsync(fd);Darwin.close(fd)
            guard synced==0 else {throw Failure.invalid("fsync")}
            // Link is no-overwrite atomic publication. Exclusive flock protects quota and cold capture.
            try FileManager.default.linkItem(at:temp,to:destination)
        }
        private func materialize(_ data:Data,source:any NativeRFDETRInferenceSource,key:NativeRFRawRequestCache.Key,
                                 preprocessMS:Double,modelMS:Double) throws->NativeRFRawSnapshot {
            var arrays:[String:MLFeatureValue]=[:],offset=0
            for (name,shape,count) in HostRFRawReplay.specs {
                let array=try MLMultiArray(shape:shape.map{NSNumber(value:$0)},dataType:.float32)
                let values=array.dataPointer.assumingMemoryBound(to:Float.self)
                try data.withUnsafeBytes { raw in
                    for i in 0..<(count/4) {
                        let bits=UInt32(littleEndian:raw.loadUnaligned(fromByteOffset:offset+i*4,as:UInt32.self))
                        let value=Float(bitPattern:bits)
                        guard value.isFinite else {throw Failure.invalid("nonfinite stored tensor")}
                        values[i]=value
                    }
                }
                arrays[name]=MLFeatureValue(multiArray:array);offset+=count
            }
            let provider=try MLDictionaryFeatureProvider(dictionary:arrays)
            return try NativeRFRawSnapshot(actualOutput:provider,preprocessingMilliseconds:preprocessMS,
                modelMilliseconds:modelMS,weightsSHA256:key.expectedWeightsSHA256,sourceIdentity:source.identity)
        }
    }

    static var enabled:Bool {ProcessInfo.processInfo.environment["AIDOKU_HOST_RF_RAW_MODE"] != nil}
    private static let processSession: Result<Session,Error> = Result {
        let env=ProcessInfo.processInfo.environment
        guard let mode=env["AIDOKU_HOST_RF_RAW_MODE"].flatMap(Mode.init),
              let path=env["AIDOKU_HOST_RF_RAW_ARCHIVE"],path.hasPrefix("/"),
              let bundlePath=env["AIDOKU_HOST_MODEL_BUNDLE"],let bundle=Bundle(path:bundlePath),
              let url=bundle.url(forResource:NativeRFDETRLayoutResource.resourceName,withExtension:"mlmodelc")
        else {throw Failure.invalid("process archive configuration")}
        let budgets = try archiveBudgets(env)
        return try Session(root:URL(fileURLWithPath:path),mode:mode,modelSHA:treeDigest(url),
            preprocessSHA:preprocessCodeSHA,decoderSHA:decoderCodeSHA,modelURL:url,
            maximumRecords:budgets.records,maximumBytes:budgets.bytes)
    }
    static func preflight() throws {
        guard enabled else {return}
        guard NativeRFRawCachePolicy.enabled else {throw Failure.disabledRoute}
        let session = try processSession.get()
        if let url = session.modelURL, try treeDigest(url) != session.modelSHA {
            throw Failure.invalid("same-path compiled model replacement")
        }
    }
    private struct Observation {let binding:Binding;var consumers:[[String:Any]]=[]}
    private final class Ledger: @unchecked Sendable {
        let lock=NSLock();var values:[NativeRFRawRequestCache.Key:Observation]=[:];var order:[NativeRFRawRequestCache.Key]=[]
    }
    private static let ledger=Ledger()
    static func snapshot(input:MLMultiArray,source:any NativeRFDETRInferenceSource,key:NativeRFRawRequestCache.Key,
                         preprocessingMS:Double,fresh:() throws->(MLFeatureProvider,Double)) throws->NativeRFRawSnapshot {
        let session=try processSession.get()
        let (value,binding)=try session.snapshot(input:input,source:source,key:key,preprocessingMS:preprocessingMS,fresh:fresh)
        ledger.lock.lock();defer{ledger.lock.unlock()}
        ledger.values[key]=Observation(binding:binding)
        ledger.order.removeAll{$0==key};ledger.order.append(key)
        while ledger.order.count>32 {ledger.values.removeValue(forKey:ledger.order.removeFirst())}
        return value
    }
    static func observe(_ result:NativeRFDETRLayoutResult,key:NativeRFRawRequestCache.Key,
                        maximumMasks:Int,retainAll:Bool) throws {
        let session=try processSession.get()
        ledger.lock.lock();defer{ledger.lock.unlock()}
        guard var row=ledger.values[key] else {throw Failure.invalid("unarchived memory result")}
        let consumer:[String:Any]=["rawIdentitySHA256":row.binding.identitySHA256,"decoderCodeSHA256":session.decoderSHA,
            "maximumMaskQueries":maximumMasks,"retainAllQueryMasks":retainAll,
            "native17Schema":NativeRFDETRSourceSupportGrid.schema,
            "hostBuildFingerprint":ProcessInfo.processInfo.environment["AIDOKU_PIPELINE_FINGERPRINT"] ?? "unavailable"]
        let encoded=try JSONSerialization.data(withJSONObject:consumer,options:.sortedKeys)
        row.consumers.append(["consumer":consumer,"consumerKeySHA256":digest(encoded),
            "typedNumericSHA256":try typedDigest(result)])
        if row.consumers.count>8 {row.consumers.removeFirst()}
        ledger.values[key]=row
    }
    static func diagnostics(sourceIdentity:String)->[String:Any] {
        guard enabled else {return [:]}
        ledger.lock.lock();defer{ledger.lock.unlock()}
        return ["schema":"host-rf-raw-archive-v2","rawRecords":ledger.order.compactMap {key->[String:Any]? in
            guard key.sourceRGBIdentity==sourceIdentity,let value=ledger.values[key] else{return nil}
            return ["sourceIdentity":sourceIdentity,"rawIdentitySHA256":value.binding.identitySHA256,
                "rawPayloadSHA256":value.binding.payloadSHA256,"disposition":value.binding.disposition,
                "archivePreprocessCodeSHA256":value.binding.archivePreprocessCodeSHA256,
                "currentPreprocessCodeSHA256":preprocessCodeSHA,
                "consumers":value.consumers,"actualPredictionCounterAuthority":"NativeRFRawCacheDiagnostics"]
        }]
    }
    static func digest(_ bytes:Data)->String {bytes.withUnsafeBytes{digest($0)}}
    static func digest(_ bytes:UnsafeRawBufferPointer)->String {
        var hash=SHA256();hash.update(bufferPointer:bytes)
        return hash.finalize().map{String(format:"%02x",$0)}.joined()
    }
    static func objectSHA<T:Encodable>(_ object:T) throws->String {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        return digest(try encoder.encode(object))
    }
    static func encode(_ provider:MLFeatureProvider) throws->Data {
        var data=Data(count:payloadBytes),offset=0
        try data.withUnsafeMutableBytes { target in
            for (name,shape,count) in specs {
                guard let array=provider.featureValue(for:name)?.multiArrayValue,array.dataType == .float32,
                      array.shape.map(\.intValue)==shape,array.strides.allSatisfy({$0.intValue>0}) else {
                    throw Failure.invalid("actual raw FP32 contract")
                }
                let values=array.dataPointer.assumingMemoryBound(to:Float.self),strides=array.strides.map(\.intValue)
                for flat in 0..<(count/4) {
                    if flat&65535==0 {try Task.checkCancellation()}
                    var remainder=flat,index=0
                    for dim in shape.indices.reversed(){index+=(remainder%shape[dim])*strides[dim];remainder/=shape[dim]}
                    let value=values[index]
                    guard value.isFinite else {throw Failure.invalid("nonfinite actual tensor")}
                    target.storeBytes(of:value.bitPattern.littleEndian,toByteOffset:offset+flat*4,as:UInt32.self)
                }
                offset+=count
            }
        }
        return data
    }
    static func tensorHashes(_ data:Data)->[String:String] {
        guard data.count==payloadBytes else{return [:]}
        var result:[String:String]=[:],offset=0
        data.withUnsafeBytes {raw in
            for (name,_,count) in specs {
                result[name]=digest(UnsafeRawBufferPointer(rebasing:raw[offset..<offset+count]));offset+=count
            }
        }
        return result
    }
    /// Actual current compiled bytes, never memoized solely by URL/mtime/size.
    static func treeDigest(_ root:URL) throws->String {
        guard let iterator=FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey])
        else {throw Failure.invalid("model tree")}
        var files:[URL]=[]
        for case let url as URL in iterator {
            let value=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
            guard value.isSymbolicLink != true else{throw Failure.invalid("model symlink")}
            if value.isRegularFile==true {files.append(url)}
        }
        guard !files.isEmpty else{throw Failure.invalid("empty model tree")}
        var hash=SHA256()
        for file in files.sorted(by:{$0.path<$1.path}) {
            let name=String(file.path.dropFirst(root.path.count+1)),size=try file.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
            hash.update(data:Data("\(name.utf8.count):\(name):\(size):".utf8))
            let handle=try FileHandle(forReadingFrom:file);defer{try? handle.close()}
            while let bytes=try handle.read(upToCount:1_048_576),!bytes.isEmpty{hash.update(data:bytes)}
        }
        return hash.finalize().map{String(format:"%02x",$0)}.joined()
    }
    static func typedDigest(_ result:NativeRFDETRLayoutResult) throws->String {
        guard result.classEvidence.count==300,let grid=result.semanticGrid,let support=result.sourceSupportGrid,
              support.native17Fields.count==17*162*162 else{throw Failure.invalid("incomplete decoded fields")}
        var hash=SHA256()
        func integer(_ n:Int){var b=Int64(n).littleEndian;withUnsafeBytes(of:&b){hash.update(bufferPointer:$0)}}
        func float(_ n:Float){var b=n.bitPattern.littleEndian;withUnsafeBytes(of:&b){hash.update(bufferPointer:$0)}}
        func double(_ n:Double){var b=n.bitPattern.littleEndian;withUnsafeBytes(of:&b){hash.update(bufferPointer:$0)}}
        func rect(_ r:CGRect){for n in [r.origin.x,r.origin.y,r.width,r.height]{double(Double(n))}}
        func floats(_ values:[Float]){integer(values.count);values.withUnsafeBytes{hash.update(bufferPointer:$0)}}
        func mask(_ value:NativeRFDETRLayoutMask?){
            integer(value==nil ? 0:1)
            if let value{integer(value.queryID);integer(value.sourceWidth);integer(value.sourceHeight);floats(value.logits)}
        }
        integer(result.sourceWidth);integer(result.sourceHeight);integer(result.maskQueriesOmittedByBudget)
        integer(result.primitives.count)
        for p in result.primitives {
            integer(p.queryID);integer(p.semanticClass.rawValue);float(p.confidence)
            rect(p.normalizedBounds);rect(p.sourceBounds);mask(p.mask)
            integer(p.supportPolygon==nil ? 0:1)
            if let points=p.supportPolygon{integer(points.count);for p in points{double(Double(p.x));double(Double(p.y))}}
        }
        integer(result.classEvidence.count)
        for q in result.classEvidence{integer(q.queryID);floats(q.logits);floats(q.probabilities);rect(q.normalizedBounds);rect(q.sourceBounds);mask(q.mask)}
        integer(grid.width);integer(grid.height);integer(grid.side);floats(grid.probabilities)
        integer(grid.weightedMeanProbabilities==nil ? 0:1)
        if let mean=grid.weightedMeanProbabilities{floats(mean)}
        floats(support.native17Fields)
        return hash.finalize().map{String(format:"%02x",$0)}.joined()
    }
}
