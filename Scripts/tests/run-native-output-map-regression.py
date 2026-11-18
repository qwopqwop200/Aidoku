#!/usr/bin/env python3
"""Exercise actual launcher object identities across source additions/removals."""
from pathlib import Path
import subprocess
import tempfile
import time
ROOT = Path(__file__).resolve().parents[2]
source = (ROOT / 'Scripts/image-translation.swift').read_text()
start = source.index('        func stableOutputMap(')
end = source.index('        let map = cache.appendingPathComponent("output-map.json")', start)
function = source[start:end]
harness = r'''
import Foundation
import CryptoKit
FUNCTION
let cache = URL(fileURLWithPath: "/tmp/stable-cache")
let a = cache.appendingPathComponent("A.swift"), b = cache.appendingPathComponent("B.swift")
let added = cache.appendingPathComponent("AA.swift")
let previous = [a.path: ["object": cache.appendingPathComponent("object-0.o").path,
                        "swift-dependencies": cache.appendingPathComponent("object-0.swiftdeps").path],
                b.path: ["object": cache.appendingPathComponent("object-1.o").path,
                        "swift-dependencies": cache.appendingPathComponent("object-1.swiftdeps").path]]
let changed = stableOutputMap(files: [a, added, b], cache: cache, previous: previous)
precondition(changed[a.path] == previous[a.path] && changed[b.path] == previous[b.path])
let reordered = stableOutputMap(files: [b, added, a], cache: cache, previous: changed)
precondition(reordered == changed)
let empty = stableOutputMap(files: [a, added, b], cache: cache, previous: [:])
let reversed = stableOutputMap(files: [b, added, a], cache: cache, previous: [:])
precondition(empty == reversed)
precondition(Set([a, added, b].compactMap { empty[$0.path]?["object"] }).count == 3)
let removed = stableOutputMap(files: [added, b], cache: cache, previous: changed)
precondition(removed[added.path] == changed[added.path] && removed[b.path] == changed[b.path])
precondition(removed[a.path] == nil)
let partial = stableOutputMap(files: [a], cache: cache, previous: [a.path: ["object": "missing-dependency"]])
precondition(partial[a.path] == empty[a.path])
precondition(changed[""]?["swift-dependencies"] == cache.appendingPathComponent("master.swiftdeps").path)
print("Stable native output map regression passed")
'''.replace('FUNCTION', function)
with tempfile.TemporaryDirectory(prefix='aidoku-stable-map-') as temp:
    directory = Path(temp)
    (directory / 'main.swift').write_text(harness)
    started = time.perf_counter()
    subprocess.run(['swiftc', str(directory / 'main.swift'), '-o', str(directory / 'test')], check=True)
    built = time.perf_counter()
    subprocess.run([str(directory / 'test')], check=True)
    print(f'Build {built-started:.3f}s; test {time.perf_counter()-built:.3f}s')
