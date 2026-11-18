import CoreGraphics
import CoreText
import Foundation

/// Shared typography is solved before choosing individual owner frames. This is
/// display grouping, not source/sentence ownership inference. Every input owner,
/// exact source footprint, member lineage, palette and erasure obligation survives.
enum NativeCausalParagraphJointLayout {
    struct Paragraph {
        /// Same-paragraph source order must come from upstream runtime ownership.
        /// Discovery below uses one owner per paragraph; never joins sentences.
        let members: [Int]
    }
    struct Cohort {
        let paragraphs: [Paragraph]
    }
    static let defaults: [String: Double] = [
        "enabled": 0, "maximumSourceFontRatio": 1.6, "topToleranceEm": 0.75,
        "minimumSourceFontScale": 0.25, "maximumSourceFontScale": 0.8,
        "maximumInputGrowth": 1.5, "minimumFontPixels": 12, "fontSteps": 8
    ]
    private struct Node {
        let index: Int
        let source: CGRect
        let em: CGFloat
        let font: CGFloat
        let text: String
        let stroke: CGFloat
    }
    private struct Shape {
        let text: String
        let frame: CGRect
        let rows: [CGRect]
        let ink: [CGRect]
        let visible: Int
    }
    private struct Plan {
        let index: Int
        let shape: Shape
        var raster: [String: Any] = [:]
    }

