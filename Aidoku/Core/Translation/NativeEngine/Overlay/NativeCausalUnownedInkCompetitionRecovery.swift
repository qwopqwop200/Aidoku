import CoreGraphics
import CryptoKit
import Foundation

/// Source reinspection, not affiliation/merge/erasure authority. A candidate-only
/// observation can be blocked by its own unresolved overlap with a larger source.
/// Resolve that observation through the existing resident DETECT -> READ -> normal
/// Reader grouping transaction, never by inventing a scalar font or dropping it.
enum NativeCausalUnownedInkCompetitionRecovery {
    typealias Plan = NativeCausalUnownedInkReinspectionPlan
    typealias Audit = (String, Int) -> Void
    static let policy = "original-closed-competition-context-v145"
    static var runtimeEnabled: Bool {
        ProcessInfo.processInfo.environment["AIDOKU_OCR_CAUSAL_UNOWNED_COMPETITION"] == "1"
    }

    struct Selection {
        let members: [Plan.Owner]
        let rootID: String
        let fragmentID: String
        let competitionSeeds: [Int]
        let cropRect: CGRect
    }

    /// Pure bounded selection; usable for original-packet fixture tests without
    /// OCR, decoding an image or any knowledge of page IDs/recognized answers.
    static func selections(owners: [Plan.Owner], size: CGSize,
                           separates: (CGRect, CGRect) -> Bool, audit: Audit? = nil) -> [Selection] {
        var reasons = [String: Int]()
        func note(_ reason: String) { reasons[reason, default: 0] += 1 }
        defer { for key in reasons.keys.sorted().prefix(16) { audit?(key, reasons[key]!) } }
        guard owners.count <= 256, Set(owners.map(\.id)).count == owners.count,
              size.width > 0, size.height > 0 else { note("selection_input_budget_or_dimensions"); return [] }
        let page = CGRect(origin: .zero, size: size)
        func accepted(_ o: Plan.Owner) -> Bool {
            guard o.sourceOnlyBeforeProvider || o.competitionInspectionBeforeProvider else {
                note("owner_not_bound_for_inspection"); return false
            }
            guard o.target.isEmpty && !o.source.isEmpty else { note("owner_source_or_target"); return false }
            guard !o.originalRect.isEmpty && page.contains(o.originalRect) else { note("owner_geometry"); return false }
            guard o.packets.count <= 64 else { note("owner_packet_budget"); return false }
            guard o.packets.allSatisfy({
                $0.isValid && $0.ownershipVersion == 2 && $0.completeCCScan == true &&
                $0.sourceWidth == Int(size.width) && $0.sourceHeight == Int(size.height)
            }) else { note("owner_packet_validity_or_dimensions"); return false }
            return true
        }
        let eligible = owners.filter(accepted)
        var results = [Selection](), seen = Set<String>()
        for fragment in eligible {
            let records = fragment.packets
            let candidates = records.flatMap { $0.candidateComponents ?? [] }
            guard records.allSatisfy({ $0.components.isEmpty && ($0.ambiguousComponents ?? []).isEmpty }),
                  (1...8).contains(candidates.count) else { continue }
            note("candidate_only_fragment")
            let competitors = Set(candidates.flatMap(\.competingOwnerIDs))
            let roots = eligible.filter { root in
                guard root.id != fragment.id, root.vertical,
                      !root.packets.flatMap(\.components).isEmpty,
                      competitors.isSubset(of: Set(root.packets.map(\.ownerID))),
                      fragment.originalRect.intersects(root.originalRect) else { return false }
                // An ID alone is insufficient. Verify identical complete runs
                // in the same original detector grid for EVERY competing claim.
                return records.allSatisfy { packet in
                    (packet.candidateComponents ?? []).allSatisfy { candidate in
                        candidate.competingOwnerIDs.allSatisfy { id in
                            root.packets.contains { other in
                                other.ownerID == id && other.mapFullWidth == packet.mapFullWidth &&
                                    other.mapFullHeight == packet.mapFullHeight &&
                                    other.mapOriginX == packet.mapOriginX && other.mapOriginY == packet.mapOriginY &&
                                    other.sourceProbabilityROI?.sourceDigest == packet.sourceProbabilityROI?.sourceDigest &&
                                    (other.components + (other.ambiguousComponents ?? [])).contains(candidate.component)
                            }
                        }
                    }
                }
            }
            guard roots.count == 1, let root = roots.first else { note("no_unique_closed_competition_root"); continue }
            let scales = root.packets.flatMap { packet in
                packet.components.map { component -> CGFloat in
                    let b = componentBounds(component, packet: packet)
                    return min(b.width, b.height)
                }
            }.filter { $0 >= 2 }.sorted()
            guard !scales.isEmpty else { note("root_no_owned_component_scale"); continue }
            let cross = scales[scales.count / 2]
            // Packetless but original-primary-bound neighbours may participate
            // in recognition, NEVER donate mask evidence. applyingReader still
            // checks every old primary atom and fresh erasure requires NEW runs.
            // Neighbours are only INSPECTION participants. Actual crop grouping
            // must independently produce ONE accepted source covering all of them.
            // Exclude a protruding upper/lower lobe by original along-axis support.
            let members = eligible.filter { owner in
                if owner.id == root.id || owner.id == fragment.id { return true }
                let r = owner.originalRect, b = root.originalRect
                if overlap(r, b) >= 0.85 { return true }
                let along = max(0, min(r.maxY, b.maxY) - max(r.minY, b.minY))
                let gap = max(0, max(r.minX, b.minX) - min(r.maxX, b.maxX))
                return owner.vertical && along >= r.height * 0.85 && along >= b.height * 0.65 && gap <= cross
            }.sorted { $0.id < $1.id }
            guard (2...6).contains(members.count) else { note("selection_member_budget"); continue }
            guard members.allSatisfy({ !separates(root.originalRect, $0.originalRect) }) else {
                note("physical_separator"); continue
            }
            let key = members.map(\.id).joined(separator: "\u{0}")
            guard seen.insert(key).inserted else { continue }
            var envelope = members.reduce(CGRect.null) { $0.union($1.originalRect) }
            for owner in members { for packet in owner.packets {
                // Ambiguous/candidate boxes are context only, NEVER removal masks.
                for component in packet.components + (packet.ambiguousComponents ?? []) +
                    (packet.candidateComponents ?? []).map(\.component) {
                    envelope = envelope.union(componentBounds(component, packet: packet))
                }
            } }
            let pad = min(32, max(4, cross * 0.5))
            let crop = envelope.insetBy(dx: -pad, dy: -pad).integral.intersection(page)
            guard !crop.isEmpty, crop.width * crop.height <= 524288 else { note("selection_crop_budget"); continue }
            // A partial foreign context may be present, but it remains a keepout
            // in recover(). Never silently absorb an unaccepted enclosed source.
            guard !owners.contains(where: { other in
                !members.contains(where: { $0.id == other.id }) && overlap(other.originalRect, envelope) >= 0.85
            }) else { note("foreign_enclosed_source"); continue }
            results.append(.init(members: members, rootID: root.id, fragmentID: fragment.id,
                competitionSeeds: candidates.map(\.component.seed).sorted(), cropRect: crop))
            note("selection_accepted")
            if results.count == 4 { break }
        }
        return results
    }

