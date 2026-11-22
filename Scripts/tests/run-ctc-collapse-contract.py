#!/usr/bin/env python3
"""Compile only the production CTC decoder; synthetic arrays, no model/API calls."""
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "Aidoku"
OCR = APP / "Core/Translation/NativeEngine/OCR"
SOURCES = [OCR / "NativeCoreMLRecognizer.swift", OCR / "NativeMangaNGram.swift", OCR / "NativeOCRFrameTypes.swift",
           APP / "Core/Translation/IPhoneOCRSettings.swift",
           APP / "Extensions/Foundation/NSLocalizedString.swift"]
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
func decode(_ array: MLMultiArray, model: NativeMangaNGram? = nil) throws -> NativeCoreMLDecodedText {
    try NativeCoreMLCTCDecoder.decode(output: array, dictionary: dictionary,
        expectedShape: [1, array.shape[1].intValue], languageModel: model)
}
func verify(_ labels: [Int], _ rawScores: [Double]) throws {
    let scores = rawScores.map { Double(Float($0)) }
    let packed = try compact(labels, scores)
    check(try decode(packed) == reference(labels, scores), "compact first-emission contract")
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
        try verify(labels, scores); count += 1
    }
}
// Ten-row output also traverses the real n-gram code, with a tiny uniform table.
var table = Data("MNG3DATA".utf8)
func integer<T: FixedWidthInteger>(_ value: T) { var v = value.littleEndian; withUnsafeBytes(of: &v) { table.append(contentsOf: $0) } }
for value: UInt32 in [1, 3, 4, 0, 0, 2, 3, 97, 98] { integer(value) }
let model = try NativeMangaNGram(data: table)
let ngramArray = try compact([0, 1, 1, 0, 2, 2, 0], [0.9, 0.4, 0.8, 1, 0.3, 0.9, 1], rows: 10)
let plain = try decode(ngramArray, model: model)
check(plain == (try decode(ngramArray)), "uniform n-gram must not change the greedy decode")
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
let corrected = try decode(correctionArray, model: correctionModel)
check(corrected.text == "b", "synthetic LM must exercise substitution")
check(corrected.confidence == Double(Float(0.7)), "LM replaced visual first-emission confidence")
check((try decode(correctionArray)).text == "a", "decode without a model stays greedy")
for invalid: Float in [.nan, .infinity, -1, 7, 1.5] {
    let array = try compact([0, 1, 0, 2], [1, 0.4, 1, 0.7])
    array.dataPointer.assumingMemoryBound(to: Float.self)[1] = invalid
    do { _ = try decode(array); preconditionFailure("accepted invalid compact index") }
    catch NativeCoreMLRecognizerError.unsupportedModelOutputType { }
}
print("PASS \(count) compact cases; n-gram and 5 malformed indices")
'''
with tempfile.TemporaryDirectory(prefix="aidoku-ctc-contract-") as folder:
    folder = Path(folder)
    main = folder / "main.swift"
    main.write_text("import Foundation\nimport CoreML\n" + checks)
    build = time.monotonic()
    subprocess.run(["xcrun", "swiftc", "-O", "-module-cache-path", str(folder / "modules"),
                    *map(str, SOURCES), str(main), "-o", str(folder / "check")], check=True)
    built = time.monotonic()
    subprocess.run([str(folder / "check")], check=True)
    print(f"build={built - build:.3f}s tests={time.monotonic() - built:.3f}s; synthetic-only")
