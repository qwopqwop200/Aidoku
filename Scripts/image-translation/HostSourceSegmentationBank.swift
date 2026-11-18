import CoreGraphics
import CryptoKit
import Foundation

/// Strict, request-owned observation writer. No detector, inference, GT lookup,
/// AOT, provider, global registry or environment-driven page selection lives here.
/// The ordinary producer still has a nil observer and never constructs this type.
final class HostSourceSegmentationBank: @unchecked Sendable {
    enum Failure: Error {
        case invalidContract, invalidOwnerRoster, ownerNotPrepared, ambiguousOwner,
             duplicateOwner, invalidStage, invalidCoarseABI, budgetExceeded,
             existingDestination, incompletePage
    }
    struct Owner {
        let id: String
        let input: SourceNativeInput
    }
    struct Contract {
        let sourceIdentity: String
        let sourceEncodedSHA256: String
        let compiledSourceFingerprint: String
        /// Caller-bound digest of the ACTUAL compiled source snapshot, not a
        /// digest computed later from mutable checkout files by this writer.
        let compiledProducerSHA256: String
        let compiledSourceSHA256: [String: String]
        let modelBinding: [String: Any]
        let rfClassCoordinateFeatureSchema: [String: Any]
        let additionalConfiguration: [String: Any]
        let maximumPageBytes: Int
    }
    /// Called only after constructor RF exists; may attach immutable raw-RF
    /// archive and original encoded-source descriptors. No new model calls.
    typealias References = () throws -> [String: Any]
    /// Source-features owns exact reconstruction and compact OCR/word inputs.
    /// Hashes are supplied to avoid rehashing dense inputs in a second writer.
    typealias InputDescriptor = (_ ownerID: String, _ input: SourceNativeInput,
                                 _ packetDirectory: URL, _ hashes: [String: String]) throws -> [String: Any]

    private let lock = NSLock()
    private let directory: URL
    private let contract: Contract
    private let references: References
    private let inputDescriptor: InputDescriptor
    private let config: [String: Any]
    private let configSHA256: String
    private var prepared = false
    private var finished = false
    private var ownerBySignature: [String: String] = [:]
    private var plans: [[String: Any]] = []
    private var packets: [String: [String: Any]] = [:]
    private var bytesWritten = 0
    private var pageReferences: [String: Any] = [:]

