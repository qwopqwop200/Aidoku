import CoreGraphics
import CryptoKit
import Darwin
import Foundation

/// Host-only experiment adapter. DB inference is allowed once only when the
/// exact-resolution full map is absent; later variants replay that same map.
/// All production crop planning, rec tensor-cache decisions, confidence gates,
/// recoveries, ownership and Reader grouping still execute normally.
enum HostDirectionReplay {
    final class Input: @unchecked Sendable {
        let source: String
        let width: Int
        let height: Int
        private var storedMap: NativeMainEnsembleOCRProbability.Sample?
        private let lock=NSLock()
        let probabilityPath: String
        let boxes: [NativeCoreMLDetectionBox]
        let sourceSHA256:String
        let mapWidth:Int
        let mapHeight:Int
        init(source:String,width:Int,height:Int,map:NativeMainEnsembleOCRProbability.Sample?,
             probabilityPath:String,boxes:[NativeCoreMLDetectionBox],sourceSHA256:String,mapWidth:Int,mapHeight:Int) {
            self.source=source;self.width=width;self.height=height;storedMap=map
            self.probabilityPath=probabilityPath;self.boxes=boxes;self.sourceSHA256=sourceSHA256
            self.mapWidth=mapWidth;self.mapHeight=mapHeight
        }
        var map:NativeMainEnsembleOCRProbability.Sample? { lock.withLock { storedMap } }
        func record(_ map:NativeCoreMLDetectionMap,originX:Int,originY:Int,fullWidth:Int,fullHeight:Int) throws {
            try lock.withLock {
                guard storedMap == nil else { return }
                guard originX==0,originY==0,map.width==mapWidth,map.height==mapHeight,
                      fullWidth==mapWidth,fullHeight==mapHeight else { throw HostError.message("Bootstrap map geometry mismatch") }
                let url=URL(fileURLWithPath:probabilityPath)
                try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
                let data=map.values.withUnsafeBytes { Data($0) }
                try data.write(to:url,options:.atomic)
                let metadata:[String:Any]=["sourceSHA256":sourceSHA256,"width":mapWidth,"height":mapHeight,
                    "SHA256":SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()]
                try JSONSerialization.data(withJSONObject:metadata).write(to:url.appendingPathExtension("identity.json"),options:.atomic)
                storedMap = .init(sourceWidth:width,sourceHeight:height,resizedWidth:mapWidth,resizedHeight:mapHeight,
                    region:CGRect(x:0,y:0,width:mapWidth,height:mapHeight),width:mapWidth,height:mapHeight,values:map.values)
            }
        }
    }
    @TaskLocal static var current: Input?

    /// Keep the ordinary analysis URL while avoiding a second byte-identical
    /// source PNG for every completed replay. Transcoded inputs stay untouched.
    static func deduplicateInput(_ directory:URL,source:URL,digest:String) throws {
        let path=directory.appendingPathComponent("input.png"),fm=FileManager.default
        guard fm.fileExists(atPath:path.path),
              try fm.attributesOfItem(atPath:path.path)[.type] as? FileAttributeType != .typeSymbolicLink,
              path.standardizedFileURL != source.resolvingSymlinksInPath().standardizedFileURL else {return}
        let original=try Data(contentsOf:source,options:.mappedIfSafe)
        guard SHA256.hash(data:original).map({String(format:"%02x",$0)}).joined()==digest,
              try Data(contentsOf:path,options:.mappedIfSafe)==original else {return}
        let temporary=directory.appendingPathComponent(".input-link-\(UUID().uuidString)")
        defer {try? fm.removeItem(at:temporary)}
        try fm.createSymbolicLink(at:temporary,withDestinationURL:source.resolvingSymlinksInPath())
        guard Darwin.rename(temporary.path,path.path)==0 else {
            throw HostError.message("Unable to replace identical replay input with original link")
        }
    }

