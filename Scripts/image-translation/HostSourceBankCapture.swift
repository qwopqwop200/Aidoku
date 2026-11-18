import CoreFoundation
import CoreGraphics
import Foundation

/// Explicit host source-only transaction. Caller supplies FROZEN compilation,
/// model and configuration identities. This facade never hashes live sources,
/// looks up GT, acquires a model, requests translation or renders a page.
@available(macOS 15.0, *)
enum HostSourceBankCapture {
    enum Failure: Error { case invalid(String) }
    struct Contract {
        let input: HostSourceInputBank.Contract
        let compiledSourceFingerprint: String
        let compiledSourceSHA256: [String: String]
        let modelBinding: [String: Any]
        let rfClassCoordinateFeatureSchema: [String: Any]
        let additionalConfiguration: [String: Any]
        let maximumStageBytes: Int
        let maximumDiagnosticBytes: Int
    }
    struct Result {
        let manifest: URL
        let observedOwners: Int
        let observedEmpty: Bool
    }
    struct RawResolution {
        let record: URL
        let reference: HostSourceInputBank.RawReference
        let consumer: [String: Any]
        let consumerKeySHA256: String
        let typedNumericSHA256: String
        let inputSHA256: String
    }
    private final class State {
        var page: HostSourceInputBank.Page?
        var bank: HostSourceSegmentationBank?
        var references: [String: Any] = [:]
        var ownerDescriptors: [String: [String: Any]] = [:]
        var diagnostics: [[String: Any]] = []
        var diagnosticBytes = 0
        var observedStages = 0
    }

    /// Fresh in-memory OCR may not yet carry an encoded-file attestation. Its
    /// exact decoded RGB identity and dimensions remain mandatory; a nonnil
    /// encoded identity must agree, never silently replaced with this page.
    static func packetMatches(_ packet: NativeMainEnsembleOCREvidence.Packet,
                              sourceIdentity: String, sourceEncodedSHA256: String,
                              width: Int, height: Int) -> Bool {
        packet.binding.contentIdentity == sourceIdentity && packet.binding.width == width && packet.binding.height == height &&
            (packet.binding.verifiedEncodedSourceSHA256.map { $0 == sourceEncodedSHA256 } ?? true)
    }

