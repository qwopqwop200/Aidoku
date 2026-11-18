import CoreGraphics
import Foundation

/// Source color hypotheses use the same 4-bit bins, first-seen ordering and component evidence as the frozen renderer.
/// Dictionary descriptors retain all observer evidence; assigning a display role must not overwrite erasure evidence.
enum NativeSourceColorSampler {
    typealias Payload = [String: Any]

    static func estimate(rgba: [UInt8], width: Int, height: Int, preferredSurfaceKey: Int? = nil,
                         exteriorSurface: [Double]? = nil, inkSeed: [Double]? = nil,
                         minimumInkDistance: Double = 60, ownership: [UInt8]? = nil) -> Payload? {
        guard width >= 8, height >= 8, width <= 4_194_304 / height,
              ownership == nil || ownership?.count == width * height,
              rgba.count == width * height * 4, !Task.isCancelled,
              let observation = Observation(rgba: rgba, width: width, height: height) else { return nil }
        return Estimator(rgba: rgba, width: width, height: height, observation: observation, ownership: ownership)
            .run(surfaceKey: preferredSurfaceKey, exterior: exteriorSurface, seed: inkSeed, minimumDistance: minimumInkDistance)
    }

    /// Styling-only retry: a low-contrast pale fill may have been mistaken for
    /// its chromatic outline. Validate owned fill -> stroke -> exterior rays;
    /// never replace the independently observed backing or infer a pen width.
    static func enclosingPaleRoleRetry(rgba: [UInt8], width: Int, height: Int,
                                      ownership: [UInt8]?, result: Payload?, observationBudget: inout Int, onBudgetBlocked: (() -> Void)? = nil) -> Payload? {
        guard width >= 8, height >= 8, width <= 4_194_304 / height, rgba.count == width * height * 4,
              let ownership, ownership.count == width * height, let result,
              let current = rgb(result["foreground"]), let background = rgb(result["background"]),
              distance(current, background) >= 48 || current.min()! >= 175,
              let confidence = result["confidence"] as? Payload,
              let priorFill = confidence["foreground"] as? NSNumber,
              let priorBackground = confidence["background"] as? NSNumber,
              CFGetTypeID(priorFill) != CFBooleanGetTypeID(), CFGetTypeID(priorBackground) != CFBooleanGetTypeID(),
              priorFill.doubleValue.isFinite, priorBackground.doubleValue.isFinite,
              (0...1).contains(priorFill.doubleValue), (0...1).contains(priorBackground.doubleValue),
              !Task.isCancelled else { return nil }
        let paleCurrent = current.min()! >= 175
        let seed = paleCurrent ? rgb((result["sourceInk"] as? Payload)?["stroke"]) : current
        guard let seed, distance(seed, background) >= 48 else { return nil }
        if !paleCurrent, let stroke = rgb(result["stroke"]), stroke.min()! < 175 { return nil }
        // Charge the extra observation even when its candidate is rejected.
        if observationBudget != .max {
            guard observationBudget >= width * height else { onBudgetBlocked?(); return nil }
            observationBudget -= width * height
        }
        guard let observation = Observation(rgba: rgba, width: width, height: height) else { return nil }
        let estimator = Estimator(rgba: rgba, width: width, height: height, observation: observation, ownership: ownership)
        var owned: [Int: Bin] = [:], order: [Bin] = []
        for i in 0..<(width * height) where ownership[i] != 0 {
            let p = i * 4, key = Int(rgba[p] >> 4) * 256 + Int(rgba[p + 1] >> 4) * 16 + Int(rgba[p + 2] >> 4)
            if owned[key] == nil { let bin = Bin(key: key, order: order.count); owned[key] = bin; order.append(bin) }
            owned[key]!.add(rgba, p)
        }
        let pale = order.filter { bin in
            let color = bin.mean
            // A wrong BG prior must not remove the actual fill before the
            // independently observed rim/exterior hypotheses are tested.
            return bin.count >= 12 && color.min()! >= 175 && color.max()! - color.min()! <= 32
        }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.order < $1.order }
        guard !pale.isEmpty else { return nil }
        let currentAxis = subtract(seed, background), currentLength = dot(currentAxis, currentAxis)
        guard currentLength.isFinite, currentLength > 0 else { return nil }
        let extremes = order.filter { bin in
            let color = bin.mean, delta = subtract(color, background)
            let fraction = dot(delta, currentAxis) / currentLength
            return bin.count >= 6 && fraction >= 1 && fraction <= 2 &&
                (zip(delta, currentAxis).map { abs($0 - fraction * $1) }.max() ?? 0) <= 24
        }.sorted { distance($0.mean, background) != distance($1.mean, background) ?
            distance($0.mean, background) > distance($1.mean, background) : $0.order < $1.order }
        let edge = extremes.first?.mean ?? seed
        // Dominant pale pixels can be photograph/background, not glyph fill.
        // Test a bounded frontier rather than committing to the largest mode.
        // Exterior hypotheses only help validate source roles; never replace BG.
        let rims = observation.bins.filter { (observation.rim[$0.key] ?? 0) >= 6 }
            .sorted { (observation.rim[$0.key] ?? 0) > (observation.rim[$1.key] ?? 0) }
        var exteriors = [background]
        for bin in rims where exteriors.count < 2 && distance(bin.mean, background) <= 64
            && distance(bin.mean, edge) >= 48 && distance(bin.mean, background) > 12 { exteriors.append(bin.mean) }
        var selected: (fill: [Double], edge: [Double], evidence: Payload)?
        var testedModes = 0
        roles: for candidate in pale.prefix(4) {
            let fill = candidate.mean
            guard !paleCurrent || distance(fill, current) <= 12, distance(fill, edge) >= 48 else { continue }
            if let stroke = rgb(result["stroke"]), distance(stroke, paleCurrent ? edge : fill) > 32 { continue }
            guard observedEdgeContact(estimator: estimator, ownership: ownership, width: width, height: height,
                fill: fill, edge: edge) else { continue }
            for exterior in exteriors where distance(fill, exterior) > 12 {
                testedModes += 1
                if var evidence = enclosingCertificate(estimator: estimator, ownership: ownership,
                    width: width, height: height, fill: fill, edge: edge, background: exterior,
                    requiresInteriorStructure: true),
                   (evidence["endpointEvidence"] as? Payload)?["accepted"] as? Bool == true {
                    evidence["roleExteriorHypothesis"] = exterior
                    selected = (fill, edge, evidence); break roles
                }
            }
        }
        if selected == nil {
            var rayWork = Int.max
            var localPairs = 0
            localRoles: for candidate in pale.prefix(4) {
                let fill = candidate.mean
                guard !paleCurrent || distance(fill, current) <= 12 else { continue }
                // A tiny clipping contact must not discard all interior points
                // of a porous lettering component. Dense pale islands still abstain.
                let mask = (0..<(width * height)).map {
                    ownership[$0] != 0 && distance(estimator.color($0), fill) <= 12 ? UInt8(1) : 0
                }
                let members = estimator.components(mask).filter {
                    !$0.boundary && $0.height >= 5 && $0.points.count >= 6 &&
                        ($0.width * 5 <= $0.height * 2 || Double($0.points.count) <= Double($0.area) * 0.65)
                }
                let points = members.flatMap(\.points).filter { i in
                    ownership[i - 1] != 0 && ownership[i + 1] != 0 &&
                        ownership[i - width] != 0 && ownership[i + width] != 0
                }
                guard points.count >= 12 else { continue }
                let near = estimator.nearOwners(mask.map(Int.init), reach: 3).near
                var adjacent: [Int: Bin] = [:], exterior: [Int: Bin] = [:]
                for i in 0..<(width * height) {
                    guard !Task.isCancelled else { return nil }
                    let value = estimator.color(i)
                    let key = Int(rgba[i * 4] >> 4) * 256 + Int(rgba[i * 4 + 1] >> 4) * 16 + Int(rgba[i * 4 + 2] >> 4)
                    if ownership[i] != 0, near[i] > 0, distance(value, fill) >= 48 {
                        if adjacent[key] == nil { adjacent[key] = Bin(key: key, order: adjacent.count) }
                        adjacent[key]!.add(rgba, i * 4)
                    } else if ownership[i] == 0 {
                        if exterior[key] == nil { exterior[key] = Bin(key: key, order: exterior.count) }
                        exterior[key]!.add(rgba, i * 4)
                    }
                }
                func ranked(_ bins: [Int: Bin]) -> [Bin] {
                    bins.values.filter { $0.count >= 6 }.sorted {
                        $0.count != $1.count ? $0.count > $1.count : $0.order < $1.order
                    }
                }
                let allEdges = ranked(adjacent)
                // A prior is an endpoint hypothesis only when the same mode
                // is actually observed next to owned pale pixels.
                var edges: [Bin] = []
                if let anchored = allEdges.filter({ distance($0.mean, seed) <= 12 })
                    .min(by: { distance($0.mean, seed) < distance($1.mean, seed) }) { edges.append(anchored) }
                for bin in allEdges where edges.count < 4 && !edges.contains(where: { $0.key == bin.key }) { edges.append(bin) }
                for observed in edges {
                    // Reserve a fair eight-model slice for each observed edge;
                    // one textured region must not exhaust the whole frontier.
                    let edgePairLimit = Int.max
                    let localEdge = observed.mean
                    // A directly observed plateau can still be an AA mixture.
                    // Do not promote an intermediate BG->prior-edge band to a
                    // source endpoint when its more extreme seed is unobserved.
                    let seedAxis = subtract(seed, background), seedSquared = dot(seedAxis, seedAxis)
                    let delta = subtract(localEdge, background)
                    let fraction = dot(delta, seedAxis) / seedSquared
                    if fraction >= 0.15, fraction < 1,
                       (zip(delta, seedAxis).map { abs($0 - fraction * $1) }.max() ?? 0) <= 24,
                       !endpointObserved(endpointSupport(estimator: estimator, ownership: ownership,
                           width: width, height: height, color: seed, background: background)) { continue }
                    guard distance(fill, localEdge) >= 48,
                          endpointObserved(endpointSupport(estimator: estimator, ownership: ownership,
                            width: width, height: height, color: localEdge, background: background)) else { continue }
                    if let stroke = rgb(result["stroke"]), distance(stroke, paleCurrent ? localEdge : fill) > 32 { continue }
                    var localExteriors = [background]
                    for bin in ranked(exterior) where localExteriors.count < 2 &&
                        distance(bin.mean, background) <= 64 && distance(bin.mean, background) > 12 &&
                        distance(bin.mean, fill) > 12 && distance(bin.mean, localEdge) >= 48 {
                        localExteriors.append(bin.mean)
                    }
                    for localBG in localExteriors where distance(fill, localBG) > 12 &&
                        distance(localEdge, localBG) >= 48 {
                        guard rayWork > 0 else { break localRoles }
                        localPairs += 1
                        if var evidence = ownedInteriorCertificate(estimator: estimator, ownership: ownership,
                            width: width, height: height, points: points, fill: fill, edge: localEdge,
                            background: localBG, remainingRayWork: &rayWork) {
                            evidence["roleExteriorHypothesis"] = localBG
                            evidence["localHypothesisPairs"] = localPairs
                            evidence["localRayWorkSpent"] = Int.max - rayWork
                            evidence["localRayWorkLimit"] = NSNull()
                            selected = (fill, localEdge, evidence)
                            break localRoles
                        }
                    }
                    if rayWork > 0, localPairs < 32, var evidence = spatialExteriorCertificate(
                        estimator: estimator, ownership: ownership, width: width, height: height, points: points,
                        nearFill: near, fill: fill, edge: localEdge, background: background,
                        remainingRayWork: &rayWork, hypothesisPairs: &localPairs, hypothesisLimit: edgePairLimit) {
                        evidence["roleExteriorHypothesis"] = NSNull()
                        evidence["localHypothesisPairs"] = localPairs
                        evidence["localRayWorkSpent"] = Int.max - rayWork
                        evidence["localRayWorkLimit"] = NSNull()
                        selected = (fill, localEdge, evidence)
                        break localRoles
                    }
                }
            }
        }
        guard let selected else { return nil }
        let fill = selected.fill
        let selectedEdge = selected.edge
        var evidence = selected.evidence
        evidence["testedModePairs"] = testedModes
        let supported = number(evidence["supported"]), tested = number(evidence["tested"])
        var updated = result, nextConfidence = confidence
        updated["foreground"] = fill; updated["stroke"] = selectedEdge; updated["outline"] = selectedEdge
        // Component-area/perimeter is not a calibrated CoreText pen width.
        updated["widthEvidence"] = NSNull()
        nextConfidence["foreground"] = min(0.85, Double(supported) / Double(tested))
        nextConfidence["stroke"] = nextConfidence["foreground"]
        nextConfidence["reason"] = "owner-local enclosing pale fill and owned source stroke"
        nextConfidence["strokeReason"] = "owned fill to stroke to distinct exterior transitions"
        updated["confidence"] = nextConfidence
        evidence["seedMethod"] = evidence["interiorPointObservation"] as? Bool == true
            ? "owned pale interior points and locally observed edge/exterior modes" : "owned pale and chromatic pixel modes"
        evidence["priorForeground"] = current; evidence["priorStroke"] = result["stroke"] ?? NSNull()
        evidence["priorConfidence"] = confidence
        updated["enclosingRoleEvidence"] = evidence
        return updated
    }


    /// Certify an already observed pair without changing either color role.
    /// Unknown stroke, indistinguishable exterior, and clipped membership abstain.
    static func certifyObservedColorPair(rgba: [UInt8], width: Int, height: Int,
                                         ownership: [UInt8]?, result: Payload?, observationBudget: inout Int, onBudgetBlocked: (() -> Void)? = nil) -> Payload? {
        guard width >= 8, height >= 8, width <= 4_194_304 / height, rgba.count == width * height * 4,
              let ownership, ownership.count == width * height, let result,
              result["enclosingRoleEvidence"] == nil,
              let fill = rgb(result["foreground"]), let edge = rgb(result["stroke"]),
              let background = rgb(result["background"]), distance(fill, edge) >= 48,
              distance(edge, background) > 12, distance(fill, background) > 12,
              let confidence = result["confidence"] as? Payload,
              number(confidence["foreground"]).isFinite, number(confidence["stroke"]).isFinite,
              number(confidence["foreground"]) >= 0.6, number(confidence["stroke"]) >= 0.6,
              !Task.isCancelled else { return nil }
        if observationBudget != .max {
            guard observationBudget >= width * height else { onBudgetBlocked?(); return nil }
            observationBudget -= width * height
        }
        guard let observation = Observation(rgba: rgba, width: width, height: height) else { return nil }
        let estimator = Estimator(rgba: rgba, width: width, height: height, observation: observation, ownership: ownership)
        // A mixed antialias band is not the source stroke endpoint. Reject
        // contradictory owned modes without changing the observed color pair.
        let axis = subtract(edge, background), length = dot(axis, axis)
        guard length.isFinite, length > 0 else { return nil }
        var modes: [Int: Bin] = [:]
        for i in 0..<(width * height) where ownership[i] != 0 {
            guard !Task.isCancelled else { return nil }
            let p = i * 4, key = Int(rgba[p] >> 4) * 256 + Int(rgba[p + 1] >> 4) * 16 + Int(rgba[p + 2] >> 4)
            if modes[key] == nil { modes[key] = Bin(key: key, order: modes.count) }
            modes[key]!.add(rgba, p)
        }
        for mode in modes.values where mode.count >= 6 {
            let delta = subtract(mode.mean, background), fraction = dot(delta, axis) / length
            if fraction > 1, distance(mode.mean, edge) > 12,
               (zip(delta, axis).map { abs($0 - fraction * $1) }.max() ?? 0) <= 12 { return nil }
        }
        guard var evidence = enclosingCertificate(estimator: estimator, ownership: ownership,
            width: width, height: height, fill: fill, edge: edge, background: background,
            requiresInteriorStructure: fill.min()! >= 175) else { return nil }
        evidence["seedMethod"] = "unchanged final observed fill and stroke"
        var updated = result
        updated["enclosingRoleEvidence"] = evidence
        return updated
    }

    /// Recertify an ordered source hypothesis before a later observer drops its
    /// stroke. Confidence is not pixel evidence; this never swaps source roles.
    /// The caller must integrate this certificate explicitly at final sampling.
    static func certifySourceInkHypothesis(rgba: [UInt8], width: Int, height: Int,
        ownership: [UInt8]?, result: Payload?, observationBudget: inout Int,
        onBudgetBlocked: (() -> Void)? = nil) -> Payload? {
        guard width >= 8, height >= 8, width <= 4_194_304 / height, rgba.count == width * height * 4,
              let ownership, ownership.count == width * height, let result,
              let hypothesis = result["sourceInk"] as? Payload,
              result["enclosingRoleEvidence"] == nil,
              let fill = rgb(hypothesis["foreground"]), let edge = rgb(hypothesis["stroke"]),
              let currentFill = rgb(result["foreground"]), distance(currentFill, fill) <= 12,
              let background = rgb(result["background"]), distance(fill, edge) >= 48,
              distance(fill, background) > 12, distance(edge, background) > 12,
              !Task.isCancelled else { return nil }
        if observationBudget != .max {
            guard observationBudget >= width * height else { onBudgetBlocked?(); return nil }
            observationBudget -= width * height
        }
        guard let observation = Observation(rgba: rgba, width: width, height: height) else { return nil }
        let estimator = Estimator(rgba: rgba, width: width, height: height, observation: observation, ownership: ownership)
        let mask = ownership.indices.map { ownership[$0] != 0 && rgba[$0 * 4 + 3] >= 250
            && distance(estimator.color($0), fill) <= 12 ? 1 : 0 }
        let eligible = estimator.components(mask.map { UInt8($0) }).filter { component in
            component.points.count >= 6 && component.height >= 5 &&
                (component.width <= max(3, component.height / 4) ||
                 Double(component.points.count) <= Double(component.area) * 0.65)
        }.flatMap(\.points).sorted()
        let points = eligible.filter { i in
            mask[i] != 0 && i / width > 0 && i / width < height - 1 && i % width > 0 && i % width < width - 1
                && ownership[i - 1] != 0 && ownership[i + 1] != 0
                && ownership[i - width] != 0 && ownership[i + width] != 0
        }
        guard points.count >= 12, !Task.isCancelled else { return nil }
        var work = Int.max, pairs = 0
        var certificate = ownedInteriorCertificate(estimator: estimator, ownership: ownership,
            width: width, height: height, points: points, fill: fill, edge: edge,
            background: background, remainingRayWork: &work, requireDirectEdge: true)
        if certificate == nil {
            certificate = spatialExteriorCertificate(estimator: estimator, ownership: ownership,
                width: width, height: height, points: points, nearFill: estimator.nearOwners(mask, reach: 3).near,
                fill: fill, edge: edge, background: background, remainingRayWork: &work,
                hypothesisPairs: &pairs, hypothesisLimit: .max, requireDirectEdge: true)
        }
        guard var certificate, !Task.isCancelled,
              (certificate["endpointEvidence"] as? Payload)?["accepted"] as? Bool == true else { return nil }
        certificate["seedMethod"] = "ordered sourceInk hypothesis; independent final pixel recertification"
        certificate["candidateModesAttempted"] = pairs
        certificate["totalRaySteps"] = Int.max - work
        var updated = result
        // Keep the final foreground and backing exactly unchanged. No source
        // width is inferred from these directional color certificates.
        updated["stroke"] = hypothesis["stroke"]
        updated["outline"] = hypothesis["stroke"]
        updated["widthEvidence"] = NSNull()
        updated["enclosingRoleEvidence"] = certificate
        return updated
    }

    /// A separate, explicitly uncalibrated forecast, never a verified style or
    /// enclosure certificate. Does not mutate any final role or source record.
    static func supportedOriginalStrokeForecast(rgba: [UInt8], width: Int, height: Int,
        ownership: [UInt8]?, result: Payload?, independentObserverAbstained: Bool) -> Payload? {
        let bandMethod = "outer stroke boundary distance to validated ink; external Manhattan band"
        guard independentObserverAbstained, width >= 8, height >= 8, width <= 4_194_304 / height,
              rgba.count == width * height * 4, let ownership, ownership.count == width * height,
              let result, rgb(result["stroke"]) == nil, result["enclosingRoleEvidence"] == nil,
              let raw = result["sourceInk"] as? Payload,
              let fill = rgb(raw["foreground"]), let edge = rgb(raw["stroke"]),
              let finalFill = rgb(result["foreground"]), distance(finalFill, fill) <= 1,
              let bg = rgb(result["background"]), distance(fill, edge) >= 48, distance(edge, bg) > 12,
              let confidence = raw["confidence"] as? Payload,
              let prior = confidence["stroke"] as? NSNumber, CFGetTypeID(prior) != CFBooleanGetTypeID(),
              prior.doubleValue.isFinite, (0.8...1).contains(prior.doubleValue),
              let band = raw["widthEvidence"] as? Payload, band["method"] as? String == bandMethod,
              let ratio = band["relativeToGlyph"] as? NSNumber,
              let glyph = band["glyphPixels"] as? NSNumber, let span = band["samplePixels"] as? NSNumber,
              [ratio, glyph, span].allSatisfy({ CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.isFinite }),
              ratio.doubleValue > 0, ratio.doubleValue <= 0.3, glyph.doubleValue >= 5,
              glyph.doubleValue <= Double(max(width, height)), span.doubleValue > 0, span.doubleValue <= 24,
              abs(span.doubleValue / glyph.doubleValue - ratio.doubleValue) <= 0.01,
              !Task.isCancelled, let observation = Observation(rgba: rgba, width: width, height: height) else { return nil }
        let estimator = Estimator(rgba: rgba, width: width, height: height, observation: observation, ownership: ownership)
        let fillEndpoint = endpointSupport(estimator: estimator, ownership: ownership, width: width, height: height,
            color: fill, background: bg)
        let strokeEndpoint = endpointSupport(estimator: estimator, ownership: ownership, width: width, height: height,
            color: edge, background: bg)
        guard endpointObserved(fillEndpoint), endpointObserved(strokeEndpoint), !Task.isCancelled else { return nil }
        let mask = ownership.indices.map { ownership[$0] != 0 && rgba[$0 * 4 + 3] >= 250
            && distance(estimator.color($0), fill) <= 12 ? UInt8(1) : 0 }
        var owners = [Int](repeating: 0, count: width * height), glyphs = 0
        for component in estimator.components(mask) where component.points.count >= 6 && component.height >= 5 {
            // A solid pale photo island cannot borrow glyph band provenance.
            guard component.width <= max(3, component.height / 4) ||
                Double(component.points.count) <= Double(component.area) * 0.65 else { continue }
            glyphs += 1
            for i in component.points { owners[i] = glyphs }
        }
        guard glyphs >= 2, !Task.isCancelled else { return nil }
        let reach = min(24, max(6, Int(ceil(min(Double(max(width, height)), glyph.doubleValue) * 0.8))))
        let nearest = estimator.nearOwners(owners, reach: reach)
        let strokeMask = ownership.indices.map { ownership[$0] != 0 && rgba[$0 * 4 + 3] >= 250 && mask[$0] == 0
            && distance(estimator.color($0), edge) <= 12 ? UInt8(1) : 0 }
        var supportedOwners: Set<Int> = [], supportedPixels = 0, supportedBands = 0
        for component in estimator.components(strokeMask) where component.points.count >= 6 {
            guard !Task.isCancelled else { return nil }
            var outer: [Int] = [], localOwners: Set<Int> = []
            for i in component.points {
                if nearest.owner[i] != 0 { localOwners.insert(nearest.owner[i]) }
                if estimator.neighbors(i).contains(where: { strokeMask[$0] == 0 && mask[$0] == 0 &&
                    rgba[$0 * 4 + 3] >= 250 && distance(estimator.color($0), bg) <= 32 }) {
                    outer.append(nearest.near[i] != 0 ? nearest.near[i] - 1 : reach + 1)
                }
            }
            guard outer.count >= 4, !localOwners.isEmpty else { continue }
            outer.sort()
            let median = outer[outer.count / 2], p90 = outer[Int(floor(Double(outer.count - 1) * 0.9))]
            guard Double(median) <= max(2, ceil(glyph.doubleValue * 0.3)),
                  Double(p90) <= max(3, ceil(glyph.doubleValue * 0.45)) else { continue }
            supportedPixels += component.points.count; supportedBands += 1; supportedOwners.formUnion(localOwners)
        }
        guard supportedPixels >= 6, supportedOwners.count >= 2, !Task.isCancelled else { return nil }
        return ["color": raw["stroke"]!, "sourceForeground": raw["foreground"]!,
            "certified": false, "uncalibrated": true,
            "reason": "source-backed original glyph-following stroke forecast; independent enclosure observer abstained; uncalibrated",
            "sourceBandMethod": bandMethod, "rawBandEvidence": band, "sourceWidthCalibrated": false,
            "supportedGlyphs": supportedOwners.count, "supportedBands": supportedBands, "supportedStrokePixels": supportedPixels,
            "endpointEvidence": ["fill": fillEndpoint, "stroke": strokeEndpoint] as Payload,
            "observerPixels": width * height, "additionalCapturePixels": 0, "candidateModesAttempted": 1]
    }

    /// A body/halo forecast, independent of an observer's proposed foreground.
    /// Connected outside excludes closed counters. This is NOT a BG certificate,
    /// calibrated width, or role accuracy claim; ordered certificates stay strict.
    static func supportedBodyStrokeForecast(rgba: [UInt8], width: Int, height: Int,
        ownership: [UInt8]?, result: Payload?, proposedStroke: [Double]? = nil,
        observationBudget: inout Int) -> Payload? {
        guard width >= 8, height >= 8, width <= 4_194_304 / height,
              rgba.count == width * height * 4, let ownership, ownership.count == width * height,
              let result, rgb(result["stroke"]) == nil, result["enclosingRoleEvidence"] == nil,
              let fill = rgb(result["foreground"]), let background = rgb(result["background"]),
              !Task.isCancelled else { return nil }
        let area = width * height
        if observationBudget != .max {
            guard observationBudget >= area else { return nil }
            observationBudget -= area
        }
        guard let observation = Observation(rgba: rgba, width: width, height: height) else { return nil }
        let estimator = Estimator(rgba: rgba, width: width, height: height, observation: observation, ownership: ownership)
        var candidates: [[Double]] = []
        for value in [rgb((result["sourceInk"] as? Payload)?["stroke"]), proposedStroke] {
            if let value, distance(fill, value) >= 48, distance(value, background) > 12,
               !candidates.contains(where: { distance($0, value) <= 12 }) { candidates.append(value) }
        }
        // No existing stroke hypothesis: derive a bounded observed adjacency
        // frontier, not a white/color preference or a confidence threshold.
        if candidates.isEmpty {
            let fillMask = ownership.indices.map { ownership[$0] != 0 && rgba[$0 * 4 + 3] >= 250 &&
                distance(estimator.color($0), fill) <= 12 ? 1 : 0 }
            let near = estimator.nearOwners(fillMask, reach: 4).near
            var adjacent: [Int: Bin] = [:]
            for i in ownership.indices where ownership[i] != 0 && near[i] > 0 && rgba[i * 4 + 3] >= 250 {
                guard !Task.isCancelled else { return nil }
                let color = estimator.color(i)
                guard distance(fill, color) >= 48, distance(color, background) > 12 else { continue }
                let key = Int(rgba[i * 4] >> 4) * 256 + Int(rgba[i * 4 + 1] >> 4) * 16 + Int(rgba[i * 4 + 2] >> 4)
                if adjacent[key] == nil { adjacent[key] = Bin(key: key, order: adjacent.count) }
                adjacent[key]!.add(rgba, i * 4)
            }
            for bin in adjacent.values.filter({ $0.count >= 6 }).sorted(by: {
                $0.count != $1.count ? $0.count > $1.count : $0.order < $1.order
            }) where candidates.count < 4 && !candidates.contains(where: { distance($0, bin.mean) <= 12 }) {
                candidates.append(rounded(bin.mean))
            }
        }
        var selected: Payload?, work = Int.max, attempted = 0
        for edge in candidates.prefix(4) {
            if attempted > 0 {
                if observationBudget != .max {
                    guard observationBudget >= area else { return nil } // Unchecked alternatives remain ambiguous.
                    observationBudget -= area
                }
            }
            attempted += 1
            guard !Task.isCancelled else { return nil }
            let support = bodyHaloSupport(estimator: estimator, ownership: ownership, width: width, height: height,
                fill: fill, edge: edge, background: background, remainingWork: &work)
            guard var support else { continue }
            if bodyHaloSupport(estimator: estimator, ownership: ownership, width: width, height: height,
                fill: edge, edge: fill, background: background, remainingWork: &work) != nil { return nil }
            guard selected == nil else { return nil }
            support["color"] = edge; support["sourceForeground"] = fill
            selected = support
        }
        guard var selected, !Task.isCancelled else { return nil }
        selected["candidateModesAttempted"] = attempted
        selected["raySteps"] = Int.max - work
        selected["observerPixels"] = area * attempted
        return selected
    }

    private static func bodyHaloSupport(estimator: Estimator, ownership: [UInt8], width: Int, height: Int,
        fill: [Double], edge: [Double], background: [Double], remainingWork: inout Int) -> Payload? {
        guard distance(fill, edge) >= 48, distance(edge, background) > 12 else { return nil }
        let count = width * height
        let fillEndpoint = endpointSupport(estimator: estimator, ownership: ownership, width: width, height: height,
            color: fill, background: background)
        let edgeEndpoint = endpointSupport(estimator: estimator, ownership: ownership, width: width, height: height,
            color: edge, background: background)
        guard endpointObserved(fillEndpoint), endpointObserved(edgeEndpoint) else { return nil }
        let axis = subtract(edge, fill), length = dot(axis, axis)
        var union = [UInt8](repeating: 0, count: count), body = union
        for i in 0..<count where ownership[i] != 0 && estimator.rgba[i * 4 + 3] >= 250 {
            guard !Task.isCancelled else { return nil }
            let color = estimator.color(i), df = distance(color, fill), de = distance(color, edge), db = distance(color, background)
            if df <= 12 { body[i] = 1; union[i] = 1; continue }
            // Direct BG takes precedence over coincident endpoint AA segments.
            if db <= 12 && db + 8 < df && db + 8 < de { continue }
            let delta = subtract(color, fill), fraction = dot(delta, axis) / length
            if de <= 12 || fraction >= 0 && fraction <= 1 &&
                (zip(delta, axis).map { abs($0 - fraction * $1) }.max() ?? 0) <= 12 { union[i] = 1 }
        }
        var outside = [UInt8](repeating: 0, count: count), queue: [Int] = []
        for i in 0..<count where union[i] == 0 && (ownership[i] == 0 || i % width == 0 ||
            i % width == width - 1 || i / width == 0 || i / width == height - 1) {
            outside[i] = 1; queue.append(i)
        }
        var read = 0
        while read < queue.count {
            guard !Task.isCancelled else { return nil }
            let i = queue[read]; read += 1
            for j in estimator.neighbors(i) where union[j] == 0 && outside[j] == 0 { outside[j] = 1; queue.append(j) }
        }
        let members = estimator.components(body).filter { c in
            c.height >= 5 && c.points.count >= 6 &&
                (c.width <= max(3, c.height / 4) || Double(c.points.count) <= Double(c.area) * 0.65)
        }
        guard members.count >= 2 else { return nil }
        var glyphs: Set<Int> = [], cells: Set<Int> = [], bands: [Double] = [], tested = 0
        let directions = [(1,0),(-1,0),(0,1),(0,-1),(1,1),(1,-1),(-1,1),(-1,-1)]
        for (id, component) in members.prefix(32).enumerated() {
            let points = component.points.sorted()
            for offset in stride(from: 0, to: points.count, by: max(1, points.count / 8)) {
                let i = points[offset], x = i % width, y = i / width
                guard x > 0, x + 1 < width, y > 0, y + 1 < height,
                      estimator.neighbors(i).allSatisfy({ ownership[$0] != 0 }) else { continue }
                for (dx,dy) in directions {
                    var crossed = false, edgeStart = 0, direct = false, persistent = 0, band = 0
                    for step in 1...min(48, max(8, component.height)) {
                        guard remainingWork > 0, !Task.isCancelled else { return nil }
                        remainingWork -= 1
                        let xx = x + dx * step, yy = y + dy * step
                        guard xx >= 0, xx < width, yy >= 0, yy < height else { break }
                        let j = yy * width + xx
                        guard ownership[j] != 0, estimator.rgba[j * 4 + 3] >= 250 else { break }
                        if body[j] != 0 {
                            // Fresh halo is required after each body reentry.
                            crossed = false; direct = false; persistent = 0; continue
                        }
                        if union[j] != 0 {
                            if persistent > 0 { break }
                            if !crossed { crossed = true; edgeStart = step }
                            if distance(estimator.color(j), edge) <= 12 { direct = true }
                            continue
                        }
                        guard crossed, direct, outside[j] != 0 else { break }
                        // An intermediate AA mode must not call the farther
                        // actual halo endpoint "exterior". Observe persistence
                        // beyond the endpoint, without extrapolating its RGB.
                        let delta = subtract(estimator.color(j), fill)
                        let fraction = dot(delta, axis) / length
                        if fraction > 1 && distance(estimator.color(j), edge) > 12 &&
                            (zip(delta, axis).map { abs($0 - fraction * $1) }.max() ?? 0) <= 24 { break }
                        if persistent == 0 { band = step - edgeStart }
                        persistent += 1
                        if persistent == 3 {
                            tested += 1
                            if band > 0 && Double(band) <= max(2, Double(component.height) * 0.3) {
                                glyphs.insert(id); cells.insert((y * 8 / height) * 8 + x * 8 / width); bands.append(Double(band))
                            }
                            break
                        }
                    }
                }
            }
        }
        guard glyphs.count >= 2, cells.count >= 2, bands.count >= 6 else { return nil }
        bands.sort()
        return ["certified": false, "uncalibrated": true, "additionalCapturePixels": 0,
            "reason": "independent owned glyph-body to observed halo to persistent connected outside; uncalibrated stroke forecast",
            "sourceBandMethod": "owned glyph-body external halo; closed counters excluded; paired orientation checked",
            "supportedGlyphs": glyphs.count, "spatialCells": cells.count, "supportedBands": bands.count,
            "testedPersistentExits": tested, "medianSampleBand": bands[bands.count / 2],
            "endpointEvidence": ["fill": fillEndpoint, "stroke": edgeEndpoint] as Payload,
            "backgroundCertified": false, "sourceWidthCalibrated": false]
    }

    /// Exact pure pixel decision, no observation role or quota changes.
    @inline(__always) fileprivate static func certificatePixelClass(_ value: [Double], fill: [Double],
        edge: [Double], background: [Double], edgeAxis: [Double], edgeLength: Double) -> UInt8 {
        let df = distance(value, fill), de = distance(value, edge), db = distance(value, background)
        if df <= 12 { return 1 }
        if db <= 12 && db + 8 < df && db + 8 < de { return 3 }
        let delta = subtract(value, background), fraction = dot(delta, edgeAxis) / edgeLength
        let mixedEdge = fraction >= 0.15 && fraction <= 1.1 &&
            (zip(delta, edgeAxis).map { abs($0 - fraction * $1) }.max() ?? 0) <= 24
        // The other side of an outlined stroke blends with fill, not BG.
        // Observe both color segments without inventing/extrapolating RGB.
        let fillAxis = subtract(edge, fill), fillLength = dot(fillAxis, fillAxis)
        let fillDelta = subtract(value, fill)
        let fillFraction = fillLength > 0 ? dot(fillDelta, fillAxis) / fillLength : -1
        let mixedFillEdge = fillFraction >= 0.15 && fillFraction <= 1.1 &&
            (zip(fillDelta, fillAxis).map { abs($0 - fillFraction * $1) }.max() ?? 0) <= 24
        if mixedEdge || mixedFillEdge || (de <= 32 && de + 8 < df && de + 8 < db) { return 2 }
        return 4
    }

    private static func observedEdgeContact(estimator: Estimator, ownership: [UInt8],
        width: Int, height: Int, fill: [Double], edge: [Double]) -> Bool {
        var contacts = 0
        for i in 0..<(width * height) where ownership[i] != 0 && distance(estimator.color(i), edge) <= 12 {
            guard !Task.isCancelled else { return false }
            let x = i % width, y = i / width
            var touches = false
            for yy in max(0, y - 3)...min(height - 1, y + 3) {
                for xx in max(0, x - 3)...min(width - 1, x + 3) {
                    let next = yy * width + xx
                    if ownership[next] != 0, distance(estimator.color(next), fill) <= 12 { touches = true; break }
                }
                if touches { break }
            }
            if touches { contacts += 1; if contacts >= 6 { return true } }
        }
        return false
    }

    private static func endpointObserved(_ evidence: Payload) -> Bool {
        let range = (evidence["rgbCubeRange"] as? NSNumber)?.doubleValue
        return number(evidence["pixels"]) >= 6 &&
            (number(evidence["owned2x2Plateaus"]) >= 2 || number(evidence["cubeCornerPixels"]) >= 6 ||
             range.map { $0.isFinite && $0 >= 0 && $0 <= 24 } == true)
    }

    /// Only individually owned interior points vote; spatially separate source
    /// support replaces neither clipping geometry nor any original color endpoint.
    private static func ownedInteriorCertificate(estimator: Estimator, ownership: [UInt8],
        width: Int, height: Int, points: [Int], fill: [Double], edge: [Double], background: [Double],
        remainingRayWork: inout Int, requireDirectEdge: Bool = false) -> Payload? {
        let axis = subtract(edge, background), length = dot(axis, axis)
        guard length.isFinite, length > 0 else { return nil }
        let sampleStride = max(1, Int(ceil(Double(points.count) / 128)))
        let directions = [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)]
        var classes = [UInt8](repeating: 0, count: width * height)
        var cells: [Int: (tested: Int, supported: Int)] = [:]
        var tested = 0, supported = 0, steps = 0, unknown = 0
        for offset in stride(from: 0, to: points.count, by: sampleStride) {
            guard !Task.isCancelled else { return nil }
            let i = points[offset], x = i % width, y = i / width
            var decisive = 0, enclosed = 0
            for (dx, dy) in directions {
                var crossed = false, directEdge = false
                for step in 1...16 {
                    guard remainingRayWork > 0, !Task.isCancelled else { return nil }
                    remainingRayWork -= 1; steps += 1
                    let xx = x + dx * step, yy = y + dy * step
                    if xx < 0 || yy < 0 || xx >= width || yy >= height { break }
                    let next = yy * width + xx
                    if requireDirectEdge && estimator.rgba[next * 4 + 3] < 250 { unknown += 1; break }
                    if classes[next] == 0 {
                        classes[next] = certificatePixelClass(estimator.color(next), fill: fill, edge: edge,
                            background: background, edgeAxis: axis, edgeLength: length)
                    }
                    if classes[next] == 1 {
                        crossed = false; directEdge = false
                        if ownership[next] == 0 { decisive += 1; break }
                    } else if classes[next] == 2 {
                        if ownership[next] == 0 { decisive += 1; break }
                        crossed = true
                        if requireDirectEdge, estimator.rgba[next * 4 + 3] >= 250,
                           distance(estimator.color(next), edge) <= 12 { directEdge = true }
                    } else if classes[next] == 3 {
                        decisive += 1
                        if crossed && (!requireDirectEdge || directEdge) { enclosed += 1 }
                        break
                    } else {
                        // A local proposal cannot skip an unknown inner band
                        // and call a subsequent unrelated outer color stroke.
                        unknown += 1; break
                    }
                }
            }
            if decisive >= 4 {
                let hit = Double(enclosed) >= Double(decisive) * 0.8
                tested += 1; supported += hit ? 1 : 0
                let cell = (y / 32) * ((width + 31) / 32) + x / 32
                let previous = cells[cell] ?? (0, 0)
                cells[cell] = (previous.tested + 1, previous.supported + (hit ? 1 : 0))
            }
        }
        let agreeingCells = cells.filter {
            $0.value.tested >= 6 && Double($0.value.supported) >= Double($0.value.tested) * 0.7
        }.map(\.key)
        let columns = (width + 31) / 32
        let separated = agreeingCells.contains { a in agreeingCells.contains { b in
            abs(a % columns - b % columns) >= 2 || abs(a / columns - b / columns) >= 2
        } }
        let agreeing = agreeingCells.count
        guard separated, agreeing >= 2, tested >= 12, Double(supported) >= Double(tested) * 0.7 else { return nil }
        let fillEndpoint = endpointSupport(estimator: estimator, ownership: ownership, width: width, height: height,
            color: fill, background: background)
        let edgeEndpoint = endpointSupport(estimator: estimator, ownership: ownership, width: width, height: height,
            color: edge, background: background)
        guard endpointObserved(fillEndpoint), endpointObserved(edgeEndpoint), !Task.isCancelled else { return nil }
        return ["accepted": true, "components": agreeing, "spatialCells": agreeing, "tested": tested, "supported": supported,
            "raySteps": steps, "unknownAfterEdge": unknown, "observerPixels": width * height, "additionalCapturePixels": 0,
            "widthObservation": NSNull(), "interiorPointObservation": true,
            "endpointEvidence": ["accepted": true, "fill": fillEndpoint, "stroke": edgeEndpoint,
                "method": "direct owned endpoints; spatial interior rays; no extrapolation"] as Payload]
    }

    /// Disjoint source pixels nominate at most two exteriors per spatial cell.
    /// Unsupported cells remain explicit; their colors never replace backing.
    private static func spatialExteriorCertificate(estimator: Estimator, ownership: [UInt8],
        width: Int, height: Int, points: [Int], nearFill: [Int], fill: [Double], edge: [Double], background: [Double],
        remainingRayWork: inout Int, hypothesisPairs: inout Int, hypothesisLimit: Int,
        requireDirectEdge: Bool = false) -> Payload? {
        let columns = (width + 31) / 32
        var groups: [Int: [Int]] = [:]
        for i in points { groups[(i / width / 32) * columns + i % width / 32, default: []].append(i) }
        let cellKeys = groups.keys.sorted {
            groups[$0]!.count != groups[$1]!.count ? groups[$0]!.count > groups[$1]!.count : $0 < $1
        }.prefix(16)
        let directions = [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)]
        var certified: [Int: (tested: Int, supported: Int, bg: [Double])] = [:]
        var steps = 0, observedCells = 0, allTested = 0, allSupported = 0, unknown = 0
        cellsSearch: for cell in cellKeys {
            guard !Task.isCancelled, remainingRayWork > 0, let members = groups[cell], members.count >= 12 else { continue }
            let left = max(0, (cell % columns) * 32 - 16), right = min(width, (cell % columns + 1) * 32 + 16)
            let top = (cell / columns) * 32, bottom = min(height, top + 32)
            var outside: [Int: Bin] = [:]
            for y in top..<bottom { for x in left..<right {
                let i = y * width + x
                // Unowned does not mean exterior: a clipped outer band can
                // occupy the same pixels. Keep nomination outside fill/edge ROI.
                guard ownership[i] == 0, nearFill[i] == 0 else { continue }
                let value = estimator.color(i)
                guard distance(value, fill) > 12, distance(value, edge) >= 48 else { continue }
                let key = Int(estimator.rgba[i * 4] >> 4) * 256 + Int(estimator.rgba[i * 4 + 1] >> 4) * 16
                    + Int(estimator.rgba[i * 4 + 2] >> 4)
                if outside[key] == nil { outside[key] = Bin(key: key, order: outside.count) }
                outside[key]!.add(estimator.rgba, i * 4)
            } }
            let choices = outside.values.filter { $0.count >= 6 }.sorted {
                $0.count != $1.count ? $0.count > $1.count : $0.order < $1.order
            }.prefix(2).map(\.mean)
            let exteriors = choices.isEmpty ? [background] : choices
            observedCells += 1
            var best: (tested: Int, supported: Int, bg: [Double])?
            for bg in exteriors {
                guard hypothesisPairs < hypothesisLimit, remainingRayWork > 0 else { break cellsSearch }
                hypothesisPairs += 1
                let axis = subtract(edge, bg), length = dot(axis, axis)
                guard length.isFinite, length > 0 else { continue }
                var tested = 0, supported = 0
                let sampleStride = max(1, Int(ceil(Double(members.count) / 32)))
                for offset in stride(from: 0, to: members.count, by: sampleStride) {
                    let i = members[offset], x = i % width, y = i / width
                    var decisive = 0, enclosed = 0
                    for (dx, dy) in directions {
                        var crossed = false, directEdge = false
                        for step in 1...16 {
                            guard remainingRayWork > 0, !Task.isCancelled else { return nil }
                            remainingRayWork -= 1; steps += 1
                            let xx = x + dx * step, yy = y + dy * step
                            if xx < 0 || yy < 0 || xx >= width || yy >= height { break }
                            let next = yy * width + xx
                            if requireDirectEdge && estimator.rgba[next * 4 + 3] < 250 { unknown += 1; break }
                            let label = certificatePixelClass(estimator.color(next), fill: fill, edge: edge,
                                background: bg, edgeAxis: axis, edgeLength: length)
                            if label == 1 {
                                crossed = false; directEdge = false
                                if ownership[next] == 0 { decisive += 1; break }
                            } else if label == 2 {
                                if ownership[next] == 0 { decisive += 1; break }
                                crossed = true
                                if requireDirectEdge, estimator.rgba[next * 4 + 3] >= 250,
                                   distance(estimator.color(next), edge) <= 12 { directEdge = true }
                            } else if label == 3 {
                                decisive += 1
                                if crossed && (!requireDirectEdge || directEdge) { enclosed += 1 }
                                break
                            } else { unknown += 1; break }
                        }
                    }
                    if decisive >= 4 {
                        tested += 1
                        if Double(enclosed) >= Double(decisive) * 0.8 { supported += 1 }
                    }
                }
                if tested >= 6, best == nil ||
                    Double(supported) / Double(tested) > Double(best!.supported) / Double(best!.tested) {
                    best = (tested, supported, bg)
                }
            }
            if let best {
                allTested += best.tested; allSupported += best.supported
                if best.tested >= 6, Double(best.supported) >= Double(best.tested) * 0.7 { certified[cell] = best }
            }
        }
        let keys = certified.keys.sorted()
        let separated = keys.contains { a in keys.contains { b in
            abs(a % columns - b % columns) >= 2 || abs(a / columns - b / columns) >= 2
        } }
        guard separated else { return nil }
        let tested = certified.values.reduce(0) { $0 + $1.tested }
        let supported = certified.values.reduce(0) { $0 + $1.supported }
        guard tested >= 12 else { return nil }
        let fillEndpoint = endpointSupport(estimator: estimator, ownership: ownership, width: width, height: height,
            color: fill, background: background)
        let edgeEndpoint = endpointSupport(estimator: estimator, ownership: ownership, width: width, height: height,
            color: edge, background: background)
        guard endpointObserved(fillEndpoint), endpointObserved(edgeEndpoint), !Task.isCancelled else { return nil }
        return ["accepted": true, "components": keys.count, "spatialCells": keys.count, "tested": tested,
            "supported": supported, "allCellTested": allTested, "allCellSupported": allSupported,
            "observedSpatialCells": observedCells, "raySteps": steps, "unknownAfterEdge": unknown,
            "spatialExteriorHypotheses": keys.map { ["cell": $0, "rgb": certified[$0]!.bg] as Payload },
            "observerPixels": width * height, "additionalCapturePixels": 0, "widthObservation": NSNull(),
            "interiorPointObservation": true, "spatialExteriorObservation": true,
            "modelConditionalSpatialSupport": true,
            "endpointEvidence": ["accepted": true, "fill": fillEndpoint, "stroke": edgeEndpoint,
                "method": "direct owned endpoints; disjoint spatial exteriors; no extrapolation"] as Payload]
    }

    private static func enclosingCertificate(estimator: Estimator, ownership: [UInt8],
                                             width: Int, height: Int, fill: [Double],
                                             edge: [Double], background: [Double],
                                             requiresInteriorStructure: Bool = false) -> Payload? {
        let count = width * height
        let edgeAxis = subtract(edge, background), edgeLength = dot(edgeAxis, edgeAxis)
        guard edgeLength.isFinite, edgeLength > 0 else { return nil }
        let mask = (0..<count).map { ownership[$0] != 0 && distance(estimator.color($0), fill) <= 12 ? UInt8(1) : 0 }
        func ownsInterior(_ component: Component) -> Bool {
            guard !component.boundary else { return false }
            return component.points.allSatisfy { i in
                ownership[i - 1] != 0 && ownership[i + 1] != 0 &&
                    ownership[i - width] != 0 && ownership[i + width] != 0
            }
        }
        // A dense, broad pale island enclosed by colored lettering can be a
        // counter's background, not a glyph fill. Topology alone cannot certify
        // that role; require porous interiors or narrow stems for a role swap.
        let members = estimator.components(mask).filter {
            ownsInterior($0) && $0.points.count >= 6 && $0.height >= 5 &&
                (!requiresInteriorStructure || $0.width * 5 <= $0.height * 2 ||
                 Double($0.points.count) <= Double($0.width * $0.height) * 0.65)
        }
        let observedHeights = members
            .map { Double($0.height) }.sorted()
        guard observedHeights.count >= 2 else { return nil }
        let glyph = observedHeights[Int(floor(Double(observedHeights.count - 1) * 0.75))]
        let reach = min(16, max(4, Int(ceil(glyph * 0.6))))
        let dx = [1, -1, 0, 0, 1, 1, -1, -1], dy = [0, 0, 1, -1, 1, -1, 1, -1]
        // 0 is unevaluated, not unknown observer evidence. One byte per captured pixel.
        // Lifetime is this exact immutable RGB/ownership/color certificate call.
        var pixelClasses = [UInt8](repeating: 0, count: count)
        var components = 0, tested = 0, supported = 0, steps = 0
        for component in members {
            guard !Task.isCancelled else { return nil }
            guard !component.boundary, component.height >= 5, component.points.count >= 6 else { continue }
            var localTested = 0, localSupported = 0
            for i in component.points {
                let x = i % width, y = i / width
                var decisive = 0, enclosed = 0
                for direction in 0..<8 {
                    guard !Task.isCancelled else { return nil }
                    var crossedEdge = false
                    for step in 1...reach {
                        steps += 1
                        let xx = x + dx[direction] * step, yy = y + dy[direction] * step
                        if xx < 0 || yy < 0 || xx >= width || yy >= height { break }
                        let index = yy * width + xx
                        var pixelClass = pixelClasses[index]
                        if pixelClass == 0 {
                            pixelClass = certificatePixelClass(estimator.color(index), fill: fill, edge: edge,
                                background: background, edgeAxis: edgeAxis, edgeLength: edgeLength)
                            pixelClasses[index] = pixelClass
                        }
                        if pixelClass == 1 {
                            // A counter/outline is not fill merely because a ray
                            // can cross ink, then another pale band before BG.
                            // Re-entering another glyph is allowed only if a
                            // fresh enclosing edge is crossed before exterior.
                            // A counter->ink->outer-white-outline->BG path fails.
                            if crossedEdge { crossedEdge = false }
                            if ownership[index] == 0 { decisive += 1; break }
                            continue
                        }
                        if pixelClass == 2 {
                            if ownership[index] == 0 { decisive += 1; break }
                            crossedEdge = true
                        } else if pixelClass == 3 {
                            decisive += 1
                            if crossedEdge { enclosed += 1 }
                            break
                        } else if crossedEdge {
                            // An unclassified third color after the edge does
                            // not prove a fill->stroke->exterior transition.
                            break
                        }
                    }
                }
                if decisive >= 4 {
                    localTested += 1
                    if Double(enclosed) >= Double(decisive) * 0.8 { localSupported += 1 }
                }
            }
            tested += localTested; supported += localSupported
            if localTested >= 6 && Double(localSupported) >= Double(localTested) * 0.7 { components += 1 }
        }
        guard components >= 2, tested >= 12, Double(supported) >= Double(tested) * 0.7 else { return nil }
        let fillEndpoint = endpointSupport(estimator: estimator, ownership: ownership, width: width, height: height,
            color: fill, background: background)
        let strokeEndpoint = endpointSupport(estimator: estimator, ownership: ownership, width: width, height: height,
            color: edge, background: background)
        func observedEndpoint(_ evidence: Payload) -> Bool {
            let range = (evidence["rgbCubeRange"] as? NSNumber)?.doubleValue
            return number(evidence["pixels"]) >= 6 &&
                (number(evidence["owned2x2Plateaus"]) >= 2 || number(evidence["cubeCornerPixels"]) >= 6 ||
                 range.map { $0.isFinite && $0 >= 0 && $0 <= 24 } == true)
        }
        let endpointsAccepted = observedEndpoint(fillEndpoint) && observedEndpoint(strokeEndpoint)
        let endpointEvidence: Payload = ["accepted": endpointsAccepted, "fill": fillEndpoint, "stroke": strokeEndpoint,
            "method": "direct owned modes with plateau or bounded RGB range; observed colors unchanged, no AA inversion"]
        var certificate: Payload = ["accepted": true, "components": components, "tested": tested, "supported": supported,
            "raySteps": steps, "observerPixels": count, "additionalCapturePixels": 0, "widthObservation": NSNull()]
        certificate["endpointEvidence"] = endpointEvidence
        return certificate
    }

    @inline(never)
    private static func endpointSupport(estimator: Estimator, ownership: [UInt8],
                                        width: Int, height: Int, color: [Double], background: [Double]) -> Payload {
        var endpoint = [UInt8](repeating: 0, count: width * height)
        var pixels = 0, plateaus = 0, corners = 0
        for i in endpoint.indices {
            if Task.isCancelled { return ["pixels": 0, "owned2x2Plateaus": 0, "cubeCornerPixels": 0,
                "rgbCubeRange": NSNull(), "tolerance": 12] }
            let observed = estimator.color(i)
            if ownership[i] != 0 && distance(observed, color) <= 12 {
                endpoint[i] = 1; pixels += 1
                if observed.min()! >= 247 || observed.max()! <= 8 { corners += 1 }
            }
        }
        for y in 0..<(height - 1) {
            for x in 0..<(width - 1) {
                let i = y * width + x
                if endpoint[i] != 0 && endpoint[i + 1] != 0 && endpoint[i + width] != 0 && endpoint[i + width + 1] != 0 {
                    plateaus += 1
                }
            }
        }
        // This bounds the nuisance endpoint range under an affine mixture;
        // it never extrapolates or replaces the directly observed RGB mode.
        // The range is model evidence, not natural-image RGB ground truth.
        var extent = Double.infinity, gap = 0.0
        for c in 0..<3 {
            let delta = color[c] - background[c]
            gap = max(gap, abs(delta))
            if delta > 0 { extent = min(extent, (255 - background[c]) / delta) }
            else if delta < 0 { extent = min(extent, background[c] / -delta) }
        }
        let range = extent.isFinite && extent >= 1 ? (extent - 1) * gap : Double.infinity
        return ["pixels": pixels, "owned2x2Plateaus": plateaus, "cubeCornerPixels": corners,
            "rgbCubeRange": range.isFinite ? range as Any : NSNull(), "tolerance": 12]
    }

    static func displayedInk(_ result: Payload?) -> [Double]? {
        // Readability adjustment belongs to the final outline-aware fill-only
        // policy. It must not reassign an outline or backing to the fill role.
        observedDisplayInk(result)
    }

    static func observedDisplayInk(_ result: Payload?) -> [Double]? {
        guard let result else { return nil }
        if let foreground = rgb(result["foreground"]) { return foreground }
        if let value = rgb((result["displayEvidence"] as? Payload)?["color"]) { return value }
        if let value = rgb((result["lettering"] as? Payload)?["color"]) { return value }
        return rgb(result["displayForeground"])
    }

    static func rgb(_ value: Any?) -> [Double]? {
        guard let numbers = value as? [NSNumber], numbers.count == 3 else { return nil }
        let result = numbers.map(\.doubleValue)
        return result.allSatisfy { $0.isFinite && (0...255).contains($0) } ? result : nil
    }
    static func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }
    static func luminance(_ rgb: [Double]) -> Double {
        zip(rgb, [0.2126, 0.7152, 0.0722]).reduce(0) { value, pair in
            let source = pair.0 / 255
            return value + (source <= 0.04045 ? source / 12.92 : pow((source + 0.055) / 1.055, 2.4)) * pair.1
        }
    }
    static func luminanceContrast(_ text: Double, _ low: Double, _ high: Double) -> Double {
        if text >= low, text <= high { return 1 }
        return min((max(text, low) + 0.05) / (min(text, low) + 0.05), (max(text, high) + 0.05) / (min(text, high) + 0.05))
    }
    fileprivate static func subtract(_ lhs: [Double], _ rhs: [Double]) -> [Double] { zip(lhs, rhs).map(-) }
    fileprivate static func dot(_ lhs: [Double], _ rhs: [Double]) -> Double { zip(lhs, rhs).reduce(0) { $0 + $1.0 * $1.1 } }
    /// Preserve max()'s first-value/strict-comparison semantics, including NaN and empty zip.
    @inline(__always) fileprivate static func distance(_ lhs: [Double], _ rhs: [Double]) -> Double {
        var pairs = zip(lhs, rhs).makeIterator()
        guard let first = pairs.next() else { return 0 }
        var greatest = abs(first.0 - first.1)
        while let pair = pairs.next() {
            let value = abs(pair.0 - pair.1)
            if greatest < value { greatest = value }
        }
        return greatest
    }
    fileprivate static func rounded(_ rgb: [Double]) -> [Double] { rgb.map { floor($0 + 0.5) } }

    /// Internal, exactly three channels; no SIMD or reassociated arithmetic.
    fileprivate struct RGB3: RandomAccessCollection {
        let red: Double
        let green: Double
        let blue: Double
        var startIndex: Int { 0 }
        var endIndex: Int { 3 }
        subscript(index: Int) -> Double {
            switch index { case 0: return red; case 1: return green; default: return blue }
        }
        func index(after index: Int) -> Int { index + 1 }
        func index(before index: Int) -> Int { index - 1 }
        func map(_ transform: (Double) -> Double) -> RGB3 {
            RGB3(red: transform(red), green: transform(green), blue: transform(blue))
        }
        func mapPairs(_ rhs: [Double], _ transform: (Double, Double) -> Double) -> RGB3 {
            if rhs.count >= 3 {
                return RGB3(red: transform(red, rhs[0]), green: transform(green, rhs[1]), blue: transform(blue, rhs[2]))
            }
            // Used only for full3-channel subtraction or abs-residual.max() ?? 0.
            // Residual missing channels contribute+0, an identity for nonnegative abs/max;
            // no transform is evaluated for missing channels, preserving shortest zip.
            return RGB3(red: rhs.count > 0 ? transform(red, rhs[0]) : 0,
                        green: rhs.count > 1 ? transform(green, rhs[1]) : 0, blue: 0)
        }
    }
    fileprivate static func subtract(_ lhs: RGB3, _ rhs: [Double]) -> RGB3 {
        lhs.mapPairs(rhs, -)
    }
    fileprivate static func dot(_ lhs: RGB3, _ rhs: [Double]) -> Double {
        zip(lhs, rhs).reduce(0) { $0 + $1.0 * $1.1 }
    }
    fileprivate static func distance(_ lhs: RGB3, _ rhs: [Double]) -> Double {
        var pairs = zip(lhs, rhs).makeIterator()
        guard let first = pairs.next() else { return 0 }
        var greatest = abs(first.0 - first.1)
        while let pair = pairs.next() {
            let value = abs(pair.0 - pair.1)
            if greatest < value { greatest = value }
        }
        return greatest
    }

    fileprivate final class Bin {
        let key: Int
        let order: Int
        var count = 0
        var sums = [Double](repeating: 0, count: 3)
        var mean: [Double] { sums.map { $0 / Double(count) } }
        init(key: Int, order: Int) { self.key = key; self.order = order }
        func add(_ rgba: [UInt8], _ offset: Int) {
            count += 1
            for channel in 0..<3 { sums[channel] += Double(rgba[offset + channel]) }
        }
    }

    fileprivate final class Observation {
        var bins: [Bin] = []
        var byKey: [Int: Bin] = [:]
        var rim: [Int: Int] = [:]
        var rimOrder: [Int] = []
        var rimCount = 0
        init?(rgba: [UInt8], width: Int, height: Int) {
            #if canImport(AidokuOverlayKernels)
            do {
                let counts = try NativeKernelBuffer<Int32>(count: 4_096)
                let sums = try NativeKernelBuffer<Int32>(count: 12_288), order = try NativeKernelBuffer<Int32>(count: 4_096)
                let selected = try NativeTranslationPixelKernels.bins_insideImmutable(
                    rgba: rgba, w: Int32(width), h: Int32(height), counts: counts, sums: sums, order: order)
                guard selected >= 0 else { return nil }
                for index in 0..<Int(selected) {
                    let key = Int(order[index]), bin = Bin(key: key, order: index)
                    bin.count = Int(counts[key]); bin.sums = (0..<3).map { Double(sums[key * 3 + $0]) }
                    bins.append(bin); byKey[key] = bin
                }
            } catch { return nil }
            #endif
            for y in 0..<height {
                for x in 0..<width {
                    let p = (y * width + x) * 4
                    guard rgba[p + 3] >= 250 else { return nil }
                    let key = Int(rgba[p] >> 4) * 256 + Int(rgba[p + 1] >> 4) * 16 + Int(rgba[p + 2] >> 4)
                    #if !canImport(AidokuOverlayKernels)
                    if byKey[key] == nil { let bin = Bin(key: key, order: bins.count); bins.append(bin); byKey[key] = bin }
                    byKey[key]!.add(rgba, p)
                    #endif
                    if y < 2 || y >= height - 2 || x < 2 || x >= width - 2 {
                        if rim[key] == nil { rimOrder.append(key) }
                        rim[key, default: 0] += 1; rimCount += 1
                    }
                }
            }
        }
    }

    fileprivate struct Hole {
        let component: Int
        let count: Int
        let rgb: [Double]
        let foreign: Int
        let compactness: Double
        let interiorWidth: Int
        let interiorHeight: Int
        let glyphHeight: Int
        let band: Double
    }
    fileprivate struct Component {
        var points: [Int]
        var left: Int
        var top: Int
        var right: Int
        var bottom: Int
        var boundary: Bool
        var width: Int { right - left + 1 }
        var height: Int { bottom - top + 1 }
        var area: Int { width * height }
    }

    fileprivate final class Estimator {
        let rgba: [UInt8]
        let width: Int
        let height: Int
        let count: Int
        let observation: Observation
        let ownership: [UInt8]?
        init(rgba: [UInt8], width: Int, height: Int, observation: Observation, ownership: [UInt8]?) {
            self.rgba = rgba; self.width = width; self.height = height; count = width * height
            self.observation = observation; self.ownership = ownership?.count == width * height ? ownership : nil
        }
        func color(_ index: Int) -> [Double] { (0..<3).map { Double(rgba[index * 4 + $0]) } }
        func color3(_ index: Int) -> RGB3 {
            let p = index * 4
            return RGB3(red: Double(rgba[p]), green: Double(rgba[p + 1]), blue: Double(rgba[p + 2]))
        }
        /// Same color(index) -> shortest-zip distance, without its three-Double array.
        @inline(__always) func pixelDistance(_ index: Int, _ rhs: [Double]) -> Double {
            let channels = min(3, rhs.count)
            guard channels > 0 else { return 0 }
            let p = index * 4
            var greatest = abs(Double(rgba[p]) - rhs[0])
            for channel in 1..<channels {
                let value = abs(Double(rgba[p + channel]) - rhs[channel])
                if greatest < value { greatest = value }
            }
            return greatest
        }

        /// Value-only iteration retains left/right/up/down order without a temporary array.
        struct NeighborIndices: Sequence, IteratorProtocol {
            let index: Int
            let width: Int
            let height: Int
            var direction = 0

            func makeIterator() -> Self { self }

            @inline(__always) mutating func next() -> Int? {
                while direction < 4 {
                    let current = direction
                    direction += 1
                    switch current {
                    case 0: if index % width > 0 { return index - 1 }
                    case 1: if index % width + 1 < width { return index + 1 }
                    case 2: if index / width > 0 { return index - width }
                    default: if index / width + 1 < height { return index + width }
                    }
                }
                return nil
            }
        }

        @inline(__always) func neighbors(_ index: Int) -> NeighborIndices {
            NeighborIndices(index: index, width: width, height: height)
        }
        func components(_ mask: [UInt8]) -> [Component] {
            var seen = [UInt8](repeating: 0, count: count), result: [Component] = []
            for start in 0..<count where mask[start] != 0 && seen[start] == 0 {
                var points = [start], read = 0, component = Component(points: [], left: width, top: height, right: 0, bottom: 0, boundary: false)
                seen[start] = 1
                while read < points.count {
                    let i = points[read], x = i % width, y = i / width; read += 1
                    component.left = min(component.left, x); component.right = max(component.right, x)
                    component.top = min(component.top, y); component.bottom = max(component.bottom, y)
                    if x == 0 || y == 0 || x == width - 1 || y == height - 1 { component.boundary = true }
                    for next in neighbors(i) where mask[next] != 0 && seen[next] == 0 { seen[next] = 1; points.append(next) }
                }
                component.points = points; result.append(component)
            }
            return result
        }
        func nearOwners(_ accepted: [Int], reach: Int) -> (near: [Int], owner: [Int]) {
            var near = [Int](repeating: 0, count: count), owners = near, queue: [Int] = []
            for i in 0..<count where accepted[i] != 0 { near[i] = 1; owners[i] = accepted[i]; queue.append(i) }
            var read = 0
            while read < queue.count {
                let i = queue[read]; read += 1
                if near[i] > reach { continue }
                for next in neighbors(i) where near[next] == 0 { near[next] = near[i] + 1; owners[next] = owners[i]; queue.append(next) }
            }
            return (near, owners)
        }

        func run(surfaceKey: Int?, exterior: [Double]?, seed: [Double]?, minimumDistance: Double) -> Payload? {
            if Task.isCancelled { return nil }
            let bins = observation.bins
            guard let key = surfaceKey ?? observation.rimOrder.max(by: {
                observation.rim[$0, default: 0] < observation.rim[$1, default: 0]
            }), let background = observation.byKey[key]?.mean else { return nil }
            func backgroundDistance(_ bin: Bin) -> Double { distance(bin.mean, background) }
            var solidCount = 0, solidRim = 0, candidateCount = 0
            var winner: Bin?
            for bin in bins {
                if backgroundDistance(bin) <= 12 { solidCount += bin.count; solidRim += observation.rim[bin.key, default: 0] }
                if backgroundDistance(bin) >= minimumDistance {
                    candidateCount += bin.count
                    if winner == nil || bin.count > winner!.count { winner = bin }
                }
            }
            let confidence: Payload = ["foreground": 0.0, "background": min(1, Double(solidRim) / Double(observation.rimCount)),
                                       "stroke": 0.0, "reason": "dominant observed rim; no validated glyph yet"]
            let colors: Payload = ["foreground": NSNull(), "background": rounded(background), "stroke": NSNull(),
                                   "outline": NSNull(), "widthEvidence": NSNull(), "confidence": confidence]
            var modes = bins
            if let ownership {
                var owned: [Int: Bin] = [:]; modes = []
                for i in 0..<count where ownership[i] != 0 {
                    let p = i * 4, key = Int(rgba[p] >> 4) * 256 + Int(rgba[p + 1] >> 4) * 16 + Int(rgba[p + 2] >> 4)
                    if owned[key] == nil { let bin = Bin(key: key, order: modes.count); owned[key] = bin; modes.append(bin) }
                    owned[key]!.add(rgba, p)
                }
                candidateCount = modes.filter { backgroundDistance($0) >= minimumDistance }.reduce(0) { $0 + $1.count }
            }
            func resolve(_ original: Payload) -> Payload {
                if seed != nil { return original }
                if rgb(original["foreground"]) == nil, Double(solidCount) >= Double(count) * 0.5,
                   Double(solidRim) >= Double(observation.rimCount) * 0.5 {
                    let stable = Double(solidRim) >= Double(observation.rimCount) * 0.75 && Double(solidCount) >= Double(count) * 0.5
                    let choices = modes.filter { Double($0.count) >= max(3, Double(count) * 0.0005) && backgroundDistance($0) >= (stable ? 24 : 60) }
                        .sorted { $0.count != $1.count ? $0.count > $1.count : $0.order < $1.order }.prefix(32)
                    var seeds: [[Double]] = []
                    for mode in choices {
                        var selected = mode.mean
                        let vector = subtract(selected, background), squared = dot(vector, vector)
                        for bin in choices {
                            let candidate = bin.mean, delta = subtract(candidate, background), factor = dot(delta, vector) / squared
                            if factor >= 1, Double(bin.count) >= max(3, Double(mode.count) * 0.05),
                               zip(delta, vector).map({ abs($0 - factor * $1) }).max() ?? 0 <= 12,
                               distance(candidate, background) > distance(selected, background) { selected = candidate }
                        }
                        if seeds.contains(where: { distance($0, selected) < 24 }) { continue }
                        seeds.append(selected)
                        if var candidate = run(surfaceKey: surfaceKey, exterior: exterior, seed: selected,
                                               minimumDistance: distance(selected, background) < 60 ? 24 : 60),
                           rgb(candidate["foreground"]) != nil,
                           number((candidate["confidence"] as? Payload)?["foreground"]) >= 0.6,
                           rgb(candidate["background"]) == nil || distance(rgb(candidate["background"])!, background) <= 32 {
                            var evidence = candidate["confidence"] as? Payload ?? [:]
                            evidence["reason"] = "independent observed ink mode; " + (evidence["reason"] as? String ?? "")
                            candidate["confidence"] = evidence; return candidate
                        }
                        if seeds.count >= 4 { break }
                    }
                }
                if surfaceKey != nil || rgb(original["foreground"]) != nil { return original }
                guard let dominant = bins.filter({ backgroundDistance($0) >= 60 }).max(by: {
                    $0.count != $1.count ? $0.count < $1.count : $0.order > $1.order
                }), var competing = run(surfaceKey: dominant.key, exterior: background, seed: nil, minimumDistance: 60),
                      rgb(competing["foreground"]) != nil else { return original }
                if let surface = rgb(competing["background"]), distance(surface, dominant.mean) > 32 { return original }
                var evidence = competing["confidence"] as? Payload ?? [:]
                evidence["reason"] = "competing interior surface with validated ink; " + (evidence["reason"] as? String ?? "")
                competing["confidence"] = evidence; return competing
            }
            guard winner != nil, Double(candidateCount) >= max(6, Double(count) * 0.004) else { return resolve(colors) }
            let inkBins = modes.filter { backgroundDistance($0) >= minimumDistance }.sorted {
                backgroundDistance($0) != backgroundDistance($1) ? backgroundDistance($0) > backgroundDistance($1) : $0.order < $1.order
            }
            let target = max(6, Double(candidateCount) * 0.12)
            var tailCount = 0.0, tailSum = [Double](repeating: 0, count: 3)
            for bin in inkBins {
                let take = min(Double(bin.count), target - tailCount)
                for channel in 0..<3 { tailSum[channel] += bin.mean[channel] * take }
                tailCount += take; if tailCount >= target { break }
            }
            let seedColor = seed ?? tailSum.map { $0 / tailCount }, direction = subtract(seedColor, background)
            let squared = dot(direction, direction)
            var mask = [UInt8](repeating: 0, count: count), core = mask, selected = 0, aligned = 0
            for i in 0..<count {
                let value = color3(i), delta = subtract(value, background), factor = dot(delta, direction) / squared
                if delta.map(abs).max() ?? 0 < minimumDistance || factor < 0.15 || factor > 1.2 ||
                    delta.mapPairs(direction, { abs($0 - factor * $1) }).max() ?? 0 > 24 { continue }
                mask[i] = 1; aligned += 1
                if distance(value, seedColor) <= 24 { core[i] = 1; selected += 1 }
            }
            guard selected >= 3 else { return resolve(colors) }
            var accepted = [Int](repeating: 0, count: count), closed = [UInt8](repeating: 0, count: count)
            var glyphHeights: [Int] = [], holes: [Hole] = [], fillBudget = count
            var sum = [Double](repeating: 0, count: 3), coreCount = 0, retained = 0, componentCount = 0
            func addCore(_ i: Int) {
                // This intentionally uses scan-array neighbors, as the oracle does after border components are excluded.
                let neighbors = [i - 1, i + 1, i - width, i + width].reduce(0) { $0 + ($1 >= 0 && $1 < count ? Int(mask[$1]) : 0) }
                if core[i] == 0 || neighbors < 3 { return }
                for channel in 0..<3 { sum[channel] += Double(rgba[i * 4 + channel]) }; coreCount += 1
            }
            for component in components(mask) {
                if component.boundary { continue }
                if let ownership, Double(component.points.filter { ownership[$0] != 0 }.count) < Double(component.points.count) * 0.6 { continue }
                let tail = component.points.count
                if tail < 3 || Double(component.width) > Double(width) * 0.9 || Double(component.height) > Double(height) * 0.9 ||
                    minimumDistance < 60 && max(component.width, component.height) < 5 ||
                    (tail > 12 || minimumDistance < 60) && Double(tail) / Double(component.area) > 0.9 { continue }
                componentCount += 1; retained += tail; glyphHeights.append(component.height)
                for i in component.points { accepted[i] = componentCount }
                if component.area <= fillBudget, component.width >= 3, component.height >= 3 {
                    fillBudget -= component.area
                    var owned = [UInt8](repeating: 0, count: component.area)
                    for i in component.points { owned[(i / width - component.top) * component.width + i % width - component.left] = 1 }
                    var visited = owned.map { _ in UInt8(0) }
                    for start in 0..<component.area where visited[start] == 0 && owned[start] == 0 {
                        var flood = [start], read = 0, open = false; visited[start] = 1
                        while read < flood.count {
                            let i = flood[read], x = i % component.width, y = i / component.width; read += 1
                            if x == 0 || y == 0 || x == component.width - 1 || y == component.height - 1 { open = true }
                            var next: [Int] = []
                            if x > 0 { next.append(i - 1) }; if x + 1 < component.width { next.append(i + 1) }
                            if y > 0 { next.append(i - component.width) }; if y + 1 < component.height { next.append(i + component.width) }
                            for j in next where visited[j] == 0 && owned[j] == 0 { visited[j] = 1; flood.append(j) }
                        }
                        if open { continue }
                        var localBins: [Int: Bin] = [:], localOrder: [Bin] = [], sampled = 0, foreign = 0
                        var left = component.width, top = component.height, right = 0, bottom = 0
                        for point in flood {
                            let x = point % component.width, y = point / component.width
                            let global = (y + component.top) * width + x + component.left
                            if mask[global] != 0 { foreign += 1; continue }
                            let p = global * 4, key = Int(rgba[p] >> 4) * 256 + Int(rgba[p + 1] >> 4) * 16 + Int(rgba[p + 2] >> 4)
                            if localBins[key] == nil { let bin = Bin(key: key, order: localOrder.count); localBins[key] = bin; localOrder.append(bin) }
                            localBins[key]!.add(rgba, p); sampled += 1
                            left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
                        }
                        if sampled >= 2, let mode = localOrder.max(by: { $0.count != $1.count ? $0.count < $1.count : $0.order > $1.order }) {
                            for point in flood {
                                let global = (point / component.width + component.top) * width + point % component.width + component.left
                                if mask[global] == 0 { closed[global] = 1 }
                            }
                            holes.append(Hole(component: component.points[0], count: sampled, rgb: mode.mean, foreign: foreign,
                                compactness: Double(sampled) / Double(max(1, (right - left + 1) * (bottom - top + 1))),
                                interiorWidth: right - left + 1, interiorHeight: bottom - top + 1, glyphHeight: component.height,
                                band: Double(tail) / Double(2 * (component.width + component.height))))
                        }
                    }
                }
                for i in component.points { addCore(i) }
            }
            // Continue with connected-surface, halo, and independent enclosing-fill roles using these exact observations.
            return finish(colors: colors, confidence: confidence, background: background, bins: bins,
                          surfaceKey: surfaceKey, exterior: exterior, resolve: resolve, mask: mask, core: core,
                          accepted: accepted, closed: closed, heights: glyphHeights, holes: holes,
                          sum: sum, coreCount: coreCount, retained: retained, aligned: aligned,
                          componentCount: componentCount, direction: direction, squared: squared,
                          solidCount: solidCount, solidRim: solidRim)
        }

        func finish(colors: Payload, confidence: Payload, background: [Double], bins: [Bin], surfaceKey: Int?, exterior: [Double]?,
                    resolve: (Payload) -> Payload, mask: [UInt8], core: [UInt8], accepted: [Int], closed: [UInt8],
                    heights: [Int], holes: [Hole], sum: [Double], coreCount: Int, retained: Int, aligned: Int,
                    componentCount: Int, direction: [Double], squared: Double, solidCount: Int, solidRim: Int) -> Payload {
            var colors = colors, confidence = confidence, accepted = accepted, heights = heights
            var sum = sum, coreCount = coreCount, retained = retained, aligned = aligned, componentCount = componentCount
            func coreNeighbors(_ i: Int) -> Int {
                [i - 1, i + 1, i - width, i + width].reduce(0) { $0 + ($1 >= 0 && $1 < count ? Int(mask[$1]) : 0) }
            }
            func evidence(_ band: Double, _ glyph: Double, _ method: String) -> Payload {
                ["samplePixels": band, "relativeToGlyph": band / glyph, "glyphPixels": glyph, "method": method]
            }
            func recoverHalo() -> Payload {
                guard surfaceKey != nil, let exterior, componentCount >= 2, coreCount >= 3 else { return colors }
                let sorted = heights.sorted(), glyph = Double(sorted[Int(floor(Double(sorted.count - 1) * 0.75))])
                let reach = min(24, max(6, Int(ceil(glyph * 0.8)))), nearest = nearOwners(accepted, reach: reach)
                var bands: [Double] = [], owners: Set<Int> = [], strokePixels = 0
                let selected = (0..<count).map { accepted[$0] == 0 && closed[$0] == 0 && pixelDistance($0, background) <= 24 ? UInt8(1) : 0 }
                for component in components(selected) {
                    var outer: [Int] = [], localOwners: Set<Int> = []
                    for i in component.points {
                        if nearest.owner[i] != 0 { localOwners.insert(nearest.owner[i]) }
                        if neighbors(i).contains(where: { selected[$0] == 0 && accepted[$0] == 0 && pixelDistance($0, exterior) <= 32 }) {
                            outer.append(nearest.near[i] != 0 ? nearest.near[i] - 1 : reach + 1)
                        }
                    }
                    guard outer.count >= 4, component.points.count >= 6 else { continue }
                    outer.sort(); let median = outer[outer.count / 2], p90 = outer[Int(floor(Double(outer.count - 1) * 0.9))]
                    if Double(median) > max(2, ceil(glyph * 0.3)) || Double(p90) > max(3, ceil(glyph * 0.45)) { continue }
                    strokePixels += component.points.count; bands.append(max(0.5, Double(median) - 0.5)); owners.formUnion(localOwners)
                }
                guard strokePixels >= 6, owners.count >= 2 else { return colors }
                var inkSum = [Double](repeating: 0, count: 3), inkPixels = 0
                for i in 0..<count where core[i] != 0 && owners.contains(accepted[i]) && coreNeighbors(i) >= 3 {
                    for channel in 0..<3 { inkSum[channel] += Double(rgba[i * 4 + channel]) }; inkPixels += 1
                }
                guard inkPixels >= 3 else { return colors }
                let observed = inkSum.map { $0 / Double(inkPixels) }
                guard distance(observed, exterior) > 12 else { return colors }
                bands.sort(); let band = bands[bands.count / 2], stroke = rounded(background)
                return ["foreground": rounded(observed), "background": NSNull(), "stroke": stroke, "outline": stroke,
                    "widthEvidence": evidence(band, glyph, "alternative observed ink with glyph-following halo; exterior surface unverified"),
                    "confidence": ["foreground": min(0.9, 0.5 + Double(owners.count) * 0.08), "background": 0.0,
                        "stroke": min(0.9, 0.5 + Double(owners.count) * 0.08),
                        "reason": "observed glyph fill and following halo; no validated flat exterior surface"]]
            }
            var broadlySupported = false
            if surfaceKey != nil {
                let surfacePixels = bins.filter { distance($0.mean, background) <= 24 }.reduce(0) { $0 + $1.count }
                broadlySupported = surfacePixels > count / 2 && Double(retained) >= Double(aligned) * 0.35 && coreCount >= 3
            }
            if surfaceKey != nil, !broadlySupported {
                guard componentCount >= 2 else { return recoverHalo() }
                let surfaceMask = (0..<count).map { pixelDistance($0, background) <= 32 ? UInt8(1) : 0 }
                let regions = components(surfaceMask)
                var labels = [Int](repeating: 0, count: count)
                for (offset, region) in regions.enumerated() { for i in region.points { labels[i] = offset + 1 } }
                var owners = (0...componentCount).map { _ in Component(points: [], left: width, top: height, right: 0, bottom: 0, boundary: false) }
                for i in 0..<count where accepted[i] != 0 {
                    let id = accepted[i], x = i % width, y = i / width
                    owners[id].points.append(i); owners[id].left = min(owners[id].left, x); owners[id].right = max(owners[id].right, x)
                    owners[id].top = min(owners[id].top, y); owners[id].bottom = max(owners[id].bottom, y)
                }
                var surfaceOwners = (0...regions.count).map { _ in [Int]() }, surfaceInk = [Int](repeating: 0, count: regions.count + 1)
                for id in 1..<owners.count where owners[id].points.count >= 6 {
                    var counts = [Int](repeating: 0, count: regions.count + 1), order: [Int] = []
                    for i in owners[id].points {
                        let x = i % width, y = i / width
                        for yy in max(0, y - 2)...min(height - 1, y + 2) {
                            for xx in max(0, x - 2)...min(width - 1, x + 2) {
                                let label = labels[yy * width + xx]
                                if label != 0 { if counts[label] == 0 { order.append(label) }; counts[label] += 1 }
                            }
                        }
                    }
                    var bestLabel = 0, bestCount = 0
                    for label in order where counts[label] > bestCount { bestLabel = label; bestCount = counts[label] }
                    if bestLabel != 0 { surfaceOwners[bestLabel].append(id); surfaceInk[bestLabel] += owners[id].points.count }
                }
                var best: (label: Int, ink: Int, localAligned: Int, bounds: Component)?
                for label in 1..<surfaceOwners.count where surfaceOwners[label].count >= 2 {
                    var bounds = Component(points: [], left: width, top: height, right: 0, bottom: 0, boundary: false)
                    for id in surfaceOwners[label] {
                        bounds.left = min(bounds.left, owners[id].left); bounds.right = max(bounds.right, owners[id].right)
                        bounds.top = min(bounds.top, owners[id].top); bounds.bottom = max(bounds.bottom, owners[id].bottom)
                    }
                    var supported = 0, localAligned = 0
                    for y in bounds.top...bounds.bottom { for x in bounds.left...bounds.right {
                        let i = y * width + x
                        if labels[i] == label { supported += 1 }; if mask[i] != 0 { localAligned += 1 }
                    } }
                    if Double(supported) <= Double(bounds.area) / 2 || Double(surfaceInk[label]) < Double(localAligned) * 0.35 { continue }
                    if best == nil || surfaceInk[label] > best!.ink { best = (label, surfaceInk[label], localAligned, bounds) }
                }
                guard let best else { return recoverHalo() }
                var extended = 0
                for i in 0..<count where labels[i] == best.label {
                    let x = i % width, y = i / width
                    if x < best.bounds.left - 2 || x > best.bounds.right + 2 || y < best.bounds.top - 2 || y > best.bounds.bottom + 2 { extended += 1 }
                }
                guard Double(extended) >= max(6, Double(regions[best.label - 1].points.count) * 0.2) else { return recoverHalo() }
                let kept = Dictionary(uniqueKeysWithValues: surfaceOwners[best.label].enumerated().map { ($0.element, $0.offset + 1) })
                sum = [Double](repeating: 0, count: 3); coreCount = 0
                for i in 0..<count {
                    accepted[i] = kept[accepted[i], default: 0]
                    if accepted[i] == 0 || core[i] == 0 || coreNeighbors(i) < 3 { continue }
                    for channel in 0..<3 { sum[channel] += Double(rgba[i * 4 + channel]) }; coreCount += 1
                }
                heights = surfaceOwners[best.label].map { owners[$0].height }
                componentCount = surfaceOwners[best.label].count; retained = best.ink; aligned = best.localAligned
            }
            guard componentCount >= 1, Double(retained) >= Double(aligned) * 0.35, coreCount >= 3 else { return resolve(colors) }
            colors["foreground"] = rounded(sum.map { $0 / Double(coreCount) })
            confidence["foreground"] = min(1, Double(retained) / Double(max(1, aligned))) * min(1, Double(componentCount) / 3)
            confidence["reason"] = "observed validated ink components"
            heights.sort(); let glyphHeight = Double(heights[Int(floor(Double(heights.count - 1) * 0.75))])
            var independentSurface = false
            // Local lifetime ends before colors is mutated by stroke selection.
            // Decode only after the original background short-circuit passes.
            var outsideForeground: [Double]?
            func outsideStroke(_ rgb: [Double]) -> Bool {
                guard distance(rgb, background) > 12 else { return false }
                if outsideForeground == nil { outsideForeground = NativeSourceColorSampler.rgb(colors["foreground"])! }
                guard distance(rgb, outsideForeground!) >= 24 else { return false }
                let delta = subtract(rgb, background), factor = dot(delta, direction) / max(1, squared)
                return factor < -0.03 || factor > 1.1 || (zip(delta, direction).map { abs($0 - factor * $1) }.max() ?? 0) > 24
            }
            let strokeBins = bins.filter { $0.count >= 3 && outsideStroke($0.mean) }
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0.order < $1.order }
            if let first = strokeBins.first {
                let strokeSeed = first.mean, reach = min(24, max(6, Int(ceil(glyphHeight * 0.8))))
                let nearest = nearOwners(accepted, reach: reach)
                let strokeMask = (0..<count).map { accepted[$0] == 0 && closed[$0] == 0 &&
                    pixelDistance($0, strokeSeed) <= 24 && outsideStroke(color($0)) ? UInt8(1) : 0 }
                var bands: [Double] = [], strokePixels = 0, strokeOwners: Set<Int> = [], surface: (count: Int, rgb: [Double])?
                for component in components(strokeMask) {
                    if let ownership,
                       Double(component.points.filter { ownership[$0] != 0 }.count) < Double(component.points.count) * 0.6 { continue }
                    var outer: [Int] = [], owners: Set<Int> = []
                    for i in component.points {
                        if nearest.owner[i] != 0 { owners.insert(nearest.owner[i]) }
                        if neighbors(i).contains(where: { strokeMask[$0] == 0 && accepted[$0] == 0 && pixelDistance($0, background) <= 32 }) {
                            outer.append(nearest.near[i] != 0 ? nearest.near[i] - 1 : reach + 1)
                        }
                    }
                    guard outer.count >= 4, component.points.count >= 6 else { continue }
                    outer.sort(); let median = outer[outer.count / 2], p90 = outer[Int(floor(Double(outer.count - 1) * 0.9))]
                    if Double(median) <= max(2, ceil(glyphHeight * 0.30)), Double(p90) <= max(3, ceil(glyphHeight * 0.45)) {
                        strokePixels += component.points.count; bands.append(max(0.5, Double(median) - 0.5)); strokeOwners.formUnion(owners)
                    } else if Double(component.points.count) >= Double(count) * 0.1,
                              surface == nil || component.points.count > surface!.count { surface = (component.points.count, rounded(strokeSeed)) }
                }
                if strokePixels >= 6, strokeOwners.count >= 2 {
                    colors["stroke"] = rounded(strokeSeed); colors["outline"] = colors["stroke"]
                    bands.sort(); let band = bands[bands.count / 2]
                    colors["widthEvidence"] = evidence(band, glyphHeight, "outer stroke boundary distance to validated ink; external Manhattan band")
                    confidence["stroke"] = min(0.9, 0.5 + Double(strokeOwners.count) * 0.08)
                    confidence["reason"] = "observed fill with glyph-following third-color outer band"
                } else if let surface {
                    colors["background"] = surface.rgb; confidence["background"] = 0.8
                    confidence["reason"] = "independent surrounding text surface, not a glyph stroke"; independentSurface = true
                }
            }
            colors["confidence"] = confidence
            if independentSurface { return resolve(colors) }
            // Closed counter islands are not a fill-role observation. Hole
            // dominance cannot distinguish glyph bodies from their counters.
            // Independent final role observers may replace the ink hypothesis.
            if rgb(colors["background"]) == nil, Double(solidRim) >= Double(observation.rimCount) * 0.85,
               Double(solidCount) >= Double(count - retained) * 0.65 { colors["background"] = rounded(background) }
            if let candidate = rgb(colors["stroke"]), confidence["reason"] as? String == "observed fill with glyph-following third-color outer band" {
                let surfaceSeed = rgb(colors["foreground"])!
                var inkEnergy = 0.0, surfaceEnergy = 0.0, inkSamples = 0, surfaceSamples = 0
                var candidateMask = [UInt8](repeating: 0, count: count)
                for y in 0..<height { for x in 0..<width {
                    let i = y * width + x, value = color(i), isInk = distance(value, candidate) <= 24, isSurface = distance(value, surfaceSeed) <= 24
                    if isInk { candidateMask[i] = 1 }
                    if x < 2 || y < 2 || x >= width - 2 || y >= height - 2 || !isInk && !isSurface { continue }
                    var energy = 0.0
                    for channel in 0..<3 {
                        var average = 0.0
                        for next in [i - 2, i + 2, i - width * 2, i + width * 2] { average += Double(rgba[next * 4 + channel]) / 4 }
                        energy = max(energy, abs(value[channel] - average))
                    }
                    if isInk { inkEnergy += energy; inkSamples += 1 }; if isSurface { surfaceEnergy += energy; surfaceSamples += 1 }
                } }
                inkEnergy /= Double(max(1, inkSamples)); surfaceEnergy /= Double(max(1, surfaceSamples))
                if inkEnergy >= 12, surfaceEnergy < inkEnergy * 0.6 {
                    var glyphs = 0, inkPixels = 0, left = width, top = height, right = 0, bottom = 0
                    for c in components(candidateMask) {
                        let tail = c.points.count
                        if c.boundary || tail < 9 || Double(c.height) < glyphHeight * 0.5 || c.width > c.height * 3 ||
                            Double(c.width) > Double(width) * 0.9 || Double(c.height) > Double(height) * 0.9 ||
                            Double(tail) / Double(c.area) < 0.15 || tail > 12 && Double(tail) / Double(c.area) > 0.9 { continue }
                        glyphs += 1; inkPixels += tail; left = min(left, c.left); top = min(top, c.top); right = max(right, c.right); bottom = max(bottom, c.bottom)
                    }
                    var beyond = 0
                    for y in 0..<height { for x in 0..<width {
                        if x >= left - 2 && x <= right + 2 && y >= top - 2 && y <= bottom + 2 { continue }
                        if pixelDistance(y * width + x, surfaceSeed) <= 24 { beyond += 1 }
                    } }
                    if glyphs >= 2, inkPixels >= 6, Double(beyond) >= max(6, Double(surfaceSamples) * 0.2) {
                        colors["foreground"] = candidate; colors["background"] = surfaceSeed; colors["stroke"] = NSNull(); colors["outline"] = NSNull()
                        colors["widthEvidence"] = NSNull(); confidence["foreground"] = 0.65; confidence["background"] = 0.5; confidence["stroke"] = 0.0
                        confidence["reason"] = "observed glyph topology and local contrast distinguish the broader source surface"
                    }
                }
            }
            colors["confidence"] = confidence
            let resolved = resolve(colors)
            return surfaceKey == nil ? directionalStroke(resolved) : resolved
        }

        func directionalStroke(_ original: Payload) -> Payload {
            guard let foreground = rgb(original["foreground"]), let stroke = rgb(original["stroke"]), let background = rgb(original["background"]),
                  let widthEvidence = original["widthEvidence"] as? Payload,
                  var confidence = original["confidence"] as? Payload,
                  confidence["reason"] as? String == "observed fill with glyph-following third-color outer band",
                  distance(foreground, background) > 32, distance(stroke, background) > 32 else { return original }
            let mask = (0..<count).map { pixelDistance($0, stroke) <= 24 ? UInt8(1) : 0 }
            let total = mask.reduce(0) { $0 + Int($1) }
            var valid = [UInt8](repeating: 0, count: count), kept = 0, accepted = 0
            for component in components(mask) {
                let tail = component.points.count
                if component.boundary || tail < 3 || Double(component.height) < max(3, number(widthEvidence["glyphPixels"]) * 0.5) ||
                    component.width > component.height * 3 || Double(component.height) >= Double(height) * 0.9 ||
                    Double(tail) / Double(component.area) < 0.15 { continue }
                accepted += 1; kept += tail; for i in component.points { valid[i] = 1 }
            }
            guard accepted >= 2, Double(kept) >= Double(total) * 0.5 else { return original }
            let dx = [1, -1, 0, 0, 1, 1, -1, -1], dy = [0, 0, 1, -1, 1, -1, 1, -1]
            func enclosure(_ selected: [Double], other: [Double], restricted: [UInt8]?) -> (ratio: Double, samples: Int) {
                var sum = 0.0, samples = 0
                // Colors are immutable for this enclosure call; preserve first-hit order.
                var classes = [UInt8](repeating: 0, count: count)
                for i in 0..<count {
                    if restricted != nil && restricted![i] == 0 || pixelDistance(i, selected) > 16 { continue }
                    let x = i % width, y = i / width
                    var ink = 0, surface = 0
                    for direction in 0..<8 {
                        for step in 1...6 {
                            let xx = x + dx[direction] * step, yy = y + dy[direction] * step
                            if xx < 0 || yy < 0 || xx >= width || yy >= height { break }
                            let index = yy * width + xx
                            if classes[index] == 0 {
                                let rgb = color(index), di = distance(rgb, other), db = distance(rgb, background), ds = distance(rgb, selected)
                                if di + 16 < db && di + 16 < ds { classes[index] = 2 }
                                else if db + 16 < di && db + 16 < ds { classes[index] = 3 }
                                else { classes[index] = 1 }
                            }
                            if classes[index] == 2 { ink += 1; break }
                            if classes[index] == 3 { surface += 1; break }
                        }
                    }
                    if ink + surface >= 5 { sum += Double(ink) / Double(ink + surface); samples += 1 }
                }
                return (sum / Double(max(1, samples)), samples)
            }
            let candidate = enclosure(stroke, other: foreground, restricted: valid)
            let current = enclosure(foreground, other: stroke, restricted: nil)
            guard candidate.samples >= 6, current.samples >= 6, candidate.ratio > 0.5, candidate.ratio > current.ratio else { return original }
            var result = original
            result["foreground"] = stroke; result["stroke"] = foreground; result["outline"] = foreground
            confidence["reason"] = "directional enclosure of repeated source ink fragments distinguishes fill from outline"
            confidence["foreground"] = 0.6; confidence["stroke"] = 0.6; result["confidence"] = confidence
            return result
        }
    }
}
