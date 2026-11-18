import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// Saved model evidence is accepted only for the exact original source file.
/// This adapter loads predictions, never labels or page-specific runtime policies.
enum HostEnsembleEvidence {
    static func sourceStageBinding(original: CGImage, sourceURL: URL?, fallbackURL: URL?) throws -> NativeMainEnsembleOCREvidence.Binding {
        guard let url = sourceURL ?? fallbackURL else { throw HostError.message("Missing encoded source binding") }
        let bytes = try Data(contentsOf: url)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return try NativeMainEnsembleOCREvidence.cachedBinding(original: original,
            encodedSource: bytes, expectedSourceSHA256: digest)
    }

    static func register(_ value: [String: Any], sourceURL: URL, image: CGImage) throws {
        let digest = SHA256.hash(data: try Data(contentsOf: sourceURL)).map { String(format: "%02x", $0) }.joined()
        guard value["sourceSHA256"] as? String == digest else { throw HostError.message("RF replay source identity mismatch") }
        func load(_ path: String) throws -> [String: Any] {
            guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any],
                  object["sourceSHA256"] as? String == digest else { throw HostError.message("Stale saved RF evidence") }
            return object
        }
        func ring(_ value: Any?) -> [CGPoint] {
            (value as? [[Double]] ?? []).compactMap {
                $0.count == 2 && $0.allSatisfy(\.isFinite) ? CGPoint(x: $0[0], y: $0[1]) : nil
            }
        }
        var regions: [Ensemble100RFRegion] = []
        if let path = value["rfBodies"] as? String {
            for body in try load(path)["bodies"] as? [[String: Any]] ?? [] {
                for polygon in body["polygons"] as? [[String: Any]] ?? [] {
                    let exterior = ring(polygon["exterior"])
                    guard exterior.count >= 3 else { continue }
                    let xs = exterior.map(\.x), ys = exterior.map(\.y)
                    regions.append(.init(queryID: body["query"] as? Int ?? -1, classID: 2,
                        confidence: body["confidence"] as? Double ?? 0,
                        bounds: CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!),
                        exterior: exterior, holes: (polygon["holes"] as? [Any] ?? []).map(ring)))
                }
            }
        }
        if let path = value["rfAllBoxes"] as? String {
            for box in try load(path)["predictions"] as? [[String: Any]] ?? [] {
                guard let b = box["boxXYWH"] as? [Double], b.count == 4, b.allSatisfy(\.isFinite),
                      let c = box["rawClass"] as? Int, let query = box["id"] as? Int else { continue }
                if regions.contains(where: { $0.queryID == query && $0.classID == c }) { continue }
                regions.append(.init(queryID: query, classID: c, confidence: box["score"] as? Double ?? 0,
                    bounds: CGRect(x: b[0], y: b[1], width: b[2], height: b[3]), exterior: [], holes: []))
            }
        }
        try NativeMainEnsembleEvidenceStore.shared.register(regions: regions, original: image)
        if let revision = value["sourceRevision"] as? [String: Any] {
            guard let path = revision["path"] as? String,
                  let expected = revision["fileSHA256"] as? String else {
                throw HostError.message("Invalid source revision descriptor")
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expected,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["sourceSHA256"] as? String == digest,
                  let version = object["version"] as? Int, [1, 2].contains(version),
                  object["originalRemovalItems"] is [[String: Any]],
                  object["transactions"] is [[String: Any]] else {
                throw HostError.message("Stale or incomplete source revision")
            }
            try NativeMainEnsembleEvidenceStore.shared.register(sourceRevision: data, original: image)
        } else {
            // A replay without a revision must not inherit a prior transaction
            // for the same source content from this resident renderer.
            try NativeMainEnsembleEvidenceStore.shared.register(sourceRevision: nil, original: image)
        }
        if let ocr = value["originalOCR"] as? [String: Any] {
            guard let path = ocr["path"] as? String,
                  let fileSHA = ocr["fileSHA256"] as? String,
                  ocr["artifactSourceSHA256"] as? String == digest else {
                throw HostError.message("Invalid cached OCR source/artifact binding")
            }
            let binding = try NativeMainEnsembleOCREvidence.cachedBinding(original: image,
                encodedSource: Data(contentsOf: sourceURL), expectedSourceSHA256: digest)
            let rows = try NativeMainEnsembleOCREvidence.cachedRows(
                data: Data(contentsOf: URL(fileURLWithPath: path)), expectedArtifactSHA256: fileSHA,
                artifactSourceSHA256: digest, schema: .readerFinalRegions, binding: binding)
            let packet = try NativeMainEnsembleOCREvidence.Packet(binding: binding, stages: [rows])
            try NativeMainEnsembleEvidenceStore.shared.register(ocr: packet, original: image)
        }
        if let probability = value["probability"] as? [String: Any] {
            guard let path = probability["path"] as? String,
                  let width = probability["width"] as? Int, let height = probability["height"] as? Int,
                  width > 0, height > 0, width <= 2000, height <= 2000,
                  width <= image.width, height <= image.height,
                  let expected = probability["fileSHA256"] as? String,
                  let tracePath = probability["trace"] as? String,
                  let traceSHA = probability["traceFileSHA256"] as? String else {
                throw HostError.message("Invalid full-source DB probability descriptor")
            }
            let traceURL = URL(fileURLWithPath: tracePath)
            let traceData = try Data(contentsOf: traceURL)
            guard SHA256.hash(data: traceData).map({ String(format: "%02x", $0) }).joined() == traceSHA,
                  let envelope = try JSONSerialization.jsonObject(with: traceData) as? [String: Any],
                  envelope["stage"] as? String == "detector-probability-map",
                  let trace = envelope["value"] as? [String: Any],
                  trace["width"] as? Int == width, trace["height"] as? Int == height,
                  trace["normalizedRect"] as? [Double] == [0, 0, 1, 1],
                  trace["format"] as? String == "little-endian float32 row-major",
                  let raw = trace["raw"] as? String,
                  traceURL.deletingLastPathComponent().appendingPathComponent(raw).resolvingSymlinksInPath().standardizedFileURL
                    == URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL else {
                throw HostError.message("DB probability is cropped, padded, stale or not bound to its actual trace")
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard data.count == width * height * MemoryLayout<Float>.size,
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expected else {
                throw HostError.message("Changed DB probability bytes")
            }
            var values = [Float](repeating: 0, count: width * height)
            _ = values.withUnsafeMutableBytes { data.copyBytes(to: $0) }
            guard values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                throw HostError.message("Nonfinite or out-of-range DB probability")
            }
            try NativeMainEnsembleEvidenceStore.shared.register(probability: .init(original: image,
                width: width, height: height, values: values))
        }
        if let cached = value["cachedRestoration"] as? [String: Any] {
            func verifiedImage(_ key: String, hashKey: String) throws -> CGImage {
                guard let path = cached[key] as? String, let expected = cached[hashKey] as? String else {
                    throw HostError.message("Incomplete cached main restoration provenance")
                }
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard actual == expected,
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    throw HostError.message("Changed cached main restoration artifact")
                }
                return decoded
            }
            let mask = try verifiedImage("mask", hashKey: "maskFileSHA256")
            let restored = try verifiedImage("restored", hashKey: "restoredFileSHA256")
            try NativeMainAOTBackend.shared.registerCachedRestoration(source: image, mask: mask, restored: restored,
                boundaryBiasPolicy: cached["boundaryBiasPolicy"] as? String)
        }
    }
}

