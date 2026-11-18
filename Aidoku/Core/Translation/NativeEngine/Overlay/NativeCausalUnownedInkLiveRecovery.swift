import CoreGraphics
import CryptoKit
import Foundation

/// Execute the source plan using the caller's RESIDENT detector/recognizer,
/// BEFORE provider translation. No saved source answers or page branches.
enum NativeCausalUnownedInkLiveRecovery {
    typealias Plan = NativeCausalUnownedInkReinspectionPlan
    static let defaultEnabled = false
    static var runtimeEnabled: Bool {
        ProcessInfo.processInfo.environment["AIDOKU_OCR_CAUSAL_UNOWNED_CONTEXT"] == "1"
    }
    struct GroupMembership {
        let groupSourceIndex: Int
        let bodySourceIndices: [Int]
        let readingSourceIndices: [Int]
    }
    struct Batch {
        let nativeRequestID: String
        /// Actual grouped/native read polygons in CROP pixel coordinates.
        let reads: [Plan.RecognitionObservation]
        /// Full fresh detector runs bound to the exact crop pixels, not boxes.
        let detectorPackets: [NativeOCRDetectorSeedEvidence]
        var packetSourceIndices: [Int] = []
        /// Exact accepted-primary membership from the normal native grouping
        /// operation. IDs are local to THIS crop/nativeRequestID, never page IDs.
        var acceptedSourceIndices: [Int] = []
        var memberships: [GroupMembership] = []
        var acceptedColumnPolygons: [Int: [CGPoint]] = [:] // exact crop-pixel columns
        var acceptedColumnReads: [Plan.RecognitionObservation] = [] // same native request, before grouping
    }
    struct CropBoundInkEvidence {
        let originalSourceRGBA256: String
        let cropOriginalPixels: CGRect
        let packet: NativeOCRDetectorSeedEvidence
        let cropSourceIndex: Int
        /// Preserve detector coordinate domain. Do NOT relabel packet dimensions
        /// or digest as the full original page; transform exact runs on consume.
        func originalRunRectangles(component: NativeOCRDetectorSeedEvidence.Component) -> [CGRect] {
            component.runs.map { run in
                CGRect(x: cropOriginalPixels.minX + Double(run.x) * cropOriginalPixels.width / Double(packet.mapFullWidth),
                    y: cropOriginalPixels.minY + Double(run.y) * cropOriginalPixels.height / Double(packet.mapFullHeight),
                    width: Double(run.count) * cropOriginalPixels.width / Double(packet.mapFullWidth),
                    height: cropOriginalPixels.height / Double(packet.mapFullHeight))
            }
        }
    }
    struct Replacement {
        let requestID: String
        let oldSourceIDs: [String]
        let source: String
        let confidence: Double
        let originalNormalizedPolygon: [CGPoint]
        let originalNormalizedBounds: CGRect
        let originalRemovalOwners: [Plan.Owner]
        let cropBodySourceIndices: [Int]
        let cropReadingSourceIndices: [Int]
        let freshCropInkEvidence: [CropBoundInkEvidence]
        let freshCropColumnPolygons: [Int: [CGPoint]]
        let cropOriginalPixels: CGRect
        let audit: [String: Any]
        var freshCropColumnReads: [Plan.RecognitionObservation] = []
    }
    struct Result { let replacements: [Replacement]; let audit: [String: Any] }
    enum Failure: Error { case staleOriginal, staleMembers, nativeRequest, evidence, budget }

