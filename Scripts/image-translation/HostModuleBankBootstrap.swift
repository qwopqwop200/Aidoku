import CoreGraphics
import CryptoKit
import Foundation

/// Host-only opt-in attestation. No model is loaded or executed here. In
/// particular, a hash of today's checkout is NEVER evidence for an older binary.
@available(macOS 15.0, *)
enum HostModuleBankBootstrap {
    enum Failure: Error { case invalid(String) }

    struct ProducerManifest: Decodable {
        let schema: String
        let pipelineFingerprint: String
        let producerSHA256: String
        let compiledSourceSHA256: [String: String]
        let stageSchemas: [String: String]
    }

    static var requiredStages: [String] {
        NativeOCRRawModuleObservation.Stage.allCases.map(\.rawValue) + ["recRequested", "recDecoded"]
    }

    static func makeSession(sourceURL: URL, original: CGImage, directory: URL,
                            configuration: ReaderOCRConfiguration,
                            sourceAnchorMode: String) throws -> HostModuleBank.Session? {
        let environment = ProcessInfo.processInfo.environment
        // Keep the ordinary path entirely free of resource reads and hashing.
        guard environment["AIDOKU_MODULE_BANK_CAPTURE"] == "1" else { return nil }
        guard let path = environment["AIDOKU_HOST_MODEL_BUNDLE"],
              Bundle(path: path) != nil else { throw Failure.invalid("missing actual HostResources bundle") }
        let producer = try producerManifest(environment: environment)
        let contract = try makeContract(sourceURL: sourceURL, original: original,
            directory: directory, configuration: configuration, sourceAnchorMode: sourceAnchorMode,
            producer: producer, bundle: HostResources.bundle, environment: environment)
        guard contract.identityComplete else { throw Failure.invalid("incomplete module-bank identity") }
        return try HostModuleBank.Session(directory: directory, sourceURL: sourceURL,
            original: original, contract: contract)
    }

    /// Root runner writes this FROZEN map after compiling the binary. Only
    /// manifest bytes are read; map paths are provenance, never live source URLs.
    static func producerManifest(environment: [String: String]) throws -> ProducerManifest {
        guard let path = environment["AIDOKU_MODULE_BANK_PRODUCER_MANIFEST"], !path.isEmpty,
              let fingerprint = environment["AIDOKU_PIPELINE_FINGERPRINT"], hex(fingerprint) else {
            throw Failure.invalid("missing frozen producer manifest or runtime fingerprint")
        }
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        guard data.count <= 8 * 1024 * 1024 else { throw Failure.invalid("oversize producer manifest") }
        let value = try JSONDecoder().decode(ProducerManifest.self, from: data)
        guard value.schema == "aidoku-module-bank-producer-v1",
              value.pipelineFingerprint == fingerprint,
              !value.compiledSourceSHA256.isEmpty,
              value.compiledSourceSHA256.keys.allSatisfy({ !$0.isEmpty }),
              value.compiledSourceSHA256.values.allSatisfy(hex),
              hex(value.producerSHA256),
              value.producerSHA256 == producerDigest(value.compiledSourceSHA256),
              requiredStages.allSatisfy({ !(value.stageSchemas[$0] ?? "").isEmpty }),
              NativeOCRRawModuleObservation.Stage.allCases.allSatisfy({
                  value.stageSchemas[$0.rawValue] == NativeOCRRawModuleObservation.schema
              }) else { throw Failure.invalid("unbound frozen producer contract") }
        // The facade needs basename lookup, but duplicate basenames must never
        // silently overwrite one another. Preserve original compiledPath keys.
        _ = try compiledSourceBasenames(value)
        return value
    }

    static func compiledSourceBasenames(_ producer: ProducerManifest) throws -> [String: String] {
        var result: [String: String] = [:]
        for (path, digest) in producer.compiledSourceSHA256 {
            let name = URL(fileURLWithPath: path).lastPathComponent
            guard !name.isEmpty, result[name] == nil else {
                throw Failure.invalid("ambiguous frozen compiled source basename")
            }
            result[name] = digest
        }
        return result
    }

