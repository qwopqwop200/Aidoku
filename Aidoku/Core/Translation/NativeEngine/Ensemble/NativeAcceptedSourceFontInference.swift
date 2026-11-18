import AidokuNativeCV
import CoreGraphics
import Foundation

/// Complete accepted source-font graph on both native platforms. Every source
/// feature is reconstructed from the supplied bounded original crop; model
/// metadata contains trained reference banks and exclusion guards, not outputs.
final class NativeAcceptedSourceFontInference: @unchecked Sendable {
    typealias Matrix = [[Double]]
    typealias Math = NativeSourceFontGraphMath
    enum Failure: Error { case invalidMetadata(String), invalidSource(String), extraction(String) }
    enum SourceGeometry: Sendable, Equatable { case originalMembers, bboxOnly }
    static var selectedEstimatorIdentity: String { "accepted-font198-v1" }

    /// The rejected physical baseline is offline-only; default render keys stay unchanged.
    static var cachePolicy: String? { nil }

    /// In-memory observations from this estimate call, in original packet order.
    /// Priors remain OCR source pixels; final ems come from the declared estimator.
    /// These are measured signals, never prediction-stage diagnostics. Retaining
    /// packets preserves actual crop/word/RF observations without inventing any.
    struct SourceFontContext: Sendable {
        let packets: [SourceNativeInput]
        let packetOrder: [Int]
        let originalPriors: [Double]
        let finalSourceEMs: [Double]
        let style187: Matrix // N x 262, from the same extraction used by the graph
        let angles131: [Double] // N scalars, not an N x 131 feature matrix
        let geometryMode: SourceGeometry
        let measuredMemberPolygons: [[[CGPoint]]]
    }

    struct Result {
        let values: [Double]
        let stages: [String: [Double]]
        let fontFaces: [[String: Any]]
        let context: SourceFontContext?
        let estimatorIdentity: String

        init(values: [Double], stages: [String: [Double]], fontFaces: [[String: Any]], context: SourceFontContext? = nil) {
            self.values = values
            self.stages = stages
            self.fontFaces = fontFaces
            self.context = context
            self.estimatorIdentity = NativeAcceptedSourceFontInference.selectedEstimatorIdentity
        }
    }
    private let heads: NativeAppearanceModelHeads
    private let graph: [String: Any]
    private let measurement: [String: Any]
    private let fontFaces: [[String: Any]]
    private let lateModels: [String: String]
    private let lateMetadata: [String: Any]
    private let banks: [String: PrototypeBank]
    private let weightReferencePairs: [[String: Any]]

    init(heads: NativeAppearanceModelHeads, fontResources: URL? = nil) throws {
        self.heads = heads
        let registry = try NativeFrozenSourceModel.Registry(directory: heads.directory, includeMetadata: true)
        let metadata = try registry.metadataTreeFoundation
        if let weight = metadata["font-weight/complete-complementary"] as? [String: Any],
           let pairs = weight["referencePairs"] as? [[String: Any]] {
            weightReferencePairs = try NativeSourceWeightFontResources.pairs(pairs, resourceRoot: fontResources)
        } else { weightReferencePairs = [] }
        guard let parent = metadata["font198"] as? [String: Any],
              let graph = parent["optimizedGraph"] as? [String: Any],
              graph["version"] as? String == "accepted-font198-v1",
              let specification = graph["measurementSpec"] as? [String: Any],
              specification["prototypeExclusionAvailable"] as? Bool == true else {
            throw Failure.invalidMetadata("complete accepted-font198 graph")
        }
        self.graph = graph
        measurement = try NativeSourceFontResolver.resolveMeasurementSpec(specification, resourceRoot: fontResources)
        fontFaces = (measurement["fonts"] as? [[String: Any]] ?? []) +
            (measurement["nativeFonts"] as? [[String: Any]] ?? [])
        guard let late = graph["lateModels"] as? [String: Any] else {
            throw Failure.invalidMetadata("accepted late font graph")
        }
        let normalized = try Self.normalizeLateMetadata(late, graph: graph, heads: heads)
        lateModels = normalized.models; lateMetadata = normalized.metadata
        guard let bankRecords = specification["referenceBanks"] as? [String: [String: Any]] else {
            throw Failure.invalidMetadata("TRAIN glyph prototype banks")
        }
        var banks: [String: PrototypeBank] = [:]
        for key in ["76", "84"] {
            guard let record = bankRecords[key] else { throw Failure.invalidMetadata("prototype bank \(key)") }
            banks[key] = try PrototypeBank(record: record, directory: heads.directory)
        }
        self.banks = banks
    }

