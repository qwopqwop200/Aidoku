import Foundation

/// Frozen 133→198 source-font inference. No pixels, files, labels, Python, or
/// source-size lookup. Source identities affect reference exclusion only.
enum NativeLateSourceFontGraph {
    typealias Matrix = [[Double]]
    typealias Math = NativeSourceFontGraphMath
    static let stages = [133, 138, 139, 142, 144, 148, 159, 161, 164, 175, 177, 179, 181, 182, 184, 189, 193, 196, 198]
    struct Result {
        let values: [Double]
        let stages: [String: [Double]]
    }
    enum Failure: Error { case invalid(String) }
    private struct Optical {
        let records: [[Int]]
        let physics: [Matrix]  // cohort × (shape, quality, area, area-quality) × family
        let optical: [Matrix]  // cohort × family × covariate
        let points: Matrix
        let anchor: [Double]
    }
    private static func fail(_ text: String) -> Failure { .invalid(text) }
    private static func clip(_ x: Double, _ a: Double, _ b: Double) -> Double { min(b, max(a, x)) }
    private static func number(_ d: [String: Any], _ k: String) throws -> Double {
        guard let n = d[k] as? NSNumber, n.doubleValue.isFinite else { throw fail("Missing numeric \(k)") }
        return n.doubleValue
    }
    private static func string(_ d: [String: Any], _ k: String) throws -> String {
        guard let s = d[k] as? String else { throw fail("Missing string \(k)") }
        return s
    }
    private static func dict(_ d: [String: Any], _ k: String) throws -> [String: Any] {
        guard let v = d[k] as? [String: Any] else { throw fail("Missing dictionary \(k)") }
        return v
    }
    private static func vector(_ d: [String: Any], _ k: String) throws -> [Double] {
        guard let v = d[k] as? [Double], v.allSatisfy(\.isFinite) else { throw fail("Missing vector \(k)") }
        return v
    }
    private static func matrix(_ d: [String: Any], _ k: String) throws -> Matrix {
        guard let v = d[k] as? Matrix, let w = v.first?.count,
            v.allSatisfy({ $0.count == w && $0.allSatisfy(\.isFinite) })
        else { throw fail("Missing matrix \(k)") }
        return v
    }
    private static func normalize(_ x: Matrix, _ state: [String: Any]) throws -> Matrix {
        let mean = try vector(state, "mean")
        let std = try vector(state, "std")
        guard std.count == mean.count, std.allSatisfy({ $0 > 0 }), x.allSatisfy({ $0.count == mean.count }) else {
            throw fail("Normalization width")
        }
        return x.map { row in row.indices.map { (row[$0] - mean[$0]) / std[$0] } }
    }
    private static func columns(_ a: Matrix) -> Matrix {
        guard let n = a.first?.count else { return [] }
        return (0..<n).map { j in a.map { $0[j] } }
    }
    private static func medianColumns(_ a: Matrix) -> [Double] { columns(a).map { Math.median($0) } }
    private static func meanColumns(_ a: Matrix) -> [Double] { columns(a).map { Math.mean($0) } }
    private static func float32(_ a: [Double]) -> [Double] { a.map { Double(Float($0)) } }
    private static func logSumExp(_ a: [Double]) -> Double {
        let m = a.max()!
        return m + log(a.reduce(0) { $0 + exp($1 - m) })
    }
    private static func weightedAverage(_ v: [Double], _ w: [Double]) -> Double {
        zip(v, w).reduce(0) { $0 + $1.0 * $1.1 } / w.reduce(0, +)
    }
    private static func decoder(_ grid: [Double], _ mass: [Double], _ kind: String) -> Double {
        if kind == "mode" { return grid[Math.argmax(mass)] }
        if kind == "plateau" {
            let cut = mass.max()! * 0.95
            return Math.mean(grid.indices.filter { mass[$0] >= cut }.map { grid[$0] })
        }
        if kind == "relative-median" { return Math.weightedMedian(grid, zip(mass, grid).map { $0 / $1 }) }
        return weightedAverage(grid, mass.map { pow($0, 4) })
    }
    private static func apply(_ before: [Double], _ prepared: Math.Prepared, _ proposal: [Double], _ p: [String: Any]) throws
        -> [Double]
    {
        Math.apply(
            before, prepared, proposal, weights: Array(repeating: try number(p, "strength"), count: proposal.count),
            clip: try number(p, "clip"), quantum: try number(p, "quantum"))
    }

