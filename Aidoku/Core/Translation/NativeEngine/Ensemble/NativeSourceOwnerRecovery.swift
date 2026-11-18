import CoreGraphics
import Foundation

/// Source-bound metadata repairs before grouping/shaping. All switches are opt-in.
/// The caller must supply the current image's verified OCR packet (the evidence store
/// owns identity validation). No paths, labels, RF membership or peer fonts are used.
enum NativeSourceOwnerRecovery {
    typealias Result = (items: [[String: Any]], audit: [[String: Any]])

    struct TargetOwnershipResult {
        let displayItems: [[String: Any]]
        /// Every original source owner, including non-contained redundant reads.
        /// Mask generation and original-pixel palette evidence MUST use these.
        let sourceItems: [[String: Any]]
        let audit: [[String: Any]]
    }

    /// Layout-only deduplication. A long redundant OCR fragment may extend
    /// beyond its paragraph and therefore fail high-IoU proposal deduplication.
    /// Keep every original owner available to removal/style evidence.
    static func partitionDisplayTargets(_ items: [[String: Any]]) -> TargetOwnershipResult {
        let exact = partitionExactDuplicateTargets(items)
        guard exact.displayItems.count <= 512 else { return exact }
        let rows = exact.displayItems
        func normalized(_ item: [String: Any]) -> String {
            let source = (item["sourceOriginalText"] as? String ?? "").precomposedStringWithCompatibilityMapping
            return String(source.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        }
        func box(_ polygon: [CGPoint]) -> CGRect {
            polygon.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        }
        let texts = rows.map(normalized)
        let order = rows.indices.sorted {
            texts[$0].count == texts[$1].count ? $0 < $1 : texts[$0].count > texts[$1].count
        }
        var kept: [Int] = [], audit = exact.audit
        for index in order {
            let item = rows[index], text = texts[index]
            guard active(item), text.count >= 5, text.count <= 8192,
                  let confidence = number(item["sourceConfidence"]), (0.8...1).contains(confidence),
                  let polygon = points(item["sourcePolygon"]), polygon.count == 4 else {
                kept.append(index); continue
            }
            let area = NativeOCRDirectionGeometry.area(polygon), small = box(polygon)
            guard area > 0, small.width > 0, small.height > 0 else { kept.append(index); continue }
            let matches: [(index: Int, coverage: Double)] = kept.compactMap { parent in
                let peer = rows[parent], body = texts[parent]
                guard active(peer), body.count > text.count,
                      occurrences(text, in: body).count == 1,
                      let score = number(peer["sourceConfidence"]), (0.8...1).contains(score),
                      let other = points(peer["sourcePolygon"]), other.count == 4 else { return nil }
                for key in ["paragraphID", "sourceParagraphID"] {
                    if let a = item[key] as? String, let b = peer[key] as? String, a != b { return nil }
                }
                let coverage = Double(NativeOCRDirectionGeometry.intersectionArea(polygon, other) / area)
                if coverage >= 0.85 { return (parent, coverage) }
                let large = box(other), overlap = small.intersection(large)
                // Font estimates from an overextended fragment can themselves
                // be wrong; never use them to veto this source/geometry witness.
                // Normalization is for lexical matching only. Do not discard
                // visible symbols when measuring the length of a physical read.
                let visibleLength = compact(item["sourceOriginalText"] as? String ?? "").count
                guard !overlap.isNull, visibleLength >= 8, coverage >= 0.5 else { return nil }
                let vertical = item["sourceVertical"] as? Bool ?? (small.height > small.width)
                let peerVertical = peer["sourceVertical"] as? Bool ?? (large.height > large.width)
                guard vertical == peerVertical else { return nil }
                let short = vertical ? overlap.width / small.width : overlap.height / small.height
                let long = vertical ? overlap.height / small.height : overlap.width / small.width
                return short >= 0.75 && long >= 0.7 ? (parent, coverage) : nil
            }
            // Multiple physical paragraphs containing the phrase are ambiguous.
            guard matches.count == 1, let match = matches.first else { kept.append(index); continue }
            audit.append(["action": "suppressDuplicateFragmentDisplay", "id": item["id"] as Any,
                "representativeID": rows[match.index]["id"] as Any, "sourceCoverage": match.coverage,
                "sourceOwnersRetained": true,
                "evidence": "unique-normalized-source-substring;overlapping-source-polygons;display-only"])
        }
        return .init(displayItems: kept.sorted().map { rows[$0] }, sourceItems: items, audit: audit)
    }

    /// Replay payloads may predate upstream OCR deduplication. Retain all physical
    /// source owners for erasure while painting exactly repeated reads only once.
    static func partitionExactDuplicateTargets(_ items: [[String: Any]]) -> TargetOwnershipResult {
        func readKey(_ text: String) -> String {
            String(compact(text.precomposedStringWithCompatibilityMapping).map { character -> Character in
                switch character {
                case "「", "『", "“": "「"
                case "」", "』", "”": "」"
                default: character
                }
            })
        }
        var kept: [Int] = [], audit: [[String: Any]] = []
        let order = items.indices.sorted {
            let a = number(items[$0]["sourceConfidence"]) ?? 0
            let b = number(items[$1]["sourceConfidence"]) ?? 0
            return a == b ? $0 < $1 : a > b
        }
        for index in order {
            let item = items[index]
            guard active(item), let source = item["sourceOriginalText"] as? String, !compact(source).isEmpty,
                  let target = item["text"] as? String,
                  let polygon = points(item["sourcePolygon"]), polygon.count == 4 else {
                kept.append(index); continue
            }
            let area = NativeOCRDirectionGeometry.area(polygon)
            let duplicate = kept.first { other in
                let peer = items[other]
                guard active(peer), let peerSource = peer["sourceOriginalText"] as? String,
                      readKey(source) == readKey(peerSource),
                      compact(target) == compact(peer["text"] as? String ?? ""),
                      let q = points(peer["sourcePolygon"]), q.count == 4 else { return false }
                let peerArea = NativeOCRDirectionGeometry.area(q)
                let minimum = min(area, peerArea), maximum = max(area, peerArea)
                guard minimum > 0, minimum / maximum >= 0.65 else { return false }
                return NativeOCRDirectionGeometry.intersectionArea(polygon, q) / minimum >= 0.90
            }
            if let duplicate {
                audit.append(["action": "suppressExactDuplicateDisplay", "id": item["id"] as Any,
                    "representativeID": items[duplicate]["id"] as Any,
                    "sourceOwnersRetained": true,
                    "evidence": "quote-normalized-source-and-identical-target;actual-source-polygon-overlap;highest-recognition-confidence"])
            } else { kept.append(index) }
        }
        return .init(displayItems: kept.sorted().map { items[$0] }, sourceItems: items, audit: audit)
    }

    /// Separate long, exactly redundant display runs from physical source owners.
    /// Unlike strict short-owner consolidation, this NEVER retires source geometry.
    /// The caller must route sourceItems to removal and displayItems to layout;
    /// do not pass displayItems alone into a combined mask/layout entrypoint.
    /// New policy remains off until actual source/final verification by the caller.
    static func partitionRedundantTargets(_ items: [[String: Any]], evidence: [String: Any],
                                          imageSize: CGSize, enabled: Bool = false) -> TargetOwnershipResult {
        let unchanged = TargetOwnershipResult(displayItems: items, sourceItems: items, audit: [])
        guard enabled, let rows = inventory(evidence, imageSize), items.count <= 512 else { return unchanged }
        let ids = items.compactMap { $0["id"] as? String }
        guard ids.count == items.count, Set(ids).count == ids.count else { return unchanged }
        // A rectangle envelope is a search domain, not redundancy evidence. Bind
        // every candidate to its exact final OCR source, target and polygon first.
        let matches = items.map { item -> (index: Int, row: [String: Any])? in
            guard active(item), item["vertical"] as? Bool == false,
                  item["sourceVertical"] as? Bool == true,
                  item["uprightQuadText"] as? Bool != true, item["drawsUprightQuadText"] as? Bool != true,
                  let match = exact(item, rows), usable(match.row, confidence: 0.9),
                  match.row["sourceOrientation"] as? String == "vertical",
                  (match.row["sourceOCRAlternatives"] as? [Any] ?? []).isEmpty,
                  let source = match.row["source"] as? String, !source.contains(where: \.isNewline),
                  source.utf16.count <= 8192, canonicalTranslation(item, match.row) != nil,
                  let box = rect(item["sourceBounds"]), let polygon = points(item["sourcePolygon"]),
                  let observed = points(match.row["polygon"]), samePoints(polygon, observed) else { return nil }
            let rectangle = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
            guard samePoints(polygon, rectangle) else { return nil }
            return match
        }
        struct Witness {
            let child: Int
            let parent: Int
            let targetRange: NSRange
            let record: [String: Any]
        }
        var accepted: [Witness] = [], audit: [[String: Any]] = []
        for child in items.indices {
            guard let short = matches[child], let shortSource = short.row["source"] as? String,
                  (4...32).contains(compact(shortSource).count),
                  shortSource.filter({ $0.isLetter || $0.isNumber }).count >= 4,
                  short.row["sourceSingleVerticalColumn"] as? Bool == true,
                  let shortTarget = canonicalTranslation(items[child], short.row),
                  (4...64).contains(compact(shortTarget).count),
                  shortTarget.filter({ $0.isLetter || $0.isNumber }).count >= 4,
                  let small = rect(items[child]["sourceBounds"]) else { continue }
            let parents = items.indices.filter { parent in
                guard parent != child, matches[parent] != nil,
                      let large = rect(items[parent]["sourceBounds"]),
                      small.width * small.height <= large.width * large.height * 0.35,
                      small.minX >= large.minX, small.maxX <= large.maxX,
                      small.height <= large.height * 1.15 else { return false }
                let overlap = small.intersection(large)
                return !overlap.isNull && overlap.height >= small.height * 0.85
            }
            guard !parents.isEmpty else { continue }
            var record: [String: Any] = ["action": "preserveTargetOwner", "id": ids[child],
                "sourceOCRIndex": short.index, "candidateParentIDs": parents.map { ids[$0] },
                "sourceGeometryUnchanged": true]
            guard parents.count == 1 else {
                record["reason"] = "ambiguousPhysicalOwner"; audit.append(record); continue
            }
            let parent = parents[0], body = matches[parent]!, large = rect(items[parent]["sourceBounds"])!
            record["parentID"] = ids[parent]
            let conflict = ["paragraphID", "sourceParagraphID"].contains { key in
                guard let a = items[child][key] as? String, let b = items[parent][key] as? String else { return false }
                return a != b
            }
            guard !conflict, let bodySource = body.row["source"] as? String,
                  let bodyTarget = canonicalTranslation(items[parent], body.row), bodyTarget.utf16.count <= 8192 else {
                record["reason"] = "paragraphOrTranslationConflict"; audit.append(record); continue
            }
            let source = compact(bodySource) as NSString, target = compact(bodyTarget) as NSString
            let sourceRanges = occurrences(compact(shortSource), in: source as String)
            let targetRanges = occurrences(compact(shortTarget), in: target as String)
            record["sourceOccurrences"] = sourceRanges.count
            record["targetOccurrences"] = targetRanges.count
            guard sourceRanges.count == 1, targetRanges.count == 1 else {
                record["reason"] = "missingOrNonuniqueSourceAndTargetCorroboration"; audit.append(record); continue
            }
            let sourceRange = sourceRanges[0], targetRange = targetRanges[0]
            let prefix = sourceRange.location == 0 && targetRange.location == 0 &&
                small.midX >= large.minX + large.width * 0.65
            let tail = sourceRange.location > 0 && targetRange.location > 0 &&
                NSMaxRange(sourceRange) == source.length && NSMaxRange(targetRange) == target.length &&
                small.midX <= large.minX + large.width * 0.35
            guard prefix || tail else {
                record["reason"] = "lexicalBoundaryOrSourceColumnAmbiguous"; audit.append(record); continue
            }
            record["action"] = "partitionRedundantTargetOwner"
            record["reason"] = prefix ? "uniqueLongSourceAndTargetPrefix" : "uniqueLongSourceAndTargetTail"
            record["sourceRangeInWhitespaceCompactedParentUTF16"] = [sourceRange.location, sourceRange.length]
            record["targetRangeInWhitespaceCompactedParentUTF16"] = [targetRange.location, targetRange.length]
            record["parentSourceOCRIndex"] = body.index
            record["sourceMaskAuthority"] = "all original source owners retained separately; no rectangle union or mask expansion"
            accepted.append(Witness(child: child, parent: parent, targetRange: targetRange, record: record))
        }
        let safe = accepted.filter { candidate in
            !accepted.contains { rival in
                rival.child != candidate.child && (rival.child == candidate.parent || rival.parent == candidate.child ||
                    (rival.parent == candidate.parent && NSIntersectionRange(rival.targetRange, candidate.targetRange).length > 0))
            }
        }
        for candidate in accepted where !safe.contains(where: { $0.child == candidate.child }) {
            audit.append(["action": "preserveTargetOwner", "id": ids[candidate.child],
                "parentID": ids[candidate.parent], "reason": "competingOrChainedTargetOwner", "sourceGeometryUnchanged": true])
        }
        var display = items
        for candidate in safe {
            var children = display[candidate.parent]["sourceOwnerConsolidatedChildren"] as? [[String: Any]] ?? []
            let row = matches[candidate.child]!.row
            children.append(["id": ids[candidate.child], "text": items[candidate.child]["text"]!, "source": row["source"]!,
                "translation": canonicalTranslation(items[candidate.child], row)!,
                "sourceOCRIndex": matches[candidate.child]!.index,
                "sourceBounds": items[candidate.child]["sourceBounds"]!,
                "sourcePolygon": items[candidate.child]["sourcePolygon"]!,
                "ownershipKind": "displayOnlySourceRetained",
                "maskCoverage": "original source owner retained separately in sourceItems; polygon containment not claimed"])
            display[candidate.parent]["sourceOwnerConsolidatedChildren"] = children
            audit.append(candidate.record)
        }
        let redundant = Set(safe.map(\.child))
        return TargetOwnershipResult(displayItems: display.indices.filter { !redundant.contains($0) }.map { display[$0] },
            sourceItems: items, audit: audit)
    }

    static func apply(_ items: [[String: Any]], evidence: [String: Any], imageSize: CGSize,
                      normalizeParagraphs: Bool = false, normalizeSkew: Bool = false,
                      consolidateShortOwners: Bool = false, recoverDistinctFragments: Bool = false) -> Result {
        let paragraphs = normalizeArtificialParagraphs(items, evidence: evidence,
            imageSize: imageSize, enabled: normalizeParagraphs)
        let skew = normalizeSourceBBoxSkew(paragraphs.items, evidence: evidence,
            imageSize: imageSize, enabled: normalizeSkew)
        let owners = consolidateNestedOwners(skew.items, evidence: evidence,
            imageSize: imageSize, enabled: consolidateShortOwners)
        let recovery = proposeDistinctFragmentRecovery(owners.items, evidence: evidence,
            imageSize: imageSize, enabled: recoverDistinctFragments)
        return (recovery.items, paragraphs.audit + skew.audit + owners.audit + recovery.audit)
    }

    /// An upstream repair contract, NOT a display merge. Overlapping final OCR
    /// polygons cannot prove shared physical ink, paragraph ownership or style.
    /// Preserve every lexical run, mask and font until an upstream consumer obtains
    /// original detector/recognizer lineage and validates any refreshed translation.
    /// The context ROI is recognition-only: it never grants erasure authority.
    static func proposeDistinctFragmentRecovery(_ items: [[String: Any]], evidence: [String: Any],
                                                imageSize: CGSize, enabled: Bool = false) -> Result {
        guard enabled, let rows = inventory(evidence, imageSize), items.count <= 512 else { return (items, []) }
        let ids = items.compactMap { $0["id"] as? String }
        guard ids.count == items.count, Set(ids).count == ids.count else { return (items, []) }
        let matches = items.map { item -> (index: Int, row: [String: Any])? in
            guard active(item), let match = exact(item, rows), usable(match.row, confidence: 0),
                  let source = match.row["source"] as? String, !compact(source).isEmpty,
                  source.utf16.count <= 8192, canonicalTranslation(item, match.row) != nil,
                  let polygon = points(item["sourcePolygon"]), polygon.count >= 3,
                  let observed = points(match.row["polygon"]), samePoints(polygon, observed) else { return nil }
            return match
        }
        func boxArray(_ box: CGRect, pixels: Bool = false) -> [Double] {
            let sx = pixels ? Double(imageSize.width) : 1, sy = pixels ? Double(imageSize.height) : 1
            return [Double(box.minX) * sx, Double(box.minY) * sy, Double(box.width) * sx, Double(box.height) * sy]
        }
        func stage(_ key: String, _ member: String) -> [String: Any] {
            let packet = evidence[key] as? [String: Any]
            let observations = packet?[member] as? [Any] ?? evidence[key] as? [Any] ?? []
            return ["availability": observations.isEmpty ? "unavailableOrEmpty" : "availableUnbound",
                "observationCount": observations.count]
        }
        let lineage = ["detector": stage("originalDetector", "boxes"),
            "recognizer": stage("originalRecognizer", "regions"),
            "decoded": stage("originalDecodedReads", "regions"),
            "rejected": stage("originalRejectedReads", "regions")]
        func snapshot(_ index: Int) -> [String: Any] {
            let item = items[index], match = matches[index]!
            return ["id": ids[index], "sourceOCRIndex": match.index, "source": match.row["source"]!,
                "target": canonicalTranslation(item, match.row)!, "sourceBounds": item["sourceBounds"]!,
                "sourcePolygon": item["sourcePolygon"]!, "confidence": match.row["confidence"] ?? NSNull(),
                "sourceIndex": match.row["sourceIndex"] ?? NSNull(),
                "sourceOrientation": match.row["sourceOrientation"] ?? NSNull(),
                "sourceOCRAlternatives": match.row["sourceOCRAlternatives"] ?? [],
                "sourceFontSize": item["sourceFontSize"] ?? NSNull(),
                "sourceLettering": item["sourceLettering"] ?? NSNull(),
                "sourceStyleAuthority": "unverified; saved display/font estimate is not shared-ink or shared-style proof"]
        }
        var output = items, audit: [[String: Any]] = []
        for child in items.indices {
            guard let short = matches[child], let source = short.row["source"] as? String,
                  (1...8).contains(compact(source).count), source.contains(where: { $0.isLetter || $0.isNumber }),
                  let small = rect(items[child]["sourceBounds"]) else { continue }
            // This threshold selects a bounded re-recognition request only. It
            // does not certify a parent; partial and competing owners stay separate.
            let peers = items.indices.filter { peer in
                guard peer != child, matches[peer] != nil, let large = rect(items[peer]["sourceBounds"]) else { return false }
                let overlap = small.intersection(large)
                let smallerArea = min(small.width * small.height, large.width * large.height)
                return !overlap.isNull && overlap.width * overlap.height >= smallerArea * 0.15
            }
            guard !peers.isEmpty else { continue }
            let context = peers.reduce(small) { $0.union(rect(items[$1]["sourceBounds"])!) }
            let involved = [child] + peers
            // Include every other owned footprint intersecting the recognition
            // context, including protected/ambiguous rows. They are keep-outs,
            // never implicitly assigned to the short fragment's paragraph.
            let keepOuts = items.indices.filter { !involved.contains($0) }.compactMap { index -> [String: Any]? in
                guard let box = rect(items[index]["sourceBounds"]), box.intersects(context) else { return nil }
                return ["id": ids[index], "sourceBounds": items[index]["sourceBounds"]!,
                    "sourcePolygon": items[index]["sourcePolygon"] ?? NSNull()]
            }
            let relations: [[String: Any]] = peers.map { peer in
                let parent = matches[peer]!, parentSource = parent.row["source"] as! String
                let childTarget = canonicalTranslation(items[child], short.row)!
                let parentTarget = canonicalTranslation(items[peer], parent.row)!
                let conflict = ["paragraphID", "sourceParagraphID"].contains { key in
                    guard let a = items[child][key] as? String, let b = items[peer][key] as? String else { return false }
                    return a != b
                }
                return ["id": ids[peer], "sourceExactOccurrences": occurrences(source, in: parentSource).count,
                    "targetExactOccurrences": occurrences(childTarget, in: parentTarget).count,
                    "fullPolygonContainment": fullyContains(points(items[peer]["sourcePolygon"])!,
                        points(items[child]["sourcePolygon"])!), "explicitParagraphConflict": conflict,
                    "paragraphOwnership": "unproven"]
            }
            let candidate: [String: Any] = ["version": 1, "kind": "upstreamOCRLineageRepair",
                "state": "requiresOriginalInkAndLineage", "fragment": snapshot(child),
                "overlappingOwners": peers.map { snapshot($0) }, "relations": relations,
                "imageSize": [Double(imageSize.width), Double(imageSize.height)],
                "recognitionContextBounds": boxArray(context), "recognitionContextPixelBounds": boxArray(context, pixels: true),
                "recognitionRequests": [
                    ["purpose": "recoverOwnedFragment", "bounds": boxArray(small),
                     "pixelBounds": boxArray(small, pixels: true), "polygon": items[child]["sourcePolygon"]!],
                    ["purpose": "resolveOverlappingParagraphLineage", "bounds": boxArray(context),
                     "pixelBounds": boxArray(context, pixels: true)]
                ], "contextKeepOuts": keepOuts, "savedLineage": lineage,
                "requiredProof": ["bind original detector/recognizer reads to exact source polygons",
                    "resolve shared physical paragraph and independent style/ink boundaries",
                    "reconcile all exact source and target lexical runs without deletion",
                    "refresh translation if repaired source changes; verify completeness before replacing display"],
                "jointLayoutCertified": false, "sourceFontUncertainty": "not resolved; no peer font substitution",
                "displayMutationAllowed": false, "maskExpansionAllowed": false,
                "translationRefreshRequiredBeforeSourceReplacement": true]
            output[child]["sourceOwnerRecoveryCandidate"] = candidate
            audit.append(["action": "proposeUpstreamOCRLineageRepair", "id": ids[child],
                "sourceOCRIndex": short.index, "overlappingOwnerIDs": peers.map { ids[$0] },
                "textAndGeometryUnchanged": true, "jointLayoutCertified": false])
        }
        return (output, audit)
    }

    /// Retire only a fully redundant display owner. Its physical source polygon
    /// must be wholly inside the unchanged parent's polygon, and exact OCR/source
    /// and target strings must each corroborate one unique prefix or tail. This
    /// deliberately abstains on partial containment and OCR omissions/alternates.
    /// No translated text is appended, rewritten or inferred. Parent mask geometry
    /// already contains the child; original child strings remain in provenance.
    static func consolidateNestedOwners(_ items: [[String: Any]], evidence: [String: Any],
                                        imageSize: CGSize, enabled: Bool = false) -> Result {
        guard enabled, let rows = inventory(evidence, imageSize), items.count <= 512 else { return (items, []) }
        let ids = items.compactMap { $0["id"] as? String }
        guard ids.count == items.count, Set(ids).count == ids.count else {
            return (items, [["action": "preserveNestedOwner", "reason": "missingOrDuplicateItemIdentity"]])
        }
        let matches = items.map { exact($0, rows) }
        struct Witness {
            let child: Int
            let parent: Int
            let sourceIndex: Int
            let targetRange: NSRange
            let record: [String: Any]
        }
        var accepted: [Witness] = [], audit: [[String: Any]] = []
        for child in items.indices {
            guard active(items[child]), let short = matches[child],
                  let shortSource = short.row["source"] as? String,
                  (1...3).contains(compact(shortSource).count),
                  shortSource.contains(where: { $0.isLetter || $0.isNumber }),
                  let small = rect(items[child]["sourceBounds"]) else { continue }
            let parents = items.indices.filter { parent in
                guard parent != child, active(items[parent]), let body = matches[parent],
                      let source = body.row["source"] as? String, compact(source).count >= 8,
                      let large = rect(items[parent]["sourceBounds"]),
                      small.width * small.height <= large.width * large.height * 0.3 else { return false }
                let overlap = small.intersection(large)
                return !overlap.isNull && overlap.width * overlap.height >= small.width * small.height * 0.85
            }
            guard !parents.isEmpty else { continue }
            var record: [String: Any] = ["action": "preserveNestedOwner", "id": ids[child],
                "sourceOCRIndex": short.index, "candidateParentIDs": parents.map { ids[$0] },
                "textAndGeometryUnchanged": true]
            guard parents.count == 1 else {
                record["reason"] = "ambiguousPhysicalOwner"; audit.append(record); continue
            }
            let parent = parents[0], body = matches[parent]!
            let large = rect(items[parent]["sourceBounds"])!
            record["parentID"] = ids[parent]
            record["shortSource"] = shortSource
            record["parentSource"] = body.row["source"] ?? NSNull()
            guard usable(short.row, confidence: 0.8), usable(body.row, confidence: 0.8),
                  body.row["sourceOrientation"] as? String == "vertical",
                  items[child]["vertical"] as? Bool != true, items[parent]["vertical"] as? Bool != true,
                  !["uprightQuadText", "drawsUprightQuadText"].contains(where: {
                      items[child][$0] as? Bool == true || items[parent][$0] as? Bool == true
                  }) else {
                record["reason"] = "uncertainSourceObservation"; audit.append(record); continue
            }
            let conflict = ["paragraphID", "sourceParagraphID"].contains { key in
                guard let a = items[child][key] as? String, let b = items[parent][key] as? String else { return false }
                return a != b
            }
            guard !conflict else {
                record["reason"] = "explicitParagraphConflict"; audit.append(record); continue
            }
            guard let shortTarget = canonicalTranslation(items[child], short.row),
                  let bodyTarget = canonicalTranslation(items[parent], body.row),
                  shortTarget.utf16.count <= 32, bodyTarget.utf16.count <= 8192,
                  let bodySource = body.row["source"] as? String, bodySource.utf16.count <= 8192 else {
                record["reason"] = "missingOrChangedTranslationBinding"; audit.append(record); continue
            }
            let sourceRanges = occurrences(compact(shortSource), in: compact(bodySource))
            let targetRanges = occurrences(compact(shortTarget), in: compact(bodyTarget))
            record["sourceOccurrences"] = sourceRanges.count
            record["targetOccurrences"] = targetRanges.count
            guard sourceRanges.count == 1, targetRanges.count == 1 else {
                record["reason"] = "missingOrNonuniqueSourceAndTargetCorroboration"
                audit.append(record); continue
            }
            // Bbox containment alone cannot certify physical ink. Require exact
            // corresponding polygons too; never enlarge the parent erasure ROI.
            guard let childQuad = points(items[child]["sourcePolygon"]),
                  let parentQuad = points(items[parent]["sourcePolygon"]),
                  let observedChild = points(short.row["polygon"]), let observedParent = points(body.row["polygon"]),
                  samePoints(childQuad, observedChild), samePoints(parentQuad, observedParent),
                  fullyContains(parentQuad, childQuad),
                  small.intersection(large).width * small.intersection(large).height >= small.width * small.height * (1 - 1e-8)
            else {
                record["reason"] = "partialOrUnverifiedPhysicalContainment"; audit.append(record); continue
            }
            let sourceText = compact(bodySource) as NSString, targetText = compact(bodyTarget) as NSString
            let sourceRange = sourceRanges[0], targetRange = targetRanges[0]
            func letters(_ text: String) -> Int { text.filter { $0.isLetter || $0.isNumber }.count }
            let sourceBefore = letters(sourceText.substring(to: sourceRange.location))
            let sourceAfter = letters(sourceText.substring(from: NSMaxRange(sourceRange)))
            let targetBefore = letters(targetText.substring(to: targetRange.location))
            let targetAfter = letters(targetText.substring(from: NSMaxRange(targetRange)))
            let prefix = sourceBefore == 0 && targetBefore == 0 && small.midY <= large.minY + large.height * 0.25
            let tail = sourceBefore > 0 && targetBefore > 0 && sourceAfter <= 2 && targetAfter == 0 &&
                small.midY >= large.minY + large.height * 0.6
            guard prefix || tail else {
                record["reason"] = "lexicalBoundaryOrSourcePositionAmbiguous"; audit.append(record); continue
            }
            record["action"] = "consolidateRedundantNestedOwner"
            record["reason"] = prefix ? "uniqueNestedSourceAndTargetPrefix" : "uniqueNestedSourceAndTargetTail"
            record["textAndGeometryUnchanged"] = false
            record["parentTextAndGeometryUnchanged"] = true
            record["sourceSourceRangeUTF16"] = [sourceRange.location, sourceRange.length]
            record["targetRangeInWhitespaceCompactedParentUTF16"] = [targetRange.location, targetRange.length]
            record["parentSourceOCRIndex"] = body.index
            record["translationCompleteness"] = "entire child text occurs once in retained parent; exact provider strings retained"
            accepted.append(Witness(child: child, parent: parent, sourceIndex: short.index,
                targetRange: targetRange, record: record))
        }
        // Two independently located short reads cannot both consume one target
        // span. Keep all such competitors rather than depending on iteration order.
        let safe = accepted.filter { candidate in
            accepted.filter { $0.parent == candidate.parent && $0.targetRange == candidate.targetRange }.count == 1
        }
        for candidate in accepted where !safe.contains(where: { $0.child == candidate.child }) {
            audit.append(["action": "preserveNestedOwner", "id": ids[candidate.child],
                "parentID": ids[candidate.parent], "reason": "competingChildTargetSpan", "textAndGeometryUnchanged": true])
        }
        var output = items
        for candidate in safe {
            let child = items[candidate.child]
            var provenance = output[candidate.parent]["sourceOwnerConsolidatedChildren"] as? [[String: Any]] ?? []
            provenance.append(["id": ids[candidate.child], "text": child["text"] ?? NSNull(),
                "source": rows[candidate.sourceIndex]["source"] ?? NSNull(),
                "translation": rows[candidate.sourceIndex]["translation"] ?? NSNull(),
                "sourceBounds": child["sourceBounds"] ?? NSNull(), "sourcePolygon": child["sourcePolygon"] ?? NSNull(),
                "sourceOCRIndex": candidate.sourceIndex, "maskCoverage": "fully inside unchanged parent polygon"])
            output[candidate.parent]["sourceOwnerConsolidatedChildren"] = provenance
            audit.append(candidate.record)
        }
        let retired = Set(safe.map(\.child))
        return (output.indices.filter { !retired.contains($0) }.map { output[$0] }, audit)
    }

    /// A single observed vertical source column is not multiple source paragraphs.
    /// Collapse only blank target paragraphs, not ordinary target line wraps. The
    /// exact provider string is retained separately; non-whitespace UTF16 is invariant.
    static func normalizeArtificialParagraphs(_ items: [[String: Any]], evidence: [String: Any],
                                             imageSize: CGSize, enabled: Bool = false) -> Result {
        guard enabled, let rows = inventory(evidence, imageSize), items.count <= 512 else { return (items, []) }
        let blank = try! NSRegularExpression(pattern: "(?:\\r\\n|\\n|\\r)[\\t ]*(?:\\r\\n|\\n|\\r)(?:[\\t ]*(?:\\r\\n|\\n|\\r))*")
        var audit: [[String: Any]] = []
        let output = items.map { item -> [String: Any] in
            guard active(item), let text = item["text"] as? String,
                  blank.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil,
                  let match = exact(item, rows), usable(match.row, confidence: 0.8),
                  match.row["sourceOrientation"] as? String == "vertical",
                  match.row["sourceSingleVerticalColumn"] as? Bool == true,
                  let source = match.row["source"] as? String, source.count >= 3,
                  !source.contains(where: \.isNewline),
                  (match.row["unitMemberRects"] as? [Any] ?? []).count <= 1,
                  let translation = match.row["translation"] as? String, same(text, translation)
            else { return item }
            let normalized = blank.stringByReplacingMatches(in: text,
                range: NSRange(text.startIndex..., in: text), withTemplate: " ")
            guard same(compact(text), compact(normalized)) else { return item }
            var result = item
            result["text"] = normalized
            result["sourceOwnerCanonicalTranslation"] = text
            audit.append(["action": "normalizeTargetBlankParagraphs", "id": item["id"] ?? NSNull(),
                "sourceOCRIndex": match.index, "beforeText": text, "afterText": normalized,
                "nonWhitespaceUTF16Unchanged": true,
                "authority": "unique exact OCR + exact saved translation + observed single source column; display whitespace only"])
            return result
        }
        return (output, audit)
    }

    /// Source skew remains in sourcePolygon. A horizontal translated body receives
    /// an upright bbox seed rather than inheriting the source column's tilt/fit.
    /// This is an explicit display policy, not a correction of the original quad.
    static func normalizeSourceBBoxSkew(_ items: [[String: Any]], evidence: [String: Any],
                                       imageSize: CGSize, enabled: Bool = false) -> Result {
        guard enabled, let rows = inventory(evidence, imageSize), items.count <= 512 else { return (items, []) }
        var audit: [[String: Any]] = []
        let output = items.map { item -> [String: Any] in
            guard active(item), item["vertical"] as? Bool == false,
                  item["uprightQuadText"] as? Bool != true, item["drawsUprightQuadText"] as? Bool != true,
                  let rotation = number(item["rotation"]), abs(rotation) >= 0.05, abs(rotation) <= 0.35,
                  let match = exact(item, rows), usable(match.row, confidence: 0.7),
                  match.row["sourceOrientation"] as? String == "vertical",
                  match.row["sourceSingleVerticalColumn"] as? Bool == true,
                  let box = rect(item["sourceBounds"]), let quad = points(match.row["polygon"]),
                  let currentQuad = points(item["sourcePolygon"]), quad.count == 4,
                  zip(quad, currentQuad).allSatisfy({ abs($0.x - $1.x) < 1e-8 && abs($0.y - $1.y) < 1e-8 }),
                  currentQuad.count == 4,
                  let source = match.row["source"] as? String, !source.isEmpty,
                  let text = item["text"] as? String,
                  let saved = match.row["translation"] as? String,
                  same(compact(text), compact(saved)),
                  same(text, saved) || same(item["sourceOwnerCanonicalTranslation"] as? String ?? "", saved),
                  let frame = item["sourceFrame"] as? [Double], frame.count == 4,
                  zip(frame, [0, 0, Double(imageSize.width), Double(imageSize.height)]).allSatisfy({ abs($0 - $1) < 1e-8 })
            else { return item }
            let envelope = quad.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
            guard close(box, envelope), quad[3].y > quad[0].y, quad[2].y > quad[1].y,
                  quad[1].x > quad[0].x, quad[2].x > quad[3].x else { return item }
            func angle(_ a: CGPoint, _ b: CGPoint) -> Double {
                -atan2(Double(b.x - a.x) * imageSize.width, Double(b.y - a.y) * imageSize.height)
            }
            let left = angle(quad[0], quad[3]), right = angle(quad[1], quad[2])
            guard abs(left - right) <= 0.02, abs(rotation - (left + right) / 2) <= 0.03 else { return item }
            var result = item
            result["rotation"] = 0.0
            result["x"] = Double(box.minX * imageSize.width)
            result["y"] = Double(box.minY * imageSize.height)
            result["width"] = Double(box.width * imageSize.width)
            result["height"] = Double(box.height * imageSize.height)
            result.removeValue(forKey: "rotationPlannedFontSize")
            result["sourceOwnerOriginalDisplayRotation"] = rotation
            result["sourceOwnerSourceSkewRadians"] = (left + right) / 2
            audit.append(["action": "normalizeInheritedSourceSkew", "id": item["id"] ?? NSNull(),
                "sourceOCRIndex": match.index, "beforeRotation": rotation, "afterRotation": 0.0,
                "sourcePolygonUnchanged": true, "translationUTF16Unchanged": true, "fontsUnchanged": true,
                "authority": "exact OCR quad confirms inherited vertical source angle; opt-in upright horizontal display bbox seed"])
            return result
        }
        return (output, audit)
    }

    private static func inventory(_ evidence: [String: Any], _ size: CGSize) -> [[String: Any]]? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              let ocr = evidence["originalOCR"] as? [String: Any],
              number(ocr["width"]) == Double(size.width), number(ocr["height"]) == Double(size.height),
              let rows = ocr["regions"] as? [[String: Any]], rows.count <= 4096 else { return nil }
        return rows
    }

