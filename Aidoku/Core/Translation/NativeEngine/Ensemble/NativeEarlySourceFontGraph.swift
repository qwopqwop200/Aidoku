import Foundation

/// Frozen base56/61 and accepted early ancestry. Only measured source arrays,
/// immutable model references and selected policies enter this graph.
enum NativeEarlySourceFontGraph {
    typealias M = NativeSourceFontGraphMath
    typealias Matrix = [[Double]]
    typealias Affinity = (ids: [Int], matrix: Matrix)
    static let stages = [68, 71, 72, 77, 79, 83, 86, 88, 90, 92, 93, 96, 98, 102, 105, 108, 112]
    struct Result {
        var point: [Double]
        var values: [Double]
        var affinities: [Affinity]
        var stages: [String: [Double]]
    }
    struct Experts {
        var values: Matrix
        var weights: Matrix
        var valid: [[Bool]]
    }

    static func sourceExperts(_ native: Matrix, _ evidence: Matrix, _ masked: Matrix) -> Experts {
        var values = Matrix(), weights = Matrix(), valid = [[Bool]]()
        for i in native.indices {
            let prior = exp(native[i][0]), e = evidence[i]
            var v = [prior], w = [1.0]
            for font in 0..<4 {
                for (factor, score) in [(1, 3), (12, 13)] {
                    v.append(prior * e[164 + font * 16 + factor])
                    w.append(max(0, e[164 + font * 16 + score]))
                }
            }
            for channel in 0..<5 {
                let start = 15 + 33 * channel, offset = native[i][2] >= native[i][1] ? 4 : 0
                for peak in 0..<2 {
                    let index = start + 25 + offset + peak * 2
                    v.append(prior * masked[i][index]); w.append(max(0, masked[i][index + 1]))
                }
            }
            for channel in 0..<4 {
                for font in [0, 2] {
                    for (dim, expected) in [(2, 5), (6, 2)] {
                        let denominator = e[font * 36 + expected]
                        v.append(denominator > 0.05 ? e[233 + channel * 14 + dim] / denominator : 0)
                        w.append(e[233 + channel * 14 + 13] > 0 ? 1 : 0)
                    }
                }
            }
            v += [prior * e[159], prior * max(e[157], e[158])]; w += [1, 1]
            values.append(v); weights.append(w)
            valid.append(v.indices.map { v[$0] > prior * 0.1 && v[$0] < prior * 4 && w[$0] > 0.08 })
        }
        return Experts(values: values, weights: weights, valid: valid)
    }

    static func groupExperts(_ ids: [Int], native: Matrix, evidence: Matrix, masked: Matrix,
                             point: [Double], experts: Experts) -> (Double, [Double]) {
        let prior = ids.map { exp(native[$0][0]) }, anchor = M.median(ids.map { exp(native[$0][0]) })
        var f = [log(anchor), log(Double(ids.count)), log1p(ids.reduce(0) { $0 + expm1(evidence[$1][146]) })]
        f += M.quantiles(ids.map { log(point[$0] / anchor) }, [0.1, 0.5, 0.9])
        f += M.quantiles(prior.map { log($0 / anchor) }, [0.1, 0.5, 0.9])
        for j in experts.values[0].indices {
            let keep = ids.filter { experts.valid[$0][j] }
            let x = keep.map { experts.values[$0][j] / anchor }
            f += x.isEmpty ? [0, 0, 0] : M.quantiles(x, [0.2, 0.5, 0.8])
            f += [Double(keep.count) / Double(ids.count), M.mean(keep.map { experts.weights[$0][j] })]
        }
        f += M.pooled(ids.map { Array(masked[$0][0..<15]) })
        f += M.pooled(ids.map { Array(evidence[$0][146..<164]) })
        return (anchor, f)
    }

    static func scaledFeatures(_ ids: [Int], kind: String, native: Matrix, evidence: Matrix,
                               masked: Matrix, cadence: Matrix, point: [Double], prior: [Double],
                               pageSizes: Matrix, experts: Experts) -> (Double, [Double]) {
        let (anchor, base) = groupExperts(ids, native: native, evidence: evidence, masked: masked, point: point, experts: experts)
        let width = pageSizes[ids[0]][0], height = pageSizes[ids[0]][1]
        let unit: Double
        switch kind {
        case "width": unit = width
        case "height": unit = height
        case "area": unit = sqrt(width * height)
        default: unit = anchor
        }
        let ratio = anchor / unit
        var f = base
        f[0] = log(ratio)
        for j in 3..<9 { f[j] += log(ratio) }
        for j in experts.values[0].indices { for k in (9 + 5 * j)..<(12 + 5 * j) { f[k] *= ratio } }
        var z = ids.map { cadence[$0] }
        for (row, id) in ids.enumerated() {
            for channel in 0..<5 {
                let start = 2 + 24 * channel
                for offset in Array(1..<12) + Array(15..<18) { z[row][start + offset] *= prior[id] / unit }
            }
        }
        return (unit, f + M.summary(z) + [log(width / height)])
    }

