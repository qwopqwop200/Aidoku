import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// Source-content-bound OCR transport only. No rendering, inference, providers, file paths,
/// display coordinates, labels, detector CC maps, or inferred translations are retained.
/// promptVersion: technical-review-v1.
enum NativeMainEnsembleOCREvidence {
    static let maximumRecords = 4096
    static let maximumPageBytes = 2 * 1024 * 1024
    static let maximumArtifactBytes = 16 * 1024 * 1024

    enum Failure: Error { case binding, digest, schema, geometry, lexical, budget, duplicateStage }
    enum GeometryFailure: Error {
        case nonfinite, whollyOutsideRect, whollyOutsidePolygon, degeneratePolygon
        case unsupportedConcaveOrNonSimpleClipping, clippingVertexBudget, numericalIntersection
    }
    struct ProjectionFailure: Error {
        let stage: Stage
        let rowIndex: Int
        let reason: String
    }
    enum Space { case normalizedTopLeft; case originalPixels(width: Int, height: Int) }
    enum Stage: String, CaseIterable, Sendable {
        case finalRegions, nativeLines, detector, recognized, rejected, decoded
    }
    enum Schema {
        case readerFinalRegions, normalizedLines, nativeLinesPixels
        case detectorBoxesPixels, recognizerRegionsPixels, rejectedReadsPixels, decodedReadsPixels
        var stage: Stage {
            switch self {
            case .readerFinalRegions: .finalRegions
            case .normalizedLines, .nativeLinesPixels: .nativeLines
            case .detectorBoxesPixels: .detector
            case .recognizerRegionsPixels: .recognized
            case .rejectedReadsPixels: .rejected
            case .decodedReadsPixels: .decoded
            }
        }
    }

    struct Binding: Sendable {
        let contentIdentity: String // NativeRFDETRSourceImage sRGB identity, NEVER encoded-file SHA.
        let width: Int
        let height: Int
        let verifiedEncodedSourceSHA256: String?
        fileprivate init(_ source: NativeRFDETRSourceImage, fileSHA: String?) {
            contentIdentity = source.identity; width = source.width; height = source.height
            verifiedEncodedSourceSHA256 = fileSHA
        }
        fileprivate init(liveIdentity: String, original: CGImage) {
            contentIdentity = liveIdentity
            width = original.width
            height = original.height
            verifiedEncodedSourceSHA256 = nil
        }
        /// Legacy Ensemble100Page.sourceSHA256 is used as an equality token by old candidates.
        /// Prefix the domain so it cannot equal ANY encoded-file digest. Never compare it to a manifest SHA.
        var candidateIdentity: String { Self.candidateIdentity(for: contentIdentity) }
        static func candidateIdentity(for contentIdentity: String) -> String { "canonical-rgb8:" + contentIdentity }
    }

    struct Record: Sendable {
        let bounds: CGRect // normalized original top-left coordinates, including pixel-schema inputs
        let polygon: [CGPoint]
        let source: String?
        let translation: String?
        let confidence: Double?
        let geometryClipped: Bool
        fileprivate let attributes: Data // small, explicit projection; never the complete input row
        fileprivate init(bounds: CGRect, polygon: [CGPoint], source: String?, translation: String?,
                         confidence: Double?, geometryClipped: Bool, attributes: Data) {
            self.bounds = bounds; self.polygon = polygon; self.source = source
            self.translation = translation; self.confidence = confidence; self.attributes = attributes
            self.geometryClipped = geometryClipped
        }
        fileprivate var bytes: Int {
            attributes.count + (source?.utf8.count ?? 0) + (translation?.utf8.count ?? 0) + polygon.count * 16 + 64
        }
        fileprivate func row(width: Int, height: Int, pixels: Bool = false) throws -> [String: Any] {
            var result = try JSONSerialization.jsonObject(with: attributes) as! [String: Any]
            let sx = pixels ? Double(width) : 1, sy = pixels ? Double(height) : 1
            let points = polygon.isEmpty ? [CGPoint(x: bounds.minX, y: bounds.minY),
                CGPoint(x: bounds.maxX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.maxY),
                CGPoint(x: bounds.minX, y: bounds.maxY)] : polygon
            result["polygon"] = points.map { [Double($0.x) * sx, Double($0.y) * sy] }
            if !pixels {
                result["rect"] = ["x": Double(bounds.minX), "y": Double(bounds.minY),
                    "width": Double(bounds.width), "height": Double(bounds.height)]
                result["sourceBounds"] = [Double(bounds.minX), Double(bounds.minY), Double(bounds.width), Double(bounds.height)]
            }
            if let source { result[pixels ? "text" : "source"] = source }
            if let translation { result["translation"] = translation }
            if let confidence { result["confidence"] = confidence }
            return result
        }
    }

