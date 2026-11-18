import CoreGraphics
import Foundation

/// Source-bound CPU replay of OBSERVED crops. This is not a detector: no global
/// DB probability map is reconstructed and changed upstream geometry/config is
/// unsupported. A loaded Page is reusable across scalar-policy sweeps, retaining
/// only typed banks, actual reads and original packets, not duplicated JSON.
@available(macOS 15.0, *)
enum HostObservedOCRReplay {
    typealias G = NativeOCRIndividualGeometryHypotheses
    enum Failure: Error { case binding, corrupt, unsupportedGeometry, unobservedCrop }
    enum SourceAuthority: String, Sendable {
        case encodedAndRGBVerified
        case rootPinnedProducerObservation
    }
    enum PreRecognition: Sendable {
        case observedScheduled
        case allPostBBox
        case model(NativeOCRPreRecognitionFilter.Model)
    }
    struct Result: Sendable {
        let lines: [NativeCoreMLOCRLine]
        let reads: [NativeCoreMLRecognizedRegion]
        let geometry: G.Output
        let recognitionAdmission: NativeSimpleRecognitionAdmission.Report?
        let deduplication: NativeOCRPostRecognitionDeduplication.Report
        let scheduledSource165Indices: [Int]
        /// Replay table ordinal -> original observed packet ordinal. Scalar
        /// deletion creates a derived ingress table, exactly as current runtime
        /// binds packets AFTER its gate; the original table is never mutated.
        let originalPacketOrdinals: [Int]
        let originalPacketTable: NativeOCRAcceptedSource.PacketTable
        let sourceAuthority: SourceAuthority
        let sourceEncodedSHA256: String
        let upstreamConfigurationSHA256: String
        let producerSHA256: String
        let newCorePredictions = 0
        let globalDBMapAvailable = false
    }
    private struct Point: Decodable {
        let x: Double
        let y: Double
        var cg: CGPoint { .init(x: x, y: y) }
    }
    private struct Rectangle: Decodable {
        let origin: Point
        let size: Size
        struct Size: Decodable { let width: Double; let height: Double }
        var cg: CGRect { .init(x: origin.x, y: origin.y, width: size.width, height: size.height) }
    }
    private struct Detector: Decodable {
        let polygon: [Point]
        let score: Double
        let erasurePolygons: [[Point]]
        let recognitionPolygon: [Point]?
        let isThinFinePrintRecovery: Bool
        let finePrintRetryPolygons: [[Point]]
        let recognitionColumnEvidence: NativeOCRDetectorColumnEvidence?
        let detectorSeedEvidence: NativeOCRDetectorSeedEvidence?
        var native: NativeCoreMLDetectionBox {
            .init(polygon: polygon.map(\.cg), score: score, erasurePolygons: erasurePolygons.map { $0.map(\.cg) },
                recognitionPolygon: recognitionPolygon?.map(\.cg), isThinFinePrintRecovery: isThinFinePrintRecovery,
                finePrintRetryPolygons: finePrintRetryPolygons.map { $0.map(\.cg) },
                recognitionColumnEvidence: recognitionColumnEvidence, detectorSeedEvidence: detectorSeedEvidence)
        }
    }
    private struct Packet: Decodable {
        let polygon: [Point]
        let text: String
        let score: Double
        let orientation: String
        let orientationIsEstimated: Bool
        let sourceTileBounds: Rectangle?
        let erasurePolygons: [[Point]]
        let detectorSeedEvidence: [NativeOCRDetectorSeedEvidence]?
        let detectorSignals: [Double]?
        let layoutPolygon: [Point]?
        var native: NativeOCRAcceptedSource.Packet {
            .init(polygon: polygon.map(\.cg), text: text, score: score,
                orientation: BrowserOCRSourceOrientation(tolerantRawValue: orientation),
                orientationIsEstimated: orientationIsEstimated, sourceTileBounds: sourceTileBounds?.cg,
                erasurePolygons: erasurePolygons.map { $0.map(\.cg) }, detectorSeedEvidence: detectorSeedEvidence,
                detectorSignals: detectorSignals, layoutPolygon: layoutPolygon?.map(\.cg))
        }
    }
    private struct Read: Decodable {
        let sourceIndex: Int
        let polygon: [Point]
        let text: String
        let confidence: Double
        let tokenObservations: [Token]
        var native: NativeCoreMLRecognizedRegion {
            .init(sourceIndex: sourceIndex, polygon: polygon.map(\.cg), text: text, confidence: confidence,
                tokenObservations: tokenObservations.map(\.native))
        }
    }
    private struct Token: Decodable {
        let text: String
        let confidence: Double
        let emissionSpan: Span?
        struct Span: Decodable {
            let steps: Steps
            let timeStepCount: Int
            let precedingBlankSteps: Int
            struct Steps: Decodable { let lowerBound: Int; let upperBound: Int }
            private enum CodingKeys: String, CodingKey { case steps, timeStepCount, precedingBlankSteps }
            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                steps = try c.decode(Steps.self, forKey: .steps)
                timeStepCount = try c.decode(Int.self, forKey: .timeStepCount)
                precedingBlankSteps = try c.decode(Int.self, forKey: .precedingBlankSteps)
                guard steps.lowerBound >= 0, steps.upperBound >= steps.lowerBound,
                      timeStepCount >= steps.upperBound, precedingBlankSteps >= 0 else { throw Failure.corrupt }
            }
        }
        var native: NativeCoreMLCTCTokenObservation {
            .init(text: text, confidence: confidence, emissionSpan: emissionSpan.map {
                .init(steps: $0.steps.lowerBound..<$0.steps.upperBound, timeStepCount: $0.timeStepCount,
                    precedingBlankSteps: $0.precedingBlankSteps)
            })
        }
    }
    private struct Region: Decodable {
        let sourceIndex: Int
        let polygon: [Point]
        let samplingPolygon: [Point]?
        let minimumSequenceWidth: Int
        let useProvidedOrder: Bool
        let photometricMode: String
        let isThinFinePrintRecovery: Bool
        let finePrintRetryPolygons: [[Point]]
        let recognitionColumnEvidence: NativeOCRDetectorColumnEvidence?
        var native: NativeCoreMLRecognitionRegion {
            .init(sourceIndex: sourceIndex, polygon: polygon.map(\.cg), samplingPolygon: samplingPolygon?.map(\.cg),
                isThinFinePrintRecovery: isThinFinePrintRecovery, finePrintRetryPolygons: finePrintRetryPolygons.map { $0.map(\.cg) },
                useProvidedOrder: useProvidedOrder, minimumSequenceWidth: minimumSequenceWidth,
                recognitionColumnEvidence: recognitionColumnEvidence,
                photometricMode: NativeCoreMLRecognitionPhotometricMode(rawValue: photometricMode)!)
        }
    }
    private struct Decoded: Decodable {
        let admitted: Bool
        let finalText: String
        let finalConfidence: Double
        let region: Region
        let request: Request
        let tokenObservations: [Token]
        let greedyObservation: Greedy?
        let cacheHit: Bool
        let reason: String
        struct Greedy: Decodable { let text: String; let confidence: Double; let tokenObservations: [Token]? }
        struct Request: Decodable {
            let requestID: String
            let generation: UInt64
            let callerConfidenceThreshold: Double
            let appliedConfidenceThreshold: Double
        }
        var native: NativeCoreMLRecognitionObservations.Decoded {
            .init(request: .init(requestID: request.requestID, generation: request.generation,
                callerConfidenceThreshold: request.callerConfidenceThreshold, appliedConfidenceThreshold: request.appliedConfidenceThreshold),
                region: region.native, finalText: finalText, finalConfidence: finalConfidence,
                tokenObservations: tokenObservations.map(\.native), greedyObservation: greedyObservation.map {
                    .init(text: $0.text, confidence: $0.confidence, tokenObservations: $0.tokenObservations?.map(\.native))
                }, cacheHit: cacheHit, admitted: admitted, reason: NativeCoreMLRecognitionObservations.AdmissionReason(rawValue: reason)!)
        }
    }

    final class Page: Sendable {
        let contract: HostModuleBank.Contract
        let originalSourceURL: URL
        let sourceAuthority: SourceAuthority
        let originalDetectors: [NativeCoreMLDetectionBox]
        let postBBox: G.Output
        let observedScheduled: G.Output
        let source165: [[Double]]
        let observedSource165Indices: [Int]
        let originalTable: NativeOCRAcceptedSource.PacketTable
        let originalTableOperationID: String?
        let observedAPIReads: [NativeCoreMLRecognizedRegion]
        let observedDecodes: [NativeCoreMLRecognitionObservations.Decoded]

        fileprivate init(contract: HostModuleBank.Contract, sourceURL: URL, detectors: [NativeCoreMLDetectionBox],
                         postBBox: G.Output, scheduled: G.Output,
                         source165: [[Double]], preIndices: [Int], table: NativeOCRAcceptedSource.PacketTable,
                         reads: [NativeCoreMLRecognizedRegion], decodes: [NativeCoreMLRecognitionObservations.Decoded],
                         originalOperationID: String? = nil, sourceAuthority: SourceAuthority = .encodedAndRGBVerified) {
            self.contract = contract; self.postBBox = postBBox; observedScheduled = scheduled
            originalSourceURL = sourceURL; originalDetectors = detectors
            self.sourceAuthority = sourceAuthority
            self.source165 = source165; observedSource165Indices = preIndices
            originalTable = table; observedAPIReads = reads
            originalTableOperationID = originalOperationID
            observedDecodes = decodes
        }

        /// Restore only actual captured grouped membership, never infer a table
        /// from envelopes or text. Supports the same immutable source operation
        /// observed by this page; a different recovery operation is unsupported.
        func restoringCapturedMetadata(_ value: Any) throws -> NativeOCRSourceMetadata {
            guard let object = value as? [String: Any], let member = object["membership"] as? [String: Any],
                  let table = member["table"] as? [String: Any],
                  table["operationID"] as? String == originalTableOperationID,
                  table["width"] as? Int == contract.width, table["height"] as? Int == contract.height,
                  let packets = table["packets"] as? [Any], packets.count == originalTable.packets.count,
                  let body = member["body"] as? [Int], let readings = member["readings"] as? [Int],
                  let unknown = member["unknownDedup"] as? [Int], let untracked = member["hasUntrackedInputs"] as? Bool,
                  [body, readings, unknown].allSatisfy({ Set($0).count == $0.count && $0.allSatisfy(originalTable.packets.indices.contains) }) else {
                throw Failure.binding
            }
            func decodeOptional<T: Decodable>(_ type: T.Type, _ value: Any?) throws -> T? {
                guard let value, !(value is NSNull) else { return nil }
                return try HostTaggedObservationDecoder.decode(type, value: value, blob: { _ in throw Failure.corrupt })
            }
            let layout = try decodeOptional([Point].self, object["layoutPolygon"])?.map(\.cg)
            let signals = try decodeOptional([Double].self, object["detectorSignals"])
            return .init(.init(table: originalTable, body: Set(body), readings: Set(readings), unknownDedup: Set(unknown),
                hasUntrackedInputs: untracked), layoutPolygon: layout, detectorSignals: signals)
        }

        /// A changed pre-gate may DELETE observed crops. It may not manufacture
        /// reads for a formerly unscheduled crop, even if its165 vector exists.
        func replay(preRecognition: PreRecognition = .observedScheduled,
                    recognitionAdmission: NativeSimpleRecognitionAdmission.Configuration? = nil,
                    deduplication: NativeSimpleOCRDedup.Configuration? = nil) throws -> Result {
            let selected: [Int]
            switch preRecognition {
            case .observedScheduled: selected = observedSource165Indices
            case .allPostBBox: selected = Array(postBBox.individuals.indices)
            case .model(let model):
                selected = try NativeOCRPreRecognitionFilter.apply(postBBox, features: source165, model: model).report.keptIndices
            }
            guard Set(selected).isSubset(of: Set(observedSource165Indices)) else { throw Failure.unobservedCrop }
            let allowed = Set(selected)
            var reads = observedAPIReads.filter { allowed.contains(observedSource165Indices[$0.sourceIndex]) }
            let admission: NativeSimpleRecognitionAdmission.Report?
            if let configuration = recognitionAdmission {
                let result = try NativeSimpleRecognitionAdmission.apply(reads, source165: source165,
                    source165Indices: observedSource165Indices, configuration: configuration)
                reads = result.reads; admission = result.report
            } else { admission = nil }
            let recognized = G.selecting(observedScheduled, indices: reads.map(\.sourceIndex))
            let dedup: NativeOCRPostRecognitionDeduplication.Result
            if let configuration = deduplication {
                dedup = try NativeSimpleOCRDedup.apply(recognized, reads: reads, configuration: configuration)
            } else {
                let features = try NativeOCRPostRecognitionFeatures.extract(input: recognized,
                    source165: reads.map { source165[observedSource165Indices[$0.sourceIndex]] },
                    recognitionConfidences: reads.map(\.confidence))
                dedup = try NativeOCRPostRecognitionDeduplication.apply(recognized, source166: features)
            }
            let originalOrdinal = Dictionary(uniqueKeysWithValues: observedAPIReads.enumerated().map { ($0.element.sourceIndex, $0.offset) })
            let originalOrdinals = try reads.map { read -> Int in
                guard let ordinal = originalOrdinal[read.sourceIndex] else { throw Failure.binding }
                return ordinal
            }
            let table = originalOrdinals == Array(originalTable.packets.indices) ? originalTable :
                NativeOCRAcceptedSource.PacketTable(packets: originalOrdinals.map { originalTable.packets[$0] },
                    width: contract.width, height: contract.height)
            let lines = dedup.report.keptIndices.map { index -> NativeCoreMLOCRLine in
                let packet = table.packets[index]
                let aliases = Set(dedup.report.replacements.filter { $0.retainedIndex == index }.map(\.inputIndex))
                return .init(polygon: packet.polygon, text: packet.text, score: packet.score,
                    orientation: packet.orientation, orientationIsEstimated: packet.orientationIsEstimated,
                    sourceTileBounds: packet.sourceTileBounds, erasurePolygons: packet.erasurePolygons,
                    detectorSeedEvidence: packet.detectorSeedEvidence,
                    acceptedSource: .init(.init(table: table, body: [index], readings: [], unknownDedup: aliases,
                        hasUntrackedInputs: false), layoutPolygon: packet.layoutPolygon, detectorSignals: packet.detectorSignals))
            }
            return .init(lines: lines, reads: reads, geometry: dedup.output, recognitionAdmission: admission,
                deduplication: dedup.report, scheduledSource165Indices: selected,
                originalPacketOrdinals: originalOrdinals, originalPacketTable: originalTable, sourceAuthority: sourceAuthority,
                sourceEncodedSHA256: contract.sourceEncodedSHA256,
                upstreamConfigurationSHA256: contract.configurationSHA256!, producerSHA256: contract.producerSHA256!)
        }
    }

    /// Bounded resident observation snapshots, not a path/mtime attestation
    /// cache. A hit still hashes current source bytes and actual supplied RGB;
    /// it then serves the previously authenticated IMMUTABLE typed snapshot.
    /// Disk artifact edits are never read through that snapshot. A new manifest
    /// or any changed expected contract forces full load/authentication again.
    final class Cache: @unchecked Sendable {
        struct Statistics: Sendable { let hits: Int; let misses: Int; let evictions: Int; let entries: Int }
        private struct Entry { let key: String; let page: Page }
        private let lock = NSLock()
        private let maximumEntries: Int
        private var entries: [Entry] = []
        private var hits = 0, misses = 0, evictions = 0
        init(maximumEntries: Int = 2) { self.maximumEntries = max(0, min(16, maximumEntries)) }
        var statistics: Statistics {
            lock.lock(); defer { lock.unlock() }
            return .init(hits: hits, misses: misses, evictions: evictions, entries: entries.count)
        }
        func removeAll() { lock.lock(); entries.removeAll(); lock.unlock() }
        func load(directory: URL, sourceURL: URL, original: CGImage, expected: HostModuleBank.Contract) throws -> Page {
            let manifest = directory.appendingPathComponent("module-bank.json")
            let key = directory.standardizedFileURL.resolvingSymlinksInPath().path + "#" +
                (try HostRenderProvenance.fileSHA256(manifest)) + "#" + sourceURL.standardizedFileURL.resolvingSymlinksInPath().path
            lock.lock()
            let index = entries.firstIndex { $0.key == key && $0.page.contract == expected }
            let cached = index.map { entries[$0].page }
            lock.unlock()
            if let cached {
                guard original.width == expected.width, original.height == expected.height,
                      let encodedBytes = try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      encodedBytes >= 0, encodedBytes <= 64 * 1024 * 1024,
                      try HostRenderProvenance.fileSHA256(sourceURL) == expected.sourceEncodedSHA256,
                      try NativeRFDETRSourceImage.decode(original).identity == expected.sourceImageIdentity else { throw Failure.binding }
                lock.lock(); defer { lock.unlock() }
                if let index = entries.firstIndex(where: { $0.page === cached }) {
                    entries.append(entries.remove(at: index))
                }
                hits += 1
                return cached
            }
            lock.lock(); misses += 1; lock.unlock()
            let page = try HostObservedOCRReplay.load(directory: directory, sourceURL: sourceURL, original: original, expected: expected)
            lock.lock(); defer { lock.unlock() }
            if maximumEntries > 0 {
                entries.removeAll { $0.key == key }
                entries.append(.init(key: key, page: page))
                while entries.count > maximumEntries { entries.removeFirst(); evictions += 1 }
            }
            return page
        }
    }

    static func load(directory: URL, sourceURL: URL, original: CGImage,
                     expected: HostModuleBank.Contract) throws -> Page {
        guard expected.identityComplete,
              original.width == expected.width, original.height == expected.height,
              let encodedBytes = try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              encodedBytes >= 0, encodedBytes <= 64 * 1024 * 1024 else { throw Failure.binding }
        // cachedBinding already hashes encoded bytes and compares both actual
        // RGB decodes. Reuse THAT attestation instead of hashing/decoding a third
        // time merely to obtain the same identity.
        let sourceBinding = try NativeMainEnsembleOCREvidence.cachedBinding(original: original, encodedSource: Data(contentsOf: sourceURL),
            expectedSourceSHA256: expected.sourceEncodedSHA256)
        guard sourceBinding.contentIdentity == expected.sourceImageIdentity,
              sourceBinding.width == expected.width, sourceBinding.height == expected.height,
              sourceBinding.verifiedEncodedSourceSHA256 == expected.sourceEncodedSHA256 else { throw Failure.binding }
        return try decodeBank(directory: directory, sourceURL: sourceURL, expected: expected, sourceAuthority: .encodedAndRGBVerified)
    }

    /// Geometry/crop/decoder consumers can use a ROOT-PINNED actual producer
    /// receipt instead of re-rasterizing the same original RGB for every scalar
    /// sweep. The digest MUST come from the immutable verified central results,
    /// not be computed from the candidate file and called an expected identity.
    /// This does not attest a newly supplied CGImage; pixel-consuming callers
    /// still use load(original:) or the Reader ingress's explicit RGB guard.
    static func loadObservedBank(directory: URL, sourceURL: URL, expected: HostModuleBank.Contract,
                                 expectedManifestSHA256: String) throws -> Page {
        guard expected.identityComplete, expectedManifestSHA256.count == 64,
              expectedManifestSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let count = try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              count >= 0, count <= 64 * 1024 * 1024,
              try HostRenderProvenance.fileSHA256(sourceURL) == expected.sourceEncodedSHA256,
              try HostRenderProvenance.fileSHA256(directory.appendingPathComponent("module-bank.json")) == expectedManifestSHA256 else {
            throw Failure.binding
        }
        return try decodeBank(directory: directory, sourceURL: sourceURL, expected: expected, sourceAuthority: .rootPinnedProducerObservation)
    }

    private static func decodeBank(directory: URL, sourceURL: URL, expected: HostModuleBank.Contract,
                                   sourceAuthority: SourceAuthority) throws -> Page {
        let manifestURL = directory.appendingPathComponent("module-bank.json")
        guard let count = try manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              count >= 0, count <= 64 * 1024 * 1024 else { throw Failure.corrupt }
        let manifestBytes = try Data(contentsOf: manifestURL)
        guard let manifest = try JSONSerialization.jsonObject(with: manifestBytes) as? [String: Any],
              manifest["schema"] as? String == "aidoku-host-module-bank-v1",
              manifest["producerIdentityComplete"] as? Bool == true,
              let failures = manifest["failures"] as? [String], failures.isEmpty || failures == ["page transaction did not finish"],
              let storedContract = manifest["contract"] as? [String: Any],
              let contractPath = manifest["contractPath"] as? String,
              let artifacts = manifest["artifacts"] as? [[String: Any]],
              let availability = manifest["availability"] as? [String: [String: Any]] else { throw Failure.corrupt }
        let decodedContract = try JSONDecoder().decode(HostModuleBank.Contract.self,
            from: JSONSerialization.data(withJSONObject: storedContract))
        guard decodedContract == expected else { throw Failure.binding }
        guard expected.requiredStages.allSatisfy({ stage in
            availability[stage]?["status"] as? String == "observed" &&
                artifacts.contains(where: { $0["stage"] as? String == stage })
        }) else { throw Failure.corrupt }
        let base = directory.standardizedFileURL.resolvingSymlinksInPath()
        func local(_ path: String) throws -> URL {
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw Failure.corrupt }
            let result = base.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
            guard result.path.hasPrefix(base.path + "/") else { throw Failure.corrupt }
            return result
        }
        let contractURL = try local(contractPath), namespace = contractURL.deletingLastPathComponent()
        let contractBytes = try Data(contentsOf: contractURL)
        guard namespace.deletingLastPathComponent() == base.appendingPathComponent("transactions"),
              HostModuleBank.digest(contractBytes) == manifest["contractSHA256"] as? String,
              try JSONDecoder().decode(HostModuleBank.Contract.self, from: contractBytes) == expected,
              try Data(contentsOf: namespace.appendingPathComponent("manifest.json")) == manifestBytes else { throw Failure.corrupt }
        var index: [String: [String: Any]] = [:]
        for artifact in artifacts {
            guard let path = artifact["path"] as? String, artifact["external"] as? Bool != true,
                  let count = artifact["bytes"] as? Int, count >= 0, count <= 64 * 1024 * 1024,
                  let hash = artifact["SHA256"] as? String else { throw Failure.corrupt }
            let file = try local(path)
            guard file.deletingLastPathComponent() == namespace,
                  try file.resourceValues(forKeys: [.fileSizeKey]).fileSize == count,
                  try HostRenderProvenance.fileSHA256(file) == hash, index[path] == nil else { throw Failure.corrupt }
            index[path] = artifact
        }
        func data(_ descriptor: [String: Any]) throws -> Data {
            guard let path = descriptor["path"] as? String, let registered = index[path],
                  descriptor["SHA256"] as? String == registered["SHA256"] as? String else { throw Failure.corrupt }
            return try Data(contentsOf: local(path))
        }
        func matrix(_ descriptor: [String: Any], columns: Int) throws -> [[Double]] {
            guard let shape = descriptor["shape"] as? [Int], shape.count == 2, shape[1] == columns,
                  shape[0] >= 0, shape[0] <= (64 * 1024 * 1024) / columns / 8 else { throw Failure.corrupt }
            let raw = try data(descriptor)
            guard raw.count == shape[0] * columns * 8 else { throw Failure.corrupt }
            return raw.withUnsafeBytes { bytes in
                (0..<shape[0]).map { row in (0..<columns).map { column in
                    Double(bitPattern: UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: (row * columns + column) * 8, as: UInt64.self)))
                } }
            }
        }
        func object(stage: String) throws -> [String: Any] {
            guard availability[stage]?["status"] as? String == "observed" else { throw Failure.corrupt }
            let found = artifacts.filter { $0["stage"] as? String == stage && ($0["path"] as? String)?.hasSuffix(".json") == true }
            guard found.count == 1, let value = try JSONSerialization.jsonObject(with: data(found[0])) as? [String: Any] else { throw Failure.corrupt }
            return value
        }
        var loadedBlobs: [String: Data] = [:]
        func blob(_ value: Any) throws -> Data {
            guard let wrapper = value as? [String: Any], let descriptor = wrapper["$dataBlob"] as? [String: Any] else { throw Failure.corrupt }
            guard let path = descriptor["path"] as? String else { throw Failure.corrupt }
            if let existing = loadedBlobs[path] { return existing }
            let bytes = try data(descriptor)
            loadedBlobs[path] = bytes
            return bytes
        }
        func decode<T: Decodable>(_ type: T.Type, _ value: Any) throws -> T {
            try HostTaggedObservationDecoder.decode(type, value: value, blob: blob)
        }
        let pre = try object(stage: "preRecognition"), post = try object(stage: "postRecognition")
        let bbox = try object(stage: "bboxAdmission"), originalStage = try object(stage: "originalDetector")
        let authenticatedBinding = try decode(NativeOCRRawModuleObservation.Binding.self, pre["binding"] as Any)
        for stage in [pre, post, bbox, originalStage] {
            guard let binding = stage["binding"] as? [String: Any], let metadata = stage["metadata"] as? [String: Any],
                  binding["sourceImageIdentity"] as? String == expected.sourceImageIdentity,
                  binding["width"] as? Int == expected.width, binding["height"] as? Int == expected.height,
                  binding["sourceAnchorMode"] as? String == "source-anchor-fixed-prerec-v1",
                  metadata["sourceEncodedSHA256"] as? String == expected.sourceEncodedSHA256,
                  metadata["modelSHA256"] as? [String: String] == expected.modelSHA256,
                  metadata["configurationSHA256"] as? String == expected.configurationSHA256,
                  metadata["producerSHA256"] as? String == expected.producerSHA256 else { throw Failure.binding }
            guard try decode(NativeOCRRawModuleObservation.Binding.self, binding) == authenticatedBinding else { throw Failure.binding }
        }
        guard let binding = pre["binding"] as? [String: Any], let requestID = binding["requestID"] as? String,
              let descriptor = pre["source165"] as? [String: Any] else { throw Failure.corrupt }
        let features = try matrix(descriptor, columns: 165)
        let bank = try decode(G.Output.self, pre["input"] as Any), scheduled = try decode(G.Output.self, pre["scheduled"] as Any)
        let detectors = try decode([Detector].self, originalStage["boxes"] as Any).map(\.native)
        let postBank = try decode(G.Output.self, post["scheduled"] as Any), bboxBank = try decode(G.Output.self, bbox["bank"] as Any)
        guard bank.individuals == bboxBank.individuals, bank.individuals.count == features.count,
              scheduled.individuals == postBank.individuals else { throw Failure.unsupportedGeometry }
        let report = pre["report"] as? [String: Any]
        guard let preIndices = report?["keptIndices"] as? [Int], preIndices.count == scheduled.individuals.count,
              Set(preIndices).count == preIndices.count,
              preIndices.allSatisfy(bank.individuals.indices.contains),
              preIndices.enumerated().allSatisfy({ bank.individuals[$0.element] == scheduled.individuals[$0.offset] }) else { throw Failure.binding }
        let baselineReads = try decode([Read].self, post["reads"] as Any).map(\.native)
        guard let acceptedIndices = post["source165Indices"] as? [Int],
              acceptedIndices.count == baselineReads.count,
              baselineReads.allSatisfy({ preIndices.indices.contains($0.sourceIndex) }),
              zip(acceptedIndices, baselineReads).allSatisfy({ $0.0 == preIndices[$0.1.sourceIndex] }),
              let acceptedDescriptor = post["accepted165"] as? [String: Any],
              let measuredDescriptor = post["source166"] as? [String: Any] else { throw Failure.binding }
        let acceptedFeatures = try matrix(acceptedDescriptor, columns: 165)
        let measuredFeatures = try matrix(measuredDescriptor, columns: 166)
        guard acceptedFeatures.count == acceptedIndices.count,
              acceptedFeatures.enumerated().allSatisfy({ $0.element.map(\.bitPattern) == features[acceptedIndices[$0.offset]].map(\.bitPattern) }) else { throw Failure.binding }
        let recognized = G.selecting(scheduled, indices: baselineReads.map(\.sourceIndex))
        let expectedFeatures = try NativeOCRPostRecognitionFeatures.extract(input: recognized,
            source165: acceptedFeatures, recognitionConfidences: baselineReads.map(\.confidence))
        guard measuredFeatures.map({ $0.map(\.bitPattern) }) == expectedFeatures.map({ $0.map(\.bitPattern) }) else { throw Failure.binding }
        let recArtifacts = artifacts.filter { $0["stage"] as? String == "recDecoded" }
        guard recArtifacts.count == 1, availability["recDecoded"]?["status"] as? String == "observed" else { throw Failure.corrupt }
        let rows = try data(recArtifacts[0]).split(separator: 10).map { line -> [String: Any] in
            guard let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { throw Failure.corrupt }
            return object
        }
        let observations = try rows.map { try decode(Decoded.self, $0["observation"] as Any) }
        guard observations.count == scheduled.individuals.count,
              Set(observations.map { $0.request.generation }).count <= 1,
              Set(observations.map { $0.region.sourceIndex }).count == observations.count else { throw Failure.binding }
        for observation in observations {
            let region = observation.region
            guard observation.request.requestID == requestID, scheduled.individuals.indices.contains(region.sourceIndex),
                  NativeCoreMLRecognitionObservations.AdmissionReason(rawValue: observation.reason) != nil,
                  region.polygon.map({ G.Point(x: $0.x, y: $0.y) }) == scheduled.individuals[region.sourceIndex].polygon,
                  region.samplingPolygon == nil, region.minimumSequenceWidth == 0, !region.useProvidedOrder,
                  region.photometricMode == "original", !region.isThinFinePrintRecovery, region.finePrintRetryPolygons.isEmpty else {
                throw Failure.unsupportedGeometry
            }
        }
        let api = observations.filter(\.admitted).sorted { $0.region.sourceIndex < $1.region.sourceIndex }
        guard api.count == baselineReads.count, zip(api, baselineReads).allSatisfy({ observation, read in
            observation.region.sourceIndex == read.sourceIndex && observation.finalText.utf8.elementsEqual(read.text.utf8) &&
                observation.finalConfidence.bitPattern == read.confidence.bitPattern
        }) else { throw Failure.binding }
        let member = try object(stage: "acceptedMembership")
        guard let tables = member["tables"] as? [[String: String]], tables.count == (api.isEmpty ? 0 : 1) else { throw Failure.corrupt }
        var packets: [NativeOCRAcceptedSource.Packet] = []
        var originalOperationID: String?
        if let reference = tables.first?["$objectRef"] {
            let definitions = manifest["objectDefinitions"] as? [[String: Any]] ?? []
            guard let descriptor = definitions.first(where: { $0["objectID"] as? String == reference }),
                  let definition = try JSONSerialization.jsonObject(with: data(descriptor)) as? [String: Any],
                  let fields = definition["fields"] as? [String: Any], fields["width"] as? Int == expected.width,
                  fields["height"] as? Int == expected.height,
                  let operation = fields["operationID"] as? [String: String], let operationID = operation["$uuid"],
                  UUID(uuidString: operationID) != nil else { throw Failure.corrupt }
            originalOperationID = operationID
            let values = try decode([Packet].self, fields["packets"] as Any)
            guard values.allSatisfy({ BrowserOCRSourceOrientation(rawValue: $0.orientation) != nil }) else { throw Failure.corrupt }
            packets = values.map(\.native)
        }
        guard packets.count == baselineReads.count, zip(packets, baselineReads).allSatisfy({ packet, read in
            packet.polygon == read.polygon && packet.text.utf8.elementsEqual(read.text.utf8) && packet.score.bitPattern == read.confidence.bitPattern
        }) else { throw Failure.binding }
        let nativeDecodes = observations.map(\.native)
        let nativeReads = nativeDecodes.filter(\.admitted).sorted { $0.region.sourceIndex < $1.region.sourceIndex }.map {
            NativeCoreMLRecognizedRegion(sourceIndex: $0.region.sourceIndex, polygon: $0.region.polygon,
                text: $0.finalText, confidence: $0.finalConfidence, tokenObservations: $0.tokenObservations)
        }
        // Share actual decoded token buffers and immutable geometry subarrays
        // within this page, rather than retaining two separately parsed copies.
        return .init(contract: expected, sourceURL: sourceURL, detectors: detectors, postBBox: bank,
            scheduled: G.selecting(bank, indices: preIndices), source165: features, preIndices: preIndices,
            table: .init(packets: packets, width: expected.width, height: expected.height), reads: nativeReads,
            decodes: nativeDecodes, originalOperationID: originalOperationID, sourceAuthority: sourceAuthority)
    }
}