    private static func active(_ item: [String: Any]) -> Bool {
        item["keptLettering"] as? Bool != true && item["sourceTextOnly"] as? Bool != true &&
            !(item["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func usable(_ row: [String: Any], confidence: Double) -> Bool {
        guard let score = number(row["confidence"]), score >= confidence, score <= 1,
              let observation = row["sourceGeometryObservation"] as? [String: Any],
              observation["rectClipped"] as? Bool == false, observation["polygonClipped"] as? Bool == false,
              (row["clippedUnitMemberIndices"] as? [Int] ?? []).isEmpty else { return false }
        return true
    }

    private static func exact(_ item: [String: Any], _ rows: [[String: Any]]) -> (index: Int, row: [String: Any])? {
        guard let box = rect(item["sourceBounds"]) else { return nil }
        let matches = rows.indices.filter { i in rect(rows[i]["sourceBounds"]).map { close(box, $0) } == true }
        guard matches.count == 1 else { return nil }
        return (matches[0], rows[matches[0]])
    }

    private static func same(_ a: String, _ b: String) -> Bool { Array(a.utf16) == Array(b.utf16) }
    private static func compact(_ text: String) -> String { String(text.filter { !$0.isWhitespace }) }

    private static func canonicalTranslation(_ item: [String: Any], _ row: [String: Any]) -> String? {
        guard let text = item["text"] as? String, let saved = row["translation"] as? String,
              same(compact(text), compact(saved)),
              same(text, saved) || same(item["sourceOwnerCanonicalTranslation"] as? String ?? "", saved) else { return nil }
        return saved
    }

    private static func occurrences(_ needle: String, in haystack: String) -> [NSRange] {
        guard !needle.isEmpty else { return [] }
        let text = haystack as NSString
        var start = 0, matches: [NSRange] = []
        while start < text.length && matches.count < 2 {
            let found = text.range(of: needle, options: .literal, range: NSRange(location: start, length: text.length - start))
            guard found.location != NSNotFound else { break }
            // Never accept half of a composed glyph, emoji, or surrogate pair.
            if text.rangeOfComposedCharacterSequences(for: found) == found { matches.append(found) }
            start = found.location + 1
        }
        return matches
    }

    private static func samePoints(_ a: [CGPoint], _ b: [CGPoint]) -> Bool {
        a.count == b.count && a.count >= 3 && zip(a, b).allSatisfy { abs($0.x - $1.x) <= 1e-8 && abs($0.y - $1.y) <= 1e-8 }
    }

    private static func fullyContains(_ parent: [CGPoint], _ child: [CGPoint]) -> Bool {
        guard parent.count == 4, child.count >= 3 else { return false }
        func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        let turns = parent.indices.map { cross(parent[$0], parent[($0 + 1) % 4], parent[($0 + 2) % 4]) }
        guard turns.allSatisfy({ $0 > 0 }) || turns.allSatisfy({ $0 < 0 }) else { return false }
        let sign: CGFloat = turns[0] > 0 ? 1 : -1
        return parent.indices.allSatisfy { i in
            child.allSatisfy { sign * cross(parent[i], parent[(i + 1) % 4], $0) >= -1e-12 }
        }
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    private static func rect(_ value: Any?) -> CGRect? {
        guard let b = value as? [Double], b.count == 4, b.allSatisfy(\.isFinite), b[0] >= 0, b[1] >= 0,
              b[2] > 0, b[3] > 0, b[0] + b[2] <= 1 + 1e-12, b[1] + b[3] <= 1 + 1e-12 else { return nil }
        return CGRect(x: b[0], y: b[1], width: b[2], height: b[3])
    }

    private static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        zip([a.minX, a.minY, a.width, a.height], [b.minX, b.minY, b.width, b.height]).allSatisfy { abs($0 - $1) <= 1e-8 }
    }

    private static func points(_ value: Any?) -> [CGPoint]? {
        guard let values = value as? [Any], values.count <= 64 else { return nil }
        var result: [CGPoint] = []
        for value in values {
            let x: Double?, y: Double?
            if let pair = value as? [Double], pair.count == 2 { x = pair[0]; y = pair[1] }
            else if let point = value as? [String: Any] { x = number(point["x"]); y = number(point["y"]) }
            else { return nil }
            guard let x, let y, x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { return nil }
            result.append(CGPoint(x: x, y: y))
        }
        return result
    }
}