    /// Called serially under the SAME OCR admission/generation as primary OCR.
    /// liveCheck runs before AND after each await; cancellation/stale generations
    /// propagate, never silently accept an obsolete page's recognition.
    static func recover(original: CGImage, requests: [Plan.Request], currentOwners: [Plan.Owner],
                        liveCheck: () throws -> Void,
                        inspectResident: (Plan.Request, String) async throws -> Batch,
                        enabled: Bool = defaultEnabled) async throws -> Result {
        guard enabled else { return .init(replacements: [], audit: ["status": "disabled"]) }
        guard requests.count <= 4, currentOwners.count <= 256,
              Set(currentOwners.map(\.id)).count == currentOwners.count else { throw Failure.budget }
        try liveCheck()
        let digest = try Plan.rgbaDigest(original), w = Double(original.width), h = Double(original.height)
        var replacements = [Replacement](), rejected = [[String: Any]](), consumed = Set<String>(), calls = 0
        for request in requests {
            try liveCheck(); try Task.checkCancellation()
            guard request.metadata["canonicalSourceRGBA256"] as? String == digest,
                  let crop = request.metadata["cropOriginalPixels"] as? [Double], crop.count == 4,
                  let members = request.metadata["members"] as? [[String: Any]],
                  (members.count == 2 || ([NativeCausalUnownedInkCompetitionRecovery.policy,
                    NativeCausalRFOriginalContextRecovery.policy].contains(request.metadata["sourcePolicy"] as? String ?? "") &&
                    (2...6).contains(members.count))),
                  let cropDigest = request.metadata["cropCanonicalRGBA256"] as? String,
                  try Plan.rgbaDigest(request.originalCrop) == cropDigest else { throw Failure.staleOriginal }
            var anchors = [Plan.Owner]()
            for member in members {
                guard let id = member["id"] as? String, !consumed.contains(id),
                      let owner = currentOwners.first(where: { $0.id == id }),
                      hash(owner.source) == member["sourceSHA256"] as? String,
                      hash(owner.target) == member["targetSHA256"] as? String,
                      let rect = member["originalRect"] as? [Double], rect.count == 4,
                      zip(rect, [Double(owner.originalRect.minX), Double(owner.originalRect.minY),
                        Double(owner.originalRect.width), Double(owner.originalRect.height)]).allSatisfy({ abs($0 - $1) < 1e-7 })
                else { throw Failure.staleMembers }
                anchors.append(owner)
            }
            let nativeID = UUID().uuidString
            calls += 1
            let batch = try await inspectResident(request, nativeID)
            try liveCheck(); try Task.checkCancellation()
            guard batch.nativeRequestID == nativeID else { throw Failure.nativeRequest }
            guard batch.reads.count <= 256, batch.detectorPackets.count <= 256 else { throw Failure.budget }
            guard batch.packetSourceIndices.count == batch.detectorPackets.count else { throw Failure.evidence }
            let acceptedIDs = Set(batch.acceptedSourceIndices)
            guard batch.acceptedColumnReads.count <= 256,
                  Set(batch.acceptedColumnReads.map(\.sourceIndex)).count == batch.acceptedColumnReads.count,
                  batch.acceptedColumnReads.allSatisfy({ read in
                    acceptedIDs.contains(read.sourceIndex) && read.confidence.isFinite &&
                        (0...1).contains(read.confidence) && read.text.utf8.count <= 32768 &&
                        batch.acceptedColumnPolygons[read.sourceIndex] == read.polygon
                  }) else { throw Failure.evidence }
            guard !acceptedIDs.isEmpty, acceptedIDs.count == batch.acceptedSourceIndices.count,
                  Set(batch.reads.map(\.sourceIndex)).count == batch.reads.count,
                  batch.memberships.count == batch.reads.count,
                  Set(batch.memberships.map(\.groupSourceIndex)) == Set(batch.reads.map(\.sourceIndex))
            else { throw Failure.evidence }
            var usedMembers = Set<Int>()
            for member in batch.memberships {
                let body = Set(member.bodySourceIndices), readings = Set(member.readingSourceIndices)
                let all = body.union(readings)
                guard !body.isEmpty, body.count == member.bodySourceIndices.count,
                      readings.count == member.readingSourceIndices.count, body.isDisjoint(with: readings),
                      all.isSubset(of: acceptedIDs), usedMembers.isDisjoint(with: all)
                else { throw Failure.evidence }
                usedMembers.formUnion(all)
            }
            guard batch.packetSourceIndices.allSatisfy({ acceptedIDs.contains($0) }) else { throw Failure.evidence }
            let bound = try Plan.bindObservedColumns(batch.reads, coordinates: .cropPixels,
                nativeRequestID: nativeID, request: request)
            let foreign = currentOwners.filter { owner in !anchors.contains { $0.id == owner.id } }
            var eligible = [(Plan.RecognitionObservation, [CGPoint], CGRect)]()
            for (read, row) in zip(batch.reads, bound) {
                let text = read.text.filter { !$0.isWhitespace }
                guard read.confidence >= 0.8, text.count >= anchors.map({ $0.source.filter { !$0.isWhitespace }.count }).max()!,
                      let b = row["sourceBounds"] as? [Double], b.count == 4 else { continue }
                let rect = CGRect(x: b[0] * w, y: b[1] * h, width: b[2] * w, height: b[3] * h)
                guard anchors.allSatisfy({ coverage($0.originalRect, rect) >= 0.85 }),
                      !foreign.contains(where: { $0.originalRect.intersects(rect) }) else { continue }

                if request.metadata["sourcePolicy"] as? String == NativeCausalRFOriginalContextRecovery.policy {
                    guard let fresh = batch.memberships.first(where: { $0.groupSourceIndex == read.sourceIndex }) else { continue }
                    let ids = fresh.bodySourceIndices + fresh.readingSourceIndices
                    let columns = ids.compactMap { batch.acceptedColumnPolygons[$0] }
                    guard columns.count == ids.count,
                          NativeCausalRFOriginalContextRecovery.coversOriginalComponents(request: request,
                            freshCropPolygons: columns) else {
                        rejected.append(["requestID": request.id, "reason": "fresh-columns-miss-closed-original-components",
                            "groupSourceIndex": read.sourceIndex]); continue
                    }
                }
                let polygon = try Plan.liftObservedPolygon(read.polygon, coordinates: .cropPixels, request: request)
                eligible.append((read, polygon, CGRect(x: b[0], y: b[1], width: b[2], height: b[3])))
            }
            // A single complete native paragraph read, not concatenation of
            // fragment translations or choosing between competing transcripts.
            guard eligible.count == 1, let accepted = eligible.first else {
                rejected.append(["requestID": request.id, "reason": "no-unique-complete-original-source-read",
                    "eligibleReads": eligible.count]); continue
            }
            let membership = batch.memberships.first { $0.groupSourceIndex == accepted.0.sourceIndex }!
            let selectedIDs = Set(membership.bodySourceIndices + membership.readingSourceIndices)
            let freshPairs = zip(batch.packetSourceIndices, batch.detectorPackets)
                .filter { selectedIDs.contains($0.0) }
            let freshPackets = freshPairs.map(\.1)
            let missingPacketIDs = selectedIDs.subtracting(freshPairs.map(\.0)).sorted()
            var runCount = 0
            for packet in freshPackets {
                guard packet.isValid, packet.ownershipVersion == 2, packet.completeCCScan == true,
                      packet.sourceWidth == request.originalCrop.width, packet.sourceHeight == request.originalCrop.height,
                      packet.sourceProbabilityROI?.sourceDigest == cropDigest else { throw Failure.evidence }
                runCount += (packet.components + (packet.ambiguousComponents ?? []) +
                    (packet.candidateComponents ?? []).map(\.component)).reduce(0) { $0 + $1.runs.count }
                guard runCount <= 32768 else { throw Failure.budget }
            }
            let cropRect = CGRect(x: crop[0], y: crop[1], width: crop[2], height: crop[3])
            var replacement = Replacement(requestID: request.id, oldSourceIDs: anchors.map(\.id),
                source: accepted.0.text, confidence: accepted.0.confidence,
                originalNormalizedPolygon: accepted.1, originalNormalizedBounds: accepted.2,
                originalRemovalOwners: anchors,
                cropBodySourceIndices: membership.bodySourceIndices,
                cropReadingSourceIndices: membership.readingSourceIndices,
                freshCropInkEvidence: freshPairs.map {
                    .init(originalSourceRGBA256: digest, cropOriginalPixels: cropRect, packet: $0.1, cropSourceIndex: $0.0)
                }, freshCropColumnPolygons: batch.acceptedColumnPolygons.filter { selectedIDs.contains($0.key) },
                cropOriginalPixels: cropRect,
                audit: ["source": "fresh-resident-native-read-before-provider", "nativeRequestID": nativeID,
                    "providerCalledHere": false, "priorRemovalOwnersRetained": true,
                    "rfOriginalContextPolicy": request.metadata["sourcePolicy"] ?? NSNull(),
                    "originalPrimaryOperationID": request.metadata["originalPrimaryOperationID"] ?? NSNull(),
                    "originalPrimaryUnion": request.metadata["originalPrimaryUnion"] ?? NSNull(),
                    "originalPrimaryPackets": request.metadata["originalPrimaryPackets"] ?? NSNull(),
                    "newSourceHasNoTargetYet": true, "requiresFreshFullSourceTranslation": true,
                    "requiresOriginalPrimaryLineageRebind": true, "bboxErasureAuthorized": false,
                    "freshDetectorPackets": freshPackets.count,
                    "cropBodySourceIndices": membership.bodySourceIndices,
                    "cropReadingSourceIndices": membership.readingSourceIndices,
                    "missingPacketSourceIndices": missingPacketIDs,
                    "freshGlyphErasureProven": false, "newInkEvidenceMissing": !missingPacketIDs.isEmpty])
            replacement.freshCropColumnReads = batch.acceptedColumnReads.filter { selectedIDs.contains($0.sourceIndex) }
            replacements.append(replacement)
            consumed.formUnion(anchors.map(\.id))
        }
        return .init(replacements: replacements, audit: ["residentOCRCalls": calls, "replacements": replacements.count,
            "rejected": rejected, "providerCalls": 0, "maskDeltaPixels": 0,
            "labelsRead": false, "offlineAnswersRead": false])
    }
    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func sourceTextDigest(_ text: String) -> String { hash(text) }
    private static func coverage(_ source: CGRect, _ enclosing: CGRect) -> Double {
        let r = source.intersection(enclosing)
        return r.isNull ? 0 : r.width * r.height / (source.width * source.height)
    }
}

