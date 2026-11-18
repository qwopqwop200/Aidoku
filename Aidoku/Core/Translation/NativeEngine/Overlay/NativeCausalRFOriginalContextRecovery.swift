import CoreGraphics
import CryptoKit
import Foundation

/// Nominate a NEW resident DETECT -> READ -> normal Reader grouping transaction
/// on immutable original RGBA. Unlike RF paragraph strip rereads, this can find
/// previously unaccepted sources. Old primaries/CC ownership remain unchanged.
enum NativeCausalRFOriginalContextRecovery {
    typealias Plan = NativeCausalUnownedInkReinspectionPlan
    typealias E = NativeOCRDetectorSeedEvidence
    private struct ContextClosure {
        let originals: [P.Owner]
        let primaryUnion: [Int]
        let primaryBounds: CGRect
        let samplingBounds: CGRect
        let records: [E]
        let components: [E.Component]
        let addedDetectorIDs: [String]
        let unresolvedReferenceSeeds: [Int]
    }
    typealias P = NativeCausalRFParagraphRecognition
    static let policy = "rf-closed-original-context-detect-read-v200-1"
    static var runtimeEnabled: Bool {
        ProcessInfo.processInfo.environment["AIDOKU_OCR_RF_ORIGINAL_CONTEXT"] == "1"
    }