    struct StageRows: Sendable {
        let stage: Stage
        let records: [Record]
        fileprivate let contentIdentity: String
        fileprivate init(stage: Stage, records: [Record], contentIdentity: String) {
            self.stage = stage; self.records = records; self.contentIdentity = contentIdentity
        }
    }
    struct Packet: Sendable {
        let binding: Binding
        let stages: [Stage: [Record]] // missing key = unavailable; present [] = observed empty
        let retainedBytes: Int
        init(binding: Binding, stages: [StageRows]) throws {
            var map: [Stage: [Record]] = [:], bytes = 0, count = 0, points = 0
            for stage in stages {
                guard stage.contentIdentity == binding.contentIdentity else { throw Failure.binding }
                guard map[stage.stage] == nil else { throw Failure.duplicateStage }
                for record in stage.records {
                    bytes += record.bytes; count += 1; points += record.polygon.count
                    guard bytes <= maximumPageBytes, count <= maximumRecords, points <= 65_536 else { throw Failure.budget }
                }
                map[stage.stage] = stage.records
            }
            self.binding = binding; self.stages = map; retainedBytes = bytes
        }

        /// Call ONLY with the renderer's just-reconstructed, source-local items. They are NOT cached.
        /// Original lexical strings, including punctuation and UTF16 distinctions, pass through unchanged.
        func savedEvidence(currentOriginalItems: [[String: Any]], removalMaskAvailable: Bool) throws -> [String: Any] {
            let w = binding.width, h = binding.height
            var result: [String: Any] = ["sourceSHA256": binding.candidateIdentity,
                "sourceIdentityDomain": "canonical-rgb8;legacy-candidate-equality-token-not-file-SHA",
                "ocrSourceContentIdentity": binding.contentIdentity,
                "verifiedEncodedSourceSHA256": binding.verifiedEncodedSourceSHA256 as Any? ?? NSNull(),
                "originalItems": currentOriginalItems, "removalMaskAvailable": removalMaskAvailable,
                "ocrStageAvailability": Dictionary(uniqueKeysWithValues: Stage.allCases.map {
                    ($0.rawValue, stages[$0].map { "observed:\($0.count)" } ?? "unavailable")
                }), "ocrRetainedBytes": retainedBytes,
                "ocrClippedRecordCount": stages.values.reduce(0) { $0 + $1.filter(\.geometryClipped).count }]
            // All consumers receive one deliberate normalized regions schema, with original dimensions.
            // Native pixel lines are NOT passed as originalOCR.lines (legacy consumers disagree on its units).
            if let rows = stages[.finalRegions] ?? stages[.nativeLines] {
                result["originalOCR"] = ["width": w, "height": h,
                    "regions": try rows.map { try $0.row(width: w, height: h) },
                    "coordinateSpace": "normalized-top-left",
                    "authority": stages[.finalRegions] != nil ? "observed-final-regions" : "explicitly-normalized-native-lines"]
            }
            for (stage, key, container) in [(Stage.detector, "originalDetector", "boxes"),
                (.recognized, "originalRecognizer", "regions")] {
                if let rows = stages[stage] {
                    result[key] = [container: try rows.map { try $0.row(width: w, height: h, pixels: true) }]
                }
            }
            for (stage, key) in [(Stage.rejected, "originalRejectedReads"), (.decoded, "originalDecodedReads")] {
                if let rows = stages[stage] { result[key] = try rows.map { try $0.row(width: w, height: h, pixels: true) } }
            }
            return result
        }

        /// Lossless archive of this already projected invocation, including
        /// observed-empty/unavailable stages and pre-provider lexical fields.
        /// Attribute bytes stay private and byte-exact; no DB/model tensor is stored.
        func archivedData() throws -> Data {
            let rows: [[String: Any]] = Stage.allCases.compactMap { stage in
                guard let records = stages[stage] else { return nil }
                return ["stage": stage.rawValue, "records": records.map { record -> [String: Any] in
                    ["bounds": rectArray(record.bounds).map(archiveScalar),
                     "polygon": record.polygon.map { [archiveScalar(Double($0.x)), archiveScalar(Double($0.y))] },
                     "source": record.source as Any? ?? NSNull(),
                     "translation": record.translation as Any? ?? NSNull(),
                     "confidence": record.confidence.map(archiveScalar) as Any? ?? NSNull(),
                     "geometryClipped": record.geometryClipped,
                     "attributes": record.attributes.base64EncodedString()]
                }]
            }
            let data = try JSONSerialization.data(withJSONObject: ["schema": "aidoku-typed-ocr-packet-v2",
                "numericABI": "ieee754-float64-lowercase-hex16-v1",
                "contentIdentity": binding.contentIdentity, "width": binding.width, "height": binding.height,
                "stages": rows], options: [.sortedKeys])
            guard data.count <= maximumArtifactBytes else { throw Failure.budget }
            return data
        }
    }