    static func rowFeatures(native: Matrix, evidence: Matrix, masked: Matrix, cadence: Matrix,
                            components: [String: Any], neighbors: [String: Any], point: [Double],
                            prior: [Double], groups: [String]) throws -> Matrix {
        let index = try M.vector(components, "indices").map(Int.init)
        let sizes = try M.vector(components, "sizes"), desc = try M.matrix(components, "features")
        let nSizes = try M.vector(neighbors, "sizes"), ratios = try M.matrix(neighbors, "ratios")
        let distances = try M.matrix(neighbors, "distances"), support = try M.matrix(neighbors, "support")
        var glyph = Matrix(repeating: [], count: prior.count)
        for i in prior.indices {
            let ids = index.indices.filter { index[$0] == i }
            if ids.isEmpty { glyph[i] = Array(repeating: 0, count: 622); continue }
            let r = ids.map { id in (0..<3).map { nSizes[id] * ratios[id][$0] / prior[i] } }
            var z = Matrix()
            for (j, id) in ids.enumerated() { z.append(desc[id] + r[j] + Array(distances[id][0..<3])) }
            glyph[i] = M.pooled(z) + [log1p(Double(ids.count))]
            glyph[i] += M.quantiles(ids.map { sizes[$0] / prior[i] }, [0.1, 0.5, 0.9])
            for j in 0..<3 { glyph[i].append(M.median(ids.map { support[$0][j] })) }
            for j in 0..<3 { glyph[i].append(M.std(r.map { $0[j] })) }
        }
        var contexts = Matrix(repeating: [], count: prior.count)
        for ids in M.groupRows(groups) {
            let rows = ids.map { i in [log(prior[i]), log(point[i])] + Array(native[i][1..<3])
                + Array(evidence[i][230..<233]) + [masked[i][10]] }
            let f = M.pooled(rows) + [log1p(Double(ids.count)), M.std(ids.map { log(point[$0]) })]
            for i in ids { contexts[i] = f }
        }
        return prior.indices.map { i in
            var e = evidence[i]
            for j in 164..<230 { e[j] = 0 }
            return native[i] + e + masked[i] + cadence[i] + glyph[i] + [log(point[i] / prior[i])] + contexts[i]
        }
    }

    static func signature(_ ids: [Int], native: Matrix, evidence: Matrix, masked: Matrix, cadence: Matrix,
                          colors: Matrix, point: [Double], prior: [Double], experts: Experts) -> ([Double], [Double]) {
        var dim = [Double](), app = [Double]()
        for j in experts.values[0].indices {
            let keep = ids.filter { experts.valid[$0][j] }
            dim += keep.isEmpty ? [0, 0, 0] : M.quantiles(keep.map { experts.values[$0][j] }, [0.2, 0.5, 0.8])
            app += [Double(keep.count) / Double(ids.count), M.mean(keep.map { experts.weights[$0][j] })]
        }
        dim += M.quantiles(ids.map { prior[$0] }, [0.2, 0.5, 0.8])
        dim += M.quantiles(ids.map { point[$0] }, [0.2, 0.5, 0.8])
        var cdim = [Int](), capp = [Int](), physical = [Int](), other = [0, 1]
        for channel in 0..<4 {
            cdim += (Array(4..<16) + Array(20..<23) + [23, 24, 26, 27, 29, 30]).map { 32 * channel + $0 }
            capp += (Array(0..<4) + Array(16..<20) + [25, 28, 31]).map { 32 * channel + $0 }
        }
        dim += M.pooled(ids.map { i in cdim.map { colors[i][$0] * prior[i] } })
        app += M.pooled(ids.map { i in capp.map { colors[i][$0] } })
        for channel in 0..<5 {
            physical += (Array(3..<12) + Array(15..<18)).map { 2 + 24 * channel + $0 }
            other += ([0] + Array(12..<15) + Array(18..<24)).map { 2 + 24 * channel + $0 }
        }
        dim += M.pooled(ids.map { i in physical.map { cadence[i][$0] * prior[i] } })
        app += M.pooled(ids.map { i in other.map { cadence[i][$0] } })
        let body = (0..<4).flatMap { j in Array((233 + 14 * j)..<(245 + 14 * j)) }
        dim += M.pooled(ids.map { i in body.map { evidence[i][$0] } })
        let expected = (0..<4).flatMap { j in Array((36 * j)..<(36 * j + 18)) }
        app += M.columnMean(ids.map { i in expected.map { evidence[i][$0] } })
        app += M.columnMean(ids.map { Array(evidence[$0][146..<164]) })
        app += M.columnMean(ids.map { Array(evidence[$0][230..<233]) })
        app += M.columnMean(ids.map { Array(native[$0][1...]) })
        app += M.pooled(ids.map { Array(masked[$0][0..<15]) })
        app.append(log1p(Double(ids.count)))
        return (dim, app + dim.map { $0 > 0 ? 1 : 0 })
    }

    static func candidateFeatures(_ dim: [Double], _ app: [Double], _ candidates: [Double]) -> Matrix {
        // The trained112 model receives float32 feature inputs, even though all
        // source reductions and candidate hypotheses above use Double.
        candidates.map { candidate in
            (dim.map { log(max(1e-6, $0 > 0 ? $0 / candidate : 1)) } + app).map { Double(Float($0)) }
        }
    }

    static func physical(_ ids: [Int], templates: Matrix, prior: [Double], policy: [String: Any]) -> (Double, [Double]) {
        let factor = M.integer(policy, "factorColumn"), quality = M.integer(policy, "qualityColumn")
        let temperature = M.number(policy, "temperature")
        var qRows = Matrix(), values = [Double](), confidence = [Double]()
        for i in ids {
            let q = (0..<4).map { max(0, templates[i][$0 * 16 + quality]) }, peak = q.max()!
            let w = q.map { exp(($0 - peak) / temperature) * ($0 >= 0.4 ? 1 : 0) }
            let v = (0..<4).map { prior[i] * templates[i][$0 * 16 + factor] }
            values.append(M.weightedMedian(v, w)); qRows.append(q)
            confidence.append(zip(q, w).reduce(0) { $0 + $1.0 * $1.1 } / max(1e-8, w.reduce(0, +)))
        }
        let value = M.weightedMedian(values, confidence), positive = values.filter { $0 > 0 }
        let variation = !positive.isEmpty && value > 0 ? M.median(positive.map { abs(log($0 / value)) }) : 1
        return (value, M.pooled(qRows) + [M.median(confidence), variation, Double(positive.count) / Double(ids.count)])
    }

