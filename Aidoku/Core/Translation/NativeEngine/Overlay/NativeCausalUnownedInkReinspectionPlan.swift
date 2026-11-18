import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// A source-only recognition REQUEST, not a merge, translation or removal mask.
/// Keep this separate from the frozen residual-mask candidate. A detector bbox
/// or an unexplained interval never grants erasure or target-retirement authority.
enum NativeCausalUnownedInkReinspectionPlan {
    static let policyVersion = "original-interval-reinspection-plan-v75"
    static let defaultEnabled = false

    struct Owner {
        struct OriginalColumn {
            let ordinal: Int
            let polygon: [CGPoint]
        }
        let id: String
        let source: String
        let target: String
        /// Exact original top-left pixel geometry, NOT display/viewport geometry.
        let originalRect: CGRect
        let vertical: Bool
        /// Caller has bound the current source AND unchanged retained target.
        let retainedSourceAndTarget: Bool
        let packets: [NativeOCRDetectorSeedEvidence]
        /// Reader BEFORE provider: accepted original source, no target exists
        /// yet. Never set for kept/unaccepted observations. No placeholder target.
        var sourceOnlyBeforeProvider = false
        /// Exact original-primary ancestry with unresolved duplicate content.
        /// Inspection only: never accepted by interval planning or applyingReader.
        var competitionInspectionBeforeProvider = false
        /// Geometry copied only from this owner's immutable primary table.
        /// Recognition axes, never a glyph mask or stored OCR answer.
        var originalPrimaryColumns: [OriginalColumn] = []
    }

    enum Trigger: String {
        case missingMiddleSourceCoverage
        case unresolvedOriginalInterval
        /// Must come from measured upstream original-owned stroke evidence.
        /// This is not a source-completeness problem; keep the mask path separate.
        case ownedStrokeResidual
    }

    struct Gap {
        let ownerIDs: [String]
        let trigger: Trigger
        let upstreamStage: String
        let upstreamReason: String
        /// Supporting model query only. Never interpreted as a mask or owner.
        let rfTextQuery: Int?
    }

    struct Request {
        let id: String
        /// Exact pixels from CGImage.cropping; no resize, padding, recoloring,
        /// restoration or synthetic gap fill. Pixel rectangle is in metadata.
        let originalCrop: CGImage
        let metadata: [String: Any]
    }
    struct Result {
        let requests: [Request]
        let audit: [String: Any]
    }
    enum Failure: Error { case dimensions, identity, owners, packet, budget, crop, bundle }

    struct RecognitionBundle {
        /// Direct input to existing image-translation --ocr-only --list.
        let nativeOCRInputList: URL
        let provenanceManifest: URL
    }

