#!/usr/bin/env python3
"""Standalone host contracts for the production source-font context boundary.

Compiles the actual Result/context/estimate/matrix declarations and actual
SourceNativeInput. Extraction, assembly and both predictors are test doubles:
this verifies same-call handoff/control flow, not CV/model numerical quality.
No shared cache, model assets, dataset, training, network or full-page reads.
"""
import json
from pathlib import Path
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[2]
ENSEMBLE = ROOT / 'Aidoku/Core/Translation/NativeEngine/Ensemble'


def declaration(source, marker):
    start = source.index(marker)
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end] + '\n'


STUBS = r'''
import Foundation
import CoreGraphics
typealias Matrix = [[Double]]
enum NativeRFDETRLayoutResource { static let highresSourceWeightsSHA256 = "fixture" }
enum NativeSourceFontGraphMath {}
struct NativeSourceFontModelAccess {}
var extractionCalls = 0
var graphCalls = 0
var fault = ""
var lateFault = false
func AIDExtractAllSourceSignals(_ request: [String: Any], _ error: inout NSError?) -> [String: Any]? {
    extractionCalls += 1
    let prior = request["prior"] as! Double
    // Verify the original prior is used for measurement, never the final em.
    precondition(prior == 10 || prior == 20)
    precondition((request["rgb"] as! Data).first == UInt8(prior))
    let marker = Double(extractionCalls)
    var row: [String: Any] = ["native156": Array(repeating: prior, count: 156),
        "CE291": Array(repeating: 0.0, count: 291),
        "style187": Array(repeating: marker, count: 262),
        "angles131": NSNumber(value: -marker / 10)]
    switch fault {
    case "missingAngle": row.removeValue(forKey: "angles131")
    case "nanAngle": row["angles131"] = Double.nan
    case "vectorAngle": row["angles131"] = [marker]
    case "shortStyle": row["style187"] = [marker]
    case "nanStyle": row["style187"] = Array(repeating: Double.nan, count: 262)
    default: break
    }
    return row
}
enum NativeEarlySourceFontGraph {
    struct Result { let values: [Double]; let point: [Double]; let affinities: [Double]; let stages: [String: [Double]] }
    static func predict(native: Matrix, evidence: Matrix, priors: [Double], groups: [String], pageSizes: Matrix,
                        signals: [String: Any], metadata: [String: Any], access: NativeSourceFontModelAccess,
                        returnStages: Bool) throws -> Result {
        graphCalls += 1
        precondition(groups == ["duplicate", "duplicate"])
        precondition(priors == [20, 10])
        return Result(values: priors.map { $0 + 1 }, point: priors, affinities: [],
                      stages: returnStages ? ["style187": [-999]] : [:])
    }
}
enum NativeLateSourceFontGraph {
    struct Result { let values: [Double]; let stages: [String: [Double]] }
    static func predict(before: [Double], point: [Double], native: Matrix, evidence: Matrix,
                        priors: [Double], groups: [String], pageSizes: Matrix, signals: [String: Any],
                        models: [String: String], policies: [String: [String: Any]], metadata: [String: Any],
                        sourceIDs: [String], access: NativeSourceFontModelAccess, returnStages: Bool) throws -> Result {
        graphCalls += 1
        precondition(priors == [20, 10] && sourceIDs == ["aliased", "aliased"])
        return Result(values: lateFault ? [Double.nan] : [27, 17],
                      stages: returnStages ? ["angles131": [999], "198": [27, 17]] : [:])
    }
}
'''


SHELL = r'''
    typealias Matrix = [[Double]]
    typealias Math = NativeSourceFontGraphMath
    let graph: [String: Any] = ["latePolicies": [String: [String: Any]](),
                                "sourceIdentityGroups": ["duplicate": "aliased"]]
    let measurement: [String: Any] = [:]
    let fontFaces: [[String: Any]] = [["fixture": "face"]]
    let lateModels: [String: String] = [:]
    let lateMetadata: [String: Any] = [:]
    let modelAccess = NativeSourceFontModelAccess()
    func assemble(_ rows: [[String: Any]], packets: [SourceNativeInput]) throws -> [String: Any] {
        ["style187": try Self.matrix(rows, "style187", width: 262)]
    }
'''


