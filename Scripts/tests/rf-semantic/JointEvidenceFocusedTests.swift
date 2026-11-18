import Foundation

enum JointEvidenceFocusedTests {
    typealias H = NativeOCRJointEvidenceAdmission
    typealias G = NativeOCRIndividualGeometryHypotheses
    typealias A = NativeOCRRFSemanticAdmission
    static func q(_ x: Double) -> [G.Point] {
        [.init(x:x,y:0),.init(x:x+100,y:0),.init(x:x+100,y:100),.init(x:x,y:100)]
    }
    static func record(_ name: String, _ x: Double) -> G.Record {
        // Deliberately shared ancestry: geometry/families must determine support.
        .init(requestID:"unit",sourceIndex:0,sourceParent:0,sourceMembers:[],alternativeID:name,
              origin:.corrected,originalDetectorIndex:nil,polygon:q(x))
    }
    static func input(_ records: [G.Record]) -> G.Output {
        let result = G.emit(requestID:"unit",corrected:records,originals:[])
        return G.admitting(result,bboxScores:[Double](repeating:0.8,count:result.individuals.count),threshold:0.085)
    }
    static func grid() -> NativeRFDETRSemanticGrid {
        NativeRFDETRSemanticGrid(width:1000,height:1000,side:162,
            probabilities:[Float](repeating:0.8,count:4*162*162),modelWeightsSHA256:"unit")
    }
    static func expect(_ condition: Bool) { precondition(condition) }
    static func run() throws {
        let bank = input([record("familyA/0",-10),record("familyB/0",-10),
                          record("familyC/0",-10),record("familyD/0",-10)])
        let raw = input([record("witness/0",0),record("candidate/0",8)])
        let observed = [A.Observation(polygon:q(0),confidence:0.9)]
        let field = grid()
        func apply(_ rows:G.Output = raw, _ references:G.Output? = bank,
                   _ quality:[Double?]? = [0.9,0.8], _ configured:Bool = true,
                   _ available:Bool = true) throws -> H.Result {
            try H.apply(rows,referenceInventory:references,grid:field,recognition:observed,
                        frozenQualityScores:quality,sourceEvidenceAvailable:available,
                        configuration:.init(countWitnessEnabled:configured))
        }
        let count = try apply()
        precondition(count.report.keptIndices == [0])
        precondition(count.report.signals[0]!.supportingFamilyCount80 == 4)
        precondition(count.report.signals[1]!.supportingFamilyCount80 == 0)
        precondition(count.report.replacements.count == 1)
        precondition(count.report.replacements[0].rule == "four-more-families-observed-direct-085")
        precondition(count.report.replacements[0].polygonIoU >= 0.85 && count.report.replacements[0].polygonIoU < 0.9)
        precondition(count.output.individuals == [raw.individuals[0]])
        expect(try apply(raw,bank,[0.9,0.8],false).report.keptIndices == [0,1])
        let repeated = input((0..<4).map { record("oneFamily/\($0)",-10) })
        expect(try apply(raw,repeated).report.keptIndices == [0,1])
        let selfOnly = input((0..<4).map { record("witness/\($0)",-10) })
        let selfResult = try apply(raw,selfOnly)
        precondition(selfResult.report.signals[0]!.supportingFamilyCount80 == 0)
        precondition(selfResult.report.keptIndices == [0,1])
        expect(try apply(raw,nil).report.keptIndices == [0,1])
        expect(try apply(raw,bank,[0.9]).report.missingEvidenceKeptIndices == [0,1])
        expect(try apply(raw,bank,[0.9,nil]).report.keptIndices == [0,1])
        expect(try apply(raw,bank,[0.9,0.8],true,false).report.keptIndices == [0,1])
        let noGrid = try H.apply(raw,referenceInventory:bank,grid:nil,recognition:observed,
            frozenQualityScores:[0.9,0.8],sourceEvidenceAvailable:true)
        precondition(noGrid.report.keptIndices == [0,1])
        let noObserved = try H.apply(raw,referenceInventory:bank,grid:field,recognition:[],
            frozenQualityScores:[0.9,0.8],sourceEvidenceAvailable:true)
        precondition(noObserved.report.keptIndices == [0,1])
        let anchored = input([record("original/0",0),record("weak/0",8)])
        let weak = try apply(anchored,bank,[0.01,0.01])
        precondition(weak.report.keptIndices == [0] && weak.report.weakJointEvidenceRejectedIndices == [1])
        let chain = input([record("witness/0",0),record("candidateA/0",8),record("candidateB/0",16)])
        let chainResult = try apply(chain,bank,[0.9,0.8,0.7])
        precondition(chainResult.report.keptIndices == [0,2])
        precondition(chainResult.report.replacements.allSatisfy { chainResult.report.keptIndices.contains($0.retainedIndex) })
        let tied = input([record("candidateA/0",0),record("candidateB/0",0)])
        expect(try apply(tied,bank,[0.9,0.9]).report.keptIndices == [0])
        let encoded = try JSONEncoder().encode(count.report)
        expect(try JSONDecoder().decode(H.Report.self,from:encoded) == count.report)
        print("PASS: count-only direct .85 witness; .90 fallback; family diversity/self exclusion; shared ancestry ignored; full reference retained; missing evidence; anchors; immutable rows; no replacement chains; deterministic ties; Codable/Equatable")
    }

}
