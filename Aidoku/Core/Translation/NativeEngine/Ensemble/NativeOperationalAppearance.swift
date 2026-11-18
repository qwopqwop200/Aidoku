import Foundation
import CryptoKit
import CoreGraphics
import CoreFoundation

protocol NativeSavedAppearanceSourceEvidence {
    var contentIdentity: String { get }
    var width: Int { get }
    var height: Int { get }
    var verifiedEncodedSourceSHA256: String? { get }
}

/// Consumer seam for a fresh source-estimator backend. The live producer owns
/// expectedBinding; never derive it from a saved prediction or its receipt.
/// This adapter does not execute Python or claim iOS model availability.
enum NativeOperationalAppearance {
    enum Failure: Error { case invalidPacket, sourceMismatch, invalidPrediction }

    // Render-local typed choices, never decoded from raw source dictionaries.
    // A missing/unconvertible actual choice cannot certify a neutral contour.
    @TaskLocal private static var actualChosenFills: [String: [Double]]?

    static func withChosenFills<Value>(_ choices: [(String, CGColor)],
                                      operation: () throws -> Value) throws -> Value {
        guard choices.count <= 256 else { throw Failure.invalidPacket }
        var result: [String: [Double]] = [:], seen = Set<String>()
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        for (owner, color) in choices {
            guard !owner.isEmpty, owner.utf8.count <= 512, seen.insert(owner).inserted else {
                throw Failure.invalidPacket
            }
            guard color.alpha.isFinite, abs(color.alpha - 1) <= 1e-9,
                  let converted = color.converted(to: space, intent: .defaultIntent, options: nil),
                  let channels = converted.components, channels.count == 4,
                  channels.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { continue }
            result[owner] = channels.prefix(3).map { Double($0) * 255 }
        }
        return try $actualChosenFills.withValue(result, operation: operation)
    }

    /// Present-outline proof, separate from the existing absent-outline guard.
    /// This only preserves a selected white core and its independently observed
    /// black band; it never selects a new fill or changes an observed width.
    private static func observedWhiteCoreWithNeutralBand(_ raw: [String: Any],
                                                        prediction: [String: Any], band: [Double]) -> Bool {
        func number(_ value: Any?) -> Double? {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
            return n.doubleValue
        }
        func close(_ a: [Double], _ b: [Double], _ limit: Double) -> Bool {
            zip(a,b).allSatisfy { abs($0 - $1) <= limit + 1e-9 }
        }
        func white(_ c: [Double]) -> Bool { c.min()! >= 245 && c.max()! - c.min()! <= 16 }
        func black(_ c: [Double]) -> Bool { c.max()! <= 32 && c.max()! - c.min()! <= 12 }
        func luminance(_ c: [Double]) -> Double {
            let v = c.map { value -> Double in
                let x = value / 255
                return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
            }
            return v[0]*0.2126 + v[1]*0.7152 + v[2]*0.0722
        }
        guard prediction["sourceOnly"] as? Bool == true,
              let id = raw["id"] as? String, let chosen = actualChosenFills?[id],
              let fill = prediction["fill"] as? [String: Any], let original = rgb(fill["rgb"]),
              white(chosen), white(original), close(chosen,original,3), black(band),
              let outline = prediction["outline"] as? [String: Any],
              let probability = number(outline["probability"]), (0.9...1).contains(probability),
              let measurement = outline["measurementEvidence"] as? [String: Any],
              measurement["reliable"] as? Bool == true,
              let rays = number(measurement["usableRays"]), rays >= 32,
              let shadow = prediction["shadow"] as? [String: Any],
              let shadowProbability = number(shadow["probability"]), (0...0.1).contains(shadowProbability),
              let pixels = prediction["pixelRoleEvidence"] as? [String: Any],
              pixels["GTAtInference"] as? Bool == false,
              pixels["featureContextPolicy"] as? String == "source-independent-paint-feature-context-v1",
              let samples = number(pixels["samples"]), samples >= 256,
              let roles = pixels["roles"] as? [String: Any] else { return false }
        if let rendered = raw["renderSourceOutlineRGB"] {
            guard let color = rgb(rendered), black(color) else { return false }
        }
        let a = luminance(chosen), b = luminance(band)
        guard (max(a,b)+0.05)/(min(a,b)+0.05) >= 7 else { return false }
        for (key, color) in [("fill",chosen),("outline",band)] {
            guard let role = roles[key] as? [String: Any],
                  let count = number(role["confidentSamples"]), (32...samples).contains(count),
                  let mean = number(role["meanProbability"]), (0...1).contains(mean),
                  let colors = role["observedColours"] as? [[String: Any]], !colors.isEmpty else { return false }
            var matched = false
            for row in colors {
                guard let observed = rgb(row["rgb"]), let mass = number(row["observedMass"]), (0...1).contains(mass) else { return false }
                if mass >= 0.8 && close(observed,color,5) { matched = true }
            }
            guard matched else { return false }
        }
        return true
    }