    init(directory: URL, contract: Contract, references: @escaping References,
         inputDescriptor: @escaping InputDescriptor) throws {
        guard Self.hex(contract.sourceIdentity), Self.hex(contract.sourceEncodedSHA256),
              UInt16(0x0102).littleEndian == 0x0102,
              Self.hex(contract.compiledSourceFingerprint), Self.hex(contract.compiledProducerSHA256),
              !contract.compiledSourceSHA256.isEmpty, contract.compiledSourceSHA256.values.allSatisfy(Self.hex),
              !contract.modelBinding.isEmpty, !contract.rfClassCoordinateFeatureSchema.isEmpty, contract.maximumPageBytes > 0,
              !NativeSourceSegmentationExecution.completedOnlyEnabled,
              !NativeSelectedSourceSegmentationProducer.connectedWeakEnabled else { throw Failure.invalidContract }
        self.directory = directory
        self.contract = contract
        self.references = references
        self.inputDescriptor = inputDescriptor
        config = ["activePolicySHA256": NativeSourceSegmentationExecution.policySHA256,
            "activePolicyRevision": NativeSourceSegmentationExecution.policyRevision,
            "maximumCropPixels": 1_500_000, "sourceContextFractionPerSide": 0.15,
            "jointComputationRadius": NativeSegmentationFinalPolicy.requiredJointRadius,
            "primaryFeatures": 62, "boundaryFeatures": 60, "contextFeatures": 83, "auxiliaryFeatures": 78,
            "rfClassCoordinateFeatureSchema": contract.rfClassCoordinateFeatureSchema,
            "additionalConfiguration": contract.additionalConfiguration]
        configSHA256 = Self.hash(try Self.json(config))
        _ = try Self.json(contract.modelBinding)
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw Failure.existingDestination }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Feed the ACTUAL factory Owner.input records and explicit live item IDs.
    /// The stable signature is source+geometry+original-text hash+font bits;
    /// no array ordinal, IoU, label ID or guessed owner association is accepted.
    func prepare(_ owners: [Owner]) throws {
        lock.lock(); defer { lock.unlock() }
        guard !prepared, !finished, owners.count <= 256,
              Set(owners.map(\.id)).count == owners.count else { throw Failure.invalidOwnerRoster }
        var expectedRawBytes = 0
        var signatures: [String: String] = [:]
        var roster: [[String: Any]] = []
        for owner in owners {
            let input = owner.input
            guard !owner.id.isEmpty, owner.id.utf8.count <= 1024, input.sourceIdentity == contract.sourceIdentity,
                  input.width > 0, input.height > 0, input.width <= 1_500_000 / input.height else { throw Failure.invalidOwnerRoster }
            let signature = try Self.signature(input)
            guard signatures[signature] == nil else { throw Failure.ambiguousOwner }
            signatures[signature] = owner.id
            let raw = input.width * input.height * 24 + 316
            guard expectedRawBytes <= contract.maximumPageBytes - raw else { throw Failure.budgetExceeded }
            expectedRawBytes += raw
            roster.append(["ownerID": owner.id, "inputGeometryTextSignatureSHA256": signature,
                "width": input.width, "height": input.height, "expectedStageRawBytes": raw])
        }
        pageReferences = try references()
        _ = try Self.json(pageReferences)
        guard pageReferences["sourceRGBIdentity"] as? String == contract.sourceIdentity,
              pageReferences["sourceEncodedSHA256"] as? String == contract.sourceEncodedSHA256,
              let bank = pageReferences["sourceInputBank"] as? [String: Any],
              let bankPath = bank["path"] as? String, !bankPath.isEmpty,
              let bankSHA = bank["SHA256"] as? String, Self.hex(bankSHA),
              let raw = pageReferences["rawRF"] as? [String: Any],
              let rawPath = raw["recordPath"] as? String, !rawPath.isEmpty,
              ["recordSHA256", "identitySHA256", "payloadSHA256"].allSatisfy({
                  (raw[$0] as? String).map(Self.hex) == true
              }) else { throw Failure.invalidContract }
        ownerBySignature = signatures
        plans = roster
        prepared = true
    }

    var observer: NativeSelectedSourceSegmentationProducer.SourceReplayObserver {
        { [self] input, stage in try observe(input, stage: stage) }
    }

