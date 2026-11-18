import CoreFoundation
import CoreGraphics
import CryptoKit
import Foundation

/// Opt-in persistence for an existing source-only pass. This type predicts
/// nothing and owns no global registry. The root producer supplies frozen model,
/// configuration and compilation identities; unknown identities remain unknown.
enum HostModuleBank {
    static let ocrOnlyRequiredModelRoles = ["ppocr-det", "ppocr-rec", "rf-detr", "pre-rec-aux"]
    enum Failure: Error {
        case contract, sourceBinding, budget, unsupportedValue(String), invalidPath
        case closed, duplicateStage(String), changedArtifact, incompleteIdentity
    }

    struct Contract: Codable, Equatable, Sendable {
        var schemaVersion = "aidoku-module-bank-contract-v1"
        let pageID: String // Artifact provenance only; never an inference feature.
        let sourceEncodedSHA256: String
        let sourceImageIdentity: String
        let width: Int
        let height: Int
        let modelSHA256: [String: String]
        let configurationSHA256: String?
        let producerSHA256: String?
        let stageSchemas: [String: String]
        let requiredStages: [String]
        let requiredModelRoles: [String]

        var identityComplete: Bool {
            Self.hex(configurationSHA256) && Self.hex(producerSHA256) && !requiredModelRoles.isEmpty &&
                requiredModelRoles.allSatisfy { Self.hex(modelSHA256[$0]) }
        }
        fileprivate static func hex(_ value: String?) -> Bool {
            guard let value else { return false }
            return value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        fileprivate func data() throws -> Data {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(self)
        }
    }

    final class Session: @unchecked Sendable {
        let contract: Contract
        let directory: URL
        private let transaction: URL
        private let contractData: Data
        private let contractSHA256: String
        private let maximumBytes: Int
        private let maximumArtifactBytes: Int
        private let lock = NSLock()
        private var bytes = 0
        private var sequence = 0
        private var closed = false
        private var artifacts: [[String: Any]] = []
        private var availability: [String: [String: Any]] = [:]
        private var failures: [String] = []
        private var streams: [String: FileHandle] = [:]
        private var streamBytes: [String: Int] = [:]
        private var streamHashes: [String: SHA256] = [:]
        private var streamCounts: [String: Int] = [:]
        private var dataBlobs: [String: [String: Any]] = [:]
        private var referencedDataBytes = 0
        private var uniqueDataBytes = 0
        private var objectOrdinals: [ObjectIdentifier: Int] = [:]
        private var retainedObjects: [AnyObject] = []
        private var objectDefinitions: [[String: Any]] = []
        private struct RecognitionPass {
            let expected: Int
            var requested = 0
            var decoded = 0
            var finished = false
        }
        private var recognitionPasses: [String: RecognitionPass] = [:]

