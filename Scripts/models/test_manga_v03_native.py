#!/usr/bin/env python3
"""Compile actual compact pack/decode code with metadata-only host carriers."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
NATIVE = ROOT / 'Aidoku/Core/Translation/NativeEngine/OCR'


def block(source, marker):
    start = source.index(marker); begin = source.index('{', start); depth = 1; end = begin + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}'); end += 1
    return source[start:end]


def main():
    text = (NATIVE / 'NativeCoreMLRecognizer.swift').read_text()
    tokens = block(text, 'struct NativeCoreMLCTCTokenObservation:')
    error = block(text, 'enum NativeCoreMLRecognizerError:').split('    var errorDescription:')[0]
    error = error.replace(', LocalizedError', '') + '}\n'
    decoder = text[text.index('@available(iOS 18.0, *)\nstruct NativeCoreMLDecodedText:'):]
    pack = block(text, 'private static func packCompactOutputs(').replace('private static', 'static', 1)
    carriers = '''
import Foundation
import CoreML
struct NativeCoreMLRecognitionModelVariant {
    struct Bucket { let timeSteps: Int }
    let batchSize: Int
    let bucket: Bucket
}
'''
    tests = r'''
@main struct Tests {
    static func check(_ condition: Bool, _ name: String) throws {
        if !condition { throw NSError(domain:name,code:1) }
    }
    static func main() throws {
        let lm = try NativeMangaNGram(data:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
        let dictionary = ["こ","ん","に","ち","わ","は"]
        let indices = try MLMultiArray(shape:[1,10],dataType:.int32)
        let scores = try MLMultiArray(shape:[1,10],dataType:.float32)
        let top = try MLMultiArray(shape:[1,10,4],dataType:.int32)
        let probabilities = try MLMultiArray(shape:[1,10,4],dataType:.float32)
        memset(indices.dataPointer,0,indices.count*4);memset(top.dataPointer,0,top.count*4)
        memset(probabilities.dataPointer,0,probabilities.count*4)
        let ids = indices.dataPointer.assumingMemoryBound(to:Int32.self)
        let p = scores.dataPointer.assumingMemoryBound(to:Float.self)
        let alternatives = top.dataPointer.assumingMemoryBound(to:Int32.self)
        let altP = probabilities.dataPointer.assumingMemoryBound(to:Float.self)
        for t in 0..<10 {
            ids[t] = t%2==0 ? Int32(t/2+1) : 0
            p[t] = t==8 ? 0.52 : 0.99
            alternatives[t*4] = ids[t];altP[t*4]=p[t]
        }
        alternatives[8*4+1]=6;altP[8*4+1]=0.45
        let variant=NativeCoreMLRecognitionModelVariant(batchSize:1,bucket:.init(timeSteps:10))
        let packed=try Packing.packCompactOutputs(indices:indices,scores:scores,variant:variant,topIndices:top,topScores:probabilities)
        try check(packed.count==1 && packed[0].shape.map(\.intValue)==[10,10],"topK packing contract")
        let greedy=try NativeCoreMLCTCDecoder.decode(output:packed[0],dictionary:dictionary,expectedShape:[2,10])
        let corrected=try NativeCoreMLCTCDecoder.decode(output:packed[0],dictionary:dictionary,expectedShape:[2,10],languageModel:lm)
        try check(greedy.text=="こんにちわ" && corrected.text=="こんにちは","real decoder applies ngram")
        try check(greedy.confidence==corrected.confidence,"recognition acceptance confidence preserved")
        try check(corrected.languageModelCorrections==1 && corrected.tokenObservations.count==5,"token provenance retained")
        let legacy=try Packing.packCompactOutputs(indices:indices,scores:scores,variant:variant)
        let legacyRead=try NativeCoreMLCTCDecoder.decode(output:legacy[0],dictionary:dictionary,expectedShape:[2,10],languageModel:lm)
        try check(legacyRead==greedy,"legacy two-row models unchanged")
        var rejected=false
        do {_=try Packing.packCompactOutputs(indices:indices,scores:scores,variant:variant,topIndices:top)} catch {rejected=true}
        try check(rejected,"incomplete topK rejected")
        memset(indices.dataPointer,0,indices.count*4);memset(top.dataPointer,0,top.count*4)
        let blank=try Packing.packCompactOutputs(indices:indices,scores:scores,variant:variant,topIndices:top,topScores:probabilities)
        let blankRead=try NativeCoreMLCTCDecoder.decode(output:blank[0],dictionary:dictionary,expectedShape:[2,10],languageModel:lm)
        try check(blankRead.text.isEmpty && blankRead.confidence==0,"LM cannot invent from blank decode")
        print("7 actual native pack/decode integration checks passed")
    }
}
'''
    output = ROOT / 'build/model-refresh-native-tests'; output.mkdir(exist_ok=True)
    source = output / 'NativeMangaV03Tests.swift'
    source.write_text(carriers + tokens + '\n' + error + '\nenum Packing {\n' + pack + '\n}\n' + decoder + tests)
    sources = [NATIVE / 'NativeMangaNGram.swift', source]
    fingerprint = hashlib.sha256(b''.join(p.read_bytes() for p in sources)).hexdigest()
    receipt = output / 'fingerprint'; binary = output / 'tests'
    if not binary.exists() or not receipt.exists() or receipt.read_text() != fingerprint:
        subprocess.run(['xcrun','swiftc','-O','-parse-as-library','-module-cache-path',
            str(ROOT/'build/segmentation-gt-replay-module-cache'),*map(str,sources),'-o',str(binary)],check=True)
        receipt.write_text(fingerprint)
    result = subprocess.run([str(binary),str(ROOT/'Aidoku/Resources/Translation/manga_ngram_v03.bin')],
                            check=True,text=True,capture_output=True)
    print(result.stdout)
    (output/'RESULT.json').write_text(json.dumps(dict(checks=7,passed=True,sourceFingerprint=fingerprint,
        scope='actual production pack and decode with numeric carrier fixtures and official LM data'),indent=2))


if __name__ == '__main__':main()