    /// Pure frozen-contract assembly seam. Filenames are resolved ONLY within
    /// the runner-attested compilation map, never against today's checkout.
    static func makeFrozenContract(session: HostModuleBank.Contract,
                                   producer: HostModuleBankBootstrap.ProducerManifest,
                                   modelBinding: [String: Any], actualRegionIDs: [String],
                                   preprocessSHA256: String, decoderSHA256: String) throws -> Contract {
        let compiled = try HostModuleBankBootstrap.compiledSourceBasenames(producer)
        guard producer.schema == "aidoku-module-bank-producer-v1",
              producer.producerSHA256 == HostModuleBankBootstrap.producerDigest(producer.compiledSourceSHA256),
              session.identityComplete,
              let config = session.configurationSHA256, hex(config),
              let producerSHA = session.producerSHA256, producerSHA == producer.producerSHA256,
              hex(producerSHA), hex(producer.pipelineFingerprint),
              let factorySHA = compiled["NativeSourceInputFactory.swift"], hex(factorySHA),
              let evidenceSHA = compiled["NativePixelRFEvidence.swift"], hex(evidenceSHA),
              let installedRF = session.modelSHA256["rf-detr"], hex(installedRF),
              hex(preprocessSHA256), hex(decoderSHA256), !modelBinding.isEmpty,
              Set(actualRegionIDs).count == actualRegionIDs.count,
              actualRegionIDs.allSatisfy({ !$0.isEmpty }) else { throw Failure.invalid("missing frozen source-bank contract field") }
        let modelSetSHA = HostRFRawReplay.digest(try json(modelBinding))
        let input = HostSourceInputBank.Contract(producerSHA256: producerSHA,
            sourceFactorySHA256: factorySHA, pixelEvidenceSHA256: evidenceSHA,
            decoderSHA256: decoderSHA256, preprocessSHA256: preprocessSHA256,
            installedRFModelSHA256: installedRF, configurationSHA256: config,
            modelSetSHA256: modelSetSHA, rfWeightsSHA256: NativeRFDETRLayoutResource.highresSourceWeightsSHA256,
            rfSourceRevision: NativeRFDETRLayoutResource.highresSourceRevision, rfFeatureSchema: HostSourceInputBank.rfSchema)
        let rfSchema: [String: Any] = [
            "nativeClassOrder": ["text", "soundEffect", "balloon", "frame", "unmappedClass4"],
            "nativeToCanonicalClassIDs": [1, 3, 2, 0],
            "canonicalTaxonomy": ["frame", "text", "balloon", "soundEffect"],
            "coordinateSystem": "upright original source pixels; top-left; crop-local polygons and bbox; global RF seed vertices",
            "source27": "class0..4 triples(max weighted-mask,linear-query weighted-mean,box-confidence); owner mask/affinity pairs15..24; margin25; uncertainty26",
            "source27Quantization": "Float16 promoted to Float32 after source bilinear interpolation",
            "coarse4": "accepted primitives in native order; nearest162 positive logit; confidence roundEven(UInt8)/255",
            "ownerAffinity5": "unquantized Float32; actual polygon raster seeds; class score times mean sigmoid mask",
            "native17Schema": NativeRFDETRSourceSupportGrid.schema,
            "native17Distinction": "native17 pairwise class denominator is not source27 linear-query denominator",
            "sourceFeatureSchema": HostSourceInputBank.rfSchema]
        return Contract(input: input, compiledSourceFingerprint: producer.pipelineFingerprint,
            compiledSourceSHA256: producer.compiledSourceSHA256, modelBinding: modelBinding,
            rfClassCoordinateFeatureSchema: rfSchema,
            additionalConfiguration: ["scope": "all-actual-observed-grouped-owners-preLLM",
                "moduleBankConfigurationSHA256": config, "moduleBankProducerSHA256": producerSHA,
                "actualReaderRegionIDsInOrder": actualRegionIDs, "moduleStageSchemas": session.stageSchemas,
                "sourcePacket": "actual current typed OCR packet; no enrichment; no GT; no provider; no AOT; no render"],
            maximumStageBytes: 256 * 1024 * 1024, maximumDiagnosticBytes: 32 * 1024 * 1024)
    }

    /// The root OCR-only route needs just this call. Session already attests the
    /// actual original/source and compiled models; modelBinding comes from the
    /// SAME operational backend registry used by the subsequent source pass.
    static func captureForSession(root: URL, originalURL: URL, source: CGImage,
                                  regions: [ReaderTranslationRegion], packet: NativeMainEnsembleOCREvidence.Packet,
                                  pageDirectory: URL, session: HostModuleBank.Session) throws -> Result {
        let producer = try HostModuleBankBootstrap.producerManifest(environment: ProcessInfo.processInfo.environment)
        let actualEncodedSHA = HostRFRawReplay.digest(try Data(contentsOf: originalURL))
        guard actualEncodedSHA == session.contract.sourceEncodedSHA256,
              packetMatches(packet, sourceIdentity: session.contract.sourceImageIdentity,
                sourceEncodedSHA256: actualEncodedSHA, width: session.contract.width, height: session.contract.height),
              source.width == session.contract.width, source.height == session.contract.height,
              let pageOrder = Int(session.contract.pageID), pageOrder >= 0 else {
            throw Failure.invalid("session/source packet or declared artifact page order")
        }
        let contract = try makeFrozenContract(session: session.contract, producer: producer,
            modelBinding: HostOperationalAppearance.observedSourceModelBinding(root: root),
            actualRegionIDs: regions.map(\.id), preprocessSHA256: HostRFRawReplay.preprocessCodeSHA,
            decoderSHA256: HostRFRawReplay.decoderCodeSHA)
        return try capture(root: root, originalURL: originalURL, source: source, regions: regions, packet: packet,
            pageDirectory: pageDirectory, pageCohort: "all-actual-observed-grouped-owners-preLLM",
            pageOrder: pageOrder, contract: contract)
    }