        init(directory: URL, sourceURL: URL, original: CGImage, contract: Contract,
             maximumBytes: Int = 256 * 1024 * 1024,
             maximumArtifactBytes: Int = 64 * 1024 * 1024) throws {
            guard Contract.hex(contract.sourceEncodedSHA256), Contract.hex(contract.sourceImageIdentity),
                  contract.width == original.width, contract.height == original.height,
                  maximumBytes > 0, maximumArtifactBytes > 0, maximumArtifactBytes <= maximumBytes,
                  !contract.pageID.isEmpty, !contract.requiredStages.isEmpty,
                  Set(contract.requiredStages).count == contract.requiredStages.count,
                  contract.requiredStages.allSatisfy({ !(contract.stageSchemas[$0] ?? "").isEmpty }),
                  contract.modelSHA256.values.allSatisfy({ Contract.hex($0) }),
                  contract.configurationSHA256.map({ Contract.hex($0) }) ?? true,
                  contract.producerSHA256.map({ Contract.hex($0) }) ?? true else { throw Failure.contract }
            let source = try Data(contentsOf: sourceURL)
            _ = try NativeMainEnsembleOCREvidence.cachedBinding(original: original, encodedSource: source,
                expectedSourceSHA256: contract.sourceEncodedSHA256)
            guard try NativeRFDETRSourceImage.decode(original).identity == contract.sourceImageIdentity else {
                throw Failure.sourceBinding
            }
            self.contract = contract; self.directory = directory
            self.maximumBytes = maximumBytes; self.maximumArtifactBytes = maximumArtifactBytes
            contractData = try contract.data(); contractSHA256 = HostModuleBank.digest(contractData)
            guard contractData.count <= maximumArtifactBytes, contractData.count <= maximumBytes else { throw Failure.budget }
            bytes = contractData.count
            let previous = directory.appendingPathComponent("module-bank.json")
            if FileManager.default.fileExists(atPath: previous.path) {
                guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: previous)) as? [String: Any],
                      value["contractSHA256"] as? String == contractSHA256, value["complete"] as? Bool != true else {
                    throw Failure.contract
                }
            }
            transaction = directory.appendingPathComponent("transactions/" + UUID().uuidString)
            try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: true)
            try contractData.write(to: transaction.appendingPathComponent("contract.json"), options: .atomic)
        }

        /// Observer callbacks cannot silently swallow I/O/budget failures. A
        /// nonthrowing producer records them here and final sealing stays incomplete.
        func recordFailure(_ reason: String) {
            lock.lock(); defer { lock.unlock() }
            failures.append(reason)
        }

        func unavailable(stage: String, reason: String) {
            lock.lock(); defer { lock.unlock() }
            availability[stage] = ["status": "unavailable", "reason": reason]
        }

        func notExecuted(stage: String, reason: String) {
            lock.lock(); defer { lock.unlock() }
            availability[stage] = ["status": "not-executed", "reason": reason]
        }

        func writeJSON(stage: String, value: Any, records: Int) throws {
            lock.lock(); defer { lock.unlock() }
            try requireOpen()
            guard records >= 0 else { throw Failure.contract }
            guard availability[stage] == nil else { throw Failure.duplicateStage(stage) }
            let object = try exactJSON(value, depth: 0)
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
            _ = try writeDataLocked(stage: stage, name: "payload.json", data: data,
                encoding: "tagged-ieee754-hex-exact-json-v1")
            availability[stage] = ["status": "observed", "records": records]
        }

        @discardableResult
        func writeFloat64(stage: String, name: String, data: Data, rows: Int, columns: Int) throws -> [String: Any] {
            lock.lock(); defer { lock.unlock() }
            try requireOpen()
            guard rows >= 0, columns > 0, rows <= Int.max / 8 / columns,
                  data.count == rows * columns * 8 else { throw Failure.contract }
            return try writeDataLocked(stage: stage, name: name, data: data,
                encoding: "ieee754-binary64-little-endian-row-major-v1", shape: [rows, columns])
        }

        /// External raw RF/DB exports are referenced and checked, never copied
        /// into each module artifact. Root supplies their actual producer receipt.
        func referenceExternal(stage: String, url: URL, expectedSHA256: String,
                               sourceEncodedSHA256: String, schema: String, identity: [String: String]) throws {
            lock.lock(); defer { lock.unlock() }
            try requireOpen()
            guard sourceEncodedSHA256 == contract.sourceEncodedSHA256, Contract.hex(expectedSHA256), !schema.isEmpty,
                  Contract.hex(identity["modelSHA256"]), Contract.hex(identity["configurationSHA256"]),
                  Contract.hex(identity["producerSHA256"]) else { throw Failure.incompleteIdentity }
            guard try HostRenderProvenance.fileSHA256(url) == expectedSHA256 else { throw Failure.changedArtifact }
            let count = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            artifacts.append(["stage": stage, "path": url.standardizedFileURL.path, "external": true,
                "SHA256": expectedSHA256, "bytes": count, "encoding": schema, "identity": identity])
            availability[stage] = ["status": "observed", "external": true, "records": 1]
        }

        /// One ordered stream per stage. A partial stream lives only in the
        /// unpublished transaction; its exact digest is committed on finish.
        func appendJSON(stage: String, value: Any) throws {
            lock.lock(); defer { lock.unlock() }
            try requireOpen(); try safe(stage)
            let object = try exactJSON(value, depth: 0)
            var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
            data.append(10)
            guard availability[stage] == nil,
                  data.count <= maximumArtifactBytes - streamBytes[stage, default: 0] else { throw Failure.budget }
            try reserve(data.count)
            let handle = try streamLocked(stage)
            try handle.write(contentsOf: data)
            streamBytes[stage, default: 0] += data.count
            streamCounts[stage, default: 0] += 1
            var hash = streamHashes[stage] ?? SHA256(); hash.update(data: data); streamHashes[stage] = hash
        }

        @discardableResult
        func finish() throws -> URL {
            lock.lock(); defer { lock.unlock() }
            try requireOpen(); closed = true
            if recognitionPasses.values.contains(where: { !$0.finished }) {
                failures.append("REC pass missing actual successful finished event")
            }
            for stage in streams.keys.sorted() {
                let handle = streams[stage]!
                try handle.synchronize(); try handle.close()
                let name = stage + ".jsonl"
                try FileManager.default.moveItem(at: transaction.appendingPathComponent(name + ".partial"),
                    to: transaction.appendingPathComponent(name))
                let hash = streamHashes[stage]!.finalize().map { String(format: "%02x", $0) }.joined()
                artifacts.append(["stage": stage, "path": relative(transaction.appendingPathComponent(name)),
                    "external": false, "SHA256": hash, "bytes": streamBytes[stage]!,
                    "encoding": "tagged-ieee754-hex-exact-jsonl-v1"])
                if availability[stage] == nil {
                    availability[stage] = ["status": "observed", "records": streamCounts[stage]!]
                }
            }
            streams.removeAll()
            let observed = contract.requiredStages.allSatisfy { availability[$0]?["status"] as? String == "observed" }
            let complete = contract.identityComplete && observed && failures.isEmpty
            var value: [String: Any] = ["schema": "aidoku-host-module-bank-v1", "contractSHA256": contractSHA256,
                "contractPath": relative(transaction.appendingPathComponent("contract.json")),
                "contract": try JSONSerialization.jsonObject(with: contractData),
                "complete": complete, "producerIdentityComplete": contract.identityComplete,
                "availability": availability, "artifacts": artifacts, "failures": failures,
                "storedBytes": bytes, "maximumBytes": maximumBytes,
                "logicalDataBytes": referencedDataBytes, "uniqueStoredDataBytes": uniqueDataBytes,
                "dataBlobEncoding": "lossless raw bytes by exact SHA; one copy per transaction; no ROI reconstruction assumed",
                "objectDefinitions": objectDefinitions, "objectIdentityPolicy": "per-session strong ObjectIdentifier; never content/text/geometry dedup",
                "numericABI": "tagged-f64/f32-lowercase-hex; binary matrices raw-f64le; no finite-value imputation",
                "authority": "actual opt-in observer data; model/config/compiled identities supplied by controlled caller",
                "GTAtInference": false, "newModelCallsByExporter": 0]
            var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            // Account for the immutable transaction receipt and current pointer.
            // The small fixed-point loop accounts for decimal byte-count length.
            while value["storedBytes"] as? Int != bytes + data.count * 2 {
                guard data.count <= maximumArtifactBytes, data.count <= (maximumBytes - bytes) / 2 else { throw Failure.budget }
                value["storedBytes"] = bytes + data.count * 2
                data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            }
            guard data.count <= maximumArtifactBytes, data.count <= (maximumBytes - bytes) / 2 else { throw Failure.budget }
            bytes += data.count * 2
            let path = directory.appendingPathComponent("module-bank.json")
            try data.write(to: transaction.appendingPathComponent("manifest.json"), options: .atomic)
            try data.write(to: path, options: .atomic) // Publish only after every artifact/stream is closed.
            retainedObjects.removeAll()
            return path
        }

        deinit { for handle in streams.values { try? handle.close() } }

        private func requireOpen() throws { if closed { throw Failure.closed } }
        private func streamLocked(_ stage: String) throws -> FileHandle {
            try safe(stage)
            if let current = streams[stage] { return current }
            let path = transaction.appendingPathComponent(stage + ".jsonl.partial")
            guard FileManager.default.createFile(atPath: path.path, contents: nil) else { throw Failure.invalidPath }
            let handle = try FileHandle(forWritingTo: path)
            streams[stage] = handle; streamBytes[stage] = 0; streamCounts[stage] = 0; streamHashes[stage] = SHA256()
            return handle
        }
        private func safe(_ value: String) throws {
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) ||
                (97...122).contains($0) || $0 == 45 || $0 == 95 || $0 == 46 }), value != ".", value != ".." else {
                throw Failure.invalidPath
            }
        }
        private func reserve(_ count: Int) throws {
            guard count >= 0, count <= maximumArtifactBytes, count <= maximumBytes - bytes else { throw Failure.budget }
            bytes += count
        }
        private func relative(_ path: URL) -> String { String(path.path.dropFirst(directory.path.count + 1)) }
        @discardableResult private func writeDataLocked(stage: String, name: String, data: Data,
            encoding: String, shape: [Int]? = nil) throws -> [String: Any] {
            try safe(stage); try safe(name); try reserve(data.count)
            sequence += 1
            let file = transaction.appendingPathComponent(String(format: "%04d-", sequence) + stage + "-" + name)
            try data.write(to: file, options: .atomic)
            var descriptor: [String: Any] = ["stage": stage, "path": relative(file), "external": false,
                "SHA256": HostModuleBank.digest(data), "bytes": data.count, "encoding": encoding]
            if let shape { descriptor["shape"] = shape }
            artifacts.append(descriptor); return descriptor
        }

        /// Reflect the actual typed value before any JSON numeric conversion.
        /// Arrays are not sampled; sets are ordered canonically; unsupported
        /// reference graphs fail instead of silently dropping properties.
        private func exactJSON(_ value: Any, depth: Int) throws -> Any {
            guard depth < 64 else { throw Failure.budget }
            if let value = value as? String { return value }
            if let value = value as? UUID { return ["$uuid": value.uuidString] }
            if let value = value as? Data {
                guard value.count <= Int.max - referencedDataBytes else { throw Failure.budget }
                referencedDataBytes += value.count
                let hash = HostModuleBank.digest(value)
                if let old = dataBlobs[hash] { return ["$dataBlob": old] }
                let descriptor = try writeDataLocked(stage: "dataBlob", name: hash + ".bin", data: value, encoding: "raw-bytes-lossless-v1")
                dataBlobs[hash] = descriptor; uniqueDataBytes += value.count
                return ["$dataBlob": descriptor]
            }
            if type(of: value) == Double.self, let number = value as? Double {
                return ["$f64": String(format: "%016llx", number.bitPattern)]
            }
            if type(of: value) == Float.self, let number = value as? Float {
                return ["$f32": String(format: "%08x", number.bitPattern)]
            }
            if type(of: value) == CGFloat.self, let number = value as? CGFloat {
                return ["$f64": String(format: "%016llx", Double(number).bitPattern)]
            }
            if let value = value as? NSNumber {
                if CFGetTypeID(value) == CFBooleanGetTypeID() { return value.boolValue }
                switch String(cString: value.objCType) {
                case "f": return ["$f32": String(format: "%08x", value.floatValue.bitPattern)]
                case "d": return ["$f64": String(format: "%016llx", value.doubleValue.bitPattern)]
                default: return value
                }
            }
            if value is NSNull { return NSNull() }
            let mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .optional {
                guard let item = mirror.children.first else { return NSNull() }
                return try exactJSON(item.value, depth: depth + 1)
            }
            if mirror.displayStyle == .collection || mirror.displayStyle == .set {
                let rows = try mirror.children.map { try exactJSON($0.value, depth: depth + 1) }
                if mirror.displayStyle == .set {
                    return try rows.sorted { a, b in
                        let left = try JSONSerialization.data(withJSONObject: a, options: [.sortedKeys, .fragmentsAllowed])
                        let right = try JSONSerialization.data(withJSONObject: b, options: [.sortedKeys, .fragmentsAllowed])
                        return left.lexicographicallyPrecedes(right)
                    }
                }
                return rows
            }
            if mirror.displayStyle == .dictionary {
                var result: [String: Any] = [:]
                for entry in mirror.children {
                    let pair = Array(Mirror(reflecting: entry.value).children)
                    guard pair.count == 2, let key = pair[0].value as? String, result[key] == nil else {
                        throw Failure.unsupportedValue("dictionary key")
                    }
                    result[key] = try exactJSON(pair[1].value, depth: depth + 1)
                }
                return result
            }
            if let raw = value as? any RawRepresentable { return try exactJSON(raw.rawValue, depth: depth + 1) }
            if mirror.displayStyle == .enum, mirror.children.isEmpty { return ["$enum": String(describing: value)] }
            if mirror.displayStyle == .class {
                let object = value as AnyObject, key = ObjectIdentifier(object)
                if let old = objectOrdinals[key] { return ["$objectRef": "object-\(old)"] }
                let ordinal = retainedObjects.count, id = "object-\(ordinal)"
                objectOrdinals[key] = ordinal; retainedObjects.append(object)
                var fields: [String: Any] = [:]
                for (index, child) in mirror.children.enumerated() {
                    fields[child.label ?? String(index)] = try exactJSON(child.value, depth: depth + 1)
                }
                let data = try JSONSerialization.data(withJSONObject: ["objectID": id,
                    "type": String(reflecting: type(of: value)), "fields": fields], options: [.sortedKeys])
                var descriptor = try writeDataLocked(stage: "objects", name: id + ".json", data: data,
                    encoding: "per-invocation-object-identity-tagged-json-v1")
                descriptor["objectID"] = id; objectDefinitions.append(descriptor)
                return ["$objectRef": id]
            }
            guard mirror.displayStyle == .struct || mirror.displayStyle == .tuple || mirror.displayStyle == .class ||
                    mirror.displayStyle == .enum else { throw Failure.unsupportedValue(String(reflecting: type(of: value))) }
            var result: [String: Any] = [:]
            for (index, child) in mirror.children.enumerated() {
                if child.label == "alternateRecognitionPolygon",
                   let detector = value as? NativeCoreMLDetectionBox, detector.alternateRecognitionPolygon == nil {
                    continue
                }
                result[child.label ?? String(index)] = try exactJSON(child.value, depth: depth + 1)
            }
            return result
        }
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Only a complete exact-contract transaction with every byte unchanged is
    /// resumable. An incomplete/unknown/legacy bank is evidence, never a cache hit.
    static func canResume(directory: URL, sourceURL: URL, contract: Contract) throws -> Bool {
        let path = directory.appendingPathComponent("module-bank.json")
        guard contract.identityComplete, FileManager.default.fileExists(atPath: path.path) else { return false }
        guard try HostRenderProvenance.fileSHA256(sourceURL) == contract.sourceEncodedSHA256 else { throw Failure.sourceBinding }
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any],
              value["schema"] as? String == "aidoku-host-module-bank-v1", value["complete"] as? Bool == true,
              value["contractSHA256"] as? String == digest(try contract.data()),
              let relativeContract = value["contractPath"] as? String,
              let stored = value["contract"] as? [String: Any],
              let availability = value["availability"] as? [String: [String: Any]],
              let artifacts = value["artifacts"] as? [[String: Any]] else { return false }
        let decoded = try JSONDecoder().decode(Contract.self, from: JSONSerialization.data(withJSONObject: stored))
        guard decoded == contract, contract.requiredStages.allSatisfy({ availability[$0]?["status"] as? String == "observed" }) else { return false }
        guard contract.requiredStages.allSatisfy({ stage in artifacts.contains { $0["stage"] as? String == stage } }) else { return false }
        func local(_ relative: String) throws -> URL {
            guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { throw Failure.invalidPath }
            let path = directory.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
            guard path.path.hasPrefix(directory.standardizedFileURL.resolvingSymlinksInPath().path + "/") else { throw Failure.invalidPath }
            return path
        }
        guard try Data(contentsOf: local(relativeContract)) == contract.data() else { return false }
        let contractURL = try local(relativeContract)
        let namespace = contractURL.deletingLastPathComponent()
        guard relativeContract.hasPrefix("transactions/"), contractURL.lastPathComponent == "contract.json",
              try Data(contentsOf: namespace.appendingPathComponent("manifest.json")) == Data(contentsOf: path) else { return false }
        for artifact in artifacts {
            guard let name = artifact["path"] as? String, let expected = artifact["SHA256"] as? String,
                  let count = artifact["bytes"] as? Int else { return false }
            let file = artifact["external"] as? Bool == true ? URL(fileURLWithPath: name) : try local(name)
            if artifact["external"] as? Bool != true,
               file.deletingLastPathComponent() != namespace { return false }
            guard try file.resourceValues(forKeys: [.fileSizeKey]).fileSize == count,
                  try HostRenderProvenance.fileSHA256(file) == expected else { return false }
        }
        return true
    }
}