@available(iOS 18.0, *)
extension NativeCausalUnownedInkLiveRecovery {
    static func readerOwners(_ regions: [ReaderTranslationRegion], primary: [NativeCoreMLOCRLine],
                             size: CGSize, audit: ((String, Int) -> Void)? = nil) -> [Plan.Owner] {
        let table = primary.first?.acceptedSource.membership?.table
        let unknown = regions.filter { $0.acceptedSource.membership?.unknownDedup.isEmpty == false }.count
        if unknown > 0 { audit?("reader_unknown_dedup_inspection_only", unknown) }
        return regions.map { r in
            let m = r.acceptedSource.membership
            let accepted = table != nil && m?.table === table && m?.hasUntrackedInputs == false &&
                m?.unknownDedup.isEmpty == true && m?.body.isEmpty == false &&
                r.translation == nil && !r.isOccludedFinePrint && !r.isRecoveredLine &&
                r.sourceOCRAlternatives.isEmpty
            // Unresolved dedup content is the reason for INSPECTION, not grounds
            // to invent known ancestry or authorize a source replacement. Keep
            // sourceOnlyBeforeProvider false; applyingReader still rejects it.
            let inspection = table != nil && m?.table === table && m?.hasUntrackedInputs == false &&
                m?.unknownDedup.isEmpty == false && m?.body.isEmpty == false &&
                m.map { member in
                    member.unknownDedup.isSubset(of: member.body.union(member.readings)) &&
                        member.body.union(member.readings).allSatisfy { member.table.packets.indices.contains($0) }
                } == true && r.translation == nil && !r.isOccludedFinePrint && !r.isRecoveredLine &&
                r.sourceOCRAlternatives.isEmpty
            var owner = Plan.Owner(id: r.id, source: r.source, target: r.translation ?? "",
                originalRect: CGRect(x: r.rect.minX * size.width, y: r.rect.minY * size.height,
                    width: r.rect.width * size.width, height: r.rect.height * size.height),
                vertical: r.sourceOrientation == .vertical, retainedSourceAndTarget: false,
                packets: accepted || inspection ? r.detectorSeedEvidence ?? [] : [])
            owner.sourceOnlyBeforeProvider = accepted
            owner.competitionInspectionBeforeProvider = inspection
            if accepted || inspection, let member = m {
                owner.originalPrimaryColumns = member.body.sorted().compactMap { ordinal in
                    guard member.table.packets.indices.contains(ordinal) else { return nil }
                    let packet = member.table.packets[ordinal]
                    guard packet.orientation == .vertical else { return nil }
                    return .init(ordinal: ordinal, polygon: packet.polygon)
                }
            }
            return owner
        }
    }

