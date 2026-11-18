import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

/// Real packaged auxiliary heads, real native44/width and real native raw597/
/// BODY. The focused synthetic primary is an observation fixture, not quality
/// evidence and not a request to run a core segmentation/RF/OCR model.
@Suite(.serialized)
struct NativeM1SourcePageActivationTests {
    @Test func ownerPairingReservesPhoneMemoryAndSerializesColdBodyFonts() {
        typealias Measurements = NativeSourceOwnerMeasurements
        let gibibyte: UInt64 = 1_024 * 1_024 * 1_024
        #expect(!Measurements.allowsPairing(processors: 3, physicalMemory: 8 * gibibyte, availableMemory: 3 * gibibyte))
        #expect(!Measurements.allowsPairing(processors: 6, physicalMemory: 6 * gibibyte, availableMemory: 3 * gibibyte))
        #expect(!Measurements.allowsPairing(processors: 6, physicalMemory: 8 * gibibyte, availableMemory: 2 * gibibyte - 1))
        #expect(Measurements.allowsPairing(processors: 4, physicalMemory: 7 * gibibyte, availableMemory: 2 * gibibyte))
        #expect(Measurements.Mode.style.mayPair(owner: 0))
        #expect(!Measurements.Mode.base4.mayPair(owner: 0))
        #expect(Measurements.Mode.base4.mayPair(owner: 1))
        #expect(!Measurements.Mode.serial.mayPair(owner: 1))
    }