    private static func normalizeLateMetadata(_ original: [String: Any], graph: [String: Any],
                                              heads: NativeAppearanceModelHeads) throws -> (models: [String: String], metadata: [String: Any]) {
        var metadata = original, models: [String: String] = [:]
        for (key, value) in original {
            if let identity = Math.modelID(value) { models[key] = identity }
            else if let wrapper = value as? [String: Any], let identity = Math.modelID(wrapper["model"]) {
                models[key] = identity
            }
        }
        guard let optical = original["175"] as? [[String: Any]], optical.count == 4 else {
            throw Failure.invalidMetadata("four optical font experts")
        }
        for (index, state) in optical.enumerated() {
            guard let identity = Math.modelID(state["model"]) else { throw Failure.invalidMetadata("optical expert head") }
            models["175.\(index)"] = identity
        }
        guard var encoder = original["style_encoder"] as? [String: Any],
              let pcaID = Math.modelID(encoder["model"]) else { throw Failure.invalidMetadata("style PCA head") }
        let pca = try heads.model(pcaID).metadataFoundation
        for key in ["components", "pcaMean", "explainedVariance"] {
            guard let value = pca[key] else { throw Failure.invalidMetadata("PCA \(key)") }
            encoder[key] = value
        }
        metadata["style_encoder"] = encoder
        metadata["sourceIdentityGroups"] = graph["sourceIdentityGroups"]
        return (models, metadata)
    }

    private var modelAccess: NativeSourceFontModelAccess {
        NativeSourceFontModelAccess(predict: { [heads] identity, matrix in
            let values = try heads.model(identity).predict(matrix)
            guard values.allSatisfy({ $0.count == 1 }) else { throw Failure.invalidMetadata("scalar regression head \(identity)") }
            return values.map { $0[0] }
        }, proba: { [heads] identity, matrix in
            try heads.model(identity).predictProbability(matrix)
        }, trees: { [heads] identity, matrix in
            let model = try heads.model(identity)
            guard let first = matrix.first else { return [] }
            let firstTrees = try model.predictTrees(first)
            guard firstTrees.allSatisfy({ $0.count == 1 }) else { throw Failure.invalidMetadata("scalar forest head") }
            var result = Matrix(repeating: [], count: firstTrees.count)
            for row in matrix {
                let values = try model.predictTrees(row)
                guard values.count == result.count, values.allSatisfy({ $0.count == 1 }) else { throw Failure.invalidMetadata("forest tree count") }
                for index in values.indices { result[index].append(values[index][0]) }
            }
            return result
        }, classes: { [heads] identity in try heads.model(identity).classes })
    }

