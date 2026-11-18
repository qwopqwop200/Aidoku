import Foundation

/// PRIVATE replacement source for review; production file remains untouched.
/// Legacy32/64 retain their assets, Float151 row and checkpoint identity.
final class NativeM1SourceStyleInference {
    static let revision = "actual-m1-p9-five-role-style-native-v1"
    enum Variant: Int { case rounds32 = 32, rounds64 = 64
        var candidateID: String {
            self == .rounds32 ? "actual-M1-physical35-p9" : "actual-M1-physical35-p9-rounds64"
        }
        var calibration: NativeM1SourceWidth.Calibration {
            self == .rounds32 ? .m1p9Rounds32 : .m1p9Rounds64
        }
    }
    enum PresenceABI: String {
        case legacy151 = "legacy-conditioned-background151-v1"
        // Actual native Float44 and Float pair6 promoted to Double; maskFraction
        // remains its measured Double, as frozen by the selected TRAIN recipe.
        case noBackground95 = "fill44-outline44-pair6-maskDouble1-v1"

        var outlinePresenceThreshold: Double {
            // The 95-feature head has its own operating point from the
            // source-group TRAIN folds. Keep the legacy 151 cutoff intact.
            self == .noBackground95 ? 0.35 : 0.4
        }

        func outlineIsPresent(probability: Double) -> Bool {
            probability >= outlinePresenceThreshold
        }
    }
    enum Failure: Error { case asset(String), output(String), packet }
    private static let widths = ["fill": 44, "outline": 94, "background": 146,
                                 "outlinePresence": 151, "shadowPresence": 151]
    private static let hashes32 = [
        "fill": "4531b7c89b6f99122edf908d817ef691b2794e0ca03581853faa03222d0c9029",
        "outline": "92d87117f0f99fca5a98f1cc56b27794a95aebdc76679f5785d4583998842ee6",
        "background": "cedf8f6c782fa78aa98d26f9c3a1feab920227b100843343b7197c2c1d5f98a1",
        "outlinePresence": "39cabd59818024ce094580651f9687d9425c53083d8ce58e362f9c264f6921c1",
        "shadowPresence": "a3c6c6a0d5413c0ac598de2c1d6699ad2abb420e256e2b3b78e319e79615dca2"]
    private static let hashes64 = [
        "fill": "690932f447e7c64520786b46d479a71eddd935fa2a0919137a86a80defed74ed",
        "outline": "4f12b0060fa5e1117315725da21860f03c5c5e503e6f643ec5f891b31c5d4349",
        "background": "65ff96dae9d7eb33f7528692a465fb6745a6001958249cb9f925fcb1f0ea0d7e",
        "outlinePresence": "4c745ee099a92c647637414fd91b73b9cb199aac86134acfadd72542383b0939",
        "shadowPresence": "e495e7cbe3282600bcfe90af35a8cc094bc16ff0c7c5de164ff3e44f7ad323d8"]
    private static let hashes95 = [
        "outlinePresence": "742dc15f789cca1eb786c6f13fab1396e6987b809606f702600cb8fc1ceb3d6b",
        "shadowPresence": "2e991c58eae8487f8ae76b0618eb520a125b7c91aa03cee9bf5756d32e1a19f5"]
    static func roleSHA256(for variant: Variant, presenceABI: PresenceABI = .legacy151) -> [String: String] {
        var hashes = variant == .rounds32 ? hashes32 : hashes64
        if presenceABI == .noBackground95, variant == .rounds64 {
            hashes.merge(hashes95) { _, new in new }
        }
        return hashes
    }
    static func roleAssetBytes(for variant: Variant, presenceABI: PresenceABI = .legacy151) -> Int {
        if variant == .rounds32 { return 92_978 }
        return presenceABI == .noBackground95 ? 179_500 : 180_037
    }
    static func cacheIdentity(for variant: Variant, presenceABI: PresenceABI = .legacy151) -> String {
        let hashes = roleSHA256(for: variant, presenceABI: presenceABI)
        let base = revision + ";" + NativeM1SourceStyleFeatures44.revision + ";" + variant.candidateID
            + ";" + hashes.keys.sorted().map { $0 + "=" + hashes[$0]! }.joined(separator: ";")
            + ";width=" + variant.calibration.identity
        guard presenceABI != .legacy151 else { return base }
        return base + ";presenceABI=" + presenceABI.rawValue + ";outlineThreshold=\(presenceABI.outlinePresenceThreshold)"
    }
    let variant: Variant
    let presenceABI: PresenceABI
    let checkpointIdentity: String
    private let models: [String: NativeFrozenSourceModel]
    private let ops: any NativeAppearanceImageOperations