    static let bindingKeys: Set<String> = [
        "rgbSHA256", "maskSHA256", "contextSHA256", "rfSHA256", "segPrimarySHA256",
        "segBoundarySHA256", "ocrSHA256", "geometrySHA256", "rfModelWeightsSHA256", "checkpointSHA256"
    ]

    /// Immutable, non-Decodable capability. Only the authenticated corpus
    /// factory can create a page scope; raw JSON markers are not capabilities.
    final class SavedAcceptedPage: @unchecked Sendable {
        let sourceIdentity: String
        let encodedSourceSHA256: String
        let width: Int
        let height: Int
        let artifactHashes: [String: String]
        private let owners: [String: Data]
        fileprivate init(sourceIdentity: String, encodedSourceSHA256: String, width: Int, height: Int,
                         artifactHashes: [String: String], owners: [String: Data]) {
            self.sourceIdentity = sourceIdentity; self.encodedSourceSHA256 = encodedSourceSHA256
            self.width = width; self.height = height; self.artifactHashes = artifactHashes; self.owners = owners
        }
        fileprivate func matches(_ raw: [String: Any]) -> Bool {
            guard raw["sourceAppearanceBinding"] == nil, raw["sourceContourPaintBinding"] == nil,
                  let id = raw["id"] as? String, let expected = owners[id],
                  let actual = try? savedProjection(raw) else { return false }
            return actual == expected
        }
        var audit: [String: Any] {
            ["authority": "saved-accepted-source-appearance-v1", "freshInference": false,
             "cachedPredictionsRead": true, "sourceInferenceExecuted": false,
             "canonicalRGBIdentity": sourceIdentity, "encodedSourceSHA256": encodedSourceSHA256,
             "nativeDimensions": [width, height], "artifactSHA256": artifactHashes,
             "authenticatedOwners": owners.keys.sorted(), "liveHashesFabricated": false]
        }
    }
    @TaskLocal static var savedAcceptedPage: SavedAcceptedPage?

