#!/usr/bin/env python3
"""Independent native signal/geometry checks; no shared host/Xcode build or GT."""
from pathlib import Path
import hashlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
OCR = ROOT / 'Aidoku/Core/Translation/NativeEngine/OCR'
LAYOUT = ROOT / 'Aidoku/Core/Translation/NativeEngine/Layout'
RESOURCES = ROOT / 'Aidoku/Resources/Translation/RawCanonicalGeometry'
FIXTURE = Path(__file__).parent / 'fixtures/raw-canonical-production/signals.json'

expected_hashes = {
    'NativeOCRRawCanonicalPrimary8D': '3e3282ed5a91c2be87de7de721609832b98ce2eb03ece2938c24dfe7f2e608ae',
    'NativeOCRRawSourceGate155': '26d9ea211057f8f99d3a6702462e9142396298e633c97a36da4688aa69553809',
    'NativeOCRRawCanonicalAuxiliary8D': 'e81499f93b44dedbf5534b7a878b8088887ae78b3ec97719a981446494fbf152',
    'NativeOCRPreRecognition165': '98a584ace8169b6e94a6e72956bdb85edee33e245af94520a92463ffcbbaa5d7',
}
for name, digest in expected_hashes.items():
    assert hashlib.sha256((RESOURCES / (name + '.json')).read_bytes()).hexdigest() == digest