    func estimate(_ packets: [SourceNativeInput], styles: [[String: Any]],
                  returnStages: Bool = false, returnContext: Bool = false,
                  geometry: SourceGeometry = .originalMembers) throws -> Result {
        guard packets.count == styles.count, packets.count <= 4096 else { throw Failure.invalidSource("source/font batch") }
        if packets.isEmpty {
            let context = returnContext ? try Self.makeContext(packets: [], rows: [], finalSourceEMs: [], geometry: geometry) : nil
            return Result(values: [], stages: [:], fontFaces: fontFaces, context: context)
        }
        var rows: [[String: Any]] = []
        for (packet, style) in zip(packets, styles) {
            try packet.validate()
            var request: [String: Any] = [
                "width": packet.width, "height": packet.height,
                "rgb": Data(packet.rgb), "ownership": Data(packet.ownMask),
                "bbox": [packet.bbox.minX, packet.bbox.minY, packet.bbox.width, packet.bbox.height].map(Double.init),
                "prior": packet.fontPriorSourcePixels, "text": packet.sourceText,
                "style": style, "measurementSpec": measurement,
                "memberPolygons": geometry == .bboxOnly ? [] : packet.memberPolygons.map { $0.map { [Double($0.x), Double($0.y)] } },
                "pageSize": [Double(packet.pageSize.width), Double(packet.pageSize.height)],
                "cropOrigin": [Double(packet.crop.minX), Double(packet.crop.minY)],
                "GTMaskUsed": false, "inferenceUsesGT": false,
            ]
            if let confidence = packet.confidence { request["confidence"] = confidence }
            if let role = packet.role { request["role"] = role }
            var error: NSError?
            guard let result = AIDExtractAllSourceSignals(request, &error) else {
                throw Failure.extraction(error?.localizedDescription ?? "native source measurements")
            }
            rows.append(result)
        }
        let batch = try assemble(rows, packets: packets)
        let priors = packets.map(\.fontPriorSourcePixels), groups = packets.map(\.sourceIdentity)
        let sizes = packets.map { [Double($0.pageSize.width), Double($0.pageSize.height)] }
        let native = try Self.matrix(rows, "native156", width: 156)
        let evidence = try Self.matrix(rows, "CE291", width: 291)
        let access = modelAccess
        let early = try NativeEarlySourceFontGraph.predict(native: native, evidence: evidence, priors: priors,
            groups: groups, pageSizes: sizes, signals: batch, metadata: graph, access: access, returnStages: returnStages)
        var signals = batch
        signals["pair_affinities"] = early.affinities
        guard let policies = graph["latePolicies"] as? [String: [String: Any]] else { throw Failure.invalidMetadata("late policies") }
        let aliases = graph["sourceIdentityGroups"] as? [String: String] ?? [:]
        let identities = packets.map { aliases[$0.sourceIdentity] ?? $0.sourceIdentity }
        let late = try NativeLateSourceFontGraph.predict(before: early.values, point: early.point,
            native: native, evidence: evidence, priors: priors, groups: groups, pageSizes: sizes,
            signals: signals, models: lateModels, policies: policies, metadata: lateMetadata,
            sourceIDs: identities, access: access, returnStages: returnStages)
        var stages = early.stages
        if returnStages { stages.merge(late.stages) { _, new in new } }
        let context = returnContext ? try Self.makeContext(packets: packets, rows: rows, finalSourceEMs: late.values, geometry: geometry) : nil
        return Result(values: late.values, stages: stages, fontFaces: fontFaces, context: context)
    }

    func weightMeasurements(_ context: SourceFontContext, styles: [[String: Any]]) throws -> NativeSourceWeightMeasurements.Result {
        guard weightReferencePairs.count == 4 else { throw Failure.invalidMetadata("accepted weight reference pairs") }
        let names = ["HiraginoSans-W3", "HiraginoSans-W6", "HiraMinProN-W3", "HiraMinProN-W6"]
        let faces = try names.map { try NativeSourceFontResolver.systemFace(postScriptName: $0).packetDescriptor }
        var extreme:Any
        do { extreme = [faces[1],try NativeSourceFontResolver.systemFace(postScriptName:"HiraginoSans-W9").packetDescriptor] }
        catch NativeSourceFontResolver.Failure.unavailableFont { extreme = ["available":false] }
        return try NativeSourceWeightMeasurements.measure(context, styles: styles, measurementSpec: measurement,
            physicalFontPairs: [[faces[0], faces[1]], extreme, [faces[2], faces[3]]], referencePairs: weightReferencePairs)
    }