TESTS = r'''
func packet(_ prior: Double) -> SourceNativeInput {
    let polygon = [CGPoint(x: 0, y: 0), CGPoint(x: 2, y: 0), CGPoint(x: 2, y: 2)]
    return SourceNativeInput(width: 2, height: 2, rgb: Array(repeating: UInt8(prior), count: 12),
        rf: Array(repeating: 0, count: 108), coarseRF: Array(repeating: 0, count: 16),
        affinityScores: Array(repeating: 0, count: 5), rfModelWeightsSHA256: "fixture",
        memberPolygons: [polygon], mergedPolygon: polygon, bbox: CGRect(x: 0, y: 0, width: 2, height: 2),
        fontPriorSourcePixels: prior, crop: CGRect(x: prior, y: 0, width: 2, height: 2),
        pageSize: CGSize(width: 100, height: 100), sourceIdentity: "duplicate", sourceText: "actual",
        confidence: nil, role: nil, wordEvidence: [SourceWordEvidence(text: "actual", sourceIndex: Int(prior),
            bbox: CGRect(x: 0, y: 0, width: 2, height: 2), polygon: polygon)],
        primary: Array(repeating: 0, count: 4), boundary: Array(repeating: 0, count: 4),
        ownMask: Array(repeating: 1, count: 4), contextMask: Array(repeating: 1, count: 4),
        ocr: Array(repeating: 0, count: 32))
}
@main enum Smoke {
    static func main() throws {
        let inference = NativeAcceptedSourceFontInference()
        precondition(NativeAcceptedSourceFontInference.cachePolicy == nil)
        precondition(NativeAcceptedSourceFontInference.selectedEstimatorIdentity == "accepted-font198-v1")
        let packets = [packet(20), packet(10)], styles = [[String: Any](), [:]]
        let legacy = NativeAcceptedSourceFontInference.Result(values: [5], stages: [:], fontFaces: [])
        precondition(legacy.context == nil && legacy.estimatorIdentity == "accepted-font198-v1")
        let baseline = try inference.estimate(packets, styles: styles)
        precondition(baseline.values == [27, 17] && baseline.stages.isEmpty && baseline.context == nil)
        for stages in [false, true] {
            let before = extractionCalls
            let result = try inference.estimate(packets, styles: styles, returnStages: stages, returnContext: true)
            precondition(extractionCalls == before + 2)
            let context = result.context!
            precondition(result.values == baseline.values && result.fontFaces[0]["fixture"] as? String == "face")
            precondition(context.packetOrder == [0, 1] && context.originalPriors == [20, 10])
            precondition(context.finalSourceEMs == result.values)
            precondition(context.geometryMode == .originalMembers)
            precondition(context.measuredMemberPolygons == packets.map(\.memberPolygons))
            precondition(context.style187 == [Array(repeating: Double(before + 1), count: 262),
                                               Array(repeating: Double(before + 2), count: 262)])
            precondition(context.angles131 == [-Double(before + 1) / 10, -Double(before + 2) / 10])
            precondition(context.packets.map(\.crop) == packets.map(\.crop))
            precondition(context.packets.map(\.pageSize) == packets.map(\.pageSize))
            precondition(context.packets.map(\.width) == packets.map(\.width))
            precondition(context.packets.map(\.height) == packets.map(\.height))
            precondition(context.packets.map(\.rgb) == packets.map(\.rgb))
            precondition(context.packets.map { $0.wordEvidence[0].sourceIndex } == [20, 10])
            precondition(context.packets.allSatisfy { $0.rawNative.isEmpty && $0.observationValid.isEmpty })
            precondition(stages ? result.stages["style187"] == [-999] : result.stages.isEmpty)
        }
        for stages in [false, true] {
            let before = (extractionCalls, graphCalls)
            let empty = try inference.estimate([], styles: [], returnStages: stages, returnContext: true)
            let c = empty.context!
            precondition(c.packets.isEmpty && c.packetOrder.isEmpty && c.originalPriors.isEmpty)
            precondition(c.finalSourceEMs.isEmpty && c.style187.isEmpty && c.angles131.isEmpty)
            precondition(empty.values.isEmpty && empty.stages.isEmpty)
            precondition(before == (extractionCalls, graphCalls))
        }
        let emptyDefault = try inference.estimate([], styles: [])
        precondition(emptyDefault.context == nil)
        // A previously ignored absent angle must remain ignored for default callers.
        fault = "missingAngle"
        let missingAngleDefault = try inference.estimate(packets, styles: styles)
        precondition(missingAngleDefault.values == baseline.values)
        for mode in ["missingAngle", "nanAngle", "vectorAngle", "shortStyle", "nanStyle"] {
            fault = mode
            do {
                _ = try inference.estimate(packets, styles: styles, returnContext: true)
                preconditionFailure("accepted malformed measurement: \(mode)")
            } catch NativeAcceptedSourceFontInference.Failure.extraction { }
        }
        fault = ""
        lateFault = true
        do {
            _ = try inference.estimate(packets, styles: styles, returnContext: true)
            preconditionFailure("accepted mismatched final em batch")
        } catch NativeAcceptedSourceFontInference.Failure.extraction { }
        lateFault = false
        do {
            _ = try inference.estimate(packets, styles: [], returnContext: true)
            preconditionFailure("accepted style count mismatch")
        } catch NativeAcceptedSourceFontInference.Failure.invalidSource { }
        let normalization = try inference.estimate(packets, styles: styles, returnContext: true, geometry: .bboxOnly)
        precondition(normalization.context!.geometryMode == .bboxOnly)
        precondition(normalization.context!.measuredMemberPolygons.allSatisfy(\.isEmpty))
        precondition(normalization.context!.packets.map(\.memberPolygons) == packets.map(\.memberPolygons))
        print("passed: default parity, same-call signals, stages independence, repeat freshness, packet order,")
        print("original priors, final ems, retained observations, empty batches, malformed signals/batches")
    }
}
'''