    init(directory: URL, variant: Variant, presenceABI: PresenceABI = .legacy151, presenceDirectory: URL? = nil,
         ops: any NativeAppearanceImageOperations = NativeOpenCVAppearanceImageOperations()) throws {
        guard directory.isFileURL, presenceDirectory?.isFileURL != false,
              presenceABI != .noBackground95 || variant == .rounds64 else { throw Failure.asset("presence-variant") }
        self.variant = variant
        self.presenceABI = presenceABI
        self.ops = ops
        let hashes = Self.roleSHA256(for: variant, presenceABI: presenceABI)
        var loaded: [String: NativeFrozenSourceModel] = [:]
        for role in hashes.keys.sorted() {
            let changed = presenceABI == .noBackground95 && role.hasSuffix("Presence")
            let root = changed ? (presenceDirectory ?? directory) : directory
            let data = try Data(contentsOf: root.appendingPathComponent(role + ".plist"))
            guard NativeFrozenSourceSHA256.hex(data) == hashes[role] else { throw Failure.asset(role) }
            let model = try NativeFrozenSourceModel(data: data)
            let width = changed ? 95 : Self.widths[role]
            guard model.kind == "forest", model.featureCount == width, model.classes == [0, 1],
                  model.forests.count == 1, model.forests[0].trees.count == variant.rawValue else {
                throw Failure.asset(role)
            }
            loaded[role] = model
        }
        models = loaded
        var contract: [String: Any] = ["revision": Self.revision, "candidate": variant.candidateID,
            "featureABI": NativeM1SourceStyleFeatures44.revision, "assets": hashes,
            "outlineThreshold": presenceABI.outlinePresenceThreshold, "shadowThreshold": 0.34,
            "widthCalibration": variant.calibration.identity]
        if presenceABI != .legacy151 { contract["presenceABI"] = presenceABI.rawValue }
        checkpointIdentity = NativeFrozenSourceSHA256.hex(try JSONSerialization.data(withJSONObject: contract, options: .sortedKeys))
    }