    static func regression(_ id: String, _ features: Matrix, _ policy: [String: Any],
                           _ access: NativeSourceFontModelAccess) throws -> [Double] {
        if let q = policy["aggregation"] as? NSNumber {
            let predictions = try access.trees(id, features)
            return features.indices.map { i in M.quantile(predictions.map { $0[i] }, q.doubleValue) }
        }
        return try access.predict(id, features)
    }

    static func pooledProbability(_ probability: Matrix, _ records: [[Int]], _ kind: String) -> Matrix {
        records.map { ids in
            let p = probability[0].indices.map { j in
                kind == "mean" ? M.mean(ids.map { probability[$0][j] })
                    : exp(M.mean(ids.map { log(max(1e-5, probability[$0][j])) }))
            }
            let total = p.reduce(0, +)
            return p.map { $0 / total }
        }
    }

}

extension NativeEarlySourceFontGraph {
    private static func componentProposals(_ stage: Int, _ p: [String: Any], _ prepared: M.Prepared,
                                           native: Matrix, evidence: Matrix, priors: [Double], point: [Double],
                                           compIndex: [Int], compSizes: [Double], desc: Matrix,
                                           bank76: [String: Any], bank84: [String: Any],
                                           access: NativeSourceFontModelAccess, modelID: String) throws -> [Double] {
        let records = prepared.records, old = prepared.old
        var proposed = [Double]()
        switch stage {
        case 77:
            let k = M.integer(p, "neighbors"), sizes = try M.vector(bank76, "sizes")
            let distance = try M.matrix(bank76, "distances"), ratio = try M.matrix(bank76, "ratios")
            let support = try M.matrix(bank76, "support")
            var estimates = [Double](), valid = [Bool]()
            for i in compIndex.indices {
                let order = (0..<k).sorted { ratio[i][$0] == ratio[i][$1] ? $0 < $1 : ratio[i][$0] < ratio[i][$1] }
                let w = order.map { exp(-distance[i][$0] / 0.02) * (distance[i][$0] <= M.number(p, "maxDistance") ? 1 : 0)
                    * pow(support[i][$0], 0.25) }
                let total = w.reduce(0, +)
                var cumulative = 0.0, selected = 0
                for j in order.indices { cumulative += w[j]; if cumulative >= total / 2 { selected = j; break } }
                estimates.append(sizes[i] * ratio[i][order[selected]]); valid.append(total > 0)
            }
            for (g, members) in records.enumerated() {
                let ids = compIndex.indices.filter { members.contains(compIndex[$0]) && valid[$0] }
                if ids.count < 3 { proposed.append(old[g]); continue }
                if M.string(p, "pooling") == "row-median" {
                    proposed.append(M.median(Set(ids.map { compIndex[$0] }).sorted().map { row in
                        M.median(ids.filter { compIndex[$0] == row }.map { estimates[$0] }) }))
                } else if M.string(p, "pooling") == "trimmed-mean" {
                    let v = ids.map { estimates[$0] }, low = M.quantile(ids.map { estimates[$0] }, 0.1), high = M.quantile(v, 0.9)
                    let w = ids.map { exp(-distance[$0][0] / 0.02) }
                    proposed.append(exp(zip(v, w).reduce(0) { $0 + log(M.clip($1.0, low, high)) * $1.1 } / w.reduce(0, +)))
                } else { proposed.append(M.median(ids.map { estimates[$0] })) }
            }
        case 79:
            let ratio = try M.matrix(bank76, "ratios"), distance = try M.matrix(bank76, "distances")
            let support = try M.matrix(bank76, "support")
            var f = Matrix()
            for (i, row) in compIndex.enumerated() {
                var v = desc[i] + [log(compSizes[i] / priors[row]), log(priors[row]), log(point[row] / priors[row])]
                v += Array(native[row][0..<6]) + Array(evidence[row][146..<164]) + Array(evidence[row][230..<233])
                v += (0..<3).map { log(max(0.1, compSizes[i] * ratio[i][$0] / priors[row])) }
                v += Array(distance[i][0..<3]) + (0..<3).map { log1p(support[i][$0]) }; f.append(v)
            }
            let prediction = f.isEmpty ? [] : try access.predict(modelID, f)
            let fonts = compIndex.indices.map { i in
                (M.string(p, "target") == "prior" ? priors[compIndex[i]] : point[compIndex[i]]) * exp(M.clip(prediction[i], -1, 1)) }
            for (g, members) in records.enumerated() {
                let ids = compIndex.indices.filter { members.contains(compIndex[$0]) }
                if ids.isEmpty { proposed.append(old[g]); continue }
                let v = ids.map { fonts[$0] }
                if M.string(p, "pooling") == "row-median" {
                    proposed.append(M.median(Set(ids.map { compIndex[$0] }).sorted().map { row in
                        M.median(ids.filter { compIndex[$0] == row }.map { fonts[$0] }) }))
                } else if M.string(p, "pooling") == "trimmed-mean" {
                    let low = M.quantile(v, 0.1), high = M.quantile(v, 0.9)
                    proposed.append(exp(M.mean(v.map { log(M.clip($0, low, high)) })))
                } else { proposed.append(M.median(v)) }
            }
        case 86:
            let sizes = try M.vector(bank84, "sizes"), distance = try M.matrix(bank84, "distances")
            let ratio = try M.matrix(bank84, "ratios"), support = try M.matrix(bank84, "support")
            var w = Matrix(), valid = [Bool]()
            for i in compIndex.indices {
                var row = (0..<8).map { exp(-distance[i][$0] / 0.02) * (distance[i][$0] <= M.number(p, "maxDistance") ? 1 : 0)
                    * log1p(support[i][$0]) }
                let denominator = max(1e-12, row.reduce(0, +))
                row = row.map { $0 / denominator * (sizes[i] / priors[compIndex[i]] >= M.number(p, "minBodyRatio") ? 1 : 0) }
                w.append(row); valid.append(row.reduce(0, +) > 0)
            }
            for (g, members) in records.enumerated() {
                let ids = compIndex.indices.filter { members.contains(compIndex[$0]) && valid[$0] }
                if ids.count < 3 { proposed.append(old[g]); continue }
                var counts = [Int: Int]()
                for i in ids { counts[compIndex[i], default: 0] += 1 }
                let grid = M.arange(max(4, Double(Int(old[g] * 0.65))), Double(Int(old[g] * 1.45)) + 1)
                let density = grid.map { candidate -> Double in
                    var total = 0.0
                    for i in ids { for j in 0..<8 {
                        let difference = log(candidate / max(0.1, sizes[i] * ratio[i][j])) / M.number(p, "bandwidth")
                        total += exp(-0.5 * difference * difference) * w[i][j] / Double(counts[compIndex[i]]!)
                    } }
                    return total
                }
                proposed.append(grid[M.argmax(density)])
            }
        default: throw NativeSourceFontGraphError.invalid("Unknown component stage")
        }
        return proposed
    }

