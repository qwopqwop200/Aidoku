import Foundation

/// Source-pixel measurements appended after incumbent heads. No GT, text decoder,
/// page routing, learned output replacement, or inferred detector ownership.
@available(iOS 18.0, *)
enum NativeOCRSourcePaintGeometry {
    typealias G = NativeOCRIndividualGeometryHypotheses
    static let environmentKey = "AIDOKU_OCR_SOURCE_PAINT_GEOMETRY"
    @TaskLocal static var mainCanonicalPolicy = false
    static var enabled: Bool { mainCanonicalPolicy || ProcessInfo.processInfo.environment[environmentKey] == "1" }
    static let generationPolicyEnvironmentKey = "AIDOKU_OCR_PAINT_GENERATION_POLICY"
    private struct GenerationPolicy: Decodable {
        let schema: String
        let disabledMechanisms: [String]
    }
    // Immutable per-process global execution plan. Invalid/missing policy restores
    // every producer. No request, geometry, GT, or page identity is consulted.
    private static let disabledGenerationMechanisms: Set<String> = {
        guard let path = ProcessInfo.processInfo.environment[generationPolicyEnvironmentKey],
              !path.isEmpty, let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let policy = try? JSONDecoder().decode(GenerationPolicy.self, from: data),
              policy.schema == "source-paint-generator-plan-v1",
              policy.disabledMechanisms.count <= 128,
              policy.disabledMechanisms.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }),
              Set(policy.disabledMechanisms).count == policy.disabledMechanisms.count else { return [] }
        return Set(policy.disabledMechanisms)
    }()
    static func shouldGenerate(_ mechanism: String) -> Bool {
        !disabledGenerationMechanisms.contains(mechanism)
    }
    static let offerPortfolioEnvironmentKey = "AIDOKU_OCR_PAINT_OFFER_PORTFOLIO"
    static let sourceFirstEnvironmentKey = "AIDOKU_OCR_GENERATION_SOURCE_FIRST"
    static var sourceFirstGeneration: Bool { mainCanonicalPolicy || ProcessInfo.processInfo.environment[sourceFirstEnvironmentKey] == "1" }
    static var recoveryV3: Bool {
        mainCanonicalPolicy || sourceFirstGeneration && ProcessInfo.processInfo.environment["AIDOKU_OCR_GENERATION_RECOVERY_V3"] == "1"
    }

    /// Preserve an observed detector boundary when the compact physical output
    /// disagrees with it. This never schedules pixel work or invents geometry.
    static func sourceFirstRecovery(originals: [G.Record], current: [G.Record]) -> [G.Record] {
        guard sourceFirstGeneration,
              let value = ProcessInfo.processInfo.environment["AIDOKU_OCR_GENERATION_SOURCE_RECOVERY_IOU"],
              let threshold = Double(value), threshold.isFinite, threshold > 0, threshold <= 1 else { return [] }
        return originals.filter { original in
            !current.contains {
                NativeOCRGeometryDeduplication.polygonIoU(original.polygon, $0.polygon) >= threshold
            }
        }
    }

    /// Per-invocation physical support, never source ownership. Two offers may
    /// share this support while all detached membership remains UNKNOWN.
    /// Only a directly retained offer of the same mechanism/layer can retire
    /// another offer. Missing support and complete-ink observations fail open.
    final class OfferPortfolio {
        private struct Key: Hashable {
            let mechanism: String
            let layer: String
            let cells: [Int]
        }
        private let cells: [G.Point]
        private var retained: [Key: [[G.Point]]] = [:]
        private var supportCache: [[[Double]]: [Int]] = [:]
        private(set) var suppressedOffers = 0

        init(originals: [NativeOCRSourceOwnedRailPartition.Original], width: Int, height: Int) {
            var observed = Set<G.Point>()
            for original in originals {
                guard let seed = original.detectorSeedEvidence, seed.isValid,
                      seed.completeCCScan == true, seed.sourceWidth == width, seed.sourceHeight == height else { continue }
                // Full-grid run coordinates already include map origin. These
                // points only index observed detector contact, not a merged seed.
                let sx = Double(width) / Double(seed.mapFullWidth)
                let sy = Double(height) / Double(seed.mapFullHeight)
                for component in seed.components { for run in component.runs {
                    for x in run.x..<(run.x + run.count) {
                        observed.insert(.init(x: (Double(x) + 0.5) * sx, y: (Double(run.y) + 0.5) * sy))
                    }
                } }
            }
            cells = observed.sorted { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }
        }

        func accepts(_ measurement: Measurement) -> Bool {
            guard measurement.terminalEvidence == nil, !cells.isEmpty,
                  measurement.polygon.count == 4,
                  measurement.polygon.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) else { return true }
            let polygon = measurement.polygon.map { G.Point(x: $0[0], y: $0[1]) }
            let support: [Int]
            if let cached = supportCache[measurement.polygon] { support = cached }
            else {
                let minX = polygon.map(\.x).min()!, maxX = polygon.map(\.x).max()!
                let minY = polygon.map(\.y).min()!, maxY = polygon.map(\.y).max()!
                var low = 0, high = cells.count
                while low < high {
                    let middle = low + (high - low) / 2
                    if cells[middle].y < minY { low = middle + 1 } else { high = middle }
                }
                var hits: [Int] = [], index = low
                while index < cells.count, cells[index].y <= maxY {
                    let p = cells[index]
                    if p.x >= minX, p.x <= maxX {
                        var positive = true, negative = true
                        for edge in 0..<4 {
                            let a = polygon[edge], b = polygon[(edge + 1) % 4]
                            let cross = (b.x-a.x)*(p.y-a.y) - (b.y-a.y)*(p.x-a.x)
                            positive = positive && cross >= 0; negative = negative && cross <= 0
                        }
                        if positive || negative { hits.append(index) }
                    }
                    index += 1
                }
                support = hits
                supportCache[measurement.polygon] = support
            }
            guard !support.isEmpty else { return true }
            let key = Key(mechanism: measurement.mechanism, layer: measurement.layer, cells: support)
            if retained[key, default: []].contains(where: {
                NativeOCRGeometryDeduplication.polygonIoU($0, polygon) >= 0.8
            }) {
                suppressedOffers += 1
                return false
            }
            retained[key, default: []].append(polygon)
            return true
        }
    }
    struct Query: Codable, Hashable, Sendable {
        let polygon: [[Double]]
        let sourceIndex: Int
        let sourceMembers: [Int]
        var contextSourceIndices: [Int]? = nil
        var searchPolygon: [[Double]]? = nil
    }
    /// All inputs read by pixel measurements. A provenance-only source index
    /// cannot turn identical pixel work into another measurement job.
    private struct QueryWorkKey: Hashable {
        let polygon: [[Double]]
        let members: [Int]
        let context: [Int]?
        let searchPolygon: [[Double]]?
        init(_ query: Query, includeContextReceipt: Bool = true) {
            polygon = query.polygon; members = query.sourceMembers.sorted()
            // Context indices are a receipt only: no measurement reads them.
            // Explicit membership, ordered geometry and search scope remain inputs.
            context = includeContextReceipt ? query.contextSourceIndices?.sorted() : nil
            searchPolygon = query.searchPolygon
        }
    }
    struct Measurement: Codable, Sendable {
        let polygon: [[Double]]
        let layer: String
        let mechanism: String
        let diagnostics: [String: Double]
        var terminalEvidenceGroup: String? = nil
        var terminalEvidence: TerminalEvidence? = nil
    }
    // estimatedDB is decoding-only compatibility for archived measurement receipts.
    enum TerminalEvidence: String, Codable, Sendable { case estimatedDB, completeSourceInk }
    struct PixelROI: Sendable {
        let width: Int, height: Int, originX: Int, originY: Int
        let rgb: [UInt8]
        func pixel(x: Int, y: Int) -> (Double, Double, Double) {
            let i = (y * width + x) * 3
            return (Double(rgb[i]), Double(rgb[i+1]), Double(rgb[i+2]))
        }
    }
    struct Observation: Codable, Sendable {
        let queryOrdinal: Int
        let queryPolygon: [[Double]]
        let actualQuery: G.Individual?
        var contextualQuery: Query? = nil
        let measurement: Measurement
        let record: G.Record
        // Query provenance is context; detached paint is not certified DB membership.
        let membership: String
        var duplicateOf: String? = nil
        var emitted = false
    }
    /// Physical boundary evidence for a source feature vector, never offered as
    /// another OCR/candidate record by canonical generation.
    struct ContextMeasurement: Codable, Sendable {
        let queryOrdinal: Int
        let queryPolygon: [[Double]]
        let actualQuery: G.Individual?
        let measurement: Measurement
    }
    struct Report: Codable, Sendable {
        let schema: String
        let enabled: Bool
        let queryCount: Int
        var contextualQueryCount = 0
        var originalQueryCount = 0
        var layoutQueryCount = 0
        var sourceGroupQueryCount = 0
        var processedQueryCount = 0
        var scheduledQueryCount = 0
        var duplicateQueriesSkipped = 0
        var pixelCropBuilds = 0
        var pixelCropCacheHits = 0
        var peakCachedRGBBytes = 0
        var pixelCropCachePolicy: String? = nil
        var pixelCropCacheInsertions: Int? = nil
        var chromaticMeasurementCacheHits = 0
        var peakCachedChromaticMeasurements = 0
        var duplicateContextQueriesSkipped = 0
        var retiredChromaticMeasurementOffers = 0
        var chromaticMeasurementPolicy = "exact-ordered-query-retirement-v1"
        var discardedTruncatedMeasurements = 0
        var queryPolicy = "canonical-source-stages-only-v1"
        var sourceFrameIdentity: String? = nil
        var sourceFrameEvidenceValid = true
        var disabledGenerationMechanisms: [String] = []
        var skippedExactProducerJobs = 0
        var retiredExactProducerMeasurements = 0
        var offerPortfolioPolicy: String? = nil
        var portfolioSuppressedOffers: Int? = nil
        var portfolioRetiredRecords: Int? = nil
        var measuredCount = 0
        var exactDuplicateMeasurements = 0
        var addedUniqueRecords = 0
        var familyElapsedSeconds: [String: Double] = [:]
        var familyCalls: [String: Int] = [:]
        var observations: [Observation] = []
        var emittedCount = 0
        var finalized = false
        var finalIndividualCount: Int? = nil
        var notFoundAfterEmit: [G.Record] = []
        var skippedNonSourceQueries: Int? = nil
        var skippedEagerFamilyCalls: Int? = nil
        var actualProducerMeasurementCount: Int? = nil
        var measurementsOnly: Bool? = nil
        var contextMeasurements: [ContextMeasurement]? = nil
        var expandedSourceWindows: Int? = nil
        var privateColorProbeReads: Int? = nil
        var privateColorRecoveryQueries: Int? = nil
    }
    private struct ReturnedToken: Hashable {
        let requestID: String
        let sourceIndex: Int
        let alternativeID: String
        let polygon: [G.Point]
        init(_ record: G.Record) {
            requestID = record.requestID; sourceIndex = record.sourceIndex
            alternativeID = record.alternativeID; polygon = record.polygon
        }
    }
    struct Production: Sendable {
        let records: [G.Record]
        let report: Report
        func finalized(actualOutput: [G.Individual]) -> Report {
            let present = Set(actualOutput.flatMap(\.provenance).map(ReturnedToken.init))
            var r = report
            for i in r.observations.indices {
                r.observations[i].emitted = present.contains(ReturnedToken(r.observations[i].record))
            }
            r.emittedCount = r.observations.filter(\.emitted).count
            r.finalized = true
            r.finalIndividualCount = actualOutput.count
            r.notFoundAfterEmit = records.filter { !present.contains(ReturnedToken($0)) }
            return r
        }
    }
    enum Failure: Error { case invalidFrame, sourceIndexOverflow }

    /// Only live physical measurements remain. The historical estimated-DB
    /// alternative producer was removed; retain frame/finite validity checks.
    static func admissibleMeasurements(_ measured: [Measurement], frame: NativeOCRRGBAFrame) -> [Measurement] {
        measured.filter { valid($0.polygon, frame: frame) && $0.diagnostics.values.allSatisfy(\.isFinite) }
    }

    /// Exactly one selected localization per immutable source-stage entry.
    /// Binding requires the producer's exact input record, never overlap, a
    /// virtual index guess, a page number or a later geometry candidate.
    static func canonicalSeeds(_ bases: [G.Record], records: [G.Record],
                               decisions: [(inputs: [G.Record], outputAlternativeID: String?)]) -> [G.Record] {
        let inventory = Dictionary(grouping: records, by: \.alternativeID)
        return bases.map { base in
            let matches = decisions.compactMap { decision -> G.Record? in
                guard decision.inputs.contains(base), let id = decision.outputAlternativeID,
                      let outputs = inventory[id], outputs.count == 1,
                      outputs[0].requestID == base.requestID else { return nil }
                return outputs[0]
            }
            // Conflicting/absent calibration cannot multiply work or delete a
            // source. Its immutable source entry is the fallback.
            return matches.count == 1 ? matches[0] : base
        }
    }

    static func produce(requestID: String, frame: NativeOCRRGBAFrame,
                        originals: [NativeOCRSourceOwnedRailPartition.Original],
                        currentCorrections: [G.Record], rf: [NativeOCRSourceContext50V2.Primitive],
                        reservedRecords: [G.Record], sourceGroups: [G.Record] = [],
                        originalSeeds: [G.Record]? = nil, layoutScopes: [G.Record] = [],
                        measurementsOnly: Bool = false,
                        measurementQueryIndices: Set<Int>? = nil) throws -> Production {
        var report = Report(schema: "source-paint-physical-observations-v1", enabled: enabled,
                            queryCount: currentCorrections.count)
        report.disabledGenerationMechanisms = disabledGenerationMechanisms.sorted()
        guard enabled else { return .init(records: [], report: report) }
        if measurementsOnly {
            guard sourceFirstGeneration else { throw Failure.invalidFrame }
            report.measurementsOnly = true
            report.contextMeasurements = []
        }
        if let measurementQueryIndices {
            guard measurementsOnly, sourceFirstGeneration,
                  measurementQueryIndices.allSatisfy({ originals.indices.contains($0) }) else {
                throw Failure.invalidFrame
            }
        }
        guard frame.width > 0, frame.height > 0, frame.width <= Int.max/4,
              frame.bytesPerRow >= frame.width*4, frame.bytesPerRow <= Int.max/frame.height,
              frame.bytes.count >= frame.bytesPerRow*frame.height else { throw Failure.invalidFrame }
        let fingerprint = NativeOCRFrameDigestBuilder.fingerprint(of: frame)
        report.sourceFrameIdentity = "\(fingerprint.width)x\(fingerprint.height):\(fingerprint.primary):\(fingerprint.verifier)"
        guard originals.allSatisfy({ original in
            guard let seed = original.detectorSeedEvidence else { return true }
            return seed.sourceWidth == frame.width && seed.sourceHeight == frame.height
        }) else {
            report.sourceFrameEvidenceValid = false
            return .init(records: [], report: report)
        }
        // Hypotheses are reserved for identity allocation only. They NEVER
        // become pixel work. A learned/refined alternative is not a new source.
        let reserved = reservedRecords + currentCorrections + (originalSeeds ?? []) + layoutScopes
        var next = max(originals.count-1, reserved.flatMap {
            [$0.sourceIndex, $0.sourceParent] + Array($0.sourceMembers) + ($0.originalDetectorIndex.map { [$0] } ?? [])
        }.max() ?? -1)
        var records: [G.Record] = []
        var seen: [[G.Point]: G.Record] = [:]
        report.actualProducerMeasurementCount = 0
        func measure(_ family: String, _ body: () -> [Measurement]) -> [Measurement] {
            let start = ProcessInfo.processInfo.systemUptime
            let result = body()
            report.familyElapsedSeconds[family, default: 0] += ProcessInfo.processInfo.systemUptime-start
            report.familyCalls[family, default: 0] += 1
            report.actualProducerMeasurementCount? += result.count
            return result
        }
        let sourceFirst = sourceFirstGeneration
        if sourceFirst { report.queryPolicy = "raw-source-once-lazy-primary-v2" }
        if recoveryV3 {
            report.queryPolicy = "raw-source-once-physical-recovery-v3"
            report.expandedSourceWindows = 0
            report.privateColorProbeReads = 0
            report.privateColorRecoveryQueries = 0
        }
        let correctionQueries = sourceFirst ? [] : currentCorrections
        let layoutQueries = sourceFirst ? [] : layoutScopes
        var work: [(Query, G.Individual?)] = correctionQueries.map { record in
            (Query(polygon: record.polygon.map { [$0.x, $0.y] }, sourceIndex: record.sourceIndex,
                   sourceMembers: record.sourceMembers.sorted()),
             G.Individual(polygon: record.polygon, provenance: [record]))
        }
        if let originalSeeds, originalSeeds.count != originals.count { throw Failure.invalidFrame }
        for (index, original) in originals.enumerated() {
            if let measurementQueryIndices, !measurementQueryIndices.contains(index) { continue }
            guard valid(original.polygon, frame: frame) else { continue }
            let polygon = original.polygon.map { G.Point(x: $0[0], y: $0[1]) }
            let raw = G.Record(requestID: requestID, sourceIndex: index, sourceParent: index,
                sourceMembers: [index], alternativeID: "original/\(index)", origin: .sourceOriginal,
                originalDetectorIndex: index, polygon: polygon)
            let record = sourceFirst ? raw : originalSeeds?[index] ?? raw
            work.append((Query(polygon: record.polygon.map { [$0.x, $0.y] }, sourceIndex: record.sourceIndex,
                               sourceMembers: record.sourceMembers.sorted()),
                         G.Individual(polygon: record.polygon, provenance: [record])))
        }
        report.originalQueryCount = measurementQueryIndices?.count ?? originals.count
        for scope in layoutQueries {
            work.append((Query(polygon: scope.polygon.map { [$0.x, $0.y] }, sourceIndex: scope.sourceIndex,
                               sourceMembers: scope.sourceMembers.sorted()),
                         G.Individual(polygon: scope.polygon, provenance: [scope])))
        }
        report.layoutQueryCount = layoutQueries.count
        // A source-owned fragment group is an independent observed scope, not
        // an alternative angle/size prediction. Schedule each member set once.
        var seenGroups = Set<Set<Int>>()
        for group in sourceGroups where group.origin == .sourceRefinement && group.sourceMembers.count > 1 {
            guard group.requestID == requestID,
                  group.sourceMembers.allSatisfy({ originals.indices.contains($0) }),
                  seenGroups.insert(group.sourceMembers).inserted else { continue }
            work.append((Query(polygon: group.polygon.map { [$0.x, $0.y] }, sourceIndex: group.sourceIndex,
                               sourceMembers: group.sourceMembers.sorted()),
                         G.Individual(polygon: group.polygon, provenance: [group])))
            report.sourceGroupQueryCount += 1
        }
        let contextual = sourceFirst ? [] : NativeOCRSourceChromaticPaint.contextualQueries(originals: originals)
        report.contextualQueryCount = contextual.count + report.sourceGroupQueryCount
        work += contextual.map { ($0, nil) }
        // Search contexts come from immutable detector/RF evidence, never from
        // iterating calibration alternatives or newly produced paint records.
        for (index, original) in originals.enumerated() where !sourceFirst {
            let base = Query(polygon: original.polygon, sourceIndex: index, sourceMembers: [index])
            if let bounds = NativeOCRSourcePaintCompleteness.requiredSourceBounds(query: base, originals: originals, rf: rf) {
                let context = Query(polygon: original.polygon, sourceIndex: index, sourceMembers: [index],
                                    contextSourceIndices: [index], searchPolygon: bounds)
                work.append((context, nil)); report.contextualQueryCount += 1
            }
        }
        if sourceFirst {
            report.skippedNonSourceQueries = currentCorrections.count + layoutScopes.count
            report.skippedEagerFamilyCalls = 0
        }
        // Layout scopes are immutable shared-head contexts. Keep every physical
        // offer they demonstrate even when another query found the same cells.
        let reservedLayoutQueries = Set(layoutScopes.map { scope in
            QueryWorkKey(Query(polygon: scope.polygon.map { [$0.x, $0.y] }, sourceIndex: scope.sourceIndex,
                               sourceMembers: scope.sourceMembers.sorted()), includeContextReceipt: false)
        })
        var seenQueries = Set<QueryWorkKey>()
        var seenPixelQueries = Set<QueryWorkKey>()
        var scheduled: [(query: Query, individual: G.Individual?, ordinal: Int)] = []
        var legacyOrdinal = 0
        for (query, individual) in work {
            guard seenQueries.insert(QueryWorkKey(query)).inserted else {
                report.duplicateQueriesSkipped += 1
                continue
            }
            // Preserve the old schedule ordinal for every surviving job, so
            // removing a receipt-only alias cannot rename later paint records.
            let ordinal = legacyOrdinal
            legacyOrdinal += 1
            guard seenPixelQueries.insert(QueryWorkKey(query, includeContextReceipt: false)).inserted else {
                report.duplicateQueriesSkipped += 1
                report.duplicateContextQueriesSkipped += 1
                continue
            }
            scheduled.append((query, individual, ordinal))
        }
        report.scheduledQueryCount = scheduled.count
        // Cache only exact source-pixel windows. Geometry/ownership-sensitive
        // measurements are NOT reused across different queries.
        // The immutable schedule also gives each window's remaining lifetime.
        // Never retain a single-use/finished window: it can evict useful RGB
        // without saving any work. Query order and provenance remain unchanged.
        let cropPlan = scheduled.map { entry -> CropBounds? in
            guard valid(entry.query.polygon, frame: frame) else { return nil }
            guard let original = cropBounds(frame, entry.query.searchPolygon ?? entry.query.polygon) else { return nil }
            guard recoveryV3, entry.query.searchPolygon == nil,
                  let extent = NativeOCRSourcePaintCompleteness.requiredSourceBounds(
                    query: entry.query, originals: originals, rf: rf),
                  let extended = cropBounds(frame, extent) else { return original }
            let x = min(original.x, extended.x), y = min(original.y, extended.y)
            let right = max(original.x + original.width, extended.x + extended.width)
            let bottom = max(original.y + original.height, extended.y + extended.height)
            guard right - x <= 1_500_000 / (bottom - y) else { return original }
            let union = CropBounds(x: x, y: y, width: right - x, height: bottom - y)
            if union != original { report.expandedSourceWindows? += 1 }
            // A window is not a second query and does not change ownership or
            // searchPolygon's completeness-only dispatch semantics.
            return union
        }
        var remainingCrops: [CropBounds: Int] = [:]
        for bounds in cropPlan.compactMap({ $0 }) { remainingCrops[bounds, default: 0] += 1 }
        report.pixelCropCachePolicy = "exact-window-remaining-uses-v1"
        report.pixelCropCacheInsertions = 0
        let cacheByteLimit = 8 * 1024 * 1024
        var cropCache: [CropBounds: PixelROI] = [:]
        var cropOrder: [CropBounds] = []
        var cachedBytes = 0
        // Chromatic reads ordered geometry and fixed ROI/original/RF banks,
        // never source membership or the context receipt. Retire a successful
        // exact job instead of replaying its offers. Membership-sensitive
        // families still execute for every distinct explicit member set.
        // Keep only counts, bounded by the immutable schedule; no RGB/results.
        var completedChromatic: [[[Double]]: Int] = [:]
        let generationLedger = NativeOCRSourcePaintColumnPartition.GenerationLedger()
        let portfolio: OfferPortfolio?
        if !sourceFirst, ProcessInfo.processInfo.environment[offerPortfolioEnvironmentKey] == "exact-source-support-preserve-layout-v1" {
            portfolio = OfferPortfolio(originals: originals, width: frame.width, height: frame.height)
            report.offerPortfolioPolicy = "exact-source-support-preserve-layout-v1"
        } else { portfolio = nil }
        var retainedOfferKeys = Set<[G.Point]>()
        var retiredPortfolioOffers = 0
        for (position, entry) in scheduled.enumerated() {
            let query = entry.query, individual = entry.individual, ordinal = entry.ordinal
            let polygon = query.polygon
            guard let bounds = cropPlan[position] else { continue }
            let remaining = (remainingCrops[bounds] ?? 1)-1
            if remaining == 0 { remainingCrops.removeValue(forKey: bounds) }
            else { remainingCrops[bounds] = remaining }
            let roi: PixelROI
            if let cached = cropCache[bounds] {
                roi = cached
                report.pixelCropCacheHits += 1
                if remaining == 0 {
                    cachedBytes -= cached.rgb.count
                    cropCache.removeValue(forKey: bounds)
                    cropOrder.removeAll { $0 == bounds }
                }
            } else {
                roi = crop(frame, bounds)
                report.pixelCropBuilds += 1
                let bytes = roi.rgb.count
                if remaining > 0, bytes <= cacheByteLimit {
                    while cachedBytes + bytes > cacheByteLimit, !cropOrder.isEmpty {
                        let oldest = cropOrder.removeFirst()
                        cachedBytes -= cropCache.removeValue(forKey: oldest)?.rgb.count ?? 0
                    }
                    cropCache[bounds] = roi
                    cropOrder.append(bounds)
                    cachedBytes += bytes
                    report.pixelCropCacheInsertions? += 1
                    report.peakCachedRGBBytes = max(report.peakCachedRGBBytes, cachedBytes)
                }
            }
            report.processedQueryCount += 1
            var measured: [Measurement]
            if query.searchPolygon != nil {
                measured = measure("completeness-search") { NativeOCRSourcePaintCompleteness.measureSearch(roi: roi, query: query, originals: originals, rf: rf, generationLedger: generationLedger) }
            } else if sourceFirst {
                // Resolve one physical source before invoking fallback mechanisms.
                // A proposal from another head never becomes another pixel query.
                measured = measure("medial") {
                    NativeOCRSourcePaintMedialGeometry.measure(roi: roi, query: query, originals: originals,
                        rf: rf, generationLedger: generationLedger)
                }
                var calls = 1
                if admissibleMeasurements(measured, frame: frame).isEmpty {
                    calls += 1
                    measured = measure("chromatic") {
                        NativeOCRSourceChromaticPaint.measure(roi: roi, query: query, originals: originals, rf: rf)
                    }
                }
                if admissibleMeasurements(measured, frame: frame).isEmpty {
                    calls += 1
                    measured = measure("achromatic") {
                        NativeOCRSourceAchromaticPaint.measure(roi: roi, query: query, originals: originals,
                            rf: rf, generationLedger: generationLedger)
                    }
                }
                if admissibleMeasurements(measured, frame: frame).isEmpty {
                    calls += 1
                    measured = measure("column") {
                        NativeOCRSourcePaintColumnPartition.measure(roi: roi, query: query, originals: originals,
                            rf: rf, generationLedger: generationLedger)
                    }
                }
                if admissibleMeasurements(measured, frame: frame).isEmpty {
                    calls += 1
                    measured = measure("completeness") {
                        NativeOCRSourcePaintCompleteness.measure(roi: roi, query: query, originals: originals,
                            rf: rf, generationLedger: generationLedger)
                    }
                }
                if recoveryV3, calls == 1, query.sourceMembers.count == 1,
                   let owner = query.sourceMembers.first, originals.indices.contains(owner),
                   let incumbent = admissibleMeasurements(measured, frame: frame).first {
                    let support = NativeOCRSourceChromaticPaint.recoveryV3Support(roi: roi,
                        queryPolygon: query.polygon, evidence: originals[owner].detectorSeedEvidence,
                        incumbentPolygon: incumbent.polygon)
                    report.privateColorProbeReads? += support.pixelReads
                    if support.shouldRecoverAfterMedial {
                        calls += 1
                        report.privateColorRecoveryQueries? += 1
                        measured += measure("chromatic") {
                            NativeOCRSourceChromaticPaint.measure(roi: roi, query: query, originals: originals, rf: rf)
                        }.map { result in
                            var diagnostics = result.diagnostics
                            diagnostics["recoveredOmittedPrivateColor"] = Double(support.omittedColoredPoints)
                            return Measurement(polygon: result.polygon, layer: result.layer, mechanism: result.mechanism,
                                diagnostics: diagnostics, terminalEvidenceGroup: result.terminalEvidenceGroup,
                                terminalEvidence: result.terminalEvidence)
                        }
                    }
                }
                if recoveryV3, calls <= 2,
                   measured.contains(where: { $0.diagnostics["completeNormalInk"] == 0 }) {
                    calls += 1
                    measured += measure("achromatic") {
                        NativeOCRSourceAchromaticPaint.measure(roi: roi, query: query, originals: originals,
                            rf: rf, generationLedger: generationLedger)
                    }
                }
                report.skippedEagerFamilyCalls? += 5 - calls
                // A complete endpoint has priority; otherwise prefer the measured
                // boundary closest to the actual observed detector localization.
                // No per-page budget, target shape or post-admission NMS is used.
                let choices = admissibleMeasurements(measured, frame: frame)
                measured = choices.enumerated().max { a, b in
                    if recoveryV3 {
                        let ac = (a.element.diagnostics["recoveredOmittedPrivateColor"] ?? 0) > 0
                        let bc = (b.element.diagnostics["recoveredOmittedPrivateColor"] ?? 0) > 0
                        if ac != bc { return !ac }
                        let an = (a.element.diagnostics["completeNormalInk"] ?? 0) > 0
                        let bn = (b.element.diagnostics["completeNormalInk"] ?? 0) > 0
                        if an != bn { return !an }
                    }
                    let ac = a.element.terminalEvidence == .completeSourceInk
                    let bc = b.element.terminalEvidence == .completeSourceInk
                    if ac != bc { return !ac }
                    let aa = a.element.polygon.map { G.Point(x: $0[0], y: $0[1]) }
                    let bb = b.element.polygon.map { G.Point(x: $0[0], y: $0[1]) }
                    let q = query.polygon.map { G.Point(x: $0[0], y: $0[1]) }
                    let ai = NativeOCRGeometryDeduplication.polygonIoU(aa, q)
                    let bi = NativeOCRGeometryDeduplication.polygonIoU(bb, q)
                    return ai == bi ? a.offset > b.offset : ai < bi
                }.map { [$0.element] } ?? []
            } else {
                if let count = completedChromatic[polygon] {
                    measured = []
                    report.chromaticMeasurementCacheHits += 1
                    report.retiredChromaticMeasurementOffers += count
                } else {
                    measured = measure("chromatic") {
                        NativeOCRSourceChromaticPaint.measure(roi: roi, query: query, originals: originals, rf: rf)
                    }
                    // Retain deterministic empty-job reuse too. Invalid-only
                    // results cannot retire a later successful observation.
                    let admitted = admissibleMeasurements(measured, frame: frame)
                    if measured.isEmpty || !admitted.isEmpty { completedChromatic[polygon] = admitted.count }
                }
                measured += measure("achromatic") { NativeOCRSourceAchromaticPaint.measure(roi: roi, query: query, originals: originals, rf: rf, generationLedger: generationLedger) }
                measured += measure("column") { NativeOCRSourcePaintColumnPartition.measure(roi: roi, query: query, originals: originals, rf: rf, generationLedger: generationLedger) }
                measured += measure("completeness") { NativeOCRSourcePaintCompleteness.measure(roi: roi, query: query, originals: originals, rf: rf, generationLedger: generationLedger) }
                measured += measure("medial") { NativeOCRSourcePaintMedialGeometry.measure(roi: roi, query: query, originals: originals, rf: rf, generationLedger: generationLedger) }
            }
            report.measuredCount += measured.count
            let admitted = admissibleMeasurements(measured, frame: frame)
            for observation in admitted {
                if measurementsOnly {
                    report.contextMeasurements?.append(.init(queryOrdinal: ordinal, queryPolygon: polygon,
                        actualQuery: individual, measurement: observation))
                    continue
                }
                let points = observation.polygon.map { G.Point(x: $0[0], y: $0[1]) }
                let key = canonicalKey(points)
                if let portfolio {
                    let accepted = portfolio.accepts(observation)
                    if accepted || reservedLayoutQueries.contains(QueryWorkKey(query, includeContextReceipt: false)) {
                        retainedOfferKeys.insert(key)
                    } else { retiredPortfolioOffers += 1 }
                }
                if let existing = seen[key] {
                    report.exactDuplicateMeasurements += 1
                    report.observations.append(.init(queryOrdinal: ordinal, queryPolygon: polygon, actualQuery: individual,
                        contextualQuery: individual == nil ? query : nil,
                        measurement: observation, record: existing, membership: "unknown; query-context-only",
                        duplicateOf: existing.alternativeID))
                    continue
                }
                guard next < Int.max else { throw Failure.sourceIndexOverflow }
                next += 1
                let record = G.Record(requestID: requestID, sourceIndex: next,
                    sourceParent: query.sourceIndex, sourceMembers: [],
                    alternativeID: "source-paint/\(ordinal)/\(next)/\(observation.mechanism)/\(observation.layer)",
                    origin: .corrected, originalDetectorIndex: nil, polygon: points)
                records.append(record)
                seen[key] = record
                report.observations.append(.init(queryOrdinal: ordinal, queryPolygon: polygon, actualQuery: individual,
                    contextualQuery: individual == nil ? query : nil,
                    measurement: observation, record: record, membership: "unknown; query-context-only"))
            }
        }
        report.skippedExactProducerJobs = generationLedger.skippedJobs
        report.retiredExactProducerMeasurements = generationLedger.retiredMeasurements
        // Reserve original identities and finish every physical producer first.
        // An independently retained exact-quad observation restores its original
        // record. No provenance is transferred from a retired geometry.
        if portfolio != nil {
            let before = records.count
            records.removeAll { !retainedOfferKeys.contains(canonicalKey($0.polygon)) }
            report.portfolioSuppressedOffers = retiredPortfolioOffers
            report.portfolioRetiredRecords = before - records.count
        }
        report.addedUniqueRecords = records.count
        if sourceFirst { report.measuredCount = report.actualProducerMeasurementCount ?? report.measuredCount }
        return .init(records: records, report: report)
    }
    private static func canonicalKey(_ points: [G.Point]) -> [G.Point] {
        var best = points
        for reverse in [false, true] { for start in 0..<4 {
            let candidate = (0..<4).map { points[(start + (reverse ? 4-$0 : $0)) % 4] }
            for i in 0..<4 {
                if candidate[i] == best[i] { continue }
                if candidate[i].x < best[i].x || (candidate[i].x == best[i].x && candidate[i].y < best[i].y) { best = candidate }
                break
            }
        } }
        return best
    }
    private static func valid(_ q: [[Double]], frame: NativeOCRRGBAFrame) -> Bool {
        guard q.count == 4, q.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) &&
            $0[0] >= 0 && $0[1] >= 0 && $0[0] <= Double(frame.width) && $0[1] <= Double(frame.height) }) else { return false }
        let turns = (0..<4).map { i -> Double in
            let a=q[i], b=q[(i+1)%4], c=q[(i+2)%4]
            return (b[0]-a[0])*(c[1]-b[1]) - (b[1]-a[1])*(c[0]-b[0])
        }
        return turns.allSatisfy { $0 > 0 } || turns.allSatisfy { $0 < 0 }
    }
    private struct CropBounds: Hashable {
        let x: Int, y: Int, width: Int, height: Int
    }
    private static func cropBounds(_ frame: NativeOCRRGBAFrame, _ q: [[Double]]) -> CropBounds? {
        let xs=q.map{$0[0]}, ys=q.map{$0[1]}
        guard let minX=xs.min(), let maxX=xs.max(), let minY=ys.min(), let maxY=ys.max() else { return nil }
        let w=maxX-minX, h=maxY-minY
        // Search context is separate from output padding. The common window
        // includes the largest finite core/rim closure family context.
        let short=max(1,min(w,h)), mx=max(short,w*0.15), my=max(short,h*0.15)
        let x0=max(0,Int(floor(minX-mx))), y0=max(0,Int(floor(minY-my)))
        let x1=min(frame.width,Int(ceil(maxX+mx))), y1=min(frame.height,Int(ceil(maxY+my)))
        let width=x1-x0, height=y1-y0
        guard width > 0, height > 0, width <= 1_500_000/height else { return nil }
        return .init(x: x0, y: y0, width: width, height: height)
    }
    private static func crop(_ frame: NativeOCRRGBAFrame, _ bounds: CropBounds) -> PixelROI {
        let width = bounds.width, height = bounds.height
        var rgb=[UInt8](); rgb.reserveCapacity(width*height*3)
        for y in bounds.y..<(bounds.y+height) { for x in bounds.x..<(bounds.x+width) {
            let i=y*frame.bytesPerRow+x*4
            rgb.append(frame.bytes[i]); rgb.append(frame.bytes[i+1]); rgb.append(frame.bytes[i+2])
        } }
        return .init(width: width, height: height, originX: bounds.x, originY: bounds.y, rgb: rgb)
    }
}
