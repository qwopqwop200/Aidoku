import CoreGraphics
import Foundation

/// Endpoint-only alternatives. Peer membership/consumption belongs to the source-union helper.
@available(iOS 18.0, *)
enum NativeOCRResidualTerminalExtension {
    typealias Measurement = NativeOCRSourceComponentMeasurements.Measurement
    private struct Ink {
        let colour: SIMD3<Int>
        let bounds: CGRect
        let points: [CGPoint] // In the incoming measurement's frame, including after remeasurement.
        let owned: Int
    }

    static func candidates(_ m: Measurement) -> [NativeOCRResidualCandidate] {
        extensions(m, measured: m, peerAllows: { _ in true })
    }

    static func candidates(_ m: Measurement, context: NativeOCRResidualSourceContext) -> [NativeOCRResidualCandidate] {
        // Opt-in, export-only diagnostics. No runtime routing reads these files.
        let diagnosticPath = ProcessInfo.processInfo.environment["AIDOKU_OCR_TERMINAL_PROBE_DIAGNOSTICS_DIR"]
        var events: [[String: Any]] = []
        func record(_ detail: [String: Any]) { if diagnosticPath != nil { events.append(detail) } }
        defer {
            if let diagnosticPath {
                let payload: [String: Any] = ["sourceIndex": m.index, "measurement": m.json, "events": events]
                let directory = URL(fileURLWithPath: diagnosticPath, isDirectory: true)
                if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try? data.write(to: directory.appendingPathComponent("terminal-\(m.index)-\(UUID().uuidString).json"), options: .atomic)
                }
            }
        }
        guard eligible(m) else { record(["stage": "entry", "rejection": "unmeasured-or-insufficient-private-geometry"]); return [] }
        let members = Set(context.groups[m.index] ?? [m.index])
        let evidence = members.compactMap { index -> NativeOCRDetectorSeedEvidence? in
            guard context.originals.indices.contains(index), let seed = context.originals[index].detectorSeedEvidence,
                  seed.isValid, !seed.components.isEmpty else { return nil }
            return seed
        }
        // Provisional views have already passed immutable external-cell exclusion
        // in the parent measurement context. Their owners must still be members.
        let memberOwners = Set(members.compactMap { index -> String? in
            guard context.originals.indices.contains(index),
                  let seed = context.originals[index].detectorSeedEvidence, seed.isValid else { return nil }
            return seed.ownerID
        })
        let verifiedProvisional = !m.provisionalOwners.isEmpty && Set(m.provisionalOwners).isSubset(of: memberOwners)
        let provisionalOnly = evidence.isEmpty && verifiedProvisional
        func versioned(_ candidates: [NativeOCRResidualCandidate]) -> [NativeOCRResidualCandidate] {
            candidates.map { candidate in
                guard provisionalOnly else { return candidate }
                return .init(key: candidate.key.replacingOccurrences(of: "-v1", with: "-provisional-member-v2"),
                             polygon: candidate.polygon, consumedIndices: candidate.consumedIndices, supportPoints: candidate.supportPoints)
            }
        }
        guard !evidence.isEmpty || verifiedProvisional || (m.kind == "independent" && !m.associatedOwners.isEmpty) else {
            record(["stage": "entry", "rejection": "no-member-evidence"]); return []
        }
        record(["stage": "entry", "provisionalOnly": provisionalOnly, "memberOwners": memberOwners.sorted()])
        let observer: (([String: Any]) -> Void)? = diagnosticPath == nil ? nil : record
        // Even unowned RGB ink must not extend into a known peer. Complete recovered
        // columns also remain peers: choosing/consuming one requires explicit provenance.
        let peers = context.regions.filter { $0.index != m.index && !members.contains($0.index) }
        func peerAllows(_ points: [CGPoint]) -> Bool {
            !peers.contains { peer in
                points.contains { point in
                    !NativeOCRSourceComponentMeasurements.contains(m.polygon, point, tolerance: 0.75) &&
                        NativeOCRSourceComponentMeasurements.contains(peer.polygon, point, tolerance: 0.75)
                }
            }
        }
        var result = extensions(m, measured: m, peerAllows: peerAllows, diagnostics: observer)
        let reach = min(m.rect.width * 3, m.rect.height * 0.4)
        guard reach >= 2 * m.step else { return versioned(result) }
        // Two bounded source-axis probes, never iterative/full-page rescans. The
        // measurement context retains the original member cells and foreign flags.
        for head in [true, false] {
            let edge = head ? m.rect.minY : m.rect.maxY
            let anchor = m.restore(.init(x: m.rect.midX, y: edge))
            let scopedRoom = m.scopes.contains { scope in
                guard scope.confidence >= 0.5, scope.rect.contains(anchor) else { return false }
                let r = scope.rect
                let projected = extent([CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                                        CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)].map(m.project))
                return head ? projected.minY < edge - m.step : projected.maxY > edge + m.step
            }
            let ownRoom = evidence.contains { seed in
                let sx = CGFloat(seed.sourceWidth) / CGFloat(seed.mapFullWidth)
                let sy = CGFloat(seed.sourceHeight) / CGFloat(seed.mapFullHeight)
                return seed.components.contains { component in
                    component.runs.contains { run in
                        // Cell-run endpoints and midpoint are sufficient to nominate a
                        // probe; only the subsequent measured pixels authorize growth.
                        [run.x, run.x + run.count / 2, run.x + run.count - 1].contains { x in
                            let p = m.project(.init(x: (CGFloat(x) + 0.5) * sx, y: (CGFloat(run.y) + 0.5) * sy))
                            let distance = head ? edge - p.y : p.y - edge
                            return p.x >= m.rect.minX && p.x <= m.rect.maxX && distance >= m.step && distance <= reach
                        }
                    }
                }
            }
            guard scopedRoom || ownRoom else {
                record(["stage": "probe", "head": head, "rejection": "no-scoped-or-owned-room"]); continue
            }
            let probe = stretched(m, head: head ? -reach : 0, tail: head ? 0 : reach)
            guard let measured = context.measure(m.index, probe) else {
                record(["stage": "probe", "head": head, "rejection": "nil-measurement"]); continue
            }
            if diagnosticPath != nil {
                record(["stage": "probe", "head": head, "scopedRoom": scopedRoom, "ownRoom": ownRoom, "measurement": measured.json])
            }
            guard measured.status == "measured" else { continue }
            for candidate in extensions(m, measured: measured, onlyHead: head, peerAllows: peerAllows, diagnostics: observer) {
                if let old = result.firstIndex(where: { $0.key == candidate.key }) {
                    // One stable candidate per direction; retain the larger observed cap.
                    let oldExtent = extent(result[old].polygon.map(m.project))
                    let newExtent = extent(candidate.polygon.map(m.project))
                    if head ? newExtent.minY < oldExtent.minY : newExtent.maxY > oldExtent.maxY { result[old] = candidate }
                } else { result.append(candidate) }
            }
        }
        // Check the entire added normal band as well as the ink points. A small
        // peer in the gap must not be jumped over by a terminal chain.
        let filtered = result.filter { candidate in
            let proposed = extent(candidate.polygon.map(m.project))
            return !peers.contains { peer in
                let b = extent(peer.polygon.map(m.project))
                let overlap = min(b.maxX, m.rect.maxX) - max(b.minX, m.rect.minX)
                guard overlap >= min(b.width, m.rect.width) * 0.25 else { return false }
                let headOverlap = min(b.maxY, m.rect.minY) - max(b.minY, proposed.minY)
                let tailOverlap = min(b.maxY, proposed.maxY) - max(b.minY, m.rect.maxY)
                return headOverlap > 0.75 || tailOverlap > 0.75
            }
        }
        record(["stage": "peer-band", "before": result.count, "after": filtered.count])
        return versioned(filtered)
    }

    private static func eligible(_ m: Measurement) -> Bool {
        m.status == "measured" && m.polygon.count == 4 && m.privateSamples >= 4 &&
            m.rect.width >= 5 && m.rect.height >= m.rect.width * 2 &&
            m.rect.width.isFinite && m.rect.height.isFinite && m.step > 0
    }

    private static func extensions(_ m: Measurement, measured: Measurement, onlyHead: Bool? = nil,
                                   peerAllows: ([CGPoint]) -> Bool,
                                   diagnostics: (([String: Any]) -> Void)? = nil) -> [NativeOCRResidualCandidate] {
        guard eligible(m), measured.status == "measured" else { return [] }
        let width = m.rect.width
        let ink = measured.components.compactMap { c -> Ink? in
            guard c.foreignPixels == 0, c.pixels >= 2, !c.hull.isEmpty else { return nil }
            let corners = [CGPoint(x: c.bounds.minX, y: c.bounds.minY), CGPoint(x: c.bounds.maxX, y: c.bounds.minY),
                           CGPoint(x: c.bounds.maxX, y: c.bounds.maxY), CGPoint(x: c.bounds.minX, y: c.bounds.maxY)]
            let b = extent(corners.map { m.project(measured.restore($0)) })
            guard b.width <= width * 1.3, b.height <= width * 2.2,
                  abs(b.midX - m.rect.midX) <= width * 0.4,
                  max(0, min(b.maxX, m.rect.maxX) - max(b.minX, m.rect.minX)) >= min(b.width, width) * 0.6 else { return nil }
            return Ink(colour: c.colour, bounds: b, points: c.hull.map { m.project(measured.restore($0)) },
                       owned: c.ownedPixels)
        }
        // Palettes are rooted in CURRENT private source ink, not in new probe pixels.
        let roots = m.components.filter { c in
            c.foreignPixels == 0 && c.insidePixels >= 2 &&
                Double(c.ownedPixels) >= max(2, min(8, Double(c.pixels) * 0.04)) &&
                c.bounds.width <= width * 1.3 && c.bounds.height <= width * 2.2 &&
                abs(c.center.x - m.rect.midX) <= width * 0.4
        }
        diagnostics?(["stage": "components", "incoming": measured.components.count, "eligible": ink.count, "roots": roots.count])
        guard !roots.isEmpty else { return [] }
        let reach = min(width * 3, m.rect.height * 0.4)
        var result: [NativeOCRResidualCandidate] = []
        for head in [true, false] where onlyHead == nil || onlyHead == head {
            let edge = head ? m.rect.minY : m.rect.maxY
            let endRoots = roots.filter { head ? $0.bounds.minY <= edge + width : $0.bounds.maxY >= edge - width }
            guard !endRoots.isEmpty else {
                diagnostics?(["stage": "endpoint", "head": head, "rejection": "no-end-roots"]); continue
            }
            var cap = head ? max(edge, endRoots.map(\.bounds.minY).min()!) : min(edge, endRoots.map(\.bounds.maxY).max()!)
            var points: [CGPoint] = []
            var chosen = Set<Int>()
            // Finite closure across measured terminal dots/stem, with original palette
            // roots fixed throughout. No gradual palette drift or unobserved extrapolation.
            for _ in 0..<min(32, ink.count) {
                var changed = false
                for (i, c) in ink.enumerated() where !chosen.contains(i) {
                    let b = c.bounds
                    let outer = head ? b.minY : b.maxY
                    guard head ? outer < cap : outer > cap,
                          b.minY >= m.rect.minY - reach, b.maxY <= m.rect.maxY + reach,
                          endRoots.contains(where: { NativeOCRSourceComponentMeasurements.colourDistance(c.colour, $0.colour) <= 40 })
                    else { continue }
                    let gap = head ? max(0, cap - b.maxY) : max(0, b.minY - cap)
                    guard gap <= width * 0.65 else { continue }
                    // Unowned additions require a shared RF text scope containing
                    // both a rooted glyph and the complete observed terminal hull.
                    let worldPoints = c.points.map(m.restore)
                    let scoped = m.scopes.contains { scope in
                        scope.confidence >= 0.5 && worldPoints.allSatisfy { scope.rect.contains($0) } &&
                            endRoots.contains { scope.rect.contains(m.restore($0.center)) }
                    }
                    guard c.owned >= 2 || scoped, peerAllows(worldPoints) else { continue }
                    cap = head ? min(cap, outer) : max(cap, outer)
                    chosen.insert(i); points += c.points; changed = true
                }
                if !changed { break }
            }
            let growth = head ? edge - cap : cap - edge
            diagnostics?(["stage": "endpoint", "head": head, "selected": chosen.count,
                          "growth": Double(growth), "reach": Double(reach)])
            guard growth >= max(1, m.step), growth <= reach, !points.isEmpty else { continue }
            let padding = min(1.5, m.step * 0.75)
            let polygon = stretched(m, head: head ? -growth - padding : 0, tail: head ? 0 : growth + padding)
            let support = points.map(m.restore)
            guard polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.y >= 0 }),
                  (support + m.guardPoints + m.polygon).allSatisfy({
                      NativeOCRSourceComponentMeasurements.contains(polygon, $0, tolerance: 0.75)
                  }), peerAllows(support) else { continue }
            result.append(.init(key: head ? "terminal-head-palette-gap065-reach3-v1" : "terminal-tail-palette-gap065-reach3-v1",
                                polygon: polygon, supportPoints: support))
        }
        return result
    }

    /// Preserve each original edge's normal coordinate and cyclic ordering. No
    /// rectification or trimming of the incoming accepted source is performed.
    private static func stretched(_ m: Measurement, head: CGFloat, tail: CGFloat) -> [CGPoint] {
        m.polygon.map { world in
            let p = m.project(world), t = (p.y - m.rect.minY) / m.rect.height
            return m.restore(.init(x: p.x, y: p.y + head * (1 - t) + tail * t))
        }
    }

    private static func extent(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        let x0 = points.map(\.x).min() ?? first.x, x1 = points.map(\.x).max() ?? first.x
        let y0 = points.map(\.y).min() ?? first.y, y1 = points.map(\.y).max() ?? first.y
        return .init(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}


/// PROPOSAL ONLY: append to TerminalExtension after the frozen run is certified.
@available(iOS 18.0, *)
extension NativeOCRResidualTerminalExtension {
    /// Input MUST already pass the bank's global source/frame/semantic checks.
    /// Outputs are proposals and MUST pass those checks again before use.
    static func composedCandidates(_ m: Measurement, accepted: [NativeOCRResidualCandidate]) -> [NativeOCRResidualCandidate] {
        let sides = accepted.filter {
            $0.key.hasPrefix("side-envelope-v1-") && $0.consumedIndices.isEmpty && !$0.supportPoints.isEmpty
        }.sorted { $0.key < $1.key }.prefix(24)
        let terminals = ["terminal-head-", "terminal-tail-"].compactMap { prefix in
            accepted.filter { $0.key.hasPrefix(prefix) && $0.consumedIndices.isEmpty && !$0.supportPoints.isEmpty }
                .sorted { $0.key < $1.key }.first
        }
        var result: [NativeOCRResidualCandidate] = []
        for side in sides {
            guard let s = jointBounds(side.polygon.map(m.project)) else { continue }
            for terminal in terminals {
                guard let t = jointBounds(terminal.polygon.map(m.project)) else { continue }
                let top = min(s.minY, t.minY), bottom = max(s.maxY, t.maxY)
                let polygon = [CGPoint(x: s.minX, y: top), CGPoint(x: s.maxX, y: top),
                               CGPoint(x: s.maxX, y: bottom), CGPoint(x: s.minX, y: bottom)].map(m.restore)
                let support = side.supportPoints + terminal.supportPoints
                guard support.allSatisfy({ NativeOCRSourceComponentMeasurements.contains(polygon, $0, tolerance: 0.75) }) else { continue }
                let prefix = terminal.key.hasPrefix("terminal-head-") ? "terminal-head-" : "terminal-tail-"
                let key = prefix + "side-joint-v1|" + side.key + "|" + terminal.key
                guard key.utf8.count <= 160 else { continue }
                result.append(.init(key: key, polygon: polygon, supportPoints: support))
            }
        }
        return result
    }

    /// Add ONLY compositions that passed global safe + semantic admission.
    /// Joint RGB support is evidence for that proposal, never permission to
    /// revoke another previously accepted candidate's eligibility.
    static func completionMenu(_ accepted: [NativeOCRResidualCandidate],
                               acceptedCompositions joints: [NativeOCRResidualCandidate]) -> [NativeOCRResidualCandidate] {
        accepted + joints
    }

    private static func jointBounds(_ points: [CGPoint]) -> CGRect? {
        guard points.count == 4, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              let left = points.map(\.x).min(), let right = points.map(\.x).max(),
              let top = points.map(\.y).min(), let bottom = points.map(\.y).max(), right > left, bottom > top else { return nil }
        return .init(x: left, y: top, width: right - left, height: bottom - top)
    }
}