    static func predict(
        before: [Double], point: [Double], native: Matrix, evidence: Matrix,
        priors: [Double], groups: [String], pageSizes: Matrix, signals: [String: Any],
        models: [String: String], policies: [String: [String: Any]], metadata: [String: Any],
        sourceIDs: [String], access: NativeSourceFontModelAccess,
        returnStages: Bool = false
    ) throws -> Result {
        let n = before.count
        guard point.count == n, priors.count == n, groups.count == n, pageSizes.count == n, sourceIDs.count == n,
            native.count == n, evidence.count == n, native.allSatisfy({ $0.count == 156 }),
            evidence.allSatisfy({ $0.count == 291 }),
            pageSizes.allSatisfy({ $0.count == 2 && $0.allSatisfy { $0.isFinite && $0 > 0 } }),
            [before, point, priors].allSatisfy({ $0.allSatisfy { $0.isFinite && $0 > 0 } }),
            native.allSatisfy({ $0.allSatisfy(\.isFinite) }), evidence.allSatisfy({ $0.allSatisfy(\.isFinite) })
        else { throw fail("Late input dimensions/ranges") }
        if n == 0 { return Result(values: [], stages: [:]) }
        let geometry = try Math.matrix(signals, "geometry128.X")
        let physical = try Math.matrix(signals, "geometry128.physical")
        let paint = try Math.matrix(signals, "paint130")
        let t135 = try Math.matrix(signals, "templates135")
        let t143 = try Math.matrix(signals, "templates143")
        let j147 = try Math.matrix(signals, "joint147")
        let j158 = try Math.matrix(signals, "joint158")
        let t167 = try Math.matrix(signals, "templates167")
        let areas = try Math.matrix(signals, "areas169")
        let sourceStyle = try Math.matrix(signals, "style187")
        let cadence = try Math.matrix(signals, "cadence69")
        for (a, w) in [
            (geometry, 45), (physical, 14), (paint, 40), (t135, 130), (t143, 130), (j147, 48), (j158, 48), (t167, 66),
            (areas, 21), (sourceStyle, 262), (cadence, 122),
        ] {
            guard a.count == n, a.allSatisfy({ $0.count == w && $0.allSatisfy(\.isFinite) }) else {
                throw fail("Late signal width \(w)")
            }
        }
        func ref(_ key: String) throws -> String {
            guard let id = models[key] else { throw fail("Missing late model \(key)") }
            return id
        }
        func predictModel(_ key: String, _ f: Matrix) throws -> [Double] {
            let out = try access.predict(ref(key), f)
            guard out.count == f.count, out.allSatisfy(\.isFinite) else { throw fail("Model result \(key)") }
            return out
        }
        let aliases = metadata["sourceIdentityGroups"] as? [String: String] ?? [:]
        let identities = sourceIDs.map { aliases[$0] ?? $0 }
        var values = before
        var trace: [String: [Double]] = [:]
        var cache: Optical?
        // Local to this estimate; source rows and encoder metadata are immutable.
        // Cohort membership, not page identity or predicted numeric em, is the key.
        var styleCache: (records: [[Int]], latent: Matrix, pooled: [String: Matrix])?
        func measuredStyle(_ records: [[Int]]) throws -> (latent: Matrix, pooled: [String: Matrix]) {
            if let hit = styleCache, hit.records == records { return (hit.latent, hit.pooled) }
            let measured = try styleFeatures(sourceStyle, records, metadata)
            styleCache = (records, measured.latent, measured.pooled)
            return measured
        }
        for stage in stages {
            guard let p = policies[String(stage)] ?? policies["round\(stage)"] else { throw fail("Missing policy \(stage)") }
            let prepared = Math.prepare(before: values, native: native, groups: groups)
            let records = prepared.records
            let old = prepared.old
            if stage == 133 {
                guard try string(p, "mode") == "physical" else { throw fail("Only selected physical 133 policy") }
                var anchors: [Double] = []
                var features: Matrix = []
                for ids in records {
                    let a = Math.median(ids.map { priors[$0] })
                    let z = ids.map { geometry[$0] + paint[$0] }
                    let q = ids.map { i in physical[i] + paint[i][0..<32].map { exp($0) * priors[i] } }
                    let size = Math.pooled(q.map { $0.map { $0 / a } }, [0.2, 0.5, 0.8])
                    features.append(
                        Math.summary(z) + size.map { log(max(0.01, $0)) }
                            + Math.quantiles(ids.map { point[$0] / a }, [0.1, 0.5, 0.9]))
                    anchors.append(a)
                }
                let raw: [Double]
                if p["aggregation"] as? String == "mean" {
                    raw = try predictModel("133", features)
                } else {
                    let trees = try access.trees(ref("133"), features)
                    raw = columns(trees).map { Math.quantile($0, (p["aggregation"] as? NSNumber)?.doubleValue ?? 0.5) }
                }
                values = try apply(values, prepared, raw.indices.map { anchors[$0] * max(0.01, raw[$0]) / 100 }, p)
            } else if [138, 139, 142, 144, 148, 159, 161, 164].contains(stage) {
                var f: Matrix = []
                var grids: Matrix = []
                var bounds = [0]
                for (i, ids) in records.enumerated() {
                    let (dim, app) = signature(
                        ids, stage, priors, point, pageSizes, geometry, physical, paint, stage <= 142 ? t135 : t143,
                        stage == 148 ? j147 : j158)
                    let grid = Math.arange(max(4, old[i] * 0.65), old[i] * 1.4 + 0.25, 0.5)
                    grids.append(grid)
                    for candidate in grid { f.append(float32(dim.map { log(max(1e-6, $0 > 0 ? $0 / candidate : 1)) } + app)) }
                    bounds.append(f.count)
                }
                let raw = try predictModel(stage == 161 ? "159" : String(stage), f).map { max(1e-8, $0) }
                var proposed: [Double] = []
                for i in records.indices {
                    let grid = grids[i]
                    let sigma = try number(p, "priorSigma")
                    var mass = Array(raw[bounds[i]..<bounds[i + 1]])
                    if stage == 161 {
                        let prior = try dict(metadata, "page_prior")
                        let targets = try vector(prior, "targets")
                        let weights = try vector(prior, "weights")
                        let sizes = try matrix(prior, "pageSizes")
                        let kind = try string(p, "pageNormalization")
                        let h = try number(p, "TRAINChosenBandwidth")
                        let beta = try number(p, "priorStrength")
                        func unit(_ s: [Double]) -> Double {
                            kind == "width" ? s[0] : kind == "height" ? s[1] : sqrt(s[0] * s[1])
                        }
                        guard targets.count == weights.count, targets.count == sizes.count else { throw fail("Prior dimensions") }
                        let z = targets.indices.map { log(targets[$0] / unit(sizes[$0])) }
                        let u = unit(pageSizes[records[i][0]])
                        let lp = grid.map { x in
                            logSumExp(z.indices.map { -0.5 * pow((log(x / u) - z[$0]) / h, 2) + log(weights[$0]) })
                        }
                        let peak = lp.max()!
                        let logits = grid.indices.map {
                            log(mass[$0]) + beta * (lp[$0] - peak) - 0.5 * pow(log(grid[$0] / old[i]) / sigma, 2)
                        }
                        let maxLog = logits.max()!
                        mass = logits.map { exp($0 - maxLog) }
                    } else {
                        mass = grid.indices.map { mass[$0] * exp(-0.5 * pow(log(grid[$0] / old[i]) / sigma, 2)) }
                    }
                    proposed.append(decoder(grid, mass, try (p["decoding"] as? String ?? string(p, "decoder"))))
                }
                values = try apply(values, prepared, proposed, p)
            } else if stage == 175 {
                let states = try opticalStates(metadata)
                cache = try makeOptical(
                    records, prepared.anchors, priors, evidence, pageSizes, geometry, paint, t167, areas, cadence, states,
                    predictModel)
                let c = cache!
                let q = c.physics.map { $0[1] }
                let noise = try states.map { try number($0, "OOFNoise") }
                let temperature = try number(p, "shapeTemperature")
                let sigma = try number(p, "consistencySigma")
                let threshold = try number(p, "minimumMatchQuality")
                let bonus = try number(p, "qualityCountBonus")
                var proposed = old
                for i in records.indices {
                    let e = c.physics[i]
                    let logits = (0..<4).map { j -> Double in
                        let valid = e[0][j] > 0 && e[2][j] > 0
                        let ratio = valid ? log(e[0][j] / e[2][j]) : 0
                        let same = valid && e[3][j] > 0.1
                        return temperature * q[i][j] - (same ? 0.5 * pow(ratio / sigma, 2) : 0) - log(noise[j])
                    }
                    let peak = logits.max()!
                    let w = (0..<4).map { q[i][$0] > 0.1 ? exp(logits[$0] - peak) : 0 }
                    if w.reduce(0, +) > 0 && q[i].max()! + bonus * log1p(Double(records[i].count)) >= threshold {
                        proposed[i] =
                            (p["decoder"] as? String) == "median"
                            ? weightedMedian(c.points[i], w) : weightedAverage(c.points[i], w)
                    }
                }
                values = try apply(values, prepared, proposed, p)
            } else if [177, 179, 181, 182, 184, 189, 193].contains(stage) {
                if cache?.records != records {
                    cache = try makeOptical(
                        records, prepared.anchors, priors, evidence, pageSizes, geometry, paint, t167, areas, cadence,
                        opticalStates(metadata), predictModel)
                }
                let c = cache!
                let stack = stackFeatures(c)
                let features = stack.0
                let spread = stack.1
                let q = stack.2
                var proposed = old
                if [177, 179, 181, 182, 184].contains(stage) {
                    let state = try dict(metadata, String(stage))
                    let f = features.indices.map { features[$0] + (stage == 184 ? [log(c.anchor[$0])] : []) }
                    let raw: [Double]
                    if state["logTarget"] as? Bool == true {
                        raw = try predictModel(String(stage), normalize(f, state)).map { exp(clip($0 / 100, -0.5, 0.5)) * 100 }
                    } else {
                        raw = try predictModel(String(stage), state["standardized"] as? Bool == true ? normalize(f, state) : f)
                            .map { max(0.1, $0) }
                    }
                    let maxSpread = try number(p, "maximumExpertLogSpread")
                    let minimum = try number(p, "minimumMatchQuality")
                    let bonus = try number(p, "qualityCountBonus")
                    for i in records.indices
                    where spread[i] <= maxSpread && q[i] + bonus * log1p(Double(records[i].count)) >= minimum {
                        proposed[i] = c.anchor[i] * raw[i] / 100
                    }
                } else {
                    let style = try measuredStyle(records)
                    let base = features.indices.map { features[$0] + [log(c.anchor[$0])] }
                    guard let classPolicy = policies["189"] ?? policies["round189"] else { throw fail("Classifier policy") }
                    let mode = try string(classPolicy, "styleRepresentation")
                    guard let pooled = style.pooled[mode] else { throw fail("Style mode") }
                    let classID = try ref("189")
                    let unsorted = try access.classes(classID)
                    let order = unsorted.indices.sorted { unsorted[$0] < unsorted[$1] }
                    let classes = order.map { unsorted[$0] }
                    let rawProb = try access.proba(classID, base.indices.map { base[$0] + pooled[$0] })
                    guard !classes.isEmpty, rawProb.count == records.count, rawProb.allSatisfy({ $0.count == classes.count })
                    else { throw fail("Class shape") }
                    let probability = rawProb.map { row in order.map { row[$0] } }
                    var mu: [Double] = []
                    if stage == 193 {
                        let state = try dict(metadata, "190")
                        let f = base.indices.map { base[$0] + style.pooled["pca"]![$0] }
                        let raw = try predictModel("190", normalize(f, state))
                        mu = raw.indices.map { c.anchor[$0] * max(0.001, raw[$0]) / 100 }
                    }
                    for i in records.indices {
                        var supported = classes.map { abs(old[i] - $0) }.min()! <= 0.5
                        let logprob = probability[i].map { log(max(1e-12, $0)) }
                        let logits: [Double]
                        if stage == 189 {
                            let sigma = try number(p, "priorSigma")
                            let minimum = try number(p, "minimumSourceProbability")
                            logits = classes.indices.map { logprob[$0] - 0.5 * pow(log(classes[$0] / old[i]) / sigma, 2) }
                            supported = supported && probability[i].max()! >= minimum
                        } else {
                            let good = (0..<4).filter { c.physics[i][0][$0] > 0 && c.physics[i][1][$0] > 0.3 }
                            let v = good.map { c.physics[i][0][$0] }
                            let center = v.isEmpty ? c.anchor[i] : Math.median(v)
                            let sp = v.count >= 2 ? Math.std(v.map { log($0) }) : 0.4
                            let floor = try number(p, "physicalSigmaFloor")
                            let scale = try number(p, "rawReferenceSpreadScale")
                            let qualityScale = try number(p, "sourceMatchQualityScale")
                            let ps = clip(floor + scale * sp + qualityScale * (1 - q[i]), 0.005, 0.4)
                            let temp = try number(p, "classTemperature")
                            let os = try number(p, "previousPriorSigma")
                            let cs = try number(p, "continuousPriorSigma")
                            logits = classes.indices.map { j in
                                logprob[j] / temp - 0.5 * pow(log(classes[j] / center) / ps, 2) - 0.5
                                    * pow(log(classes[j] / old[i]) / os, 2) - 0.5 * pow(log(classes[j] / mu[i]) / cs, 2)
                            }
                            supported = supported && good.count >= 2
                        }
                        if supported {
                            let peak = logits.max()!
                            let mass = logits.map { exp($0 - peak) }
                            let kind = try string(p, "decoder")
                            proposed[i] = kind == "mean" ? weightedAverage(classes, mass) : decoder(classes, mass, kind)
                        }
                    }
                }
                values = try apply(values, prepared, proposed, p)
            } else if stage == 196 {
                let style = try measuredStyle(records)
                let family = sourceStyle.map { row in Math.argmax(Array(row[258..<262])) }
                let em = (0..<n).map { t167[$0][16 * family[$0] + 1] * priors[$0] }
                let proposal = try calibrate(prepared, sourceStyle, style.latent, family, em, identities, metadata, p)
                values = try apply(values, prepared, proposal, p)
            } else if stage == 198 {
                let family = sourceStyle.map { row in Math.argmax(Array(row[258..<262])) }
                let em = (0..<n).map { t167[$0][16 * family[$0] + 1] * priors[$0] }
                let affinities: [(ids: [Int], matrix: Matrix)]
                if let a = signals["pair_affinities"] as? [(ids: [Int], matrix: Matrix)] {
                    affinities = a
                } else if let a = signals["pair_affinities"] as? [[String: Any]] {
                    affinities = try a.map { d in
                        let ids: [Int]
                        if let integers = d["ids"] as? [Int] {
                            ids = integers
                        } else if let numbers = d["ids"] as? [Double],
                            numbers.allSatisfy({ $0.isFinite && $0 >= 0 && $0 < Double(n) && $0.rounded(.towardZero) == $0 })
                        {
                            ids = numbers.map { Int($0) }
                        } else {
                            throw fail("Affinity indices")
                        }
                        return (ids, try matrix(d, "matrix"))
                    }
                } else {
                    throw fail("Missing pair_affinities")
                }
                var covered = Set<Int>()
                for packet in affinities {
                    let ids = packet.ids
                    guard !ids.isEmpty, ids.allSatisfy({ $0 >= 0 && $0 < n }), Set(ids).count == ids.count,
                        covered.isDisjoint(with: ids), Set(ids.map { groups[$0] }).count == 1
                    else { throw fail("Affinity partition") }
                    covered.formUnion(ids)
                    let repaired = try repair(
                        ids.map { values[$0] }, packet.matrix, ids.map { em[$0] }, ids.map { family[$0] },
                        ids.map { sourceStyle[$0][256] }, ids.map { sourceStyle[$0][255] }, p)
                    for (i, row) in ids.enumerated() { values[row] = repaired[i] }
                }
                guard covered.count == n else { throw fail("Incomplete affinity partition") }
            }
            guard values.count == n, values.allSatisfy({ $0.isFinite && $0 > 0 }) else { throw fail("Invalid stage \(stage)") }
            if returnStages { trace["round\(stage)"] = values }
        }
        return Result(values: values, stages: trace)
    }