    static func predictEarly(before: [Double], point: [Double], native: Matrix, evidence: Matrix,
                             priors: [Double], groups: [String], pageSizes: Matrix, signals: [String: Any],
                             models: [String: String], policies: [String: [String: Any]],
                             access: NativeSourceFontModelAccess, returnStages: Bool = false) throws -> (values: [Double], stages: [String: [Double]]) {
        let n = before.count
        try M.validate(native, width: 156, count: n, name: "native156")
        try M.validate(evidence, width: 291, count: n, name: "evidence291")
        try M.validate(pageSizes, width: 2, count: n, name: "pageSizes")
        guard point.count == n, priors.count == n, groups.count == n,
              [before, point, priors].allSatisfy({ $0.allSatisfy { $0.isFinite && $0 > 0 } }),
              pageSizes.allSatisfy({ $0.allSatisfy { $0 > 0 } }) else {
            throw NativeSourceFontGraphError.invalid("Invalid source font inputs")
        }
        if n == 0 { return ([], returnStages ? Dictionary(uniqueKeysWithValues: stages.map { ("round\($0)", []) }) : [:]) }
        let masked = try M.matrix(signals, "masked65"), cadence = try M.matrix(signals, "cadence69")
        let colors = try M.matrix(signals, "colors100"), templates = try M.matrix(signals, "templates103")
        try M.validate(masked, width: 180, count: n, name: "masked65")
        try M.validate(cadence, width: 122, count: n, name: "cadence69")
        try M.validate(colors, width: 128, count: n, name: "colors100")
        try M.validate(templates, width: 66, count: n, name: "templates103")
        guard let components = signals["components75"] as? [String: Any],
              let bank76 = signals["neighbors76"] as? [String: Any],
              let bank84 = signals["neighbors84"] as? [String: Any] else {
            throw NativeSourceFontGraphError.invalid("Missing component measurements")
        }
        let rawIndex = try M.vector(components, "indices")
        guard rawIndex.allSatisfy({ $0.isFinite && $0 >= 0 && $0 < Double(n) && $0.rounded(.towardZero) == $0 }) else {
            throw NativeSourceFontGraphError.invalid("Invalid component source row index")
        }
        let compIndex = rawIndex.map(Int.init)
        let compSizes = try M.vector(components, "sizes"), desc = try M.matrix(components, "features")
        try M.validate(desc, width: 198, count: compIndex.count, name: "components75")
        guard compSizes.count == compIndex.count, compIndex.allSatisfy({ $0 >= 0 && $0 < n }) else {
            throw NativeSourceFontGraphError.invalid("Invalid component row binding")
        }
        for bank in [bank76, bank84] {
            guard try M.vector(bank, "indices").map(Int.init) == compIndex,
                  try M.vector(bank, "sizes").count == compIndex.count else {
                throw NativeSourceFontGraphError.invalid("Misaligned neighbor measurements")
            }
            for key in ["ratios", "distances", "support"] {
                try M.validate(M.matrix(bank, key), width: 8, count: compIndex.count, name: key)
            }
        }
        var zero = evidence, actual = evidence
        for i in 0..<n { for j in 164..<230 { zero[i][j] = 0; actual[i][j] = templates[i][j - 164] } }
        let experts = sourceExperts(native, evidence, masked), zeroExperts = sourceExperts(native, zero, masked)
        let actualExperts = sourceExperts(native, actual, masked)
        var values = before, trace = [String: [Double]](), probabilities = [Int: Matrix]()
        var rowMatrix: Matrix?
        func reference(_ stage: Int) throws -> String {
            guard let id = models["round\(stage)"] ?? models[String(stage)] else {
                throw NativeSourceFontGraphError.invalid("Missing early model \(stage)")
            }
            return id
        }
        for stage in stages {
            guard let p = policies["round\(stage)"] ?? policies[String(stage)] else {
                throw NativeSourceFontGraphError.invalid("Missing early policy \(stage)")
            }
            let prepared = M.prepare(before: values, native: native, groups: groups)
            let records = prepared.records, old = prepared.old
            var proposed = [Double](), weights = Array(repeating: M.number(p, "strength", 1), count: old.count)
            switch stage {
            case 68, 71:
                let f = records.map { ids -> [Double] in
                    let base = groupExperts(ids, native: native, evidence: evidence, masked: masked, point: point, experts: experts).1
                    if stage == 68 { return base }
                    return (M.string(p, "variant") == "all" ? base : Array(base.prefix(9))) + M.summary(ids.map { cadence[$0] })
                }
                let prediction = try regression(reference(stage), f, p, access)
                proposed = prediction.indices.map { i in
                    let factor = M.string(p, "space", "log") == "log" ? exp(M.clip(prediction[i], -2, 2)) : M.clip(prediction[i], 0.1, 5)
                    return prepared.anchors[i] * factor
                }
            case 72, 83, 88, 105:
                let ce = stage == 83 ? zero : stage == 105 ? actual : evidence
                let ex = stage == 83 ? zeroExperts : stage == 105 ? actualExperts : experts
                let pairs = records.map { scaledFeatures($0, kind: M.string(p, "unit"), native: native, evidence: ce,
                    masked: masked, cadence: cadence, point: point, prior: priors, pageSizes: pageSizes, experts: ex) }
                let prediction = try regression(reference(stage), pairs.map(\.1), p, access)
                proposed = prediction.indices.map { pairs[$0].0 * (stage == 88 ? max(0.0001, prediction[$0]) : exp(prediction[$0])) }
            case 77, 79, 86:
                proposed = try componentProposals(stage, p, prepared, native: native, evidence: evidence,
                    priors: priors, point: point, compIndex: compIndex, compSizes: compSizes, desc: desc,
                    bank76: bank76, bank84: bank84, access: access, modelID: stage == 79 ? reference(stage) : "")
            case 90, 92, 93, 96, 98, 102:
                if rowMatrix == nil {
                    rowMatrix = try rowFeatures(native: native, evidence: evidence, masked: masked, cadence: cadence,
                        components: components, neighbors: bank84, point: point, prior: priors, groups: groups)
                }
                if [90, 92, 96, 102].contains(stage) {
                    let f = stage == 102 ? rowMatrix!.indices.map { rowMatrix![$0] + colors[$0] } : rowMatrix!
                    probabilities[stage] = try access.proba(reference(stage), f)
                }
                if [90, 96, 102].contains(stage) {
                    guard M.number(p, "posteriorUnbiasPower") == 0 else { throw NativeSourceFontGraphError.invalid("Unaccepted posterior unbias") }
                    let probability = pooledProbability(probabilities[stage]!, records, M.string(p, "pooling"))
                    let classes = try access.classes(reference(stage))
                    for (g, ids) in records.enumerated() {
                        let row = probability[g], unit = M.string(p, "unit") == "pixels" ? 1 : M.median(ids.map { pageSizes[$0][0] / 2048 })
                        var decoded = classes[M.argmax(row)]
                        if M.string(p, "decoding") == "mean" { decoded = zip(row, classes).reduce(0) { $0 + $1.0 * $1.1 } }
                        if M.string(p, "decoding") == "relative-median" {
                            let mass = row.indices.map { row[$0] / classes[$0] }, half = massSum(row, classes) / 2
                            var cumulative = 0.0
                            for j in mass.indices { cumulative += mass[j]; if cumulative >= half { decoded = classes[j]; break } }
                        }
                        proposed.append(row.max()! >= M.number(p, "minConfidence") ? unit * decoded : old[g])
                    }
                } else if stage == 98 {
                    let classes = try access.classes(reference(96))
                    let probability = records.map { ids in M.columnMean(ids.map { probabilities[96]![$0] }) }
                    for (g, ids) in records.enumerated() {
                        let row = probability[g], ordered = row.sorted()
                        let v = M.median(ids.map { pageSizes[$0][0] / 2048 }) * classes[M.argmax(row)]
                        let certainty = M.string(p, "certainty") == "probability" ? row.max()! : ordered[ordered.count - 1] - ordered[ordered.count - 2]
                        let threshold = M.number(p, "threshold")
                        let confident = M.clip((certainty - threshold) / max(0.05, 1 - threshold), 0, 1)
                        let diff = log(v / prepared.anchors[g]) / M.number(p, "physicalAgreementTolerance")
                        var support = confident * exp(-0.5 * diff * diff)
                        if M.flag(p, "directionGate"), (v - old[g]) * (prepared.anchors[g] - old[g]) <= 0 { support = 0 }
                        weights[g] = M.number(p, "baseStrength") + (1 - M.number(p, "baseStrength")) * support
                        proposed.append(v)
                    }
                } else {
                    let policy92 = policies["round92"] ?? policies["92"]!
                    let step = stage == 92 ? M.number(p, "logRatioStep") : M.number(policy92, "logRatioStep")
                    let c92 = try access.classes(reference(92)).map { $0 * step }
                    let c90 = stage == 93 ? try access.classes(reference(90)) : []
                    for (g, ids) in records.enumerated() {
                        let grid = M.arange(max(4, old[g] * (stage == 92 ? 0.6 : 0.65)), old[g] * (stage == 92 ? 1.5 : 1.4) + 0.25)
                        let b = ids.map { i in grid.map { M.interp(log($0 / priors[i]), c92, probabilities[92]![i]) } }
                        var likelihood = [Double]()
                        if stage == 92 {
                            likelihood = grid.indices.map { j in
                                M.string(p, "pooling") == "mean" ? M.mean(b.map { $0[j] })
                                    : exp(M.mean(b.map { log(max(1e-6, $0[j])) })) }
                        } else {
                            let a = ids.map { i in grid.map { M.interp($0 / (pageSizes[i][0] / 2048), c90, probabilities[90]![i]) } }
                            var w = ids.map { pow(M.clip(expm1(evidence[$0][146]), 1, 30), M.number(p, "characterCountPower")) }
                            let total = w.reduce(0, +); w = w.map { $0 / total }
                            let mix = M.number(p, "absolutePosteriorWeight")
                            for j in grid.indices {
                                var aa = 0.0, bb = 0.0
                                for i in ids.indices {
                                    aa += (M.string(p, "pooling") == "mean" ? a[i][j] : log(max(1e-6, a[i][j]))) * w[i]
                                    bb += (M.string(p, "pooling") == "mean" ? b[i][j] : log(max(1e-6, b[i][j]))) * w[i]
                                }
                                if M.string(p, "pooling") != "mean" { aa = exp(aa); bb = exp(bb) }
                                likelihood.append(pow(max(aa, 1e-8), mix) * pow(max(bb, 1e-8), 1 - mix))
                            }
                        }
                        let density = grid.indices.map { j -> Double in
                            let delta = log(grid[j] / old[g]) / M.number(p, "priorSigma")
                            return likelihood[j] * exp(-0.5 * delta * delta)
                        }
                        proposed.append(density.max()! > 0 ? grid[M.argmax(density)] : old[g])
                    }
                }
            case 108:
                var f = Matrix()
                for (g, ids) in records.enumerated() {
                    let (anchor, base) = scaledFeatures(ids, kind: "prior", native: native, evidence: evidence,
                        masked: masked, cadence: cadence, point: point, prior: priors, pageSizes: pageSizes, experts: experts)
                    let (raw, summary) = physical(ids, templates: templates, prior: priors, policy: p)
                    let v = raw > 0 ? raw : old[g]
                    f.append(base + summary + [log(old[g] / anchor), log(v / anchor), log(v / old[g])]); proposed.append(v)
                }
                let probability = try access.proba(reference(stage), f)
                for g in old.indices where probability[g][1] < M.number(p, "gateProbability") { proposed[g] = old[g] }
            case 112:
                var grids = Matrix(), f = Matrix(), bounds = [0]
                for (g, ids) in records.enumerated() {
                    let (dim, app) = signature(ids, native: native, evidence: actual, masked: masked, cadence: cadence,
                        colors: colors, point: point, prior: priors, experts: actualExperts)
                    let grid = M.arange(max(4, old[g] * 0.65), old[g] * 1.4 + 0.25)
                    let row = candidateFeatures(dim, app, grid); grids.append(grid); f += row; bounds.append(bounds.last! + row.count)
                }
                let density = try access.predict(reference(stage), f).map { max(1e-8, $0) }
                for (g, grid) in grids.enumerated() {
                    let mass = grid.indices.map { j -> Double in
                        let d = log(grid[j] / old[g]) / M.number(p, "priorSigma")
                        return density[bounds[g] + j] * exp(-0.5 * d * d)
                    }
                    switch M.string(p, "decoding") {
                    case "mode": proposed.append(grid[M.argmax(mass)])
                    case "plateau":
                        let threshold = mass.max()! * 0.95
                        proposed.append(M.mean(grid.indices.filter { mass[$0] >= threshold }.map { grid[$0] }))
                    default:
                        let w = mass.map { pow($0, 4) }
                        proposed.append(zip(grid, w).reduce(0) { $0 + $1.0 * $1.1 } / w.reduce(0, +))
                    }
                }
            default: throw NativeSourceFontGraphError.invalid("Unaccepted early stage")
            }
            values = M.apply(values, prepared, proposed, weights: weights, clip: M.number(p, "clip"), quantum: M.number(p, "quantum"))
            guard values.allSatisfy({ $0.isFinite && $0 > 0 }) else { throw NativeSourceFontGraphError.invalid("Nonfinite early output") }
            if returnStages { trace["round\(stage)"] = values }
        }
        return (values, trace)
    }

