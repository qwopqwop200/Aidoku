#!/usr/bin/env python3
"""Focused tests of live column relations, without retired pipeline test APIs."""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Scripts'))
from swift_replay_cache import compile_replay

translation = ROOT / 'Aidoku/Core/Translation'
sources = [translation / 'NativeEngine/OCR/BrowserOCRSourceOrientation.swift',
           translation / 'NativeParagraphFragmentGrouping.swift']
main = r'''
import Foundation
import CoreGraphics
typealias Grouping = NativeParagraphFragmentGrouping
typealias Atom = Grouping.Atom
for scale: CGFloat in [0.5, 1, 2] {
    for text in ["x", "xxxx", "xxxxxxxxxxxxxxxx"] {
        let a = Atom(index: 8, source: text,
            box: CGRect(x: 30, y: 10, width: 10, height: 100).applying(.init(scaleX: scale, y: scale)),
            orientation: .vertical, owner: nil)
        let b = Atom(index: 19, source: "abcdefghij",
            box: CGRect(x: 15, y: 10, width: 10, height: 100).applying(.init(scaleX: scale, y: scale)),
            orientation: .vertical, owner: nil)
        let links = Grouping.measuredColumnEdges(atoms: [a, b])
        precondition(links.contains { Set([$0.first, $0.second]) == Set([8, 19]) })
        precondition(Grouping.measuredColumnEdges(atoms: [a, a]).isEmpty)
        let distant = Atom(index: 20, source: "abcdefghij",
            box: CGRect(x: 0, y: 10, width: 10, height: 100).applying(.init(scaleX: scale, y: scale)),
            orientation: .vertical, owner: nil)
        precondition(Grouping.measuredColumnEdges(atoms: [a, distant]).isEmpty)
    }
}
precondition(!Grouping.compatibleGlyphScale(10, 20))
precondition(Grouping.compatibleGlyphScale(10, 15))
let parent = Atom(index: 0, source: "a", box: CGRect(x: 0, y: 0, width: 20, height: 100), orientation: .vertical, owner: nil)
let tail = Atom(index: 1, source: "b", box: CGRect(x: 5, y: 110, width: 10, height: 20), orientation: .vertical, owner: nil)
precondition(Grouping.columnRelations(atoms: [parent, tail]).isEmpty)
precondition(!Grouping.columnRelations(atoms: [parent, tail], maximumFitRatio: 2).isEmpty)
print("Column geometry: transcription invariance, scale invariance, gap, duplicate IDs and font scale passed")
'''
cache = ROOT / 'build/paragraph-column-geometry-smoke'
cache.mkdir(parents=True, exist_ok=True)
binary = cache / 'smoke'
compile_replay(cache, sources, main, binary)
subprocess.run([str(binary)], check=True)