    private static func weightedMedian(_ v: [Double], _ w: [Double]) -> Double {
        let ids = v.indices.sorted { v[$0] == v[$1] ? $0 < $1 : v[$0] < v[$1] }
        let half = w.reduce(0, +) / 2
        var total = 0.0
        for i in ids {
            total += w[i]
            if total >= half { return v[i] }
        }
        return v[ids.last!]
    }
    private static func signature(
        _ ids: [Int], _ stage: Int, _ priors: [Double], _ point: [Double], _ pages: Matrix,
        _ geometry: Matrix, _ physical: Matrix, _ paint: Matrix, _ templates: Matrix, _ joint: Matrix
    ) -> ([Double], [Double]) {
        var dim: [Double] = []
        var app: [Double] = []
        if stage == 138 {
            for font in 0..<8 {
                dim += Math.pooled(ids.map { i in [0, 1, 2, 12].map { templates[i][font * 16 + $0] * priors[i] } })
                app += Math.pooled(ids.map { i in [3, 4, 5, 13].map { templates[i][font * 16 + $0] } })
                app += Math.pooled(ids.map { i in [6, 7, 8, 9, 10, 11, 14, 15].map { templates[i][font * 16 + $0] } })
            }
            dim += Math.pooled(ids.map { physical[$0] })
            dim += Math.pooled(ids.map { i in paint[i][0..<32].map { exp($0) * priors[i] } })
            app += Math.pooled(ids.map { geometry[$0] })
            app += Math.pooled(ids.map { Array(paint[$0][32...]) })
        } else {
            for font in 0..<8 {
                let v = ids.map { templates[$0][font * 16 + 12] * priors[$0] }
                let q = ids.map { max(0, templates[$0][font * 16 + 13]) }
                let w = q.map { pow($0, 4) + 0.0001 }
                let median = weightedMedian(v, w)
                dim += [median, weightedAverage(v, w)]
                app += [Math.mean(q), Math.median(q), Math.std(v) / max(1, median)]
            }
            let p = medianColumns(ids.map { physical[$0] })
            dim += [0, 3, 6, 7, 8, 9, 11, 12].map { p[$0] }
            let a = medianColumns(ids.map { i in paint[i][0..<32].map { exp($0) * priors[i] } })
            dim += stride(from: 0, to: 32, by: 4).map { a[$0] }
            app += Array(medianColumns(ids.map { geometry[$0] }).dropFirst(14))
            app += medianColumns(ids.map { Array(paint[$0][32...]) })
        }
        dim += Math.quantiles(ids.map { point[$0] }, [0.2, 0.5, 0.8])
        dim += Math.quantiles(ids.map { priors[$0] }, [0.2, 0.5, 0.8])
        app.append(log1p(Double(ids.count)))
        if stage >= 148 {
            dim += Math.pooled(
                ids.map { i in (0..<4).flatMap { font in [0, 1, 5, 6, 7].map { joint[i][font * 12 + $0] * priors[i] } } })
            app += Math.pooled(
                ids.map { i in (0..<4).flatMap { font in [2, 3, 4, 8, 9, 10, 11].map { joint[i][font * 12 + $0] } } })
        }
        let page = pages[ids[0]]
        dim += [page[0], page[1], sqrt(page[0] * page[1])]
        app.append(log(page[0] / page[1]))
        return (dim, app)
    }

