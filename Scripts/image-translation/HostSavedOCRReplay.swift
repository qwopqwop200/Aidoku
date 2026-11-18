import CoreGraphics
import Foundation
import CryptoKit

// BEGIN SAVED OCR CONTENT IDENTITY
/// Hash the exact replay snapshot and linked source pixels, not just their paths.
enum HostSavedOCRIdentity {
    static func fileSHA256(_ url: URL) throws -> String {
        var hash = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func digest(directory: URL) throws -> String {
        var hash = SHA256()
        for name in ["final.json", "input.png"] {
            hash.update(data: Data(name.utf8))
            let handle = try FileHandle(forReadingFrom: directory.appendingPathComponent(name))
            defer { try? handle.close() }
            var count: UInt64 = 0
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                count += UInt64(chunk.count)
                hash.update(data: chunk)
            }
            // Length-delimit each file to keep the combined hash unambiguous.
            hash.update(data: Data("\u{0}\(count)\u{0}".utf8))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
// END SAVED OCR CONTENT IDENTITY

/// Reuses the completed OCR region snapshot without repeating detection or recognition.
enum HostSavedOCRReplay {
    static let groupingPolicy = "saved-primary-source-" + NativeParagraphFragmentGrouping.policyVersion

    struct Result {
        let regions: [ReaderTranslationRegion]
        let originalCount: Int
        let recoveredLineages: Int
        let merged: [[String]]
        let split: [String: [String]]
        let splitBodies: [String: [Int]]
        let evidenceDirectory: String
    }
    struct Rect: Decodable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        var cg: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }

    struct Point: Decodable {
        let x: Double
        let y: Double
        var cg: CGPoint { CGPoint(x: x, y: y) }
    }

    struct Balloon: Decodable {
        let rect: Rect
        let center: Point
        let spans: [Double]
        let members: Int?
        let contourVerified: Bool?
        let modelEstimated: Bool?
        var native: ReaderTranslationBalloonInterior {
            .init(rect: rect.cg, center: center.cg, spans: spans,
                members: members, contourVerified: contourVerified, modelEstimated: modelEstimated)
        }
    }

    struct Region: Decodable {
        let id: String
        let rect: Rect
        let source: String
        let polygon: [Point]
        let confidence: Double
        let sourceOrientation: String
        let sourceSingleVerticalColumn: Bool?
        let sourceImageAspectRatio: Double?
        let translationOrder: Int?
        let translationOrderVersion: String?
        let auxiliaryInkRects: [Rect]
        let auxiliaryInkPolygons: [[Point]]
        let balloonInterior: Balloon?
        let unitMemberRects: [Rect]
        let isRecoveredLine: Bool
        let isOccludedFinePrint: Bool
        let sourceRoleEvidence: NativeTranslationRoleEvidence?
        let postLLMContentEvidence: NativePostLLMContentReclassifier.Evidence?
        let sourceOCRAlternatives: [ReaderTranslationSourceOCRAlternative]
        let detectorSeedEvidence: [NativeOCRDetectorSeedEvidence]?

        var native: ReaderTranslationRegion {
            var region = ReaderTranslationRegion(id: id, rect: rect.cg, source: source)
            region.polygon = polygon.map(\.cg)
            region.confidence = confidence
            region.sourceOrientation = BrowserOCRSourceOrientation(rawValue: sourceOrientation) ?? .unknown
            region.sourceSingleVerticalColumn = sourceSingleVerticalColumn
            region.sourceImageAspectRatio = sourceImageAspectRatio
            region.translationOrder = translationOrder
            region.translationOrderVersion = translationOrderVersion
            region.auxiliaryInkRects = auxiliaryInkRects.map(\.cg)
            region.auxiliaryInkPolygons = auxiliaryInkPolygons.map { $0.map(\.cg) }
            region.balloonInterior = balloonInterior?.native
            region.unitMemberRects = unitMemberRects.map(\.cg)
            region.isRecoveredLine = isRecoveredLine
            region.isOccludedFinePrint = isOccludedFinePrint
            region.sourceRoleEvidence = sourceRoleEvidence
            region.postLLMContentEvidence = postLLMContentEvidence
            region.sourceOCRAlternatives = sourceOCRAlternatives
            region.detectorSeedEvidence = detectorSeedEvidence
            return region
        }
    }

    private struct Page: Decodable {
        let input: String
        let width: Int
        let height: Int
        let mode: String
        let regions: [Region]
    }

    static func load(from directory: URL, expectedInput: URL, imageSize: CGSize) throws -> [ReaderTranslationRegion] {
        try loadGrouped(from: directory, expectedInput: expectedInput, imageSize: imageSize).regions
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dataDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            struct Bytes: Decodable { let base64: String }
            let value = try (try? c.decode(String.self)) ?? c.decode(Bytes.self).base64
            guard let bytes = Data(base64Encoded: value) else { throw CocoaError(.coderReadCorrupt) }
            return bytes
        }
        return decoder
    }

    /// Exact captured Reader cohort ingress for stage-local request generation.
    /// This DOES NOT regroup, refresh RF, classify, translate or render. The
    /// caller must attest the actual final receipt and original encoded bytes;
    /// upstream-changing candidates cannot relabel this as newly grouped output.
    static func loadCapturedOwners(from directory: URL, expectedInput: URL, imageSize: CGSize,
                                   expectedEncodedSHA256: String, expectedFinalSHA256: String) throws -> [ReaderTranslationRegion] {
        guard try HostSavedOCRIdentity.fileSHA256(expectedInput) == expectedEncodedSHA256,
              try HostSavedOCRIdentity.fileSHA256(directory.appendingPathComponent("final.json")) == expectedFinalSHA256 else {
            throw HostError.message("Captured owner source/final receipt changed")
        }
        return try loadGrouped(from: directory, expectedInput: expectedInput, imageSize: imageSize,
            capturedOwnersOnly: true).regions
    }


    /// Restore saved evidence, never manufacture fresh primary provenance from
    /// aggregate OCR strings. Follow only the replay's recorded ancestry.
    static func loadGrouped(from directory: URL, expectedInput: URL, imageSize: CGSize,
                            capturedOwnersOnly: Bool = false) throws -> Result {
        func matchesInput(_ path: String?) -> Bool {
            guard let path else { return false }
            if capturedOwnersOnly {
                return URL(fileURLWithPath: path).resolvingSymlinksInPath() == expectedInput.resolvingSymlinksInPath()
            }
            return path == expectedInput.path
        }
        let page = try decoder().decode(Page.self,
            from: Data(contentsOf: directory.appendingPathComponent("final.json")))
        guard (page.mode == "translation" || (capturedOwnersOnly && page.mode == "ocr-only")), matchesInput(page.input),
              page.width == Int(imageSize.width), page.height == Int(imageSize.height),
              page.regions.count <= (capturedOwnersOnly ? 4096 : 256),
              Set(page.regions.map(\.id)).count == page.regions.count,
              page.regions.allSatisfy({ region in
                  let r = region.rect.cg
                  return [r.minX, r.minY, r.maxX, r.maxY].allSatisfy(\.isFinite) &&
                      r.minX >= 0 && r.minY >= 0 && r.maxX <= 1.000001 && r.maxY <= 1.000001 &&
                      r.width > 0 && r.height > 0 && !region.source.isEmpty
              }) else {
            throw HostError.message("Saved OCR snapshot does not match this input: \(directory.path)")
        }
        var regions = page.regions.map { saved in
            var region = saved.native
            // Regrouping can change final owners and their output evidence.
            // The saved-replay caller refreshes RF signals after this pass.
            if !capturedOwnersOnly { region.postLLMContentEvidence = nil }
            return region
        }
        var current = directory.resolvingSymlinksInPath(), visited = Set<String>()
        var records: [[String: Any]] = [], rf: [String: Any]?
        var evidenceDirectory = directory.path
        // A historical translation-only snapshot may have dropped transient
        // primary tables. Resolve its original capture, with cycle/size bounds.
        for _ in 0..<16 {
            guard visited.insert(current.resolvingSymlinksInPath().path).inserted else {
                throw HostError.message("Saved OCR ancestry cycle: \(current.path)")
            }
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: current.appendingPathComponent("final.json"))) as? [String: Any]
            guard let saved, matchesInput(saved["input"] as? String),
                  saved["width"] as? Int == page.width, saved["height"] as? Int == page.height,
                  let sourceRegions = saved["regions"] as? [[String: Any]] else {
                throw HostError.message("Saved OCR ancestry does not match input: \(current.path)")
            }
            records += sourceRegions
            let files = try FileManager.default.contentsOfDirectory(at: current, includingPropertiesForKeys: nil)
            if let path = files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).last(where: { $0.lastPathComponent.hasSuffix("-rf-layout-evidence.json") }) {
                let envelope = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]
                rf = envelope?["value"] as? [String: Any]; evidenceDirectory = current.path
                break
            }
            guard let path = files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).last(where: { $0.lastPathComponent.hasSuffix("-saved-ocr-replay.json") }),
                  let envelope = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any],
                  let value = envelope["value"] as? [String: Any], let source = value["source"] as? String else { break }
            current = URL(fileURLWithPath: source).standardizedFileURL.resolvingSymlinksInPath()
        }
        var tables: [String: NativeOCRAcceptedSource.PacketTable] = [:]
        func decode<T: Decodable>(_ type: T.Type, _ value: Any) throws -> T {
            try decoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
        }
        func points(_ value: Any?) throws -> [CGPoint] {
            guard let value, !(value is NSNull) else { return [] }
            return try decode([Point].self, value).map(\.cg)
        }
        func seeds(_ value: Any?) throws -> [NativeOCRDetectorSeedEvidence]? {
            guard let value, !(value is NSNull) else { return nil }
            return try decode([NativeOCRDetectorSeedEvidence].self, value)
        }
        for i in regions.indices {
            let r = regions[i]
            guard let record = records.first(where: { record in
                guard record["id"] as? String == r.id, record["source"] as? String == r.source,
                      let box = record["rect"] as? [String: Double],
                      let source = record["acceptedSource"] as? [String: Any], source["membership"] is [String: Any] else { return false }
                return ["x": r.rect.minX, "y": r.rect.minY, "width": r.rect.width, "height": r.rect.height].allSatisfy { key, coordinate in
                    box[key].map { abs($0 - coordinate) < 1e-12 } ?? false
                }
            }), let source = record["acceptedSource"] as? [String: Any],
                  let member = source["membership"] as? [String: Any],
                  let table = member["table"] as? [String: Any], let identity = table["operationID"] as? String,
                  let body = member["body"] as? [Int], let untracked = member["hasUntrackedInputs"] as? Bool else {
                throw HostError.message("Missing exact saved primary lineage: \(directory.path)/\(r.id)")
            }
            if tables[identity] == nil {
                guard table["width"] as? Int == page.width, table["height"] as? Int == page.height,
                      let packets = table["packets"] as? [[String: Any]], packets.count <= 4096 else {
                    throw HostError.message("Invalid saved primary table")
                }
                tables[identity] = .init(packets: try packets.map { value in
                    guard let text = value["text"] as? String, let score = value["score"] as? Double else { throw CocoaError(.coderReadCorrupt) }
                    return .init(polygon: try points(value["polygon"]), text: text, score: score,
                        orientation: .init(tolerantRawValue: value["orientation"] as? String),
                        orientationIsEstimated: value["orientationIsEstimated"] as? Bool ?? false,
                        sourceTileBounds: try (value["sourceTileBounds"] as? [String: Any]).map { try decode(Rect.self, $0).cg },
                        erasurePolygons: try (value["erasurePolygons"] as? [Any] ?? []).map(points),
                        detectorSeedEvidence: try seeds(value["detectorSeedEvidence"]),
                        layoutPolygon: try (value["layoutPolygon"] as? [Any]).map(points))
                }, width: page.width, height: page.height)
            }
            let restored = tables[identity]!, readings = Set(member["readings"] as? [Int] ?? []), unknown = Set(member["unknownDedup"] as? [Int] ?? [])
            guard Set(body).union(readings).union(unknown).allSatisfy(restored.packets.indices.contains) else { throw CocoaError(.coderReadCorrupt) }
            regions[i].acceptedSource = .init(.init(table: restored, body: Set(body), readings: readings,
                unknownDedup: unknown, hasUntrackedInputs: untracked))
            // Keep aggregate-region support exactly as captured. The restored
            // table already preserves every original packet's DB evidence;
            // backfilling only some aggregates creates mixed evidence versions.
        }
        if capturedOwnersOnly {
            return .init(regions: regions, originalCount: page.regions.count,
                recoveredLineages: regions.filter { $0.acceptedSource.membership != nil }.count,
                merged: [], split: [:], splitBodies: [:], evidenceDirectory: directory.path)
        }
        guard let rf, rf["sourceWidth"] as? Int == page.width, rf["sourceHeight"] as? Int == page.height,
              let primitives = rf["primitives"] as? [[String: Any]], primitives.count <= 1024 else {
            throw HostError.message("Missing matching saved RF evidence: \(directory.path)")
        }
        let scopes = try primitives.filter { $0["class"] as? Int == 1 }.map { value -> NativeParagraphFragmentGrouping.TextScope in
            guard let owner = value["queryID"] as? Int, let confidence = value["confidence"] as? Double,
                  let box = value["sourceBounds"] else { throw CocoaError(.coderReadCorrupt) }
            return .init(owner: owner, box: try decode(Rect.self, box).cg.applying(
                .init(scaleX: 1 / CGFloat(page.width), y: 1 / CGFloat(page.height))), confidence: confidence)
        }
        var merged: [[String]] = [], split: [String: [String]] = [:], splitBodies: [String: [Int]] = [:]
        let output = NativeParagraphFragmentGrouping.reconcilingObservations(regions, scopes: scopes,
            didCoalesce: { merged.append($0) }, didSplit: { id, parts in
                split[id] = parts.map(\.id)
                for part in parts { splitBodies[part.id] = part.acceptedSource.membership?.body.sorted() }
            })
        // An intermediate aggregate can keep an original display ID, then
        // split off packets that came from a different (possibly filtered)
        // source. Derive original-source splits from immutable packet ancestry;
        // callback IDs alone would promote that neighbor into the retained GT.
        for original in regions {
            guard let source=original.acceptedSource.membership else { continue }
            let descendants=output.filter {
                guard let member=$0.acceptedSource.membership,member.table === source.table else { return false }
                return !member.body.isDisjoint(with:source.body)
            }
            if descendants.count > 1 {
                split[original.id]=descendants.map(\.id)
                for part in descendants {
                    splitBodies[part.id]=part.acceptedSource.membership?.body.intersection(source.body).sorted()
                }
            } else {
                split.removeValue(forKey:original.id)
            }
        }
        return .init(regions: output, originalCount: regions.count, recoveredLineages: regions.count,
            merged: merged, split: split, splitBodies: splitBodies, evidenceDirectory: evidenceDirectory)
    }
}