    private static func massSum(_ probability: [Double], _ classes: [Double]) -> Double {
        probability.indices.reduce(0) { $0 + probability[$1] / classes[$1] }
    }

}

extension NativeEarlySourceFontGraph {
    static func harmonize(_ input: [Double], _ groups: [String], _ ratio: Double, method: String = "median") -> [Double] {
        if ratio <= 1 { return input }
        var out = input
        for page in M.groupRows(groups) {
            let ordered = page.sorted { out[$0] == out[$1] ? $0 < $1 : out[$0] < out[$1] }
            var cohorts = [[Int]]()
            for i in ordered {
                if cohorts.isEmpty || out[i] / out[cohorts.last![0]] > ratio { cohorts.append([i]) }
                else { cohorts[cohorts.count - 1].append(i) }
            }
            for ids in cohorts where ids.count > 1 {
                var values = ids.map { out[$0] }
                let canonical: Double
                switch method {
                case "mean": canonical = M.mean(values)
                case "log_mean", "trimmed_log_mean":
                    if method == "trimmed_log_mean" && values.count >= 5 {
                        let trim = values.count / 5
                        values = Array(values.sorted()[trim..<(values.count - trim)])
                    }
                    canonical = exp(M.mean(values.map(log)))
                default: canonical = M.median(values)
                }
                for i in ids { out[i] = canonical }
            }
        }
        return out
    }