    private static func opticalStates(_ metadata: [String: Any]) throws -> [[String: Any]] {
        guard let states = metadata["175"] as? [[String: Any]], states.count == 4 else {
            throw fail("Four optical expert metadata states required")
        }
        return states
    }
    private static func makeOptical(
        _ records: [[Int]], _ fallback: [Double], _ priors: [Double], _ evidence: Matrix,
        _ pages: Matrix, _ geometry: Matrix, _ paint: Matrix, _ templates: Matrix, _ areas: Matrix,
        _ cadence: Matrix, _ states: [[String: Any]],
        _ predict: (String, Matrix) throws -> [Double]
    ) throws -> Optical {
        var physics: [Matrix] = []
        var optical: [Matrix] = []
        var anchors: [Double] = []
        for (cohort, ids) in records.enumerated() {
            var shape: [Double] = []
            var quality: [Double] = []
            var area: [Double] = []
            var areaQ: [Double] = []
            for font in 0..<4 {
                let v = ids.map { templates[$0][font * 16 + 12] * priors[$0] }
                let q = ids.map { max(0, templates[$0][font * 16 + 13]) }
                var good = v.indices.filter { v[$0] > 0 && q[$0] > 0.1 }
                shape.append(good.isEmpty ? 0 : weightedMedian(good.map { v[$0] }, good.map { pow(q[$0], 4) }))
                quality.append(good.isEmpty ? 0 : Math.mean(good.map { q[$0] }))
                let av = ids.map { areas[$0][4 * font] * priors[$0] }
                let aq = ids.map { areas[$0][16 + font] * clip(paint[$0][38] * 5, 0, 1) * clip(paint[$0][36], 0, 1) }
                good = av.indices.filter { av[$0] > 0 && aq[$0] > 0.1 }
                area.append(good.isEmpty ? 0 : weightedMedian(good.map { av[$0] }, good.map { pow(aq[$0], 2) }))
                areaQ.append(good.isEmpty ? 0 : Math.mean(good.map { aq[$0] }))
            }
            let positive = shape.filter { $0 > 0 }
            let anchor = positive.isEmpty ? 1 : Math.median(positive)
            let page = pages[ids[0]]
            anchors.append(positive.isEmpty ? fallback[cohort] : anchor)
            let logratio = (0..<4).map { j in log(clip(shape[j] > 0 && area[j] > 0 ? area[j] / shape[j] : 1, 0.05, 20)) }
            let g = medianColumns(ids.map { geometry[$0] })
            let common = logratio + quality + areaQ + Array(g.dropFirst(14)) + [log1p(Double(ids.count)), log(page[0] / page[1])]
            var dim: [Double] = []
            var confidence: [Double] = []
            for channel in 0..<5 {
                let start = 2 + 24 * channel
                for (offset, qoffset) in [(1, -1), (2, -1), (4, -1), (10, 13), (16, 19)] {
                    let v = ids.map { cadence[$0][start + offset] * priors[$0] }
                    let w = ids.map { i -> Double in
                        if qoffset >= 0 { return max(0, cadence[i][start + qoffset]) }
                        let count = max(1, expm1(evidence[i][146]))
                        return clip(count, 1, 50) * max(0.01, cadence[i][start + 21])
                    }
                    let good = v.indices.filter { v[$0] > 0 && w[$0] > 0.01 }
                    dim.append(good.isEmpty ? 0 : weightedMedian(good.map { v[$0] }, good.map { w[$0] }))
                    confidence +=
                        good.isEmpty ? [0, 0] : [Double(good.count) / Double(ids.count), Math.mean(good.map { w[$0] })]
                }
            }
            for offset in [11, 12, 13] { dim.append(Math.median(ids.map { evidence[$0][146 + offset] * priors[$0] })) }
            let extra =
                confidence + medianColumns(ids.map { Array(evidence[$0][146..<164]) })
                + medianColumns(ids.map { Array(cadence[$0][0..<2]) })
            var fontFeatures: Matrix = []
            for j in 0..<4 {
                let size = max(1, shape[j])
                let base =
                    common + [
                        logratio[j], quality[j], areaQ[j], log(size / anchor), 1 / size, 1 / pow(size, 2), log(size / page[0]),
                        log(size / page[1]),
                    ]
                let ratios = dim.map { log(max(0.01, $0 > 0 ? $0 / max(1, shape[j]) : 1)) }
                fontFeatures.append(base + ratios + dim.map { $0 > 0 ? 1 : 0 } + extra)
            }
            physics.append([shape, quality, area, areaQ])
            optical.append(fontFeatures)
        }
        var points = Array(repeating: Array(repeating: 0.0, count: 4), count: records.count)
        for font in 0..<4 {
            let state = states[font]
            let target = try number(state, "targetScale")
            let raw = try predict("175.\(font)", normalize(optical.map { $0[font] }, state))
            guard target > 0, raw.count == records.count else { throw fail("Optical prediction") }
            for i in records.indices { points[i][font] = physics[i][0][font] * exp(clip(raw[i] / target, -0.5, 0.5)) }
        }
        return Optical(records: records, physics: physics, optical: optical, points: points, anchor: anchors)
    }