@available(macOS 15.0, *)
extension HostModuleBank.Session {
    var rawObserver: NativeOCRRawModuleObservation.Observer {
        .init(metadata: .init(sourceEncodedSHA256: contract.sourceEncodedSHA256,
            configurationSHA256: contract.configurationSHA256, producerSHA256: contract.producerSHA256,
            modelSHA256: contract.modelSHA256), receive: { [self] event in
                do { try recordRawModule(event) }
                catch { recordFailure("raw module export failed: \(error)") }
            })
    }

    var recognitionObserver: NativeCoreMLRecognitionObservations {
        .init(observer: { [self] event in
            do { try recordRecognition(event) }
            catch { recordFailure("REC export failed: \(error)"); throw error }
        })
    }

    func recordRawModule(_ event: NativeOCRRawModuleObservation.Event) throws {
        guard event.binding.sourceImageIdentity == contract.sourceImageIdentity,
              event.binding.width == contract.width, event.binding.height == contract.height,
              event.metadata.sourceEncodedSHA256 == contract.sourceEncodedSHA256,
              event.metadata.configurationSHA256 == contract.configurationSHA256,
              event.metadata.producerSHA256 == contract.producerSHA256,
              event.metadata.modelSHA256 == contract.modelSHA256 else { throw HostModuleBank.Failure.sourceBinding }
        let context: [String: Any] = ["binding": event.binding, "metadata": event.metadata]
        func value(_ payload: [String: Any]) -> [String: Any] {
            context.merging(payload) { _, new in new }
        }
        switch event.payload {
        case .originalDetector(let boxes):
            try writeJSON(stage: "originalDetector", value: value(["boxes": boxes]), records: boxes.count)
        case .proposals(let bank):
            try writeJSON(stage: "proposals", value: value(["bank": bank]), records: bank.individuals.count)
        case .bboxAdmission(let bank, let report):
            try writeJSON(stage: "bboxAdmission", value: value(["bank": bank, "report": report]), records: bank.individuals.count)
        case .preRecognition(let input, let scheduled, let matrix, let report):
            let artifact = try writeFloat64(stage: "preRecognition", name: "source165.f64le",
                data: matrix.bytes, rows: matrix.rows, columns: matrix.columns)
            try writeJSON(stage: "preRecognition", value: value(["input": input, "scheduled": scheduled,
                "source165": artifact, "report": report as Any? ?? NSNull()]), records: scheduled.individuals.count)
        case .postRecognition(let scheduled, let input, let reads, let indices, let prefix, let matrix):
            let prefixArtifact = try writeFloat64(stage: "postRecognition", name: "accepted165.f64le",
                data: prefix.bytes, rows: prefix.rows, columns: prefix.columns)
            let artifact = try writeFloat64(stage: "postRecognition", name: "source166.f64le",
                data: matrix.bytes, rows: matrix.rows, columns: matrix.columns)
            try writeJSON(stage: "postRecognition", value: value(["scheduled": scheduled, "input": input,
                "reads": reads, "source165Indices": indices, "accepted165": prefixArtifact, "source166": artifact]), records: reads.count)
        case .deduplication(let input, let output, let report):
            try writeJSON(stage: "deduplication", value: value(["input": input, "output": output, "report": report]),
                records: output.individuals.count)
        case .acceptedMembership(let archive):
            try writeJSON(stage: "acceptedMembership", value: value(["tables": archive.tables, "outputs": archive.outputs,
                "tableAuthority": "actual immutable original accepted tables; survivors do not replace original packets"]),
                records: archive.outputs.count)
        case .unavailable(let stage, let reason):
            unavailable(stage: stage.rawValue, reason: reason.rawValue)
        }
    }