    /// Materialize native OCR inputs, not merely a planner interface. The
    /// production detector THEN recognizer must inspect each crop: sending a
    /// multi-column envelope straight to a single CRNN region loses its middle.
    /// No model, provider, pipeline process or renderer is invoked here.
    static func exportRecognitionBundle(_ requests: [Request], to directory: URL) throws -> RecognitionBundle {
        guard !requests.isEmpty, requests.count <= 4, Set(requests.map(\.id)).count == requests.count,
              !FileManager.default.fileExists(atPath: directory.path) else { throw Failure.bundle }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var inputs = [String](), rows = [[String: Any]](), totalPixels = 0
        for (index, request) in requests.sorted(by: { $0.id < $1.id }).enumerated() {
            guard request.id.count == 64, request.id.allSatisfy({ $0.isHexDigit }),
                  request.metadata["requestID"] as? String == request.id,
                  let r = request.metadata["cropOriginalPixels"] as? [Double], r.count == 4,
                  r.allSatisfy(\.isFinite), r[2] == Double(request.originalCrop.width),
                  r[3] == Double(request.originalCrop.height),
                  let expected = request.metadata["cropCanonicalRGBA256"] as? String,
                  try rgbaDigest(request.originalCrop) == expected else { throw Failure.bundle }
            totalPixels += request.originalCrop.width * request.originalCrop.height
            guard totalPixels <= 1048576 else { throw Failure.budget }
            let url = directory.appendingPathComponent(request.id + "-original-crop.png")
            guard let dst = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
                throw Failure.crop
            }
            CGImageDestinationAddImage(dst, request.originalCrop, nil)
            guard CGImageDestinationFinalize(dst), let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let decoded = CGImageSourceCreateImageAtIndex(src, 0, nil),
                  try rgbaDigest(decoded) == expected else { throw Failure.identity }
            let fileDigest = digest(try Data(contentsOf: url))
            inputs.append(url.path)
            var row = request.metadata
            row["inputIndex"] = index; row["inputPath"] = url.path; row["inputFileSHA256"] = fileDigest
            row["inputSize"] = [decoded.width, decoded.height]
            row["cropToOriginalPixelAffine"] = [1, 0, 0, 1, r[0], r[1]]
            row["recognitionMode"] = "native-detector-then-recognizer;not-one-CRNN-read-for-whole-envelope"
            row["nativeOutputAssociation"] = "match summary.input to inputPath;never guess by output page number"
            row["ready"] = true
            rows.append(row)
        }
        let list = directory.appendingPathComponent("native-ocr-inputs.json")
        let manifest = directory.appendingPathComponent("recognition-manifest.json")
        try JSONSerialization.data(withJSONObject: inputs, options: [.prettyPrinted, .sortedKeys]).write(to: list, options: .atomic)
        let value: [String: Any] = ["version": 1, "policyVersion": policyVersion, "requests": rows,
            "nativeOCRInputList": list.path, "nativeCLIArguments": ["--ocr-only", "--list", list.path],
            "modelsCalledHere": 0, "mayErase": false, "sourceOrTargetsChanged": false,
            "requiresCompleteSourceAndTargetTransaction": true, "manifestIsCompletionMarker": true]
        // Commit marker last: incomplete export directories are NOT runnable.
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: manifest, options: .atomic)
        return .init(nativeOCRInputList: list, provenanceManifest: manifest)
    }

    enum RecognitionCoordinates: Equatable { case cropPixels, normalizedCrop }

    struct RecognitionObservation {
        /// LOCAL detector/recognizer sourceIndex, not a primary-page atom ID.
        let sourceIndex: Int
        let polygon: [CGPoint]
        let text: String
        let confidence: Double
    }

    /// Direct adapter for actual recognizer columns. Preserves empty/low-score
    /// observations for diagnosis; never promotes a local crop sourceIndex into
    /// original accepted-primary ancestry. That rebind is a separate proof.
    static func bindObservedColumns(_ observations: [RecognitionObservation], coordinates: RecognitionCoordinates,
                                    nativeRequestID: String, request: Request) throws -> [[String: Any]] {
        guard !nativeRequestID.isEmpty, nativeRequestID.utf8.count <= 160, observations.count <= 256,
              Set(observations.map(\.sourceIndex)).count == observations.count,
              observations.allSatisfy({ (0..<4096).contains($0.sourceIndex) && $0.text.utf8.count <= 32768 &&
                  $0.confidence.isFinite && (0...1).contains($0.confidence) }) else { throw Failure.owners }
        return try observations.map { observation in
            let p = try liftObservedPolygon(observation.polygon, coordinates: coordinates, request: request)
            let xs = p.map(\.x), ys = p.map(\.y)
            return ["source": observation.text, "confidence": observation.confidence,
                "sourcePolygon": p.map { [Double($0.x), Double($0.y)] },
                "sourceBounds": [Double(xs.min()!), Double(ys.min()!), Double(xs.max()! - xs.min()!), Double(ys.max()! - ys.min()!)],
                "inspectionRequestID": request.id, "nativeRecognitionRequestID": nativeRequestID,
                "cropLocalSourceIndex": observation.sourceIndex,
                "localSourceIdentity": request.id + ":" + String(observation.sourceIndex),
                "canonicalOriginalSourceRGBA256": request.metadata["canonicalSourceRGBA256"] ?? NSNull(),
                "priorSourceTargetMembers": request.metadata["members"] ?? [],
                "acceptedPrimaryUnionVerified": false, "requiresPrimaryLineageRebind": true,
                "candidateOnly": true, "mayErase": false, "mayRetireTarget": false]
        }
    }

    /// Lift a REAL detector/recognizer observation, not an invented missing run.
    /// Returned points are normalized original-page coordinates. This function
    /// grants no source ownership, translation correctness or erasure authority.
    static func liftObservedPolygon(_ points: [CGPoint], coordinates: RecognitionCoordinates,
                                    request: Request) throws -> [CGPoint] {
        guard (3...32).contains(points.count),
              let r = request.metadata["cropOriginalPixels"] as? [Double], r.count == 4,
              let size = request.metadata["originalSourceSize"] as? [Int], size.count == 2,
              size[0] > 0, size[1] > 0, r.allSatisfy(\.isFinite), r[0] >= 0, r[1] >= 0,
              r[2] == Double(request.originalCrop.width), r[3] == Double(request.originalCrop.height),
              r[0] + r[2] <= Double(size[0]), r[1] + r[3] <= Double(size[1]) else { throw Failure.crop }
        return try points.map { p in
            let x = coordinates == .normalizedCrop ? p.x * r[2] : p.x
            let y = coordinates == .normalizedCrop ? p.y * r[3] : p.y
            guard x.isFinite, y.isFinite, x >= 0, y >= 0, x <= r[2], y <= r[3] else { throw Failure.crop }
            return CGPoint(x: (x + r[0]) / Double(size[0]), y: (y + r[1]) / Double(size[1]))
        }
    }

    static func plan(original: CGImage, canonicalSourceRGBA256: String, owners: [Owner], gaps: [Gap],
                     enabled: Bool = defaultEnabled) throws -> Result {
        guard enabled else { return .init(requests: [], audit: ["status": "disabled"]) }
        let w = original.width, h = original.height
        guard w > 0, h > 0, w <= 16_777_216 / h, gaps.count <= 64 else { throw Failure.dimensions }
        guard canonicalSourceRGBA256.count == 64,
              try rgbaDigest(original) == canonicalSourceRGBA256 else { throw Failure.identity }
        let page = CGRect(x: 0, y: 0, width: w, height: h)
        guard owners.count <= 256, Set(owners.map(\.id)).count == owners.count,
              owners.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 160 && valid($0.originalRect, page) &&
                  $0.source.utf8.count <= 32768 && $0.target.utf8.count <= 32768 && $0.packets.count <= 64 })
        else { throw Failure.owners }
        var runCount = 0
        for owner in owners { for packet in owner.packets {
            guard packet.isValid, packet.ownershipVersion == 2, packet.completeCCScan == true,
                  packet.sourceWidth == w, packet.sourceHeight == h,
                  packet.sourceProbabilityROI?.sourceDigest == canonicalSourceRGBA256 else { throw Failure.packet }
            runCount += (packet.components + (packet.ambiguousComponents ?? []) +
                (packet.candidateComponents ?? []).map(\.component)).reduce(0) { $0 + $1.runs.count }
            guard runCount <= 131072 else { throw Failure.budget }
        } }
        let byID = Dictionary(uniqueKeysWithValues: owners.map { ($0.id, $0) })
        var requests = [Request](), rejections = [[String: Any]](), seen = Set<String>(), totalCropPixels = 0
        func reject(_ gap: Gap, _ reason: String) {
            rejections.append(["owners": gap.ownerIDs, "reason": reason, "trigger": gap.trigger.rawValue])
        }
        for gap in gaps {
            try Task.checkCancellation()
            guard gap.ownerIDs.count == 2, Set(gap.ownerIDs).count == 2,
                  gap.upstreamStage.utf8.count <= 160, !gap.upstreamStage.isEmpty,
                  gap.upstreamReason.utf8.count <= 512, !gap.upstreamReason.isEmpty,
                  gap.rfTextQuery.map({ (0..<4096).contains($0) }) ?? true,
                  let a = byID[gap.ownerIDs[0]], let b = byID[gap.ownerIDs[1]] else {
                reject(gap, "invalid-or-unresolved-source-binding"); continue
            }
            guard gap.trigger != .ownedStrokeResidual else {
                reject(gap, "owned-stroke-is-not-missing-source-authority"); continue
            }
            func bound(_ owner: Owner) -> Bool {
                owner.sourceOnlyBeforeProvider ? owner.target.isEmpty :
                    owner.retainedSourceAndTarget && !owner.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            guard bound(a), bound(b),
                  !a.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !b.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                reject(gap, "preserved-or-unbound-source-target"); continue
            }
            guard a.vertical, b.vertical else { reject(gap, "unsupported-source-axis"); continue }
            let sorted = [a, b].sorted { $0.originalRect.minX < $1.originalRect.minX }
            let left = sorted[0].originalRect, right = sorted[1].originalRect
            let separation = right.minX - left.maxX
            let top = max(left.minY, right.minY), bottom = min(left.maxY, right.maxY)
            // Geometry is only a bounded recognition search domain. Missing
            // middle glyphs, art or plain paper remain UNKNOWN until recognition.
            guard separation >= 1, separation <= min(left.width, right.width) * 8,
                  bottom - top >= min(left.height, right.height) * 0.4,
                  abs(left.minY - right.minY) <= min(left.height, right.height) * 0.35 else {
                reject(gap, "not-a-bounded-aligned-source-interval"); continue
            }
            // Use only complete interior original pixels: an edge pixel that
            // straddles the source envelope is not declared unowned.
            let interval = CGRect(x: ceil(left.maxX), y: ceil(top),
                width: floor(right.minX) - ceil(left.maxX), height: floor(bottom) - ceil(top))
            guard !interval.isEmpty, interval.width * interval.height <= 262144 else {
                reject(gap, "interval-budget-or-no-whole-pixels"); continue
            }
            let foreign = owners.filter { $0.id != a.id && $0.id != b.id }
            guard !foreign.contains(where: { $0.originalRect.intersects(interval) }) else {
                reject(gap, "foreign-original-source-in-interval"); continue
            }
            let pad = min(32, max(4, ceil(min(left.width, right.width) * 0.5)))
            let cropRect = left.union(right).insetBy(dx: -pad, dy: -pad).integral.intersection(page)
            let cropPixels = Int(cropRect.width) * Int(cropRect.height)
            guard cropPixels <= 524288, totalCropPixels <= 1048576 - cropPixels, requests.count < 4 else {
                reject(gap, "crop-budget-deferred"); continue
            }
            let members = [a, b].sorted { $0.id < $1.id }
            let memberRecords: [[String: Any]] = members.map { owner in
                var record: [String: Any] = ["id": owner.id, "sourceSHA256": hash(owner.source), "targetSHA256": hash(owner.target),
                 "originalRect": array(owner.originalRect), "retainedSourceAndTarget": owner.retainedSourceAndTarget,
                 "packetIDs": owner.packets.map(\.ownerID).sorted()]
                if owner.sourceOnlyBeforeProvider { record["targetStatus"] = "not-requested-before-provider" }
                return record
            }
            // Exact full runs are counted, not filled component bboxes. The
            // exported counts are detector evidence only, NEVER stroke pixels.
            var roles = [String: Int](), runCells = 0
            var componentSignatures = [String: String](), packetIDs = Set<String>()
            var roleSeeds = Set<String>(), unresolvedCompetitors = Set<String>()
            for owner in owners { for packet in owner.packets {
                let observations = packet.components.map { ($0, "exclusive-owned-detector") } +
                    (packet.ambiguousComponents ?? []).map { ($0, "ambiguous-detector") } +
                    (packet.candidateComponents ?? []).map { ($0.component, "candidate-detector") }
                for (component, role) in observations {
                    let key = "\(packet.mapFullWidth)x\(packet.mapFullHeight):\(component.seed)"
                    let signature = hash(component.runs.map { "\($0.y),\($0.x),\($0.count)" }.joined(separator: ";"))
                    if let prior = componentSignatures[key], prior != signature { throw Failure.packet }
                    componentSignatures[key] = signature
                    guard roleSeeds.insert(role + ":" + key).inserted else { continue }
                    var hits = 0
                    for run in component.runs {
                        let yy = (Double(run.y) + 0.5) * Double(h) / Double(packet.mapFullHeight)
                        guard yy >= interval.minY, yy < interval.maxY else { continue }
                        let start = max(run.x, Int(ceil(interval.minX * Double(packet.mapFullWidth) / Double(w) - 0.5)))
                        let end = min(run.x + run.count, Int(ceil(interval.maxX * Double(packet.mapFullWidth) / Double(w) - 0.5)))
                        hits += max(0, end - start)
                    }
                    if hits > 0 {
                        roles[role, default: 0] += hits; runCells += hits; packetIDs.insert(packet.ownerID)
                        if let candidate = packet.candidateComponents?.first(where: { $0.component.seed == component.seed }) {
                            let present = Set(owners.flatMap { $0.packets.map(\.ownerID) })
                            unresolvedCompetitors.formUnion(candidate.competingOwnerIDs.filter { !present.contains($0) })
                        }
                    }
                }
            } }
            let transaction = try JSONSerialization.data(withJSONObject: ["policy": policyVersion,
                "source": canonicalSourceRGBA256, "members": memberRecords, "crop": array(cropRect),
                "interval": array(interval), "trigger": gap.trigger.rawValue, "stage": gap.upstreamStage,
                "reason": gap.upstreamReason, "rfTextQueryHint": gap.rfTextQuery as Any? ?? NSNull(),
                "detectorComponents": componentSignatures,
                "detectorRoleAndCompetition": owners.sorted { $0.id < $1.id }.flatMap { owner in
                    owner.packets.sorted { $0.ownerID < $1.ownerID }.map { packet -> [String: Any] in
                        ["sourceOwner": owner.id, "packet": packet.ownerID, "parentBoxIndex": packet.parentBoxIndex,
                         "exclusiveSeeds": packet.components.map(\.seed).sorted(),
                         "ambiguousSeeds": (packet.ambiguousComponents ?? []).map(\.seed).sorted(),
                         "candidates": (packet.candidateComponents ?? []).map {
                            ["seed": $0.component.seed, "competitors": $0.competingOwnerIDs,
                             "outsideCompetingCells": $0.outsideCompetingCells] as [String: Any]
                         }]
                    }
                },
                "foreignSources": foreign.map { ["id": $0.id, "source": hash($0.source), "target": hash($0.target),
                    "rect": array($0.originalRect)] as [String: Any] }], options: [.sortedKeys])
            let id = digest(transaction)
            guard seen.insert(id).inserted else { reject(gap, "duplicate-request"); continue }
            guard let crop = original.cropping(to: cropRect), crop.width == Int(cropRect.width),
                  crop.height == Int(cropRect.height) else { throw Failure.crop }
            let metadata: [String: Any] = ["version": 1, "policyVersion": policyVersion, "requestID": id,
                "canonicalSourceRGBA256": canonicalSourceRGBA256, "originalSourceSize": [w, h],
                "cropOriginalPixels": array(cropRect), "cropCanonicalRGBA256": try rgbaDigest(crop),
                "intervalOriginalPixels": array(interval), "trigger": gap.trigger.rawValue,
                "upstreamStage": gap.upstreamStage, "upstreamReason": gap.upstreamReason,
                "rfTextQueryHint": gap.rfTextQuery as Any? ?? NSNull(), "rfIsOwnershipAuthority": false,
                "members": memberRecords, "detectorCellsInIntervalByRole": roles,
                "detectorCellObservations": runCells, "intervalPacketIDs": packetIDs.sorted(),
                "unresolvedPacketCompetitors": unresolvedCompetitors.sorted(),
                "ownedStrokePixelClassification": "not-measured; detector support is NOT a glyph/stroke pixel mask",
                "intervalClassification": "unknown-original-source-coverage; neither missing glyph nor blank gap certified",
                "preservedContextOwners": foreign.filter { $0.originalRect.intersects(cropRect) }.map {
                    ["id": $0.id, "originalRect": array($0.originalRect), "sourceSHA256": hash($0.source),
                     "targetSHA256": hash($0.target), "mustPreserve": true] as [String: Any]
                },
                "consumerContract": ["recognizeOriginalCropOnly": true, "requiresCompleteSourceAndTargetTransaction": true,
                    "requiresOriginalReadingOrderAndComponentProvenance": true, "preserveUnrelatedTargets": true,
                    "mayMerge": false, "mayErase": false, "mayRetireTarget": false,
                    "maskDeltaPixels": 0, "modelCalledHere": false]]
            requests.append(.init(id: id, originalCrop: crop, metadata: metadata)); totalCropPixels += cropPixels
        }
        return .init(requests: requests, audit: ["policyVersion": policyVersion, "status": "source-reinspection-plan-only",
            "requests": requests.count, "rejections": rejections, "cropPixels": totalCropPixels,
            "sourceRunsValidated": runCount, "mayErase": false, "maskDeltaPixels": 0,
            "sourceOrTargetsChanged": false, "modelsCalled": 0, "labelsRead": false])
    }

    /// Same canonical RGBA domain as original detector packets; never file SHA.
    static func rgbaDigest(_ image: CGImage) throws -> String {
        let w = image.width, h = image.height
        guard w > 0, h > 0, w <= 16_777_216 / h else { throw Failure.dimensions }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        try bytes.withUnsafeMutableBytes { raw in
            guard let c = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                    CGBitmapInfo.byteOrder32Big.rawValue) else { throw Failure.crop }
            c.setBlendMode(.copy); c.interpolationQuality = .none
            c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return digest(Data(bytes))
    }
    private static func valid(_ r: CGRect, _ page: CGRect) -> Bool {
        [r.minX, r.minY, r.width, r.height].allSatisfy(\.isFinite) && !r.isEmpty && page.contains(r)
    }
    private static func array(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height] }
    private static func hash(_ s: String) -> String { digest(Data(s.utf8)) }
    private static func digest(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
}