    private func observe(_ input: SourceNativeInput, stage: NativeSelectedSourceSegmentationProducer.ReplayStage) throws {
        lock.lock(); defer { lock.unlock() }
        guard prepared, !finished else { throw Failure.ownerNotPrepared }
        guard input.sourceIdentity == contract.sourceIdentity,
              let ownerID = ownerBySignature[try Self.signature(input)] else { throw Failure.invalidOwnerRoster }
        guard packets[ownerID] == nil else { throw Failure.duplicateOwner }
        try Task.checkCancellation()
        let n = input.width * input.height
        guard stage.width == input.width, stage.height == input.height,
              stage.fontPixels.bitPattern == input.fontPriorSourcePixels.bitPattern,
              stage.jointComputationRadius == NativeSegmentationFinalPolicy.requiredJointRadius,
              [stage.primary.count, stage.boundary.count, stage.rawNative.count, stage.completed.count,
               stage.filledBase.count, stage.finalMask.count, stage.jointCodes.count].allSatisfy({ $0 == n }),
              input.rgb.count == n * 3, input.rf.count == n * 27, input.coarseRF.count == n * 4,
              input.affinityScores.count == 5, stage.sourceStyle18.count == 18, stage.auxiliaryStyle18.count == 18,
              stage.primary.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              stage.boundary.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              stage.rawNative.allSatisfy({ $0 == 0 || $0 == 1 || $0 == 255 }),
              [stage.completed, stage.filledBase, stage.finalMask].allSatisfy({ $0.allSatisfy({ $0 == 0 || $0 == 255 }) }),
              stage.jointCodes.allSatisfy({ $0 < 8192 || $0 == 65535 }),
              stage.weakPositions.count == stage.auxiliaryCodes.count,
              Set(stage.weakPositions).count == stage.weakPositions.count,
              stage.weakPositions.allSatisfy({ (0..<n).contains($0) }),
              stage.auxiliaryCodes.allSatisfy({ $0 < 8192 }),
              stage.sourceStyle18.allSatisfy(\.isFinite), stage.auxiliaryStyle18.allSatisfy(\.isFinite),
              input.affinityScores.allSatisfy(\.isFinite) else { throw Failure.invalidStage }
        var auxiliary = [UInt16](repeating: 65535, count: n)
        for (row, pixel) in stage.weakPositions.enumerated() { auxiliary[pixel] = stage.auxiliaryCodes[row] }
        var rfText = [Float](repeating: 0, count: n)
        for pixel in 0..<n { rfText[pixel] = input.rf[pixel * 27] }
        var coarse = [UInt8](); coarse.reserveCapacity(n * 4)
        for (i, value) in input.coarseRF.enumerated() {
            if i % 16384 == 0 { try Task.checkCancellation() }
            guard value.isFinite, (0...1).contains(value) else { throw Failure.invalidCoarseABI }
            let code = UInt8((Double(value) * 255).rounded(.toNearestOrEven))
            guard (Float(code) / 255).bitPattern == value.bitPattern else { throw Failure.invalidCoarseABI }
            coarse.append(code)
        }
        let hashes = ["rgbSHA256": Self.hash(input.rgb), "fullRFSHA256": Self.hash(input.rf),
            "coarseRFSHA256": Self.hash(input.coarseRF)]
        let ownerKey = Self.hash(try Self.json(["sourceIdentity": input.sourceIdentity, "ownerID": ownerID,
            "signatureSHA256": try Self.signature(input)]))
        let packet = directory.appendingPathComponent(ownerKey, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: packet.path) else { throw Failure.existingDestination }
        try FileManager.default.createDirectory(at: packet, withIntermediateDirectories: false)
        var files: [String: Any] = [:]
        var rawBytes = 0
        func write<T>(_ field: String, _ filename: String, _ values: [T], _ scalar: String) throws {
            let size = values.count * MemoryLayout<T>.stride
            guard bytesWritten <= contract.maximumPageBytes - rawBytes - size else { throw Failure.budgetExceeded }
            try values.withUnsafeBytes { buffer in
                if let address = buffer.baseAddress {
                    let bytes = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: address), count: buffer.count, deallocator: .none)
                    try bytes.write(to: packet.appendingPathComponent(filename), options: [.withoutOverwriting])
                } else {
                    try Data().write(to: packet.appendingPathComponent(filename), options: [.withoutOverwriting])
                }
            }
            files[field] = ["path": filename, "scalar": scalar, "count": values.count, "bytes": size, "SHA256": Self.hash(values)]
            rawBytes += size
        }
        try write("primary", "primary.f32", stage.primary, "f32le")
        try write("boundary", "boundary.f32", stage.boundary, "f32le")
        try write("rawNative", "native.u8", stage.rawNative, "u8")
        try write("completed", "completed.u8", stage.completed, "u8")
        try write("filledBase", "filled-base.u8", stage.filledBase, "u8")
        try write("finalMask", "final-mask.u8", stage.finalMask, "u8")
        try write("jointCodes", "joint.u16", stage.jointCodes, "u16le-original-policy-code")
        try write("auxiliaryCodes", "auxiliary.u16", auxiliary, "u16le-original-policy-code")
        try write("rfMaximumText", "rf-max-native-text.f32", rfText, "f32le")
        try write("coarseRFUInt8Codes", "coarse.u8", coarse, "u8")
        try write("sourceStyle18", "source-style.f64", stage.sourceStyle18, "f64le")
        try write("auxiliaryStyle18", "auxiliary-style.f64", stage.auxiliaryStyle18, "f64le")
        try write("affinityScores", "affinity.f32", input.affinityScores, "f32le")
        try write("fontPixels", "font.f64", [stage.fontPixels], "f64le")
        let descriptor = try inputDescriptor(ownerID, input, packet, hashes)
        guard descriptor["ownerID"] as? String == ownerID,
              descriptor["hashes"] as? [String: String] == hashes,
              descriptor["sourceInputBankSHA256"] as? String == (pageReferences["sourceInputBank"] as? [String: Any])?["SHA256"] as? String,
              let ownerIndex = descriptor["sourceInputBankOwnerIndex"] as? Int, ownerIndex >= 0,
              let itemIndex = descriptor["actualItemIndex"] as? Int, itemIndex >= 0,
              let ownerSHA = descriptor["ownerDescriptorSHA256"] as? String, Self.hex(ownerSHA)
        else { throw Failure.invalidContract }
        let descriptorData = try Self.json(descriptor)
        try descriptorData.write(to: packet.appendingPathComponent("source-input-descriptor.json"), options: [.withoutOverwriting])
        var document: [String: Any] = ["schema": "aidoku-source-stage-cache-v2", "files": files,
            "sourceIdentity": input.sourceIdentity, "sourceEncodedSHA256": contract.sourceEncodedSHA256,
            "ownerID": ownerID, "ownerKey": ownerKey, "inputGeometryTextSignatureSHA256": try Self.signature(input),
            "compiledProducerSHA256": contract.compiledProducerSHA256,
            "compiledSourceFingerprint": contract.compiledSourceFingerprint, "compiledSourceSHA256": contract.compiledSourceSHA256,
            "implementationFingerprint": contract.compiledSourceFingerprint,
            "configSHA256": configSHA256, "configuration": config,
            "rfClassSchema": contract.rfClassCoordinateFeatureSchema, "reconstructionReferences": pageReferences,
            "sourceInputDescriptor": ["path": "source-input-descriptor.json", "SHA256": Self.hash(descriptorData)],
            "width": input.width, "height": input.height,
            "cropBounds": [input.crop.minX, input.crop.minY, input.crop.maxX, input.crop.maxY].map(Double.init),
            "pageSize": [Double(input.pageSize.width), Double(input.pageSize.height)],
            "bboxLocal": [input.bbox.minX, input.bbox.minY, input.bbox.width, input.bbox.height].map(Double.init),
            "memberPolygonsLocal": input.memberPolygons.map { $0.map { [Double($0.x), Double($0.y)] } },
            "mergedPolygonLocal": input.mergedPolygon.map { [Double($0.x), Double($0.y)] },
            "sourceTextSHA256": Self.hash(Data(input.sourceText.utf8)),
            "filledBaseSHA256": Self.hash(stage.filledBase), "finalMaskSHA256": Self.hash(stage.finalMask),
            "modelBinding": contract.modelBinding, "RFWeightsSHA256": input.rfModelWeightsSHA256,
            "primaryModelSHA256": "8f5dba949b25c2cf54359bd8e4066c6423970980a0355887c83e150d82a0e617",
            "boundaryModelSHA256": "3df521613d2981c412c3c9a38878128d1450bb1016e7baaaddad5f3a0d3a36ea",
            "jointModelSHA256": NativeSegmentationFinalPolicy.jointModelSHA256,
            "auxiliaryModelSHA256": NativeSegmentationFinalPolicy.auxiliaryModelSHA256,
            "policySHA256": NativeSourceSegmentationExecution.policySHA256,
            "jointComputationRadius": stage.jointComputationRadius,
            "jointDomainABI": "full-fields-policy-radius-v1; base OR Chebyshev<=radius;65535 elsewhere",
            "probabilityABI": "raw Float32 primary/boundary and native source27; no added quantization",
            "decisionABI": "ORIGINAL consumed joint/aux uint16 codes0..8191;65535 UNCOMPUTED,notzero",
            "coarseRFABI": "pixel-interleaved4 UInt8 codes; Float(code)/Float(255) bit-exact to actual input.coarseRF",
            "rfPlaneABI": "input.rf pixel-interleaved27; native text plane0; semantic map bound by rfClassSchema, not Host canonical IDs",
            "styleABI": "source/aux style18 and font original Float64 RAWBITS; affinity original Float32 RAWBITS",
            "baseABI": "actual production filledBase bytes; no observer recomputation",
            "finalMaskABI": "actual selected own mask before final protection, ownerID/source/crop-bound",
            "rawBytes": rawBytes, "complete": true, "sourceOnly": true, "GTAtInference": false,
            "additionalInference": false, "bboxMaskClipping": false, "dense78FeatureRowsStored": false]
        for (key, value) in hashes { document[key] = value }
        let metadata = try Self.json(document)
        let extra = descriptor["additionalPayloadBytes"] as? Int ?? 0
        guard extra >= 0, bytesWritten <= contract.maximumPageBytes - rawBytes - descriptorData.count - metadata.count - extra else { throw Failure.budgetExceeded }
        try Task.checkCancellation()
        try metadata.write(to: packet.appendingPathComponent("manifest.json"), options: [.withoutOverwriting])
        bytesWritten += rawBytes + descriptorData.count + metadata.count + extra
        packets[ownerID] = ["ownerID": ownerID, "ownerKey": ownerKey,
            "manifest": ownerKey + "/manifest.json", "manifestSHA256": Self.hash(metadata), "rawBytes": rawBytes]
    }

    /// Commit only after every expected ACTUAL constructor owner was observed.
    /// Missing owners/budget/IO are not silently marked complete or skipped.
    @discardableResult func finish() throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        guard prepared, !finished, packets.count == plans.count,
              Set(packets.keys) == Set(plans.compactMap { $0["ownerID"] as? String }) else { throw Failure.incompletePage }
        var document: [String: Any] = ["schema": "aidoku-selected-source-observation-page-v2",
            "sourceIdentity": contract.sourceIdentity, "sourceEncodedSHA256": contract.sourceEncodedSHA256,
            "compiledProducerSHA256": contract.compiledProducerSHA256, "compiledSourceFingerprint": contract.compiledSourceFingerprint,
            "configSHA256": configSHA256, "expectedOwnerCount": plans.count, "observedOwnerCount": packets.count,
            "ownerRoster": plans, "ownerRosterSHA256": Self.hash(try Self.json(plans)),
            "owners": packets.keys.sorted().compactMap { packets[$0] }, "reconstructionReferences": pageReferences,
            "payloadBytesWritten": bytesWritten, "bytesWritten": bytesWritten, "maximumPageBytes": contract.maximumPageBytes,
            "complete": true, "allPredictedSourceOwnersObserved": true,
            "GTAtInference": false, "additionalInference": false, "dense78FeatureRowsStored": false]
        // The index itself is part of the quota. Iterate the self-reported byte
        // count to its stable decimal representation before committing LAST.
        var metadata = try Self.json(document)
        for _ in 0..<16 {
            let total = bytesWritten + metadata.count
            guard total <= contract.maximumPageBytes else { throw Failure.budgetExceeded }
            if document["bytesWritten"] as? Int == total { break }
            document["bytesWritten"] = total
            metadata = try Self.json(document)
        }
        guard document["bytesWritten"] as? Int == bytesWritten + metadata.count else { throw Failure.invalidContract }
        try Task.checkCancellation()
        try metadata.write(to: directory.appendingPathComponent("page-manifest.json"), options: [.withoutOverwriting])
        finished = true
        return document
    }

    private static func hex(_ value: String) -> Bool { value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    private static func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) }
    private static func hash(_ value: Data) -> String { SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined() }
    private static func hash<T>(_ values: [T]) -> String {
        values.withUnsafeBytes { buffer in
            guard let address = buffer.baseAddress else { return hash(Data()) }
            return hash(Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: address), count: buffer.count, deallocator: .none))
        }
    }
    private static func signature(_ input: SourceNativeInput) throws -> String {
        hash(try json(["sourceIdentity": input.sourceIdentity, "sourceTextSHA256": hash(Data(input.sourceText.utf8)),
            "width": input.width, "height": input.height, "fontPriorFloat64Bits": String(input.fontPriorSourcePixels.bitPattern, radix: 16),
            "crop": [input.crop.minX, input.crop.minY, input.crop.maxX, input.crop.maxY].map(Double.init),
            "page": [Double(input.pageSize.width), Double(input.pageSize.height)],
            "bbox": [input.bbox.minX, input.bbox.minY, input.bbox.width, input.bbox.height].map(Double.init),
            "members": input.memberPolygons.map { $0.map { [Double($0.x), Double($0.y)] } },
            "merged": input.mergedPolygon.map { [Double($0.x), Double($0.y)] }]))
    }
}