    static func contextFeatures(_ native: Matrix, _ values: [Double], _ priors: [Double],
                                _ groups: [String], featureCount: Int) -> Matrix {
        var extra = Matrix(repeating: Array(repeating: 0, count: 15), count: priors.count)
        for page in M.groupRows(groups) {
            for i in page {
                extra[i][0] = log(values[i] / priors[i])
                let ratios = page.filter { $0 != i }.map { log(values[$0] / values[i]) }
                if ratios.isEmpty { continue }
                let nearest = ratios.sorted { abs($0) == abs($1) ? $0 < $1 : abs($0) < abs($1) }
                for (j, v) in nearest.prefix(3).enumerated() { extra[i][1 + j] = v }
                let q = M.quantiles(ratios, [0, 0.25, 0.5, 0.75, 1])
                for j in 0..<5 { extra[i][4 + j] = q[j] }
                extra[i][9] = min(1, Double(ratios.count) / 12)
                extra[i][10] = Double(ratios.filter { abs($0) <= log(1.12) }.count) / Double(ratios.count)
                extra[i][11] = Double(ratios.filter { abs($0) <= log(1.3) }.count) / Double(ratios.count)
                extra[i][12] = M.std(ratios)
                extra[i][13] = Double(ratios.filter { $0 < 0 }.count) / Double(ratios.count)
                extra[i][14] = Double(ratios.filter { $0 > 0 }.count) / Double(ratios.count)
            }
        }
        return native.indices.map { Array(native[$0].prefix(featureCount)) + extra[$0] }
    }

