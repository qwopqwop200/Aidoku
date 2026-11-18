import Foundation
import CoreGraphics
import ImageIO
import CryptoKit
import Darwin

/// Stage-local HTTP experiment. No OCR/RF/REC/AOT preparation or render entry
/// point exists here. A request-byte identity deliberately excludes renderer,
/// whole-pipeline producer and downstream post-classification policy versions.
@available(macOS 15.0, *)
enum HostSealedLLMStage {
    struct Source: Decodable {
        let pageID: String
        let split: String
        let sourcePath: String
        let sourceSHA256: String
        let snapshotDirectory: String?
        let snapshotSHA256: String?
        let failureReceiptPath: String?
        let failureReceiptSHA256: String?
        let capturedGroupedArtifactSHA256: String?
        let moduleContractPath: String?
        let moduleContractSHA256: String?
    }
    struct Input: Decodable {
        let mode: String
        let outputDirectory: String
        let cacheDirectory: String
        let configurationArguments: [String]
        let expectedModel: String
        let corpusManifestPath: String
        let corpusManifestSHA256: String
        let sources: [Source]?
        let sealsPath: String?
        let sealsSHA256: String?
        let reuseIndexPath: String?
        let reuseIndexSHA256: String?
        let maximumWorkers: Int?
        let confirmedNoOtherProviderJobs: Bool?
    }
    struct Binding: Codable, Sendable {
        let pageID: String
        let split: String
        let sourcePath: String
        let sourceSHA256: String
        let snapshotDirectory: String
        let snapshotSHA256: String
        let capturedOwnerStage: String?
        let canonicalToCallerID: [String: String]
    }
    struct Seal: Codable, Sendable {
        let schema: String
        let stageDigest: String
        let endpoint: String
        let apiProtocol: RemoteTranslationProtocol
        let model: String
        let wireBodyPath: String
        let wireBodySHA256: String
        let canonicalRequestPath: String
        let canonicalRequestSHA256: String
        let promptSHA256: String
        let samplingSHA256: String
        let suppliedImageSHA256: String?
        var bindings: [Binding]
    }
    struct Reuse: Decodable {
        let stageDigest: String
        let responsePath: String
        let responseSHA256: String
        let statusCode: Int
        let wireBodySHA256: String
        let endpoint: String
        let model: String
    }
    struct Receipt: Codable, Sendable {
        let schema: String
        let stageDigest: String
        let wireBodySHA256: String
        let endpoint: String
        let model: String
        let status: String
        let statusCode: Int?
        let responsePath: String?
        let responseSHA256: String?
        let responseBytes: Int
        let requestBytes: Int
        let elapsedMilliseconds: Double
        let providerCalls: Int
        let source: String
        let promptTokens: Int?
        let completionTokens: Int?
        let totalTokens: Int?
        let errorKind: String?
    }
    private struct Corpus: Decodable {
        struct Page: Decodable { let page_id: String; let image_sha256: String; let split: String }
        let pages: [Page]
    }