    static func detection(frame: NativeOCRRGBAFrame, requestID: String,
                          configuration: NativeCoreMLDBPostprocessConfiguration,
                          probabilityObserver: NativeMainEnsembleOCRProbability.Observer?) throws -> NativeCoreMLDetectionResult? {
        guard let input=current else { return nil }
        guard frame.width == input.width, frame.height == input.height,
              configuration == .manga else { throw HostError.message("Replay detector source/configuration mismatch") }
        guard let map=input.map else {
            HostDump.capture("detector-bootstrap",["source":input.source,"inferenceCalls":1,
                "reason":"correct-resolution full probability map not persisted"])
            return nil
        }
        guard map.width <= frame.width, map.height <= frame.height else {
            throw HostError.message("Replay DB map predates no-upsample content geometry")
        }
        _ = probabilityObserver?(map)
        HostDump.capture("detector-probability-map", ["raw":input.probabilityPath,
            "width":map.width,"height":map.height,
            "format":"little-endian float32 row-major","normalizedRect":[0,0,1,1],
            "reused":true])
        HostDump.capture("detector-replay",["source":input.source,"inferenceCalls":0,"boxes":input.boxes.count])
        let d=NativeCoreMLDetectionDiagnostics(requestID:requestID,generation:0,
            backend:"saved-db-evidence",executionProvider:"none",computeUnits:"none",modelName:"PP-OCRv6-Manga",
            inputFeatureName:"saved",outputFeatureName:"saved",inputShape:[],outputShape:[],
            sourceWidth:input.width,sourceHeight:input.height,resizedWidth:map.width,resizedHeight:map.height,
            threshold:configuration.threshold,boxThreshold:configuration.boxThreshold,unclipRatio:configuration.unclipRatio,
            maximumCandidates:configuration.maximumCandidates,candidateComponents:input.boxes.count,detectedBoxes:input.boxes.count,
            modelWasAlreadyLoaded:true,modelLoadMilliseconds:0,inputTensorCreationMilliseconds:0,tensorGraphMilliseconds:0,
            preprocessingMilliseconds:0,predictionMilliseconds:0,outputMaterializationMilliseconds:0,
            dbPostprocessingMilliseconds:0,postprocessingMilliseconds:0,totalMilliseconds:0)
        return .init(requestID:requestID,width:input.width,height:input.height,boxes:input.boxes,diagnostics:d)
    }