    static func basePoint(_ config: [String: Any], native: Matrix, priors: [Double], groups: [String],
                          access: NativeSourceFontModelAccess) throws -> [Double] {
        guard M.isNull(config["contextEnsemble"]), M.isNull(config["physicalConsensus"]), M.isNull(config["sourceClustering"]),
              M.string(config, "contextWitness", "none") == "none", !M.flag(config, "contextRawFeatures"),
              M.number(config, "contextRawWeight") == 0 else {
            throw NativeSourceFontGraphError.invalid("Base56 metadata does not match frozen accepted configuration")
        }
        let width = M.integer(config, "modelFeatureCount", 156)
        let model = M.modelID(config["model"]) ?? ""
        var correction = model.isEmpty ? Array(repeating: M.number(config, "logScale"), count: priors.count)
            : try access.predict(model, native.map { Array($0.prefix(width)) })
        if let auxiliary = M.modelID(config["auxiliaryModel"]) {
            let columns = config["auxiliaryFeatureIndices"] as? [Int] ?? Array(0..<156)
            let prediction = try access.predict(auxiliary, native.map { row in columns.map { row[$0] } })
            let weight = M.number(config, "auxiliaryWeight")
            correction = correction.indices.map { (1 - weight) * correction[$0] + weight * prediction[$0] }
        }
        let bounds = config["correctionBounds"] as? [Double] ?? [-0.85, 0.85]
        var values = priors.indices.map { priors[$0] * exp(M.clip(correction[$0], bounds[0], bounds[1])) }
        values = harmonize(values, groups, M.number(config, "harmonizationRatio", 1))
        if let context = M.modelID(config["contextModel"]) {
            let f = contextFeatures(native, values, priors, groups, featureCount: M.integer(config, "contextBaseFeatureCount", 156))
            let delta = try access.predict(context, f)
            let strength = M.number(config, "contextStrength"), bound = M.number(config, "contextClip")
            values = values.indices.map { values[$0] * exp(M.clip(delta[$0] * strength, -bound, bound)) }
            // Runtime56 forcibly overrides contextFinalRatio to one.
        }
        if let final = config["finalClustering"] as? [String: Any] {
            values = harmonize(values, groups, M.number(final, "lock_ratio", 1 + 1e-10))
            let quantum = M.number(final, "quantum")
            if quantum > 0 { values = values.map { max(quantum, ($0 / quantum).rounded(.toNearestOrEven) * quantum) } }
        }
        return values
    }

    static func pairFeatures(_ native: Matrix, _ evidence: Matrix, _ left: Int, _ right: Int) -> [Double] {
        let a = Array(native[left][1...]) + Array(evidence[left][0..<233])
        let b = Array(native[right][1...]) + Array(evidence[right][0..<233])
        let dx = evidence[left][289] - evidence[right][289], dy = evidence[left][290] - evidence[right][290]
        var f = [sqrt(dx * dx + dy * dy)]
        f += a.indices.map { abs(a[$0] - b[$0]) }
        f += a.indices.map { (a[$0] + b[$0]) / 2 }
        f += (233..<289).map { j in
            evidence[left][j] > 0 && evidence[right][j] > 0 ? abs(log(evidence[left][j] / evidence[right][j])) : 0 }
        f += (233..<289).map { evidence[left][$0] > 0 && evidence[right][$0] > 0 ? 1 : 0 }
        return f
    }

