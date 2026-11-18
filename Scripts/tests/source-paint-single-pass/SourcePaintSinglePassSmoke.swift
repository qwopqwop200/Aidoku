import Foundation
import Darwin
struct NativeOCRRGBAFrame { let width: Int, height: Int, bytesPerRow: Int; let bytes: [UInt8] }
struct TestRun { let x: Int; let y: Int; let count: Int }
struct TestComponent { let runs: [TestRun] }
struct TestSeed {
    let sourceWidth: Int, sourceHeight: Int
    var isValid = true
    var completeCCScan: Bool? = nil
    var mapFullWidth = 1
    var mapFullHeight = 1
    var components: [TestComponent] = []
}
enum NativeOCRFrameDigestBuilder {
    struct Fingerprint { let width: Int, height: Int, primary: Int, verifier: Int }
    static func fingerprint(of frame: NativeOCRRGBAFrame) -> Fingerprint {
        .init(width: frame.width, height: frame.height, primary: frame.bytes.count, verifier: frame.bytesPerRow)
    }
}
enum NativeOCRSourceOwnedRailPartition {
    struct Original { let polygon: [[Double]]; let detectorSeedEvidence: TestSeed? }
}
enum NativeOCRSourceContext50V2 { struct Primitive { let canonicalClass: Int; let confidence: Double; let polygon: [[Double]] } }
enum TestMeasurement {
    static var calls = 0
    static var search = false
    static func measure(_ roi: NativeOCRSourcePaintGeometry.PixelROI,
                        _ query: NativeOCRSourcePaintGeometry.Query) -> [NativeOCRSourcePaintGeometry.Measurement] {
        calls += 1
        precondition(roi.rgb.count == roi.width*roi.height*3)
        // Verify exact source coordinates even on a cache hit.
        for (x,y) in [(0,0),(roi.width-1,roi.height-1)] {
            let i = (y*roi.width+x)*3
            precondition(roi.rgb[i] == UInt8((x+roi.originX) % 251))
            precondition(roi.rgb[i+1] == UInt8((y+roi.originY) % 251))
        }
        return [.init(polygon: query.polygon, layer: "stub", mechanism: "stub", diagnostics: [:])]
    }
}
enum NativeOCRSourceChromaticPaint {
    static func contextualQueries(originals: [NativeOCRSourceOwnedRailPartition.Original]) -> [NativeOCRSourcePaintGeometry.Query] { [] }
    static func measure(roi: NativeOCRSourcePaintGeometry.PixelROI, query: NativeOCRSourcePaintGeometry.Query,
                        originals: [NativeOCRSourceOwnedRailPartition.Original], rf: [NativeOCRSourceContext50V2.Primitive]) -> [NativeOCRSourcePaintGeometry.Measurement] {
        TestMeasurement.measure(roi,query)
    }
}
enum NativeOCRSourceAchromaticPaint {
    static func measure(roi: NativeOCRSourcePaintGeometry.PixelROI, query: NativeOCRSourcePaintGeometry.Query,
                        originals: [NativeOCRSourceOwnedRailPartition.Original], rf: [NativeOCRSourceContext50V2.Primitive], generationLedger: NativeOCRSourcePaintColumnPartition.GenerationLedger? = nil) -> [NativeOCRSourcePaintGeometry.Measurement] {
        TestMeasurement.measure(roi,query)
    }
}
enum NativeOCRSourcePaintColumnPartition {
    final class GenerationLedger { let skippedJobs = 0; let retiredMeasurements = 0 }
    static func measure(roi: NativeOCRSourcePaintGeometry.PixelROI, query: NativeOCRSourcePaintGeometry.Query,
                        originals: [NativeOCRSourceOwnedRailPartition.Original], rf: [NativeOCRSourceContext50V2.Primitive], generationLedger: NativeOCRSourcePaintColumnPartition.GenerationLedger? = nil) -> [NativeOCRSourcePaintGeometry.Measurement] {
        TestMeasurement.measure(roi,query)
    }
}
enum NativeOCRSourcePaintCompleteness {
    static func requiredSourceBounds(query: NativeOCRSourcePaintGeometry.Query,
                                     originals: [NativeOCRSourceOwnedRailPartition.Original], rf: [NativeOCRSourceContext50V2.Primitive], generationLedger: NativeOCRSourcePaintColumnPartition.GenerationLedger? = nil) -> [[Double]]? {
        TestMeasurement.search ? query.polygon : nil
    }
    static func measureSearch(roi: NativeOCRSourcePaintGeometry.PixelROI, query: NativeOCRSourcePaintGeometry.Query,
                              originals: [NativeOCRSourceOwnedRailPartition.Original], rf: [NativeOCRSourceContext50V2.Primitive], generationLedger: NativeOCRSourcePaintColumnPartition.GenerationLedger? = nil) -> [NativeOCRSourcePaintGeometry.Measurement] {
        TestMeasurement.measure(roi,query)
    }
    static func measure(roi: NativeOCRSourcePaintGeometry.PixelROI, query: NativeOCRSourcePaintGeometry.Query,
                        originals: [NativeOCRSourceOwnedRailPartition.Original], rf: [NativeOCRSourceContext50V2.Primitive], generationLedger: NativeOCRSourcePaintColumnPartition.GenerationLedger? = nil) -> [NativeOCRSourcePaintGeometry.Measurement] {
        TestMeasurement.measure(roi,query)
    }
}
enum NativeOCRSourcePaintMedialGeometry {
    static func measure(roi: NativeOCRSourcePaintGeometry.PixelROI, query: NativeOCRSourcePaintGeometry.Query,
                        originals: [NativeOCRSourceOwnedRailPartition.Original], rf: [NativeOCRSourceContext50V2.Primitive], generationLedger: NativeOCRSourcePaintColumnPartition.GenerationLedger? = nil) -> [NativeOCRSourcePaintGeometry.Measurement] {
        TestMeasurement.measure(roi,query)
    }
}
@main enum SourcePaintSinglePassSmoke {
    typealias API = NativeOCRSourcePaintGeometry
    typealias G = NativeOCRIndividualGeometryHypotheses
    static func q(_ x: Double) -> [[Double]] { [[x,40],[x+20,40],[x+20,160],[x,160]] }
    static func frame(_ width: Int, _ height: Int) -> NativeOCRRGBAFrame {
        var bytes: [UInt8] = []; bytes.reserveCapacity(width*height*4)
        for y in 0..<height { for x in 0..<width { bytes += [UInt8(x % 251),UInt8(y % 251),127,255] } }
        return .init(width: width, height: height, bytesPerRow: width*4, bytes: bytes)
    }
    static func record(_ index: Int, members: Set<Int>, polygon: [[Double]], alternative: String? = nil) -> G.Record {
        .init(requestID: "source", sourceIndex: index, sourceParent: index, sourceMembers: members,
              alternativeID: alternative ?? "corrected/\(index)", origin: .corrected, originalDetectorIndex: nil,
              polygon: polygon.map { .init(x: $0[0], y: $0[1]) })
    }
    static func main() throws {
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--generator-policy" {
            precondition(API.shouldGenerate(CommandLine.arguments[2]) == (CommandLine.arguments[3] == "1"))
            precondition(API.shouldGenerate("unconfigured-generator"))
            print("PASS: immutable global generator plan and fail-open configuration")
            return
        }
        precondition(G.finalLayoutProposals([], environment: [:]).isEmpty)
        let layoutProbe = record(0, members: [0], polygon: q(40))
        precondition(G.finalLayoutProposals([layoutProbe], environment: [:]) == [layoutProbe])
        precondition(G.finalLayoutProposals([layoutProbe], environment: ["AIDOKU_OCR_LAYOUT_PROPOSAL_EMISSION": "context-only-v1"]).isEmpty)
        precondition(G.finalLayoutProposals([layoutProbe], environment: ["AIDOKU_OCR_LAYOUT_PROPOSAL_EMISSION": "unknown"]) == [layoutProbe])
        // Exact physical contacts may retire only a directly retained offer;
        // producer/layer, complete ink and absent seed evidence remain independent.
        var supportSeed = TestSeed(sourceWidth:100,sourceHeight:100)
        supportSeed.completeCCScan = true; supportSeed.mapFullWidth = 100; supportSeed.mapFullHeight = 100
        supportSeed.components = [.init(runs:[.init(x:20,y:20,count:3)])]
        let supportOriginal = NativeOCRSourceOwnedRailPartition.Original(polygon:[[10,10],[30,10],[30,80],[10,80]],detectorSeedEvidence:supportSeed)
        let offer = API.OfferPortfolio(originals:[supportOriginal],width:100,height:100)
        func candidate(_ dx:Double, layer:String = "rim", complete:Bool = false) -> API.Measurement {
            .init(polygon:[[10+dx,10],[30+dx,10],[30+dx,80],[10+dx,80]],layer:layer,mechanism:"physical",diagnostics:[:],terminalEvidence:complete ? .completeSourceInk : nil)
        }
        precondition(offer.accepts(candidate(0)))
        precondition(!offer.accepts(candidate(2)))
        precondition(offer.accepts(candidate(4))) // Suppressed middle offer is never a witness.
        precondition(offer.accepts(candidate(2,layer:"fill")))
        precondition(offer.accepts(candidate(2,complete:true)))
        let noSupport = API.OfferPortfolio(originals:[],width:100,height:100)
        precondition(noSupport.accepts(candidate(0)) && noSupport.accepts(candidate(0)))
        setenv(API.environmentKey, "1", 1)
        let image = frame(256,256)
        let originals = [q(40),q(160)].map { NativeOCRSourceOwnedRailPartition.Original(polygon: $0, detectorSeedEvidence: TestSeed(sourceWidth:256,sourceHeight:256)) }
        let complete = API.Measurement(polygon:[[40,45],[60,45],[60,155],[40,155]],layer:"complete",mechanism:"physical",diagnostics:[:],terminalEvidenceGroup:"support",terminalEvidence:.completeSourceInk)
        let outside = API.Measurement(polygon:[[40,-1],[60,-1],[60,155],[40,155]],layer:"outside",mechanism:"physical",diagnostics:[:])
        let nonfinite = API.Measurement(polygon:complete.polygon,layer:"nonfinite",mechanism:"physical",diagnostics:["invalid":Double.nan])
        precondition(API.admissibleMeasurements([complete,outside,nonfinite],frame:image).map(\.layer) == ["complete"])
        let correction = record(0, members: [0], polygon: q(40))
        let baseline = try API.produce(requestID:"source",frame:image,originals:originals,currentCorrections:[correction],rf:[],reservedRecords:[])
        precondition(baseline.report.queryCount == 1 && baseline.report.originalQueryCount == 2)
        precondition(baseline.report.scheduledQueryCount == 2 && baseline.report.duplicateQueriesSkipped == 1)
        precondition(baseline.report.familyCalls.values.reduce(0,+) == 10)
        precondition(baseline.report.pixelCropCachePolicy == "exact-window-remaining-uses-v1")
        precondition(baseline.report.pixelCropCacheInsertions == 0 && baseline.report.peakCachedRGBBytes == 0)
        // Thousands of calibration alternatives may reserve identities but
        // cannot create a single extra pixel job or feed their outputs back.
        let alternatives = (1...10_000).map { record(100+$0, members: [], polygon:q(80), alternative:"learned/\($0)") }
        let reserved = try API.produce(requestID:"source",frame:image,originals:originals,currentCorrections:[correction],rf:[],reservedRecords:alternatives)
        precondition(reserved.report.scheduledQueryCount == baseline.report.scheduledQueryCount)
        precondition(reserved.report.familyCalls == baseline.report.familyCalls)
        precondition(reserved.records.map(\.polygon) == baseline.records.map(\.polygon))
        let canonical = record(20_000, members: [0], polygon:q(48), alternative:"canonical/0")
        let bindings: [(inputs:[G.Record], outputAlternativeID:String?)] = [([correction],canonical.alternativeID)]
        precondition(API.canonicalSeeds([correction],records:[canonical]+alternatives,decisions:bindings) == [canonical])
        precondition(API.canonicalSeeds([correction],records:[canonical],decisions:bindings+bindings) == [correction])
        precondition(API.canonicalSeeds([correction],records:[],decisions:bindings) == [correction])
        // Same pixels, DIFFERENT ownership context: share RGB only, never the
        // geometry-sensitive measurement or metadata.
        let unknown = record(0, members: [], polygon:q(40))
        let cached = try API.produce(requestID:"source",frame:image,originals:originals,currentCorrections:[unknown],rf:[],reservedRecords:[])
        precondition(cached.report.scheduledQueryCount == 3)
        precondition(cached.report.pixelCropBuilds == 2 && cached.report.pixelCropCacheHits == 1)
        precondition(cached.report.familyCalls.values.reduce(0,+) == 14
        && cached.report.chromaticMeasurementCacheHits == 1)
        precondition(cached.report.pixelCropCacheInsertions == 1)
        precondition(cached.records.allSatisfy { $0.sourceMembers.isEmpty })
        // Single-use windows must not evict the only reusable window, even
        // when their combined RGB exceeds the cache budget. Work/provenance
        // for unknown versus source-owned queries still stays separate.
        let largeImage = frame(1600,1600)
        let largeOriginal = NativeOCRSourceOwnedRailPartition.Original(
            polygon:q(40),detectorSeedEvidence:TestSeed(sourceWidth:1600,sourceHeight:1600))
        let singleUse = [300.0,650,1000,1100].enumerated().map { i, x in
            record(i+1,members:[],polygon:[[x,300],[x+220,300],[x+220,1200],[x,1200]])
        }
        let lifetime = try API.produce(requestID:"source",frame:largeImage,originals:[largeOriginal],
            currentCorrections:[unknown]+singleUse,rf:[],reservedRecords:[])
        precondition(lifetime.report.scheduledQueryCount == 6 && lifetime.report.processedQueryCount == 6)
        precondition(lifetime.report.pixelCropBuilds == 5 && lifetime.report.pixelCropCacheHits == 1)
        precondition(lifetime.report.pixelCropCacheInsertions == 1 && lifetime.report.peakCachedRGBBytes < 100_000)
        precondition(lifetime.report.observations.count == 29 && lifetime.records.count == 5
            && lifetime.report.chromaticMeasurementCacheHits == 1)
        precondition(lifetime.report.observations.last?.actualQuery?.provenance.first?.sourceMembers == [0])
        precondition(lifetime.report.observations.first?.actualQuery?.provenance.first?.sourceMembers == [])
        TestMeasurement.search = true
        let search = try API.produce(requestID:"source",frame:image,originals:originals,currentCorrections:[correction],rf:[],reservedRecords:alternatives)
        precondition(search.report.contextualQueryCount == 2 && search.report.scheduledQueryCount == 4)
        precondition(search.report.familyCalls["completeness-search"] == 2)
        precondition(search.report.pixelCropCacheHits >= 2)
        precondition(search.report.peakCachedRGBBytes <= 8*1024*1024)
        precondition(search.report.processedQueryCount == search.report.pixelCropBuilds + search.report.pixelCropCacheHits)
        let final = G.emit(requestID:"source",corrected:search.records,originals:[])
        let proof = search.finalized(actualOutput:final.individuals)
        precondition(proof.finalized && proof.finalIndividualCount == final.individuals.count)
        print("PASS: fixed original/correction work, no hypothesis feedback, 10k-alternative invariance, exact RGB reuse without ownership aliasing, search contexts and final emission proof")
    }
}
