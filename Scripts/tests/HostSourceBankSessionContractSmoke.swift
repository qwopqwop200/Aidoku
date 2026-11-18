import Foundation

@available(macOS 15.0, *)
@main struct HostSourceBankSessionContractSmoke {
    static func main() throws {
        typealias C = HostSourceBankCapture
        let a = String(repeating: "a", count: 64), b = String(repeating: "b", count: 64)
        let compiled = ["/frozen-only/NativeSourceInputFactory.swift": a, "/frozen-only/NativePixelRFEvidence.swift": b]
        let producerHash = HostModuleBankBootstrap.producerDigest(compiled)
        let producer = HostModuleBankBootstrap.ProducerManifest(schema: "aidoku-module-bank-producer-v1",
            pipelineFingerprint: a, producerSHA256: producerHash, compiledSourceSHA256: compiled, stageSchemas: ["raw": "test"])
        func session(config: String? = a, rf: String? = b, sha: String? = producerHash) -> HostModuleBank.Contract {
            HostModuleBank.Contract(pageID: "0007", sourceEncodedSHA256: a, sourceImageIdentity: b,
                width: 10, height: 20, modelSHA256: rf.map { ["rf-detr": $0] } ?? [:], configurationSHA256: config,
                producerSHA256: sha, stageSchemas: ["raw": "test"], requiredStages: ["raw"], requiredModelRoles: ["rf-detr"])
        }
        let binding: [String: Any] = ["actualStubArtifact": ["resourceSHA256": b, "selectedPolicy": "stub-only"]]
        let validSession = session()
        func make(_ s: HostModuleBank.Contract = validSession, _ p: HostModuleBankBootstrap.ProducerManifest = producer,
                  ids: [String] = ["actual-right", "actual-left"], preprocess: String = a) throws -> C.Contract {
            try C.makeFrozenContract(session: s, producer: p, modelBinding: binding,
                actualRegionIDs: ids, preprocessSHA256: preprocess, decoderSHA256: b)
        }
        let result = try make()
        func packet(identity: String = b, encoded: String? = nil, width: Int = 10, height: Int = 20) -> NativeMainEnsembleOCREvidence.Packet {
            .init(binding: .init(contentIdentity: identity, width: width, height: height, verifiedEncodedSourceSHA256: encoded))
        }
        precondition(C.packetMatches(packet(), sourceIdentity: b, sourceEncodedSHA256: a, width: 10, height: 20))
        precondition(C.packetMatches(packet(encoded: a), sourceIdentity: b, sourceEncodedSHA256: a, width: 10, height: 20))
        precondition(!C.packetMatches(packet(encoded: b), sourceIdentity: b, sourceEncodedSHA256: a, width: 10, height: 20))
        precondition(!C.packetMatches(packet(identity: a), sourceIdentity: b, sourceEncodedSHA256: a, width: 10, height: 20))
        precondition(!C.packetMatches(packet(width: 11), sourceIdentity: b, sourceEncodedSHA256: a, width: 10, height: 20))
        precondition(result.input.sourceFactorySHA256 == a && result.input.pixelEvidenceSHA256 == b)
        precondition(result.input.installedRFModelSHA256 == b && result.input.configurationSHA256 == a)
        precondition(result.input.producerSHA256 == producerHash && result.compiledSourceSHA256 == compiled)
        let modelBindingData = try C.json(binding)
        precondition(result.input.modelSetSHA256 == HostRFRawReplay.digest(modelBindingData))
        precondition(result.maximumStageBytes == 256 * 1024 * 1024 && result.maximumDiagnosticBytes == 32 * 1024 * 1024)
        precondition(result.additionalConfiguration["actualReaderRegionIDsInOrder"] as? [String] == ["actual-right", "actual-left"])
        var rejected = 0
        for bad in [session(config: nil), session(rf: nil), session(sha: b)] {
            do { _ = try make(bad); fatalError("missing frozen field admitted") } catch { rejected += 1 }
        }
        for ids in [["same", "same"], [""]] {
            do { _ = try make(ids: ids); fatalError("ambiguous observed IDs admitted") } catch { rejected += 1 }
        }
        do { _ = try make(preprocess: "__unexpanded-placeholder__"); fatalError("placeholder admitted") } catch { rejected += 1 }
        let duplicate = HostModuleBankBootstrap.ProducerManifest(schema: producer.schema, pipelineFingerprint: a,
            producerSHA256: producerHash, compiledSourceSHA256: compiled.merging(["/another/NativeSourceInputFactory.swift": a]) { x, _ in x },
            stageSchemas: producer.stageSchemas)
        do { _ = try make(session(), duplicate); fatalError("ambiguous basename admitted") } catch { rejected += 1 }
        let missing = HostModuleBankBootstrap.ProducerManifest(schema: producer.schema, pipelineFingerprint: a,
            producerSHA256: producerHash, compiledSourceSHA256: ["/frozen-only/NativePixelRFEvidence.swift": b], stageSchemas: producer.stageSchemas)
        do { _ = try make(session(), missing); fatalError("missing compiled source admitted") } catch { rejected += 1 }
        print("{\"status\":\"PASS\",\"frozenContractChecks\":7,\"freshAndBoundPacketChecks\":5,\"missingOrAmbiguousRejected\":\(rejected),\"liveCheckoutReads\":0,\"modelLoads\":0,\"modelCalls\":0,\"APIRequests\":0,\"scope\":\"Focused stub session contract assembly only\"}")
    }
}