    static func requests(original: CGImage, owners: [Plan.Owner],
                         separates: (CGRect, CGRect) -> Bool, enabled: Bool = false,
                         audit: Audit? = nil) throws -> [Plan.Request] {
        var reasons = [String: Int]()
        func note(_ reason: String) { reasons[reason, default: 0] += 1 }
        defer { for key in reasons.keys.sorted().prefix(8) { audit?(key, reasons[key]!) } }
        guard enabled else { return [] }
        let selected = selections(owners: owners, size: CGSize(width: original.width, height: original.height),
                                  separates: separates, audit: audit)
        guard !selected.isEmpty else { note("request_no_selection"); return [] } // no decode/hash on no-match pages
        let digest = try Plan.rgbaDigest(original)
        var requests = [Plan.Request](), pixels = 0
        for selection in selected {
            try Task.checkCancellation()
            let crop = selection.cropRect
            let count = Int(crop.width) * Int(crop.height)
            guard pixels <= 1048576 - count else { note("request_total_pixel_budget"); continue }
            // The triggering competition MUST bind original pixels. Ancillary
            // accepted-primary observations may lack a probability ROI entirely;
            // they donate no erasure authority, and applyingReader rebinds their
            // exact primary atoms. A PRESENT conflicting ROI always rejects.
            guard selection.members.allSatisfy({ owner in owner.packets.allSatisfy { packet in
                let required = owner.id == selection.rootID || owner.id == selection.fragmentID
                return (!required && packet.sourceProbabilityROI == nil) ||
                    packet.sourceProbabilityROI?.sourceDigest == digest
            } }) else {
                let missingRequired = selection.members.contains { owner in
                    (owner.id == selection.rootID || owner.id == selection.fragmentID) &&
                        owner.packets.contains { $0.sourceProbabilityROI == nil }
                }
                note(missingRequired ? "request_required_packet_missing_roi" : "request_original_digest_mismatch")
                continue
            }
            let members: [[String: Any]] = selection.members.map { owner in
                ["id": owner.id, "sourceSHA256": hash(owner.source), "targetSHA256": hash(owner.target),
                 "originalRect": array(owner.originalRect), "packetIDs": owner.packets.map(\.ownerID).sorted(),
                 "targetStatus": "not-requested-before-provider"]
            }
            let signatures = selection.members.flatMap { owner in owner.packets.map { packet -> [String: Any] in
                var sparse = packet
                sparse.sourceProbabilityROI = nil // no duplicate ROI/map byte hashing
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let bytes = (try? encoder.encode(sparse)) ?? Data()
                return ["owner": owner.id, "packet": packet.ownerID, "sparsePacketSHA256": hash(bytes)]
            } }
            var metadata: [String: Any] = ["version": 1, "sourcePolicy": policy,
                "canonicalSourceRGBA256": digest, "originalSourceSize": [original.width, original.height],
                "cropOriginalPixels": array(crop), "members": members,
                "competitionSeeds": selection.competitionSeeds, "competitionRootID": selection.rootID,
                "competitionFragmentID": selection.fragmentID, "originalPacketSignatures": signatures,
                "originalPrimaryColumns": selection.members.flatMap { owner in
                    owner.originalPrimaryColumns.map { column -> [String: Any] in
                        ["ordinal": column.ordinal, "polygon": column.polygon.map { [Double($0.x), Double($0.y)] }]
                    }
                },
                "consumerContract": ["mayErase": false, "mayMerge": false, "requiresNativeGrouping": true,
                    "requiresOriginalPrimaryLineageRebind": true, "requiresFreshFullSourceTranslation": true]]
            let id = hash(try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]))
            guard let image = original.cropping(to: crop) else { throw Plan.Failure.crop }
            metadata["requestID"] = id
            metadata["cropCanonicalRGBA256"] = try Plan.rgbaDigest(image)
            requests.append(.init(id: id, originalCrop: image, metadata: metadata)); pixels += count
            note("request_accepted")
        }
        return requests
    }

    /// Opt-in actual crop receipt, bounded independently of probability packets.
    /// Preserve real native columns/groups for the next failed coverage guard.
    static func recordFresh(request: Plan.Request, batch: NativeCausalUnownedInkLiveRecovery.Batch) {
        guard runtimeEnabled, request.metadata["sourcePolicy"] as? String == policy else { return }
        func points(_ value: [CGPoint]) -> [[Double]] {
            value.prefix(32).map { [Double($0.x), Double($0.y)] }
        }
        let receipt: [String: Any] = ["requestID": request.id, "nativeRequestID": batch.nativeRequestID,
            "cropOriginalPixels": request.metadata["cropOriginalPixels"] ?? NSNull(),
            "oldMembers": request.metadata["members"] ?? [],
            "acceptedSourceIndices": batch.acceptedSourceIndices,
            "groups": batch.reads.prefix(32).map { read -> [String: Any] in
                ["id": read.sourceIndex, "text": String(read.text.prefix(1024)),
                 "confidence": read.confidence, "cropPolygon": points(read.polygon)]
            },
            "memberships": batch.memberships.prefix(32).map { member -> [String: Any] in
                ["group": member.groupSourceIndex, "body": member.bodySourceIndices, "readings": member.readingSourceIndices]
            },
            "columns": batch.acceptedColumnReads.prefix(64).map { read -> [String: Any] in
                ["id": read.sourceIndex, "text": String(read.text.prefix(1024)),
                 "confidence": read.confidence, "cropPolygon": points(read.polygon)]
            }]
        guard let data = try? JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]),
              data.count <= 131072 else { return }
        var line = Data("causal_unowned_competition_fresh ".utf8)
        line.append(data); line.append(10); FileHandle.standardError.write(line)
    }

    private static func componentBounds(_ c: NativeOCRDetectorSeedEvidence.Component,
                                        packet p: NativeOCRDetectorSeedEvidence) -> CGRect {
        c.runs.reduce(CGRect.null) { box, run in
            box.union(CGRect(x: CGFloat(run.x) * CGFloat(p.sourceWidth) / CGFloat(p.mapFullWidth),
                y: CGFloat(run.y) * CGFloat(p.sourceHeight) / CGFloat(p.mapFullHeight),
                width: CGFloat(run.count) * CGFloat(p.sourceWidth) / CGFloat(p.mapFullWidth),
                height: CGFloat(p.sourceHeight) / CGFloat(p.mapFullHeight)))
        }
    }
    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        guard !a.isEmpty else { return 0 }
        let i = a.intersection(b)
        return i.isNull ? 0 : i.width * i.height / (a.width * a.height)
    }
    private static func array(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height] }
    private static func hash(_ s: String) -> String { hash(Data(s.utf8)) }
    private static func hash(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
}