    static func load(_ row:[String:Any],loadProbability:Bool=true) throws -> Input {
        let path=row["detectorReplay"] as! String
        let saved=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:path))) as! [String:Any]
        let source=row["source"] as! String
        let digest=SHA256.hash(data:try Data(contentsOf:URL(fileURLWithPath:source))).map { String(format:"%02x",$0) }.joined()
        guard digest == row["sourceSHA256"] as? String,
              saved["sourceSHA256"] as? String == digest,
              saved["configuration"] as? [Double] == [0.85,0.25,1.4,3],
              let rows=saved["boxes"] as? [[String:Any]] else { throw HostError.message("Stale replay evidence") }
        let width=saved["width"] as! Int,height=saved["height"] as! Int
        let decoder=JSONDecoder()
        decoder.dataDecodingStrategy = .custom { decoder in
            let c=try decoder.singleValueContainer()
            struct Bytes:Decodable { let base64:String }
            let value=try (try? c.decode(String.self)) ?? c.decode(Bytes.self).base64
            guard let data=Data(base64Encoded:value) else { throw HostError.message("Invalid replay bytes") }
            return data
        }
        func decode<T:Decodable>(_ t:T.Type,_ v:Any?) throws -> T? {
            guard let v, !(v is NSNull) else { return nil }
            func codablePoints(_ value:Any) -> Any {
                if let d=value as? [String:Any] {
                    if d.count == 2, let x=d["x"] as? NSNumber,let y=d["y"] as? NSNumber { return [x,y] }
                    return d.mapValues(codablePoints)
                }
                if let a=value as? [Any] { return a.map(codablePoints) }
                return value
            }
            return try decoder.decode(t,from:JSONSerialization.data(withJSONObject:codablePoints(v)))
        }
        let boxes=try rows.map { b -> NativeCoreMLDetectionBox in
            let polygon=HostDirectionAudit.polygon(b["polygon"])
            guard polygon.count == 4 else { throw HostError.message("Invalid replay DB quad") }
            return .init(polygon:polygon,score:(b["score"] as! NSNumber).doubleValue,
                erasurePolygons:(b["erasurePolygons"] as? [Any] ?? []).map { HostDirectionAudit.polygon($0) },
                recognitionPolygon:(b["recognitionPolygon"] is NSNull || b["recognitionPolygon"] == nil) ? nil : HostDirectionAudit.polygon(b["recognitionPolygon"]),
                isThinFinePrintRecovery:b["isThinFinePrintRecovery"] as? Bool ?? false,
                finePrintRetryPolygons:(b["finePrintRetryPolygons"] as? [Any] ?? []).map { HostDirectionAudit.polygon($0) },
                recognitionColumnEvidence:try decode(NativeOCRDetectorColumnEvidence.self,b["recognitionColumnEvidence"]),
                detectorSeedEvidence:try decode(NativeOCRDetectorSeedEvidence.self,b["detectorSeedEvidence"]))
        }
        let descriptor=saved["probability"] as! [String:Any]
        let mapPath=descriptor["path"] as! String
        let mw=descriptor["width"] as! Int,mh=descriptor["height"] as! Int
        var sample:NativeMainEnsembleOCRProbability.Sample?
        let mapURL=URL(fileURLWithPath:mapPath)
        if loadProbability,FileManager.default.fileExists(atPath:mapPath) {
            let data=try Data(contentsOf:mapURL)
            let identity=descriptor["bootstrap"] as? Bool == true
                ? try JSONSerialization.jsonObject(with:Data(contentsOf:mapURL.appendingPathExtension("identity.json"))) as! [String:Any]
                : descriptor
            guard identity["sourceSHA256"] as? String == digest,
                  identity["width"] as? Int == mw, identity["height"] as? Int == mh,
                  SHA256.hash(data:data).map({String(format:"%02x",$0)}).joined() == identity["SHA256"] as? String,
                  data.count == mw*mh*4 else { throw HostError.message("Replay map identity/geometry mismatch") }
            let values=data.withUnsafeBytes { Array($0.bindMemory(to:Float.self)) }
            sample = .init(sourceWidth:width,sourceHeight:height,resizedWidth:mw,resizedHeight:mh,
                region:CGRect(x:0,y:0,width:mw,height:mh),width:mw,height:mh,values:values)
        } else if loadProbability,descriptor["bootstrap"] as? Bool != true { throw HostError.message("Replay map missing") }
        return .init(source:source,width:width,height:height,
            map:sample,probabilityPath:mapPath,boxes:boxes,sourceSHA256:digest,mapWidth:mw,mapHeight:mh)
    }

    /// Exact production first-recognizer audit. This branch never calls the
    /// image-output/translation path or prepares native model resources.
    @MainActor static func runFirstPassGeometryProbe(request: URL, output: URL, root: URL) async throws -> Int32 {
        guard !HostBuildMode.savedReaderReplay else { throw HostError.message("Probe requires the production Reader build") }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: request))
        guard let spec = object as? [String: Any], let rows = spec["pages"] as? [[String: Any]], !rows.isEmpty,
              let rfCache = spec["rfCache"] as? String, !rfCache.isEmpty, spec["variants"] == nil else {
            throw HostError.message("Probe requires pages + rfCache, without replay variants")
        }
        // Validate required fields before entering the existing identity-checked replay loader.
        var ids = Set<String>()
        for row in rows {
            guard let id = row["id"] as? String, !id.isEmpty, ids.insert(id).inserted,
                  let source = row["source"] as? String, !source.isEmpty,
                  let replay = row["detectorReplay"] as? String, !replay.isEmpty,
                  let digest = row["sourceSHA256"] as? String, digest.count == 64,
                  digest.allSatisfy({ $0.isHexDigit }) else { throw HostError.message("Invalid/duplicate probe source row") }
        }
        try HostEnvironment.load(root: root)
        guard ProcessInfo.processInfo.environment["AIDOKU_DISABLE_RF_LAYOUT"] != "1",
              ProcessInfo.processInfo.environment["AIDOKU_HOST_SAVED_READER_REPLAY"] != "1" else {
            throw HostError.message("Probe requires default production Reader with RF enabled")
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var results: [[String: Any]] = []
        var failures = 0
        for (index, row) in rows.enumerated() {
            try Task.checkCancellation()
            let id = row["id"] as! String
            let directory = output.appendingPathComponent(String(format: "%04d", index + 1))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let started = ProcessInfo.processInfo.systemUptime
            var result: [String: Any] = ["id": id, "sourceSHA256": row["sourceSHA256"]!, "status": "failed"]
            do {
                let input = try load(row)
                guard input.map != nil else { throw HostFirstPassGeometryProbe.Failure.replayRequired }
                let source = URL(fileURLWithPath: input.source)
                // Same installed/default settings resolution as the ordinary CLI;
                // request confidence, when present, is the sole explicit override.
                var arguments = ["--ocr-only", "--quiet"]
                if let confidence = spec["confidence"] {
                    guard let value = confidence as? NSNumber, value.doubleValue.isFinite,
                          (0...1).contains(value.doubleValue) else { throw HostError.message("Invalid probe confidence") }
                    arguments += ["--confidence", String(value.doubleValue)]
                }
                arguments += ["--", source.path]
                let options = try HostOptions(root: root, arguments: arguments)
                guard options.tier == .manga, options.ocrConfiguration.detectorPostprocessConfiguration == .manga,
                      let expected = NativeCoreMLDetectionPreprocessor.contentDimensions(
                          sourceWidth: input.width, sourceHeight: input.height, maximumSide: options.detectorSide),
                      input.mapWidth == expected.width, input.mapHeight == expected.height else {
                    throw HostError.message("Replay DB tier/configuration/resolution differs from default OCR settings")
                }
                let rf = try HostRFLayoutReplay.Context(root: root, cache: URL(fileURLWithPath: rfCache),
                    sourceSHA256: input.sourceSHA256, width: input.width, height: input.height)
                let probe = try HostFirstPassGeometryProbe.Context(
                    receiptURL: directory.appendingPathComponent("first-pass-geometry.json"),
                    sourceSHA256: input.sourceSHA256, width: input.width, height: input.height)
                // Decode the source once; no source RGB/PNG/preview is emitted.
                let image = try ImageTranslationMain.loadImage(source)
                let reader = ReaderOCRService()
                let configuration = options.ocrConfiguration
                let receipt = try await $current.withValue(input) {
                    try await HostRFLayoutReplay.$context.withValue(rf) {
                        // Reader's RF fallback catches normal errors; preflight here
                        // preserves corrupt/missing replay failures before that catch.
                        guard try HostRFLayoutReplay.read(image: image, maximumMasks: 160) != nil else {
                            throw HostFirstPassGeometryProbe.Failure.replayRequired
                        }
                        return try await HostFirstPassGeometryProbe.audit(context: probe) {
                            _ = try await reader.recognize(image: image, configuration: configuration)
                        }
                    }
                }
                try Task.checkCancellation()
                let statistics = rf.statistics
                guard statistics["RF_model_calls"] as? Int == 0,
                      (statistics["RF_replay_hits"] as? Int ?? 0) >= 2 else {
                    throw HostError.message("Production Reader did not consume full RF replay without prediction")
                }
                result["status"] = "geometry-probed"
                result["receipt"] = probe.receiptURL.path
                result["recognizerInputCount"] = receipt.regions.count
                result["recognizer_model_calls"] = receipt.recognizerModelCalls
                result["DB_model_calls"] = 0
                result["RF"] = statistics
                result["ocrConfiguration"] = HostDump.json(options.ocrConfiguration)
                result["engineFingerprint"] = ProcessInfo.processInfo.environment["AIDOKU_PIPELINE_FINGERPRINT"] ?? "unknown"
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures += 1
                result["error"] = String(describing: error)
                if case HostFirstPassGeometryProbe.Failure.firstPassNotReached = error {
                    result["status"] = "first-pass-not-reached"
                }
            }
            result["milliseconds"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("probe-status.json"), options: .atomic)
            results.append(result)
            // The summary is this run's progress, never an OCR resume marker.
            try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "mode": "first-pass-geometry-probe",
                "requested": rows.count, "completed": results.count, "probed": results.count - failures,
                "failures": failures, "pages": results], options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("probe-summary.json"), options: .atomic)
            print("First-pass geometry \(id): \(result["status"]!)")
        }
        return failures == 0 ? 0 : 1
    }

    @MainActor static func run(request:URL,root:URL) async throws -> Int32 {
        let spec=try JSONSerialization.jsonObject(with:Data(contentsOf:request)) as! [String:Any]
        let rows=spec["pages"] as! [[String:Any]], variants=spec["variants"] as! [[String:String]]
        try HostEnvironment.load(root:root)
        let confidence = (spec["confidence"] as? NSNumber)?.doubleValue ??
            Double(ProcessInfo.processInfo.environment["AIDOKU_OCR_CONFIDENCE"] ?? "0.5") ?? 0.5
        guard confidence.isFinite, (0...1).contains(confidence) else {
            throw HostError.message("Invalid replay recognition confidence")
        }
        try HostResources.prepare(root:root,tier:.manga)
        let client=TranslationService(client:RemoteTranslationClient(transport:RecordingTransport()),
            cache:try TranslationCache(configuration:.init(diskEnabled:false)))
        for (index,row) in rows.enumerated() {
            let input=try load(row), source=URL(fileURLWithPath:input.source), id=row["id"] as! String
            for variant in variants {
                let name=variant["name"]!,run=URL(fileURLWithPath:variant["run"]!)
                let directory=run.appendingPathComponent(String(format:"%04d",index+1))
                if name != "cache-prime", FileManager.default.fileExists(atPath:directory.appendingPathComponent("final.json").path) {
                    continue
                }
                if let paths=variant["paths"] { setenv("AIDOKU_OCR_ORIENTED_PATHS",paths,1) }
                else { unsetenv("AIDOKU_OCR_ORIENTED_PATHS") }
                let bootstrap=input.map == nil
                let options=try HostOptions(root:root,arguments:["--ocr-only","--tier","manga","--source","ja","--target","ko",
                    "--confidence",String(confidence),"--detector-side","1120","--recognizer-width","2400","--quiet","--compact-output",source.path])
                let rfContext=try (spec["rfCache"] as? String).map { path in
                    try HostRFLayoutReplay.Context(root:root,cache:URL(fileURLWithPath:path),sourceSHA256:input.sourceSHA256,
                        width:input.width,height:input.height)
                }
                let result=await $current.withValue(input) {
                    await HostRFLayoutReplay.$context.withValue(rfContext) {
                        await ImageTranslationMain.processImage(index:index,url:source,count:rows.count,run:run,root:root,options:options,client:client)
                    }
                }
                guard input.map != nil else { throw HostError.message("Bootstrap did not retain exact full map") }
                guard result.row["status"] as? String == "success" else { throw HostError.message("Replay failed: \(id) / \(name)") }
                var receipt:[String:Any] = ["id":id,"variant":name,"DB_model_calls":bootstrap ? 1 : 0,
                    "recognitionReuse":"production exact rectified-tensor SHA256 cache", "recognitionConfidence":confidence,
                    "sourceSHA256":row["sourceSHA256"]!,"RF_replay_enabled":rfContext != nil]
                if let rfContext {
                    let statistics = rfContext.statistics
                    guard (statistics["RF_model_calls"] as? Int ?? 0) + (statistics["RF_replay_hits"] as? Int ?? 0) > 0 else {
                        throw HostError.message("RF replay did not observe a complete detector result: \(id)")
                    }
                    receipt.merge(statistics,uniquingKeysWith: { _,new in new })
                }
                try JSONSerialization.data(withJSONObject:receipt)
                    .write(to:directory.appendingPathComponent("replay-receipt.json"),options:.atomic)
                let auditStages = ProcessInfo.processInfo.environment["AIDOKU_OCR_GROUPING_AUDIT"] == "1" ?
                    ["paragraph-grouping-input","paragraph-grouping-output","paragraph-grouping-scopes",
                     "initial-grouping","after-recovery","balloon-interiors","chromatic-grouping",
                     "recognition-context-input","recognition-context-controls",
                     "recognition-context-decoded","recognition-context-proposals","recognition-context-accepted","recognition-context-admission","point-tail-audit",
                     "recognition-glyph-contour-proposals","recognition-glyph-contour-decoded",
                     "recognition-glyph-contour-accepted","recognition-glyph-contour-admission"] : []
                try HostAnalysis.compactPage(directory,additionalStages:Set(["ocr-phases","detector-replay","rf-layout-replay","recognition-input","recognition-first-pass-input"]+auditStages))
                try deduplicateInput(directory,source:source,digest:input.sourceSHA256)
                print("Direction replay \(id) \(name) complete; DB predictions=\(bootstrap ? 1 : 0)")
            }
        }
        return 0
    }
}
