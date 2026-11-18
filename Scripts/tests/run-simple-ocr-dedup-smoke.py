#!/usr/bin/env python3
"""Compile actual NMS/geometry and both actual raw dispatch blocks, no models.

Recognizer value declarations are copied verbatim. Private transport doubles
only count post-rec observer calls; actual feature assembly/NMS code executes.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
OCR = ROOT / 'Aidoku/Core/Translation/NativeEngine/OCR'
SWIFT = r'''
import Foundation
import CoreGraphics
typealias G = NativeOCRIndividualGeometryHypotheses
typealias N = NativeSimpleOCRDedup
enum NativeOCRPreRecognitionFeatures { static let featureNames = (0..<165).map { "source\($0)" } }
enum DefaultPolicySnapshot {
    DEFAULT_DECLARATIONS
}
func q(_ x: Double = 0) -> [G.Point] {
    [.init(x:x,y:0),.init(x:x+10,y:0),.init(x:x+10,y:10),.init(x:x,y:10)]
}
func bank(_ polygons: [[G.Point]], _ bbox: [Double]? = nil) -> G.Output {
    let rows = polygons.enumerated().map { i, p in G.Individual(polygon:p,provenance:[],bboxConfidence:bbox?[i]) }
    return .init(mode:.correctedOnly,individuals:rows,
        counts:.init(correctedInput:rows.count,originalInput:0,emittedIndividuals:rows.count,addedOriginalIndividuals:0,
            exactQuadDeduplicatedOriginals:0,duplicateOriginalObservations:0,rejectedOriginals:0),events:[])
}
func reads(_ polygons: [[G.Point]], _ scores: [Double], _ ids: [Int]? = nil) -> [NativeCoreMLRecognizedRegion] {
    polygons.enumerated().map { i, p in .init(sourceIndex:ids?[i] ?? i,
        polygon:p.map {CGPoint(x:$0.x,y:$0.y)},text:"synthetic",confidence:scores[i]) }
}
final class Spy {
    var calls = 0
    func postRecognition(scheduled: G.Output, input: G.Output, reads: [NativeCoreMLRecognizedRegion],
                         source165Indices: [Int], accepted165: [[Double]], source166: [[Double]], binding: String) {
        calls += 1
        precondition(source165Indices == [7,42] && accepted165.count == 2 && source166.count == 2)
        precondition(source166.allSatisfy {$0.count == 166} && accepted165.allSatisfy {$0.count == 165})
        precondition(source166[0][165] == Double(Float(reads[0].confidence)))
    }
}
struct Pre { struct Report {let keptIndices:[Int]}; let output:G.Output; let report:Report }
enum Failure: Error {case missingEvidence}
func moduleBinding(requestID:String,frame:Int,sourceImageIdentity:String,mode:String)->String {"bound"}
func route(_ anchor: Bool, simpleDeduplication: N.Configuration?, observed: Bool) throws {
    let input = bank([q(),q()]), recognized=input
    let reads=reads([q(),q()],[0.9,0.8],[7,42])
    let observer:Spy? = observed ? Spy() : nil
    // Poison absent prefixes: NMS without an observer must not index or build it.
    let source165:[[Double]] = simpleDeduplication != nil && !observed ? [] : Array(repeating:Array(repeating:0,count:165),count:43)
    let electedReads=reads
    let effectiveSource165:[[Double]]? = source165.isEmpty ? nil : source165
    let preIndices=Array(0..<43)
    let pre=Pre(output:bank(Array(repeating:q(),count:43)),report:.init(keptIndices:preIndices))
    let effectiveBank=pre.output, requestID="request", frame=0, layout=(imageIdentity:"source",unused:0)
    let anchorMode="fixed", mode=anchorMode
    if anchor {
        ANCHOR_BLOCK
        precondition(dedup.report.keptIndices == [0] && dedup.report.replacements[0].inputIndex == 1)
    } else {
        DISABLED_BLOCK
        precondition(dedup.report.keptIndices == [0] && dedup.report.replacements[0].retainedIndex == 0)
    }
    precondition(observer?.calls == (observed ? 1 : nil))
}
@main struct Check {
    static func main() throws {
        let selectedDefault = DefaultPolicySnapshot.defaultSimpleDeduplication!
        precondition(selectedDefault.iouThreshold.bitPattern == 0x3feb333333333333 && selectedDefault.rank == .recognition)
        precondition(DefaultPolicySnapshot.simpleDeduplication == selectedDefault)
        precondition(DefaultPolicySnapshot.$simpleDeduplication.withValue(nil) { DefaultPolicySnapshot.simpleDeduplication == nil })
        precondition(DefaultPolicySnapshot.simpleDeduplication == selectedDefault)
        let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys]
        let encoded=try encoder.encode(selectedDefault)
        precondition(String(data:encoded,encoding:.utf8) == #"{"iouThreshold":0.85,"rank":"rec"}"#)
        let same=[q(),q()]
        let source=bank(same,[1,0])
        let raw=reads(same,[0.9000000001,0.9000000002],[7,42])
        precondition(Float(raw[0].confidence) == Float(raw[1].confidence))
        let exact=try N.apply(source,reads:raw,configuration:.init(rank:.recognitionThenBBox))
        precondition(exact.report.keptIndices == [1],"REC64 must win before bbox even when Float32 confidence ties")
        precondition(exact.output.individuals == [source.individuals[1]])
        let equal=reads(same,[0.9,0.9],[7,42])
        let recOnly=try N.apply(source,reads:equal,configuration:.init())
        precondition(recOnly.report.keptIndices == [0])
        let bboxTie=try N.apply(bank(same,[0.1,0.9]),reads:equal,configuration:.init(rank:.recognitionThenBBox))
        precondition(bboxTie.report.keptIndices == [1])
        let chain=[q(),q(0.6),q(1.2)]
        let direct=try N.apply(bank(chain),reads:reads(chain,[0.9,0.8,0.7]),configuration:.init())
        precondition(direct.report.keptIndices == [0,2] && direct.report.replacements.count == 1)
        let separate=try N.apply(bank([q(),q(30)]),reads:reads([q(),q(30)],[0.8,0.9]),configuration:.init())
        precondition(separate.report.keptIndices == [0,1])
        // Force spatial indexing, with reversed geometry order, equal ranks, a
        // box crossing every interval, and retained-witness chains in each row.
        let many = (0..<16).reversed().flatMap { k in
            [0.0,0.6,1.2].map { q(Double(k)*30+$0) }
        } + [q(0).map { G.Point(x: $0.x*200, y: $0.y) }]
        let allEqual = reads(many, Array(repeating: 0.9, count: many.count))
        let indexed = try N.apply(bank(many), reads: allEqual, configuration: .init())
        let removed = Array(stride(from: 1, to: 48, by: 3))
        precondition(indexed.report.replacements.map(\.inputIndex) == removed)
        precondition(indexed.report.replacements.map(\.retainedIndex) == removed.map { $0-1 })
        precondition(indexed.report.keptIndices == many.indices.filter { !removed.contains($0) })
        let shuffled = (0..<16).map { q(Double($0)*30) }
        let ties = shuffled + shuffled.reversed() + shuffled + shuffled
        let tied = try N.apply(bank(ties), reads: reads(ties,Array(repeating: 0.9,count:64)), configuration:.init())
        precondition(tied.report.keptIndices == Array(0..<16))
        for i in 0..<16 {
            precondition(tied.report.replacements[(i*3)..<(i*3+3)].map(\.inputIndex) == [31-i,32+i,48+i])
        }
        let unknown=try N.apply(source,reads:reads(same,[.nan,0.9]),configuration:.init())
        precondition(unknown.report.keptIndices == [0,1])
        let empty=try N.apply(bank([]),reads:[],configuration:.init())
        precondition(empty.report.keptIndices.isEmpty)
        for invalid in [0.0,-0.1,1.1,Double.nan] {
            do {_ = try N.apply(source,reads:raw,configuration:.init(iouThreshold:invalid));preconditionFailure("bad threshold")}
            catch N.Failure.invalidThreshold {}
        }
        for invalid in [reads([q(0.1),q()],[0.9,0.8],[7,42]),reads(same,[0.9,0.8],[7,7]),[]] {
            do {_ = try N.apply(source,reads:invalid,configuration:.init());preconditionFailure("unbound REC")}
            catch N.Failure.recognitionBinding {}
        }
        for anchor in [false,true] {
            for observed in [false,true] {
                try route(anchor,simpleDeduplication:nil,observed:observed)
                try route(anchor,simpleDeduplication:.init(),observed:observed)
            }
        }
        print("PASS actual NMS contracts + both actual raw dispatch blocks x nil/NMS x observerOFF/ON; no-prefix NMS bypass proven")
    }
}
'''


def main():
    raw = (OCR / 'NativeOCRRawCanonicalRuntime.swift').read_text()
    starts = []
    cursor = 0
    while True:
        start = raw.find('let source166: [[Double]]?', cursor)
        if start < 0:
            break
        end = raw.index('if let observer {\n', raw.index('dedup = try NativeOCRPostRecognitionDeduplication.apply', start))
        starts.append(raw[start:end])
        cursor = end
    assert len(starts) == 2
    recognizer = (OCR / 'NativeCoreMLRecognizer.swift').read_text()
    declarations = recognizer[recognizer.index('@available(iOS 18.0, *)\nstruct NativeCoreMLRecognizedRegion:'):
        recognizer.index('@available(iOS 18.0, *)\nstruct NativeCoreMLGreedyRecognition:')]
    start = raw.index('static let defaultSimpleDeduplication:')
    end = raw.index('    /// Optional transport only.', start)
    check = SWIFT.replace('ANCHOR_BLOCK', starts[1]).replace('DISABLED_BLOCK', starts[0])
    check = check.replace('DEFAULT_DECLARATIONS', raw[start:end])
    with tempfile.TemporaryDirectory(prefix='aidoku-simple-nms-') as directory:
        work = Path(directory)
        types = work / 'RecognitionValues.swift'
        types.write_text('import CoreGraphics\nimport Foundation\n' + declarations)
        main_source = work / 'Check.swift'
        main_source.write_text(check)
        binary = work / 'check'
        files = ['NativeOCRIndividualGeometryHypotheses.swift', 'NativeOCRGeometryDeduplication.swift',
            'NativeOCRPostRecognitionFeatures.swift', 'NativeOCRPostRecognitionDeduplication.swift', 'NativeSimpleOCRDedup.swift']
        subprocess.run(['swiftc', '-O', '-swift-version', '6', '-module-cache-path', str(work / 'modules'),
            *[str(OCR / name) for name in files], str(types), str(main_source), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == '__main__':
    main()