extension HostEnsembleEvidence {
    static let completeV2Schema = "aidoku-complete-render-evidence-v2"
    static let savedContextSchema = "aidoku-source-render-context-v2"
    private static let requiredSavedContextStages: Set<NativeMainEnsembleOCREvidence.Stage> = [.finalRegions, .nativeLines]
    private static let fiveObservedStages: Set<NativeMainEnsembleOCREvidence.Stage> = [
        .finalRegions, .nativeLines, .detector, .recognized, .rejected]

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Seal the entire actual pre-provider packet, including unavailable slots.
    /// Native/final are required by the render carrier; additional stages are
    /// preserved only when observed. Neither final.json nor old numbered files
    /// reconstruct observations or supply an unobserved stage.
    static func captureSavedContext(sourceURL: URL, image: CGImage, directory: URL,
                                    packet: NativeMainEnsembleOCREvidence.Packet?) throws {
        guard let packet else {
            HostDump.capture("saved-source-context", ["status": "capture-unavailable", "reason": "current-typed-packet-unavailable"])
            return
        }
        let bytes = try Data(contentsOf: sourceURL)
        let sourceSHA = digest(bytes)
        let binding = try NativeMainEnsembleOCREvidence.cachedBinding(original: image,
            encodedSource: bytes, expectedSourceSHA256: sourceSHA)
        guard packet.binding.contentIdentity == binding.contentIdentity,
              packet.binding.width == image.width, packet.binding.height == image.height else {
            throw HostError.message("Current OCR packet source mismatch")
        }
        guard requiredSavedContextStages.isSubset(of: Set(packet.stages.keys)) else {
            let unavailable: [String: Any] = ["schema": "aidoku-source-render-context-unavailable-v1",
                "sourceSHA256": sourceSHA, "sourceSize": [image.width, image.height],
                "status": "capture-unavailable", "reason": "required-observed-OCR-stage-unavailable"]
            // Replace any older complete pointer in a resumed directory. The
            // successful normal pipeline remains successful, with no fake rows.
            try JSONSerialization.data(withJSONObject: unavailable, options: [.sortedKeys])
                .write(to: directory.appendingPathComponent("source-render-context.json"), options: .atomic)
            HostDump.capture("saved-source-context", unavailable)
            return
        }
        let data = try packet.archivedData(), sha = digest(data)
        _ = try NativeMainEnsembleOCREvidence.cachedPacket(data: data, expectedArtifactSHA256: sha,
            artifactSourceSHA256: sourceSHA, binding: binding)
        let name = "source-ocr-packet.json"
        let descriptor: [String: Any] = ["path": name, "fileSHA256": sha, "artifactSourceSHA256": sourceSHA]
        let value: [String: Any] = ["schema": savedContextSchema, "sourceSHA256": sourceSHA,
            "sourceSize": [image.width, image.height], "ocrPacket": descriptor,
            "stageAvailability": Dictionary(uniqueKeysWithValues: NativeMainEnsembleOCREvidence.Stage.allCases.map {
                ($0.rawValue, packet.stages[$0].map { "observed:\($0.count)" } ?? "unavailable")
            }), "observedStageCount": packet.stages.count,
            "hasAllFiveObserved": fiveObservedStages.isSubset(of: Set(packet.stages.keys)),
            "producer": "current-typed-packet-publication-before-provider-v1",
            "authority": "source invocation sealed actual typed OCR packet; not detector model producer attestation"]
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            .write(to: directory.appendingPathComponent("source-render-context.json"), options: .atomic)
    }