    /// Concrete Ensemble100Proposal; no restoration/mask request. Optional
    /// cohorts are a synchronous runtime seam for upstream paragraph authority,
    /// never serialized evaluation labels. All indices are validated per page.
    static func apply(_ page: Ensemble100Page, parameters: [String: Double] = [:],
                      cohorts supplied: [Cohort]? = nil) throws -> Ensemble100Proposal {
        func option(_ key: String, _ range: ClosedRange<Double>) -> CGFloat {
            let value = parameters[key] ?? defaults[key]!
            return CGFloat(value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : defaults[key]!)
        }
        guard option("enabled", 0...1) > 0 else { return .init(items: page.items, audit: ["status": "disabled"]) }
        let v = page.viewport
        guard v.width.isFinite, v.height.isFinite, v.width > 0, v.height > 0, page.items.count <= 128 else {
            return .init(items: page.items, audit: ["status": "invalid-or-over-budget-preserved"])
        }
        let bounds = CGRect(origin: .zero, size: v)
        let scale = min(CGFloat(page.original.width) / v.width, CGFloat(page.original.height) / v.height)
        guard abs(CGFloat(page.original.width) / v.width - CGFloat(page.original.height) / v.height) < 0.01 else {
            return .init(items: page.items, audit: ["status": "nonuniform-scale-preserved"])
        }
        let nodes = page.items.enumerated().compactMap { i, raw -> Node? in
            guard raw["keptLettering"] as? Bool != true, raw["sourceTextOnly"] as? Bool != true,
                  raw["sourceVertical"] as? Bool == true, raw["vertical"] as? Bool != true,
                  let rotation = number(raw["rotation"]), abs(rotation) <= 0.12,
                  let source = normalized(raw["sourceBounds"], viewport: v),
                  let em = number(raw["sourceFontSize"]), em > 0, em < 1000,
                  let font = number(raw["fontSize"]), font > 0, font < 1000,
                  let text = raw["text"] as? String, !text.isEmpty, text.utf16.count <= 2048,
                  let stroke = number(raw["ensembleStrokeRatio"]), stroke >= 0.2, stroke <= 0.5,
                  let endpoint = raw["ensembleDisplayStroke"] as? [Double],
                  endpoint == [0, 0, 0] || endpoint == [255, 255, 255] else { return nil }
            return Node(index: i, source: source, em: em, font: font, text: text, stroke: stroke)
        }
        let byIndex = Dictionary(uniqueKeysWithValues: nodes.map { ($0.index, $0) })
        let cohorts: [Cohort]
        if let supplied { cohorts = supplied }
        else {
            // A font/alignment cohort is not a common paragraph. Even distant
            // common-top columns keep distinct source-centered paragraph slots.
            var families: [[Node]] = []
            for node in nodes.sorted(by: { $0.source.minY == $1.source.minY ? $0.index < $1.index : $0.source.minY < $1.source.minY }) {
                if let family = families.firstIndex(where: { group in
                    group.count < 12 && group.allSatisfy { peer in
                        max(peer.em, node.em) <= min(peer.em, node.em) * option("maximumSourceFontRatio", 1...2) &&
                        abs(peer.source.minY - node.source.minY) <= min(peer.em, node.em) * option("topToleranceEm", 0...1) &&
                        min(peer.source.maxX, node.source.maxX) - max(peer.source.minX, node.source.minX) <=
                            min(peer.source.width, node.source.width) * 0.35 &&
                        compatibleContours(page.items[peer.index], page.items[node.index], viewport: v)
                    }
                }) { families[family].append(node) } else { families.append([node]) }
            }
            cohorts = families.filter { $0.count > 1 }.map { group in
                Cohort(paragraphs: group.sorted { $0.source.midX > $1.source.midX }.map { Paragraph(members: [$0.index]) })
            }
        }
        var output = page.items, records: [[String: Any]] = [], consumed = Set<Int>()
        for cohort in cohorts.prefix(64) {
            try Task.checkCancellation()
            let members = cohort.paragraphs.flatMap(\.members)
            func record(_ status: String, _ extra: [String: Any] = [:]) {
                records.append(extra.merging(["status": status, "members": members]) { _, new in new })
            }
            guard members.count > 1, members.count <= 12, Set(members).count == members.count,
                  members.allSatisfy({ byIndex[$0] != nil && !consumed.contains($0) }),
                  cohort.paragraphs.allSatisfy({ !$0.members.isEmpty }) else { record("invalid-cohort-preserved"); continue }
            let group = members.map { byIndex[$0]! }
            // Small-reference ownership is upstream authority, not a font-size
            // discrepancy to repair. In particular, wrapping a short unresolved
            // reference into a tall column must not manufacture equal emphasis.
            guard !group.contains(where: { node in
                let raw = page.items[node.index]
                let reference = raw["smallTextReference"]
                let hasReference = reference is [String: Any] || reference as? Bool == true
                return hasReference && raw["smallTextReferenceResolved"] as? Bool != true &&
                    node.text.filter({ !$0.isWhitespace }).count <= 4
            }) else { record("unresolved-small-reference-preserved"); continue }
            let envelope = union(group.map(\.source))
            // A partial source-overlap component is not an independent layout
            // problem. Otherwise its unrepresented continuation forces the
            // chosen subset into a tiny font around the remaining OCR owner.
            // Upstream may pass that closed component as one Paragraph; this
            // layout stage never guesses away or deletes the missing owner.
            let externalDependencies = page.items.indices.filter { peer in
                guard !members.contains(peer), let source = normalized(page.items[peer]["sourceBounds"], viewport: v) else { return false }
                return group.contains { $0.source.intersects(source) }
            }
            guard externalDependencies.isEmpty else {
                record("incomplete-source-component-preserved", ["externalSourceDependencies": externalDependencies]); continue
            }
            let paragraphSources = cohort.paragraphs.map { union($0.members.map { byIndex[$0]!.source }) }
            // Source-order hierarchy must be spatially possible. Overlapping
            // independent paragraphs are not silently recast as one sentence.
            guard paragraphSources.indices.allSatisfy({ i in paragraphSources.indices.allSatisfy { j in
                i == j || !paragraphSources[i].intersects(paragraphSources[j]) ||
                    min(paragraphSources[i].maxX, paragraphSources[j].maxX) - max(paragraphSources[i].minX, paragraphSources[j].minX) <=
                        min(paragraphSources[i].width, paragraphSources[j].width) * 0.35
            } }) else { record("independent-paragraph-source-overlap-preserved"); continue }
            let contours = group.compactMap { NativeRawBalloonCapacity.contour(raw: page.items[$0.index], viewport: v) }
            let contour = contours.first
            guard contours.allSatisfy({ c in contour.map { same(c.rect, $0.rect) && c.spans.count == $0.spans.count &&
                zip(c.spans, $0.spans).allSatisfy { abs($0.0.0 - $0.1.0) < 1e-6 && abs($0.0.1 - $0.1.1) < 1e-6 } } ?? false }),
                contour.map({ c in group.allSatisfy { c.contains($0.source) } }) ?? true else {
                record("incompatible-supported-contours-preserved"); continue
            }
            var domain = contour?.rect ?? envelope
            if let contour {
                var left = domain.minX, right = domain.maxX, top = domain.minY, bottom = domain.maxY
                for peer in page.items.indices where !members.contains(peer) {
                    guard let source = normalized(page.items[peer]["sourceBounds"], viewport: v), contour.contains(source) else { continue }
                    if source.minY >= envelope.maxY { bottom = min(bottom, (envelope.maxY + source.minY) / 2) }
                    else if source.maxY <= envelope.minY { top = max(top, (source.maxY + envelope.minY) / 2) }
                    else if source.minX >= envelope.maxX { right = min(right, (envelope.maxX + source.minX) / 2) }
                    else if source.maxX <= envelope.minX { left = max(left, (source.maxX + envelope.minX) / 2) }
                }
                domain = CGRect(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top))
            }
            let slots = paragraphSources.map { source -> CGRect in
                var left = domain.minX, right = domain.maxX, top = domain.minY, bottom = domain.maxY
                for other in paragraphSources where other != source {
                    let overlapX = min(source.maxX, other.maxX) - max(source.minX, other.minX)
                    if overlapX > min(source.width, other.width) * 0.5 && (source.maxY <= other.minY || other.maxY <= source.minY) {
                        if other.midY < source.midY { top = max(top, (other.maxY + source.minY) / 2) }
                        else { bottom = min(bottom, (source.maxY + other.minY) / 2) }
                    } else if other.midX < source.midX { left = max(left, (other.maxX + source.minX) / 2) }
                    else { right = min(right, (source.maxX + other.minX) / 2) }
                }
                let hierarchySlot = CGRect(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top))
                // Equal source em/top grants typography coupling, NEVER space
                // sharing. Only a certified contour can authorize expansion.
                // An explicit multi-owner Paragraph may use its own envelope;
                // independently owned Paragraphs cannot borrow the cohort hull.
                return contour == nil ? hierarchySlot.intersection(source) : hierarchySlot
            }
            guard slots.allSatisfy({ !$0.isNull && !$0.isEmpty }) else {
                record("empty-paragraph-capacity-preserved"); continue
            }
            let slotByMember = Dictionary(uniqueKeysWithValues: cohort.paragraphs.indices.flatMap { p in
                cohort.paragraphs[p].members.map { ($0, p) }
            })
            let obstacles = page.items.indices.filter { !members.contains($0) }.flatMap { peer -> [CGRect] in
                [normalized(page.items[peer]["sourceBounds"], viewport: v), itemRect(output[peer])].compactMap { $0 }
            }
            let ems = group.map(\.em).sorted(), fonts = group.map(\.font).sorted()
            let reference = ems[ems.count / 2]
            let maximum = min(reference * option("maximumSourceFontScale", 0.4...1), fonts[fonts.count / 2] * option("maximumInputGrowth", 1...2))
            let minimum = max(option("minimumFontPixels", 8...32) / scale, reference * option("minimumSourceFontScale", 0.15...0.6))
            guard maximum >= minimum else { record("insufficient-readable-capacity-preserved"); continue }
            let steps = Int(option("fontSteps", 1...12))
            var winner: (plans: [Plan], font: CGFloat, pitch: CGFloat, score: CGFloat)?, attempts = 0
            for step in 0...steps {
                try Task.checkCancellation()
                let font = maximum - (maximum - minimum) * CGFloat(step) / CGFloat(steps)
                for leading: CGFloat in [1.3, 1.5, 1.7] {
                    let pitch = font * leading
                    var shapes: [[Shape]] = []
                    for (paragraph, slot) in zip(cohort.paragraphs, slots) {
                        var parts: [Shape] = []
                        for member in paragraph.members {
                            let node = byIndex[member]!
                            guard let shape = shape(node.text, width: slot.width, font: font, pitch: pitch,
                                stroke: node.stroke, scale: scale) else { break }
                            parts.append(shape)
                        }
                        if parts.count != paragraph.members.count { break }
                        shapes.append(parts)
                    }
                    guard shapes.count == cohort.paragraphs.count else { continue }
                    let gap = font * 0.2
                    let heights = shapes.map { $0.reduce(CGFloat.zero) { $0 + union($1.rows).height } + CGFloat($0.count - 1) * gap }
                    let commonTop = paragraphSources.map(\.minY).max()!
                    let commonRow = commonTop - paragraphSources.map(\.minY).min()! <= reference * 0.75
                    let centerY = contour.map(bodyCenter) ?? envelope.midY
                    // Shared source-top for open lettering, shared contour-body
                    // center for certified capacity. All owners participate in
                    // one solve; no independent rescue after a member fails.
                    for alignment in contour == nil ? ["source-top"] : ["contour-center", "source-top"] {
                        attempts += 1
                        var plans: [Plan] = []
                        for p in cohort.paragraphs.indices {
                            var top = alignment == "source-top" ? (commonRow ? commonTop : max(slots[p].minY, paragraphSources[p].minY)) :
                                (commonRow ? centerY : slots[p].midY) - heights[p] / 2
                            for (member, part) in zip(cohort.paragraphs[p].members, shapes[p]) {
                                let block = union(part.rows)
                                let centerX = min(slots[p].maxX - block.width / 2,
                                    max(slots[p].minX + block.width / 2, paragraphSources[p].midX))
                                let moved = shifted(part, dx: centerX - block.midX, dy: top - block.minY)
                                plans.append(Plan(index: member, shape: moved)); top += block.height + gap
                            }
                        }
                        guard plans.allSatisfy({ plan in
                            explicitTopPermits(page.items[plan.index], source: byIndex[plan.index]!.source, rows: plan.shape.rows) &&
                                (contour != nil || page.items[plan.index]["sourceLocalTripleGrid"] as? Bool != true ||
                                    plan.shape.rows.allSatisfy { byIndex[plan.index]!.source.contains($0) }) &&
                                bounds.contains(plan.shape.frame) && plan.shape.rows.allSatisfy { row in
                                bounds.contains(row) && domain.contains(row) && slots[slotByMember[plan.index]!].contains(row) &&
                                    (contour?.contains(row) ?? true) &&
                                    !obstacles.contains(where: { row.intersects($0.insetBy(dx: -1 / scale, dy: -1 / scale)) })
                            }
                        }) else { continue }
                        let allInk = plans.flatMap { $0.shape.ink }
                        guard allInk.indices.allSatisfy({ i in allInk.indices.allSatisfy { j in i == j || !allInk[i].intersects(allInk[j]) } }) else { continue }
                        var measuredPlans: [Plan] = []
                        for plan in plans {
                            let tripleEnvelope = contour == nil && page.items[plan.index]["sourceLocalTripleGrid"] as? Bool == true
                            let slot = tripleEnvelope ? slots[slotByMember[plan.index]!].intersection(byIndex[plan.index]!.source) :
                                slots[slotByMember[plan.index]!]
                            guard let raster = rasterEvidence(plan.shape, font: font, pitch: pitch, stroke: byIndex[plan.index]!.stroke,
                                scale: scale, pageHeight: v.height, slot: slot, domain: domain,
                                contour: contour, obstacles: obstacles) else { break }
                            var measured = plan; measured.raster = raster; measuredPlans.append(measured)
                        }
                        guard measuredPlans.count == plans.count else { continue }
                        let allRows = plans.flatMap { $0.shape.rows }
                        let score = CGFloat(allRows.count) * 0.2 + (leading - 1.3) * 0.1 +
                            (alignment == "contour-center" ? 0 : contour == nil ? 0 : 1)
                        if winner == nil || score < winner!.score { winner = (measuredPlans, font, pitch, score) }
                    }
                }
                if winner != nil { break } // Largest feasible common font first.
            }
            guard let winner else { record("no-complete-joint-plan-preserved", ["attempts": attempts]); continue }
            guard winner.plans.allSatisfy({ compact($0.shape.text) == compact(page.items[$0.index]["text"] as! String) }) else {
                record("target-conservation-veto-preserved"); continue
            }
            for plan in winner.plans {
                let i = plan.index, s = plan.shape
                output[i]["text"] = s.text
                output[i]["x"] = Double(s.frame.minX); output[i]["y"] = Double(s.frame.minY)
                output[i]["width"] = Double(s.frame.width); output[i]["height"] = Double(s.frame.height)
                output[i]["fontSize"] = Double(winner.font); output[i]["lineHeight"] = Double(winner.pitch)
                output[i]["ensembleLockLayout"] = true
                output[i]["ensembleParagraphJointLayoutAudit"] = ["cohortMembers": members,
                    "paragraphMembers": cohort.paragraphs.map(\.members), "paragraphOwnersRemainSeparate": true,
                    "sourceNearDisplayConstraintsReplacedJointly": true, "sourceGeometryAndMaskUnchanged": true,
                    "glyphStrokeRows": s.rows.map(values), "completeUTF16": s.visible,
                    "paragraphSlot": values(slots[slotByMember[i]!]),
                    "paragraphSourceEnvelope": values(paragraphSources[slotByMember[i]!]),
                    "retainedRaster": plan.raster,
                    "nonWhitespaceTargetUTF8Equal": true, "commonFont": Double(winner.font), "commonPitch": Double(winner.pitch),
                    "capacityAuthority": contour == nil ? "own-paragraph-source-envelope;not-balloon-certification" : "verified-native-contour",
                    "fontAuthority": "median own sourceFontSize estimates;not source font gold",
                    "qualityAccepted": false, "finalCompositeMeasured": false] as [String: Any]
            }
            consumed.formUnion(members)
            record("joint-plan-proposed", ["attempts": attempts, "font": Double(winner.font), "pitch": Double(winner.pitch),
                "paragraphs": cohort.paragraphs.map(\.members), "domain": values(domain), "sourceEnvelope": values(envelope),
                "supportedContour": contour != nil, "ownersMerged": false, "sourceMaskDelta": false])
        }
        return .init(items: output, audit: ["status": "complete", "groups": records, "runtimeLabelsRead": false,
            "sourceOwnerMembershipChanged": false, "sourceMaskDelta": false, "qualityAccepted": false])
    }

    private static func shape(_ text: String, width: CGFloat, font: CGFloat, pitch: CGFloat, stroke: CGFloat, scale: CGFloat) -> Shape? {
        let margin = (ceil(max(2, font * stroke * scale)) + 3) / scale
        let available = width - 2 * margin
        guard available > font * 0.5 else { return nil }
        let attributes = NativeRawBalloonCapacity.attributes(fontSize: font, pitch: pitch)
        func measure(_ s: String) -> CGFloat {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attributes))
            return max(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)), CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds]).width)
        }
        guard let wrapped = wrap(text, width: available, measure: measure), compact(wrapped) == compact(text) else { return nil }
        let lines = wrapped.components(separatedBy: "\n")
        let height = CGFloat(lines.count) * pitch + font + 2 * margin
        let setter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: wrapped, attributes: attributes))
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0),
            CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil), nil)
        let visible = CTFrameGetVisibleStringRange(frame)
        let ctLines = CTFrameGetLines(frame) as! [CTLine]
        guard visible.location == 0, visible.length == wrapped.utf16.count, ctLines.count == lines.count else { return nil }
        var origins = [CGPoint](repeating: .zero, count: ctLines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        var ink: [CGRect] = [], rows: [CGRect] = []
        for (i, line) in ctLines.enumerated() {
            let glyph = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds]).union(CTLineGetImageBounds(line, nil))
            if glyph.isNull || glyph.isEmpty { continue }
            let r = CGRect(x: origins[i].x + glyph.minX, y: height - origins[i].y - glyph.maxY, width: glyph.width, height: glyph.height)
            let halo = r.insetBy(dx: -margin, dy: -margin)
            guard halo.minX >= 0, halo.maxX <= width else { return nil }
            ink.append(r); rows.append(halo)
        }
        guard !rows.isEmpty else { return nil }
        // Keep the exact CT frame that passed complete-range measurement.
        // Trimming bottom whitespace can silently remove trailing paragraph
        // separators from CoreText's visible range even when all ink still fits.
        return Shape(text: wrapped, frame: CGRect(x: 0, y: 0, width: width, height: height), rows: rows, ink: ink, visible: visible.length)
    }

    /// Preserve explicit blank paragraphs. Only CJK/Hangul grapheme boundaries
    /// may split overlong words; Latin words and extended graphemes stay whole.
    private static func wrap(_ text: String, width: CGFloat, measure: (String) -> CGFloat) -> String? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var paragraphs: [String] = []
        for paragraph in normalized.components(separatedBy: "\n\n") {
            var rows: [String] = [], row = ""
            for word in paragraph.split(whereSeparator: \.isWhitespace).map(String.init) {
                var pieces = [word]
                if measure(word) > width {
                    guard word.unicodeScalars.allSatisfy({ scalar in
                        let c = scalar.value
                        return (0xAC00...0xD7AF).contains(c) || (0x3040...0x30FF).contains(c) ||
                            (0x3400...0x9FFF).contains(c) || CharacterSet.punctuationCharacters.contains(scalar)
                    }) else { return nil }
                    pieces = []; var piece = ""
                    for character in word {
                        guard measure(String(character)) <= width else { return nil }
                        if measure(piece + String(character)) > width { pieces.append(piece); piece = "" }
                        piece.append(character)
                    }
                    if !piece.isEmpty { pieces.append(piece) }
                }
                for (i, piece) in pieces.enumerated() {
                    let next = row.isEmpty ? piece : row + " " + piece
                    if i > 0 || measure(next) > width {
                        if !row.isEmpty { rows.append(row) }; row = piece
                    } else { row = next }
                }
            }
            if !row.isEmpty { rows.append(row) }
            paragraphs.append(rows.joined(separator: "\n"))
        }
        return paragraphs.joined(separator: "\n\n")
    }
    private static func compatibleContours(_ a: [String: Any], _ b: [String: Any], viewport: CGSize) -> Bool {
        let x = NativeRawBalloonCapacity.contour(raw: a, viewport: viewport), y = NativeRawBalloonCapacity.contour(raw: b, viewport: viewport)
        switch (x, y) { case (nil, nil): return true; case let (x?, y?): return same(x.rect, y.rect); default: return false }
    }
    /// Measure the exact final locked CT frame, not a fit flag or font bbox.
    /// A bounded local glyph crop is sufficient; never renders the source page.
    private static func rasterEvidence(_ shape: Shape, font: CGFloat, pitch: CGFloat, stroke: CGFloat,
        scale: CGFloat, pageHeight: CGFloat, slot: CGRect, domain: CGRect,
        contour: NativeRawBalloonCapacity.Contour?, obstacles: [CGRect]) -> [String: Any]? {
        let f = shape.frame
        let box = CGRect(x: f.minX * scale, y: f.minY * scale, width: f.width * scale, height: f.height * scale)
        let crop = box.insetBy(dx: -4, dy: -4).integral
        guard crop.width > 0, crop.height > 0, crop.width * crop.height <= 250_000 else { return nil }
        let attributes = NativeRawBalloonCapacity.attributes(fontSize: font * scale, pitch: pitch * scale)
        let setter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: shape.text, attributes: attributes))
        let ct = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0),
            CGPath(rect: CGRect(x: box.minX, y: pageHeight * scale - box.maxY, width: box.width, height: box.height), transform: nil), nil)
        let visible = CTFrameGetVisibleStringRange(ct)
        let lines = CTFrameGetLines(ct) as! [CTLine]
        guard visible.location == 0, visible.length == shape.text.utf16.count,
              lines.count == shape.text.components(separatedBy: "\n").count else { return nil }
        let width = Int(crop.width), height = Int(crop.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { memory -> Bool in
            guard let c = CGContext(data: memory.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            c.translateBy(x: -crop.minX, y: -(pageHeight * scale - crop.maxY)); c.textMatrix = .identity
            CTFrameDraw(ct, c); return true
        }
        guard drawn else { return nil }
        let halo = ceil(max(2, font * scale * stroke)) + 1
        var retained = CGRect.null, count = 0
        for y in 0..<height {
            var left = width, right = -1
            for x in 0..<width where bytes[(y * width + x) * 4 + 3] > 0 { left = min(left, x); right = x }
            if right >= left {
                guard left > 0, right < width - 1, y > 0, y < height - 1 else { return nil }
                let row = CGRect(x: (crop.minX + CGFloat(left) - halo) / scale,
                    y: (crop.minY + CGFloat(y) - halo) / scale,
                    width: (CGFloat(right - left + 1) + 2 * halo) / scale, height: (1 + 2 * halo) / scale)
                guard slot.contains(row), domain.contains(row), contour?.contains(row) ?? true,
                      !obstacles.contains(where: { row.intersects($0.insetBy(dx: -1 / scale, dy: -1 / scale)) }) else { return nil }
                retained = retained.union(row); count += 1
            }
        }
        guard count > 0 else { return nil }
        return ["observedAlphaRows": count, "retainedGlyphStrokeBounds": values(retained),
            "conservativeOutwardRadiusPixels": Double(halo), "visibleUTF16": visible.length,
            "allObservedRowsContained": true, "fullPageCompositeMeasured": false]
    }
    private static func explicitTopPermits(_ raw: [String: Any], source: CGRect, rows: [CGRect]) -> Bool {
        guard let m = raw["sourceNearLayout"] as? [String: Any], number(m["version"]) == 2 else { return true }
        guard m["verticalAnchorMetric"] as? String == "source-top", let limit = number(m["maxTopDrift"]), limit >= 0 else { return false }
        return abs(union(rows).minY - source.minY) <= limit + 1e-7
    }
    private static func bodyCenter(_ c: NativeRawBalloonCapacity.Contour) -> CGFloat {
        let widths = c.spans.map { $0.1 - $0.0 }, maximum = c.spans.map { $0.1 - $0.0 }.max() ?? 0
        var weight: CGFloat = 0, sum: CGFloat = 0
        for i in widths.indices where widths[i] >= maximum * 0.65 {
            weight += widths[i]; sum += widths[i] * (c.rect.minY + (CGFloat(i) + 0.5) * c.rect.height / CGFloat(widths.count))
        }
        return sum / max(1e-9, weight)
    }
    private static func shifted(_ s: Shape, dx: CGFloat, dy: CGFloat) -> Shape {
        Shape(text: s.text, frame: s.frame.offsetBy(dx: dx, dy: dy), rows: s.rows.map { $0.offsetBy(dx: dx, dy: dy) },
            ink: s.ink.map { $0.offsetBy(dx: dx, dy: dy) }, visible: s.visible)
    }
    private static func number(_ x: Any?) -> CGFloat? { (x as? NSNumber).flatMap { $0.doubleValue.isFinite ? CGFloat($0.doubleValue) : nil } }
    private static func itemRect(_ raw: [String: Any]) -> CGRect? { rect([raw["x"] ?? NSNull(), raw["y"] ?? NSNull(), raw["width"] ?? NSNull(), raw["height"] ?? NSNull()]) }
    private static func rect(_ value: Any?) -> CGRect? {
        guard let a = value as? [Any], a.count == 4 else { return nil }
        let n = a.compactMap(number)
        guard n.count == 4, n[2] > 0, n[3] > 0 else { return nil }
        let r = CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
        return [r.minX, r.minY, r.maxX, r.maxY].allSatisfy(\.isFinite) ? r : nil
    }
    private static func normalized(_ x: Any?, viewport: CGSize) -> CGRect? {
        guard let r = rect(x), CGRect(x: 0, y: 0, width: 1, height: 1).contains(r) else { return nil }
        return CGRect(x: r.minX * viewport.width, y: r.minY * viewport.height, width: r.width * viewport.width, height: r.height * viewport.height)
    }
    private static func union(_ rows: [CGRect]) -> CGRect { rows.reduce(CGRect.null) { $0.union($1) } }
    private static func same(_ a: CGRect, _ b: CGRect) -> Bool { abs(a.minX - b.minX) < 1e-6 && abs(a.minY - b.minY) < 1e-6 && abs(a.width - b.width) < 1e-6 && abs(a.height - b.height) < 1e-6 }
    private static func compact(_ s: String) -> [UInt8] { Array(String(s.filter { !$0.isWhitespace }).utf8) }
    private static func values(_ r: CGRect) -> [Double] { [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)] }
}