    /// Unknown aligned source coverage is only a bounded inspection trigger.
    /// Separation vetoes are the SAME original-space Reader policy as grouping.
    static func readerGaps(_ owners: [Plan.Owner], separates: (CGRect, CGRect) -> Bool) -> [Plan.Gap] {
        guard owners.count <= 256 else { return [] }
        var pairs = [(Double, String, String)]()
        for i in owners.indices where owners[i].sourceOnlyBeforeProvider && owners[i].vertical {
            for j in owners.indices where j > i && owners[j].sourceOnlyBeforeProvider && owners[j].vertical {
                let a = owners[i].originalRect, b = owners[j].originalRect
                let left = a.minX < b.minX ? a : b, right = a.minX < b.minX ? b : a
                let gap = right.minX - left.maxX, cross = min(a.width, b.width), along = min(a.height, b.height)
                guard cross > 0, along > 0, gap >= 1, gap <= cross * 8,
                      min(a.maxY, b.maxY) - max(a.minY, b.minY) >= along * 0.4,
                      abs(a.minY - b.minY) <= along * 0.35,
                      !separates(a, b) else { continue }
                let interval = CGRect(x: left.maxX, y: max(a.minY, b.minY), width: gap,
                    height: min(a.maxY, b.maxY) - max(a.minY, b.minY))
                guard !owners.contains(where: { $0.id != owners[i].id && $0.id != owners[j].id &&
                    $0.originalRect.intersects(interval) }) else { continue }
                pairs.append((Double(gap / cross), owners[i].id, owners[j].id))
            }
        }
        return pairs.sorted { a, b in
            a.0 == b.0 ? (a.1 == b.1 ? a.2 < b.2 : a.1 < b.1) : a.0 > b.0
        }.prefix(64).map {
            .init(ownerIDs: [$0.1, $0.2], trigger: .unresolvedOriginalInterval,
                upstreamStage: "Reader-final-source-before-provider", upstreamReason: "bounded-aligned-unowned-interval",
                rfTextQuery: nil)
        }
    }