    /// Source bytes and a frozen artifact digest must be verified by the host.
    /// Restore projected records directly: reprojecting normalized exports would
    /// lose original-pixel observation metadata and compact ownership channels.
    static func cachedPacket(data: Data, expectedArtifactSHA256: String, artifactSourceSHA256: String,
                             binding: Binding) throws -> Packet {
        guard binding.verifiedEncodedSourceSHA256 == artifactSourceSHA256,
              data.count <= maximumArtifactBytes, digest(data) == expectedArtifactSHA256 else { throw Failure.digest }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == Set(["schema", "numericABI", "contentIdentity", "width", "height", "stages"]),
              root["schema"] as? String == "aidoku-typed-ocr-packet-v2",
              root["numericABI"] as? String == "ieee754-float64-lowercase-hex16-v1",
              root["contentIdentity"] as? String == binding.contentIdentity,
              root["width"] as? Int == binding.width, root["height"] as? Int == binding.height,
              let stages = root["stages"] as? [[String: Any]], stages.count <= Stage.allCases.count else { throw Failure.schema }
        // The producer writes this canonical form. Re-encoding rejects repeated
        // JSON object keys that a permissive parser would otherwise overwrite.
        guard try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]) == data else { throw Failure.schema }
        var restored: [StageRows] = [], seen = Set<String>()
        for value in stages {
            try Task.checkCancellation()
            guard Set(value.keys) == Set(["stage", "records"]), let name = value["stage"] as? String,
                  seen.insert(name).inserted, let stage = Stage(rawValue: name),
                  let rows = value["records"] as? [[String: Any]], rows.count <= maximumRecords else { throw Failure.schema }
            let records = try rows.map { row -> Record in
                guard Set(row.keys) == Set(["bounds", "polygon", "source", "translation", "confidence", "geometryClipped", "attributes"]),
                      let rawBounds = row["bounds"], let clipped = row["geometryClipped"] as? NSNumber,
                      CFGetTypeID(clipped) == CFBooleanGetTypeID(), let encoded = row["attributes"] as? String,
                      let attributes = Data(base64Encoded: encoded), attributes.count <= maximumPageBytes else { throw Failure.schema }
                let box = try archivedVector(rawBounds, count: 4)
                let bounds = CGRect(x: box[0], y: box[1], width: box[2], height: box[3])
                guard let rawPolygon = row["polygon"] as? [Any], rawPolygon.count <= 4096 else { throw Failure.geometry }
                let polygon = try rawPolygon.map { point -> CGPoint in
                    let p = try archivedVector(point, count: 2)
                    return CGPoint(x: p[0], y: p[1])
                }
                guard valid(bounds), polygon.count <= 4096, polygon.allSatisfy(onCanvas),
                      polygon == (try observablePolygon(polygon)) else { throw Failure.geometry }
                let source = try string(row["source"]), translation = try string(row["translation"])
                let confidence = row["confidence"] is NSNull ? nil : try archivedScalar(row["confidence"])
                guard confidence.map({ (0...1).contains($0) }) ?? true else { throw Failure.schema }
                try validateArchivedAttributes(attributes, stage: stage, binding: binding,
                    bounds: bounds, polygon: polygon, geometryClipped: clipped.boolValue)
                return Record(bounds: bounds, polygon: polygon, source: source, translation: translation,
                    confidence: confidence, geometryClipped: clipped.boolValue, attributes: attributes)
            }
            restored.append(StageRows(stage: stage, records: records, contentIdentity: binding.contentIdentity))
        }
        guard restored.map(\.stage) == Stage.allCases.filter({ seen.contains($0.rawValue) }) else { throw Failure.schema }
        return try Packet(binding: binding, stages: restored)
    }

    private static func archiveScalar(_ value: Double) -> String {
        String(format: "%016llx", value.bitPattern)
    }

    private static func archivedScalar(_ raw: Any?) throws -> Double {
        guard let text = raw as? String, text.utf8.count == 16,
              text.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let bits = UInt64(text, radix: 16) else { throw Failure.schema }
        let value = Double(bitPattern: bits)
        guard value.isFinite else { throw Failure.geometry }
        return value
    }

    private static func archivedVector(_ raw: Any, count: Int) throws -> [Double] {
        guard let values = raw as? [Any], values.count == count else { throw Failure.geometry }
        return try values.map(archivedScalar)
    }

    /// Foundation may return NSDecimalNumber whose doubleValue is 1-2 ULP away
    /// from the correctly rounded stored decimal. Scope this correction to archive
    /// validation; original attributes and the live projector remain unchanged.
    private static func archivedAttributeNumbers(_ raw: Any) throws -> Any {
        if let decimal = raw as? NSDecimalNumber {
            guard let value = Double(decimal.stringValue), value.isFinite else { throw Failure.schema }
            return NSNumber(value: value)
        }
        if let rows = raw as? [Any] { return try rows.map(archivedAttributeNumbers) }
        if let value = raw as? [String: Any] { return try value.mapValues(archivedAttributeNumbers) }
        return raw
    }

    /// The JSON codec writes -0 but parses it as zero. Ignore only that numeric
    /// spelling for canonical-key validation, never bytes inside strings. The
    /// retained attribute data and authoritative hex scalars preserve their bits.
    private static func attributeCanonicalBytes(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var result = Data(), index = 0, quoted = false, escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 45, index + 1 < bytes.count, bytes[index + 1] == 48,
                    index + 2 == bytes.count || [9, 10, 13, 32, 44, 93, 125].contains(bytes[index + 2]) {
                result.append(48); index += 2; continue
            }
            result.append(byte); index += 1
        }
        return result
    }

    private static func validateArchivedAttributes(_ data: Data, stage: Stage, binding: Binding,
                                                   bounds: CGRect, polygon: [CGPoint], geometryClipped: Bool) throws {
        let allowed: Set<String> = ["id", "score", "sourceIndex", "sourceOrientation", "sourceSingleVerticalColumn",
            "rejectionReason", "nativeThreshold", "cacheHit", "sourceOCRAlternatives", "sourceMemberPolygons", "unitMemberRects",
            "rawUnitMemberRects", "clippedUnitMemberIndices", "rawSourceMemberPolygons", "sourceGeometryObservation", "sourceOwnedDetectorComponents",
            "sourceObservedExclusiveSubcolumns"]
        guard let storedValue = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = try archivedAttributeNumbers(storedValue) as? [String: Any],
              Set(value.keys).isSubset(of: allowed),
              let observation = value["sourceGeometryObservation"] as? [String: Any],
              observation["policy"] as? String == "observable-canvas-intersection-v1",
              observation["originalSourceSize"] as? [Int] == [binding.width, binding.height],
              ["normalized-top-left", "original-source-pixels"].contains(observation["inputCoordinateSpace"] as? String ?? "") else {
            throw Failure.schema
        }
        let canonical = try JSONSerialization.data(withJSONObject: storedValue, options: [.sortedKeys])
        guard attributeCanonicalBytes(canonical) == attributeCanonicalBytes(data) else { throw Failure.schema }
        for key in ["id", "sourceOrientation", "rejectionReason"] { _ = try string(value[key]) }
        for key in ["score", "sourceIndex", "nativeThreshold"] { _ = try number(value[key]) }
        for key in ["sourceSingleVerticalColumn", "cacheHit"] where value[key] != nil {
            guard let n = value[key] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw Failure.schema }
        }
        if let alternatives = value["sourceOCRAlternatives"] {
            guard alternatives is [Any] else { throw Failure.schema }
        }
        let rawMembers = value["rawSourceMemberPolygons"]
        if let members = value["sourceMemberPolygons"] {
            guard let polygons = members as? [[[Double]]], polygons.count <= 256,
                  polygons.allSatisfy({ polygon in
                      (3...16).contains(polygon.count) && polygon.allSatisfy {
                          $0.count == 2 && $0.allSatisfy(\.isFinite) && (0...Double(binding.width)).contains($0[0]) &&
                              (0...Double(binding.height)).contains($0[1])
                      }
                  }) else { throw Failure.geometry }
            if let rawMembers {
                guard let original = rawMembers as? [[[Double]]], original != polygons,
                      try observableMemberPolygons(original, binding: binding) == polygons else { throw Failure.geometry }
            }
        } else if rawMembers != nil { throw Failure.geometry }
        if let members = value["unitMemberRects"] {
            guard let rows = members as? [Any], rows.count <= maximumRecords,
                  let raw = value["rawUnitMemberRects"] as? [Any], raw.count == rows.count,
                  let clipped = value["clippedUnitMemberIndices"] as? [Int],
                  clipped.allSatisfy({ rows.indices.contains($0) }) else { throw Failure.schema }
            let normalized = observation["inputCoordinateSpace"] as? String == "normalized-top-left"
            let sx = normalized ? 1 : Double(binding.width), sy = normalized ? 1 : Double(binding.height)
            var observedClipped: [Int] = []
            for index in rows.indices {
                let projected = try rectangle(rows[index]), original = try rectangle(raw[index])
                let r = CGRect(x: original.minX / sx, y: original.minY / sy,
                    width: original.width / sx, height: original.height / sy)
                guard valid(projected), projected == (try observableRect(r)) else { throw Failure.geometry }
                if projected != r { observedClipped.append(index) }
            }
            guard clipped == observedClipped else { throw Failure.geometry }
        }
        let normalized = observation["inputCoordinateSpace"] as? String == "normalized-top-left"
        let sx = normalized ? 1 : Double(binding.width), sy = normalized ? 1 : Double(binding.height)
        let rawPolygon = try points(observation["rawPolygon"])
        let projectedPolygon = rawPolygon.map { CGPoint(x: $0.x / sx, y: $0.y / sy) }
        let rawRect: CGRect
        if let rect = observation["rawRect"], !(rect is NSNull) {
            let r = try rectangle(rect)
            rawRect = CGRect(x: r.minX / sx, y: r.minY / sy, width: r.width / sx, height: r.height / sy)
        } else {
            guard projectedPolygon.count >= 3 else { throw Failure.geometry }
            let xs = projectedPolygon.map(\.x), ys = projectedPolygon.map(\.y)
            rawRect = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
        let polygonClipped = projectedPolygon.contains { !onCanvas($0) }
        let unitClipped = !(value["clippedUnitMemberIndices"] as? [Int] ?? []).isEmpty
        let expectedBounds = try observableRect(rawRect), expectedPolygon = try observablePolygon(projectedPolygon)
        guard bounds == expectedBounds, polygon == expectedPolygon,
              observation["rectClipped"] as? Bool == (expectedBounds != rawRect),
              observation["polygonClipped"] as? Bool == polygonClipped,
              geometryClipped == (expectedBounds != rawRect || polygonClipped || unitClipped || rawMembers != nil),
              observation["observableGeometryOnly"] as? Bool == true,
              observation["offCanvasPixelsObserved"] as? Bool == false,
              observation["sourceCompletenessInferred"] as? Bool == false else { throw Failure.geometry }
        for key in ["sourceOwnedDetectorComponents", "sourceObservedExclusiveSubcolumns"] where value[key] != nil {
            guard stage == .finalRegions || stage == .nativeLines,
                  let summary = value[key] as? [String: Any], summary["version"] as? Int == 1,
                  summary["originalSourceSize"] as? [Int] == [binding.width, binding.height],
                  summary["coordinateSpace"] as? String == "normalized-top-left",
                  let components = summary["components"] as? [[String: Any]], components.count <= 256 else { throw Failure.schema }
            if key == "sourceObservedExclusiveSubcolumns" {
                guard summary["sourceIdentity"] as? String == binding.candidateIdentity else { throw Failure.binding }
            }
            for component in components {
                guard let raw = component["bounds"], valid(try rectangle(raw)),
                      let mean = try number(component["meanProbability"]), (0.9...1).contains(mean),
                      let pixels = try number(component["pixels"]), pixels > 0,
                      let parent = try number(component["parentBoxIndex"]), parent >= 0, parent < 4096,
                      parent.rounded() == parent else { throw Failure.geometry }
            }
        }
    }

    static func liveBinding(original: CGImage) throws -> Binding {
        Binding(try NativeRFDETRSourceImage.decode(original), fileSHA: nil)
    }

    static func liveBinding(source: NativeMainEnsemblePreparedDB.SourceBinding) -> Binding {
        Binding(liveIdentity: source.identity, original: source.original)
    }

    /// Host supplies bytes already read for this input. A file digest alone cannot bind an arbitrary CGImage.
    /// Compare canonical decoded pixels too; no DeviceRGB frame fingerprint is substituted for sRGB identity.
    static func cachedBinding(original: CGImage, encodedSource: Data, expectedSourceSHA256: String) throws -> Binding {
        guard encodedSource.count <= 64 * 1024 * 1024, digest(encodedSource) == expectedSourceSHA256,
              let encoded = CGImageSourceCreateWithData(encodedSource as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(encoded, 0, nil) else { throw Failure.digest }
        let actual = try NativeRFDETRSourceImage.decode(original), decoded = try NativeRFDETRSourceImage.decode(image)
        guard actual.identity == decoded.identity else { throw Failure.binding }
        return Binding(actual, fileSHA: expectedSourceSHA256)
    }

    /// Explicit artifact schema, verified source bytes, and artifact hash are all required.
    /// final.json's input PATH is not provenance and is never read or retained.
    static func cachedRows(data: Data, expectedArtifactSHA256: String, artifactSourceSHA256: String,
                           schema: Schema, binding: Binding) throws -> StageRows {
        // artifactSourceSHA256 comes from the parent's frozen source-to-artifact descriptor,
        // NOT a guessed filename, final.json.input, or the artifact's own unverified claim.
        guard binding.verifiedEncodedSourceSHA256 == artifactSourceSHA256, data.count <= maximumArtifactBytes,
              digest(data) == expectedArtifactSHA256 else { throw Failure.digest }
        let raw = try JSONSerialization.jsonObject(with: data)
        let envelope = raw as? [String: Any]
        let object = envelope?["value"] ?? raw
        let root = object as? [String: Any]
        let rows: Any?
        let space: Space
        switch schema {
        case .readerFinalRegions, .normalizedLines:
            guard envelope?["stage"] == nil else { throw Failure.schema }
            try dimensions(root, binding: binding, required: true)
            rows = root?[schema.stage == .finalRegions ? "regions" : "lines"]
            space = .normalizedTopLeft
        case .nativeLinesPixels:
            try dimensions(root, binding: binding, required: true)
            rows = root?["lines"]; space = .originalPixels(width: binding.width, height: binding.height)
        case .detectorBoxesPixels, .recognizerRegionsPixels, .rejectedReadsPixels, .decodedReadsPixels:
            try dimensions(root, binding: binding, required: false)
            switch schema {
            case .detectorBoxesPixels: rows = root?["boxes"]
            case .recognizerRegionsPixels: rows = root?["regions"]
            default: rows = object
            }
            space = .originalPixels(width: binding.width, height: binding.height)
        }
        guard let rows = rows as? [[String: Any]] else { throw Failure.schema }
        return try project(rows: rows, stage: schema.stage, space: space, binding: binding)
    }

    /// Live bridge for already-observed rows; the caller explicitly supplies their units and original dimensions.
    static func project(rows: [[String: Any]], stage: Stage, space: Space, binding: Binding) throws -> StageRows {
        guard rows.count <= maximumRecords else { throw Failure.budget }
        let sx: Double, sy: Double, normalizedInput: Bool
        switch space {
        case .normalizedTopLeft: sx = 1; sy = 1; normalizedInput = true
        case let .originalPixels(w, h):
            guard w == binding.width, h == binding.height, w > 0, h > 0 else { throw Failure.binding }
            sx = Double(w); sy = Double(h); normalizedInput = false
        }
        var records: [Record] = [], bytes = 0, pointCount = 0
        // Separate positive-only channel; never weakens complete-CC admission.
        let partial = NativeCausalPartialSourceProjector.project(rows,
            sourceIdentity: binding.candidateIdentity,
            originalSize: CGSize(width: binding.width, height: binding.height),
            enabled: stage == .finalRegions || stage == .nativeLines)
        // Keep ORIGINAL input ordinals even if later row projection clips/fails.
        for (index, row) in rows.enumerated() {
            do {
                try Task.checkCancellation()
                let rawPolygon = try points(row["polygon"])
                let normalizedPolygon = rawPolygon.map { CGPoint(x: $0.x / sx, y: $0.y / sy) }
                guard normalizedPolygon.isEmpty || normalizedPolygon.count >= 3 else { throw Failure.geometry }
                let polygon = try observablePolygon(normalizedPolygon)
                let normalizedRect: CGRect
                var rawRect: CGRect?
                if let value = row["rect"] ?? row["sourceBounds"] {
                    let raw = try rectangle(value)
                    rawRect = raw
                    normalizedRect = CGRect(x: raw.minX / sx, y: raw.minY / sy, width: raw.width / sx, height: raw.height / sy)
                } else if polygon.count >= 3 {
                    let xs = normalizedPolygon.map(\.x), ys = normalizedPolygon.map(\.y)
                    normalizedRect = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
                } else { throw Failure.geometry }
                let rect = try observableRect(normalizedRect)
                let polygonClipped = normalizedPolygon.contains { !onCanvas($0) }
                var geometryClipped = rect != normalizedRect || polygonClipped
                let source = try string(row["source"] ?? row["text"]), translation = try string(row["translation"])
                let confidence = try number(row["confidence"] ?? (stage == .nativeLines ? row["score"] : nil))
                if let confidence, !(0...1).contains(confidence) { throw Failure.schema }
                var attributes: [String: Any] = [:]
                // Never encode full detector seeds/probability ROIs or display state.
                // Retain only explicitly validated compact owned-component geometry;
                // this carries no glyph/font estimate or erasure authority.
                if (stage == .finalRegions || stage == .nativeLines),
                   let owned = NativeSourceOwnedComponentProjection.project(row["detectorSeedEvidence"],
                        width: binding.width, height: binding.height) {
                    attributes["sourceOwnedDetectorComponents"] = owned
                }
                if let observed = partial.sourceObservedExclusiveSubcolumnsByRow[index] {
                    attributes["sourceObservedExclusiveSubcolumns"] = observed
                }
                for key in ["id", "score", "sourceIndex", "sourceOrientation", "sourceSingleVerticalColumn",
                            "rejectionReason", "nativeThreshold", "cacheHit"] {
                    if let value = row[key], !(value is NSNull) {
                        switch key {
                        case "score", "sourceIndex", "nativeThreshold": _ = try number(value)
                        case "sourceSingleVerticalColumn", "cacheHit":
                            guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw Failure.schema }
                        default: _ = try string(value)
                        }
                        attributes[key] = value
                    }
                }
                if normalizedInput {
                    for key in ["sourceOCRAlternatives"] {
                        if let value = row[key], !(value is NSNull) {
                            guard value is [Any] else { throw Failure.schema }
                            attributes[key] = value
                        }
                    }
                }
                // This field is always original source pixels, even when the
                // containing Reader row is normalized. Preserve observed quads;
                // reconstructing rectangles loses detector angle/ownership.
                if let members = row["sourceMemberPolygons"] {
                    guard let raw = members as? [[[Double]]] else { throw Failure.geometry }
                    let visible = try observableMemberPolygons(raw, binding: binding)
                    pointCount += visible.reduce(0) { $0 + $1.count }
                    if !visible.isEmpty { attributes["sourceMemberPolygons"] = visible }
                    if visible != raw {
                        attributes["rawSourceMemberPolygons"] = raw
                        geometryClipped = true
                    }
                }
                if let members = row["unitMemberRects"] as? [Any] {
                    var rawMembers: [[Double]] = [], clippedMemberIndices: [Int] = []
                    attributes["unitMemberRects"] = try members.enumerated().map { index, value -> [String: Double] in
                        let raw = try rectangle(value)
                        let r = CGRect(x: raw.minX / sx, y: raw.minY / sy, width: raw.width / sx, height: raw.height / sy)
                        let clipped = try observableRect(r)
                        rawMembers.append(rectArray(raw))
                        if clipped != r { clippedMemberIndices.append(index) }
                        return ["x": clipped.minX, "y": clipped.minY, "width": clipped.width, "height": clipped.height]
                    }
                    attributes["rawUnitMemberRects"] = rawMembers
                    attributes["clippedUnitMemberIndices"] = clippedMemberIndices
                    geometryClipped = geometryClipped || !clippedMemberIndices.isEmpty
                }
                attributes["sourceGeometryObservation"] = [
                    "policy": "observable-canvas-intersection-v1",
                    "inputCoordinateSpace": normalizedInput ? "normalized-top-left" : "original-source-pixels",
                    "originalSourceSize": [binding.width, binding.height],
                    "rawRect": rawRect.map(rectArray) as Any? ?? NSNull(),
                    "rawPolygon": rawPolygon.map { [Double($0.x), Double($0.y)] },
                    "rectClipped": rect != normalizedRect, "polygonClipped": polygonClipped,
                    "polygonMethod": polygonClipped ? "convex-Sutherland-Hodgman-unit-canvas-intersection" : "unchanged",
                    "polygonAuthority": rawPolygon.isEmpty ? "bbox-derived-not-segmentation" : "observed-source-vertices",
                    "observableGeometryOnly": true, "offCanvasPixelsObserved": false,
                    "sourceCompletenessInferred": false, "textAndTranslationUTF16Unchanged": true
                ] as [String: Any]
                guard JSONSerialization.isValidJSONObject(attributes) else { throw Failure.schema }
                let data = try JSONSerialization.data(withJSONObject: attributes, options: [.sortedKeys])
                let record = Record(bounds: rect, polygon: polygon, source: source, translation: translation,
                    confidence: confidence, geometryClipped: geometryClipped, attributes: data)
                bytes += record.bytes; pointCount += polygon.count
                guard bytes <= maximumPageBytes, pointCount <= 65_536 else { throw Failure.budget }
                records.append(record)
            } catch is CancellationError { throw CancellationError() }
            catch { throw ProjectionFailure(stage: stage, rowIndex: index, reason: String(reflecting: error)) }
        }
        return StageRows(stage: stage, records: records, contentIdentity: binding.contentIdentity)
    }

    final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var packets: [String: Packet] = [:]
        private var order: [String] = []
        private var pins = NativeMainEnsembleEvidenceLease.Registry()

        /// The parent already decoded the canonical RGB identity. Reuse it
        /// exactly; no encoded-file SHA, page key or second image decode.
        /// Called without the parent lock; callback takes only this store lock.
        func lease(contentIdentity: String) throws -> NativeMainEnsembleEvidenceLease {
            lock.lock(); defer { lock.unlock() }
            let token = try pins.acquire(identity: contentIdentity)
            return NativeMainEnsembleEvidenceLease { [self] in
                lock.lock(); defer { lock.unlock() }
                pins.release(token)
                trim()
            }
        }

        private func trim() {
            while order.count > 3 {
                guard let index = pins.evictionIndex(in: order) else { break }
                packets.removeValue(forKey: order.remove(at: index))
            }
        }
        /// Replace one complete invocation packet. Never merge nil stages with stale results from an older OCR pass.
        func register(_ packet: Packet, original: CGImage, source: NativeMainEnsemblePreparedDB.SourceBinding? = nil) throws {
            let identity: String
            if let source {
                guard source.original === original else { throw Failure.binding }
                identity = source.identity
            } else {
                identity = try NativeRFDETRSourceImage.decode(original).identity
            }
            guard identity == packet.binding.contentIdentity,
                  original.width == packet.binding.width, original.height == packet.binding.height else { throw Failure.binding }
            lock.lock(); defer { lock.unlock() }
            packets[identity] = packet
            order.removeAll { $0 == identity }; order.append(identity)
            trim()
        }
        func read(original: CGImage) throws -> Packet? {
            try read(contentIdentity: NativeRFDETRSourceImage.decode(original).identity)
        }
        func read(contentIdentity identity: String) -> Packet? {
            lock.lock(); defer { lock.unlock() }
            guard let packet = packets[identity] else { return nil }
            order.removeAll { $0 == identity }; order.append(identity)
            return packet
        }
        var retainedPageCount: Int { lock.lock(); defer { lock.unlock() }; return packets.count }
    }

    private static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private static func dimensions(_ object: [String: Any]?, binding: Binding, required: Bool) throws {
        if !required && object?["width"] == nil && object?["height"] == nil { return }
        guard try number(object?["width"]) == Double(binding.width),
              try number(object?["height"]) == Double(binding.height) else { throw Failure.binding }
    }
    private static func number(_ value: Any?) throws -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { throw Failure.schema }
        return n.doubleValue
    }
    private static func string(_ value: Any?) throws -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let s = value as? String, s.utf8.count <= maximumPageBytes else { throw Failure.lexical }
        return s
    }
    private static func rectangle(_ value: Any) throws -> CGRect {
        let a: [Double]
        if let pairs = value as? [Double], pairs.count == 4 { a = pairs }
        else if let d = value as? [String: Any], let x = try number(d["x"]), let y = try number(d["y"]),
                let w = try number(d["width"]), let h = try number(d["height"]) { a = [x, y, w, h] }
        else { throw Failure.geometry }
        guard a.allSatisfy(\.isFinite), a[2] > 0, a[3] > 0 else { throw Failure.geometry }
        return CGRect(x: a[0], y: a[1], width: a[2], height: a[3])
    }
    private static func points(_ raw: Any?) throws -> [CGPoint] {
        guard let raw, !(raw is NSNull) else { return [] }
        guard let rows = raw as? [Any], rows.count <= 4096 else { throw Failure.geometry }
        return try rows.map { value in
            if let pair = value as? [Double], pair.count == 2 { return CGPoint(x: pair[0], y: pair[1]) }
            if let d = value as? [String: Any], let x = try number(d["x"]), let y = try number(d["y"]) { return CGPoint(x: x, y: y) }
            throw Failure.geometry
        }
    }
    private static func valid(_ r: CGRect) -> Bool {
        [r.minX, r.minY, r.width, r.height].allSatisfy(\.isFinite) && r.width > 0 && r.height > 0 &&
            r.minX >= 0 && r.minY >= 0 && r.maxX <= 1 && r.maxY <= 1
    }

    private static let canvas = CGRect(x: 0, y: 0, width: 1, height: 1)
    private static func rectArray(_ r: CGRect) -> [Double] {
        [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)]
    }
    private static func onCanvas(_ p: CGPoint) -> Bool {
        p.x.isFinite && p.y.isFinite && (0...1).contains(p.x) && (0...1).contains(p.y)
    }
    /// BODY polygons are measured in original pixels even in a normalized Reader row.
    /// A rotated detection can cross a page edge. Intersect its edges with the canvas and
    /// retain its original coordinates separately for replay. Interior members stay byte-exact.
    private static func observableMemberPolygons(_ raw: [[[Double]]], binding: Binding) throws -> [[[Double]]] {
        guard raw.count <= 256 else { throw Failure.budget }
        let width = Double(binding.width), height = Double(binding.height)
        return try raw.map { polygon in
            guard (3...16).contains(polygon.count),
                  polygon.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) else { throw Failure.geometry }
            if polygon.allSatisfy({ (0...width).contains($0[0]) && (0...height).contains($0[1]) }) { return polygon }
            let normalized = polygon.map { CGPoint(x: $0[0] / width, y: $0[1] / height) }
            let clipped = try observablePolygon(normalized)
            guard (3...16).contains(clipped.count) else { throw Failure.geometry }
            return clipped.map { [$0.x * width, $0.y * height] }
        }
    }
    private static func observableRect(_ r: CGRect) throws -> CGRect {
        guard [r.minX, r.minY, r.maxX, r.maxY, r.width, r.height].allSatisfy(\.isFinite) else { throw GeometryFailure.nonfinite }
        // Preserve already-observable widths bit-for-bit: maxX-minX can introduce an avoidable ULP change.
        if valid(r) { return r }
        let clipped = r.intersection(canvas)
        guard valid(clipped) else { throw GeometryFailure.whollyOutsideRect }
        return clipped
    }
    private static func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Double {
        Double((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x))
    }
    private static func signedArea(_ p: [CGPoint]) -> Double {
        guard p.count >= 3 else { return 0 }
        return (1..<(p.count - 1)).reduce(0) { $0 + cross(p[0], p[$1], p[$1 + 1]) } / 2
    }
    private static func compact(_ points: [CGPoint]) -> [CGPoint] {
        var result: [CGPoint] = []
        for point in points where result.last != point { result.append(point) }
        if result.count > 1 && result.first == result.last { result.removeLast() }
        return result
    }
    /// Only crossing polygons need repair. Existing in-canvas geometry remains unaltered.
    /// A convex ring has one convex intersection. Concave/multipart/hole cases cannot be safely
    /// encoded as this contract's one ring; abstain explicitly rather than joining parts or clamping vertices.
    private static func observablePolygon(_ raw: [CGPoint]) throws -> [CGPoint] {
        guard raw.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { throw GeometryFailure.nonfinite }
        guard raw.contains(where: { !onCanvas($0) }) else { return raw }
        var p = compact(raw)
        guard p.count >= 3 else { throw GeometryFailure.degeneratePolygon }
        guard p.count <= 64 else { throw GeometryFailure.clippingVertexBudget }
        let area = signedArea(p)
        guard area.isFinite else { throw GeometryFailure.nonfinite }
        guard area != 0 else { throw GeometryFailure.degeneratePolygon }
        let sign: Double = area > 0 ? 1 : -1
        // A repeated traversal of a convex ring can satisfy all half-planes but is not a simple ring.
        for i in p.indices {
            for j in p.indices where j > i && p[i] == p[j] {
                throw GeometryFailure.unsupportedConcaveOrNonSimpleClipping
            }
        }
        // Every vertex must lie in every oriented edge half-plane. This rejects concave rings,
        // bow-ties, star winding and duplicated/non-simple traversals before any intersection.
        for i in p.indices {
            let a = p[i], b = p[(i + 1) % p.count]
            for point in p {
                let value = cross(a, b, point)
                guard value.isFinite else { throw GeometryFailure.nonfinite }
                guard sign * value >= 0 else { throw GeometryFailure.unsupportedConcaveOrNonSimpleClipping }
            }
        }
        // Axis half-planes x>=0, x<=1, y>=0, y<=1. Intersections, not pointwise coordinate clamps.
        for edge in 0..<4 {
            guard !p.isEmpty else { throw GeometryFailure.whollyOutsidePolygon }
            func coordinate(_ point: CGPoint) -> Double { edge < 2 ? Double(point.x) : Double(point.y) }
            let boundary: Double = edge % 2 == 0 ? 0 : 1
            func inside(_ point: CGPoint) -> Bool { edge % 2 == 0 ? coordinate(point) >= boundary : coordinate(point) <= boundary }
            func intersection(_ a: CGPoint, _ b: CGPoint) throws -> CGPoint {
                let av = coordinate(a), bv = coordinate(b), t = (boundary - av) / (bv - av)
                guard t.isFinite, (0...1).contains(t) else { throw GeometryFailure.numericalIntersection }
                let other = edge < 2 ? (1 - t) * Double(a.y) + t * Double(b.y) : (1 - t) * Double(a.x) + t * Double(b.x)
                guard other.isFinite else { throw GeometryFailure.numericalIntersection }
                return edge < 2 ? CGPoint(x: boundary, y: other) : CGPoint(x: other, y: boundary)
            }
            var output: [CGPoint] = [], previous = p.last!
            for current in p {
                if inside(current) {
                    if !inside(previous) { output.append(try intersection(previous, current)) }
                    output.append(current)
                } else if inside(previous) { output.append(try intersection(previous, current)) }
                previous = current
            }
            p = compact(output)
        }
        guard p.count >= 3, signedArea(p).isFinite, abs(signedArea(p)) > 0 else { throw GeometryFailure.whollyOutsidePolygon }
        guard p.allSatisfy(onCanvas) else { throw GeometryFailure.numericalIntersection }
        return p
    }
}