    private static func stackFeatures(_ c: Optical) -> (Matrix, [Double], [Double]) {
        var features: Matrix = []
        var spread: [Double] = []
        var quality: [Double] = []
        for i in c.records.indices {
            let e = c.physics[i]
            let anchor = c.anchor[i]
            let valid = (0..<4).map { c.points[i][$0] > 0 && e[1][$0] > 0.3 }
            let relative = (0..<4).map { log(max(0.01, (valid[$0] ? c.points[i][$0] : anchor) / anchor)) }
            var f = relative + valid.map { $0 ? 1.0 : 0.0 } + e[0].map { $0 / anchor } + e[2].map { $0 / anchor } + e[1] + e[3]
            f += [Math.std(relative), relative.max()! - relative.min()!] + medianColumns(c.optical[i])
            features.append(float32(f))
            let good = (0..<4).filter { valid[$0] }
            spread.append(good.count >= 2 ? Math.std(good.map { relative[$0] }) : 10)
            quality.append(e[1].max()!)
        }
        return (features, spread, quality)
    }

    private static func styleFeatures(_ source: Matrix, _ records: [[Int]], _ metadata: [String: Any]) throws -> (
        latent: Matrix, pooled: [String: Matrix]
    ) {
        let encoder = try dict(metadata, "style_encoder")
        let mean = try vector(encoder, "mean")
        let std = try vector(encoder, "std")
        let components = try matrix(encoder, "components")
        let pcaMean = try vector(encoder, "pcaMean")
        let limit = try number(encoder, "clip")
        guard mean.count == 255, std.count == 255, pcaMean.count == 255, std.allSatisfy({ $0 > 0 }), components.count == 32,
            components.allSatisfy({ $0.count == 255 })
        else { throw fail("PCA metadata dimensions") }
        let clipped = source.map { Array($0[0..<255]).map { clip($0, -limit, limit) } }
        let x = clipped.map { row in row.indices.map { (row[$0] - mean[$0]) / std[$0] } }
        // sklearn transform computes X @ components.T - mean @ components.T.
        let projectedMean = components.map { c in zip(pcaMean, c).reduce(0) { $0 + $1.0 * $1.1 } }
        let latent = x.map { row in
            components.enumerated().map { j, c in zip(row, c).reduce(0) { $0 + $1.0 * $1.1 } - projectedMean[j] }
        }
        let supported = source.indices.map { source[$0][255] > 0 }
        let pca = source.indices.map {
            (supported[$0] ? latent[$0] : Array(repeating: 0.0, count: 32)) + Array(source[$0][255...])
        }
        let raw = source.indices.map { clipped[$0] + Array(source[$0][255...]) }
        var pooled: [String: Matrix] = [:]
        for (kind, values) in [("raw", raw), ("pca", pca)] {
            var rows: Matrix = []
            for ids in records {
                let good = ids.filter { supported[$0] }
                if good.isEmpty {
                    rows.append(Array(repeating: 0, count: 2 * values[0].count + 9))
                    continue
                }
                let w = good.map { source[$0][255] * pow(max(0.05, source[$0][256]), 4) }
                let z = good.map { values[$0] }
                let cols = columns(z)
                let average = cols.map { weightedAverage($0, w) }
                let deviation = cols.enumerated().map { j, col in sqrt(weightedAverage(col.map { pow($0 - average[j], 2) }, w)) }
                rows.append(
                    average + deviation + [
                        Double(good.count) / Double(ids.count), Math.mean(ids.map { source[$0][255] }),
                        Math.mean(ids.map { source[$0][256] }), Math.mean(ids.map { source[$0][257] }),
                    ] + meanColumns(ids.map { Array(source[$0][258...]) }) + [log1p(Double(ids.count))])
            }
            pooled[kind] = rows
        }
        return (latent, pooled)
    }

