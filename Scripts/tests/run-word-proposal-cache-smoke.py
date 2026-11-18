"""Page-local generated-word cache: accepted/nil/error isolation and bounds."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
PROGRAM = r'''
import Foundation
import CoreGraphics
enum CorpusWholeWordProposal {
 struct Result {let image:CGImage}
}
enum Failed:Error {case example}
let context=CGContext(data:nil,width:2,height:2,bitsPerComponent:8,bytesPerRow:8,
 space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
let expected=CorpusWholeWordProposal.Result(image:context.makeImage()!)
let key=Data("shaping-mode-a".utf8),other=Data("shaping-mode-b".utf8)
let cache=CorpusRenderReferenceCache(enabled:true)
var calls=0
let first=cache.wordProposal(for:key) {calls+=1;return expected}
let second=cache.wordProposal(for:key) {calls+=1;return nil}
precondition(first != nil && second != nil && calls==1 && cache.proposalHits==1)
let rejected=cache.wordProposal(for:other) {calls+=1;return nil}
let stillRejected=cache.wordProposal(for:other) {calls+=1;return expected}
precondition(rejected==nil && stillRejected==nil && calls==2)
let throwKey=Data("failure".utf8)
do {_ = try cache.wordProposal(for:throwKey) {throw Failed.example};preconditionFailure()}
catch Failed.example {}
precondition(cache.wordProposal(for:throwKey) {expected} != nil)
// A different page never reuses the first page's identity.
let separate=CorpusRenderReferenceCache(enabled:true)
precondition(separate.wordProposal(for:key) {nil} == nil)
let disabled=CorpusRenderReferenceCache(enabled:false)
var disabledCalls=0
for _ in 0..<2 {_ = disabled.wordProposal(for:key) {disabledCalls+=1;return expected}}
precondition(disabledCalls==2 && disabled.proposalHits==0)
// Negative results are bounded as well as image memory.
let bounded=CorpusRenderReferenceCache(enabled:true)
for i in 0..<513 {_ = bounded.wordProposal(for:Data(String(i).utf8)) {nil}}
var evicted=false
_ = bounded.wordProposal(for:Data("0".utf8)) {evicted=true;return nil}
precondition(evicted)
print("PASS accepted/nil caching, shaping-key isolation, failure retry, page isolation, disabled mode, bounded entries")
'''
with tempfile.TemporaryDirectory(prefix='aidoku-word-proposal-cache-') as tmp:
    main = Path(tmp) / 'main.swift'
    main.write_text(PROGRAM)
    binary = Path(tmp) / 'check'
    subprocess.run(['xcrun', 'swiftc', '-O', str(ROOT / 'Scripts/inpainting_compare/render_reference_cache.swift'),
                    str(main), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
