import Foundation

/// One source-only geometric prediction per raw detector query. Physical fits
/// feed features; they are not separately materialized as OCR candidate records.
@available(iOS 18.0, *)
enum NativeOCRRawCanonicalGeometry {
    typealias G = NativeOCRIndividualGeometryHypotheses
    typealias Paint = NativeOCRSourcePaintGeometry
    typealias Base = NativeOCRRawBoundaryFeatures
    typealias Physical = NativeOCRRawPhysicalFeatures
    typealias Generator = NativeOCRRawBoundaryGenerator

    static var featureNames: [String] {
        Base.names + Physical.featureNames.map { "physical/" + $0 } + ["physical/missingFraction"]
            + NativeOCRRFBoundaryProfiles.featureNames.map { "RF113/" + $0 } + ["RF113/missingFraction"]
    }
    enum Failure: Error { case invalidSource, unavailableFeature(Int) }
    struct SourceAdmission: Sendable {
        let model: NativeOCRRawSourceAdmission.Model
        let rf: NativeOCRSourceSupportFeatures155.PreparedRF?
        let detectorConfidences: [Double]
    }
    struct Production: Sendable {
        let output: G.Output
        let physicalReport: Paint.Report
        let features: [[Double]]
        let residuals: [[Double]]
        let rawInputCount: Int
        let contextRawInputCount: Int
        let numericPredictions: Int
        let queryOrdinals: [Int]
        var auxiliaryReferencePolygons: [[[Double]]] = []
    }
    struct CombinedProduction: Sendable {
        let output: G.Output
        let primary: Production
        let auxiliary: Production
        /// Factories run only in the two branches. The final union reuses their
        /// existing records and does not propose another geometry bank.
        var materializedRecords: Int { primary.numericPredictions + auxiliary.numericPredictions }
    }

    static func produceCombined(requestID: String, frame: NativeOCRRGBAFrame,
                                originals: [NativeOCRSourceOwnedRailPartition.Original],
                                auxiliaryOriginals: [NativeOCRSourceOwnedRailPartition.Original],
                                rfPrimitives: [Base.RFPrimitive], grid: NativeRFDETRSemanticGrid,
                                primaryModel: Generator.Model, auxiliaryModel: Generator.Model,
                                sourceAdmission: SourceAdmission?, captureFeatures: Bool = false) throws -> CombinedProduction {
        let primary = try produce(requestID: requestID, frame: frame, originals: originals,
            rfPrimitives: rfPrimitives, grid: grid, model: primaryModel,
            captureFeatures: captureFeatures, sourceAdmission: sourceAdmission)
        let auxiliary = try produce(requestID: requestID, frame: frame, originals: originals,
            rfPrimitives: rfPrimitives, grid: grid, model: auxiliaryModel,
            captureFeatures: captureFeatures, auxiliaryOriginals: auxiliaryOriginals)
        let records = (primary.output.individuals + auxiliary.output.individuals).flatMap(\.provenance)
        guard records.count == primary.numericPredictions + auxiliary.numericPredictions,
              Set(records.map(\.sourceIndex)).count == records.count else { throw Failure.invalidSource }
        let output = G.emit(requestID: requestID, corrected: records, originals: [], layout: [], refinements: [],
            mode: .sourceOriginalLayoutRefinedAndCorrectedV3)
        return .init(output: output, primary: primary, auxiliary: auxiliary)
    }

    /// Measurements for seedless runtime queries can only share a retiring
    /// producer job if their ordered quad is repeated. Keep the complete bank
    /// for every pixel, ownership, RF and crop calculation in both schedules.
    static func auxiliaryMeasurementIndices(originals: [NativeOCRSourceOwnedRailPartition.Original],
                                            auxiliary: [NativeOCRSourceOwnedRailPartition.Original]) -> Set<Int>? {
        if auxiliary.isEmpty { return [] }
        var seen = Set(originals.map(\.polygon))
        for row in auxiliary {
            guard row.detectorSeedEvidence == nil, seen.insert(row.polygon).inserted else { return nil }
        }
        return Set(originals.count..<(originals.count + auxiliary.count))
    }