    private static func calibrate(
        _ prepared: Math.Prepared, _ source: Matrix, _ latent: Matrix, _ family: [Int], _ em: [Double],
        _ identities: [String], _ metadata: [String: Any], _ p: [String: Any]
    ) throws -> [Double] {
        let bank = try dict(metadata, "style_bank")
        let bankStyle = try matrix(bank, "style")
        let bankFamily = try vector(bank, "referenceFamily")
        let bankEm = try vector(bank, "measuredEm")
        let ratio = try vector(bank, "calibrationRatio")
        guard let bankGroups = bank["sourceGroup"] as? [String], bankGroups.count == bankStyle.count,
            [bankFamily, bankEm, ratio].allSatisfy({ $0.count == bankStyle.count })
        else { throw fail("TRAIN bank dimensions") }
        let encoder = try dict(metadata, "style_encoder")
        let variance = try vector(encoder, "explainedVariance")
        let dimensions = Int(try number(p, "styleDimensions"))
        let neighbors = Int(try number(p, "neighbors"))
        guard dimensions > 0, dimensions <= 32, variance.count >= dimensions, neighbors > 0, neighbors <= 31,
            bankStyle.allSatisfy({ $0.count >= dimensions }),
            try number(p, "TRAINSourceExcludedDistanceQuantile") == 1
        else { throw fail("Unsupported calibration metadata/policy") }
        let whitening = p["whitening"] as? Bool ?? false
        let sizeWeight = try number(p, "sourceSizeDistanceWeight")
        let power = try number(p, "inverseDistancePower")
        let maximumSpread = try number(p, "maximumCalibrationLogSpread")
        func transform(_ row: [Double]) -> [Double] {
            (0..<dimensions).map { row[$0] / (whitening ? sqrt(max(1e-6, variance[$0])) : 1) }
        }
        let z = latent.map { transform($0) }
        let b = bankStyle.map { transform($0) }
        var points = Array(repeating: 0.0, count: source.count)
        var spread = Array(repeating: 10.0, count: source.count)
        for i in source.indices where source[i][255] > 0 && source[i][256] > 0.3 && em[i] >= 2 {
            var distances: [(Int, Double)] = []
            let a = z[i]
            let aa = a.reduce(0) { $0 + $1 * $1 }
            for j in bankStyle.indices where Int(bankFamily[j]) == family[i] && bankGroups[j] != identities[i] {
                guard bankEm[j] >= 2, ratio[j] > 0.25, ratio[j] < 4 else { throw fail("TRAIN bank range") }
                let bb = b[j].reduce(0) { $0 + $1 * $1 }
                let ab = zip(a, b[j]).reduce(0) { $0 + $1.0 * $1.1 }
                let d = max(0, (aa + bb - 2 * ab) / Double(dimensions)) + sizeWeight * pow(log(em[i] / bankEm[j]), 2)
                distances.append((j, sqrt(d)))
            }
            distances.sort { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }
            var seen = Set<String>()
            var chosen: [(Int, Double)] = []
            for pair in distances where !seen.contains(bankGroups[pair.0]) {
                seen.insert(bankGroups[pair.0])
                chosen.append(pair)
                if chosen.count == neighbors { break }
            }
            if chosen.isEmpty { continue }
            let logs = chosen.map { log(ratio[$0.0]) }
            let weights = chosen.map { 1 / pow(max(0.05, $0.1), power) }
            let center =
                (p["neighborAggregation"] as? String) == "median" ? weightedMedian(logs, weights) : weightedAverage(logs, weights)
            points[i] = em[i] * exp(center)
            let median = Math.median(logs)
            spread[i] = Math.median(logs.map { abs($0 - median) })
        }
        var proposed = prepared.old
        for (i, ids) in prepared.records.enumerated() {
            let good = ids.filter { points[$0] > 0 && spread[$0] <= maximumSpread }
            if !good.isEmpty {
                proposed[i] = weightedMedian(
                    good.map { points[$0] }, good.map { pow(max(0.001, source[$0][256]), 4) * max(0.25, source[$0][255]) })
            }
        }
        return proposed
    }

