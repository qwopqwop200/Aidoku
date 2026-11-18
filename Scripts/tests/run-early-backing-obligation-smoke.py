#!/usr/bin/env python3
"""Exact pure backing admission geometry; not a final-pixel quality test."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'Aidoku/Core/Translation/NativeEngine/Overlay/NativeTextBoxEarlySurfaceTrial.swift').read_text()
start = source.index('    static func backingUnion(')
end = source.index('\n    }', start) + len('\n    }')
harness = '''import Foundation
import CoreGraphics
enum Trial {
''' + source[start:end] + '''
}
let owner = CGRect(x: 10, y: 10, width: 10, height: 20)
let old = owner.insetBy(dx: -1, dy: -1)
let new = CGRect(x: 10, y: 9, width: 11, height: 22)
let face = old.insetBy(dx: -5, dy: -5)
let result = Trial.backingUnion(candidate: new, incumbent: old, owner: owner, peers: [], contains: { face.contains($0) })!
precondition(result == old.union(new) && result.contains(old) && result.contains(new))
precondition(Trial.backingUnion(candidate: old, incumbent: old, owner: owner, peers: [], contains: { _ in true }) == nil)
precondition(Trial.backingUnion(candidate: new, incumbent: old, owner: owner, peers: [old], contains: { _ in true }) == nil)
precondition(Trial.backingUnion(candidate: new, incumbent: old, owner: owner, peers: [], contains: { _ in false }) == nil)
precondition(Trial.backingUnion(candidate: new, incumbent: .zero, owner: owner, peers: [], contains: { _ in true }) == nil)
precondition(Trial.backingUnion(candidate: new, incumbent: CGRect(x: 0,y: 0,width: 1,height: 1), owner: owner, peers: [], contains: { _ in true }) == nil)
print("PASS: retained source obligation, full rectangular containment, peer veto and invalid/foreign incumbent veto")
'''
with tempfile.TemporaryDirectory(prefix='aidoku-backing-obligation-') as directory:
    work = Path(directory)
    (work / 'main.swift').write_text(harness)
    subprocess.run(['xcrun', 'swiftc', '-O', str(work / 'main.swift'), '-o', str(work / 'probe')], check=True)
    subprocess.run([str(work / 'probe')], check=True)