    func recordRecognition(_ event: NativeCoreMLRecognitionObservations.Event) throws {
        let request: NativeCoreMLRecognitionObservations.Request
        switch event {
        case .began(let value, _), .finished(let value, _), .requested(let value, _): request = value
        case .decoded(let value): request = value.request
        }
        let key = "\(request.requestID.utf8.count):\(request.requestID):\(request.generation):" +
            "\(request.callerConfidenceThreshold.bitPattern):\(request.appliedConfidenceThreshold.bitPattern)"
        try lock.withLock {
            try requireOpen()
            switch event {
            case .began(_, let count):
                guard count >= 0, recognitionPasses[key] == nil else { throw HostModuleBank.Failure.contract }
                recognitionPasses[key] = .init(expected: count)
                // These are genuinely observed empty streams, not invented
                // requests/decodes. No began event means no empty artifact.
                _ = try streamLocked("recRequested"); _ = try streamLocked("recDecoded")
            case .requested:
                guard var pass = recognitionPasses[key], !pass.finished, pass.requested < pass.expected else {
                    throw HostModuleBank.Failure.contract
                }
                pass.requested += 1; recognitionPasses[key] = pass
            case .decoded:
                guard var pass = recognitionPasses[key], !pass.finished, pass.decoded < pass.requested else {
                    throw HostModuleBank.Failure.contract
                }
                pass.decoded += 1; recognitionPasses[key] = pass
            case .finished(_, let count):
                guard var pass = recognitionPasses[key], !pass.finished, pass.requested == pass.expected,
                      count == pass.decoded else { throw HostModuleBank.Failure.contract }
                pass.finished = true; recognitionPasses[key] = pass
            }
        }
        switch event {
        case .began(let request, let count):
            try appendJSON(stage: "recLifecycle", value: ["event": "began", "request": request, "requestedRegions": count])
        case .finished(let request, let count):
            try appendJSON(stage: "recLifecycle", value: ["event": "finished", "request": request, "decodedRegions": count])
        case .requested(let request, let region):
            try appendJSON(stage: "recRequested", value: ["request": request, "region": region,
                "coordinateAuthority": "actual supplied recognition crop/sourceIndex; not a fabricated original DET ordinal"])
        case .decoded(let decoded):
            try appendJSON(stage: "recDecoded", value: ["observation": decoded,
                "greedyAvailability": decoded.greedyObservation == nil ? "unavailable" : "observed",
                "tokenAuthority": "actual pre-admission final tokens and optional pre-ngram greedy tokens; nil is not empty"])
        }
    }
}
