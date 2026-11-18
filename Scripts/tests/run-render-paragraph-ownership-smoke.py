"""Test the actual renderer ownership guard without models or provider calls."""
import hashlib
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
source = ROOT/'Aidoku/Core/Translation/NativeEngine/Ensemble/NativeMainEnsemblePipeline.swift'
text = source.read_text()
start = text.index('    static func preservesParagraphOwnership(')
body = text.index('{', start)
depth, end = 1, body+1
while depth:
    depth += (text[end] == '{') - (text[end] == '}')
    end += 1
method = text[start:end]
fixture = 'import Foundation\nenum Contract {\n'+method+'\n}\n'+r'''
let input: [[String: Any]] = [["id":"a","text":"第一 文"],["id":"b","text":"第二文"],["id":"kept","text":""]]
precondition(Contract.preservesParagraphOwnership(input,input))
precondition(Contract.preservesParagraphOwnership(input,[input[2],input[1],["id":"a","text":"第一\n文"]]))
precondition(!Contract.preservesParagraphOwnership(input,[["id":"a+b","text":"第一 文第二文"],input[2]]))
precondition(!Contract.preservesParagraphOwnership(input,[input[0],input[2]]))
precondition(!Contract.preservesParagraphOwnership(input,[input[0],["id":"b","text":"different"],input[2]]))
precondition(!Contract.preservesParagraphOwnership(input,[input[0],input[0],input[2]]))
precondition(!Contract.preservesParagraphOwnership(input,[["id":"a","text":"第一 文第二文"],["id":"b","text":""],input[2]]))
print("Renderer owner contract: reorder/whitespace allowed; union/deletion/duplicates/content reassignment rejected")
'''
for file, banned in [
    ('NativeMainEnsemblePipeline.swift',['joinAdjacentSourceFragments(', 'joinSameHeightColumns(', 'NativeCausalParagraphAdjacencyGraph.apply(', 'originalAxisContinuation(', 'partitionRedundantTargets(']),
    ('NativeEnsembleOwnershipSourceNear.swift',['NativeSourceTextBlockGrouping.apply(', 'EnsembleCandidate02.apply(']),
    ('NativeMainEnsembleRenderer.swift',['NativeSourceOwnerRecovery.apply(']),
]:
    content = (source.parent/file).read_text()
    assert not any(symbol in content for symbol in banned), file
cache = ROOT/'build/render-paragraph-ownership-smoke'
cache.mkdir(parents=True,exist_ok=True)
swift = cache/'main.swift'
stamp = cache/'fingerprint'
fingerprint = hashlib.sha256(fixture.encode()).hexdigest()
if not stamp.exists() or stamp.read_text() != fingerprint:
    swift.write_text(fixture)
    subprocess.run(['xcrun','swiftc',str(swift),'-o',str(cache/'smoke')],check=True)
    stamp.write_text(fingerprint)
subprocess.run([str(cache/'smoke')],check=True)
