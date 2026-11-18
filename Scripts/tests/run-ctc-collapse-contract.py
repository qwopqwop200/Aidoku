#!/usr/bin/env python3
"""Compile only the production CTC decoder; synthetic arrays, no model/API calls."""
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
OCR = ROOT / "Aidoku/Core/Translation/NativeEngine/OCR"
source = (OCR / "NativeCoreMLRecognizer.swift").read_text()
tokens = source[source.index("struct NativeCoreMLCTCTokenObservation:"):source.index("/// Explicit full-bank observation")]
errors = source[source.index("enum NativeCoreMLRecognizerError:"):source.index("    var errorDescription:")]
errors = errors.replace(", LocalizedError", "") + "}\n"
decoder = source[source.index("struct NativeCoreMLDecodedText:"):source.index("/// Read-only replay identity;")]
checks = r'''
func check(_ value: Bool, _ message: String) {
    precondition(value, message)
}
let dictionary = ["a", "b", "っ", "…", "𠮷", "xy"]
func reference(_ labels: [Int], _ scores: [Double]) -> NativeCoreMLDecodedText {
    var previous = -1, text = "", sum = 0.0
    var tokens: [NativeCoreMLCTCTokenObservation] = []
    for (label, score) in zip(labels, scores) {
        if label > 0 && label != previous {
            text += dictionary[label - 1]
            sum += score
            tokens.append(.init(text: dictionary[label - 1], confidence: score))
        }
        previous = label
    }
    return .init(text: text, confidence: tokens.isEmpty ? 0 : sum / Double(tokens.count), tokenObservations: tokens)
}
func compact(_ labels: [Int], _ scores: [Double], rows: Int = 2) throws -> MLMultiArray {
    let array = try MLMultiArray(shape: [NSNumber(value: rows), NSNumber(value: labels.count)], dataType: .float32)
    for t in labels.indices {
        array[[0, NSNumber(value: t)]] = NSNumber(value: labels[t])
        array[[1, NSNumber(value: t)]] = NSNumber(value: scores[t])
        if rows == 10 {
            for rank in 0..<4 {
                array[[NSNumber(value: 2 + rank * 2), NSNumber(value: t)]] = NSNumber(value: labels[t])
                array[[NSNumber(value: 3 + rank * 2), NSNumber(value: t)]] = NSNumber(value: scores[t])
            }
        }
    }
    return array
}
func decode(_ array: MLMultiArray, spans: Bool = false, model: NativeMangaNGram? = nil, greedy: Bool = false) throws -> NativeCoreMLDecodedText {
    try NativeCoreMLCTCDecoder.decode(output: array, dictionary: dictionary,
        expectedShape: array.shape.map(\.intValue), languageModel: model, observeEmissionSpans: spans, observeGreedy: greedy)
}
func verify(_ labels: [Int], _ rawScores: [Double], denseType: MLMultiArrayDataType) throws {
    let scores = rawScores.map { Double(Float($0)) }
    let expected = reference(labels, scores)
    let packed = try compact(labels, scores)
    let baseline = try decode(packed)
    check(baseline == expected, "compact first-emission contract")
    let measured = try decode(packed, spans: true)
    check(measured.text == expected.text && measured.confidence.bitPattern == expected.confidence.bitPattern,
        "span collection changed acceptance")
    check(measured.tokenObservations.count == expected.tokenObservations.count, "span token count")
    var token = 0, t = 0, blanks = 0
    while t < labels.count {
        if labels[t] == 0 { blanks += 1; t += 1; continue }
        let start = t, label = labels[t]
        while t < labels.count && labels[t] == label { t += 1 }
        let span = measured.tokenObservations[token].emissionSpan!
        check(span.steps == start..<t && span.timeStepCount == labels.count && span.precedingBlankSteps == blanks,
            "emission/blank span")
        check(measured.tokenObservations[token].confidence == scores[start], "repeat raised token confidence")
        blanks = 0; token += 1
    }
    let dense = try MLMultiArray(shape: [1, NSNumber(value: labels.count), NSNumber(value: dictionary.count + 1)], dataType: denseType)
    for t in labels.indices {
        for c in 0...dictionary.count {
            dense[[0, NSNumber(value: t), NSNumber(value: c)]] = NSNumber(value: c == labels[t] ? scores[t] : -1)
        }
    }
    let denseScores = labels.indices.map { dense[[0, NSNumber(value: $0), NSNumber(value: labels[$0])]].doubleValue }
    let denseRead = try decode(dense)
    check(denseRead == reference(labels, denseScores), "dense datatype contract")
    let denseMeasured = try decode(dense, spans: true)
    check(denseMeasured.text == denseRead.text && denseMeasured.confidence == denseRead.confidence,
        "dense span parity")
    check(denseMeasured.tokenObservations.map(\.emissionSpan) == measured.tokenObservations.map(\.emissionSpan),
        "compact/dense span parity")
}
var count = 0
for length in [4, 7, 19, 40, 148, 400] {
    for seed in 0..<24 {
        var state = UInt64(seed + 1)
        var labels: [Int] = [], scores: [Double] = []
        for step in 0..<length {
            state = state &* 6364136223846793005 &+ 1
            labels.append(seed == 0 ? 0 : seed == 1 ? 1 : Int((state >> 32) % 7))
            scores.append(Double((step * 17 + seed * 13) % 101) / 100)
        }
        for type: MLMultiArrayDataType in [.float16, .float32, .double] {
            try verify(labels, scores, denseType: type); count += 1
        }
    }
}
// Ten-row output also traverses the real n-gram code, with a tiny uniform table.
var table = Data("MNG3DATA".utf8)
func integer<T: FixedWidthInteger>(_ value: T) { var v = value.littleEndian; withUnsafeBytes(of: &v) { table.append(contentsOf: $0) } }
for value: UInt32 in [1, 3, 4, 0, 0, 2, 3, 97, 98] { integer(value) }
let model = try NativeMangaNGram(data: table)
let ngramArray = try compact([0, 1, 1, 0, 2, 2, 0], [0.9, 0.4, 0.8, 1, 0.3, 0.9, 1], rows: 10)
let plain = try decode(ngramArray, model: model)
let observed = try decode(ngramArray, spans: true, model: model)
check(plain.text == observed.text && plain.confidence == observed.confidence, "n-gram observation parity")
check(observed.tokenObservations.allSatisfy { $0.emissionSpan != nil }, "n-gram lost timing provenance")
// Force a visually gated substitution using synthetic numeric LM counts.
table = Data("MNG3DATA".utf8)
for value: UInt32 in [1, 3, 4, 1, 0, 2, 3, 97, 98] { integer(value) }
integer((UInt64(1) << 60) | 4); integer(Float16(0).bitPattern)
let correctionModel = try NativeMangaNGram(data: table)
let correctionArray = try compact([0, 1, 1, 0], [1, 0.7, 0.71, 1], rows: 10)
for step in [1, 2] {
    correctionArray[[2, NSNumber(value: step)]] = 2
    correctionArray[[3, NSNumber(value: step)]] = NSNumber(value: 0.7)
}
let corrected = try decode(correctionArray, spans: true, model: correctionModel, greedy: true)
let unobservedCorrection = try decode(correctionArray, model: correctionModel)
check(corrected.text == "b" && corrected.languageModelCorrections == 1, "synthetic LM must exercise substitution")
check(corrected.tokenObservations.first?.emissionSpan?.steps == 1..<3, "substitution lost greedy path timing")
check(corrected.text == unobservedCorrection.text && corrected.confidence == unobservedCorrection.confidence,
    "observation changed corrected acceptance")
check(corrected.confidence == Double(Float(0.7)), "LM replaced visual first-emission confidence")
check(corrected.greedyObservation?.text == "a" && corrected.greedyObservation?.confidence == Double(Float(0.7)),
    "typed observer must retain actual pre-ngram decode when requested")
check(corrected.greedyObservation?.tokenObservations?.map(\.text) == ["a"] && corrected.tokenObservations.map(\.text) == ["b"],
    "actual greedy token observations must stay distinct from corrected token observations")
check(unobservedCorrection.greedyObservation == nil, "default decode retains no extra greedy text")
for invalid: Float in [.nan, .infinity, -1, 7, 1.5] {
    let array = try compact([0, 1, 0, 2], [1, 0.4, 1, 0.7])
    array.dataPointer.assumingMemoryBound(to: Float.self)[1] = invalid
    do { _ = try decode(array); preconditionFailure("accepted invalid compact index") }
    catch NativeCoreMLRecognizerError.unsupportedModelOutputType { }
}
print("PASS \(count) compact/dense datatype+span cases; n-gram and 5 malformed indices")
'''
with tempfile.TemporaryDirectory(prefix="aidoku-ctc-contract-") as folder:
    folder = Path(folder)
    main = folder / "main.swift"
    main.write_text("import Foundation\nimport CoreML\n" + tokens + errors + decoder + checks)
    build = time.monotonic()
    subprocess.run(["xcrun", "swiftc", "-O", "-module-cache-path", str(folder / "modules"),
                    str(OCR / "NativeMangaNGram.swift"), str(main), "-o", str(folder / "check")], check=True)
    built = time.monotonic()
    subprocess.run([str(folder / "check")], check=True)
    print(f"build={built - build:.3f}s tests={time.monotonic() - built:.3f}s; synthetic-only")