    static func hex(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    static func typedData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    /// Verify the actual source-consumer receipt, not a nearby source, first
    /// record, encoded-file alias or normal160/retainfalse decoder observation.
    /// Environment supplies archive location ONLY; all identity comes from the
    /// same-request RF ledger and the frozen contract passed by the caller.
    static func resolveRaw(source: NativeRFDETRSourceImage, contract: Contract,
                           diagnostics: [String: Any], archive: URL) throws -> RawResolution {
        guard diagnostics["schema"] as? String == "host-rf-raw-archive-v2",
              let records = diagnostics["rawRecords"] as? [[String: Any]] else { throw Failure.invalid("missing actual RF ledger") }
        var matches: [RawResolution] = []
        for row in records where row["sourceIdentity"] as? String == source.identity {
            guard let id = row["rawIdentitySHA256"] as? String, hex(id),
                  let payload = row["rawPayloadSHA256"] as? String, hex(payload),
                  let consumers = row["consumers"] as? [[String: Any]] else { throw Failure.invalid("RF ledger identity") }
            let record = archive.appendingPathComponent(id + ".record.json")
            let metadata = try Data(contentsOf: record)
            let header = try JSONDecoder().decode(HostRFRawReplay.Header.self, from: metadata)
            let reference = try HostSourceInputBank.rawReference(record)
            guard reference.identitySHA256 == id, reference.payloadSHA256 == payload,
                  header.identity.schema == "rf-actual-f32-all300-le-v2",
                  header.identity.base.tensorContractVersion == "rf648-input-f32-1x3x648x648-output300x4-300x5-300x162x162-v1",
                  header.identity.base.sourceRGBIdentity == source.identity,
                  header.identity.width == source.width, header.identity.height == source.height,
                  header.identity.base.expectedWeightsSHA256 == contract.input.rfWeightsSHA256,
                  header.identity.base.sourceRevision == contract.input.rfSourceRevision,
                  header.identity.base.installedModelTreeSHA256 == contract.input.installedRFModelSHA256,
                  header.identity.preprocessCodeSHA256 == contract.input.preprocessSHA256,
                  hex(header.identity.inputSHA256) else { throw Failure.invalid("actual raw model/source/input binding") }
            for receipt in consumers {
                guard let consumer = receipt["consumer"] as? [String: Any],
                      consumer["rawIdentitySHA256"] as? String == id,
                      consumer["maximumMaskQueries"] as? Int == 160,
                      consumer["retainAllQueryMasks"] as? Bool == true else { continue }
                guard consumer["decoderCodeSHA256"] as? String == contract.input.decoderSHA256,
                      consumer["native17Schema"] as? String == NativeRFDETRSourceSupportGrid.schema,
                      consumer["hostBuildFingerprint"] as? String == contract.compiledSourceFingerprint,
                      let consumerHash = receipt["consumerKeySHA256"] as? String,
                      consumerHash == HostRFRawReplay.digest(try JSONSerialization.data(withJSONObject: consumer, options: .sortedKeys)),
                      let numeric = receipt["typedNumericSHA256"] as? String, hex(numeric) else {
                    throw Failure.invalid("selected RF consumer binding")
                }
                // Duplicate identical ledger observations do not create an
                // ambiguity. Distinct raw or decoder observations do.
                if !matches.contains(where: { $0.reference.identitySHA256 == id && $0.consumerKeySHA256 == consumerHash && $0.typedNumericSHA256 == numeric }) {
                    matches.append(.init(record: record, reference: reference, consumer: consumer,
                        consumerKeySHA256: consumerHash, typedNumericSHA256: numeric, inputSHA256: header.identity.inputSHA256))
                }
            }
        }
        guard matches.count == 1, let selected = matches.first else { throw Failure.invalid("missing/ambiguous source RF consumer") }
        let tensor = try NativeRFDETRLayoutTensorContract.preprocess(source)
        guard tensor.dataType == .float32, tensor.shape.map(\.intValue) == [1, 3, 648, 648],
              tensor.strides.map(\.intValue) == [1_259_712, 419_904, 648, 1],
              HostRFRawReplay.digest(UnsafeRawBufferPointer(start: tensor.dataPointer, count: 5_038_848)) == selected.inputSHA256 else {
            throw Failure.invalid("actual raw input tensor differs")
        }
        let payload = try Data(contentsOf: archive.appendingPathComponent(selected.reference.payloadSHA256 + ".f32le"))
        let header = try JSONDecoder().decode(HostRFRawReplay.Header.self, from: Data(contentsOf: selected.record))
        guard payload.count == HostRFRawReplay.payloadBytes, HostRFRawReplay.digest(payload) == selected.reference.payloadSHA256,
              HostRFRawReplay.tensorHashes(payload) == header.tensorSHA256 else { throw Failure.invalid("raw payload changed") }
        return selected
    }

    /// Small diagnostics retain IEEE bits before JSON's decimal conversion.
    /// Dense source pixels/RF do not enter this path; unsupported objects fail.
    static func exactJSON(_ value: Any, depth: Int = 0) throws -> Any {
        guard depth < 64 else { throw Failure.invalid("diagnostic nesting") }
        if let v = value as? String { return v }
        if value is NSNull { return NSNull() }
        if type(of: value) == Double.self, let v = value as? Double { return ["$f64": HostSourceInputBank.bits(v)] }
        if type(of: value) == Float.self, let v = value as? Float { return ["$f32": HostSourceInputBank.bits(v)] }
        if type(of: value) == CGFloat.self, let v = value as? CGFloat { return ["$f64": HostSourceInputBank.bits(Double(v))] }
        if let v = value as? NSNumber {
            if CFGetTypeID(v) == CFBooleanGetTypeID() { return v.boolValue }
            switch String(cString: v.objCType) {
            case "f": return ["$f32": HostSourceInputBank.bits(v.floatValue)]
            case "d": return ["$f64": HostSourceInputBank.bits(v.doubleValue)]
            default: return ["$integer": v.stringValue]
            }
        }
        if let rows = value as? [Any] { return try rows.map { try exactJSON($0, depth: depth + 1) } }
        if let row = value as? [String: Any] { return try row.mapValues { try exactJSON($0, depth: depth + 1) } }
        throw Failure.invalid("unsupported or dense diagnostic value: \(type(of: value))")
    }

    /// The final link is atomic and never overwrites a previously sealed page.
    /// Partial transactions remain explicit and are not accepted as complete.
    static func publishManifest(_ value: [String: Any], transaction: URL, final: URL) throws {
        let staging = transaction.appendingPathComponent("seal-" + UUID().uuidString + ".json")
        try json(value).write(to: staging, options: .withoutOverwriting)
        try FileManager.default.linkItem(at: staging, to: final)
    }

    static func capture(root: URL, originalURL: URL, source: CGImage,
                        regions: [ReaderTranslationRegion], packet: NativeMainEnsembleOCREvidence.Packet,
                        pageDirectory: URL, pageCohort: String, pageOrder: Int,
                        contract: Contract) throws -> Result {
        let requiredHashes = [contract.input.producerSHA256, contract.input.sourceFactorySHA256,
            contract.input.pixelEvidenceSHA256, contract.input.decoderSHA256, contract.input.preprocessSHA256,
            contract.input.installedRFModelSHA256, contract.input.configurationSHA256, contract.input.modelSetSHA256]
        guard hex(contract.compiledSourceFingerprint), requiredHashes.allSatisfy(hex),
              contract.input.rfWeightsSHA256 == NativeRFDETRLayoutResource.highresSourceWeightsSHA256,
              contract.input.rfSourceRevision == NativeRFDETRLayoutResource.highresSourceRevision,
              contract.input.rfFeatureSchema == HostSourceInputBank.rfSchema,
              !contract.compiledSourceSHA256.isEmpty, contract.compiledSourceSHA256.values.allSatisfy(hex),
              contract.maximumStageBytes > 0, contract.maximumDiagnosticBytes > 0 else { throw Failure.invalid("frozen contract") }
        let binding = try HostEnsembleEvidence.sourceStageBinding(original: source, sourceURL: originalURL, fallbackURL: nil)
        guard let sourceSHA = binding.verifiedEncodedSourceSHA256,
              packetMatches(packet, sourceIdentity: binding.contentIdentity, sourceEncodedSHA256: sourceSHA,
                width: source.width, height: source.height) else { throw Failure.invalid("actual current OCR/source packet") }
        let final = pageDirectory.appendingPathComponent("source-bank.json")
        guard !FileManager.default.fileExists(atPath: final.path) else { throw Failure.invalid("already sealed source bank") }
        let transaction = pageDirectory.appendingPathComponent("source-bank-transactions/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: true)
        let state = State()
        let inputPath = transaction.appendingPathComponent("source-input-bank.json")
        let stagesPath = transaction.appendingPathComponent("selected-stages")
        let inputContract = try JSONSerialization.jsonObject(with: typedData(contract.input))
        let cohort: [[String: Any]] = regions.enumerated().map { index, region in
            ["actualItemIndex": index, "ownerID": region.id, "emptySource": region.source.isEmpty,
             "sourceTextSHA256": HostRFRawReplay.digest(Data(region.source.utf8)),
             "sourceBoundsBits": HostSourceInputBank.rectBits(region.rect),
             "sourcePolygonBits": HostSourceInputBank.polygonBits(region.polygon)]
        }
        var base: [String: Any] = ["schema": "authentic-source-bank-capture-v1", "sourceEncodedSHA256": sourceSHA,
            "originalPath": originalURL.path, "sourceContentIdentity": binding.contentIdentity,
            "sourceRGBIdentity": binding.contentIdentity,
            "sourceSize": [source.width, source.height], "pageCohort": pageCohort, "pageOrder": pageOrder,
            "inputContract": inputContract, "compiledSourceFingerprint": contract.compiledSourceFingerprint,
            "compiledSourceSHA256": contract.compiledSourceSHA256, "modelBinding": try exactJSON(contract.modelBinding),
            "actualObservedCohort": cohort, "actualObservedGroupedOwners": regions.count,
            "sourceOnly": true, "GTAtInference": false, "providerInvoked": false, "AOTInvoked": false,
            "renderInvoked": false, "additionalCoreInference": false, "denseFeatureBankStored": false]
        do {
            if regions.allSatisfy({ $0.source.isEmpty }) {
                base["complete"] = true; base["status"] = "observed-empty-source-owner-cohort"
                base["expectedOwnerCount"] = 0; base["observedOwnerCount"] = 0
                base["rawRF"] = ["status": "not-required-for-observed-empty-constructor"]
                try publishManifest(base, transaction: transaction, final: final)
                return Result(manifest: final, observedOwners: 0, observedEmpty: true)
            }
            _ = try HostOperationalAppearance.collectObservedSourceBank(root: root, source: source, regions: regions, packet: packet,
                segmentationObserver: { input, stage in
                    guard let bank = state.bank else { throw Failure.invalid("stage before actual constructor") }
                    try bank.observer(input, stage)
                    state.observedStages += 1
                }, diagnostics: { index, stage, payload in
                    let data = try json(["sourceIndex": index, "stage": stage, "payload": try exactJSON(payload),
                                         "encoding": "tagged-ieee754-hex-small-vectors-v1"])
                    guard state.diagnosticBytes <= contract.maximumDiagnosticBytes - data.count else { throw Failure.invalid("diagnostic budget") }
                    let name = "diagnostic-\(state.diagnostics.count).json"
                    try data.write(to: transaction.appendingPathComponent(name), options: .withoutOverwriting)
                    state.diagnosticBytes += data.count
                    state.diagnostics.append(["path": transaction.appendingPathComponent(name).path,
                                              "SHA256": HostRFRawReplay.digest(data), "bytes": data.count,
                                              "sourceIndex": index, "stage": stage])
                }, constructorObserver: { [state] owners, decoded in
                    guard state.page == nil, state.bank == nil,
                          let archivePath = ProcessInfo.processInfo.environment["AIDOKU_HOST_RF_RAW_ARCHIVE"], archivePath.hasPrefix("/") else {
                        throw Failure.invalid("missing constructor/raw archive configuration")
                    }
                    let resolved = try resolveRaw(source: decoded, contract: contract,
                        diagnostics: HostRFRawReplay.diagnostics(sourceIdentity: decoded.identity), archive: URL(fileURLWithPath: archivePath))
                    let page = try HostSourceInputBank.makePage(source: decoded, original: originalURL, rawRecord: resolved.record,
                        owners: owners, contract: contract.input, pageCohort: pageCohort, pageOrder: pageOrder, completeInventory: true)
                    try HostSourceInputBank.publish(page, to: inputPath)
                    let inputHash = HostRFRawReplay.digest(try Data(contentsOf: inputPath))
                    state.references = ["sourceInputBank": ["path": inputPath.path, "SHA256": inputHash],
                        "rawRF": ["recordPath": resolved.reference.recordPath, "recordSHA256": resolved.reference.recordSHA256,
                            "identitySHA256": resolved.reference.identitySHA256, "payloadSHA256": resolved.reference.payloadSHA256],
                        "sourceRGBIdentity": decoded.identity, "sourceEncodedSHA256": sourceSHA,
                        "rawSelectedConsumer": resolved.consumer, "rawSelectedConsumerKeySHA256": resolved.consumerKeySHA256,
                        "rawSelectedConsumerTypedNumericSHA256": resolved.typedNumericSHA256, "rawInputSHA256": resolved.inputSHA256]
                    var planned: [HostSourceSegmentationBank.Owner] = []
                    for (order, owner) in owners.enumerated() {
                        guard regions.indices.contains(owner.itemIndex), !regions[owner.itemIndex].source.isEmpty else { throw Failure.invalid("actual constructor item mapping") }
                        let id = regions[owner.itemIndex].id
                        guard state.ownerDescriptors[id] == nil else { throw Failure.invalid("duplicate actual owner ID") }
                        state.ownerDescriptors[id] = ["ownerID": id, "sourceInputBankOwnerIndex": order,
                            "sourceInputBankSHA256": inputHash, "actualItemIndex": owner.itemIndex,
                            "ownerDescriptorSHA256": HostRFRawReplay.digest(try typedData(page.owners[order]))]
                        planned.append(.init(id: id, input: owner.input))
                    }
                    let bank = try HostSourceSegmentationBank(directory: stagesPath, contract: .init(sourceIdentity: decoded.identity,
                        sourceEncodedSHA256: sourceSHA, compiledSourceFingerprint: contract.compiledSourceFingerprint,
                        compiledProducerSHA256: contract.input.producerSHA256, compiledSourceSHA256: contract.compiledSourceSHA256,
                        modelBinding: contract.modelBinding, rfClassCoordinateFeatureSchema: contract.rfClassCoordinateFeatureSchema,
                        additionalConfiguration: contract.additionalConfiguration, maximumPageBytes: contract.maximumStageBytes),
                        references: { [weak state] in
                            guard let state else { throw Failure.invalid("capture lifetime ended") }
                            return state.references
                        }, inputDescriptor: { [weak state] id, _, _, hashes in
                            guard let state else { throw Failure.invalid("capture lifetime ended") }
                            guard var descriptor = state.ownerDescriptors[id] else { throw Failure.invalid("unknown live owner") }
                            descriptor["hashes"] = hashes
                            return descriptor
                        })
                    try bank.prepare(planned)
                    state.page = page; state.bank = bank
                })
            guard let page = state.page, let bank = state.bank else { throw Failure.invalid("constructor not observed") }
            let stageIndex = try bank.finish()
            let stageIndexPath = stagesPath.appendingPathComponent("page-manifest.json")
            base["sourceRGBIdentity"] = page.sourceRGBIdentity; base["reconstructionReferences"] = state.references
            base["selectedStages"] = ["path": stageIndexPath.path, "SHA256": HostRFRawReplay.digest(try Data(contentsOf: stageIndexPath)),
                                      "expectedOwners": stageIndex["expectedOwnerCount"] ?? NSNull()]
            base["smallVectorArtifacts"] = state.diagnostics; base["smallVectorBytes"] = state.diagnosticBytes
            base["expectedOwnerCount"] = page.owners.count; base["observedOwnerCount"] = state.observedStages
            base["complete"] = true; base["status"] = "complete-actual-source-owner-cohort"
            try publishManifest(base, transaction: transaction, final: final)
            return Result(manifest: final, observedOwners: page.owners.count, observedEmpty: page.owners.isEmpty)
        } catch {
            base["complete"] = false; base["status"] = "incomplete-source-bank"
            base["error"] = String(describing: error); base["constructorObserved"] = state.page != nil
            base["observedOwnerCount"] = state.observedStages; base["smallVectorArtifacts"] = state.diagnostics
            try? publishManifest(base, transaction: transaction, final: final)
            throw error
        }
    }
}