    /// Source evidence is supplied by the REAL cachedBinding helper in HostRaw.
    /// This protocol keeps the standalone appearance consumer independent of
    /// OCR record parsing/transport. No inference is executed through this seam.
    final class SavedAcceptedCorpus {
        private let pages: [String: [String: Any]]
        private let metadata: [String: [String: Any]]
        private let requestSHA: String
        private let manifestSHA: String
        init(request: Data, expectedRequestSHA256: String, manifest: Data, expectedManifestSHA256: String,
             selectedPages: Set<String>) throws {
            guard request.count <= 256 * 1024 * 1024, manifest.count <= 256 * 1024 * 1024,
                  !selectedPages.isEmpty, selectedPages.count <= 1000,
                  savedSHA(request) == expectedRequestSHA256, savedSHA(manifest) == expectedManifestSHA256,
                  validSHA256(expectedRequestSHA256), validSHA256(expectedManifestSHA256) else { throw Failure.sourceMismatch }
            func selected(_ data: Data) throws -> [String: [String: Any]] {
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let rows = object["pages"] as? [[String: Any]], rows.count <= 1000 else { throw Failure.invalidPacket }
                var seen = Set<String>(), result: [String: [String: Any]] = [:]
                for row in rows {
                    guard let id = row["page"] as? String, !id.isEmpty, seen.insert(id).inserted else { throw Failure.invalidPacket }
                    if selectedPages.contains(id) { result[id] = row }
                }
                guard Set(result.keys) == selectedPages else { throw Failure.sourceMismatch }
                return result
            }
            pages = try selected(request); metadata = try selected(manifest)
            requestSHA = expectedRequestSHA256; manifestSHA = expectedManifestSHA256
        }
        func metadataForPage(_ page: String) throws -> [String: Any] {
            guard let row = metadata[page] else { throw Failure.sourceMismatch }; return row
        }
        func auditPathForPage(_ page: String) throws -> String {
            guard let path = pages[page]?["audit"] as? String else { throw Failure.invalidPacket }; return path
        }
        func authenticate<B: NativeSavedAppearanceSourceEvidence>(page: String, source: B, maskSHA256: String,
            audit: Data, expectedAuditSHA256: String, receipt: Data, expectedReceiptSHA256: String,
            specRows: [[String: Any]]) throws -> SavedAcceptedPage {
            guard let original = pages[page], let meta = metadata[page],
                  let sourceSHA = source.verifiedEncodedSourceSHA256, validSHA256(sourceSHA),
                  sourceSHA == meta["sourceSHA256"] as? String, maskSHA256 == meta["maskSHA256"] as? String,
                  !source.contentIdentity.isEmpty, source.width == original["width"] as? Int,
                  source.height == original["height"] as? Int, source.width == meta["width"] as? Int,
                  source.height == meta["height"] as? Int, validSHA256(maskSHA256),
                  audit.count <= 16 * 1024 * 1024, receipt.count <= 16 * 1024 * 1024,
                  savedSHA(audit) == expectedAuditSHA256, savedSHA(receipt) == expectedReceiptSHA256,
                  let auditObject = try JSONSerialization.jsonObject(with: audit) as? [String: Any],
                  let receiptObject = try JSONSerialization.jsonObject(with: receipt) as? [String: Any],
                  receiptObject["auditSHA256"] as? String == expectedAuditSHA256,
                  receiptObject["page"] as? String == page,
                  receiptObject["width"] as? Int == source.width, receiptObject["height"] as? Int == source.height,
                  let originalRows = original["items"] as? [[String: Any]], originalRows.count <= 256,
                  let actualRows = auditObject["items"] as? [[String: Any]],
                  let ownerEntries = receiptObject["owners"] as? [[String: Any]] else { throw Failure.sourceMismatch }
            func index(_ rows: [[String: Any]]) throws -> [String: [String: Any]] {
                var result: [String: [String: Any]] = [:]
                for row in rows {
                    guard let id = row["id"] as? String, !id.isEmpty, result[id] == nil else { throw Failure.invalidPacket }
                    result[id] = row
                }; return result
            }
            let originals = try index(originalRows), actual = try index(actualRows), specs = try index(specRows), entries = try index(ownerEntries)
            guard Set(originals.keys) == Set(actual.keys), Set(originals.keys) == Set(specs.keys),
                  Set(originals.keys) == Set(entries.keys) else { throw Failure.sourceMismatch }
            var owners: [String: Data] = [:]
            for id in originals.keys.sorted() {
                let old = originals[id]!, row = actual[id]!, supplied = specs[id]!
                guard supplied["sourceAppearanceBinding"] == nil, supplied["sourceContourPaintBinding"] == nil,
                      let text = old["text"] as? String, !text.isEmpty,
                      row["textSHA256"] as? String == savedSHA(Data(text.utf8)),
                      row["utf16Expected"] as? Int == text.utf16.count, row["utf16Visible"] as? Int == text.utf16.count,
                      let prediction = old["sourcePredictedStyle"] as? [String: Any],
                      prediction["sourceOnly"] as? Bool == true, prediction["inferenceUsesGT"] as? Bool == false,
                      let font = row["fontPixels"] as? Double, font.isFinite, font > 0,
                      let pitch = row["lineHeightPixels"] as? Double, pitch.isFinite, pitch > 0,
                      let sourceFont = old["fontReference"] as? Double, sourceFont.isFinite, sourceFont > 0,
                      let width = old["outlineWidth"] as? Double, width.isFinite, width >= 0,
                      let frame = old["frame"] as? [Double], frame.count == 4,
                      frame.allSatisfy(\.isFinite), frame[2] > 0, frame[3] > 0,
                      let layout = row["layoutFrame"] as? [Double], layout.count == 4,
                      layout.allSatisfy(\.isFinite), layout[2] > 0, layout[3] > 0,
                      let weight = old["sourceFontWeight"] as? String, ["regular", "bold", "mixed"].contains(weight),
                      let bold = old["renderBold"] as? Bool, bold == (weight == "bold"),
                      row["renderFontName"] as? String == (bold ? "AppleSDGothicNeo-Bold" : "AppleSDGothicNeo-Regular"),
                      try savedEqual(row["sourceFrame"], old["frame"]),
                      try savedEqual(row["fillRGB"], old["fill"]), try savedEqual(row["displayOutlineRGB"], old["outline"])
                else { throw Failure.sourceMismatch }
                // Compare the COMPLETE item after this small explicit override
                // list. A spec cannot swap a prediction or any source field.
                var expected = old
                expected["fontReference"] = font; expected["sourceFontSize"] = sourceFont
                expected["layoutFrame"] = layout; expected["lineHeightEm"] = pitch / font
                expected["renderReplayStrokeRatio"] = max(0.035, width / sourceFont)
                expected["sourceAppearance"] = prediction
                guard try savedEqual(expected, supplied) else { throw Failure.sourceMismatch }
                var runtime = supplied
                runtime["sourceBounds"] = [frame[0] / Double(source.width), frame[1] / Double(source.height),
                    frame[2] / Double(source.width), frame[3] / Double(source.height)]
                runtime["fontSize"] = font
                owners[id] = try savedProjection(runtime)
            }
            return SavedAcceptedPage(sourceIdentity: source.contentIdentity, encodedSourceSHA256: sourceSHA,
                width: source.width, height: source.height,
                artifactHashes: ["acceptedRequest": requestSHA, "acceptedManifest": manifestSHA, "mask": maskSHA256,
                    "audit": expectedAuditSHA256, "receipt": expectedReceiptSHA256], owners: owners)
        }
    }
    private static func savedSHA(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func savedEqual(_ a: Any?, _ b: Any?) throws -> Bool {
        try JSONSerialization.data(withJSONObject: ["value": a ?? NSNull()], options: .sortedKeys) ==
            JSONSerialization.data(withJSONObject: ["value": b ?? NSNull()], options: .sortedKeys)
    }
    private static func savedProjection(_ raw: [String: Any]) throws -> Data {
        let keys = ["id", "text", "sourceBounds", "sourceMemberPolygons", "sourceStyleGroupID", "sourceFontSize",
                    "sourceFontWeight", "renderBold", "sourceAppearance", "sourcePredictedStyle", "renderSourceOutlineRGB",
                    "renderSourceOutlineWidthPx", "fill", "outline", "outlineWidth", "fontSize", "fontReference", "lineHeightEm"]
        return try JSONSerialization.data(withJSONObject: Dictionary(uniqueKeysWithValues:
            keys.map { ($0, raw[$0] ?? NSNull()) }), options: .sortedKeys)
    }
    private static func contourAuthority(_ raw: [String: Any]) -> Bool {
        // Supplying ANY live binding field always selects the unchanged live
        // contract. An authenticated replay never rescues a malformed live pair.
        if raw["sourceAppearanceBinding"] != nil || raw["sourceContourPaintBinding"] != nil {
            guard let validated = raw["sourceContourPaintBinding"] as? [String: String],
                  Set(validated.keys) == bindingKeys, validated.values.allSatisfy(validSHA256),
                  let binding = raw["sourceAppearanceBinding"] as? [String: String], binding == validated else { return false }
            return true
        }
        return savedAcceptedPage?.matches(raw) == true
    }

    /// Apply BEFORE palette/stroke selection and shaping, using source-local
    /// geometry. Retain all source heads separately from display decisions.
    static func apply(packet: Data, expectedBinding: [String: String], to item: [String: Any]) throws -> [String: Any] {
        guard packet.count <= 4 * 1024 * 1024,
              Set(expectedBinding.keys) == bindingKeys,
              expectedBinding.values.allSatisfy(validSHA256),
              let value = try JSONSerialization.jsonObject(with: packet) as? [String: Any],
              value["schema"] as? String == "aidoku-live-source-appearance-v1",
              value["sourceOnly"] as? Bool == true, value["freshInference"] as? Bool == true,
              value["GTAtInference"] as? Bool == false, value["cachedPredictionsRead"] as? Bool == false,
              let binding = value["binding"] as? [String: String] else { throw Failure.invalidPacket }
        guard binding == expectedBinding else { throw Failure.sourceMismatch }
        guard let prediction = value["prediction"] as? [String: Any],
              let fill = prediction["fill"] as? [String: Any], let fillRGB = rgb(fill["rgb"]),
              let outline = prediction["outline"] as? [String: Any], outline["present"] is Bool,
              let background = prediction["background"] as? [String: Any], rgb(background["rgb"]) != nil,
              let shadow = prediction["shadow"] as? [String: Any], shadow["present"] is Bool else {
            throw Failure.invalidPrediction
        }
        if outline["present"] as? Bool == true {
            guard rgb(outline["rgb"]) != nil, let width = outline["widthPx"] as? Double,
                  width.isFinite, width >= 0 else { throw Failure.invalidPrediction }
        }
        // Source shadow RGB is a composite observation. Unknown intrinsic blur
        // and opacity stay unknown; never invent them to enable a paint effect.
        if let color = shadow["rgb"], !(color is NSNull), rgb(color) == nil { throw Failure.invalidPrediction }
        if let offset = shadow["offsetPx"], !(offset is NSNull) {
            guard let xy = offset as? [Double], xy.count == 2, xy.allSatisfy(\.isFinite) else {
                throw Failure.invalidPrediction
            }
        }
        var result = item
        result["sourceAppearance"] = prediction
        result["sourceAppearanceBinding"] = binding
        // Set only after the independently supplied producer binding matched.
        // A saved appearance dictionary alone never opts into a paint mode.
        result["sourceContourPaintBinding"] = binding
        // This is the source-fill initial choice. Existing owned dominance and
        // restored-background BW stroke selection still own display treatment.
        result["ensembleDisplayFill"] = fillRGB
        result["ensemblePaletteAudit"] = [
            "sourceFill": fillRGB, "sourceStroke": outline["rgb"] ?? NSNull(),
            "sourceOutlinePresent": outline["present"] ?? false,
            "sourceBackground": background, "sourceShadow": shadow,
            "selectedOriginalInk": fillRGB, "displayFill": fillRGB,
            "displayFallback": false, "selectionPolicy": "fresh-source-estimator-fill-before-owned-dominance",
            "authority": "fresh source RF/seg/OCR inference; expected producer binding matched",
            "sourceAppearanceBinding": binding
        ] as [String: Any]
        if NativeSourceStyleConsistency.observedFillDominanceEnabled,
           let selected = NativeSourceStyleConsistency.observedFillDominance(prediction) {
            result["ensembleDisplayFill"] = selected.selectedRGB
            result["renderSourceFillRGB"] = selected.selectedRGB
            result["observedFillDisplaySelection"] = selected.audit
        }
        return result
    }

    /// Experimental paint selection is part of host resume identity too.
    static var sourceContourOnlyDiagnosticEnabled: Bool {
        ProcessInfo.processInfo.environment["AIDOKU_SOURCE_CONTOUR_ONLY"] == "1"
    }

    /// Explicit diagnostic opt-in for a bound single chromatic source contour.
    /// Default production painting retains the mandatory BW guard. Flag1 is a
    /// source-contour comparison outside the mandatory-outline quality contract.
    static func sourceContourOnly(_ raw: [String: Any]?) -> Bool {
        guard sourceContourOnlyDiagnosticEnabled,
              let raw, raw["sourceContourCohortVeto"] as? Bool != true,
              contourAuthority(raw),
              let prediction = raw["sourceAppearance"] as? [String: Any],
              let outline = prediction["outline"] as? [String: Any], outline["present"] as? Bool == true,
              let shadow = prediction["shadow"] as? [String: Any], shadow["present"] as? Bool == false,
              let font = (raw["sourceFontSize"] as? NSNumber)?.doubleValue, font.isFinite, font > 0,
              let width = (outline["widthPx"] as? NSNumber)?.doubleValue, width.isFinite, width > 0, width <= 256,
              let color = rgb(outline["rgb"]) else { return false }
        var bandColor = color, bandWidth = width
        if let rawLayers = outline["observedLayers"] {
            guard let layers = rawLayers as? [[String: Any]], layers.count <= 1 else { return false }
            if let layer = layers.first {
                guard let rgb = rgb(layer["rgb"]), let pixels = (layer["widthPx"] as? NSNumber)?.doubleValue,
                      pixels.isFinite, pixels > 0, pixels <= 256 else { return false }
                bandColor = rgb; bandWidth = pixels
            }
        }
        guard bandColor.max()! - bandColor.min()! >= 16 ||
              observedWhiteCoreWithNeutralBand(raw, prediction: prediction, band: bandColor) else { return false }
        if let rendered = raw["renderSourceOutlineRGB"] {
            // Both colours already passed the authenticated source authority above.
            // Cohort palette quantization may differ by up to three code values;
            // preserve all topology, width, shadow and complete-cohort gates.
            guard let rgb = rgb(rendered),
                  zip(rgb, bandColor).allSatisfy({ abs($0 - $1) <= 3 }) else { return false }
        }
        if let rendered = raw["renderSourceOutlineWidthPx"] {
            guard let pixels = (rendered as? NSNumber)?.doubleValue, pixels.isFinite,
                  abs(pixels - bandWidth) < 0.000001 else { return false }
        }
        return true
    }

    /// A source-style cohort cannot alternate between synthetic fill dilation
    /// and source-only contours. All members must independently qualify.
    static func annotateContourPolicies(_ input: [[String: Any]]) -> [[String: Any]] {
        var result = input.map { raw -> [String: Any] in
            var copy = raw; copy.removeValue(forKey: "sourceContourCohortVeto"); return copy
        }
        let groups = Dictionary(grouping: result.indices.filter { result[$0]["sourceStyleGroupID"] as? String != nil },
            by: { result[$0]["sourceStyleGroupID"] as! String })
        for indices in groups.values where indices.count > 1 {
            if !indices.allSatisfy({ sourceContourOnly(result[$0]) }) {
                for index in indices { result[index]["sourceContourCohortVeto"] = true }
            }
        }
        return result
    }

    private static func rgb(_ value: Any?) -> [Double]? {
        guard let values = value as? [Double], values.count == 3,
              values.allSatisfy({ $0.isFinite && (0...255).contains($0) }) else { return nil }
        return values
    }

    private static func validSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