    static func requests(original: CGImage, owners: [Plan.Owner], primaryOwners: [P.Owner],
                         allDetectors: [E], supports: [P.Support], sourceIdentity: String,
                         retainedDetectorInventory: [String: [E]]? = nil,
                         enabled: Bool = false, separates: (CGRect, CGRect) -> Bool,
                         audit: ((String) -> Void)? = nil) throws -> [Plan.Request] {
        guard enabled, supports.count <= 512, owners.count <= 256,
              Set(owners.map(\.id)).count == owners.count,
              Set(primaryOwners.map(\.id)) == Set(owners.map(\.id)) else { return [] }
        let size = CGSize(width: original.width, height: original.height)
        let canvas = CGRect(origin: .zero, size: size)
        let records = Dictionary(uniqueKeysWithValues: owners.map { ($0.id, $0.packets) })
        // Aggregate source evidence can be absent after a ruby/dedup union.
        // Keep the FULL body+reading primary detector inventory separate from
        // eligible source owners. It is competitor evidence, not read authority.
        let retainedRecords = retainedDetectorInventory ?? records
        var result = [Plan.Request](), used = Set<String>(), pixels = 0, originalDigest: String?
        for support in supports.filter({ $0.confidence.isFinite && $0.confidence >= 0.55 })
            .sorted(by: { $0.confidence > $1.confidence }).prefix(32) {
            func note(_ reason: String) {
                audit?("query-\(support.queryID)-" + reason)
                record("nomination", fields: ["query": support.queryID, "reason": reason])
            }
            guard result.count < 2 else { break }
            guard let closure = inspectContext(owners: primaryOwners, recordsByOwner: records,
                retainedRecordsByOwner: retainedRecords,
                allDetectors: allDetectors, support: support, sourceIdentity: sourceIdentity, imageSize: size,
                separates: separates, audit: note) else { continue }
            guard !closure.unresolvedReferenceSeeds.isEmpty else {
                note("no-uncovered-original-cells"); continue
            }
            guard used.isDisjoint(with: closure.originals.map(\.id)) else {
                note("source-already-scheduled"); continue
            }
            let selected = closure.originals.compactMap { primary in owners.first { $0.id == primary.id } }
            guard selected.count == closure.originals.count, (2...6).contains(selected.count),
                  selected.allSatisfy({ owner in
                      owner.sourceOnlyBeforeProvider && owner.target.isEmpty && !owner.source.isEmpty &&
                      closure.originals.contains { $0.id == owner.id && $0.source == owner.source && $0.bounds == owner.originalRect }
                  }) else { note("unbound-original-source"); continue }
            let widths = closure.originals.flatMap(\.runs).map { run in
                run.polygon.map(\.x).max()! - run.polygon.map(\.x).min()!
            }.sorted()
            let pad = min(24, max(8, widths[widths.count / 2] * 0.4))
            // Whole RF + EVERY exact closed CC + old originals, including ink
            // beyond the previous source envelope. This is sampling only.
            let envelope = closure.samplingBounds.union(support.bounds)
            let crop = envelope.insetBy(dx: -pad, dy: -pad).integral.intersection(canvas)
            let count = Int(crop.width) * Int(crop.height)
            let ids = Set(selected.map(\.id)), outside = owners.filter { !ids.contains($0.id) }
            guard !crop.isEmpty, count <= 524_288, count <= 1_048_576 - pixels,
                  !outside.contains(where: { $0.originalRect.intersects(crop) }) else {
                note("outside-retained-source-or-context-budget"); continue
            }
            if originalDigest == nil { originalDigest = try Plan.rgbaDigest(original) }
            let digest = originalDigest!
            // SAME original RGBA, not file hash or a rebadged crop/grid digest.
            guard closure.records.allSatisfy({ $0.sourceProbabilityROI?.sourceDigest == digest }) else {
                note("original-rgba-detector-mismatch"); continue
            }
            let members: [[String: Any]] = selected.sorted { $0.id < $1.id }.map {
                ["id": $0.id, "sourceSHA256": hash(Data($0.source.utf8)), "targetSHA256": hash(Data($0.target.utf8)),
                 "originalRect": array($0.originalRect), "packetIDs": $0.packets.map(\.ownerID).sorted(),
                 "targetStatus": "not-requested-before-provider"]
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let signatures = try closure.records.map { record -> [String: Any] in
                var sparse = record; sparse.sourceProbabilityROI = nil
                return ["detectorID": record.ownerID, "sparseSHA256": hash(try encoder.encode(sparse))]
            }
            let grid = closure.records[0]
            let sx = size.width / CGFloat(grid.mapFullWidth), sy = size.height / CGFloat(grid.mapFullHeight)
            let required: [[String: Any]] = closure.components.map { c in
                ["seed": c.seed, "runs": c.runs.map { r -> [Double] in
                    [CGFloat(r.x) * sx, CGFloat(r.y) * sy, CGFloat(r.count) * sx, sy]
                }]
            }
            let primaries: [[String: Any]] = closure.originals.flatMap(\.runs).sorted { $0.ordinal < $1.ordinal }.map {
                ["ordinal": $0.ordinal, "sourceSHA256": hash(Data($0.text.utf8)),
                 "originalPolygon": $0.polygon.map { [Double($0.x), Double($0.y)] }]
            }
            var metadata: [String: Any] = ["version": 1, "sourcePolicy": policy,
                "canonicalSourceRGBA256": digest, "originalSourceSize": [original.width, original.height],
                "sourceIdentity": sourceIdentity, "rfTextQueryHint": support.queryID,
                "rfOriginalBounds": array(support.bounds), "members": members,
                "originalPrimaryUnion": closure.primaryUnion, "originalPrimaryBounds": array(closure.primaryBounds),
                "originalPrimaryOperationID": closure.originals[0].operationID, "originalPrimaryPackets": primaries,
                "closedOriginalCellBounds": array(closure.samplingBounds), "cropOriginalPixels": array(crop),
                "unretainedDetectorIDs": closure.addedDetectorIDs, "originalDetectorSignatures": signatures,
                "requiredOriginalComponents": required, "unprovedPrimarySeeds": closure.unresolvedReferenceSeeds,
                "consumerContract": ["requiresFreshDetection": true, "requiresFreshRecognition": true,
                    "requiresNormalNativeGrouping": true, "requiresFreshFullSourceTranslation": true,
                    "requiresOriginalPrimaryLineageRebind": true, "requiresFreshExclusiveGlyphMask": true,
                    "mayErase": false, "mayMerge": false, "bboxErasureAuthorized": false]]
            let id = hash(try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]))
            guard let image = original.cropping(to: crop), image.width == Int(crop.width), image.height == Int(crop.height)
            else { throw Plan.Failure.crop }
            metadata["requestID"] = id; metadata["cropCanonicalRGBA256"] = try Plan.rgbaDigest(image)
            result.append(.init(id: id, originalCrop: image, metadata: metadata))
            pixels += count; used.formUnion(ids)
            note("original-detect-read-requested")
        }
        return result
    }

    /// Source-completeness guard AFTER fresh native detection/read/grouping.
    /// Every whole old CC cell must fit the fresh accepted column union, so a
    /// high-confidence read of only the previous x extent cannot pass. Two
    /// source pixels of sampling tolerance do not expand any removal authority.
    static func coversOriginalComponents(request: Plan.Request, freshCropPolygons: [[CGPoint]]) -> Bool {
        guard request.metadata["sourcePolicy"] as? String == policy,
              let crop = request.metadata["cropOriginalPixels"] as? [Double], crop.count == 4,
              let rows = request.metadata["requiredOriginalComponents"] as? [[String: Any]],
              !rows.isEmpty, rows.count <= 256, !freshCropPolygons.isEmpty, freshCropPolygons.count <= 64,
              freshCropPolygons.allSatisfy({ validQuad($0) }) else { return false }
        let polygons = freshCropPolygons.map { p in p.map { CGPoint(x: $0.x + crop[0], y: $0.y + crop[1]) } }
        var cells = 0, work = 0
        for row in rows {
            guard let runs = row["runs"] as? [[Double]], !runs.isEmpty, runs.count <= 8192 else { return false }
            for r in runs {
                guard r.count == 4, r.allSatisfy(\.isFinite), r[2] > 0, r[3] > 0 else { return false }
                // Split only for coverage measurement, NEVER ownership. A DB
                // component can span more than one fresh detected column.
                let n = max(1, Int(ceil(r[2] / 1.25)))
                cells += n; guard cells <= 524_288 else { return false }
                for i in 0..<n {
                    let x0 = r[0] + r[2] * Double(i) / Double(n), x1 = r[0] + r[2] * Double(i + 1) / Double(n)
                    let corners = [CGPoint(x: x0,y: r[1]),CGPoint(x: x1,y: r[1]),
                        CGPoint(x: x1,y: r[1]+r[3]),CGPoint(x: x0,y: r[1]+r[3])]
                    var covered = false
                    for p in polygons {
                        work += 1; guard work <= 8_388_608 else { return false }
                        if corners.allSatisfy({ inside($0, p, tolerance: 2) }) { covered = true; break }
                    }
                    guard covered else { return false }
                }
            }
        }
        return true
    }

    static func record(_ stage: String, fields: [String: Any]) {
        guard runtimeEnabled, let data = try? JSONSerialization.data(withJSONObject:
            ["stage": stage, "value": fields], options: [.sortedKeys]), data.count <= 2_097_152 else { return }
        var line = Data("causal_rf_original_context ".utf8)
        line.append(data); line.append(10); FileHandle.standardError.write(line)
    }

    static func detectorReceipts(_ packets: [E]) -> [[String: Any]] {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return packets.prefix(256).compactMap { packet in
            var sparse = packet; sparse.sourceProbabilityROI = nil
            guard let data = try? encoder.encode(sparse), let value = try? JSONSerialization.jsonObject(with: data)
            else { return nil }
            return ["cropRGBA256": packet.sourceProbabilityROI?.sourceDigest ?? "", "sparseOriginalRecord": value]
        }
    }

    private static func inspectContext(owners: [P.Owner], recordsByOwner: [String: [E]],
                        retainedRecordsByOwner: [String: [E]], allDetectors: [E],
                        support: P.Support, sourceIdentity: String, imageSize: CGSize,
                        separates: (CGRect, CGRect) -> Bool,
                        audit: ((String) -> Void)? = nil) -> ContextClosure? {
        func reject(_ reason: String) -> ContextClosure? { audit?(reason); return nil }
        guard sourceIdentity.hasPrefix("canonical-rgb8:"), owners.count <= 256,
              (1...256).contains(allDetectors.count), support.confidence.isFinite,
              (0.55...1).contains(support.confidence), valid(support.bounds),
              imageSize.width.isFinite, imageSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0 else { return reject("invalid-input") }
        let canvas = CGRect(origin: .zero, size: imageSize)
        let selected = owners.filter { $0.bounds.intersects(support.bounds) }
        guard (2...6).contains(selected.count), Set(owners.map(\.id)).count == owners.count,
              let operation = selected.first?.operationID, !operation.isEmpty,
              selected.allSatisfy({ owner in owner.operationID == operation && !owner.source.isEmpty &&
                  !owner.source.contains("\n\n") && !owner.source.contains("\u{2029}") &&
                  !owner.runs.isEmpty && valid(owner.bounds) && canvas.contains(owner.bounds) &&
                  owner.runs.allSatisfy({ run in run.polygon.allSatisfy { point in
                      owner.bounds.insetBy(dx: -1e-6, dy: -1e-6).contains(point)
                  } }) })
        else { return reject("invalid-primary-snapshot") }
        let runs = selected.flatMap(\.runs), selectedIDs = Set(selected.map(\.id))
        guard runs.count <= 64, Set(runs.map(\.ordinal)).count == runs.count,
              runs.allSatisfy({ validQuad($0.polygon) && !$0.text.isEmpty && $0.text.utf16.count <= 512 })
        else { return reject("invalid-primary-packets") }
        for i in selected.indices { for j in selected.indices where j > i {
            if separates(selected[i].bounds, selected[j].bounds) { return reject("explicit-source-separator") }
        } }
        let primaryBounds = selected.map(\.bounds).reduce(CGRect.null) { $0.union($1) }
        let outside = owners.filter { !selectedIDs.contains($0.id) }
        // An unrelated retained reading/kept source can lack rereadable runs.
        // Its complete original box remains a HARD keepout, including padding;
        // it need not qualify as an editable source in this transaction.
        guard outside.allSatisfy({ valid($0.bounds) && canvas.contains($0.bounds) })
        else { return reject("invalid-outside-keepout") }
        guard Set(allDetectors.map(\.ownerID)).count == allDetectors.count, let grid = allDetectors.first,
              allDetectors.allSatisfy({ $0.isValid && $0.ownershipVersion == 2 && $0.completeCCScan == true &&
                  $0.sourceWidth == Int(imageSize.width) && $0.sourceHeight == Int(imageSize.height) &&
                  $0.mapFullWidth == grid.mapFullWidth && $0.mapFullHeight == grid.mapFullHeight &&
                  $0.mapOriginX == grid.mapOriginX && $0.mapOriginY == grid.mapOriginY })
        else { return reject("invalid-detector-snapshot") }
        let byID = Dictionary(uniqueKeysWithValues: allDetectors.map { ($0.ownerID, $0) })
        var roots = Set<String>()
        for owner in selected {
            guard let records = recordsByOwner[owner.id], !records.isEmpty,
                  records.allSatisfy({ byID[$0.ownerID] == $0 }) else { return reject("missing-primary-detector-record") }
            roots.formUnion(records.map(\.ownerID))
        }
        var retainedIDs = Set<String>()
        for owner in owners {
            guard let records = retainedRecordsByOwner[owner.id], !records.isEmpty,
                  records.allSatisfy({ byID[$0.ownerID] == $0 })
            else { return reject("unknown-retained-detector:" + owner.id) }
            retainedIDs.formUnion(records.map(\.ownerID))
        }
        var bySeed = [Int: E.Component](), references = [Int: Set<String>]()
        var totalRuns = 0
        for record in allDetectors {
            for component in components(record) {
                totalRuns += component.runs.count
                guard totalRuns <= 131_072 else { return reject("snapshot-run-budget") }
                if let previous = bySeed[component.seed], previous != component { return reject("contradictory-component") }
                bySeed[component.seed] = component
                references[component.seed, default: []].insert(record.ownerID)
            }
        }
        var closedIDs = roots, queue = roots.sorted(), cursor = 0
        while cursor < queue.count {
            let id = queue[cursor]; cursor += 1
            guard let record = byID[id] else { return reject("missing-competitor") }
            var next = Set<String>()
            for component in components(record) { next.formUnion(references[component.seed] ?? []) }
            for candidate in record.candidateComponents ?? [] {
                guard Set(candidate.competingOwnerIDs).isSubset(of: references[candidate.component.seed] ?? [])
                else { return reject("missing-exact-competing-component") }
                next.formUnion(candidate.competingOwnerIDs)
            }
            for other in next.sorted() where !closedIDs.contains(other) {
                guard byID[other] != nil else { return reject("missing-competitor") }
                guard !retainedIDs.contains(other) else { return reject("outside-retained-competitor") }
                closedIDs.insert(other); queue.append(other)
                guard closedIDs.count <= 32 else { return reject("closure-detector-budget") }
            }
        }
        let added = closedIDs.subtracting(roots)
        guard !added.isEmpty else { return reject("already-closed") }
        let records = closedIDs.sorted().compactMap { byID[$0] }
        let seeds = Set(records.flatMap(components).map(\.seed)).sorted()
        let closed = seeds.compactMap { bySeed[$0] }
        guard closed.count <= 256, closed.reduce(0, { $0 + $1.runs.count }) <= 8192 else { return reject("closure-cell-budget") }
        let sx = imageSize.width / CGFloat(grid.mapFullWidth), sy = imageSize.height / CGFloat(grid.mapFullHeight)
        func cells(_ c: E.Component) -> [CGRect] {
            c.runs.map { CGRect(x: CGFloat($0.x) * sx, y: CGFloat($0.y) * sy,
                width: CGFloat($0.count) * sx, height: sy) }
        }
        var samplingBounds = primaryBounds, unresolved = [Int]()
        for component in closed {
            let measured = cells(component)
            // RF supplies only the read boundary; every exact DB cell must fit.
            guard measured.allSatisfy({ canvas.contains($0) && support.bounds.contains($0) })
            else { return reject("closure-cell-outside-rf") }
            guard outside.allSatisfy({ owner in !measured.contains { owner.bounds.intersects($0) } })
            else { return reject("outside-retained-primary-cell") }
            let bounds = measured.reduce(CGRect.null) { $0.union($1) }
            samplingBounds = samplingBounds.union(bounds)
            // This absence only triggers fresh inspection. It does not grant
            // primary affiliation or permission to use these cells as a mask.
            if !(references[component.seed] ?? []).isDisjoint(with: added),
               !runs.contains(where: { p in measured.allSatisfy { contained($0, p.polygon) } }) {
                unresolved.append(component.seed)
            }
        }
        guard valid(samplingBounds), samplingBounds.width * samplingBounds.height <= 1_048_576,
              outside.allSatisfy({ !$0.bounds.intersects(samplingBounds) }) else { return reject("foreign-source-in-sampling-scope") }
        for record in allDetectors where !closedIDs.contains(record.ownerID) {
            guard components(record).allSatisfy({ c in !cells(c).contains { $0.intersects(samplingBounds) } })
            else { return reject("unclosed-detector-island-in-sampling-scope") }
        }
        return ContextClosure(originals: selected, primaryUnion: runs.map(\.ordinal).sorted(),
            primaryBounds: primaryBounds, samplingBounds: samplingBounds,
            records: records, components: closed, addedDetectorIDs: added.sorted(),
            unresolvedReferenceSeeds: unresolved)
    }

    private static func components(_ e: E) -> [E.Component] {
        e.components + (e.ambiguousComponents ?? []) + (e.candidateComponents ?? []).map(\.component)
    }
    private static func valid(_ r: CGRect) -> Bool {
        !r.isNull && !r.isInfinite && [r.minX,r.minY,r.width,r.height].allSatisfy(\.isFinite) &&
            r.width > 0 && r.height > 0
    }
    private static func contained(_ r: CGRect, _ p: [CGPoint]) -> Bool {
        [CGPoint(x:r.minX,y:r.minY),CGPoint(x:r.maxX,y:r.minY),
         CGPoint(x:r.maxX,y:r.maxY),CGPoint(x:r.minX,y:r.maxY)].allSatisfy { inside($0,p,tolerance:0) }
    }

    private static func validQuad(_ p: [CGPoint]) -> Bool {
        guard p.count == 4, p.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
        let signs = p.indices.map { cross(p[$0],p[($0+1)%4],p[($0+2)%4]) }
        return signs.allSatisfy { $0 > 1e-8 } || signs.allSatisfy { $0 < -1e-8 }
    }
    private static func cross(_ a: CGPoint,_ b: CGPoint,_ c: CGPoint) -> CGFloat {
        (b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x)
    }
    private static func inside(_ q: CGPoint,_ p: [CGPoint],tolerance: CGFloat) -> Bool {
        let values = p.indices.map { i -> CGFloat in
            let a = p[i], b = p[(i+1)%4], length = hypot(b.x-a.x,b.y-a.y)
            return cross(a,b,q) / length
        }
        return values.allSatisfy { $0 >= -tolerance } || values.allSatisfy { $0 <= tolerance }
    }
    private static func array(_ r: CGRect) -> [Double] { [r.minX,r.minY,r.width,r.height] }
    private static func hash(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x",$0) }.joined() }
}