    @Test func cropMeasurementsKeepOwnerOrderAcrossSerialAndPairedCrops() throws {
        let pixels = [20_000, 40_000, 1_500_000, 80_000, 90_000, 10_000]
        let order = try NativeSourceOwnerMeasurements.map(count: pixels.count, pixels: { pixels[$0] }) { $0 }
        #expect(order == Array(pixels.indices))

        enum Failure: Error { case firstOwner, secondOwner }
        #expect(throws: Failure.firstOwner) {
            try NativeSourceOwnerMeasurements.map(count: 2, pixels: { _ in 10_000 }) { index -> Int in
                throw index == 0 ? Failure.firstOwner : Failure.secondOwner
            }
        }
    }

    @Test func cancelledPageDoesNotBeginOwnerMeasurements() async {
        let result = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try NativeSourceOwnerMeasurements.map(count: 2, pixels: { _ in 1 }) { index in
                Issue.record("Cancelled page started owner \(index)")
                return index
            }
        }.result
        guard case .failure(let error) = result else {
            Issue.record("Cancelled page returned measurements")
            return
        }
        #expect(error is CancellationError)
    }

    @Test func bundled64AssetsMatchFrozenCandidateWithoutEnvironmentOverride() throws {
        let models = try NativeM1SourcePageInference.sourceModelDirectory()
        let directory = try NativeM1SourcePageInference.styleDirectory(modelDirectory: models, variant: .rounds64)
        let hashes = NativeM1SourceStyleInference.roleSHA256(for: .rounds64)
        var bytes = 0
        for role in hashes.keys {
            let data = try Data(contentsOf: directory.appendingPathComponent(role + ".plist"))
            #expect(NativeFrozenSourceSHA256.hex(data) == hashes[role])
            bytes += data.count
        }
        #expect(hashes.count == 5 && bytes == 180_037)
        #expect(try NativeSourceInferencePolicy.resolveStagedM1StyleDirectory(mode: .minimalM1P9Body64) == nil)
        #expect(NativeSourceInferencePolicy.defaultMode == .minimalM1P9Body64Presence95)
    }

    @Test func bundledDTOStyleAndWholePageBODYActivateWithoutCoreModelForward() throws {
        let w = 128, h = 128
        let bounds = CGRect(x: 12, y: 12, width: 104, height: 104)
        var rgb = [UInt8](repeating: 240, count: w * h * 3)
        var primary = [Float](repeating: 0, count: w * h)
        for y in 28..<100 { for x in 46..<82 {
            primary[y * w + x] = 1
            for c in 0..<3 { rgb[(y * w + x) * 3 + c] = 20 }
        }}
        let mask = try NativeMinimalSourceSegmentation.postprocessPrimary(primary, width: w, height: h,
            configuration: NativeSourceInferencePolicy.primaryM1Configuration)
        let prior = try NativeSimpleSourceFont.prior(bounds: bounds, originalCharacterCount: 2)
        let input = NativeMinimalSourceStyleInput(width: w, height: h, rgb: rgb, ownMask: mask,
            primary: primary, fontPriorSourcePixels: prior, bbox: bounds,
            sourceIdentity: "synthetic-actual-primary-M1-page", sourceText: "文字",
            memberPolygons: [[CGPoint(x: 12, y: 12), CGPoint(x: 116, y: 12),
                CGPoint(x: 116, y: 116), CGPoint(x: 12, y: 116)]])
        let page = try NativeM1SourcePageInference()
        let result = try page.predict([input, input])
        #expect(result.styles.count == 2 && result.weights.count == 2)
        #expect(result.audit["styleRoleCount"] as? Int == 5)
        #expect(result.audit["BODYRoleCount"] as? Int == 1)
        #expect(result.audit["BODYPageBatchForwardCalls"] as? Int == 1)
        #expect(result.audit["coreModelForwardCalls"] as? Int == 0)
        // Execution declaration only: no assertion of observed cache hits,
        // retained predictions or numerical-ABI changes.
        #expect(result.audit["BODYIntrinsicMetricsExecutionRevision"] as? String == "base4-intrinsic-metrics-content-lru-v1")
        #expect(result.audit["BODYIntrinsicMetricsCacheDeclaration"] as? String ==
            NativeM1SourcePageInference.bodyIntrinsicMetricsCacheDeclaration)
        #expect(result.audit["acceptedAppearanceGraphConstructed"] as? Bool == false)
        #expect(result.audit["upstreamPrimaryComputedHere"] as? Bool == false)
        for (style, weight) in zip(result.styles, result.weights) {
            let evidence = try #require(style["nativeSourceInference"] as? [String: Any])
            #expect(evidence["sourceFeatureCount"] as? Int == 44)
            #expect(evidence["roleModelCount"] as? Int == 5)
            let outline = try #require(style["outline"] as? [String: Any])
            #expect((outline["widthPx"] as? Double)?.isFinite == true)
            #expect(weight["raw597OnlyBridge"] as? Bool == true)
            #expect(weight["weightModelRoleCount"] as? Int == 1)
            #expect(weight["bodyScore"] as? Double != nil)
            #expect(weight["measurementABI"] as? String == "raw597-base4-v1")
        }
        let empty = try page.predict([])
        #expect(empty.styles.isEmpty && empty.weights.isEmpty)
        #expect(empty.audit["BODYPageBatchForwardCalls"] as? Int == 0)
    }

    @Test func verifiedExternalOverrideRejectsChangedBytesWithoutBundledFallback() throws {
        let models = try NativeM1SourcePageInference.sourceModelDirectory()
        let source = try NativeM1SourcePageInference.styleDirectory(modelDirectory: models, variant: .rounds64)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        for role in NativeM1SourceStyleInference.roleSHA256(for: .rounds64).keys {
            try FileManager.default.copyItem(at: source.appendingPathComponent(role + ".plist"),
                to: directory.appendingPathComponent(role + ".plist"))
        }
        let fill = directory.appendingPathComponent("fill.plist")
        var corrupted = try Data(contentsOf: fill)
        corrupted[corrupted.startIndex] ^= 255
        try corrupted.write(to: fill)
        #expect(throws: (any Error).self) {
            try NativeM1SourcePageInference(styleDirectoryOverride: directory)
        }
    }

    @Test func compactBASE4InitializerMatchesOrderedLegacyFacesAndRejectsMissingOrCorruptAsset() throws {
        let models = try NativeM1SourcePageInference.sourceModelDirectory()
        let url = models.appendingPathComponent(NativeM1SourcePageInference.bodyBase4SpecFileName)
        let data = try Data(contentsOf: url)
        #expect(data.count == 654)
        #expect(NativeFrozenSourceSHA256.hex(data) == NativeM1SourcePageInference.bodyBase4SpecSHA256)
        let compact = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(compact.keys) == ["fonts"])
        let actual = try NativeM1SourcePageInference.resolvedBodyBase4Spec(modelDirectory: models)
        #expect(Set(actual.keys) == ["fonts"])
        let registry = try NativeFrozenSourceModel.Registry(directory: models, includeMetadata: true)
        let metadata = try registry.metadataTreeFoundation
        let font = try #require(metadata["font198"] as? [String: Any])
        let graph = try #require(font["optimizedGraph"] as? [String: Any])
        let full = try #require(graph["measurementSpec"] as? [String: Any])
        let legacy = try NativeSourceFontResolver.resolveMeasurementSpec(full)
        let actualFonts = try #require(actual["fonts"] as? [[String: Any]])
        let legacyFonts = try #require(legacy["fonts"] as? [[String: Any]])
        #expect(actualFonts.count == 4 && NSDictionary(dictionary: actual).isEqual(to: ["fonts": legacyFonts]))
        #expect(NSDictionary(dictionary: compact).isEqual(to: ["fonts": try #require(full["fonts"])]))
        #expect(throws: (any Error).self) { try NativeSourceFontResolver.resolveMeasurementSpec(compact) }
        var extra = compact
        extra["extendedFonts"] = []
        #expect(throws: (any Error).self) { try NativeSourceFontResolver.resolveBodyBase4MeasurementSpec(extra) }
        for count in [0, 3, 5] {
            let invalid = ["fonts": Array(repeating: actualFonts[0], count: count)]
            #expect(throws: (any Error).self) { try NativeSourceFontResolver.resolveBodyBase4MeasurementSpec(invalid) }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: (any Error).self) { try NativeM1SourcePageInference.resolvedBodyBase4Spec(modelDirectory: directory) }
        var corrupt = data
        corrupt[0] ^= 1
        try corrupt.write(to: directory.appendingPathComponent(NativeM1SourcePageInference.bodyBase4SpecFileName))
        #expect(throws: (any Error).self) { try NativeM1SourcePageInference.resolvedBodyBase4Spec(modelDirectory: directory) }
    }

    @Test func explicitBASE4RawMatchesLegacyAndRejectsEachMissingOrCorruptBaseFont() throws {
        let models = try NativeM1SourcePageInference.sourceModelDirectory()
        let registry = try NativeFrozenSourceModel.Registry(directory: models, includeMetadata: true)
        let metadata = try registry.metadataTreeFoundation
        let font = try #require(metadata["font198"] as? [String: Any])
        let graph = try #require(font["optimizedGraph"] as? [String: Any])
        let spec = try #require(graph["measurementSpec"] as? [String: Any])
        let fullSpec = try NativeSourceFontResolver.resolveMeasurementSpec(spec)
        let fonts = try #require(fullSpec["fonts"] as? [[String: Any]])
        #expect(fonts.count == 4)
        let width = 24, height = 24
        var rgb = [UInt8](repeating: 255, count: width * height * 3)
        for y in 4..<20 { for x in 8..<16 {
            for channel in 0..<3 { rgb[(y * width + x) * 3 + channel] = 0 }
        }}
        let packet: [String: Any] = ["measurementABI": "raw597-base4-v1", "width": width, "height": height,
            "rgb": Data(rgb), "bbox": [0, 0, width, height], "prior": 12.0, "text": "字A",
            "measurementSpec": ["fonts": fonts], "GTMaskUsed": false, "inferenceUsesGT": false]
        let raw = try NativeSingleBodyWeightInference.extractRaw597(packet: packet, measurementABI: .base4)
        #expect(raw.count == 597 && raw.allSatisfy(\.isFinite) && raw.prefix(6).allSatisfy({ $0 == 0 }))
        var legacy = packet
        legacy.removeValue(forKey: "measurementABI")
        legacy["measurementSpec"] = fullSpec
        legacy["ownership"] = Data(repeating: 1, count: width * height)
        legacy["sourceEm"] = 12.0
        legacy["style"] = ["fill": ["rgb": [0, 0, 0]], "background": ["rgb": [255, 255, 255]],
            "outline": ["present": false, "widthPx": 0], "sourceOnly": true] as [String: Any]
        let legacyRaw = try NativeSingleBodyWeightInference.extractRaw597(packet: legacy, measurementABI: .genericAdmission)
        #expect(raw == legacyRaw)
        for index in fonts.indices {
            for failure in ["wrongSHA", "missingFile", "missingPin"] {
                var invalidFonts = fonts
                if failure == "wrongSHA" { invalidFonts[index]["SHA256"] = String(repeating: "0", count: 64) }
                else if failure == "missingFile" {
                    invalidFonts[index]["path"] = FileManager.default.temporaryDirectory
                        .appendingPathComponent("absent-BASE4-\(UUID().uuidString).ttf").path
                } else { invalidFonts[index].removeValue(forKey: "SHA256") }
                var invalid = packet
                invalid["measurementSpec"] = ["fonts": invalidFonts]
                #expect(throws: (any Error).self) {
                    try NativeSingleBodyWeightInference.extractRaw597(packet: invalid, measurementABI: .base4)
                }
            }
        }
        var missingBase = packet
        missingBase["measurementSpec"] = ["fonts": Array(fonts.prefix(3))]
        #expect(throws: (any Error).self) {
            try NativeSingleBodyWeightInference.extractRaw597(packet: missingBase, measurementABI: .base4)
        }
        var legacyWithoutExtraBanks = legacy
        legacyWithoutExtraBanks["measurementSpec"] = ["fonts": fonts]
        #expect(throws: (any Error).self) {
            try NativeSingleBodyWeightInference.extractRaw597(packet: legacyWithoutExtraBanks, measurementABI: .genericAdmission)
        }
    }

    @Test func presence95DefaultKeepsExplicitLegacyModeAndIndependentPinnedDirectories() throws {
        typealias Policy = NativeSourceInferencePolicy
        let mode = Policy.Mode.minimalM1P9Body64Presence95
        #expect(Policy.defaultMode == mode)
        #expect(Policy.resolveMode(override: mode.rawValue) == mode)
        #expect(mode.m1StyleVariant == .rounds64 && mode.m1PresenceABI == .noBackground95)
        #expect(Policy.Mode.minimalM1P9Body64.m1PresenceABI == .legacy151)
        #expect(Policy.Mode.minimalM1P9Body32.m1PresenceABI == .legacy151)
        #expect(try Policy.resolveStagedM1StyleDirectory(mode: mode) == nil)
        let old = NativeM1SourceStyleInference.cacheIdentity(for: .rounds64)
        let new = NativeM1SourceStyleInference.cacheIdentity(for: .rounds64, presenceABI: .noBackground95)
        #expect(old != new && new.contains("fill44-outline44-pair6-maskDouble1-v1"))
        #expect(new.hasSuffix(";outlineThreshold=0.35"))
        #expect(!old.contains("outlineThreshold"))
        let models = try NativeM1SourcePageInference.sourceModelDirectory()
        let legacy = try NativeM1SourcePageInference.styleDirectory(modelDirectory: models, variant: .rounds64)
        let resolvedPresence = try NativeM1SourcePageInference.presenceDirectory(modelDirectory: models,
            variant: .rounds64, presenceABI: .noBackground95)
        let presence = try #require(resolvedPresence)
        #expect(presence.lastPathComponent == "M1SourcePresence95")
        #expect(legacy != presence)
        #expect(try NativeM1SourcePageInference.styleDirectory(modelDirectory: models, variant: .rounds64,
            override: legacy) == legacy.standardizedFileURL)
        #expect(throws: (any Error).self) {
            try NativeM1SourcePageInference.presenceDirectory(modelDirectory: models,
                variant: .rounds32, presenceABI: .noBackground95)
        }
        let pinned = NativeM1SourceStyleInference.roleSHA256(for: .rounds64, presenceABI: .noBackground95)
        let oldPinned = NativeM1SourceStyleInference.roleSHA256(for: .rounds64)
        for role in ["fill", "outline", "background"] { #expect(pinned[role] == oldPinned[role]) }
        for role in ["outlinePresence", "shadowPresence"] {
            let bytes = try Data(contentsOf: presence.appendingPathComponent(role + ".plist"))
            #expect(NativeFrozenSourceSHA256.hex(bytes) == pinned[role])
            #expect(pinned[role] != oldPinned[role])
        }
        _ = try NativeM1SourceStyleInference(directory: legacy, variant: .rounds64,
            presenceABI: .noBackground95, presenceDirectory: presence)
        // A legacy presence directory cannot masquerade as the new candidate.
        #expect(throws: (any Error).self) {
            try NativeM1SourceStyleInference(directory: legacy, variant: .rounds64,
                presenceABI: .noBackground95, presenceDirectory: legacy)
        }
    }

    @Test func outline95UsesItsOwnInclusiveThreshold() {
        typealias ABI = NativeM1SourceStyleInference.PresenceABI
        let candidate = 0.35
        let legacy = 0.4
        #expect(!ABI.noBackground95.outlineIsPresent(probability: candidate.nextDown))
        #expect(ABI.noBackground95.outlineIsPresent(probability: candidate))
        #expect(ABI.noBackground95.outlineIsPresent(probability: candidate.nextUp))
        #expect(!ABI.legacy151.outlineIsPresent(probability: legacy.nextDown))
        #expect(ABI.legacy151.outlineIsPresent(probability: legacy))
        #expect(ABI.legacy151.outlineIsPresent(probability: legacy.nextUp))
    }

    @Test func presence95ActivatesThroughSharedPageAndPreservesBASE4BODY() throws {
        let width = 32, height = 32
        var rgb = [UInt8](repeating: 240, count: width * height * 3)
        var primary = [Float](repeating: 0, count: width * height)
        for y in 8..<24 { for x in 12..<20 {
            primary[y * width + x] = 1
            for channel in 0..<3 { rgb[(y * width + x) * 3 + channel] = 20 }
        }}
        let mask = try NativeMinimalSourceSegmentation.postprocessPrimary(primary, width: width, height: height,
            configuration: NativeSourceInferencePolicy.primaryM1Configuration)
        let input = NativeMinimalSourceStyleInput(width: width, height: height, rgb: rgb, ownMask: mask,
            primary: primary, fontPriorSourcePixels: 12, bbox: CGRect(x: 4, y: 4, width: 24, height: 24),
            sourceIdentity: "synthetic-presence95-shared-page", sourceText: "字",
            memberPolygons: [[CGPoint(x: 4, y: 4), CGPoint(x: 28, y: 4),
                CGPoint(x: 28, y: 28), CGPoint(x: 4, y: 28)]])
        let legacy = try NativeM1SourcePageInference()
        let candidate = try NativeM1SourcePageInference(presenceABI: .noBackground95)
        let old = try legacy.predict([input]), new = try candidate.predict([input])
        #expect(legacy.checkpointIdentity != candidate.checkpointIdentity)
        #expect(old.styles.count == 1 && new.styles.count == 1)
        for role in ["fill", "outline", "background"] {
            #expect((old.styles[0][role] as? [String: Any])?["rgb"] as? [Double] ==
                (new.styles[0][role] as? [String: Any])?["rgb"] as? [Double])
        }
        for (style, threshold) in [(old.styles[0], 0.4), (new.styles[0], 0.35)] {
            let outline = try #require(style["outline"] as? [String: Any])
            let outlineProbability = try #require(outline["probability"] as? Double)
            #expect((outline["present"] as? Bool) == (outlineProbability >= threshold))
            let shadow = try #require(style["shadow"] as? [String: Any])
            let shadowProbability = try #require(shadow["probability"] as? Double)
            #expect((shadow["present"] as? Bool) == (shadowProbability >= 0.34))
        }
        #expect(NSDictionary(dictionary: old.weights[0]).isEqual(to: new.weights[0]))
        let diagnostic = try #require(new.styles[0]["nativeSourceInference"] as? [String: Any])
        #expect(diagnostic["presenceFeatureCount"] as? Int == 95)
        #expect(diagnostic["outlinePresenceThreshold"] as? Double == 0.35)
        #expect(diagnostic["presenceABI"] as? String == NativeM1SourceStyleInference.PresenceABI.noBackground95.rawValue)
        #expect(new.audit["coreModelForwardCalls"] as? Int == 0)
        #expect(new.audit["BODYPageBatchForwardCalls"] as? Int == 1)
    }
}