    /// Reuse bound OCR artifacts and a current DB capability. RF remains the
    /// ordinary semantic consumer, with its existing source/model cache key.
    static func prepareSavedContext(sourceURL: URL, image: CGImage, directory: URL,
                                    arguments: [String: Any], preparedDB: NativeMainEnsemblePreparedDB) async throws
        -> NativeMainEnsembleRenderEvidence? {
        let manifest = directory.appendingPathComponent("source-render-context.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else { return nil }
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any] else {
            throw HostError.message("Invalid saved source render context")
        }
        // v1 reconstructed post-provider rows from files rather than capturing
        // the actual invocation packet. Its two slots are not an authenticated
        // copy of a current two-stage packet; never promote it retroactively.
        if value["schema"] as? String == "aidoku-source-render-context-v1" { return nil }
        if value["schema"] as? String == "aidoku-source-render-context-unavailable-v1" { return nil }
        guard value["schema"] as? String == savedContextSchema,
              value["sourceSize"] as? [Int] == [image.width, image.height],
              let sourceSHA = value["sourceSHA256"] as? String,
              value["producer"] as? String == "current-typed-packet-publication-before-provider-v1",
              let descriptor = value["ocrPacket"] as? [String: Any],
              descriptor["artifactSourceSHA256"] as? String == sourceSHA,
              let path = descriptor["path"] as? String,
              path == URL(fileURLWithPath: path).lastPathComponent, path != ".", path != "..",
              let expected = descriptor["fileSHA256"] as? String else {
            throw HostError.message("Invalid saved source render context")
        }
        let binding = try NativeMainEnsembleOCREvidence.cachedBinding(original: image,
            encodedSource: Data(contentsOf: sourceURL), expectedSourceSHA256: sourceSHA)
        let packet = try NativeMainEnsembleOCREvidence.cachedPacket(data: Data(contentsOf: directory.appendingPathComponent(path)),
            expectedArtifactSHA256: expected, artifactSourceSHA256: sourceSHA, binding: binding)
        guard requiredSavedContextStages.isSubset(of: Set(packet.stages.keys)) else {
            throw HostError.message("Saved source render context lacks an observed required OCR stage")
        }
        let availability = Dictionary(uniqueKeysWithValues: NativeMainEnsembleOCREvidence.Stage.allCases.map {
            ($0.rawValue, packet.stages[$0].map { "observed:\($0.count)" } ?? "unavailable")
        })
        guard value["stageAvailability"] as? [String: String] == availability,
              value["observedStageCount"] as? Int == packet.stages.count,
              let allFive = value["hasAllFiveObserved"] as? NSNumber, CFGetTypeID(allFive) == CFBooleanGetTypeID(),
              allFive.boolValue == fiveObservedStages.isSubset(of: Set(packet.stages.keys)) else {
            throw HostError.message("Saved OCR stage availability changed")
        }
        try preparedDB.validate(original: image)
        let revision: Data?
        if let evidence = arguments["nativeEnsembleEvidence"] as? [String: Any],
           let descriptor = evidence["sourceRevision"] as? [String: Any] {
            guard evidence["sourceSHA256"] as? String == sourceSHA,
                  let path = descriptor["path"] as? String, let expected = descriptor["fileSHA256"] as? String else {
                throw HostError.message("Invalid saved context source revision binding")
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard digest(data) == expected,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["sourceSHA256"] as? String == sourceSHA else {
                throw HostError.message("Changed saved context source revision")
            }
            revision = data
        } else { revision = nil }
        let unowned = try NativeCausalUnownedInkLiveRecovery.masksFromPayload(arguments["causalUnownedContextMasks"], original: image)
        let source = try NativeRFDETRSourceImage.decode(image)
        let rf = try await normalRF(source: source)
        let db = preparedDB.probability
        return try NativeMainEnsembleRenderEvidence(original: image, normalRF: rf, probability: db,
            dbGeometry: .init(resizedWidth: db.width, resizedHeight: db.height,
                region: CGRect(x: 0, y: 0, width: db.width, height: db.height), origin: .controlledLiveFullMap),
            ocr: packet, producerContract: "sealed source-bound OCR artifacts plus current shared DB ensure and normal RF",
            revisionData: revision, unownedMasks: unowned, validatedDB: preparedDB)
    }

    private static func ocrPacket(_ descriptors: [[String: Any]], binding: NativeMainEnsembleOCREvidence.Binding,
                                  sourceSHA: String, directory: URL? = nil) throws -> NativeMainEnsembleOCREvidence.Packet {
        guard descriptors.count == 2 else { throw HostError.message("Missing saved OCR stage slots") }
        var stages: [NativeMainEnsembleOCREvidence.StageRows] = []
        var seen: Set<String> = []
        for descriptor in descriptors {
            guard let name = descriptor["schema"] as? String, seen.insert(name).inserted,
                  descriptor["artifactSourceSHA256"] as? String == sourceSHA,
                  let expected = descriptor["fileSHA256"] as? String,
                  let path = descriptor["path"] as? String else { throw HostError.message("Invalid saved OCR artifact binding") }
            let schema: NativeMainEnsembleOCREvidence.Schema
            switch name {
            case "readerFinalRegions": schema = .readerFinalRegions
            case "nativeLinesPixels": schema = .nativeLinesPixels
            default: throw HostError.message("Unsupported saved OCR schema")
            }
            let url: URL
            if let directory {
                guard path == URL(fileURLWithPath: path).lastPathComponent, path != ".", path != ".." else {
                    throw HostError.message("Saved context artifact must be a sibling file")
                }
                url = directory.appendingPathComponent(path)
            } else { url = URL(fileURLWithPath: path) }
            stages.append(try NativeMainEnsembleOCREvidence.cachedRows(data: Data(contentsOf: url),
                expectedArtifactSHA256: expected, artifactSourceSHA256: sourceSHA, schema: schema, binding: binding))
        }
        guard seen == Set(["readerFinalRegions", "nativeLinesPixels"]) else { throw HostError.message("Missing saved OCR stage") }
        return try NativeMainEnsembleOCREvidence.Packet(binding: binding, stages: stages)
    }

    private static func normalRF(source: NativeRFDETRSourceImage) async throws -> NativeRFDETRLayoutResult {
        try Task.checkCancellation()
        let detector = NativeRFDETRLayoutDetector(maximumMaskQueries: 160, retainAllQueryMasks: false,
            expectedWeightsSHA256: NativeRFDETRLayoutResource.sourceWeightsSHA256,
            expectedSourceRevision: NativeRFDETRLayoutResource.sourceRevision,
            resolveModelURL: {
                guard let url = HostResources.bundle.url(forResource: NativeRFDETRLayoutResource.resourceName,
                                                        withExtension: "mlmodelc") else {
                    throw NativeRFDETRLayoutError.modelUnavailable
                }
                return url
            })
        let rf = try await detector.detect(source: source)
        if HostRFRawReplay.enabled {
            HostDump.capture("rf-raw-archive-v2-normal", HostRFRawReplay.diagnostics(sourceIdentity: source.identity))
        }
        try Task.checkCancellation()
        guard rf.imageIdentity == source.identity, rf.sourceWidth == source.width, rf.sourceHeight == source.height,
              rf.semanticGrid?.modelWeightsSHA256 == NativeRFDETRLayoutResource.sourceWeightsSHA256 else {
            throw HostError.message("Normal RF source/model mismatch")
        }
        return rf
    }

    /// All file/source/model preflight completes before the sole normal RF
    /// detector demand. Returns invocation-owned values; registers no global store.
    static func prepareCompleteV2(_ value: [String: Any], sourceURL: URL, image: CGImage,
                                  root: URL, arguments: [String: Any]) async throws -> NativeMainEnsembleRenderEvidence {
        func digest(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        func verified(_ descriptor: [String: Any]) throws -> Data {
            guard let path = descriptor["path"] as? String,
                  let expected = descriptor["fileSHA256"] as? String else {
                throw HostError.message("Incomplete completeV2 artifact descriptor")
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard digest(data) == expected else { throw HostError.message("Changed completeV2 artifact") }
            return data
        }
        guard value["schema"] as? String == completeV2Schema,
              value["requireCompleteEvidence"] as? Bool == true,
              value["rfBodies"] == nil, value["rfAllBoxes"] == nil,
              value["cachedRestoration"] == nil, value["originalOCR"] == nil,
              let sourceSHA = value["sourceSHA256"] as? String,
              value["sourceSize"] as? [Int] == [image.width, image.height],
              let models = value["expectedModels"] as? [String: Any],
              models["RFWeightsSHA256"] as? String == NativeRFDETRLayoutResource.sourceWeightsSHA256,
              models["RFSourceRevision"] as? String == NativeRFDETRLayoutResource.sourceRevision,
              models["RFMaximumMaskQueries"] as? Int == 160,
              models["RFRetainAllQueryMasks"] as? Bool == false,
              let detectorName = models["DBDetectorResourceName"] as? String,
              let tierName = models["DBModelTier"] as? String,
              let tier = IPhoneOCRModelTier(rawValue: tierName),
              NativeCoreMLOCRModelProfile.profile(for: tier).detectorResourceName == detectorName,
              ProcessInfo.processInfo.environment["AIDOKU_SOURCE_RF_LAYOUT_HANDOFF"] != "1" else {
            throw HostError.message("Incomplete/mismatched completeV2 source/model/normal-RF contract")
        }
        let encodedSource = try Data(contentsOf: sourceURL)
        guard digest(encodedSource) == sourceSHA else { throw HostError.message("CompleteV2 source digest mismatch") }
        let source = try NativeRFDETRSourceImage.decode(image)
        let binding = try NativeMainEnsembleOCREvidence.cachedBinding(original: image,
            encodedSource: encodedSource, expectedSourceSHA256: sourceSHA)

        // The frozen manifest is an externally bound artifact, not a new claim
        // embedded retroactively in old probability trace metadata.
        guard let frozen = value["frozenInventory"] as? [String: Any],
              let inventory = try JSONSerialization.jsonObject(with: verified(frozen)) as? [String: Any],
              inventory["model_weights_may_change"] as? Bool == false,
              let files = inventory["files"] as? [[String: Any]] else {
            throw HostError.message("Invalid completeV2 frozen model inventory")
        }
        let prefixes = ["Aidoku/Resources/Translation/" + detectorName + ".mlpackage/",
                        "Aidoku/Resources/Translation/" + NativeRFDETRLayoutResource.resourceName + ".mlpackage/",
                        "Aidoku/Resources/Translation/SourceModels/"]
        let selected = files.filter { row in
            guard let path = row["path"] as? String else { return false }
            return prefixes.contains { path.hasPrefix($0) }
        }
        guard prefixes.allSatisfy({ prefix in selected.contains { ($0["path"] as? String)?.hasPrefix(prefix) == true } }) else {
            throw HostError.message("Incomplete frozen DB/RF/source model file inventory")
        }
        for file in selected {
            try Task.checkCancellation()
            guard let relative = file["path"] as? String, !relative.split(separator: "/").contains(".."),
                  let expected = file["sha256"] as? String, let count = file["bytes"] as? Int else {
                throw HostError.message("Malformed frozen completeV2 model entry")
            }
            let bytes = try Data(contentsOf: root.appendingPathComponent(relative))
            guard bytes.count == count, digest(bytes) == expected else {
                throw HostError.message("Frozen completeV2 model file changed")
            }
        }
        let registryData = try Data(contentsOf: root.appendingPathComponent("Aidoku/Resources/Translation/SourceModels/registry-index.json"))
        guard digest(registryData) == models["registryIndexSHA256"] as? String,
              let registry = try JSONSerialization.jsonObject(with: registryData) as? [String: Any],
              let actualArtifacts = registry["sourceArtifacts"] as? [String: String],
              actualArtifacts == models["sourceArtifacts"] as? [String: String] else {
            throw HostError.message("CompleteV2 source registry contract changed")
        }

        guard let inputDescriptor = value["originalInput"] as? [String: Any],
              inputDescriptor["artifactSourceSHA256"] as? String == sourceSHA,
              let inputEnvelope = try JSONSerialization.jsonObject(with: verified(inputDescriptor)) as? [String: Any],
              inputEnvelope["stage"] as? String == "input",
              let input = inputEnvelope["value"] as? [String: Any],
              input["width"] as? Int == image.width, input["height"] as? Int == image.height,
              let configuration = input["configuration"] as? [String: Any],
              configuration["modelTier"] as? String == tierName else {
            throw HostError.message("CompleteV2 original invocation/source binding changed")
        }
        guard let probability = value["probability"] as? [String: Any],
              let width = probability["width"] as? Int, let height = probability["height"] as? Int,
              width > 0, height > 0, width <= min(2000, image.width), height <= min(2000, image.height),
              let path = probability["path"] as? String,
              let tracePath = probability["trace"] as? String,
              let traceSHA = probability["traceFileSHA256"] as? String else {
            throw HostError.message("Missing completeV2 full-source DB slot")
        }
        let traceURL = URL(fileURLWithPath: tracePath)
        let traceData = try Data(contentsOf: traceURL)
        guard digest(traceData) == traceSHA,
              let traceEnvelope = try JSONSerialization.jsonObject(with: traceData) as? [String: Any],
              traceEnvelope["stage"] as? String == "detector-probability-map",
              let trace = traceEnvelope["value"] as? [String: Any],
              trace["width"] as? Int == width, trace["height"] as? Int == height,
              trace["format"] as? String == "little-endian float32 row-major",
              trace["normalizedRect"] as? [Double] == [0, 0, 1, 1],
              let raw = trace["raw"] as? String,
              traceURL.deletingLastPathComponent().appendingPathComponent(raw).resolvingSymlinksInPath().standardizedFileURL
                == URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL else {
            throw HostError.message("CompleteV2 DB trace/crop/path mismatch")
        }
        let mapData = try verified(probability)
        guard mapData.count == width * height * 4 else { throw HostError.message("CompleteV2 DB tensor byte count mismatch") }
        var values = [Float](repeating: 0, count: width * height)
        try mapData.withUnsafeBytes { buffer in
            for index in values.indices {
                if index & 4095 == 0 { try Task.checkCancellation() }
                // Explicit little-endian decoding preserves every original float bit.
                let bits = buffer.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)
                let value = Float(bitPattern: UInt32(littleEndian: bits))
                guard value.isFinite, (0...1).contains(value) else { throw HostError.message("Invalid completeV2 DB probability") }
                values[index] = value
            }
        }
        let db = NativeMainAOTRemovalMaskBuilder.SourceProbability(original: image, width: width, height: height, values: values)

        guard let descriptors = value["originalOCRStages"] as? [[String: Any]] else {
            throw HostError.message("Missing completeV2 OCR bank")
        }
        let packet = try ocrPacket(descriptors, binding: binding, sourceSHA: sourceSHA)
        // Optional source revisions are deliberately unsupported by this initial
        // completeV2 probe, rather than omitted silently from the snapshot.
        guard value["sourceRevision"] == nil else { throw HostError.message("CompleteV2 source revision is not supported yet") }
        let unowned = try NativeCausalUnownedInkLiveRecovery.masksFromPayload(arguments["causalUnownedContextMasks"], original: image)
        // Normal auxiliary semantic consumer, NOT retainAll=true source-style RF.
        let rf = try await normalRF(source: source)
        let geometry = NativeMainEnsembleRenderEvidence.DBGeometry(resizedWidth: width, resizedHeight: height,
            region: CGRect(x: 0, y: 0, width: width, height: height), origin: .authenticatedSavedFullMapLegacyProducerUnproven)
        return try NativeMainEnsembleRenderEvidence(original: image, normalRF: rf, probability: db,
            dbGeometry: geometry, ocr: packet,
            producerContract: "authenticated original source/input/trace/raw plus fixed task inventory; legacy trace embeds no source/model SHA",
            revisionData: nil, unownedMasks: unowned)
    }
}