# The original seed wire type is compiled unchanged. Its optional ROI is not
# inspected by these source-signal algorithms; no image subsystem is linked.
seed = (OCR / 'NativeOCRDetectorSeedEvidence.swift').read_text().split('extension NativeOCRDetectorSeedEvidence {')[0]
support = '''import Foundation
import CoreGraphics
struct NativeOCRSourceROIProbabilityEvidence: Codable, Equatable, Sendable {}
struct NativeCoreMLDetectionBox {
    let polygon: [CGPoint]; let score: Double
    var detectorSeedEvidence: NativeOCRDetectorSeedEvidence? = nil
}
enum NativeMainEnsembleOCRProbability {
    struct Sample {
        let sourceWidth: Int; let sourceHeight: Int; let resizedWidth: Int; let resizedHeight: Int
        let region: CGRect; let width: Int; let height: Int; let values: [Float]
    }
}
''' + seed
checks = r'''
import Foundation
typealias G = NativeOCRIndividualGeometryHypotheses
struct Aux: Decodable {
    let name: String; let width: Int; let height: Int; let probabilities: [Float]; let rfSupport: Float
    let references: [[[Double]]]; let expectedPolygons: [[[Double]]]; let expectedScores: [Double]
}
struct Fixture: Decodable {
    let generatorFeatures: [[Double]]; let generatorResiduals: [[Double]]
    let preFeatures: [[Double?]]; let preKept: [Int]
    let dedupOutput: G.Output; let dedupFeatures: [[Double?]]; let dedupRecognition: [Double]; let dedupKept: [Int]
    let auxiliaryCases: [Aux]
}
let resources = URL(fileURLWithPath: CommandLine.arguments[1])
let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
let primaryData = try Data(contentsOf: resources.appendingPathComponent("NativeOCRRawCanonicalPrimary8D.json"))
struct Header: Decodable { let featureNames: [String] }
let names = try JSONDecoder().decode(Header.self, from: primaryData).featureNames
let generator = try NativeOCRRawBoundaryGenerator.Model(data: primaryData, expectedFeatureNames: names)
for (x, expected) in zip(fixture.generatorFeatures, fixture.generatorResiduals) {
    let actual = generator.residual(features: x)!
    precondition(zip(actual, expected).allSatisfy { abs($0-$1) < 1e-11 })
}
let pre = try NativeOCRPreRecognitionFilter.Model(
    data: Data(contentsOf: resources.appendingPathComponent("NativeOCRPreRecognition165.json")),
    expectedFeatureNames: NativeOCRPreRecognitionFeatures.featureNames)
func quad(_ x: Double) -> [G.Point] {
    [.init(x:x,y:0),.init(x:x+20,y:0),.init(x:x+20,y:80),.init(x:x,y:80)]
}
func bank(_ offsets: [Double], scores: [Double]) -> G.Output {
    let rows = offsets.enumerated().map { i,x in G.Record(requestID:"fresh-operation",sourceIndex:i,
        sourceParent:i,sourceMembers:[],alternativeID:"fresh-quad",origin:.corrected,
        originalDetectorIndex:nil,polygon:quad(x)) }
    let output = G.emit(requestID:"fresh-operation",corrected:rows,originals:[],layout:[],refinements:[],mode:.correctedOnly)
    return G.admitting(output,bboxScores:scores,threshold:0.085)
}
let numericInput = bank(fixture.preFeatures.indices.map { Double($0)*25 },scores:[Double](repeating:0.9,count:fixture.preFeatures.count))
let numeric = try NativeOCRPreRecognitionFilter.apply(numericInput,
    features:fixture.preFeatures.map { $0.map { $0 ?? .nan } },model:pre)
precondition(numeric.report.keptIndices == fixture.preKept)
let bboxEdges = bank([0,25,50],scores:[0.084999,0.085,0.9])
precondition(bboxEdges.individuals.count == 2 && bboxEdges.individuals[0].bboxConfidence == 0.085)
let actual = try NativeOCRPostRecognitionDeduplication.apply(fixture.dedupOutput,
    source166:fixture.dedupFeatures.map { $0.map { $0 ?? .nan } })
precondition(actual.report.keptIndices == fixture.dedupKept)
precondition(!actual.report.replacements.isEmpty)
precondition(actual.report.replacements.allSatisfy { actual.report.keptIndices.contains($0.retainedIndex) })
var signals = [Double](repeating:0,count:166); signals[6]=0.8; signals[163]=0.8
let fresh = bank([0,0.9,1.8],scores:[0.9,0.9,0.9])
let chain = try NativeOCRPostRecognitionDeduplication.apply(fresh,
    source166:[0.95,0.93,0.91].map { rec in var x=signals;x[165]=rec;return x })
precondition(chain.report.keptIndices == [0,2])
let equal = try NativeOCRPostRecognitionDeduplication.apply(fresh,
    source166:[Double](repeating:0.95,count:3).map { rec in var x=signals;x[165]=rec;return x })
precondition(equal.report.keptIndices == [0,2])
var missing=signals;missing[8] = .nan
let abstained = try NativeOCRPostRecognitionDeduplication.apply(fresh,
    source166:[missing,missing,missing])
precondition(abstained.report.keptIndices == [0,1,2])
for c in fixture.auxiliaryCases {
    let p=NativeMainEnsembleOCRProbability.Sample(sourceWidth:c.width,sourceHeight:c.height,
        resizedWidth:c.width,resizedHeight:c.height,region:CGRect(x:0,y:0,width:c.width,height:c.height),
        width:c.width,height:c.height,values:c.probabilities)
    let cells=162*162
    var fields=[Float](repeating:0,count:17*cells)
    for i in 0..<cells { fields[i]=c.rfSupport }
    let discovered=try NativeOCRCanonicalAuxiliarySeeds.produce(probability:p,originals:[],
        referencePolygons:c.references,support:.init(native17Fields:fields),cancellationCheck:{})
    print("CC03",c.name,"count",discovered.count,"expected",c.expectedPolygons.count); fflush(stdout)
    precondition(discovered.count == c.expectedPolygons.count, "CC03 count: (c.name)")
    for (row, expected) in zip(discovered,c.expectedPolygons) {
        let overlap=NativeOCRPremergeCandidateFeatures.polygonOverlap(
            row.polygon.map { .init(x:$0[0],y:$0[1]) },expected.map { .init(x:$0[0],y:$0[1]) })!
        print("CC03 IoU",overlap.iou); fflush(stdout)
        precondition(overlap.iou > 0.999, "CC03 geometry: (c.name) (overlap.iou)")
    }
    for (row,expected) in zip(discovered,c.expectedScores) { print("CC03 score",row.score,expected);fflush(stdout);precondition(abs(row.score-expected)<1e-5) }
}
print("PASS actual native models/source165/direct-witness: bounded frozen numerical fixture + fresh DET085 packets, confidence-rank/no-chain/missing-signal cases; source-only CC03 reference geometry")
'''

sources = [OCR / (n + '.swift') for n in (
    'NativeOCRIndividualGeometryHypotheses', 'NativeOCRGeometryDeduplication',
    'NativeOCRPremergeCandidateFeatures', 'NativeOCRSourceSupportFeatures155',
    'NativeOCRPreRecognitionFeatures', 'NativeOCRPreRecognitionFilter',
    'NativeOCRPostRecognitionFeatures', 'NativeOCRPostRecognitionDeduplication',
    'NativeOCRRawBoundaryGenerator', 'NativeOCRRawSourceAdmission', 'NativeOCRCanonicalAuxiliarySeeds')]
sources += [LAYOUT / 'NativeRFDETRSourceSupportGrid.swift']
with tempfile.TemporaryDirectory(prefix='aidoku-raw-canonical-focused-') as directory:
    temp = Path(directory)
    (temp / 'Support.swift').write_text(support)
    (temp / 'main.swift').write_text(checks)
    binary = temp / 'smoke'
    subprocess.run(['xcrun', 'swiftc', '-O', str(temp / 'Support.swift'), *map(str, sources),
                    str(temp / 'main.swift'), '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(RESOURCES), str(FIXTURE)], check=True)