    /// Rebind ORIGINAL accepted-primary ordinals, not detector IDs. Fresh crop
    /// membership stays in the separate typed ledger; it never impersonates an
    /// old primary atom. Unrelated sources remain byte-for-byte value copies.
    static func applyingReader(_ r: Replacement, to regions: [ReaderTranslationRegion],
                               primary: [NativeCoreMLOCRLine]) -> [ReaderTranslationRegion]? {
        guard (2...6).contains(r.oldSourceIDs.count), Set(r.oldSourceIDs).count == r.oldSourceIDs.count,
              let table = primary.first?.acceptedSource.membership?.table else { return nil }
        let indices = regions.indices.filter { r.oldSourceIDs.contains(regions[$0].id) }
        guard indices.count == r.oldSourceIDs.count else { return nil }
        let originals = indices.map { regions[$0] }
        for region in originals {
            guard let snapshot = r.originalRemovalOwners.first(where: { $0.id == region.id }),
                  (snapshot.sourceOnlyBeforeProvider || snapshot.competitionInspectionBeforeProvider),
                  snapshot.source == region.source, region.translation == nil,
                  !region.isOccludedFinePrint, !region.isRecoveredLine,
                  let m = region.acceptedSource.membership, m.table === table,
                  !m.hasUntrackedInputs, !m.body.isEmpty,
                  (m.unknownDedup.isEmpty || (snapshot.competitionInspectionBeforeProvider &&
                    m.unknownDedup.isSubset(of: m.body))),
                  m.body.union(m.readings).allSatisfy({ table.packets.indices.contains($0) }) else { return nil }
            let rect = CGRect(x: region.rect.minX * CGFloat(table.width), y: region.rect.minY * CGFloat(table.height),
                width: region.rect.width * CGFloat(table.width), height: region.rect.height * CGFloat(table.height))
            guard rect == snapshot.originalRect else { return nil }
        }
        var metadata = NativeOCRSourceMetadata.union(originals.map(\.acceptedSource))
        guard let mergedMember = metadata.membership, mergedMember.table === table,
              !mergedMember.hasUntrackedInputs else { return nil }
        guard let resolved = resolvingOriginalDuplicates(mergedMember, replacement: r) else { return nil }
        metadata = .init(resolved)
        let claimed = mergedMember.body.union(mergedMember.readings)
        if r.audit["rfOriginalContextPolicy"] as? String == NativeCausalRFOriginalContextRecovery.policy {
            guard r.audit["originalPrimaryOperationID"] as? String == table.operationID.uuidString,
                  r.audit["originalPrimaryUnion"] as? [Int] == mergedMember.body.sorted(),
                  let snapshots = r.audit["originalPrimaryPackets"] as? [[String: Any]],
                  snapshots.count == mergedMember.body.count else { return nil }
            for snapshot in snapshots {
                guard let ordinal = snapshot["ordinal"] as? Int, mergedMember.body.contains(ordinal),
                      table.packets.indices.contains(ordinal),
                      snapshot["sourceSHA256"] as? String == sourceTextDigest(table.packets[ordinal].text),
                      snapshot["originalPolygon"] as? [[Double]] == table.packets[ordinal].polygon.map({ [Double($0.x), Double($0.y)] })
                else { return nil }
            }
        }
        guard originals.reduce(0, { $0 + $1.acceptedSource.membership!.body.count }) == mergedMember.body.count else { return nil }
        for index in regions.indices where !indices.contains(index) {
            guard let member = regions[index].acceptedSource.membership else { return nil }
            guard member.table === table, claimed.isDisjoint(with: member.body.union(member.readings).union(member.unknownDedup))
            else { return nil }
        }
        let parent = originals.max { $0.source.count < $1.source.count }!
        let originalPolygons = claimed.sorted().flatMap { ordinal -> [[CGPoint]] in
            let p = table.packets[ordinal]
            return ([p.polygon] + p.erasurePolygons).map { polygon in
                polygon.map { CGPoint(x: $0.x / CGFloat(table.width), y: $0.y / CGFloat(table.height)) }
            }
        }
        let cropPolygons = r.freshCropColumnPolygons.keys.sorted().map { id in
            r.freshCropColumnPolygons[id]!.map { CGPoint(
                x: ($0.x + r.cropOriginalPixels.minX) / CGFloat(table.width),
                y: ($0.y + r.cropOriginalPixels.minY) / CGFloat(table.height)) }
        }
        guard cropPolygons.count == r.cropBodySourceIndices.count + r.cropReadingSourceIndices.count else { return nil }
        let merged = ReaderTranslationRegion(id: parent.id, rect: r.originalNormalizedBounds, source: r.source,
            translation: nil, polygon: r.originalNormalizedPolygon, confidence: r.confidence,
            sourceImageAspectRatio: parent.sourceImageAspectRatio, translationOrder: nil, translationOrderVersion: nil,
            sourceOrientation: parent.sourceOrientation, sourceSingleVerticalColumn: nil, translationReuseIdentity: nil,
            auxiliaryInkRects: originals.flatMap(\.auxiliaryInkRects),
            auxiliaryInkPolygons: originals.flatMap(\.auxiliaryInkPolygons) + originalPolygons + cropPolygons,
            detectorSeedEvidence: NativeOCRDetectorSeedEvidence.preservingUnion(originals.map(\.detectorSeedEvidence)),
            acceptedSource: metadata, sourceOCRAlternatives: [], balloonInterior: nil,
            unitMemberRects: originals.flatMap { $0.unitMemberRects.isEmpty ? [$0.rect] : $0.unitMemberRects } +
                cropPolygons.map(polygonBounds), isOccludedFinePrint: false, isRecoveredLine: false)
        return regions.indices.compactMap { i in
            i == indices[0] ? merged : (indices.contains(i) ? nil : regions[i])
        }
    }
    /// Clear an unresolved duplicate only with a unique original containing
    /// column AND an independently accepted fresh column repeating that complete
    /// column at the same source pixels. Preserve every old body/erasure atom.
    private static func resolvingOriginalDuplicates(_ member: NativeOCRAcceptedSource.Membership,
                                                    replacement r: Replacement) -> NativeOCRAcceptedSource.Membership? {
        guard !member.unknownDedup.isEmpty else { return member }
        let table = member.table, unknown = member.unknownDedup
        guard unknown.count <= 8, unknown.isSubset(of: member.body),
              r.freshCropColumnReads.count <= 256,
              Set(r.freshCropColumnReads.map(\.sourceIndex)).count == r.freshCropColumnReads.count else { return nil }
        let freshIDs = Set(r.cropBodySourceIndices)
        func text(_ value: String) -> String {
            value.precomposedStringWithCanonicalMapping.filter { !$0.isWhitespace }
        }
        for ordinal in unknown {
            guard table.packets.indices.contains(ordinal) else { return nil }
            let atom = table.packets[ordinal], fragment = text(atom.text)
            let atomBounds = polygonBounds(atom.polygon)
            guard fragment.count >= 2 else { return nil }
            let witnesses = member.body.subtracting(unknown).filter { other in
                guard table.packets.indices.contains(other) else { return false }
                let column = table.packets[other], complete = text(column.text)
                guard complete.count > fragment.count, complete.contains(fragment),
                      text(r.source).contains(complete),
                      coverage(atomBounds, polygonBounds(column.polygon)) >= 0.85 else { return false }
                return r.freshCropColumnReads.contains { fresh in
                    guard freshIDs.contains(fresh.sourceIndex), fresh.confidence >= 0.8,
                          text(fresh.text) == complete,
                          let polygon = r.freshCropColumnPolygons[fresh.sourceIndex], polygon == fresh.polygon else { return false }
                    let original = polygonBounds(polygon).offsetBy(dx: r.cropOriginalPixels.minX, dy: r.cropOriginalPixels.minY)
                    return coverage(polygonBounds(column.polygon), original) >= 0.85 && coverage(atomBounds, original) >= 0.85
                }
            }
            guard witnesses.count == 1 else { return nil }
        }
        return .init(table: table, body: member.body, readings: member.readings,
            unknownDedup: [], hasUntrackedInputs: member.hasUntrackedInputs)
    }
}