    /// Internal seam permits metadata/resource-only fake-bundle proof without
    /// invoking Session, decoding pixels or acquiring any Core ML model.
    static func makeContract(sourceURL: URL, original: CGImage, directory: URL,
                             configuration: ReaderOCRConfiguration, sourceAnchorMode: String,
                             producer: ProducerManifest, bundle: Bundle,
                             environment: [String: String]) throws -> HostModuleBank.Contract {
        guard let mode = NativeOCRRawCanonicalPolicy.SourceAnchorMode(rawValue: sourceAnchorMode),
              mode != .disabled, environment["AIDOKU_DISABLE_RF_LAYOUT"] != "1" else {
            throw Failure.invalid("capture requires actual source-anchor OCR and RF")
        }
        let profile = NativeCoreMLOCRModelProfile.profile(for: configuration.modelTier)
        func resource(_ name: String, _ ext: String) throws -> URL {
            guard let url = bundle.url(forResource: name, withExtension: ext),
                  FileManager.default.fileExists(atPath: url.path) else {
                throw Failure.invalid("missing actual bundle resource: \(name).\(ext)")
            }
            return url
        }
        // Always hash the actually resolved compiled resource trees, never an
        // adjacent mlpackage, stale registry or resource-name-only identity.
        let models = [
            "ppocr-det": try HostRFRawReplay.treeDigest(resource(profile.detectorResourceName, "mlmodelc")),
            "ppocr-rec": try HostRFRawReplay.treeDigest(resource(profile.recognizerResourceName, "mlmodelc")),
            "rf-detr": try HostRFRawReplay.treeDigest(resource(NativeRFDETRLayoutResource.resourceName, "mlmodelc")),
            "pre-rec-aux": try HostRenderProvenance.fileSHA256(resource(
                NativeOCRRawGeometryModelBundle.File.preRecognition.rawValue, "json"))
        ]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let ocr = try JSONSerialization.jsonObject(with: encoder.encode(configuration))
        var config: [String: Any] = [
            "schema": "aidoku-module-bank-source-ocr-configuration-v1",
            "scope": "source-module-ocr-only;no-AOT;no-LLM;no-GT",
            "ocr": ocr, "sourceAnchorMode": sourceAnchorMode,
            "sourceAnchorPolicy": NativeOCRRawCanonicalPolicy.version,
            "detectorPreprocessingABI": NativeCoreMLDetectionPreprocessor.provenanceABI,
            "detectorNormalizationSHA256": NativeCoreMLDetectionPreprocessor.normalizationConfigurationSHA256,
            "rawModuleSchema": NativeOCRRawModuleObservation.schema,
            "stageSchemas": producer.stageSchemas,
            "recognizerDictionarySHA256": try HostRenderProvenance.fileSHA256(resource(profile.dictionaryResourceName, "txt")),
            "compiledSourceContractSHA256": producer.producerSHA256
        ]
        if configuration.modelTier == .manga {
            config["recognizerNgramSHA256"] = try HostRenderProvenance.fileSHA256(resource("manga_ngram_v03", "bin"))
        }
        if environment[NativeCoreMLDBPostprocessor.alternateCellEnvelopeEnvironmentKey] == "1" {
            config["detectorAlternatePolicyVersion"] = NativeOCRRawCanonicalPolicy.detectorAlternatePolicyVersion
        }
        if let deduplication = NativeOCRRawCanonicalRuntime.simpleDeduplication {
            config["postRecognitionDeduplication"] = ["policy": NativeSimpleOCRDedup.policyVersion,
                "configuration": try JSONSerialization.jsonObject(with: encoder.encode(deduplication))]
        }
        let configurationData = try JSONSerialization.data(withJSONObject: config,
            options: [.sortedKeys, .withoutEscapingSlashes])
        let sourceSHA = try HostRenderProvenance.fileSHA256(sourceURL)
        let identity = try NativeRFDETRSourceImage.decode(original).identity
        let contract = HostModuleBank.Contract(
            // This is the output artifact ordinal ONLY. Source filenames never
            // guess canonical corpus page IDs or become model features.
            pageID: directory.lastPathComponent,
            sourceEncodedSHA256: sourceSHA, sourceImageIdentity: identity,
            width: original.width, height: original.height, modelSHA256: models,
            configurationSHA256: digest(configurationData), producerSHA256: producer.producerSHA256,
            stageSchemas: producer.stageSchemas, requiredStages: requiredStages,
            requiredModelRoles: HostModuleBank.ocrOnlyRequiredModelRoles)
        guard contract.identityComplete else { throw Failure.invalid("incomplete required metadata") }
        return contract
    }

    static func hex(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Python json.dumps(map,sort_keys=True,separators=(',',':'),ensure_ascii=True)
    /// parity. Foundation sortedKeys has locale-aware key ordering, so it is
    /// deliberately NOT used for this cross-language frozen producer identity.
    static func producerDigest(_ files: [String: String]) -> String {
        func quoted(_ value: String) -> String {
            var result = "\""
            for scalar in value.unicodeScalars {
                switch scalar.value {
                case 34: result += "\\\""
                case 92: result += "\\\\"
                case 8: result += "\\b"
                case 9: result += "\\t"
                case 10: result += "\\n"
                case 12: result += "\\f"
                case 13: result += "\\r"
                case 32...126: result.unicodeScalars.append(scalar)
                case 0...0xffff: result += String(format: "\\u%04x", scalar.value)
                default:
                    let code = scalar.value - 0x10000
                    result += String(format: "\\u%04x\\u%04x", 0xd800 + (code >> 10), 0xdc00 + (code & 0x3ff))
                }
            }
            return result + "\""
        }
        let keys = files.keys.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
        let text = "{" + keys.map { quoted($0) + ":" + quoted(files[$0]!) }.joined(separator: ",") + "}"
        return digest(Data(text.utf8))
    }
}