    static func produce(requestID: String, frame: NativeOCRRGBAFrame,
                        originals: [NativeOCRSourceOwnedRailPartition.Original],
                        rfPrimitives: [Base.RFPrimitive], grid: NativeRFDETRSemanticGrid,
                        model: Generator.Model, captureFeatures: Bool = false,
                        auxiliaryOriginals: [NativeOCRSourceOwnedRailPartition.Original]? = nil,
                        sourceAdmission: SourceAdmission? = nil,
                        auxiliaryReferenceModel: Generator.Model? = nil,
                        auxiliaryOutputOnly: Bool = false) throws -> Production {
        guard Paint.enabled, Paint.sourceFirstGeneration, Paint.recoveryV3,
              grid.width == frame.width, grid.height == frame.height,
              grid.hasValidWeightedMeanProbabilities,
              let preparedRF = NativeOCRRFBoundaryProfiles.PreparedGrid(grid: grid) else {
            throw Failure.invalidSource
        }
        let primitives = rfPrimitives.map { primitive -> NativeOCRSourceContext50V2.Primitive in
            let b = primitive.sourceBounds
            return .init(canonicalClass: primitive.classID, confidence: primitive.confidence,
                polygon: [[b.x, b.y], [b.x + b.width, b.y], [b.x + b.width, b.y + b.height], [b.x, b.y + b.height]])
        }
        // Auxiliary detector roots are a separate emission family. The primary
        // raw inventory remains immutable for uniform CC features, and none of
        // its predictions are re-emitted in this invocation.
        let queries = auxiliaryOriginals ?? originals
        let queryOffset = auxiliaryOriginals == nil ? 0 : originals.count
        let context = originals + (auxiliaryOriginals ?? [])
        let recordOffset = context.count + (auxiliaryOriginals == nil ? 0 : originals.count)
        if let sourceAdmission {
            guard sourceAdmission.detectorConfidences.count == originals.count else { throw Failure.invalidSource }
        }
        let admitted = queries.indices.filter { index in
            guard auxiliaryOriginals == nil, let admission = sourceAdmission,
                  let feature = NativeOCRSourceSupportFeatures155.extract(rawPolygon: queries[index].polygon,
                    detectorConfidence: admission.detectorConfidences[index],
                    detectorSeed: queries[index].detectorSeedEvidence,
                    sourceWidth: frame.width, sourceHeight: frame.height, rf: admission.rf) else { return true }
            return admission.model.keep(rawFeatures: feature.features)
        }
        // The accepted auxiliary discovery requires a frozen novelty reference
        // for every raw root. Share physical measurements/features with primary
        // prediction rather than running another source-pixel producer pass.
        let selected = auxiliaryReferenceModel == nil ? admitted : Array(queries.indices)
        let admittedSet = Set(admitted)
        let queryOrdinals = selected.map { queryOffset + $0 }
        let measurementIndices: Set<Int>?
        if auxiliaryOutputOnly, let auxiliaryOriginals {
            measurementIndices = auxiliaryMeasurementIndices(originals: originals, auxiliary: auxiliaryOriginals)
        } else {
            measurementIndices = auxiliaryOriginals == nil && sourceAdmission != nil ? Set(queryOrdinals) : nil
        }
        let physical = try Paint.produce(requestID: requestID, frame: frame, originals: context,
            currentCorrections: [], rf: primitives, reservedRecords: [], measurementsOnly: true,
            measurementQueryIndices: measurementIndices)
        guard physical.records.isEmpty else { throw Failure.invalidSource }
        let inventory = Physical.prepare(rawInventory: originals)
        var observations = [Physical.PhysicalObservation]()
        for context in physical.report.contextMeasurements ?? [] {
            guard let actual = context.actualQuery else { continue }
            for proof in actual.provenance {
                guard proof.origin == .sourceOriginal, let index = proof.originalDetectorIndex else { continue }
                observations.append(.init(originalDetectorIndex: index, sourceMembers: proof.sourceMembers.sorted(),
                    isSourceOriginal: true, actualQueryPolygon: actual.polygon.map { [$0.x, $0.y] },
                    queryPolygon: context.queryPolygon, measurement: context.measurement))
            }
        }
        var records = [G.Record](), featureRows = [[Double]](), residualRows = [[Double]]()
        var referencePolygons: [[[Double]]] = []
        records.reserveCapacity(queries.count)
        func provider(_ values: [Double]) -> [Double] {
            values.map { $0.isFinite ? $0 : -1 } +
                [Double(values.filter { !$0.isFinite }.count) / Double(max(1, values.count))]
        }
        func component(_ value: NativeOCRDetectorSeedEvidence.Component) -> Base.Component {
            .init(meanProbability: value.meanProbability,
                runs: value.runs.map { .init(x: $0.x, y: $0.y, count: $0.count) })
        }
        for index in selected {
            let original = queries[index]
            let queryOrdinal = queryOffset + index
            let seed = original.detectorSeedEvidence.map { value in
                Base.DBEvidence(sourceWidth: value.sourceWidth, sourceHeight: value.sourceHeight,
                    mapFullWidth: value.mapFullWidth, mapFullHeight: value.mapFullHeight,
                    components: value.components.map(component), ownershipVersion: value.ownershipVersion,
                    completeCCScan: value.completeCCScan, ambiguousComponents: value.ambiguousComponents?.map(component),
                    candidateComponents: value.candidateComponents?.map { .init(component: component($0.component)) })
            }
            guard let base = Base.extract(rawPolygon: original.polygon, frame: frame,
                    detectorSeed: seed, rfPrimitives: rfPrimitives),
                  let measured = Physical.extract(query: original, queryOrdinal: queryOrdinal,
                    inventory: inventory, observations: observations) else {
                throw Failure.unavailableFeature(index)
            }
            let rf = NativeOCRRFBoundaryProfiles.extract(polygon: original.polygon, prepared: preparedRF)
            let features = base.features.map(Double.init) + provider(measured) + provider(rf.features.map(Double.init))
            if let reference = auxiliaryReferenceModel {
                guard let residual = reference.residual(features:features),
                      let polygon = Generator.apply(rawQuad:original.polygon,residual:residual,
                        frame:.init(width:Double(frame.width),height:Double(frame.height))) else {
                    throw Failure.unavailableFeature(index)
                }
                referencePolygons.append(polygon)
            }
            guard admittedSet.contains(index) else { continue }
            guard let residual = model.residual(features: features),
                  let polygon = Generator.apply(rawQuad: original.polygon, residual: residual,
                    frame: .init(width: Double(frame.width), height: Double(frame.height))) else {
                throw Failure.unavailableFeature(index)
            }
            // The raw query establishes context, not ownership of the detached prediction.
            records.append(.init(requestID: requestID, sourceIndex: recordOffset + index,
                sourceParent: queryOrdinal, sourceMembers: [], alternativeID: "raw-canonical-8d/\(queryOrdinal)",
                origin: .corrected, originalDetectorIndex: nil,
                polygon: polygon.map { .init(x: $0[0], y: $0[1]) }))
            if captureFeatures { featureRows.append(features); residualRows.append(residual) }
        }
        let output = G.emit(requestID: requestID, corrected: records, originals: [], layout: [], refinements: [],
            mode: .sourceOriginalLayoutRefinedAndCorrectedV3)
        return .init(output: output, physicalReport: physical.report, features: featureRows,
            residuals: residualRows, rawInputCount: queries.count, contextRawInputCount: originals.count,
            numericPredictions: records.count, queryOrdinals: admitted.map { queryOffset + $0 },
            auxiliaryReferencePolygons: referencePolygons)
    }
}