    static func sha(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    private static func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private static func write<T: Encodable>(_ value: T, _ path: URL) throws {
        try encode(value).write(to: path, options: .atomic)
    }
    private static func verified(_ path: String, _ expected: String) throws -> Data {
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        guard expected.count == 64, sha(bytes) == expected else { throw HostError.message("Sealed artifact checksum mismatch") }
        return bytes
    }
    private static func rawDigest(body: Data, endpoint: String, apiProtocol: RemoteTranslationProtocol, model: String) throws -> String {
        sha(try json(["schema": "actual-llm-http-request-v1", "endpoint": endpoint,
            "apiProtocol": apiProtocol.rawValue, "model": model, "wireBodySHA256": sha(body)]))
    }

    @MainActor static func run(root: URL, arguments: [String]) async -> Int32 {
        do {
            let args = arguments.first == "--sealed-llm-stage" ? Array(arguments.dropFirst()) : arguments
            guard args.count == 1 else { throw HostError.message("Expected sealed LLM stage manifest") }
            let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: URL(fileURLWithPath: args[0])))
            let corpus = try JSONDecoder().decode(Corpus.self,
                from: verified(input.corpusManifestPath, input.corpusManifestSHA256))
            guard corpus.pages.count == 685, Set(corpus.pages.map(\.page_id)).count == 685,
                  corpus.pages.allSatisfy({ ["train", "dev"].contains($0.split) }) else { throw HostError.message("TRAIN/DEV685 corpus required") }
            let authorized = Dictionary(uniqueKeysWithValues: corpus.pages.map { ($0.page_id, $0) })
            // Same loading order as normal CLI: dotenv before HostOptions reads
            // environment defaults. Secrets stay inside the credential store.
            try HostEnvironment.load(root: root)
            guard input.mode != "execute" || ProcessInfo.processInfo.environment["AIDOKU_FORBID_LLM_NETWORK"] != "1" else {
                // This private one-shot executor bypasses RecordingTransport.
                // Honor the same explicit model-execution prohibition before
                // credentials, claims, transport creation or HTTP are reached.
                throw HostError.message("LLM model execution is forbidden; use existing cache observations offline")
            }
            let options = try HostOptions(root: root, arguments: input.configurationArguments + ["--ocr-only"])
            guard !options.model.isEmpty, options.model == input.expectedModel else { throw HostError.message("Configured model differs from the frozen model") }
            let endpoint = try options.configuration.validatedEndpoint()
            let output = URL(fileURLWithPath: input.outputDirectory)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            switch input.mode {
            case "export":
                try export(input, options: options, endpoint: endpoint, output: output, authorized: authorized)
            case "execute":
                try await execute(input, options: options, endpoint: endpoint, output: output, authorized: authorized)
            default: throw HostError.message("Choose explicit export or execute mode")
            }
            return 0
        } catch {
            // Do not print NSError.userInfo, URLs with secret-bearing query
            // strings, request/response bodies or credential-store errors.
            fputs("Sealed LLM stage failed (details retained in stage receipts when available).\n", stderr)
            return 1
        }
    }

    @MainActor private static func export(_ input: Input, options: HostOptions, endpoint: URL, output: URL,
                                         authorized: [String: Corpus.Page]) throws {
        guard let sources = input.sources, Set(sources.map(\.pageID)).count == sources.count,
              sources.allSatisfy({ ["train", "dev"].contains($0.split) }) else { throw HostError.message("Unique TRAIN/DEV sources required") }
        guard sources.allSatisfy({ authorized[$0.pageID]?.image_sha256 == $0.sourceSHA256 &&
            authorized[$0.pageID]?.split == $0.split }) else { throw HostError.message("Source outside authorized corpus") }
        guard ProcessInfo.processInfo.environment["AIDOKU_VLLM_FRESH_PREFIX"] != "1" else {
            throw HostError.message("Fresh random prefix salt is incompatible with a reproducible sealed stage")
        }
        let artifacts = output.appendingPathComponent("requests", isDirectory: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        var seals: [String: Seal] = [:]
        var pageReports: [[String: Any]] = []
        for source in sources {
            try Task.checkCancellation()
            var report: [String: Any] = ["pageID": source.pageID, "split": source.split,
                "sourceSHA256": source.sourceSHA256, "providerCalls": 0]
            do {
                _ = try verified(source.sourcePath, source.sourceSHA256)
                if let path = source.failureReceiptPath, let checksum = source.failureReceiptSHA256 {
                    _ = try verified(path, checksum)
                    report["upstreamSourceFactoryFailureReceiptSHA256"] = checksum
                    if source.capturedGroupedArtifactSHA256 == nil {
                        report["status"] = "observed_failure_no_successful_owner_payload"
                        report["failureReceiptSHA256"] = checksum
                        report["notAnEmptyPrediction"] = true
                        pageReports.append(report); continue
                    }
                }
                guard let directoryPath = source.snapshotDirectory else {
                    throw HostError.message("Missing actual captured-owner snapshot")
                }
                let imageURL = URL(fileURLWithPath: source.sourcePath)
                guard let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { throw HostError.message("Source image decode failed") }
                let captured: [ReaderTranslationRegion]
                let capturedSHA: String
                let capturedStage: String
                if let groupedSHA = source.capturedGroupedArtifactSHA256 {
                    guard let contractPath = source.moduleContractPath, let contractSHA = source.moduleContractSHA256 else {
                        throw HostError.message("Captured grouped owners require their actual immutable module contract")
                    }
                    let expected = try JSONDecoder().decode(HostModuleBank.Contract.self,
                        from: verified(contractPath, contractSHA))
                    captured = try HostSavedOCRReplay.loadCapturedGroupedOwners(from: URL(fileURLWithPath: directoryPath),
                        expectedInput: imageURL, original: image, expected: expected, expectedGroupedArtifactSHA256: groupedSHA)
                    capturedSHA = groupedSHA; capturedStage = "actualGroupedRegions"
                } else {
                    guard let finalSHA = source.snapshotSHA256 else { throw HostError.message("Missing captured final receipt") }
                    captured = try HostSavedOCRReplay.loadCapturedOwners(from: URL(fileURLWithPath: directoryPath),
                        expectedInput: imageURL, imageSize: CGSize(width: image.width, height: image.height),
                        expectedEncodedSHA256: source.sourceSHA256, expectedFinalSHA256: finalSHA)
                    capturedSHA = finalSHA; capturedStage = "final.json"
                }
                report["capturedOwnerStage"] = capturedStage
                report["capturedOwnerArtifactSHA256"] = capturedSHA
                let settings = ReaderTranslationSettings(includePageImage: true, sourceLanguage: options.source,
                    targetLanguage: options.target, translationSourceLanguages: options.translationSourceLanguages,
                    filterSFXWithLLM: true, filterBackgroundWithLLM: true,
                    rightToLeftPanelOrder: options.rtl, modelTier: options.tier)
                let eligible = ReaderTranslationLanguageFilter.apply(captured, settings: settings)
                let plans = ReaderTranslationService.plans(regions: eligible, settings: settings)
                report["capturedOwners"] = captured.count
                report["eligibleOwners"] = eligible.count
                report["excludedOwnerIDs"] = captured.map(\.id).filter { id in !eligible.contains(where: { $0.id == id }) }
                report["observedEmpty"] = captured.isEmpty
                report["requestDigests"] = [String]()
                if !plans.isEmpty {
                    let jpeg = try HostTranslationParity.translationJPEG(image)
                    let imageIdentity = try NativeRFDETRSourceImage.decode(image).identity
                    var digests: [String] = []
                    for plan in plans {
                        var request = plan.request
                        request.imageJPEG = jpeg
                        request.roleEvidenceSourceImageIdentity = imageIdentity
                        request.filtersSFX = true; request.filtersBackground = true
                        request.translatesPageLettering = true
                        let canonical = request.canonicalizedForTranslationSemantics()
                        let body = try TranslationHTTPCodec.requestBody(configuration: options.configuration,
                            request: canonical.request, chatOptions: .standard)
                        let stageDigest = try rawDigest(body: body, endpoint: endpoint.absoluteString,
                            apiProtocol: options.apiProtocol, model: options.model)
                        let payload = try JSONSerialization.jsonObject(with: body) as! [String: Any]
                        let sampling = payload.filter { !["input", "messages", "instructions"].contains($0.key) }
                        let prompt: Any = payload["instructions"] ?? (payload["messages"] as? [[String: Any]])?.filter { $0["role"] as? String == "system" } ?? []
                        let map = Dictionary(uniqueKeysWithValues: zip(canonical.request.segments.map(\.id), request.segments.map(\.id)))
                        let binding = Binding(pageID: source.pageID, split: source.split, sourcePath: source.sourcePath,
                            sourceSHA256: source.sourceSHA256, snapshotDirectory: directoryPath, snapshotSHA256: capturedSHA,
                            capturedOwnerStage: capturedStage,
                            canonicalToCallerID: map)
                        if var seal = seals[stageDigest] {
                            seal.bindings.append(binding); seals[stageDigest] = seal
                        } else {
                            let bodyPath = artifacts.appendingPathComponent(stageDigest + ".httpbody")
                            let requestPath = artifacts.appendingPathComponent(stageDigest + ".request.json")
                            let requestData = try encode(canonical.request)
                            try body.write(to: bodyPath, options: .atomic)
                            try requestData.write(to: requestPath, options: .atomic)
                            seals[stageDigest] = Seal(schema: "actual-llm-http-request-v1", stageDigest: stageDigest,
                                endpoint: endpoint.absoluteString, apiProtocol: options.apiProtocol, model: options.model,
                                wireBodyPath: bodyPath.path, wireBodySHA256: sha(body), canonicalRequestPath: requestPath.path,
                                canonicalRequestSHA256: sha(requestData), promptSHA256: sha(try json(["prompt": prompt])),
                                samplingSHA256: sha(try json(sampling)), suppliedImageSHA256: sha(jpeg), bindings: [binding])
                        }
                        digests.append(stageDigest)
                    }
                    report["requestDigests"] = digests
                }
                report["status"] = "captured_cohort_request_contract_exported"
            } catch {
                report["status"] = "unavailable_or_unverified_request_contract"
                report["notAnEmptyPrediction"] = true
            }
            pageReports.append(report)
            try json(["schema": "sealed-LLM-export-progress-v1", "pages": pageReports,
                "sourcePageDenominator": sources.count, "uniqueRequests": seals.count, "providerCalls": 0,
                "additionalCoreInference": false]).write(to: output.appendingPathComponent("export-progress.json"), options: .atomic)
        }
        try write(seals.values.sorted { $0.stageDigest < $1.stageDigest }, output.appendingPathComponent("seals.json"))
        print("Sealed LLM export: \(sources.count) source records, \(seals.count) unique request contracts; provider calls 0")
    }

    private static func decodeResponse(_ bytes: Data, seal: Seal) throws -> [RemoteTranslatedSegment] {
        let request = try JSONDecoder().decode(RemoteTranslationRequest.self,
            from: verified(seal.canonicalRequestPath, seal.canonicalRequestSHA256))
        let sources = Dictionary(uniqueKeysWithValues: request.segments.map { ($0.id, $0.text) })
        return try TranslationHTTPCodec.responseTranslations(from: bytes, protocol: seal.apiProtocol,
            expectedSegmentIDs: request.segments.map(\.id), sfxSourceTexts: sources, backgroundSourceTexts: sources)
    }

    private static func receipt(seal: Seal, bytes: Data?, status: String, statusCode: Int?, path: String?,
                                elapsed: Double, calls: Int, source: String, errorKind: String? = nil) -> Receipt {
        let envelope = bytes.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let usage = envelope?["usage"] as? [String: Any]
        return Receipt(schema: "sealed-LLM-once-receipt-v1", stageDigest: seal.stageDigest,
            wireBodySHA256: seal.wireBodySHA256, endpoint: seal.endpoint, model: seal.model, status: status,
            statusCode: statusCode, responsePath: path, responseSHA256: bytes.map(sha), responseBytes: bytes?.count ?? 0,
            requestBytes: ((try? FileManager.default.attributesOfItem(atPath: seal.wireBodyPath)[.size]) as? NSNumber)?.intValue ?? 0,
            elapsedMilliseconds: elapsed, providerCalls: calls, source: source,
            promptTokens: (usage?["input_tokens"] ?? usage?["prompt_tokens"]) as? Int,
            completionTokens: (usage?["output_tokens"] ?? usage?["completion_tokens"]) as? Int,
            totalTokens: usage?["total_tokens"] as? Int, errorKind: errorKind)
    }

    private static func one(_ seal: Seal, reuse: Reuse?, configuration: RemoteTranslationConfiguration, key: String, cache: URL,
                            transport: BoundedURLSessionTransport) async -> Receipt {
        let started = ProcessInfo.processInfo.systemUptime
        let responsePath = cache.appendingPathComponent(seal.stageDigest + ".response.json")
        let receiptPath = cache.appendingPathComponent(seal.stageDigest + ".receipt.json")
        var networkStarted = false
        do {
            let body = try verified(seal.wireBodyPath, seal.wireBodySHA256)
            guard seal.model == configuration.model, seal.endpoint == (try configuration.validatedEndpoint().absoluteString),
                  seal.apiProtocol == configuration.apiProtocol,
                  seal.stageDigest == (try rawDigest(body: body, endpoint: seal.endpoint, apiProtocol: seal.apiProtocol, model: seal.model)) else {
                throw HostError.message("Sealed request/configuration mismatch")
            }
            if let cached = try? JSONDecoder().decode(Receipt.self, from: Data(contentsOf: receiptPath)),
               cached.status == "complete", cached.stageDigest == seal.stageDigest,
               cached.wireBodySHA256 == seal.wireBodySHA256, cached.endpoint == seal.endpoint, cached.model == seal.model,
               let path = cached.responsePath, let checksum = cached.responseSHA256,
               let bytes = try? verified(path, checksum), (try? decodeResponse(bytes, seal: seal)) != nil {
                return receipt(seal: seal, bytes: bytes, status: "complete", statusCode: cached.statusCode, path: path,
                    elapsed: 0, calls: 0, source: "verified-stage-cache")
            }
            if let reuse, reuse.stageDigest == seal.stageDigest, reuse.wireBodySHA256 == seal.wireBodySHA256,
               reuse.endpoint == seal.endpoint, reuse.model == seal.model, (200...299).contains(reuse.statusCode) {
                let bytes = try verified(reuse.responsePath, reuse.responseSHA256)
                _ = try decodeResponse(bytes, seal: seal)
                try bytes.write(to: responsePath, options: .atomic)
                let result = receipt(seal: seal, bytes: bytes, status: "complete", statusCode: reuse.statusCode,
                    path: responsePath.path, elapsed: 0, calls: 0, source: "exact-historical-wire-cache")
                try write(result, receiptPath); return result
            }
            // Permanent O_EXCL claim BEFORE HTTP. A timeout/crash remains an
            // uncertain attempted request, never an automatic resubmission.
            let claim = cache.appendingPathComponent(seal.stageDigest + ".claimed")
            let fd = Darwin.open(claim.path, O_CREAT | O_EXCL | O_WRONLY, S_IRUSR | S_IWUSR)
            guard fd >= 0 else {
                return receipt(seal: seal, bytes: nil, status: "already_claimed_no_retry", statusCode: nil,
                    path: nil, elapsed: 0, calls: 0, source: "once-claim")
            }
            Darwin.close(fd)
            let pending = receipt(seal: seal, bytes: nil, status: "pending", statusCode: nil,
                path: nil, elapsed: 0, calls: 0, source: "claimed-before-network")
            try write(pending, receiptPath)
            var request = URLRequest(url: URL(string: seal.endpoint)!, cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: configuration.timeout)
            request.httpMethod = "POST"; request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            request.setValue("Aidoku-iOS/1", forHTTPHeaderField: "User-Agent")
            networkStarted = true
            let response = try await transport.data(for: request, maximumResponseBytes: configuration.maximumResponseBytes,
                bypassesProxy: URL(string: seal.endpoint)?.scheme == "http")
            try response.data.write(to: responsePath, options: .atomic)
            guard (200...299).contains(response.response.statusCode) else {
                let result = receipt(seal: seal, bytes: response.data, status: "http_failure_no_retry",
                    statusCode: response.response.statusCode, path: responsePath.path,
                    elapsed: (ProcessInfo.processInfo.systemUptime-started)*1000, calls: 1, source: "network")
                try write(result, receiptPath); return result
            }
            _ = try decodeResponse(response.data, seal: seal)
            let result = receipt(seal: seal, bytes: response.data, status: "complete", statusCode: response.response.statusCode,
                path: responsePath.path, elapsed: (ProcessInfo.processInfo.systemUptime-started)*1000, calls: 1, source: "network")
            try write(result, receiptPath); return result
        } catch {
            let result = receipt(seal: seal, bytes: nil, status: networkStarted ? "uncertain_or_parse_failure_no_retry" : "preflight_failure_no_retry",
                statusCode: nil, path: nil, elapsed: (ProcessInfo.processInfo.systemUptime-started)*1000,
                calls: networkStarted ? 1 : 0, source: networkStarted ? "network" : "preflight",
                errorKind: networkStarted ? "transport-or-response-validation" : "identity-artifact-or-credential")
            if networkStarted { try? write(result, receiptPath) }
            return result
        }
    }

    @MainActor private static func execute(_ input: Input, options: HostOptions, endpoint: URL, output: URL,
                                          authorized: [String: Corpus.Page]) async throws {
        guard input.confirmedNoOtherProviderJobs == true, let count = input.maximumWorkers, (1...4).contains(count),
              let path = input.sealsPath, let checksum = input.sealsSHA256 else { throw HostError.message("Explicit bounded execution authorization required") }
        let seals = try JSONDecoder().decode([Seal].self, from: verified(path, checksum))
        guard Set(seals.map(\.stageDigest)).count == seals.count,
              seals.allSatisfy({ $0.model == options.model && $0.endpoint == endpoint.absoluteString &&
                  $0.bindings.allSatisfy { authorized[$0.pageID]?.image_sha256 == $0.sourceSHA256 &&
                    authorized[$0.pageID]?.split == $0.split } }) else { throw HostError.message("Invalid or duplicate executable request plan") }
        var reuse: [String: Reuse] = [:]
        if let index = input.reuseIndexPath, let hash = input.reuseIndexSHA256 {
            let rows = try JSONDecoder().decode([Reuse].self, from: verified(index, hash))
            for row in rows { if reuse[row.stageDigest] == nil { reuse[row.stageDigest] = row } }
        }
        let cache = URL(fileURLWithPath: input.cacheDirectory)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        // Verify all request artifacts and credentials before any permanent
        // claim/network attempt. Unknown config must not poison once claims.
        let configuration = options.configuration
        let key = try KeychainTranslationCredentialStore().secret(for: options.keyEnv)
        guard !key.isEmpty, key.utf8.count <= KeychainTranslationCredentialStore.maximumSecretBytes,
              !key.contains("\r"), !key.contains("\n"), !key.contains("\0") else { throw HostError.message("Credential unavailable") }
        for seal in seals {
            let body = try verified(seal.wireBodyPath, seal.wireBodySHA256)
            _ = try verified(seal.canonicalRequestPath, seal.canonicalRequestSHA256)
            guard seal.stageDigest == (try rawDigest(body: body, endpoint: seal.endpoint, apiProtocol: seal.apiProtocol, model: seal.model)) else {
                throw HostError.message("Frozen request digest changed")
            }
        }
        let transport = BoundedURLSessionTransport()
        var receipts: [Receipt] = []
        let frozenReuse = reuse
        await withTaskGroup(of: Receipt.self) { group in
            var next = 0
            func add(_ index: Int) {
                let seal = seals[index]
                group.addTask { await one(seal, reuse: frozenReuse[seal.stageDigest], configuration: configuration, key: key, cache: cache, transport: transport) }
            }
            for _ in 0..<min(count, seals.count) { add(next); next += 1 }
            while let result = await group.next() {
                receipts.append(result)
                try? write(receipts.sorted { $0.stageDigest < $1.stageDigest }, output.appendingPathComponent("execution-receipts.json"))
                if next < seals.count { add(next); next += 1 }
            }
        }
        let summary: [String: Any] = ["schema": "sealed-LLM-stage-execution-v1", "uniqueRequestCount": seals.count,
            "maximumConcurrentRequests": count, "providerCalls": receipts.reduce(0) { $0 + $1.providerCalls },
            "complete": receipts.filter { $0.status == "complete" }.count,
            "unresolvedNoAutomaticRetry": receipts.filter { $0.status != "complete" }.count,
            "responseBytes": receipts.reduce(0) { $0 + $1.responseBytes },
            "networkRequestBytes": receipts.filter { $0.providerCalls > 0 }.reduce(0) { $0 + $1.requestBytes },
            "networkResponseBytes": receipts.filter { $0.providerCalls > 0 }.reduce(0) { $0 + $1.responseBytes },
            "measuredTotalTokens": receipts.compactMap(\.totalTokens).reduce(0, +),
            "newNetworkTokens": receipts.filter { $0.providerCalls > 0 }.compactMap(\.totalTokens).reduce(0, +),
            "USDMeasured": false, "additionalCoreInference": false, "renderInvoked": false,
            "modelChanged": false, "TESTRequests": 0]
        try json(summary).write(to: output.appendingPathComponent("execution-summary.json"), options: .atomic)
        print("Sealed LLM stage: \(receipts.count) receipts; network calls \(receipts.reduce(0) { $0 + $1.providerCalls })")
    }
}
