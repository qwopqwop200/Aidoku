import CoreGraphics
import CryptoKit
import Foundation

/// Paragraph ink is a group property; missing individual endpoints remain
/// missing. The result is usable before shaping, without recoloring members or
/// extending any member's source-removal authority to a union bounding box.
enum NativeCausalParagraphPaletteCompatibility {
    static let version = 2
    struct OwnBoundaryAttempt {
        let observation: NativeOriginalSourcePalette.Observation
        let audit: [String: Any]
    }

    /// Page-aware upstream seam: bind exact OCR/source/target before refining a
    /// still unknown member. Does not require another member or RF rectangle.
    static func observeOwnMember(_ page: Ensemble100Page, member: [String: Any], enabled: Bool = false) -> OwnBoundaryAttempt {
        let clean = observationGeometry(member)
        let baseline = NativeOriginalSourcePalette(original: page.original).observe(
            sourceBounds: clean["sourceBounds"] as? [Double] ?? [], originalGeometry: clean)
        guard enabled, baseline.selected.color == nil else {
            return refineUnknownOwnInk(original: page.original, geometry: clean, baseline: baseline, enabled: enabled)
        }
        guard let identity = try? NativeRFDETRSourceImage.decode(page.original).identity,
              page.savedEvidence["ocrSourceContentIdentity"] as? String == identity,
              page.savedEvidence["sourceSHA256"] as? String == page.sourceSHA256,
              let root = page.savedEvidence["originalOCR"] as? [String: Any],
              root["coordinateSpace"] as? String == "normalized-top-left",
              (root["width"] as? NSNumber)?.intValue == page.original.width,
              (root["height"] as? NSNumber)?.intValue == page.original.height,
              let rows = root["regions"] as? [[String: Any]], rows.count <= 4096,
              let own = matchedRecords(member, rows: rows), own.count == 1,
              (own[0]["confidence"] as? Double ?? 0) >= 0.8 else {
            return OwnBoundaryAttempt(observation: baseline, audit: ["accepted": false, "reason": "unboundOwnMember", "version": 1])
        }
        return refineUnknownOwnInk(original: page.original, geometry: clean, baseline: baseline, enabled: true)
    }