extension NativeCausalUnownedInkLiveRecovery {
    struct AffiliatedMask {
        let originalRGBA256: String
        let sourceBounds: CGRect // normalized ORIGINAL page, exact future owner
        let sourceSHA256: String
        let runs: [NativeOCRDetectorSeedEvidence.Run] // ORIGINAL source pixel rows
        let audit: [String: Any]
    }

    /// Self-contained saved render evidence, not paths into a resident store.
    /// Exact original RGBA + complete accepted source hash + source geometry
    /// remain mandatory on replay. No ROI/map bytes or offline answers enter it.
    static func maskPayload(_ masks: [AffiliatedMask], original: CGImage) throws -> [String: Any] {
        guard masks.count <= 4, masks.reduce(0, { $0 + $1.runs.count }) <= 131072 else { throw Failure.budget }
        let digest = try Plan.rgbaDigest(original)
        let rows = try masks.map { mask -> [String: Any] in
            guard mask.originalRGBA256 == digest else { throw Failure.staleOriginal }
            let b = mask.sourceBounds
            return ["sourceSHA256": mask.sourceSHA256,
                "sourceBounds": [Double(b.minX), Double(b.minY), Double(b.width), Double(b.height)],
                "runs": mask.runs.map { [$0.y, $0.x, $0.count] }, "affiliation": mask.audit]
        }
        var object: [String: Any] = ["version": 1, "originalRGBA256": digest,
            "originalSize": [original.width, original.height], "masks": rows,
            "policy": "original-pixel-factory-intersect-exclusive-DB-runs-v102"]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard data.count <= 4 * 1024 * 1024 else { throw Failure.budget }
        object["payloadSHA256"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return object
    }

    static func masksFromPayload(_ value: Any?, original: CGImage) throws -> [AffiliatedMask] {
        guard let value else { return [] }
        guard var object = value as? [String: Any], object["version"] as? Int == 1,
              let expected = object.removeValue(forKey: "payloadSHA256") as? String,
              object["originalSize"] as? [Int] == [original.width, original.height],
              let digest = object["originalRGBA256"] as? String,
              digest == (try Plan.rgbaDigest(original)),
              let rows = object["masks"] as? [[String: Any]], rows.count <= 4 else { throw Failure.evidence }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard data.count <= 4 * 1024 * 1024,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expected else { throw Failure.evidence }
        var totalRuns = 0
        return try rows.map { row in
            guard let source = row["sourceSHA256"] as? String,
                  NativeOCRSourceROIProbabilityEvidence.validDigest(source),
                  let b = row["sourceBounds"] as? [Double], b.count == 4, b.allSatisfy(\.isFinite),
                  b[0] >= 0, b[1] >= 0, b[2] > 0, b[3] > 0, b[0] + b[2] <= 1 + 1e-9, b[1] + b[3] <= 1 + 1e-9,
                  let triples = row["runs"] as? [[Int]], triples.count <= 131072 - totalRuns else { throw Failure.evidence }
            totalRuns += triples.count
            var lastY = -1, lastEnd = -1
            let runs = try triples.map { triple -> NativeOCRDetectorSeedEvidence.Run in
                guard triple.count == 3 else { throw Failure.evidence }
                let y = triple[0], x = triple[1], n = triple[2]
                guard y >= 0, y < original.height, x >= 0, x < original.width, n > 0, n <= original.width - x,
                      y > lastY || (y == lastY && x >= lastEnd) else { throw Failure.evidence }
                lastY = y; lastEnd = x + n
                return .init(y: y, x: x, count: n)
            }
            return .init(originalRGBA256: digest, sourceBounds: CGRect(x: b[0], y: b[1], width: b[2], height: b[3]),
                sourceSHA256: source, runs: runs, audit: (row["affiliation"] as? [String: Any] ?? [:]).merging(
                    ["savedSourceBoundMaskReplay": true, "payloadSHA256": expected,
                     "requiresTranslatedExactGeometryOwner": true]) { _, value in value })
        }
    }

    /// CPU-only provisional glyph mask. Not committed until a real translated
    /// owner with exactly this source geometry reaches the main mask caller.
    /// Existing original-pixel factory supplies glyph/halo selection; complete
    /// exclusive DB runs bound that selection. Neither box nor run is itself ink.
    static func affiliatedMask(original: CGImage, replacement r: Replacement,
                               foreignOwners: [Plan.Owner]) throws -> AffiliatedMask {
        let digest = try Plan.rgbaDigest(original), crop = r.cropOriginalPixels
        let selected = Set(r.cropBodySourceIndices + r.cropReadingSourceIndices)
        guard !selected.isEmpty, Set(r.freshCropColumnPolygons.keys) == selected,
              Set(r.freshCropInkEvidence.map(\.cropSourceIndex)) == selected,
              r.freshCropInkEvidence.allSatisfy({ $0.originalSourceRGBA256 == digest && $0.cropOriginalPixels == crop }),
              let image = original.cropping(to: crop) else { throw Failure.evidence }
        let w = image.width, h = image.height, cropDigest = try Plan.rgbaDigest(image)
        guard w > 0, h > 0, w <= 524288 / h else { throw Failure.budget }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let c = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            c.translateBy(x: 0, y: CGFloat(h)); c.scaleBy(x: 1, y: -1)
            c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
        }
        guard drawn else { throw Failure.evidence }
        var rgb = [UInt8](); rgb.reserveCapacity(w * h * 3)
        for i in 0..<(w * h) { rgb.append(contentsOf: rgba[(i * 4)..<(i * 4 + 3)]) }
        typealias F = NativeMainRemovalSourceFactory
        typealias C = F.NativeCurrentMaskCaller
        let owners = try selected.sorted().map { id -> C.Owner in
            let p = r.freshCropColumnPolygons[id]!
            guard (3...16).contains(p.count), p.allSatisfy({ $0.x.isFinite && $0.y.isFinite &&
                $0.x >= 0 && $0.y >= 0 && $0.x <= CGFloat(w) && $0.y <= CGFloat(h) }) else { throw Failure.evidence }
            let b = polygonBounds(p)
            guard b.width > 0, b.height > 0 else { throw Failure.evidence }
            return .init(id: String(id), polygon: p, fontPixels: max(1, min(b.width, b.height)),
                translated: true, balloon: false)
        }
        let base = try F.NativeSourceBaseMask.extract(source: .init(width: w, height: h, rgb: rgb, revision: cropDigest),
            owners: owners)
        var supported = [UInt8](repeating: 0, count: w * h), work = 0
        for evidence in r.freshCropInkEvidence {
            let packet = evidence.packet
            guard packet.isValid, packet.ownershipVersion == 2, packet.completeCCScan == true,
                  packet.sourceWidth == w, packet.sourceHeight == h,
                  packet.sourceProbabilityROI?.sourceDigest == cropDigest else { throw Failure.evidence }
            // Candidate/ambiguous runs are deliberately NOT admitted here.
            for component in packet.components { for run in component.runs {
                let x0 = max(0, Int(floor(Double(run.x) * Double(w) / Double(packet.mapFullWidth))) - 2)
                let x1 = min(w, Int(ceil(Double(run.x + run.count) * Double(w) / Double(packet.mapFullWidth))) + 2)
                let y0 = max(0, Int(floor(Double(run.y) * Double(h) / Double(packet.mapFullHeight))) - 2)
                let y1 = min(h, Int(ceil(Double(run.y + 1) * Double(h) / Double(packet.mapFullHeight))) + 2)
                work += max(0, x1 - x0) * max(0, y1 - y0)
                guard work <= 16_777_216 else { throw Failure.budget }
                if x1 > x0, y1 > y0 { for y in y0..<y1 { for x in x0..<x1 { supported[y * w + x] = 1 } } }
            } }
        }
        let keepouts = foreignOwners.map { $0.originalRect.insetBy(dx: -1, dy: -1) }
        var runs = [NativeOCRDetectorSeedEvidence.Run](), pixels = 0
        for y in 0..<h {
            if y & 31 == 0 { try Task.checkCancellation() }
            var start: Int?
            for x in 0...w {
                let allowed: Bool
                if x == w { allowed = false } else {
                    let point = CGPoint(x: crop.minX + CGFloat(x) + 0.5, y: crop.minY + CGFloat(y) + 0.5)
                    allowed = supported[y * w + x] != 0 && base.mask[y * w + x] != 0 &&
                        !keepouts.contains(where: { $0.contains(point) })
                }
                if allowed, start == nil { start = x }
                if !allowed, let first = start {
                    runs.append(.init(y: Int(crop.minY) + y, x: Int(crop.minX) + first, count: x - first))
                    pixels += x - first; start = nil
                }
            }
        }
        guard runs.count <= 131072 else { throw Failure.budget }
        return .init(originalRGBA256: digest, sourceBounds: r.originalNormalizedBounds,
            sourceSHA256: hash(r.source), runs: runs,
            audit: ["candidatePixels": pixels, "exclusiveRunAndOriginalFactoryIntersection": true,
                "bboxFill": false, "candidateAmbiguousRunsAdmitted": false,
                "nativeRequestID": r.audit["nativeRequestID"] ?? NSNull(),
                "oldSourceIDs": r.oldSourceIDs,
                "cropBodySourceIndices": r.cropBodySourceIndices,
                "cropReadingSourceIndices": r.cropReadingSourceIndices,
                "cropOriginalPixels": [Double(crop.minX), Double(crop.minY), Double(crop.width), Double(crop.height)],
                "packets": r.freshCropInkEvidence.map { evidence -> [String: Any] in
                    ["cropSourceIndex": evidence.cropSourceIndex, "ownerID": evidence.packet.ownerID,
                     "parentBoxIndex": evidence.packet.parentBoxIndex,
                     "cropRGBA256": evidence.packet.sourceProbabilityROI?.sourceDigest ?? "",
                     "componentSeeds": evidence.packet.components.map(\.seed)]
                },
                "scaleAuthority": "actual-recognized-column-cross-extent-not-nominal-font",
                "requiresTranslatedExactGeometryOwner": true, "factory": base.audit])
    }