    /// Existing source model observations, not a second segmentation/RF call.
    func weightImageEvidence(_ context: SourceFontContext, index: Int, style: [String: Any],
                             sourceEM: Double, kind: String, references: [[String: Any]],
                             ordered: Bool = false, policy: [String: Any]? = nil,
                             sourceAngle: Double? = nil) throws -> [String: Any] {
        guard context.packets.indices.contains(index), sourceEM.isFinite, sourceEM > 0 else {
            throw Failure.invalidSource("weight evidence context")
        }
        let input = context.packets[index]
        try input.validateWeightObservations()
        let words = input.wordEvidence.filter {
            $0.bbox.minX >= 0 && $0.bbox.minY >= 0 &&
            $0.bbox.maxX <= CGFloat(input.width) + 1 && $0.bbox.maxY <= CGFloat(input.height) + 1
        }
        var request: [String: Any] = [
            "width": input.width, "height": input.height, "rgb": Data(input.rgb),
            "ownership": Data(input.ownMask), "valid": Data(input.observationValid),
            "primary": input.primary.withUnsafeBytes { Data($0) },
            "boundary": input.boundary.withUnsafeBytes { Data($0) },
            "rf": input.rf.withUnsafeBytes { Data($0) }, "nativeMask": Data(input.rawNative),
            "bbox": [input.bbox.minX, input.bbox.minY, input.bbox.width, input.bbox.height].map(Double.init),
            "prior": input.fontPriorSourcePixels, "text": input.sourceText, "style": style,
            "measurementSpec": measurement, "memberPolygons": [[Any]](),
            "sourceEm": sourceEM, "kind": kind, "referenceInkPairs": references,
            "sourceAngle": sourceAngle ?? context.angles131[index],
            "includeOrdered": ordered, "GTMaskUsed": false, "inferenceUsesGT": false,
            "wordMembers": words.map { word -> [String: Any] in
                ["text": word.text, "bbox": [word.bbox.minX, word.bbox.minY, word.bbox.width, word.bbox.height].map(Double.init),
                 "polygon": word.polygon.map { [Double($0.x), Double($0.y)] }]
            }
        ]
        if let policy { request["policy"] = policy }
        var error: NSError?
        guard let result = AIDMeasureSourceWeightImageEvidence(request, &error) else {
            throw Failure.extraction(error?.localizedDescription ?? "source weight image evidence")
        }
        return result
    }