    static func decode61(_ values: [Double], _ affinity: Matrix, _ source: Matrix, _ policy: [String: Any]) -> [Double] {
        var cohorts = values.indices.map { [$0] }, counts = Array(repeating: 1.0, count: values.count)
        var low = values, high = values, a = affinity, s = source
        while cohorts.count > 1 {
            var best = -Double.infinity, first = 0, second = 0
            for i in cohorts.indices {
                for j in cohorts.indices where j > i {
                    let ratio = max(high[i], high[j]) / min(low[i], low[j])
                    let required = min(0.95, M.number(policy, "minSourceAffinity")
                        + M.number(policy, "sourceGapSlope") * max(0, ratio - 1) / 0.4)
                    if ratio <= M.number(policy, "span"), s[i][j] >= required, a[i][j] > best {
                        best = a[i][j]; first = i; second = j
                    }
                }
            }
            if best <= M.number(policy, "threshold") + 1e-9 { break }
            let total = counts[first] + counts[second]
            let merged = a[first].indices.map { (a[first][$0] * counts[first] + a[second][$0] * counts[second]) / total }
            let sourceMerged = s[first].indices.map { (s[first][$0] * counts[first] + s[second][$0] * counts[second]) / total }
            for j in cohorts.indices { a[first][j] = merged[j]; a[j][first] = merged[j]; s[first][j] = sourceMerged[j]; s[j][first] = sourceMerged[j] }
            counts[first] += counts[second]; low[first] = min(low[first], low[second]); high[first] = max(high[first], high[second])
            cohorts[first] += cohorts[second]
            cohorts.remove(at: second); counts.remove(at: second); low.remove(at: second); high.remove(at: second)
            a.remove(at: second); s.remove(at: second)
            for j in a.indices { a[j].remove(at: second); s[j].remove(at: second) }
        }
        var result = values
        for ids in cohorts {
            let canonical = M.median(ids.map { values[$0] }).rounded(.toNearestOrEven)
            for i in ids { result[i] = canonical }
        }
        return result
    }

    static func predictBase(base: [String: Any], pairModel: String, policy: [String: Any], native: Matrix,
                            evidence: Matrix, priors: [Double], groups: [String],
                            access: NativeSourceFontModelAccess) throws -> (point: [Double], values: [Double], affinities: [Affinity]) {
        try M.validate(native, width: 156, count: priors.count, name: "native156")
        try M.validate(evidence, width: 291, count: priors.count, name: "evidence291")
        guard groups.count == priors.count, priors.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw NativeSourceFontGraphError.invalid("Invalid base source rows")
        }
        if priors.isEmpty { return ([], [], []) }
        let point = try basePoint(base, native: native, priors: priors, groups: groups, access: access)
        var values = point, affinities = [Affinity]()
        for ids in M.groupRows(groups) {
            var source = Matrix(repeating: Array(repeating: 0, count: ids.count), count: ids.count)
            var pairs = [(Int, Int)](), f = Matrix()
            for i in ids.indices {
                source[i][i] = 1
                for j in ids.indices where j > i { pairs.append((i, j)); f.append(pairFeatures(native, evidence, ids[i], ids[j])) }
            }
            if !pairs.isEmpty {
                let probability = try access.proba(pairModel, f)
                for (index, pair) in pairs.enumerated() {
                    let p = probability[index][1]
                    guard p.isFinite, p >= 0, p <= 1 else { throw NativeSourceFontGraphError.invalid("Invalid pair probability") }
                    source[pair.0][pair.1] = p; source[pair.1][pair.0] = p
                }
            }
            let weight = M.number(policy, "numericAffinityWeight")
            let affinity = ids.indices.map { i in ids.indices.map { j in
                weight == 0 ? source[i][j] : (1 - weight) * source[i][j]
                    + weight * exp(-abs(log(point[ids[i]] / point[ids[j]])) / 0.15) } }
            let order = ids.indices.sorted { lhs, rhs in
                let a = [point[ids[lhs]], native[ids[lhs]][0]] + native[ids[lhs]]
                let b = [point[ids[rhs]], native[ids[rhs]][0]] + native[ids[rhs]]
                for j in a.indices where a[j] != b[j] { return a[j] < b[j] }
                return lhs < rhs
            }
            let decoded = decode61(order.map { point[ids[$0]] }, order.map { i in order.map { affinity[i][$0] } },
                                   order.map { i in order.map { source[i][$0] } }, policy)
            for (i, local) in order.enumerated() { values[ids[local]] = decoded[i] }
            affinities.append((ids, source))
        }
        return (point, values, affinities)
    }

    /// Decode JSON numeric arrays via JSONDecoder (not JSONSerialization); its
    /// decimal parser preserves the IEEE values used at trained split thresholds.
    /// Metadata is the portable bundle graph: baseModel model references are
    /// registry IDs; pairModel, earlyModels and policies are serialized assets.
    static func predict(native: Matrix, evidence: Matrix, priors: [Double], groups: [String], pageSizes: Matrix,
                        signals: [String: Any], metadata: [String: Any], access: NativeSourceFontModelAccess,
                        returnStages: Bool = false) throws -> Result {
        guard let base = metadata["baseModel"] as? [String: Any], let pair = M.modelID(metadata["pairModel"]),
              let policy = metadata["clusteringPolicy"] as? [String: Any],
              let modelObjects = metadata["earlyModels"] as? [String: Any],
              let policies = metadata["earlyPolicies"] as? [String: [String: Any]] else {
            throw NativeSourceFontGraphError.invalid("Missing frozen early graph metadata")
        }
        var models = [String: String]()
        for (key, object) in modelObjects {
            guard let identity = M.modelID(object) else { throw NativeSourceFontGraphError.invalid("Invalid early model reference") }
            models[key] = identity
        }
        let b = try predictBase(base: base, pairModel: pair, policy: policy, native: native, evidence: evidence,
                                priors: priors, groups: groups, access: access)
        let e = try predictEarly(before: b.values, point: b.point, native: native, evidence: evidence, priors: priors,
                                 groups: groups, pageSizes: pageSizes, signals: signals, models: models, policies: policies,
                                 access: access, returnStages: returnStages)
        var trace = e.stages
        if returnStages { trace["point56"] = b.point; trace["cluster61"] = b.values }
        return Result(point: b.point, values: e.values, affinities: b.affinities, stages: trace)
    }
}