    static func polygonBounds(_ p: [CGPoint]) -> CGRect {
        guard let x = p.map(\.x).min(), let y = p.map(\.y).min(),
              let r = p.map(\.x).max(), let b = p.map(\.y).max() else { return .null }
        return CGRect(x: x, y: y, width: r - x, height: b - y)
    }

    /// Parent mask caller still intersects its actual protection raster AFTER
    /// applying this delta. No ROI AOT, original-resolution composition only.
    static func applyAffiliatedMasks(_ candidates: [AffiliatedMask], original: CGImage,
                                    items: [[String: Any]], mask: inout [UInt8]) throws -> Int {
        guard candidates.count <= 4, mask.count == original.width * original.height else { throw Failure.budget }
        guard !candidates.isEmpty else { return 0 }
        let digest = try Plan.rgbaDigest(original), w = original.width, h = original.height
        var added = 0
        for candidate in candidates {
            guard candidate.originalRGBA256 == digest else { throw Failure.staleOriginal }
            let matches = items.filter { item in
                guard item["originalSourceSHA256"] as? String == candidate.sourceSHA256,
                      item["keptLettering"] as? Bool != true, item["sourceTextOnly"] as? Bool != true,
                      let text = item["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let b = item["sourceBounds"] as? [Double], b.count == 4 else { return false }
                let r = candidate.sourceBounds
                return zip(b, [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)]).allSatisfy { abs($0 - $1) < 1e-7 }
            }
            guard matches.count == 1 else { continue }
            for run in candidate.runs {
                guard run.y >= 0, run.y < h, run.x >= 0, run.count > 0, run.count <= w - run.x else { throw Failure.evidence }
                for x in run.x..<(run.x + run.count) {
                    let i = run.y * w + x
                    if mask[i] == 0 { added += 1 }; mask[i] = 255
                }
            }
        }
        return added
    }
}