    private static func makeContext(packets: [SourceNativeInput], rows: [[String: Any]],
                                    finalSourceEMs: [Double], geometry: SourceGeometry = .originalMembers) throws -> SourceFontContext {
        guard rows.count == packets.count, finalSourceEMs.count == packets.count else {
            throw Failure.extraction("source font context batch")
        }
        let priors = packets.map(\.fontPriorSourcePixels)
        guard priors.allSatisfy({ $0.isFinite && $0 > 0 }),
              finalSourceEMs.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw Failure.extraction("source font context ems")
        }
        // Read the actual measure return. Do not remeasure, substitute a stage,
        // deskew an angle again, or normalize residuals using the final em.
        let style = try matrix(rows, "style187", width: 262)
        let angles: [Double] = try rows.map { row in
            guard let angle = row["angles131"] as? Double, angle.isFinite else {
                throw Failure.extraction("source signal angles131")
            }
            return angle
        }
        return SourceFontContext(packets: packets, packetOrder: Array(packets.indices),
            originalPriors: priors, finalSourceEMs: finalSourceEMs, style187: style, angles131: angles,
            geometryMode: geometry, measuredMemberPolygons: packets.map { geometry == .bboxOnly ? [] : $0.memberPolygons })
    }

    private static func matrix(_ rows: [[String: Any]], _ key: String, width: Int) throws -> Matrix {
        try rows.map { row in
            guard let values = row[key] as? [Double], values.count == width, values.allSatisfy(\.isFinite) else {
                throw Failure.extraction("source signal \(key)")
            }
            return values
        }
    }

    private func assemble(_ rows: [[String: Any]], packets: [SourceNativeInput]) throws -> [String: Any] {
        var signals: [String: Any] = [:]
        let widths: [String: Int] = ["masked65": 180, "cadence69": 122, "colors100": 128, "templates103": 66,
            "paint130": 40, "templates135": 130, "templates143": 130, "joint147": 48, "joint158": 48,
            "templates167": 66, "areas169": 21, "style187": 262]
        for (key, width) in widths { signals[key] = try Self.matrix(rows, key, width: width) }
        var geometry: Matrix = [], physical: Matrix = [], descriptors: Matrix = []
        var componentSizes: [Double] = [], componentRows: [Int] = []
        for (index, row) in rows.enumerated() {
            guard let g = row["geometry128"] as? [String: Any], let x = g["X"] as? [Double], x.count == 45,
                  let p = g["physical"] as? [Double], p.count == 14,
                  let c = row["components75"] as? [String: Any], let f = c["features"] as? Matrix,
                  let s = c["sizes"] as? [Double], f.count == s.count,
                  f.allSatisfy({ $0.count == 198 && $0.allSatisfy(\.isFinite) }), s.allSatisfy({ $0.isFinite && $0 > 0 }) else {
                throw Failure.extraction("source geometry/components")
            }
            geometry.append(x); physical.append(p); descriptors += f; componentSizes += s
            componentRows += Array(repeating: index, count: s.count)
        }
        signals["geometry128.X"] = geometry; signals["geometry128.physical"] = physical
        signals["components75"] = ["features": descriptors, "sizes": componentSizes, "indices": componentRows]
        let identities = measurement["sourceIdentityGroups"] as? [String: String] ?? [:]
        let groups = packets.map { identities[$0.sourceIdentity] ?? $0.sourceIdentity }
        for key in ["76", "84"] {
            guard let bank = banks[key] else { throw Failure.invalidMetadata("prototype bank") }
            signals["neighbors" + key] = try bank.query(descriptors, sizes: componentSizes, rowIndices: componentRows,
                sourceGroups: groups, weighted: key == "84")
        }
        return signals
    }

    private final class PrototypeBank {
        let features: NativeFrozenTensor
        let ratios: [Double]
        let support: [Double]
        let exclusions: [String: [Int]]
        init(record: [String: Any], directory: URL) throws {
            guard let descriptor = record["features"] as? [String: Any],
                  let ratios = record["emPerComponentScale"] as? [Double],
                  let support = record["support"] as? [Double],
                  let rawExclusions = record["excludedBySourceGroup"] as? [String: [Double]] else {
                throw Failure.invalidMetadata("typed TRAIN prototype tensors")
            }
            let features = try NativeFrozenTensor(directory: directory, record: descriptor)
            guard features.shape.count == 2, features.rowWidth == 198, features.rowCount >= 8,
                  ratios.count == features.rowCount, support.count == ratios.count,
                  ratios.allSatisfy({ $0.isFinite && $0 > 0 }), support.allSatisfy({ $0.isFinite && $0 > 0 }) else {
                throw Failure.invalidMetadata("prototype tensor layout")
            }
            var exclusions: [String: [Int]] = [:]
            for (group, values) in rawExclusions {
                guard values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 < Double(features.rowCount) && $0.rounded(.towardZero) == $0 }) else {
                    throw Failure.invalidMetadata("prototype exclusion indices")
                }
                exclusions[group] = values.map(Int.init)
            }
            self.features = features; self.ratios = ratios; self.support = support; self.exclusions = exclusions
        }
        func query(_ descriptors: Matrix, sizes: [Double], rowIndices: [Int], sourceGroups: [String], weighted: Bool) throws -> [String: Any] {
            guard descriptors.count == sizes.count, rowIndices.count == sizes.count else { throw Failure.invalidSource("prototype row binding") }
            var nearest = [[Int]](repeating: [], count: descriptors.count)
            var distances = Matrix(repeating: [], count: descriptors.count)
            // Page-sized groups permit one exclusion set per native BLAS call.
            for group in Set(rowIndices.map { sourceGroups[$0] }).sorted() {
                let ids = descriptors.indices.filter { sourceGroups[rowIndices[$0]] == group }
                var flat: [Float] = []
                for i in ids {
                    var row = descriptors[i].map(Float.init)
                    if weighted {
                        row[193] *= 3; for j in 194..<197 { row[j] *= 3 }
                        let norm = sqrt(row.reduce(Float(0)) { $0 + $1 * $1 })
                        guard norm > 0 else { throw Failure.invalidSource("zero glyph descriptor") }
                        row = row.map { $0 / norm }
                    }
                    flat += row
                }
                let excluded = (exclusions[group] ?? []).map(Int32.init)
                let result = try features.withUnsafeFloat32Buffer { reference in
                    try NativeCosineNeighbors.search(queries: flat, queryCount: ids.count, references: reference,
                        referenceCount: features.rowCount, dimension: 198, excluded: excluded)
                }
                for (offset, index) in ids.enumerated() {
                    nearest[index] = (0..<8).map { Int(result.indices[offset * 8 + $0]) }
                    distances[index] = (0..<8).map { Double(result.distances[offset * 8 + $0]) }
                }
            }
            return ["indices": rowIndices, "sizes": sizes, "distances": distances,
                "ratios": nearest.map { $0.map { ratios[$0] } },
                "support": nearest.map { $0.map { support[$0] } }]
        }
    }
}