    private func positive(_ role: String, _ rows: [[Float]]) throws -> [Double] {
        try rows.map { row in try positiveProbability(role, row.map(Double.init)) }
    }
    private func positiveProbability(_ role: String, _ row: [Double]) throws -> Double {
        guard let model = models[role] else { throw Failure.asset(role) }
        let result = try model.predictProbability(row)
        guard result.count == 2, result.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw Failure.output(role)
        }
        return result[1]
    }
    private func presenceProbability(_ role: String, summary: [Double]) throws -> Double {
        try positiveProbability(role, summary)
    }
    private func legacyPresenceProbability(_ role: String, summary: [Float]) throws -> Double {
        try positiveProbability(role, summary.map(Double.init))
    }
    private func rank(_ role: String, _ rows: [[Float]], excluding: Int? = nil) throws -> Int {
        var values = try positive(role, rows)
        guard !values.isEmpty else { throw Failure.output(role) }
        if let excluding { values[excluding] = -1 }
        var chosen = 0
        for index in values.indices.dropFirst() where values[index] > values[chosen] { chosen = index }
        return chosen
    }
    static func presenceSummary95(_ packet: NativeAppearanceSourceFeatures209.Packet, fill: Int, outline: Int) -> [Double] {
        packet.features[fill].map(Double.init) + packet.features[outline].map(Double.init)
            + packet.pair[fill][outline].map(Double.init) + [packet.maskFraction]
    }
    func predictPalette(_ packet: NativeAppearanceSourceFeatures209.Packet) throws -> [String: Any] {
        guard !packet.colors.isEmpty, packet.colors.count == packet.features.count,
              packet.colors.allSatisfy({ $0.count == 3 && $0.allSatisfy({ $0.isFinite && (0...255).contains($0) }) }),
              packet.maskFraction.isFinite, (0...1).contains(packet.maskFraction),
              packet.features.allSatisfy({ $0.count == 44 && $0.allSatisfy(\.isFinite) }),
              packet.pair.count == packet.colors.count,
              packet.pair.allSatisfy({ $0.count == packet.colors.count && $0.allSatisfy({ $0.count == 6 && $0.allSatisfy(\.isFinite) }) }) else {
            throw Failure.packet
        }
        let fill = try rank("fill", packet.features)
        let outline = try rank("outline", packet.role("outline", fill: fill), excluding: fill)
        let background = try rank("background", packet.role("background", fill: fill, outline: outline))
        let op: Double, sp: Double
        if presenceABI == .noBackground95 {
            let summary = Self.presenceSummary95(packet, fill: fill, outline: outline)
            op = try presenceProbability("outlinePresence", summary: summary)
            sp = try presenceProbability("shadowPresence", summary: summary)
        } else {
            let summary = packet.summary(fill: fill, outline: outline, background: background)
            op = try legacyPresenceProbability("outlinePresence", summary: summary)
            sp = try legacyPresenceProbability("shadowPresence", summary: summary)
        }
        return ["fillIndex": fill, "outlineIndex": outline, "backgroundIndex": background,
            "fill": ["rgb": packet.colors[fill]], "background": ["rgb": packet.colors[background]],
            "outline": ["rgb": packet.colors[outline], "present": presenceABI.outlineIsPresent(probability: op),
                        "probability": op, "widthPx": NSNull()],
            "shadow": ["present": sp >= 0.34, "probability": sp, "rgb": NSNull(),
                       "offsetPx": NSNull(), "blurRadiusPx": NSNull(), "opacity": NSNull()],
            "sourceOnly": true, "inferenceUsesGT": false]
    }
    func predict(_ input: NativeMinimalSourceStyleInput) throws -> [String: Any] {
        try input.validate()
        try Task.checkCancellation()
        let packet = try NativeM1SourceStyleFeatures44.extract(input, ops: ops)
        var result = try predictPalette(packet)
        guard var outline = result["outline"] as? [String: Any],
              let rgb = outline["rgb"] as? [Double], let present = outline["present"] as? Bool else { throw Failure.output("outline") }
        let width = try NativeM1SourceWidth.estimate(rgb: input.rgb, width: input.width, height: input.height,
            mask: input.ownMask, outlineRGB: rgb, outlinePresent: present,
            fontPrior: input.fontPriorSourcePixels, calibration: variant.calibration)
        outline["widthPx"] = width.widthPx
        outline["measurementEvidence"] = width.measurementEvidence
        result["outline"] = outline
        var diagnostic: [String: Any] = ["backend": Self.revision, "checkpointSHA256": checkpointIdentity,
            "candidateID": variant.candidateID, "sourceFeatureCount": 44, "roleModelCount": 5,
            "rich209Executed": false, "boundaryOCRContextFeaturesExecuted": false,
            "intrinsicShadowPaintAvailable": false, "sourceOnly": true, "GTAtInference": false]
        if presenceABI != .legacy151 {
            diagnostic["presenceABI"] = presenceABI.rawValue
            diagnostic["presenceFeatureCount"] = 95
            diagnostic["outlinePresenceThreshold"] = presenceABI.outlinePresenceThreshold
        }
        result["nativeSourceInference"] = diagnostic
        return result
    }
}