    /// Unknown-only OWN glyph boundary refinement. A pair of ordered original
    /// core/contour/exterior profiles seeds a connected core, not just a sparse
    /// ray center. This fixes sparse-profile shape undercounting without lowering
    /// endpoint shape/repetition quorums or borrowing any other owner's color.
    static func refineUnknownOwnInk(original: CGImage, geometry: [String: Any],
                                    baseline: NativeOriginalSourcePalette.Observation,
                                    enabled: Bool = false) -> OwnBoundaryAttempt {
        func keep(_ reason: String, _ detail: [String: Any] = [:]) -> OwnBoundaryAttempt {
            OwnBoundaryAttempt(observation: baseline, audit: ["accepted": false, "reason": reason, "version": 1]
                .merging(detail, uniquingKeysWith: { $1 }))
        }
        guard enabled else { return keep("policyDisabled") }
        guard baseline.selected.color == nil else { return keep("acceptedOwnOriginalPreserved") }
        guard let guide = rgb(baseline.originalFill), guide.min()! >= 225, guide.max()! - guide.min()! <= 32,
              let b = rect(geometry["sourceBounds"]), CGRect(x: 0, y: 0, width: 1, height: 1).contains(b) else {
            return keep("missingOwnedPaleCoreGuide")
        }
        let iw = original.width, ih = original.height
        let x0 = max(0, Int(floor(b.minX * Double(iw))) - 4), y0 = max(0, Int(floor(b.minY * Double(ih))) - 4)
        let w = min(iw, Int(ceil(b.maxX * Double(iw))) + 4) - x0
        let h = min(ih, Int(ceil(b.maxY * Double(ih))) + 4) - y0
        guard w >= 8, h >= 8, h <= 65536, w <= 65536 / h,
              let crop = original.cropping(to: CGRect(x: x0, y: y0, width: w, height: h)) else { return keep("ownCropBudget") }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let captured = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let c = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            c.interpolationQuality = .none; c.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
        }
        let polygon = geometry["sourcePolygon"] as? [[Double]] ?? [[b.minX, b.minY], [b.maxX, b.minY],
            [b.maxX, b.maxY], [b.minX, b.maxY]]
        guard captured, polygon.count >= 3, polygon.count <= 64,
              polygon.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) else { return keep("invalidOwnPolygon") }
        let path = CGMutablePath()
        path.addLines(between: polygon.map { CGPoint(x: $0[0] * Double(iw) - Double(x0), y: $0[1] * Double(ih) - Double(y0)) })
        path.closeSubpath()
        var owned = [Bool](repeating: false, count: w * h)
        for y in 0..<h { for x in 0..<w {
            owned[y * w + x] = pixels[(y * w + x) * 4 + 3] >= 250 && path.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5))
        }}
        let measured = measureOwnBoundary(rgba: pixels, width: w, height: h, owned: owned, guide: guide)
        guard let fill = measured.fill, let stroke = measured.stroke, let evidence = measured.evidence else {
            return keep(measured.audit["reason"] as? String ?? "unobservedOwnBoundary", measured.audit)
        }
        let selection = NativeSourceInkSelection.select(fill: fill, stroke: stroke, evidence: evidence)
        guard selection.color != nil else { return keep("unrankedOwnEndpoints", measured.audit) }
        return OwnBoundaryAttempt(observation: .init(originalFill: fill, originalStroke: stroke, evidence: evidence,
            selected: selection, rawPrediction: ["ownedConnectedBoundaryRecovery": measured.audit],
            unknownReason: "own ordered profiles and connected endpoint support; source estimate, not gold"),
            audit: measured.audit)
    }

    struct OwnBoundaryMeasurement {
        let fill: [Double]?
        let stroke: [Double]?
        let evidence: NativeSourceInkSelection.Evidence?
        let audit: [String: Any]
    }

    /// Pure raster core permits focused negative controls without model calls.
    static func measureOwnBoundary(rgba: [UInt8], width: Int, height: Int, owned: [Bool], guide: [Double]) -> OwnBoundaryMeasurement {
        func reject(_ reason: String, _ detail: [String: Any] = [:]) -> OwnBoundaryMeasurement {
            .init(fill: nil, stroke: nil, evidence: nil, audit: ["accepted": false, "reason": reason, "version": 1]
                .merging(detail, uniquingKeysWith: { $1 }))
        }
        guard width >= 8, height >= 8, height <= 65536, width <= 65536 / height,
              rgba.count == width * height * 4, owned.count == width * height, rgb(guide) != nil else { return reject("invalidOwnRaster") }
        func color(_ p: Int) -> [Double] { (0..<3).map { Double(rgba[p * 4 + $0]) } }
        func valid(_ p: Int) -> Bool { p >= 0 && p < owned.count && owned[p] && rgba[p * 4 + 3] >= 250 }
        func pale(_ p: Int) -> Bool {
            guard valid(p) else { return false }; let c = color(p)
            return c.min()! >= 225 && c.max()! - c.min()! <= 32 && distance(c, guide) <= 24
        }
        func neighbors(_ p: Int) -> [Int] {
            let x = p % width, y = p / width
            return [x > 0 ? p - 1 : -1, x + 1 < width ? p + 1 : -1,
                    y > 0 ? p - width : -1, y + 1 < height ? p + width : -1].filter { $0 >= 0 }
        }
        struct Ray { let shell: [Int]; let endpoint: [Double] }
        func ray(_ p: Int, _ dx: Int, _ dy: Int) -> Ray? {
            var points = [Int]()
            for step in 1...16 {
                let x = p % width + dx * step, y = p / width + dy * step
                guard x >= 0, y >= 0, x < width, y < height else { break }
                let q = y * width + x; guard valid(q) else { break }; points.append(q)
            }
            var first = 0
            while first < points.count && pale(points[first]) { first += 1 }
            guard points.count >= 2, first < points.count - 1 else { return nil }
            let core = color(p)
            for start in first..<min(first + 4, points.count - 1) {
                let c = color(points[start])
                guard c.max()! - c.min()! >= 90, c.min()! <= 160,
                      distance(c, color(points[start + 1])) <= 12 else { continue }
                let vector = zip(c, core).map { $0 - $1 }, denominator = vector.reduce(0) { $0 + $1 * $1 }
                guard denominator > 0, points[first..<start].allSatisfy({ q in
                    let t = zip(zip(color(q), core), vector).reduce(0) { $0 + ($1.0.0 - $1.0.1) * $1.1 } / denominator
                    return (-0.05...1.05).contains(t) && distance(color(q), zip(core, vector).map { $0 + min(1, max(0, t)) * $1 }) <= 16
                }) else { continue }
                var end = start + 2
                while end < points.count && distance(color(points[end]), c) <= 16 { end += 1 }
                guard end - start <= 8, end < points.count - 1 else { continue }
                for outside in end..<min(end + 4, points.count - 1) {
                    let surface = color(points[outside])
                    if distance(surface, c) >= 48, distance(surface, core) >= 48,
                       distance(surface, color(points[outside + 1])) <= 16 {
                        return Ray(shell: Array(points[start..<end]), endpoint: c)
                    }
                }
            }
            return nil
        }
        struct Profile { let center: Int; let axis: Int; let shell: [Int]; let endpoint: [Double] }
        let axes = [(1, 0), (0, 1), (1, 1), (1, -1)]
        var profiles = [Profile]()
        for p in owned.indices where pale(p) && neighbors(p).filter({ pale($0) }).count >= 2 {
            for (axis, d) in axes.enumerated() {
                if let a = ray(p, d.0, d.1), let b = ray(p, -d.0, -d.1), distance(a.endpoint, b.endpoint) <= 16 {
                    profiles.append(.init(center: p, axis: axis, shell: a.shell + b.shell, endpoint: a.endpoint))
                }
                guard profiles.count <= 8192 else { return reject("ownProfileBudget") }
            }
        }
        var detail: [String: Any] = ["opposingProfiles": profiles.count, "capturedPixels": width * height,
            "authority": "same-owner original ordered boundaries; connected core support, not bbox or peer mode"]
        guard profiles.count >= 12 else { return reject("insufficientOwnProfiles", detail) }
        var bins = [Int: [Double]]()
        for profile in profiles {
            let c = profile.endpoint, key = (Int(c[0]) / 16) * 256 + (Int(c[1]) / 16) * 16 + Int(c[2]) / 16
            bins[key] = bins[key] ?? c
        }
        guard bins.count <= 64 else { return reject("diffuseOwnContours", detail) }
        var ranked = [[Int]]()
        for key in bins.keys.sorted() {
            let center = bins[key]!
            let indices: [Int] = profiles.indices.filter { distance(profiles[$0].endpoint, center) <= 16 }
            ranked.append(indices)
        }
        ranked.sort { a, b in a.count == b.count ? a[0] < b[0] : a.count > b.count }
        let selected = ranked[0], selectedSet = Set(selected)
        guard !ranked.contains(where: { $0.count >= max(6, selected.count / 4) && Set($0).isDisjoint(with: selectedSet) }) else {
            return reject("contradictoryOwnContours", detail)
        }
        let cells = Set(selected.map { let p = profiles[$0].center; return (p / width / 3) * width + p % width / 3 })
        let orientations = Set(selected.map { profiles[$0].axis })
        guard selected.count >= 12, cells.count >= 4, orientations.count >= 2 else { return reject("insufficientIndependentOwnProfiles", detail) }
        var labels = [Int](repeating: -1, count: owned.count), components = [[Int]]()
        for p in owned.indices where labels[p] == -1 && pale(p) {
            let label = components.count; var queue = [p], next = 0; labels[p] = label
            while next < queue.count {
                let q = queue[next]; next += 1
                for n in neighbors(q) where labels[n] == -1 && pale(n) { labels[n] = label; queue.append(n) }
            }
            components.append(queue)
        }
        let grouped = Dictionary(grouping: selected, by: { labels[profiles[$0].center] })
        var cores = Set<Int>(), seeds = Set<Int>(), supportedComponents = 0
        for (label, indices) in grouped where label >= 0 && Set(indices.map { profiles[$0].center }).count >= 2 {
            let component = components[label]
            // A core joined to the ownership boundary is not independently
            // enclosed glyph support. Never flood a pale exterior/background.
            guard !component.contains(where: { p in
                neighbors(p).count < 4 || neighbors(p).contains(where: { !valid($0) })
            }) else { continue }
            // A supported profile labels its whole connected stable core. It
            // does NOT label any other pale component or exterior surface.
            cores.formUnion(component); supportedComponents += 1
            indices.forEach { seeds.formUnion(profiles[$0].shell) }
        }
        let representative = profiles[selected[0]].endpoint
        var shells = seeds, frontier = Array(seeds)
        // A bounded contour band, not a flood of the entire chromatic surface.
        for _ in 0..<3 {
            var next = [Int]()
            for p in frontier { for n in neighbors(p) where valid(n) && !shells.contains(n) && !cores.contains(n) {
                if distance(color(n), representative) <= 16 { shells.insert(n); next.append(n) }
            }}
            frontier = next
        }
        func shape(_ set: Set<Int>) -> Int { set.filter { neighbors($0).filter { set.contains($0) }.count >= 2 }.count }
        func tiles(_ set: Set<Int>) -> Int { Set(set.map { (($0 / width) * 6 / height) * 6 + ($0 % width) * 6 / width }).count }
        let fs = shape(cores), ss = shape(shells), ft = tiles(cores), st = tiles(shells)
        detail.merge(["selectedProfiles": selected.count, "independentCells": cells.count, "orientations": orientations.count,
            "profileCorePixels": Set(selected.map { profiles[$0].center }).count,
            "connectedCorePixels": cores.count, "contourPixels": shells.count,
            "coreShapePixels": fs, "contourShapePixels": ss, "coreTiles": ft, "contourTiles": st,
            "seededCoreComponents": supportedComponents], uniquingKeysWith: { $1 })
        guard supportedComponents >= 2, cores.isDisjoint(with: shells), fs >= 12, ss >= 12, ft >= 4, st >= 4 else {
            return reject("insufficientOwnConnectedShape", detail)
        }
        func endpoint(_ set: Set<Int>) -> [Double] {
            (0..<3).map { channel in (set.reduce(0.0) { $0 + Double(rgba[$1 * 4 + channel]) } / Double(set.count)).rounded() }
        }
        let fill = endpoint(cores), stroke = endpoint(shells)
        let evidence = NativeSourceInkSelection.Evidence(fillPixels: Double(cores.count), strokePixels: Double(shells.count),
            fillShapePixels: Double(fs), strokeShapePixels: Double(ss), fillRepeatedTiles: Double(ft), strokeRepeatedTiles: Double(st),
            fillEnclosedPixels: 0, strokeEnclosedPixels: 0)
        detail["accepted"] = true; detail["foreground"] = fill; detail["stroke"] = stroke; detail["version"] = 1
        return .init(fill: fill, stroke: stroke, evidence: evidence, audit: detail)
    }

    /// One explicit original-evidence policy for02, graph admission and07.
    /// Display BW stroke selection is deliberately outside this descriptor.
    struct GroupPalettePolicy {
        static let descriptorVersion = 1
        let inkOnly: Bool
        let ownedGlyph: Bool
        let openRim: Bool
        let chromaticShell: Bool

        init(parameters: [String: Double] = [:], chromaticShell: Bool = false) {
            inkOnly = (parameters["rfTextJoinInkOnlyAdmission"] ?? 1) == 1
            ownedGlyph = (parameters["rfTextJoinOwnedGlyphPaletteRecovery"] ?? 1) == 1
            openRim = (parameters["rfTextJoinOpenRimGlyphPaletteRecovery"] ?? 1) == 1
            self.chromaticShell = chromaticShell
        }

        private init(inkOnly: Bool, ownedGlyph: Bool, openRim: Bool, chromaticShell: Bool) {
            self.inkOnly = inkOnly; self.ownedGlyph = ownedGlyph
            self.openRim = openRim; self.chromaticShell = chromaticShell
        }

        var metadata: [String: Any] {
            ["version": Self.descriptorVersion, "inkOnly": inkOnly, "ownedGlyph": ownedGlyph,
             "openRim": openRim, "chromaticShell": chromaticShell]
        }

        fileprivate static func decode(_ raw: Any?) -> Self? {
            guard let d = raw as? [String: Any], d["version"] as? Int == descriptorVersion,
                  let ink = d["inkOnly"] as? Bool, let own = d["ownedGlyph"] as? Bool,
                  let rim = d["openRim"] as? Bool, let shell = d["chromaticShell"] as? Bool else { return nil }
            return Self(inkOnly: ink, ownedGlyph: own, openRim: rim, chromaticShell: shell)
        }

        /// New proposals may use independently measured OWN endpoints, never
        /// peer-assisted endpoint imputation. Already accepted groups bypass
        /// this transformation entirely in makePolicyDescriptor.
        func applying(to raw: [String: Any]) -> [String: Any] {
            var d = observationGeometry(raw)
            d["sourceTextBlockMemberPalette"] = true
            d["sourceTextBlockInkOnlyAdmission"] = inkOnly
            d["sourceOwnedGlyphPaletteRecovery"] = ownedGlyph
            d["sourceOpenRimGlyphPaletteRecovery"] = openRim
            d["sourceChromaticShellPaletteRecovery"] = chromaticShell
            d["sourceOwnedGlyphPaletteRecoverySuppressed"] = !(ownedGlyph || openRim || chromaticShell)
            d["sourceOpenRimGlyphPaletteRecoverySuppressed"] = !openRim
            d["sourceChromaticShellPaletteRecoverySuppressed"] = !chromaticShell
            for key in ["sourceStackedContinuation", "sourceTextBlockColumnPeerShell",
                        "sourceTextBlockNativePeerRecovery", "sourceTextBlockMeasuredEvidenceRecovery"] { d[key] = false }
            return d
        }
    }

    struct PolicyDescriptor {
        let geometry: [String: Any]?
        let observation: NativeOriginalSourcePalette.Observation
        let accepted: Bool
        let audit: [String: Any]
    }

    /// A single adapter for the parent's existing Bool admission callbacks.
    /// Unlike a Bool-only hook, this retains the source-bound policy descriptor
    /// in the ACTUAL returned items, so07 can repeat the same original decision.
    final class UnifiedOwnPaletteAdapter {
        private let page: Ensemble100Page
        private let policy: GroupPalettePolicy
        private let enabled: Bool
        private var retained = [String: (signature: String, geometry: [String: Any])]()
        private(set) var audit = [[String: Any]]()

        init(page: Ensemble100Page, parameters: [String: Double], chromaticShell: Bool, enabled: Bool = false) {
            self.page = page; self.enabled = enabled
            policy = GroupPalettePolicy(parameters: parameters, chromaticShell: chromaticShell)
        }

        /// Use directly as02's admitGroup and graph's admitGroup. Bounds and
        /// original member objects are not rewritten, including on rejection.
        func admit(_ candidate: [String: Any]) -> Bool {
            guard audit.count < 256 else { return false }
            let attempt = makePolicyDescriptor(page, candidate: candidate, policy: policy, enabled: enabled)
            var record = attempt.audit
            record["groupID"] = candidate["id"] as Any? ?? NSNull()
            record["members"] = (candidate["agent02MemberItems"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            // Diagnostics do not depend on reaching RF/axis/group palette gates.
            // Missing support must not hide genuinely unknown OWN original ink.
            if enabled { record["ownInk"] = ownInkDiagnostics(page, candidate: candidate) }
            audit.append(record)
            if attempt.accepted, let id = candidate["id"] as? String,
               let geometry = attempt.geometry, let signature = Self.footprint(candidate) {
                retained[id] = (signature, geometry)
            }
            return attempt.accepted
        }

        /// Call on grouped.items / graph.items BEFORE placement or03. Copy only
        /// policy fields: preserve later graph annotations and every target,
        /// original/removal member, geometry and source-revision descriptor.
        func applying(to items: [[String: Any]]) -> [[String: Any]] {
            items.map { item in
                guard let id = item["id"] as? String, let entry = retained[id],
                      Self.footprint(item) == entry.signature,
                      entry.geometry["sourceParagraphPolicyBinding"] != nil else { return item }
                var output = item
                for key in Self.policyKeys {
                    if let value = entry.geometry[key] { output[key] = value }
                }
                return output
            }
        }

        private static let policyKeys = ["sourceParagraphPolicyBinding", "sourceTextBlockMemberPalette",
            "sourceTextBlockInkOnlyAdmission", "sourceOwnedGlyphPaletteRecovery", "sourceOpenRimGlyphPaletteRecovery",
            "sourceChromaticShellPaletteRecovery", "sourceOwnedGlyphPaletteRecoverySuppressed",
            "sourceOpenRimGlyphPaletteRecoverySuppressed", "sourceChromaticShellPaletteRecoverySuppressed",
            "sourceStackedContinuation", "sourceTextBlockColumnPeerShell", "sourceTextBlockNativePeerRecovery",
            "sourceTextBlockMeasuredEvidenceRecovery"]

        private static func footprint(_ item: [String: Any]) -> String? {
            guard let members = item["agent02MemberItems"] as? [[String: Any]],
                  let signature = memberSignature(members), let bounds = item["sourceBounds"] as? [Double],
                  let text = item["text"] as? String, let id = item["id"] as? String,
                  let bytes = try? JSONSerialization.data(withJSONObject:
                    ["id": id, "sourceBounds": bounds, "text": text, "members": signature], options: [.sortedKeys]) else { return nil }
            return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Fresh, compact scalar evidence even when group admission stops before the
    /// palette gate. No serialized RGB, probability buffers or peer predictions.
    static func ownInkDiagnostics(_ page: Ensemble100Page, candidate: [String: Any]) -> [[String: Any]] {
        guard let members = candidate["agent02MemberItems"] as? [[String: Any]], (2...6).contains(members.count),
              let identity = try? NativeRFDETRSourceImage.decode(page.original).identity,
              page.savedEvidence["ocrSourceContentIdentity"] as? String == identity,
              page.savedEvidence["sourceSHA256"] as? String == page.sourceSHA256,
              let root = page.savedEvidence["originalOCR"] as? [String: Any],
              (root["width"] as? NSNumber)?.intValue == page.original.width,
              (root["height"] as? NSNumber)?.intValue == page.original.height,
              root["coordinateSpace"] as? String == "normalized-top-left",
              let rows = root["regions"] as? [[String: Any]], rows.count <= 4096 else { return [] }
        let observer = NativeOriginalSourcePalette(original: page.original)
        return members.map { member in
            let clean = observationGeometry(member)
            let observation = observer.observe(sourceBounds: clean["sourceBounds"] as? [Double] ?? [], originalGeometry: clean)
            let records = matchedRecords(member, rows: rows)
            let axis = records?.count == 1 && supportsOwnAxis(records![0], original: page.original)
            let box = rect(member["sourceBounds"])
            let textSupport = page.rfRegions.filter { region in
                guard let box else { return false }
                return region.classID == 0 && region.confidence.isFinite && region.confidence >= 0.55 &&
                    valid(region.bounds) && coverage(box, region.bounds) >= 0.75
            }.map { ["query": $0.queryID, "confidence": $0.confidence] as [String: Any] }
            return ["owner": member["id"] as Any? ?? NSNull(), "exactSourceTargetBound": records != nil,
                "ownAxisSupported": axis, "nativeTextSupport": textSupport,
                "originalFill": observation.originalFill as Any? ?? NSNull(),
                "originalStroke": observation.originalStroke as Any? ?? NSNull(),
                "selectedOriginalInk": observation.selected.color as Any? ?? NSNull(),
                "role": observation.selected.role, "unresolvedOwnInk": observation.selected.color == nil,
                "unknownReason": observation.unknownReason as Any? ?? NSNull(),
                "authority": "fresh own original pixels; no display/peer RGB or imputation"] as [String: Any]
        }
    }

    /// Palette admission ONLY for an independently proposed graph/02 group.
    /// No membership, source order, target, layout or mask is modified here.
    /// Parent must separately certify source/target order before consuming it.
    static func makePolicyDescriptor(_ page: Ensemble100Page, candidate: [String: Any],
                                     policy: GroupPalettePolicy, enabled: Bool = false) -> PolicyDescriptor {
        let observer = NativeOriginalSourcePalette(original: page.original)
        let clean = observationGeometry(candidate)
        let baseline = observer.observe(sourceBounds: clean["sourceBounds"] as? [Double] ?? [], originalGeometry: clean)
        func result(_ reason: String, geometry: [String: Any]? = nil,
                    observation: NativeOriginalSourcePalette.Observation? = nil, accepted: Bool = false) -> PolicyDescriptor {
            PolicyDescriptor(geometry: geometry, observation: observation ?? baseline, accepted: accepted,
                audit: ["reason": reason, "accepted": accepted, "enabled": enabled,
                        "policy": policy.metadata, "paletteOnlyNotGroupingPermission": true,
                        "originalGroupEvidence": (observation ?? baseline).rawPrediction as Any? ?? NSNull()])
        }
        let baselineAccepted = (baseline.rawPrediction?["memberPaletteConsensus"] as? [String: Any])?["accepted"] as? Bool == true
        let retainedIncumbent = page.items.contains { NSDictionary(dictionary: $0).isEqual(to: candidate) }
        if baselineAccepted && retainedIncumbent {
            return result("acceptedBaselinePreserved", geometry: candidate, accepted: true)
        }
        guard enabled else { return result("policyDisabled") }
        guard let identity = try? NativeRFDETRSourceImage.decode(page.original).identity,
              page.savedEvidence["ocrSourceContentIdentity"] as? String == identity,
              page.savedEvidence["sourceSHA256"] as? String == page.sourceSHA256,
              let root = page.savedEvidence["originalOCR"] as? [String: Any],
              root["coordinateSpace"] as? String == "normalized-top-left",
              (root["width"] as? NSNumber)?.intValue == page.original.width,
              (root["height"] as? NSNumber)?.intValue == page.original.height,
              let rows = root["regions"] as? [[String: Any]], rows.count <= 4096,
              let members = candidate["agent02MemberItems"] as? [[String: Any]], (2...6).contains(members.count),
              Set(members.compactMap { $0["id"] as? String }).count == members.count,
              let signature = memberSignature(members), let union = rect(candidate["sourceBounds"]),
              let target = candidate["text"] as? String,
              lexical(target) == lexical(members.compactMap { $0["text"] as? String }.joined()) else {
            return result("unboundGroupSourceOrTarget")
        }
        var bound = [String: [[String: Any]]]()
        for member in members {
            guard member["keptLettering"] as? Bool != true, member["sourceTextOnly"] as? Bool != true,
                  let id = member["id"] as? String, let own = matchedRecords(member, rows: rows), own.count == 1,
                  let row = projectedRecord(own[0]), supportsOwnAxis(row, original: page.original),
                  let font = member["sourceFontSize"] as? Double, font.isFinite, font > 0 else {
                return result("missingExactOwnAxisMemberBinding")
            }
            bound[id] = [row]
        }
        let boxes = members.compactMap { rect($0["sourceBounds"]) }
        guard boxes.count == members.count, sameRect(union, boxes.reduce(CGRect.null) { $0.union($1) }),
              let support = page.rfRegions.filter({ region in
                  region.classID == 0 && region.confidence.isFinite && (0.55...1).contains(region.confidence) &&
                    valid(region.bounds) && boxes.allSatisfy { coverage($0, region.bounds) >= 0.75 }
              }).sorted(by: { $0.confidence > $1.confidence }).first else { return result("missingCommonNativeTextSupport") }
        var descriptor = policy.applying(to: candidate)
        // Retain the exact original member objects as provenance. Observation
        // paths strip their serialized audits on a private copy, never here.
        descriptor["agent02MemberItems"] = members
        descriptor["sourceParagraphPolicyBinding"] = ["version": GroupPalettePolicy.descriptorVersion,
            "policy": policy.metadata, "sourceIdentity": identity, "sourceSize": [page.original.width, page.original.height],
            "memberSignature": signature, "records": bound,
            "viewport": [Double(page.viewport.width), Double(page.viewport.height)],
            "support": ["queryID": support.queryID, "nativeClassID": 0, "confidence": support.confidence,
                        "bounds": components(support.bounds)]]
        if baselineAccepted {
            return result("boundNewGroupBaselinePreserved", geometry: descriptor, observation: baseline, accepted: true)
        }
        guard let fresh = observePolicyDescriptor(original: page.original, geometry: descriptor,
                                                   sourceBounds: components(union)) else {
            return result("unsupportedOriginalGroupInk", geometry: descriptor)
        }
        return result(fresh.selected.color != nil ? "freshOwnAxisGroupPalette" : "unsupportedOriginalGroupInk",
                      geometry: descriptor, observation: fresh, accepted: fresh.selected.color != nil)
    }

    /// Replays02/graph policy at07 from ORIGINAL pixels. The descriptor has no
    /// RGB endpoint field; serialized palette audits are not consulted.
    static func observePolicyDescriptor(original: CGImage, geometry: [String: Any],
                                        sourceBounds: [Double]) -> NativeOriginalSourcePalette.Observation? {
        guard let binding = geometry["sourceParagraphPolicyBinding"] as? [String: Any],
              binding["version"] as? Int == GroupPalettePolicy.descriptorVersion,
              let policy = GroupPalettePolicy.decode(binding["policy"]),
              let members = geometry["agent02MemberItems"] as? [[String: Any]], (2...6).contains(members.count),
              let signature = memberSignature(members), signature == binding["memberSignature"] as? String,
              let identity = try? NativeRFDETRSourceImage.decode(original).identity,
              binding["sourceIdentity"] as? String == identity,
              binding["sourceSize"] as? [Int] == [original.width, original.height],
              let records = binding["records"] as? [String: [[String: Any]]], records.count == members.count,
              let rawSupport = binding["support"] as? [String: Any], rawSupport["nativeClassID"] as? Int == 0,
              let query = rawSupport["queryID"] as? Int, let confidence = rawSupport["confidence"] as? Double,
              confidence.isFinite, (0.55...1).contains(confidence),
              let support = rect(rawSupport["bounds"]),
              let viewport = binding["viewport"] as? [Double], viewport.count == 2,
              viewport.allSatisfy({ $0.isFinite && $0 > 0 }),
              let declared = rect(geometry["sourceBounds"]), let requested = rect(sourceBounds), sameRect(declared, requested),
              let text = geometry["text"] as? String,
              lexical(text) == lexical(members.compactMap { $0["text"] as? String }.joined()) else { return nil }
        let rows = records.values.flatMap { $0 }
        let boxes = members.compactMap { rect($0["sourceBounds"]) }
        guard boxes.count == members.count, sameRect(declared, boxes.reduce(CGRect.null) { $0.union($1) }),
              boxes.allSatisfy({ coverage($0, support) >= 0.75 }) else { return nil }
        for member in members {
            guard let id = member["id"] as? String, let own = matchedRecords(member, rows: rows), own.count == 1,
                  let stored = records[id], sameRecords(own, stored), supportsOwnAxis(own[0], original: original) else { return nil }
        }
        let observer = NativeOriginalSourcePalette(original: original)
        let normalized = policy.applying(to: geometry)
        let incumbent = observer.observe(sourceBounds: sourceBounds, originalGeometry: normalized)
        if (incumbent.rawPrediction?["memberPaletteConsensus"] as? [String: Any])?["accepted"] as? Bool == true { return incumbent }
        let fresh = members.map { member -> NativeOriginalSourcePalette.Observation in
            // Rejected group recovery is not a new per-owner observation.
            // Retain each actual member's original policy and its accepted
            // palette first. In particular, do not turn a missing dominant
            // endpoint into a pale-core selection by applying a GROUP flag to
            // a singleton and then mistake that for measured contradiction.
            let own = observationGeometry(member)
            return observer.observe(sourceBounds: own["sourceBounds"] as? [Double] ?? [], originalGeometry: own)
        }
        // Endpoint-only policy never upgrades missing fill/stroke agreement to
        // an ink-only pooled decision. This branch is specifically opt-in ink.
        guard policy.inkOnly else { return nil }
        let attempt = propose(members: members, observations: fresh, sourceRecords: records, original: original,
            sourceIdentity: identity, rfText: [.init(queryID: query, classID: 1, confidence: confidence,
                bounds: support, sourceIdentity: identity)], viewport: CGSize(width: viewport[0], height: viewport[1]), enabled: true)
        return attempt.observation ?? NativeOriginalSourcePalette.Observation(originalFill: nil, originalStroke: nil, evidence: nil,
            selected: .init(color: nil, role: "unknown", neutralExteriorSuppressed: false),
            rawPrediction: ["paragraphPaletteCompatibility": attempt.audit], unknownReason: "unsupported original paragraph ink")
    }

    private static func supportsOwnAxis(_ row: [String: Any], original: CGImage) -> Bool {
        guard (row["confidence"] as? Double ?? 0) >= 0.8, row["sourceOrientation"] as? String == "vertical" else { return false }
        if row["sourceSingleVerticalColumn"] as? Bool == true { return true }
        guard let compact = row["sourceOwnedDetectorComponents"] as? [String: Any],
              compact["version"] as? Int == 1, compact["complete"] as? Bool == true,
              compact["status"] as? String == "complete-exclusive-components",
              compact["omittedComponentCount"] as? Int == 0,
              compact["coordinateSpace"] as? String == "normalized-top-left",
              compact["originalSourceSize"] as? [Int] == [original.width, original.height],
              let components = compact["components"] as? [[String: Any]], (1...16).contains(components.count) else { return false }
        return components.allSatisfy { component in
            guard let owner = component["ownerID"] as? String, !owner.isEmpty, rect(component["bounds"]) != nil,
                  let probability = component["meanProbability"] as? Double, (0.9...1).contains(probability),
                  let pixels = component["pixels"] as? Int, pixels > 0 else { return false }
            return true
        }
    }

    struct RFText {
        let queryID: Int
        let classID: Int
        let confidence: Double
        let bounds: CGRect
        /// Must come from the parent's identity-checked original RF adapter.
        let sourceIdentity: String
    }

    struct Proposal {
        let groupedItem: [String: Any]?
        let observation: NativeOriginalSourcePalette.Observation?
        let audit: [String: Any]
        let removalMembers: [[String: Any]]

        init(groupedItem: [String: Any]?, observation: NativeOriginalSourcePalette.Observation?,
             audit: [String: Any], removalMembers: [[String: Any]] = []) {
            self.groupedItem = groupedItem; self.observation = observation
            self.audit = audit; self.removalMembers = removalMembers
        }
    }

    struct Application {
        let items: [[String: Any]]
        let groups: [Proposal]
        let audit: [String: Any]
    }

    /// Live adapter: no supplied palette audits, numeric-ID membership, or
    /// assumed source ordering. The page's OCR transport must be source-bound.
    static func apply(_ page: Ensemble100Page, currentItems: [[String: Any]]? = nil, enabled: Bool = false) -> Application {
        let items = currentItems ?? page.items
        func unchanged(_ reason: String) -> Application {
            Application(items: items, groups: [], audit: ["enabled": enabled, "reason": reason, "version": version])
        }
        guard enabled else { return unchanged("policyDisabled") }
        guard items.count <= 256, Set(items.compactMap { $0["id"] as? String }).count == items.count else {
            return unchanged("invalidPageOwnerContract")
        }
        guard let identity = try? NativeRFDETRSourceImage.decode(page.original).identity,
              page.savedEvidence["ocrSourceContentIdentity"] as? String == identity,
              page.savedEvidence["sourceSHA256"] as? String == page.sourceSHA256,
              let root = page.savedEvidence["originalOCR"] as? [String: Any],
              root["coordinateSpace"] as? String == "normalized-top-left",
              (root["width"] as? NSNumber)?.intValue == page.original.width,
              (root["height"] as? NSNumber)?.intValue == page.original.height,
              let rawRows = root["regions"] as? [[String: Any]], rawRows.count <= 4096 else {
            return unchanged("unboundOriginalOCRTransport")
        }
        let rows = rawRows.compactMap(projectedRecord)
        guard rows.count == rawRows.count else { return unchanged("invalidBoundOCRRecords") }
        let observer = NativeOriginalSourcePalette(original: page.original)
        var observations = [String: NativeOriginalSourcePalette.Observation]()
        var records = [String: [[String: Any]]](), bindingFailures = [[String: Any]]()
        for item in items {
            guard let id = item["id"] as? String else { return unchanged("missingOwnerIdentity") }
            let geometry = observationGeometry(item)
            let fresh = observer.observe(sourceBounds: geometry["sourceBounds"] as? [Double] ?? [], originalGeometry: geometry)
            observations[id] = fresh
            if (fresh.rawPrediction?["memberPaletteConsensus"] as? [String: Any])?["accepted"] as? Bool == true { continue }
            if let matched = matchedRecords(item, rows: rows) { records[id] = matched }
            else {
                let geometric = rows.filter { row in
                    guard let a = rect(item["sourceBounds"]), let b = recordBounds(row) else { return false }
                    return sameRect(a, b)
                }
                bindingFailures.append(["owner": id, "reason": "sourceTranslationRefresh",
                    "cause": "nonuniqueExactSourceTargetBinding", "exactGeometryRecords": geometric.count,
                    "exactTargetRecords": geometric.filter {
                        lexical($0["translation"] as? String ?? "") == lexical(item["text"] as? String ?? "")
                    }.count])
            }
        }
        // Ensemble100RFRegion uses the actual native taxonomy, not the cached
        // artifact's canonical class. Native text0 is explicitly mapped to1.
        let support = page.rfRegions.filter { $0.classID == 0 }.map {
            RFText(queryID: $0.queryID, classID: 1, confidence: $0.confidence, bounds: $0.bounds, sourceIdentity: identity)
        }
        var orderFailures = [[String: Any]]()
        let result = apply(items: items, observations: observations, sourceRecords: records, original: page.original,
            sourceIdentity: identity, rfText: support, viewport: page.viewport, enabled: true, readingOrder: { members in
                let certificate = certifiedOrder(members, records: records)
                if let cause = certificate.reason {
                    orderFailures.append(["reason": "sourceTranslationRefresh", "cause": cause,
                        "members": members.compactMap { $0["id"] as? String }])
                }
                return certificate.items
            })
        var groups = [Proposal](), replacements = [String: [String: Any]]()
        for proposal in result.groups {
            guard var item = proposal.groupedItem,
                  let members = item["agent02MemberItems"] as? [[String: Any]],
                  let query = proposal.audit["rfTextQuery"] as? Int,
                  let region = support.first(where: { $0.queryID == query }),
                  let signature = memberSignature(members) else { return unchanged("liveGroupBindingAssemblyFailed") }
            let memberRecords = Dictionary(uniqueKeysWithValues: members.map { member in
                let id = member["id"] as! String; return (id, records[id]!)
            })
            item["sourceParagraphLivePalette"] = true
            item["sourceParagraphPaletteBinding"] = ["version": version, "sourceIdentity": identity,
                "sourceSize": [page.original.width, page.original.height],
                "viewport": [Double(page.viewport.width), Double(page.viewport.height)],
                "memberSignature": signature, "records": memberRecords,
                "support": ["queryID": region.queryID, "nativeClassID": 0, "confidence": region.confidence,
                    "bounds": components(region.bounds)]]
            // Ensure incumbent group consensus is tried first by the observer.
            item["sourceTextBlockMemberPalette"] = true
            item["sourceTextBlockInkOnlyAdmission"] = true
            // These are new groups, not accepted incumbents. Peer-assisted
            // recovery cannot supply the original evidence for this policy.
            for key in ["sourceStackedContinuation", "sourceTextBlockColumnPeerShell",
                        "sourceTextBlockNativePeerRecovery", "sourceTextBlockMeasuredEvidenceRecovery"] {
                item[key] = false
            }
            let bridged = Proposal(groupedItem: item, observation: proposal.observation,
                audit: proposal.audit, removalMembers: proposal.removalMembers)
            groups.append(bridged); replacements[item["id"] as! String] = item
        }
        let output = result.items.map { replacements[$0["id"] as? String ?? ""] ?? $0 }
        return Application(items: output, groups: groups, audit: result.audit.merging([
            "adapter": "fresh-original-observer/exact-OCR-binding/native-text0-to1",
            "freshOriginalObservations": observations.count,
            "freshKnownOwnerIDs": observations.filter { $0.value.selected.color != nil }.keys.sorted(),
            "sourceBindingFailures": bindingFailures, "sourceOrderingFailures": orderFailures,
            "sourceTranslationRefreshNeeded": bindingFailures.count + orderFailures.count,
            "serializedPaletteAuditsUsed": false], uniquingKeysWith: { $1 }))
    }

    /// Source-observer seam for07. Call AFTER incumbent member consensus is
    /// unknown. All member observations and pooled samples are recomputed from
    /// original pixels; serialized RGB/audits in the item are ignored.
    static func observeGrouped(original: CGImage, originalGeometry: [String: Any],
                               sourceBounds: [Double]) -> NativeOriginalSourcePalette.Observation? {
        if originalGeometry["sourceParagraphPolicyBinding"] != nil {
            return observePolicyDescriptor(original: original, geometry: originalGeometry, sourceBounds: sourceBounds)
        }
        guard originalGeometry["sourceParagraphLivePalette"] as? Bool == true,
              let binding = originalGeometry["sourceParagraphPaletteBinding"] as? [String: Any],
              binding["version"] as? Int == version,
              let members = originalGeometry["agent02MemberItems"] as? [[String: Any]], (2...12).contains(members.count),
              let signature = memberSignature(members), binding["memberSignature"] as? String == signature,
              let size = binding["sourceSize"] as? [Int], size == [original.width, original.height],
              let identity = try? NativeRFDETRSourceImage.decode(original).identity,
              binding["sourceIdentity"] as? String == identity,
              let records = binding["records"] as? [String: [[String: Any]]],
              let rawSupport = binding["support"] as? [String: Any], rawSupport["nativeClassID"] as? Int == 0,
              let query = rawSupport["queryID"] as? Int, let confidence = rawSupport["confidence"] as? Double,
              let supportBounds = rect(rawSupport["bounds"]),
              let viewport = binding["viewport"] as? [Double], viewport.count == 2,
              let expected = rect(sourceBounds), let declared = rect(originalGeometry["sourceBounds"]) else { return nil }
        let boxes = members.compactMap { rect($0["sourceBounds"]) }
        guard boxes.count == members.count,
              let target = originalGeometry["text"] as? String,
              lexical(target) == lexical(members.compactMap { $0["text"] as? String }.joined()),
              sameRect(expected, boxes.reduce(CGRect.null) { $0.union($1) }), sameRect(expected, declared) else { return nil }
        let rows = records.values.flatMap { $0 }.reduce(into: [[String: Any]]()) { rows, row in
            if !rows.contains(where: { NSDictionary(dictionary: $0).isEqual(to: row) }) { rows.append(row) }
        }
        var rebound = [String: [[String: Any]]]()
        for member in members {
            guard let id = member["id"] as? String, let own = matchedRecords(member, rows: rows),
                  let declared = records[id], sameRecords(own, declared) else { return nil }
            rebound[id] = own
        }
        let order = certifiedOrder(members, records: rebound)
        guard let certified = order.items,
              certified.compactMap({ $0["id"] as? String }) == members.compactMap({ $0["id"] as? String }) else { return nil }
        let observer = NativeOriginalSourcePalette(original: original)
        var incumbentGeometry = observationGeometry(originalGeometry)
        incumbentGeometry["sourceTextBlockMemberPalette"] = true
        incumbentGeometry["sourceTextBlockInkOnlyAdmission"] = true
        let incumbent = observer.observe(sourceBounds: sourceBounds, originalGeometry: incumbentGeometry)
        if (incumbent.rawPrediction?["memberPaletteConsensus"] as? [String: Any])?["accepted"] as? Bool == true {
            return incumbent
        }
        let fresh = members.map { member -> NativeOriginalSourcePalette.Observation in
            let geometry = observationGeometry(member)
            return observer.observe(sourceBounds: geometry["sourceBounds"] as? [Double] ?? [], originalGeometry: geometry)
        }
        let proposal = propose(members: members, observations: fresh, sourceRecords: rebound, original: original,
            sourceIdentity: identity,
            rfText: [.init(queryID: query, classID: 1, confidence: confidence, bounds: supportBounds, sourceIdentity: identity)],
            viewport: CGSize(width: viewport[0], height: viewport[1]), enabled: true)
        return proposal.observation
    }

    /// Run before old per-item eligibility/palette-unanimity filters. Group
    /// candidates are maximal shared RF text sets, not pairwise color bridges.
    /// Parent supplies source-certified reading order and accepted-group IDs.
    /// Use groups.observation for palette admission/paint, groups.removalMembers
    /// for unchanged erasure authorities, and items for existing 04 layout.
    static func apply(items: [[String: Any]], observations: [String: NativeOriginalSourcePalette.Observation],
                      sourceRecords: [String: [[String: Any]]], original: CGImage, sourceIdentity: String,
                      rfText: [RFText], viewport: CGSize, protectedGroupIDs: Set<String> = [], enabled: Bool = false,
                      readingOrder: ([[String: Any]]) -> [[String: Any]]?) -> Application {
        guard enabled else { return Application(items: items, groups: [], audit: ["enabled": false, "version": version]) }
        guard items.count <= 256, Set(items.compactMap { $0["id"] as? String }).count == items.count else {
            return Application(items: items, groups: [], audit: ["enabled": true, "reason": "invalidPageOwnerContract"])
        }
        let protected = Set(items.indices.filter { index in
            let id = items[index]["id"] as! String
            if protectedGroupIDs.contains(id) { return true }
            let raw = observations[id]?.rawPrediction
            return (raw?["memberPaletteConsensus"] as? [String: Any])?["accepted"] as? Bool == true
        })
        var candidates = [(indices: [Int], support: RFText)]()
        for region in rfText where region.classID == 1 && region.sourceIdentity == sourceIdentity && region.confidence.isFinite &&
            (0.55...1).contains(region.confidence) && valid(region.bounds) {
            // Do not build a new group around/through an already accepted one.
            if protected.contains(where: { index in
                rect(items[index]["sourceBounds"]).map { coverage($0, region.bounds) >= 0.75 } ?? false
            }) { continue }
            let indices = items.indices.filter { index in
                guard !protected.contains(index), let box = rect(items[index]["sourceBounds"]) else { return false }
                return coverage(box, region.bounds) >= 0.75
            }
            if (2...12).contains(indices.count) { candidates.append((indices, region)) }
        }
        candidates.sort { a, b in
            if a.indices.count != b.indices.count { return a.indices.count > b.indices.count }
            if a.support.confidence != b.support.confidence { return a.support.confidence > b.support.confidence }
            return a.support.queryID < b.support.queryID
        }
        var consumed = Set<Int>(), replacements = [Int: [String: Any]](), groups = [Proposal](), attempts = [[String: Any]]()
        for candidate in candidates where consumed.isDisjoint(with: candidate.indices) {
            let members = candidate.indices.map { items[$0] }
            guard let ordered = readingOrder(members), ordered.count == members.count,
                  Set(ordered.compactMap { $0["id"] as? String }) == Set(members.compactMap { $0["id"] as? String }),
                  ordered.allSatisfy({ item in
                      guard let id = item["id"] as? String, let original = members.first(where: { $0["id"] as? String == id }) else {
                          return false
                      }
                      return NSDictionary(dictionary: item).isEqual(to: original)
                  }) else {
                attempts.append(["reason": "missingOrMutatedCertifiedReadingOrder", "query": candidate.support.queryID]); continue
            }
            let own = ordered.compactMap { observations[$0["id"] as! String] }
            let decision = propose(members: ordered, observations: own, sourceRecords: sourceRecords,
                original: original, sourceIdentity: sourceIdentity, rfText: [candidate.support], viewport: viewport, enabled: true)
            attempts.append(decision.audit)
            guard let grouped = decision.groupedItem else { continue }
            consumed.formUnion(candidate.indices); replacements[candidate.indices.min()!] = grouped; groups.append(decision)
        }
        var result = [[String: Any]]()
        for index in items.indices {
            if let replacement = replacements[index] { result.append(replacement) }
            else if !consumed.contains(index) { result.append(items[index]) }
        }
        return Application(items: result, groups: groups, audit: ["enabled": true, "version": version,
            "inputItems": items.count, "outputItems": result.count, "acceptedGroups": groups.count,
            "protectedExistingGroups": protected.count, "attempts": attempts, "newRemovalPixelsAuthorized": 0])
    }

    /// Members MUST be in parent-certified source reading order. Source records
    /// are the complete original OCR records (including alternatives), keyed by
    /// current owner. Nested/combined owners retain all records and target text;
    /// this compatibility policy never deduplicates strings or erases glyphs.
    static func propose(members: [[String: Any]], observations: [NativeOriginalSourcePalette.Observation],
                        sourceRecords: [String: [[String: Any]]], original: CGImage, sourceIdentity: String,
                        rfText: [RFText], viewport: CGSize, enabled: Bool = false,
                        acceptedBaseline: [String: Any]? = nil) -> Proposal {
        func reject(_ reason: String, _ detail: [String: Any] = [:]) -> Proposal {
            Proposal(groupedItem: nil, observation: nil,
                audit: ["accepted": false, "reason": reason, "version": version].merging(detail, uniquingKeysWith: { $1 }))
        }
        if let acceptedBaseline {
            return Proposal(groupedItem: acceptedBaseline, observation: nil,
                audit: ["accepted": true, "reason": "acceptedBaselinePreserved", "version": version])
        }
        guard enabled else { return reject("policyDisabled") }
        guard (2...12).contains(members.count), observations.count == members.count,
              viewport.width.isFinite, viewport.height.isFinite, viewport.width > 0, viewport.height > 0,
              !sourceIdentity.isEmpty else { return reject("invalidGroupContract") }
        let ids = members.compactMap { $0["id"] as? String }
        guard ids.count == members.count, Set(ids).count == ids.count,
              ids.allSatisfy({ !$0.isEmpty && !(sourceRecords[$0] ?? []).isEmpty }) else { return reject("incompleteSourceProvenance") }
        guard observations.allSatisfy({ $0.selected.color == nil || rgb($0.selected.color) != nil }) else {
            return reject("invalidMeasuredOriginalInk")
        }
        var boxes = [CGRect](), targets = [String]()
        for member in members {
            guard member["keptLettering"] as? Bool != true, member["sourceTextOnly"] as? Bool != true,
                  let b = rect(member["sourceBounds"]), CGRect(x: 0, y: 0, width: 1, height: 1).contains(b),
                  let text = member["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !text.contains("\n\n"), !text.contains("\u{2029}") else { return reject("protectedOrInvalidMember") }
            boxes.append(b); targets.append(text)
        }
        for key in ["paragraphID", "paragraphIndex", "balloonID"] {
            let known = members.compactMap { $0[key] }
            if let first = known.first, known.dropFirst().contains(where: {
                !NSDictionary(dictionary: ["v": first]).isEqual(to: ["v": $0])
            }) { return reject("explicitSourceBoundary:" + key) }
        }
        let matching = rfText.filter { region in
            region.classID == 1 && region.sourceIdentity == sourceIdentity && region.confidence.isFinite &&
                (0.55...1).contains(region.confidence) &&
                valid(region.bounds) && boxes.allSatisfy { coverage($0, region.bounds) >= 0.75 }
        }
        guard let support = matching.sorted(by: { $0.confidence > $1.confidence }).first else {
            return reject("noIdentityBoundCommonRFParagraph")
        }
        let iw = Double(original.width), ih = Double(original.height)
        let physical = boxes.map { CGRect(x: $0.minX * iw, y: $0.minY * ih, width: $0.width * iw, height: $0.height * ih) }
        let major = physical.indices.max { physical[$0].width * physical[$0].height < physical[$1].width * physical[$1].height }!
        let vertical = members[major]["sourceVertical"] as? Bool ?? true
        let area = physical[major].width * physical[major].height
        for index in members.indices where (members[index]["sourceVertical"] as? Bool ?? vertical) != vertical {
            // A nested single glyph's local orientation does not split a source
            // paragraph, but its original record/orientation is never rewritten.
            guard physical[index].width * physical[index].height <= area * 0.15,
                  coverage(physical[index], physical[major]) >= 0.95 else { return reject("contradictorySourceDirection") }
        }
        let fonts = members.compactMap { ($0["sourceFontSize"] as? Double).flatMap { $0.isFinite && $0 > 0 ? $0 : nil } }.sorted()
        guard !fonts.isEmpty else { return reject("noOriginalScale") }
        let em = fonts[fonts.count / 2]
        func adjacent(_ a: CGRect, _ b: CGRect) -> Bool {
            if !a.intersection(b).isNull && a.intersection(b).width > 0 && a.intersection(b).height > 0 { return true }
            let alongA = vertical ? a.minY : a.minX, alongB = vertical ? b.minY : b.minX
            let endA = vertical ? a.maxY : a.maxX, endB = vertical ? b.maxY : b.maxX
            let lenA = vertical ? a.height : a.width, lenB = vertical ? b.height : b.width
            let crossA = vertical ? a.minX : a.minY, crossB = vertical ? b.minX : b.minY
            let crossEndA = vertical ? a.maxX : a.maxY, crossEndB = vertical ? b.maxX : b.maxY
            let crossLenA = vertical ? a.width : a.height, crossLenB = vertical ? b.width : b.height
            let overlap = max(0, min(endA, endB) - max(alongA, alongB))
            let crossOverlap = max(0, min(crossEndA, crossEndB) - max(crossA, crossB))
            let gap = max(0, max(alongA, alongB) - min(endA, endB))
            let crossGap = max(0, max(crossA, crossB) - min(crossEndA, crossEndB))
            return (overlap >= min(lenA, lenB) * 0.45 && crossGap <= em * 0.65) ||
                (crossOverlap >= min(crossLenA, crossLenB) * 0.5 && gap <= em * 0.45)
        }
        var connected: Set<Int> = [0], changed = true
        while changed {
            changed = false
            for i in physical.indices where !connected.contains(i) && connected.contains(where: { adjacent(physical[$0], physical[i]) }) {
                connected.insert(i); changed = true
            }
        }
        guard connected.count == members.count else { return reject("disconnectedOriginalParagraphRuns") }
        let known = observations.indices.filter { rgb(observations[$0].selected.color) != nil }
        // Contradiction is not uncertainty. Unknown middle owners cannot bridge
        // two measured colors, even if RF happens to put them in one text box.
        for a in known { for b in known where a < b {
            if distance(observations[a].selected.color!, observations[b].selected.color!) > 24 {
                return reject("measuredOriginalInkContradiction", ["contradictoryOwners": [ids[a], ids[b]]])
            }
        }}
        let unknown = observations.indices.filter { observations[$0].selected.color == nil }
        var groupInk: [Double]?, pooled: [String: Any] = [:]
        let anchors = known.filter { provedOriginalInk(observations[$0]) }
        if unknown.isEmpty && anchors.count == observations.count {
            groupInk = observations[known[0]].selected.color
            pooled = ["authority": "unchanged compatible measured original owner inks", "uniqueOriginalSamples": 0]
        } else {
            let measured = pooledInk(original: original, members: members)
            pooled = measured.audit
            guard let ink = measured.ink else { return reject("insufficientPooledOriginalInk", pooled) }
            for index in known where distance(ink, observations[index].selected.color!) > 24 {
                return reject("poolContradictsMeasuredOwner", pooled.merging(["owner": ids[index]], uniquingKeysWith: { $1 }))
            }
            // The pool proves presence/repetition, not whether a colored rim
            // dominates an entirely unranked white core. At least one existing
            // owned dominance observation must establish that source ink role.
            guard !anchors.isEmpty else {
                return reject("noIndependentOriginalAnchor", pooled)
            }
            // A large unmeasured owner cannot be smuggled in by a tiny anchor.
            let votes = measured.audit["ownerSamples"] as? [String: Int] ?? [:]
            for index in unknown where (votes[ids[index]] ?? 0) == 0 {
                guard physical[index].width * physical[index].height <= area * 0.15,
                      coverage(physical[index], physical[major]) >= 0.95 else {
                    return reject("unmeasuredSubstantialOwner", pooled.merging(["owner": ids[index]], uniquingKeysWith: { $1 }))
                }
            }
            groupInk = ink
        }
        guard let ink = groupInk else { return reject("unknownParagraphInk") }
        let union = boxes.reduce(CGRect.null) { $0.union($1) }
        var grouped = members[major]
        grouped["id"] = "causal-paragraph:" + ids.joined(separator: "+")
        grouped["text"] = targets.joined(separator: " ")
        grouped["sourceBounds"] = components(union)
        grouped["x"] = union.minX * viewport.width; grouped["y"] = union.minY * viewport.height
        grouped["width"] = union.width * viewport.width; grouped["height"] = union.height * viewport.height
        grouped["agent02MemberItems"] = members; grouped["agent02MemberIDs"] = ids
        grouped["sourceParagraphOriginalRecords"] = ids.map { ["owner": $0, "records": sourceRecords[$0]!] as [String: Any] }
        var offset = 0
        grouped["sourceParagraphTargetSpans"] = targets.enumerated().map { index, text -> [String: Any] in
            let span: [String: Any] = ["owner": ids[index], "locationUTF16": offset, "lengthUTF16": text.utf16.count]
            offset += text.utf16.count + 1
            return span
        }
        grouped["unitMemberRects"] = members.flatMap { $0["unitMemberRects"] as? [[Double]] ?? [$0["sourceBounds"] as! [Double]] }
        let sourceMembers = members.compactMap { $0["sourceMemberPolygons"] as? [[[Double]]] }
        if sourceMembers.count == members.count { grouped["sourceMemberPolygons"] = sourceMembers.flatMap { $0 } }
        else { grouped.removeValue(forKey: "sourceMemberPolygons") }
        grouped["auxiliaryInkRects"] = members.flatMap { $0["auxiliaryInkRects"] as? [[Double]] ?? [] }
        grouped["auxiliaryInkPolygons"] = members.flatMap { $0["auxiliaryInkPolygons"] as? [[[Double]]] ?? [] }
        grouped["sourceParagraphPreserveRemovalAuthority"] = true
        grouped["sourceParagraphFitSourceEnvelope"] = true
        grouped["sourceSingleColumn"] = false
        // Parent must run the existing BW stroke policy and shaping/certification
        // with this group observation. A member display style is stale here.
        for key in ["ensemblePaletteAudit", "ensembleDisplayFill", "ensembleDisplayStroke", "sourcePolygon", "sourceQuad",
                    "typesettingText", "typesettingPreformattedRows", "smallTextReference", "unitPlannedCard",
                    "balloonUnit", "columnLayout", "uprightAlternative", "balloonInterior", "sourceNearLayout"] {
            grouped.removeValue(forKey: key)
        }
        let ownerStates = observations.enumerated().map { i, observation -> [String: Any] in
            ["owner": ids[i], "sourceFill": observation.originalFill as Any? ?? NSNull(),
                "sourceStroke": observation.originalStroke as Any? ?? NSNull(),
                "selectedOriginalInk": observation.selected.color as Any? ?? NSNull(),
                "role": observation.selected.role, "uncertainty": observation.unknownReason as Any? ?? NSNull()]
        }
        let audit: [String: Any] = ["accepted": true, "reason": "sourceParagraphPaletteCompatible", "version": version,
            "rfTextQuery": support.queryID, "sourceIdentity": sourceIdentity, "members": ids,
            "unmeasuredOwnerIDs": unknown.map { ids[$0] }, "ownerObservations": ownerStates,
            "pooledEvidence": pooled, "paragraphSelectedOriginalInk": ink,
            "unknownOwnerColorsImputed": false, "newRemovalPixelsAuthorized": 0,
            "authority": "independent RF paragraph and original source continuity + owner-accounted original ink; not sentence/glyph gold"]
        grouped["sourceParagraphPaletteCompatibility"] = audit
        let observation = NativeOriginalSourcePalette.Observation(originalFill: nil, originalStroke: nil, evidence: nil,
            selected: .init(color: ink, role: "sourceParagraphPooledInk", neutralExteriorSuppressed: false),
            rawPrediction: ["paragraphPaletteCompatibility": audit],
            unknownReason: "group ink established; unresolved member endpoints remain unknown; source roles retained per owner")
        return Proposal(groupedItem: grouped, observation: observation, audit: audit, removalMembers: members)
    }

    private struct Pool {
        let ink: [Double]?
        let audit: [String: Any]
    }

    /// Only locally flat chromatic pixels with an owned pale glyph interface
    /// vote. No guide/neighbor color is supplied. Overlapping OCR owners attach
    /// provenance to ONE physical source pixel rather than multiplying votes.
    private static func pooledInk(original: CGImage, members: [[String: Any]]) -> Pool {
        struct Sample { let rgb: [Double]; var owners: Set<Int>; var axes: Set<Int> }
        let iw = original.width, ih = original.height
        var samples = [Int: Sample](), totalCaptured = 0
        for (index, member) in members.enumerated() {
            let b = rect(member["sourceBounds"])!
            let x = max(0, Int(floor(b.minX * Double(iw))) - 4), y = max(0, Int(floor(b.minY * Double(ih))) - 4)
            let w = min(iw, Int(ceil(b.maxX * Double(iw))) + 4) - x
            let h = min(ih, Int(ceil(b.maxY * Double(ih))) + 4) - y
            guard w >= 3, h >= 3, h <= 262144, w <= 262144 / h, totalCaptured + w * h <= 1_048_576,
                  let crop = original.cropping(to: CGRect(x: x, y: y, width: w, height: h)) else {
                return Pool(ink: nil, audit: ["reason": "originalSamplingBudgetOrCrop"])
            }
            totalCaptured += w * h
            var rgba = [UInt8](repeating: 0, count: w * h * 4)
            let ok = rgba.withUnsafeMutableBytes { bytes -> Bool in
                guard let c = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                c.interpolationQuality = .none; c.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
            }
            let polygon = member["sourcePolygon"] as? [[Double]] ?? [
                [b.minX, b.minY], [b.maxX, b.minY], [b.maxX, b.maxY], [b.minX, b.maxY]]
            guard ok, polygon.count >= 3, polygon.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) else {
                return Pool(ink: nil, audit: ["reason": "invalidOriginalOwnership"])
            }
            let path = CGMutablePath()
            path.addLines(between: polygon.map { CGPoint(x: $0[0] * Double(iw) - Double(x), y: $0[1] * Double(ih) - Double(y)) })
            path.closeSubpath()
            var owned = [Bool](repeating: false, count: w * h)
            for yy in 0..<h { for xx in 0..<w {
                owned[yy * w + xx] = path.contains(CGPoint(x: Double(xx) + 0.5, y: Double(yy) + 0.5)) && rgba[(yy * w + xx) * 4 + 3] >= 250
            }}
            func color(_ p: Int) -> [Double] { (0..<3).map { Double(rgba[p * 4 + $0]) } }
            for yy in 1..<(h - 1) { for xx in 1..<(w - 1) {
                let p = yy * w + xx
                guard owned[p] else { continue }
                let c = color(p)
                guard c.max()! - c.min()! >= 28, c.min()! <= 160,
                      [p - 1, p + 1, p - w, p + w].filter({ owned[$0] && distance(color($0), c) <= 12 }).count >= 2 else { continue }
                var axes = Set<Int>()
                for (axis, d) in [(1, 0), (0, 1), (1, 1), (1, -1)].enumerated() {
                    for sign in [-1, 1] {
                        var transition = [[Double]]()
                        for step in 1...6 {
                            let qx = xx + d.0 * step * sign, qy = yy + d.1 * step * sign
                            guard qx >= 0, qy >= 0, qx < w, qy < h else { break }
                            let q = qy * w + qx
                            guard owned[q] else { break }
                            let v = color(q)
                            if v.min()! >= 225, v.max()! - v.min()! <= 32 {
                                // Intermediate AA must lie on this observed
                                // core/endpoint segment; artwork is not a rim.
                                let delta = zip(v, c).map { $0 - $1 }, den = delta.reduce(0) { $0 + $1 * $1 }
                                if den > 0 && transition.allSatisfy({ t in
                                    let weight = zip(zip(t, c), delta).reduce(0) { $0 + ($1.0.0 - $1.0.1) * $1.1 } / den
                                    let expected = zip(c, delta).map { $0 + min(1, max(0, weight)) * $1 }
                                    return (-0.05...1.05).contains(weight) && distance(t, expected) <= 16
                                }) { axes.insert(axis) }
                                break
                            }
                            transition.append(v)
                        }
                    }
                }
                guard !axes.isEmpty else { continue }
                let pixel = (y + yy) * iw + x + xx
                if var prior = samples[pixel] {
                    guard prior.rgb == c else {
                        return Pool(ink: nil, audit: ["reason": "inconsistentOriginalPixelCoordinates"])
                    }
                    prior.owners.insert(index); prior.axes.formUnion(axes); samples[pixel] = prior
                } else { samples[pixel] = Sample(rgb: c, owners: [index], axes: axes) }
                guard samples.count <= 131072 else { return Pool(ink: nil, audit: ["reason": "originalSampleBudget"]) }
            }}
        }
        var centers = [Int: [Double]]()
        for pixel in samples.keys.sorted() {
            let c = samples[pixel]!.rgb
            let key = (Int(c[0]) / 16) * 256 + (Int(c[1]) / 16) * 16 + Int(c[2]) / 16
            if centers[key] == nil { centers[key] = c }
        }
        guard !centers.isEmpty, centers.count <= 128 else { return Pool(ink: nil, audit: ["reason": "missingOrDiffuseOriginalEndpoints"]) }
        let pixels = samples.keys.sorted()
        var ranked = centers.keys.sorted().map { key in pixels.filter { distance(samples[$0]!.rgb, centers[key]!) <= 20 } }
        ranked.sort { a, b in a.count == b.count ? a[0] < b[0] : a.count > b.count }
        let selected = ranked[0], selectedSet = Set(selected)
        let cells = Set(selected.map { ($0 / iw / 4) * iw + $0 % iw / 4 })
        let axes = selected.reduce(into: Set<Int>()) { $0.formUnion(samples[$1]!.axes) }
        var ownerCounts = [String: Int](), exclusive = [Int: Int]()
        for pixel in selected {
            for owner in samples[pixel]!.owners { ownerCounts[members[owner]["id"] as! String, default: 0] += 1 }
            if samples[pixel]!.owners.count == 1 { exclusive[samples[pixel]!.owners.first!, default: 0] += 1 }
        }
        let audit: [String: Any] = ["uniqueOriginalSamples": selected.count, "allQualifiedSamples": samples.count,
            "independentCells": cells.count, "orientations": axes.count, "ownerSamples": ownerCounts,
            "exclusiveSupportingOwners": exclusive.values.filter { $0 >= 12 }.count,
            "physicalDuplicatesRemoved": ownerCounts.values.reduce(0, +) - selected.count,
            "capturedPixels": totalCaptured, "authority": "unique owned stable chromatic pixels at original pale glyph interfaces; no bbox/peer/display colors"]
        guard selected.count >= 48, cells.count >= 6, axes.count >= 2 else { return Pool(ink: nil, audit: audit) }
        guard !ranked.contains(where: { $0.count >= max(24, selected.count / 4) && Set($0).isDisjoint(with: selectedSet) }) else {
            return Pool(ink: nil, audit: audit.merging(["reason": "repeatedContradictoryOriginalEndpoints"], uniquingKeysWith: { $1 }))
        }
        // Return one actually observed pixel (medoid-nearest endpoint), not a
        // synthetic peer average or an imputed per-owner color.
        let mean = (0..<3).map { channel in selected.reduce(0.0) { $0 + samples[$1]!.rgb[channel] } / Double(selected.count) }
        let representative = selected.min { a, b in
            let da = distance(samples[a]!.rgb, mean), db = distance(samples[b]!.rgb, mean)
            return da == db ? a < b : da < db
        }!
        return Pool(ink: samples[representative]!.rgb, audit: audit)
    }

    private static func rgb(_ c: [Double]?) -> [Double]? {
        guard let c, c.count == 3, c.allSatisfy({ $0.isFinite && (0...255).contains($0) }) else { return nil }; return c
    }
    private static func provedOriginalInk(_ observation: NativeOriginalSourcePalette.Observation) -> Bool {
        guard let ink = rgb(observation.selected.color) else { return false }
        let raw = observation.rawPrediction ?? [:]
        if let shell = raw["ownedChromaticShellRecovery"] as? [String: Any],
           (shell["components"] as? Int ?? 0) >= 6, (shell["tiles"] as? Int ?? 0) >= 4,
           let color = rgb(shell["stroke"] as? [Double]), distance(color, ink) <= 24 { return true }
        if let e = observation.evidence {
            if let fill = rgb(observation.originalFill), distance(fill, ink) <= 24,
               e.fillShapePixels >= 12, e.fillRepeatedTiles >= 4 { return true }
            if let stroke = rgb(observation.originalStroke), distance(stroke, ink) <= 24,
               e.strokeShapePixels >= 12, e.strokeRepeatedTiles >= 4 { return true }
        }
        guard let topology = raw["sourceInkDominance"] as? [String: Any] else { return false }
        for (name, endpoint) in [("fill", observation.originalFill), ("stroke", observation.originalStroke)] {
            if let endpoint = rgb(endpoint), distance(endpoint, ink) <= 24,
               let shape = (topology[name + "ShapePixels"] as? NSNumber)?.doubleValue,
               let tiles = (topology[name + "RepeatedTiles"] as? NSNumber)?.doubleValue,
               shape.isFinite, shape >= 12, tiles.isFinite, (4...36).contains(tiles) { return true }
        }
        return false
    }
    private static func observationGeometry(_ raw: [String: Any], depth: Int = 0) -> [String: Any] {
        var result = raw
        for key in ["ensemblePaletteAudit", "ensembleDisplayFill", "ensembleDisplayStroke",
                    "sourceParagraphLivePalette", "sourceParagraphPaletteBinding", "sourceParagraphPaletteCompatibility",
                    "sourceParagraphPolicyBinding"] {
            result.removeValue(forKey: key)
        }
        if let members = raw["agent02MemberItems"] as? [[String: Any]] {
            if depth < 8 { result["agent02MemberItems"] = members.map { observationGeometry($0, depth: depth + 1) } }
            else { result.removeValue(forKey: "agent02MemberItems"); result["sourceTextBlockMemberPalette"] = false }
        }
        return result
    }
    private static func recordBounds(_ row: [String: Any]) -> CGRect? {
        if let r = rect(row["sourceBounds"]) { return r }
        guard let r = row["rect"] as? [String: Any] else { return nil }
        return rect([r["x"], r["y"], r["width"], r["height"]].compactMap { ($0 as? NSNumber)?.doubleValue })
    }
    private static func points(_ raw: Any?) -> [[Double]]? {
        if raw == nil || raw is NSNull { return [] }
        let result: [[Double]]
        if let p = raw as? [[Double]] { result = p }
        else if let p = raw as? [[String: Any]] {
            result = p.map { [($0["x"] as? NSNumber)?.doubleValue, ($0["y"] as? NSNumber)?.doubleValue].compactMap { $0 } }
        } else { return nil }
        guard result.isEmpty || result.count >= 3,
              result.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) else { return nil }
        return result
    }
    private static func projectedRecord(_ row: [String: Any]) -> [String: Any]? {
        guard let box = recordBounds(row), CGRect(x: 0, y: 0, width: 1, height: 1).contains(box),
              let polygon = points(row["polygon"]), let source = row["source"] as? String, !source.isEmpty else { return nil }
        // Same lexical/geometry projection as the runtime OCR transport. Never
        // serialize probability byte arrays, paths or rendered RGB predictions.
        var result = [String: Any]()
        for key in ["id", "score", "sourceIndex", "sourceOrientation", "sourceSingleVerticalColumn", "confidence",
                    "source", "translation", "sourceOCRAlternatives", "unitMemberRects", "sourceMemberPolygons",
                    "rawUnitMemberRects", "clippedUnitMemberIndices", "sourceGeometryObservation", "sourceOwnedDetectorComponents"] {
            if let value = row[key], !(value is NSNull) { result[key] = value }
        }
        result["sourceBounds"] = components(box)
        result["polygon"] = polygon
        return JSONSerialization.isValidJSONObject(result) ? result : nil
    }
    private static func sameRect(_ a: CGRect, _ b: CGRect) -> Bool {
        zip([a.minX, a.minY, a.width, a.height], [b.minX, b.minY, b.width, b.height]).allSatisfy { abs($0 - $1) <= 1e-8 }
    }
    // Keep the in-memory transport identical to its JSON round trip: boxed
    // CGFloat arrays do not cast to [Double] until serialized and reloaded.
    private static func components(_ box: CGRect) -> [Double] {
        [box.minX, box.minY, box.width, box.height].map(Double.init)
    }
    private static func samePolygon(_ a: [[Double]], _ b: [[Double]]) -> Bool {
        guard a.count == b.count else { return false }
        if a.isEmpty { return true }
        return a.indices.contains { shift in
            a.indices.allSatisfy { i in zip(a[i], b[(i + shift) % b.count]).allSatisfy { abs($0 - $1) <= 1e-8 } }
        }
    }
    private static func lexical(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }))
    }
    private static func matchedRecords(_ item: [String: Any], rows: [[String: Any]], depth: Int = 0) -> [[String: Any]]? {
        guard depth < 8, let box = rect(item["sourceBounds"]), let target = item["text"] as? String else { return nil }
        if let members = item["agent02MemberItems"] as? [[String: Any]], (2...12).contains(members.count) {
            var source = [String: [[String: Any]]]()
            for member in members {
                guard let id = member["id"] as? String, let own = matchedRecords(member, rows: rows, depth: depth + 1) else { return nil }
                source[id] = own
            }
            guard let ordered = certifiedOrder(members, records: source).items,
                  lexical(ordered.compactMap { $0["text"] as? String }.joined()) == lexical(target),
                  sameRect(box, members.compactMap { rect($0["sourceBounds"]) }.reduce(CGRect.null) { $0.union($1) }) else { return nil }
            return ordered.flatMap { source[$0["id"] as! String]! }
        }
        guard let polygon = points(item["sourcePolygon"]) else { return nil }
        let matches = rows.filter { row in
            guard let r = recordBounds(row), sameRect(box, r),
                  let translated = row["translation"] as? String, lexical(translated) == lexical(target),
                  let own = points(row["polygon"]) else { return false }
            return polygon.isEmpty || own.isEmpty || samePolygon(polygon, own)
        }
        return matches.count == 1 ? matches : nil
    }
    private struct OrderCertificate { let items: [[String: Any]]?; let reason: String? }
    private static func certifiedOrder(_ members: [[String: Any]], records: [String: [[String: Any]]]) -> OrderCertificate {
        func refresh(_ reason: String) -> OrderCertificate { .init(items: nil, reason: reason) }
        guard (2...12).contains(members.count), members.allSatisfy({ member in
            guard let id = member["id"] as? String else { return false }; return !(records[id] ?? []).isEmpty
        }) else { return refresh("nonuniqueExactSourceTargetBinding") }
        let boxes = members.compactMap { rect($0["sourceBounds"]) }
        guard boxes.count == members.count else { return refresh("missingOriginalGeometry") }
        let major = boxes.indices.max { boxes[$0].width * boxes[$0].height < boxes[$1].width * boxes[$1].height }!
        let vertical = members[major]["sourceVertical"] as? Bool ?? true
        var before = [Set<Int>](repeating: [], count: members.count)
        for a in boxes.indices { for b in boxes.indices where a < b {
            let x = boxes[a], y = boxes[b], intersection = x.intersection(y)
            // Bounding rectangles that overlap cannot certify insertion into a
            // translated run, even when one child string occurs in the parent.
            if !intersection.isNull, intersection.width > 1e-8, intersection.height > 1e-8 {
                return refresh("nestedOrOverlappingSourceRunsRequireTranslationRefresh")
            }
            var earlier: Int?, later: Int?
            if vertical {
                if x.maxX <= y.minX + 1e-8 { earlier = b; later = a }
                else if y.maxX <= x.minX + 1e-8 { earlier = a; later = b }
                else {
                    let single = [a, b].allSatisfy { index in
                        records[members[index]["id"] as! String]!.allSatisfy { $0["sourceSingleVerticalColumn"] as? Bool == true }
                    }
                    guard single else { return refresh("incomparableMulticolumnInsertionRequiresTranslationRefresh") }
                    if x.maxY <= y.minY + 1e-8 { earlier = a; later = b }
                    else if y.maxY <= x.minY + 1e-8 { earlier = b; later = a }
                }
            } else {
                if x.maxY <= y.minY + 1e-8 { earlier = a; later = b }
                else if y.maxY <= x.minY + 1e-8 { earlier = b; later = a }
                else if x.maxX <= y.minX + 1e-8 { earlier = a; later = b }
                else if y.maxX <= x.minX + 1e-8 { earlier = b; later = a }
            }
            guard let earlier, let later else { return refresh("incomparableSourceOrderRequiresTranslationRefresh") }
            before[later].insert(earlier)
        }}
        var remaining = Set(boxes.indices), ordered = [Int]()
        while !remaining.isEmpty {
            let available = remaining.filter { before[$0].isDisjoint(with: remaining) }
            guard available.count == 1, let next = available.first else { return refresh("nonuniqueSourceRunOrder") }
            ordered.append(next); remaining.remove(next)
        }
        return .init(items: ordered.map { members[$0] }, reason: nil)
    }
    private static func memberSignature(_ members: [[String: Any]]) -> String? {
        let projected = members.map { member -> [String: Any] in
            var row = [String: Any]()
            for key in ["id", "sourceBounds", "sourcePolygon", "text", "agent02MemberItems"] {
                if let value = member[key] { row[key] = key == "agent02MemberItems"
                    ? (value as? [[String: Any]]).map { $0.map { observationGeometry($0) } } as Any? ?? NSNull() : value }
            }
            return row
        }
        guard JSONSerialization.isValidJSONObject(projected),
              let data = try? JSONSerialization.data(withJSONObject: projected, options: [.sortedKeys]), data.count <= 2 * 1024 * 1024 else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func sameRecords(_ a: [[String: Any]], _ b: [[String: Any]]) -> Bool {
        guard a.count == b.count,
              let x = try? JSONSerialization.data(withJSONObject: a, options: [.sortedKeys]),
              let y = try? JSONSerialization.data(withJSONObject: b, options: [.sortedKeys]) else { return false }
        return x == y
    }
    private static func distance(_ a: [Double], _ b: [Double]) -> Double { zip(a, b).map { abs($0 - $1) }.max()! }
    private static func valid(_ r: CGRect) -> Bool {
        !r.isNull && !r.isInfinite && r.width > 0 && r.height > 0 && [r.minX, r.minY, r.maxX, r.maxY].allSatisfy(\.isFinite)
    }
    private static func rect(_ raw: Any?) -> CGRect? {
        guard let b = raw as? [Double], b.count == 4, b.allSatisfy(\.isFinite), b[2] > 0, b[3] > 0 else { return nil }
        return CGRect(x: b[0], y: b[1], width: b[2], height: b[3])
    }
    private static func coverage(_ a: CGRect, _ b: CGRect) -> Double {
        let i = a.intersection(b); return i.isNull ? 0 : i.width * i.height / (a.width * a.height)
    }
}