    private static func repair(
        _ values: [Double], _ affinity: Matrix, _ em: [Double], _ family: [Int], _ quality: [Double], _ support: [Double],
        _ p: [String: Any]
    ) throws -> [Double] {
        let n = values.count
        let minimum = try number(p, "minimum_affinity")
        let span = try number(p, "maximum_scale_ratio")
        let predictionSpan = try number(p, "maximum_prediction_ratio")
        let agreement = try number(p, "minimum_family_agreement")
        let minq = try number(p, "minimum_quality")
        guard affinity.count == n, affinity.allSatisfy({ $0.count == n && $0.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 } })
        else { throw fail("Repair affinity") }
        for i in 0..<n { for j in 0..<i where abs(affinity[i][j] - affinity[j][i]) > 1e-12 { throw fail("Asymmetric affinity") } }
        var cohorts = Set(values).sorted().map { v in values.indices.filter { values[$0] == v } }
        var families: [Int] = []
        var physical: [[Double]] = []
        for ids in cohorts {
            let good = ids.filter { em[$0] >= 2 && quality[$0] >= minq && support[$0] > 0 }
            if good.isEmpty {
                families.append(-1)
                physical.append([0])
                continue
            }
            let w = good.map { pow(quality[$0], 4) * max(0.25, support[$0]) }
            var mass = Array(repeating: 0.0, count: 4)
            for (k, i) in good.enumerated() { mass[family[i]] += w[k] }
            let dominant = Math.argmax(mass)
            if mass[dominant] / mass.reduce(0, +) + 1e-12 < agreement {
                families.append(-1)
                physical.append([0])
                continue
            }
            let select = good.indices.filter { family[good[$0]] == dominant }
            families.append(dominant)
            physical.append([weightedMedian(select.map { em[good[$0]] }, select.map { w[$0] })])
        }
        while cohorts.count > 1 {
            var best: (confidence: Double, ratio: Double, a: Int, b: Int)?
            for a in cohorts.indices {
                for b in cohorts.indices where b > a {
                    if families[a] < 0 || families[a] != families[b] { continue }
                    let scales = physical[a] + physical[b]
                    let scale = scales.max()! / scales.min()!
                    if scale > span + 1e-12 { continue }
                    let ids = cohorts[a] + cohorts[b]
                    let v = ids.map { values[$0] }
                    if v.max()! / v.min()! > predictionSpan + 1e-12 { continue }
                    let confidence = Math.mean(cohorts[a].flatMap { i in cohorts[b].map { affinity[i][$0] } })
                    if confidence < minimum { continue }
                    let canonical = Math.median(v).rounded(.toNearestOrEven)
                    if cohorts.indices.contains(where: {
                        $0 != a && $0 != b && Math.median(cohorts[$0].map { values[$0] }).rounded(.toNearestOrEven) == canonical
                    }) {
                        continue
                    }
                    if best == nil || confidence > best!.confidence || (confidence == best!.confidence && scale < best!.ratio) {
                        best = (confidence, scale, a, b)
                    }
                }
            }
            guard let chosen = best else { break }
            cohorts[chosen.a] += cohorts[chosen.b]
            physical[chosen.a] += physical[chosen.b]
            cohorts.remove(at: chosen.b)
            physical.remove(at: chosen.b)
            families.remove(at: chosen.b)
        }
        var out = values
        for ids in cohorts where Set(ids.map { values[$0] }).count > 1 {
            let v = Math.median(ids.map { values[$0] }).rounded(.toNearestOrEven)
            for i in ids { out[i] = v }
        }
        return out
    }
}