def checked(command):
    result = subprocess.run(list(map(str, command)), cwd=ROOT, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result.stdout.strip()


def main():
    production = ENSEMBLE / 'NativeAcceptedSourceFontInference.swift'
    source = production.read_text()
    markers = ['enum Failure:', 'enum SourceGeometry:', 'static var selectedEstimatorIdentity:',
               'static var cachePolicy:', 'struct SourceFontContext:', 'struct Result {',
               'func estimate(', 'private static func makeContext(', 'private static func matrix(']
    boundary = STUBS + '\nfinal class NativeAcceptedSourceFontInference {\n' + SHELL
    boundary += ''.join(declaration(source, marker) for marker in markers) + '}\n' + TESTS
    with tempfile.TemporaryDirectory(prefix='aidoku-source-font-context-') as temporary:
        out = Path(temporary)
        fixture = out / 'ContextSmoke.swift'
        fixture.write_text(boundary)
        start = time.monotonic()
        checked(['xcrun', 'swiftc', '-frontend', '-parse', production])
        checked(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-O',
                 '-module-cache-path', out / 'modules', ENSEMBLE / 'SourceNativeInput.swift',
                 ENSEMBLE / 'NativeSourceFontFitGroups.swift',
                 fixture, '-o', out / 'smoke'])
        build = time.monotonic() - start
        start = time.monotonic()
        result = checked([out / 'smoke'])
        print(json.dumps(dict(phase='host-only', buildSeconds=build,
                              testSeconds=time.monotonic() - start, result=result)))


if __name__ == '__main__':
    main()
